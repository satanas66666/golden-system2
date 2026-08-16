#!/usr/bin/env bash
set -u
ok=0; fail=0
pass(){ echo "[OK] $*"; ok=$((ok+1)); }
bad(){ echo "[FAIL] $*"; fail=$((fail+1)); }
echo "GOLDEN WEB PANEL REV27.2 - VALIDACION"
echo "===================================="
arch=$(uname -m)
case "$arch" in x86_64|amd64) A=amd64;; aarch64|arm64) A=arm64;; i?86) A=386;; *) A="";; esac
[[ -n "$A" ]] && pass "Arquitectura compatible: $arch" || bad "Arquitectura no soportada: $arch"
command -v gerar >/dev/null 2>&1 && pass "gerar disponible" || bad "gerar no encontrado"
[[ -d /etc/http-shell ]] && pass "/etc/http-shell presente" || bad "/etc/http-shell falta"
[[ -d /etc/SCRIPT ]] && pass "/etc/SCRIPT presente" || bad "/etc/SCRIPT falta"
if [[ -x /usr/local/bin/golden-web ]]; then
  /usr/local/bin/golden-web --self-test --config /etc/golden-web/config.json >/dev/null 2>&1 && pass "binario/config web OK" || bad "self-test web falló"
else bad "panel no instalado"; fi
if [[ -x /usr/local/sbin/golden-web-bridge ]]; then
  sudo /usr/local/sbin/golden-web-bridge --self-test >/dev/null 2>&1 && pass "bridge OK" || bad "bridge falló"
else bad "bridge no instalado"; fi
if command -v curl >/dev/null 2>&1; then
  port=$(sed -n 's/.*"listen"[[:space:]]*:[[:space:]]*"[^"]*:\([0-9]*\)".*/\1/p' /etc/golden-web/config.json 2>/dev/null | head -1); port=${port:-8443}
  curl -kfsS --connect-timeout 2 --max-time 5 "https://127.0.0.1:$port/api/health" >/dev/null 2>&1 && pass "HTTPS health OK en $port" || bad "HTTPS health no responde en $port"
fi
command -v gerar >/dev/null 2>&1 && gerar --self-test >/dev/null 2>&1 && pass "core gerar self-test sigue OK" || bad "core gerar self-test falló"
echo "------------------------------------"
echo "OK=$ok FAIL=$fail"
((fail==0))
