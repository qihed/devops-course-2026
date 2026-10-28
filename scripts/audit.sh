#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo " [OK] $desc"; ((PASS++))
  else
    echo " [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"
    ((FAIL++))
  fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён" "no" "$(sudo sshd -T | awk '/^permitrootlogin/{print $2}')"
check "Парольная аутентификация отключена" "no" "$(sudo sshd -T | awk '/^passwordauthentication/{print $2}')"
port="$(sudo sshd -T | awk '/^port/{print $2; exit}')"
check "Порт SSH отличен от 22" "yes" "$([[ -n "$port" && "$port" != "22" ]] && echo yes || echo no)"
check "MaxAuthTries равен 3" "3" "$(sudo sshd -T | awk '/^maxauthtries/{print $2}')"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"
check "Политика входящего трафика: deny" "deny" "$(sudo ufw status verbose | awk '/^Default:/{gsub(",","",$2); print $2}')"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf " %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
check "Служба nginx активна" "active" "$(systemctl is-active nginx)"
check "Конфигурация nginx корректна" "0" "$(sudo nginx -t >/dev/null 2>&1; echo $?)"
# порог в днях можно завысить для проверки: CERT_DAYS=400 scripts/audit.sh
check "Сертификат действует ещё не менее ${CERT_DAYS:-30} дн." "0" "$(openssl x509 -in /etc/ssl/certs/devops.crt -noout -checkend $(( ${CERT_DAYS:-30} * 86400 )) >/dev/null 2>&1; echo $?)"
check "В каталоге ресурса нет файлов, доступных для записи всем" "0" "$(find /var/www/devops-site -perm -o+w | wc -l | tr -d ' ')"
check "Права закрытого ключа равны 600" "600" "$(sudo stat -c '%a' /etc/ssl/private/devops.key)"

echo "[5] Контейнеризация"
APP_DIR="${APP_DIR:-$HOME/app}"
check "Служба docker активна" "active" "$(systemctl is-active docker)"
check "Контейнер СУБД в состоянии healthy" "healthy" "$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null)"
check "Порты 5000 и 5432 слушаются только на 127.0.0.1" "0" "$(ss -tln | awk '$4 ~ /:(5000|5432)$/ && $4 !~ /^127\.0\.0\.1:/' | wc -l | tr -d ' ')"
check "Права файла .env равны 600" "600" "$(stat -c '%a' "${APP_DIR}/.env")"

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
