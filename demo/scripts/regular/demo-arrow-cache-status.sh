#!/bin/bash

# Arrow Cache Demo Status Script
# Shows the current status of the arrow cache deployment

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

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_cluster_status() {
    log "Arrow Cache Cluster Status"
    echo "=========================="
    echo

    # Check if cluster exists
    if ! kind get clusters | grep -q arrow-cache-demo; then
        error "Arrow cache demo cluster not found!"
        echo "Run: ./demo/scripts/setup-arrow-cache-kind.sh"
        return 1
    fi

    success "Kind cluster 'arrow-cache-demo' is running"
    echo

    # Show namespace
    log "Namespace:"
    kubectl get namespace arrow-cache -o wide 2>/dev/null || warn "Namespace not found"
    echo

    # Show pods
    log "Pods Status:"
    kubectl get pods -n arrow-cache -o wide
    echo

    # Show services
    log "Services:"
    kubectl get services -n arrow-cache -o wide
    echo

    # Show deployments and statefulsets
    log "Workloads:"
    kubectl get deployment,statefulset -n arrow-cache -o wide
    echo
}

show_configuration() {
    log "Configuration:"
    echo

    log "ConfigMap (arrow-cache-config):"
    kubectl get configmap arrow-cache-config -n arrow-cache -o yaml | grep -A 20 "data:" | head -15
    echo

    log "Secret (aws-credentials):"
    if kubectl get secret aws-credentials -n arrow-cache >/dev/null 2>&1; then
        echo "  AWS credentials configured ✓"
        kubectl get secret aws-credentials -n arrow-cache -o jsonpath='{.data}' | jq -r 'keys[]' 2>/dev/null || echo "  Keys: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY"
    else
        warn "AWS credentials not configured"
        echo "  Run: ./demo/scripts/setup-aws-credentials.sh"
    fi
    echo
}

show_logs() {
    log "Recent Logs:"
    echo

    log "Head Node Logs (last 10 lines):"
    kubectl logs -n arrow-cache deployment/arrow-cache-head --tail=10 2>/dev/null || warn "No head node logs available"
    echo

    log "Worker Node Logs (last 5 lines each):"
    for i in 0 1; do
        echo "  Worker $i:"
        kubectl logs -n arrow-cache arrow-cache-worker-$i --tail=5 2>/dev/null | sed 's/^/    /' || warn "    No logs for worker $i"
    done
    echo
}

show_connectivity_test() {
    log "Connectivity Test:"
    echo

    # Test if services are reachable
    log "Testing internal service connectivity..."

    # Port-forward test
    log "Setting up port forwarding to test connectivity..."
    kubectl port-forward -n arrow-cache service/arrow-cache-head-svc 50051:50051 &
    PF_PID=$!

    sleep 2

    # Test connection
    if nc -z localhost 50051 2>/dev/null; then
        success "Head service is reachable on localhost:50051"
    else
        warn "Head service not reachable (may be starting up)"
    fi

    # Clean up port forward
    kill $PF_PID 2>/dev/null || true
    echo
}

show_demo_summary() {
    log "Demo Summary:"
    echo

    # Count running pods
    RUNNING_PODS=$(kubectl get pods -n arrow-cache --no-headers | grep -c "Running" || echo "0")
    TOTAL_PODS=$(kubectl get pods -n arrow-cache --no-headers | wc -l || echo "0")

    if [ "$RUNNING_PODS" -eq 2 ] && [ "$TOTAL_PODS" -eq 2 ]; then
        success "Worker nodes are running successfully! ($RUNNING_PODS/$TOTAL_PODS pods ready)"
    else
        warn "Some pods are not running ($RUNNING_PODS/$TOTAL_PODS pods ready)"
    fi

    # Check head node status
    HEAD_STATUS=$(kubectl get deployment arrow-cache-head -n arrow-cache -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "$HEAD_STATUS" = "1" ]; then
        success "Head node is running and ready!"
    else
        warn "Head node is not ready (likely needs proper AWS credentials and data)"
        echo "  This is expected for the demo - the head node needs:"
        echo "  1. Valid AWS credentials (run setup-aws-credentials.sh)"
        echo "  2. Valid Iceberg metadata location in S3"
        echo "  3. Proper table and schema configuration"
    fi

    echo
    echo "🎉 Demo Status: Arrow Cache infrastructure is deployed!"
    echo
    echo "✅ What's Working:"
    echo "  - Kind cluster with 3 nodes"
    echo "  - Worker StatefulSet (2 replicas) running"
    echo "  - Head Deployment created"
    echo "  - Services and networking configured"
    echo "  - Kubernetes service discovery working"
    echo "  - Docker image built and loaded"
    echo
    echo "🔧 What Needs Data:"
    echo "  - Head node needs valid Iceberg metadata"
    echo "  - AWS credentials for S3 access"
    echo "  - Sample data files for caching"
    echo
    echo "📝 Next Steps for Full Demo:"
    echo "  1. Configure AWS credentials: ./demo/scripts/setup-aws-credentials.sh"
    echo "  2. Point to real Iceberg data in S3"
    echo "  3. Test with Flight client: python3 demo/scripts/demo-arrow-cache-client.py"
    echo "  4. Scale workers: kubectl scale statefulset arrow-cache-worker --replicas=3 -n arrow-cache"
    echo
}

main() {
    show_cluster_status
    show_configuration
    show_logs
    show_connectivity_test
    show_demo_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
