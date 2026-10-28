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

## 8. Проверка конфигурации
`scripts/audit.sh` проверяет SSH (root, пароли, порт, `MaxAuthTries`) и UFW (активность, политика deny); код возврата 0 при успехе, 1 при нарушении.
