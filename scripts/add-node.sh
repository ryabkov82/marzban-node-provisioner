#!/usr/bin/env bash
set -euo pipefail

# ========= Config via environment =========
: "${PANEL_URL:?need PANEL_URL}"
: "${PANEL_USERNAME:?need PANEL_USERNAME}"
: "${PANEL_PASSWORD:?need PANEL_PASSWORD}"
: "${NODE:?need NODE (ip or host)}"

SSH_USER="${SSH_USER:-root}"
PANEL_VERIFY_TLS="${PANEL_VERIFY_TLS:-true}"   # set to "false" for self-signed panel TLS
SERVICE_PORT="${SERVICE_PORT:-62050}"
API_PORT="${API_PORT:-62051}"
ADD_AS_NEW_HOST="${ADD_AS_NEW_HOST:-true}"
USAGE_COEFF="${USAGE_COEFF:-1}"

# Optional flags to control flow
SKIP_UPGRADE="${SKIP_UPGRADE:-false}"
SKIP_DOCKER="${SKIP_DOCKER:-false}"
SKIP_REGISTER="${SKIP_REGISTER:-false}"
SSH_KEY="${SSH_KEY:-}"   # path to private key (e.g., ~/.ssh/marzban_ci)
[[ "${DEBUG:-}" == "1" ]] && set -x

# SSH options
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"
if [[ -n "$SSH_KEY" ]]; then
  SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
fi

# ========= Helpers =========
_curl() {
  if [[ "$PANEL_VERIFY_TLS" == "false" ]]; then
    curl -fsS -k "$@"
  else
    curl -fsS "$@"
  fi
}

wait_for_ssh() {
  local host="$1" user="${2:-root}" tries="${3:-120}"
  echo "[wait] Waiting for SSH on ${user}@${host} ..."
  for ((i=1; i<=tries; i++)); do
    if ssh $SSH_OPTS "${user}@${host}" true 2>/dev/null; then
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

# ========= Checks =========
require_tool jq "Install it: sudo apt-get update && sudo apt-get install -y jq"
require_tool ssh "Install OpenSSH client."
require_tool curl "Install curl."

# ========= 1) Get admin token =========
echo "[1/5] Getting admin token from panel..."
TOKEN=$(_curl -X POST "$PANEL_URL/api/admin/token" \
  -d "username=$PANEL_USERNAME" -d "password=$PANEL_PASSWORD" -d "grant_type=password" \
  | jq -r .access_token)

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "ERROR: Failed to obtain access token. Check PANEL_URL/credentials." >&2
  exit 1
fi

# ========= 2) Fetch node certificate =========
echo "[2/5] Fetching node certificate from panel..."
CERT=$(_curl -H "Authorization: Bearer $TOKEN" "$PANEL_URL/api/node/settings" | jq -r .certificate)

if [[ -z "$CERT" || "$CERT" == "null" ]]; then
  echo "ERROR: Failed to fetch node certificate." >&2
  exit 1
fi

# ========= 3) Remote: system upgrade (optional) =========
if [[ "$SKIP_UPGRADE" != "true" ]]; then
  echo "[3/5] Upgrading remote system (noninteractive) on ${SSH_USER}@${NODE} ..."
  UPGRADE_STATUS=$(ssh $SSH_OPTS "${SSH_USER}@${NODE}" 'bash -s' <<'EOSH'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

# pick sudo only if not root
if [ "$(id -u)" -ne 0 ]; then SUDO=sudo; else SUDO=; fi

# APT noninteractive defaults (keep old configs by default)
$SUDO install -m 0644 /dev/null /etc/apt/apt.conf.d/99noninteractive || true
$SUDO tee /etc/apt/apt.conf.d/99noninteractive >/dev/null <<'EOF'
APT::Get::Assume-Yes "true";
Dpkg::Options {
  "--force-confdef";
  "--force-confold";
}
Dpkg::Use-Pty "0";
EOF

# needrestart: auto-restart services
$SUDO mkdir -p /etc/needrestart/conf.d
$SUDO tee /etc/needrestart/conf.d/zzz-ansible.conf >/dev/null <<'EOF'
$nrconf{restart} = 'a';
EOF

# Upgrade
$SUDO apt-get -yq update
$SUDO apt-get -yq full-upgrade
$SUDO apt-get -yq autoremove --purge
$SUDO apt-get -yq autoclean

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
    ssh $SSH_OPTS "${SSH_USER}@${NODE}" 'sudo reboot || reboot' || true
    sleep 5
    wait_for_ssh "$NODE" "$SSH_USER"
  else
    echo "[3/5] No reboot required."
  fi
else
  echo "[3/5] Skipped system upgrade (SKIP_UPGRADE=true)"
fi

# ========= 4) Remote: Docker & container (optional) =========
if [[ "$SKIP_DOCKER" != "true" ]]; then
  echo "[4/5] Installing Docker (if needed), writing cert, starting marzban-node ..."
  ssh $SSH_OPTS "${SSH_USER}@${NODE}" 'bash -s' <<'EOSH'
set -euo pipefail

# pick sudo only if not root
if [ "$(id -u)" -ne 0 ]; then SUDO=sudo; else SUDO=; fi

# Install Docker if missing (convenience script)
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | $SUDO sh
fi

$SUDO mkdir -p /var/lib/marzban-node
EOSH

  # Copy certificate
  ssh $SSH_OPTS "${SSH_USER}@${NODE}" "cat | sudo tee /var/lib/marzban-node/ssl_client_cert.pem >/dev/null" <<<"$CERT"

  # (Re)start container
  ssh $SSH_OPTS "${SSH_USER}@${NODE}" 'bash -s' <<'EOSH'
set -euo pipefail
# if not root, add current user to docker group for next sessions (no effect in current session)
if [ "$(id -u)" -ne 0 ]; then SUDO=sudo; else SUDO=; fi
$SUDO docker rm -f marzban-node >/dev/null 2>&1 || true
$SUDO docker run -d --name marzban-node --restart always --network host \
  -v /var/lib/marzban-node:/var/lib/marzban-node \
  -e SSL_CLIENT_CERT_FILE=/var/lib/marzban-node/ssl_client_cert.pem \
  -e SERVICE_PROTOCOL=rest \
  gozargah/marzban-node:latest
EOSH
else
  echo "[4/5] Skipped Docker/cert/container (SKIP_DOCKER=true)"
fi

# ========= 5) Register node in panel (optional) =========
if [[ "$SKIP_REGISTER" != "true" ]]; then
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
else
  echo "[5/5] Skipped node registration (SKIP_REGISTER=true)"
fi

echo "Done."
