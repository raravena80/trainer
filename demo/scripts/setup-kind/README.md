# Kind Cluster Setup for Arrow Cache

This directory provides unified infrastructure setup for creating production-ready Kind clusters with complete IRSA (IAM Roles for Service Accounts) support for all Arrow Cache demos and ML training workflows.

## 🎯 Overview

Creates a comprehensive development environment that supports:
- **All Dataset Types**: Regular, IMDB, Alpaca, and custom datasets
- **IRSA Authentication**: Secure AWS access without hardcoded credentials
- **ML Training Integration**: Full TrainJob CRD and Kubeflow Trainer support
- **Production-like Features**: Multi-node clusters, service accounts, and monitoring

## 📁 Directory Structure

```
setup-kind/
├── README.md                    # This documentation
├── setup-kind-cluster.sh       # Main cluster setup script
├── create-service-accounts.sh  # Service account configuration
└── irsa/                        # Complete IRSA implementation
    ├── README.md               # IRSA-specific documentation
    ├── setup-irsa-kind.sh      # IRSA infrastructure setup
    ├── arrow-cache-example.sh  # Complete demo deployment
    ├── test-irsa.sh            # IRSA validation testing
    └── cleanup-irsa.sh         # Resource cleanup
```

## 🚀 Quick Start

### Option 1: Complete Setup with IRSA (Recommended)
```bash
# Setup Kind cluster with IRSA
./setup-kind-cluster.sh --enable-irsa

# Deploy Arrow Cache for specific dataset
./irsa/arrow-cache-example.sh --demo-type imdb

# Run training
../generic/setup-generic-training.sh \
  --dataset-name imdb \
  --use-arrow-cache \
  --use-irsa
```

### Option 2: Basic Cluster (No AWS)
```bash
# Create basic cluster
./setup-kind-cluster.sh

# Deploy Arrow Cache (uses basic auth)
../regular/setup-arrow-cache.sh
```

## ⚙️ Main Setup Script Features

### `setup-kind-cluster.sh`

**Basic Usage:**
```bash
# Create basic Kind cluster
./setup-kind-cluster.sh

# Create cluster with full IRSA support
./setup-kind-cluster.sh --enable-irsa

# Custom configuration
./setup-kind-cluster.sh \
  --cluster-name my-demo \
  --enable-irsa \
  --aws-region us-west-2 \
  --node-count 4
```

**Cluster Configuration:**
- **Multi-node**: 1 control-plane + 3 worker nodes (configurable)
- **Port Mappings**: Pre-configured for Arrow Cache services (50051, 8080)
- **Resource Limits**: Optimized for ML workloads
- **Networking**: Container networking with service discovery

**IRSA Integration:**
- Automatic OIDC discovery setup with S3 backend
- IAM role creation with S3 and Glue permissions
- Service account creation across all namespaces
- Webhook configuration for pod identity

## 🔐 IRSA (IAM Roles for Service Accounts)

Complete AWS authentication without credentials in containers:

### Features
- **Secure**: No AWS keys in containers or config files
- **Automatic**: Pod-level IAM role assumption
- **Scalable**: Works across all namespaces and datasets
- **Production-Ready**: Same mechanism used in production EKS

### Setup Process
When `--enable-irsa` is used:

1. **OIDC Provider**: Creates S3-backed OIDC discovery endpoint
2. **IAM Role**: Creates `ArrowCacheRole` with required S3/Glue permissions
3. **Trust Policy**: Configures role to trust the cluster OIDC provider
4. **Service Accounts**: Creates annotated service accounts in all namespaces
5. **Webhook**: Deploys pod-identity-webhook for automatic token injection

### Supported Services
- **S3**: Read/write access to data buckets
- **AWS Glue**: Iceberg metadata catalog access
- **STS**: AssumeRole operations
- **CloudWatch**: Optional logging integration

## 🎭 Demo Integration

### Supported Namespaces
The setup creates these namespaces for different use cases:

- **`arrow-cache-demo`**: Primary demo namespace (regular, generic)
- **`arrow-cache-imdb`**: IMDB-specific deployment
- **`arrow-cache-alpaca`**: Alpaca-specific deployment
- **`kubeflow-trainer-system`**: ML training infrastructure

### Complete Demo Workflow
```bash
# 1. Setup infrastructure
./setup-kind-cluster.sh --enable-irsa

# 2. Deploy specific demo type
./irsa/arrow-cache-example.sh --demo-type imdb

# 3. Run ML training
../generic/setup-generic-training.sh \
  --dataset-name imdb \
  --dataset-config ../generic/configs/imdb.yaml \
  --use-arrow-cache \
  --use-irsa \
  --in-cluster

# 4. Monitor training
kubectl get trainjobs -n arrow-cache-demo -w
```

## 🛠️ Helper Scripts

### `create-service-accounts.sh`
Creates service accounts with IAM role annotations:

```bash
# Create service accounts for existing IAM role
./create-service-accounts.sh --role-arn arn:aws:iam::123456789:role/ArrowCacheRole

# Create for specific namespace only
./create-service-accounts.sh \
  --role-arn arn:aws:iam::123456789:role/ArrowCacheRole \
  --namespace arrow-cache-demo
```

### IRSA Validation
```bash
# Test IRSA setup
./irsa/test-irsa.sh

# Validate specific service account
kubectl run irsa-test --rm -i --tty \
  --serviceaccount=arrow-cache-sa \
  --namespace=arrow-cache-demo \
  --image=amazon/aws-cli:latest -- aws sts get-caller-identity
```

## 🔧 Advanced Configuration

### Custom Cluster Options
```bash
# High-resource cluster for large datasets
./setup-kind-cluster.sh \
  --enable-irsa \
  --node-count 6 \
  --cluster-name large-demo

# Development cluster with specific region
./setup-kind-cluster.sh \
  --enable-irsa \
  --aws-region eu-west-1 \
  --cluster-name dev-cluster
```

### Environment Variables
Control setup behavior:
- `CLUSTER_NAME`: Override default cluster name
- `AWS_REGION`: Specify AWS region for IRSA
- `IRSA_ROLE_NAME`: Custom IAM role name
- `SKIP_DOCKER_BUILD`: Skip image building

## 📋 Prerequisites

**Required for Basic Setup:**
- Docker or Lima
- kubectl
- Kind

**Additional for IRSA:**
- AWS CLI (configured with appropriate permissions)
- jq (JSON processor)
- Go (for key generation)
- OpenSSL
- curl

**AWS Permissions Required:**
- IAM role/policy creation
- S3 bucket creation/management
- OIDC provider creation

## 🧹 Cleanup

### Complete Cleanup
```bash
# Delete cluster and all resources
kind delete cluster --name arrow-cache-demo

# Clean up AWS resources (if IRSA was used)
./irsa/cleanup-irsa.sh --cluster-name arrow-cache-demo
```

### Selective Cleanup
```bash
# Only clean up IRSA resources (keep cluster)
./irsa/cleanup-irsa.sh --irsa-only --cluster-name arrow-cache-demo

# Only delete cluster (manual AWS cleanup)
kind delete cluster --name arrow-cache-demo
```

## 🔍 Troubleshooting

### Common Issues

1. **IRSA Setup Fails**
   ```bash
   # Check AWS permissions
   aws sts get-caller-identity
   aws iam list-roles --max-items 5
   ```

2. **Pod Identity Issues**
   ```bash
   # Check webhook deployment
   kubectl get deployment pod-identity-webhook -n kube-system

   # Verify service account annotations
   kubectl get sa arrow-cache-sa -n arrow-cache-demo -o yaml
   ```

3. **Cluster Creation Problems**
   ```bash
   # Check Docker/Lima status
   docker info

   # Verify Kind installation
   kind version
   ```

### Debug Commands
```bash
# Check all Arrow Cache resources
kubectl get all -A -l app.kubernetes.io/name=arrow-cache

# View IRSA-related pods
kubectl get pods -n kube-system -l app=pod-identity-webhook

# Test AWS access from pod
kubectl run aws-test --rm -i --tty \
  --serviceaccount=arrow-cache-sa \
  --namespace=arrow-cache-demo \
  --image=amazon/aws-cli:latest -- aws s3 ls
```

## 🌟 Integration with Existing Workflows

This setup is fully compatible with all existing Arrow Cache scripts:

```bash
# After IRSA setup, use existing scripts with --use-irsa flag
../imdb/setup-imdb-arrow-cache.sh --use-irsa
../alpaca/setup-alpaca-arrow-cache.sh --use-irsa
../regular/setup-arrow-cache.sh --use-irsa

# Or use the generic training system
../generic/setup-generic-training.sh \
  --dataset-name my-dataset \
  --use-arrow-cache \
  --use-irsa
```

This comprehensive setup provides a production-like development environment for exploring distributed ML training with Arrow Cache.
