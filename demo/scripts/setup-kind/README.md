# Kind Cluster Setup for Arrow Cache

This directory contains unified setup scripts for creating Kind clusters that work with all Arrow Cache dataset flavors (regular, imdb, alpaca) and optionally support IRSA (IAM Roles for Service Accounts).

## Scripts

### `setup-kind-cluster.sh`

Main script for creating Kind clusters with optional IRSA support.

**Basic Usage:**
```bash
# Create basic kind cluster
./setup-kind-cluster.sh

# Create cluster with IRSA support
./setup-kind-cluster.sh --enable-irsa

# Custom cluster name with IRSA
./setup-kind-cluster.sh --cluster-name my-demo --enable-irsa --aws-region us-west-2
```

**Features:**
- Creates a 4-node Kind cluster (1 control-plane, 3 workers)
- Configures port mappings for Arrow Cache services
- Optionally sets up IRSA with S3-based OIDC discovery
- Pre-creates namespaces and service accounts for all dataset types
- Compatible with existing Arrow Cache setup scripts

### `create-service-accounts.sh`

Helper script for creating service accounts with IAM role annotations across all Arrow Cache namespaces.

**Usage:**
```bash
./create-service-accounts.sh --role-arn arn:aws:iam::120832439621:role/ArrowCacheRole
```

## Supported Namespaces

The setup automatically configures these namespaces for different dataset types:

- `arrow-cache` - Regular demo
- `arrow-cache-imdb` - IMDB demo
- `arrow-cache-demo` - Alpaca demo

## IRSA Integration

When `--enable-irsa` is used, the script:

1. Calls the existing `irsa-kind-setup/setup-irsa-kind.sh`
2. Creates a shared IAM role `ArrowCacheRole` with S3 permissions
3. Creates service accounts in all namespaces with proper annotations
4. Saves configuration for later use

## Usage with Existing Scripts

After running the unified setup, use existing demo scripts as before:

```bash
# Regular demo
cd ../regular/
./setup-arrow-cache.sh --iam-role arn:aws:iam::ACCOUNT_ID:role/ArrowCacheRole

# IMDB demo
cd ../imdb/
./setup-imdb-arrow-cache.sh --iam-role arn:aws:iam::ACCOUNT_ID:role/ArrowCacheRole

# Alpaca demo
cd ../alpaca/
./setup-alpaca-arrow-cache.sh --iam-role arn:aws:iam::ACCOUNT_ID:role/ArrowCacheRole
```

## Migration from Existing Setup

This setup is designed to be compatible with existing scripts. You can:

1. Continue using the old `../setup-kind-cluster.sh` for basic clusters
2. Use the new `./setup-kind-cluster.sh` for enhanced features
3. Gradually migrate to the unified approach

## File Structure

```
setup-kind/
├── README.md                    # This file
├── setup-kind-cluster.sh       # Main cluster setup script
└── create-service-accounts.sh  # Service account helper script
```

## Dependencies

- `kubectl` - Kubernetes command-line tool
- `kind` - Kubernetes IN Docker
- `docker` - Container runtime

For IRSA support, additionally requires:
- `aws` - AWS CLI
- `jq` - JSON processor
- `go` - Go programming language
- `openssl` - SSL/TLS toolkit
- `curl` - HTTP client

## Cleanup

```bash
# Delete cluster
kind delete cluster --name arrow-cache-demo

# Clean up AWS resources (if IRSA was used)
../irsa-kind-setup/cleanup-irsa.sh --cluster-config ../irsa-kind-setup/cluster-info-arrow-cache-demo.env
```
