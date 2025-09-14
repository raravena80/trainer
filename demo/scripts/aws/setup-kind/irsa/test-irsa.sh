#!/bin/bash
set -euo pipefail

# Test IRSA Setup
# This script creates a simple test pod to verify IRSA functionality

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/functions.sh"

CLUSTER_CONFIG=""
ROLE_ARN=""
NAMESPACE="default"
SERVICE_ACCOUNT="test-irsa-sa"
TEST_BUCKET=""

show_help() {
    cat <<EOF
Test IRSA Setup

This script creates a test pod to verify that IRSA is working correctly.
The test pod will attempt to list S3 buckets using the IAM role.

Usage: $0 [OPTIONS]

Options:
  --cluster-config FILE    Path to cluster configuration file (required)
  --role-arn ARN          IAM role ARN to test (required)
  --namespace NAME        Kubernetes namespace (default: default)
  --service-account NAME  Service account name (default: test-irsa-sa)
  --test-bucket NAME      S3 bucket name to test access (optional)
  --help                 Show this help message

Examples:
  # Basic test - list S3 buckets
  $0 \\
    --cluster-config cluster-info-myapp.env \\
    --role-arn arn:aws:iam::123456789:role/MyTestRole

  # Test specific bucket access
  $0 \\
    --cluster-config cluster-info-myapp.env \\
    --role-arn arn:aws:iam::123456789:role/MyS3Role \\
    --test-bucket my-test-bucket

EOF
}

create_test_service_account() {
    log "Creating test service account: $NAMESPACE/$SERVICE_ACCOUNT"

    # Create namespace if it doesn't exist
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    # Create service account with IAM role annotation
    kubectl create serviceaccount "$SERVICE_ACCOUNT" -n "$NAMESPACE" --dry-run=client -o yaml | \
    kubectl annotate --local -f - "eks.amazonaws.com/role-arn=$ROLE_ARN" -o yaml | \
    kubectl apply -f -

    success "Test service account created"
}

run_test_pod() {
    log "Creating test pod to verify IRSA functionality..."

    local test_commands="echo 'Testing IRSA functionality...'; "
    test_commands+="echo 'AWS CLI version:'; aws --version; "
    test_commands+="echo; echo 'Current AWS identity:'; aws sts get-caller-identity; "
    test_commands+="echo; echo 'Listing S3 buckets:'; aws s3 ls; "

    if [ -n "$TEST_BUCKET" ]; then
        test_commands+="echo; echo 'Testing access to bucket: $TEST_BUCKET'; aws s3 ls s3://$TEST_BUCKET/ || echo 'Bucket access test failed'; "
    fi

    # Create test pod
    kubectl run irsa-test \
        --image=amazon/aws-cli:latest \
        --restart=Never \
        --rm -i \
        --overrides='{"spec":{"serviceAccountName":"'$SERVICE_ACCOUNT'"}}' \
        --namespace="$NAMESPACE" \
        --command -- sh -c "$test_commands"

    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        success "IRSA test completed successfully!"
        echo
        echo "✅ Your IRSA setup is working correctly!"
        echo "   Pods using service account '$SERVICE_ACCOUNT' can assume IAM role:"
        echo "   $ROLE_ARN"
    else
        error "IRSA test failed!"
        echo
        echo "❌ Possible issues:"
        echo "   - IAM role trust policy may be incorrect"
        echo "   - IAM role may not have required permissions"
        echo "   - OIDC provider may not be configured correctly"
        echo "   - Pod identity webhook may not be running"
    fi

    return $exit_code
}

cleanup_test_resources() {
    log "Cleaning up test resources..."

    # Delete test pod if it exists
    kubectl delete pod irsa-test -n "$NAMESPACE" --ignore-not-found=true

    # Optionally delete test service account
    read -p "Delete test service account $NAMESPACE/$SERVICE_ACCOUNT? (y/N): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kubectl delete serviceaccount "$SERVICE_ACCOUNT" -n "$NAMESPACE" --ignore-not-found=true
        log "Test service account deleted"
    fi
}

show_debug_info() {
    echo
    log "Debug information:"
    echo
    echo "Pod Identity Webhook status:"
    kubectl get pods -n pod-identity-webhook
    echo
    echo "Service account details:"
    kubectl get serviceaccount "$SERVICE_ACCOUNT" -n "$NAMESPACE" -o yaml
    echo
    echo "OIDC provider information:"
    echo "  Provider ARN: $PROVIDER_ARN"
    echo "  Issuer URL: $ISSUER_URL"
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cluster-config)
                CLUSTER_CONFIG="$2"
                shift 2
                ;;
            --role-arn)
                ROLE_ARN="$2"
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
            --test-bucket)
                TEST_BUCKET="$2"
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
    if [ -z "$CLUSTER_CONFIG" ] || [ -z "$ROLE_ARN" ]; then
        error "Missing required arguments. Use --help for usage information."
        exit 1
    fi

    # Validate and load cluster configuration
    if ! validate_cluster_config "$CLUSTER_CONFIG"; then
        exit 1
    fi
    source "$CLUSTER_CONFIG"

    log "Testing IRSA setup"
    echo "=================="
    log "Cluster: $CLUSTER_NAME"
    log "Role ARN: $ROLE_ARN"
    log "Service Account: $NAMESPACE/$SERVICE_ACCOUNT"
    if [ -n "$TEST_BUCKET" ]; then
        log "Test Bucket: $TEST_BUCKET"
    fi
    echo

    # Execute test
    create_test_service_account

    if ! run_test_pod; then
        show_debug_info
        echo
        error "IRSA test failed. Check the debug information above."
        exit 1
    fi

    cleanup_test_resources
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
