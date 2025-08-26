#!/bin/bash

# Unified Kind Cluster Setup with IRSA Support
# This script creates a kind cluster that can optionally support IRSA (IAM Roles for Service Accounts)
# Compatible with all Arrow Cache dataset flavors: regular, imdb, alpaca, and future datasets

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME=${CLUSTER_NAME:-"arrow-cache-demo"}
ENABLE_IRSA=false
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_PROFILE="root-ricardo"
SUFFIX="$(date +%Y%m%d-%H%M%S)"
SLEEP_TIME=30
INSTALL_TRAINER=true
INSTALL_TRAINER_RUNTIMES=true
INSTALL_LEADERWORKERSET=true
LEADERWORKERSET_VERSION=${LEADERWORKERSET_VERSION:-"v0.7.0"}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared functions from IRSA setup if available
if [[ -f "$SCRIPT_DIR/irsa/lib/functions.sh" ]]; then
    source "$SCRIPT_DIR/irsa/lib/functions.sh"
fi

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
Unified Kind Cluster Setup with IRSA Support

This script creates a kind cluster that can optionally support IRSA (IAM Roles for Service Accounts).
It is compatible with all Arrow Cache dataset flavors: regular, imdb, alpaca, and future datasets.

Usage: $0 [OPTIONS]

Options:
  --cluster-name NAME         Name of the kind cluster (default: arrow-cache-demo)
  --enable-irsa               Enable IRSA support (creates S3 OIDC provider and configures kind)
  --aws-region REGION         AWS region to use (default: us-east-1, only used with --enable-irsa)
  --aws-profile PROFILE       AWS profile to use (optional, only used with --enable-irsa)
  --suffix SUFFIX             Unique suffix for AWS resources (default: timestamp, only used with --enable-irsa)
  --sleep-time SECONDS        Wait time between operations (default: 30, only used with --enable-irsa)
  --install-trainer           Install Kubeflow Trainer manager (default: true)
  --no-install-trainer        Skip installing Kubeflow Trainer manager
  --install-trainer-runtimes  Install Kubeflow Trainer runtimes (default: true)
  --no-install-trainer-runtimes Skip installing Kubeflow Trainer runtimes
  --install-leaderworkerset   Install LeaderWorkerSet controller (default: true)
  --no-install-leaderworkerset Skip installing LeaderWorkerSet controller
  --leaderworkerset-version   LeaderWorkerSet version to install (default: v0.7.0)
  --debug                     Enable debug output
  --help                      Show this help message

Examples:
  # Create basic kind cluster (no IRSA)
  $0

  # Create kind cluster with IRSA support
  $0 --enable-irsa

  # Create cluster with custom name and IRSA in specific region
  $0 --cluster-name my-demo --enable-irsa --aws-region us-west-2

  # Use custom suffix for resource naming
  $0 --enable-irsa --suffix my-test-1

After setup, you can deploy Arrow Cache datasets to different namespaces:
  - Regular demo: uses namespace "arrow-cache"
  - IMDB demo: uses namespace "arrow-cache-imdb"
  - Alpaca demo: uses namespace "arrow-cache-demo"

When IRSA is enabled, service accounts will be automatically created in each namespace
with the IAM role annotation: eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/ArrowCacheRole

EOF
}

check_prerequisites() {
    log "Checking prerequisites..."

    local missing_tools=()

    # Basic tools required for kind cluster
    for tool in kubectl kind docker; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    # Additional tools required for IRSA
    if [[ "$ENABLE_IRSA" == true ]]; then
        for tool in aws jq go openssl curl; do
            if ! command -v "$tool" &> /dev/null; then
                missing_tools+=("$tool")
            fi
        done
    fi

    if [ ${#missing_tools[@]} -ne 0 ]; then
        error "Missing required tools: ${missing_tools[*]}"
        log "Please install the missing tools and try again."
        exit 1
    fi

    # Check Docker daemon
    if ! docker info &> /dev/null; then
        error "Docker daemon is not running. Please start Docker."
    fi

    # Check AWS credentials if IRSA is enabled
    if [[ "$ENABLE_IRSA" == true ]]; then
        if ! aws sts get-caller-identity &> /dev/null; then
            error "AWS credentials not configured or invalid"
            log "Please run 'aws configure' or set up your AWS credentials."
            exit 1
        fi
    fi

    success "All prerequisites are met."
}

create_basic_kind_cluster() {
    log "Creating basic kind cluster: $CLUSTER_NAME"

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
- role: worker
EOF

        kind create cluster --name "$CLUSTER_NAME" --config /tmp/kind-config.yaml
        success "Kind cluster '$CLUSTER_NAME' created successfully."
    fi

    # Set kubectl context
    kubectl cluster-info --context "kind-${CLUSTER_NAME}"

    success "Kind cluster '$CLUSTER_NAME' is ready and context is set."
}

create_irsa_kind_cluster() {
    log "Creating IRSA-enabled kind cluster: $CLUSTER_NAME"

    # Check if IRSA setup script exists
    local irsa_setup="$SCRIPT_DIR/irsa/setup-irsa-kind.sh"
    if [[ ! -f "$irsa_setup" ]]; then
        error "IRSA setup script not found at: $irsa_setup"
        log "Please ensure the irsa directory is available."
        exit 1
    fi

    # Run the IRSA setup with appropriate parameters
    local irsa_args=(
        "--cluster-name" "$CLUSTER_NAME"
        "--aws-region" "$AWS_REGION"
        "--suffix" "$SUFFIX"
        "--sleep-time" "$SLEEP_TIME"
    )

    if [[ -n "$AWS_PROFILE" ]]; then
        irsa_args+=("--aws-profile" "$AWS_PROFILE")
    fi

    bash "$irsa_setup" "${irsa_args[@]}"

    success "IRSA-enabled kind cluster '$CLUSTER_NAME' created successfully."
}

create_namespace_service_accounts() {
    if [[ "$ENABLE_IRSA" != true ]]; then
        log "IRSA not enabled, skipping service account creation."
        return 0
    fi

    log "Creating service accounts for different dataset namespaces..."

    # Load cluster configuration
    local cluster_config="$SCRIPT_DIR/irsa/cluster-info-$CLUSTER_NAME.env"
    if [[ ! -f "$cluster_config" ]]; then
        warn "Cluster config not found: $cluster_config"
        warn "Skipping service account creation. You'll need to create them manually."
        return 0
    fi

    source "$cluster_config"

    # Define namespaces for different datasets
    local namespaces=("arrow-cache" "arrow-cache-imdb" "arrow-cache-demo")
    local service_account="aws-service-account"
    local role_name="ArrowCacheRole"

    # Create IAM role first (shared across all namespaces)
    local create_role_script="$SCRIPT_DIR/irsa/create-irsa-role.sh"
    if [[ -f "$create_role_script" ]]; then
        log "Creating shared IAM role: $role_name"

        # Create role for the first namespace, then reuse for others
        log "Calling create-irsa-role.sh script..."
        set +e  # Temporarily disable exit on error

        # Ensure AWS environment variables are properly set for the subprocess
        local role_create_env="AWS_PAGER= AWS_REGION=$AWS_REGION"
        if [[ -n "$AWS_PROFILE" ]]; then
            role_create_env="$role_create_env AWS_PROFILE=$AWS_PROFILE"
        fi

        env $role_create_env bash "$create_role_script" \
            --cluster-config "$cluster_config" \
            --role-name "$role_name" \
            --namespace "${namespaces[0]}" \
            --service-account "$service_account" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonS3FullAccess" \
            --policy-arn "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole" \
            --skip-k8s-creation \
            --use-wildcard
        local create_role_exit_code=$?
        set -e  # Re-enable exit on error

        if [ $create_role_exit_code -eq 0 ]; then
            log "IAM role creation completed successfully"
        else
            warn "create-irsa-role.sh exited with code $create_role_exit_code, but continuing..."
            log "IAM role may already exist or there may be a minor issue"
        fi

        local role_arn="arn:aws:iam::$ACCOUNT_ID:role/$role_name"
        success "Created IAM role: $role_arn"

        # Create service accounts in all namespaces
        for namespace in "${namespaces[@]}"; do
            log "Creating service account in namespace: $namespace"

            # Create namespace if it doesn't exist
            kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -

            # Create service account with IAM role annotation
            cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $service_account
  namespace: $namespace
  annotations:
    eks.amazonaws.com/role-arn: "$role_arn"
EOF
            success "Created service account: $namespace/$service_account"
        done
    else
        warn "create-irsa-role.sh script not found, skipping automatic role creation."
        warn "You'll need to create IAM roles and service accounts manually."
    fi
}

install_leaderworkerset() {
    if [[ "$INSTALL_LEADERWORKERSET" == false ]]; then
        log "Skipping LeaderWorkerSet installation (disabled)."
        return 0
    fi

    log "Installing LeaderWorkerSet controller version $LEADERWORKERSET_VERSION..."

    local lws_manifest_url="https://github.com/kubernetes-sigs/lws/releases/download/$LEADERWORKERSET_VERSION/manifests.yaml"

    # Install LeaderWorkerSet
    if kubectl apply --server-side -f "$lws_manifest_url"; then
        success "LeaderWorkerSet manifests applied successfully."
    else
        error "Failed to install LeaderWorkerSet."
        exit 1
    fi

    # Wait for the controller to be ready
    log "Waiting for LeaderWorkerSet controller to be ready..."
    if kubectl wait deploy/lws-controller-manager -n lws-system --for=condition=available --timeout=300s; then
        success "LeaderWorkerSet controller is ready."
    else
        warn "Timeout waiting for LeaderWorkerSet controller. It may still be starting up."
    fi

    # Show status
    echo
    log "LeaderWorkerSet controller status:"
    kubectl get deployments -n lws-system || true
    echo
}

install_kubeflow_trainer_components() {
    if [[ "$INSTALL_TRAINER" == false ]] && [[ "$INSTALL_TRAINER_RUNTIMES" == false ]]; then
        log "Skipping Kubeflow Trainer components installation (both disabled)."
        return 0
    fi

    log "Installing Kubeflow Trainer components..."

    # Navigate to the trainer manifest directory (relative to the script location)
    local manifests_dir="$SCRIPT_DIR/../../../manifests"

    # Check if manifests directory exists
    if [[ ! -d "$manifests_dir" ]]; then
        error "Kubeflow Trainer manifests directory not found at: $manifests_dir"
        log "Please ensure you're running this script from the correct location."
        exit 1
    fi

    # Install Kubeflow Trainer Manager
    if [[ "$INSTALL_TRAINER" == true ]]; then
        log "Installing Kubeflow Trainer Manager..."

        local manager_overlay="$manifests_dir/overlays/manager"
        if [[ ! -f "$manager_overlay/kustomization.yaml" ]]; then
            error "Manager overlay not found at: $manager_overlay"
            exit 1
        fi

        if kubectl apply --server-side -k "$manager_overlay"; then
            success "Kubeflow Trainer Manager installed successfully."
        else
            error "Failed to install Kubeflow Trainer Manager."
            exit 1
        fi

        # Wait for the manager to be ready
        log "Waiting for Kubeflow Trainer Manager to be ready..."
        kubectl wait --for=condition=Available --timeout=300s deployment/kubeflow-trainer-controller-manager -n kubeflow-system || {
            warn "Timeout waiting for kubeflow-trainer-controller-manager deployment. It may still be starting up."
        }

        # Wait for the webhook service to be ready (required for runtime installation)
        log "Waiting for Kubeflow Trainer webhook service to be ready..."
        kubectl wait --for=condition=Available --timeout=120s deployment/kubeflow-trainer-controller-manager -n kubeflow-system

        # Give the webhook a moment to fully initialize
        log "Allowing webhook service to fully initialize..."
        sleep 10
    else
        log "Skipping Kubeflow Trainer Manager installation (disabled)."
    fi

    # Install Kubeflow Trainer Runtimes
    if [[ "$INSTALL_TRAINER_RUNTIMES" == true ]]; then
        # Only install runtimes if manager was also installed (required for webhook)
        if [[ "$INSTALL_TRAINER" == false ]]; then
            # Check if manager is already installed
            if ! kubectl get deployment kubeflow-trainer-controller-manager -n kubeflow-system &>/dev/null; then
                error "Cannot install Kubeflow Trainer Runtimes without the Manager. Please enable --install-trainer first."
                exit 1
            fi

            # If manager exists but wasn't installed in this run, ensure it's ready
            log "Verifying existing Kubeflow Trainer Manager is ready..."
            kubectl wait --for=condition=Available --timeout=120s deployment/kubeflow-trainer-controller-manager -n kubeflow-system
            sleep 5
        fi

        log "Installing Kubeflow Trainer Runtimes..."

        local runtimes_overlay="$manifests_dir/overlays/runtimes"
        if [[ ! -f "$runtimes_overlay/kustomization.yaml" ]]; then
            error "Runtimes overlay not found at: $runtimes_overlay"
            exit 1
        fi

        # Test webhook connectivity before applying runtimes
        log "Testing webhook connectivity..."
        local webhook_ready=false
        for i in {1..6}; do
            if kubectl get validatingwebhookconfigurations.admissionregistration.k8s.io validator.trainer.kubeflow.org &>/dev/null; then
                # Try a dry-run to test webhook
                if timeout 10s kubectl apply --dry-run=server -k "$runtimes_overlay" &>/dev/null; then
                    webhook_ready=true
                    break
                fi
            fi
            log "Webhook not ready yet, waiting... (attempt $i/6)"
            sleep 10
        done

        if [[ "$webhook_ready" == false ]]; then
            warn "Webhook may not be fully ready, but proceeding with runtime installation..."
        fi

        # Apply runtimes with retries
        local retry_count=0
        local max_retries=3
        while [ $retry_count -lt $max_retries ]; do
            if kubectl apply --server-side -k "$runtimes_overlay"; then
                success "Kubeflow Trainer Runtimes installed successfully."
                break
            else
                retry_count=$((retry_count + 1))
                if [ $retry_count -lt $max_retries ]; then
                    warn "Runtime installation failed, retrying in 15 seconds... (attempt $retry_count/$max_retries)"
                    sleep 15
                else
                    error "Failed to install Kubeflow Trainer Runtimes after $max_retries attempts."
                    exit 1
                fi
            fi
        done
    else
        log "Skipping Kubeflow Trainer Runtimes installation (disabled)."
    fi

    # Show status of installed components
    if [[ "$INSTALL_TRAINER" == true ]] || [[ "$INSTALL_TRAINER_RUNTIMES" == true ]]; then
        echo
        log "Kubeflow Trainer components status:"

        if [[ "$INSTALL_TRAINER" == true ]]; then
            echo "Manager deployments:"
            kubectl get deployments -n kubeflow-system || true
            echo
        fi

        if [[ "$INSTALL_TRAINER_RUNTIMES" == true ]]; then
            echo "Available Training Runtimes:"
            kubectl get trainingruntimes --all-namespaces || true
            echo "Available Cluster Training Runtimes:"
            kubectl get clustertrainingruntimes || true
            echo
        fi
    fi
}

show_cluster_info() {
    log "Cluster information:"
    echo
    echo "=== Cluster Details ==="
    echo "  Name: $CLUSTER_NAME"
    echo "  Context: kind-$CLUSTER_NAME"
    echo "  Nodes: 4 (1 control-plane, 3 workers)"
    echo "  Port mappings: 30051:30051, 30052:30052"
    if [[ "$ENABLE_IRSA" == true ]]; then
        echo "  IRSA: Enabled"
        if [[ -f "$SCRIPT_DIR/irsa/cluster-info-$CLUSTER_NAME.env" ]]; then
            source "$SCRIPT_DIR/irsa/cluster-info-$CLUSTER_NAME.env"
            echo "  OIDC Issuer: $ISSUER_URL"
            echo "  Provider ARN: $PROVIDER_ARN"
        fi
    else
        echo "  IRSA: Disabled"
    fi
    echo
    echo "=== Available Nodes ==="
    kubectl get nodes
    echo
    echo "=== Pre-configured Namespaces ==="
    for namespace in arrow-cache arrow-cache-imdb arrow-cache-demo; do
        if kubectl get namespace "$namespace" &>/dev/null; then
            echo "  ✅ $namespace"
            if [[ "$ENABLE_IRSA" == true ]] && kubectl get serviceaccount aws-service-account -n "$namespace" &>/dev/null; then
                echo "    └── Service account: aws-service-account (IRSA-enabled)"
            fi
        else
            echo "  ➖ $namespace (will be created when needed)"
        fi
    done
    echo
    echo "=== LeaderWorkerSet Controller ==="
    if [[ "$INSTALL_LEADERWORKERSET" == true ]]; then
        if kubectl get namespace lws-system &>/dev/null; then
            echo "  ✅ LeaderWorkerSet Controller (version: $LEADERWORKERSET_VERSION)"
            local lws_pods=$(kubectl get pods -n lws-system --no-headers 2>/dev/null | wc -l)
            echo "    └── Controller pods: $lws_pods"
        else
            echo "  ❌ LeaderWorkerSet Controller (installation failed or pending)"
        fi
    else
        echo "  ➖ LeaderWorkerSet Controller (installation skipped)"
    fi
    echo
    echo "=== Kubeflow Trainer Components ==="
    if [[ "$INSTALL_TRAINER" == true ]] || [[ "$INSTALL_TRAINER_RUNTIMES" == true ]]; then
        if [[ "$INSTALL_TRAINER" == true ]]; then
            if kubectl get namespace kubeflow-system &>/dev/null; then
                echo "  ✅ Kubeflow Trainer Manager (namespace: kubeflow-system)"
                local manager_pods=$(kubectl get pods -n kubeflow-system --no-headers 2>/dev/null | wc -l)
                echo "    └── Manager pods: $manager_pods"
            else
                echo "  ❌ Kubeflow Trainer Manager (installation failed or pending)"
            fi
        else
            echo "  ➖ Kubeflow Trainer Manager (installation skipped)"
        fi

        if [[ "$INSTALL_TRAINER_RUNTIMES" == true ]]; then
            local runtime_count=$(kubectl get clustertrainingruntimes --no-headers 2>/dev/null | wc -l)
            if [[ $runtime_count -gt 0 ]]; then
                echo "  ✅ Kubeflow Trainer Runtimes ($runtime_count installed)"
                kubectl get clustertrainingruntimes --no-headers 2>/dev/null | while read -r line; do
                    local runtime_name=$(echo "$line" | awk '{print $1}')
                    echo "    └── $runtime_name"
                done
            else
                echo "  ❌ Kubeflow Trainer Runtimes (installation failed or pending)"
            fi
        else
            echo "  ➖ Kubeflow Trainer Runtimes (installation skipped)"
        fi
    else
        echo "  ➖ Kubeflow Trainer components (installation disabled)"
    fi
    echo
    echo "=== Usage ==="
    echo "This cluster can be used by all Arrow Cache demos:"
    echo "  - Regular demo: cd regular/ && ./setup-arrow-cache.sh"
    echo "  - IMDB demo: cd imdb/ && ./setup-imdb-arrow-cache.sh"
    echo "  - Alpaca demo: cd alpaca/ && ./setup-alpaca-arrow-cache.sh"

    if [[ "$INSTALL_LEADERWORKERSET" == true ]]; then
        echo
        echo "LeaderWorkerSet usage:"
        echo "  - Create LeaderWorkerSet resources for leader-worker pattern workloads"
        echo "  - Example: kubectl apply -f your-leaderworkerset.yaml"
    fi

    if [[ "$INSTALL_TRAINER" == true ]] || [[ "$INSTALL_TRAINER_RUNTIMES" == true ]]; then
        echo
        echo "Kubeflow Trainer usage:"
        echo "  - Create TrainJob resources to run distributed training workloads"
        echo "  - Available runtimes: kubectl get clustertrainingruntimes"
        echo "  - Example: kubectl apply -f your-trainjob.yaml"
    fi
    echo
    if [[ "$ENABLE_IRSA" == true ]]; then
        echo "=== IRSA Configuration ==="
        echo "When deploying with IAM roles, use:"
        echo "  ./setup-arrow-cache.sh --iam-role arn:aws:iam::$ACCOUNT_ID:role/ArrowCacheRole"
        echo
        echo "Configuration saved to:"
        echo "  $SCRIPT_DIR/irsa/cluster-info-$CLUSTER_NAME.env"
        echo
    fi
    echo "=== Cleanup ==="
    echo "To delete this cluster when done:"
    echo "  kind delete cluster --name $CLUSTER_NAME"
    if [[ "$ENABLE_IRSA" == true ]]; then
        echo "  # Clean up AWS resources:"
        echo "  $SCRIPT_DIR/irsa/cleanup-irsa.sh --cluster-config $SCRIPT_DIR/irsa/cluster-info-$CLUSTER_NAME.env"
    fi
    echo
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cluster-name)
                CLUSTER_NAME="$2"
                shift 2
                ;;
            --enable-irsa)
                ENABLE_IRSA=true
                shift
                ;;
            --aws-region)
                AWS_REGION="$2"
                shift 2
                ;;
            --aws-profile)
                AWS_PROFILE="$2"
                shift 2
                ;;
            --suffix)
                SUFFIX="$2"
                shift 2
                ;;
            --sleep-time)
                SLEEP_TIME="$2"
                shift 2
                ;;
            --install-trainer)
                INSTALL_TRAINER=true
                shift
                ;;
            --no-install-trainer)
                INSTALL_TRAINER=false
                shift
                ;;
            --install-trainer-runtimes)
                INSTALL_TRAINER_RUNTIMES=true
                shift
                ;;
            --no-install-trainer-runtimes)
                INSTALL_TRAINER_RUNTIMES=false
                shift
                ;;
            --install-leaderworkerset)
                INSTALL_LEADERWORKERSET=true
                shift
                ;;
            --no-install-leaderworkerset)
                INSTALL_LEADERWORKERSET=false
                shift
                ;;
            --leaderworkerset-version)
                LEADERWORKERSET_VERSION="$2"
                shift 2
                ;;
            --debug)
                set -x
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

    log "Starting Unified Kind Cluster Setup"
    echo "==================================="
    log "Cluster name: $CLUSTER_NAME"
    log "IRSA support: $ENABLE_IRSA"
    if [[ "$ENABLE_IRSA" == true ]]; then
        log "AWS region: $AWS_REGION"
        log "Suffix: $SUFFIX"
        if [[ -n "$AWS_PROFILE" ]]; then
            log "AWS profile: $AWS_PROFILE"
        fi
    fi
    echo

    # Unset AWS pager for non-interactive use
    export AWS_PAGER=""

    # Set AWS profile if specified
    if [[ -n "$AWS_PROFILE" ]]; then
        export AWS_PROFILE="$AWS_PROFILE"
    fi

    # Check prerequisites
    check_prerequisites

    # Create cluster based on IRSA setting
    if [[ "$ENABLE_IRSA" == true ]]; then
        create_irsa_kind_cluster
        create_namespace_service_accounts
    else
        create_basic_kind_cluster
    fi

    # Install LeaderWorkerSet controller
    install_leaderworkerset

    # Install Kubeflow Trainer components
    install_kubeflow_trainer_components

    echo
    echo "========================================"
    success "Kind cluster setup completed successfully!"

    # Show cluster information
    show_cluster_info
}

# Handle cleanup on script exit
cleanup_temp_files() {
    rm -f /tmp/kind-config.yaml
}
trap cleanup_temp_files EXIT

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
