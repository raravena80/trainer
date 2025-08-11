#!/bin/bash

# AWS Credentials Setup Script for Arrow Cache Demo
# This script helps set up AWS credentials for accessing S3/Iceberg data

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

setup_aws_credentials() {
    log "Setting up AWS credentials for Arrow Cache demo..."

    echo
    echo "You can get your AWS credentials in several ways:"
    echo "1. From AWS CLI: aws configure list"
    echo "2. From AWS Console: IAM -> Users -> [Your User] -> Security credentials"
    echo "3. From environment variables: echo \$AWS_ACCESS_KEY_ID"
    echo

    # Get current AWS credentials if available
    CURRENT_KEY_ID=$(aws configure get aws_access_key_id 2>/dev/null || echo "")
    CURRENT_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

    if [[ -n "$CURRENT_KEY_ID" ]]; then
        log "Found existing AWS configuration:"
        echo "  Access Key ID: ${CURRENT_KEY_ID:0:4}****${CURRENT_KEY_ID: -4}"
        echo "  Region: $CURRENT_REGION"
        echo
        read -p "Use existing AWS configuration? (y/n): " use_existing
        if [[ "$use_existing" =~ ^[Yy]$ ]]; then
            ACCESS_KEY_ID="$CURRENT_KEY_ID"
            SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key 2>/dev/null || "")
            SESSION_TOKEN=$(aws configure get aws_session_token 2>/dev/null || "")
            REGION="$CURRENT_REGION"
        else
            read_aws_credentials
        fi
    else
        warn "No existing AWS configuration found."
        read_aws_credentials
    fi

    # Update the Kubernetes secret
    log "Creating/updating AWS credentials secret..."

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

    # Update region in configmap
    kubectl patch configmap arrow-cache-config -n arrow-cache \
        --patch '{"data":{"AWS_REGION":"'$REGION'"}}'

    success "AWS credentials configured successfully!"

    # Restart head deployment to pick up new credentials
    log "Restarting head deployment to apply new credentials..."
    kubectl rollout restart deployment/arrow-cache-head -n arrow-cache

    success "Setup complete! The head node will restart with new AWS credentials."
}

read_aws_credentials() {
    echo
    read -p "Enter your AWS Access Key ID: " ACCESS_KEY_ID
    read -s -p "Enter your AWS Secret Access Key: " SECRET_ACCESS_KEY
    echo
    read -p "Enter your AWS Region (default: us-east-1): " REGION
    REGION=${REGION:-us-east-1}

    # Optional session token for temporary credentials
    echo
    read -p "Enter AWS Session Token (optional, press enter to skip): " SESSION_TOKEN
}

validate_credentials() {
    log "Validating AWS credentials..."

    # Test credentials by listing S3 buckets
    if AWS_ACCESS_KEY_ID="$ACCESS_KEY_ID" \
       AWS_SECRET_ACCESS_KEY="$SECRET_ACCESS_KEY" \
       AWS_REGION="$REGION" \
       ${SESSION_TOKEN:+AWS_SESSION_TOKEN="$SESSION_TOKEN"} \
       aws sts get-caller-identity &>/dev/null; then
        success "AWS credentials are valid!"
        return 0
    else
        error "AWS credentials validation failed. Please check your credentials."
    fi
}

show_demo_info() {
    log "AWS Setup Complete!"

    cat <<EOF

=== Next Steps ===

1. Your AWS credentials have been configured in the arrow-cache namespace
2. The head node deployment is restarting to pick up the new credentials
3. Make sure your S3 data is accessible with these credentials

=== Checking Status ===

Watch the head pod restart:
  kubectl get pods -n arrow-cache -w

Check head node logs:
  kubectl logs -n arrow-cache deployment/arrow-cache-head -f

=== Demo Data Setup ===

If you don't have Iceberg data yet, you can:
1. Use the demo data generator (coming soon)
2. Point to an existing Iceberg table in S3
3. Use a local file:// path for testing

=== Troubleshooting ===

If you see AWS errors:
- Check that your credentials have S3 read permissions
- Verify the bucket and region are correct
- Ensure your Iceberg metadata location is accessible

EOF
}

main() {
    log "Arrow Cache AWS Credentials Setup"
    echo "=================================="

    # Check if kubectl is available and cluster is accessible
    if ! kubectl get namespaces &>/dev/null; then
        error "Cannot access Kubernetes cluster. Make sure kubectl is configured and the arrow-cache cluster is running."
    fi

    # Check if arrow-cache namespace exists
    if ! kubectl get namespace arrow-cache &>/dev/null; then
        error "arrow-cache namespace not found. Run the main setup script first."
    fi

    setup_aws_credentials

    if [[ -n "$ACCESS_KEY_ID" && -n "$SECRET_ACCESS_KEY" ]]; then
        validate_credentials
    fi

    show_demo_info
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
