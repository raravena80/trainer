#!/bin/bash
set -euo pipefail

# Alpaca Arrow Cache Setup Script
# This script sets up the Arrow Cache system configured for the Alpaca dataset

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/manifests/arrow-cache-alpaca"

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
Alpaca Arrow Cache Setup

This script sets up the Arrow Cache system configured for the Alpaca dataset.

Usage: $0 [OPTIONS]

Options:
  --cluster-name NAME   Name of the kind cluster (default: arrow-cache-demo)
  --no-build           Skip Docker image build check
  --aws-profile NAME   AWS profile to use (default: root-ricardo)
  --iam-role ARN       Use IAM role instead of AWS credentials (EKS only, e.g., arn:aws:iam::123456789:role/MyRole)
  --use-leaderworkerset Use LeaderWorkerSet instead of separate Deployment/StatefulSet
  --help               Show this help message

Examples:
  # Complete setup
  $0

  # Setup with custom cluster name
  $0 --cluster-name my-demo-cluster

  # Skip Docker build check (assumes image exists)
  $0 --no-build

  # Use different AWS profile
  $0 --aws-profile my-profile

  # Use IAM role instead of credentials
  $0 --iam-role arn:aws:iam::120832439621:role/ArrowCacheRole

  # Use LeaderWorkerSet deployment pattern
  $0 --use-leaderworkerset

  # Use LeaderWorkerSet with IAM role
  $0 --use-leaderworkerset --iam-role arn:aws:iam::120832439621:role/ArrowCacheRole

IAM Role Setup:
  To create an IAM role with the required permissions (S3 + Glue), use:

  ../setup-kind/irsa/arrow-cache-alpaca-example.sh

  Or manually create a role with these policies:
  - arn:aws:iam::aws:policy/AmazonS3FullAccess
  - arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole

EOF
}

check_prerequisites() {
    log "Checking prerequisites..."

    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is not installed or not in PATH"
    fi

    # Check if docker is available
    if ! command -v docker &> /dev/null; then
        error "docker is not installed or not in PATH"
    fi

    # Check if aws cli is available
    if ! command -v aws &> /dev/null; then
        error "aws cli is not installed or not in PATH"
    fi

    success "All prerequisites are met."
}

setup_kind_cluster() {
    local cluster_name="$1"

    # Check if kind cluster is running, create if needed
    if ! kubectl cluster-info &> /dev/null; then
        log "Setting up kind cluster using shared cluster script..."
        bash "$(dirname "$SCRIPT_DIR")/setup-kind-cluster.sh" --cluster-name "$cluster_name"
    else
        log "Kind cluster already running and accessible."
    fi
}

check_docker_image() {
    local no_build="$1"

    if [[ "$no_build" == "true" ]]; then
        log "Skipping Docker image check (--no-build specified)"
        return 0
    fi

    # Check if Docker image exists
    log "Checking for arrow-cache-demo Docker image..."
    if docker images | grep "arrow-cache-demo" > /dev/null 2>&1; then
        log "Found arrow-cache-demo Docker image"
    else
        log "Available images:"
        docker images | head -5
        error "arrow-cache-demo Docker image not found. Please build it first: docker build -t arrow-cache-demo:latest ."
    fi

    # Load Docker image into kind cluster
    log "Loading Docker image into kind cluster..."
    kind load docker-image arrow-cache-demo:latest --name arrow-cache-demo
}

create_irsa_overlay() {
    local iam_role_arn="$1"
    local temp_overlay_dir="/tmp/arrow-cache-alpaca-irsa-overlay"

    log "Creating temporary IRSA overlay at: $temp_overlay_dir"

    # Clean up any existing temp directory
    rm -rf "$temp_overlay_dir"
    mkdir -p "$temp_overlay_dir"

    # Copy only the YAML manifests (not subdirectories) from the base manifests
    find "$MANIFESTS_DIR" -maxdepth 1 -name "*.yaml" -exec cp {} "$temp_overlay_dir/" \;

    # Copy IRSA overlay patches
    local irsa_source="$MANIFESTS_DIR/overlays/irsa"
    cp "$irsa_source/head-deployment-patch.yaml" "$temp_overlay_dir/"
    cp "$irsa_source/worker-statefulset-patch.yaml" "$temp_overlay_dir/"

    # Create aws-service-account.yaml with the specific role ARN
    cat > "$temp_overlay_dir/aws-service-account.yaml" << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-service-account
  namespace: arrow-cache-demo
  annotations:
    eks.amazonaws.com/role-arn: $iam_role_arn
EOF

    # Remove the aws-secret.yaml since we're using IRSA (no need for credentials)
    rm -f "$temp_overlay_dir/aws-secret.yaml"

    # Create a new kustomization.yaml with absolute paths to avoid cycles
    cat > "$temp_overlay_dir/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: arrow-cache-demo

resources:
- namespace.yaml
- configmap.yaml
- worker-statefulset.yaml
- head-deployment.yaml
- aws-service-account.yaml

patches:
- path: head-deployment-patch.yaml
  target:
    kind: Deployment
    name: arrow-cache-head
- path: worker-statefulset-patch.yaml
  target:
    kind: StatefulSet
    name: arrow-cache-worker

images:
- name: arrow-cache
  newTag: latest

commonLabels:
  app.kubernetes.io/name: arrow-cache-demo
  app.kubernetes.io/part-of: trainer
  app.kubernetes.io/component: distributed-cache
EOF

    # Set the overlay directory for deployment
    IRSA_OVERLAY_DIR="$temp_overlay_dir"

    log "Temporary IRSA overlay created successfully"
}

setup_aws_credentials() {
    local aws_profile="$1"
    local iam_role_arn="$2"

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
                warn "  1. Use AWS credentials: $0 --aws-profile your-profile"
                warn "  2. Set up IRSA for kind: scripts/irsa-kind-setup/setup-irsa-kind.sh"
                warn ""
                error "IAM roles are not supported in standard kind clusters."
            fi
        fi

        # Create the temporary IRSA overlay
        log "Configuring IRSA overlay with role: $iam_role_arn"
        create_irsa_overlay "$iam_role_arn"
        log "IRSA overlay configured with role ARN"
    else
        # Check if AWS credentials are configured
        log "Checking AWS credentials..."
        if ! aws configure list --profile "$aws_profile" &> /dev/null; then
            error "AWS profile '$aws_profile' not found. Please configure: aws configure --profile $aws_profile"
        fi

        # Get AWS credentials for secret creation
        log "Extracting AWS credentials..."
        AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id --profile "$aws_profile")
        AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key --profile "$aws_profile")
        AWS_SESSION_TOKEN=$(aws configure get aws_session_token --profile "$aws_profile" 2>/dev/null || echo "")

        if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
            error "AWS credentials not properly configured"
        fi

        # Create temporary AWS secret file with actual credentials
        log "Creating AWS secret with actual credentials..."
        cat > /tmp/aws-secret-alpaca.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: aws-credentials
  namespace: arrow-cache-demo
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "${AWS_ACCESS_KEY_ID}"
  AWS_SECRET_ACCESS_KEY: "${AWS_SECRET_ACCESS_KEY}"
EOF

        # Add session token if available
        if [ ! -z "$AWS_SESSION_TOKEN" ]; then
            echo "  AWS_SESSION_TOKEN: \"${AWS_SESSION_TOKEN}\"" >> /tmp/aws-secret-alpaca.yaml
        fi
    fi
}

deploy_kubernetes_resources() {
    local iam_role_arn="$1"
    local use_leaderworkerset="$2"

    log "Deploying Kubernetes resources..."

    # Check if manifests directory exists
    if [ ! -d "$MANIFESTS_DIR" ]; then
        error "Manifests directory not found: $MANIFESTS_DIR"
    fi

    # Choose deployment method based on IAM role usage and deployment type
    if [ -n "$iam_role_arn" ]; then
        # For IRSA, we need to update the overlay creation to handle LeaderWorkerSet
        if [[ "$use_leaderworkerset" == "true" ]]; then
            # Update the IRSA overlay to use LeaderWorkerSet
            rm -f "$IRSA_OVERLAY_DIR/kustomization.yaml"
            cp "$MANIFESTS_DIR/overlays/irsa/kustomization-lws.yaml" "$IRSA_OVERLAY_DIR/kustomization.yaml"
            cp "$MANIFESTS_DIR/overlays/irsa/lws-patch.yaml" "$IRSA_OVERLAY_DIR/"
        fi

        log "Deploying with IRSA overlay (no AWS credentials in pods)..."
        kubectl apply -k "$IRSA_OVERLAY_DIR/"
        if [[ "$use_leaderworkerset" == "true" ]]; then
            success "IRSA-enabled Alpaca arrow cache deployed using LeaderWorkerSet"
        else
            success "IRSA-enabled Alpaca arrow cache deployed using Deployment/StatefulSet"
        fi
    else
        if [[ "$use_leaderworkerset" == "true" ]]; then
            log "Deploying with LeaderWorkerSet and standard AWS credentials..."
            # Create temporary directory for LeaderWorkerSet deployment
            LWS_TEMP_DIR="/tmp/arrow-cache-alpaca-lws"
            rm -rf "$LWS_TEMP_DIR"
            mkdir -p "$LWS_TEMP_DIR"
            cp "$MANIFESTS_DIR/kustomization-lws.yaml" "$LWS_TEMP_DIR/kustomization.yaml"
            cp "$MANIFESTS_DIR/namespace.yaml" "$LWS_TEMP_DIR/"
            cp "$MANIFESTS_DIR/configmap.yaml" "$LWS_TEMP_DIR/"
            cp "$MANIFESTS_DIR/aws-secret.yaml" "$LWS_TEMP_DIR/"
            cp "$MANIFESTS_DIR/arrow-cache-leaderworkerset.yaml" "$LWS_TEMP_DIR/"
            kubectl apply -k "$LWS_TEMP_DIR/"
            rm -rf "$LWS_TEMP_DIR"
            success "Alpaca arrow cache deployed using LeaderWorkerSet"
        else
            log "Deploying with standard AWS credentials..."
            kubectl apply -k "$MANIFESTS_DIR/"
            success "Standard Alpaca arrow cache deployed"
        fi
    fi
}

wait_for_pods() {
    local use_leaderworkerset="$1"

    log "Waiting for pods to be ready..."

    if [[ "$use_leaderworkerset" == "true" ]]; then
        # Wait for LeaderWorkerSet pods to be ready
        kubectl wait --for=condition=ready pod -l leaderworkerset.sigs.k8s.io/name=arrow-cache-alpaca-lws -n arrow-cache-demo --timeout=300s
        success "LeaderWorkerSet pods are ready"
    else
        # Wait for workers to be ready
        kubectl wait --for=condition=ready pod -l app=arrow-cache-worker -n arrow-cache-demo --timeout=300s
        success "Worker pods are ready"

        # Wait for head to be ready
        kubectl wait --for=condition=ready pod -l app=arrow-cache-head -n arrow-cache-demo --timeout=300s
        success "Head pod is ready"
    fi
}

show_success_info() {
    echo
    success "Alpaca Arrow Cache Demo deployed successfully!"
    echo
    echo "📊 Deployment Status:"
    kubectl get pods -n arrow-cache-demo

    echo
    echo "🔧 Next steps:"
    echo
    echo "1. Set up port forwarding to access the services:"
    echo "   kubectl port-forward -n arrow-cache-demo service/arrow-cache-head-svc 50051:50051 &"
    echo "   kubectl port-forward -n arrow-cache-demo arrow-cache-worker-0 50052:50051 &"
    echo "   kubectl port-forward -n arrow-cache-demo arrow-cache-worker-1 50053:50051 &"
    echo
    echo "2. Run the training script:"
    echo "   python3 alpaca_training.py --use-arrow-cache --dry-run  # Test first"
    echo "   python3 alpaca_training.py --use-arrow-cache            # Real training"
    echo
    echo "3. Monitor logs:"
    echo "   kubectl logs -f -n arrow-cache-demo deployment/arrow-cache-head"
    echo "   kubectl logs -f -n arrow-cache-demo statefulset/arrow-cache-worker"
    echo
    echo "4. Clean up when done:"
    echo "   ./demo/scripts/alpaca/cleanup-alpaca-arrow-cache.sh"

    echo
    echo "📈 Alpaca Dataset Info:"
    echo "  - Total samples: ~52,000 instruction-following examples"
    echo "  - Schema: instruction, input, output, text"
    echo "  - Purpose: Training conversational AI models"
    echo "  - S3 location: s3://ricardo.hf.datasets/iceberg/hf_datasets.db/tatsu-lab_alpaca/"
}

main() {
    # Parse arguments
    local cluster_name="arrow-cache-demo"
    local no_build="false"
    local aws_profile="root-ricardo"
    local iam_role_arn=""
    local use_leaderworkerset="false"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --cluster-name)
                cluster_name="$2"
                shift 2
                ;;
            --no-build)
                no_build="true"
                shift
                ;;
            --aws-profile)
                aws_profile="$2"
                shift 2
                ;;
            --iam-role)
                iam_role_arn="$2"
                shift 2
                ;;
            --use-leaderworkerset)
                use_leaderworkerset="true"
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

    log "Starting Alpaca Arrow Cache Setup"
    echo "=================================="
    log "Cluster: $cluster_name"
    log "Deployment Type: $([ "$use_leaderworkerset" == "true" ] && echo "LeaderWorkerSet" || echo "Deployment/StatefulSet")"
    if [ -n "$iam_role_arn" ]; then
        log "AWS IAM Role: $iam_role_arn"
    else
        log "AWS Profile: $aws_profile"
    fi
    echo

    # Check prerequisites
    check_prerequisites

    # Setup kind cluster
    setup_kind_cluster "$cluster_name"

    # Check Docker image
    check_docker_image "$no_build"

    # Setup AWS credentials
    setup_aws_credentials "$aws_profile" "$iam_role_arn"

    # Deploy Kubernetes resources
    deploy_kubernetes_resources "$iam_role_arn" "$use_leaderworkerset"

    # Wait for pods to be ready
    wait_for_pods "$use_leaderworkerset"

    # Show success information
    show_success_info
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
