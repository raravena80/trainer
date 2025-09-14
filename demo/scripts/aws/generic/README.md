# Generic Dataset Training with Arrow Cache

This directory contains a unified, configurable training system that can work with any dataset using Arrow Cache integration.

## 🎯 Overview

Instead of maintaining separate scripts for each dataset (alpaca, imdb, regular), this generic system provides:

- **Single Training Script** - Works with any dataset via configuration
- **Parameterized TrainJob Template** - Generates Kubernetes jobs for any dataset
- **Dataset Configuration Files** - YAML configs defining dataset-specific parameters
- **Automated Setup Script** - One-command deployment for any dataset

## 📁 Directory Structure

```
generic/
├── README.md                          # This file
├── generic_training.py                 # Universal training script
├── setup-generic-training.sh          # Setup script for any dataset
├── templates/
│   └── generic-trainjob.yaml          # Parameterized TrainJob template
└── configs/
    ├── alpaca.yaml                     # Alpaca dataset configuration
    ├── imdb.yaml                       # IMDB dataset configuration
    ├── regular.yaml                    # Regular/demo dataset configuration
    └── custom-template.yaml            # Template for custom datasets
```

## 🚀 Quick Start

### 1. Run Alpaca Training with Arrow Cache

```bash
./setup-generic-training.sh \
  --dataset-name alpaca \
  --dataset-config configs/alpaca.yaml \
  --use-arrow-cache \
  --use-irsa \
  --in-cluster \
  --dry-run
```

### 2. Run IMDB Training

```bash
./setup-generic-training.sh \
  --dataset-name imdb \
  --dataset-config configs/imdb.yaml \
  --use-arrow-cache \
  --max-samples 100 \
  --model-name gpt2
```

### 3. Run Custom Dataset

```bash
# First, create your dataset config based on custom-template.yaml
cp configs/custom-template.yaml configs/my-dataset.yaml
# Edit my-dataset.yaml with your specific settings

# Then run training
./setup-generic-training.sh \
  --dataset-name my-dataset \
  --dataset-config configs/my-dataset.yaml \
  --use-arrow-cache
```

## ⚙️ Configuration

### Dataset Configuration (YAML)

Each dataset has a YAML configuration file that defines:

```yaml
dataset_name: "alpaca"
description: "Dataset description"

# Arrow Cache settings
namespace: "arrow-cache-demo"
num_partitions: 4

# Iceberg table location
iceberg_table: "hf_datasets.tatsu-lab_alpaca"

# Data schema
text_column: "text"
columns:
  - name: "text"
    type: "string"
    description: "Training text"

# Training defaults
default_model: "distilgpt2"
default_max_length: 128
default_batch_size: 1

# AWS resources
checkpoint_bucket: "your-bucket"
glue_database: "hf_datasets"
```

### Command Line Options

The setup script accepts many parameters:

**Dataset Options:**
- `--dataset-name` - Dataset identifier
- `--dataset-config` - Path to YAML config file
- `--text-column` - Column name containing training text

**Model Options:**
- `--model-name` - HuggingFace model name (default: distilgpt2)
- `--max-length` - Sequence length (default: 128)
- `--batch-size` - Training batch size (default: 1)
- `--epochs` - Training epochs (default: 1)

**Infrastructure Options:**
- `--use-arrow-cache` - Enable Arrow Cache data loading
- `--use-irsa` - Use IRSA for AWS authentication
- `--in-cluster` - Running inside Kubernetes cluster
- `--namespace` - Kubernetes namespace

**Resource Options:**
- `--cpu-request/limit` - CPU allocation
- `--memory-request/limit` - Memory allocation

## 🔧 How It Works

### 1. Dataset Configuration
Each dataset is defined by a YAML config file containing:
- Arrow Cache connection details
- Iceberg table location
- Data schema and column mappings
- Training defaults
- AWS resource specifications

### 2. Generic Training Script
The `generic_training.py` script:
- Loads dataset config from YAML
- Connects to Arrow Cache or Iceberg directly
- Creates a generic PyTorch dataset
- Runs training with configurable parameters

### 3. Template System
The TrainJob template (`templates/generic-trainjob.yaml`) uses variable substitution:
- `${DATASET_NAME}` → actual dataset name
- `${MODEL_NAME}` → model selection
- `${MAX_SAMPLES}` → sample limit
- `${USE_ARROW_CACHE_FLAG}` → Arrow Cache toggle

### 4. Automated Deployment
The setup script:
- Validates configuration
- Creates Kubernetes ConfigMap with scripts
- Generates TrainJob from template
- Deploys to cluster

## 📊 Monitoring

After deployment, monitor your training job:

```bash
# Watch TrainJob status
kubectl get trainjobs -n arrow-cache-demo -w

# View training logs
kubectl logs -f -n arrow-cache-demo job/alpaca-training-20240816-123456-node-0

# Check pod status
kubectl get pods -n arrow-cache-demo -l jobset.sigs.k8s.io/jobset-name=alpaca-training-20240816-123456
```

## 🎨 Adding New Datasets

To add a new dataset:

1. **Create Config File:**
   ```bash
   cp configs/custom-template.yaml configs/my-new-dataset.yaml
   ```

2. **Edit Configuration:**
   - Set `dataset_name`, `iceberg_table`, `namespace`
   - Define `text_column` and data schema
   - Configure training defaults

3. **Deploy Arrow Cache:**
   ```bash
   # Ensure Arrow Cache is deployed for your namespace
   ../setup-kind/irsa/arrow-cache-example.sh --demo-type custom
   ```

4. **Run Training:**
   ```bash
   ./setup-generic-training.sh \
     --dataset-name my-new-dataset \
     --dataset-config configs/my-new-dataset.yaml \
     --use-arrow-cache
   ```

## 🔍 Comparison with Dataset-Specific Scripts

| Feature | Dataset-Specific (alpaca/, imdb/, regular/) | Generic System |
|---------|---------------------------------------------|----------------|
| **Maintenance** | Separate scripts per dataset | Single script for all |
| **Flexibility** | Hard-coded parameters | Configurable via YAML |
| **Consistency** | Potential drift between scripts | Unified implementation |
| **New Datasets** | Copy/modify entire script | Add YAML config only |
| **Testing** | Test each script separately | Test once, works for all |

## 💡 Best Practices

1. **Start with Dry-Run:** Always test new datasets with `--dry-run` first
2. **Resource Sizing:** Adjust CPU/memory based on model size and data volume
3. **Configuration Validation:** Verify Iceberg table and Arrow Cache accessibility
4. **Monitoring:** Use kubectl commands to monitor job progress and resource usage
5. **Cleanup:** Remove completed TrainJobs to avoid cluster resource consumption

## 🔧 Troubleshooting

**Common Issues:**

1. **Config Not Found:** Ensure dataset config file exists and path is correct
2. **OOM Errors:** Reduce `--max-samples`, `--batch-size`, or `--max-length`
3. **Arrow Cache Connection:** Verify Arrow Cache is deployed in correct namespace
4. **IRSA Issues:** Ensure service account has required AWS permissions
5. **Resource Limits:** Check cluster has sufficient CPU/memory for requests

**Debug Commands:**
```bash
# Check Arrow Cache pods
kubectl get pods -n arrow-cache-demo

# Verify ConfigMap
kubectl get configmap generic-training-script -n arrow-cache-demo -o yaml

# Check TrainJob status
kubectl describe trainjob your-job-name -n arrow-cache-demo
```

This generic system provides a scalable, maintainable approach to training with Arrow Cache while supporting any dataset with minimal configuration effort.
