#!/usr/bin/env bash
set -euo pipefail
umask 077

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG_DIR=/etc/golden-web
STATE_DIR=/var/lib/golden-web
LOG=/var/log/golden-web-audit.log
BIN=/usr/local/bin/golden-web
BRIDGE=/usr/local/sbin/golden-web-bridge
SUDOERS=/etc/sudoers.d/golden-web
SERVICE=/etc/systemd/system/golden-web.service
INIT=/etc/init.d/golden-web

[[ $(id -u) -eq 0 ]] || { echo "ERROR: ejecuta como root."; exit 1; }
[[ -x /bin/gerar || -x /usr/bin/gerar.sh ]] || { echo "ERROR: primero instala Golden ADM PRO (gerar)."; exit 1; }
[[ -d /etc/http-shell && -d /etc/SCRIPT ]] || { echo "ERROR: no encontré la estructura estable del generador (/etc/http-shell y /etc/SCRIPT)."; exit 1; }

echo "============================================================"
echo " GOLDEN ADM PRO - WEB CONTROL CENTER V1 (REV27)"
echo " Complemento web: NO reemplaza ni modifica /bin/gerar"
echo "============================================================"

apt_safe(){
  if command -v timeout >/dev/null 2>&1; then timeout 300 apt-get -o DPkg::Lock::Timeout=180 "$@"; else apt-get -o DPkg::Lock::Timeout=180 "$@"; fi
}
need_pkg(){
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "Instalando dependencia: $2"
  export DEBIAN_FRONTEND=noninteractive
  apt_safe update -y >/dev/null 2>&1 || { echo "ERROR: APT no pudo actualizar repositorios."; exit 1; }
  apt_safe install -y "$2" >/dev/null 2>&1 || { echo "ERROR: no se pudo instalar $2."; exit 1; }
}
need_pkg openssl openssl
need_pkg sudo sudo

arch=$(uname -m)
case "$arch" in
  x86_64|amd64) SRC_BIN="$BASE_DIR/bin/golden-web-linux-amd64"; SRC_BRIDGE="$BASE_DIR/bin/golden-web-bridge-linux-amd64" ;;
  aarch64|arm64) SRC_BIN="$BASE_DIR/bin/golden-web-linux-arm64"; SRC_BRIDGE="$BASE_DIR/bin/golden-web-bridge-linux-arm64" ;;
  i386|i486|i586|i686) SRC_BIN="$BASE_DIR/bin/golden-web-linux-386"; SRC_BRIDGE="$BASE_DIR/bin/golden-web-bridge-linux-386" ;;
  *) echo "ERROR: arquitectura no soportada por el panel: $arch"; exit 1 ;;
esac
[[ -x "$SRC_BIN" ]] || { echo "ERROR: falta binario $SRC_BIN"; exit 1; }
[[ -x "$SRC_BRIDGE" ]] || { echo "ERROR: falta binario $SRC_BRIDGE"; exit 1; }

read -r -p "Usuario administrador web [admin]: " WEB_USER
WEB_USER=${WEB_USER:-admin}
[[ "$WEB_USER" =~ ^[A-Za-z0-9._-]{3,32}$ ]] || { echo "ERROR: usuario inválido (3-32: letras, números, . _ -)."; exit 1; }
while :; do
  read -r -s -p "Contraseña web (mínimo 8 caracteres): " WEB_PASS; echo
  [[ ${#WEB_PASS} -ge 8 ]] || { echo "Debe tener al menos 8 caracteres."; continue; }
  read -r -s -p "Repite la contraseña: " WEB_PASS2; echo
  [[ "$WEB_PASS" == "$WEB_PASS2" ]] || { echo "Las contraseñas no coinciden."; continue; }
  break
done

read -r -p "Puerto HTTPS del panel [8443]: " WEB_PORT
WEB_PORT=${WEB_PORT:-8443}
[[ "$WEB_PORT" =~ ^[0-9]+$ ]] && (( WEB_PORT >= 1024 && WEB_PORT <= 65535 )) || { echo "ERROR: usa un puerto 1024-65535."; exit 1; }
case "$WEB_PORT" in 80|81|8888) echo "ERROR: $WEB_PORT está reservado por Golden/ProxyGo/servidor de keys. Usa otro puerto."; exit 1;; esac
if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${WEB_PORT}$"; then
  echo "ERROR: TCP $WEB_PORT ya está ocupado."; exit 1
fi

if ! getent group golden-web >/dev/null 2>&1; then groupadd --system golden-web; fi
if ! id golden-web >/dev/null 2>&1; then
  NOLOGIN=$(command -v nologin 2>/dev/null || echo /usr/sbin/nologin)
  useradd --system --gid golden-web --home-dir "$STATE_DIR" --create-home --shell "$NOLOGIN" golden-web
fi
mkdir -p "$CFG_DIR" "$STATE_DIR"
install -m 0755 "$SRC_BIN" "$BIN"
install -m 0750 -o root -g golden-web "$SRC_BRIDGE" "$BRIDGE"

HASH=$("$BIN" --hash-password "$WEB_PASS")
unset WEB_PASS WEB_PASS2

CERT="$CFG_DIR/tls.crt"; KEY="$CFG_DIR/tls.key"
if [[ ! -s "$CERT" || ! -s "$KEY" ]]; then
  PUBIP=$(curl -4fsS --connect-timeout 2 --max-time 4 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true)
  CN=${PUBIP:-Golden-ADM-PRO}
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 825 \
    -keyout "$KEY" -out "$CERT" -subj "/CN=$CN/O=Golden ADM PRO" >/dev/null 2>&1
fi
chown root:golden-web "$CERT" "$KEY"
chmod 0644 "$CERT"; chmod 0640 "$KEY"

cat > "$CFG_DIR/config.json" <<EOF
{
  "username": "$WEB_USER",
  "password_hash": "$HASH",
  "listen": "0.0.0.0:$WEB_PORT",
  "tls_cert": "$CERT",
  "tls_key": "$KEY",
  "bridge_path": "$BRIDGE",
  "session_minutes": 60
}
EOF
chown root:golden-web "$CFG_DIR/config.json"
chmod 0640 "$CFG_DIR/config.json"

touch "$LOG"; chown golden-web:golden-web "$LOG"; chmod 0640 "$LOG"

cat > "$SUDOERS" <<EOF
# Golden Web Panel: solo permite el puente root restringido.
Defaults:golden-web !requiretty
golden-web ALL=(root) NOPASSWD: $BRIDGE *
EOF
chmod 0440 "$SUDOERS"
visudo -cf "$SUDOERS" >/dev/null || { rm -f "$SUDOERS"; echo "ERROR: sudoers inválido."; exit 1; }

cat > "$SERVICE" <<EOF
[Unit]
Description=Golden ADM PRO Web Control Center
After=network-online.target golden-http.service
Wants=network-online.target

[Service]
Type=simple
User=golden-web
Group=golden-web
ExecStart=$BIN --config $CFG_DIR/config.json
Restart=on-failure
RestartSec=3
PrivateTmp=true
ProtectHome=true
UMask=0077

[Install]
WantedBy=multi-user.target
EOF

cat > "$INIT" <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          golden-web
# Required-Start:    \$network
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Golden ADM PRO Web Panel
### END INIT INFO
DAEMON=$BIN
PIDFILE=/var/run/golden-web.pid
CFG=$CFG_DIR/config.json
case "\$1" in
 start)
   start-stop-daemon --start --quiet --background --make-pidfile --pidfile \$PIDFILE --chuid golden-web:golden-web --exec \$DAEMON -- --config \$CFG
   ;;
 stop)
   start-stop-daemon --stop --quiet --retry=TERM/10/KILL/5 --pidfile \$PIDFILE || true
   rm -f \$PIDFILE
   ;;
 restart) \$0 stop; sleep 1; \$0 start ;;
 status) if [ -f \$PIDFILE ] && kill -0 \$(cat \$PIDFILE) 2>/dev/null; then echo ONLINE; else echo OFF; exit 3; fi ;;
 *) echo "Uso: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
exit 0
EOF
chmod 0755 "$INIT"

"$BIN" --self-test --config "$CFG_DIR/config.json"

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  systemctl daemon-reload
  systemctl enable --now golden-web.service
  sleep 1
  systemctl is-active --quiet golden-web.service || { systemctl --no-pager -l status golden-web.service || true; exit 1; }
else
  update-rc.d golden-web defaults >/dev/null 2>&1 || true
  "$INIT" restart
  sleep 1
fi

IP=$(curl -4fsS --connect-timeout 2 --max-time 4 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true)
echo
echo "============================================================"
echo " PANEL WEB INSTALADO CORRECTAMENTE"
echo "============================================================"
echo " SSH tradicional : gerar"
echo " Panel Web HTTPS : https://${IP:-IP-DE-LA-VPS}:$WEB_PORT"
echo " Usuario          : $WEB_USER"
echo " Puerto keys      : 8888 (sin cambios)"
echo " Apache Golden    : 81   (sin cambios)"
echo " Puerto 80        : sin tocar"
echo "============================================================"
echo "IMPORTANTE: el certificado inicial es autofirmado; el navegador"
echo "puede mostrar una advertencia la primera vez. Puedes aceptar la"
echo "excepción o después instalar un certificado válido con dominio."
echo "Si tu proveedor/firewall bloquea $WEB_PORT, abre TCP $WEB_PORT."
echo "NO es necesario abrir ni cambiar 80/81/8888 para el panel."
