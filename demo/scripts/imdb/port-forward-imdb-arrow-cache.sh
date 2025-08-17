#!/bin/bash
set -e

# Port Forward IMDB Arrow Cache Demo Services
# This script sets up port forwarding to access the Arrow Cache services locally

echo "🔌 Setting up port forwarding for IMDB Arrow Cache..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is not installed or not in PATH"
    exit 1
fi

# Check if the namespace exists
if ! kubectl get namespace arrow-cache-imdb &> /dev/null; then
    echo "❌ Namespace arrow-cache-imdb doesn't exist"
    echo "Please deploy the demo first:"
    echo "  ./demo/scripts/imdb/setup-imdb-arrow-cache.sh"
    exit 1
fi

# Check if pods are ready
echo "🔍 Checking pod status..."
if ! kubectl get pods -n arrow-cache-imdb | grep -q "Running"; then
    echo "❌ No running pods found in arrow-cache-imdb namespace"
    echo "Please make sure the demo is deployed and pods are ready:"
    echo "  kubectl get pods -n arrow-cache-imdb"
    exit 1
fi

# Detect deployment type
echo "🔍 Detecting deployment type..."
if kubectl get leaderworkerset arrow-cache-imdb-lws -n arrow-cache-imdb &> /dev/null; then
    deployment_type="lws"
    echo "📋 Detected: LeaderWorkerSet deployment"
    worker1_pod="arrow-cache-imdb-lws-0-1"
    worker2_pod="arrow-cache-imdb-lws-0-2"
else
    deployment_type="statefulset"
    echo "📋 Detected: StatefulSet deployment"
    worker1_pod="arrow-cache-worker-0"
    worker2_pod="arrow-cache-worker-1"
fi

# Kill any existing port-forward processes
echo "🔌 Stopping existing port-forward processes..."
pkill -f "kubectl port-forward.*arrow-cache-imdb" || true
sleep 2

# Function to start port forwarding in background
start_port_forward() {
    local resource=$1
    local local_port=$2
    local remote_port=$3
    local service_name=$4

    echo "🚀 Starting port forward: $service_name (localhost:$local_port -> $resource:$remote_port)"
    kubectl port-forward -n arrow-cache-imdb "$resource" "$local_port:$remote_port" &
    local pid=$!
    echo "  PID: $pid"

    # Give it a moment to start
    sleep 1

    # Check if the process is still running
    if ! kill -0 $pid 2>/dev/null; then
        echo "❌ Failed to start port forward for $service_name"
        return 1
    fi

    return 0
}

echo ""
echo "🔌 Setting up port forwarding..."

# Port forward head service
if ! start_port_forward "service/arrow-cache-head-svc" "50051" "50051" "Head Service"; then
    echo "❌ Failed to set up head service port forward"
    exit 1
fi

# Port forward worker-0
if ! start_port_forward "$worker1_pod" "50052" "50051" "Worker-1"; then
    echo "❌ Failed to set up worker-1 port forward"
    exit 1
fi

# Port forward worker-1
if ! start_port_forward "$worker2_pod" "50053" "50051" "Worker-2"; then
    echo "❌ Failed to set up worker-2 port forward"
    exit 1
fi

echo ""
echo "✅ Port forwarding setup complete!"
echo ""
echo "📡 Active port forwards:"
echo "  Head Service:  localhost:50051 -> arrow-cache-head-svc:50051"
echo "  Worker-1:      localhost:50052 -> $worker1_pod:50051"
echo "  Worker-2:      localhost:50053 -> $worker2_pod:50051"
echo ""
echo "🎯 Now you can run the demo client:"
echo "  python3 demo/scripts/imdb/demo-client.py --demo"
echo ""
echo "📊 Monitor logs with:"
if [[ "$deployment_type" == "lws" ]]; then
    echo "  kubectl logs -f -n arrow-cache-imdb arrow-cache-imdb-lws-0-0  # Head pod"
    echo "  kubectl logs -f -n arrow-cache-imdb $worker1_pod  # Worker pod 1"
    echo "  kubectl logs -f -n arrow-cache-imdb $worker2_pod  # Worker pod 2"
else
    echo "  kubectl logs -f -n arrow-cache-imdb deployment/arrow-cache-head"
    echo "  kubectl logs -f -n arrow-cache-imdb statefulset/arrow-cache-worker"
fi
echo ""
echo "⚡ To stop port forwarding, press Ctrl+C or run:"
echo "  pkill -f 'kubectl port-forward.*arrow-cache-imdb'"

# Wait for user to interrupt
echo ""
echo "🔄 Port forwarding active. Press Ctrl+C to stop..."
wait
