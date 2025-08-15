#!/usr/bin/env python3
"""
Complete IMDB to Iceberg Ingestion Script

This script handles the complete workflow:
1. Downloads IMDB dataset from HuggingFace
2. Creates S3 bucket and Glue database if needed
3. Creates Iceberg table with proper schema
4. Ingests all data directly into Iceberg table

No intermediate parquet files needed - complete one-stop solution.
"""

import argparse
import logging
import tempfile

import boto3
import pyarrow as pa
import pyarrow.parquet as pq
from datasets import load_dataset
from pyiceberg.catalog.glue import GlueCatalog
from pyiceberg.partitioning import PartitionSpec
from pyiceberg.schema import NestedField, Schema
from pyiceberg.types import LongType, StringType

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def ensure_s3_bucket_exists(bucket_name, boto3_session):
    """Ensure S3 bucket exists, create if it doesn't."""
    s3_client = boto3_session.client("s3")
    try:
        s3_client.head_bucket(Bucket=bucket_name)
        logger.info(f"S3 bucket '{bucket_name}' exists.")
    except Exception:
        logger.info(f"S3 bucket '{bucket_name}' not found. Creating...")
        try:
            # For us-east-1, don't specify LocationConstraint
            region = boto3_session.region_name or "us-east-1"
            if region == "us-east-1":
                s3_client.create_bucket(Bucket=bucket_name)
            else:
                s3_client.create_bucket(
                    Bucket=bucket_name,
                    CreateBucketConfiguration={"LocationConstraint": region},
                )
            logger.info(f"S3 bucket '{bucket_name}' created.")
        except Exception as e:
            logger.error(f"Failed to create bucket {bucket_name}: {e}")
            raise


def ensure_glue_database_exists(database_name, boto3_session):
    """Ensure Glue database exists, create if it doesn't."""
    glue_client = boto3_session.client("glue")
    try:
        glue_client.get_database(Name=database_name)
        logger.info(f"Glue database '{database_name}' exists.")
    except glue_client.exceptions.EntityNotFoundException:
        logger.info(f"Glue database '{database_name}' not found. Creating...")
        glue_client.create_database(DatabaseInput={"Name": database_name})
        logger.info(f"Glue database '{database_name}' created.")


def create_iceberg_schema_from_hf_dataset(dataset):
    """Create Iceberg schema from HuggingFace dataset features."""
    arrow_schema = dataset["train"].features
    iceberg_fields = []
    field_id = 1

    for name, feature in arrow_schema.items():
        if feature.dtype in ["string", "object"]:
            typ = StringType()
        elif feature.dtype in ["int64", "int32"]:
            typ = LongType()
        else:
            typ = StringType()  # fallback
        iceberg_fields.append(NestedField(field_id, name, typ, required=False))
        field_id += 1

    return Schema(*iceberg_fields)


def main():
    parser = argparse.ArgumentParser(
        description="Complete IMDB to Iceberg ingestion - downloads from "
        "HuggingFace and creates Iceberg table"
    )
    parser.add_argument(
        "--bucket",
        default="ricardo.hf.datasets",
        help="S3 bucket name (default: ricardo.hf.datasets)",
    )
    parser.add_argument(
        "--profile",
        default="root-ricardo",
        help="AWS profile name (default: root-ricardo)",
    )
    parser.add_argument(
        "--dataset", default="imdb", help="HuggingFace dataset name (default: imdb)"
    )
    parser.add_argument(
        "--table", default="imdb_reviews", help="Table name (default: imdb_reviews)"
    )
    parser.add_argument(
        "--database",
        default="hf_datasets",
        help="Glue database name (default: hf_datasets)",
    )
    parser.add_argument(
        "--iceberg-path",
        default="iceberg",
        help="Path prefix for Iceberg table in S3 (default: iceberg)",
    )
    parser.add_argument(
        "--skip-download",
        action="store_true",
        help="Skip HuggingFace download, only ingest existing parquet files",
    )

    args = parser.parse_args()

    # Initialize AWS session
    session = boto3.Session(profile_name=args.profile)
    logger.info(f"Using AWS profile: {args.profile}")

    # Ensure S3 bucket exists
    ensure_s3_bucket_exists(args.bucket, session)

    # Ensure Glue database exists
    ensure_glue_database_exists(args.database, session)

    # Load or download HuggingFace dataset
    if not args.skip_download:
        logger.info(f"Loading HuggingFace dataset: {args.dataset}")
        dataset = load_dataset(args.dataset)
        logger.info(f"Dataset loaded with splits: {list(dataset.keys())}")
    else:
        logger.info("Skipping dataset download as requested")
        dataset = None

    # Initialize Iceberg catalog
    warehouse_path = f"s3://{args.bucket}/{args.iceberg_path}"
    catalog = GlueCatalog(
        name="glue_catalog",
        warehouse=warehouse_path,
        profile_name=args.profile,
        region_name="us-east-1",
    )

    table_identifier = f"{args.database}.{args.table}"

    # Create or load Iceberg table
    try:
        table = catalog.load_table(table_identifier)
        logger.info(f"Loaded existing table: {table_identifier}")
        logger.info(f"Table location: {table.location()}")

        # If we're not downloading, just show current table info
        if args.skip_download:
            current_snapshot = table.current_snapshot()
            if current_snapshot:
                logger.info(f"Current snapshot ID: {current_snapshot.snapshot_id}")
            else:
                logger.info("Table exists but has no data snapshots")
            return 0

    except Exception:
        if dataset is None:
            logger.error(
                "Cannot create table without dataset. Either remove "
                "--skip-download or ensure table exists."
            )
            return 1

        logger.info(f"Creating new table: {table_identifier}")

        # Create Iceberg schema from HuggingFace dataset
        iceberg_schema = create_iceberg_schema_from_hf_dataset(dataset)
        logger.info(
            f"Created schema with fields: {[f.name for f in iceberg_schema.fields]}"
        )

        # Create table
        table = catalog.create_table(
            identifier=table_identifier,
            schema=iceberg_schema,
            partition_spec=PartitionSpec(),  # No partitioning for simplicity
        )
        logger.info(f"Table '{table_identifier}' created at {table.location()}")

    # If we have dataset, ingest all splits directly into Iceberg
    if dataset is not None:
        total_records = 0

        for split_name, split_dataset in dataset.items():
            logger.info(f"Processing {split_name} split...")

            try:
                # Convert HuggingFace dataset to PyArrow Table
                logger.info(f"Converting {split_name} to Arrow table...")
                arrow_table = pa.Table.from_pydict(split_dataset[:])

                logger.info(f"Read {len(arrow_table)} rows from {split_name} split")
                logger.info(f"Schema: {arrow_table.schema}")

                # Append directly to Iceberg table
                logger.info(f"Appending {split_name} data to Iceberg table...")
                table.append(arrow_table)

                records_count = len(arrow_table)
                total_records += records_count
                logger.info(
                    f"Successfully appended {records_count} rows from {split_name} split"
                )

            except Exception as e:
                logger.error(f"Failed to process {split_name} split: {e}")
                continue

        logger.info(f"\n🎉 Ingestion complete! Total records ingested: {total_records}")

    # If skip_download but we want to ingest existing parquet files
    elif args.skip_download:
        logger.info("Checking for existing parquet files to ingest...")
        s3_client = session.client("s3")
        parquet_files = ["train.parquet", "test.parquet", "unsupervised.parquet"]

        total_records = 0
        for parquet_file in parquet_files:
            logger.info(f"Processing {parquet_file}...")

            try:
                # Check if file exists
                s3_client.head_object(Bucket=args.bucket, Key=parquet_file)

                # Download and process
                with tempfile.NamedTemporaryFile(suffix=".parquet") as tmp_file:
                    logger.info(f"Downloading s3://{args.bucket}/{parquet_file}")
                    s3_client.download_file(args.bucket, parquet_file, tmp_file.name)

                    # Read and append
                    arrow_table = pq.read_table(tmp_file.name)
                    logger.info(f"Read {len(arrow_table)} rows from {parquet_file}")

                    table.append(arrow_table)
                    total_records += len(arrow_table)
                    logger.info(
                        f"Successfully appended {len(arrow_table)} rows from {parquet_file}"
                    )

            except Exception as e:
                logger.warning(f"Could not process {parquet_file}: {e}")
                continue

        if total_records > 0:
            logger.info(
                f"\n🎉 Ingestion complete! Total records ingested from "
                f"parquet files: {total_records}"
            )

    # Print final table info
    try:
        logger.info("\n📊 Final Table Information:")
        logger.info(f"Table location: {table.location()}")
        logger.info(f"Table schema: {table.schema()}")

        current_snapshot = table.current_snapshot()
        if current_snapshot:
            logger.info(f"Current snapshot ID: {current_snapshot.snapshot_id}")
            logger.info(f"Manifest list: {current_snapshot.manifest_list}")
        else:
            logger.info("No data snapshots found - table may be empty")

    except Exception as e:
        logger.warning(f"Could not get table info: {e}")

    return 0


if __name__ == "__main__":
    exit(main())
