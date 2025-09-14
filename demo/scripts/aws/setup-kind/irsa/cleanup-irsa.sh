#!/bin/bash
set -euo pipefail

# Cleanup IRSA Resources
# This script removes AWS resources created for IRSA kind clusters

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/functions.sh"

# Configuration
CLUSTER_CONFIG=""
FORCE=false
DELETE_CLUSTER=false

show_help() {
    cat <<EOF
Cleanup IRSA Resources

This script removes AWS resources created for IRSA kind clusters including:
- S3 OIDC discovery bucket
- IAM OIDC identity provider
- Optionally: IAM roles and kind cluster

Usage: $0 [OPTIONS]

Options:
  --cluster-config FILE    Path to cluster configuration file (required)
  --delete-cluster        Also delete the kind cluster
  --force                 Skip confirmation prompts
  --help                 Show this help message

Examples:
  # Clean up AWS resources only
  $0 --cluster-config cluster-info-myapp.env

  # Clean up everything including the kind cluster
  $0 --cluster-config cluster-info-myapp.env --delete-cluster

  # Force cleanup without prompts
  $0 --cluster-config cluster-info-myapp.env --force

EOF
}

list_resources_to_delete() {
    echo "📋 Resources that will be deleted:"
    echo
    echo "AWS Resources:"
    echo "  - S3 Bucket: $DISCOVERY_BUCKET"
    echo "  - OIDC Provider: $PROVIDER_ARN"
    echo

    # List IAM roles that use this OIDC provider
    log "Checking for IAM roles that use this OIDC provider..."
    local roles_found=false

    # Get all roles and check their trust policies
    local roles
    roles=$(aws iam list-roles --query 'Roles[].RoleName' --output text 2>/dev/null || true)

    echo "IAM Roles using this OIDC provider:"
    for role in $roles; do
        if aws iam get-role --role-name "$role" --output json 2>/dev/null | \
           grep -q "$ISSUER_HOSTPATH" 2>/dev/null; then
            echo "  - Role: $role"
            roles_found=true
        fi
    done

    if [ "$roles_found" = false ]; then
        echo "  - No IAM roles found using this OIDC provider"
    else
        echo
        warn "Note: IAM roles will NOT be automatically deleted."
        warn "Delete them manually if no longer needed:"
        echo "  aws iam delete-role --role-name ROLE_NAME"
    fi

    if [ "$DELETE_CLUSTER" = true ]; then
        echo
        echo "Kind Cluster:"
        echo "  - Cluster: $CLUSTER_NAME"
    fi
    echo
}

delete_s3_bucket() {
    log "Deleting S3 bucket: $DISCOVERY_BUCKET"

    if ! bucket_exists "$DISCOVERY_BUCKET"; then
        warn "S3 bucket $DISCOVERY_BUCKET does not exist"
        return 0
    fi

    # Remove all objects from bucket first
    aws s3 rm "s3://$DISCOVERY_BUCKET" --recursive --quiet 2>/dev/null || true

    # Delete the bucket
    aws s3api delete-bucket --bucket "$DISCOVERY_BUCKET" --region "$AWS_REGION"

    success "S3 bucket deleted: $DISCOVERY_BUCKET"
}

delete_oidc_provider() {
    log "Deleting OIDC identity provider: $PROVIDER_ARN"

    if ! oidc_provider_exists "$PROVIDER_ARN"; then
        warn "OIDC provider $PROVIDER_ARN does not exist"
        return 0
    fi

    aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN"

    success "OIDC provider deleted: $PROVIDER_ARN"
}

delete_kind_cluster() {
    if [ "$DELETE_CLUSTER" = false ]; then
        return 0
    fi

    log "Deleting kind cluster: $CLUSTER_NAME"

    if ! cluster_exists "$CLUSTER_NAME"; then
        warn "Kind cluster $CLUSTER_NAME does not exist"
        return 0
    fi

    kind delete cluster --name "$CLUSTER_NAME"

    success "Kind cluster deleted: $CLUSTER_NAME"
}

cleanup_local_files() {
    log "Cleaning up local files..."

    # Remove keys directory
    if [ -d "$SCRIPT_DIR/keys" ]; then
        rm -rf "$SCRIPT_DIR/keys"
        log "Removed keys directory"
    fi

    # Remove cluster config file
    local config_file="$SCRIPT_DIR/cluster-info-$CLUSTER_NAME.env"
    if [ -f "$config_file" ]; then
        rm -f "$config_file"
        log "Removed cluster configuration: $config_file"
    fi

    success "Local files cleaned up"
}

confirm_deletion() {
    if [ "$FORCE" = true ]; then
        return 0
    fi

    echo
    warn "This action will permanently delete AWS resources and cannot be undone!"
    echo
    read -p "Are you sure you want to continue? (type 'yes' to confirm): " -r

    if [ "$REPLY" != "yes" ]; then
        log "Cleanup cancelled by user"
        exit 0
    fi
}

show_completion_info() {
    echo
    success "Cleanup completed successfully!"
    echo
    echo "📋 Summary:"
    echo "  - S3 bucket deleted: $DISCOVERY_BUCKET"
    echo "  - OIDC provider deleted: $PROVIDER_ARN"

    if [ "$DELETE_CLUSTER" = true ]; then
        echo "  - Kind cluster deleted: $CLUSTER_NAME"
    fi

    echo
    echo "💡 Manual cleanup reminders:"
    echo "  - Review and delete any IAM roles that used this OIDC provider"
    echo "  - Check for any remaining AWS resources with suffix: $SUFFIX"

    if [ "$DELETE_CLUSTER" = false ]; then
        echo "  - Delete the kind cluster: kind delete cluster --name $CLUSTER_NAME"
    fi
    echo
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cluster-config)
                CLUSTER_CONFIG="$2"
                shift 2
                ;;
            --delete-cluster)
                DELETE_CLUSTER=true
                shift
                ;;
            --force)
                FORCE=true
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
    if [ -z "$CLUSTER_CONFIG" ]; then
        error "Missing required argument: --cluster-config. Use --help for usage information."
        exit 1
    fi

    # Validate and load cluster configuration
    if ! validate_cluster_config "$CLUSTER_CONFIG"; then
        exit 1
    fi
    source "$CLUSTER_CONFIG"

    log "IRSA cleanup for cluster: $CLUSTER_NAME"
    echo "================================="
    echo

    # Show what will be deleted
    list_resources_to_delete

    # Confirm deletion
    confirm_deletion

    # Execute cleanup steps
    log "Starting cleanup process..."

    validate_aws_access
    delete_s3_bucket
    delete_oidc_provider
    delete_kind_cluster
    cleanup_local_files

    show_completion_info
}

# Clean up temporary files on exit
trap cleanup_temp_files EXIT

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
