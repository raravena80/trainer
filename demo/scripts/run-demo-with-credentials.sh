#!/bin/bash

# Source AWS credentials
source "$(dirname "$0")/aws-credentials.sh"

# Run the demo client with credentials available
exec python3 "$(dirname "$0")/demo-arrow-cache-client.py" "$@"
