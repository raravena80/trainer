#!/bin/bash
set -e

# Cleanup Alpaca Arrow Cache Demo
# This script removes all resources created by the Alpaca Arrow Cache demo

echo "🧹 Cleaning up Alpaca Arrow Cache Demo..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is not installed or not in PATH"
    exit 1
fi

# Check if the namespace exists
if ! kubectl get namespace arrow-cache-demo &> /dev/null; then
    echo "ℹ️  Namespace arrow-cache-demo doesn't exist - nothing to clean up"
    exit 0
fi

echo "🔍 Found resources in arrow-cache-demo namespace:"
kubectl get all -n arrow-cache-demo

echo ""
read -p "Are you sure you want to delete all Alpaca Arrow Cache resources? (y/N): " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🗑️  Deleting Alpaca Arrow Cache resources..."

    # Stop any running port-forwards
    echo "🔌 Stopping port-forward processes..."
    pkill -f "kubectl port-forward.*arrow-cache-demo" || true

    # Delete the namespace (this will delete all resources in it)
    kubectl delete namespace arrow-cache-demo

    echo "✅ Alpaca Arrow Cache demo resources cleaned up successfully!"
    echo ""
    echo "📝 Note: The Alpaca data in S3 (s3://ricardo.hf.datasets/) has been preserved."
    echo "     If you want to clean that up too, run:"
    echo "     aws s3 rm s3://ricardo.hf.datasets/iceberg/hf_datasets.db/tatsu-lab_alpaca/ --recursive --profile root-ricardo"
else
    echo "❌ Cleanup cancelled"
    exit 1
fi
