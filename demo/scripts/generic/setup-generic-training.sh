#!/bin/bash
set -euo pipefail

# Generic Dataset Training Setup Script
# This script can deploy training jobs for any dataset using Arrow Cache

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
Generic Dataset Training Setup

This script sets up training jobs for any dataset using Arrow Cache integration.

Usage: $0 [OPTIONS]

Required Options:
  --dataset-name NAME       Name of the dataset (alpaca, imdb, regular, or custom)
  --dataset-config FILE     Path to dataset configuration YAML file

Optional Options:
  --execution-id ID         Unique execution ID (default: timestamp)
  --namespace NAME          Kubernetes namespace (default: arrow-cache-demo)
  --model-name NAME         Model to use (default: distilgpt2)
  --max-samples NUM         Maximum samples to use (default: 50)
  --batch-size NUM          Training batch size (default: 1)
  --max-length NUM          Maximum sequence length (default: 128)
  --epochs NUM              Number of training epochs (default: 1)
  --learning-rate FLOAT     Learning rate (default: 5e-5)
  --text-column NAME        Name of text column (default: text)
  --cpu-request SIZE        CPU request (default: 500m)
  --memory-request SIZE     Memory request (default: 1Gi)
  --cpu-limit SIZE          CPU limit (default: 1)
  --memory-limit SIZE       Memory limit (default: 2Gi)
  --service-account NAME    Kubernetes service account (default: aws-service-account)
  --configmap-name NAME     ConfigMap name (default: generic-training-script)
  --arrow-cache-host HOST   Arrow Cache head host (default: arrow-cache-head-svc.arrow-cache-demo.svc.cluster.local)
  --arrow-cache-port PORT   Arrow Cache head port (default: 50051)
  --aws-region REGION       AWS region (default: us-east-1)
  --dry-run                 Run in dry-run mode (no actual training)
  --skip-checkpoint         Skip saving checkpoints
  --use-irsa                Use IRSA for AWS authentication
  --use-arrow-cache         Use Arrow Cache for data loading
  --in-cluster              Running in-cluster mode
  --help                    Show this help message

Examples:
  # Run Alpaca training with Arrow Cache
  $0 --dataset-name alpaca --dataset-config configs/alpaca.yaml --use-arrow-cache --use-irsa --in-cluster

  # Run IMDB training in dry-run mode
  $0 --dataset-name imdb --dataset-config configs/imdb.yaml --dry-run --use-arrow-cache

  # Run custom dataset training
  $0 --dataset-name my-dataset --dataset-config /path/to/custom.yaml --model-name gpt2

EOF
}

generate_trainjob() {
    local template_file="$SCRIPT_DIR/templates/generic-trainjob.yaml"
    local output_file="$SCRIPT_DIR/generated-trainjob-${DATASET_NAME}-${EXECUTION_ID}.yaml"

    log "Generating TrainJob from template..."

    # Read template and substitute variables
    cat "$template_file" | \
    sed "s/\${DATASET_NAME}/$DATASET_NAME/g" | \
    sed "s/\${EXECUTION_ID}/$EXECUTION_ID/g" | \
    sed "s/\${NAMESPACE}/$NAMESPACE/g" | \
    sed "s/\${MODEL_NAME}/$MODEL_NAME/g" | \
    sed "s/\${MAX_SAMPLES}/$MAX_SAMPLES/g" | \
    sed "s/\${BATCH_SIZE}/$BATCH_SIZE/g" | \
    sed "s/\${MAX_LENGTH}/$MAX_LENGTH/g" | \
    sed "s/\${EPOCHS}/$EPOCHS/g" | \
    sed "s/\${LEARNING_RATE}/$LEARNING_RATE/g" | \
    sed "s/\${TEXT_COLUMN}/$TEXT_COLUMN/g" | \
    sed "s/\${ARROW_CACHE_HEAD_HOST}/$ARROW_CACHE_HEAD_HOST/g" | \
    sed "s/\${ARROW_CACHE_HEAD_PORT}/$ARROW_CACHE_HEAD_PORT/g" | \
    sed "s/\${AWS_REGION}/$AWS_REGION/g" | \
    sed "s/\${CPU_REQUEST}/$CPU_REQUEST/g" | \
    sed "s/\${MEMORY_REQUEST}/$MEMORY_REQUEST/g" | \
    sed "s/\${CPU_LIMIT}/$CPU_LIMIT/g" | \
    sed "s/\${MEMORY_LIMIT}/$MEMORY_LIMIT/g" | \
    sed "s/\${SERVICE_ACCOUNT}/$SERVICE_ACCOUNT/g" | \
    sed "s/\${CONFIGMAP_NAME}/$CONFIGMAP_NAME/g" | \
    sed "s/\${DRY_RUN_FLAG}/$DRY_RUN_FLAG/g" | \
    sed "s/\${SKIP_CHECKPOINT_FLAG}/$SKIP_CHECKPOINT_FLAG/g" | \
    sed "s/\${USE_IRSA_FLAG}/$USE_IRSA_FLAG/g" | \
    sed "s/\${USE_ARROW_CACHE_FLAG}/$USE_ARROW_CACHE_FLAG/g" | \
    sed "s/\${IN_CLUSTER_FLAG}/$IN_CLUSTER_FLAG/g" \
    > "$output_file"

    echo "$output_file"
}

create_configmap() {
    log "Creating ConfigMap with training scripts..."

    # Create ConfigMap with generic training script and dataset config
    kubectl create configmap "$CONFIGMAP_NAME" \
        --from-file="$SCRIPT_DIR/generic_training.py" \
        --from-file="$SCRIPT_DIR/../lib/arrow_cache_client.py" \
        --from-file="$SCRIPT_DIR/../lib/__init__.py" \
        --from-file="configs=$(basename "$DATASET_CONFIG")" \
        -n "$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -

    success "ConfigMap '$CONFIGMAP_NAME' created/updated"
}

deploy_trainjob() {
    local trainjob_file="$1"

    log "Deploying TrainJob..."
    kubectl apply -f "$trainjob_file"

    local job_name="${DATASET_NAME}-training-${EXECUTION_ID}"
    success "TrainJob '$job_name' deployed successfully"

    echo
    echo "📊 Monitoring Commands:"
    echo "  # Watch TrainJob status:"
    echo "  kubectl get trainjobs -n $NAMESPACE -w"
    echo
    echo "  # View training logs:"
    echo "  kubectl logs -f -n $NAMESPACE job/$job_name-node-0"
    echo
    echo "  # Check pod status:"
    echo "  kubectl get pods -n $NAMESPACE -l jobset.sigs.k8s.io/jobset-name=$job_name"
    echo
}

main() {
    # Default values
    local DATASET_NAME=""
    local DATASET_CONFIG=""
    local EXECUTION_ID=$(date +%Y%m%d-%H%M%S)
    local NAMESPACE="arrow-cache-demo"
    local MODEL_NAME="distilgpt2"
    local MAX_SAMPLES="50"
    local BATCH_SIZE="1"
    local MAX_LENGTH="128"
    local EPOCHS="1"
    local LEARNING_RATE="5e-5"
    local TEXT_COLUMN="text"
    local CPU_REQUEST="500m"
    local MEMORY_REQUEST="1Gi"
    local CPU_LIMIT="1"
    local MEMORY_LIMIT="2Gi"
    local SERVICE_ACCOUNT="aws-service-account"
    local CONFIGMAP_NAME="generic-training-script"
    local ARROW_CACHE_HEAD_HOST="arrow-cache-head-svc.arrow-cache-demo.svc.cluster.local"
    local ARROW_CACHE_HEAD_PORT="50051"
    local AWS_REGION="us-east-1"

    # Flags
    local DRY_RUN_FLAG=""
    local SKIP_CHECKPOINT_FLAG="--skip-checkpoint"
    local USE_IRSA_FLAG=""
    local USE_ARROW_CACHE_FLAG=""
    local IN_CLUSTER_FLAG=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dataset-name)
                DATASET_NAME="$2"
                shift 2
                ;;
            --dataset-config)
                DATASET_CONFIG="$2"
                shift 2
                ;;
            --execution-id)
                EXECUTION_ID="$2"
                shift 2
                ;;
            --namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --model-name)
                MODEL_NAME="$2"
                shift 2
                ;;
            --max-samples)
                MAX_SAMPLES="$2"
                shift 2
                ;;
            --batch-size)
                BATCH_SIZE="$2"
                shift 2
                ;;
            --max-length)
                MAX_LENGTH="$2"
                shift 2
                ;;
            --epochs)
                EPOCHS="$2"
                shift 2
                ;;
            --learning-rate)
                LEARNING_RATE="$2"
                shift 2
                ;;
            --text-column)
                TEXT_COLUMN="$2"
                shift 2
                ;;
            --cpu-request)
                CPU_REQUEST="$2"
                shift 2
                ;;
            --memory-request)
                MEMORY_REQUEST="$2"
                shift 2
                ;;
            --cpu-limit)
                CPU_LIMIT="$2"
                shift 2
                ;;
            --memory-limit)
                MEMORY_LIMIT="$2"
                shift 2
                ;;
            --service-account)
                SERVICE_ACCOUNT="$2"
                shift 2
                ;;
            --configmap-name)
                CONFIGMAP_NAME="$2"
                shift 2
                ;;
            --arrow-cache-host)
                ARROW_CACHE_HEAD_HOST="$2"
                shift 2
                ;;
            --arrow-cache-port)
                ARROW_CACHE_HEAD_PORT="$2"
                shift 2
                ;;
            --aws-region)
                AWS_REGION="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN_FLAG="--dry-run"
                shift
                ;;
            --skip-checkpoint)
                SKIP_CHECKPOINT_FLAG="--skip-checkpoint"
                shift
                ;;
            --use-irsa)
                USE_IRSA_FLAG="--use-irsa"
                shift
                ;;
            --use-arrow-cache)
                USE_ARROW_CACHE_FLAG="--use-arrow-cache"
                shift
                ;;
            --in-cluster)
                IN_CLUSTER_FLAG="--in-cluster"
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

    # Validate required arguments
    if [ -z "$DATASET_NAME" ] || [ -z "$DATASET_CONFIG" ]; then
        error "Missing required arguments. Use --help for usage information."
    fi

    # Validate dataset config file exists
    if [ ! -f "$DATASET_CONFIG" ]; then
        error "Dataset config file not found: $DATASET_CONFIG"
    fi

    log "Generic Dataset Training Setup"
    echo "=================================="
    log "Dataset: $DATASET_NAME"
    log "Config: $DATASET_CONFIG"
    log "Execution ID: $EXECUTION_ID"
    log "Namespace: $NAMESPACE"
    log "Model: $MODEL_NAME"
    echo

    # Export variables for template substitution
    export DATASET_NAME EXECUTION_ID NAMESPACE MODEL_NAME MAX_SAMPLES BATCH_SIZE
    export MAX_LENGTH EPOCHS LEARNING_RATE TEXT_COLUMN
    export ARROW_CACHE_HEAD_HOST ARROW_CACHE_HEAD_PORT AWS_REGION
    export CPU_REQUEST MEMORY_REQUEST CPU_LIMIT MEMORY_LIMIT
    export SERVICE_ACCOUNT CONFIGMAP_NAME
    export DRY_RUN_FLAG SKIP_CHECKPOINT_FLAG USE_IRSA_FLAG USE_ARROW_CACHE_FLAG IN_CLUSTER_FLAG

    # Create ConfigMap
    create_configmap

    # Generate and deploy TrainJob
    local trainjob_file
    trainjob_file=$(generate_trainjob)

    deploy_trainjob "$trainjob_file"

    success "Generic training setup completed successfully!"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
