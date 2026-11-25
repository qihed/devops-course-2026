# Конфигурация виртуальной машины devops-vm

Документ позволяет восстановить конфигурацию с нуля: откатить VM на снимок `01-clean-install` и выполнить шаги ниже.
Вместо VirtualBox использована LXD-VM на собственном сервере (Ubuntu Server 26.04, хост `daam-server`, доступ по Tailscale).

## 1. Параметры машины
- Гипервизор: LXD 6.10 (KVM), VM создана командой
  `lxc launch ubuntu:24.04 devops-vm --vm -c limits.memory=2GiB -c limits.cpu=2 -d root,size=25GiB`
- ОС: Ubuntu Server 24.04.5 LTS, образ `ubuntu:24.04` (cloud image)
- Имя узла: `devops-vm`, FQDN: `devops-vm.devops.local`
- ОЗУ: 2 ГБ, ядра: 2, диск: 25 ГБ (хранилище LXD `default`, драйвер `dir`)
- После создания: `sudo apt update && sudo apt upgrade -y`

## 2. Сетевые интерфейсы
| Интерфейс | Тип | Адрес | Назначение |
|---|---|---|---|
| `enp5s0` | NIC на мосту `lxdbr0` (NAT) | `10.56.0.174/24` | выход в Интернет и доступ с хоста `daam-server` |

- Мост `lxdbr0`: `10.56.0.1/24`, `ipv4.nat=true`, IPv6 отключён. Создан через `lxd init --preseed`.
- Отдельного Host-only адаптера нет: роль Host-only выполняет тот же мост (VM видна с сервера, снаружи недоступна).
- С Mac VM доступна только через сервер: `ProxyJump huawei`.
- На хосте `daam-server` нужны правила, иначе Docker блокирует пересылку трафика моста:
  ```
  sudo iptables -I DOCKER-USER -i lxdbr0 -j ACCEPT
  sudo iptables -I DOCKER-USER -o lxdbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  ```
  (после перезагрузки сервера пропадают, пока не сделаны постоянными).

## 3. Правило проброса портов
Проброса портов нет. Роль `127.0.0.1:2222 -> гость:2222` выполняет `ProxyJump`:
Mac -> `huawei` (Tailscale, `dev`) -> `10.56.0.174:2222`.
Фрагмент `~/.ssh/config` на Mac:
```
Host devops
  HostName 10.56.0.174
  Port 2222
  User devops
  IdentityFile ~/.ssh/devops_vm
  IdentitiesOnly yes
  ProxyJump huawei
```

## 4. Учётные записи
| Имя | Группы | Аутентификация |
|---|---|---|
| `ubuntu` | sudo и др. (учётка cloud image) | по SSH закрыта (`AllowUsers devops`); доступ только через `lxc exec` с сервера |
| `devops` | `devops`, `sudo`, `users` | по SSH только ключ ed25519 `~/.ssh/devops_vm` (на Mac); пароль нужен для `sudo` |

Создание:
```
sudo adduser devops            # в VM; пароль задаётся владельцем
sudo usermod -aG sudo devops
```
Ключ на Mac и установка:
```
ssh-keygen -t ed25519 -C "devops-vm-key" -f ~/.ssh/devops_vm
# публичный ключ -> /home/devops/.ssh/authorized_keys
chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys     # владелец devops
```
Отпечаток ключа хоста VM: `SHA256:mMXdtz+tEbECaM/FCmXoeNn8sJucIL4UZRKJ3rApTDo` (ED25519).
Root-доступ по SSH запрещён.

## 5. Служба SSH
Файл конфигурации: `/etc/ssh/sshd_config.d/99-hardening.conf` (основной `sshd_config` не менялся, копия: `/etc/ssh/sshd_config.backup`).
```
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers devops
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```
Дополнительно:
- Сокет-активация отключена, иначе порт остаётся 22:
  `sudo systemctl disable --now ssh.socket && sudo systemctl enable --now ssh.service && sudo systemctl restart ssh`
- Конфликтующих директив нет: в `60-cloudimg-settings.conf` уже `PasswordAuthentication no`.
- Проверка: `sudo sshd -t`, `sudo sshd -T | grep -Ei "^(port|permitrootlogin|passwordauthentication|maxauthtries|allowusers)"`, `sudo ss -tlnp | grep sshd` (ожидается `0.0.0.0:2222`).
- Порядок: действующую сессию не закрывать, проверять новым соединением.

## 6. Правила межсетевого экрана
Политики: `default deny incoming`, `default allow outgoing`, routed — disabled. Логирование: `medium`.
Порядок (разрешающие правила до включения):
```
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 2222/tcp comment 'SSH'
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw enable
sudo ufw delete allow 2222/tcp
sudo ufw limit 2222/tcp comment 'SSH rate-limited'
sudo ufw logging medium
```
Итоговые правила: `80/tcp ALLOW`, `443/tcp ALLOW`, `2222/tcp LIMIT` (и IPv6-варианты).
Правило `ufw allow ssh` не используется: оно открывает порт 22, а не 2222.

Имя узла:
```
sudo hostnamectl set-hostname devops-vm
sudo sed -i 's/^127.0.1.1.*/127.0.1.1 devops-vm.devops.local devops-vm/' /etc/hosts
hostname -f        # devops-vm.devops.local
```
`devops.local` на Mac (`/etc/hosts`) — запись выполняется владельцем: `<адрес> devops.local` (адрес уточняется в ПР6).

## 7. Снимки состояния
Создаются командой `lxc snapshot devops-vm <имя>`, откат: `lxc restore devops-vm <имя>`, список: `lxc info devops-vm`.
| Наименование | Момент создания (UTC) | Состояние |
|---|---|---|
| `01-clean-install` | 2026-10-28 19:35 | чистая установка, `apt upgrade` |
| `02-keys-configured` | 2026-10-28 19:38 | пользователь `devops`, ключ, `ssh devops` без пароля |
| `03-ssh-hardened` | 2026-10-28 19:38 | SSH ужесточён (порт 2222, без root и паролей) |
| `04-nginx-https` | 2026-10-28 20:08 | Nginx, самоподписанный сертификат, перенаправление на HTTPS |
| `05-docker-compose` | 2026-10-28 20:25 | Docker Engine, проект `~/app` (приложение + PostgreSQL) |

## 8. Веб-сервер
- Пакет: `nginx` 1.24.0 из репозитория Ubuntu (`sudo apt install -y nginx`). Главный процесс — root, рабочие — `www-data`.
- Конфигурация ресурса: `/etc/nginx/sites-available/devops-site`, активирована ссылкой `/etc/nginx/sites-enabled/devops-site`; стандартный ресурс отключён (`sudo rm /etc/nginx/sites-enabled/default`, файл в `sites-available` сохранён).
  - блок 1: `listen 80; listen [::]:80; server_name devops.local; return 301 https://$host$request_uri;`
  - блок 2: `listen 443 ssl; listen [::]:443 ssl; server_name devops.local;`, `ssl_certificate /etc/ssl/certs/devops.crt;`, `ssl_certificate_key /etc/ssl/private/devops.key;`, `ssl_protocols TLSv1.2 TLSv1.3;`, `root /var/www/devops-site; index index.html; location / { try_files $uri $uri/ =404; } error_page 404 /404.html;`, журналы `/var/log/nginx/devops-site.access.log` и `.error.log`. HSTS не включён.
- Каталог ресурса: `/var/www/devops-site`, владелец `devops:devops`, права каталога 755, файлов 644 (`sudo mkdir -p ... && sudo chown -R devops:devops ...`). Доставка: `scripts/deploy.sh` (`rsync --delete --chmod=u=rwX,go=rX`).
- Сертификат `/etc/ssl/certs/devops.crt` (644, root) и ключ `/etc/ssl/private/devops.key` (600, root:root). Формирование (срок 365 дней, самоподписанный, SAN `DNS:devops.local`):
  ```
  sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/private/devops.key -out /etc/ssl/certs/devops.crt \
    -subj "/CN=devops.local" -addext "subjectAltName=DNS:devops.local"
  ```
  Действует с 2026-10-28 до 2027-10-28. Ключ не покидает `/etc/ssl/private`, сертификат копируется на хост: `scp devops:/etc/ssl/certs/devops.crt ~/devops.crt`.
- Применение конфигурации: `sudo nginx -t && sudo systemctl reload nginx` (не `restart`).
- Порты 80 и 443 уже разрешены в UFW (раздел 6), профили `Nginx *` не используются.
- Доступ с Mac (VM не видна напрямую): SSH-туннель через сервер,
  `ssh -f -N -L 127.0.0.1:8080:10.56.0.174:80 -L 127.0.0.1:8443:10.56.0.174:443 huawei`;
  проверки: `curl --cacert ~/devops.crt --connect-to devops.local:443:127.0.0.1:8443 https://devops.local`.
  Для обращения по `https://devops.local` в браузере без порта в `/etc/hosts` Mac добавляется `127.0.0.1 devops.local`, а туннель поднимается на портах 80 и 443 (нужен sudo).

## 9. Контейнеризация
- Docker Engine 29.9.2 и плагин Compose v5.6.1 установлены из официального репозитория Docker (`https://download.docker.com/linux/ubuntu`, пакеты `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`); пакет `docker.io` не используется. Ключ репозитория `/etc/apt/keyrings/docker.asc`, список `/etc/apt/sources.list.d/docker.list`.
- Группа `docker`: участник `devops` (`sudo usermod -aG docker devops`, затем новая SSH-сессия). Участник группы фактически имеет права root, поэтому группа выдаётся только учётным записям с правом sudo.
- Проект: `~/app` (`/home/devops/app`), доставляется с хоста `rsync -avz --delete --exclude=.env app/ devops:app/`. Файлы: `Dockerfile`, `app.py`, `requirements.txt`, `.dockerignore`, `docker-compose.yml`, `.env.example`.
- Образ `devops-app:1.0` (`python:3.12-slim`, процесс от пользователя `app`, uid 999, команда в exec-форме `gunicorn`). Контейнеры: `app-app-1` (приложение), `app-db-1` (`postgres:16-alpine`, healthcheck `pg_isready`); `depends_on` с условием `service_healthy`; `restart: unless-stopped`.
- Файл `~/app/.env` создаётся только на сервере: `cp .env.example .env; chmod 600 .env; sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env`; права 600, владелец `devops`; в репозиторий не входит (`.gitignore`, `.dockerignore`, `--exclude=.env`).
- Публикуемые порты: `127.0.0.1:5000 -> 5000` (приложение, только для Nginx); порт СУБД 5432 не публикуется, приложение обращается к ней по имени сервиса `db` во встроенном DNS сети `app_backend`.
- Том: `app_db_data` (данные PostgreSQL, `/var/lib/postgresql/data`); `docker compose down` том сохраняет, `down -v` удаляет (на рабочем сервере не использовать).
- Обратный прокси-сервер: в блок HTTPS файла `/etc/nginx/sites-available/devops-site` добавлено
  ```
  location /app/ {
      proxy_pass http://127.0.0.1:5000/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
  }
  ```
  Применение: `sudo nginx -t && sudo systemctl reload nginx`. Статический ресурс сохранён.
- Запуск: `cd ~/app && docker compose up -d --build`; остановка: `docker compose down` (без `-v`).

## 10. Ansible

- **Расположение проекта**: каталог `ansible/` репозитория `qihed/devops-course-2026` (и переносится в `qihed/devops-ci-app/ansible/` для КР № 3).
- **Управляющий узел**: изолированный LXD-контейнер `devops-control` (Ubuntu 24.04, `10.56.0.121`, `ansible-core 2.16.3`, `sshpass 1.09`, коллекции `ansible.posix 1.6.2`, `community.docker 4.5.0`, `community.general 9.5.0`).
- **Управляемый узел**: виртуальная машина `devops-vm` (Ubuntu Server 24.04 amd64, `10.56.0.174/24` на мосту `lxdbr0`, возвращена к снимку `01-clean-install`).
- **Inventory**:
  - `ansible/inventory/bootstrap.ini` — первичный запуск от `student` (порт `22`) с `--ask-pass` и `--ask-become-pass`;
  - `ansible/inventory/prod.ini` (по умолчанию в `ansible.cfg`) — неинтерактивные запуски от `devops` (порт `22`) по ключу `~/.ssh/devops_vm`.
- **Роли и ответственность**:
  - `base` — проверка ОС (Ubuntu 24.04 amd64), базовые пакеты (`python3-debian`, `python3-requests`, `ufw`, `openssh-server`), официальный репозиторий Docker (`deb822_repository`), установка и запуск Docker Engine;
  - `ssh` — пользователь `devops`, открытый SSH-ключ, `/etc/sudoers.d/devops` (`NOPASSWD`, проверка `visudo -cf`), hardening SSH в `/etc/ssh/sshd_config.d/00-ansible-hardening.conf` (проверка `sshd -t -f`, отключение паролей и root), UFW (`22/tcp`, `80/tcp`, `deny incoming`);
  - `nginx` — пакет Nginx, шаблон reverse proxy `devops-ci-app.conf.j2` (`80 -> 127.0.0.1:5000`), отключение `default`, активация `devops-ci-app`, handlers `nginx -t` + `reload`;
  - `app` — добавление `devops` в группу `docker`, загрузка проверенного образа GHCR по полному SHA, запуск контейнера `devops-ci-app` с публикацией `127.0.0.1:5000:5000`, проверка `http://127.0.0.1:5000/health` модулем `uri`.
- **Приложение (из ПР № 10)**:
  - адрес образа GHCR: `ghcr.io/qihed/devops-ci-app` (публичный пакет, аутентификация для `docker pull` не требуется);
  - полный SHA (`app_tag`): `03548dd1f0c8b837912512c1f13ec2cb6148f1aa`;
  - порт контейнера: `127.0.0.1:5000 -> 5000` (доступ снаружи только через Nginx на порту `80`);
  - health endpoint: `http://10.56.0.174/health` (внутри VM — `http://127.0.0.1:5000/health`), ожидается `{"status":"ok"}`.
- **Команды управления** (из каталога `ansible/`):
  - первичный запуск (bootstrap): `ansible-playbook -i inventory/bootstrap.ini site.yml --ask-pass --ask-become-pass`;
  - повторный запуск (prod, идемпотентный): `ansible-playbook site.yml`;
  - read-only аудит: `ansible-playbook verify.yml`.

## 11. Проверка конфигурации
`scripts/audit.sh` проверяет SSH (root, пароли, порт, `MaxAuthTries`), UFW (активность, политика deny) веб-сервер (раздел 8) и контейнеризацию (раздел 9); код возврата 0 при успехе, 1 при нарушении.
