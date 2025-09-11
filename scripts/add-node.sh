#!/usr/bin/env bash
set -euo pipefail

# Required env vars:
: "${PANEL_URL:?need PANEL_URL}"
: "${PANEL_USERNAME:?need PANEL_USERNAME}"
: "${PANEL_PASSWORD:?need PANEL_PASSWORD}"
: "${NODE:?need NODE (ip or host)}"

# Optional env vars:
SSH_USER="${SSH_USER:-root}"
PANEL_VERIFY_TLS="${PANEL_VERIFY_TLS:-true}"   # set to "false" for self-signed panel TLS
SERVICE_PORT="${SERVICE_PORT:-62050}"
API_PORT="${API_PORT:-62051}"
ADD_AS_NEW_HOST="${ADD_AS_NEW_HOST:-true}"
USAGE_COEFF="${USAGE_COEFF:-1}"

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

# --- Helpers ---
_curl() {
  if [[ "$PANEL_VERIFY_TLS" == "false" ]]; then
    curl -fsS -k "$@"
  else
    curl -fsS "$@"
  fi
}

wait_for_ssh() {
  local host="$1" user="${2:-root}" tries=120
  echo "[wait] Waiting for SSH on ${user}@${host} ..."
  for i in $(seq 1 "$tries"); do
    if ssh $SSH_OPTS "${user}@${host}" 'true' 2>/dev/null; then
      echo "[wait] SSH is back."
      return 0
    fi
    sleep 2
  done
  echo "[wait] ERROR: SSH did not come back in time." >&2
  return 1
}

require_tool() {
  local bin="$1" hint="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: '$bin' not found. $hint" >&2
    exit 1
  fi
}

# --- Checks ---
require_tool jq "Install it: sudo apt-get update && sudo apt-get install -y jq"
require_tool ssh "Install OpenSSH client."
require_tool curl "Install curl."

# --- 1) Get admin token ---
echo "[1/5] Getting admin token from panel..."
TOKEN=$(_curl -X POST "$PANEL_URL/api/admin/token" \
  -d "username=$PANEL_USERNAME" -d "password=$PANEL_PASSWORD" -d "grant_type=password" \
  | jq -r .access_token)

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "ERROR: Failed to obtain access token. Check PANEL_URL/credentials." >&2
  exit 1
fi

# --- 2) Fetch node certificate from panel ---
echo "[2/5] Fetching node certificate from panel..."
CERT=$(_curl -H "Authorization: Bearer $TOKEN" "$PANEL_URL/api/node/settings" | jq -r .certificate)

if [[ -z "$CERT" || "$CERT" == "null" ]]; then
  echo "ERROR: Failed to fetch node certificate." >&2
  exit 1
fi

# --- 3) Remote: non-interactive system upgrade (with optional reboot) ---
echo "[3/5] Upgrading remote system (noninteractive) on ${SSH_USER}@${NODE} ..."
UPGRADE_STATUS=$(ssh $SSH_OPTS "${SSH_USER}@${NODE}" 'bash -s' <<'EOSH'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

# APT noninteractive defaults (keep old configs by default)
sudo install -m 0644 /dev/null /etc/apt/apt.conf.d/99noninteractive || true
sudo tee /etc/apt/apt.conf.d/99noninteractive >/dev/null <<'EOF'
APT::Get::Assume-Yes "true";
Dpkg::Options {
  "--force-confdef";
  "--force-confold";
}
Dpkg::Use-Pty "0";
EOF

# needrestart: auto-restart services
sudo mkdir -p /etc/needrestart/conf.d
sudo tee /etc/needrestart/conf.d/zzz-ansible.conf >/dev/null <<'EOF'
$nrconf{restart} = 'a';
EOF

# Upgrade
sudo apt-get -yq update
sudo apt-get -yq full-upgrade
sudo apt-get -yq autoremove --purge
sudo apt-get -yq autoclean

# Report reboot requirement without rebooting here (we'll handle it from the caller)
if [ -f /var/run/reboot-required ]; then
  echo REBOOT_REQUIRED
else
  echo NO_REBOOT
fi
EOSH
)

if [[ "$UPGRADE_STATUS" == *"REBOOT_REQUIRED"* ]]; then
  echo "[3/5] Reboot required. Rebooting ${NODE} ..."
  ssh $SSH_OPTS "${SSH_USER}@${NODE}" 'sudo reboot' || true
  sleep 5
  wait_for_ssh "$NODE" "$SSH_USER"
else
  echo "[3/5] No reboot required."
fi

# --- 4) Remote: install Docker (if not present), drop certificate, start node ---
echo "[4/5] Installing Docker (if needed) and starting marzban-node ..."
ssh $SSH_OPTS "${SSH_USER}@${NODE}" 'bash -s' <<'EOSH'
set -euo pipefail

# Install Docker if missing (convenience script)
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

sudo mkdir -p /var/lib/marzban-node
EOSH

# Copy certificate
ssh $SSH_OPTS "${SSH_USER}@${NODE}" "cat > /var/lib/marzban-node/ssl_client_cert.pem" <<<"$CERT"

# (Re)start container
ssh $SSH_OPTS "${SSH_USER}@${NODE}" 'bash -s' <<'EOSH'
set -euo pipefail
docker rm -f marzban-node >/dev/null 2>&1 || true
docker run -d --name marzban-node --restart always --network host \
  -v /var/lib/marzban-node:/var/lib/marzban-node \
  -e SSL_CLIENT_CERT_FILE=/var/lib/marzban-node/ssl_client_cert.pem \
  -e SERVICE_PROTOCOL=rest \
  gozargah/marzban-node:latest
EOSH

# --- 5) Register node in panel ---
echo "[5/5] Registering node in panel..."
_curl -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$PANEL_URL/api/node" \
  -d '{
    "name":"'"$NODE"'",
    "address":"'"$NODE"'",
    "port":'"$SERVICE_PORT"',
    "api_port":'"$API_PORT"',
    "add_as_new_host":'"$ADD_AS_NEW_HOST"',
    "usage_coefficient":'"$USAGE_COEFF"'
  }' | jq

echo "Done."
