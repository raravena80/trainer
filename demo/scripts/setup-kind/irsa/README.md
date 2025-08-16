# IRSA (IAM Roles for Service Accounts) for Kind Clusters

This directory contains scripts to enable IRSA functionality in local kind clusters, making it possible to use AWS IAM roles with Kubernetes service accounts just like in Amazon EKS.

## What This Solves

By default, IAM roles for service accounts only work in Amazon EKS clusters. This toolkit allows you to:
- Use IAM roles in local kind clusters for development/testing
- Test IRSA configurations before deploying to EKS
- Develop applications that use IRSA without needing an EKS cluster

## How It Works

1. **Creates an OIDC Provider**: Sets up an S3-hosted OIDC discovery endpoint
2. **Configures Kind Cluster**: Modifies the API server to use custom service account keys
3. **Installs Pod Identity Webhook**: Deploys the same webhook that EKS uses
4. **Creates IAM Roles**: Sets up roles with proper trust policies for OIDC federation

## Files

- `setup-irsa-kind.sh` - Main setup script for IRSA-enabled kind cluster
- `create-irsa-role.sh` - Helper script to create IAM roles for specific service accounts
- `cleanup-irsa.sh` - Cleanup script to remove AWS resources
- `templates/` - Configuration templates for AWS and Kubernetes resources
- `lib/` - Shared library functions

## Prerequisites

- `kubectl`
- `aws-cli` (configured with credentials)
- `jq`
- `go`
- `kind`
- `openssl`

## Quick Start

```bash
# Create an IRSA-enabled kind cluster
./setup-irsa-kind.sh --cluster-name arrow-cache-demo

# Create an IAM role for your Arrow Cache service account
./create-irsa-role.sh \
  --role-name ArrowCacheRole \
  --namespace arrow-cache-imdb \
  --service-account aws-service-account \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

# Your existing Arrow Cache setup scripts can now use --iam-role!
```

## Integration with Arrow Cache Demos

Once you have an IRSA-enabled cluster, your existing demo scripts work with IAM roles:

```bash
# IMDB demo with IRSA
./setup-imdb-arrow-cache.sh --iam-role arn:aws:iam::ACCOUNT:role/ArrowCacheRole

# Regular demo with IRSA
./setup-arrow-cache.sh --s3-path s3://bucket/data --iam-role arn:aws:iam::ACCOUNT:role/ArrowCacheRole
```

## Cleanup

```bash
# Clean up AWS resources (S3 buckets, IAM roles, OIDC provider)
./cleanup-irsa.sh --cluster-name arrow-cache-demo
```

## Cost Considerations

- Creates two S3 buckets (minimal cost for discovery endpoint)
- IAM resources have no cost
- Bucket and role names include timestamps to avoid conflicts

## Credits

Based on the excellent work from [amazon-eks-pod-identity-webhook](https://github.com/aws/amazon-eks-pod-identity-webhook) and the example at `kind-aws-irsa-example/`.
