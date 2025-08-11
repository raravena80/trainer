#!/bin/bash

# Arrow Cache Kind Cluster Setup Script
# This script sets up the distributed arrow cache system on a local kind cluster

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME=${CLUSTER_NAME:-"arrow-cache-demo"}
IMAGE_NAME="arrow-cache:latest"
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

create_kind_cluster() {
    log "Creating kind cluster: $CLUSTER_NAME"

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
EOF

        kind create cluster --name "$CLUSTER_NAME" --config /tmp/kind-config.yaml
        success "Kind cluster '$CLUSTER_NAME' created successfully."
    fi

    # Set kubectl context
    kubectl cluster-info --context "kind-${CLUSTER_NAME}"
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

update_configuration() {
    log "Updating configuration files..."

    # Prompt for configuration values or use defaults
    read -p "Enter metadata location (e.g., gs://your-bucket/metadata): " metadata_loc
    read -p "Enter table name: " table_name
    read -p "Enter schema name: " schema_name

    if [[ -z "$metadata_loc" || -z "$table_name" || -z "$schema_name" ]]; then
        warn "Using default configuration values. Update demo/manifests/arrow-cache/configmap.yaml manually if needed."
        return
    fi

    # Update configmap with user values
    sed -i.bak "s|gs://your-bucket/metadata|$metadata_loc|g" "$DEMO_ROOT/manifests/arrow-cache/configmap.yaml"
    sed -i.bak "s|your_table|$table_name|g" "$DEMO_ROOT/manifests/arrow-cache/configmap.yaml"
    sed -i.bak "s|your_schema|$schema_name|g" "$DEMO_ROOT/manifests/arrow-cache/configmap.yaml"

    success "Configuration updated."
}

deploy_arrow_cache() {
    log "Deploying arrow cache to kind cluster..."

    cd "$TRAINER_ROOT"

    # Apply the manifests using kustomize
    kubectl apply -k demo/manifests/arrow-cache/

    # Wait for deployments to be ready
    log "Waiting for deployments to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/arrow-cache-head -n "$NAMESPACE"
    kubectl wait --for=condition=ready --timeout=300s statefulset/arrow-cache-worker -n "$NAMESPACE"

    success "Arrow cache deployed successfully."
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

    # Port forward head service
    kubectl port-forward -n "$NAMESPACE" service/arrow-cache-head-svc 50051:50051 &
    HEAD_PF_PID=$!

    echo
    success "Port forwarding setup:"
    echo "  - Head service: localhost:50051"
    echo "  - To stop port forwarding: kill $HEAD_PF_PID"
    echo
    echo "You can now connect to the arrow cache head node at: localhost:50051"
}

show_demo_commands() {
    log "Demo commands and next steps:"

    cat <<EOF

=== Arrow Cache Demo Commands ===

1. Check cluster status:
   kubectl get all -n arrow-cache

2. View logs:
   kubectl logs -n arrow-cache -l component=head -f
   kubectl logs -n arrow-cache -l component=worker -f

3. Access head node (with port forwarding):
   # Use your Flight client to connect to localhost:50051

4. Scale workers:
   kubectl scale statefulset arrow-cache-worker --replicas=3 -n arrow-cache

5. Delete deployment:
   kubectl delete -k demo/manifests/arrow-cache/

6. Delete kind cluster:
   kind delete cluster --name $CLUSTER_NAME

=== Troubleshooting ===

- If pods are not starting, check the logs:
  kubectl describe pod -n arrow-cache <pod-name>

- If you need to rebuild the image:
  docker build -f cmd/data_cache/Dockerfile -t $IMAGE_NAME .
  kind load docker-image $IMAGE_NAME --name $CLUSTER_NAME
  kubectl rollout restart deployment/arrow-cache-head -n arrow-cache
  kubectl rollout restart statefulset/arrow-cache-worker -n arrow-cache

EOF
}

main() {
    log "Starting Arrow Cache Kind Cluster Setup"
    echo "========================================"

    check_prerequisites
    create_kind_cluster
    build_docker_image
    update_configuration
    deploy_arrow_cache
    show_status

    echo
    echo "========================================"
    success "Arrow Cache setup completed successfully!"

    setup_port_forwarding
    show_demo_commands
}

# Handle cleanup on script exit
cleanup() {
    if [[ -n "${HEAD_PF_PID:-}" ]]; then
        kill "$HEAD_PF_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
