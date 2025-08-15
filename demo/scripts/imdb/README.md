# IMDB Arrow Cache Demo

This directory contains the IMDB movie review demo using real data from an Apache Iceberg table.

## Quick Start

```bash
# Deploy the IMDB demo
./deploy-imdb-arrow-cache.sh

# Set up port forwarding (in another terminal)
./port-forward-imdb-arrow-cache.sh

# Run the demo
python3 demo-client.py --demo

# Run performance test
python3 demo-client.py --perf-test --queries 10

# Clean up
./cleanup-imdb-arrow-cache.sh
```

## Files

- `demo-client.py` - IMDB demo client using shared library
- `demo-imdb-arrow-cache-client.py` - Original standalone client (legacy)
- `deploy-imdb-arrow-cache.sh` - Deploy IMDB demo to Kubernetes
- `port-forward-imdb-arrow-cache.sh` - Set up port forwarding
- `cleanup-imdb-arrow-cache.sh` - Clean up all resources
- `ingest_imdb_to_iceberg.py` - Ingest raw parquet files to Iceberg

## Dataset Details

- **Source**: IMDB movie reviews from HuggingFace
- **Records**: ~100,000 movie reviews
- **Schema**: `text` (string), `label` (int64)
- **Labels**: 0=negative review, 1=positive review
- **Storage**: S3 Iceberg table at `s3://ricardo.hf.datasets/iceberg/hf_datasets.db/imdb_reviews/`

## Prerequisites

- Docker and kind cluster
- AWS profile `root-ricardo` configured
- Python with pyarrow, grpcio, pandas
- kubectl access to Kubernetes cluster

## Usage

The new `demo-client.py` uses the shared library from `../lib/` for cleaner code:

```python
from arrow_cache_client import BaseArrowCacheClient, S3Utils

class IMDBArrowCacheClient(BaseArrowCacheClient):
    # IMDB-specific functionality
```

See the main demo README (`../../README-IMDB.md`) for complete documentation.
