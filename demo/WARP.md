# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

This is the **demo** subdirectory of Kubeflow Trainer, containing demonstration scripts and resources for the distributed Arrow Cache system. The parent project is Kubeflow Trainer V2 - a Kubernetes-native project for large language model (LLM) fine-tuning and scalable distributed training built on top of JobSet.

The demo specifically showcases:
- **Arrow Cache System**: Distributed caching using Apache Arrow Flight protocol
- **Kubernetes Native Deployment**: Uses Kind clusters with custom manifests
- **ML Training Workflows**: Integration with PyTorch, HuggingFace, and various ML frameworks
- **Iceberg Integration**: Modern data lake metadata management with Apache Iceberg

## Core Architecture

### Main Project (Parent Directory)
- **TrainJob**: Main API for data scientists to create training jobs
- **TrainingRuntime** & **ClusterTrainingRuntime**: Blueprint configurations managed by platform engineers
- **JobSet Integration**: Built on Kubernetes SIG's JobSet for managing groups of Jobs
- **Runtime Framework**: Pluggable system supporting PyTorch, MPI, TensorFlow, JAX, etc.

### Demo Architecture
- **Head-Worker Model**: Distributed caching with coordinating head node and multiple workers
- **Apache Arrow Flight**: High-performance data transport protocol
- **Arrow Cache Client**: Python client library for interacting with the cache
- **Kubernetes Manifests**: Complete deployment configurations for different scenarios

## Key Development Commands

### Demo Environment Setup
```bash
# Create conda environment
conda env create -f environment.yml
conda activate arrow-cache-demo

# Setup Kind cluster with IRSA support
./scripts/setup-kind/setup-kind-cluster.sh --enable-irsa

# Deploy Arrow Cache for specific demo type
./scripts/setup-kind/irsa/arrow-cache-example.sh --demo-type regular

# Alternative: Use generic training system (recommended)
./scripts/generic/setup-generic-training.sh \
  --dataset-name imdb \
  --dataset-config scripts/generic/configs/imdb.yaml \
  --use-arrow-cache \
  --use-irsa
```

### Arrow Cache Demo Commands
```bash
# Generic training system (recommended approach)
./scripts/generic/setup-generic-training.sh \
  --dataset-name imdb \
  --dataset-config scripts/generic/configs/imdb.yaml \
  --use-arrow-cache \
  --use-irsa

# Dataset-specific demos
./scripts/regular/setup-arrow-cache.sh
./scripts/regular/demo-arrow-cache-status.sh
python3 scripts/regular/demo-client.py --demo

# IMDB sentiment classification
./scripts/imdb/setup-imdb-arrow-cache.sh --use-irsa
python3 scripts/imdb/demo-client.py --demo
python3 scripts/imdb/imdb_training.py --use-arrow-cache --use-irsa

# Alpaca instruction following
./scripts/alpaca/setup-alpaca-arrow-cache.sh --use-irsa
python3 scripts/alpaca/alpaca_training.py --use-arrow-cache --use-irsa
```

### Parent Project (Go-based) Commands
```bash
# From parent directory (/Users/raravena/git/trainer)

# Build and test
make generate    # Generate manifests and APIs
make test       # Run Go unit tests
make test-integration  # Run Go integration tests
make test-python      # Run Python unit tests

# Development
make fmt        # Format Go code
make vet        # Run Go vet
make golangci-lint  # Run linting

# E2E testing
make test-e2e-setup-cluster  # Setup Kind cluster
make test-e2e              # Run e2e tests
make test-e2e-notebook     # Run Jupyter notebook tests

# Helm operations
make helm-lint     # Lint Helm charts
make helm-unittest # Run Helm unit tests
```

### Cleanup Commands
```bash
# Clean up specific demo resources
./scripts/regular/cleanup-arrow-cache.sh
./scripts/imdb/cleanup-imdb-arrow-cache.sh
./scripts/alpaca/cleanup-alpaca-arrow-cache.sh

# Complete cleanup with IRSA resources
kind delete cluster --name arrow-cache-demo
./scripts/setup-kind/irsa/cleanup-irsa.sh --cluster-name arrow-cache-demo
```

## Code Structure

### Demo Directory Structure
```
demo/
├── scripts/           # Deployment and demo scripts
│   ├── lib/          # Shared Python libraries
│   ├── generic/      # Universal training system (⭐ Recommended)
│   ├── setup-kind/   # Kind cluster and IRSA setup
│   ├── regular/      # Standard Arrow Cache demos
│   ├── imdb/         # IMDB dataset-specific demos
│   └── alpaca/       # Alpaca training demos
├── manifests/        # Kubernetes deployment manifests
│   ├── arrow-cache/       # Base Arrow Cache deployment
│   ├── arrow-cache-imdb/  # IMDB-specific configuration
│   └── arrow-cache-alpaca/# Alpaca-specific configuration
├── docs/             # Demo documentation
└── ingest_hf_dataset_to_s3_iceberg.py  # HuggingFace dataset ingestion
```

### Parent Project Structure
```
trainer/
├── pkg/
│   ├── apis/trainer/v1alpha1/    # Core API definitions
│   ├── controller/               # Kubernetes controllers
│   ├── runtime/                 # Runtime abstraction layer
│   └── webhooks/                # Admission webhooks
├── cmd/
│   ├── trainer-controller-manager/  # Main controller binary
│   ├── initializers/               # Dataset/model initializers
│   └── runtimes/                   # Runtime implementations
├── manifests/                      # Kubernetes manifests
├── charts/kubeflow-trainer/        # Helm charts
└── examples/                       # Training examples
```

## Important Technical Details

### Demo-Specific APIs
- **Arrow Cache Client** (`scripts/lib/arrow_cache_client.py`): Core client for interacting with distributed cache
- **Generic Training System** (`scripts/generic/generic_training.py`): Universal training pipeline supporting any dataset
- **Demo Data Generation** (`scripts/regular/generate-demo-data.py`): Synthetic dataset creation
- **HuggingFace Integration** (`ingest_hf_dataset_to_s3_iceberg.py`): HuggingFace to Iceberg data pipeline

### Core Trainer APIs
- **TrainJob** (`pkg/apis/trainer/v1alpha1/trainjob_types.go`): Main training job specification
- **TrainingRuntime** (`pkg/apis/trainer/v1alpha1/trainingruntime_types.go`): Runtime templates
- **Runtime Interface** (`pkg/runtime/interface.go`): Pluggable runtime system

### Key Technologies
- **Go 1.24+**: Main project language
- **Python 3.11+**: Demo scripts and ML components
- **Kubernetes/JobSet**: Orchestration layer
- **Apache Arrow**: High-performance data processing
- **Apache Iceberg**: Data lake metadata
- **conda**: Python environment management
- **Kind**: Local Kubernetes clusters
- **Helm**: Kubernetes package management

## Development Guidelines

### Code Quality
- **Pre-commit hooks**: Run `pre-commit install` before committing
- **Go formatting**: Use `make fmt` and `make vet`
- **Python formatting**: Black and isort are configured
- **Linting**: golangci-lint for Go, flake8 for Python

### Testing Strategy
- **Unit tests**: `make test` (Go), `make test-python` (Python)
- **Integration tests**: `make test-integration`
- **E2E tests**: `make test-e2e` with Kind clusters
- **Notebook tests**: `make test-e2e-notebook` with Papermill

### Demo Development
- Use the conda environment for consistency
- Test with local Kind clusters before production
- Follow the established naming patterns for new demo scenarios
- Ensure cleanup scripts work properly

### Kubernetes Integration
- All resources use proper labels and annotations
- Gang scheduling via coscheduling plugin or Volcano
- PVC management for persistent storage
- Service account configuration for cloud integration

## Common Pitfalls

### Demo Environment
- Ensure Docker/Lima is running before Kind cluster creation
- AWS credentials must be properly configured for S3 demos
- Port forwarding conflicts can occur with multiple demos
- Resource limits may need adjustment for larger datasets

### Parent Project
- Always run `make generate` after API changes
- JobSet version compatibility is critical
- Runtime plugins must implement the correct interfaces
- Webhook configurations require proper TLS setup

## File Patterns

### Important Demo Files
- `setup-*.sh`: Deployment and configuration scripts
- `demo-client.py` / `*_training.py`: Client applications and training scripts
- `*-arrow-cache.sh`: Arrow Cache specific operations
- `cleanup-*.sh`: Resource cleanup scripts
- `generic_training.py`: Universal training script for any dataset
- `configs/*.yaml`: Dataset configuration files
- `arrow-cache-example.sh`: One-command IRSA + Arrow Cache deployment

### Important Project Files
- `*_types.go`: Kubernetes API type definitions
- `*_controller.go`: Kubernetes controller implementations
- `*_webhook.go`: Admission webhook handlers
- `*_test.go`: Go test files
- `requirements.txt`: Python dependencies for specific components
