#!/bin/bash

# Setup port-forwarding for Arrow Cache demo
echo "Setting up port-forwarding for Arrow Cache services..."

# Kill any existing port-forward processes
pkill -f "kubectl port-forward.*arrow-cache" || true
sleep 2

# Start port-forwarding in background
echo "Starting head node port-forward on :50051..."
kubectl port-forward -n arrow-cache svc/arrow-cache-head-svc 50051:50051 &
HEAD_PF_PID=$!

echo "Starting worker-0 port-forward on :50052..."
kubectl port-forward -n arrow-cache arrow-cache-worker-0 50052:50051 &
WORKER0_PF_PID=$!

echo "Starting worker-1 port-forward on :50053..."
kubectl port-forward -n arrow-cache arrow-cache-worker-1 50053:50051 &
WORKER1_PF_PID=$!

# Wait a moment for port-forwards to establish
sleep 3

# Check if port-forwards are working
echo "Testing port-forward connections..."

if nc -z localhost 50051; then
    echo "✓ Head node port-forward working on :50051"
else
    echo "✗ Head node port-forward failed"
fi

if nc -z localhost 50052; then
    echo "✓ Worker-0 port-forward working on :50052"
else
    echo "✗ Worker-0 port-forward failed"
fi

if nc -z localhost 50053; then
    echo "✓ Worker-1 port-forward working on :50053"
else
    echo "✗ Worker-1 port-forward failed"
fi

echo ""
echo "Port-forward PIDs:"
echo "Head:     $HEAD_PF_PID"
echo "Worker-0: $WORKER0_PF_PID"
echo "Worker-1: $WORKER1_PF_PID"
echo ""
echo "To stop all port-forwards, run: pkill -f 'kubectl port-forward.*arrow-cache'"
echo "Port-forwarding is now ready for demo!"
