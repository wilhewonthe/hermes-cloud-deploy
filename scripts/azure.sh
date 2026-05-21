#!/usr/bin/env bash
# =============================================================================
# Deploy Hermes on Azure (using always-free B1S VM for 12 months)
# Prerequisites:
#   - Azure CLI installed and logged in (az login)
#   - Telegram bot token & chat ID ready
# =============================================================================

set -euo pipefail

# -------------------------- USER SETTINGS --------------------------
# 1. Azure subscription (if not set as default)
#    You can leave empty if you have a default subscription configured.
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"

# 2. Telegram credentials (mandatory)
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# 3. VM configuration
RESOURCE_GROUP="${RESOURCE_GROUP:-hermes-rg}"
LOCATION="${LOCATION:-eastus}"        # choose a region that offers B1S
VM_NAME="${VM_NAME:-hermes-vm}"
# B1S: 1 vCPU, 1 GiB RAM (always free for 12 months)
VM_SIZE="${VM_SIZE:-Standard_B1s}"
IMAGE="${IMAGE:-Canonical:UbuntuServer:22_04-lts-gen2:latest}"
# SSH key (will use existing or generate)
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"

# 4. Ollama model to pull
OLLAMA_MODEL="${OLLAMA_MODEL:-nemotron-3-super:cloud}"
# ------------------------------------------------------------------

# ---------- Helper: abort if mandatory vars missing ----------
if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
  echo "❌  Please set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID before running."
  exit 1
fi

# If subscription not set, try to get current
if [[ -z "$AZURE_SUBSCRIPTION_ID" ]]; then
  AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
  if [[ -z "$AZURE_SUBSCRIPTION_ID" ]]; then
    echo "❌  No Azure subscription set. Please run 'az account set --subscription <ID>' or set AZURE_SUBSCRIPTION_ID."
    exit 1
  fi
fi
az account set --subscription "$AZURE_SUBSCRIPTION_ID"

# ---------- 1. Ensure we have an SSH key ----------
if [[ ! -f "$SSH_KEY_PATH.pub" ]]; then
  echo "🔐  Generating a new SSH key pair (no passphrase)…"
  mkdir -p "$(dirname "$SSH_KEY_PATH")"
  ssh-keygen -t rsa -b 2048 -f "$SSH_KEY_PATH" -N "" >/dev/null
fi
SSH_PUBLIC_KEY=$(cat "$SSH_KEY_PATH.pub")

# ---------- 2. Create resource group ----------
echo "🛠️  Creating resource group $RESOURCE_GROUP in $LOCATION ..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" >/dev/null

# ---------- 3. Create VM ----------
echo "🚀  Creating VM $VM_NAME ..."
az vm create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --image "$IMAGE" \
  --size "$VM_SIZE" \
  --admin-username azureuser \
  --ssh-key-values "$SSH_PUBLIC_KEY" \
  --public-ip-sku Standard \
  --nsg-rule SSH \
  --custom-data cloud-init.txt \
  --no-wait >/dev/null

# Wait for VM to be ready (we'll poll)
echo "⏳  Waiting for VM to be provisioned..."
while true; do
  PROVISIONING_STATE=$(az vm get-instance-view \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --query "instanceView.statuses[?code=='ProvisioningState/running']"). 
  if [[ -n "$PROVISIONING_STATE" ]]; then
    break
  fi
  sleep 5
done

# Get public IP
PUBLIC_IP=$(az network public-ip show \
  --resource-group "$RESOURCE_GROUP" \
  --name "${VM_NAME}PublicIP" \
  --query ipAddress -o tsv)

echo "✅  VM ready at $PUBLIC_IP"

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
echo "🚀  Running remote setup on $PUBLIC_IP ..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" azureuser@"$PUBLIC_IP" "$REMOTE_SCRIPT"

echo ""
echo "✅  Setup complete!"
echo "💬  You can now chat with Hermes via Telegram."
echo "🖥️  To SSH into the VM later:"
echo "    ssh -i $SSH_KEY_PATH azureuser@$PUBLIC_IP"
echo ""
echo "🛠️  To view Hermes logs:"
echo "    ssh -i $SSH_KEY_PATH azureuser@$PUBLIC_IP 'journalctl -u hermes -f'"
echo ""
echo "📝  Notes:"
echo "   * This uses the B1S (Standard_B1s) VM size which is free for 12 months with Azure free account."
echo "   * After 12 months, you may be charged unless you stop/deallocate the VM."
echo "   * To change the Ollama model, edit ~/.hermes/config.yaml on the VM and run:"
echo "        sudo systemctl restart hermes"
echo ""
echo "🚀  Happy chatting with Hermes on Telegram!"