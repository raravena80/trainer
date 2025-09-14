#!/bin/bash
set -euo pipefail

# Arrow Cache IRSA Integration Example
# This script demonstrates how to set up an IRSA-enabled kind cluster and run Arrow Cache demos with IAM roles

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/functions.sh"

# Configuration
CLUSTER_NAME="arrow-cache-irsa-demo"
ROLE_NAME="ArrowCacheS3Role"
DEMO_TYPE="imdb"  # or "regular"

show_help() {
    cat <<EOF
Arrow Cache IRSA Integration Example

This script demonstrates the complete workflow for using IAM roles with Arrow Cache demos:
1. Creates an IRSA-enabled kind cluster
2. Creates an IAM role with S3 permissions
3. Runs the Arrow Cache demo with the IAM role

Usage: $0 [OPTIONS]

Options:
  --cluster-name NAME   Name of the kind cluster (default: arrow-cache-irsa-demo)
  --role-name NAME      Name of the IAM role (default: ArrowCacheS3Role)
  --demo-type TYPE      Demo type: 'imdb' or 'regular' (default: imdb)
  --help               Show this help message

Examples:
  # Run IMDB demo with IRSA
  $0

  # Run regular demo with IRSA
  $0 --demo-type regular

  # Custom cluster and role names
  $0 --cluster-name my-cluster --role-name MyRole --demo-type imdb

EOF
}

setup_irsa_cluster() {
    log "Setting up IRSA-enabled kind cluster..."

    "$SCRIPT_DIR/setup-irsa-kind.sh" --cluster-name "$CLUSTER_NAME"

    success "IRSA cluster setup completed"
}

create_arrow_cache_role() {
    log "Creating IAM role for Arrow Cache..."

    local namespace
    if [ "$DEMO_TYPE" = "imdb" ]; then
        namespace="arrow-cache-imdb"
    else
        namespace="arrow-cache"
    fi

    "$SCRIPT_DIR/create-irsa-role.sh" \
        --cluster-config "$SCRIPT_DIR/cluster-info-$CLUSTER_NAME.env" \
        --role-name "$ROLE_NAME" \
        --namespace "$namespace" \
        --service-account "aws-service-account" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonS3FullAccess" \
        --policy-arn "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"

    success "IAM role created successfully"
}

run_demo() {
    log "Running Arrow Cache demo with IAM role..."

    # Get role ARN
    local role_arn
    role_arn=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

    # Change to the appropriate demo directory
    if [ "$DEMO_TYPE" = "imdb" ]; then
        cd "$SCRIPT_DIR/../../imdb"
        log "Running IMDB demo..."
        ./setup-imdb-arrow-cache.sh --iam-role "$role_arn"
    else
        cd "$SCRIPT_DIR/../../regular"
        log "Running regular demo with S3..."
        echo
        warn "Note: Regular demo requires an S3 path. Please provide one:"
        read -p "Enter S3 path (e.g., s3://my-bucket/demo-data): " s3_path

        if [ -z "$s3_path" ]; then
            error "S3 path is required for regular demo"
            exit 1
        fi

        ./setup-arrow-cache.sh --s3-path "$s3_path" --iam-role "$role_arn"
    fi

    success "Demo setup completed with IAM role!"
}

test_irsa_setup() {
    log "Testing IRSA functionality..."

    local role_arn
    role_arn=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

    "$SCRIPT_DIR/test-irsa.sh" \
        --cluster-config "$SCRIPT_DIR/cluster-info-$CLUSTER_NAME.env" \
        --role-arn "$role_arn"
}

show_next_steps() {
    local role_arn
    role_arn=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

    echo
    success "🎉 Arrow Cache IRSA demo is ready!"
    echo
    echo "📋 What was created:"
    echo "  - IRSA-enabled kind cluster: $CLUSTER_NAME"
    echo "  - IAM role: $ROLE_NAME ($role_arn)"
    echo "  - Arrow Cache demo running with IAM role"
    echo
    echo "🚀 Next steps:"
    echo
    echo "1. Test the demo client:"
    if [ "$DEMO_TYPE" = "imdb" ]; then
        echo "   cd ../../imdb && python3 demo-client.py --demo"
    else
        echo "   cd ../../regular && python3 demo-client.py --demo"
    fi
    echo
    echo "2. Monitor the pods:"
    if [ "$DEMO_TYPE" = "imdb" ]; then
        echo "   kubectl get pods -n arrow-cache-imdb"
        echo "   kubectl logs -f -n arrow-cache-imdb deployment/arrow-cache-head"
    else
        echo "   kubectl get pods -n arrow-cache"
        echo "   kubectl logs -f -n arrow-cache deployment/arrow-cache-head"
    fi
    echo
    echo "3. When done, clean up:"
    echo "   $SCRIPT_DIR/cleanup-irsa.sh --cluster-config $SCRIPT_DIR/cluster-info-$CLUSTER_NAME.env --delete-cluster"
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
            --role-name)
                ROLE_NAME="$2"
                shift 2
                ;;
            --demo-type)
                DEMO_TYPE="$2"
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

    # Validate demo type
    if [ "$DEMO_TYPE" != "imdb" ] && [ "$DEMO_TYPE" != "regular" ]; then
        error "Invalid demo type: $DEMO_TYPE. Must be 'imdb' or 'regular'."
        exit 1
    fi

    print_section "Arrow Cache IRSA Integration Example"
    log "Cluster: $CLUSTER_NAME"
    log "Role: $ROLE_NAME"
    log "Demo Type: $DEMO_TYPE"
    echo

    # Check prerequisites
    check_required_tools kubectl aws jq go kind openssl
    validate_aws_access

    # Execute setup steps
    setup_irsa_cluster
    create_arrow_cache_role
    test_irsa_setup
    run_demo
    show_next_steps
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
