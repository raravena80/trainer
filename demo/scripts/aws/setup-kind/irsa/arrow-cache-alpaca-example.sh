#!/bin/bash
set -euo pipefail

# Arrow Cache Alpaca IRSA Integration Example
# This script demonstrates how to set up an IRSA-enabled kind cluster and run Alpaca Arrow Cache demos with IAM roles

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/functions.sh"

# Configuration
CLUSTER_NAME="arrow-cache-alpaca-demo"
ROLE_NAME="ArrowCacheAlpacaRole"

show_help() {
    cat <<EOF
Arrow Cache Alpaca IRSA Integration Example

This script demonstrates the complete workflow for using IAM roles with Alpaca Arrow Cache demos:
1. Creates an IRSA-enabled kind cluster
2. Creates an IAM role with S3 and Glue permissions
3. Runs the Alpaca Arrow Cache demo with the IAM role

Usage: $0 [OPTIONS]

Options:
  --cluster-name NAME   Name of the kind cluster (default: arrow-cache-alpaca-demo)
  --role-name NAME      Name of the IAM role (default: ArrowCacheAlpacaRole)
  --help               Show this help message

Examples:
  # Run Alpaca demo with IRSA
  $0

  # Custom cluster and role names
  $0 --cluster-name my-alpaca-cluster --role-name MyAlpacaRole

EOF
}

setup_irsa_cluster() {
    log "Setting up IRSA-enabled kind cluster..."

    "$SCRIPT_DIR/setup-irsa-kind.sh" --cluster-name "$CLUSTER_NAME"

    success "IRSA cluster setup completed"
}

create_alpaca_role() {
    log "Creating IAM role for Alpaca Arrow Cache..."

    "$SCRIPT_DIR/create-irsa-role.sh" \
        --cluster-config "$SCRIPT_DIR/cluster-info-$CLUSTER_NAME.env" \
        --role-name "$ROLE_NAME" \
        --namespace "arrow-cache-demo" \
        --service-account "aws-service-account" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonS3FullAccess" \
        --policy-arn "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"

    success "IAM role created successfully with S3 and Glue permissions"
}

run_alpaca_demo() {
    log "Running Alpaca Arrow Cache demo with IAM role..."

    # Get role ARN
    local role_arn
    role_arn=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

    # Change to the alpaca demo directory
    cd "$SCRIPT_DIR/../../alpaca"
    log "Running Alpaca demo..."
    ./setup-alpaca-arrow-cache.sh --iam-role "$role_arn"

    success "Alpaca demo setup completed with IAM role!"
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
    success "🎉 Alpaca Arrow Cache IRSA demo is ready!"
    echo
    echo "📋 What was created:"
    echo "  - IRSA-enabled kind cluster: $CLUSTER_NAME"
    echo "  - IAM role: $ROLE_NAME ($role_arn)"
    echo "  - Arrow Cache demo running with IAM role"
    echo "  - Permissions: S3 Full Access + AWS Glue Service Role"
    echo
    echo "🚀 Next steps:"
    echo
    echo "1. Run the training script:"
    echo "   cd ../../alpaca"
    echo "   python3 alpaca_training.py --use-irsa --use-arrow-cache --dry-run  # Test first"
    echo "   python3 alpaca_training.py --use-irsa --use-arrow-cache            # Real training"
    echo
    echo "2. Or use the TrainJob:"
    echo "   kubectl apply -f alpaca-trainjob-real.yaml"
    echo
    echo "3. Monitor the pods:"
    echo "   kubectl get pods -n arrow-cache-demo"
    echo "   kubectl logs -f -n arrow-cache-demo deployment/arrow-cache-head"
    echo
    echo "4. Monitor training job:"
    echo "   kubectl get trainjobs -n arrow-cache-demo"
    echo "   kubectl logs -f -n arrow-cache-demo job/<trainjob-name>"
    echo
    echo "5. When done, clean up:"
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
            --help)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done

    print_section "Arrow Cache Alpaca IRSA Integration Example"
    log "Cluster: $CLUSTER_NAME"
    log "Role: $ROLE_NAME"
    log "Demo Type: Alpaca (Instruction Following)"
    echo

    # Check prerequisites
    check_required_tools kubectl aws jq go kind openssl
    validate_aws_access

    # Execute setup steps
    setup_irsa_cluster
    create_alpaca_role
    test_irsa_setup
    run_alpaca_demo
    show_next_steps
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
