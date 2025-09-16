# Marzban Node Provisioner

Автоматизирует **развёртывание Marzban Node** на серверах (Docker), настройку **HAProxy+nginx**, доставку **TLS-сертификата** с мастер-сервера, **регистрацию узла в панели** (Host Settings + REALITY), а также обратный сценарий — **удаление узла** с чисткой DNS и доступа к сертификатам.

> Кому полезно: администраторам Marzban, кто часто добавляет/удаляет узлы и хочет делать это одной командой — локально или в CI.

---

## Возможности

- **OS update (noninteractive)**: тихое обновление/перезагрузка до установки Docker (настраивается тегами/флагами).
- **Docker + контейнер `gozargah/marzban-node`** (host network), авторазвёртывание/перезапуск.
- **HAProxy + nginx**: быстрая настройка TCP-проксирования (443→8443/8444), health-checks, /haproxy-stats.
- **TLS Sync**: копирование `fullchain.pem`/`privkey.pem` с мастер-сервера сертификатов на новый узел по SSH (без rsync), проверка subject/сроков.
- **Panel API**:
  - создание Node (`POST /api/node`) с нужным адресом/портами;
  - **Host Settings**: добавление/обновление хоста узла; поддержка **multi-SNI** (значения через запятую — Marzban выберет одно случайно);
  - **REALITY**: чтение и **добавление** FQDN в `streamSettings.realitySettings.serverNames` через `PUT /api/core/config` (без очистки существующих) + **перезапуск core**.
- **Cloudflare DNS**:
  - создание A-записей для узла (по списку из `host_vars`);
  - «solo default» можно отключать для общих записей (например, `www`, `site`);
  - **purge по IP**: удаление всех DNS-записей, указывающих на заданный IP.
- **Unregister**:
  - удаление узла из Host Settings, чистка его FQDN в REALITY, рестарт core;
  - удаление Node (`DELETE /api/node/{id}`).
- **Cert-master enroll/unenroll**:
  - добавление/удаление узла в allow-list файла рассылки сертификатов на мастер-сервере.

Все операции доступны как **Ansible-плейбуки**, **Makefile-цели** и **GitHub Actions**.

---

## Требования

- Доступ по SSH к узлам (обычно `root` по ключу).
- Ubuntu/Debian на узлах.
- Доступ к панели Marzban (URL, логин/пароль админа или access-token).
- Для Cloudflare: `CF_API_TOKEN`, `CF_ZONE` (и опц. `CF_ZONE_ID`).

Локально (вариант «system Ansible»):
- `ansible` 9.x, `ansible-lint` (через apt/пакеты дистрибутива) или через venv (см. ниже).

---

## Структура репозитория (главное)

```
marzban-node-provisioner/
├─ README.md
├─ .env.example
├─ Makefile
├─ ansible/
│  ├─ ansible.cfg
│  ├─ collections/requirements.yml
│  ├─ inventories/
│  │  ├─ example.ini
│  │  ├─ prod.ini                 # ваш прод-инвентарь (не коммитить)
│  │  └─ ssh_config.yml           # inventory через ~/.ssh/config (опционально)
│  ├─ group_vars/all.yml
│  ├─ host_vars/                  # переменные на хост
│  ├─ playbooks/provision_node.yml
│  └─ roles/
│     ├─ marzban_node/
│     ├─ haproxy/
│     ├─ nginx/
│     ├─ tls_sync/
│     ├─ panel_api/
│     ├─ panel_register/
│     ├─ panel_unregister/
│     ├─ cf_dns/
│     ├─ cf_dns_purge_ip/
│     └─ cert_master_enroll/
└─ scripts/
   └─ add-node.sh
```

> **Важно:** `prod.ini` и любые приватные `host_vars/*` добавляйте в `.gitignore` (см. ниже).

---

## Установка зависимостей

### Вариант A — системные пакеты (рекомендуется)
```bash
sudo apt-get update
sudo apt-get install -y ansible ansible-lint jq curl
ansible-galaxy collection install -r ansible/collections/requirements.yml
```

### Вариант B — через venv (если нужно изолированно)
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip "ansible==9.*" ansible-lint
ansible-galaxy collection install -r ansible/collections/requirements.yml
```
`.venv/` уже исключён в `.gitignore`.

---

## Инвентарь и секреты

- Пример: `ansible/inventories/example.ini`:
  ```ini
  [marzban_nodes]
  203.0.113.10 ansible_user=root
  ```

- Либо `ssh_config.yml` (plugin: `community.general.ssh_config`) — использовать алиасы из `~/.ssh/config`:
  ```yaml
  plugin: community.general.ssh_config
  strict: false
  ```

- Секреты задавайте через **`.env`** (см. `.env.example`) или GitHub Secrets.

### `.env.example` (фрагмент)
```dotenv
# Panel API
PANEL_URL=
PANEL_USERNAME=
PANEL_PASSWORD=
PANEL_VERIFY_TLS=true

# Inventory (локально)
INV=ansible/inventories/prod.ini

# Cert-master (TLS sync)
CERT_MASTER=nl-ams-1
CERT_MASTER_USER=root
CERT_SERVERS_FILE=/root/etc/cert-sync-servers.txt

# Cloudflare
CF_API_TOKEN=
CF_ZONE=digitalstreamers.xyz
# CF_ZONE_ID=

# Script defaults (scripts/add-node.sh)
SSH_TARGET=nl-ams-3
SSH_KEY=~/.ssh/id_rsa

# Optional script flags
# SKIP_UPGRADE=false
# SKIP_DOCKER=false
# SKIP_REGISTER=false
```

Добавьте в `.gitignore`:
```
# Inventories/host vars (секреты)
ansible/inventories/prod.ini
ansible/host_vars/*
.env
```

---

## Основные сценарии (Makefile)

> Используйте `LIMIT=<host>` для операций с конкретным узлом.  
> Если цель работает на `localhost`, Makefile автоматически добавит `,localhost` в `--limit`.

### 1) Полный деплой узла
```bash
make deploy LIMIT=nl-ams-3
```
Делает: panel_api → os_update → marzban_node → haproxy → nginx → tls_sync → panel_register.

### 2) Обновление ОС только
```bash
make update-only LIMIT=nl-ams-3
```

### 3) Только контейнер узла
```bash
make container-only LIMIT=nl-ams-3
```

### 4) Только прокси (HAProxy+nginx)
```bash
make proxy-only LIMIT=nl-ams-3
```

### 5) Только TLS-сертификат
```bash
make tls-only LIMIT=nl-ams-3
```

### 6) Регистрация в панели / правка Host Settings + REALITY
```bash
make panel-register LIMIT=nl-ams-3
# dry-run (только показать payload для /api/hosts):
make panel-register LIMIT=nl-ams-3 EXTRA='-e panel_register_hosts_dry_run=true'
```

### 7) Удаление узла из панели (unregister)
```bash
make panel-unregister LIMIT=nl-ams-3
```

### 8) Cloudflare DNS — применить записи для узла
```bash
make dns-apply LIMIT=nl-ams-3
```

### 9) Cloudflare DNS — purge всех записей по IP
```bash
make cf-dns-purge-ip LIMIT=nl-ams-3
# или вручную:
make cf-dns-purge-ip PURGE_IP=45.142.164.36
```

### 10) Cert-master — удалить узел из allow-list
```bash
make cert-master-unenroll LIMIT=nl-ams-3
```

### 11) «Каскадный» вывод узла из эксплуатации
```bash
make purge-node LIMIT=nl-ams-3
# (включает: panel-unregister → cf-dns-purge-ip → cert-master-unenroll)
```

### 12) Проверки прокси на узле
```bash
make proxy-check LIMIT=nl-ams-3
```
Проверяет конфиги, сервисы, порты и SNI (curl с --resolve).

---

## Что делает плейбук `provision_node.yml` (по ролям)

- **panel_api** (локально): получает токен панели.
- **os_update**: бесшумное обновление пакетов; перезагрузка при необходимости.
- **marzban_node**: Docker, каталог `/var/lib/marzban-node`, запуск контейнера с `SSL_CLIENT_CERT_FILE` и `SERVICE_PROTOCOL=rest`.
- **haproxy**/**nginx**: ставит пакеты и деплоит конфиги (`/etc/haproxy/haproxy.cfg`, nginx на 127.0.0.1:8443).
- **tls_sync**: читает `fullchain.pem`/`privkey.pem` с **cert-master** и кладёт их в `/etc/letsencrypt/live/<domain>/` на узле; проверяет subject.
- **panel_register** (локально):
  - создаёт Node (409 → находит существующий `node_id`);
  - **Host Settings**: для выбранных inbound-тегов добавляет/обновляет запись хоста узла (поддержка **multi-SNI** — через запятую);
  - **REALITY**: достаёт `serverNames` из `/api/core/config` по `tag`, **добавляет** домены узла (`panel_register_address` + `panel_register_reality_extra_names`) без удаления существующих, `PUT /api/core/config` + `POST /api/core/restart`.
- **panel_unregister** (локально):
  - чистит хост из Host Settings, удаляет домены из REALITY, перезапускает core;
  - удаляет сам Node.
- **cf_dns**: создаёт A-записи Cloudflare для узла.
- **cf_dns_purge_ip**: удаляет ВСЕ DNS-записи зоны, у которых `content == <IP>`.
- **cert_master_enroll**: добавляет/удаляет узел в списке рассылки сертификатов на master.

Все роли имеют теги для выборочного запуска (см. Makefile).

---

## Настройка Host Settings и REALITY

В `host_vars/<узел>.yml` задайте минимум:

```yaml
# Имя inbound с REALITY (точный tag в core config)
panel_register_reality_inbound_tag: "VLESS TCP REALITY"

# Адрес/имя узла — FQDN для Host Settings, и добавляется в REALITY
panel_register_address: "edge-ams-03.digitalstreamers.xyz"

# Дополнительные FQDN для REALITY (и для мульти-SNI)
panel_register_reality_extra_names:
  - "edge-ams-03.digitalstreamers.xyz"
  - "stream-ams-03.digitalstreamers.xyz"
  - "cache-ams-03.digitalstreamers.xyz"
  - "segment-ams-03.digitalstreamers.xyz"

# Теги inbound'ов, куда добавлять хост в Host Settings
panel_register_hosts_inbound_tags:
  - "vless"
# multi-SNI (строка формируется автоматически из address + extra_names;
# при желании можно задать приоритетное имя):
# panel_register_hosts_sni_preferred: "edge-ams-03.digitalstreamers.xyz"
```

> Для Cloudflare DNS: добавьте `cf_dns_records` с нужным набором A-записей (см. существующие примеры).  
> Для «общих» записей (`www`, `site`) отключайте поведение «solo default» в вашей конфигурации DNS-роли (мы поддерживаем оба сценария).

---

## Скрипт `scripts/add-node.sh`

Альтернатива Ansible для единичных инсталляций. Поддерживает флаги:
- `SKIP_UPGRADE=true` — пропустить обновление ОС,
- `SKIP_DOCKER=true` — пропустить установку Docker/контейнера,
- `SKIP_REGISTER=true` — пропустить регистрацию в панели.

Также можно вызвать отдельную синхронизацию TLS с cert-master (см. цель `script-sync-cert` в Makefile, если включили).

---

## GitHub Actions

В репозитории есть workflow **Deploy Marzban Node**.  
Он умеет запускать **полный деплой** или **частичные режимы**, а после полного — выполнить **post-checks** (syntax HAProxy/nginx, активность сервисов, слушающие порты, curl-проверки SNI).  
Переменные берутся из GitHub Secrets (`PANEL_URL`, `PANEL_USERNAME`, `PANEL_PASSWORD`/`PANEL_ACCESS_TOKEN`, `SSH_PRIVATE_KEY`, а для DNS — `CF_API_TOKEN`, `CF_ZONE`, …).

---

## Частые проблемы

- **Не видит инвентарь/хосты** — проверьте `INV` в `.env`, содержимое `prod.ini` или корректность `ssh_config.yml` и наличие коллекции `community.general`.
- **Узел недоступен по SSH** — проверьте ключ, `~/.ssh/config`, `known_hosts`, секцию `ansible_user`, а также фаервол.
- **Host Settings возвращает 400/“Inbound X doesn’t exist”** — убедитесь, что используете **правильные теги** inbound’ов (`vless`, `shadowsocks`) или отключите теги, которых нет.
- **REALITY не меняется** — проверьте `panel_register_reality_inbound_tag` (точный **tag** из core-конфига) и наличие `streamSettings.realitySettings` у этого inbound.

---

## Лицензия

MIT. См. `LICENSE`.
