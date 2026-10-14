#!/usr/bin/env bash
#
# Marzban Setup by F3 Cloud
# Installs Marzban, creates a ready VLESS Reality inbound with an automatically
# chosen masking site, opens the panel on a random port and closes everything else.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/f3cloud-host/Marzban/main/marzban-setup.sh)
#
# Supported: Ubuntu 22.04+ and Debian 11+. Run as root on a fresh server.
# Source: https://github.com/f3cloud-host/Marzban

set -o pipefail

APP_DIR="/opt/marzban"
DATA_DIR="/var/lib/marzban"
ENV_FILE="$APP_DIR/.env"
XRAY_CONFIG="$DATA_DIR/xray_config.json"
NGINX_SITE="/etc/nginx/sites-available/marzban-panel"
COMPOSE="docker compose -f $APP_DIR/docker-compose.yml -p marzban"
INSTALLER_URL="https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh"
LOG="/root/marzban-setup.log"

# Masking sites: small European sites with TLS 1.3 and HTTP/2 on their own servers,
# not behind a CDN. Every candidate is checked live before use.
SITES=(t3n.de www.computerbase.de www.reichelt.de www.pollin.de wiki.ubuntuusers.de
       www.kuketz-blog.de mailbox.org www.df.eu www.manitu.de www.webgo.de)

if [ -t 1 ]; then
  R=$'\e[91m'; G=$'\e[92m'; Y=$'\e[93m'; B=$'\e[1m'; C=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; C=""
fi

LINE="------------------------------------------------------------"
info() { echo "${G}$*${C}"; }
warn() { echo "${Y}$*${C}"; }
step() { echo; echo "${B}$*${C}"; }
die()  { echo; echo "${R}Ошибка: $*${C}" >&2; echo "Подробности в файле $LOG" >&2; exit 1; }

rand_hex()  { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
rand_pass() { local p=""; while [ "${#p}" -lt 20 ]; do p="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"; done; echo "$p"; }

port_busy() { ss -Htln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"; }
rand_port() {
  local p
  while true; do
    p=$(( (RANDOM << 15 | RANDOM) % 30000 + 20000 ))
    port_busy "$p" || { echo "$p"; return; }
  done
}

server_ip() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
  if [ -z "$ip" ] || [[ "$ip" =~ ^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]]; then
    ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null)"
  fi
  echo "$ip"
}

# A site fits if it answers with TLS 1.3 and HTTP/2 and is not behind a known CDN
site_ok() {
  local d="$1" hs srv
  getent ahostsv4 "$d" >/dev/null 2>&1 || return 1
  hs="$(timeout 10 openssl s_client -connect "$d:443" -servername "$d" -tls1_3 -alpn h2 </dev/null 2>/dev/null)"
  echo "$hs" | grep -q "TLSv1.3" || return 1
  echo "$hs" | grep -q "ALPN protocol: h2" || return 1
  srv="$(timeout 10 curl -s -o /dev/null -D - --max-time 8 "https://$d" 2>/dev/null | tr -d '\r' \
        | awk -F': ' 'tolower($1) == "server" {print tolower($2); exit}')"
  echo "$srv" | grep -qiE "cloudflare|fastly|akamai" && return 1
  return 0
}

pick_site() {
  local d
  for d in $(printf '%s\n' "${SITES[@]}" | shuf); do
    if site_ok "$d"; then echo "$d"; return 0; fi
  done
  return 1
}

# ---------- checks ----------

[ "$(id -u)" -eq 0 ] || die "запустите скрипт от имени root"
command -v apt-get >/dev/null 2>&1 || die "скрипт работает только на Ubuntu и Debian"
: >"$LOG"

echo
echo "${B}Установка Marzban от F3 Cloud${C}"
echo "Скрипт сам всё установит и настроит, это займёт 3–5 минут."

if [ -d "$APP_DIR" ]; then
  die "Marzban уже установлен в $APP_DIR. Скрипт рассчитан на новый сервер"
fi
if port_busy 443; then
  die "порт 443 уже занят другой программой. Скрипт рассчитан на новый сервер"
fi
# Other Nginx sites could take port 443 from Xray after Nginx restarts
for f in /etc/nginx/sites-enabled/*; do
  [ -e "$f" ] || continue
  [ "$(basename "$f")" = "default" ] && continue
  die "в Nginx уже есть другие сайты. Скрипт рассчитан на новый сервер"
done
if ls /etc/nginx/conf.d/*.conf >/dev/null 2>&1; then
  die "в Nginx уже есть другие настройки в /etc/nginx/conf.d. Скрипт рассчитан на новый сервер"
fi

step "Шаг 1 из 6. Устанавливаем нужные программы"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >>"$LOG" 2>&1 || die "не удалось обновить список пакетов"
apt-get install -y -qq curl openssl nginx ufw ca-certificates sqlite3 >>"$LOG" 2>&1 || die "не удалось установить пакеты"
info "Готово"

step "Шаг 2 из 6. Устанавливаем Marzban"
echo "Это самый долгий шаг, подождите пару минут..."
tmp="$(mktemp -d)"
curl -fsSL -o "$tmp/marzban.sh" "$INSTALLER_URL" || die "не удалось скачать установщик Marzban"
# The official installer ends by following the logs forever, so we skip that call
sed -i 's/^\([[:space:]]*\)follow_marzban_logs$/\1true/' "$tmp/marzban.sh"
bash "$tmp/marzban.sh" install --database sqlite </dev/null >>"$LOG" 2>&1 || die "установщик Marzban завершился с ошибкой"
rm -rf "$tmp"
[ -f "$ENV_FILE" ] || die "не найден файл настроек $ENV_FILE"
info "Marzban установлен"

step "Шаг 3 из 6. Подбираем сайт для маскировки"
echo "Проверяем сайты из списка..."
SITE="$(pick_site)" || die "ни один сайт из списка сейчас не подходит, запустите скрипт ещё раз позже"
info "Выбран сайт: $SITE"

step "Шаг 4 из 6. Настраиваем VLESS Reality"
KEYS="$($COMPOSE exec -T marzban xray x25519 2>>"$LOG")" || die "не удалось создать ключи Reality"
PRIVATE_KEY="$(echo "$KEYS" | awk -F': ' '/Private/ {print $2}' | tr -d '\r ')"
PUBLIC_KEY="$(echo "$KEYS" | awk -F': ' '/Public/ {print $2}' | tr -d '\r ')"
if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
  die "не удалось прочитать ключи Reality"
fi
SHORT_ID="$(rand_hex 8)"

cat >"$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "routing": {
    "rules": [ { "ip": ["geoip:private"], "outboundTag": "BLOCK", "type": "field" } ]
  },
  "inbounds": [
    {
      "tag": "VLESS TCP REALITY",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": {
        "network": "tcp",
        "tcpSettings": {},
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SITE:443",
          "xver": 0,
          "serverNames": ["$SITE"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "DIRECT" },
    { "protocol": "blackhole", "tag": "BLOCK" }
  ]
}
EOF
info "Готово"

step "Шаг 5 из 6. Открываем панель управления"
IP="$(server_ip)"
[ -n "$IP" ] || die "не удалось определить IP-адрес сервера"
PANEL_PORT="$(rand_port)"

# Marzban without SSL listens only on 127.0.0.1:8000, so Nginx publishes it on a random port
sed -i 's~^#* *UVICORN_PORT.*~UVICORN_PORT = 8000~' "$ENV_FILE"
sed -i '/^#* *XRAY_SUBSCRIPTION_URL_PREFIX/d' "$ENV_FILE"
# The stock .env ends without a newline, so start the new setting on its own line
printf '\nXRAY_SUBSCRIPTION_URL_PREFIX = "http://%s:%s"\n' "$IP" "$PANEL_PORT" >>"$ENV_FILE"

cat >"$NGINX_SITE" <<EOF
server {
    listen $PANEL_PORT;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/marzban-panel
nginx -t >>"$LOG" 2>&1 || die "ошибка в настройках Nginx"
systemctl enable nginx >>"$LOG" 2>&1
systemctl restart nginx >>"$LOG" 2>&1 || die "не удалось запустить Nginx"

$COMPOSE down >>"$LOG" 2>&1
$COMPOSE up -d >>"$LOG" 2>&1 || die "не удалось перезапустить Marzban"
for _ in $(seq 1 30); do
  sleep 2
  curl -s -o /dev/null "http://127.0.0.1:$PANEL_PORT/dashboard/" && break
done
curl -s -o /dev/null "http://127.0.0.1:$PANEL_PORT/dashboard/" || die "панель не отвечает"

ADMIN_USER="admin"
ADMIN_PASS="$(rand_pass)"
printf '\n\n' | $COMPOSE exec -T -e MARZBAN_ADMIN_PASSWORD="$ADMIN_PASS" marzban \
  marzban-cli admin create -u "$ADMIN_USER" --sudo >>"$LOG" 2>&1 || die "не удалось создать администратора"

# Marzban hardcodes the Reality client fingerprint to chrome, which filters flag
# more often than firefox. The default host is created lazily on the first hosts
# request, so we trigger it, then switch its fingerprint to firefox.
DB="$DATA_DIR/db.sqlite3"
TOKEN="$(curl -s -X POST "http://127.0.0.1:$PANEL_PORT/api/admin/token" \
  -d "username=$ADMIN_USER&password=$ADMIN_PASS" \
  | python3 -c "import sys, json; print(json.load(sys.stdin).get('access_token', ''))" 2>/dev/null)"
if [ -n "$TOKEN" ]; then
  for _ in $(seq 1 15); do
    curl -s -o /dev/null -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PANEL_PORT/api/hosts"
    rows="$(sqlite3 "$DB" "SELECT count(*) FROM hosts WHERE inbound_tag = 'VLESS TCP REALITY';" 2>/dev/null)"
    [ "$rows" = "1" ] && break
    sleep 2
  done
  sqlite3 -cmd ".timeout 5000" "$DB" \
    "UPDATE hosts SET fingerprint = 'firefox' WHERE inbound_tag = 'VLESS TCP REALITY';" >>"$LOG" 2>&1
  # Reload so the panel serves the new fingerprint
  $COMPOSE restart >>"$LOG" 2>&1
  for _ in $(seq 1 30); do
    sleep 2
    curl -s -o /dev/null "http://127.0.0.1:$PANEL_PORT/dashboard/" && break
  done
fi
fp_now="$(sqlite3 "$DB" "SELECT fingerprint FROM hosts WHERE inbound_tag = 'VLESS TCP REALITY';" 2>/dev/null)"
[ "$fp_now" = "firefox" ] || warn "не удалось задать отпечаток firefox, его можно выбрать в панели в разделе Hosts"
info "Панель работает на порту $PANEL_PORT"

step "Шаг 6 из 6. Закрываем лишние порты"
{
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  ufw allow 443/tcp
  ufw allow "$PANEL_PORT"/tcp
} >>"$LOG" 2>&1
ufw --force enable >>"$LOG" 2>&1 || die "не удалось включить брандмауэр"
info "Открыты только порты 22 (SSH), 443 (VPN) и $PANEL_PORT (панель)"

# keep the answers for the owner of the server, readable only by root
cat >/root/marzban-credentials.txt <<EOF
Панель:   http://$IP:$PANEL_PORT/dashboard/
Логин:    $ADMIN_USER
Пароль:   $ADMIN_PASS
Сайт для маскировки: $SITE
EOF
chmod 600 /root/marzban-credentials.txt

echo
echo "$LINE"
info "${B}Готово! Marzban установлен и настроен${C}"
echo "$LINE"
echo
echo "${B}Панель управления${C}"
echo "  Адрес:   http://$IP:$PANEL_PORT/dashboard/"
echo "  Логин:   $ADMIN_USER"
echo "  Пароль:  $ADMIN_PASS"
echo
echo "${B}VPN${C}"
echo "  Протокол:  VLESS Reality на порту 443"
echo "  Маскировка: сайт $SITE, отпечаток firefox"
echo
echo "${B}Что дальше${C}"
echo "  1. Откройте адрес панели в браузере и войдите."
echo "  2. Нажмите «Создать», придумайте имя, выберите Vless и сохраните."
echo "  3. Скопируйте ссылку подписки пользователя и добавьте её в приложение VPN."
echo
echo "  Инструкция: https://docs.f3cloud.com/ru/vpn-guide/marzban-ustanovka-vpn"
echo
warn "Данные для входа сохранены в файле /root/marzban-credentials.txt"
echo "$LINE"
