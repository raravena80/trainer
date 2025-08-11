# Arrow Cache Demo

This directory contains all files needed for demonstrating the distributed Arrow Cache system.

## Directory Structure

```
demo/
├── README.md                          # This file
├── docs/
│   └── arrow-cache-demo.md            # Complete setup and demo guide
├── manifests/
│   └── arrow-cache/                   # Kubernetes deployment manifests
│       ├── aws-secret.yaml
│       ├── configmap.yaml
│       ├── head-deployment.yaml
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       └── worker-statefulset.yaml
├── scripts/
│   ├── aws-credentials.sh             # AWS credential setup
│   ├── demo-arrow-cache-client.py     # Demo client for testing
│   ├── demo-arrow-cache-status.sh     # Status checking script
│   ├── generate-demo-data.py          # Generate sample data
│   ├── setup-arrow-cache-kind.sh      # Main setup script
│   ├── setup-aws-credentials.sh       # AWS credentials configuration
│   ├── setup-demo-data.sh             # Data generation and configuration
│   ├── setup-working-demo.sh          # Quick working demo setup
│   └── upload-demo-to-s3.sh           # Upload data to S3
├── create_manifest_files.py           # Create Iceberg manifest files
├── create_proper_iceberg_table.py     # Create proper Iceberg table
└── environment.yml                    # Conda environment for demo
```

## Quick Start

1. **Automated Setup**
   ```bash
   ./demo/scripts/setup-arrow-cache-kind.sh
   ```

2. **Configure AWS Credentials**
   ```bash
   ./demo/scripts/setup-aws-credentials.sh
   ```

3. **Check Status**
   ```bash
   ./demo/scripts/demo-arrow-cache-status.sh
   ```

4. **Run Demo**
   ```bash
   python3 demo/scripts/demo-arrow-cache-client.py --demo
   ```

## Files Explained

### Core Scripts
- **setup-arrow-cache-kind.sh**: Main setup script that creates the kind cluster, builds Docker images, and deploys the Arrow Cache system
- **setup-aws-credentials.sh**: Interactive script to configure AWS credentials for S3 access
- **demo-arrow-cache-status.sh**: Shows current status of the deployment with helpful diagnostics
- **demo-arrow-cache-client.py**: Python client that demonstrates the Arrow Cache functionality

### Data Generation
- **generate-demo-data.py**: Creates realistic sample data for testing
- **setup-demo-data.sh**: Generates data and configures Arrow Cache to use it
- **upload-demo-to-s3.sh**: Uploads locally generated data to S3

### Support Scripts
- **setup-working-demo.sh**: Quick setup for a minimal working demo
- **create_manifest_files.py**: Creates minimal Iceberg manifest files
- **create_proper_iceberg_table.py**: Creates proper Iceberg table using pyiceberg

### Configuration
- **manifests/arrow-cache/**: Complete Kubernetes deployment manifests
- **environment.yml**: Conda environment with required dependencies
- **docs/arrow-cache-demo.md**: Comprehensive setup and demonstration guide

## Usage Patterns

### For Development
```bash
# Full setup with custom data
./demo/scripts/setup-arrow-cache-kind.sh
./demo/scripts/setup-demo-data.sh --records 50000 --files 8
./demo/scripts/demo-arrow-cache-status.sh
```

### For Quick Demo
```bash
# Minimal working setup
./demo/scripts/setup-arrow-cache-kind.sh
./demo/scripts/setup-working-demo.sh
```

### For Production-like Testing
```bash
# Use S3 storage
./demo/scripts/setup-arrow-cache-kind.sh
./demo/scripts/generate-demo-data.py --output s3://my-bucket/demo --records 100000
./demo/scripts/upload-demo-to-s3.sh s3://my-bucket/demo
```

## Environment Setup

Create the demo environment:
```bash
conda env create -f demo/environment.yml
conda activate arrow-cache-demo
```

## Troubleshooting

1. **Check pod status**: `kubectl get pods -n arrow-cache`
2. **View logs**: `kubectl logs -n arrow-cache -l app=arrow-cache-head -f`
3. **Verify configuration**: `kubectl get configmap arrow-cache-config -n arrow-cache -o yaml`
4. **Test connectivity**: `./demo/scripts/demo-arrow-cache-status.sh`

## Demo Flow for Presentations

1. **Architecture Overview** (2 mins)
   - Show distributed head-worker model
   - Explain Arrow Flight protocol
   - Kubernetes deployment benefits

2. **Live Setup** (3 mins)
   - Run setup script
   - Show cluster creation
   - Demonstrate automatic configuration

3. **Data Loading** (2 mins)
   - Generate sample data
   - Show file assignment to workers
   - Explain caching strategy

4. **Query Demonstration** (2 mins)
   - Run demo client
   - Show distributed query execution
   - Display performance metrics

5. **Scaling Demo** (1 min)
   - Scale workers live
   - Show automatic load distribution

Total: ~10 minutes for complete demonstration

## Architecture Highlights

- **Distributed Caching**: Head node coordinates multiple worker nodes
- **Apache Arrow Flight**: High-performance data transport protocol
- **Iceberg Integration**: Modern data lake metadata management
- **Kubernetes Native**: Cloud-native deployment with service discovery
- **Horizontal Scaling**: Add workers to increase cache capacity
- **S3 Integration**: Production-ready storage backend support
