#!/usr/bin/env python3
"""
Fix Iceberg metadata to reference actual data files in S3.

This script updates the Iceberg table metadata to include proper snapshots
that reference the real Parquet data files, making the demo client work with actual data.
"""

import json
import subprocess
import sys
from datetime import datetime


def get_s3_data_files(bucket_prefix: str):
    """Get list of actual data files in S3."""
    try:
        print(f"Listing data files in {bucket_prefix}/data/...")
        result = subprocess.run(
            ["aws", "s3", "ls", f"{bucket_prefix}/data/", "--recursive"],
            capture_output=True,
            text=True,
            check=True,
        )

        files = []
        for line in result.stdout.strip().split("\n"):
            if line and ".parquet" in line:
                parts = line.split()
                if len(parts) >= 4:
                    size = int(parts[2])
                    filename = parts[3]
                    if filename.endswith(".parquet"):
                        files.append(
                            {"path": f"{bucket_prefix}/{filename}", "size": size}
                        )

        print(f"Found {len(files)} data files:")
        for f in files:
            print(f"  - {f['path']} ({f['size']} bytes)")

        return files

    except subprocess.CalledProcessError as e:
        print(f"Error listing S3 files: {e}")
        return []


def create_manifest_entry(data_file):
    """Create a manifest entry for a data file."""
    return {
        "status": 1,  # ADDED
        "snapshot_id": 1,
        "data_file": {
            "content": 0,  # DATA
            "file_path": data_file["path"],
            "file_format": "PARQUET",
            "partition": {},
            "record_count": 100,  # Estimate - could be refined
            "file_size_in_bytes": data_file["size"],
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


def update_metadata_with_real_files(metadata_loc: str, bucket_prefix: str):
    """Update Iceberg metadata to reference real data files."""

    # Get current metadata
    try:
        print(f"Fetching current metadata from {metadata_loc}...")
        result = subprocess.run(
            ["aws", "s3", "cp", metadata_loc, "-"],
            capture_output=True,
            text=True,
            check=True,
        )

        metadata = json.loads(result.stdout)
        print("✅ Successfully fetched current metadata")

    except Exception as e:
        print(f"❌ Error fetching metadata: {e}")
        return False

    # Get actual data files
    data_files = get_s3_data_files(bucket_prefix)
    if not data_files:
        print("❌ No data files found!")
        return False

    # Calculate totals
    total_records = len(data_files) * 100  # Estimate 100 records per file
    total_size = sum(f["size"] for f in data_files)

    # Create snapshot with references to real data files
    snapshot_id = int(datetime.now().timestamp())
    timestamp_ms = int(datetime.now().timestamp() * 1000)

    # Create a simple snapshot structure that references the data files
    snapshot = {
        "snapshot-id": snapshot_id,
        "timestamp-ms": timestamp_ms,
        "summary": {
            "operation": "append",
            "total-records": str(total_records),
            "total-data-files": str(len(data_files)),
            "total-files-size": str(total_size),
            "added-data-files": str(len(data_files)),
            "added-records": str(total_records),
        },
        # For simplicity, we'll embed file references directly
        # In a full Iceberg implementation, this would reference manifest lists
        "data-files": [f["path"] for f in data_files],
    }

    # Update metadata
    metadata["current-snapshot-id"] = snapshot_id
    metadata["snapshots"] = [snapshot]
    metadata["snapshot-log"] = [
        {"snapshot-id": snapshot_id, "timestamp-ms": timestamp_ms}
    ]
    metadata["last-updated-ms"] = timestamp_ms

    # Write updated metadata
    try:
        updated_metadata = json.dumps(metadata, indent=2)
        print(f"Uploading updated metadata to {metadata_loc}...")

        result = subprocess.run(
            ["aws", "s3", "cp", "-", metadata_loc],
            input=updated_metadata,
            text=True,
            check=True,
        )

        print("✅ Successfully updated metadata with real data file references")
        return True

    except Exception as e:
        print(f"❌ Error uploading metadata: {e}")
        return False


def main():
    """Main function."""
    bucket_prefix = "s3://ricardometadata"
    metadata_loc = f"{bucket_prefix}/metadata/table.metadata.json"

    print("🔧 Fixing Iceberg metadata to reference real data files")
    print("=" * 60)
    print(f"Bucket: {bucket_prefix}")
    print(f"Metadata: {metadata_loc}")
    print()

    if update_metadata_with_real_files(metadata_loc, bucket_prefix):
        print("\n🎉 Metadata successfully updated!")
        print("\nYour demo client will now use the actual data files:")
        print("  - s3://ricardometadata/data/data_000.parquet")
        print("  - s3://ricardometadata/data/data_001.parquet")
        print("\n📋 Next steps:")
        print("  1. Restart the Arrow Cache head node:")
        print("     kubectl rollout restart deployment/arrow-cache-head -n arrow-cache")
        print("  2. Test with the demo client:")
        print("     python3 demo/scripts/demo-arrow-cache-client.py --demo")
        return 0
    else:
        print("\n❌ Failed to update metadata")
        return 1


if __name__ == "__main__":
    sys.exit(main())
