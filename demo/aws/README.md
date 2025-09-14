# Arrow Cache Demo

This directory contains all files needed for demonstrating the distributed Arrow Cache system.

## Directory Structure

```
demo/
├── README.md                          # This file
├── WARP.md                           # WARP development guidance
├── docs/
│   └── arrow-cache-demo.md           # Complete setup and demo guide
├── manifests/                        # Kubernetes deployment manifests
│   ├── arrow-cache/                  # Base Arrow Cache deployment
│   ├── arrow-cache-imdb/            # IMDB-specific deployment
│   └── arrow-cache-alpaca/          # Alpaca-specific deployment
├── scripts/                          # Demo and setup scripts
│   ├── README.md                    # Scripts overview
│   ├── lib/                         # Shared Python libraries
│   │   ├── arrow_cache_client.py   # Base client functionality
│   │   └── README.md               # Library documentation
│   ├── generic/                     # Generic dataset training
│   │   ├── generic_training.py     # Universal training script
│   │   ├── configs/                # Dataset configurations
│   │   └── templates/              # TrainJob templates
│   ├── imdb/                        # IMDB movie review demos
│   │   ├── imdb_training.py        # IMDB sentiment training
│   │   ├── demo-client.py          # IMDB demo client
│   │   └── setup-imdb-arrow-cache.sh
│   ├── alpaca/                      # Alpaca dataset demos
│   │   ├── alpaca_training.py      # Alpaca fine-tuning
│   │   └── setup-alpaca-arrow-cache.sh
│   ├── regular/                     # Regular synthetic demos
│   │   ├── demo-client.py          # Basic demo client
│   │   ├── generate-demo-data.py   # Synthetic data generation
│   │   └── setup-arrow-cache.sh    # Standard deployment
│   └── setup-kind/                  # Kind cluster setup
│       ├── setup-kind-cluster.sh   # Main cluster setup
│       └── irsa/                   # IRSA/IAM configuration
├── ingest_hf_dataset_to_s3_iceberg.py  # HuggingFace to Iceberg ingestion
└── environment.yml                  # Conda environment for demo
```

## Quick Start

### Option 1: Generic Training System (Recommended)
```bash
# Setup Kind cluster and IRSA
./scripts/setup-kind/setup-kind-cluster.sh
./scripts/setup-kind/irsa/arrow-cache-example.sh --demo-type regular

# Run training with any dataset
./scripts/generic/setup-generic-training.sh \
  --dataset-name alpaca \
  --dataset-config scripts/generic/configs/alpaca.yaml \
  --use-arrow-cache \
  --use-irsa
```

### Option 2: Dataset-Specific Demos

**IMDB Movie Reviews:**
```bash
./scripts/imdb/setup-imdb-arrow-cache.sh
python3 scripts/imdb/demo-client.py --demo
```

**Alpaca Fine-tuning:**
```bash
./scripts/alpaca/setup-alpaca-arrow-cache.sh
python3 scripts/alpaca/alpaca_training.py --use-arrow-cache
```

**Regular/Synthetic Data:**
```bash
./scripts/regular/setup-arrow-cache.sh
python3 scripts/regular/demo-client.py --demo
```

## Components Overview

### Training Systems
- **Generic Training** (`scripts/generic/`): Universal training system supporting any dataset via YAML configuration
- **IMDB Training** (`scripts/imdb/`): Sentiment classification on movie reviews
- **Alpaca Training** (`scripts/alpaca/`): LLM fine-tuning with instruction following
- **Regular Demos** (`scripts/regular/`): Basic demonstrations with synthetic data

### Core Infrastructure
- **Arrow Cache**: Distributed caching system with head-worker architecture
- **Apache Arrow Flight**: High-performance data transport protocol
- **Iceberg Integration**: Modern data lake metadata management
- **Kubernetes Native**: Full orchestration with Kind clusters and IRSA

### Key Scripts
- **`scripts/setup-kind/`**: Kind cluster and IRSA setup for local development
- **`scripts/lib/`**: Shared Python libraries and base client functionality
- **`scripts/generic/`**: Unified training system for all datasets
- **`ingest_hf_dataset_to_s3_iceberg.py`**: HuggingFace dataset ingestion pipeline

## Usage Patterns

### For ML Training
```bash
# Generic training with Arrow Cache
./scripts/generic/setup-generic-training.sh \
  --dataset-name imdb \
  --dataset-config scripts/generic/configs/imdb.yaml \
  --use-arrow-cache \
  --model-name distilbert-base-uncased \
  --max-samples 1000
```

### For Development and Testing
```bash
# Setup development cluster with IRSA
./scripts/setup-kind/setup-kind-cluster.sh
./scripts/setup-kind/irsa/arrow-cache-example.sh --demo-type regular

# Test Arrow Cache connectivity
./scripts/regular/setup-arrow-cache.sh
python3 scripts/regular/demo-client.py --demo
```

### For Dataset-Specific Workflows
```bash
# IMDB sentiment analysis
./scripts/imdb/setup-imdb-arrow-cache.sh
python3 scripts/imdb/imdb_training.py --use-arrow-cache --dry-run

# Alpaca instruction following
./scripts/alpaca/setup-alpaca-arrow-cache.sh
python3 scripts/alpaca/alpaca_training.py --use-arrow-cache --epochs 1
```

## Environment Setup

Create the demo environment:
```bash
conda env create -f environment.yml
conda activate arrow-cache-demo
```

**Prerequisites:**
- Docker or Lima (for Kind cluster)
- kubectl
- AWS CLI configured
- Python 3.11+

## Troubleshooting

1. **Check pod status**: `kubectl get pods -n arrow-cache-demo`
2. **View logs**: `kubectl logs -n arrow-cache-demo -l app=arrow-cache-head -f`
3. **Verify configuration**: `kubectl get configmap arrow-cache-config -n arrow-cache-demo -o yaml`
4. **Test connectivity**: `./scripts/regular/demo-arrow-cache-status.sh`
5. **Check IRSA setup**: `./scripts/setup-kind/irsa/test-irsa.sh`
6. **Debug training**: `kubectl get trainjobs -n arrow-cache-demo -w`

## Demo Flow for Presentations

### 5-Minute Quick Demo
1. **Setup** (1 min): `./scripts/setup-kind/irsa/arrow-cache-example.sh --demo-type regular`
2. **Training Demo** (2 mins): Show generic training system with live IMDB sentiment analysis
3. **Scaling** (1 min): Scale Arrow Cache workers and show distributed queries
4. **Results** (1 min): Display training metrics and cached performance

### 10-Minute Complete Demo
1. **Architecture Overview** (2 mins): Explain distributed caching and ML training integration
2. **Infrastructure Setup** (2 mins): Kind cluster, IRSA, and Arrow Cache deployment
3. **Dataset Comparison** (3 mins): Show IMDB, Alpaca, and custom dataset support
4. **Live Training** (2 mins): Run actual model training with Arrow Cache
5. **Performance Analysis** (1 min): Compare with/without caching, show scaling benefits

## Architecture Highlights

- **ML-First Design**: Seamless integration with PyTorch, HuggingFace, and popular ML frameworks
- **Distributed Caching**: Head-worker architecture with Apache Arrow Flight for high-performance data transport
- **Universal Dataset Support**: Generic training system works with any dataset via YAML configuration
- **Kubernetes Native**: Full orchestration with TrainJob CRDs, Kind clusters, and IRSA authentication
- **Production Ready**: IRSA for AWS, configurable resource limits, monitoring, and cleanup automation
- **Developer Friendly**: Comprehensive demos, shared libraries, and consistent CLI patterns
