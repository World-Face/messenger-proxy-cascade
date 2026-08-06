#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║   Messenger Proxy Cascade — вход (РФ) → выход (зарубеж)      ║
# ║      WhatsApp + Telegram MTProto                             ║
# ║      Транспорт между серверами: Xray VLESS + REALITY (TCP)   ║
# ║      https://github.com/World-Face/messenger-proxy-cascade   ║
# ╚══════════════════════════════════════════════════════════════╝
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓ $1${NC}"; }
info() { echo -e "${CYAN}  → $1${NC}"; }
warn() { echo -e "${YELLOW}  ! $1${NC}"; }
err()  { echo -e "${RED}  ✗ $1${NC}"; exit 1; }
step() { echo -e "\n${BOLD}${BLUE}[$1]${NC} $2"; }

STATE_DIR="/opt/messenger-proxy"
XRAY_DIR="${STATE_DIR}/xray"
# локальные порты dokodemo-door на входном сервере
LP_CHAT=20443; LP_MEDIA=20777; LP_TG=20943; LP_PROBE=10808

[[ $EUID -ne 0 ]] && err "Запустите скрипт от root: sudo bash install.sh"

# Если скрипт пришёл по конвейеру (bash <(curl ...)), забираем ввод с терминала.
# Терминала может не быть вовсе — тогда работаем на переменных окружения.
if [[ ! -t 0 ]] && (exec < /dev/tty) 2>/dev/null; then exec < /dev/tty; fi

# ask ИМЯ_ПЕРЕМЕННОЙ "вопрос" [значение по умолчанию]
# Уже заданная переменная окружения выигрывает — так ставится без интерактива.
ask() {
  local n="$1" p="$2" d="${3:-}" v
  if [[ -n "${!n:-}" ]]; then
    info "${p}: ${!n}"
    return
  fi
  read -rp "  ${p}${d:+ [$d]}: " v
  printf -v "$n" '%s' "${v:-$d}"
}

confirm() {
  [[ "${AUTO_CONFIRM:-}" == "y" ]] && return 0
  local c; read -rp "  Продолжить? (y/n): " c
  [[ "$c" =~ ^[yY]$ ]] || { echo "  Отменено."; exit 0; }
}

# ══════════════════════════════════════════════════════════════
#  Общее
# ══════════════════════════════════════════════════════════════

base_deps() {
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    ca-certificates curl openssl unzip netcat-openbsd haproxy >/dev/null
}

tune_sysctl() {
  sysctl -qw net.ipv6.conf.all.disable_ipv6=1     >/dev/null 2>&1 || true
  sysctl -qw net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
  cat > /etc/sysctl.d/99-messenger-proxy.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.core.somaxconn=8192
net.ipv4.tcp_fastopen=3
EOF
  sysctl -p /etc/sysctl.d/99-messenger-proxy.conf >/dev/null 2>&1 || true
}

open_port() { # open_port <порт> <tcp|udp> [источник]
  local p="$1" proto="$2" src="${3:-}"
  if [[ -n "$src" ]]; then
    iptables -I INPUT -p "$proto" --dport "$p" -s "$src" -j ACCEPT 2>/dev/null || true
    ufw allow from "$src" to any port "$p" proto "$proto" >/dev/null 2>&1 || true
  else
    iptables -I INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null || true
    ufw allow "$p/$proto" >/dev/null 2>&1 || true
  fi
}

install_xray() {
  if command -v xray &>/dev/null; then
    ok "xray уже установлен ($(xray version 2>/dev/null | head -1))"
  else
    local v
    v=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest \
        | grep '"tag_name"' | cut -d'"' -f4)
    [[ -z "$v" ]] && v="v25.9.11"
    info "Скачиваем Xray-core ${v}..."
    curl -sL "https://github.com/XTLS/Xray-core/releases/download/${v}/Xray-linux-64.zip" -o /tmp/xray.zip
    unzip -oq /tmp/xray.zip -d /tmp/xray-dl xray
    install -m 0755 /tmp/xray-dl/xray /usr/local/bin/xray
    rm -rf /tmp/xray.zip /tmp/xray-dl
    ok "Xray $(xray version 2>/dev/null | head -1) установлен"
  fi
  mkdir -p "$XRAY_DIR"
  cat > /etc/systemd/system/xray-cascade.service <<EOF
[Unit]
Description=Xray cascade transport (messenger-proxy)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config ${XRAY_DIR}/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}

install_mtg() {
  if command -v mtg &>/dev/null; then
    ok "mtg уже установлен ($(mtg --version 2>/dev/null | head -1))"
    return
  fi
  local v
  v=$(curl -s https://api.github.com/repos/9seconds/mtg/releases/latest \
      | grep '"tag_name"' | cut -d'"' -f4 | tr -d 'v')
  [[ -z "$v" ]] && v="2.1.7"
  info "Скачиваем mtg v${v}..."
  curl -sL "https://github.com/9seconds/mtg/releases/download/v${v}/mtg-${v}-linux-amd64.tar.gz" -o /tmp/mtg.tar.gz
  tar xz -C /tmp/ -f /tmp/mtg.tar.gz
  install -m 0755 "/tmp/mtg-${v}-linux-amd64/mtg" /usr/local/bin/mtg
  rm -rf /tmp/mtg.tar.gz "/tmp/mtg-${v}-linux-amd64"
  ok "mtg $(mtg --version 2>/dev/null | head -1) установлен"
}

# Самоподписанный сертификат WhatsApp (схема Meta)
gen_wa_cert() {
  local dns="$1" ip="$2" d=/tmp/wacert.$$
  mkdir -p /etc/haproxy/ssl "$d"; pushd "$d" >/dev/null
  local CA_SUBJ SSL_SUBJ
  CA_SUBJ=$(head -c 60 /dev/urandom | tr -dc 'a-zA-Z0-9')
  SSL_SUBJ="$(head -c 60 /dev/urandom | tr -dc 'a-zA-Z0-9').net"

  openssl genrsa -out ca-key.pem 4096 2>/dev/null
  openssl req -x509 -new -nodes -key ca-key.pem -days 36500 \
    -out ca.pem -subj "/CN=${CA_SUBJ}" 2>/dev/null

  cat > openssl.cnf <<EOM
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth, serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${dns}
IP.1 = ${ip}
EOM

  openssl genrsa -out key.pem 4096 2>/dev/null
  openssl req -new -key key.pem -out key.csr -subj "/CN=${SSL_SUBJ}" -config openssl.cnf 2>/dev/null
  openssl x509 -req -in key.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
    -out cert.pem -days 3650 -extensions v3_req -extfile openssl.cnf 2>/dev/null

  cat key.pem cert.pem > /etc/haproxy/ssl/proxy.whatsapp.net.pem
  chmod 600 /etc/haproxy/ssl/proxy.whatsapp.net.pem
  chown haproxy:haproxy /etc/haproxy/ssl/proxy.whatsapp.net.pem 2>/dev/null || true
  popd >/dev/null; rm -rf "$d"
  ok "Сертификат для ${dns} создан"
}

# ══════════════════════════════════════════════════════════════
#  ВЫХОДНОЙ СЕРВЕР (зарубеж) — реальный прокси + приёмник VLESS
# ══════════════════════════════════════════════════════════════
install_exit() {
  echo -e "\n${YELLOW}${BOLD}  Настройка ВЫХОДНОГО (зарубежного) сервера${NC}\n"

  local guess
  guess=$(curl -s4 --max-time 10 https://api.ipify.org || true)
  ask EXIT_IP  "Публичный IP этого (выходного) сервера" "$guess"
  ask ENTRY_IP "Публичный IP входного сервера (РФ)"
  [[ $EXIT_IP  =~ ^[0-9.]+$ ]] || err "Некорректный IP выходного сервера"
  [[ $ENTRY_IP =~ ^[0-9.]+$ ]] || err "Некорректный IP входного сервера"

  echo ""
  echo -e "  ${CYAN}── WhatsApp ──${NC}"
  ask WA_DOMAIN     "Домен WhatsApp (напр. whatsapp.example.com)"
  ask WA_CHAT_PORT  "Порт Chat"  8443
  ask WA_MEDIA_PORT "Порт Media" 7777
  echo ""
  echo -e "  ${CYAN}── Telegram MTProto ──${NC}"
  ask TG_DOMAIN "Домен Telegram (напр. telegram.example.com)"
  ask TG_PORT   "Порт" 9443
  echo ""
  echo -e "  ${CYAN}── Транспорт каскада (VLESS + REALITY) ──${NC}"
  ask XRAY_PORT "Порт REALITY" 443
  ask SNI       "Маскировочный домен (SNI)" vk.ru

  echo ""
  echo -e "${BOLD}  ┌──────────────────────────────────────────────┐${NC}"
  printf "  │  %-20s %-21s│\n" "Выход (этот сервер):" "$EXIT_IP"
  printf "  │  %-20s %-21s│\n" "Вход (РФ):"        "$ENTRY_IP"
  printf "  │  %-20s %-21s│\n" "WhatsApp:"         "$WA_DOMAIN"
  printf "  │  %-20s %-21s│\n" "  chat / media:"   ":$WA_CHAT_PORT / :$WA_MEDIA_PORT"
  printf "  │  %-20s %-21s│\n" "Telegram:"         "$TG_DOMAIN:$TG_PORT"
  printf "  │  %-20s %-21s│\n" "REALITY:"          ":$XRAY_PORT ($SNI)"
  echo -e "${BOLD}  └──────────────────────────────────────────────┘${NC}"
  confirm

  step "1/7" "Системные зависимости"
  base_deps; tune_sysctl; ok "Зависимости установлены"

  step "2/7" "Xray и ключи REALITY"
  install_xray
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  local xk
  xk=$(xray x25519)
  # у разных версий подписи строк отличаются (Private key / PrivateKey, Public key / Password)
  REALITY_PRIV=$(echo "$xk" | sed -n '1s/^[^:]*: *//p')
  REALITY_PUB=$(echo "$xk"  | sed -n '2s/^[^:]*: *//p')
  [[ -n "$REALITY_PRIV" && -n "$REALITY_PUB" ]] || err "Не удалось сгенерировать ключи REALITY"
  UUID=$(cat /proc/sys/kernel/random/uuid)
  SHORT_ID=$(openssl rand -hex 8)
  ok "Ключи REALITY сгенерированы"

  step "3/7" "Конфиг Xray (приём VLESS)"
  cat > "$XRAY_DIR/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "cascade-in",
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": [ "${SNI}" ],
          "privateKey": "${REALITY_PRIV}",
          "shortIds": [ "${SHORT_ID}" ]
        }
      },
      "sniffing": { "enabled": false }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } }
  ]
}
EOF
  chmod 600 "$XRAY_DIR/config.json"
  xray run -test -config "$XRAY_DIR/config.json" >/dev/null 2>&1 || err "Конфиг Xray невалиден"
  ok "Xray настроен (слушает :${XRAY_PORT}, маскировка под ${SNI})"

  step "4/7" "WhatsApp: сертификат и HAProxy"
  gen_wa_cert "$WA_DOMAIN" "$EXIT_IP"
  cat > /etc/haproxy/haproxy.cfg <<EOF
global
  log /dev/log local0
  tune.bufsize 4096
  maxconn 27500
  spread-checks 5
  ssl-server-verify none
  stats socket /run/haproxy/admin.sock mode 660 level admin
  chroot /var/lib/haproxy
  user haproxy
  group haproxy
  daemon

defaults
  mode tcp
  timeout client-fin 1s
  timeout server-fin 1s
  timeout connect 5s
  timeout client 200s
  timeout server 200s
  default-server inter 10s fastinter 1s downinter 3s error-limit 50

resolvers dns_ipv4
  nameserver dns1 8.8.8.8:53
  nameserver dns2 1.1.1.1:53
  accepted_payload_size 4096
  timeout resolve 1s
  timeout retry   1s
  hold valid 10s

listen stats
  bind 127.0.0.1:8199
  mode http
  stats uri /
  stats refresh 10s

# ── WhatsApp chat: SSL-терминация, PROXY-протокол к серверам Meta ──
frontend fe_chat
  maxconn 27495
  bind 127.0.0.1:${WA_CHAT_PORT} accept-proxy ssl crt /etc/haproxy/ssl/proxy.whatsapp.net.pem
  tcp-request connection set-dst ipv4(${EXIT_IP})
  default_backend wa_chat

backend wa_chat
  default-server check inter 60000 observe layer4 send-proxy resolvers dns_ipv4 resolve-prefer ipv4
  server g_whatsapp_net g.whatsapp.net:5222

# ── WhatsApp media ──
frontend fe_media
  maxconn 27495
  bind 127.0.0.1:${WA_MEDIA_PORT} accept-proxy
  tcp-request connection set-dst ipv4(${EXIT_IP})
  default_backend wa_media

backend wa_media
  default-server check inter 60000 observe layer4 resolvers dns_ipv4 resolve-prefer ipv4
  server whatsapp_net whatsapp.net:443
EOF
  haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null || err "Ошибка в конфиге HAProxy"
  ok "HAProxy настроен (слушает только 127.0.0.1)"

  step "5/7" "Telegram MTProto (mtg)"
  install_mtg
  mkdir -p "$STATE_DIR/telegram"
  TG_SECRET=$(mtg generate-secret --hex "$TG_DOMAIN")
  cat > "$STATE_DIR/telegram/config.toml" <<EOF
secret  = "${TG_SECRET}"
bind-to = "127.0.0.1:${TG_PORT}"

[network]
  [network.timeout]
    tcp  = "10s"
    http = "10s"
    idle = "3m"

[stats]
  bind-to = "127.0.0.1:3129"
EOF
  cat > /etc/systemd/system/telegram-proxy.service <<EOF
[Unit]
Description=Telegram MTProto Proxy (mtg)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mtg run ${STATE_DIR}/telegram/config.toml
Restart=always
RestartSec=5
User=nobody
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadOnlyPaths=${STATE_DIR}/telegram/config.toml

[Install]
WantedBy=multi-user.target
EOF
  ok "mtg настроен (слушает только 127.0.0.1)"

  step "6/7" "Firewall"
  open_port "$XRAY_PORT" tcp "$ENTRY_IP"
  ok "TCP ${XRAY_PORT} открыт только для ${ENTRY_IP}; остальные сервисы на loopback"

  step "7/7" "Запуск сервисов"
  systemctl daemon-reload
  systemctl enable xray-cascade telegram-proxy haproxy >/dev/null 2>&1
  systemctl restart haproxy
  systemctl restart telegram-proxy
  systemctl restart xray-cascade
  sleep 3
  systemctl is-active --quiet haproxy        && ok "haproxy запущен"        || warn "haproxy не запустился"
  systemctl is-active --quiet telegram-proxy && ok "telegram-proxy запущен" || warn "telegram-proxy не запустился"
  systemctl is-active --quiet xray-cascade   && ok "xray-cascade запущен"   || warn "xray-cascade не запустился"

  TOKEN=$(printf '%s\n' \
    "EXIT_IP=${EXIT_IP}" \
    "XRAY_PORT=${XRAY_PORT}" \
    "UUID=${UUID}" \
    "REALITY_PUB=${REALITY_PUB}" \
    "SHORT_ID=${SHORT_ID}" \
    "SNI=${SNI}" \
    "WA_DOMAIN=${WA_DOMAIN}" \
    "WA_CHAT_PORT=${WA_CHAT_PORT}" \
    "WA_MEDIA_PORT=${WA_MEDIA_PORT}" \
    "TG_DOMAIN=${TG_DOMAIN}" \
    "TG_PORT=${TG_PORT}" \
    "TG_SECRET=${TG_SECRET}" | base64 -w0)

  umask 077; echo "$TOKEN" > "$STATE_DIR/join-token.txt"; umask 022

  echo ""
  echo -e "${BOLD}${GREEN}  ╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}  ║          Выходной сервер готов                             ║${NC}"
  echo -e "${BOLD}${GREEN}  ╚════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BOLD}  Токен для входного сервера (RU) — скопируйте целиком:${NC}"
  echo ""
  echo -e "${CYAN}${TOKEN}${NC}"
  echo ""
  echo "  Копия: ${STATE_DIR}/join-token.txt"
  echo -e "  Дальше на входном сервере:  ${CYAN}bash install.sh entry${NC}"
  echo ""
}

# ══════════════════════════════════════════════════════════════
#  ВХОДНОЙ СЕРВЕР (РФ) — приём клиентов, отправка в VLESS
# ══════════════════════════════════════════════════════════════
install_entry() {
  echo -e "\n${YELLOW}${BOLD}  Настройка ВХОДНОГО (российского) сервера${NC}\n"
  echo "  Вставьте токен, полученный при установке выходного сервера:"
  ask TOKEN "Токен"
  [[ -n "${TOKEN:-}" ]] || err "Токен не введён"

  local decoded line k v
  decoded=$(echo "$TOKEN" | base64 -d 2>/dev/null) || err "Токен повреждён"
  # разбор по ПЕРВОМУ '=' — значения сами могут оканчиваться на '='
  while IFS= read -r line; do
    k=${line%%=*}; v=${line#*=}
    case "$k" in
      EXIT_IP|XRAY_PORT|UUID|REALITY_PUB|SHORT_ID|SNI|WA_DOMAIN|WA_CHAT_PORT|\
      WA_MEDIA_PORT|TG_DOMAIN|TG_PORT|TG_SECRET) printf -v "$k" '%s' "$v" ;;
    esac
  done <<< "$decoded"
  for req in EXIT_IP XRAY_PORT UUID REALITY_PUB SHORT_ID SNI \
             WA_DOMAIN WA_CHAT_PORT WA_MEDIA_PORT TG_DOMAIN TG_PORT TG_SECRET; do
    [[ -n "${!req:-}" ]] || err "В токене нет поля ${req}"
  done

  echo ""
  echo -e "${BOLD}  ┌──────────────────────────────────────────────┐${NC}"
  printf "  │  %-20s %-21s│\n" "Выход (зарубеж):" "$EXIT_IP:$XRAY_PORT"
  printf "  │  %-20s %-21s│\n" "Маскировка SNI:" "$SNI"
  printf "  │  %-20s %-21s│\n" "WhatsApp:"       "$WA_DOMAIN"
  printf "  │  %-20s %-21s│\n" "  chat / media:" ":$WA_CHAT_PORT / :$WA_MEDIA_PORT"
  printf "  │  %-20s %-21s│\n" "Telegram:"       "$TG_DOMAIN:$TG_PORT"
  echo -e "${BOLD}  └──────────────────────────────────────────────┘${NC}"
  confirm

  step "1/5" "Системные зависимости"
  base_deps; tune_sysctl; ok "Зависимости установлены"

  step "2/5" "Xray — транспорт до выходного сервера"
  install_xray
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  cat > "$XRAY_DIR/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "in-wa-chat",  "listen": "127.0.0.1", "port": ${LP_CHAT},  "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1", "port": ${WA_CHAT_PORT},  "network": "tcp" } },
    { "tag": "in-wa-media", "listen": "127.0.0.1", "port": ${LP_MEDIA}, "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1", "port": ${WA_MEDIA_PORT}, "network": "tcp" } },
    { "tag": "in-tg",       "listen": "127.0.0.1", "port": ${LP_TG},    "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1", "port": ${TG_PORT},        "network": "tcp" } },
    { "tag": "in-probe",    "listen": "127.0.0.1", "port": ${LP_PROBE}, "protocol": "socks",
      "settings": { "udp": false } }
  ],
  "outbounds": [
    {
      "tag": "cascade",
      "protocol": "vless",
      "settings": {
        "vnext": [ {
          "address": "${EXIT_IP}",
          "port": ${XRAY_PORT},
          "users": [ { "id": "${UUID}", "encryption": "none", "flow": "xtls-rprx-vision" } ]
        } ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "${SNI}",
          "fingerprint": "chrome",
          "publicKey": "${REALITY_PUB}",
          "shortId": "${SHORT_ID}",
          "spiderX": "/"
        }
      }
    }
  ],
  "routing": {
    "rules": [ {
      "type": "field",
      "inboundTag": [ "in-wa-chat", "in-wa-media", "in-tg", "in-probe" ],
      "outboundTag": "cascade"
    } ]
  }
}
EOF
  chmod 600 "$XRAY_DIR/config.json"
  xray run -test -config "$XRAY_DIR/config.json" >/dev/null 2>&1 || err "Конфиг Xray невалиден"
  systemctl daemon-reload
  systemctl enable xray-cascade >/dev/null 2>&1
  systemctl restart xray-cascade
  sleep 2
  systemctl is-active --quiet xray-cascade && ok "xray-cascade запущен" || warn "xray-cascade не запустился"

  step "3/5" "HAProxy — приём клиентов"
  cat > /etc/haproxy/haproxy.cfg <<EOF
global
  log /dev/log local0
  maxconn 27500
  spread-checks 5
  stats socket /run/haproxy/admin.sock mode 660 level admin
  chroot /var/lib/haproxy
  user haproxy
  group haproxy
  daemon

defaults
  mode tcp
  timeout client-fin 1s
  timeout server-fin 1s
  timeout connect 5s
  timeout client 200s
  timeout server 200s

listen stats
  bind 127.0.0.1:8199
  mode http
  stats uri /
  stats refresh 10s

# PROXY-протокол несётся сквозь VLESS и разбирается уже на выходном сервере,
# поэтому WhatsApp видит реальный IP клиента, а не адрес каскада.
frontend fe_wa_chat
  maxconn 27495
  bind ipv4@*:${WA_CHAT_PORT}
  default_backend be_wa_chat

backend be_wa_chat
  server cascade 127.0.0.1:${LP_CHAT} send-proxy check inter 30s

frontend fe_wa_media
  maxconn 27495
  bind ipv4@*:${WA_MEDIA_PORT}
  default_backend be_wa_media

backend be_wa_media
  server cascade 127.0.0.1:${LP_MEDIA} send-proxy check inter 30s

# mtg не понимает PROXY-протокол — отдаём поток как есть
frontend fe_telegram
  maxconn 27495
  bind ipv4@*:${TG_PORT}
  default_backend be_telegram

backend be_telegram
  server cascade 127.0.0.1:${LP_TG} check inter 30s
EOF
  haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null || err "Ошибка в конфиге HAProxy"
  systemctl enable haproxy >/dev/null 2>&1
  systemctl restart haproxy
  ok "HAProxy настроен"

  step "4/5" "Firewall"
  for p in "$WA_CHAT_PORT" "$WA_MEDIA_PORT" "$TG_PORT"; do open_port "$p" tcp; done
  ok "Порты ${WA_CHAT_PORT}, ${WA_MEDIA_PORT}, ${TG_PORT} открыты"

  step "5/5" "Проверка каскада"
  sleep 3
  local WA_OK=false TG_OK=false CASCADE_IP=""
  nc -z 127.0.0.1 "$WA_CHAT_PORT" -w5 2>/dev/null && WA_OK=true
  nc -z 127.0.0.1 "$TG_PORT"      -w5 2>/dev/null && TG_OK=true
  # сквозная проверка: наружу через каскад должен смотреть IP выходного сервера
  CASCADE_IP=$(curl -s --max-time 15 --socks5-hostname 127.0.0.1:${LP_PROBE} https://api.ipify.org || true)

  cat > "$STATE_DIR/info.txt" <<EOF
WhatsApp:  ${WA_DOMAIN}  chat ${WA_CHAT_PORT} / media ${WA_MEDIA_PORT}
Telegram:  ${TG_DOMAIN}:${TG_PORT}
Secret:    ${TG_SECRET}
Ссылка:    https://t.me/proxy?server=${TG_DOMAIN}&port=${TG_PORT}&secret=${TG_SECRET}
Выход:     ${EXIT_IP}:${XRAY_PORT} (VLESS+REALITY, SNI ${SNI})
EOF

  echo ""
  echo -e "${BOLD}${GREEN}  ╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}  ║                     Каскад запущен                         ║${NC}"
  echo -e "${BOLD}${GREEN}  ╚════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  if [[ "$CASCADE_IP" == "$EXIT_IP" ]]; then
    ok "Каскад работает: внешний трафик выходит с ${CASCADE_IP}"
  elif [[ -n "$CASCADE_IP" ]]; then
    warn "Трафик выходит с ${CASCADE_IP}, а ожидался ${EXIT_IP}"
  else
    warn "Выходной сервер недоступен через VLESS (journalctl -u xray-cascade -n 50)"
  fi
  echo ""
  echo -e "${BOLD}  ── WhatsApp ──────────────────────────────────────${NC}"
  $WA_OK && ok "порт слушается" || warn "порт не слушается"
  echo "  Настройки → Хранилище и данные → Прокси"
  echo -e "  Адрес: ${CYAN}${WA_DOMAIN}${NC}   Chat: ${CYAN}${WA_CHAT_PORT}${NC}   Media: ${CYAN}${WA_MEDIA_PORT}${NC}"
  echo ""
  echo -e "${BOLD}  ── Telegram ──────────────────────────────────────${NC}"
  $TG_OK && ok "порт слушается" || warn "порт не слушается"
  echo -e "  ${CYAN}https://t.me/proxy?server=${TG_DOMAIN}&port=${TG_PORT}&secret=${TG_SECRET}${NC}"
  echo ""
  echo "  Памятка: ${STATE_DIR}/info.txt"
  echo ""
}

# ══════════════════════════════════════════════════════════════
clear
echo -e "${BLUE}${BOLD}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║   Messenger Proxy — каскадный прокси         ║"
echo "  ║      WhatsApp  +  Telegram MTProto           ║"
echo "  ║      Транспорт: VLESS + REALITY              ║"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${NC}"

ROLE="${1:-}"
if [[ -z "$ROLE" ]]; then
  echo "  Какую роль ставим на этот сервер?"
  echo ""
  echo -e "    ${BOLD}1${NC}) ${CYAN}exit${NC}  — выходной, зарубежный. Ставится ПЕРВЫМ."
  echo -e "    ${BOLD}2${NC}) ${CYAN}entry${NC} — входной, российский. На него смотрят домены."
  echo ""
  read -rp "  Выбор [1/2]: " a
  case "$a" in 1) ROLE=exit ;; 2) ROLE=entry ;; *) err "Неверный выбор" ;; esac
fi

case "$ROLE" in
  exit)  install_exit  ;;
  entry) install_entry ;;
  *)     err "Использование: bash install.sh [exit|entry]" ;;
esac
