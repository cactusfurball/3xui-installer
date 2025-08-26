#!/usr/bin/env bash
set -euo pipefail

# ===== Helpers =====
log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
err()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "Запусти скрипт от root (sudo -i)."; exit 1
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
    sed -i -E \
      's/^[[:space:]]*#?[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|MaxAuthTries|LoginGraceTime)[[:space:]].*$/# disabled by installer: &/I' \
      "$f"
  done
}

apply_sshd_directive() {
  local key="$1" val="$2"
  if grep -qiE "^[#[:space:]]*${key}[[:space:]]" /etc/ssh/sshd_config; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]].*$|${key} ${val}|I" /etc/ssh/sshd_config
  else
    echo "${key} ${val}" >> /etc/ssh/sshd_config
  fi
}

detect_ipv4() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "${ip:-}" ]] && echo "$ip" || curl -s https://api.ipify.org || echo "<IP>"
}

# ===== Start =====
require_root
export DEBIAN_FRONTEND=noninteractive

log "Обновляю систему и ставлю зависимости…"
apt update
apt -y upgrade
apt -y install curl ufw sudo openssl jq lsof

# --- создаём юзера (с паролем!) ---
read -rp "Введите ИМЯ НОВОГО пользователя (без пробелов): " NEWUSER
if id "$NEWUSER" &>/dev/null; then
  warn "Пользователь $NEWUSER уже существует. Можно обновить пароль."
else
  adduser --gecos "" "$NEWUSER"   # adduser интерактивен; попросит пароль сам
fi

# если adduser не спросил (на некоторых образах), спросим сами
if [[ -z "$(getent shadow "$NEWUSER" | cut -d: -f2)" || "$(getent shadow "$NEWUSER" | cut -d: -f2)" == "!" ]]; then
  while true; do
    read -srp "Задайте пароль для ${NEWUSER}: " PW1; echo
    read -srp "Повторите пароль: " PW2; echo
    [[ "$PW1" == "$PW2" && ${#PW1} -ge 8 ]] && break
    warn "Пароли не совпали или короче 8 символов. Попробуйте ещё раз."
  done
  echo "${NEWUSER}:${PW1}" | chpasswd
  unset PW1 PW2
fi

usermod -aG sudo "$NEWUSER"

# --- ключи SSH ---
echo
echo "1) Вставить свой публичный ключ"
echo "2) Сгенерировать новый (ed25519, можно задать passphrase)"
read -rp "Выбор [1/2]: " KEYMODE
install -d -m 700 "/home/$NEWUSER/.ssh"

if [[ "${KEYMODE:-1}" == "2" ]]; then
  KEYDIR="/root/generated-keys"
  mkdir -p "$KEYDIR"
  ssh-keygen -t ed25519 -f "$KEYDIR/${NEWUSER}_id_ed25519" -C "${NEWUSER}@$(hostname)"
  install -m 600 "$KEYDIR/${NEWUSER}_id_ed25519.pub" "/home/$NEWUSER/.ssh/authorized_keys"
  warn "Скачайте приватный ключ и удалите его с сервера: $KEYDIR/${NEWUSER}_id_ed25519"
else
  read -rp "Вставьте публичный ключ: " SSHKEY
  printf '%s\n' "$SSHKEY" > "/home/$NEWUSER/.ssh/authorized_keys"
  chmod 600 "/home/$NEWUSER/.ssh/authorized_keys"
fi
chown -R "$NEWUSER:$NEWUSER" "/home/$NEWUSER/.ssh"

# --- Настройка SSH (порт и харденинг) ---
read -rp "Новый SSH порт (например 5569): " NEWPORT
[[ "$NEWPORT" =~ ^[0-9]+$ ]] || { err "Неверный порт"; exit 1; }

backup_file /etc/ssh/sshd_config
comment_conflicting_directives

apply_sshd_directive "Port" "$NEWPORT"
apply_sshd_directive "PermitRootLogin" "no"
apply_sshd_directive "PasswordAuthentication" "no"
apply_sshd_directive "PubkeyAuthentication" "yes"
apply_sshd_directive "MaxAuthTries" "3"
apply_sshd_directive "LoginGraceTime" "20s"
apply_sshd_directive "ClientAliveInterval" "300"
apply_sshd_directive "ClientAliveCountMax" "2"

# --- Firewall (UFW) ---
log "Настраиваю UFW…"
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming
ufw default allow outgoing

# не отрезать себя во время смены порта: временно оставим 22/tcp
ufw allow 22/tcp
ufw limit "${NEWPORT}/tcp"
ufw allow 443/tcp

# применим и включим заранее, до рестарта sshd
ufw --force enable

# --- Перезапуск SSHD с проверкой синтаксиса ---
sshd -t
systemctl restart sshd

# --- Установка 3x-ui ---
log "Устанавливаю 3x-ui…"
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

# --- Генерация самоподписанных SSL (Не прописываем в панель!) ---
CERTDIR="/etc/ssl/3xui"
mkdir -p "$CERTDIR"
IPV4="$(detect_ipv4)"
CN="${IPV4:-$(hostname)}"

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$CERTDIR/selfsigned.key" \
  -out   "$CERTDIR/selfsigned.crt" \
  -subj "/CN=${CN}"

chmod 600 "$CERTDIR/selfsigned.key"
chmod 644 "$CERTDIR/selfsigned.crt"

# НИЧЕГО не меняем в /etc/x-ui/x-ui.json — только сообщаем пути.

# --- Включение BBR (через sysctl.d) ---
CONF_BBR="/etc/sysctl.d/99-bbr.conf"
backup_file "$CONF_BBR" || true
cat > "$CONF_BBR" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null

# --- Вывод итогов и пост-шаги ---
IP_SHOW="${IPV4:-<IP>}"
cat <<EOF

========================================
✅ Готово! 3x-ui установлена, сервер ужесточён.

▶ Доступ по SSH:
   ssh -p ${NEWPORT} ${NEWUSER}@${IP_SHOW} -i <путь_к_приватному_ключу>

   ВАЖНО: Порт 22/tcp сейчас временно открыт, чтобы не потерять доступ.
   Если вход по новому порту работает — закройте 22:
       sudo ufw delete allow 22/tcp

▶ Панель 3x-ui:
   http://${IP_SHOW}:<порт>   (узнать через "x-ui", пункт 10)
   Данные для входа: команда "x-ui" → пункт 10

▶ SSL (самоподписанные, НЕ прописаны в панели — добавьте сами):
   Путь к файлу публичного ключа сертификата панели:
       ${CERTDIR}/selfsigned.crt
   Путь к файлу приватного ключа сертификата панели:
       ${CERTDIR}/selfsigned.key

   В панели: Настройки → Сертификаты → укажите пути выше и сохраните.

▶ Firewall (UFW):
   - SSH (limit)    : ${NEWPORT}/tcp
   - VPN/Xray       : 443/tcp
   - Порт панели выбирается случайно.
   Узнть порт:  x-ui (пункт 10)
   Oткрыть доступ извне:
      sudo ufw allow <порт>
    Закрыть:
    sudo ufw deny <порт>
   ⚠️ Лучше держать панель закрытой и использовать SSH-туннель.
   - Временно открыт: 22/tcp (удалите после проверки)

▶ Рекомендации по безопасности:
   1) Проверьте вход по SSH новым пользователем и новому порту.
   2) Удалите правило 22/tcp:  ufw delete allow 22/tcp
   3) В x-ui выполните сброс стандартных настроек (пункты 6 и 7 в меню).
   4) Настройте VLESS/REALITY на 443 и клиентские маршруты.
   5) Делайте регулярные обновления: apt update && apt upgrade -y

========================================

🌵🌵🌵 All done! Dancing cactus celebrates your VPN setup! 🌵🌵🌵

        \\   ^__^
         \\  (oo)\_______
            (__)\\       )\\/\\
                ||----w |
                ||     ||
                
EOF
