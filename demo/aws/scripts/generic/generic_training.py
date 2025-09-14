#!/usr/bin/env python3
"""
Generic Dataset Training Script with Arrow Cache Integration

This script provides a unified training interface that can work with any dataset
by using configurable parameters and dataset-specific configurations.

Supported datasets: alpaca, imdb, any custom dataset with Arrow Cache integration
"""

import argparse
import logging
import os
import sys
import time
from pathlib import Path
from typing import Any, Dict

import boto3
import pyarrow as pa
import pyarrow.flight as flight
import torch
import yaml
from torch.utils.data import DataLoader, Dataset
from transformers import AutoModelForCausalLM, AutoTokenizer, Trainer, TrainingArguments

# Configure environment before importing our modules
os.environ["TOKENIZERS_PARALLELISM"] = "false"
sys.path.append("../lib")

from arrow_cache_client import BaseArrowCacheClient  # noqa: E402

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


class GenericDataset(Dataset):
    """Generic PyTorch dataset that works with any text data format."""

    def __init__(
        self,
        data: pa.Table,
        tokenizer,
        max_length: int = 512,
        text_column: str = "text",
    ):
        self.data = data
        self.tokenizer = tokenizer
        self.max_length = max_length
        self.text_column = text_column

        # Convert to pandas for easier manipulation
        self.df = data.to_pandas()

        # Validate text column exists
        if text_column not in self.df.columns:
            available_cols = ", ".join(self.df.columns)
            raise ValueError(
                f"Text column '{text_column}' not found. Available columns: {available_cols}"
            )

        logger.info(f"Dataset initialized with {len(self.df)} samples")
        logger.info(f"Using text column: '{text_column}'")
        logger.info(f"Available columns: {list(self.df.columns)}")

    def __len__(self):
        return len(self.df)

    def __getitem__(self, idx):
        text = str(self.df.iloc[idx][self.text_column])

        # Tokenize
        encoding = self.tokenizer(
            text,
            truncation=True,
            padding="max_length",
            max_length=self.max_length,
            return_tensors="pt",
        )

        return {
            "input_ids": encoding["input_ids"].flatten(),
            "attention_mask": encoding["attention_mask"].flatten(),
            "labels": encoding["input_ids"].flatten(),
        }


class GenericArrowCacheClient(BaseArrowCacheClient):
    """Generic Arrow Cache client that can work with any dataset."""

    def __init__(
        self,
        host: str = "localhost",
        port: int = 50051,
        in_cluster: bool = False,
        namespace: str = "arrow-cache",
    ):
        super().__init__(host, port)
        self.namespace = namespace
        self.in_cluster = in_cluster

    def translate_worker_uri(self, worker_uri: str, namespace: str = None) -> str:
        """Override to handle in-cluster vs local execution."""
        if namespace is None:
            namespace = self.namespace

        if self.in_cluster:
            # Running in cluster - use URIs as-is, just convert http to grpc
            if isinstance(worker_uri, bytes):
                worker_uri = worker_uri.decode("utf-8")
            if worker_uri.startswith("http://"):
                worker_uri = worker_uri.replace("http://", "grpc://", 1)
            return worker_uri
        else:
            # Running locally - use parent's port-forwarding translation
            return super().translate_worker_uri(worker_uri, namespace)

    def get_dataset_data(self, num_partitions: int = 4) -> pa.Table:
        """Retrieve any dataset data from Arrow Cache."""
        self.logger.info("Fetching dataset data from Arrow Cache...")

        all_data = []

        for partition_id in range(num_partitions):
            try:
                self.logger.info(f"Fetching partition {partition_id}/{num_partitions}")

                flight_info = self.get_flight_info_for_partition(
                    partition_id, num_partitions
                )

                if flight_info.endpoints:
                    for endpoint in flight_info.endpoints:
                        if endpoint.locations and endpoint.ticket:
                            worker_uri = self.translate_worker_uri(
                                endpoint.locations[0].uri, self.namespace
                            )

                            self.logger.info(f"Querying worker at {worker_uri}")

                            try:
                                worker_location = flight.Location(worker_uri)
                                worker_client = flight.FlightClient(worker_location)

                                flight_stream = worker_client.do_get(endpoint.ticket)
                                partition_data = flight_stream.read_all()

                                self.logger.info(
                                    f"Retrieved {len(partition_data)} rows from "
                                    f"partition {partition_id}"
                                )
                                all_data.append(partition_data)
                                break

                            except Exception as e:
                                self.logger.warning(
                                    f"Failed to query worker {worker_uri}: {e}"
                                )
                else:
                    self.logger.warning(
                        f"No endpoints found for partition {partition_id}"
                    )

            except Exception as e:
                self.logger.warning(
                    f"Failed to get flight info for partition {partition_id}: {e}"
                )

            time.sleep(0.5)  # Small delay between partitions

        if not all_data:
            raise Exception("Failed to retrieve any data from Arrow Cache")

        # Concatenate all partition data
        result = pa.concat_tables(all_data)
        self.logger.info(f"Total samples retrieved: {len(result)}")

        return result


def load_dataset_config(config_path: str) -> Dict[str, Any]:
    """Load dataset configuration from YAML file."""
    config_file = Path(config_path)
    if not config_file.exists():
        raise FileNotFoundError(f"Dataset config not found: {config_path}")

    with open(config_file, "r") as f:
        config = yaml.safe_load(f)

    logger.info(f"Loaded dataset config: {config['dataset_name']}")
    return config


def load_data_from_arrow_cache(args, config: Dict[str, Any]) -> pa.Table:
    """Load data from Arrow Cache using the provided configuration."""
    cache_client = GenericArrowCacheClient(
        args.head_host,
        args.head_port,
        args.in_cluster,
        config.get("namespace", "arrow-cache"),
    )
    cache_client.connect()

    # Get data from cache
    arrow_data = cache_client.get_dataset_data(config.get("num_partitions", 4))

    # Limit samples if specified
    if args.max_samples and len(arrow_data) > args.max_samples:
        import random

        indices = random.sample(range(len(arrow_data)), args.max_samples)
        arrow_data = arrow_data.take(indices)
        logger.info(f"Using {len(arrow_data)} samples (limited from full dataset)")

    return arrow_data


def load_data_from_iceberg(config: Dict[str, Any]) -> pa.Table:
    """Load data directly from Iceberg using the provided configuration."""
    from pyiceberg.catalog.glue import GlueCatalog

    catalog = GlueCatalog(**config.get("iceberg_catalog", {}))
    table = catalog.load_table(config["iceberg_table"])

    scan = table.scan()
    arrow_data = scan.to_arrow()

    logger.info(f"Loaded {len(arrow_data)} samples from Iceberg")
    return arrow_data


def ensure_aws_resources(session, config: Dict[str, Any]):
    """Ensure required AWS resources exist."""
    # Ensure S3 bucket
    if "checkpoint_bucket" in config:
        s3 = session.client("s3")
        bucket_name = config["checkpoint_bucket"]
        try:
            s3.head_bucket(Bucket=bucket_name)
            logger.info(f"S3 bucket '{bucket_name}' exists.")
        except Exception:
            logger.info(f"Creating S3 bucket '{bucket_name}'...")
            s3.create_bucket(Bucket=bucket_name)

    # Ensure Glue database
    if "glue_database" in config:
        glue = session.client("glue")
        db_name = config["glue_database"]
        try:
            glue.get_database(Name=db_name)
            logger.info(f"Glue database '{db_name}' exists.")
        except Exception:
            logger.info(f"Creating Glue database '{db_name}'...")
            glue.create_database(DatabaseInput={"Name": db_name})


def main():
    parser = argparse.ArgumentParser(
        description="Generic training script for any dataset with Arrow Cache"
    )

    # Dataset configuration
    parser.add_argument(
        "--dataset-config",
        required=True,
        help="Path to dataset configuration YAML file",
    )
    parser.add_argument(
        "--text-column",
        default="text",
        help="Name of the text column to use for training",
    )

    # Model configuration
    parser.add_argument(
        "--model-name", default="distilgpt2", help="Model to use for training"
    )
    parser.add_argument(
        "--max-length", type=int, default=512, help="Maximum sequence length"
    )
    parser.add_argument("--batch-size", type=int, default=4, help="Training batch size")
    parser.add_argument(
        "--epochs", type=int, default=1, help="Number of training epochs"
    )
    parser.add_argument(
        "--learning-rate", type=float, default=5e-5, help="Learning rate"
    )

    # Data loading options
    parser.add_argument(
        "--use-arrow-cache",
        action="store_true",
        help="Use Arrow Cache for data loading",
    )
    parser.add_argument(
        "--max-samples", type=int, help="Maximum samples to use for training"
    )

    # Arrow Cache connection
    parser.add_argument(
        "--head-host", default="localhost", help="Arrow Cache head host"
    )
    parser.add_argument(
        "--head-port", type=int, default=50051, help="Arrow Cache head port"
    )
    parser.add_argument(
        "--in-cluster",
        action="store_true",
        help="Running in-cluster (don't translate worker URIs)",
    )

    # AWS configuration
    parser.add_argument(
        "--use-irsa", action="store_true", help="Use IRSA (no AWS profile)"
    )
    parser.add_argument(
        "--aws-profile",
        default="default",
        help="AWS profile name (ignored if --use-irsa)",
    )
    parser.add_argument("--aws-region", default="us-east-1", help="AWS region")

    # Training control
    parser.add_argument(
        "--dry-run", action="store_true", help="Run without actual training"
    )
    parser.add_argument(
        "--skip-checkpoint", action="store_true", help="Skip saving checkpoint to S3"
    )

    args = parser.parse_args()

    # Load dataset configuration
    config = load_dataset_config(args.dataset_config)

    # Set seeds for reproducibility
    torch.manual_seed(config.get("seed", 42))

    logger.info("🚀 Starting generic training with Arrow Cache integration")
    logger.info(f"Dataset: {config['dataset_name']}")
    logger.info(f"Model: {args.model_name}")
    logger.info(f"Use Arrow Cache: {args.use_arrow_cache}")
    logger.info(f"Max samples: {args.max_samples}")

    # AWS session
    if args.use_irsa:
        session = boto3.Session(region_name=args.aws_region)
        logger.info("Using IRSA for AWS authentication")
    else:
        session = boto3.Session(
            profile_name=args.aws_profile, region_name=args.aws_region
        )
        logger.info(f"Using AWS profile: {args.aws_profile}")

    # Ensure AWS resources
    if not args.skip_checkpoint:
        ensure_aws_resources(session, config)

    # Initialize tokenizer and model
    logger.info("Loading tokenizer and model...")
    tokenizer = AutoTokenizer.from_pretrained(args.model_name)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    model = AutoModelForCausalLM.from_pretrained(args.model_name)
    logger.info(f"Model loaded: {model.config.name_or_path}")

    # Load data
    if args.use_arrow_cache:
        logger.info("📊 Loading data from Arrow Cache...")
        try:
            arrow_data = load_data_from_arrow_cache(args, config)
            data_source = "arrow_cache"
        except Exception as e:
            logger.error(f"Failed to load from Arrow Cache: {e}")
            logger.info("Falling back to direct Iceberg access...")
            arrow_data = load_data_from_iceberg(config)
            data_source = "iceberg_direct"
    else:
        logger.info("📊 Loading data directly from Iceberg...")
        arrow_data = load_data_from_iceberg(config)
        data_source = "iceberg_direct"

    # Create dataset
    dataset = GenericDataset(arrow_data, tokenizer, args.max_length, args.text_column)

    logger.info(f"Filtered dataset size: {len(dataset)} samples")

    # Create data loader
    dataloader = DataLoader(dataset, batch_size=args.batch_size, shuffle=True)
    logger.info(f"Dataset loaded: {len(dataset)} samples, {len(dataloader)} batches")

    if args.dry_run:
        logger.info("🧪 Dry run mode - skipping actual training")
        logger.info(f"Would train on {len(dataset)} samples for {args.epochs} epochs")
        logger.info(f"Dataset: {config['dataset_name']}")
        logger.info(f"Data source: {data_source}")
        logger.info(f"Text column: {args.text_column}")
        return

    # Setup training
    logger.info("🏋️ Setting up training...")

    # Training arguments
    training_args = TrainingArguments(
        output_dir=f"./results_{config['dataset_name']}",
        num_train_epochs=args.epochs,
        per_device_train_batch_size=args.batch_size,
        learning_rate=args.learning_rate,
        logging_steps=10,
        save_strategy="no",  # Don't save intermediate checkpoints
        logging_dir=f"./logs_{config['dataset_name']}",
    )

    # Create trainer
    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=dataset,
        tokenizer=tokenizer,
    )

    # Start training
    logger.info(f"🎯 Starting training for {args.epochs} epochs...")
    start_time = time.time()

    try:
        trainer.train()

        training_time = time.time() - start_time
        logger.info(f"✅ Training completed in {training_time:.2f} seconds")

        # Save final model if not skipping checkpoints
        if not args.skip_checkpoint:
            model_save_path = f"./final_model_{config['dataset_name']}"
            trainer.save_model(model_save_path)
            logger.info(f"💾 Model saved to {model_save_path}")

    except Exception as e:
        logger.error(f"❌ Training failed: {e}")
        raise


if __name__ == "__main__":
    main()
