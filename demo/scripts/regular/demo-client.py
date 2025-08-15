#!/usr/bin/env python3
"""
Arrow Cache Demo Client

This script demonstrates how to interact with the distributed Arrow Cache system
deployed on a Kubernetes cluster. It shows how to:
1. Connect to the head node
2. Send file assignments to workers
3. Query cached data
4. Demonstrate the distributed nature of the system

Prerequisites:
- pyarrow with flight support: pip install pyarrow
- grpcio: pip install grpcio

Usage:
    python3 demo/scripts/regular/demo-client.py --host localhost --port 50051 --demo
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


class RegularArrowCacheClient(BaseArrowCacheClient):
    """Client for interacting with the distributed Arrow Cache system with synthetic data."""

    def __init__(self, host: str = "localhost", port: int = 50051):
        """Initialize the regular Arrow Cache client."""
        super().__init__(host, port)
        self.namespace = "arrow-cache"

    def create_demo_data(self) -> pa.Table:
        """Create sample data for demonstration.

        Returns:
            A PyArrow table with sample data
        """
        self.logger.info("Creating demo data...")

        # Create sample data that mimics a training dataset
        data = {
            "id": list(range(1000)),
            "text": [f"Sample text data {i}" for i in range(1000)],
            "label": [i % 10 for i in range(1000)],
            "score": [i * 0.1 for i in range(1000)],
            "metadata": [
                {"source": f"file_{i//100}.parquet", "row": i % 100}
                for i in range(1000)
            ],
        }

        table = pa.table(data)
        self.logger.info(
            f"Created demo table with {len(table)} rows and {len(table.column_names)} columns"
        )
        return table

    def get_real_data_files(self):
        """Get actual data file paths from Arrow Cache configuration."""
        # Try different S3 locations that might contain data
        locations = [
            "s3://ricardometadata/data/",
            "s3://ricardo.hf.datasets/data/",
        ]

        for location in locations:
            files = S3Utils.list_s3_files(location, profile="root-ricardo")
            if files:
                return files

        return None

    def process_query_result(self, result: pa.Table, description: str):
        """Process regular demo query results."""
        if len(result) > 0:
            self.logger.info(f"Columns: {result.column_names}")
            self.logger.info(f"Schema: {result.schema}")

            # Show first few rows as example
            df = result.to_pandas()
            self.logger.info("=== Sample Data ===")
            self.logger.info("First few rows:")
            for i in range(min(3, len(df))):
                row = df.iloc[i]
                self.logger.info(f"Row {i+1}: {row.to_dict()}")

    def demonstrate_caching(self):
        """Demonstrate the caching functionality using synthetic data."""
        self.logger.info("Starting Arrow Cache demonstration...")

        # Try to get real data file paths (for informational purposes)
        sample_files = self.get_real_data_files()

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

            # Step 2: Query data from workers directly
            self.logger.info("=== Step 2: Querying data from workers ===")

            if partition_infos:
                self.logger.info(
                    f"Successfully got flight info for {len(partition_infos)} partitions"
                )

                # Try querying specific row ranges
                sample_queries = [
                    (0, 99, "First 100 rows"),
                    (100, 299, "Next 200 rows"),
                    (500, 599, "Mid-range rows"),
                    (800, 999, "Later rows"),
                ]

                self.query_workers_for_data(
                    partition_infos, sample_queries, self.namespace
                )
            else:
                self.logger.warning(
                    "No valid partition information received - cannot query data"
                )

        except Exception as e:
            self.logger.error(f"Demo failed: {e}")
            raise


def main():
    """Main function to run the demo."""
    parser = argparse.ArgumentParser(description="Arrow Cache Demo Client")
    parser.add_argument(
        "--host", default="localhost", help="Arrow Cache head node host"
    )
    parser.add_argument(
        "--port", type=int, default=50051, help="Arrow Cache head node port"
    )
    parser.add_argument(
        "--demo", action="store_true", help="Run the full demonstration"
    )
    parser.add_argument("--perf-test", action="store_true", help="Run performance test")
    parser.add_argument(
        "--queries", type=int, default=10, help="Number of queries for performance test"
    )

    args = parser.parse_args()

    # Create and connect client
    client = RegularArrowCacheClient(args.host, args.port)

    try:
        client.connect()

        if args.demo:
            client.demonstrate_caching()

        if args.perf_test:
            client.run_performance_test(args.queries)

        if not args.demo and not args.perf_test:
            logger.info("No action specified. Use --demo or --perf-test")
            logger.info("Example: python3 demo/scripts/regular/demo-client.py --demo")

    except Exception as e:
        logger.error(f"Demo failed: {e}")
        return 1

    logger.info("Demo completed successfully!")
    return 0


if __name__ == "__main__":
    exit(main())
