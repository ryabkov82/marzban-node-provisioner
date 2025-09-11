# Makefile for marzban-node-provisioner
# Usage examples:
#   make help
#   make deps
#   make deploy LIMIT=203.0.113.10
#   make update-only LIMIT=groupname
#   make deploy-no-update
#   make script-all
#   make script-update-only NODE=203.0.113.10
#
# Variables:
#   INV   - inventory path (default: ansible/inventories/example.ini)
#   PLAY  - playbook path   (default: ansible/playbooks/provision_node.yml)
#   LIMIT - limit hosts/group (optional)
#   TAGS  - extra tags for playbook (optional)
#   EXTRA - extra flags for ansible-playbook (optional, e.g. EXTRA="-vvv")
#   NODE  - target node for script targets (ip/host); or set in .env
#
# .env file is supported. Place panel creds and defaults there:
#   PANEL_URL=https://panel.example.com
#   PANEL_USERNAME=admin
#   PANEL_PASSWORD=S3cr3t
#   PANEL_VERIFY_TLS=true
#   SSH_USER=root
#   NODE=203.0.113.10

SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

.DEFAULT_GOAL := help

INV ?= ansible/inventories/example.ini
PLAY ?= ansible/playbooks/provision_node.yml
ANSIBLE ?= ansible-playbook

# Helper: load .env variables into current shell for a recipe
define LOAD_ENV
set -a; [[ -f .env ]] && source ./.env || true; set +a
endef

.PHONY: help deps lint ping deploy update-only deploy-no-update list-tasks \
        script-all script-update-only script-docker-only script-register-only \
        node-logs

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "}; /^[a-zA-Z0-9_.-]+:.*?## / {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

deps: ## Install Ansible and required collections
	$(LOAD_ENV)
	python3 -m pip install --upgrade pip
	pip3 install "ansible==9.*" ansible-lint || true
	ansible-galaxy collection install -r ansible/collections/requirements.yml

lint: ## Run ansible-lint on playbooks and roles
	$(LOAD_ENV)
	ansible-lint -p || true

ping: ## Ansible ping to all/limited hosts
	$(LOAD_ENV)
	ansible -i "$(INV)" all -m ansible.builtin.ping $(if $(LIMIT),--limit "$(LIMIT)",)

deploy: ## Full deploy (all plays); uses PANEL_* vars from env/.env
	$(LOAD_ENV)
	$(ANSIBLE) -i "$(INV)" "$(PLAY)" \
		$(if $(LIMIT),--limit "$(LIMIT)",) \
		$(if $(TAGS),--tags "$(TAGS)",) \
		$(EXTRA)

update-only: ## Only OS update/reboot steps (tags: update,upgrade)
	$(LOAD_ENV)
	$(ANSIBLE) -i "$(INV)" "$(PLAY)" \
		--tags update,upgrade \
		$(if $(LIMIT),--limit "$(LIMIT)",) \
		$(EXTRA)

deploy-no-update: ## Deploy everything except OS updates
	$(LOAD_ENV)
	$(ANSIBLE) -i "$(INV)" "$(PLAY)" \
		--skip-tags update,upgrade \
		$(if $(LIMIT),--limit "$(LIMIT)",) \
		$(EXTRA)

list-tasks: ## List tasks for the playbook (with optional LIMIT)
	$(LOAD_ENV)
	$(ANSIBLE) -i "$(INV)" "$(PLAY)" --list-tasks \
		$(if $(LIMIT),--limit "$(LIMIT)",)

# ---------- Script targets (scripts/add-node.sh) ----------
# Require: PANEL_URL, PANEL_USERNAME, PANEL_PASSWORD, NODE (+ optional SSH_USER).
# Reads them from .env automatically.

script-all: ## Run scripts/add-node.sh full flow (upgrade+docker+register)
	$(LOAD_ENV)
	chmod +x scripts/add-node.sh
	./scripts/add-node.sh

script-update-only: ## Run only remote OS update via script (skip docker & register)
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

node-logs: ## Tail marzban-node logs on SSH_TARGET (alias from ~/.ssh/config)
	$(LOAD_ENV)
	[[ -n "$${SSH_TARGET:-}" ]] || { echo "Set SSH_TARGET (env or .env)"; exit 1; }
	ssh -o BatchMode=yes $${SSH_KEY:+-i "$${SSH_KEY}"} "$${SSH_TARGET}" \
	  'docker logs -f --since=1h marzban-node || true'
