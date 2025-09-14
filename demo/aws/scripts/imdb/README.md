# IMDB Movie Review Sentiment Training with Arrow Cache

This directory contains scripts for training sentiment classification models on the IMDB movie review dataset using Arrow Cache for distributed data access.

## 📁 Files Overview

- **`imdb_training.py`** - Main training script for IMDB sentiment classification
- **`imdb-trainjob-real.yaml`** - Production TrainJob for actual training
- **`imdb-trainjob-simple.yaml`** - Simple TrainJob for testing script loading
- **`imdb-configmap.yaml`** - Basic ConfigMap template
- **`imdb-training-configmap.yaml`** - Complete ConfigMap with all scripts
- **`demo-client.py`** - Demo client for testing Arrow Cache connectivity
- **`README.md`** - This documentation

## 🎬 Dataset Information

**IMDB Movie Review Dataset:**
- **Total Samples**: ~50,000 movie reviews
- **Task**: Binary sentiment classification (positive/negative)
- **Schema**:
  - `text` - Movie review text
  - `label` - Sentiment label (0=negative, 1=positive)
- **Source**: [IMDB Movie Reviews](https://huggingface.co/datasets/imdb)

## 🚀 Quick Start

### 1. Deploy IMDB Arrow Cache System

First, set up the Arrow Cache infrastructure for IMDB:

```bash
# From the setup-kind directory
./irsa/arrow-cache-example.sh --demo-type imdb

# Or manually
../setup-imdb-arrow-cache.sh --iam-role arn:aws:iam::123456789:role/YourRole
```

### 2. Test Arrow Cache Connection

```bash
# Test basic connectivity
python3 demo-client.py --demo

# Run sentiment analysis demo
python3 demo-client.py --sentiment

# Performance testing
python3 demo-client.py --performance --queries 20
```

### 3. Run Training

**Simple Test (dry-run):**
```bash
kubectl apply -f imdb-trainjob-simple.yaml
```

**Production Training:**
```bash
kubectl apply -f imdb-trainjob-real.yaml
```

**Manual Training:**
```bash
python3 imdb_training.py \\
  --model-name distilgpt2 \\
  --max-samples 100 \\
  --use-arrow-cache \\
  --use-irsa \\
  --dry-run
```

## ⚙️ Configuration Options

### Training Script Options

```bash
python3 imdb_training.py [OPTIONS]

# Model and Data
--model-name MODEL          # Model to use (default: distilgpt2)
--max-samples N             # Limit training samples
--use-arrow-cache           # Use Arrow Cache for data loading

# Arrow Cache Connection
--head-host HOST            # Arrow Cache head service
--head-port PORT            # Arrow Cache head port
--in-cluster               # Running inside Kubernetes

# AWS Authentication
--use-irsa                 # Use IRSA for AWS auth
--aws-profile PROFILE      # AWS profile (if not using IRSA)

# Training Control
--dry-run                  # Test mode (no actual training)
--skip-checkpoint          # Skip saving model checkpoints
```

This IMDB training system provides a complete sentiment classification pipeline with distributed data access via Arrow Cache.
