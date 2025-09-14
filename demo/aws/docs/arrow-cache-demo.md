# Arrow Cache Demo Comprehensive Setup Guide

This guide provides complete documentation for setting up and demonstrating the distributed Arrow Cache system with ML training integration on local Kind Kubernetes clusters.

## 🎯 Overview

The Arrow Cache ecosystem provides a comprehensive platform for distributed machine learning with:

### Core Components
- **Arrow Cache**: Distributed caching system with head-worker architecture
- **ML Training Integration**: Native support for PyTorch, HuggingFace, and popular frameworks
- **Generic Training System**: Universal training pipeline supporting any dataset via YAML configuration
- **IRSA Authentication**: Production-grade AWS authentication without hardcoded credentials
- **Kubernetes Native**: Full orchestration with TrainJob CRDs and service discovery

### Supported Datasets
- **IMDB Movie Reviews**: Sentiment classification with 50K movie reviews
- **Alpaca Instructions**: LLM fine-tuning with instruction-following dataset
- **Regular/Synthetic**: Configurable synthetic data for testing and development
- **Custom Datasets**: Easy integration of any HuggingFace or custom dataset

## 🏗️ Architecture

### ML-First Architecture
```
┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────────┐
│   Training Jobs     │    │   Arrow Cache       │    │   Data Sources      │
│                     │    │                     │    │                     │
│ ┌─────────────────┐ │    │ ┌─────────────────┐ │    │ ┌─────────────────┐ │
│ │ PyTorch         │ │───▶│ │  Head Node      │ │───▶│ │ S3 + Iceberg    │ │
│ │ HuggingFace     │ │    │ │ (Coordinator)   │ │    │ │ Metadata        │ │
│ │ Generic Script  │ │    │ └─────────────────┘ │    │ └─────────────────┘ │
│ └─────────────────┘ │    │         │           │    │         │           │
│         │           │    │         ▼           │    │         ▼           │
│         ▼           │    │ ┌─────────────────┐ │    │ ┌─────────────────┐ │
│ ┌─────────────────┐ │    │ │ Worker Nodes    │ │    │ │ Dataset Files   │ │
│ │ TrainJob CRDs   │ │    │ │ (Distributed    │ │    │ │ (Parquet)       │ │
│ │ K8s Resources   │ │    │ │  Cache)         │ │    │ │                 │ │
│ └─────────────────┘ │    │ └─────────────────┘ │    │ └─────────────────┘ │
└─────────────────────┘    └─────────────────────┘    └─────────────────────┘
           │                           │                           │
           ▼                           ▼                           ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Kubernetes Cluster (Kind)                          │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐              │
│  │  IRSA/AWS Auth  │  │  Service        │  │  Monitoring     │              │
│  │  (IAM Roles)    │  │  Discovery      │  │  & Logging      │              │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow Architecture
```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   ML Training   │    │   Arrow Cache   │    │   Storage       │
│                 │    │                 │    │                 │
│ ┌─────────────┐ │    │ ┌─────────────┐ │    │ ┌─────────────┐ │
│ │ DataLoader  │ │───▶│ │ Flight      │ │───▶│ │ S3 Buckets  │ │
│ │ (PyTorch)   │ │    │ │ Client      │ │    │ │ (Raw Data)  │ │
│ └─────────────┘ │    │ └─────────────┘ │    │ └─────────────┘ │
│       │         │    │       │         │    │       │         │
│       ▼         │    │       ▼         │    │       ▼         │
│ ┌─────────────┐ │    │ ┌─────────────┐ │    │ ┌─────────────┐ │
│ │ Model       │ │    │ │ Head Node   │ │    │ │ Glue Catalog│ │
│ │ Training    │ │    │ │ (Query      │ │    │ │ (Metadata)  │ │
│ └─────────────┘ │    │ │  Router)    │ │    │ └─────────────┘ │
└─────────────────┘    │ └─────────────┘ │    └─────────────────┘
                       │       │         │
                       │       ▼         │
                       │ ┌─────────────┐ │
                       │ │ Workers     │ │
                       │ │ (In-memory  │ │
                       │ │  Cache)     │ │
                       │ └─────────────┘ │
                       └─────────────────┘
```

## 📋 Prerequisites

### Required Software
1. **Docker or Lima** - Container runtime for Kind clusters
2. **kubectl** - Kubernetes command-line tool
3. **Kind** - Kubernetes in Docker for local clusters
4. **Python 3.11+** - For training scripts and demo clients
5. **AWS CLI** - For IRSA and S3 integration (optional but recommended)

### Installation Commands

**macOS (Homebrew):**
```bash
brew install docker kubectl kind awscli
```

**Linux (Ubuntu/Debian):**
```bash
# Docker
curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind

# AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install
```

### Python Environment Setup
```bash
# Create conda environment
conda env create -f environment.yml
conda activate arrow-cache-demo

# Or use pip
pip install pyarrow grpcio pandas torch transformers datasets boto3 s3fs
```

## 🚀 Quick Start Options

### Option 1: Generic Training System (Recommended)
The universal approach that works with any dataset:

```bash
# 1. Setup complete infrastructure with IRSA
./scripts/setup-kind/setup-kind-cluster.sh --enable-irsa
./scripts/setup-kind/irsa/arrow-cache-example.sh --demo-type imdb

# 2. Run ML training with any dataset
./scripts/generic/setup-generic-training.sh \
  --dataset-name imdb \
  --dataset-config scripts/generic/configs/imdb.yaml \
  --use-arrow-cache \
  --use-irsa

# 3. Monitor training progress
kubectl get trainjobs -n arrow-cache-demo -w
kubectl logs -f job/imdb-training-$(date +%Y%m%d)-node-0 -n arrow-cache-demo
```

### Option 2: Dataset-Specific Demos
Traditional approach with specialized scripts:

**IMDB Movie Review Sentiment Classification:**
```bash
# Setup and training
./scripts/imdb/setup-imdb-arrow-cache.sh --use-irsa
python3 scripts/imdb/imdb_training.py --use-arrow-cache --use-irsa --dry-run

# Demo client testing
python3 scripts/imdb/demo-client.py --demo --performance
```

**Alpaca Instruction Following Fine-tuning:**
```bash
# Setup and training
./scripts/alpaca/setup-alpaca-arrow-cache.sh --use-irsa
python3 scripts/alpaca/alpaca_training.py --use-arrow-cache --use-irsa --epochs 1

# Check TrainJob status
kubectl get trainjobs -n arrow-cache-demo
```

**Regular Synthetic Data (Learning/Testing):**
```bash
# Basic setup without AWS
./scripts/regular/setup-arrow-cache.sh
python3 scripts/regular/demo-client.py --demo

# Generate custom synthetic data
./scripts/regular/generate-demo-data.py --records 10000 --files 4
```

### Option 3: Manual Step-by-Step Setup
For understanding the complete process:

```bash
# 1. Create Kind cluster with IRSA support
./scripts/setup-kind/setup-kind-cluster.sh --enable-irsa --aws-region us-west-2

# 2. Create IAM role for service accounts
./scripts/setup-kind/irsa/create-irsa-role.sh \
  --role-name ArrowCacheRole \
  --namespace arrow-cache-demo \
  --service-account arrow-cache-sa

# 3. Deploy Arrow Cache
kubectl apply -k manifests/arrow-cache/

# 4. Wait for deployment
kubectl wait --for=condition=ready pod -l app=arrow-cache-head -n arrow-cache-demo --timeout=300s
kubectl wait --for=condition=ready pod -l app=arrow-cache-worker -n arrow-cache-demo --timeout=300s

# 5. Test connectivity
python3 scripts/regular/demo-client.py --demo
```

## 🔧 Configuration

### Dataset Configuration (Generic System)
Each dataset is configured via YAML files in `scripts/generic/configs/`:

```yaml
# Example: scripts/generic/configs/imdb.yaml
dataset_name: "imdb"
description: "IMDB movie review sentiment classification"

# Arrow Cache settings
namespace: "arrow-cache-demo"
num_partitions: 4

# Iceberg table location
iceberg_table: "hf_datasets.imdb"

# Data schema
text_column: "text"
columns:
  - name: "text"
    type: "string"
    description: "Movie review text"
  - name: "label"
    type: "int64"
    description: "Sentiment label (0=negative, 1=positive)"

# Training defaults
default_model: "distilbert-base-uncased"
default_max_length: 512
default_batch_size: 8
default_epochs: 3

# AWS resources (for IRSA)
checkpoint_bucket: "my-training-checkpoints"
glue_database: "hf_datasets"
```

### Arrow Cache Configuration
Core Arrow Cache settings in `manifests/arrow-cache/configmap.yaml`:

```yaml
data:
  # Data source configuration
  METADATA_LOC: "s3://my-bucket/metadata"
  TABLE_NAME: "my_table"
  SCHEMA_NAME: "my_schema"

  # Performance tuning
  WORKER_COUNT: "2"
  CACHE_SIZE_MB: "2048"
  FLIGHT_PORT: "50051"

  # AWS integration (when using IRSA)
  AWS_REGION: "us-west-2"
  USE_IRSA: "true"
```

## 🎭 Demo Usage and Testing

### 1. Generic Training Demos
**IMDB Sentiment Classification:**
```bash
# Complete training pipeline
./scripts/generic/setup-generic-training.sh \
  --dataset-name imdb \
  --dataset-config scripts/generic/configs/imdb.yaml \
  --model-name distilbert-base-uncased \
  --max-samples 1000 \
  --batch-size 8 \
  --use-arrow-cache \
  --use-irsa

# Monitor progress
kubectl logs -f job/imdb-training-$(date +%Y%m%d)-node-0 -n arrow-cache-demo
```

**Custom Dataset Training:**
```bash
# Create custom config based on template
cp scripts/generic/configs/custom-template.yaml scripts/generic/configs/my-dataset.yaml
# Edit my-dataset.yaml with your settings

# Run training
./scripts/generic/setup-generic-training.sh \
  --dataset-name my-dataset \
  --dataset-config scripts/generic/configs/my-dataset.yaml \
  --use-arrow-cache
```

### 2. Arrow Cache Connectivity Testing
**Basic Demo Client:**
```bash
# Test basic connectivity
python3 scripts/regular/demo-client.py --demo

# Performance benchmarking
python3 scripts/imdb/demo-client.py --performance --queries 50

# Specific query testing
python3 scripts/regular/demo-client.py --query --start-row 0 --end-row 100
```

**Status Monitoring:**
```bash
# Comprehensive status check
./scripts/regular/demo-arrow-cache-status.sh

# Arrow Cache resource monitoring
kubectl get pods,services,configmaps -n arrow-cache-demo -l app.kubernetes.io/name=arrow-cache
```

### 3. Manual Flight Client Testing
For advanced users who want to interact directly with the Arrow Flight protocol:

```python
import pyarrow.flight as flight
import struct

# Connect to Arrow Cache head node
client = flight.FlightClient("grpc://localhost:50051")

# List available flights (datasets)
flights = client.list_flights()
for flight_info in flights:
    print(f"Dataset: {flight_info.descriptor}")

# Query specific data range
ticket_data = struct.pack('QQ', 0, 99)  # rows 0-99
ticket = flight.Ticket(ticket_data)

# Execute query and get results
flight_stream = client.do_get(ticket)
arrow_table = flight_stream.read_all()

print(f"Retrieved {len(arrow_table)} rows")
print(f"Schema: {arrow_table.schema}")
print(f"Sample data:\n{arrow_table.to_pandas().head()}")
```

### 4. Training Integration Testing
**PyTorch DataLoader Integration:**
```python
import sys, os
sys.path.append('scripts/lib')
from arrow_cache_client import BaseArrowCacheClient

# Create custom dataset that uses Arrow Cache
class ArrowCacheDataset:
    def __init__(self, cache_client, total_samples):
        self.client = cache_client
        self.total_samples = total_samples

    def __len__(self):
        return self.total_samples

    def __getitem__(self, idx):
        # Query Arrow Cache for specific sample
        result = self.client.query_sample(idx)
        return result['text'], result['label']

# Use with PyTorch DataLoader
from torch.utils.data import DataLoader
dataset = ArrowCacheDataset(client, 1000)
dataloader = DataLoader(dataset, batch_size=32, shuffle=True)
```

## 🔍 Monitoring and Troubleshooting

### Deployment Status Monitoring

**Arrow Cache Resources:**
```bash
# Check all Arrow Cache resources
kubectl get all -n arrow-cache-demo -l app.kubernetes.io/name=arrow-cache

# Check pod status and readiness
kubectl get pods -n arrow-cache-demo -o wide

# View resource usage
kubectl top pods -n arrow-cache-demo
```

**Training Job Monitoring:**
```bash
# Monitor TrainJobs (if using generic training system)
kubectl get trainjobs -n arrow-cache-demo -w

# Check training logs
kubectl logs -f job/imdb-training-$(date +%Y%m%d)-node-0 -n arrow-cache-demo

# View all training-related resources
kubectl get jobs,pods,configmaps -n arrow-cache-demo -l app=training
```

### Log Analysis

**Arrow Cache Logs:**
```bash
# Head node logs (coordination and routing)
kubectl logs -n arrow-cache-demo -l app=arrow-cache-head -f --tail=100

# Worker node logs (data caching and queries)
kubectl logs -n arrow-cache-demo -l app=arrow-cache-worker -f --tail=100

# All Arrow Cache logs
kubectl logs -n arrow-cache-demo -l app.kubernetes.io/name=arrow-cache -f
```

**IRSA and Authentication Logs:**
```bash
# Pod identity webhook logs
kubectl logs -n kube-system -l app=pod-identity-webhook -f

# Service account and IRSA debugging
kubectl describe sa arrow-cache-sa -n arrow-cache-demo
kubectl get events -n arrow-cache-demo --sort-by='.lastTimestamp'
```

### Common Issues and Solutions

**1. Pods Not Starting:**
```bash
# Check pod status and events
kubectl describe pod <pod-name> -n arrow-cache-demo

# Common causes:
# - Insufficient cluster resources
# - Image pull failures
# - ConfigMap/Secret mounting issues
# - IRSA configuration problems

# Solutions:
# Check resource limits, verify image availability, validate configs
```

**2. Arrow Cache Connection Issues:**
```bash
# Test port forwarding
kubectl port-forward -n arrow-cache-demo service/arrow-cache-head-svc 50051:50051 &
telnet localhost 50051

# Check service endpoints
kubectl get endpoints arrow-cache-head-svc -n arrow-cache-demo

# Verify service configuration
kubectl describe service arrow-cache-head-svc -n arrow-cache-demo
```

**3. IRSA Authentication Failures:**
```bash
# Test IRSA setup
./scripts/setup-kind/irsa/test-irsa.sh

# Manually test AWS access from pod
kubectl run irsa-debug --rm -i --tty \
  --serviceaccount=arrow-cache-sa \
  --namespace=arrow-cache-demo \
  --image=amazon/aws-cli:latest -- aws sts get-caller-identity

# Check OIDC configuration
curl -s $(kubectl get cm cluster-info -n kube-system -o jsonpath='{.data.issuer-url}')/.well-known/openid_configuration
```

**4. Training Job Issues:**
```bash
# Check TrainJob status
kubectl describe trainjob <job-name> -n arrow-cache-demo

# View training logs
kubectl logs job/<job-name>-node-0 -n arrow-cache-demo

# Common issues:
# - Model/dataset loading failures
# - Resource constraints (OOM, CPU limits)
# - Arrow Cache connectivity problems
# - AWS permissions issues
```

**5. Performance Issues:**
```bash
# Monitor resource usage
kubectl top pods -n arrow-cache-demo

# Check Arrow Cache metrics
python3 scripts/regular/demo-client.py --performance --queries 20

# Scale workers if needed
kubectl scale statefulset arrow-cache-worker --replicas=4 -n arrow-cache-demo
```

### Advanced Debugging

**Network Connectivity:**
```bash
# Test inter-pod communication
kubectl exec -it <head-pod> -n arrow-cache-demo -- nc -zv arrow-cache-worker-0.arrow-cache-worker-svc 50051

# Check DNS resolution
kubectl exec -it <head-pod> -n arrow-cache-demo -- nslookup arrow-cache-worker-svc
```

**Storage and Data Issues:**
```bash
# Check S3 access from pods (with IRSA)
kubectl exec -it <pod-name> -n arrow-cache-demo -- aws s3 ls s3://your-bucket/

# Verify Iceberg metadata
kubectl exec -it <pod-name> -n arrow-cache-demo -- python3 -c "
import boto3
glue = boto3.client('glue')
print(glue.get_table(DatabaseName='hf_datasets', Name='imdb'))
"
```

### Performance Tuning

**Arrow Cache Scaling:**
```bash
# Scale workers horizontally
kubectl scale statefulset arrow-cache-worker --replicas=4 -n arrow-cache-demo

# Update cache configuration for larger datasets
kubectl edit configmap arrow-cache-config -n arrow-cache-demo
# Increase CACHE_SIZE_MB, adjust WORKER_COUNT
```

**Training Resource Optimization:**
```bash
# Adjust training resource requests/limits
# Edit scripts/generic/templates/generic-trainjob.yaml
resources:
  requests:
    memory: "4Gi"
    cpu: "2"
  limits:
    memory: "8Gi"
    cpu: "4"
```

## 🏗️ Architecture Deep Dive

### System Components

**Arrow Cache Head Node:**
- **Service**: `arrow-cache-head-svc` on port 50051
- **Purpose**: Query routing, worker coordination, client entry point
- **Deployment**: Single replica deployment with service discovery
- **Responsibilities**: File-to-worker mapping, query planning, result aggregation

**Arrow Cache Worker Nodes:**
- **Service**: `arrow-cache-worker-svc` (headless) on port 50051
- **Purpose**: Data caching, query execution, result streaming
- **Deployment**: StatefulSet with 2+ replicas (horizontally scalable)
- **Responsibilities**: In-memory data caching, Apache Arrow Flight serving

**Training Integration:**
- **TrainJob CRDs**: Kubernetes-native training job management
- **Generic Training System**: Universal pipeline supporting any dataset
- **Resource Management**: CPU/memory limits, GPU support, distributed training

### Data Architecture

**Storage Layers:**
- **S3 Data Lake**: Raw Parquet files with optimized partitioning
- **Apache Iceberg**: Metadata management with schema evolution
- **Arrow Cache**: Distributed in-memory caching layer
- **Flight Protocol**: High-performance data transport

**Authentication Flow (IRSA):**
1. Pod starts with service account annotation
2. Pod Identity Webhook injects AWS token
3. Arrow Cache assumes IAM role automatically
4. Secure access to S3/Glue without hardcoded credentials

### Scalability Patterns

**Horizontal Scaling:**
```bash
# Scale Arrow Cache workers
kubectl scale statefulset arrow-cache-worker --replicas=6 -n arrow-cache-demo

# Scale training jobs (via JobSet)
# Edit TrainJob manifest to increase parallelism
parallelism: 4
```

**Performance Optimization:**
- **Data Partitioning**: Optimize file sizes and partition strategy
- **Cache Warming**: Pre-load frequently accessed data
- **Query Optimization**: Batch queries, minimize data transfer
- **Resource Tuning**: Balance memory vs CPU allocation

## 🧹 Cleanup and Resource Management

### Selective Cleanup
```bash
# Remove only Arrow Cache deployment
kubectl delete -k manifests/arrow-cache/ -n arrow-cache-demo

# Remove only training jobs
kubectl delete trainjobs --all -n arrow-cache-demo

# Remove specific demo resources
kubectl delete namespace arrow-cache-imdb
kubectl delete namespace arrow-cache-alpaca
```

### Complete Environment Cleanup
```bash
# Remove entire Kind cluster
kind delete cluster --name arrow-cache-demo

# Clean up AWS resources (if IRSA was used)
./scripts/setup-kind/irsa/cleanup-irsa.sh --cluster-name arrow-cache-demo

# Remove local data (if generated)
rm -rf /tmp/arrow-cache-demo-data
```

### Resource Cost Management
**AWS Resources Created:**
- S3 buckets (OIDC discovery): ~$0.01/month
- IAM roles/policies: Free
- Data transfer: Pay per GB

**Cleanup Automation:**
```bash
# Set cleanup reminder
echo "kind delete cluster --name arrow-cache-demo" | at now + 4 hours

# Automated cleanup script
cat > cleanup-demo.sh << 'EOF'
#!/bin/bash
kind delete cluster --name arrow-cache-demo
./scripts/setup-kind/irsa/cleanup-irsa.sh --cluster-name arrow-cache-demo
echo "Demo environment cleaned up at $(date)"
EOF
```

## 🎪 Production Migration Path

### Development to Production Checklist

**1. Infrastructure Migration:**
- [ ] Replace Kind with EKS cluster
- [ ] Replace S3 OIDC with native EKS OIDC
- [ ] Add persistent storage for caching
- [ ] Configure auto-scaling groups

**2. Security Hardening:**
- [ ] Network policies for pod isolation
- [ ] Least-privilege IAM roles
- [ ] Secrets management with external secrets operator
- [ ] Pod security standards enforcement

**3. Monitoring and Observability:**
- [ ] Prometheus metrics collection
- [ ] Grafana dashboards for Arrow Cache
- [ ] Distributed tracing (Jaeger/Zipkin)
- [ ] Log aggregation (CloudWatch/ELK)

**4. High Availability:**
- [ ] Multi-AZ deployment
- [ ] Load balancing for head nodes
- [ ] Data replication strategies
- [ ] Disaster recovery procedures

### Migration Commands
```bash
# Export configurations from Kind
kubectl get configmaps,secrets,serviceaccounts -o yaml -n arrow-cache-demo > demo-configs.yaml

# Apply to EKS (after cluster setup)
kubectl apply -f demo-configs.yaml -n production-namespace

# Update OIDC issuer in service account annotations
kubectl annotate sa arrow-cache-sa -n production-namespace \
  eks.amazonaws.com/role-arn=arn:aws:iam::ACCOUNT:role/ArrowCacheRole --overwrite
```

## 🎭 Demo Presentation Flow

### 5-Minute Lightning Demo
```bash
# 1. One-command setup (1 min)
./scripts/setup-kind/irsa/arrow-cache-example.sh --demo-type imdb

# 2. Show training execution (2 mins)
./scripts/generic/setup-generic-training.sh --dataset-name imdb --use-arrow-cache --use-irsa
kubectl get trainjobs -w

# 3. Performance demonstration (1 min)
python3 scripts/imdb/demo-client.py --performance --queries 10

# 4. Scaling demo (1 min)
kubectl scale statefulset arrow-cache-worker --replicas=4 -n arrow-cache-demo
```

### 15-Minute Comprehensive Demo
1. **Architecture Overview** (3 mins): Show ML-first design, IRSA benefits
2. **Live Infrastructure Setup** (3 mins): Kind cluster + IRSA deployment
3. **Multi-Dataset Demo** (4 mins): IMDB, Alpaca, and custom dataset examples
4. **Performance Analysis** (3 mins): Scaling, caching benefits, monitoring
5. **Production Migration** (2 mins): EKS transition, security considerations

### Demo Script Template
```bash
#!/bin/bash
echo "🎯 Arrow Cache + ML Training Demo"
echo "1. Setting up infrastructure..."
./scripts/setup-kind/irsa/arrow-cache-example.sh --demo-type imdb

echo "2. Running IMDB sentiment training..."
./scripts/generic/setup-generic-training.sh --dataset-name imdb --use-arrow-cache --use-irsa --dry-run

echo "3. Testing performance..."
python3 scripts/imdb/demo-client.py --performance --queries 20

echo "4. Scaling workers..."
kubectl scale statefulset arrow-cache-worker --replicas=4 -n arrow-cache-demo

echo "✅ Demo complete! Questions?"
```

This comprehensive guide provides everything needed to understand, deploy, and present the Arrow Cache system with ML training integration.
