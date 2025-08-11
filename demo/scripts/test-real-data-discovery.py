#!/usr/bin/env python3
"""
Test Real Data Discovery

This script tests the real data file discovery functionality without requiring
PyArrow Flight support. It shows which files the demo client would use.
"""

import json
import subprocess
import sys
from typing import List, Optional


def get_real_data_files() -> Optional[List[str]]:
    """Get actual data file paths from S3."""
    try:
        print("🔍 Fetching real data file paths from S3...")

        # Direct approach: list the known S3 data directory
        bucket_prefix = "s3://ricardometadata"
        data_prefix = f"{bucket_prefix}/data/"

        print(f"Listing files in: {data_prefix}")

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
            print(f"✅ Found {len(files)} real data files:")
            for f in files:
                print(f"  - {f}")
            return files
        else:
            print("⚠️ No parquet files found in S3")
            return None

    except Exception as e:
        print(f"❌ Failed to list S3 files: {e}")
        return None


def get_current_arrow_cache_config():
    """Get current Arrow Cache configuration."""
    try:
        print("\n📋 Current Arrow Cache Configuration:")

        # Get metadata location
        result = subprocess.run(
            [
                "kubectl",
                "get",
                "configmap",
                "arrow-cache-config",
                "-n",
                "arrow-cache",
                "-o",
                "json",
            ],
            capture_output=True,
            text=True,
            check=True,
        )

        config = json.loads(result.stdout)
        data = config.get("data", {})

        print(f"  METADATA_LOC: {data.get('METADATA_LOC', 'Not set')}")
        print(f"  TABLE_NAME: {data.get('TABLE_NAME', 'Not set')}")
        print(f"  SCHEMA_NAME: {data.get('SCHEMA_NAME', 'Not set')}")

        return data

    except Exception as e:
        print(f"❌ Failed to get config: {e}")
        return {}


def get_metadata_info(metadata_loc: str):
    """Get information from Iceberg metadata."""
    try:
        print("\n📊 Iceberg Metadata Information:")
        print(f"Fetching from: {metadata_loc}")

        # Fetch metadata
        result = subprocess.run(
            ["aws", "s3", "cp", metadata_loc, "-"],
            capture_output=True,
            text=True,
            check=True,
        )

        metadata = json.loads(result.stdout)

        print(f"  Format Version: {metadata.get('format-version', 'Unknown')}")
        print(f"  Location: {metadata.get('location', 'Unknown')}")

        # Schema info
        schemas = metadata.get("schemas", [])
        if schemas:
            schema = schemas[0]
            fields = schema.get("fields", [])
            print(f"  Schema Fields: {len(fields)}")
            for field in fields[:5]:  # Show first 5 fields
                print(f"    - {field.get('name')}: {field.get('type')}")

        # Snapshot info
        snapshots = metadata.get("snapshots", [])
        print(f"  Snapshots: {len(snapshots)}")
        if snapshots:
            latest = snapshots[-1]
            summary = latest.get("summary", {})
            print(
                f"    Latest snapshot records: {summary.get('total-records', 'Unknown')}"
            )
            print(
                f"    Latest snapshot files: {summary.get('total-data-files', 'Unknown')}"
            )

            # Show data files if available
            data_files = latest.get("data-files", [])
            if data_files:
                print("    Data files referenced:")
                for df in data_files:
                    print(f"      - {df}")

        return metadata

    except Exception as e:
        print(f"❌ Failed to get metadata: {e}")
        return None


def check_pod_status():
    """Check Arrow Cache pod status."""
    try:
        print("\n🚀 Arrow Cache Pod Status:")

        result = subprocess.run(
            ["kubectl", "get", "pods", "-n", "arrow-cache"],
            capture_output=True,
            text=True,
            check=True,
        )

        print(result.stdout)

        # Count running pods
        lines = result.stdout.strip().split("\n")[1:]  # Skip header
        running_pods = sum(1 for line in lines if "Running" in line)
        total_pods = len(lines)

        print(f"Status: {running_pods}/{total_pods} pods running")

        return running_pods > 0

    except Exception as e:
        print(f"❌ Failed to check pod status: {e}")
        return False


def main():
    """Main function."""
    print("🎯 Arrow Cache Real Data Discovery Test")
    print("=" * 50)

    # 1. Check pod status
    pods_running = check_pod_status()

    # 2. Get current configuration
    config = get_current_arrow_cache_config()
    metadata_loc = config.get("METADATA_LOC", "")

    # 3. Get real data files
    data_files = get_real_data_files()

    # 4. Get metadata information
    if metadata_loc:
        # metadata = get_metadata_info(metadata_loc)
        get_metadata_info(metadata_loc)

    # 5. Summary
    print("\n" + "=" * 50)
    print("📋 Summary:")

    if pods_running:
        print("✅ Arrow Cache pods are running")
    else:
        print("❌ Arrow Cache pods are not running")

    if data_files:
        print(f"✅ Found {len(data_files)} real data files")
        print("   The demo client will use these actual S3 files:")
        for df in data_files:
            print(f"   - {df}")
    else:
        print("❌ No real data files found")

    if metadata_loc:
        print(f"✅ Metadata location configured: {metadata_loc}")
    else:
        print("❌ No metadata location configured")

    print("\n🎉 Next steps:")
    if not pods_running:
        print("   1. Start Arrow Cache: ./demo/scripts/setup-arrow-cache-kind.sh")

    print("   2. Fix PyArrow Flight dependency:")
    print("      pip install --force-reinstall --no-cache-dir pyarrow[flight]")
    print("   3. Test demo client:")
    print("      python3 demo/scripts/demo-arrow-cache-client.py --demo")

    return 0


if __name__ == "__main__":
    sys.exit(main())
