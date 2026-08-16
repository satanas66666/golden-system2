#!/usr/bin/env bash
set -euo pipefail
REPO="${GOLDEN_REPO:-https://raw.githubusercontent.com/satanas66666/golden-system2/main}"
BASE_URL="$REPO/webpanel"
BIN=/usr/local/bin/golden-web
CFG=/etc/golden-web/config.json
[[ $(id -u) -eq 0 ]] || { echo "ERROR: ejecuta como root."; exit 1; }
[[ -f "$CFG" ]] || { echo "ERROR: Golden Web Panel no está instalado ($CFG)."; exit 1; }
arch=$(uname -m)
case "$arch" in
 x86_64|amd64) A=amd64 ;;
 aarch64|arm64) A=arm64 ;;
 i386|i486|i586|i686) A=386 ;;
 *) echo "ERROR: arquitectura no soportada: $arch"; exit 1 ;;
esac
TMP=$(mktemp /tmp/golden-web.XXXXXX)
trap 'rm -f "$TMP"' EXIT
fetch(){
 local url="$1" out="$2"
 if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 --connect-timeout 10 --max-time 180 "$url" -o "$out"
 elif command -v wget >/dev/null 2>&1; then wget --timeout=30 --tries=3 -O "$out" "$url"
 else echo "ERROR: necesitas curl o wget."; exit 1; fi
}
echo "Actualizando SOLO Golden Web Panel a REV27.3 ($A)..."
fetch "$BASE_URL/bin/golden-web-linux-$A" "$TMP"
chmod +x "$TMP"
"$TMP" --self-test --config "$CFG" >/dev/null
BACKUP="${BIN}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$BIN" "$BACKUP" 2>/dev/null || true
install -m 0755 "$TMP" "$BIN"
# Añadir remember_days a configuraciones REV27/27.1/27.2 sin cambiar usuario, hash, TLS ni puerto.
if ! grep -q '"remember_days"' "$CFG"; then
  python3 - "$CFG" <<'PYC' 2>/dev/null || true
import json,sys
p=sys.argv[1]
with open(p,encoding='utf-8') as f: d=json.load(f)
d['remember_days']=30
with open(p,'w',encoding='utf-8') as f: json.dump(d,f,indent=2)
f.write('\n')
PYC
  chown root:golden-web "$CFG" 2>/dev/null || true
  chmod 0640 "$CFG" 2>/dev/null || true
fi
if command -v systemctl >/dev/null 2>&1 && [[ -f /etc/systemd/system/golden-web.service ]]; then
 systemctl restart golden-web
 sleep 1
 if ! systemctl is-active --quiet golden-web; then
   echo "ERROR: el panel no inició. Restaurando binario anterior..."
   [[ -f "$BACKUP" ]] && cp -a "$BACKUP" "$BIN"
   systemctl restart golden-web || true
   systemctl status golden-web --no-pager -l || true
   exit 1
 fi
else
 service golden-web restart || /etc/init.d/golden-web restart
fi
PORT=$(sed -n 's/.*"listen"[[:space:]]*:[[:space:]]*"[^"]*:\([0-9][0-9]*\)".*/\1/p' "$CFG" | head -n1)
PORT=${PORT:-8443}
if command -v curl >/dev/null 2>&1; then
 curl -kfsS --connect-timeout 3 --max-time 8 "https://127.0.0.1:${PORT}/api/health" >/dev/null || { echo "ERROR: health check falló en ${PORT}."; exit 1; }
fi
echo "[OK] Golden Web Panel REV27.3 actualizado."
echo "     Configuración/login/certificado conservados."
echo "     gerar y el generador NO fueron modificados."
echo "     Panel: https://IP:${PORT}"
