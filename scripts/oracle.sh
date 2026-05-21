#!/usr/bin/env bash
# =============================================================================
# Deploy Hermes on Oracle Cloud Always Free (maximizes free resources)
# Prerequisites:
#   - OCI CLI installed & configured (oci setup config)
#   - Telegram bot token & chat ID ready
#   - (Optional) existing SSH public key at ~/.ssh/id_rsa.pub
# =============================================================================

set -euo pipefail

# -------------------------- USER SETTINGS --------------------------
# 1. Oracle Cloud tenancy / user details (if not already in ~/.oci/config)
#    You can leave these blank if you have already run `oci setup config`.
TENANCY_OCID="${TENANCY_OCID:-}"          # e.g. ocid1.tenancy.oc1..xxxxxx
USER_OCID="${USER_OCID:-}"                 # e.g. ocid1.user.oc1..xxxxxx
FINGERPRINT="${FINGERPRINT:-}"             # e.g. 12:34:56:78:90:ab:cd:ef:12:34:56:78:90:ab:cd:ef
PRIVATE_KEY_PATH="${PRIVATE_KEY_PATH:-}"   # Full path to your API key PEM file
REGION="${REGION:-}"                       # e.g. us-ashburn-1

# 2. Telegram credentials (mandatory)
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"    # from @BotFather
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"        # numeric ID (can be negative for groups/channels)

# 3. VM shape & image
#    Choose AMD (VM.Standard.E2.Flex) = 2 vCPU, up to 24 GB RAM (always free)
#    or ARM (VM.Standard.A1.Flex) = 4 vCPU, up to 24 GB RAM (always free)
SHAPE="${SHAPE:-VM.Standard.E2.Flex}"   # AMD flexible shape
# If you prefer ARM, uncomment the next line and comment the AMD line:
# SHAPE="VM.Standard.A1.Flex"   # ARM flexible shape

# Number of vCPUs and amount of memory (in GB) for the flex shape.
# Must comply with Always Free limits: total <= 2 vCPU (AMD) or <= 4 vCPU (ARM)
# and memory <= 24 GB.
VCPU_COUNT="${VCPU_COUNT:-2}"
MEMORY_IN_GBS="${MEMORY_IN_GBS:-24}"

# 4. Ollama model to pull (you can change this later)
OLLAMA_MODEL="${OLLAMA_MODEL:-nemotron-3-super:cloud}"
# ------------------------------------------------------------------

# ---------- Helper: abort if mandatory vars missing ----------
if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
  echo "❌  Please set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID before running."
  exit 1
fi

# If OCI config not present, ask for the missing bits
if [[ ! -f ~/.oci/config ]]; then
  echo "⚙️  OCI config not found – please provide the missing details."
  [[ -z "$TENANCY_OCID"     ]] && read -p "Tenancy OCID:               " TENANCY_OCID
  [[ -z "$USER_OCID"        ]] && read -p "User OCID:                  " USER_OCID
  [[ -z "$FINGERPRINT"      ]] && read -p "API key fingerprint:        " FINGERPRINT
  [[ -z "$PRIVATE_KEY_PATH" ]] && read -p "Path to private key PEM:    " PRIVATE_KEY_PATH
  [[ -z "$REGION"           ]] && read -p "Region (e.g. us-ashburn-1): " REGION

  # Write a minimal config
  mkdir -p ~/.oci
  cat > ~/.oci/config <<EOF
[DEFAULT]
user=$USER_OCID
fingerprint=$FINGERPRINT
key_file=$PRIVATE_KEY_PATH
tenancy=$TENANCY_OCID
region=$REGION
EOF
  chmod 600 ~/.oci/config
fi

# ---------- 1. Ensure we have an SSH key ----------
SSH_KEY_PATH="${HOME}/.ssh/id_rsa"
if [[ ! -f "$SSH_KEY_PATH.pub" ]]; then
  echo "🔐  Generating a new SSH key pair (no passphrase)…"
  ssh-keygen -t rsa -b 2048 -f "$SSH_KEY_PATH" -N "" >/dev/null
fi
SSH_PUBLIC_KEY=$(cat "$SSH_KEY_PATH.pub")

# ---------- 2. Pick a free‑tier compatible shape ----------
# Oracle's Always Free compute shapes:
#   AMD: VM.Standard.E2.Flex (max 2 vCPU, up to 24 GB RAM)
#   ARM: VM.Standard.A1.Flex (max 4 vCPU, up to 24 GB RAM)
# We'll enforce the limits.
if [[ "$SHAPE" == "VM.Standard.E2.Flex" ]]; then
  if (( VCPU_COUNT > 2 )); then
    echo "⚠️  AMD free tier allows at most 2 vCPU; setting to 2."
    VCPU_COUNT=2
  fi
  if (( MEMORY_IN_GBS > 24 )); then
    echo "⚠️  AMD free tier allows at most 24 GB RAM; setting to 24."
    MEMORY_IN_GBS=24
  fi
elif [[ "$SHAPE" == "VM.Standard.A1.Flex" ]]; then
  if (( VCPU_COUNT > 4 )); then
    echo "⚠️  ARM free tier allows at most 4 vCPU; setting to 4."
    VCPU_COUNT=4
  fi
  if (( MEMORY_IN_GBS > 24 )); then
    echo "⚠️  ARM free tier allows at most 24 GB RAM; setting to 24."
    MEMORY_IN_GBS=24
  fi
else
  echo "❌  Unsupported shape. Use VM.Standard.E2.Flex (AMD) or VM.Standard.A1.Flex (ARM)."
  exit 1
fi

INSTANCE_NAME="hermes-free-${SHAPE,,}"
# Remove dots from shape for a valid hostname
INSTANCE_NAME="${INSTANCE_NAME//./-}"

echo "🚀  Creating/fetching VM $INSTANCE_NAME ..."
if ! oci compute instance get --instance-id "$(oci compute instance list \
      --compartment-id "$(oci iam compartment list \
          --compartment-id-in-subtree true \
          --access-level ANY \
          --query "data[?name=='${TENANCY_OCID//ocid1.tenancy.oc1.:}'']/id | [0]" \
          --raw-output) \
      --display-name "$INSTANCE_NAME" \
      --lifecycle-state RUNNING \
      --query "data[0].id" \
      --raw-output 2>/dev/null || true)" &>/dev/null; then
  echo "   Creating new instance..."
  oci compute instance launch \
    --availability-domain "$(oci iam availability-domain list --compartment-id "$TENANCY_OCID" --query "data[0].name" --raw-output)" \
    --shape "$SHAPE" \
    --display-name "$INSTANCE_NAME" \
    --compartment-id "$TENANCY_OCID" \
    --image-id "$(oci compute image list \
        --compartment-id "$TENANCY_OCID" \
        --image-family "Canonical Ubuntu Server Release" \
        --operating-system "Ubuntu" \
        --operating-system-version "22.04 LTS" \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --limit 1 \
        --query "data[0].id" \
        --raw-output)" \
    --shape-config "{\"memoryInGBs\":$MEMORY_IN_GBS,\"ocpus\":$VCPU_COUNT}" \
    --ssh-authorized-keys-file "$SSH_KEY_PATH.pub" \
    --assign-public-ip true \
    --wait-for-state RUNNING \
    >/dev/null
else
  echo "   Instance $INSTANCE_NAME already exists."
fi

# Grab the instance's public IP
INSTANCE_ID=$(oci compute instance list \
    --compartment-id "$TENANCY_OCID" \
    --display-name "$INSTANCE_NAME" \
    --lifecycle-state RUNNING \
    --query "data[0].id" \
    --raw-output)
PUBLIC_IP=$(oci compute instance get --instance-id "$INSTANCE_ID" \
    --query "data.\"public-ip-address\"" \
    --raw-output)

echo "✅  VM ready at $PUBLIC_IP"

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
newgrp docker || true   # if it fails, continue; user may need to relogin

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
echo "🚀  Running remote setup on $PUBLIC_IP ..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" ubuntu@"$PUBLIC_IP" "$REMOTE_SCRIPT"

echo ""
echo "✅  Setup complete!"
echo "💬  You can now chat with Hermes via Telegram."
echo "🖥️  To SSH into the VM later:"
echo "    ssh -i $SSH_KEY_PATH ubuntu@$PUBLIC_IP"
echo ""
echo "🛠️  To view Hermes logs:"
echo "    ssh -i $SSH_KEY_PATH ubuntu@$PUBLIC_IP 'journalctl -u hermes -f'"
echo ""
echo "📝  Notes:"
echo "   * The VM is always‑free as long as you stay within the shape limits."
echo "   * If you ever need more RAM/VCPU (still within free tier), edit the shape‑config"
echo "     in the script and relaunch the instance."
echo "   * To change the Ollama model, edit ~/.hermes/config.yaml on the VM and run:"
echo "        sudo systemctl restart hermes"
echo ""
echo "🚀  Happy chatting with Hermes on Telegram!"