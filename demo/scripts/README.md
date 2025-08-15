# Arrow Cache Demo Scripts

This directory contains demo scripts for the distributed Arrow Cache system organized by demo type.

## Directory Structure

```
scripts/
├── imdb/           # IMDB movie review demo
├── regular/        # Regular demo with synthetic data
├── lib/            # Shared library code
└── README.md       # This file
```

## Quick Start

### IMDB Demo (Real Data)
```bash
# Deploy
cd imdb/
./deploy-imdb-arrow-cache.sh

# Port forward
./port-forward-imdb-arrow-cache.sh &

# Run demo
python3 demo-client.py --demo
```

### Regular Demo (Synthetic Data)
```bash
# Deploy
cd regular/
./setup-demo.sh

# Port forward
./setup-port-forward.sh &

# Run demo
python3 demo-client.py --demo
```

## Shared Library

The `lib/` directory contains shared functionality:
- `BaseArrowCacheClient` - Common client operations
- `S3Utils` - S3 file operations
- Flight operations and worker URI translation

Both demo clients inherit from `BaseArrowCacheClient` to avoid code duplication.

## Files Overview

### IMDB Directory (`imdb/`)
- `demo-client.py` - IMDB-specific demo client
- `deploy-imdb-arrow-cache.sh` - Deploy IMDB demo
- `port-forward-imdb-arrow-cache.sh` - Port forwarding
- `cleanup-imdb-arrow-cache.sh` - Cleanup resources
- `ingest_imdb_to_iceberg.py` - Data ingestion script

### Regular Directory (`regular/`)
- `demo-client.py` - Regular demo client
- `demo-arrow-cache-client.py` - Original client (legacy)
- `setup-demo.sh` - Deploy regular demo
- `setup-port-forward.sh` - Port forwarding
- `generate-demo-data.py` - Synthetic data generation
- Other setup and utility scripts

### Library Directory (`lib/`)
- `__init__.py` - Python package marker
- `arrow_cache_client.py` - Shared client functionality

## Migration Notes

- Old clients are preserved for compatibility
- New clients use the shared library for cleaner code
- File paths updated to reflect new structure
- Both demo types can coexist independently

## Prerequisites

- Docker
- kubectl
- kind
- Python 3.8+ with pyarrow, grpcio, pandas
- AWS CLI configured

## Detailed Documentation

- See `README-IMDB.md` in the root demo directory for IMDB demo details
- See individual script files for specific usage instructions
