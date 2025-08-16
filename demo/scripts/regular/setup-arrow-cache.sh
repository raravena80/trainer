#!/bin/bash

# Unified Arrow Cache Setup Script
# This script sets up the complete distributed Arrow Cache demo environment

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME=${CLUSTER_NAME:-"arrow-cache-demo"}
IMAGE_NAME="arrow-cache-demo:latest"
NAMESPACE="arrow-cache"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
TRAINER_ROOT="$(dirname "$DEMO_ROOT")"

# Functions
log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

show_help() {
    cat <<EOF
Unified Arrow Cache Setup - Complete Environment

This script sets up the complete distributed Arrow Cache demo environment
including kind cluster, Docker images, data generation, and configuration.

Usage: $0 [OPTIONS]

Options:
  --cluster-only    Only setup cluster and cache (no data generation)
  --data-only       Only generate and configure demo data
  --cache-only      Only deploy cache (assumes cluster exists)
  --no-build        Skip Docker image build (use existing image)
  --s3-path URL     Use S3 for data storage (requires AWS credentials)
  --iam-role ARN    Use IAM role instead of AWS credentials (EKS only, e.g., arn:aws:iam::123456789:role/MyRole)
  --records NUM     Number of demo records (default: 10000)
  --files NUM       Number of data files (default: 4)
  --no-port-forward Skip port forwarding setup
  --help            Show this help message

Examples:
  # Complete setup with local data
  $0

  # Setup with S3 storage
  $0 --s3-path s3://my-bucket/demo-data

  # Setup with S3 and IAM role
  $0 --s3-path s3://my-bucket/demo-data --iam-role arn:aws:iam::120832439621:role/ArrrowDemo

  # Just cluster and cache setup
  $0 --cluster-only

  # Just cache deployment (cluster exists)
  $0 --cache-only

  # Just data generation
  $0 --data-only --records 50000

IAM Role Setup:
  To create an IAM role with the required permissions (S3 + Glue), use:

  ../setup-kind/irsa/arrow-cache-example.sh --demo-type regular

  Or manually create a role with these policies:
  - arn:aws:iam::aws:policy/AmazonS3FullAccess
  - arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole

EOF
}

check_prerequisites() {
    log "Checking prerequisites..."

    # Check if kind is installed
    if ! command -v kind &> /dev/null; then
        error "kind is not installed. Please install it from https://kind.sigs.k8s.io/docs/user/quick-start/"
    fi

    # Check if kubectl is installed
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is not installed. Please install it from https://kubernetes.io/docs/tasks/tools/"
    fi

    # Check if docker is installed and running
    if ! command -v docker &> /dev/null; then
        error "docker is not installed. Please install Docker Desktop or Docker Engine."
    fi

    if ! docker info &> /dev/null; then
        error "Docker daemon is not running. Please start Docker."
    fi

    success "All prerequisites are met."
}

check_python_prerequisites() {
    # Check Python packages for data generation
    if ! command -v python3 &> /dev/null; then
        warn "python3 is not installed. Data generation will be skipped."
        return 1
    fi

    if ! python3 -c "import pandas, pyarrow" 2> /dev/null; then
        warn "Python packages pandas/pyarrow not installed. Data generation will be skipped."
        return 1
    fi

    return 0
}

create_kind_cluster() {
    log "Setting up kind cluster using shared cluster script..."

    # Use the shared cluster setup script
    bash "$(dirname "$SCRIPT_DIR")/setup-kind-cluster.sh" --cluster-name "$CLUSTER_NAME"
}

build_docker_image() {
    log "Building arrow cache Docker image..."

    cd "$TRAINER_ROOT"

    # Build the Docker image
    docker build -f cmd/data_cache/Dockerfile -t "$IMAGE_NAME" .

    # Load the image into kind cluster
    kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME"

    success "Docker image built and loaded into kind cluster."
}

setup_aws_credentials() {
    local iam_role_arn="$1"

    if [ -n "$iam_role_arn" ]; then
        log "Using IAM role for AWS access: $iam_role_arn"

        # Check if we're running in kind (IAM roles don't work in regular kind)
        if kubectl cluster-info | grep -q "kind-"; then
            # Check if this is an IRSA-enabled kind cluster
            if kubectl get deployment pod-identity-webhook -n pod-identity-webhook &>/dev/null; then
                log "Detected IRSA-enabled kind cluster - IAM roles are supported"
            else
                warn "⚠️  IAM roles only work in Amazon EKS or IRSA-enabled clusters!"
                warn "You're running in a standard kind cluster where IAM roles won't work."
                warn "The deployment will fail with 'InvalidAccessKeyId' errors."
                warn ""
                warn "Options:"
                warn "  1. Use AWS credentials: $0 --s3-path $s3_path --aws-profile your-profile"
                warn "  2. Set up IRSA for kind: scripts/irsa-kind-setup/setup-irsa-kind.sh"
                warn ""
                error "IAM roles are not supported in standard kind clusters."
            fi
        fi

        # Update the IRSA overlay with the specific role ARN
        log "Configuring IRSA overlay with role: $iam_role_arn"

        # Create temporary overlay with the correct role ARN and fix relative paths
        TEMP_OVERLAY_DIR="/tmp/arrow-cache-irsa-overlay"
        rm -rf "$TEMP_OVERLAY_DIR"
        mkdir -p "$TEMP_OVERLAY_DIR"

        # Copy the overlay files
        cp "$TRAINER_ROOT/demo/manifests/arrow-cache/overlays/irsa/"*.yaml "$TEMP_OVERLAY_DIR/"

        # Create a symlink to the base manifests to avoid absolute path issues
        ln -sf "$TRAINER_ROOT/demo/manifests/arrow-cache" "$TEMP_OVERLAY_DIR/base"

        # Create a new kustomization.yaml that references the symlinked base
        cat > "$TEMP_OVERLAY_DIR/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Use the base arrow-cache manifests and add IRSA service account
resources:
- base
- aws-service-account.yaml

# Patch deployments to remove AWS credentials and add service account
patches:
- path: head-deployment-patch.yaml
  target:
    kind: Deployment
    name: arrow-cache-head
- path: worker-statefulset-patch.yaml
  target:
    kind: StatefulSet
    name: arrow-cache-worker
EOF

        # Substitute the role ARN
        sed -i.bak "s|ROLE_ARN_PLACEHOLDER|$iam_role_arn|g" "$TEMP_OVERLAY_DIR/aws-service-account.yaml"

        success "IRSA overlay configured with role ARN"
    else
        log "Setting up AWS credentials..."

        # Check if setup-aws.sh exists
        if [[ -f "$SCRIPT_DIR/setup-aws.sh" ]]; then
            log "Running AWS setup..."
            bash "$SCRIPT_DIR/setup-aws.sh" --from-cli
            success "AWS credentials configured"
        else
            warn "setup-aws.sh not found. Skipping AWS credentials setup."
            warn "You'll need to configure AWS credentials manually if using S3 data."
        fi
    fi
}

deploy_arrow_cache() {
    local iam_role_arn="$1"

    log "Deploying arrow cache to kind cluster..."

    cd "$TRAINER_ROOT"

    # Choose deployment method based on IAM role usage
    if [ -n "$iam_role_arn" ]; then
        log "Deploying with IRSA overlay (no AWS credentials in pods)..."
        kubectl apply -k /tmp/arrow-cache-irsa-overlay/
        success "IRSA-enabled arrow cache deployed"
    else
        log "Deploying with standard AWS credentials..."
        kubectl apply -k demo/manifests/arrow-cache/
        success "Standard arrow cache deployed"
    fi

    # Clean up temporary overlay directory if used
    if [ -n "$iam_role_arn" ]; then
        rm -rf /tmp/arrow-cache-irsa-overlay
    fi

    # Wait for deployments to be ready
    log "Waiting for deployments to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/arrow-cache-head -n "$NAMESPACE"
    kubectl wait --for=condition=ready --timeout=300s statefulset/arrow-cache-worker -n "$NAMESPACE"

    success "Arrow cache deployed successfully."
}

generate_demo_data() {
    local output_path="$1"
    local records="$2"
    local files="$3"

    log "Generating demo data with $records records in $files files..."

    # Run the data generator
    python3 "$DEMO_ROOT/scripts/generate-demo-data.py" \
        --output "$output_path" \
        --records "$records" \
        --files "$files" \
        --table-name "demo_events" \
        --schema-name "demo"

    if [ $? -ne 0 ]; then
        error "Failed to generate demo data"
    fi

    success "Demo data generated successfully"
}

configure_arrow_cache() {
    local metadata_path="$1"

    log "Configuring Arrow Cache to use generated data..."

    # Update the configmap with new metadata location
    kubectl patch configmap arrow-cache-config -n "$NAMESPACE" \
        --patch "{\"data\":{\"METADATA_LOC\":\"$metadata_path\",\"TABLE_NAME\":\"demo_events\",\"SCHEMA_NAME\":\"demo\"}}"

    if [ $? -ne 0 ]; then
        error "Failed to update Arrow Cache configuration"
    fi

    # Configure fallback files if using S3
    if [[ "$metadata_path" == s3://* ]]; then
        local s3_base=$(echo "$metadata_path" | sed 's|/metadata/table.metadata.json||')
        kubectl patch configmap arrow-cache-config -n "$NAMESPACE" \
            --patch "{\"data\":{\"ARROW_CACHE_FALLBACK_FILES\":\"${s3_base}/data/data_000.parquet:2500,${s3_base}/data/data_001.parquet:2500,${s3_base}/data/data_002.parquet:2500,${s3_base}/data/data_003.parquet:2500\"}}"
    fi

    # Restart the head deployment to pick up new configuration
    log "Restarting head node to apply new configuration..."
    kubectl rollout restart deployment/arrow-cache-head -n "$NAMESPACE"

    # Wait for rollout to complete
    kubectl rollout status deployment/arrow-cache-head -n "$NAMESPACE" --timeout=120s

    success "Arrow Cache configured and restarted"
}

show_status() {
    log "Checking deployment status..."

    echo
    echo "=== Namespace ==="
    kubectl get namespace "$NAMESPACE"

    echo
    echo "=== Pods ==="
    kubectl get pods -n "$NAMESPACE" -o wide

    echo
    echo "=== Services ==="
    kubectl get services -n "$NAMESPACE"

    echo
    echo "=== StatefulSet ==="
    kubectl get statefulset -n "$NAMESPACE"

    echo
    echo "=== Deployment ==="
    kubectl get deployment -n "$NAMESPACE"
}

setup_port_forwarding() {
    log "Setting up port forwarding for local access..."

    # Kill any existing port-forwards for arrow-cache
    pkill -f "kubectl port-forward.*arrow-cache" || true
    sleep 2

    # Port forward head service
    kubectl port-forward -n "$NAMESPACE" service/arrow-cache-head-svc 50051:50051 &
    HEAD_PF_PID=$!

    # Port forward workers for direct access
    kubectl port-forward -n "$NAMESPACE" arrow-cache-worker-0 50052:50051 &
    WORKER0_PF_PID=$!

    kubectl port-forward -n "$NAMESPACE" arrow-cache-worker-1 50053:50051 &
    WORKER1_PF_PID=$!

    # Wait for port-forwards to establish
    sleep 3

    echo
    success "Port forwarding setup:"
    echo "  - Head service: localhost:50051"
    echo "  - Worker 0: localhost:50052"
    echo "  - Worker 1: localhost:50053"
    echo "  - To stop: pkill -f \"kubectl port-forward.*arrow-cache\""
    echo
}

show_demo_commands() {
    local metadata_path="$1"

    log "Demo setup completed successfully!"

    cat <<EOF

🎉 Arrow Cache Demo Environment Ready!

✅ What was setup:
  - Kind cluster: $CLUSTER_NAME
  - Arrow Cache head and worker pods
  - Demo data with realistic events
  - Port forwarding for local access

📊 Configuration:
  - Metadata location: $metadata_path
  - Head node: localhost:50051
  - Worker 0: localhost:50052
  - Worker 1: localhost:50053

🚀 Demo Commands:

1. Check status:
   kubectl get all -n arrow-cache

2. View logs:
   kubectl logs -n arrow-cache -l component=head -f
   kubectl logs -n arrow-cache -l component=worker -f

3. Run demo client (if available):
   python3 $DEMO_ROOT/scripts/demo-arrow-cache-client.py --demo

4. Scale workers:
   kubectl scale statefulset arrow-cache-worker --replicas=3 -n arrow-cache

5. Access head node (with port forwarding):
   # Use your Flight client to connect to localhost:50051

=== Troubleshooting ===

- If pods are not starting, check the logs:
  kubectl describe pod -n arrow-cache <pod-name>

- If you need to rebuild the image:
  docker build -f cmd/data_cache/Dockerfile -t $IMAGE_NAME $TRAINER_ROOT
  kind load docker-image $IMAGE_NAME --name $CLUSTER_NAME
  kubectl rollout restart deployment/arrow-cache-head -n arrow-cache
  kubectl rollout restart statefulset/arrow-cache-worker -n arrow-cache

🧹 Cleanup:
  kind delete cluster --name $CLUSTER_NAME
  pkill -f "kubectl port-forward.*arrow-cache"

EOF
}

main() {
    # Parse arguments
    local cluster_only=false
    local data_only=false
    local cache_only=false
    local no_build=false
    local s3_path=""
    local iam_role_arn=""
    local records=10000
    local files=4
    local no_port_forward=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --cluster-only)
                cluster_only=true
                shift
                ;;
            --data-only)
                data_only=true
                shift
                ;;
            --cache-only)
                cache_only=true
                shift
                ;;
            --no-build)
                no_build=true
                shift
                ;;
            --s3-path)
                s3_path="$2"
                shift 2
                ;;
            --iam-role)
                iam_role_arn="$2"
                shift 2
                ;;
            --records)
                records="$2"
                shift 2
                ;;
            --files)
                files="$2"
                shift 2
                ;;
            --no-port-forward)
                no_port_forward=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done

    log "Starting Unified Arrow Cache Setup"
    echo "=================================="
    log "Cluster: $CLUSTER_NAME"
    log "Records: $records"
    log "Files: $files"
    if [[ -n "$s3_path" ]]; then
        log "Storage: $s3_path (S3)"
        if [[ -n "$iam_role_arn" ]]; then
            log "AWS Access: IAM Role ($iam_role_arn)"
        else
            log "AWS Access: Credentials"
        fi
    else
        log "Storage: /tmp/arrow-cache-demo-data (Local)"
    fi
    echo

    # Check prerequisites
    check_prerequisites

    # Check python prerequisites for data generation
    local has_python=true
    if ! check_python_prerequisites; then
        has_python=false
        if [[ "$data_only" == true ]]; then
            error "Data generation requested but Python prerequisites not met"
        fi
    fi

    # Setup AWS credentials if using S3
    if [[ -n "$s3_path" ]] || [[ -n "$iam_role_arn" ]]; then
        setup_aws_credentials "$iam_role_arn"
    fi

    # Create cluster if needed
    if [[ "$data_only" == false ]]; then
        if [[ "$cache_only" == false ]]; then
            create_kind_cluster
            if [[ "$no_build" == false ]]; then
                build_docker_image
            fi
        fi
        deploy_arrow_cache "$iam_role_arn"
    fi

    # Generate and configure data if not cluster-only
    local metadata_path=""
    if [[ "$cluster_only" == false ]] && [[ "$has_python" == true ]]; then
        # Determine output path
        local output_path
        if [[ -n "$s3_path" ]]; then
            output_path="$s3_path"
        else
            output_path="/tmp/arrow-cache-demo-data"
        fi

        generate_demo_data "$output_path" "$records" "$files"

        # Construct metadata path
        if [[ "$output_path" == s3://* ]]; then
            metadata_path="$output_path/metadata/table.metadata.json"
        else
            metadata_path="file://$output_path/metadata/table.metadata.json"
        fi

        if [[ "$data_only" == false ]]; then
            configure_arrow_cache "$metadata_path"
        fi
    fi

    # Show status if cluster was set up
    if [[ "$data_only" == false ]]; then
        show_status

        # Setup port forwarding unless disabled
        if [[ "$no_port_forward" == false ]]; then
            setup_port_forwarding
        fi
    fi

    echo
    echo "========================================"
    success "Arrow Cache setup completed successfully!"

    # Show demo commands with appropriate metadata path
    if [[ -z "$metadata_path" ]]; then
        if [[ -n "$s3_path" ]]; then
            metadata_path="$s3_path/metadata/table.metadata.json"
        else
            metadata_path="file:///tmp/arrow-cache-demo-data/metadata/table.metadata.json"
        fi
    fi

    show_demo_commands "$metadata_path"
}

# Handle cleanup on script exit
cleanup() {
    # Kill port-forwards on exit
    pkill -f "kubectl port-forward.*arrow-cache" 2>/dev/null || true
}
trap cleanup EXIT

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
