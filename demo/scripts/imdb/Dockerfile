FROM python:3.11-slim

# Set environment variables
ENV PYTHONUNBUFFERED=1
ENV AWS_REGION=us-east-1
ENV AWS_DEFAULT_REGION=us-east-1

# Update system packages and install basic dependencies
RUN apt-get update && apt-get install -y \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
RUN pip install --no-cache-dir \
    transformers[torch] \
    datasets \
    pyarrow \
    boto3 \
    torch \
    pyiceberg \
    mypy_boto3_glue \
    accelerate \
    pandas

# Create working directory
WORKDIR /app

# Create lib directory and add required modules
RUN mkdir -p /app/lib

# Create __init__.py for lib directory
RUN echo "# Arrow Cache Demo Library" > /app/lib/__init__.py

# Create stub arrow_cache_client to prevent import errors
RUN cat > /app/lib/arrow_cache_client.py << 'EOF'
class BaseArrowCacheClient:
    def __init__(self, host="localhost", port=50051):
        pass

class S3Utils:
    pass
EOF

# Set default command
CMD ["/bin/bash"]
