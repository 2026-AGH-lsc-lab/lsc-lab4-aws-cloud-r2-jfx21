#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

echo "=== Step 5: EC2 Application Instance (t3.small) ==="

# --- Get default VPC ---
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION")

# --- Security Group ---
echo "Creating/Checking app security group..."
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${APP_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
    SG_ID=$(aws ec2 create-security-group --group-name "$APP_SG_NAME" --description "EC2 app for k-NN lab" --vpc-id "$VPC_ID" --query 'GroupId' --output text --region "$AWS_REGION")
    # Add rules, ignoring errors if they already exist
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 8080 --cidr 0.0.0.0/0 --region "$AWS_REGION" || true
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 --region "$AWS_REGION" || true
fi
echo "Security Group: ${SG_ID}"

# --- Find AMI (Ensure x86_64 to match t3.small) ---
echo "Finding latest Amazon Linux 2023 x86_64 AMI..."
AMI_ID=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text --region "$AWS_REGION")
echo "AMI: ${AMI_ID}"

# --- Instance Profile (AWS Academy optimized) ---
INSTANCE_PROFILE_NAME="LabInstanceProfile"
if ! aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" &>/dev/null; then
    echo "ERROR: LabInstanceProfile not found. If not in AWS Academy, create it before running."
    exit 1
fi

# --- User data script ---
# We use a HEREDOC to make it cleaner and ensure variables are expanded correctly
USER_DATA=$(cat <<EOF
#!/bin/bash
dnf update -y
dnf install -y docker
systemctl enable docker
systemctl start docker

# Give Docker a few seconds to start up
sleep 5

# Authenticate to ECR and run container
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
docker pull ${ECR_URI}:latest
docker run -d -p 8080:8080 -e MODE=server --restart always --name knn-app ${ECR_URI}:latest
EOF
)

# --- Launch or Locate Instance ---
EXISTING_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=lsc-knn-app" "Name=instance-state-name,Values=running,pending" --query 'Reservations[0].Instances[0].InstanceId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [ "$EXISTING_ID" != "None" ] && [ -n "$EXISTING_ID" ]; then
    echo "Instance already running: ${EXISTING_ID}"
    INSTANCE_ID="$EXISTING_ID"
else
    echo "Launching EC2 instance (t3.small)..."
    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type t3.small \
        --iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}" \
        --security-group-ids "$SG_ID" \
        --user-data "$USER_DATA" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=lsc-knn-app}]" \
        --query 'Instances[0].InstanceId' --output text \
        --region "$AWS_REGION")
fi

echo "Waiting for instance ($INSTANCE_ID) to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region "$AWS_REGION")

echo "=== EC2 App Ready ==="
echo "Public IP: ${PUBLIC_IP}"
echo "URL: http://${PUBLIC_IP}:8080"
echo "Check progress: ssh -i your-key.pem ec2-user@${PUBLIC_IP} 'sudo tail -f /var/log/user-data.log'"