#!/usr/bin/env python3
"""
Create a proper Iceberg table using pyiceberg.
"""
import os
import tempfile
from datetime import datetime

import boto3
import pyarrow as pa
from dotenv import load_dotenv
from pyiceberg.catalog.sql import SqlCatalog
from pyiceberg.schema import Schema
from pyiceberg.types import DoubleType, LongType, NestedField, StringType, TimestampType

# Load environment variables from .env file
load_dotenv()


def create_sample_data():
    """Create sample data for testing."""
    # Create Arrow schema that matches our Iceberg schema
    arrow_schema = pa.schema(
        [
            pa.field("id", pa.int64(), nullable=False),
            pa.field("user_id", pa.string(), nullable=False),
            pa.field("event_type", pa.string(), nullable=False),
            pa.field("timestamp", pa.timestamp("us"), nullable=False),
            pa.field("value", pa.float64(), nullable=True),
        ]
    )

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

    return pa.table(data, schema=arrow_schema)


def setup_s3_filesystem():
    """Setup S3 filesystem configuration for pyiceberg."""
    # Environment variables should already be loaded from .env file
    # Validate they exist
    if not os.getenv("AWS_ACCESS_KEY_ID") or not os.getenv("AWS_SECRET_ACCESS_KEY"):
        raise ValueError("AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be set")


def create_proper_table():
    """Create a proper Iceberg table with pyiceberg."""

    # Setup S3 credentials
    setup_s3_filesystem()

    # Create a temporary SQLite database for the catalog
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as tmp_db:
        db_path = tmp_db.name

    try:
        # Create SQL catalog
        # Get S3 bucket from environment
        s3_bucket = os.getenv("AWS_S3_BUCKET", "ricardometadata")

        catalog = SqlCatalog(
            "my_catalog",
            **{"uri": f"sqlite:///{db_path}", "warehouse": f"s3://{s3_bucket}"},
        )

        # Define schema
        schema = Schema(
            NestedField(field_id=1, name="id", field_type=LongType(), required=True),
            NestedField(
                field_id=2, name="user_id", field_type=StringType(), required=True
            ),
            NestedField(
                field_id=3, name="event_type", field_type=StringType(), required=True
            ),
            NestedField(
                field_id=4, name="timestamp", field_type=TimestampType(), required=True
            ),
            NestedField(
                field_id=5, name="value", field_type=DoubleType(), required=False
            ),
        )

        # Create namespace
        try:
            catalog.create_namespace("ricardoschema")
        except Exception:
            pass  # Namespace might already exist

        # Create table
        table = catalog.create_table(
            identifier="ricardoschema.ricardotable",
            schema=schema,
            location=f"s3://{s3_bucket}",
        )

        # Create sample data
        data = create_sample_data()

        # Append data to table
        table.append(data)

        print("✅ Successfully created proper Iceberg table!")
        print(f"   Table location: {table.location()}")
        print(f"   Schema: {table.schema()}")
        print(f"   Current snapshot: {table.current_snapshot()}")

        # List the files in the bucket to see what was created
        s3_client = boto3.client(
            "s3",
            aws_access_key_id=os.getenv("AWS_ACCESS_KEY_ID"),
            aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
            region_name=os.getenv("AWS_DEFAULT_REGION", "us-east-1"),
        )

        response = s3_client.list_objects_v2(Bucket=s3_bucket, Prefix="")
        print("\n📁 Files created in S3:")
        if "Contents" in response:
            for obj in response["Contents"]:
                print(f"   s3://{s3_bucket}/{obj['Key']} ({obj['Size']} bytes)")

        return True

    except Exception as e:
        print(f"❌ Error creating table: {e}")
        import traceback

        traceback.print_exc()
        return False
    finally:
        # Clean up temp db
        try:
            os.unlink(db_path)
        except Exception:
            pass


def main():
    """Main function."""
    success = create_proper_table()
    return 0 if success else 1


if __name__ == "__main__":
    exit(main())
