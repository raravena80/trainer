#!/bin/bash

# Shared functions for IRSA kind setup scripts

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Validate AWS account access
validate_aws_access() {
    if ! aws sts get-caller-identity &> /dev/null; then
        error "Cannot access AWS. Please check your credentials."
        return 1
    fi
    return 0
}

# Generate unique suffix if not provided
generate_suffix() {
    echo "$(date +%Y%m%d-%H%M%S)"
}

# Check if kind cluster exists
cluster_exists() {
    local cluster_name="$1"
    kind get clusters | grep -q "^${cluster_name}$"
}

# Wait for deployment to be ready
wait_for_deployment() {
    local deployment="$1"
    local namespace="${2:-default}"
    local timeout="${3:-300}"

    log "Waiting for deployment $deployment in namespace $namespace..."
    kubectl wait --for=condition=available --timeout="${timeout}s" "deployment/$deployment" -n "$namespace"
}

# Check if S3 bucket exists
bucket_exists() {
    local bucket_name="$1"
    aws s3api head-bucket --bucket "$bucket_name" &> /dev/null
}

# Check if IAM role exists
role_exists() {
    local role_name="$1"
    aws iam get-role --role-name "$role_name" &> /dev/null
}

# Check if OIDC provider exists
oidc_provider_exists() {
    local provider_arn="$1"
    aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$provider_arn" &> /dev/null
}

# Create directory if it doesn't exist
ensure_directory() {
    local dir_path="$1"
    if [ ! -d "$dir_path" ]; then
        mkdir -p "$dir_path"
    fi
}

# Validate cluster configuration file
validate_cluster_config() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        error "Cluster configuration file not found: $config_file"
        return 1
    fi

    # Source the config and check required variables
    source "$config_file"

    local required_vars=(
        "CLUSTER_NAME"
        "AWS_REGION"
        "DISCOVERY_BUCKET"
        "ISSUER_URL"
        "PROVIDER_ARN"
        "ACCOUNT_ID"
    )

    for var in "${required_vars[@]}"; do
        if [ -z "${!var:-}" ]; then
            error "Required variable $var not found in $config_file"
            return 1
        fi
    done

    return 0
}

# Clean up temporary files
cleanup_temp_files() {
    local temp_files=(
        "/tmp/s3-readonly-policy.json"
        "/tmp/discovery.json"
        "/tmp/keys.json"
        "/tmp/kind-irsa-config.yaml"
        "/tmp/irsa-trust-policy.json"
    )

    for file in "${temp_files[@]}"; do
        [ -f "$file" ] && rm -f "$file"
    done

    [ -d "/tmp/pod-identity-webhook" ] && rm -rf "/tmp/pod-identity-webhook"
}

# Substitute environment variables in template
substitute_template() {
    local template_file="$1"
    local output_file="$2"

    if [ ! -f "$template_file" ]; then
        error "Template file not found: $template_file"
        return 1
    fi

    envsubst < "$template_file" > "$output_file"
}

# Create IAM trust policy for OIDC
create_oidc_trust_policy() {
    local provider_arn="$1"
    local issuer_hostpath="$2"
    local namespace="$3"
    local service_account="$4"
    local output_file="$5"
    local use_wildcard="${6:-false}"

    local condition_type="StringEquals"
    local namespace_pattern="$namespace"

    # If wildcard is enabled and namespace starts with arrow-cache, use StringLike with wildcard
    if [[ "$use_wildcard" == "true" && "$namespace" == arrow-cache* ]]; then
        condition_type="StringLike"
        namespace_pattern="arrow-cache*"
    fi

    cat > "$output_file" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "$provider_arn"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "$condition_type": {
          "$issuer_hostpath:sub": "system:serviceaccount:$namespace_pattern:$service_account"
        }
      }
    }
  ]
}
EOF
}

# Print formatted section header
print_section() {
    local title="$1"
    echo
    echo "=================================="
    echo "$title"
    echo "=================================="
}

# Validate required tools
check_required_tools() {
    local tools=("$@")
    local missing_tools=()

    for tool in "${tools[@]}"; do
        if ! command_exists "$tool"; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        error "Missing required tools: ${missing_tools[*]}"
        log "Please install the missing tools and try again."
        return 1
    fi

    return 0
}
