#!/usr/bin/env bash
set -euo pipefail
REPO="${GOLDEN_REPO:-https://raw.githubusercontent.com/satanas66666/golden-system2/main}"
BASE_URL="$REPO/webpanel"
TMP=$(mktemp -d /tmp/golden-webpanel.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
arch=$(uname -m)
case "$arch" in
  x86_64|amd64) A=amd64 ;;
  aarch64|arm64) A=arm64 ;;
  i386|i486|i586|i686) A=386 ;;
  *) echo "Arquitectura no soportada: $arch"; exit 1;;
esac
fetch(){
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 --connect-timeout 10 --max-time 180 "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then wget --timeout=30 --tries=3 -O "$out" "$url"
  else echo "Necesitas curl o wget."; exit 1; fi
}
echo "Descargando Golden Web Panel para $A..."
fetch "$BASE_URL/instalar_webpanel.sh" "$TMP/instalar_webpanel.sh"
fetch "$BASE_URL/bin/golden-web-linux-$A" "$TMP/bin/golden-web-linux-$A"
fetch "$BASE_URL/bin/golden-web-bridge-linux-$A" "$TMP/bin/golden-web-bridge-linux-$A"
chmod +x "$TMP/instalar_webpanel.sh" "$TMP/bin/"*
bash "$TMP/instalar_webpanel.sh"
