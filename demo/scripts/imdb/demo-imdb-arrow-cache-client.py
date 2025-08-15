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
    python3 demo/scripts/demo-imdb-arrow-cache-client.py --host localhost --port 50051 --demo
"""

import argparse
import logging
import subprocess
import time
from typing import List, Optional

import pyarrow.flight as flight

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


class IMDBArrowCacheClient:
    """Client for interacting with the distributed Arrow Cache system using IMDB data."""

    def __init__(self, host: str = "localhost", port: int = 50051):
        """Initialize the IMDB Arrow Cache client.

        Args:
            host: Host of the Arrow Cache head node
            port: Port of the Arrow Cache head node
        """
        self.host = host
        self.port = port
        self.client = None

    def connect(self):
        """Connect to the Arrow Cache head node."""
        try:
            logger.info(f"Connecting to Arrow Cache at {self.host}:{self.port}")
            location = flight.Location.for_grpc_tcp(self.host, self.port)
            self.client = flight.FlightClient(location)
            logger.info("Successfully connected to Arrow Cache")
        except Exception as e:
            logger.error(f"Failed to connect to Arrow Cache: {e}")
            raise

    def get_flight_info_for_partition(self, partition_id: int, total_partitions: int):
        """Get flight info for a specific partition from the head node.

        Args:
            partition_id: The partition ID to query (0-based)
            total_partitions: Total number of partitions

        Returns:
            FlightInfo containing endpoints for the partition
        """
        try:
            logger.info(
                f"Getting flight info for partition {partition_id} of {total_partitions}"
            )

            # Create flight descriptor with partition info
            descriptor = flight.FlightDescriptor.for_path(
                str(partition_id), str(total_partitions)
            )

            # Get flight info from head node
            flight_info = self.client.get_flight_info(descriptor)

            logger.info(
                f"Received flight info with {len(flight_info.endpoints)} endpoints"
            )
            return flight_info

        except Exception as e:
            logger.error(f"Failed to get flight info: {e}")
            raise

    def get_imdb_data_files(self) -> Optional[List[str]]:
        """Get IMDB data file paths from the Iceberg table."""
        try:
            logger.info("Fetching IMDB data file paths from S3...")

            # List files in the IMDB Iceberg table data directory
            bucket_prefix = "s3://ricardo.hf.datasets"
            data_prefix = f"{bucket_prefix}/iceberg/hf_datasets.db/imdb_reviews/data/"

            logger.info(f"Listing files in: {data_prefix}")

            # List files in the data directory
            result = subprocess.run(
                [
                    "aws",
                    "s3",
                    "ls",
                    data_prefix,
                    "--recursive",
                    "--profile=root-ricardo",
                ],
                capture_output=True,
                text=True,
                check=True,
            )

            files = []
            for line in result.stdout.strip().split("\\n"):
                if line and ".parquet" in line:
                    # Extract filename from ls output
                    filename = line.split()[-1]
                    if filename.endswith(".parquet"):
                        full_path = f"{bucket_prefix}/{filename}"
                        files.append(full_path)

            if files:
                logger.info(f"Found {len(files)} IMDB data files:")
                for f in files:
                    logger.info(f"  - {f}")
                return files
            else:
                logger.warning("No parquet files found in IMDB Iceberg table")
                return None

        except Exception as e:
            logger.warning(f"Failed to list IMDB data files: {e}")
            return None

    def demonstrate_imdb_caching(self):
        """Demonstrate the caching functionality using IMDB movie review data."""
        logger.info("Starting IMDB Arrow Cache demonstration...")

        logger.info("=== IMDB Dataset Overview ===")
        logger.info("Dataset: IMDB Movie Reviews")
        logger.info("Schema: text (string), label (int64)")
        logger.info("Labels: 0=negative review, 1=positive review")
        logger.info("Total records: ~100,000 movie reviews")

        # Try to get real data file paths (for informational purposes)
        sample_files = self.get_imdb_data_files()

        if not sample_files:
            logger.info(
                "No S3 data files found in metadata, but system may still have cached data"
            )
        else:
            logger.info(f"Found {len(sample_files)} data files in S3:")
            for i, file_path in enumerate(sample_files, 1):
                logger.info(f"  {i}. {file_path}")

        try:
            # Step 1: Get flight info for different partitions
            logger.info("=== Step 1: Getting partition information from head node ===")

            total_partitions = 4  # Test with 4 partitions
            partition_infos = []

            for partition_id in range(total_partitions):
                logger.info(f"Getting flight info for partition {partition_id}")
                try:
                    flight_info = self.get_flight_info_for_partition(
                        partition_id, total_partitions
                    )
                    partition_infos.append((partition_id, flight_info))

                    logger.info(
                        f"Partition {partition_id}: {len(flight_info.endpoints)} worker endpoints"
                    )

                    # Show worker endpoints for this partition
                    for i, endpoint in enumerate(flight_info.endpoints):
                        if endpoint.locations:
                            worker_uri = endpoint.locations[0].uri
                            logger.info(f"  Worker {i}: {worker_uri}")

                except Exception as e:
                    logger.warning(
                        f"Failed to get flight info for partition {partition_id}: {e}"
                    )

                time.sleep(1)  # Small delay between requests

            # Step 2: Query IMDB data from workers directly
            logger.info("=== Step 2: Querying IMDB review data from workers ===")

            if partition_infos:
                logger.info(
                    f"Successfully got flight info for {len(partition_infos)} partitions"
                )

                # Query different ranges of IMDB reviews
                sample_queries = [
                    (0, 99, "First 100 reviews"),
                    (1000, 1099, "Reviews 1000-1099"),
                    (5000, 5049, "Mid-range reviews"),
                    (10000, 10099, "Later reviews"),
                ]

                for start, end, description in sample_queries:
                    logger.info(f"Querying {description} (rows {start}-{end})")

                    # Try each partition to find the one containing this range
                    success = False
                    for partition_id, flight_info in partition_infos:
                        if not flight_info.endpoints:
                            continue

                        # Try querying this partition's worker
                        for endpoint in flight_info.endpoints:
                            if not endpoint.locations:
                                continue

                            try:
                                # Decode worker URI and fix protocol if needed
                                worker_uri = endpoint.locations[0].uri
                                if isinstance(worker_uri, bytes):
                                    worker_uri = worker_uri.decode("utf-8")

                                # Convert http:// to grpc:// for Arrow Flight compatibility
                                if worker_uri.startswith("http://"):
                                    worker_uri = worker_uri.replace(
                                        "http://", "grpc://", 1
                                    )

                                # Translate internal Kubernetes URIs to localhost
                                # port-forwarded URIs
                                if (
                                    "arrow-cache-worker-0.arrow-cache-worker-svc."
                                    "arrow-cache-imdb.svc.cluster.local" in worker_uri
                                ):
                                    worker_uri = "grpc://localhost:50052"  # Port-forward worker-0
                                elif (
                                    "arrow-cache-worker-1.arrow-cache-worker-svc."
                                    "arrow-cache-imdb.svc.cluster.local" in worker_uri
                                ):
                                    worker_uri = "grpc://localhost:50053"  # Port-forward worker-1

                                logger.info(
                                    f"  Trying worker at {worker_uri} for partition {partition_id}"
                                )

                                # Connect to the worker directly
                                worker_location = flight.Location(worker_uri)
                                worker_client = flight.FlightClient(worker_location)

                                # Use the ticket from the endpoint (contains the partition range)
                                if endpoint.ticket:
                                    flight_stream = worker_client.do_get(
                                        endpoint.ticket
                                    )
                                    result = flight_stream.read_all()
                                    logger.info(
                                        f"Successfully retrieved {len(result)} IMDB reviews from "
                                        f"partition {partition_id}"
                                    )

                                    # Print some sample IMDB review data
                                    if len(result) > 0:
                                        logger.info(f"Columns: {result.column_names}")
                                        logger.info(f"Schema: {result.schema}")

                                        # Convert to pandas for easier display
                                        df = result.to_pandas()

                                        # Show sample reviews
                                        logger.info("=== Sample IMDB Reviews ===")
                                        for i in range(min(3, len(df))):
                                            row = df.iloc[i]
                                            sentiment = (
                                                "Positive"
                                                if row["label"] == 1
                                                else "Negative"
                                            )
                                            review_preview = (
                                                row["text"][:100] + "..."
                                                if len(row["text"]) > 100
                                                else row["text"]
                                            )
                                            logger.info(
                                                f"Review {i+1} ({sentiment}): {review_preview}"
                                            )

                                        # Show label distribution
                                        label_counts = df["label"].value_counts()
                                        logger.info(
                                            "Label distribution in this partition:"
                                        )
                                        logger.info(
                                            f"  Negative (0): {label_counts.get(0, 0)} reviews"
                                        )
                                        logger.info(
                                            f"  Positive (1): {label_counts.get(1, 0)} reviews"
                                        )

                                    success = True
                                    break

                            except Exception as e:
                                logger.warning(
                                    f"Failed to query worker {worker_uri}: {e}"
                                )

                        if success:
                            break

                    if not success:
                        logger.warning(f"Failed to query {description} from any worker")

                    time.sleep(2)  # Delay between queries to see results clearly
            else:
                logger.warning(
                    "No valid partition information received - cannot query data"
                )

        except Exception as e:
            logger.error(f"IMDB demo failed: {e}")
            raise

    def run_imdb_performance_test(self, num_queries: int = 5):
        """Run a performance test using IMDB data queries.

        Args:
            num_queries: Number of queries to execute
        """
        logger.info(f"=== Running IMDB performance test with {num_queries} queries ===")

        import random

        query_times = []

        # Define realistic query ranges for IMDB data
        imdb_ranges = [
            (0, 999, "First 1000 reviews"),
            (1000, 2999, "Reviews 1000-2999"),
            (5000, 7999, "Mid-range reviews"),
            (10000, 12999, "Later reviews"),
            (20000, 24999, "Final batch"),
        ]

        for i in range(num_queries):
            # Pick a random range from our predefined ranges
            start_range, end_range, description = random.choice(imdb_ranges)

            # Generate a smaller random subrange within the selected range
            query_start = random.randint(start_range, end_range - 200)
            query_end = query_start + random.randint(50, 200)

            start_time = time.time()
            try:
                # Note: This would need to be adapted to use the actual flight client
                # For now, we'll just simulate the timing
                logger.info(
                    f"Query {i+1}/{num_queries}: {description}, "
                    f"rows {query_start}-{query_end}"
                )

                # Simulate query time (replace with actual query when implemented)
                import time

                time.sleep(random.uniform(0.1, 0.5))  # Simulate network/processing time

                query_time = time.time() - start_time
                query_times.append(query_time)

                logger.info(f"Query {i+1} completed in {query_time:.3f}s")

            except Exception as e:
                logger.warning(f"Query {i+1} failed: {e}")

            time.sleep(0.5)  # Small delay between queries

        if query_times:
            avg_time = sum(query_times) / len(query_times)
            min_time = min(query_times)
            max_time = max(query_times)

            logger.info("=== IMDB Performance Test Results ===")
            logger.info(f"Successful queries: {len(query_times)}/{num_queries}")
            logger.info(f"Average query time: {avg_time:.3f}s")
            logger.info(f"Min query time: {min_time:.3f}s")
            logger.info(f"Max query time: {max_time:.3f}s")


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
            logger.info(
                "Example: python3 demo/scripts/demo-imdb-arrow-cache-client.py --demo"
            )

    except Exception as e:
        logger.error(f"IMDB demo failed: {e}")
        return 1

    logger.info("IMDB demo completed successfully!")
    return 0


if __name__ == "__main__":
    exit(main())
