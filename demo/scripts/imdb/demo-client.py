#!/usr/bin/env python3
"""
IMDB Arrow Cache Demo Client

This script demonstrates how to interact with the distributed Arrow Cache system
using the IMDB dataset stored in an Iceberg table. It shows how to:
1. Connect to the head node
2. Query IMDB movie review data (text and labels)
3. Demonstrate distributed caching of real text data

The IMDB dataset contains:
- text: Movie review text
- label: Sentiment label (0=negative, 1=positive)

Prerequisites:
- pyarrow with flight support: pip install pyarrow
- grpcio: pip install grpcio

Usage:
    python3 demo/scripts/imdb/demo-client.py --host localhost --port 50051 --demo
"""

import argparse
import importlib.util
import logging
import os
import sys

import pyarrow as pa

# Add the lib directory to the Python path
sys.path.append(os.path.join(os.path.dirname(__file__), "..", "lib"))

# Load arrow_cache_client module
_spec = importlib.util.spec_from_file_location(
    "arrow_cache_client",
    os.path.join(os.path.dirname(__file__), "..", "lib", "arrow_cache_client.py"),
)
_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_module)
BaseArrowCacheClient = _module.BaseArrowCacheClient
S3Utils = _module.S3Utils

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


class IMDBArrowCacheClient(BaseArrowCacheClient):
    """Client for interacting with the distributed Arrow Cache system using IMDB data."""

    def __init__(self, host: str = "localhost", port: int = 50051):
        """Initialize the IMDB Arrow Cache client."""
        super().__init__(host, port)
        self.namespace = "arrow-cache-imdb"

    def get_imdb_data_files(self):
        """Get IMDB data file paths from the Iceberg table."""
        bucket_prefix = (
            "s3://ricardo.hf.datasets/iceberg/hf_datasets.db/imdb_reviews/data/"
        )
        return S3Utils.list_s3_files(bucket_prefix, profile="root-ricardo")

    def process_query_result(self, result: pa.Table, description: str):
        """Process IMDB-specific query results."""
        if len(result) > 0:
            self.logger.info(f"Columns: {result.column_names}")
            self.logger.info(f"Schema: {result.schema}")

            # Convert to pandas for easier display
            df = result.to_pandas()

            # Show sample reviews
            self.logger.info("=== Sample IMDB Reviews ===")
            for i in range(min(3, len(df))):
                row = df.iloc[i]
                sentiment = "Positive" if row["label"] == 1 else "Negative"
                review_preview = (
                    row["text"][:100] + "..." if len(row["text"]) > 100 else row["text"]
                )
                self.logger.info(f"Review {i+1} ({sentiment}): {review_preview}")

            # Show label distribution
            if "label" in df.columns:
                label_counts = df["label"].value_counts()
                self.logger.info("Label distribution in this partition:")
                self.logger.info(f"  Negative (0): {label_counts.get(0, 0)} reviews")
                self.logger.info(f"  Positive (1): {label_counts.get(1, 0)} reviews")

    def demonstrate_imdb_caching(self):
        """Demonstrate the caching functionality using IMDB movie review data."""
        self.logger.info("Starting IMDB Arrow Cache demonstration...")

        self.logger.info("=== IMDB Dataset Overview ===")
        self.logger.info("Dataset: IMDB Movie Reviews")
        self.logger.info("Schema: text (string), label (int64)")
        self.logger.info("Labels: 0=negative review, 1=positive review")
        self.logger.info("Total records: ~100,000 movie reviews")

        # Try to get real data file paths (for informational purposes)
        sample_files = self.get_imdb_data_files()

        if not sample_files:
            self.logger.info(
                "No S3 data files found in metadata, but system may still have cached data"
            )
        else:
            self.logger.info(f"Found {len(sample_files)} data files in S3:")
            for i, file_path in enumerate(sample_files, 1):
                self.logger.info(f"  {i}. {file_path}")

        try:
            # Step 1: Get flight info for different partitions
            self.logger.info(
                "=== Step 1: Getting partition information from head node ==="
            )

            total_partitions = 4  # Test with 4 partitions
            partition_infos = []

            for partition_id in range(total_partitions):
                self.logger.info(f"Getting flight info for partition {partition_id}")
                try:
                    flight_info = self.get_flight_info_for_partition(
                        partition_id, total_partitions
                    )
                    partition_infos.append((partition_id, flight_info))

                    self.logger.info(
                        f"Partition {partition_id}: {len(flight_info.endpoints)} worker endpoints"
                    )

                    # Show worker endpoints for this partition
                    for i, endpoint in enumerate(flight_info.endpoints):
                        if endpoint.locations:
                            worker_uri = endpoint.locations[0].uri
                            self.logger.info(f"  Worker {i}: {worker_uri}")

                except Exception as e:
                    self.logger.warning(
                        f"Failed to get flight info for partition {partition_id}: {e}"
                    )

                import time

                time.sleep(1)  # Small delay between requests

            # Step 2: Query IMDB data from workers directly
            self.logger.info("=== Step 2: Querying IMDB review data from workers ===")

            if partition_infos:
                self.logger.info(
                    f"Successfully got flight info for {len(partition_infos)} partitions"
                )

                # Query different ranges of IMDB reviews
                sample_queries = [
                    (0, 99, "First 100 reviews"),
                    (1000, 1099, "Reviews 1000-1099"),
                    (5000, 5049, "Mid-range reviews"),
                    (10000, 10099, "Later reviews"),
                ]

                self.query_workers_for_data(
                    partition_infos, sample_queries, self.namespace
                )
            else:
                self.logger.warning(
                    "No valid partition information received - cannot query data"
                )

        except Exception as e:
            self.logger.error(f"IMDB demo failed: {e}")
            raise

    def run_imdb_performance_test(self, num_queries: int = 5):
        """Run a performance test using IMDB data queries."""
        # Define realistic query ranges for IMDB data
        imdb_ranges = [
            (0, 999, "First 1000 reviews"),
            (1000, 2999, "Reviews 1000-2999"),
            (5000, 7999, "Mid-range reviews"),
            (10000, 12999, "Later reviews"),
            (20000, 24999, "Final batch"),
        ]

        self.run_performance_test(num_queries, imdb_ranges)


def main():
    """Main function to run the IMDB demo."""
    parser = argparse.ArgumentParser(description="IMDB Arrow Cache Demo Client")
    parser.add_argument(
        "--host", default="localhost", help="Arrow Cache head node host"
    )
    parser.add_argument(
        "--port", type=int, default=50051, help="Arrow Cache head node port"
    )
    parser.add_argument(
        "--demo", action="store_true", help="Run the full IMDB demonstration"
    )
    parser.add_argument(
        "--perf-test", action="store_true", help="Run IMDB performance test"
    )
    parser.add_argument(
        "--queries", type=int, default=5, help="Number of queries for performance test"
    )

    args = parser.parse_args()

    # Create and connect client
    client = IMDBArrowCacheClient(args.host, args.port)

    try:
        client.connect()

        if args.demo:
            client.demonstrate_imdb_caching()

        if args.perf_test:
            client.run_imdb_performance_test(args.queries)

        if not args.demo and not args.perf_test:
            logger.info("No action specified. Use --demo or --perf-test")
            logger.info("Example: python3 demo/scripts/imdb/demo-client.py --demo")

    except Exception as e:
        logger.error(f"IMDB demo failed: {e}")
        return 1

    logger.info("IMDB demo completed successfully!")
    return 0


if __name__ == "__main__":
    exit(main())
