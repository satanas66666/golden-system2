#!/usr/bin/env bash
set -euo pipefail

CFG=/etc/golden-web/config.json
CERT_DST=/etc/golden-web/tls.crt
KEY_DST=/etc/golden-web/tls.key
CERT_NAME=golden-web-ip
DEPLOY=/usr/local/sbin/golden-web-cert-deploy
CRON=/etc/cron.d/golden-web-cert-renew

[[ $(id -u) -eq 0 ]] || { echo "ERROR: ejecuta como root."; exit 1; }
[[ -f "$CFG" ]] || { echo "ERROR: Golden Web Panel no está instalado."; exit 1; }

PUBIP=$(curl -4fsS --connect-timeout 3 --max-time 8 https://api.ipify.org 2>/dev/null || true)
if [[ -z "$PUBIP" ]]; then
  PUBIP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
[[ "$PUBIP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "ERROR: no pude detectar una IPv4 pública válida."; exit 1; }

echo "============================================================"
echo " GOLDEN WEB - HTTPS PUBLICO PARA IP (REV27.3)"
echo " IP detectada: $PUBIP"
echo "============================================================"

echo "[1/6] Verificando TCP 80 para validación ACME..."
if command -v ss >/dev/null 2>&1 && ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)80$'; then
  echo "ERROR: TCP 80 está ocupado. Let's Encrypt necesita validar esta IP periódicamente."
  echo "Libera TCP 80 en la VPS del GENERADOR o usa un dominio/certificado alternativo."
  exit 1
fi

version_ge(){
  # version_ge actual minima
  [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

get_certbot_version(){
  command -v certbot >/dev/null 2>&1 || return 1
  certbot --version 2>/dev/null | awk '{print $2}' | head -n1
}

ensure_certbot(){
  local v=""
  v=$(get_certbot_version || true)
  if [[ -n "$v" ]] && version_ge "$v" "5.4.0"; then
    echo "[2/6] Certbot $v OK"
    return 0
  fi
  echo "[2/6] Instalando Certbot moderno (>=5.4) en entorno aislado..."
  command -v python3 >/dev/null 2>&1 || { echo "ERROR: Python 3 es necesario para Certbot moderno."; exit 1; }
  local py
  py=$(python3 - <<'PY'
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}")
PY
)
  if ! version_ge "$py" "3.10"; then
    echo "ERROR: esta VPS tiene Python $py. Certbot moderno requiere Python 3.10+."
    echo "Puedes usar un dominio con otro cliente ACME o mantener temporalmente el certificado autofirmado."
    exit 1
  fi
  if ! python3 -m venv --help >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=180 update -y >/dev/null
    apt-get -o DPkg::Lock::Timeout=180 install -y python3-venv >/dev/null
  fi
  rm -rf /opt/golden-certbot
  python3 -m venv /opt/golden-certbot
  /opt/golden-certbot/bin/pip -q install --upgrade pip
  /opt/golden-certbot/bin/pip -q install 'certbot>=5.4,<6'
  ln -sf /opt/golden-certbot/bin/certbot /usr/local/bin/certbot
  v=$(get_certbot_version || true)
  [[ -n "$v" ]] && version_ge "$v" "5.4.0" || { echo "ERROR: no pude instalar Certbot >=5.4."; exit 1; }
  echo "      Certbot $v instalado."
}

ensure_certbot

echo "[3/6] Solicitando certificado público Let's Encrypt para $PUBIP..."
# IP certificates are short-lived and require the shortlived profile.
certbot certonly \
  --non-interactive \
  --agree-tos \
  --register-unsafely-without-email \
  --standalone \
  --preferred-challenges http-01 \
  --preferred-profile shortlived \
  --ip-address "$PUBIP" \
  --cert-name "$CERT_NAME"

LIVE="/etc/letsencrypt/live/$CERT_NAME"
[[ -s "$LIVE/fullchain.pem" && -s "$LIVE/privkey.pem" ]] || { echo "ERROR: Certbot no dejó los archivos esperados en $LIVE"; exit 1; }

echo "[4/6] Instalando certificado en Golden Web..."
cat > "$DEPLOY" <<'DEP'
#!/usr/bin/env bash
set -euo pipefail
LIVE=/etc/letsencrypt/live/golden-web-ip
install -m 0644 -o root -g golden-web "$LIVE/fullchain.pem" /etc/golden-web/tls.crt
install -m 0640 -o root -g golden-web "$LIVE/privkey.pem" /etc/golden-web/tls.key
if command -v systemctl >/dev/null 2>&1 && [[ -f /etc/systemd/system/golden-web.service ]]; then
  systemctl restart golden-web
else
  service golden-web restart || /etc/init.d/golden-web restart
fi
DEP
chmod 0750 "$DEPLOY"
"$DEPLOY"

echo "[5/6] Configurando renovación automática..."
cat > "$CRON" <<EOF
# Golden Web Panel - certificados IP Let's Encrypt son de corta duración.
17 */6 * * * root /usr/local/bin/certbot renew --quiet --deploy-hook $DEPLOY
EOF
chmod 0644 "$CRON"

# Si systemd incluye timer de certbot también puede coexistir; Certbot evita renovar si no corresponde.

echo "[6/6] Verificando HTTPS del panel..."
PORT=$(sed -n 's/.*"listen"[[:space:]]*:[[:space:]]*"[^"]*:\([0-9][0-9]*\)".*/\1/p' "$CFG" | head -n1)
PORT=${PORT:-8443}
sleep 2
if command -v curl >/dev/null 2>&1; then
  curl -fsS --connect-timeout 4 --max-time 10 "https://${PUBIP}:${PORT}/api/health" >/dev/null || {
    echo "ADVERTENCIA: el certificado se instaló, pero el health check externo falló."
    echo "Comprueba firewall TCP $PORT y: systemctl status golden-web"
    exit 1
  }
fi

echo
echo "============================================================"
echo " HTTPS CONFIABLE ACTIVADO"
echo " Panel: https://${PUBIP}:${PORT}"
echo " El navegador ya no debería mostrar CERT_AUTHORITY_INVALID."
echo " Renovación automática: cada 6 horas se comprueba si toca renovar."
echo " IMPORTANTE: mantén TCP 80 accesible para futuras validaciones ACME."
echo "============================================================"
