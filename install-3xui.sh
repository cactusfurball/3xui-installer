#!/usr/bin/env bash
set -euo pipefail

# ===== Helper =====
log() { echo -e "\e[1;32m[+]\e[0m 🌵 $*"; }
warn(){ echo -e "\e[1;33m[!]\e[0m ⚠️ $*"; }
err() { echo -e "\e[1;31m[x]\e[0m ❌ $*" >&2; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "Запусти скрипт от root (sudo -i)."
    exit 1
  fi
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  cp -a "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)"
}

comment_conflicting_directives() {
  local d="/etc/ssh/sshd_config.d"
  [[ -d "$d" ]] || return 0
  for f in "$d"/*.conf; do
    [[ -e "$f" ]] || continue
    backup_file "$f"
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication)[[:space:]].*$/# disabled by installer: &/I' "$f"
  done
}

# ===== Start =====
require_root
log "Установка зависимостей и обновление системы…"
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y
apt install -y curl ufw sudo openssl jq lsof

# --- создаём юзера ---
read -rp "Введите имя НОВОГО пользователя (без пробелов): " NEWUSER
if ! id "$NEWUSER" &>/dev/null; then
  adduser --disabled-password --gecos "" "$NEWUSER"
  usermod -aG sudo "$NEWUSER"
fi

# --- ключи ---
echo
echo "1) Вставить свой публичный ключ"
echo "2) Сгенерировать новый (ssh-ed25519, с passphrase по желанию)"
read -rp "Выбор [1/2]: " KEYMODE
mkdir -p "/home/$NEWUSER/.ssh"
chmod 700 "/home/$NEWUSER/.ssh"

if [[ "${KEYMODE:-1}" == "2" ]]; then
  KEYDIR="/root/generated-keys"
  mkdir -p "$KEYDIR"
  ssh-keygen -t ed25519 -f "$KEYDIR/${NEWUSER}_id_ed25519" -C "${NEWUSER}@$(hostname)"  # спросит passphrase
  cp "$KEYDIR/${NEWUSER}_id_ed25519.pub" "/home/$NEWUSER/.ssh/authorized_keys"
  warn "Скачай приватный ключ: $KEYDIR/${NEWUSER}_id_ed25519 и удали с сервера!"
else
  read -rp "Вставь публичный ключ: " SSHKEY
  echo "$SSHKEY" > "/home/$NEWUSER/.ssh/authorized_keys"
fi
chmod 600 "/home/$NEWUSER/.ssh/authorized_keys"
chown -R "$NEWUSER:$NEWUSER" "/home/$NEWUSER/.ssh"

# --- ssh порт ---
read -rp "Новый SSH порт (например 5569): " NEWPORT
backup_file /etc/ssh/sshd_config
comment_conflicting_directives

apply_sshd_directive() {
  local key="$1" val="$2"
  if grep -qiE "^[#[:space:]]*${key}[[:space:]]" /etc/ssh/sshd_config; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]].*$|${key} ${val}|I" /etc/ssh/sshd_config
  else
    echo "${key} ${val}" >> /etc/ssh/sshd_config
  fi
}
apply_sshd_directive "Port" "$NEWPORT"
apply_sshd_directive "PermitRootLogin" "no"
apply_sshd_directive "PasswordAuthentication" "no"
apply_sshd_directive "PubkeyAuthentication" "yes"

ufw default deny incoming
ufw default allow outgoing
ufw allow "${NEWPORT}/tcp"
ufw allow 443/tcp
ufw --force enable

sshd -t && systemctl restart sshd

# --- установка 3x-ui ---
log "Устанавливаю 3x-ui… 🌵"
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

# --- ssl ---
CERTDIR="/root/3xui-selfsigned"
mkdir -p "$CERTDIR"
IPV4="$(hostname -I | awk '{print $1}')"
CN="${IPV4:-$(hostname)}"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$CERTDIR/selfsigned.key" -out "$CERTDIR/selfsigned.crt" \
  -subj "/CN=${CN}"
chmod 600 "$CERTDIR/selfsigned.key"
chmod 644 "$CERTDIR/selfsigned.crt"

# --- патчим конфиг 3x-ui ---
CONFIG="/etc/x-ui/x-ui.json"
if [[ -f "$CONFIG" ]]; then
  backup_file "$CONFIG"
  jq ".webCertFile=\"$CERTDIR/selfsigned.crt\" | .webKeyFile=\"$CERTDIR/selfsigned.key\"" "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
  systemctl restart x-ui
fi

# --- открываем порт панели на время ---
PANEL_PORT=$(jq -r '.webPort // 54321' "$CONFIG" 2>/dev/null || echo "54321")
MYIP=$(curl -s https://api.ipify.org || echo "0.0.0.0")
ufw allow from "$MYIP" to any port "$PANEL_PORT" proto tcp

# --- bbr ---
backup_file /etc/sysctl.conf
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p >/dev/null

# --- вывод ---
IP_SHOW="${IPV4:-<IP>}"
cat <<EOF

========================================
✅ Установка завершена! 🌵🌵🌵

▶ SSH:
   ssh -p ${NEWPORT} ${NEWUSER}@${IP_SHOW} -i <ключ>

▶ Панель 3x-ui:
   https://${IP_SHOW}:${PANEL_PORT}
   (логин/пароль см. в "x-ui" → пункт 10)

   SSL уже подключён:
   crt: $CERTDIR/selfsigned.crt
   key: $CERTDIR/selfsigned.key

   ⚠️ Порт панели ${PANEL_PORT} открыт ВРЕМЕННО для твоего IP: ${MYIP}
   После настройки панели закрой доступ:
      ufw delete allow from ${MYIP} to any port ${PANEL_PORT}

▶ Firewall:
   SSH (${NEWPORT}/tcp), VPN (443/tcp), Панель (временно ${PANEL_PORT}/tcp для ${MYIP})

▶ Совет:
   - После входа в панель сбрось дефолтные настройки (п.6, п.7).
   - Настрой VLESS/REALITY на порту 443.
   - В панели добавь правила маршрутизации для .ru-доменов (см. гайд).
   - Используй SSH-туннель для доступа к панели в будущем.
========================================

🌵🌵🌵 All done! Dancing cactus celebrates your VPN setup! 🌵🌵🌵

        \\   ^__^
         \\  (oo)\_______
            (__)\\       )\\/\\
                ||----w |
                ||     ||

EOF
