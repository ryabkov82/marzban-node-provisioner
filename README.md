# Marzban Node Provisioner

Автоматически разворачивает **Marzban Node** на удалённых серверах (Docker) и регистрирует его в панели Marzban — **без ручного копирования сертификата**.

> Кому полезно: администраторам Marzban, кто добавляет узлы часто и хочет делать это одним плейбуком/джобой.

---

## Возможности

- Получение токена панели (`/api/admin/token`) и сертификата узла (`/api/node/settings` → `certificate`)
- Деплой контейнера `gozargah/marzban-node` с `SSL_CLIENT_CERT_FILE` и `SERVICE_PROTOCOL=rest`
- Автоматическая регистрация узла в панели (`POST /api/node`)
- Тихое обновление системы (noninteractive) перед установкой Docker — по желанию
- Варианты запуска: **Ansible локально** или **GitHub Actions**

---

## Требования

- Доступ по SSH на узел (обычно `root` по ключу)
- Ubuntu/Debian на узле (скрипт ставит Docker через официальный установщик)
- На вашей машине (или в CI), откуда запускается плейбук:
  - Python 3.10+
  - Ansible 9+
  - `community.docker` коллекция
- Доступ к панели Marzban (URL, логин/пароль администратора)

> Примеры ниже предполагают, что панель доступна по HTTPS. Для самоподписанных сертификатов можно временно отключить проверку (`panel_validate_certs=false`).

---

## Структура репозитория

```
marzban-node-provisioner/
├─ README.md
├─ LICENSE
├─ ansible/
│  ├─ ansible.cfg
│  ├─ collections/requirements.yml
│  ├─ group_vars/all.yml
│  ├─ inventories/example.ini
│  ├─ playbooks/provision_node.yml
│  └─ roles/marzban_node/
│     └─ tasks/main.yml
├─ scripts/
│  └─ add-node.sh
└─ .github/workflows/deploy-node.yml
```

---

## Быстрый старт (локально, Ansible)

1) Установите зависимости и коллекции:
```bash
python3 -m pip install --upgrade pip
pip install "ansible==9.*"
ansible-galaxy collection install -r ansible/collections/requirements.yml
```

2) Заполните инвентарь `ansible/inventories/example.ini` (или используйте свой):
```ini
[marzban_nodes]
203.0.113.10 ansible_user=root
# node2.example.com ansible_user=root
```

3) (Опционально) отредактируйте `ansible/group_vars/all.yml` (порты, REST-протокол и т.д.)

4) Запустите плейбук:
```bash
ansible-playbook -i ansible/inventories/example.ini ansible/playbooks/provision_node.yml   -e panel_url="https://panel.example.com"   -e panel_username="admin"   -e panel_password="S3cr3t"   -e panel_validate_certs=true
```

После выполнения:
- на узле появится `/var/lib/marzban-node/ssl_client_cert.pem`
- запустится контейнер `gozargah/marzban-node:latest` (host network)
- узел будет добавлен в панель через API

---

## Запуск через GitHub Actions

1) Включите в Secrets репозитория:
- `PANEL_URL` — URL вашей панели (например, `https://panel.example.com`)
- `PANEL_USERNAME`
- `PANEL_PASSWORD`
- `SSH_PRIVATE_KEY` — приватный SSH-ключ с доступом к узлам

2) Откройте **Actions → Deploy Marzban Node → Run workflow** и заполните поля:
- `nodes` — список IP/доменных имён (по одному в строке)
- `ssh_user` — пользователь на узлах (обычно `root`)
- опционально: `service_port`, `api_port`, `add_as_new_host`, `usage_coefficient`, `panel_verify_tls`

Workflow сам создаст динамический инвентарь и запустит Ansible-плейбук.

---

## Переменные (по умолчанию)

Файл `ansible/group_vars/all.yml`:

```yaml
service_port: 62050         # порт сервиса узла
api_port: 62051             # порт API узла
add_as_new_host: true       # добавить хост во все inbound'ы
usage_coefficient: 1.0      # коэффициент учёта трафика
service_protocol: "rest"    # используем REST-протокол для узла

panel_validate_certs: true  # проверка TLS-сертификата панели
```

> Эти значения можно переопределять в инвентаре или через `-e` при запуске плейбука/джобы.

---

## Тихое обновление системы (опционально)

Чтобы перед установкой Docker обновить систему **без вопросов**, в плейбуке уже есть заготовка. Она:
- включает noninteractive режим APT
- заставляет `needrestart` автоматически перезапускать сервисы
- выполняет `dist-upgrade` + autoremove/autoclean
- по необходимости делает `reboot`

Если вы хотите **принимать новые конфиги** при обновлении — замените `--force-confold` на `--force-confnew` в конфиге APT.

---

## Скрипт «одной кнопкой» (альтернатива Ansible)

Для единичных узлов есть `scripts/add-node.sh`:
```bash
export PANEL_URL="https://panel.example.com"
export PANEL_USERNAME="admin"
export PANEL_PASSWORD="S3cr3t"
export NODE="203.0.113.10"      # адрес узла
export SSH_USER="root"          # пользователь на узле
# export PANEL_VERIFY_TLS=false # если у панели самоподписанный TLS

./scripts/add-node.sh
```

Скрипт:
1) получает токен панели
2) скачивает сертификат узла
3) ставит Docker при необходимости, кладёт сертификат на узел
4) запускает контейнер узла
5) регистрирует узел в панели

---

## Частые вопросы

**1) Панель с самоподписанным сертификатом, запросы `curl`/`uri` падают.**  
Запускайте плейбук/скрипт с параметром `panel_validate_certs=false` (Ansible) или `PANEL_VERIFY_TLS=false` (скрипт). Используйте это только временно.

**2) Узел не появляется в панели.**  
Проверьте, что:
- на узле запущен контейнер `marzban-node` (и находится сертификат по пути `SSL_CLIENT_CERT_FILE`)
- фаервол пропускает порты `service_port` (по умолчанию 62050) и `api_port` (62051)
- адрес, который вы передаёте в API (`address`) — доступен панели по сети

**3) Можно ли использовать RPyC вместо REST?**  
Рекомендован REST. При необходимости вы можете адаптировать переменные окружения контейнера под RPyC, но плейбук ориентирован на REST.

**4) Как удалить узел с сервера?**  
```bash
docker rm -f marzban-node || true
rm -f /var/lib/marzban-node/ssl_client_cert.pem
```

---

## Лицензия

MIT. Смотрите файл `LICENSE`.
