# Arrow Cache Demo Scripts

This directory contains comprehensive scripts for demonstrating distributed Arrow Cache with ML training, organized by functionality and dataset type.

## 🏗️ Directory Structure

```
scripts/
├── README.md                    # This file
├── lib/                         # Shared Python libraries
│   ├── arrow_cache_client.py   # Base client functionality
│   └── README.md               # Library documentation
├── setup-kind/                 # Kind cluster and IRSA setup
│   ├── setup-kind-cluster.sh  # Main cluster setup script
│   ├── irsa/                   # IRSA/AWS authentication
│   └── README.md               # Setup documentation
├── generic/                     # Universal training system (🌟 Recommended)
│   ├── generic_training.py     # Universal training script
│   ├── setup-generic-training.sh  # Unified deployment
│   ├── configs/                # Dataset YAML configurations
│   ├── templates/              # TrainJob templates
│   └── README.md               # Generic system docs
├── imdb/                        # IMDB movie review sentiment
│   ├── imdb_training.py        # Sentiment classification training
│   ├── demo-client.py          # IMDB-specific demo client
│   ├── setup-imdb-arrow-cache.sh  # IMDB deployment
│   └── README.md               # IMDB-specific documentation
├── alpaca/                      # Alpaca instruction following
│   ├── alpaca_training.py      # Alpaca fine-tuning script
│   ├── setup-alpaca-arrow-cache.sh  # Alpaca deployment
│   └── alpaca-trainjob-*.yaml  # TrainJob manifests
├── regular/                     # Synthetic data demos
│   ├── demo-client.py          # Basic demo client
│   ├── generate-demo-data.py   # Synthetic data generation
│   ├── setup-arrow-cache.sh    # Basic deployment
│   └── README.md               # Regular demo docs
└── ingest_hf_dataset_to_s3_iceberg.py  # HuggingFace ingestion
```

## 🚀 Quick Start Guide

### 1. Generic Training System (Recommended)
The unified system that works with any dataset via YAML configuration:

```bash
# Setup infrastructure
./setup-kind/setup-kind-cluster.sh
./setup-kind/irsa/arrow-cache-example.sh --demo-type regular

# Train with any dataset
./generic/setup-generic-training.sh \
  --dataset-name imdb \
  --dataset-config generic/configs/imdb.yaml \
  --use-arrow-cache \
  --use-irsa \
  --dry-run
```

### 2. Dataset-Specific Demos

**IMDB Movie Review Sentiment:**
```bash
./imdb/setup-imdb-arrow-cache.sh --use-irsa
python3 imdb/demo-client.py --demo
python3 imdb/imdb_training.py --use-arrow-cache --dry-run
```

**Alpaca Instruction Following:**
```bash
./alpaca/setup-alpaca-arrow-cache.sh --use-irsa
python3 alpaca/alpaca_training.py --use-arrow-cache --epochs 1
```

**Regular/Synthetic Data:**
```bash
./regular/setup-arrow-cache.sh
python3 regular/demo-client.py --demo
./regular/generate-demo-data.py --records 1000
```

## 🎯 Script Categories

### Infrastructure Scripts
- **`setup-kind/`**: Complete Kind cluster setup with IRSA authentication
- **`lib/`**: Shared Python libraries used by all demo clients
- **`ingest_hf_dataset_to_s3_iceberg.py`**: Pipeline for ingesting HuggingFace datasets

### Training Scripts
- **`generic/`**: Universal training system supporting any dataset
- **`imdb/`**: IMDB movie review sentiment classification
- **`alpaca/`**: Alpaca instruction-following fine-tuning
- **`regular/`**: Basic demonstrations with synthetic data

### Client Scripts
- **`**/demo-client.py`**: Arrow Cache connectivity and query testing
- **`**/setup-*.sh`**: Automated deployment for each demo type
- **`regular/demo-arrow-cache-status.sh`**: Comprehensive status checking

## 🔧 Key Features

### Unified Generic System
- **Single Training Script**: Works with any dataset via YAML config
- **Template-Based**: Parameterized TrainJob generation
- **Configurable**: Dataset-specific settings without code duplication
- **Production-Ready**: IRSA, resource limits, monitoring

### Shared Infrastructure
- **BaseArrowCacheClient**: Common client operations across all demos
- **S3Utils**: Unified S3 operations and metadata handling
- **IRSA Setup**: Complete AWS authentication for Kubernetes
- **Kind Integration**: Local development with production-like features

### ML-First Design
- **PyTorch Integration**: Native support for popular ML frameworks
- **HuggingFace Models**: Pre-configured model selections
- **Configurable Training**: Batch size, epochs, sequence length, etc.
- **Monitoring**: TrainJob status, logs, resource usage

## 📋 Prerequisites

**Required:**
- Docker or Lima (for Kind)
- kubectl
- Python 3.11+
- AWS CLI configured

**Python Dependencies** (installed via conda environment):
- pyarrow, grpcio, pandas
- torch, transformers, datasets
- boto3, s3fs

## 🎭 Demo Workflow

### Complete Setup (5 minutes)
```bash
# 1. Create Kind cluster with IRSA
./setup-kind/setup-kind-cluster.sh

# 2. Deploy Arrow Cache for specific demo
./setup-kind/irsa/arrow-cache-example.sh --demo-type imdb

# 3. Run training
./generic/setup-generic-training.sh \
  --dataset-name imdb \
  --dataset-config generic/configs/imdb.yaml \
  --use-arrow-cache \
  --use-irsa

# 4. Monitor progress
kubectl get trainjobs -n arrow-cache-demo -w
```

### Testing and Development
```bash
# Test Arrow Cache connectivity
python3 regular/demo-client.py --demo

# Performance testing
python3 imdb/demo-client.py --performance --queries 50

# Status checking
./regular/demo-arrow-cache-status.sh
```

## 🔍 Architecture Benefits

### Over Dataset-Specific Scripts
| Feature | Dataset-Specific | Generic System |
|---------|-----------------|----------------|
| **Maintenance** | N scripts | 1 script |
| **Configuration** | Hard-coded | YAML-based |
| **New Datasets** | Copy/modify script | Add YAML file |
| **Consistency** | Potential drift | Unified implementation |

### Production Features
- **IRSA Authentication**: No hardcoded AWS credentials
- **Resource Management**: Configurable CPU/memory limits
- **Monitoring**: TrainJob CRDs, kubectl integration
- **Cleanup Automation**: Proper resource cleanup
- **Scalability**: Horizontal worker scaling

## 📖 Detailed Documentation

Each subdirectory contains specific documentation:
- **`setup-kind/README.md`**: Kind cluster and IRSA setup
- **`generic/README.md`**: Universal training system
- **`imdb/README.md`**: IMDB sentiment classification
- **`lib/README.md`**: Shared library functionality

For comprehensive setup guidance, see `../docs/arrow-cache-demo.md`.
