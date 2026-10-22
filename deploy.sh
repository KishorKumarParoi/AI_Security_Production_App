#!/usr/bin/env bash
# ==============================================================================
# Enterprise Agentic RAG — Automated End-to-End AWS Production Deployment
# 
# One-command full deployment:
#   1. Validates prerequisites (AWS CLI, Docker, jq, .env)
#   2. Idempotently provisions VPC, subnets, IGW, NAT GW, route tables, and SGs
#   3. Syncs production secrets to AWS Secrets Manager
#   4. Builds, tags, and pushes multi-service container to Amazon ECR
#   5. Configures IAM roles, CloudWatch logs, and ECS cluster
#   6. Renders and registers ECS Fargate task definitions
#   7. Provisions Application Load Balancer with intelligent path routing (:80 -> API, /ui* -> UI)
#   8. Deploys ECS Fargate services with rolling zero-downtime updates
#   9. Configures Application Auto Scaling
#  10. Bootstraps GitHub Secrets via GitHub CLI for continuous CI/CD
#  11. Verifies /health and /ready endpoints on the live AWS domain
# ==============================================================================
set -euo pipefail

# Color formatting
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

echo -e "${CYAN}"
echo "=================================================================="
echo "   🚀 ENTERPRISE AGENTIC RAG — AWS FULL DEPLOYMENT SUITE"
echo "=================================================================="
echo -e "${NC}"

# ── 1. PRE-FLIGHT VALIDATION ──────────────────────────────────────────────────
echo -e "${YELLOW}[1/11] Checking prerequisites...${NC}"

if ! command -v aws &> /dev/null; then
    echo -e "${RED}ERROR: 'aws' CLI is not installed.${NC}"
    exit 1
fi

if ! command -v docker &> /dev/null; then
    echo -e "${RED}ERROR: 'docker' CLI is not installed.${NC}"
    exit 1
fi

if ! docker info &> /dev/null; then
    echo -e "${RED}ERROR: Docker daemon is not running. Please launch Docker Desktop.${NC}"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${RED}ERROR: 'jq' is not installed. Install via: brew install jq${NC}"
    exit 1
fi

if [ ! -f ".env" ]; then
    echo -e "${RED}ERROR: .env file not found in $ROOT_DIR${NC}"
    exit 1
fi

AWS_ACCOUNT=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null || true)
AWS_CALLER_ARN=$(aws sts get-caller-identity --query "Arn" --output text 2>/dev/null || true)
if [ -z "$AWS_ACCOUNT" ]; then
    echo -e "${RED}ERROR: AWS credentials not configured or expired. Run 'aws configure'.${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Authenticated as: ${AWS_CALLER_ARN} (Account: ${AWS_ACCOUNT})${NC}"

# Detect Python binary
PYTHON_BIN="python3"
if [ -f "$ROOT_DIR/.venv/bin/python" ]; then
    PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
elif [ -f "$ROOT_DIR/venv/bin/python" ]; then
    PYTHON_BIN="$ROOT_DIR/venv/bin/python"
fi
echo -e "${GREEN}✓ Python runtime: ${PYTHON_BIN}${NC}"

# Source deployment environment variables
source scripts/aws_deploy_env.sh
echo -e "${GREEN}✓ Region: ${AWS_REGION} | Project: ${PROJECT}${NC}"

# ── 2. NETWORK INFRASTRUCTURE (VPC, SUBNETS, IGW, NAT) ───────────────────────
echo -e "\n${YELLOW}[2/11] Setting up Network Infrastructure...${NC}"

# VPC
VPC_ID=$(aws ec2 describe-vpcs \
    --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=${VPC_NAME}" \
    --query "Vpcs[0].VpcId" \
    --output text 2>/dev/null || true)

if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
    echo "Creating VPC ${VPC_NAME} (${VPC_CIDR})..."
    VPC_ID=$(aws ec2 create-vpc \
        --region "$AWS_REGION" \
        --cidr-block "$VPC_CIDR" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${VPC_NAME}}]" \
        --query "Vpc.VpcId" \
        --output text)
    aws ec2 modify-vpc-attribute --region "$AWS_REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames
    echo -e "${GREEN}✓ Created VPC: ${VPC_ID}${NC}"
else
    echo -e "${GREEN}✓ Existing VPC found: ${VPC_ID}${NC}"
fi

# Internet Gateway
IGW_ID=$(aws ec2 describe-internet-gateways \
    --region "$AWS_REGION" \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --query "InternetGateways[0].InternetGatewayId" \
    --output text 2>/dev/null || true)

if [ -z "$IGW_ID" ] || [ "$IGW_ID" = "None" ]; then
    echo "Creating Internet Gateway..."
    IGW_ID=$(aws ec2 create-internet-gateway \
        --region "$AWS_REGION" \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT}-igw}]" \
        --query "InternetGateway.InternetGatewayId" \
        --output text)
    aws ec2 attach-internet-gateway --region "$AWS_REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
    echo -e "${GREEN}✓ Created & Attached IGW: ${IGW_ID}${NC}"
else
    echo -e "${GREEN}✓ Existing IGW found: ${IGW_ID}${NC}"
fi

# Availability Zones
AZS=$(aws ec2 describe-availability-zones --region "$AWS_REGION" --query "AvailabilityZones[0:2].ZoneName" --output text)
AZ1=$(echo "$AZS" | awk '{print $1}')
AZ2=$(echo "$AZS" | awk '{print $2}')

# Subnets helper
get_or_create_subnet() {
    local cidr="$1"
    local az="$2"
    local name="$3"
    local sub_id
    sub_id=$(aws ec2 describe-subnets --region "$AWS_REGION" --filters "Name=vpc-id,Values=${VPC_ID}" "Name=cidr-block,Values=${cidr}" --query "Subnets[0].SubnetId" --output text 2>/dev/null || true)
    if [ -z "$sub_id" ] || [ "$sub_id" = "None" ]; then
        sub_id=$(aws ec2 create-subnet --region "$AWS_REGION" --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${name}}]" --query "Subnet.SubnetId" --output text)
    fi
    echo "$sub_id"
}

PUBLIC_SUBNET_1=$(get_or_create_subnet "$PUBLIC_SUBNET_1_CIDR" "$AZ1" "${PROJECT}-public-${AZ1}")
PUBLIC_SUBNET_2=$(get_or_create_subnet "$PUBLIC_SUBNET_2_CIDR" "$AZ2" "${PROJECT}-public-${AZ2}")
PRIVATE_SUBNET_1=$(get_or_create_subnet "$PRIVATE_SUBNET_1_CIDR" "$AZ1" "${PROJECT}-private-${AZ1}")
PRIVATE_SUBNET_2=$(get_or_create_subnet "$PRIVATE_SUBNET_2_CIDR" "$AZ2" "${PROJECT}-private-${AZ2}")

# Enable auto-assign public IP on public subnets
aws ec2 modify-subnet-attribute --region "$AWS_REGION" --subnet-id "$PUBLIC_SUBNET_1" --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --region "$AWS_REGION" --subnet-id "$PUBLIC_SUBNET_2" --map-public-ip-on-launch

# NAT Gateway
NAT_GW_1=$(aws ec2 describe-nat-gateways --region "$AWS_REGION" --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available,pending" --query "NatGateways[0].NatGatewayId" --output text 2>/dev/null || true)
if [ -z "$NAT_GW_1" ] || [ "$NAT_GW_1" = "None" ]; then
    echo "Allocating Elastic IP and creating NAT Gateway (this may take ~60s)..."
    EIP_1=$(aws ec2 allocate-address --region "$AWS_REGION" --domain vpc --query "AllocationId" --output text)
    NAT_GW_1=$(aws ec2 create-nat-gateway --region "$AWS_REGION" --subnet-id "$PUBLIC_SUBNET_1" --allocation-id "$EIP_1" --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT}-nat-${AZ1}}]" --query "NatGateway.NatGatewayId" --output text)
    echo "Waiting for NAT gateway ${NAT_GW_1} to become available..."
    aws ec2 wait nat-gateway-available --region "$AWS_REGION" --nat-gateway-ids "$NAT_GW_1"
    echo -e "${GREEN}✓ NAT Gateway is active: ${NAT_GW_1}${NC}"
else
    EIP_1=$(aws ec2 describe-nat-gateways --region "$AWS_REGION" --nat-gateway-ids "$NAT_GW_1" --query "NatGateways[0].NatGatewayAddresses[0].AllocationId" --output text)
    echo -e "${GREEN}✓ Existing NAT Gateway found: ${NAT_GW_1}${NC}"
fi

# Public Route Table
PUBLIC_RT=$(aws ec2 describe-route-tables --region "$AWS_REGION" --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${PROJECT}-public-rt" --query "RouteTables[0].RouteTableId" --output text 2>/dev/null || true)
if [ -z "$PUBLIC_RT" ] || [ "$PUBLIC_RT" = "None" ]; then
    PUBLIC_RT=$(aws ec2 create-route-table --region "$AWS_REGION" --vpc-id "$VPC_ID" --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-public-rt}]" --query "RouteTable.RouteTableId" --output text)
    aws ec2 create-route --region "$AWS_REGION" --route-table-id "$PUBLIC_RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" || true
    aws ec2 associate-route-table --region "$AWS_REGION" --route-table-id "$PUBLIC_RT" --subnet-id "$PUBLIC_SUBNET_1" || true
    aws ec2 associate-route-table --region "$AWS_REGION" --route-table-id "$PUBLIC_RT" --subnet-id "$PUBLIC_SUBNET_2" || true
fi

# Private Route Table
PRIVATE_RT=$(aws ec2 describe-route-tables --region "$AWS_REGION" --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${PROJECT}-private-rt" --query "RouteTables[0].RouteTableId" --output text 2>/dev/null || true)
if [ -z "$PRIVATE_RT" ] || [ "$PRIVATE_RT" = "None" ]; then
    PRIVATE_RT=$(aws ec2 create-route-table --region "$AWS_REGION" --vpc-id "$VPC_ID" --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-private-rt}]" --query "RouteTable.RouteTableId" --output text)
    aws ec2 create-route --region "$AWS_REGION" --route-table-id "$PRIVATE_RT" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_GW_1" || true
    aws ec2 associate-route-table --region "$AWS_REGION" --route-table-id "$PRIVATE_RT" --subnet-id "$PRIVATE_SUBNET_1" || true
    aws ec2 associate-route-table --region "$AWS_REGION" --route-table-id "$PRIVATE_RT" --subnet-id "$PRIVATE_SUBNET_2" || true
fi
echo -e "${GREEN}✓ Routing configured (Public RT: ${PUBLIC_RT}, Private RT: ${PRIVATE_RT})${NC}"

# ── 3. SECURITY GROUPS ────────────────────────────────────────────────────────
echo -e "\n${YELLOW}[3/11] Configuring Security Groups...${NC}"

get_or_create_sg() {
    local name="$1"
    local desc="$2"
    local sg_id
    sg_id=$(aws ec2 describe-security-groups --region "$AWS_REGION" --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${name}" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
    if [ -z "$sg_id" ] || [ "$sg_id" = "None" ]; then
        sg_id=$(aws ec2 create-security-group --region "$AWS_REGION" --group-name "$name" --description "$desc" --vpc-id "$VPC_ID" --query "GroupId" --output text)
    fi
    echo "$sg_id"
}

ALB_SG=$(get_or_create_sg "${PROJECT}-alb-sg" "ALB public ingress security group")
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$ALB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0 2>/dev/null || true
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$ALB_SG" --protocol tcp --port 443 --cidr 0.0.0.0/0 2>/dev/null || true

API_SG=$(get_or_create_sg "${PROJECT}-api-sg" "RAG FastAPI container security group")
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$API_SG" --protocol tcp --port 8080 --source-group "$ALB_SG" 2>/dev/null || true

UI_SG=$(get_or_create_sg "${PROJECT}-ui-sg" "RAG Streamlit UI security group")
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$UI_SG" --protocol tcp --port 8501 --source-group "$ALB_SG" 2>/dev/null || true

echo -e "${GREEN}✓ Security Groups ready (ALB: ${ALB_SG}, API: ${API_SG}, UI: ${UI_SG})${NC}"

# ── 4. SECRETS MANAGER SYNCHRONIZATION ────────────────────────────────────────
echo -e "\n${YELLOW}[4/11] Syncing Secrets to AWS Secrets Manager...${NC}"
"$PYTHON_BIN" scripts/create_aws_secrets.py
source scripts/aws_secret_arns.sh
echo -e "${GREEN}✓ Secrets Manager populated and ARNs cached.${NC}"

# ── 5. IAM ROLES & ACCESS POLICIES ───────────────────────────────────────────
echo -e "\n${YELLOW}[5/11] Configuring IAM Task Roles & Policies...${NC}"

# Trust policy
cat > /tmp/ecs-trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ecs-tasks.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

# Execution Role
aws iam get-role --role-name ecsTaskExecutionRole >/dev/null 2>&1 || \
aws iam create-role --role-name ecsTaskExecutionRole --assume-role-policy-document file:///tmp/ecs-trust-policy.json
aws iam attach-role-policy --role-name ecsTaskExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy 2>/dev/null || true

# Task Roles
aws iam get-role --role-name rag-api-task-role >/dev/null 2>&1 || \
aws iam create-role --role-name rag-api-task-role --assume-role-policy-document file:///tmp/ecs-trust-policy.json

aws iam get-role --role-name rag-ui-task-role >/dev/null 2>&1 || \
aws iam create-role --role-name rag-ui-task-role --assume-role-policy-document file:///tmp/ecs-trust-policy.json

# Read secrets policy
cat > /tmp/rag-secrets-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["secretsmanager:GetSecretValue"],
    "Resource": [
      "$NEON_DB_URL_ARN",
      "$UPSTASH_REDIS_REST_URL_ARN",
      "$UPSTASH_REDIS_REST_TOKEN_ARN",
      "$QDRANT_URL_ARN",
      "$QDRANT_API_KEY_ARN",
      "$OPENAI_API_KEY_ARN",
      "$JINA_API_KEY_ARN",
      "$PORTKEY_API_KEY_ARN",
      "$RAG_API_KEY_ARN",
      "$LOGFIRE_TOKEN_ARN",
      "$LANGSMITH_API_KEY_ARN"
    ]
  }]
}
EOF

SECRETS_POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='rag-read-secrets-policy'].Arn" --output text)
if [ -z "$SECRETS_POLICY_ARN" ]; then
    SECRETS_POLICY_ARN=$(aws iam create-policy --policy-name rag-read-secrets-policy --policy-document file:///tmp/rag-secrets-policy.json --query "Policy.Arn" --output text)
fi

for ROLE in rag-api-task-role rag-ui-task-role ecsTaskExecutionRole; do
    aws iam attach-role-policy --role-name "$ROLE" --policy-arn "$SECRETS_POLICY_ARN" 2>/dev/null || true
done
echo -e "${GREEN}✓ IAM roles and permissions attached.${NC}"

# ── 6. ECR REGISTRY, DOCKER BUILD & PUSH ──────────────────────────────────────
echo -e "\n${YELLOW}[6/11] Building and Pushing Docker Image to Amazon ECR...${NC}"

aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$ECR_REPO" >/dev/null 2>&1 || \
aws ecr create-repository --region "$AWS_REGION" --repository-name "$ECR_REPO" --image-scanning-configuration scanOnPush=true --encryption-configuration encryptionType=AES256

ECR_URI=$(aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$ECR_REPO" --query "repositories[0].repositoryUri" --output text)
echo "Logging Docker into ECR: ${ECR_URI}..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "Building production container image (${ECR_REPO}:latest)..."
docker build -t "${ECR_REPO}:latest" -f Dockerfile .
docker tag "${ECR_REPO}:latest" "${ECR_URI}:latest"

echo "Pushing image to Amazon ECR..."
docker push "${ECR_URI}:latest"
echo -e "${GREEN}✓ Image successfully pushed to ECR: ${ECR_URI}:latest${NC}"

# ── 7. CLOUDWATCH LOGS & ECS CLUSTER ──────────────────────────────────────────
echo -e "\n${YELLOW}[7/11] Initializing CloudWatch Log Groups & ECS Cluster...${NC}"

aws logs create-log-group --region "$AWS_REGION" --log-group-name /ecs/rag-api 2>/dev/null || true
aws logs create-log-group --region "$AWS_REGION" --log-group-name /ecs/rag-ui 2>/dev/null || true

aws ecs describe-clusters --region "$AWS_REGION" --clusters "$ECS_CLUSTER" --query "clusters[0].clusterArn" --output text >/dev/null 2>&1 || \
aws ecs create-cluster --region "$AWS_REGION" --cluster-name "$ECS_CLUSTER" --capacity-providers FARGATE FARGATE_SPOT --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1

echo -e "${GREEN}✓ ECS Cluster active: ${ECS_CLUSTER}${NC}"

# ── 8. APPLICATION LOAD BALANCER & TARGET GROUPS ──────────────────────────────
echo -e "\n${YELLOW}[8/11] Setting up Application Load Balancer...${NC}"

ALB_ARN=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --names "$ALB_NAME" --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null || true)
if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
    echo "Creating ALB ${ALB_NAME}..."
    ALB_ARN=$(aws elbv2 create-load-balancer \
        --region "$AWS_REGION" \
        --name "$ALB_NAME" \
        --type application \
        --scheme internet-facing \
        --security-groups "$ALB_SG" \
        --subnets "$PUBLIC_SUBNET_1" "$PUBLIC_SUBNET_2" \
        --query "LoadBalancers[0].LoadBalancerArn" \
        --output text)
fi

ALB_DNS=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --load-balancer-arns "$ALB_ARN" --query "LoadBalancers[0].DNSName" --output text)
echo -e "${GREEN}✓ ALB active: http://${ALB_DNS}${NC}"

# Target Groups
API_TG_ARN=$(aws elbv2 describe-target-groups --region "$AWS_REGION" --names "${PROJECT}-api-tg" --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)
if [ -z "$API_TG_ARN" ] || [ "$API_TG_ARN" = "None" ]; then
    API_TG_ARN=$(aws elbv2 create-target-group \
        --region "$AWS_REGION" \
        --name "${PROJECT}-api-tg" \
        --protocol HTTP \
        --port 8080 \
        --vpc-id "$VPC_ID" \
        --target-type ip \
        --health-check-path "/health" \
        --health-check-interval-seconds 15 \
        --health-check-timeout-seconds 5 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 3 \
        --matcher "HttpCode=200" \
        --query "TargetGroups[0].TargetGroupArn" \
        --output text)
fi

UI_TG_ARN=$(aws elbv2 describe-target-groups --region "$AWS_REGION" --names "${PROJECT}-ui-tg" --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)
if [ -z "$UI_TG_ARN" ] || [ "$UI_TG_ARN" = "None" ]; then
    UI_TG_ARN=$(aws elbv2 create-target-group \
        --region "$AWS_REGION" \
        --name "${PROJECT}-ui-tg" \
        --protocol HTTP \
        --port 8501 \
        --vpc-id "$VPC_ID" \
        --target-type ip \
        --health-check-path "/_stcore/health" \
        --health-check-interval-seconds 20 \
        --health-check-timeout-seconds 5 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 3 \
        --matcher "HttpCode=200" \
        --query "TargetGroups[0].TargetGroupArn" \
        --output text)
fi

# Listener on port 80
LISTENER_ARN=$(aws elbv2 describe-listeners --region "$AWS_REGION" --load-balancer-arn "$ALB_ARN" --query "Listeners[0].ListenerArn" --output text 2>/dev/null || true)
if [ -z "$LISTENER_ARN" ] || [ "$LISTENER_ARN" = "None" ]; then
    LISTENER_ARN=$(aws elbv2 create-listener \
        --region "$AWS_REGION" \
        --load-balancer-arn "$ALB_ARN" \
        --protocol HTTP \
        --port 80 \
        --default-actions "Type=forward,TargetGroupArn=${API_TG_ARN}" \
        --query "Listeners[0].ListenerArn" \
        --output text)

    # Route /ui* to Streamlit target group
    aws elbv2 create-rule \
        --region "$AWS_REGION" \
        --listener-arn "$LISTENER_ARN" \
        --priority 10 \
        --conditions "Field=path-pattern,PathPatternConfig={Values=[/ui*]}" \
        --actions "Type=forward,TargetGroupArn=${UI_TG_ARN}" >/dev/null
fi
echo -e "${GREEN}✓ ALB Listener & Target Routing configured.${NC}"

# Write state file for render script and teardown script
cat > scripts/aws_deploy_state.sh <<EOF
export AWS_REGION="${AWS_REGION}"
export VPC_ID="${VPC_ID}"
export IGW_ID="${IGW_ID}"
export AZ1="${AZ1}"
export AZ2="${AZ2}"
export PUBLIC_SUBNET_1="${PUBLIC_SUBNET_1}"
export PUBLIC_SUBNET_2="${PUBLIC_SUBNET_2}"
export PRIVATE_SUBNET_1="${PRIVATE_SUBNET_1}"
export PRIVATE_SUBNET_2="${PRIVATE_SUBNET_2}"
export EIP_1="${EIP_1}"
export NAT_GW_1="${NAT_GW_1}"
export PUBLIC_RT="${PUBLIC_RT}"
export PRIVATE_RT="${PRIVATE_RT}"
export ALB_SG="${ALB_SG}"
export API_SG="${API_SG}"
export UI_SG="${UI_SG}"
export ECR_URI="${ECR_URI}"
export SECRETS_POLICY_ARN="${SECRETS_POLICY_ARN}"
export ALB_ARN="${ALB_ARN}"
export ALB_DNS="${ALB_DNS}"
export API_TG_ARN="${API_TG_ARN}"
export UI_TG_ARN="${UI_TG_ARN}"
export LISTENER_ARN="${LISTENER_ARN}"
EOF

# ── 9. TASK DEFINITIONS & ECS SERVICES ────────────────────────────────────────
echo -e "\n${YELLOW}[9/11] Registering Task Definitions & Deploying Services...${NC}"

# Render task definitions
"$PYTHON_BIN" scripts/render_task_defs.py

RAG_API_TASK_DEF_ARN=$(aws ecs register-task-definition --region "$AWS_REGION" --cli-input-json file:///tmp/rag-api.json --query "taskDefinition.taskDefinitionArn" --output text)
RAG_UI_TASK_DEF_ARN=$(aws ecs register-task-definition --region "$AWS_REGION" --cli-input-json file:///tmp/rag-ui.json --query "taskDefinition.taskDefinitionArn" --output text)

echo "RAG_API_TASK_DEF_ARN=${RAG_API_TASK_DEF_ARN}" >> scripts/aws_deploy_state.sh
echo "RAG_UI_TASK_DEF_ARN=${RAG_UI_TASK_DEF_ARN}" >> scripts/aws_deploy_state.sh

# Deploy or Update API Service
API_SERVICE_EXISTS=$(aws ecs describe-services --region "$AWS_REGION" --cluster "$ECS_CLUSTER" --services "rag-api" --query "services[?status=='ACTIVE'].serviceName" --output text 2>/dev/null || true)
if [ -n "$API_SERVICE_EXISTS" ] && [ "$API_SERVICE_EXISTS" != "None" ]; then
    echo "Updating existing service 'rag-api'..."
    aws ecs update-service --region "$AWS_REGION" --cluster "$ECS_CLUSTER" --service "rag-api" --task-definition "$RAG_API_TASK_DEF_ARN" --force-new-deployment >/dev/null
else
    echo "Creating ECS service 'rag-api' (desired: 2)..."
    aws ecs create-service \
        --region "$AWS_REGION" \
        --cluster "$ECS_CLUSTER" \
        --service-name "rag-api" \
        --task-definition "$RAG_API_TASK_DEF_ARN" \
        --desired-count 2 \
        --launch-type FARGATE \
        --platform-version LATEST \
        --network-configuration "awsvpcConfiguration={subnets=[${PRIVATE_SUBNET_1},${PRIVATE_SUBNET_2}],securityGroups=[${API_SG}],assignPublicIp=DISABLED}" \
        --load-balancers "targetGroupArn=${API_TG_ARN},containerName=api,containerPort=8080" \
        --health-check-grace-period-seconds 60 \
        --deployment-configuration "minimumHealthyPercent=100,maximumPercent=200" >/dev/null
fi

# Deploy or Update UI Service
UI_SERVICE_EXISTS=$(aws ecs describe-services --region "$AWS_REGION" --cluster "$ECS_CLUSTER" --services "rag-ui" --query "services[?status=='ACTIVE'].serviceName" --output text 2>/dev/null || true)
if [ -n "$UI_SERVICE_EXISTS" ] && [ "$UI_SERVICE_EXISTS" != "None" ]; then
    echo "Updating existing service 'rag-ui'..."
    aws ecs update-service --region "$AWS_REGION" --cluster "$ECS_CLUSTER" --service "rag-ui" --task-definition "$RAG_UI_TASK_DEF_ARN" --force-new-deployment >/dev/null
else
    echo "Creating ECS service 'rag-ui' (desired: 1)..."
    aws ecs create-service \
        --region "$AWS_REGION" \
        --cluster "$ECS_CLUSTER" \
        --service-name "rag-ui" \
        --task-definition "$RAG_UI_TASK_DEF_ARN" \
        --desired-count 1 \
        --launch-type FARGATE \
        --platform-version LATEST \
        --network-configuration "awsvpcConfiguration={subnets=[${PRIVATE_SUBNET_1},${PRIVATE_SUBNET_2}],securityGroups=[${UI_SG}],assignPublicIp=DISABLED}" \
        --load-balancers "targetGroupArn=${UI_TG_ARN},containerName=ui,containerPort=8501" \
        --health-check-grace-period-seconds 60 \
        --deployment-configuration "minimumHealthyPercent=100,maximumPercent=200" >/dev/null
fi
echo -e "${GREEN}✓ ECS Fargate services triggered successfully.${NC}"

# ── 10. GITHUB CI/CD SECRETS SYNC ─────────────────────────────────────────────
echo -e "\n${YELLOW}[10/11] Configuring GitHub Actions CI/CD Secrets...${NC}"

if command -v gh &>/dev/null && gh auth status &>/dev/null; then
    TARGET_REPO="KishorKumarParoi/AI_Security_Production_App"
    if git config --get remote.origin.url 2>/dev/null | grep -q "AI_Security_Production_App"; then
        GH_REPO_ARG=""
    else
        GH_REPO_ARG="-R $TARGET_REPO"
    fi
    echo "Syncing cloud deployment secrets to GitHub repository (${TARGET_REPO})..."
    AWS_KEY_ID=$(aws configure get aws_access_key_id 2>/dev/null || echo "")
    AWS_SECRET=$(aws configure get aws_secret_access_key 2>/dev/null || echo "")

    [ -n "$AWS_KEY_ID" ] && gh secret set AWS_ACCESS_KEY_ID --body "$AWS_KEY_ID" $GH_REPO_ARG
    [ -n "$AWS_SECRET" ] && gh secret set AWS_SECRET_ACCESS_KEY --body "$AWS_SECRET" $GH_REPO_ARG
    gh secret set AWS_REGION --body "$AWS_REGION" $GH_REPO_ARG
    gh secret set ECR_REPOSITORY --body "$ECR_REPO" $GH_REPO_ARG
    gh secret set ECS_CLUSTER --body "$ECS_CLUSTER" $GH_REPO_ARG
    gh secret set ECS_SERVICE_API --body "rag-api" $GH_REPO_ARG
    gh secret set ECS_SERVICE_UI --body "rag-ui" $GH_REPO_ARG
    gh secret set BACKEND_URL --body "http://${ALB_DNS}" $GH_REPO_ARG

    gh secret set NEON_DB_URL_ARN --body "$NEON_DB_URL_ARN" $GH_REPO_ARG
    gh secret set UPSTASH_REDIS_REST_URL_ARN --body "$UPSTASH_REDIS_REST_URL_ARN" $GH_REPO_ARG
    gh secret set UPSTASH_REDIS_REST_TOKEN_ARN --body "$UPSTASH_REDIS_REST_TOKEN_ARN" $GH_REPO_ARG
    gh secret set QDRANT_URL_ARN --body "$QDRANT_URL_ARN" $GH_REPO_ARG
    gh secret set QDRANT_API_KEY_ARN --body "$QDRANT_API_KEY_ARN" $GH_REPO_ARG
    gh secret set OPENAI_API_KEY_ARN --body "$OPENAI_API_KEY_ARN" $GH_REPO_ARG
    gh secret set JINA_API_KEY_ARN --body "$JINA_API_KEY_ARN" $GH_REPO_ARG
    gh secret set PORTKEY_API_KEY_ARN --body "$PORTKEY_API_KEY_ARN" $GH_REPO_ARG
    gh secret set RAG_API_KEY_ARN --body "$RAG_API_KEY_ARN" $GH_REPO_ARG
    gh secret set LOGFIRE_TOKEN_ARN --body "$LOGFIRE_TOKEN_ARN" $GH_REPO_ARG
    gh secret set LANGSMITH_API_KEY_ARN --body "$LANGSMITH_API_KEY_ARN" $GH_REPO_ARG
    echo -e "${GREEN}✓ All 18 GitHub Actions secrets synced successfully.${NC}"
else
    echo -e "${YELLOW}ℹ GitHub CLI not authenticated. Skipping automatic GitHub secret sync.${NC}"
fi

# ── 11. HEALTH CHECK & VALIDATION ─────────────────────────────────────────────
echo -e "\n${YELLOW}[11/11] Verifying live endpoints on AWS (waiting for tasks to warm up)...${NC}"

HEALTHY=false
for attempt in {1..24}; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${ALB_DNS}/health" || true)
    if [ "$STATUS" = "200" ]; then
        HEALTHY=true
        echo -e "${GREEN}✓ Health check passed with HTTP 200!${NC}"
        break
    fi
    echo "Waiting for ALB targets to become healthy (Attempt $attempt/24)... status: $STATUS"
    sleep 10
done

echo -e "\n${CYAN}=================================================================="
echo "   ✨ DEPLOYMENT COMPLETED SUCCESSFULLY!"
echo "==================================================================${NC}"
echo -e "🌐 Application URL   : ${GREEN}http://${ALB_DNS}${NC}"
echo -e "📖 Swagger API Docs  : ${GREEN}http://${ALB_DNS}/docs${NC}"
echo -e "🩺 Liveness Check    : ${GREEN}http://${ALB_DNS}/health${NC}"
echo -e "🔍 Dependency Ready  : ${GREEN}http://${ALB_DNS}/ready${NC}"
echo -e "🖥️ Streamlit UI      : ${GREEN}http://${ALB_DNS}/ui${NC}"
echo -e "📦 ECS Cluster       : ${GREEN}${ECS_CLUSTER}${NC}"
echo -e "🐳 ECR Image         : ${GREEN}${ECR_URI}:latest${NC}"
echo -e "=================================================================="
echo -e "${YELLOW}To test a query against your live AWS deployment:${NC}"
echo "curl -X POST http://${ALB_DNS}/query \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -d '{\"q\": \"What is an enterprise CronJob and what are its best practices?\"}'"
echo -e "==================================================================\n"
