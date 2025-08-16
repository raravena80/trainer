#!/bin/bash
set -euo pipefail

# IRSA (IAM Roles for Service Accounts) Setup for Kind Clusters
# This script creates a kind cluster with IRSA support, similar to Amazon EKS

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
CLUSTER_NAME="irsa-demo"
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_PROFILE=""
SUFFIX="$(date +%Y%m%d-%H%M%S)"
SLEEP_TIME=30
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared functions
source "$SCRIPT_DIR/lib/functions.sh"

show_help() {
    cat <<EOF
IRSA Setup for Kind Clusters

This script creates a kind cluster with IRSA (IAM Roles for Service Accounts) support,
allowing you to use AWS IAM roles with Kubernetes service accounts in local development.

Usage: $0 [OPTIONS]

Options:
  --cluster-name NAME   Name of the kind cluster (default: irsa-demo)
  --aws-region REGION   AWS region to use (default: us-east-1)
  --aws-profile PROFILE AWS profile to use (optional)
  --suffix SUFFIX       Unique suffix for AWS resources (default: timestamp)
  --sleep-time SECONDS  Wait time between operations (default: 30)
  --debug              Enable debug output
  --help               Show this help message

Examples:
  # Create default IRSA cluster
  $0

  # Create cluster with custom name and region
  $0 --cluster-name arrow-cache-demo --aws-region us-west-2

  # Use custom suffix for resource naming
  $0 --suffix my-test-1

EOF
}

check_prerequisites() {
    log "Checking prerequisites..."

    local missing_tools=()

    for tool in kubectl aws jq go kind openssl curl; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        error "Missing required tools: ${missing_tools[*]}"
        log "Please install the missing tools and try again."
        exit 1
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        error "AWS credentials not configured or invalid"
        log "Please run 'aws configure' or set up your AWS credentials."
        exit 1
    fi

    success "All prerequisites are met."
}

setup_s3_oidc_discovery() {
    log "Setting up S3-based OIDC discovery endpoint..."

    # Create S3 bucket for OIDC discovery
    export DISCOVERY_BUCKET="irsa-oidc-discovery-$SUFFIX"
    log "Creating S3 bucket: $DISCOVERY_BUCKET"

    if [ "$AWS_REGION" = "us-east-1" ]; then
        aws s3api create-bucket --bucket "$DISCOVERY_BUCKET" --region "$AWS_REGION"
    else
        aws s3api create-bucket \
            --bucket "$DISCOVERY_BUCKET" \
            --region "$AWS_REGION" \
            --create-bucket-configuration "LocationConstraint=$AWS_REGION"
    fi

    # Configure bucket for public read access (required for OIDC discovery)
    aws s3api put-public-access-block \
        --bucket "$DISCOVERY_BUCKET" \
        --public-access-block-configuration \
        "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

    # Set bucket policy for public read access
    # Use virtual-hosted style URL (modern S3 format)
    export HOSTNAME="$DISCOVERY_BUCKET.s3.$AWS_REGION.amazonaws.com"
    export ISSUER_HOSTPATH="$HOSTNAME"

    envsubst < "$SCRIPT_DIR/templates/aws/s3-readonly-policy.template.json" > "/tmp/s3-readonly-policy.json"
    aws s3api put-bucket-policy --bucket "$DISCOVERY_BUCKET" --policy file:///tmp/s3-readonly-policy.json

    success "S3 OIDC discovery bucket created: $DISCOVERY_BUCKET"
}

generate_oidc_keys() {
    log "Generating OIDC signing keys..."

    # Create keys directory
    mkdir -p "$SCRIPT_DIR/keys"

    # Generate RSA key pair
    local priv_key="$SCRIPT_DIR/keys/oidc-issuer.key"
    local pub_key="$SCRIPT_DIR/keys/oidc-issuer.key.pub"
    local pkcs_key="$SCRIPT_DIR/keys/oidc-issuer.pub"

    ssh-keygen -t rsa -b 2048 -f "$priv_key" -m pem -N ""
    ssh-keygen -e -m PKCS8 -f "$pub_key" > "$pkcs_key"

    # Generate JWKS
    log "Generating JWKS (JSON Web Key Set)..."
    go run "$SCRIPT_DIR/keys-generator/main.go" -key "$pkcs_key" | jq > "/tmp/keys.json"

    success "OIDC keys generated successfully"
}

upload_oidc_config() {
    log "Uploading OIDC configuration to S3..."

    # Generate discovery document
    export ISSUER_URL="https://$ISSUER_HOSTPATH"
    envsubst < "$SCRIPT_DIR/templates/aws/discovery.template.json" > "/tmp/discovery.json"

    # Upload to S3
    aws s3 cp "/tmp/discovery.json" "s3://$DISCOVERY_BUCKET/.well-known/openid-configuration"
    aws s3 cp "/tmp/keys.json" "s3://$DISCOVERY_BUCKET/keys.json"

    log "OIDC issuer URL: $ISSUER_URL"
    success "OIDC configuration uploaded to S3"
}

create_oidc_provider() {
    log "Creating AWS OIDC identity provider..."

    # Get account ID first
    export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    export PROVIDER_ARN="arn:aws:iam::$ACCOUNT_ID:oidc-provider/$ISSUER_HOSTPATH"

    # Check if provider already exists
    if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" &>/dev/null; then
        warn "OIDC provider already exists: $PROVIDER_ARN"
        return 0
    fi

    # Verify OIDC discovery endpoint is accessible
    log "Verifying OIDC discovery endpoint is accessible..."
    if ! curl -s "https://$ISSUER_HOSTPATH/.well-known/openid-configuration" >/dev/null; then
        error "OIDC discovery endpoint is not accessible: https://$ISSUER_HOSTPATH/.well-known/openid-configuration"
        log "Please check that the S3 bucket and files were uploaded correctly."
        return 1
    fi

    # Get certificate thumbprint for S3
    log "Getting SSL certificate thumbprint for S3..."
    local ca_thumbprint
    ca_thumbprint=$(openssl s_client -connect "$HOSTNAME:443" \
        -servername "$HOSTNAME" -showcerts </dev/null 2>/dev/null | \
        openssl x509 -in /dev/stdin -sha1 -noout -fingerprint | \
        cut -d '=' -f 2 | tr -d ':')

    if [ -z "$ca_thumbprint" ]; then
        error "Failed to get SSL certificate thumbprint"
        return 1
    fi

    log "Certificate thumbprint: $ca_thumbprint"

    # Create OIDC provider
    log "Creating OIDC provider with URL: https://$ISSUER_HOSTPATH"
    if aws iam create-open-id-connect-provider \
        --url "https://$ISSUER_HOSTPATH" \
        --thumbprint-list "$ca_thumbprint" \
        --client-id-list sts.amazonaws.com; then
        success "OIDC provider created: $PROVIDER_ARN"
    else
        error "Failed to create OIDC provider"
        return 1
    fi
}

create_kind_cluster() {
    log "Creating kind cluster with IRSA configuration..."

    # Delete existing cluster if it exists
    if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        warn "Deleting existing cluster: $CLUSTER_NAME"
        kind delete cluster --name "$CLUSTER_NAME"
    fi

    # Generate kind config with OIDC issuer settings
    export KEYS_PATH="$SCRIPT_DIR/keys"
    envsubst < "$SCRIPT_DIR/templates/kind/irsa-config.template.yaml" > "/tmp/kind-irsa-config.yaml"

    # Create cluster
    kind create cluster --config "/tmp/kind-irsa-config.yaml" --name "$CLUSTER_NAME"

    success "Kind cluster created: $CLUSTER_NAME"
}

install_cert_manager() {
    log "Installing cert-manager..."

    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.6/cert-manager.yaml

    log "Waiting for cert-manager to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager -n cert-manager
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-webhook -n cert-manager
    kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-cainjector -n cert-manager

    success "cert-manager installed and ready"
}

install_pod_identity_webhook() {
    log "Installing AWS Pod Identity Webhook..."

    # Create namespace for pod identity webhook
    kubectl create namespace pod-identity-webhook --dry-run=client -o yaml | kubectl apply -f -

    # Copy webhook manifests to temp directory with substitutions
    local webhook_dir="/tmp/pod-identity-webhook"
    mkdir -p "$webhook_dir"

    cp -r "$SCRIPT_DIR/pod-identity-webhook/"* "$webhook_dir/"

    # Apply webhook components
    kubectl apply -f "$webhook_dir/auth.yaml"
    kubectl apply -f "$webhook_dir/service.yaml"
    kubectl apply -f "$webhook_dir/cert.yaml"
    kubectl apply -f "$webhook_dir/mutatingwebhook-ca-bundle.yaml"

    log "Waiting for certificate to be ready..."
    sleep "$SLEEP_TIME"

    kubectl apply -f "$webhook_dir/deployment.yaml"

    log "Waiting for pod identity webhook to be ready..."
    # The webhook is deployed in the pod-identity-webhook namespace
    kubectl wait --for=condition=available --timeout=300s deployment/pod-identity-webhook -n pod-identity-webhook

    success "Pod Identity Webhook installed and ready"
}

save_cluster_info() {
    log "Saving cluster configuration..."

    cat > "$SCRIPT_DIR/cluster-info-$CLUSTER_NAME.env" <<EOF
# IRSA Cluster Configuration for $CLUSTER_NAME
# Generated on $(date)

export CLUSTER_NAME="$CLUSTER_NAME"
export AWS_REGION="$AWS_REGION"
export DISCOVERY_BUCKET="$DISCOVERY_BUCKET"
export ISSUER_URL="https://$ISSUER_HOSTPATH"
export ISSUER_HOSTPATH="$ISSUER_HOSTPATH"
export PROVIDER_ARN="$PROVIDER_ARN"
export ACCOUNT_ID="$ACCOUNT_ID"
export SUFFIX="$SUFFIX"

# To create IAM roles for this cluster:
# ./create-irsa-role.sh --cluster-config cluster-info-$CLUSTER_NAME.env --role-name MyRole --namespace default --service-account my-sa

# To clean up this cluster:
# ./cleanup-irsa.sh --cluster-config cluster-info-$CLUSTER_NAME.env
EOF

    success "Cluster configuration saved to: cluster-info-$CLUSTER_NAME.env"
}

show_success_info() {
    echo
    success "IRSA-enabled kind cluster is ready!"
    echo
    echo "📋 Cluster Information:"
    echo "  Cluster Name: $CLUSTER_NAME"
    echo "  AWS Region: $AWS_REGION"
    echo "  OIDC Issuer: https://$ISSUER_HOSTPATH"
    echo "  Provider ARN: $PROVIDER_ARN"
    echo
    echo "🚀 Next Steps:"
    echo
    echo "1. Create IAM roles for your service accounts:"
    echo "   ./create-irsa-role.sh \\"
    echo "     --cluster-config cluster-info-$CLUSTER_NAME.env \\"
    echo "     --role-name ArrowCacheRole \\"
    echo "     --namespace arrow-cache-imdb \\"
    echo "     --service-account aws-service-account \\"
    echo "     --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess"
    echo
    echo "2. Use IAM roles in your Arrow Cache demos:"
    echo "   ./setup-imdb-arrow-cache.sh --iam-role arn:aws:iam::$ACCOUNT_ID:role/ArrowCacheRole"
    echo
    echo "3. When done, clean up AWS resources:"
    echo "   ./cleanup-irsa.sh --cluster-config cluster-info-$CLUSTER_NAME.env"
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

    log "Starting IRSA setup for kind cluster"
    echo "===================================="
    log "Cluster: $CLUSTER_NAME"
    log "Region: $AWS_REGION"
    log "Suffix: $SUFFIX"
    echo

    # Unset AWS pager for non-interactive use
    export AWS_PAGER=""

    # Set AWS profile if specified
    if [ -n "$AWS_PROFILE" ]; then
        export AWS_PROFILE="$AWS_PROFILE"
        log "Using AWS profile: $AWS_PROFILE"
    fi

    # Execute setup steps
    check_prerequisites
    setup_s3_oidc_discovery
    generate_oidc_keys
    upload_oidc_config
    create_oidc_provider
    create_kind_cluster
    install_cert_manager
    install_pod_identity_webhook
    save_cluster_info

    show_success_info
}

# Handle cleanup on script exit
cleanup_temp_files() {
    rm -f /tmp/s3-readonly-policy.json /tmp/discovery.json /tmp/keys.json /tmp/kind-irsa-config.yaml
    rm -rf /tmp/pod-identity-webhook
}
trap cleanup_temp_files EXIT

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
