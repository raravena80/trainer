#!/bin/bash
set -e

# Deploy IMDB Arrow Cache Demo
# This script deploys the Arrow Cache system configured for the IMDB dataset

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(dirname "$SCRIPT_DIR")/manifests/arrow-cache-imdb"

echo "🚀 Deploying IMDB Arrow Cache Demo..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is not installed or not in PATH"
    exit 1
fi

# Check if kind cluster is running
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Kubernetes cluster is not accessible"
    echo "Make sure your kind cluster is running:"
    echo "  kind create cluster --name arrow-cache-demo"
    exit 1
fi

# Check if Docker image exists
if ! docker images | grep -q "arrow-cache-demo"; then
    echo "❌ arrow-cache-demo Docker image not found"
    echo "Please build the Docker image first:"
    echo "  # From the trainer project root:"
    echo "  docker build -t arrow-cache-demo:latest ."
    exit 1
fi

# Load Docker image into kind cluster
echo "📦 Loading Docker image into kind cluster..."
kind load docker-image arrow-cache-demo:latest --name arrow-cache-demo

# Check if AWS credentials are configured
echo "🔐 Checking AWS credentials..."
if ! aws configure list --profile root-ricardo &> /dev/null; then
    echo "❌ AWS profile 'root-ricardo' not found"
    echo "Please configure your AWS credentials first:"
    echo "  aws configure --profile root-ricardo"
    exit 1
fi

# Get AWS credentials for secret creation
echo "🔑 Extracting AWS credentials..."
AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id --profile root-ricardo)
AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key --profile root-ricardo)
AWS_SESSION_TOKEN=$(aws configure get aws_session_token --profile root-ricardo || echo "")

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "❌ AWS credentials not properly configured"
    exit 1
fi

# Create temporary AWS secret file with actual credentials
echo "📝 Creating AWS secret with actual credentials..."
cat > /tmp/aws-secret-imdb.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: aws-credentials
  namespace: arrow-cache-imdb
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "${AWS_ACCESS_KEY_ID}"
  AWS_SECRET_ACCESS_KEY: "${AWS_SECRET_ACCESS_KEY}"
EOF

# Add session token if available
if [ ! -z "$AWS_SESSION_TOKEN" ]; then
    echo "  AWS_SESSION_TOKEN: \"${AWS_SESSION_TOKEN}\"" >> /tmp/aws-secret-imdb.yaml
fi

# Deploy using kubectl
echo "🚢 Deploying Kubernetes resources..."

# Apply manifests in order
kubectl apply -f "${MANIFESTS_DIR}/namespace.yaml"
echo "✅ Namespace created"

kubectl apply -f "${MANIFESTS_DIR}/configmap.yaml"
echo "✅ ConfigMap applied"

kubectl apply -f /tmp/aws-secret-imdb.yaml
echo "✅ AWS Secret applied"

kubectl apply -f "${MANIFESTS_DIR}/worker-statefulset.yaml"
echo "✅ Worker StatefulSet deployed"

kubectl apply -f "${MANIFESTS_DIR}/head-deployment.yaml"
echo "✅ Head Deployment applied"

# Clean up temporary secret file
rm -f /tmp/aws-secret-imdb.yaml

echo "⏳ Waiting for pods to be ready..."

# Wait for workers to be ready
kubectl wait --for=condition=ready pod -l app=arrow-cache-worker -n arrow-cache-imdb --timeout=300s
echo "✅ Worker pods are ready"

# Wait for head to be ready
kubectl wait --for=condition=ready pod -l app=arrow-cache-head -n arrow-cache-imdb --timeout=300s
echo "✅ Head pod is ready"

echo ""
echo "🎉 IMDB Arrow Cache Demo deployed successfully!"
echo ""
echo "📊 Deployment Status:"
kubectl get pods -n arrow-cache-imdb

echo ""
echo "🔧 Next steps:"
echo ""
echo "1. Set up port forwarding to access the services:"
echo "   kubectl port-forward -n arrow-cache-imdb service/arrow-cache-head-svc 50051:50051 &"
echo "   kubectl port-forward -n arrow-cache-imdb arrow-cache-worker-0 50052:50051 &"
echo "   kubectl port-forward -n arrow-cache-imdb arrow-cache-worker-1 50053:50051 &"
echo ""
echo "2. Run the IMDB demo client:"
echo "   python3 demo/scripts/imdb/demo-client.py --demo"
echo ""
echo "3. Monitor logs:"
echo "   kubectl logs -f -n arrow-cache-imdb deployment/arrow-cache-head"
echo "   kubectl logs -f -n arrow-cache-imdb statefulset/arrow-cache-worker"
echo ""
echo "4. Clean up when done:"
echo "   ./demo/scripts/cleanup-imdb-arrow-cache.sh"

echo ""
echo "📈 IMDB Dataset Info:"
echo "  - Total reviews: ~100,000"
echo "  - Schema: text (string), label (int64)"
echo "  - Labels: 0=negative, 1=positive"
echo "  - S3 location: s3://ricardo.hf.datasets/iceberg/hf_datasets.db/imdb_reviews/"
