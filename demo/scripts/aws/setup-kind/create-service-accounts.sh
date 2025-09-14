#!/bin/bash

# Create Service Accounts for All Arrow Cache Namespaces
# This script creates service accounts with IAM role annotations in all Arrow Cache namespaces

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME=${CLUSTER_NAME:-"arrow-cache-demo"}
ROLE_ARN=""
SERVICE_ACCOUNT="aws-service-account"
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
Create Service Accounts for All Arrow Cache Namespaces

This script creates service accounts with IAM role annotations in all Arrow Cache namespaces.
It supports the following namespaces:
  - arrow-cache (regular demo)
  - arrow-cache-imdb (IMDB demo)
  - arrow-cache-demo (Alpaca demo)

Usage: $0 [OPTIONS]

Options:
  --cluster-name NAME   Name of the kind cluster (default: arrow-cache-demo)
  --role-arn ARN        IAM role ARN to annotate service accounts with (required)
  --service-account SA  Service account name (default: aws-service-account)
  --help               Show this help message

Examples:
  # Create service accounts with specific IAM role
  $0 --role-arn arn:aws:iam::120832439621:role/ArrowCacheRole

  # Use custom service account name
  $0 --role-arn arn:aws:iam::120832439621:role/ArrowCacheRole --service-account my-sa

EOF
}

check_prerequisites() {
    log "Checking prerequisites..."

    # Check if kubectl is installed
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is not installed. Please install it from https://kubernetes.io/docs/tasks/tools/"
    fi

    # Check if cluster is accessible
    if ! kubectl cluster-info &> /dev/null; then
        error "Cannot access Kubernetes cluster. Please check your kubeconfig."
    fi

    # Verify we're connected to the right cluster
    local current_context
    current_context=$(kubectl config current-context)
    if [[ ! "$current_context" =~ kind-${CLUSTER_NAME} ]]; then
        warn "Current context '$current_context' doesn't match expected cluster 'kind-$CLUSTER_NAME'"
        warn "Continuing anyway, but please verify you're connected to the correct cluster."
    fi

    success "Prerequisites check completed."
}

create_service_account_in_namespace() {
    local namespace="$1"

    log "Creating service account in namespace: $namespace"

    # Create namespace if it doesn't exist
    kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -

    # Create service account with IAM role annotation
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SERVICE_ACCOUNT
  namespace: $namespace
  annotations:
    eks.amazonaws.com/role-arn: "$ROLE_ARN"
EOF

    success "Created service account: $namespace/$SERVICE_ACCOUNT"
}

verify_service_accounts() {
    log "Verifying service accounts..."

    local namespaces=("arrow-cache" "arrow-cache-imdb" "arrow-cache-demo")

    echo
    echo "=== Service Account Summary ==="
    for namespace in "${namespaces[@]}"; do
        if kubectl get namespace "$namespace" &>/dev/null; then
            if kubectl get serviceaccount "$SERVICE_ACCOUNT" -n "$namespace" &>/dev/null; then
                local role_arn_annotation
                role_arn_annotation=$(kubectl get serviceaccount "$SERVICE_ACCOUNT" -n "$namespace" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")

                if [[ -n "$role_arn_annotation" ]]; then
                    echo "  ✅ $namespace/$SERVICE_ACCOUNT"
                    echo "     Role: $role_arn_annotation"
                else
                    echo "  ❌ $namespace/$SERVICE_ACCOUNT (missing role annotation)"
                fi
            else
                echo "  ❌ $namespace/$SERVICE_ACCOUNT (not found)"
            fi
        else
            echo "  ➖ $namespace (namespace not found)"
        fi
    done
    echo
}

show_usage_info() {
    echo
    success "Service accounts created successfully!"
    echo
    echo "📋 Configuration:"
    echo "  IAM Role ARN: $ROLE_ARN"
    echo "  Service Account: $SERVICE_ACCOUNT"
    echo "  Cluster: $CLUSTER_NAME"
    echo
    echo "🚀 Usage in Arrow Cache demos:"
    echo
    echo "  # Regular demo"
    echo "  cd ../regular/"
    echo "  ./setup-arrow-cache.sh --iam-role $ROLE_ARN"
    echo
    echo "  # IMDB demo"
    echo "  cd ../imdb/"
    echo "  ./setup-imdb-arrow-cache.sh --iam-role $ROLE_ARN"
    echo
    echo "  # Alpaca demo"
    echo "  cd ../alpaca/"
    echo "  ./setup-alpaca-arrow-cache.sh --iam-role $ROLE_ARN"
    echo
    echo "🔍 Verification:"
    echo "  # Check service accounts"
    echo "  kubectl get serviceaccount $SERVICE_ACCOUNT -n arrow-cache -o yaml"
    echo "  kubectl get serviceaccount $SERVICE_ACCOUNT -n arrow-cache-imdb -o yaml"
    echo "  kubectl get serviceaccount $SERVICE_ACCOUNT -n arrow-cache-demo -o yaml"
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
            --role-arn)
                ROLE_ARN="$2"
                shift 2
                ;;
            --service-account)
                SERVICE_ACCOUNT="$2"
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

    # Validate required arguments
    if [[ -z "$ROLE_ARN" ]]; then
        error "Missing required argument: --role-arn. Use --help for usage information."
    fi

    log "Creating service accounts for Arrow Cache namespaces"
    echo "================================================="
    log "Cluster: $CLUSTER_NAME"
    log "Role ARN: $ROLE_ARN"
    log "Service Account: $SERVICE_ACCOUNT"
    echo

    # Check prerequisites
    check_prerequisites

    # Define namespaces for different datasets
    local namespaces=("arrow-cache" "arrow-cache-imdb" "arrow-cache-demo")

    # Create service accounts in all namespaces
    for namespace in "${namespaces[@]}"; do
        create_service_account_in_namespace "$namespace"
    done

    # Verify service accounts
    verify_service_accounts

    # Show usage information
    show_usage_info
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
