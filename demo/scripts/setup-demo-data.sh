#!/bin/bash

# Arrow Cache Demo Data Setup Script
# Generates sample data and configures the Arrow Cache system to use it

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DEFAULT_RECORDS=25000
DEFAULT_FILES=6
DEFAULT_OUTPUT="/tmp/arrow-cache-demo-data"
NAMESPACE="arrow-cache"

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
Arrow Cache Demo Data Setup

This script generates sample Iceberg data and configures Arrow Cache to use it.
Perfect for demos and testing without requiring external S3 dependencies.

Usage: $0 [OPTIONS]

Options:
  -r, --records NUM     Number of records to generate (default: $DEFAULT_RECORDS)
  -f, --files NUM       Number of data files to create (default: $DEFAULT_FILES)
  -o, --output PATH     Output directory (default: $DEFAULT_OUTPUT)
  -s, --s3-path URL     Use S3 path instead of local (requires AWS credentials)
  -h, --help           Show this help message

Examples:
  # Generate demo data locally
  $0

  # Generate larger dataset
  $0 --records 100000 --files 10

  # Generate data in S3
  $0 --s3-path s3://my-bucket/demo-data --records 50000

  # Custom local path
  $0 --output /tmp/my-demo-data --records 5000

What this script does:
  1. Generates realistic sample data (events, users, purchases, etc.)
  2. Creates proper Iceberg metadata structure
  3. Updates Arrow Cache configuration to use the generated data
  4. Restarts the head node to pick up new configuration
  5. Shows status and next steps

EOF
}

check_prerequisites() {
    log "Checking prerequisites..."

    # Check Python and required packages
    if ! command -v python3 &> /dev/null; then
        error "python3 is required but not installed"
    fi

    # Check if we can import required packages
    if ! /opt/miniconda3/envs/arrow-cache-demo/bin/python -c "import pandas, pyarrow" 2>/dev/null; then
        error "Required Python packages not installed. Run: conda activate arrow-cache-demo"
    fi

    # Check if kubectl is available and cluster is accessible
    if ! kubectl get namespaces &>/dev/null; then
        error "Cannot access Kubernetes cluster. Make sure kubectl is configured and the arrow-cache cluster is running."
    fi

    # Check if arrow-cache namespace exists
    if ! kubectl get namespace arrow-cache &>/dev/null; then
        error "arrow-cache namespace not found. Run the main setup script first: ./demo/scripts/setup-arrow-cache-kind.sh"
    fi

    success "All prerequisites are met"
}

generate_demo_data() {
    local output_path="$1"
    local records="$2"
    local files="$3"

    log "Generating demo data with $records records in $files files..."

    # Run the data generator
    /opt/miniconda3/envs/arrow-cache-demo/bin/python demo/scripts/generate-demo-data.py \
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

    # Restart the head deployment to pick up new configuration
    log "Restarting head node to apply new configuration..."
    kubectl rollout restart deployment/arrow-cache-head -n "$NAMESPACE"

    # Wait for rollout to complete
    kubectl rollout status deployment/arrow-cache-head -n "$NAMESPACE" --timeout=120s

    success "Arrow Cache configured and restarted"
}

show_demo_status() {
    local metadata_path="$1"

    log "Demo setup completed successfully!"

    cat <<EOF

🎉 Arrow Cache Demo Data Setup Complete!

✅ What was created:
  - Sample Iceberg table with realistic event data
  - Multiple Parquet data files for distributed processing
  - Proper Iceberg metadata structure
  - Arrow Cache configuration updated

📊 Data Details:
  - Metadata location: $metadata_path
  - Table name: demo_events
  - Schema name: demo
  - Data types: events, users, purchases, timestamps, etc.

🚀 Next Steps:

1. Check that everything is running:
   ./demo/scripts/demo-arrow-cache-status.sh

2. Wait for head node to be ready:
   kubectl get pods -n arrow-cache -w

3. Test with the demo client:
   python3 demo/scripts/demo-arrow-cache-client.py --demo

4. Try port forwarding and manual testing:
   kubectl port-forward -n arrow-cache service/arrow-cache-head-svc 50051:50051

5. Scale workers for larger demo:
   kubectl scale statefulset arrow-cache-worker --replicas=4 -n arrow-cache

📝 Demo Talking Points:
  - Distributed Arrow caching with head-worker architecture
  - Iceberg metadata integration for modern data lakes
  - Apache Arrow Flight protocol for high-performance data transport
  - Kubernetes-native deployment with service discovery
  - Horizontal scaling of cache workers
  - Real-time query performance across distributed data

🔍 Monitoring:
  - Head node logs: kubectl logs -n arrow-cache deployment/arrow-cache-head -f
  - Worker logs: kubectl logs -n arrow-cache arrow-cache-worker-0 -f
  - All pods: kubectl get pods -n arrow-cache

EOF

    if [[ "$metadata_path" == file://* ]] || [[ "$metadata_path" != s3://* ]]; then
        warn "Using local filesystem - data will be lost when cluster is deleted"
        echo "   For persistent demo data, consider using S3 with: $0 --s3-path s3://your-bucket/demo"
    fi
}

main() {
    # Parse arguments
    RECORDS="$DEFAULT_RECORDS"
    FILES="$DEFAULT_FILES"
    OUTPUT="$DEFAULT_OUTPUT"
    S3_PATH=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -r|--records)
                RECORDS="$2"
                shift 2
                ;;
            -f|--files)
                FILES="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT="$2"
                shift 2
                ;;
            -s|--s3-path)
                S3_PATH="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done

    # Use S3 path if provided
    if [[ -n "$S3_PATH" ]]; then
        OUTPUT="$S3_PATH"
        log "Using S3 path: $OUTPUT"
    else
        log "Using local path: $OUTPUT"
    fi

    # Validate arguments
    if [[ "$RECORDS" -le 0 ]]; then
        error "Number of records must be positive"
    fi

    if [[ "$FILES" -le 0 ]]; then
        error "Number of files must be positive"
    fi

    if [[ "$RECORDS" -lt "$FILES" ]]; then
        error "Number of records must be >= number of files"
    fi

    log "Arrow Cache Demo Data Setup"
    echo "============================"
    log "Records: $RECORDS"
    log "Files: $FILES"
    log "Output: $OUTPUT"
    echo

    # Run setup steps
    check_prerequisites
    generate_demo_data "$OUTPUT" "$RECORDS" "$FILES"

    # Construct metadata path
    if [[ "$OUTPUT" == s3://* ]]; then
        METADATA_PATH="$OUTPUT/metadata/table.metadata.json"
    else
        METADATA_PATH="file://$OUTPUT/metadata/table.metadata.json"
    fi

    configure_arrow_cache "$METADATA_PATH"
    show_demo_status "$METADATA_PATH"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
