# Regular Arrow Cache Demo

This directory contains the regular Arrow Cache demo using synthetic data.

## Quick Start

```bash
# Complete setup
./setup-arrow-cache.sh

# Run the demo
python3 demo-client.py --demo

# Run performance test
python3 demo-client.py --perf-test --queries 10

# Check status
./demo-arrow-cache-status.sh
```

## Setup Options

The `setup-arrow-cache.sh` script provides a complete environment setup:

```bash
# Complete setup with local data
./setup-arrow-cache.sh

# Setup with S3 storage
./setup-arrow-cache.sh --s3-path s3://my-bucket/demo-data

# Only cluster and cache setup (no data generation)
./setup-arrow-cache.sh --cluster-only

# Only data generation
./setup-arrow-cache.sh --data-only --records 50000

# Only cache deployment (assumes cluster exists)
./setup-arrow-cache.sh --cache-only

# Skip Docker image build (use existing image)
./setup-arrow-cache.sh --no-build

# Skip port forwarding setup
./setup-arrow-cache.sh --no-port-forward

# Custom data configuration
./setup-arrow-cache.sh --records 25000 --files 8
```

## Files

- `setup-arrow-cache.sh` - Complete environment setup
- `demo-client.py` - Demo client using shared library
- `demo-arrow-cache-status.sh` - Status checker
- `generate-demo-data.py` - Synthetic data generation
- `setup-aws.sh` - AWS credentials configuration

## Dataset Details

- **Source**: Synthetic data generated programmatically
- **Records**: Configurable (default ~1,000 for demo)
- **Schema**: `id`, `text`, `label`, `score`, `metadata`
- **Purpose**: Testing and development

## Usage

The `demo-client.py` uses the shared library:

```python
from arrow_cache_client import BaseArrowCacheClient, S3Utils

class RegularArrowCacheClient(BaseArrowCacheClient):
    # Regular demo functionality
```
