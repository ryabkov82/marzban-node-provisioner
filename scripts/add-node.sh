#!/usr/bin/env bash
set -euo pipefail

# ========= Config via environment =========
: "${PANEL_URL:?need PANEL_URL}"
: "${PANEL_USERNAME:?need PANEL_USERNAME}"
: "${PANEL_PASSWORD:?need PANEL_PASSWORD}"
: "${SSH_TARGET:?need SSH_TARGET (ssh alias or user@host)}"

# Optional
NODE_ADDRESS="${NODE_ADDRESS:-}"             # address for panel (IP/DNS); auto-detected if empty
PANEL_VERIFY_TLS="${PANEL_VERIFY_TLS:-true}" # set to "false" for self-signed panel TLS
SERVICE_PORT="${SERVICE_PORT:-62050}"
API_PORT="${API_PORT:-62051}"
ADD_AS_NEW_HOST="${ADD_AS_NEW_HOST:-true}"
USAGE_COEFF="${USAGE_COEFF:-1}"
SSH_KEY="${SSH_KEY:-}"                        # overrides IdentityFile from ssh config if set

# Flow switches
SKIP_UPGRADE="${SKIP_UPGRADE:-false}"
SKIP_DOCKER="${SKIP_DOCKER:-false}"
SKIP_REGISTER="${SKIP_REGISTER:-false}"
[[ "${DEBUG:-}" == "1" ]] && set -x

# SSH options (respect ~/.ssh/config)
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
[[ -n "$SSH_KEY" ]] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"

# ========= Helpers =========
_curl() { if [[ "$PANEL_VERIFY_TLS" == "false" ]]; then curl -fsS -k "$@"; else curl -fsS "$@"; fi; }

wait_for_ssh() {
  local target="$1" tries="${2:-120}"
  echo "[wait] Waiting for SSH on ${target} ..."
  for ((i=1; i<=tries; i++)); do
    if ssh $SSH_OPTS "$target" true 2>/dev/null; then
      echo "[wait] SSH is back."; return 0
    fi
    sleep 2
  done
  echo "[wait] ERROR: SSH did not come back in time." >&2
  return 1
}

# --- Copy wildcard TLS cert from cert-master to target without rsync ----------
# Требуемые переменные окружения:
#   CERT_DOMAIN      (обязательно)  пример: digitalstreamers.xyz
#   CERT_MASTER      (обязательно)  SSH-алиас/hostname cert-master
#   NODE или CERT_TARGET_HOST       адрес целевого узла
# Необязательные:
#   CERT_MASTER_USER (default: root) пользователь на cert-master
#   SSH_USER         (default: root) пользователь на target
#   CERT_MASTER_SSH_KEY             ключ для SSH на cert-master (с вашей машины)
#   SSH_OPTS                         опции SSH на target (ключ, StrictHostKeyChecking и т.п.)
#   CERT_DEST_DIR    (default: /etc/letsencrypt/live/<domain>)
#   RELOAD_SERVICES  (default: "nginx haproxy")
sync_tls_cert_via_master() {
  set -u

  local domain="${CERT_DOMAIN:-}"
  local master="${CERT_MASTER:-}"
  local target_host="${CERT_TARGET_HOST:-${SSH_TARGET##*@}}"
  local master_user="${CERT_MASTER_USER:-root}"
  local target_user="${SSH_USER:-root}"

  if [[ -z "$domain" || -z "$master" || -z "$target_host" ]]; then
    echo "[cert] Skip: set CERT_DOMAIN, CERT_MASTER and SSH_TARGET (or CERT_TARGET_HOST)" >&2
    return 10
  fi

  local live_dir="/etc/letsencrypt/live/${domain}"
  local dest_dir="${CERT_DEST_DIR:-$live_dir}"

  # SSH на cert-master (с вашей машины)
  local MASTER_SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new"
  [[ -n "${CERT_MASTER_SSH_KEY:-}" ]] && MASTER_SSH_OPTS+=" -i ${CERT_MASTER_SSH_KEY}"

  echo "[cert] Stream-copy '${domain}' from ${master_user}@${master}:${live_dir} -> ${target_user}@${target_host}:${dest_dir} (no rsync, dereference)"

  # 0) Проверяем доступность master и target
  ssh ${MASTER_SSH_OPTS} "${master_user}@${master}" 'true' || { echo "[cert] ERROR: cannot SSH to cert-master ${master}" >&2; return 1; }
  ssh ${SSH_OPTS:-}       "${target_user}@${target_host}" 'true' || { echo "[cert] ERROR: cannot SSH to target ${target_host}" >&2; return 1; }

  # 1) Проверим наличие файлов на мастере
  ssh ${MASTER_SSH_OPTS} "${master_user}@${master}" \
    "test -r '${live_dir}/fullchain.pem' -a -r '${live_dir}/privkey.pem'" || {
      echo "[cert] ERROR: '${live_dir}/(fullchain.pem|privkey.pem)' not found on cert-master" >&2
      return 2
  }

  # 2) Подготовим каталог на target и уберём возможные старые (в т.ч. линкованные) файлы
  ssh ${SSH_OPTS:-} "${target_user}@${target_host}" \
    "mkdir -p '${dest_dir}' && rm -f '${dest_dir}/fullchain.pem' '${dest_dir}/privkey.pem'" || {
      echo "[cert] ERROR: cannot prepare ${dest_dir} on target" >&2
      return 3
  }

  # 3) Передача: на мастере TАР с ДЕРЕФЕРЕНСОМ (-h) → по SSH → распаковка на target
  ssh ${MASTER_SSH_OPTS} "${master_user}@${master}" \
    "tar -h -C '${live_dir}' -cf - fullchain.pem privkey.pem" \
    | ssh ${SSH_OPTS:-} "${target_user}@${target_host}" \
        "tar -C '${dest_dir}' -xpf - && chown root:root '${dest_dir}/fullchain.pem' '${dest_dir}/privkey.pem' && chmod 644 '${dest_dir}/fullchain.pem' && chmod 600 '${dest_dir}/privkey.pem'" \
    || { echo '[cert] ERROR: streaming copy failed' >&2; return 4; }

  # 4) Мягко перезагрузим сервисы, если развёрнуты
  local services="${RELOAD_SERVICES:-nginx haproxy}"
  for srv in ${services}; do
    ssh ${SSH_OPTS:-} "${target_user}@${target_host}" \
      "systemctl is-active --quiet ${srv} && systemctl reload ${srv} || true" || true
  done

  # 5) Короткая информация о сертификате на target
  ssh ${SSH_OPTS:-} "${target_user}@${target_host}" \
    "command -v openssl >/dev/null && openssl x509 -in '${dest_dir}/fullchain.pem' -noout -subject -issuer -dates | sed -n '1,3p' || true" || true

  echo "[cert] Done: certificate streamed successfully."
  return 0
}

# --- Soft/Hard check of TLS cert on remote host ------------------------------
verify_remote_tls_cert() {
  # Требуется: SSH_OPTS, CERT_DOMAIN; host берём из CERT_TARGET_HOST или SSH_TARGET (отрежем user@), fallback к NODE
  local user="${SSH_USER:-root}"
  local domain="${CERT_DOMAIN:?CERT_DOMAIN is required}"

  local host="${CERT_TARGET_HOST:-}"
  [[ -z "$host" && -n "${SSH_TARGET:-}" ]] && host="${SSH_TARGET##*@}"
  [[ -z "$host" && -n "${NODE:-}"       ]] && host="${NODE}"
  if [[ -z "$host" ]]; then
    echo "[cert] ERROR: set CERT_TARGET_HOST or SSH_TARGET or NODE" >&2
    return 1
  fi

  local cert_path="${NGINX_SSL_CERT:-/etc/letsencrypt/live/${domain}/fullchain.pem}"

  echo "[cert] Verifying TLS certificate at ${user}@${host}:${cert_path}"

  ssh ${SSH_OPTS:-} "${user}@${host}" "command -v openssl >/dev/null || (apt-get update -y && apt-get install -y openssl)" || {
    echo "[cert] ERROR: cannot ensure openssl on target" >&2
    return 2
  }

  # Мягкая проверка: subject/issuer/dates
  ssh ${SSH_OPTS:-} "${user}@${host}" \
    "openssl x509 -in '${cert_path}' -noout -subject -issuer -dates" || {
      echo "[cert] WARNING: cannot read certificate at ${cert_path}" >&2
      return 0
    }

  # Жёсткая (опциональная) проверка домена
  if [[ "${STRICT_CERT_CHECK:-false}" == "true" ]]; then
    local base="${domain#*.}"
    ssh ${SSH_OPTS:-} "${user}@${host}" \
      "openssl x509 -in '${cert_path}' -noout -subject -ext subjectAltName" | \
      awk 'BEGIN{ok=0}
           /subject=/{sub(\".*CN=\",\"\"); cn=$0}
           /DNS:/{ if (index($0,\"DNS:'"$domain"'\")||index($0,\"DNS:*.'"$base"'\"))
                     ok=1 }
           END{ if (ok==1 || cn ~ /('"$domain"'|\*.'"$base"')/) exit 0; else exit 1 }'
    if [[ $? -ne 0 ]]; then
      echo "[cert] ERROR: certificate CN/SAN does not match '"$domain"'" >&2
      return 3
    fi
  fi

  echo "[cert] Certificate check passed."
  return 0
}

require_tool() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found. $2" >&2; exit 1; }; }
require_tool jq "Install it: sudo apt-get update && sudo apt-get install -y jq"
require_tool ssh "Install OpenSSH client."
require_tool curl "Install curl."

# ========= 1) Get admin token =========
echo "[1/5] Getting admin token from panel..."
TOKEN=$(_curl -X POST "$PANEL_URL/api/admin/token" \
  -d "username=$PANEL_USERNAME" -d "password=$PANEL_PASSWORD" -d "grant_type=password" \
  | jq -r .access_token)
[[ -n "$TOKEN" && "$TOKEN" != "null" ]]

# ========= 2) Fetch node certificate =========
echo "[2/5] Fetching node certificate from panel..."
CERT=$(_curl -H "Authorization: Bearer $TOKEN" "$PANEL_URL/api/node/settings" | jq -r .certificate)
[[ -n "$CERT" && "$CERT" != "null" ]]

# ========= 3) Remote: system upgrade (optional) =========
if [[ "$SKIP_UPGRADE" != "true" ]]; then
  echo "[3/5] Upgrading remote system (noninteractive) on ${SSH_TARGET} ..."
  UPGRADE_STATUS=$(ssh $SSH_OPTS "$SSH_TARGET" 'bash -s' <<'EOSH'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
if [ "$(id -u)" -ne 0 ]; then SUDO=sudo; else SUDO=; fi
$SUDO install -m 0644 /dev/null /etc/apt/apt.conf.d/99noninteractive || true
$SUDO tee /etc/apt/apt.conf.d/99noninteractive >/dev/null <<'EOF'
APT::Get::Assume-Yes "true";
Dpkg::Options { "--force-confdef"; "--force-confold"; }
Dpkg::Use-Pty "0";
EOF
$SUDO mkdir -p /etc/needrestart/conf.d
$SUDO tee /etc/needrestart/conf.d/zzz-ansible.conf >/dev/null <<'EOF'
$nrconf{restart} = 'a';
EOF
$SUDO apt-get -yq update
$SUDO apt-get -yq full-upgrade
$SUDO apt-get -yq autoremove --purge
$SUDO apt-get -yq autoclean
if [ -f /var/run/reboot-required ]; then echo REBOOT_REQUIRED; else echo NO_REBOOT; fi
EOSH
)
  if [[ "$UPGRADE_STATUS" == *"REBOOT_REQUIRED"* ]]; then
    echo "[3/5] Reboot required. Rebooting ${SSH_TARGET} ..."
    ssh $SSH_OPTS "$SSH_TARGET" 'sudo reboot || reboot' || true
    sleep 5
    wait_for_ssh "$SSH_TARGET"
  else
    echo "[3/5] No reboot required."
  fi
else
  echo "[3/5] Skipped system upgrade (SKIP_UPGRADE=true)"
fi

# ───── derive CERT_TARGET_HOST from SSH_TARGET if not set ─────
# из "user@host" берём только host; это нужно нашей функции
export CERT_TARGET_HOST="${CERT_TARGET_HOST:-${SSH_TARGET##*@}}"

# ========= 3.5) TLS: sync wildcard cert from cert-master (optional) =========
if [[ "${CERT_SYNC_ENABLE:-false}" == "true" ]]; then
  echo "[3.5/5] Sync TLS cert from cert-master (no rsync) ..."
  sync_tls_cert_via_master || echo "[cert] WARNING: sync failed (continuing)"
  if [[ "${CERT_VERIFY:-true}" == "true" ]]; then
    echo "[3.5/5] Verify TLS cert on target ..."
    verify_remote_tls_cert || echo "[cert] WARNING: verification reported an issue"
  fi
else
  echo "[3.5/5] Skipped TLS cert sync (CERT_SYNC_ENABLE!=true)"
fi

# ========= 4) Remote: Docker & container (optional) =========
if [[ "$SKIP_DOCKER" != "true" ]]; then
  echo "[4/5] Installing Docker (if needed), writing cert, starting marzban-node ..."
  ssh $SSH_OPTS "$SSH_TARGET" 'bash -s' <<'EOSH'
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then SUDO=sudo; else SUDO=; fi
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | $SUDO sh
fi
$SUDO mkdir -p /var/lib/marzban-node
EOSH
# Copy certificate
echo "$CERT" | ssh $SSH_OPTS "$SSH_TARGET" "sudo tee /var/lib/marzban-node/ssl_client_cert.pem >/dev/null"
# (Re)start container
ssh $SSH_OPTS "$SSH_TARGET" 'bash -s' <<'EOSH'
set -euo pipefail
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
  # Determine address for panel: NODE_ADDRESS > ssh HostName > SSH_TARGET w/o user@
  HOST_ONLY="${SSH_TARGET##*@}"
  RESOLVED_HOST=$(ssh -G "$SSH_TARGET" 2>/dev/null | awk '/^hostname /{print $2; exit}')
  ADDRESS="${NODE_ADDRESS:-${RESOLVED_HOST:-$HOST_ONLY}}"

  echo "[5/5] Registering node in panel as address=${ADDRESS} ..."
  _curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -X POST "$PANEL_URL/api/node" \
    -d '{
      "name":"'"$ADDRESS"'",
      "address":"'"$ADDRESS"'",
      "port":'"$SERVICE_PORT"',
      "api_port":'"$API_PORT"',
      "add_as_new_host":'"$ADD_AS_NEW_HOST"',
      "usage_coefficient":'"$USAGE_COEFF"'
    }' | jq
else
  echo "[5/5] Skipped node registration (SKIP_REGISTER=true)"
fi

echo "Done."
