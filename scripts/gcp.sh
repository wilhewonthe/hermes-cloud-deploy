#!/usr/bin/env bash
# =============================================================================
# Deploy Hermes on Google Cloud Platform (using always-free f1-micro or e2-small)
# Prerequisites:
#   - gcloud CLI installed and authenticated (gcloud auth login)
#   - A project set (gcloud config set project PROJECT_ID)
#   - Telegram bot token & chat ID ready
# =============================================================================

set -euo pipefail

# -------------------------- USER SETTINGS --------------------------
# 1. Google Cloud project ID (must be set)
PROJECT_ID="${PROJECT_ID:-}"  # e.g. my-hermes-project

# 2. Telegram credentials (mandatory)
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# 3. VM configuration
#    For always free: f1-micro (0.2 vCPU, 0.6 GB RAM) OR e2-small (2 vCPU, 2 GB RAM) 
#    but note: e2-small is not always free; only f1-micro is always free.
#    However, we can use the free trial credits to get a slightly bigger VM for a limited time.
#    We'll let the user choose via VM_TIER: "always-free" (f1-micro) or "trial" (e2-medium).
VM_TIER="${VM_TIER:-always-free}"   # options: always-free, trial
ZONE="${ZONE:-us-central1-a}"
# If always-free:
if [[ "$VM_TIER" == "always-free" ]]; then
  MACHINE_TYPE="${MACHINE_TYPE:-f1-micro}"
else
  # trial: use e2-medium (2 vCPU, 4 GB RAM) as a decent balance
  MACHINE_TYPE="${MACHINE_TYPE:-e2-medium}"
fi
IMAGE_FAMILY="${IMAGE_FAMILY:-debian-11}"
IMAGE_PROJECT="${IMAGE_PROJECT:-debian-cloud}"
INSTANCE_NAME="${INSTANCE_NAME:-hermes-vm}"
# SSH key (will use existing or generate)
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"

# 4. Ollama model to pull
OLLAMA_MODEL="${OLLAMA_MODEL:-nemotron-3-super:cloud}"
# ------------------------------------------------------------------

# ---------- Helper: abort if mandatory vars missing ----------
if [[ -z "$PROJECT_ID" ]]; then
  echo "❌  Please set PROJECT_ID (your Google Cloud project ID) before running."
  exit 1
fi
if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
  echo "❌  Please set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID before running."
  exit 1
fi

# Ensure project is set
gcloud config set project "$PROJECT_ID"

# ---------- 1. Ensure we have an SSH key ----------
if [[ ! -f "$SSH_KEY_PATH.pub" ]]; then
  echo "🔐  Generating a new SSH key pair (no passphrase)…"
  mkdir -p "$(dirname "$SSH_KEY_PATH")"
  ssh-keygen -t rsa -b 2048 -f "$SSH_KEY_PATH" -N "" >/dev/null
fi
SSH_PUBLIC_KEY=$(cat "$SSH_KEY_PATH.pub")

# ---------- 2. Create VM (if not exists) ----------
echo "🚀  Creating/fetching VM $INSTANCE_NAME in zone $ZONE ..."
if ! gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null; then
  echo "   Creating new instance..."
  gcloud compute instances create "$INSTANCE_NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --boot-disk-size=10GB \
    --tags=http-server,https-server \
    --ssh-key-file="$SSH_KEY_PATH.pub" \
    --no-address   # we will add a static IP later? Actually we need external IP to connect.
    # We'll add an external IP via --address
    --address
else
  echo "   Instance $INSTANCE_NAME already exists."
fi

# Get the external IP
EXTERNAL_IP=$(gcloud compute instances describe "$INSTANCE_NAME" \
  --zone="$ZONE" \
  --project="$PROJECT_ID" \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)')

echo "✅  VM ready at $EXTERNAL_IP"

# ---------- 3. Remote provisioning script ----------
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

# ---------- 4. Execute remote script ----------
echo "🚀  Running remote setup on $EXTERNAL_IP ..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" "$USER"@"$EXTERNAL_IP" "$REMOTE_SCRIPT"

echo ""
echo "✅  Setup complete!"
echo "💬  You can now chat with Hermes via Telegram."
echo "🖥️  To SSH into the VM later:"
echo "    gcloud compute ssh $INSTANCE_NAME --zone=$ZONE --project=$PROJECT_ID"
echo ""
echo "🛠️  To view Hermes logs:"
echo "    gcloud compute ssh $INSTANCE_NAME --zone=$ZONE --project=$PROJECT_ID -- 'sudo journalctl -u hermes -f'"
echo ""
echo "📝  Notes:"
echo "   * If you chose 'always-free' (f1-micro), the VM is always free but limited to 0.2 vCPU and 0.6 GB RAM."
echo "   * If you chose 'trial' (e2-medium), you are using free trial credits; monitor usage to avoid charges."
echo "   * To change the Ollama model, edit ~/.hermes/config.yaml on the VM and run:"
echo "        sudo systemctl restart hermes"
echo ""
echo "🚀  Happy chatting with Hermes on Telegram!"