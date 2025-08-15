#!/usr/bin/env python3
"""
Common Arrow Cache Client Library

This module provides shared functionality for interacting with the distributed
Arrow Cache system, including connection management, flight operations, and
common utilities.
"""

import logging
import subprocess
import time
from typing import List, Optional

import pyarrow as pa
import pyarrow.flight as flight


class BaseArrowCacheClient:
    """Base client for interacting with the distributed Arrow Cache system."""

    def __init__(self, host: str = "localhost", port: int = 50051):
        """Initialize the Arrow Cache client.

        Args:
            host: Host of the Arrow Cache head node
            port: Port of the Arrow Cache head node
        """
        self.host = host
        self.port = port
        self.client = None
        self.logger = logging.getLogger(self.__class__.__name__)

    def connect(self):
        """Connect to the Arrow Cache head node."""
        try:
            self.logger.info(f"Connecting to Arrow Cache at {self.host}:{self.port}")
            location = flight.Location.for_grpc_tcp(self.host, self.port)
            self.client = flight.FlightClient(location)
            self.logger.info("Successfully connected to Arrow Cache")
        except Exception as e:
            self.logger.error(f"Failed to connect to Arrow Cache: {e}")
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
            self.logger.info(
                f"Getting flight info for partition {partition_id} of {total_partitions}"
            )

            # Create flight descriptor with partition info
            descriptor = flight.FlightDescriptor.for_path(
                str(partition_id), str(total_partitions)
            )

            # Get flight info from head node
            flight_info = self.client.get_flight_info(descriptor)

            self.logger.info(
                f"Received flight info with {len(flight_info.endpoints)} endpoints"
            )
            return flight_info

        except Exception as e:
            self.logger.error(f"Failed to get flight info: {e}")
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
            self.logger.info(f"Querying data range: {start_row} to {end_row}")

            # Create a ticket with the row range
            import struct

            ticket_data = struct.pack("QQ", start_row, end_row)  # Pack as two uint64
            ticket = flight.Ticket(ticket_data)

            # Get the data stream
            flight_stream = self.client.do_get(ticket)

            # Read all data into a table
            table = flight_stream.read_all()

            self.logger.info(
                f"Retrieved {len(table)} rows with {len(table.column_names)} columns"
            )
            return table

        except Exception as e:
            self.logger.error(f"Failed to query data range: {e}")
            raise

    def translate_worker_uri(
        self, worker_uri: str, namespace: str = "arrow-cache"
    ) -> str:
        """Translate internal Kubernetes URIs to localhost port-forwarded URIs.

        Args:
            worker_uri: Original worker URI
            namespace: Kubernetes namespace

        Returns:
            Translated URI for local access
        """
        # Decode if bytes
        if isinstance(worker_uri, bytes):
            worker_uri = worker_uri.decode("utf-8")

        # Convert http:// to grpc:// for Arrow Flight compatibility
        if worker_uri.startswith("http://"):
            worker_uri = worker_uri.replace("http://", "grpc://", 1)

        # Translate internal Kubernetes URIs to localhost port-forwarded URIs
        if (
            f"arrow-cache-worker-0.arrow-cache-worker-svc.{namespace}.svc.cluster.local"
            in worker_uri
        ):
            return "grpc://localhost:50052"  # Port-forward worker-0
        elif (
            f"arrow-cache-worker-1.arrow-cache-worker-svc.{namespace}.svc.cluster.local"
            in worker_uri
        ):
            return "grpc://localhost:50053"  # Port-forward worker-1

        return worker_uri

    def query_workers_for_data(
        self,
        partition_infos: List,
        sample_queries: List,
        namespace: str = "arrow-cache",
    ):
        """Query data from workers for given sample queries.

        Args:
            partition_infos: List of (partition_id, flight_info) tuples
            sample_queries: List of (start, end, description) tuples
            namespace: Kubernetes namespace
        """
        for start, end, description in sample_queries:
            self.logger.info(f"Querying {description} (rows {start}-{end})")

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
                        worker_uri = self.translate_worker_uri(
                            endpoint.locations[0].uri, namespace
                        )

                        self.logger.info(
                            f"  Trying worker at {worker_uri} for partition {partition_id}"
                        )

                        # Connect to the worker directly
                        worker_location = flight.Location(worker_uri)
                        worker_client = flight.FlightClient(worker_location)

                        # Use the ticket from the endpoint (contains the partition range)
                        if endpoint.ticket:
                            flight_stream = worker_client.do_get(endpoint.ticket)
                            result = flight_stream.read_all()

                            self.logger.info(
                                f"Successfully retrieved {len(result)} rows from "
                                f"partition {partition_id}"
                            )

                            # Let subclasses handle the specific data processing
                            self.process_query_result(result, description)
                            success = True
                            break

                    except Exception as e:
                        self.logger.warning(f"Failed to query worker {worker_uri}: {e}")

                if success:
                    break

            if not success:
                self.logger.warning(f"Failed to query {description} from any worker")

            time.sleep(2)  # Delay between queries to see results clearly

    def process_query_result(self, result: pa.Table, description: str):
        """Process query result. Override in subclasses for specific behavior.

        Args:
            result: PyArrow table with query results
            description: Description of the query
        """
        if len(result) > 0:
            self.logger.info(f"Columns: {result.column_names}")
            self.logger.info(f"Schema: {result.schema}")

    def run_performance_test(
        self, num_queries: int = 10, query_ranges: Optional[List] = None
    ):
        """Run a performance test with configurable query ranges.

        Args:
            num_queries: Number of queries to execute
            query_ranges: List of (start, end, description) tuples, or None for default
        """
        self.logger.info(f"=== Running performance test with {num_queries} queries ===")

        import random

        query_times = []

        # Default query ranges if none provided
        if query_ranges is None:
            query_ranges = [
                (0, 999, "First 1000 rows"),
                (1000, 2999, "Rows 1000-2999"),
                (5000, 7999, "Mid-range rows"),
                (10000, 12999, "Later rows"),
                (20000, 24999, "Final batch"),
            ]

        for i in range(num_queries):
            # Pick a random range from our predefined ranges
            start_range, end_range, description = random.choice(query_ranges)

            # Generate a smaller random subrange within the selected range
            query_start = random.randint(start_range, end_range - 200)
            query_end = query_start + random.randint(50, 200)

            start_time = time.time()
            try:
                self.logger.info(
                    f"Query {i+1}/{num_queries}: {description}, "
                    f"rows {query_start}-{query_end}"
                )

                # Simulate query time (replace with actual query when implemented)
                time.sleep(random.uniform(0.1, 0.5))  # Simulate network/processing time

                query_time = time.time() - start_time
                query_times.append(query_time)

                self.logger.info(f"Query {i+1} completed in {query_time:.3f}s")

            except Exception as e:
                self.logger.warning(f"Query {i+1} failed: {e}")

            time.sleep(0.5)  # Small delay between queries

        if query_times:
            avg_time = sum(query_times) / len(query_times)
            min_time = min(query_times)
            max_time = max(query_times)

            self.logger.info("=== Performance Test Results ===")
            self.logger.info(f"Successful queries: {len(query_times)}/{num_queries}")
            self.logger.info(f"Average query time: {avg_time:.3f}s")
            self.logger.info(f"Min query time: {min_time:.3f}s")
            self.logger.info(f"Max query time: {max_time:.3f}s")


class S3Utils:
    """Utilities for working with S3 and Arrow Cache data files."""

    @staticmethod
    def list_s3_files(
        bucket_prefix: str, profile: str = "default"
    ) -> Optional[List[str]]:
        """List parquet files in an S3 path.

        Args:
            bucket_prefix: S3 path prefix (e.g., 's3://bucket/path/')
            profile: AWS profile name

        Returns:
            List of S3 file paths or None if failed
        """
        try:
            logger = logging.getLogger("S3Utils")
            logger.info(f"Listing files in: {bucket_prefix}")

            cmd = ["aws", "s3", "ls", bucket_prefix, "--recursive"]
            if profile and profile != "default":
                cmd.extend([f"--profile={profile}"])

            result = subprocess.run(cmd, capture_output=True, text=True, check=True)

            files = []
            for line in result.stdout.strip().split("\\n"):
                if line and ".parquet" in line:
                    # Extract filename from ls output
                    filename = line.split()[-1]
                    if filename.endswith(".parquet"):
                        # Reconstruct full S3 path
                        if bucket_prefix.endswith("/"):
                            full_path = f"{bucket_prefix.rstrip('/')}/{filename}"
                        else:
                            full_path = f"{bucket_prefix}/{filename}"
                        files.append(full_path)

            if files:
                logger.info(f"Found {len(files)} parquet files:")
                for f in files:
                    logger.info(f"  - {f}")
                return files
            else:
                logger.warning("No parquet files found")
                return None

        except Exception as e:
            logger = logging.getLogger("S3Utils")
            logger.warning(f"Failed to list S3 files: {e}")
            return None

    @staticmethod
    def get_metadata_location_from_configmap(
        namespace: str, configmap_name: str = "arrow-cache-config"
    ) -> Optional[str]:
        """Get metadata location from Kubernetes ConfigMap.

        Args:
            namespace: Kubernetes namespace
            configmap_name: ConfigMap name

        Returns:
            Metadata location or None if failed
        """
        try:
            result = subprocess.run(
                [
                    "kubectl",
                    "get",
                    "configmap",
                    configmap_name,
                    "-n",
                    namespace,
                    "-o",
                    "jsonpath={.data.METADATA_LOC}",
                ],
                capture_output=True,
                text=True,
                check=True,
            )

            metadata_loc = result.stdout.strip()
            return metadata_loc if metadata_loc else None
        except Exception as e:
            logger = logging.getLogger("S3Utils")
            logger.warning(f"Failed to get metadata location from configmap: {e}")
            return None
