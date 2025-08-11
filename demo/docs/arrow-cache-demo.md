# Arrow Cache Demo Setup Guide

This guide shows you how to set up and demo the distributed Arrow Cache system on a local kind Kubernetes cluster.

## Overview

The Arrow Cache system is a distributed caching layer built with Rust and Apache Arrow Flight protocol. It consists of:

- **Head Node**: Coordinates data distribution and serves as the main entry point
- **Worker Nodes**: Cache assigned data files in memory and serve query results
- **Flight Protocol**: High-performance data transport using Apache Arrow

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Client        │───▶│   Head Node     │───▶│ Worker Nodes    │
│ (Flight Client) │    │ (Coordinator)   │    │ (Data Cache)    │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                │                       │
                                ▼                       ▼
                       ┌─────────────────┐    ┌─────────────────┐
                       │  File Assignment│    │  Query Results  │
                       │  Distribution   │    │  Streaming      │
                       └─────────────────┘    └─────────────────┘
```

## Prerequisites

1. **Docker** - For building container images
2. **kind** - For local Kubernetes cluster
   ```bash
   # macOS
   brew install kind

   # Linux
   curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
   chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind
   ```

3. **kubectl** - For Kubernetes management
   ```bash
   # macOS
   brew install kubectl

   # Linux
   curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
   chmod +x kubectl && sudo mv kubectl /usr/local/bin/
   ```

4. **Python dependencies** (for demo client):
   ```bash
   pip install pyarrow grpcio
   ```

## Quick Start

### 1. Automated Setup

Run the automated setup script:

```bash
./demo/scripts/setup-arrow-cache-kind.sh
```

This script will:
- Check prerequisites
- Create a kind cluster named `arrow-cache-demo`
- Build and load the Docker image
- Deploy the arrow cache system
- Set up port forwarding
- Show status and demo commands

### 2. Configure AWS Credentials (Required)

The head node needs AWS credentials to access Iceberg metadata in S3:

```bash
./demo/scripts/setup-aws-credentials.sh
```

This script will:
- Prompt for your AWS Access Key ID and Secret Access Key
- Create/update the Kubernetes secret
- Restart the head node deployment
- Validate the credentials

### 3. Check Demo Status

View the current status of your deployment:

```bash
./demo/scripts/demo-arrow-cache-status.sh
```

### 2. Manual Setup (Alternative)

If you prefer manual setup:

```bash
# 1. Create kind cluster
kind create cluster --name arrow-cache-demo

# 2. Build and load image
docker build -f cmd/data_cache/Dockerfile -t arrow-cache:latest .
kind load docker-image arrow-cache:latest --name arrow-cache-demo

# 3. Deploy to cluster
kubectl apply -k demo/manifests/arrow-cache/

# 4. Wait for pods to be ready
kubectl wait --for=condition=ready pod -l app=arrow-cache-head -n arrow-cache --timeout=300s
kubectl wait --for=condition=ready pod -l app=arrow-cache-worker -n arrow-cache --timeout=300s

# 5. Set up port forwarding
kubectl port-forward -n arrow-cache service/arrow-cache-head-svc 50051:50051
```

## Configuration

Before running, update the configuration in `demo/manifests/arrow-cache/configmap.yaml`:

```yaml
data:
  METADATA_LOC: "gs://your-bucket/metadata"  # Your dataset metadata location
  TABLE_NAME: "your_table"                   # Your table name
  SCHEMA_NAME: "your_schema"                 # Your schema name
```

## Demo Usage

### 1. Basic Demo

Run the Python demo client:

```bash
python3 demo/scripts/demo-arrow-cache-client.py --demo
```

This will:
- Connect to the head node at localhost:50051
- Send file assignments to workers
- Query different data ranges
- Show the distributed caching in action

### 2. Performance Test

Run performance testing:

```bash
python3 demo/scripts/demo-arrow-cache-client.py --perf-test --queries 20
```

### 3. Manual Testing with Flight Client

You can also manually test using any Apache Arrow Flight client:

```python
import pyarrow.flight as flight

# Connect to head node
client = flight.FlightClient("grpc://localhost:50051")

# Create ticket for row range 0-99
import struct
ticket_data = struct.pack('QQ', 0, 99)  # start_row, end_row
ticket = flight.Ticket(ticket_data)

# Query data
stream = client.do_get(ticket)
table = stream.read_all()
print(f"Retrieved {len(table)} rows")
```

## Monitoring and Troubleshooting

### Check Deployment Status

```bash
# View all resources
kubectl get all -n arrow-cache

# Check pod logs
kubectl logs -n arrow-cache -l component=head -f
kubectl logs -n arrow-cache -l component=worker -f

# Describe pods for detailed status
kubectl describe pod -n arrow-cache -l component=head
```

### Common Issues

1. **Pods not starting**: Check resource limits and Docker image
2. **Connection refused**: Verify port forwarding is active
3. **Build failures**: Ensure Rust binaries are correctly built

### Scaling Workers

Scale the number of worker nodes:

```bash
kubectl scale statefulset arrow-cache-worker --replicas=3 -n arrow-cache
```

Update the worker mapping in the configmap accordingly.

## Architecture Details

### Head Node
- **Service**: `arrow-cache-head-svc` on port 50051
- **Purpose**: Receives client requests, distributes work to workers
- **Deployment**: Single replica deployment

### Worker Nodes
- **Service**: `arrow-cache-worker-svc` (headless) on port 50051
- **Purpose**: Cache assigned data files, serve query results
- **Deployment**: StatefulSet with 2 replicas by default

### Storage
- **Type**: In-memory caching using DataFusion
- **Persistence**: None (ephemeral, suitable for demo)
- **Scaling**: Horizontal by adding more worker replicas

## Cleanup

### Remove Deployment Only
```bash
kubectl delete -k demo/manifests/arrow-cache/
```

### Remove Everything Including Cluster
```bash
kind delete cluster --name arrow-cache-demo
```

## Next Steps for Production

1. **Persistent Storage**: Add persistent volumes for data caching
2. **Authentication**: Implement proper authentication for Flight protocol
3. **Monitoring**: Add Prometheus metrics and Grafana dashboards
4. **High Availability**: Multi-replica head node with load balancing
5. **Resource Management**: Fine-tune CPU/memory limits
6. **Network Policies**: Implement proper network segmentation

## Talk Demo Flow

For your presentation, consider this demo flow:

1. **Show Architecture**: Explain the distributed head-worker model
2. **Deploy System**: Run the setup script live
3. **Load Data**: Demonstrate file assignment to workers
4. **Query Data**: Show distributed query execution
5. **Scale Workers**: Live scaling demonstration
6. **Performance**: Show query performance metrics
7. **Cleanup**: Quick teardown

The entire demo can run in 5-10 minutes with the automated setup script.
