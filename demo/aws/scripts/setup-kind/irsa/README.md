# IRSA (IAM Roles for Service Accounts) for Kind Clusters

This directory provides a complete IRSA implementation for local Kind clusters, enabling production-like AWS authentication without hardcoded credentials. This is essential for secure Arrow Cache demos and ML training workflows.

## 🎯 What This Solves

**Production-Grade Development**:
- Use AWS IAM roles in local Kind clusters exactly like EKS
- Test IRSA configurations before production deployment
- Secure access to S3, Glue, and other AWS services without credential files
- Complete integration with Kubeflow Trainer and Arrow Cache systems

**Development Benefits**:
- No AWS credentials in containers or config files
- Automatic pod-level IAM role assumption
- Same security model as production EKS clusters
- Support for multiple namespaces and service accounts

## 🏗️ Architecture Overview

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Kind Cluster  │    │  OIDC Provider  │    │   IAM Roles     │
│                 │    │    (S3-hosted)  │    │                 │
│  ┌────────────┐ │    │  ┌────────────┐ │    │  ┌────────────┐ │
│  │    Pod     │ │───▶│  │ Discovery  │ │───▶│  │Arrow Cache │ │
│  │  + Token   │ │    │  │ Document   │ │    │  │    Role    │ │
│  └────────────┘ │    │  └────────────┘ │    │  └────────────┘ │
│        │        │    └─────────────────┘    └─────────────────┘
│        ▼        │                                     │
│  ┌────────────┐ │                                     ▼
│  │Pod Identity│ │                              ┌─────────────────┐
│  │  Webhook   │ │                              │  AWS Services   │
│  └────────────┘ │                              │  (S3, Glue,     │
└─────────────────┘                              │   CloudWatch)   │
                                                 └─────────────────┘
```

## 📁 Directory Structure

```
irsa/
├── README.md                    # This documentation
├── setup-irsa-kind.sh          # Main IRSA infrastructure setup
├── arrow-cache-example.sh      # Complete demo deployment with IRSA
├── create-irsa-role.sh          # IAM role creation helper
├── test-irsa.sh                 # IRSA validation and testing
├── cleanup-irsa.sh             # Complete resource cleanup
├── templates/                   # Configuration templates
│   ├── aws/                    # AWS resource templates
│   └── kind/                   # Kind cluster templates
├── keys/                        # RSA key pairs for OIDC
├── lib/                        # Shared functions
└── pod-identity-webhook/       # Webhook deployment manifests
```

## 🚀 Quick Start

### Option 1: Complete Demo Setup (Recommended)
```bash
# Complete setup with IRSA + Arrow Cache deployment
./arrow-cache-example.sh --demo-type imdb

# This single command:
# 1. Creates IRSA-enabled Kind cluster
# 2. Sets up OIDC provider and IAM roles
# 3. Deploys Arrow Cache for IMDB dataset
# 4. Configures all authentication
```

### Option 2: Step-by-Step Setup
```bash
# 1. Create IRSA infrastructure
./setup-irsa-kind.sh --cluster-name arrow-cache-demo

# 2. Create IAM role for specific service account
./create-irsa-role.sh \
  --role-name ArrowCacheRole \
  --namespace arrow-cache-demo \
  --service-account arrow-cache-sa

# 3. Test IRSA setup
./test-irsa.sh

# 4. Deploy Arrow Cache with IRSA
../imdb/setup-imdb-arrow-cache.sh --use-irsa
```

## ⚙️ Core Scripts

### `setup-irsa-kind.sh` - Infrastructure Setup
Creates complete IRSA infrastructure:

**Features:**
- OIDC discovery endpoint with S3 backend
- Kind cluster with custom service account keys
- Pod identity webhook deployment
- Multi-namespace service account creation

**Usage:**
```bash
# Basic IRSA setup
./setup-irsa-kind.sh --cluster-name arrow-cache-demo

# Custom configuration
./setup-irsa-kind.sh \
  --cluster-name my-cluster \
  --aws-region us-west-2 \
  --role-name CustomRole
```

### `arrow-cache-example.sh` - Complete Demo Deployment
One-command deployment of IRSA + Arrow Cache:

**Usage:**
```bash
# Deploy IMDB demo with IRSA
./arrow-cache-example.sh --demo-type imdb

# Deploy Alpaca demo with IRSA
./arrow-cache-example.sh --demo-type alpaca

# Deploy regular demo with IRSA
./arrow-cache-example.sh --demo-type regular
```

**What it does:**
1. **Infrastructure**: Creates IRSA-enabled Kind cluster
2. **Authentication**: Sets up IAM roles and OIDC provider
3. **Deployment**: Deploys Arrow Cache for specified dataset
4. **Validation**: Tests IRSA functionality and Arrow Cache connectivity

### `create-irsa-role.sh` - IAM Role Management
Creates IAM roles with proper trust policies:

```bash
# Create role with S3 and Glue access
./create-irsa-role.sh \
  --role-name ArrowCacheRole \
  --namespace arrow-cache-demo \
  --service-account arrow-cache-sa

# Create role with custom policies
./create-irsa-role.sh \
  --role-name CustomRole \
  --namespace my-namespace \
  --service-account my-sa \
  --policy-arn arn:aws:iam::aws:policy/CustomPolicy
```

### `test-irsa.sh` - Validation and Testing
Comprehensive IRSA validation:

```bash
# Test IRSA setup
./test-irsa.sh

# Test specific service account
./test-irsa.sh --namespace arrow-cache-demo --service-account arrow-cache-sa

# Verify AWS access
./test-irsa.sh --verify-aws-access
```

## 🔐 AWS Permissions and Security

### Required AWS Permissions
Your AWS credentials need the following permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:CreatePolicy",
        "iam:AttachRolePolicy",
        "iam:CreateOpenIDConnectProvider",
        "s3:CreateBucket",
        "s3:PutObject",
        "s3:PutBucketPolicy",
        "s3:PutBucketPublicAccessBlock"
      ],
      "Resource": "*"
    }
  ]
}
```

### Created AWS Resources
Each IRSA setup creates:

- **OIDC Provider**: For cluster identity federation
- **IAM Role**: `ArrowCacheRole` with S3/Glue permissions
- **S3 Buckets**: OIDC discovery endpoint and keys storage
- **IAM Policies**: Fine-grained permissions for Arrow Cache

### Security Features
- **No Hardcoded Credentials**: Tokens are automatically injected
- **Temporary Credentials**: AWS STS tokens with limited lifetime
- **Least Privilege**: Role permissions scoped to specific resources
- **Audit Trail**: All AWS API calls logged via CloudTrail

## 🎭 Integration with Arrow Cache Demos

### Generic Training System
```bash
# Setup IRSA then use generic training
./arrow-cache-example.sh --demo-type regular
../generic/setup-generic-training.sh \
  --dataset-name imdb \
  --use-arrow-cache \
  --use-irsa
```

### Dataset-Specific Demos
```bash
# IMDB with IRSA
./arrow-cache-example.sh --demo-type imdb
python3 ../imdb/imdb_training.py --use-arrow-cache --use-irsa

# Alpaca with IRSA
./arrow-cache-example.sh --demo-type alpaca
python3 ../alpaca/alpaca_training.py --use-arrow-cache --use-irsa
```

### Custom Datasets
```bash
# Setup IRSA infrastructure
./setup-irsa-kind.sh --cluster-name my-demo

# Create role for custom namespace
./create-irsa-role.sh \
  --role-name MyRole \
  --namespace my-namespace \
  --service-account my-sa

# Use with any script that supports --use-irsa
```

## 🔍 Troubleshooting

### Common Issues and Solutions

**1. OIDC Provider Creation Fails**
```bash
# Check AWS permissions
aws iam list-open-id-connect-providers

# Verify S3 bucket access
aws s3 ls s3://arrow-cache-oidc-$(date +%s)
```

**2. Pod Identity Webhook Issues**
```bash
# Check webhook deployment
kubectl get deployment pod-identity-webhook -n kube-system

# View webhook logs
kubectl logs -n kube-system -l app=pod-identity-webhook
```

**3. Service Account Token Issues**
```bash
# Verify service account annotations
kubectl get sa arrow-cache-sa -n arrow-cache-demo -o yaml

# Check token injection
kubectl describe pod <pod-name> -n arrow-cache-demo
```

### Diagnostic Commands
```bash
# Test AWS access from pod
kubectl run irsa-test --rm -i --tty \
  --serviceaccount=arrow-cache-sa \
  --namespace=arrow-cache-demo \
  --image=amazon/aws-cli:latest -- aws sts get-caller-identity

# Check OIDC configuration
curl -s $(kubectl get configmap cluster-info -n kube-system -o jsonpath='{.data.issuer-url}')/.well-known/openid_configuration

# Verify IAM role trust policy
aws iam get-role --role-name ArrowCacheRole --query Role.AssumeRolePolicyDocument
```

## 🧹 Cleanup

### Complete Cleanup
```bash
# Remove all AWS resources and cluster
./cleanup-irsa.sh --cluster-name arrow-cache-demo

# This removes:
# - Kind cluster
# - IAM roles and policies
# - OIDC provider
# - S3 buckets
# - All associated resources
```

### Selective Cleanup
```bash
# Only AWS resources (keep cluster)
./cleanup-irsa.sh --cluster-name arrow-cache-demo --aws-only

# Only cluster (manual AWS cleanup)
kind delete cluster --name arrow-cache-demo
```

## 💡 Advanced Usage

### Multiple Roles per Cluster
```bash
# Create different roles for different workflows
./create-irsa-role.sh --role-name DataRole --namespace data --service-account data-sa
./create-irsa-role.sh --role-name MLRole --namespace ml --service-account ml-sa
./create-irsa-role.sh --role-name AdminRole --namespace admin --service-account admin-sa
```

### Custom Policies
```bash
# Create role with custom inline policy
./create-irsa-role.sh \
  --role-name CustomRole \
  --namespace my-namespace \
  --service-account my-sa \
  --inline-policy-document file://my-policy.json
```

### Environment Variables
Control behavior with environment variables:
- `AWS_REGION`: AWS region for resources
- `CLUSTER_NAME`: Override cluster name
- `IRSA_ROLE_NAME`: Custom role name
- `SKIP_CLUSTER_CREATE`: Use existing cluster

## 🌟 Production Considerations

When moving to production EKS:

1. **Same Service Accounts**: Use identical service account names and namespaces
2. **Same IAM Policies**: Transfer IAM roles and policies directly
3. **Same Code**: Application code works unchanged
4. **EKS OIDC**: Replace S3 OIDC with native EKS OIDC provider

This IRSA implementation provides a production-identical development experience for secure cloud-native ML workflows.
