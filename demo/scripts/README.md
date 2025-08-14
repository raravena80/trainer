# Arrow Cache Demo Scripts

This directory contains consolidated scripts for setting up and running the distributed Arrow Cache demo environment.

## Core Scripts

### 🚀 `setup-demo.sh` - **All-in-One Demo Setup**
**Primary script for complete demo environment setup**

```bash
# Complete setup with local data
./setup-demo.sh

# Setup with S3 storage
./setup-demo.sh --s3-path s3://my-bucket/demo-data

# Only cluster setup (no data generation)
./setup-demo.sh --cluster-only

# Only data generation (cluster must exist)
./setup-demo.sh --data-only --records 50000
```

**Features:**
- Creates Kind cluster with 3 nodes
- Builds and loads Docker image
- Deploys Arrow Cache to Kubernetes
- Generates realistic demo data (local or S3)
- Configures system automatically
- Sets up port forwarding for local access

---

### 🔐 `setup-aws.sh` - **AWS Credentials Helper**
**Configure AWS credentials for S3 access**

```bash
# Use existing AWS CLI config
./setup-aws.sh --from-cli

# Use environment variables
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
./setup-aws.sh --from-env

# Interactive setup
./setup-aws.sh --interactive

# Test existing credentials
./setup-aws.sh --test-only
```

---

### 🏗️ `setup-arrow-cache-kind.sh` - **Cluster Setup Only**
**Sets up just the Kubernetes cluster and Arrow Cache deployment**

```bash
# Basic cluster and deployment setup
./setup-arrow-cache-kind.sh
```

**Note:** This script only sets up the infrastructure. Use `setup-demo.sh` for complete environment including data.

---

### ⚡ `setup-port-forward.sh` - **Port Forwarding**
**Sets up local port forwarding for demo access**

```bash
# Enable local access to Arrow Cache services
./setup-port-forward.sh
```

**Provides access to:**
- Head node: `localhost:50051`
- Worker 0: `localhost:50052`
- Worker 1: `localhost:50053`

---

### 📊 `demo-arrow-cache-status.sh` - **Status Check**
**Shows current status of the Arrow Cache deployment**

```bash
# Check deployment status
./demo-arrow-cache-status.sh
```

---

### 🐍 `demo-arrow-cache-client.py` - **Demo Client**
**Python client for testing the Arrow Cache system**

```bash
# Run full demonstration
python3 demo-arrow-cache-client.py --demo

# Run performance test
python3 demo-arrow-cache-client.py --perf-test

# Custom connection
python3 demo-arrow-cache-client.py --host localhost --port 50051 --demo
```

---

### 🔧 `generate-demo-data.py` - **Data Generation**
**Generates realistic Iceberg demo data**

```bash
# Generate local data
python3 generate-demo-data.py --output /tmp/demo-data --records 10000

# Generate S3 data
python3 generate-demo-data.py --output s3://bucket/demo --records 50000
```

## Quick Start Guide

### 1. **Complete Local Demo**
```bash
# One command for complete setup
./demo/scripts/setup-demo.sh

# Test the system
python3 demo/scripts/demo-arrow-cache-client.py --demo
```

### 2. **S3-Based Demo**
```bash
# Configure AWS credentials first
./demo/scripts/setup-aws.sh --from-cli

# Setup with S3 storage
./demo/scripts/setup-demo.sh --s3-path s3://my-bucket/arrow-cache-demo

# Test the system
python3 demo/scripts/demo-arrow-cache-client.py --demo
```

### 3. **Development Workflow**
```bash
# Build and deploy cluster only
./demo/scripts/setup-demo.sh --cluster-only

# Generate new data as needed
./demo/scripts/setup-demo.sh --data-only --records 25000

# Check status
./demo/scripts/demo-arrow-cache-status.sh
```

## Troubleshooting

### Common Issues

**Port forwarding not working:**
```bash
# Kill existing port forwards and restart
pkill -f "kubectl port-forward.*arrow-cache"
./demo/scripts/setup-port-forward.sh
```

**Pods not starting:**
```bash
# Check logs
kubectl logs -n arrow-cache deployment/arrow-cache-head -f
kubectl logs -n arrow-cache arrow-cache-worker-0 -f

# Restart deployment
kubectl rollout restart deployment/arrow-cache-head -n arrow-cache
```

**AWS credentials issues:**
```bash
# Test credentials
./demo/scripts/setup-aws.sh --test-only

# Reconfigure
./demo/scripts/setup-aws.sh --interactive
```

### Cleanup

```bash
# Delete everything
kind delete cluster --name arrow-cache-demo
pkill -f "kubectl port-forward.*arrow-cache"
```

## Dependencies

- **Required:** Docker, kind, kubectl
- **For data generation:** Python 3, pandas, pyarrow
- **For S3:** AWS CLI, AWS credentials
- **For demo client:** Python 3, pyarrow[flight], grpcio

## Architecture

```
setup-demo.sh (primary)
├── setup-arrow-cache-kind.sh (cluster)
├── generate-demo-data.py (data)
├── setup-aws.sh (credentials)
└── setup-port-forward.sh (access)

demo-arrow-cache-client.py (testing)
demo-arrow-cache-status.sh (monitoring)
```
