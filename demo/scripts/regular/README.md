# Regular Arrow Cache Demo

This directory contains the regular Arrow Cache demo using synthetic data.

## Quick Start

```bash
# Deploy the regular demo
./setup-demo.sh

# Set up port forwarding
./setup-port-forward.sh &

# Run the demo
python3 demo-client.py --demo

# Run performance test
python3 demo-client.py --perf-test --queries 10

# Check status
./demo-arrow-cache-status.sh
```

## Files

### New Refactored Files
- `demo-client.py` - Regular demo client using shared library

### Legacy Files (Preserved)
- `demo-arrow-cache-client.py` - Original standalone client
- `setup-demo.sh` - Complete demo environment setup
- `setup-port-forward.sh` - Port forwarding setup
- `setup-arrow-cache-kind.sh` - Cluster setup only
- `setup-aws.sh` - AWS credentials configuration
- `demo-arrow-cache-status.sh` - Status checker
- `generate-demo-data.py` - Synthetic data generation

## Dataset Details

- **Source**: Synthetic data generated programmatically
- **Records**: Configurable (default ~1,000 for demo)
- **Schema**: `id`, `text`, `label`, `score`, `metadata`
- **Purpose**: Testing and development

## Usage

The new `demo-client.py` uses the shared library:

```python
from arrow_cache_client import BaseArrowCacheClient, S3Utils

class RegularArrowCacheClient(BaseArrowCacheClient):
    # Regular demo functionality
```

## Legacy Setup

The original setup scripts are preserved and continue to work:

```bash
# Complete setup with local data
./setup-demo.sh

# Setup with S3 storage
./setup-demo.sh --s3-path s3://my-bucket/demo-data

# Only cluster setup
./setup-demo.sh --cluster-only
```

See individual script files for detailed usage instructions.
