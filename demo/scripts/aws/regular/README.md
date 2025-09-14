# Regular Arrow Cache Demo

This directory contains the foundational Arrow Cache demo using synthetic data. This is the simplest demo type, ideal for understanding the basic Arrow Cache functionality before exploring real datasets.

## 🎯 Purpose

- **Learning**: Understand Arrow Cache basics without dataset complexity
- **Testing**: Validate Arrow Cache functionality and performance
- **Development**: Foundation for building custom demos
- **Debugging**: Isolate Arrow Cache issues from dataset complications

## 🚀 Quick Start

### Basic Demo
```bash
# Complete setup with synthetic data
./setup-arrow-cache.sh

# Test Arrow Cache connectivity
python3 demo-client.py --demo

# Run performance testing
python3 demo-client.py --performance --queries 20

# Check system status
./demo-arrow-cache-status.sh
```

### With Generic Training System
```bash
# Use regular demo with generic training
../generic/setup-generic-training.sh \
  --dataset-name regular \
  --dataset-config ../generic/configs/regular.yaml \
  --use-arrow-cache \
  --max-samples 500
```

## ⚙️ Setup Options

The `setup-arrow-cache.sh` script provides flexible configuration:

```bash
# Complete setup with default synthetic data
./setup-arrow-cache.sh

# Custom data generation
./setup-arrow-cache.sh --records 10000 --files 4

# Use existing Kind cluster
./setup-arrow-cache.sh --cluster-only

# Only generate data (cluster exists)
./setup-arrow-cache.sh --data-only --records 50000

# Only deploy cache (cluster and data exist)
./setup-arrow-cache.sh --cache-only

# Skip Docker build (use existing image)
./setup-arrow-cache.sh --no-build

# Setup with IRSA authentication
./setup-arrow-cache.sh --use-irsa

# Custom S3 storage backend
./setup-arrow-cache.sh --s3-path s3://my-bucket/demo-data
```

## 📁 Files Overview

### Core Scripts
- **`setup-arrow-cache.sh`** - Complete environment setup and deployment
- **`demo-client.py`** - Demo client using shared library for testing connectivity
- **`demo-arrow-cache-status.sh`** - Comprehensive status checker and diagnostics

### Data Generation
- **`generate-demo-data.py`** - Synthetic dataset creation with configurable parameters

### Configuration
- **`setup-aws.sh`** - AWS credentials configuration for S3 access
- **`setup-port-forward.sh`** - Port forwarding setup for local access

## 📊 Dataset Details

### Synthetic Data Schema
- **`id`**: Unique record identifier
- **`text`**: Generated text content (for ML training)
- **`label`**: Classification labels (0 or 1)
- **`score`**: Floating-point scores (0.0 to 1.0)
- **`metadata`**: JSON metadata with additional fields

### Generation Parameters
- **Records**: Configurable (default: 1,000 for quick demos)
- **Files**: Configurable partitioning (default: 2 files)
- **Schema**: Consistent with real ML datasets
- **Format**: Parquet with Iceberg metadata

## 🔧 Client Usage

The `demo-client.py` extends the shared base client:

```python
import sys
import os
sys.path.append(os.path.join(os.path.dirname(__file__), '..', 'lib'))

from arrow_cache_client import BaseArrowCacheClient, S3Utils

class RegularArrowCacheClient(BaseArrowCacheClient):
    def __init__(self, host="localhost", port=50051):
        super().__init__(host, port)
        self.namespace = "arrow-cache-demo"

    def process_query_result(self, result, description):
        # Process regular demo results
        print(f"Regular demo result: {len(result)} rows")
```

### Available Commands
```bash
# Basic connectivity test
python3 demo-client.py --demo

# Performance benchmarking
python3 demo-client.py --performance --queries 50

# Specific query testing
python3 demo-client.py --query --start-row 0 --end-row 100

# Worker status checking
python3 demo-client.py --status
```

## 🎭 Integration with Other Systems

### With Generic Training
Use the regular demo as a data source for generic training:

```bash
# Create regular dataset config if it doesn't exist
cp ../generic/configs/custom-template.yaml ../generic/configs/regular.yaml
# Edit regular.yaml to point to your synthetic data

# Run training with regular data
../generic/setup-generic-training.sh \
  --dataset-name regular \
  --dataset-config ../generic/configs/regular.yaml \
  --use-arrow-cache
```

### With IRSA Setup
Use with IRSA for production-like authentication:

```bash
# Setup IRSA first
../setup-kind/irsa/arrow-cache-example.sh --demo-type regular

# Then run regular demo
./setup-arrow-cache.sh --use-irsa
```

## 🔍 Troubleshooting

### Common Issues
1. **Port conflicts**: Check if port 50051 is in use
2. **Kind cluster**: Ensure Docker/Lima is running
3. **Data generation**: Verify write permissions for local data
4. **AWS credentials**: Required for S3 backends

### Debug Commands
```bash
# Check Arrow Cache pods
kubectl get pods -n arrow-cache-demo

# View head node logs
kubectl logs -n arrow-cache-demo -l app=arrow-cache-head -f

# Check configmap
kubectl get configmap arrow-cache-config -n arrow-cache-demo -o yaml

# Test port forwarding
telnet localhost 50051
```

## 📈 Performance Testing

The regular demo provides baseline performance metrics:

```bash
# Quick performance test
python3 demo-client.py --performance --queries 10

# Extended performance test
python3 demo-client.py --performance --queries 100 --concurrent 5

# Latency testing
python3 demo-client.py --latency-test --iterations 50
```

## 🎪 Demo Integration

The regular demo serves as the foundation for other demos:

- **IMDB Demo**: Builds on regular demo patterns with real movie data
- **Alpaca Demo**: Uses regular demo infrastructure with instruction data
- **Generic System**: Uses regular demo as the default configuration

This makes the regular demo the best starting point for understanding the complete Arrow Cache ecosystem.
