# Arrow Cache Shared Library

This directory contains shared functionality used by both IMDB and regular demo clients.

## Files

- `__init__.py` - Python package marker
- `arrow_cache_client.py` - Main shared library module

## Classes

### `BaseArrowCacheClient`

Base class for Arrow Cache demo clients. Provides:

- **Connection management**: Connect to Arrow Cache head node
- **Flight operations**: Get flight info, query workers
- **Worker URI translation**: Kubernetes to localhost port-forward mapping
- **Query coordination**: Distribute queries across workers
- **Performance testing**: Configurable performance test framework

### `S3Utils`

Utility class for S3 operations:

- **File listing**: List parquet files in S3 paths
- **ConfigMap integration**: Get metadata locations from Kubernetes
- **Profile support**: Use different AWS profiles

## Usage

Both demo clients inherit from `BaseArrowCacheClient`:

```python
import sys
import os
sys.path.append(os.path.join(os.path.dirname(__file__), '..', 'lib'))

from arrow_cache_client import BaseArrowCacheClient, S3Utils

class MyDemoClient(BaseArrowCacheClient):
    def __init__(self, host="localhost", port=50051):
        super().__init__(host, port)
        self.namespace = "my-namespace"

    def process_query_result(self, result, description):
        # Override to handle specific data processing
        pass
```

## Key Methods

### Connection
- `connect()` - Connect to head node
- `get_flight_info_for_partition()` - Get worker info for partition

### Query Processing
- `query_workers_for_data()` - Query workers with sample queries
- `process_query_result()` - Override in subclasses for data-specific processing
- `translate_worker_uri()` - Translate Kubernetes URIs to localhost

### Performance Testing
- `run_performance_test()` - Run configurable performance tests

### Utilities
- `S3Utils.list_s3_files()` - List files in S3 path
- `S3Utils.get_metadata_location_from_configmap()` - Get config from Kubernetes

This shared library eliminates code duplication and provides a consistent interface for both demo types.
