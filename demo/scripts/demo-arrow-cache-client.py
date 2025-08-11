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
    python3 demo/scripts/demo-arrow-cache-client.py --host localhost --port 50051
"""

import argparse
import json
import logging
import subprocess
import time
from typing import Any, Dict, List, Optional

import pyarrow as pa
import pyarrow.flight as flight

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


class ArrowCacheClient:
    """Client for interacting with the distributed Arrow Cache system."""

    def __init__(self, host: str = "localhost", port: int = 50051):
        """Initialize the Arrow Cache client.

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

    def create_demo_data(self) -> pa.Table:
        """Create sample data for demonstration.

        Returns:
            A PyArrow table with sample data
        """
        logger.info("Creating demo data...")

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
        logger.info(
            f"Created demo table with {len(table)} rows and {len(table.column_names)} columns"
        )
        return table

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
            # The head service expects [local_rank, total] in the path
            # Note: for_path expects individual string arguments, not a list
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

    def query_data_range(self, start_row: int, end_row: int) -> pa.Table:
        """Query data for a specific row range.

        Args:
            start_row: Starting row index (inclusive)
            end_row: Ending row index (inclusive)

        Returns:
            PyArrow table with the requested data
        """
        try:
            logger.info(f"Querying data range: {start_row} to {end_row}")

            # Create a ticket with the row range
            # This should match the IndexPair struct in the Rust code
            import struct

            ticket_data = struct.pack("QQ", start_row, end_row)  # Pack as two uint64

            ticket = flight.Ticket(ticket_data)

            # Get the data stream
            flight_stream = self.client.do_get(ticket)

            # Read all data into a table
            table = flight_stream.read_all()

            logger.info(
                f"Retrieved {len(table)} rows with {len(table.column_names)} columns"
            )
            return table

        except Exception as e:
            logger.error(f"Failed to query data range: {e}")
            raise

    def get_real_data_files(self) -> Optional[List[str]]:
        """Get actual data file paths from Arrow Cache configuration."""
        try:
            logger.info("Fetching real data file paths from S3...")

            # Direct approach: list the known S3 data directory
            bucket_prefix = "s3://ricardometadata"
            data_prefix = f"{bucket_prefix}/data/"

            logger.info(f"Listing files in: {data_prefix}")

            # List files in the data directory
            result = subprocess.run(
                ["aws", "s3", "ls", data_prefix, "--recursive"],
                capture_output=True,
                text=True,
                check=True,
            )

            files = []
            for line in result.stdout.strip().split("\n"):
                if line and ".parquet" in line:
                    # Extract filename from ls output
                    filename = line.split()[-1]
                    if filename.endswith(".parquet"):
                        full_path = f"{bucket_prefix}/{filename}"
                        files.append(full_path)

            if files:
                logger.info(f"Found {len(files)} real data files:")
                for f in files:
                    logger.info(f"  - {f}")
                return files
            else:
                logger.warning("No parquet files found in S3")
                return None

        except Exception as e:
            logger.warning(f"Failed to list S3 files: {e}")
            # Try the metadata approach as fallback
            return self._get_files_from_metadata_fallback()

    def _get_files_from_metadata_fallback(self) -> Optional[List[str]]:
        """Fallback: try to get files from metadata location."""
        try:
            # Get the metadata location from kubernetes configmap
            result = subprocess.run(
                [
                    "kubectl",
                    "get",
                    "configmap",
                    "arrow-cache-config",
                    "-n",
                    "arrow-cache",
                    "-o",
                    "jsonpath={.data.METADATA_LOC}",
                ],
                capture_output=True,
                text=True,
                check=True,
            )

            metadata_loc = result.stdout.strip()
            if metadata_loc and metadata_loc.startswith("s3://"):
                return self._get_files_from_s3_metadata(metadata_loc)
            return None
        except Exception as e:
            logger.warning(f"Metadata fallback failed: {e}")
            return None

    def _get_files_from_s3_metadata(self, metadata_loc: str) -> List[str]:
        """Extract data file paths from S3-hosted Iceberg metadata."""
        try:
            # Use AWS CLI to fetch metadata
            result = subprocess.run(
                ["aws", "s3", "cp", metadata_loc, "-"],
                capture_output=True,
                text=True,
                check=True,
            )

            metadata = json.loads(result.stdout)
            return self._extract_data_files_from_metadata(metadata, metadata_loc)

        except subprocess.CalledProcessError as e:
            logger.warning(f"Failed to fetch S3 metadata: {e}")
            # Fallback: try to list files in the data directory
            return self._fallback_list_s3_files(metadata_loc)
        except Exception as e:
            logger.warning(f"Error parsing S3 metadata: {e}")
            return self._fallback_list_s3_files(metadata_loc)

    def _fallback_list_s3_files(self, metadata_loc: str) -> List[str]:
        """Fallback: list parquet files in S3 data directory."""
        try:
            # Extract bucket and prefix from metadata location
            # e.g., s3://ricardometadata/metadata/table.metadata.json -> s3://ricardometadata/data/
            bucket_and_path = metadata_loc.replace("s3://", "").replace(
                "/metadata/table.metadata.json", ""
            )
            data_prefix = f"s3://{bucket_and_path}/data/"

            logger.info(f"Trying to list files in: {data_prefix}")

            # List files in the data directory
            result = subprocess.run(
                ["aws", "s3", "ls", data_prefix, "--recursive"],
                capture_output=True,
                text=True,
                check=True,
            )

            files = []
            for line in result.stdout.strip().split("\n"):
                if line and ".parquet" in line:
                    # Extract filename from ls output
                    filename = line.split()[-1]
                    if filename.endswith(".parquet"):
                        files.append(f"{data_prefix}{filename.split('/')[-1]}")

            logger.info(f"Found {len(files)} parquet files via directory listing")
            return files[:4]  # Limit to first 4 files for demo

        except Exception as e:
            logger.warning(f"Fallback S3 listing failed: {e}")
            return []

    def _get_files_from_local_metadata(self, metadata_loc: str) -> List[str]:
        """Extract data file paths from local Iceberg metadata."""
        try:
            file_path = metadata_loc.replace("file://", "")
            with open(file_path, "r") as f:
                metadata = json.load(f)
            return self._extract_data_files_from_metadata(metadata, metadata_loc)
        except Exception as e:
            logger.warning(f"Failed to read local metadata: {e}")
            return []

    def _extract_data_files_from_metadata(
        self, metadata: Dict[str, Any], metadata_loc: str
    ) -> List[str]:
        """Extract data file paths from Iceberg metadata structure."""
        files = []

        try:
            # Look for snapshots with manifest lists or direct file references
            snapshots = metadata.get("snapshots", [])

            if snapshots:
                logger.info(f"Found {len(snapshots)} snapshots in metadata")
                # For demo purposes, we'll generate some realistic file paths based
                # on the metadata location
                base_location = metadata.get("location", "")
                if not base_location:
                    # Extract base from metadata location
                    if "/metadata/" in metadata_loc:
                        base_location = metadata_loc.split("/metadata/")[0]

                # Generate realistic data file paths
                data_dir = f"{base_location}/data" if base_location else "data"

                # Try to determine number of files from snapshot summary
                latest_snapshot = snapshots[-1] if snapshots else {}
                summary = latest_snapshot.get("summary", {})
                total_files = int(summary.get("total-data-files", "4"))

                for i in range(min(total_files, 6)):  # Limit to max 6 files for demo
                    files.append(f"{data_dir}/data_{i:03d}.parquet")

                logger.info(f"Generated {len(files)} data file paths from metadata")

            return files

        except Exception as e:
            logger.warning(f"Error extracting files from metadata: {e}")
            return []

    def demonstrate_caching(self):
        """Demonstrate the caching functionality using real data."""
        logger.info("Starting Arrow Cache demonstration...")

        # Try to get real data file paths (for informational purposes)
        sample_files = self.get_real_data_files()

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

            # Step 2: Query data from workers directly (if we got endpoints)
            logger.info("=== Step 2: Querying data from workers ===")

            if partition_infos:
                logger.info(
                    f"Successfully got flight info for {len(partition_infos)} partitions"
                )

                # Try querying specific row ranges
                # Note: The actual implementation may need adjustment based on how
                # the worker endpoints handle tickets
                ranges = [
                    (0, 99),  # First 100 rows
                    (100, 299),  # Next 200 rows
                    (500, 599),  # Another range
                    (800, 999),  # Last 200 rows
                ]

                for start, end in ranges:
                    logger.info(f"Attempting to query range {start}-{end} via workers")

                    # Find which partition contains this range
                    # For now, let's use a simple approach and try each partition
                    success = False
                    for partition_id, flight_info in partition_infos:
                        if not flight_info.endpoints:
                            continue

                        # Try querying this partition's worker
                        for endpoint in flight_info.endpoints:
                            if not endpoint.locations:
                                continue

                            try:
                                # Decode worker URI from bytes and fix protocol if needed
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
                                    "arrow-cache.svc.cluster.local" in worker_uri
                                ):
                                    worker_uri = "grpc://localhost:50052"  # Port-forward worker-0
                                elif (
                                    "arrow-cache-worker-1.arrow-cache-worker-svc."
                                    "arrow-cache.svc.cluster.local" in worker_uri
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
                                        f"Successfully retrieved {len(result)} rows from "
                                        f"partition {partition_id}"
                                    )

                                    # Print some sample data
                                    if len(result) > 0:
                                        logger.info(
                                            f"Sample columns: {result.column_names}"
                                        )
                                        logger.info(f"Data types: {result.schema}")
                                        # Print first few rows
                                        logger.info(
                                            f"First few rows: "
                                            f"{result.to_pandas().head(3).to_dict('records')}"
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
                        logger.warning(
                            f"Failed to query range {start}-{end} from any worker"
                        )

                    time.sleep(1)  # Small delay between queries
            else:
                logger.warning(
                    "No valid partition information received - cannot query data"
                )

        except Exception as e:
            logger.error(f"Demo failed: {e}")
            raise

    def run_performance_test(self, num_queries: int = 10):
        """Run a simple performance test.

        Args:
            num_queries: Number of queries to execute
        """
        logger.info(f"=== Running performance test with {num_queries} queries ===")

        import random

        query_times = []

        for i in range(num_queries):
            # Generate random query range
            start = random.randint(0, 800)
            end = min(start + random.randint(50, 200), 999)

            start_time = time.time()
            try:
                result = self.query_data_range(start, end)
                query_time = time.time() - start_time
                query_times.append(query_time)

                logger.info(
                    f"Query {i+1}/{num_queries}: range {start}-{end}, "
                    f"{len(result)} rows, {query_time:.3f}s"
                )

            except Exception as e:
                logger.warning(f"Query {i+1} failed: {e}")

            time.sleep(0.5)  # Small delay between queries

        if query_times:
            avg_time = sum(query_times) / len(query_times)
            min_time = min(query_times)
            max_time = max(query_times)

            logger.info("=== Performance Test Results ===")
            logger.info(f"Successful queries: {len(query_times)}/{num_queries}")
            logger.info(f"Average query time: {avg_time:.3f}s")
            logger.info(f"Min query time: {min_time:.3f}s")
            logger.info(f"Max query time: {max_time:.3f}s")


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
    client = ArrowCacheClient(args.host, args.port)

    try:
        client.connect()

        if args.demo:
            client.demonstrate_caching()

        if args.perf_test:
            client.run_performance_test(args.queries)

        if not args.demo and not args.perf_test:
            logger.info("No action specified. Use --demo or --perf-test")
            logger.info(
                "Example: python3 demo/scripts/demo-arrow-cache-client.py --demo"
            )

    except Exception as e:
        logger.error(f"Demo failed: {e}")
        return 1

    logger.info("Demo completed successfully!")
    return 0


if __name__ == "__main__":
    exit(main())
