#!/bin/bash
set -euo pipefail

# Create IAM Role for IRSA Service Account
# This script creates an IAM role that can be assumed by a specific Kubernetes service account

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/functions.sh"

# Default values
CLUSTER_CONFIG=""
ROLE_NAME=""
NAMESPACE=""
SERVICE_ACCOUNT=""
POLICY_ARNS=()
CUSTOM_POLICIES=()
SKIP_K8S_CREATION=false
USE_WILDCARD=false

show_help() {
    cat <<EOF
Create IAM Role for IRSA Service Account

This script creates an IAM role that can be assumed by a specific Kubernetes service account
in an IRSA-enabled kind cluster.

Usage: $0 [OPTIONS]

Options:
  --cluster-config FILE    Path to cluster configuration file (required)
  --role-name NAME         Name of the IAM role to create (required)
  --namespace NAME         Kubernetes namespace (required)
  --service-account NAME   Kubernetes service account name (required)
  --policy-arn ARN         AWS managed policy ARN to attach (can be used multiple times)
  --custom-policy FILE     Path to custom policy JSON file (can be used multiple times)
  --skip-k8s-creation     Skip Kubernetes service account creation (only create IAM role)
  --use-wildcard          Use wildcard pattern for namespace matching (e.g., arrow-cache*)
  --help                  Show this help message

Examples:
  # Create role with S3 full access
  $0 \\
    --cluster-config cluster-info-myapp.env \\
    --role-name MyAppS3Role \\
    --namespace myapp \\
    --service-account aws-service-account \\
    --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

  # Create role with multiple managed policies
  $0 \\
    --cluster-config cluster-info-myapp.env \\
    --role-name MyAppRole \\
    --namespace myapp \\
    --service-account my-sa \\
    --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \\
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess

  # Create role with custom policy
  $0 \\
    --cluster-config cluster-info-myapp.env \\
    --role-name MyAppRole \\
    --namespace myapp \\
    --service-account my-sa \\
    --custom-policy /path/to/custom-policy.json

EOF
}

create_iam_role() {
    log "Creating IAM role: $ROLE_NAME"

    # Check if role already exists
    if role_exists "$ROLE_NAME"; then
        warn "IAM role $ROLE_NAME already exists"
        read -p "Do you want to delete and recreate it? (y/N): " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "Deleting existing role..."
            # Detach all attached policies first
            local attached_policies
            attached_policies=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true)
            for policy_arn in $attached_policies; do
                aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$policy_arn"
            done

            # Delete inline policies
            local inline_policies
            inline_policies=$(aws iam list-role-policies --role-name "$ROLE_NAME" --query 'PolicyNames' --output text 2>/dev/null || true)
            for policy_name in $inline_policies; do
                aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$policy_name"
            done

            aws iam delete-role --role-name "$ROLE_NAME"
        else
            log "Using existing role: $ROLE_NAME"
            return 0
        fi
    fi

    # Create trust policy
    local trust_policy_file="/tmp/irsa-trust-policy.json"
    create_oidc_trust_policy "$PROVIDER_ARN" "$ISSUER_HOSTPATH" "$NAMESPACE" "$SERVICE_ACCOUNT" "$trust_policy_file" "$USE_WILDCARD"

    # Create the IAM role
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "file://$trust_policy_file" \
        --description "IRSA role for $NAMESPACE/$SERVICE_ACCOUNT in $CLUSTER_NAME"

    success "IAM role created: $ROLE_NAME"
}

attach_policies() {
    if [ ${#POLICY_ARNS[@]} -eq 0 ] && [ ${#CUSTOM_POLICIES[@]} -eq 0 ]; then
        warn "No policies specified. Role will have no permissions."
        return 0
    fi

    # Attach managed policies
    for policy_arn in "${POLICY_ARNS[@]}"; do
        log "Attaching managed policy: $policy_arn"
        aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$policy_arn"
    done

    # Attach custom policies
    for i in "${!CUSTOM_POLICIES[@]}"; do
        local policy_file="${CUSTOM_POLICIES[$i]}"
        local policy_name="${ROLE_NAME}-custom-policy-$((i+1))"

        if [ ! -f "$policy_file" ]; then
            error "Custom policy file not found: $policy_file"
            continue
        fi

        log "Attaching custom policy: $policy_name"
        aws iam put-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-name "$policy_name" \
            --policy-document "file://$policy_file"
    done

    success "Policies attached to role: $ROLE_NAME"
}

create_service_account() {
    if [[ "$SKIP_K8S_CREATION" == true ]]; then
        log "Skipping Kubernetes service account creation as requested"
        return 0
    fi

    log "Creating Kubernetes service account: $NAMESPACE/$SERVICE_ACCOUNT"

    # Create namespace if it doesn't exist
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    # Get the role ARN
    local role_arn
    role_arn=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

    # Create service account with IAM role annotation
    kubectl create serviceaccount "$SERVICE_ACCOUNT" -n "$NAMESPACE" --dry-run=client -o yaml | \
    kubectl annotate --local -f - "eks.amazonaws.com/role-arn=$role_arn" -o yaml | \
    kubectl apply -f -

    success "Service account created with IAM role annotation: $role_arn"
}

show_usage_info() {
    local role_arn
    role_arn=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

    echo
    success "IRSA setup completed successfully!"
    echo
    echo "📋 Configuration:"
    echo "  IAM Role: $ROLE_NAME"
    echo "  Role ARN: $role_arn"
    echo "  Namespace: $NAMESPACE"
    echo "  Service Account: $SERVICE_ACCOUNT"
    echo "  Cluster: $CLUSTER_NAME"
    echo
    echo "🚀 Usage in your applications:"
    echo
    echo "1. Use the IAM role in your Arrow Cache demos:"
    echo "   ./setup-imdb-arrow-cache.sh --iam-role $role_arn"
    echo "   ./setup-arrow-cache.sh --s3-path s3://bucket/data --iam-role $role_arn"
    echo
    echo "2. Or reference it in your Kubernetes manifests:"
    echo "   apiVersion: v1"
    echo "   kind: Pod"
    echo "   spec:"
    echo "     serviceAccountName: $SERVICE_ACCOUNT"
    echo "     # Pod will automatically assume the IAM role"
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
            --role-name)
                ROLE_NAME="$2"
                shift 2
                ;;
            --namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --service-account)
                SERVICE_ACCOUNT="$2"
                shift 2
                ;;
            --policy-arn)
                POLICY_ARNS+=("$2")
                shift 2
                ;;
            --custom-policy)
                CUSTOM_POLICIES+=("$2")
                shift 2
                ;;
            --skip-k8s-creation)
                SKIP_K8S_CREATION=true
                shift
                ;;
            --use-wildcard)
                USE_WILDCARD=true
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
    if [ -z "$CLUSTER_CONFIG" ] || [ -z "$ROLE_NAME" ] || [ -z "$NAMESPACE" ] || [ -z "$SERVICE_ACCOUNT" ]; then
        error "Missing required arguments. Use --help for usage information."
        exit 1
    fi

    # Validate and load cluster configuration
    if ! validate_cluster_config "$CLUSTER_CONFIG"; then
        exit 1
    fi
    source "$CLUSTER_CONFIG"

    log "Creating IRSA role for service account"
    echo "====================================="
    log "Cluster: $CLUSTER_NAME"
    log "Role: $ROLE_NAME"
    log "Service Account: $NAMESPACE/$SERVICE_ACCOUNT"
    echo

    # Execute creation steps
    validate_aws_access
    create_iam_role
    attach_policies
    create_service_account
    show_usage_info
}

# Clean up temporary files on exit
trap cleanup_temp_files EXIT

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
