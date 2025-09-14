#!/usr/bin/env python3
"""
IMDB Arrow Cache Demo Client

This client demonstrates how to:
1. Connect to the IMDB Arrow Cache system
2. Query movie review data from distributed workers
3. Show sample sentiment classification data
4. Test different query patterns and performance

Usage:
    python3 demo-client.py --demo          # Quick demo mode
    python3 demo-client.py --performance   # Performance test
    python3 demo-client.py --samples 1000  # Custom sample size
"""

import argparse
import logging
import sys
import time

import pyarrow as pa
import pyarrow.flight as flight

# Add lib directory to path
sys.path.append("../lib")

from arrow_cache_client import BaseArrowCacheClient  # noqa: E402

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s"
)


class IMDBDemoClient(BaseArrowCacheClient):
    """Demo client for IMDB Arrow Cache system."""

    def __init__(self, host: str = "localhost", port: int = 50051):
        super().__init__(host, port)
        self.namespace = "arrow-cache-imdb"

    def process_query_result(self, result, description: str):
        """Process IMDB demo query results with sentiment analysis."""
        if len(result) > 0:
            self.logger.info(f"=== {description} ===")
            self.logger.info(f"Retrieved {len(result)} IMDB movie reviews")
            self.logger.info(f"Columns: {result.column_names}")

            # Convert to pandas for analysis
            df = result.to_pandas()

            # Show sentiment distribution
            if "label" in df.columns:
                label_counts = df["label"].value_counts()
                total = len(df)
                self.logger.info("Sentiment Distribution:")
                for label, count in label_counts.items():
                    sentiment = "Positive" if label == 1 else "Negative"
                    percentage = (count / total) * 100
                    self.logger.info(f"  {sentiment}: {count} ({percentage:.1f}%)")

            # Show sample reviews
            self.logger.info("\n=== Sample Movie Reviews ===")
            for i in range(min(3, len(df))):
                sample = df.iloc[i]
                sentiment = "Positive" if sample.get("label") == 1 else "Negative"
                text = str(sample.get("text", ""))[:200]
                self.logger.info(f"\nReview {i+1} [{sentiment}]:")
                self.logger.info(f"  {text}...")
        else:
            self.logger.warning(f"No data retrieved for {description}")

    def run_imdb_demo(self):
        """Run comprehensive IMDB dataset demo."""
        self.logger.info("🎬 Starting IMDB Movie Review Demo")
        self.logger.info("=" * 50)

        # Connect to Arrow Cache
        self.connect()

        # Query all partitions like the training script does
        num_partitions = 4
        all_data = []

        for partition_id in range(num_partitions):
            try:
                self.logger.info(f"Fetching partition {partition_id}/{num_partitions}")

                flight_info = self.get_flight_info_for_partition(
                    partition_id, num_partitions
                )

                if flight_info.endpoints:
                    for endpoint in flight_info.endpoints:
                        if endpoint.locations and endpoint.ticket:
                            worker_uri = self.translate_worker_uri(
                                endpoint.locations[0].uri, self.namespace
                            )

                            self.logger.info(f"Querying worker at {worker_uri}")

                            try:
                                worker_location = flight.Location(worker_uri)
                                worker_client = flight.FlightClient(worker_location)

                                flight_stream = worker_client.do_get(endpoint.ticket)
                                partition_data = flight_stream.read_all()

                                self.logger.info(
                                    f"Retrieved {len(partition_data)} rows from "
                                    f"partition {partition_id}"
                                )

                                # Process a sample of this partition
                                sample_size = min(100, len(partition_data))
                                if len(partition_data) > sample_size:
                                    # Take first 100 rows as sample
                                    sample_data = partition_data.slice(0, sample_size)
                                else:
                                    sample_data = partition_data

                                self.process_query_result(
                                    sample_data,
                                    f"Partition {partition_id} Sample ({sample_size} reviews)",
                                )
                                all_data.append(partition_data)
                                break

                            except Exception as e:
                                self.logger.warning(
                                    f"Failed to query worker {worker_uri}: {e}"
                                )
                else:
                    self.logger.warning(
                        f"No endpoints found for partition {partition_id}"
                    )

            except Exception as e:
                self.logger.warning(
                    f"Failed to get flight info for partition {partition_id}: {e}"
                )

            # Small delay between partitions to avoid overwhelming servers
            time.sleep(0.5)

        if all_data:
            # Show overall statistics
            total_data = pa.concat_tables(all_data)
            self.logger.info("\n🎬 Overall IMDB Dataset Statistics:")
            self.logger.info(f"Total samples across all partitions: {len(total_data)}")

            # Show overall sentiment distribution
            df_total = total_data.to_pandas()
            if "label" in df_total.columns:
                label_counts = df_total["label"].value_counts()
                total = len(df_total)
                self.logger.info("Overall Sentiment Distribution:")
                for label, count in label_counts.items():
                    sentiment = "Positive" if label == 1 else "Negative"
                    percentage = (count / total) * 100
                    self.logger.info(f"  {sentiment}: {count:,} ({percentage:.1f}%)")

        self.logger.info("🎬 IMDB demo completed!")

    def run_sentiment_analysis_demo(self):
        """Run sentiment-focused demo queries."""
        self.logger.info("😊😞 Running Sentiment Analysis Demo")

        self.connect()

        # Query all partitions systematically for sentiment analysis
        num_partitions = 4
        all_sentiment_data = []

        for partition_id in range(num_partitions):
            try:
                self.logger.info(
                    f"Analyzing sentiment in partition {partition_id}/{num_partitions}"
                )

                flight_info = self.get_flight_info_for_partition(
                    partition_id, num_partitions
                )

                if flight_info.endpoints:
                    for endpoint in flight_info.endpoints:
                        if endpoint.locations and endpoint.ticket:
                            worker_uri = self.translate_worker_uri(
                                endpoint.locations[0].uri, self.namespace
                            )

                            self.logger.info(
                                f"Querying worker at {worker_uri} for sentiment analysis"
                            )

                            try:
                                worker_location = flight.Location(worker_uri)
                                worker_client = flight.FlightClient(worker_location)

                                flight_stream = worker_client.do_get(endpoint.ticket)
                                partition_data = flight_stream.read_all()

                                self.logger.info(
                                    f"Retrieved {len(partition_data)} rows from "
                                    f"partition {partition_id}"
                                )

                                # Process sentiment analysis for this partition
                                sample_size = min(500, len(partition_data))
                                if len(partition_data) > sample_size:
                                    sample_data = partition_data.slice(0, sample_size)
                                else:
                                    sample_data = partition_data

                                self.process_query_result(
                                    sample_data,
                                    f"Partition {partition_id} Sentiment Analysis "
                                    f"({sample_size} reviews)",
                                )
                                all_sentiment_data.append(sample_data)
                                break

                            except Exception as e:
                                self.logger.warning(
                                    f"Failed to query worker {worker_uri}: {e}"
                                )
                else:
                    self.logger.warning(
                        f"No endpoints found for partition {partition_id}"
                    )

            except Exception as e:
                self.logger.warning(
                    f"Failed to get flight info for partition {partition_id}: {e}"
                )

            time.sleep(0.5)  # Small delay between partitions

        if all_sentiment_data:
            # Show cross-partition sentiment analysis
            total_data = pa.concat_tables(all_sentiment_data)
            self.logger.info("\n😊😞 Cross-Partition Sentiment Analysis:")
            self.logger.info(f"Total samples analyzed: {len(total_data)}")

            # Show overall sentiment distribution across all partitions
            df_total = total_data.to_pandas()
            if "label" in df_total.columns:
                label_counts = df_total["label"].value_counts()
                total = len(df_total)
                self.logger.info(
                    "Overall Sentiment Distribution Across All Partitions:"
                )
                for label, count in label_counts.items():
                    sentiment = "Positive" if label == 1 else "Negative"
                    percentage = (count / total) * 100
                    self.logger.info(f"  {sentiment}: {count:,} ({percentage:.1f}%)")

        self.logger.info("😊😞 Sentiment analysis demo completed!")


def main():
    parser = argparse.ArgumentParser(description="IMDB Arrow Cache Demo Client")
    parser.add_argument("--host", default="localhost", help="Arrow Cache head host")
    parser.add_argument("--port", type=int, default=50051, help="Arrow Cache head port")
    parser.add_argument("--demo", action="store_true", help="Run quick demo")
    parser.add_argument(
        "--sentiment", action="store_true", help="Run sentiment analysis demo"
    )
    parser.add_argument(
        "--performance", action="store_true", help="Run performance test"
    )
    parser.add_argument(
        "--queries", type=int, default=10, help="Number of performance test queries"
    )

    args = parser.parse_args()

    # Create demo client
    demo_client = IMDBDemoClient(args.host, args.port)

    if args.demo:
        demo_client.run_imdb_demo()
    elif args.sentiment:
        demo_client.run_sentiment_analysis_demo()
    elif args.performance:
        # Custom query ranges for IMDB performance testing
        imdb_query_ranges = [
            (0, 999, "First 1000 reviews"),
            (1000, 2999, "Reviews 1000-2999"),
            (5000, 7999, "Mid-range reviews"),
            (10000, 12999, "Later reviews"),
            (20000, 24999, "Final batch"),
        ]
        demo_client.run_performance_test(args.queries, imdb_query_ranges)
    else:
        print("Please specify --demo, --sentiment, or --performance")
        print("Use --help for more options")


if __name__ == "__main__":
    main()
