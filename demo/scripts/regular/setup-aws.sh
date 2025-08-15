#!/bin/bash

# AWS Setup Helper for Arrow Cache Demo
# Simplified script to configure AWS credentials and S3 access

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
AWS Setup Helper for Arrow Cache Demo

This script helps configure AWS credentials for S3 access in the Arrow Cache demo.
It can use existing AWS CLI configuration or prompt for new credentials.

Usage: $0 [OPTIONS]

Options:
  --from-env        Use credentials from environment variables
  --from-cli        Use existing AWS CLI configuration
  --interactive     Prompt for credentials interactively
  --test-only       Only test existing credentials
  --help            Show this help message

Examples:
  # Use existing AWS CLI config
  $0 --from-cli

  # Use environment variables
  export AWS_ACCESS_KEY_ID="..."
  export AWS_SECRET_ACCESS_KEY="..."
  $0 --from-env

  # Interactive setup
  $0 --interactive

EOF
}

load_from_env() {
    log "Loading AWS credentials from environment variables..."

    if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]] || [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        error "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be set"
    fi

    ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
    SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
    SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"
    REGION="${AWS_DEFAULT_REGION:-us-east-1}"

    success "Loaded credentials from environment"
}

load_from_cli() {
    log "Loading AWS credentials from CLI configuration..."

    if ! command -v aws &> /dev/null; then
        error "AWS CLI is not installed"
    fi

    ACCESS_KEY_ID=$(aws configure get aws_access_key_id 2>/dev/null || echo "")
    SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key 2>/dev/null || echo "")
    SESSION_TOKEN=$(aws configure get aws_session_token 2>/dev/null || echo "")
    REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

    if [[ -z "$ACCESS_KEY_ID" ]] || [[ -z "$SECRET_ACCESS_KEY" ]]; then
        error "No valid AWS CLI configuration found. Run 'aws configure' first."
    fi

    success "Loaded credentials from AWS CLI"
}

load_interactive() {
    log "Interactive AWS credentials setup..."
    echo

    read -p "Enter your AWS Access Key ID: " ACCESS_KEY_ID
    read -s -p "Enter your AWS Secret Access Key: " SECRET_ACCESS_KEY
    echo
    read -p "Enter your AWS Region (default: us-east-1): " REGION
    REGION=${REGION:-us-east-1}

    echo
    read -p "Enter AWS Session Token (optional, press enter to skip): " SESSION_TOKEN

    if [[ -z "$ACCESS_KEY_ID" ]] || [[ -z "$SECRET_ACCESS_KEY" ]]; then
        error "Access Key ID and Secret Access Key are required"
    fi

    success "Credentials entered interactively"
}

test_credentials() {
    log "Testing AWS credentials..."

    # Test credentials by calling STS
    if AWS_ACCESS_KEY_ID="$ACCESS_KEY_ID" \
       AWS_SECRET_ACCESS_KEY="$SECRET_ACCESS_KEY" \
       AWS_REGION="$REGION" \
       ${SESSION_TOKEN:+AWS_SESSION_TOKEN="$SESSION_TOKEN"} \
       aws sts get-caller-identity &> /dev/null; then
        success "AWS credentials are valid!"
        return 0
    else
        error "AWS credentials validation failed. Please check your credentials."
    fi
}

configure_kubernetes() {
    log "Configuring Kubernetes with AWS credentials..."

    # Check if kubectl is available
    if ! kubectl get namespaces &> /dev/null; then
        error "Cannot access Kubernetes cluster. Make sure kubectl is configured."
    fi

    # Check if arrow-cache namespace exists
    if ! kubectl get namespace arrow-cache &> /dev/null; then
        error "arrow-cache namespace not found. Deploy Arrow Cache first."
    fi

    # Create temporary secret file
    cat > /tmp/aws-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: aws-credentials
  namespace: arrow-cache
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "$ACCESS_KEY_ID"
  AWS_SECRET_ACCESS_KEY: "$SECRET_ACCESS_KEY"
$(if [[ -n "$SESSION_TOKEN" ]]; then echo "  AWS_SESSION_TOKEN: \"$SESSION_TOKEN\""; fi)
EOF

    # Apply the secret
    kubectl apply -f /tmp/aws-secret.yaml
    rm /tmp/aws-secret.yaml

    # Update region in configmap if it exists
    if kubectl get configmap arrow-cache-config -n arrow-cache &> /dev/null; then
        kubectl patch configmap arrow-cache-config -n arrow-cache \
            --patch '{"data":{"AWS_REGION":"'$REGION'"}}'
    fi

    success "AWS credentials configured in Kubernetes"
}

restart_head_node() {
    log "Restarting head node to apply new credentials..."

    if kubectl get deployment arrow-cache-head -n arrow-cache &> /dev/null; then
        kubectl rollout restart deployment/arrow-cache-head -n arrow-cache

        # Wait for rollout
        kubectl rollout status deployment/arrow-cache-head -n arrow-cache --timeout=120s

        success "Head node restarted successfully"
    else
        warn "No head node deployment found to restart"
    fi
}

show_completion() {
    cat <<EOF

🎉 AWS Setup Complete!

✅ Configured:
  - AWS credentials in Kubernetes secret
  - Region: $REGION
  - Head node restarted (if deployed)

📋 Next Steps:
  1. Verify pods are running: kubectl get pods -n arrow-cache
  2. Check head node logs: kubectl logs -n arrow-cache deployment/arrow-cache-head -f
  3. Run demo with S3 data: ./demo/scripts/setup-demo.sh --s3-path s3://your-bucket/demo

🔍 Troubleshooting:
  - If you see AWS errors, verify bucket permissions
  - Ensure your credentials have S3 read/write access
  - Check the bucket region matches your configured region

EOF
}

main() {
    local method=""
    local test_only=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --from-env)
                method="env"
                shift
                ;;
            --from-cli)
                method="cli"
                shift
                ;;
            --interactive)
                method="interactive"
                shift
                ;;
            --test-only)
                test_only=true
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

    # Default to CLI method if no method specified
    if [[ -z "$method" ]]; then
        method="cli"
    fi

    log "AWS Setup for Arrow Cache Demo"
    echo "=============================="

    # Load credentials based on method
    case "$method" in
        "env")
            load_from_env
            ;;
        "cli")
            load_from_cli
            ;;
        "interactive")
            load_interactive
            ;;
        *)
            error "Invalid method: $method"
            ;;
    esac

    # Test credentials
    test_credentials

    # If test-only, exit here
    if [[ "$test_only" == true ]]; then
        success "AWS credentials test completed successfully"
        exit 0
    fi

    # Configure Kubernetes
    configure_kubernetes

    # Restart head node
    restart_head_node

    # Show completion message
    show_completion
}

# Global variables for credentials
ACCESS_KEY_ID=""
SECRET_ACCESS_KEY=""
SESSION_TOKEN=""
REGION=""

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
