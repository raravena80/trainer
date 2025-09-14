#!/usr/bin/env python3
"""
Alpaca Dataset Training Script with Arrow Cache Integration

This script trains a language model on the Alpaca dataset using:
1. Arrow Cache for distributed data access
2. PyTorch/Transformers for model training
3. Iceberg for experiment logging
4. Real Alpaca instruction-following data

Schema of Alpaca dataset:
- instruction: The instruction given to the model
- input: Additional input context (optional)
- output: The expected output
- text: Combined formatted text for training
"""

import argparse
import hashlib
import io
import logging
import os
import platform
import subprocess
import sys
import time
from datetime import datetime, timezone

import boto3
import pyarrow as pa
import pyarrow.flight as flight
import pyarrow.parquet as pq
import torch
from torch import optim
from torch.utils.data import DataLoader, Dataset
from transformers import AutoModelForCausalLM, AutoTokenizer

# Configure environment before importing our modules
os.environ["TOKENIZERS_PARALLELISM"] = "false"
sys.path.append(os.path.join(os.path.dirname(__file__), "..", "lib"))

from arrow_cache_client import BaseArrowCacheClient  # noqa: E402
from pyiceberg.catalog import load_catalog  # noqa: E402
from pyiceberg.partitioning import PartitionSpec  # noqa: E402
from pyiceberg.schema import NestedField, Schema  # noqa: E402
from pyiceberg.types import (  # noqa: E402
    FloatType,
    LongType,
    MapType,
    StringType,
    TimestampType,
)

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
RUNS_TABLE = "alpaca_training_runs"

# Iceberg warehouse for training logs
WAREHOUSE_S3 = "s3://ricardo.hf.datasets/iceberg-warehouse"

# Model checkpoints
CKPT_BUCKET = "ricardo.hf.datasets"
CKPT_PREFIX = "alpaca_models"

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
ARROW_CACHE_NAMESPACE = "arrow-cache-demo"
# =======================================================


class AlpacaArrowCacheClient(BaseArrowCacheClient):
    """Arrow Cache client specialized for Alpaca dataset."""

    def __init__(
        self, host: str = "localhost", port: int = 50051, in_cluster: bool = False
    ):
        super().__init__(host, port)
        self.namespace = ARROW_CACHE_NAMESPACE
        self.in_cluster = in_cluster

    def process_query_result(self, result: pa.Table, description: str):
        """Process Alpaca-specific query results."""
        if len(result) > 0:
            self.logger.info(f"Retrieved {len(result)} Alpaca samples")
            self.logger.info(f"Columns: {result.column_names}")

            # Show sample data
            df = result.to_pandas()
            if len(df) > 0:
                sample = df.iloc[0]
                self.logger.info("=== Sample Alpaca Entry ===")
                self.logger.info(
                    f"Instruction: {sample.get('instruction', 'N/A')[:100]}..."
                )
                self.logger.info(f"Input: {sample.get('input', 'N/A')[:50]}...")
                self.logger.info(f"Output: {sample.get('output', 'N/A')[:100]}...")
        return result

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
            return super().translate_worker_uri(worker_uri, namespace)

    def get_alpaca_data(self, num_partitions: int = 4) -> pa.Table:
        """Retrieve Alpaca data from Arrow Cache."""
        self.logger.info("Fetching Alpaca data from Arrow Cache...")

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
                                continue

            except Exception as e:
                self.logger.warning(
                    f"Failed to get flight info for partition {partition_id}: {e}"
                )
                continue

            time.sleep(0.5)  # Small delay between partitions

        if all_data:
            # Concatenate all partition data
            combined_data = pa.concat_tables(all_data)
            self.logger.info(f"Total Alpaca samples retrieved: {len(combined_data)}")
            return combined_data
        else:
            raise RuntimeError("Failed to retrieve any data from Arrow Cache")


class AlpacaDataset(Dataset):
    """PyTorch Dataset for Alpaca instruction-following data."""

    def __init__(self, arrow_table: pa.Table, tokenizer, max_length: int = 512):
        self.data = arrow_table.to_pandas()
        self.tokenizer = tokenizer
        self.max_length = max_length

        # Filter out entries without required fields
        required_fields = ["instruction", "output"]
        for field in required_fields:
            if field not in self.data.columns:
                raise ValueError(f"Missing required field: {field}")

        # Remove rows with null values in critical fields
        self.data = self.data.dropna(subset=required_fields)
        logger.info(f"Filtered dataset size: {len(self.data)} samples")

    def __len__(self):
        return len(self.data)

    def __getitem__(self, idx):
        row = self.data.iloc[idx]

        # Format the instruction-following prompt
        instruction = row["instruction"]
        input_text = row.get("input", "")
        output = row["output"]

        if input_text.strip():
            prompt = (
                f"### Instruction:\n{instruction}\n\n### Input:\n{input_text}"
                f"\n\n### Response:\n{output}"
            )
        else:
            prompt = f"### Instruction:\n{instruction}\n\n### Response:\n{output}"

        # Tokenize
        encoding = self.tokenizer(
            prompt,
            truncation=True,
            padding="max_length",
            max_length=self.max_length,
            return_tensors="pt",
        )

        return {
            "input_ids": encoding["input_ids"].squeeze(),
            "attention_mask": encoding["attention_mask"].squeeze(),
            "labels": encoding[
                "input_ids"
            ].squeeze(),  # For causal LM, labels = input_ids
        }


def git_commit_hash():
    try:
        return (
            subprocess.check_output(
                ["git", "rev-parse", "HEAD"], stderr=subprocess.DEVNULL
            )
            .decode()
            .strip()
        )
    except Exception:
        return "unknown"


def sha256_bytesio(buf: io.BytesIO) -> str:
    h = hashlib.sha256()
    h.update(buf.getbuffer())
    return h.hexdigest()


def ensure_glue_db(session, name: str):
    glue = session.client("glue", region_name=AWS_REGION)
    try:
        glue.get_database(Name=name)
        logger.info(f"Glue database '{name}' exists.")
    except glue.exceptions.EntityNotFoundException:
        logger.info(f"Creating Glue database '{name}'...")
        glue.create_database(DatabaseInput={"Name": name})
        logger.info("Created.")


def ensure_bucket(session, bucket: str):
    s3 = session.client("s3", region_name=AWS_REGION)
    try:
        s3.head_bucket(Bucket=bucket)
        logger.info(f"S3 bucket '{bucket}' exists.")
    except Exception:
        raise RuntimeError(f"S3 bucket '{bucket}' does not exist or is not accessible.")


def build_runs_schema() -> Schema:
    """Build schema for training runs logging."""
    field_id = 1

    def F(name, typ, required=False):
        nonlocal field_id
        nf = NestedField(field_id, name, typ, required=required)
        field_id += 1
        return nf

    # Helper for map types
    def create_map_type():
        nonlocal field_id
        key_id = field_id
        field_id += 1
        value_id = field_id
        field_id += 1
        return MapType(
            key_id=key_id,
            key_type=StringType(),
            value_id=value_id,
            value_type=StringType(),
            value_required=False,
        )

    return Schema(
        F("run_id", StringType(), True),
        F("timestamp", TimestampType()),
        F("model_name", StringType()),
        F("dataset", StringType()),
        F("train_size", LongType()),
        F("epochs", LongType()),
        F("batch_size", LongType()),
        F("lr", FloatType()),
        F("max_length", LongType()),
        F("seed", LongType()),
        F("train_loss", FloatType()),
        F("duration_sec", FloatType()),
        F("checkpoint_uri", StringType()),
        F("checkpoint_sha256", StringType()),
        F("git_commit", StringType()),
        F("env", create_map_type()),
        F("hparams", create_map_type()),
        F("arrow_cache_used", StringType()),  # Whether Arrow Cache was used
    )


def main():
    parser = argparse.ArgumentParser(
        description="Train model on Alpaca dataset using Arrow Cache"
    )
    parser.add_argument(
        "--model-name",
        default="microsoft/DialoGPT-small",
        help="Model to use for training",
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

    logger.info("🚀 Starting Alpaca training with Arrow Cache integration")
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
            cache_client = AlpacaArrowCacheClient(
                args.head_host, args.head_port, args.in_cluster
            )
            cache_client.connect()

            # Get data from cache
            arrow_data = cache_client.get_alpaca_data()

            # Limit samples if specified
            if args.max_samples and len(arrow_data) > args.max_samples:
                # Take a random sample
                import random

                indices = random.sample(range(len(arrow_data)), args.max_samples)
                arrow_data = arrow_data.take(indices)
                logger.info(
                    f"Using {len(arrow_data)} samples (limited from full dataset)"
                )

            dataset = AlpacaDataset(arrow_data, tokenizer, MAX_LENGTH)
            data_source = "arrow_cache"

        except Exception as e:
            logger.error(f"Failed to load from Arrow Cache: {e}")
            logger.info("Falling back to direct Iceberg access...")

            # Fallback to direct Iceberg access
            from pyiceberg.catalog.glue import GlueCatalog

            catalog = GlueCatalog(
                name="glue_catalog",
                warehouse=WAREHOUSE_S3,
                profile_name=AWS_PROFILE,
                region_name=AWS_REGION,
            )

            table = catalog.load_table("hf_datasets.tatsu-lab_alpaca")
            scan = table.scan()
            arrow_data = scan.to_arrow()

            if args.max_samples and len(arrow_data) > args.max_samples:
                import random

                indices = random.sample(range(len(arrow_data)), args.max_samples)
                arrow_data = arrow_data.take(indices)

            dataset = AlpacaDataset(arrow_data, tokenizer, MAX_LENGTH)
            data_source = "direct_iceberg"
    else:
        logger.info("📊 Loading data directly from Iceberg...")
        from pyiceberg.catalog.glue import GlueCatalog

        catalog = GlueCatalog(
            name="glue_catalog",
            warehouse=WAREHOUSE_S3,
            profile_name=AWS_PROFILE,
            region_name=AWS_REGION,
        )

        table = catalog.load_table("hf_datasets.tatsu-lab_alpaca")
        scan = table.scan()
        arrow_data = scan.to_arrow()

        if args.max_samples and len(arrow_data) > args.max_samples:
            import random

            indices = random.sample(range(len(arrow_data)), args.max_samples)
            arrow_data = arrow_data.take(indices)

        dataset = AlpacaDataset(arrow_data, tokenizer, MAX_LENGTH)
        data_source = "direct_iceberg"

    # Create data loader
    data_loader = DataLoader(dataset, batch_size=BATCH_SIZE, shuffle=True)
    logger.info(f"Dataset loaded: {len(dataset)} samples, {len(data_loader)} batches")

    if args.dry_run:
        logger.info("🧪 Dry run mode - skipping actual training")
        logger.info(f"Would train on {len(dataset)} samples for {EPOCHS} epochs")
        return

    # Training setup
    logger.info("🏋️ Setting up training...")
    optimizer = optim.AdamW(model.parameters(), lr=LR)

    # Training loop
    model.train()
    total_loss = 0.0
    step = 0

    t0 = time.time()
    logger.info(f"🎯 Starting training for {EPOCHS} epochs...")

    for epoch in range(EPOCHS):
        epoch_loss = 0.0
        for batch_idx, batch in enumerate(data_loader):
            input_ids = batch["input_ids"]
            attention_mask = batch["attention_mask"]
            labels = batch["labels"]

            # Forward pass
            outputs = model(
                input_ids=input_ids, attention_mask=attention_mask, labels=labels
            )
            loss = outputs.loss

            # Backward pass
            loss = loss / GRADIENT_ACCUMULATION_STEPS
            loss.backward()

            step += 1
            epoch_loss += loss.item()
            total_loss += loss.item()

            if step % GRADIENT_ACCUMULATION_STEPS == 0:
                optimizer.step()
                optimizer.zero_grad()

            if batch_idx % 10 == 0:
                logger.info(
                    f"Epoch {epoch+1}/{EPOCHS}, Batch {batch_idx}/"
                    f"{len(data_loader)}, Loss: {loss.item():.4f}"
                )

        avg_epoch_loss = epoch_loss / len(data_loader)
        logger.info(
            f"✅ Epoch {epoch+1}/{EPOCHS} completed. Average loss: {avg_epoch_loss:.4f}"
        )

    duration_sec = time.time() - t0
    avg_train_loss = total_loss / (len(data_loader) * EPOCHS)

    logger.info(
        f"🎉 Training completed in {duration_sec:.2f}s. Average loss: {avg_train_loss:.4f}"
    )

    # Save model checkpoint
    run_id = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    ckpt_key = f"{CKPT_PREFIX}/alpaca_{args.model_name.replace('/', '_')}_{run_id}.pt"
    checkpoint_uri = f"s3://{CKPT_BUCKET}/{ckpt_key}"

    if args.skip_checkpoint:
        logger.info("💾 Skipping checkpoint save (--skip-checkpoint specified)")
        ckpt_hash = "skipped"
    else:
        logger.info("💾 Preparing model checkpoint...")

        # Configure S3 client with shorter timeout
        from botocore.config import Config

        s3_config = Config(
            connect_timeout=30,
            read_timeout=300,  # 5 minutes
            retries={"max_attempts": 3},
        )
        s3 = session.client("s3", region_name=AWS_REGION, config=s3_config)

        logger.info("💾 Serializing model state...")
        ckpt_buf = io.BytesIO()
        torch.save(model.state_dict(), ckpt_buf)
        checkpoint_size_mb = len(ckpt_buf.getvalue()) / (1024 * 1024)
        logger.info(f"💾 Checkpoint size: {checkpoint_size_mb:.1f} MB")

        ckpt_buf.seek(0)
        ckpt_hash = sha256_bytesio(ckpt_buf)
        ckpt_buf.seek(0)

        logger.info(f"💾 Uploading checkpoint to s3://{CKPT_BUCKET}/{ckpt_key}...")
        try:
            s3.upload_fileobj(ckpt_buf, CKPT_BUCKET, ckpt_key)
            logger.info(f"💾 Checkpoint saved successfully: {checkpoint_uri}")
        except Exception as e:
            logger.error(f"Failed to upload checkpoint: {e}")
            # Continue without checkpoint for now
            ckpt_hash = "upload_failed"

    # Log training run to Iceberg
    logger.info("📝 Logging training run to Iceberg...")

    # Environment info
    env_map = {
        "python": platform.python_version(),
        "platform": platform.platform(),
        "torch": torch.__version__,
    }
    try:
        import transformers

        env_map["transformers"] = transformers.__version__
    except Exception:
        pass

    # Hyperparameters
    hparams_map = {
        "model_name": args.model_name,
        "epochs": str(EPOCHS),
        "batch_size": str(BATCH_SIZE),
        "lr": str(LR),
        "max_length": str(MAX_LENGTH),
        "seed": str(SEED),
        "max_samples": str(args.max_samples),
    }

    # Prepare Arrow record - match Iceberg table schema exactly
    arrow_schema = pa.schema(
        [
            pa.field("run_id", pa.string(), nullable=False),  # Required field
            pa.field("timestamp", pa.timestamp("us"), nullable=True),
            pa.field("model_name", pa.string(), nullable=True),
            pa.field("dataset", pa.string(), nullable=True),
            pa.field("train_size", pa.int64(), nullable=True),
            pa.field("epochs", pa.int64(), nullable=True),
            pa.field("batch_size", pa.int64(), nullable=True),
            pa.field("lr", pa.float32(), nullable=True),
            pa.field("max_length", pa.int64(), nullable=True),
            pa.field("seed", pa.int64(), nullable=True),
            pa.field("train_loss", pa.float32(), nullable=True),
            pa.field("duration_sec", pa.float32(), nullable=True),
            pa.field("checkpoint_uri", pa.string(), nullable=True),
            pa.field("checkpoint_sha256", pa.string(), nullable=True),
            pa.field("git_commit", pa.string(), nullable=True),
            pa.field("env", pa.map_(pa.string(), pa.string()), nullable=True),
            pa.field("hparams", pa.map_(pa.string(), pa.string()), nullable=True),
            pa.field("arrow_cache_used", pa.string(), nullable=True),
        ]
    )

    now = datetime.now(timezone.utc)
    record_tbl = pa.Table.from_arrays(
        [
            pa.array([run_id]),
            pa.array([now], type=pa.timestamp("us")),
            pa.array([args.model_name]),
            pa.array(["tatsu-lab_alpaca"]),
            pa.array([len(dataset)], type=pa.int64()),
            pa.array([EPOCHS], type=pa.int64()),
            pa.array([BATCH_SIZE], type=pa.int64()),
            pa.array([float(LR)], type=pa.float32()),
            pa.array([MAX_LENGTH], type=pa.int64()),
            pa.array([SEED], type=pa.int64()),
            pa.array([float(avg_train_loss)], type=pa.float32()),
            pa.array([float(duration_sec)], type=pa.float32()),
            pa.array([checkpoint_uri]),
            pa.array([ckpt_hash]),
            pa.array([git_commit_hash()]),
            pa.array([env_map], type=pa.map_(pa.string(), pa.string())),
            pa.array([hparams_map], type=pa.map_(pa.string(), pa.string())),
            pa.array([data_source]),
        ],
        schema=arrow_schema,
    )

    # Save to Iceberg
    catalog = load_catalog(
        "glue",
        **{
            "type": "glue",
            "profile_name": AWS_PROFILE,
            "region": AWS_REGION,
            "warehouse": WAREHOUSE_S3,
        },
    )

    # Create runs table if needed
    runs_schema = build_runs_schema()
    runs_table_id = f"{GLUE_DB}.{RUNS_TABLE}"

    if not catalog.table_exists(runs_table_id):
        logger.info(f"Creating training runs table {runs_table_id}...")
        catalog.create_table(
            identifier=runs_table_id, schema=runs_schema, partition_spec=PartitionSpec()
        )

    runs_table = catalog.load_table(runs_table_id)

    # Save record
    table_location = runs_table.location().rstrip("/")
    data_key = f"data/run={run_id}.parquet"
    data_s3_uri = f"{table_location}/{data_key}"

    buf = io.BytesIO()
    pq.write_table(record_tbl, buf)
    buf.seek(0)

    # Create S3 client for logging data upload
    s3_logging = session.client("s3", region_name=AWS_REGION)
    loc_bucket, loc_prefix = table_location[5:].split("/", 1)
    s3_logging.upload_fileobj(buf, loc_bucket, f"{loc_prefix}/{data_key}")

    # Register with Iceberg using table append
    try:
        runs_table.append(record_tbl)
        logger.info("✅ Training run logged using table.append()")
    except Exception as e:
        logger.warning(
            f"Failed to use table.append(), using manual file registration: {e}"
        )
        # Alternative approach - just upload the file without Iceberg registration for now
        logger.info(f"Data saved to: {data_s3_uri}")

    snap = runs_table.current_snapshot()
    logger.info(
        f"✅ Training run logged to Iceberg with "
        f"snapshot_id={snap.snapshot_id if snap else 'unknown'}"
    )

    logger.info("🎊 Training pipeline completed successfully!")


if __name__ == "__main__":
    main()
