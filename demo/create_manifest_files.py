#!/usr/bin/env python3
"""
Create minimal Iceberg manifest files for testing.
"""
import io
import json
import os
from datetime import datetime

import boto3
import pyarrow as pa
import pyarrow.parquet as pq
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()


def create_minimal_data_file():
    """Create a minimal Parquet data file for the Iceberg table."""
    # Create sample data matching our schema
    data = {
        "id": [1, 2, 3, 4, 5],
        "user_id": ["user1", "user2", "user3", "user4", "user5"],
        "event_type": ["click", "view", "purchase", "click", "view"],
        "timestamp": [
            datetime(2024, 1, 1, 10, 0, 0),
            datetime(2024, 1, 1, 10, 1, 0),
            datetime(2024, 1, 1, 10, 2, 0),
            datetime(2024, 1, 1, 10, 3, 0),
            datetime(2024, 1, 1, 10, 4, 0),
        ],
        "value": [10.5, 20.3, 100.0, 15.7, 25.1],
    }

    # Create Arrow table
    table = pa.table(data)

    # Write to parquet bytes
    buffer = io.BytesIO()
    pq.write_table(table, buffer)
    buffer.seek(0)

    return buffer.getvalue(), len(data["id"])


def create_manifest_file(data_file_path, record_count, file_size):
    """Create a minimal manifest file (Avro format)."""

    # This is a simplified manifest - in a real scenario you'd use Avro properly
    # For now, let's create a minimal structure that satisfies the requirements

    manifest_entry = {
        "status": 1,  # ADDED
        "snapshot_id": 1,
        "data_file": {
            "content": 0,  # DATA
            "file_path": data_file_path,
            "file_format": "PARQUET",
            "partition": {},
            "record_count": record_count,
            "file_size_in_bytes": file_size,
            "column_sizes": {},
            "value_counts": {},
            "null_value_counts": {},
            "nan_value_counts": {},
            "lower_bounds": {},
            "upper_bounds": {},
            "key_metadata": None,
            "split_offsets": [],
            "equality_ids": [],
        },
    }

    # For simplicity, return JSON (in real Iceberg this would be Avro)
    return json.dumps([manifest_entry], indent=2).encode("utf-8")


def create_manifest_list(manifest_path, manifest_length):
    """Create a minimal manifest list file (Avro format)."""

    manifest_file_entry = {
        "manifest_path": manifest_path,
        "manifest_length": manifest_length,
        "partition_spec_id": 0,
        "content": 0,  # DATA
        "sequence_number": 0,
        "min_sequence_number": 0,
        "added_snapshot_id": 1,
        "added_data_files_count": 1,
        "existing_data_files_count": 0,
        "deleted_data_files_count": 0,
        "added_rows_count": 5,
        "existing_rows_count": 0,
        "deleted_rows_count": 0,
        "partitions": [],
    }

    # For simplicity, return JSON (in real Iceberg this would be Avro)
    return json.dumps([manifest_file_entry], indent=2).encode("utf-8")


def main():
    # AWS credentials from environment variables
    aws_access_key = os.getenv("AWS_ACCESS_KEY_ID")
    aws_secret_key = os.getenv("AWS_SECRET_ACCESS_KEY")
    aws_region = os.getenv("AWS_DEFAULT_REGION", "us-east-1")
    bucket_name = os.getenv("AWS_S3_BUCKET", "ricardometadata")

    # Validate required credentials
    if not aws_access_key or not aws_secret_key:
        print("❌ Error: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be set")
        return 1

    # Initialize S3 client
    s3_client = boto3.client(
        "s3",
        aws_access_key_id=aws_access_key,
        aws_secret_access_key=aws_secret_key,
        region_name=aws_region,
    )

    try:
        print("Creating minimal Iceberg table structure...")

        # 1. Create data file
        print("1. Creating sample data file...")
        data_content, record_count = create_minimal_data_file()
        data_file_path = "data/sample_data.parquet"

        s3_client.put_object(
            Bucket=bucket_name,
            Key=data_file_path,
            Body=data_content,
            ContentType="application/octet-stream",
        )
        print(
            f"   ✅ Created data file: s3://{bucket_name}/{data_file_path} "
            f"({len(data_content)} bytes, {record_count} records)"
        )

        # 2. Create manifest file
        print("2. Creating manifest file...")
        manifest_content = create_manifest_file(
            f"s3://{bucket_name}/{data_file_path}", record_count, len(data_content)
        )
        manifest_path = "metadata/manifest-1.json"  # Using JSON for simplicity

        s3_client.put_object(
            Bucket=bucket_name,
            Key=manifest_path,
            Body=manifest_content,
            ContentType="application/json",
        )
        print(
            f"   ✅ Created manifest file: s3://{bucket_name}/{manifest_path} "
            f"({len(manifest_content)} bytes)"
        )

        # 3. Create manifest list file
        print("3. Creating manifest list file...")
        manifest_list_content = create_manifest_list(
            f"s3://{bucket_name}/{manifest_path}", len(manifest_content)
        )

        # Get the current metadata to find the manifest list path
        response = s3_client.get_object(
            Bucket=bucket_name, Key="metadata/table.metadata.json"
        )
        metadata_str = response["Body"].read().decode("utf-8")
        metadata = json.loads(metadata_str)

        # Find the manifest list path from the snapshot
        manifest_list_path = None
        for snapshot in metadata.get("snapshots", []):
            if "manifest-list" in snapshot:
                manifest_list_path = snapshot["manifest-list"].replace(
                    f"s3://{bucket_name}/", ""
                )
                break

        if manifest_list_path:
            s3_client.put_object(
                Bucket=bucket_name,
                Key=manifest_list_path,
                Body=manifest_list_content,
                ContentType="application/json",
            )
            print(
                f"   ✅ Created manifest list: s3://{bucket_name}/{manifest_list_path} "
                f"({len(manifest_list_content)} bytes)"
            )
        else:
            print("   ❌ Could not find manifest list path in metadata")
            return 1

        # 4. Update metadata to point to real manifest and data files
        print("4. Updating metadata with real file references...")

        # Update the snapshot summary to reflect real data
        for snapshot in metadata.get("snapshots", []):
            if snapshot.get("snapshot-id") == 1:
                snapshot["summary"] = {
                    "operation": "append",
                    "total-records": str(record_count),
                    "total-data-files": "1",
                    "total-files-size": str(len(data_content)),
                    "added-data-files": "1",
                    "added-records": str(record_count),
                }

        # Upload updated metadata
        updated_metadata_str = json.dumps(metadata, indent=2)
        s3_client.put_object(
            Bucket=bucket_name,
            Key="metadata/table.metadata.json",
            Body=updated_metadata_str,
            ContentType="application/json",
        )
        print("   ✅ Updated table metadata")

        print("\n🎉 Successfully created minimal Iceberg table structure!")
        print(f"📊 Table contains {record_count} records in 1 data file")
        print("📁 File structure:")
        print(f"   └── s3://{bucket_name}/")
        print(f"       ├── {data_file_path}")
        print(f"       ├── {manifest_path}")
        print(f"       ├── {manifest_list_path}")
        print("       └── metadata/table.metadata.json")

        return 0

    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback

        traceback.print_exc()
        return 1


if __name__ == "__main__":
    exit(main())
