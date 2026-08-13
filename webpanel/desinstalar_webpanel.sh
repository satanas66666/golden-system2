#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) -eq 0 ]] || { echo "Ejecuta como root."; exit 1; }
echo "Este desinstalador elimina SOLO Golden Web Panel. gerar/keys/8888/Apache NO se tocan."
read -r -p "Confirmar desinstalación del panel [S/N]: " x
[[ "$x" =~ ^[SsYy]$ ]] || exit 0
if command -v systemctl >/dev/null 2>&1; then systemctl disable --now golden-web.service >/dev/null 2>&1 || true; fi
/etc/init.d/golden-web stop >/dev/null 2>&1 || true
rm -f /etc/systemd/system/golden-web.service /etc/init.d/golden-web /etc/sudoers.d/golden-web
rm -f /usr/local/bin/golden-web /usr/local/sbin/golden-web-bridge
rm -rf /etc/golden-web /var/lib/golden-web
rm -f /var/log/golden-web-audit.log
if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload >/dev/null 2>&1 || true; fi
echo "Golden Web Panel eliminado. El generador SSH sigue intacto: gerar"
