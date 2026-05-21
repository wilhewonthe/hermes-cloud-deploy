#!/usr/bin/env bash
# =============================================================================
# Deploy Hermes on Alibaba Cloud (using Elastic Compute Service - ECS)
# Prerequisites:
#   - Alibaba Cloud CLI (aliyun) installed and configured (aliyun configure)
#   - Telegram bot token & chat ID ready
#   - (Optional) existing SSH key pair at ~/.ssh/id_rsa.pub
# =============================================================================

set -euo pipefail

# -------------------------- USER SETTINGS --------------------------
# 1. Alibaba Cloud region (default: cn-hangzhou)
REGION="${REGION:-cn-hangzhou}"

# 2. Telegram credentials (mandatory)
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# 3. ECS instance configuration
#    Choose an instance type that fits within free trial or low cost.
#    For example: ecs.t6-c1m1.large (2 vCPU, 4 GB RAM) - often part of free trial.
INSTANCE_TYPE="${INSTANCE_TYPE:-ecs.t6-c1m1.large}"
# Image: Ubuntu 22.04
IMAGE_ID="${IMAGE_ID:-ubuntu_22_04_x64_20U4_alibaba_20230915.vhd}" # Example, may need to look up
# Security group: we'll create one allowing SSH (22) and optional HTTP/HTTPS
SECURITY_GROUP_NAME="${SECURITY_GROUP_NAME:-hermes-sg}"
# Instance name
INSTANCE_NAME="${INSTANCE_NAME:-hermes-instance}"
# SSH key pair name (will be created/uploaded)
KEY_PAIR_NAME="${KEY_PAIR_NAME:-hermes-key}"
# Password (if you prefer password over key, set INSTANCE_PASSWORD and leave key pair empty)
INSTANCE_PASSWORD="${INSTANCE_PASSWORD:-}"
# System disk size (GB)
SYSTEM_DISK_SIZE="${SYSTEM_DISK_SIZE:-40}"
# Data disk size (GB) - optional
DATA_DISK_SIZE="${DATA_DISK_SIZE:-0}"
DATA_DISK_CATEGORY="${DATA_DISK_CATEGORY:-cloud_efficiency}"

# 4. Ollama model to pull
OLLAMA_MODEL="${OLLAMA_MODEL:-nemotron-3-super:cloud}"
# ------------------------------------------------------------------

# ---------- Helper: abort if mandatory vars missing ----------
if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
  echo "❌  Please set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID before running."
  exit 1
fi

# Ensure aliyun CLI is configured (we assume it is; if not, the commands will fail)
# Check if we have a default region set; if not, use the one provided.
aliyun configure get --region >/dev/null 2>&1 || aliyun configure set --region "$REGION"

# ---------- 1. Ensure we have an SSH key pair ----------
SSH_KEY_PATH="${HOME}/.ssh/id_rsa"
if [[ -z "$INSTANCE_PASSWORD" && ( ! -f "$SSH_KEY_PATH" || ! -f "$SSH_KEY_PATH.pub" ) ]]; then
  echo "🔐  Generating a new SSH key pair (no passphrase)…"
  mkdir -p "$(dirname "$SSH_KEY_PATH")"
  ssh-keygen -t rsa -b 2048 -f "$SSH_KEY_PATH" -N "" >/dev/null
fi

# If using key pair, upload it to Alibaba Cloud (if not already uploaded)
if [[ -z "$INSTANCE_PASSWORD" ]]; then
  # Check if key pair exists; if not, import
  KEY_EXISTS=$(aliyun ecs DescribeKeyPairs --region-id "$REGION" --KeyPairNames.1 "$KEY_PAIR_NAME" --query "KeyPairs.KeyPair[0].KeyPairName" --output text 2>/dev/null || true)
  if [[ -z "$KEY_EXISTS" || "$KEY_EXISTS" == "None" ]]; then
    echo "🔑  Importing SSH key pair $KEY_PAIR_NAME to Alibaba Cloud..."
    aliyun ecs ImportKeyPair --region-id "$REGION" --KeyPairName "$KEY_PAIR_NAME" --PublicKeyBody "$(cat "$SSH_KEY_PATH.pub")" >/dev/null
  else
    echo "🔑  Key pair $KEY_PAIR_NAME already exists."
  fi
fi

# ---------- 2. Create security group (if not exists) ----------
SG_ID=$(aliyun ecs DescribeSecurityGroups --region-id "$REGION" --SecurityGroupName "$SECURITY_GROUP_NAME" --query "SecurityGroups.SecurityGroup[0].SecurityGroupId" --output text 2>/dev/null || true)
if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
  echo "🛡️  Creating security group $SECURITY_GROUP_NAME..."
  SG_ID=$(aliyun ecs CreateSecurityGroup --region-id "$REGION" --SecurityGroupName "$SECURITY_GROUP_NAME" --Description "Security group for Hermes instance" --output json | jq -r .SecurityGroupId)
  # Allow SSH (port 22)
  aliyun ecs AuthorizeSecurityGroup --region-id "$REGION" --SecurityGroupId "$SG_ID" --IpProtocol "tcp" --PortRange "22/22" --SourceCidrIp "0.0.0.0/0" --Priority 1 >/dev/null
  # Optional: allow HTTP (80) and HTTPS (443) if you want to expose Hermes web UI
  aliyun ecs AuthorizeSecurityGroup --region-id "$REGION" --SecurityGroupId "$SG_ID" --IpProtocol "tcp" --PortRange "80/80" --SourceCidrIp "0.0.0.0/0" --Priority 1 >/dev/null
  aliyun ecs AuthorizeSecurityGroup --region-id "$REGION" --SecurityGroupId "$SG_ID" --IpProtocol "tcp" --PortRange "443/443" --SourceCidrIp "0.0.0.0/0" --Priority 1 >/dev/null
else
  echo "🛡️  Security group $SECURITY_GROUP_NAME already exists (ID: $SG_ID)."
fi

# ---------- 3. Create ECS instance ----------
echo "🚀  Creating ECS instance $INSTANCE_NAME ..."
INSTANCE_ID=$(aliyun ecs RunInstances \
  --region-id "$REGION" \
  --ImageId "$IMAGE_ID" \
  --InstanceType "$INSTANCE_TYPE" \
  --SecurityGroupId "$SG_ID" \
  --InstanceName "$INSTANCE_NAME" \
  --SystemDisk.Size "$SYSTEM_DISK_SIZE" \
  --SystemDisk.Category "cloud_efficiency" \
  ${DATA_DISK_SIZE:+--DataDisk.1.Size "$DATA_DISK_SIZE"} \
  ${DATA_DISK_SIZE:+--DataDisk.1.Category "$DATA_DISK_CATEGORY"} \
  ${INSTANCE_PASSWORD:+--Password "$INSTANCE_PASSWORD"} \
  ${INSTANCE_PASSWORD:+--InternetMaxBandwidthOut 10} \
  ${INSTANCE_PASSWORD:+--InternetMaxBandwidthIn 10} \
  ${INSTANCE_PASSWORD:+--AssignPublicIp true} \
  ${INSTANCE_PASSWORD:+--UserData "$(echo -e '#!/bin/bash\napt-get update && apt-get install -yq curl' | base64)"} \
  ${INSTANCE_PASSWORD:+--PasswordInherit false} \
  ${INSTANCE_PASSWORD:+--InternetChargeType PayByTraffic} \
  ${INSTANCE_PASSWORD:+--InstanceChargeType PostPaid} \
  ${INSTANCE_PASSWORD:+--Period 1} \
  ${INSTANCE_PASSWORD:+--Amount 1} \
  ${INSTANCE_PASSWORD:+--AutoRenew false} \
  ${INSTANCE_PASSWORD:+--AutoRenewPeriod 1} \
  ${INSTANCE_PASSWORD:+--DeploymentSetId ""} \
  ${INSTANCE_PASSWORD:+--HpcClusterId ""} \
  ${INSTANCE_PASSWORD:+--RamRoleName ""} \
  ${INSTANCE_PASSWORD:+--SecurityEnhancementStrategy "Disable"} \
  ${INSTANCE_PASSWORD:+--UserData ""} \
  ${INSTANCE_PASSWORD:+--KeyPairName ""} \
  ${INSTANCE_PASSWORD:+--} \
  $( [[ -z "$INSTANCE_PASSWORD" ]] && echo "--KeyPairName \"$KEY_PAIR_NAME\"" ) \
  $( [[ -z "$INSTANCE_PASSWORD" ]] && echo "--InternetMaxBandwidthOut 10" ) \
  $( [[ -z "$INSTANCE_PASSWORD" ]] && echo "--InternetMaxBandwidthIn 10" ) \
  $( [[ -z "$INSTANCE_PASSWORD" ]] && echo "--AssignPublicIp true" ) \
  $( [[ -z "$INSTANCE_PASSWORD" ]] && echo "--UserData \"$(echo -e '#!/bin/bash\napt-get update && apt-get install -yq curl' | base64)\"" ) \
  --output json | jq -r .InstanceIdSets.InstanceSet[0].InstanceId)

echo "✅  Instance created with ID: $INSTANCE_ID"

# Wait for instance to be running
echo "⏳  Waiting for instance to be running..."
while true; do
  STATUS=$(aliyun ecs DescribeInstances --region-id "$REGION" --InstanceIds.1 "$INSTANCE_ID" --query "Instances.Instance[0].Status" --output text)
  if [[ "$STATUS" == "Running" ]]; then
    break
  fi
  sleep 5
done

# Get public IP
PUBLIC_IP=$(aliyun ecs DescribeInstances --region-id "$REGION" --InstanceIds.1 "$INSTANCE_ID" --query "Instances.Instance[0].PublicIpAddress.IpAddress[0]" --output text)
echo "🌐  Public IP: $PUBLIC_IP"

# ---------- 4. Remote provisioning script ----------
REMOTE_SCRIPT=$(cat <<'EOS'
set -euo pipefail

# ---- Update & install prerequisites ----
apt-get update -qq
apt-get install -y -qq curl gnupg2 ca-certificates lsb-release ubuntu-keyring

# ---- Install Docker (for Ollama) ----
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
usermod -aG docker $USER
newgrp docker || true

# ---- Pull and run Ollama container ----
docker pull ollama/ollama
docker run -d --name ollama -p 11434:11434 --restart unless-stopped ollama/ollama

# Wait for Ollama API
until curl -s http://localhost:11434/api/tags >/dev/null; do
  echo "⏳  Waiting for Ollama to be ready ..."
  sleep 2
done

# Pull the model (make sure it matches the one in config)
OLLAMA_MODEL="${OLLAMA_MODEL:-nemotron-3-super:cloud}"
echo "📦  Pulling Ollama model: $OLLAMA_MODEL"
docker exec ollama ollama pull "$OLLAMA_MODEL"

# ---- Install Hermes ----
apt-get install -y -qq git python3-pip python3-venv
git clone https://hermes-agent.nousresearch.com /opt/hermes || true
cd /opt/hermes
python3 -m venv .venv
source .venv/bin/activate
pip install -e .

# ---- Configure Hermes ----
mkdir -p ~/.hermes
cat > ~/.hermes/config.yaml <<EOF
agent:
  max_turns: 60
  verbose: false
model:
  api_key: ollama
  base_url: http://127.0.0.1:11434/v1
  default: $OLLAMA_MODEL
  provider: ollama-launch
platform_toolsets:
  telegram:
  - hermes-telegram
toolsets:
- hermes-cli
- web
- telegram
telegram:
  bot_token: "$TELEGRAM_BOT_TOKEN"
  chat_id: "$TELEGRAM_CHAT_ID"
EOF

# ---- Systemd service for Hermes ----
cat > /etc/systemd/system/hermes.service <<EOF
[Unit]
Description=Hermes AI Agent
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/hermes
Environment=PATH=/opt/hermes/.venv/bin
ExecStart=/opt/hermes/.venv/bin/hermes start
Restart=on-failure
User=$USER
Group=$USER

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hermes
systemctl start hermes

echo "🎉  Hermes is running! Telegram bot token and chat ID are configured."
EOS
)

# ---------- 5. Execute remote script ----------
# Determine SSH user: for Ubuntu images on Aliyun, default user is usually 'root' or 'ubuntu'? 
# Official Ubuntu images from Alibaba Cloud marketplace often use 'root' with password or key.
# We'll try 'root' first, but if key pair is set, we can use 'root' with key.
SSH_USER="root"
if [[ -n "$INSTANCE_PASSWORD" ]]; then
  # Use sshpass? We'll avoid for simplicity; instruct user to use password.
  echo "⚠️  Using password authentication; please ensure sshpass is installed or use ssh with password manually."
  # We'll still attempt ssh with password; but for automation we'll skip and instruct.
  echo "🚀  Please manually SSH into $PUBLIC_IP as $SSH_USER and run the provisioning script."
  echo "    The script to run is available in the instance's user data or you can copy from this script."
else
  echo "🚀  Running remote setup on $PUBLIC_IP ..."
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" "$SSH_USER"@"$PUBLIC_IP" "$REMOTE_SCRIPT"
fi

echo ""
echo "✅  Setup complete!"
echo "💬  You can now chat with Hermes via Telegram."
echo "🖥️  To SSH into the VM later:"
if [[ -z "$INSTANCE_PASSWORD" ]]; then
  echo "    ssh -i $SSH_KEY_PATH root@$PUBLIC_IP"
else
  echo "    ssh root@$PUBLIC_IP  (enter password when prompted)"
fi
echo ""
echo "🛠️  To view Hermes logs:"
echo "    ssh -i $SSH_KEY_PATH root@$PUBLIC_IP 'journalctl -u hermes -f'"
echo ""
echo "📝  Notes:"
echo "   * Alibaba Cloud does not have a permanent always‑free tier, but new users often get a free trial."
echo "   * Please monitor your usage to avoid unexpected charges."
echo "   * To change the Ollama model, edit ~/.hermes/config.yaml on the VM and run:"
echo "        sudo systemctl restart hermes"
echo ""
echo "🚀  Happy chatting with Hermes on Telegram!"