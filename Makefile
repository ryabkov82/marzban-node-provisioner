# Makefile for marzban-node-provisioner (with local Python venv)
# Usage examples:
#   make help
#   make deps                      # creates .venv and installs ansible/ansible-lint
#   make ping LIMIT=node1
#   make proxy-only LIMIT=node1
#
# Variables:
#   INV   - inventory path (default: ansible/inventories/example.ini)
#   PLAY  - playbook path   (default: ansible/playbooks/provision_node.yml)
#   LIMIT - limit hosts/group (optional)
#   TAGS  - extra tags for playbook (optional)
#   EXTRA - extra flags for ansible-playbook (optional, e.g. EXTRA="-vvv")
#   NODE  - target node for script targets (ip/host or SSH alias); or set in .env
#
# .env file is supported. Place panel creds and defaults there.

# ---- Ansible config and roles path ----
export ANSIBLE_CONFIG=$(PWD)/ansible.cfg
export ANSIBLE_ROLES_PATH=$(PWD)/ansible/roles

SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -o pipefail -e -u -c

.DEFAULT_GOAL := help

INV ?= ansible/inventories/example.ini
PLAY ?= ansible/playbooks/provision_node.yml
ANSIBLE ?= ansible-playbook

# Load .env into shell (so $INV etc. available as shell vars)
define LOAD_ENV
set -a; [[ -f .env ]] && source ./.env || true; set +a
endef

# Вспомогательная функция: резолв IP цели (в переменную shell-а ip)
define _RESOLVE_PURGE_IP
ip="$${PURGE_IP:-}"; \
if [ -z "$$ip" ]; then \
  host="$${LIMIT:?Set LIMIT=<inventory host> or provide PURGE_IP}"; \
  inv="$${INV:-ansible/inventories/example.ini}"; \
  # 1) ansible_host из инвентаря
  if command -v ansible-inventory >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then \
    ip="$$(ansible-inventory -i "$$inv" --host "$$host" 2>/dev/null | jq -r '.ansible_host // empty')"; \
  fi; \
  # 2) HostName из ssh -G
  if [ -z "$$ip" ]; then \
    ip="$$(ssh -G "$$host" 2>/dev/null | awk '/^hostname /{print $$2; exit}')"; \
  fi; \
  # 3) Если это не IPv4 — зарезолвить A-запись
  if [ -n "$$ip" ] && ! printf '%s' "$$ip" | grep -Eq '^[0-9]+(\.[0-9]+){3}$$'; then \
    ip="$$(getent ahostsv4 "$$ip" | awk 'NR==1{print $$1}')"; \
  fi; \
fi; \
[ -n "$$ip" ] || { echo "Cannot resolve PURGE_IP; set PURGE_IP or LIMIT"; exit 2; };
endef

.PHONY: help deps lint ping deploy update-only deploy-no-update list-tasks \
        haproxy nginx proxy-only \
        script-all script-update-only script-docker-only script-register-only \
        node-logs

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "}; /^[a-zA-Z0-9_.-]+:.*?## / {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

deps: ## Use system Ansible; install Galaxy collections from requirements
	$(LOAD_ENV)
	@command -v ansible >/dev/null || { echo "Ansible not found. Install: sudo apt-get update && sudo apt-get install -y ansible"; exit 1; }
	@ansible --version
	ansible-galaxy collection install -r ansible/collections/requirements.yml
	@echo "OK: collections installed."

lint: ## Run ansible-lint if available (non-fatal)
	$(LOAD_ENV)
	@if command -v ansible-lint >/dev/null; then ansible-lint -p || true; else echo "ansible-lint not installed; skip"; fi

ping: ## Ansible ping to all/limited hosts
	$(LOAD_ENV)
	ansible -i "$${INV:-$(INV)}" all -m ansible.builtin.ping $(if $(LIMIT),--limit "$(LIMIT)",)

deploy: ## Full deploy (all plays)
	$(LOAD_ENV)
	@lim="$(LIMIT)"; \
	if [ -n "$$lim" ]; then lim="$$lim,localhost"; fi; \
	$(ANSIBLE) -i "$${INV:-$(INV)}" "$(PLAY)" \
		$${lim:+--limit "$$lim"} \
		$(if $(TAGS),--tags "$(TAGS)",) \
		$(EXTRA)

update-only: ## Only OS update/reboot steps (tags: update,upgrade)
	$(LOAD_ENV)
	$(ANSIBLE) -i "$${INV:-$(INV)}" "$(PLAY)" \
		--tags update,upgrade \
		$(if $(LIMIT),--limit "$(LIMIT)",) \
		$(EXTRA)

deploy-no-update: ## Deploy everything except OS updates
	$(LOAD_ENV)
	$(ANSIBLE) -i "$${INV:-$(INV)}" "$(PLAY)" \
		--skip-tags update,upgrade \
		$(if $(LIMIT),--limit "$(LIMIT)",) \
		$(EXTRA)

list-tasks: ## List tasks for the playbook (with optional LIMIT)
	$(LOAD_ENV)
	$(ANSIBLE) -i "$${INV:-$(INV)}" "$(PLAY)" --list-tasks \
		$(if $(LIMIT),--limit "$(LIMIT)",)

# ---------- Proxy-only targets ----------
haproxy: ## Apply only HAProxy role (--tags haproxy)
	$(LOAD_ENV)
	$(ANSIBLE) -i "$${INV:-$(INV)}" "$(PLAY)" \
		--tags haproxy \
		$(if $(LIMIT),--limit "$(LIMIT)",) \
		$(EXTRA)

nginx: ## Apply only nginx role (--tags nginx)
	$(LOAD_ENV)
	$(ANSIBLE) -i "$${INV:-$(INV)}" "$(PLAY)" \
		--tags nginx \
		$(if $(LIMIT),--limit "$(LIMIT)",) \
		$(EXTRA)

proxy-only: ## Apply HAProxy + nginx roles (--tags haproxy,nginx)
	$(LOAD_ENV)
	$(ANSIBLE) -i "$${INV:-$(INV)}" "$(PLAY)" \
		--tags haproxy,nginx \
		$(if $(LIMIT),--limit "$(LIMIT)",) \
		$(EXTRA)

container-only: ## Fetch cert + Docker + marzban-node (skip update/proxy/register)
	$(LOAD_ENV)
	$(ANSIBLE) -i "$${INV:-$(INV)}" "$(PLAY)" \
		--skip-tags update,upgrade,haproxy,nginx,panel_register \
		-e panel_url="$${PANEL_URL}" \
		-e panel_username="$${PANEL_USERNAME}" \
		-e panel_password="$${PANEL_PASSWORD}" \
		-e panel_validate_certs=$${PANEL_VERIFY_TLS:-true} \
		$(if $(LIMIT),--limit "$(LIMIT)",) \
		$(EXTRA)

tls-only: ## Sync wildcard TLS certs only (role tls_sync)
	$(LOAD_ENV)
	$(ANSIBLE) -i "$${INV:-$(INV)}" "$(PLAY)" \
		--tags tls_sync \
		--skip-tags panel_api,panel_register \
		--limit marzban_nodes \
		$(if $(LIMIT),--limit "$(LIMIT)",) \
		$(EXTRA)


proxy-with-tls: ## tls_sync + haproxy + nginx (proxy layer with real cert)
	$(LOAD_ENV)
	$(ANSIBLE) -i "$${INV:-$(INV)}" "$(PLAY)" \
		--tags tls_sync,haproxy,nginx \
		--skip-tags panel_api,panel_register \
		--limit marzban_nodes \
		$(if $(LIMIT),--limit "$(LIMIT)",) \
		$(EXTRA)

proxy-check: ## Check haproxy/nginx configs, services, ports, SNI
	$(LOAD_ENV)
	@host="$${LIMIT:?Set LIMIT=<host> or group}"; \
	ansible -i "$${INV:-$(INV)}" $$host -m shell -a 'haproxy -c -f /etc/haproxy/haproxy.cfg'
	ansible -i "$${INV:-$(INV)}" $$host -m shell -a 'nginx -t'
	ansible -i "$${INV:-$(INV)}" $$host -m shell -a 'systemctl is-active haproxy; systemctl is-active nginx'
	ansible -i "$${INV:-$(INV)}" $$host -m shell -a 'ss -lntp | egrep ":443|:1936|:8443|:8444" || true'
	ansible -i "$${INV:-$(INV)}" $$host -m shell -a 'curl -ks --resolve site.digitalstreamers.xyz:443:127.0.0.1 https://site.digitalstreamers.xyz/ | head -1'

# Регистрируем конкретный узел из инвентаря
# make panel-register LIMIT=nl-ams-3
panel-register: ## Register node in panel + Host Settings + REALITY (use LIMIT=<host>)
	$(LOAD_ENV)
	if [ -n "$(LIMIT)" ]; then lim="--limit $(LIMIT),localhost"; else lim="--limit localhost"; fi; \
	$(ANSIBLE) -i "$${INV:-$(INV)}" "$(PLAY)" --tags panel_api,panel_register $$lim
	
dns-apply: ## Create/update Cloudflare DNS records (use LIMIT=<host|group>)
	$(LOAD_ENV)
	$(ANSIBLE) -i "$${INV:-$(INV)}" "$(PLAY)" \
		--tags dns \
		$(if $(LIMIT),--limit "$(LIMIT)",) \
		$(EXTRA)

dns-plan: ## Dry-run DNS (check mode)
	$(LOAD_ENV)
	$(ANSIBLE) -i "$${INV:-$(INV)}" "$(PLAY)" \
		--tags dns --check --diff \
		$(if $(LIMIT),--limit "$(LIMIT)",) \
		$(EXTRA)

# make dns-purge-ip PURGE_IP=45.142.164.36
# dry-run (посмотреть, что удалит): добавь --check
# make dns-purge-ip PURGE_IP=45.142.164.36 EXTRA="--check --diff"
dns-purge-ip: ## Remove ALL Cloudflare DNS records that point to PURGE_IP (require PURGE_IP)
	$(LOAD_ENV)
	@set -euo pipefail; \
	$(call _RESOLVE_PURGE_IP) \
	echo "[dns-purge] Target IP: $$ip"; \
	$(ANSIBLE) -i "$${INV:-$(INV)}" "$(PLAY)" \
		--tags dns_purge_ip \
		-e cf_dns_purge_ip_target_ip="$$ip" \
		-e cf_dns_purge_ip_confirm=true \
		$(EXTRA)

# Добавление узла в задачу обновления сертификатов
# ansible-playbook -i ansible/inventories/prod.ini ansible/playbooks/provision_node.yml --tags cert_enroll --limit nl-ams-3 -vv
# Удаление узла из задачи обновления сертификатов
# make cert-master-remove LIMIT=nl-ams-3
cert-master-remove: ## Remove node from cert-master (SERVERS_FILE + revoke key). Use LIMIT=<host>
	$(LOAD_ENV)
	$(ANSIBLE) -i "$${INV:-$(INV)}" "$(PLAY)" \
		--tags cert_master_remove \
		$(if $(LIMIT),--limit "$(LIMIT)",) \
		$(EXTRA)

panel-unregister: ## Unregister node(s) from Marzban panel (use LIMIT=<host>)
	$(LOAD_ENV)
	if [ -n "$(LIMIT)" ]; then lim="--limit $(LIMIT),localhost"; else lim="--limit localhost"; fi; \
	$(ANSIBLE) -i "$${INV:-$(INV)}" "$(PLAY)" --tags panel_api,panel_unregister $$lim

# Композитная цель: полное выведение узла из эксплуатации
purge-node: ## Decommission node: panel-unregister + cf-dns-purge-ip + cert-master-unenroll
	$(MAKE) panel-unregister $(if $(LIMIT),LIMIT="$(LIMIT)")
	$(MAKE) dns-purge-ip $(if $(LIMIT),LIMIT="$(LIMIT)") $(if $(PURGE_IP),PURGE_IP="$(PURGE_IP)")
	$(MAKE) cert-master-remove $(if $(LIMIT),LIMIT="$(LIMIT)")

# ---------- Script targets (scripts/add-node.sh) ----------
# Uses PANEL_URL/PANEL_USERNAME/PANEL_PASSWORD and SSH_TARGET or SSH_USER+NODE (from .env or env)

script-all: ## Run scripts/add-node.sh full flow (upgrade+docker+register)
	$(LOAD_ENV)
	chmod +x scripts/add-node.sh
	./scripts/add-node.sh

script-update-only: ## Run only remote OS update (skip docker & register)
	$(LOAD_ENV)
	chmod +x scripts/add-node.sh
	SKIP_DOCKER=true SKIP_REGISTER=true ./scripts/add-node.sh

script-docker-only: ## Run only docker/cert/container (skip upgrade & register)
	$(LOAD_ENV)
	chmod +x scripts/add-node.sh
	SKIP_UPGRADE=true SKIP_REGISTER=true ./scripts/add-node.sh

script-register-only: ## Register node in panel only (skip upgrade & docker)
	$(LOAD_ENV)
	chmod +x scripts/add-node.sh
	SKIP_UPGRADE=true SKIP_DOCKER=true ./scripts/add-node.sh

node-logs: ## Tail marzban-node logs on SSH_TARGET or SSH_USER@NODE
	$(LOAD_ENV)
	@if [[ -n "$${SSH_TARGET:-}" ]]; then \
		ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes $${SSH_KEY:+-i "$${SSH_KEY}"} "$${SSH_TARGET}" \
		  'docker logs -f --since=1h marzban-node || true'; \
	elif [[ -n "$${SSH_USER:-}" && -n "$${NODE:-}" ]]; then \
		ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes $${SSH_KEY:+-i "$${SSH_KEY}"} "$${SSH_USER}@$${NODE}" \
		  'docker logs -f --since=1h marzban-node || true'; \
	else \
		echo "Set SSH_TARGET (recommended) or SSH_USER and NODE (in .env or env)"; exit 1; \
	fi

# --- Script-only: sync TLS cert from cert-master to target -------------------
script-sync-cert: ## Sync wildcard TLS cert (cert-master -> target) via scripts/add-node.sh (no upgrade/docker/register)
	$(LOAD_ENV)
	@command -v bash >/dev/null || { echo "bash not found in PATH"; exit 127; }
	@[[ -n "$${SSH_TARGET:-}" ]]     || { echo "Set SSH_TARGET (env or .env)"; exit 1; }
	@[[ -n "$${CERT_DOMAIN:-}" ]]    || { echo "Set CERT_DOMAIN (env or .env)"; exit 1; }
	@[[ -n "$${CERT_MASTER:-}" ]]    || { echo "Set CERT_MASTER (env or .env)"; exit 1; }
	@[[ -n "$${SSH_OPTS:-}" ]]       || echo "Tip: define SSH_OPTS or SSH_KEY in .env (using ~/.ssh/id_rsa by default in script)"
	chmod +x scripts/add-node.sh
	CERT_SYNC_ENABLE=true CERT_VERIFY=$${CERT_VERIFY:-true} \
	SKIP_UPGRADE=true SKIP_DOCKER=true SKIP_REGISTER=true \
	./scripts/add-node.sh	