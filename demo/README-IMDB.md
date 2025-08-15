# IMDB Arrow Cache Demo

This demo showcases the distributed Arrow Cache system using real IMDB movie review data stored in an Apache Iceberg table on S3.

## Overview

- **Dataset**: IMDB Movie Reviews (~100,000 reviews)
- **Schema**:
  - `text` (string): Movie review text
  - `label` (int64): Sentiment label (0=negative, 1=positive)
- **Storage**: Apache Iceberg table in S3 (`s3://ricardo.hf.datasets/`)
- **Architecture**: Distributed cache with head node + 2 worker nodes

## Dataset Details

The IMDB dataset can be created using the complete ingestion script:

```bash
# From the scripts/imdb/ directory
python3 ingest_imdb_to_iceberg.py
```

**New One-Step Process:** This script handles everything - downloads from HuggingFace, creates S3/Glue resources, and ingests directly into Iceberg.

This created an Iceberg table with the following structure:
- **Database**: `hf_datasets`
- **Table**: `imdb_reviews`
- **Location**: `s3://ricardo.hf.datasets/iceberg/hf_datasets.db/imdb_reviews/`
- **Data Files**: 3 Parquet files (~56MB total)
  - Train split: 25,000 reviews
  - Test split: 25,000 reviews
  - Unsupervised split: 50,000 reviews

## Prerequisites

### Required Tools
- Docker
- kubectl
- kind (Kubernetes in Docker)
- Python 3.8+ with required packages
- AWS CLI configured with profile `root-ricardo`

### Python Dependencies
```bash
pip install pyarrow grpcio boto3 pyiceberg pandas
```

### AWS Setup
Make sure you have AWS credentials configured for the `root-ricardo` profile:
```bash
aws configure --profile root-ricardo
# Verify access to the S3 bucket:
aws s3 ls s3://ricardo.hf.datasets/ --profile root-ricardo
```

## Quick Start

### 1. Deploy the Demo

```bash
# From the trainer/demo/scripts directory
./deploy-imdb-arrow-cache.sh
```

This script will:
- ✅ Verify prerequisites (kubectl, kind, Docker image, AWS credentials)
- 📦 Load the Docker image into the kind cluster
- 🚢 Deploy all Kubernetes resources
- ⏳ Wait for all pods to be ready
- 📊 Show deployment status

### 2. Set Up Port Forwarding

```bash
./port-forward-imdb-arrow-cache.sh
```

This creates local access to:
- **Head Service**: `localhost:50051`
- **Worker-0**: `localhost:50052`
- **Worker-1**: `localhost:50053`

### 3. Run the Demo Client

```bash
python3 demo-imdb-arrow-cache-client.py --demo
```

This will demonstrate:
- 🔌 Connecting to the head node
- 📊 Querying partition information
- 🎬 Retrieving actual IMDB movie reviews
- 📈 Showing sentiment distribution
- 🔄 Distributed caching across workers

### 4. Performance Testing

```bash
python3 demo-imdb-arrow-cache-client.py --perf-test --queries 10
```

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Client        │    │   Head Node     │    │   Worker-0      │
│  (localhost)    │────│  (port 50051)   │────│  (port 50052)   │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                │                        │
                                │               ┌─────────────────┐
                                └───────────────│   Worker-1      │
                                                │  (port 50053)   │
                                                └─────────────────┘
                                │
                        ┌─────────────────┐
                        │   S3 Iceberg    │
                        │     Table       │
                        └─────────────────┘
```

## Configuration

The demo uses a dedicated namespace `arrow-cache-imdb` with configuration pointing to:

- **Metadata Location**: `s3://ricardo.hf.datasets/iceberg/hf_datasets.db/imdb_reviews/metadata/00003-132588d1-594d-4b12-99b1-d912667bba51.metadata.json`
- **Table**: `hf_datasets.imdb_reviews`
- **AWS Region**: `us-east-1`
- **Workers**: 2 StatefulSet replicas

## Monitoring

### View Logs
```bash
# Head node logs
kubectl logs -f -n arrow-cache-imdb deployment/arrow-cache-head

# Worker logs
kubectl logs -f -n arrow-cache-imdb statefulset/arrow-cache-worker
```

### Check Pod Status
```bash
kubectl get pods -n arrow-cache-imdb
kubectl describe pod -n arrow-cache-imdb <pod-name>
```

### View Configuration
```bash
kubectl get configmap -n arrow-cache-imdb arrow-cache-config -o yaml
```

## Troubleshooting

### Common Issues

1. **Pods not starting**
   ```bash
   kubectl describe pod -n arrow-cache-imdb <pod-name>
   kubectl logs -n arrow-cache-imdb <pod-name>
   ```

2. **AWS credentials issues**
   ```bash
   # Verify AWS profile
   aws configure list --profile root-ricardo
   # Test S3 access
   aws s3 ls s3://ricardo.hf.datasets/iceberg/ --profile root-ricardo
   ```

3. **Docker image not found**
   ```bash
   # From trainer project root, build the image:
   docker build -t arrow-cache-demo:latest .
   # Load into kind cluster:
   kind load docker-image arrow-cache-demo:latest --name arrow-cache-demo
   ```

4. **Port forwarding issues**
   ```bash
   # Stop existing port forwards
   pkill -f "kubectl port-forward.*arrow-cache-imdb"
   # Restart port forwarding
   ./port-forward-imdb-arrow-cache.sh
   ```

## Sample Output

When running the demo client, you should see output like:

```
INFO - Starting IMDB Arrow Cache demonstration...
INFO - === IMDB Dataset Overview ===
INFO - Dataset: IMDB Movie Reviews
INFO - Schema: text (string), label (int64)
INFO - Labels: 0=negative review, 1=positive review
INFO - Total records: ~100,000 movie reviews
INFO - Found 3 IMDB data files:
INFO -   1. s3://ricardo.hf.datasets/iceberg/hf_datasets.db/imdb_reviews/data/00000-0-f1331eba...
INFO - === Step 1: Getting partition information from head node ===
INFO - Getting flight info for partition 0
INFO - Received flight info with 1 endpoints
INFO - === Step 2: Querying IMDB review data from workers ===
INFO - Successfully retrieved 1000 IMDB reviews from partition 0
INFO - === Sample IMDB Reviews ===
INFO - Review 1 (Positive): This movie was absolutely fantastic! The acting was superb...
INFO - Review 2 (Negative): What a waste of time. The plot made no sense and the characters...
INFO - Label distribution in this partition:
INFO -   Negative (0): 502 reviews
INFO -   Positive (1): 498 reviews
```

## Cleanup

```bash
./cleanup-imdb-arrow-cache.sh
```

This will:
- 🔌 Stop all port-forward processes
- 🗑️ Delete the `arrow-cache-imdb` namespace and all resources
- 📝 Preserve the S3 data (optionally clean it up separately)

## Files Created

### Configuration Files
- `manifests/arrow-cache-imdb/namespace.yaml`
- `manifests/arrow-cache-imdb/configmap.yaml`
- `manifests/arrow-cache-imdb/aws-secret.yaml`
- `manifests/arrow-cache-imdb/head-deployment.yaml`
- `manifests/arrow-cache-imdb/worker-statefulset.yaml`
- `manifests/arrow-cache-imdb/kustomization.yaml`

### Scripts
- `scripts/ingest_imdb_to_iceberg.py` - Ingests raw parquet files into Iceberg table
- `scripts/demo-imdb-arrow-cache-client.py` - Demo client for IMDB data
- `scripts/deploy-imdb-arrow-cache.sh` - Deployment script
- `scripts/port-forward-imdb-arrow-cache.sh` - Port forwarding setup
- `scripts/cleanup-imdb-arrow-cache.sh` - Cleanup script

## Next Steps

1. **Experiment with different query patterns** - Try different row ranges and see how data is distributed across workers
2. **Scale workers** - Modify the StatefulSet replicas to test with more workers
3. **Performance testing** - Run larger performance tests with more queries
4. **Custom datasets** - Adapt the configuration to work with your own Iceberg tables
5. **Production deployment** - Modify for production use with proper resource limits, monitoring, etc.

## Related Files

- Original demo: `manifests/arrow-cache/` (synthetic data)
- HuggingFace to Iceberg script: `/Users/raravena/git/demo-iceberg-tables/hf_to_iceberg.py`
- Current working config: `manifests/arrow-cache/` (preserved as requested)
