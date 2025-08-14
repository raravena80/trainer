#!/bin/bash

# Arrow Cache Demo Setup - Consolidated Script
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
DEMO_ROOT="$(dirname "$SCRIPT_DIR")"
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
Arrow Cache Demo Setup - Complete Environment

This script sets up the complete distributed Arrow Cache demo environment
including kind cluster, Docker images, data generation, and configuration.

Usage: $0 [OPTIONS]

Options:
  --cluster-only    Only setup cluster and images (no data generation)
  --data-only       Only generate and configure demo data
  --s3-path URL     Use S3 for data storage (requires AWS credentials)
  --records NUM     Number of demo records (default: 10000)
  --files NUM       Number of data files (default: 4)
  --help            Show this help message

Examples:
  # Complete setup with local data
  $0

  # Setup with S3 storage
  $0 --s3-path s3://my-bucket/demo-data

  # Just cluster setup
  $0 --cluster-only

  # Just data generation
  $0 --data-only --records 50000

EOF
}

check_prerequisites() {
    log "Checking prerequisites..."

    # Check required tools
    local required_tools=("kind" "kubectl" "docker" "python3")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            error "$tool is required but not installed"
        fi
    done

    # Check Docker is running
    if ! docker info &> /dev/null; then
        error "Docker daemon is not running. Please start Docker."
    fi

    # Check Python packages for data generation
    if ! python3 -c "import pandas, pyarrow" 2> /dev/null; then
        warn "Python packages pandas/pyarrow not installed. Data generation will be skipped."
        return 1
    fi

    success "All prerequisites are met"
    return 0
}

setup_cluster() {
    log "Setting up Kind cluster..."

    # Create kind cluster if it doesn't exist
    if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        warn "Kind cluster '$CLUSTER_NAME' already exists. Using existing cluster."
    else
        # Create cluster config
        cat > /tmp/kind-config.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 30051
    hostPort: 30051
    protocol: TCP
  - containerPort: 30052
    hostPort: 30052
    protocol: TCP
- role: worker
- role: worker
- role: worker
EOF

        kind create cluster --name "$CLUSTER_NAME" --config /tmp/kind-config.yaml
        success "Kind cluster '$CLUSTER_NAME' created successfully."
    fi

    # Set kubectl context
    kubectl cluster-info --context "kind-${CLUSTER_NAME}"
}

build_and_load_image() {
    log "Building and loading Arrow Cache Docker image..."

    cd "$TRAINER_ROOT"

    # Build the Docker image
    docker build -f cmd/data_cache/Dockerfile -t "$IMAGE_NAME" .

    # Load the image into kind cluster
    kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME"

    success "Docker image built and loaded into kind cluster."
}

deploy_arrow_cache() {
    log "Deploying Arrow Cache to Kubernetes..."

    cd "$TRAINER_ROOT"

    # Apply the manifests using kustomize
    kubectl apply -k demo/manifests/arrow-cache/

    # Wait for worker statefulset to be ready (head will wait for data)
    log "Waiting for worker pods to be ready..."
    kubectl wait --for=condition=ready --timeout=300s statefulset/arrow-cache-worker -n "$NAMESPACE"

    success "Arrow Cache deployed successfully."
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

setup_port_forwarding() {
    log "Setting up port forwarding for demo access..."

    # Kill any existing port-forwards
    pkill -f "kubectl port-forward.*arrow-cache" || true
    sleep 2

    # Start port-forwarding in background
    kubectl port-forward -n arrow-cache svc/arrow-cache-head-svc 50051:50051 &
    kubectl port-forward -n arrow-cache arrow-cache-worker-0 50052:50051 &
    kubectl port-forward -n arrow-cache arrow-cache-worker-1 50053:50051 &

    # Wait for port-forwards to establish
    sleep 3

    success "Port forwarding setup complete"
}

show_demo_status() {
    local metadata_path="$1"

    log "Demo setup completed successfully!"

    cat <<EOF

🎉 Arrow Cache Demo Environment Ready!

✅ What was setup:
  - Kind cluster with 3 nodes
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
   kubectl get pods -n arrow-cache
   ./demo/scripts/demo-arrow-cache-status.sh

2. Run demo client:
   python3 demo/scripts/demo-arrow-cache-client.py --demo

3. View logs:
   kubectl logs -n arrow-cache deployment/arrow-cache-head -f
   kubectl logs -n arrow-cache arrow-cache-worker-0 -f

4. Scale workers:
   kubectl scale statefulset arrow-cache-worker --replicas=4 -n arrow-cache

🧹 Cleanup:
   kind delete cluster --name $CLUSTER_NAME
   pkill -f "kubectl port-forward.*arrow-cache"

EOF
}

main() {
    # Parse arguments
    local cluster_only=false
    local data_only=false
    local s3_path=""
    local records=10000
    local files=4

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
            --s3-path)
                s3_path="$2"
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
            --help)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done

    log "Arrow Cache Demo Setup - Consolidated"
    echo "====================================="
    log "Records: $records"
    log "Files: $files"
    if [[ -n "$s3_path" ]]; then
        log "Storage: $s3_path (S3)"
    else
        log "Storage: /tmp/arrow-cache-demo-data (Local)"
    fi
    echo

    # Check prerequisites
    local has_python=true
    if ! check_prerequisites; then
        has_python=false
    fi

    # Setup cluster if not data-only
    if [[ "$data_only" == false ]]; then
        setup_cluster
        build_and_load_image
        deploy_arrow_cache
    fi

    # Generate and configure data if not cluster-only
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
        local metadata_path
        if [[ "$output_path" == s3://* ]]; then
            metadata_path="$output_path/metadata/table.metadata.json"
        else
            metadata_path="file://$output_path/metadata/table.metadata.json"
        fi

        configure_arrow_cache "$metadata_path"
    fi

    # Setup port forwarding if not data-only
    if [[ "$data_only" == false ]]; then
        setup_port_forwarding
    fi

    # Show final status
    local final_metadata_path
    if [[ -n "$s3_path" ]]; then
        final_metadata_path="$s3_path/metadata/table.metadata.json"
    else
        final_metadata_path="file:///tmp/arrow-cache-demo-data/metadata/table.metadata.json"
    fi

    show_demo_status "$final_metadata_path"
}

# Cleanup on script exit
cleanup() {
    # Kill port-forwards on exit
    pkill -f "kubectl port-forward.*arrow-cache" || true
}
trap cleanup EXIT

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
