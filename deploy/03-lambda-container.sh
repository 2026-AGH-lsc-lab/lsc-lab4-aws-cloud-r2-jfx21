#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

echo "=== Step 3: Lambda Container Deployment (Podman) ==="

# 1. Build the image for Intel (x86_64)
echo "Building Container Image for linux/amd64..."
podman build --platform linux/amd64 -t "${ECR_URI}:latest" "$WORKLOAD_DIR"

# 2. Login and Push to ECR
echo "Pushing image to ECR..."
aws ecr get-login-password --region "$AWS_REGION" | podman login --username AWS --password-stdin "${ECR_URI}"
podman push "${ECR_URI}:latest"

# 3. Deploy to Lambda
echo "Deploying to Lambda..."
if aws lambda get-function --function-name "$LAMBDA_CONTAINER_NAME" --region "$AWS_REGION" &>/dev/null; then
    echo "Updating Lambda code..."
    aws lambda update-function-code \
        --function-name "$LAMBDA_CONTAINER_NAME" \
        --image-uri "${ECR_URI}:latest" \
        --region "$AWS_REGION" --output text --query 'FunctionArn'
    
    echo "Waiting for update to finish..."
    aws lambda wait function-updated-v2 --function-name "$LAMBDA_CONTAINER_NAME" --region "$AWS_REGION"

    aws lambda update-function-configuration \
        --function-name "$LAMBDA_CONTAINER_NAME" \
        --memory-size "$LAMBDA_MEMORY" \
        --timeout "$LAMBDA_TIMEOUT" \
        --region "$AWS_REGION" --output text --query 'FunctionArn'
else
    echo "Creating new Lambda function..."
    aws lambda create-function \
        --function-name "$LAMBDA_CONTAINER_NAME" \
        --package-type Image \
        --code "ImageUri=${ECR_URI}:latest" \
        --role "$LAB_ROLE_ARN" \
        --timeout "$LAMBDA_TIMEOUT" \
        --memory-size "$LAMBDA_MEMORY" \
        --region "$AWS_REGION" --output text --query 'FunctionArn'
fi

aws lambda wait function-active-v2 --function-name "$LAMBDA_CONTAINER_NAME" --region "$AWS_REGION"

# Create Function URL
echo "Creating Function URL..."
FUNC_URL=$(aws lambda get-function-url-config \
    --function-name "$LAMBDA_CONTAINER_NAME" \
    --region "$AWS_REGION" \
    --query 'FunctionUrl' --output text 2>/dev/null || true)

if [ -z "$FUNC_URL" ] || [ "$FUNC_URL" = "None" ]; then
    FUNC_URL=$(aws lambda create-function-url-config \
        --function-name "$LAMBDA_CONTAINER_NAME" \
        --auth-type AWS_IAM \
        --region "$AWS_REGION" \
        --query 'FunctionUrl' --output text)

    aws lambda add-permission \
        --function-name "$LAMBDA_CONTAINER_NAME" \
        --statement-id FunctionURLInvoke \
        --action lambda:InvokeFunctionUrl \
        --principal "*" \
        --function-url-auth-type AWS_IAM \
        --region "$AWS_REGION" || true
fi

echo "=== Container Deployment Done ==="