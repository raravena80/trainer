#!/usr/bin/env python3
"""
Script to ingest existing IMDB parquet files into an Iceberg table.

This script takes the raw parquet files created by hf_to_iceberg.py and properly
ingests them into the Iceberg table structure with data files and manifest entries.
"""

import argparse
import logging
import tempfile

import boto3
import pyarrow.parquet as pq
from pyiceberg.catalog.glue import GlueCatalog

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def main():
    parser = argparse.ArgumentParser(
        description="Ingest IMDB parquet files into Iceberg table"
    )
    parser.add_argument(
        "--bucket", required=True, help="S3 bucket name (e.g., ricardo.hf.datasets)"
    )
    parser.add_argument("--profile", required=True, help="AWS profile name")
    parser.add_argument(
        "--table", default="hf_datasets.imdb_reviews", help="Full table identifier"
    )
    parser.add_argument(
        "--iceberg-path", default="iceberg", help="Path prefix for Iceberg table in S3"
    )

    args = parser.parse_args()

    # Initialize AWS session
    session = boto3.Session(profile_name=args.profile)
    s3_client = session.client("s3")

    # Initialize Iceberg catalog
    catalog = GlueCatalog(
        name="glue_catalog",
        warehouse=f"s3://{args.bucket}/{args.iceberg_path}",
        profile_name=args.profile,
        region_name="us-east-1",
    )

    # Load the existing table
    try:
        table = catalog.load_table(args.table)
        logger.info(f"Loaded existing table: {args.table}")
    except Exception as e:
        logger.error(f"Failed to load table {args.table}: {e}")
        return 1

    # List of parquet files to ingest
    parquet_files = ["train.parquet", "test.parquet", "unsupervised.parquet"]

    for parquet_file in parquet_files:
        logger.info(f"Processing {parquet_file}...")

        try:
            # Download parquet file temporarily
            with tempfile.NamedTemporaryFile(suffix=".parquet") as tmp_file:
                logger.info(f"Downloading s3://{args.bucket}/{parquet_file}")
                s3_client.download_file(args.bucket, parquet_file, tmp_file.name)

                # Read parquet file
                arrow_table = pq.read_table(tmp_file.name)
                logger.info(f"Read {len(arrow_table)} rows from {parquet_file}")

                # Check if schema matches
                logger.info(f"Schema: {arrow_table.schema}")

                # Append to Iceberg table
                logger.info("Appending data to Iceberg table...")
                table.append(arrow_table)
                logger.info(
                    f"Successfully appended {len(arrow_table)} rows from {parquet_file}"
                )

        except Exception as e:
            logger.error(f"Failed to process {parquet_file}: {e}")
            continue

    logger.info("Ingestion complete!")

    # Print table info
    try:
        logger.info(f"Table location: {table.location()}")
        logger.info(f"Table schema: {table.schema()}")
        # Get current snapshot info if available
        current_snapshot = table.current_snapshot()
        if current_snapshot:
            logger.info(f"Current snapshot ID: {current_snapshot.snapshot_id}")
            logger.info(f"Manifest list: {current_snapshot.manifest_list}")

    except Exception as e:
        logger.warning(f"Could not get table info: {e}")


if __name__ == "__main__":
    exit(main())
