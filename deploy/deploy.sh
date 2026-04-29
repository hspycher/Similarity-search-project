#!/usr/bin/env bash
# deploy.sh — Provision an EC2 instance in us-west-2 that runs the Fashion
# Similarity Search app (Streamlit on :8501) and queries the existing Qdrant
# collection at http://16.144.140.219:6333.
#
# Usage:
#   ./deploy.sh                       # create everything
#   MY_IP=1.2.3.4/32 ./deploy.sh      # restrict :8501 to your IP only
#
# Prerequisites:
#   - AWS CLI v2 installed and `aws configure` done (or AWS_PROFILE set)
#   - IAM permissions for ec2:* (RunInstances, CreateSecurityGroup, etc.)
#
# Output: writes deploy.state with instance ID + public IP, and prints the URL.

set -euo pipefail

# ── Tweakable defaults ───────────────────────────────────────────────────────
REGION="${REGION:-us-west-2}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"
KEY_NAME="${KEY_NAME:-fashion-search-key}"
SG_NAME="${SG_NAME:-fashion-search-sg}"
TAG_NAME="${TAG_NAME:-fashion-search}"
REPO_URL="${REPO_URL:-https://github.com/dongyansun/Similarity-search-project.git}"
ROOT_VOLUME_GB="${ROOT_VOLUME_GB:-30}"

# Restrict :8501 to this CIDR. Default = open to internet.
# Override with: MY_IP="$(curl -s https://checkip.amazonaws.com)/32" ./deploy.sh
APP_PORT_CIDR="${MY_IP:-0.0.0.0/0}"
SSH_CIDR="${SSH_CIDR:-0.0.0.0/0}"

# ── Helpers ──────────────────────────────────────────────────────────────────
log() { printf "\033[1;36m[deploy]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[error]\033[0m %s\n" "$*" >&2; exit 1; }

command -v aws >/dev/null || err "aws CLI not found. Install: https://aws.amazon.com/cli/"
aws sts get-caller-identity --region "$REGION" >/dev/null \
    || err "AWS credentials not configured. Run: aws configure"

cd "$(dirname "$0")"
[[ -f user-data.sh ]] || err "user-data.sh not found next to deploy.sh"

# ── Resolve latest Ubuntu 22.04 AMI for the region ──────────────────────────
log "Resolving latest Ubuntu 22.04 LTS AMI in ${REGION}…"
AMI_ID="$(aws ec2 describe-images \
    --region "$REGION" \
    --owners 099720109477 \
    --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
        "Name=state,Values=available" \
    --query 'Images | sort_by(@,&CreationDate) | [-1].ImageId' \
    --output text)"
[[ -n "$AMI_ID" && "$AMI_ID" != "None" ]] || err "Could not resolve Ubuntu AMI"
log "AMI: $AMI_ID"

# ── Key pair ─────────────────────────────────────────────────────────────────
if aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" \
        >/dev/null 2>&1; then
    log "Key pair '$KEY_NAME' already exists — reusing."
else
    log "Creating key pair '$KEY_NAME' → ${KEY_NAME}.pem"
    aws ec2 create-key-pair \
        --region "$REGION" \
        --key-name "$KEY_NAME" \
        --query 'KeyMaterial' \
        --output text > "${KEY_NAME}.pem"
    chmod 400 "${KEY_NAME}.pem"
fi

# ── Default VPC ──────────────────────────────────────────────────────────────
VPC_ID="$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters "Name=is-default,Values=true" \
    --query 'Vpcs[0].VpcId' --output text)"
[[ "$VPC_ID" != "None" ]] || err "No default VPC in $REGION. Create one or set VPC_ID manually."
log "Default VPC: $VPC_ID"

# ── Security group ──────────────────────────────────────────────────────────
SG_ID="$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)"

if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
    log "Creating security group '$SG_NAME'"
    SG_ID="$(aws ec2 create-security-group \
        --region "$REGION" \
        --group-name "$SG_NAME" \
        --description "Fashion similarity search — Streamlit on 8501" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' --output text)"

    aws ec2 authorize-security-group-ingress \
        --region "$REGION" --group-id "$SG_ID" \
        --ip-permissions \
            "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${SSH_CIDR},Description=ssh}]" \
            "IpProtocol=tcp,FromPort=8501,ToPort=8501,IpRanges=[{CidrIp=${APP_PORT_CIDR},Description=streamlit}]" \
        >/dev/null
else
    log "Security group '$SG_NAME' already exists — reusing ($SG_ID)."
fi
log "Security group: $SG_ID  (ssh from $SSH_CIDR, :8501 from $APP_PORT_CIDR)"

# ── Render user-data with REPO_URL substituted ──────────────────────────────
USER_DATA_RENDERED="$(mktemp)"
trap 'rm -f "$USER_DATA_RENDERED"' EXIT
{
    echo "#!/bin/bash"
    echo "export REPO_URL='${REPO_URL}'"
    tail -n +2 user-data.sh
} > "$USER_DATA_RENDERED"

# ── Launch the instance ──────────────────────────────────────────────────────
log "Launching $INSTANCE_TYPE instance…"
INSTANCE_ID="$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --user-data "file://${USER_DATA_RENDERED}" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=${ROOT_VOLUME_GB},VolumeType=gp3,DeleteOnTermination=true}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${TAG_NAME}}]" \
    --query 'Instances[0].InstanceId' --output text)"
log "Instance: $INSTANCE_ID"

log "Waiting for instance to enter 'running' state…"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_IP="$(aws ec2 describe-instances \
    --region "$REGION" --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

# ── Persist state for teardown.sh ────────────────────────────────────────────
cat > deploy.state <<EOF
REGION=$REGION
INSTANCE_ID=$INSTANCE_ID
SG_ID=$SG_ID
SG_NAME=$SG_NAME
KEY_NAME=$KEY_NAME
PUBLIC_IP=$PUBLIC_IP
EOF

cat <<EOF

============================================================
  Fashion Similarity Search — deployed
============================================================
  Region        : $REGION
  Instance      : $INSTANCE_ID  ($INSTANCE_TYPE)
  Public IP     : $PUBLIC_IP
  App URL       : http://$PUBLIC_IP:8501
  SSH           : ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP
  Watch boot    : ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP \\
                    'sudo tail -f /var/log/cloud-init-output.log'

  Note: first boot takes ~5–8 min (installing torch + CLIP).
        The app will be live once Streamlit prints "You can now
        view your Streamlit app in your browser".

  Qdrant target : http://16.144.140.219:6333
                  collection: deepfashion_items

  Tear down     : ./teardown.sh
============================================================
EOF
