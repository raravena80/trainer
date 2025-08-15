#!/usr/bin/env python3
"""
Arrow Cache Demo Data Generator

This script generates sample Iceberg table data for testing the distributed Arrow Cache system.
It creates realistic datasets that can be used for demos without requiring external S3 dependencies.

Features:
- Creates sample Iceberg tables with various data types
- Generates multiple data files for distributed processing
- Creates proper Iceberg metadata structure
- Supports both local filesystem and S3 storage
- Includes schema evolution examples
- Generates data suitable for caching demos

Usage:
    python3 demo/scripts/generate-demo-data.py --output /tmp/demo-data --records 10000
    python3 demo/scripts/generate-demo-data.py --output s3://my-bucket/demo \
        --records 50000 --files 10
"""

import argparse
import json
import random
import sys
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, List

import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from pyarrow import fs


class DemoDataGenerator:
    """Generates demo data for Arrow Cache testing."""

    def __init__(self, output_path: str, num_records: int = 10000, num_files: int = 4):
        self.output_path = output_path
        self.num_records = num_records
        self.num_files = num_files
        self.table_name = "demo_table"
        self.schema_name = "demo_schema"

        # Initialize filesystem
        if output_path.startswith("s3://"):
            self.filesystem = fs.S3FileSystem()
            # For S3, store the bucket and prefix separately
            self.s3_bucket = output_path[5:].split("/")[
                0
            ]  # Remove 's3://' and get bucket
            self.s3_prefix = "/".join(
                output_path[5:].split("/")[1:]
            )  # Get the rest as prefix
        else:
            self.filesystem = fs.LocalFileSystem()
            self.s3_bucket = None
            self.s3_prefix = None
            # Create output directory if it doesn't exist
            Path(output_path).mkdir(parents=True, exist_ok=True)

    def _get_filesystem_path(self, path: str) -> str:
        """Convert path for filesystem operations (removes s3:// for S3FileSystem)."""
        if self.output_path.startswith("s3://"):
            # For S3, remove the s3:// prefix and return bucket/key format
            if path.startswith("s3://"):
                return path[5:]  # Remove 's3://'
            else:
                return path
        else:
            return path

    def _get_full_path(self, path: str) -> str:
        """Get the full path including s3:// prefix for URLs."""
        if self.output_path.startswith("s3://"):
            if path.startswith("s3://"):
                return path
            else:
                return f"s3://{path}"
        else:
            return path

    def generate_sample_schema(self) -> pa.Schema:
        """Generate a realistic Arrow schema for demo data."""
        return pa.schema(
            [
                pa.field("id", pa.uint64(), nullable=False),
                pa.field("user_id", pa.string(), nullable=False),
                pa.field("event_type", pa.string(), nullable=False),
                pa.field("timestamp", pa.timestamp("us", tz="UTC"), nullable=False),
                pa.field("value", pa.float64(), nullable=True),
                pa.field("category", pa.string(), nullable=True),
                pa.field("metadata", pa.string(), nullable=True),  # JSON string
                pa.field("session_id", pa.string(), nullable=True),
                pa.field("device_type", pa.string(), nullable=True),
                pa.field("country", pa.string(), nullable=True),
                pa.field(
                    "revenue", pa.float64(), nullable=True
                ),  # Simplified to float64
            ]
        )

    def generate_sample_data(self, start_id: int, count: int) -> pa.Table:
        """Generate sample data for a single file."""

        # Sample data generators
        event_types = [
            "page_view",
            "click",
            "purchase",
            "signup",
            "login",
            "logout",
            "search",
        ]
        categories = [
            "electronics",
            "books",
            "clothing",
            "home",
            "sports",
            "toys",
            None,
        ]
        device_types = ["desktop", "mobile", "tablet"]
        countries = ["US", "UK", "DE", "FR", "JP", "CA", "AU", "BR", "IN"]

        data = []
        base_time = datetime(2024, 1, 1, tzinfo=None)

        for i in range(count):
            record_id = start_id + i
            user_id = f"user_{random.randint(1, 1000)}"
            event_type = random.choice(event_types)
            timestamp = base_time + timedelta(
                seconds=random.randint(0, 365 * 24 * 3600)  # Random time in 2024
            )

            # Generate correlated data
            value = None
            revenue = None
            if event_type == "purchase":
                value = random.uniform(10.0, 1000.0)
                revenue = round(value * 0.95, 2)  # 5% tax, rounded to 2 decimal places
            elif event_type == "click":
                value = random.uniform(0.1, 5.0)

            category = (
                random.choice(categories)
                if event_type in ["purchase", "click", "search"]
                else None
            )

            metadata = json.dumps(
                {
                    "ip": (
                        f"{random.randint(1, 255)}.{random.randint(1, 255)}."
                        f"{random.randint(1, 255)}.{random.randint(1, 255)}"
                    ),
                    "user_agent": f"Browser/{random.randint(1, 10)}.0",
                    "referrer": random.choice(
                        ["google.com", "facebook.com", "direct", None]
                    ),
                }
            )

            data.append(
                {
                    "id": record_id,
                    "user_id": user_id,
                    "event_type": event_type,
                    "timestamp": timestamp,
                    "value": value,
                    "category": category,
                    "metadata": metadata,
                    "session_id": f"session_{uuid.uuid4().hex[:8]}",
                    "device_type": random.choice(device_types),
                    "country": random.choice(countries),
                    "revenue": revenue,
                }
            )

        # Convert to pandas DataFrame first for easier handling
        df = pd.DataFrame(data)

        # Convert to Arrow table with proper schema
        table = pa.Table.from_pandas(df, schema=self.generate_sample_schema())
        return table

    def write_parquet_file(self, table: pa.Table, file_path: str) -> Dict[str, Any]:
        """Write Arrow table to Parquet file and return metadata."""

        print(f"Writing {len(table)} records to {file_path}")

        # Convert path for filesystem operations
        fs_path = self._get_filesystem_path(file_path)

        # Write parquet file
        with self.filesystem.open_output_stream(fs_path) as stream:
            pq.write_table(table, stream, compression="snappy")

        # Get file stats
        file_info = self.filesystem.get_file_info(fs_path)

        return {
            "file_path": self._get_full_path(
                fs_path
            ),  # Return full path with s3:// if needed
            "record_count": len(table),
            "file_size": file_info.size,
            "schema": table.schema,
        }

    def create_iceberg_metadata(
        self, data_files: List[Dict[str, Any]]
    ) -> Dict[str, Any]:
        """Create Iceberg table metadata structure."""

        # Get schema from first file
        schema = data_files[0]["schema"]

        # Convert Arrow schema to Iceberg schema format
        iceberg_fields = []
        field_id = 1
        for field in schema:
            iceberg_field = {
                "id": field_id,
                "name": field.name,
                "required": not field.nullable,
                "type": self._arrow_to_iceberg_type(field.type),
            }
            iceberg_fields.append(iceberg_field)
            field_id += 1

        # Create proper Iceberg schema structure
        iceberg_schema = {"type": "struct", "fields": iceberg_fields}

        # For iceberg 0.5.0 compatibility, create a simple snapshot structure
        # Some versions expect manifest-list, others work with simplified format
        snapshot_id = random.randint(1000000, 9999999)
        snapshot = {
            "snapshot-id": snapshot_id,
            "timestamp-ms": int(datetime.now().timestamp() * 1000),
            "summary": {
                "operation": "append",
                "total-records": str(sum(f["record_count"] for f in data_files)),
                "total-files-size": str(sum(f["file_size"] for f in data_files)),
                "total-data-files": str(len(data_files)),
            },
        }

        # Create full metadata
        metadata = {
            "format-version": 1,
            "table-uuid": str(uuid.uuid4()),
            "location": self.output_path,
            "last-updated-ms": int(datetime.now().timestamp() * 1000),
            "last-column-id": len(schema),
            "current-schema-id": 0,
            "schema": iceberg_schema,
            "schemas": [iceberg_schema],
            "partition-spec": [],
            "partition-specs": [{"spec-id": 0, "fields": []}],
            "default-spec-id": 0,
            "last-partition-id": 0,
            "default-sort-order-id": 0,
            "sort-orders": [{"order-id": 0, "fields": []}],
            "properties": {
                "write.format.default": "parquet",
                "write.parquet.compression-codec": "snappy",
            },
            "current-snapshot-id": snapshot["snapshot-id"],
            "last-sequence-number": 0,
            "snapshots": [snapshot],
            "snapshot-log": [
                {
                    "snapshot-id": snapshot["snapshot-id"],
                    "timestamp-ms": snapshot["timestamp-ms"],
                }
            ],
            "metadata-log": [],
        }

        return metadata

    def _arrow_to_iceberg_type(self, arrow_type: pa.DataType) -> str:
        """Convert Arrow data type to Iceberg type string."""
        if pa.types.is_uint64(arrow_type):
            return "long"
        elif pa.types.is_string(arrow_type):
            return "string"
        elif pa.types.is_timestamp(arrow_type):
            return "timestamptz"
        elif pa.types.is_float64(arrow_type):
            return "double"
        elif pa.types.is_decimal(arrow_type):
            return f"decimal({arrow_type.precision},{arrow_type.scale})"
        else:
            return "string"  # fallback

    def write_metadata_file(self, metadata: Dict[str, Any], metadata_path: str):
        """Write Iceberg metadata JSON file."""
        print(f"Writing metadata to {metadata_path}")

        # Convert path for filesystem operations
        fs_path = self._get_filesystem_path(metadata_path)

        with self.filesystem.open_output_stream(fs_path) as stream:
            stream.write(json.dumps(metadata, indent=2).encode("utf-8"))

    def generate_demo_dataset(self):
        """Generate complete demo dataset with Iceberg metadata."""

        print("Generating demo dataset:")
        print(f"  Output path: {self.output_path}")
        print(f"  Total records: {self.num_records}")
        print(f"  Number of files: {self.num_files}")
        print(f"  Records per file: {self.num_records // self.num_files}")
        print()

        # Create directory structure
        data_dir = f"{self.output_path}/data"
        metadata_dir = f"{self.output_path}/metadata"

        if not self.output_path.startswith("s3://"):
            Path(data_dir.replace("file://", "")).mkdir(parents=True, exist_ok=True)
            Path(metadata_dir.replace("file://", "")).mkdir(parents=True, exist_ok=True)

        # Generate data files
        data_files = []
        records_per_file = self.num_records // self.num_files

        for i in range(self.num_files):
            start_id = i * records_per_file
            count = records_per_file

            # Last file gets any remaining records
            if i == self.num_files - 1:
                count = self.num_records - start_id

            # Generate data
            table = self.generate_sample_data(start_id, count)

            # Write parquet file
            file_path = f"{data_dir}/data_{i:03d}.parquet"
            file_metadata = self.write_parquet_file(table, file_path)
            data_files.append(file_metadata)

        # Create Iceberg metadata
        print("Creating Iceberg metadata...")
        iceberg_metadata = self.create_iceberg_metadata(data_files)

        # Write metadata file
        metadata_path = f"{metadata_dir}/table.metadata.json"
        self.write_metadata_file(iceberg_metadata, metadata_path)

        print()
        print("✅ Demo dataset generated successfully!")
        print()
        print("Configuration for Arrow Cache:")
        print(f"  METADATA_LOC: {metadata_path}")
        print(f"  TABLE_NAME: {self.table_name}")
        print(f"  SCHEMA_NAME: {self.schema_name}")
        print()
        print("Sample kubectl commands:")
        print("kubectl patch configmap arrow-cache-config -n arrow-cache \\")
        print(f'  --patch \'{{"data":{{"METADATA_LOC":"{metadata_path}"}}}}\'')
        print()
        print("Data summary:")
        print(f"  Total records: {sum(f['record_count'] for f in data_files):,}")
        print(f"  Total size: {sum(f['file_size'] for f in data_files):,} bytes")
        print(f"  Files created: {len(data_files)}")
        print()

        return {
            "metadata_path": metadata_path,
            "data_files": data_files,
            "total_records": sum(f["record_count"] for f in data_files),
            "total_size": sum(f["file_size"] for f in data_files),
        }


def main():
    parser = argparse.ArgumentParser(description="Generate demo data for Arrow Cache")
    parser.add_argument(
        "--output",
        "-o",
        required=True,
        help="Output path (local directory or s3:// URL)",
    )
    parser.add_argument(
        "--records",
        "-r",
        type=int,
        default=10000,
        help="Total number of records to generate (default: 10000)",
    )
    parser.add_argument(
        "--files",
        "-f",
        type=int,
        default=4,
        help="Number of data files to create (default: 4)",
    )
    parser.add_argument(
        "--table-name",
        default="demo_table",
        help="Table name for metadata (default: demo_table)",
    )
    parser.add_argument(
        "--schema-name",
        default="demo_schema",
        help="Schema name for metadata (default: demo_schema)",
    )

    args = parser.parse_args()

    # Validate arguments
    if args.records <= 0:
        print("Error: Number of records must be positive")
        sys.exit(1)

    if args.files <= 0:
        print("Error: Number of files must be positive")
        sys.exit(1)

    if args.records < args.files:
        print("Error: Number of records must be >= number of files")
        sys.exit(1)

    # Check dependencies
    try:
        pass  # pandas and pyarrow already imported at module level
    except ImportError as e:
        print(f"Error: Missing required dependency: {e}")
        print("Install with: pip install pandas pyarrow")
        sys.exit(1)

    # Generate demo data
    try:
        generator = DemoDataGenerator(
            output_path=args.output, num_records=args.records, num_files=args.files
        )
        generator.table_name = args.table_name
        generator.schema_name = args.schema_name

        # result = generator.generate_demo_dataset()
        generator.generate_demo_dataset()

        print("🎉 Demo data generation completed successfully!")
        return 0

    except Exception as e:
        print(f"❌ Error generating demo data: {e}")
        import traceback

        traceback.print_exc()
        return 1


if __name__ == "__main__":
    sys.exit(main())
