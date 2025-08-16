#!/usr/bin/env python3
"""
IMDB Dataset Training Script with Arrow Cache Integration

This script trains a language model on the IMDB movie review dataset using:
1. Arrow Cache for distributed data access
2. PyTorch/Transformers for model training
3. Iceberg for experiment logging
4. Real IMDB sentiment classification data

Schema of IMDB dataset:
- text: The movie review text
- label: Sentiment label (0=negative, 1=positive)
"""

import argparse
import hashlib
import logging
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from typing import Dict

import boto3
import pandas as pd
import pyarrow as pa
import pyarrow.flight as flight
import torch
from pyiceberg.partitioning import PartitionSpec
from pyiceberg.types import DoubleType, LongType, NestedField, StringType, TimestampType
from torch.utils.data import DataLoader, Dataset
from transformers import AutoModelForCausalLM, AutoTokenizer, Trainer, TrainingArguments

# Configure environment
os.environ["TOKENIZERS_PARALLELISM"] = "false"

# Import will be done locally where needed

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# ===================== Configuration =====================
AWS_PROFILE = "root-ricardo"
AWS_REGION = "us-east-1"
GLUE_DB = "hf_datasets"
RUNS_TABLE = "imdb_training_runs"

# Iceberg warehouse for training logs
WAREHOUSE_S3 = "s3://ricardo.hf.datasets/iceberg-warehouse"

# Model checkpoints
CKPT_BUCKET = "ricardo.hf.datasets"
CKPT_PREFIX = "imdb_models"

# Training configuration
EPOCHS = 1
BATCH_SIZE = 1  # Very small batch size for demo with limited memory
LR = 5e-5
SEED = 42
MAX_LENGTH = 128  # Much shorter sequences for memory efficiency
GRADIENT_ACCUMULATION_STEPS = 4

# Arrow Cache configuration
ARROW_CACHE_HOST = "localhost"
ARROW_CACHE_PORT = 50051
ARROW_CACHE_NAMESPACE = "arrow-cache-imdb"
# =======================================================


class IMDBArrowCacheClient:
    """Arrow Cache client specialized for IMDB dataset."""

    def __init__(
        self, host: str = "localhost", port: int = 50051, in_cluster: bool = False
    ):
        # Import here to avoid issues if not available
        sys.path.append("../lib")
        from arrow_cache_client import BaseArrowCacheClient

        self.base_client = BaseArrowCacheClient(host, port)
        self.namespace = ARROW_CACHE_NAMESPACE
        self.in_cluster = in_cluster
        self.logger = logging.getLogger(self.__class__.__name__)

    def connect(self):
        """Connect to the Arrow Cache head node."""
        return self.base_client.connect()

    def get_flight_info_for_partition(self, partition_id: int, total_partitions: int):
        """Get flight info for a specific partition from the head node."""
        return self.base_client.get_flight_info_for_partition(
            partition_id, total_partitions
        )

    def translate_worker_uri(
        self, worker_uri: str, namespace: str = "arrow-cache"
    ) -> str:
        """Override to handle in-cluster vs local execution."""
        if self.in_cluster:
            # Running in cluster - use URIs as-is, just convert http to grpc
            if isinstance(worker_uri, bytes):
                worker_uri = worker_uri.decode("utf-8")
            if worker_uri.startswith("http://"):
                worker_uri = worker_uri.replace("http://", "grpc://", 1)
            return worker_uri
        else:
            # Running locally - use parent's port-forwarding translation
            return self.base_client.translate_worker_uri(worker_uri, namespace)

    def process_query_result(self, result: pa.Table, description: str):
        """Process IMDB-specific query results."""
        if len(result) > 0:
            self.logger.info(f"Retrieved {len(result)} IMDB samples")
            self.logger.info(f"Columns: {result.column_names}")

            # Show sample data
            df = result.to_pandas()
            if len(df) > 0:
                sample = df.iloc[0]
                self.logger.info("=== Sample IMDB Entry ===")
                self.logger.info(f"Text: {sample.get('text', 'N/A')[:200]}...")
                self.logger.info(
                    f"Label: {sample.get('label', 'N/A')} "
                    f"({'Positive' if sample.get('label') == 1 else 'Negative'})"
                )
        return result

    def get_imdb_data(self, num_partitions: int = 4) -> pa.Table:
        """Retrieve IMDB data from Arrow Cache."""
        self.logger.info("Fetching IMDB data from Arrow Cache...")

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

                            except Exception as worker_error:
                                self.logger.warning(
                                    f"Failed to query worker {worker_uri}: {worker_error}"
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
        self.logger.info(f"Total IMDB samples retrieved: {len(result)}")

        return result


class IMDBDataset(Dataset):
    """PyTorch dataset for IMDB movie reviews."""

    def __init__(self, data: pa.Table, tokenizer, max_length: int = 512):
        self.data = data
        self.tokenizer = tokenizer
        self.max_length = max_length

        # Convert to pandas for easier manipulation
        self.df = data.to_pandas()

        logger.info(f"IMDB dataset initialized with {len(self.df)} samples")
        logger.info(f"Columns: {list(self.df.columns)}")

        # Verify required columns
        if "text" not in self.df.columns:
            raise ValueError("Required column 'text' not found in IMDB data")
        if "label" in self.df.columns:
            logger.info(
                f"Label distribution: {self.df['label'].value_counts().to_dict()}"
            )

    def __len__(self):
        return len(self.df)

    def __getitem__(self, idx):
        row = self.df.iloc[idx]
        text = str(row["text"])

        # For sentiment classification, we can format the text with label information
        if "label" in row and not pd.isna(row["label"]):
            sentiment = "positive" if row["label"] == 1 else "negative"
            formatted_text = f"Review: {text}\nSentiment: {sentiment}"
        else:
            formatted_text = text

        # Tokenize
        encoding = self.tokenizer(
            formatted_text,
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


def ensure_bucket(session, bucket_name: str):
    """Ensure S3 bucket exists."""
    s3 = session.client("s3")
    try:
        s3.head_bucket(Bucket=bucket_name)
        logger.info(f"S3 bucket '{bucket_name}' exists.")
    except Exception:
        logger.info(f"Creating S3 bucket '{bucket_name}'...")
        s3.create_bucket(Bucket=bucket_name)


def ensure_glue_db(session, db_name: str):
    """Ensure Glue database exists."""
    glue = session.client("glue")
    try:
        glue.get_database(Name=db_name)
        logger.info(f"Glue database '{db_name}' exists.")
    except Exception:
        logger.info(f"Creating Glue database '{db_name}'...")
        glue.create_database(DatabaseInput={"Name": db_name})


def save_training_run_to_iceberg(session, run_data: Dict):
    """Save training run metadata to Iceberg table."""
    try:
        # Ensure AWS region is set in environment for pyiceberg
        import os

        from pyiceberg.catalog.glue import GlueCatalog

        os.environ["AWS_DEFAULT_REGION"] = AWS_REGION
        os.environ["AWS_REGION"] = AWS_REGION

        # Create catalog with explicit region configuration
        catalog_props = {
            "warehouse": WAREHOUSE_S3,
            "region_name": AWS_REGION,
            "region": AWS_REGION,
            "aws_region": AWS_REGION,
        }

        catalog = GlueCatalog(name="glue", **catalog_props)

        # Try to load existing table, create if it doesn't exist
        try:
            table = catalog.load_table(f"{GLUE_DB}.{RUNS_TABLE}")
        except Exception:
            logger.info(f"Creating Iceberg table {GLUE_DB}.{RUNS_TABLE}")

            from pyiceberg.schema import Schema

            schema = Schema(
                NestedField(
                    field_id=1, name="run_id", field_type=StringType(), required=True
                ),
                NestedField(
                    field_id=2,
                    name="timestamp",
                    field_type=TimestampType(),
                    required=True,
                ),
                NestedField(
                    field_id=3,
                    name="model_name",
                    field_type=StringType(),
                    required=True,
                ),
                NestedField(
                    field_id=4,
                    name="dataset_samples",
                    field_type=LongType(),
                    required=True,
                ),
                NestedField(
                    field_id=5, name="epochs", field_type=LongType(), required=True
                ),
                NestedField(
                    field_id=6, name="batch_size", field_type=LongType(), required=True
                ),
                NestedField(
                    field_id=7,
                    name="learning_rate",
                    field_type=DoubleType(),
                    required=True,
                ),
                NestedField(
                    field_id=8, name="max_length", field_type=LongType(), required=True
                ),
                NestedField(
                    field_id=9,
                    name="training_time_seconds",
                    field_type=DoubleType(),
                    required=True,
                ),
                NestedField(
                    field_id=10,
                    name="data_source",
                    field_type=StringType(),
                    required=True,
                ),
                NestedField(
                    field_id=11,
                    name="arrow_cache_used",
                    field_type=StringType(),
                    required=True,
                ),
            )

            table = catalog.create_table(
                f"{GLUE_DB}.{RUNS_TABLE}", schema=schema, partition_spec=PartitionSpec()
            )

        # Convert run data to PyArrow table with proper column names
        run_table = pa.table(
            [
                [run_data["run_id"]],
                [run_data["timestamp"]],
                [run_data["model_name"]],
                [run_data["dataset_samples"]],
                [run_data["epochs"]],
                [run_data["batch_size"]],
                [run_data["learning_rate"]],
                [run_data["max_length"]],
                [run_data["training_time_seconds"]],
                [run_data["data_source"]],
                [run_data["arrow_cache_used"]],
            ],
            names=[
                "run_id",
                "timestamp",
                "model_name",
                "dataset_samples",
                "epochs",
                "batch_size",
                "learning_rate",
                "max_length",
                "training_time_seconds",
                "data_source",
                "arrow_cache_used",
            ],
        )

        table.append(run_table)
        logger.info(f"Training run metadata saved to {GLUE_DB}.{RUNS_TABLE}")

    except Exception as e:
        logger.warning(f"Failed to save training run to Iceberg: {e}")


def main():
    parser = argparse.ArgumentParser(
        description="Train model on IMDB dataset using Arrow Cache"
    )
    parser.add_argument(
        "--model-name", default="distilgpt2", help="Model to use for training"
    )
    parser.add_argument(
        "--use-arrow-cache",
        action="store_true",
        help="Use Arrow Cache for data loading",
    )
    parser.add_argument(
        "--max-samples",
        type=int,
        default=1000,
        help="Maximum samples to use for training",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="Run without actual training"
    )
    parser.add_argument(
        "--skip-checkpoint",
        action="store_true",
        help="Skip saving checkpoint to S3 (for testing)",
    )
    parser.add_argument(
        "--use-irsa", action="store_true", help="Use IRSA (no AWS profile)"
    )
    parser.add_argument(
        "--aws-profile",
        default="root-ricardo",
        help="AWS profile name (ignored if --use-irsa)",
    )
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

    args = parser.parse_args()

    # Set seeds for reproducibility
    torch.manual_seed(SEED)

    logger.info("🚀 Starting IMDB training with Arrow Cache integration")
    logger.info(f"Model: {args.model_name}")
    logger.info(f"Use Arrow Cache: {args.use_arrow_cache}")
    logger.info(f"Max samples: {args.max_samples}")

    # AWS session
    if args.use_irsa:
        # Use IRSA - no profile needed, credentials from environment/metadata service
        session = boto3.Session(region_name=AWS_REGION)
        logger.info("Using IRSA for AWS authentication")
    else:
        # Use specified AWS profile
        session = boto3.Session(profile_name=args.aws_profile, region_name=AWS_REGION)
        logger.info(f"Using AWS profile: {args.aws_profile}")
    ensure_bucket(session, CKPT_BUCKET)
    ensure_glue_db(session, GLUE_DB)

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
            cache_client = IMDBArrowCacheClient(
                args.head_host, args.head_port, args.in_cluster
            )
            cache_client.connect()

            # Get data from cache
            arrow_data = cache_client.get_imdb_data()

            # Limit samples if specified
            if args.max_samples and len(arrow_data) > args.max_samples:
                # Take a random sample
                import random

                indices = random.sample(range(len(arrow_data)), args.max_samples)
                arrow_data = arrow_data.take(indices)
                logger.info(
                    f"Using {len(arrow_data)} samples (limited from full dataset)"
                )

            dataset = IMDBDataset(arrow_data, tokenizer, MAX_LENGTH)
            data_source = "arrow_cache"

        except Exception as e:
            logger.error(f"Failed to load from Arrow Cache: {e}")
            logger.info("Falling back to direct Iceberg access...")

            # Fallback to direct Iceberg access
            from pyiceberg.catalog.glue import GlueCatalog

            catalog = GlueCatalog(
                name="glue", warehouse=WAREHOUSE_S3, region_name=AWS_REGION
            )
            table = catalog.load_table(f"{GLUE_DB}.imdb")

            scan = table.scan()
            arrow_data = scan.to_arrow()

            # Limit samples if specified
            if args.max_samples and len(arrow_data) > args.max_samples:
                import random

                indices = random.sample(range(len(arrow_data)), args.max_samples)
                arrow_data = arrow_data.take(indices)
                logger.info(
                    f"Using {len(arrow_data)} samples (limited from full dataset)"
                )

            dataset = IMDBDataset(arrow_data, tokenizer, MAX_LENGTH)
            data_source = "iceberg_direct"
    else:
        logger.info("📊 Loading data directly from Iceberg...")
        from pyiceberg.catalog.glue import GlueCatalog

        catalog = GlueCatalog(
            name="glue", warehouse=WAREHOUSE_S3, region_name=AWS_REGION
        )
        table = catalog.load_table(f"{GLUE_DB}.imdb")

        scan = table.scan()
        arrow_data = scan.to_arrow()

        # Limit samples if specified
        if args.max_samples and len(arrow_data) > args.max_samples:
            import random

            indices = random.sample(range(len(arrow_data)), args.max_samples)
            arrow_data = arrow_data.take(indices)
            logger.info(f"Using {len(arrow_data)} samples (limited from full dataset)")

        dataset = IMDBDataset(arrow_data, tokenizer, MAX_LENGTH)
        data_source = "iceberg_direct"

    logger.info(f"Filtered dataset size: {len(dataset)} samples")

    # Create data loader
    dataloader = DataLoader(dataset, batch_size=BATCH_SIZE, shuffle=True)
    logger.info(f"Dataset loaded: {len(dataset)} samples, {len(dataloader)} batches")

    if args.dry_run:
        logger.info("🧪 Dry run mode - skipping actual training")
        logger.info(f"Would train on {len(dataset)} samples for {EPOCHS} epochs")
        return

    # Setup training
    logger.info("🏋️ Setting up training...")

    # Training arguments
    training_args = TrainingArguments(
        output_dir="./results",
        num_train_epochs=EPOCHS,
        per_device_train_batch_size=BATCH_SIZE,
        gradient_accumulation_steps=GRADIENT_ACCUMULATION_STEPS,
        learning_rate=LR,
        logging_steps=10,
        save_strategy="no",  # Don't save intermediate checkpoints
        logging_dir="./logs",
    )

    # Create trainer
    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=dataset,
        tokenizer=tokenizer,
    )

    # Start training
    logger.info(f"🎯 Starting training for {EPOCHS} epochs...")
    start_time = time.time()

    try:
        trainer.train()

        training_time = time.time() - start_time
        logger.info(f"✅ Training completed in {training_time:.2f} seconds")

        # Save training run metadata
        run_data = {
            "run_id": hashlib.md5(
                f"{args.model_name}_{int(start_time)}".encode()
            ).hexdigest()[:8],
            "timestamp": datetime.now(timezone.utc),
            "model_name": args.model_name,
            "dataset_samples": len(dataset),
            "epochs": EPOCHS,
            "batch_size": BATCH_SIZE,
            "learning_rate": LR,
            "max_length": MAX_LENGTH,
            "training_time_seconds": training_time,
            "data_source": data_source,
            "arrow_cache_used": str(args.use_arrow_cache),
        }

        save_training_run_to_iceberg(session, run_data)

        # Save final model if not skipping checkpoints
        if not args.skip_checkpoint:
            model_save_path = f"./final_model_{run_data['run_id']}"
            trainer.save_model(model_save_path)
            logger.info(f"💾 Model saved to {model_save_path}")

            # Upload to S3
            try:
                s3_path = f"s3://{CKPT_BUCKET}/{CKPT_PREFIX}/{run_data['run_id']}/"
                subprocess.run(
                    ["aws", "s3", "cp", model_save_path, s3_path, "--recursive"],
                    check=True,
                )
                logger.info(f"📦 Model uploaded to {s3_path}")
            except Exception as e:
                logger.warning(f"Failed to upload model to S3: {e}")

    except Exception as e:
        logger.error(f"❌ Training failed: {e}")
        raise


if __name__ == "__main__":
    main()
