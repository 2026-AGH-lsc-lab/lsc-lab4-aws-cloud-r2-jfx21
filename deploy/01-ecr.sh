#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

echo "=== Step 1: ECR Repository & Podman Image ==="

# 1. Create ECR repository (ignore if exists)
echo "Creating ECR repository..."
aws ecr create-repository \
    --repository-name "$ECR_REPO_NAME" \
    --region "$AWS_REGION" 2>/dev/null || echo "Repository already exists."

# 2. Podman login to ECR
# Note: Using ${ECR_URI%%/*} extracts the registry hostname from your full URI
echo "Logging into ECR..."
REGISTRY_URL="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
aws ecr get-login-password --region "$AWS_REGION" \
    | podman login --username AWS --password-stdin "$REGISTRY_URL"

# 3. Build image (FORCING AMD64)
# This is the "Magic Sauce" that prevents the Manifest error on Mac
echo "Building image for linux/amd64..."
podman build --platform linux/amd64 -t "${ECR_REPO_NAME}:latest" "$WORKLOAD_DIR"

# 4. Tag and push
echo "Pushing image to ECR..."
podman tag "${ECR_REPO_NAME}:latest" "${ECR_URI}:latest"
podman push "${ECR_URI}:latest"

echo "=== ECR done. Image URI: ${ECR_URI}:latest ==="