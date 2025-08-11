#!/bin/bash

# Upload Demo Data to S3 and Configure Arrow Cache
#
# Usage:
#   export AWS_ACCESS_KEY_ID="your-key"
#   export AWS_SECRET_ACCESS_KEY="your-secret"
#   export AWS_DEFAULT_REGION="us-west-2"  # optional, defaults to us-west-2
#   ./demo/scripts/upload-demo-to-s3.sh s3://your-bucket/path/demo-data /tmp/s3-demo-data

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
Upload Demo Data to S3 and Configure Arrow Cache

This script uploads locally generated demo data to S3 and configures
Arrow Cache to use the S3 metadata location.

Prerequisites:
  - Set AWS credentials as environment variables:
    export AWS_ACCESS_KEY_ID="your-access-key"
    export AWS_SECRET_ACCESS_KEY="your-secret-key"
    export AWS_DEFAULT_REGION="us-west-2"  # optional

Usage: $0 <s3-path> [local-data-path]

Arguments:
  s3-path           S3 URL where to upload data (e.g., s3://my-bucket/demo-data)
  local-data-path   Local directory with demo data (default: /tmp/s3-demo-data)

Examples:
  # Upload to S3 and configure Arrow Cache
  $0 s3://my-bucket/arrow-cache-demo

  # Upload specific local data
  $0 s3://my-bucket/demo /tmp/my-demo-data

What this script does:
  1. Validates AWS credentials and S3 access
  2. Uploads local demo data files to S3
  3. Updates Arrow Cache configuration to use S3 metadata location
  4. Restarts Arrow Cache head node to apply changes
  5. Shows verification steps

EOF
}

check_prerequisites() {
    log "Checking prerequisites..."

    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        error "AWS CLI is required but not installed. Install with: brew install awscli"
    fi

    # Check for AWS credentials
    if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
        error "AWS_ACCESS_KEY_ID environment variable is required"
    fi

    if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        error "AWS_SECRET_ACCESS_KEY environment variable is required"
    fi

    # Set default region if not provided
    if [[ -z "${AWS_DEFAULT_REGION:-}" ]]; then
        export AWS_DEFAULT_REGION="us-west-2"
        log "Using default region: $AWS_DEFAULT_REGION"
    fi

    # Test AWS credentials
    log "Testing AWS credentials..."
    if ! aws sts get-caller-identity > /dev/null 2>&1; then
        error "AWS credentials are invalid or AWS is not accessible"
    fi

    success "AWS credentials are valid"
}

upload_data_to_s3() {
    local s3_path="$1"
    local local_path="$2"

    log "Uploading demo data to S3..."
    log "  Source: $local_path"
    log "  Destination: $s3_path"

    # Validate local path exists
    if [[ ! -d "$local_path" ]]; then
        error "Local data path does not exist: $local_path"
    fi

    # Check for expected structure
    if [[ ! -d "$local_path/data" ]] || [[ ! -d "$local_path/metadata" ]]; then
        error "Local path missing expected 'data' or 'metadata' directories"
    fi

    # Extract bucket from S3 path for validation
    bucket=$(echo "$s3_path" | sed 's|s3://||' | cut -d'/' -f1)
    log "Checking S3 bucket access: $bucket"

    # Test bucket access
    if ! aws s3 ls "s3://$bucket/" > /dev/null 2>&1; then
        error "Cannot access S3 bucket: $bucket. Check permissions and bucket exists."
    fi

    # Upload data files
    log "Uploading data files..."
    aws s3 sync "$local_path/data/" "$s3_path/data/" \
        --storage-class STANDARD \
        --no-progress

    # Upload metadata files
    log "Uploading metadata files..."
    aws s3 sync "$local_path/metadata/" "$s3_path/metadata/" \
        --storage-class STANDARD \
        --no-progress

    # Verify upload
    log "Verifying upload..."
    local file_count=$(aws s3 ls "$s3_path/" --recursive | wc -l | tr -d ' ')
    log "Uploaded $file_count files to S3"

    success "Data uploaded successfully to S3"
}

configure_arrow_cache() {
    local metadata_s3_path="$1"

    log "Configuring Arrow Cache to use S3 metadata..."

    # Check kubectl access
    if ! kubectl get namespaces &> /dev/null; then
        error "Cannot access Kubernetes cluster. Make sure kubectl is configured."
    fi

    # Check if arrow-cache namespace exists
    if ! kubectl get namespace arrow-cache &> /dev/null; then
        error "arrow-cache namespace not found. Deploy Arrow Cache first."
    fi

    # Update configmap
    local full_metadata_path="$metadata_s3_path/metadata/table.metadata.json"
    log "Setting METADATA_LOC to: $full_metadata_path"

    kubectl patch configmap arrow-cache-config -n arrow-cache \
        --patch "{\"data\":{\"METADATA_LOC\":\"$full_metadata_path\",\"TABLE_NAME\":\"demo_events\",\"SCHEMA_NAME\":\"demo\"}}"

    if [[ $? -ne 0 ]]; then
        error "Failed to update Arrow Cache configuration"
    fi

    # Restart head deployment
    log "Restarting Arrow Cache head node..."
    kubectl rollout restart deployment/arrow-cache-head -n arrow-cache

    # Wait for rollout
    kubectl rollout status deployment/arrow-cache-head -n arrow-cache --timeout=120s

    success "Arrow Cache configured to use S3 data"
}

show_completion_status() {
    local s3_path="$1"
    local metadata_path="$s3_path/metadata/table.metadata.json"

    log "Upload and configuration completed!"

    cat <<EOF

🎉 Demo Data Successfully Uploaded to S3!

✅ What was uploaded:
  - S3 Location: $s3_path
  - Data Files: $s3_path/data/
  - Metadata: $metadata_path
  - Arrow Cache configured to use S3 metadata

📊 Configuration Applied:
  - METADATA_LOC: $metadata_path
  - TABLE_NAME: demo_events
  - SCHEMA_NAME: demo

🔍 Verification Steps:

1. Check S3 contents:
   aws s3 ls $s3_path --recursive

2. Verify Arrow Cache config:
   kubectl get configmap arrow-cache-config -n arrow-cache -o yaml

3. Check Arrow Cache pods:
   kubectl get pods -n arrow-cache

4. View head node logs:
   kubectl logs -n arrow-cache deployment/arrow-cache-head -f

5. Test the configuration:
   python3 demo/scripts/demo-arrow-cache-client.py --demo

🚀 Next Steps:
  - The Arrow Cache system is now configured to use your S3 data
  - Data will persist even if the Kubernetes cluster is recreated
  - Scale workers as needed: kubectl scale statefulset arrow-cache-worker --replicas=N -n arrow-cache

EOF
}

main() {
    # Parse arguments
    if [[ $# -lt 1 ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
        show_help
        exit 0
    fi

    local s3_path="$1"
    local local_path="${2:-/tmp/s3-demo-data}"

    # Validate S3 path format
    if [[ ! "$s3_path" =~ ^s3:// ]]; then
        error "S3 path must start with s3:// (got: $s3_path)"
    fi

    log "Arrow Cache S3 Demo Data Upload"
    echo "================================="
    log "S3 Destination: $s3_path"
    log "Local Source: $local_path"
    log "AWS Region: ${AWS_DEFAULT_REGION:-us-west-2}"
    echo

    # Execute steps
    check_prerequisites
    upload_data_to_s3 "$s3_path" "$local_path"
    configure_arrow_cache "$s3_path"
    show_completion_status "$s3_path"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
