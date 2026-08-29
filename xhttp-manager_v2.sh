#!/usr/bin/env bash
set -Euo pipefail

MANAGER_VERSION="2.0.0"
XRAY_VERSION="25.10.15"
LEGACY_SERVICE="superflash-xhttp.service"
SERVICE="superflash-xhttp-native.service"
BASE="/etc/superflash-xhttp-native"
CONFIG="$BASE/config"
XRAY_CONFIG="$BASE/xray.json"
BIN="/usr/local/bin/superflash-xray"
UNIT="/etc/systemd/system/$SERVICE"
LEGACY_BASE="/etc/superflash-xhttp"
LEGACY_CONFIG="$LEGACY_BASE/config"
TLS_DIR="$LEGACY_BASE/tls"
CERT="$TLS_DIR/fullchain.pem"
KEY="$TLS_DIR/key.pem"
ACME="/root/.acme.sh/acme.sh"
DEFAULT_XHTTP_PORT=443
DEFAULT_SSH_PORT=22

red='\033[1;31m'; green='\033[1;32m'; cyan='\033[1;36m'; yellow='\033[1;33m'; reset='\033[0m'

need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo -e "${red}Ejecuta como root.${reset}"; exit 1; }; }
pause(){ echo; read -r -p "Presiona ENTER para continuar..." _ || true; }
valid_port(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_domain(){ [[ "${1:-}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_uuid(){ [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; }

load_config(){
  XHTTP_PORT="$DEFAULT_XHTTP_PORT"; SSH_PORT="$DEFAULT_SSH_PORT"; DOMAIN=""; NATIVE_UUID=""; ACME_EMAIL=""
  if [ -f "$LEGACY_CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$LEGACY_CONFIG" || true
  fi
  if [ -f "$CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG" || true
  fi
  valid_port "$XHTTP_PORT" || XHTTP_PORT="$DEFAULT_XHTTP_PORT"
  valid_port "$SSH_PORT" || SSH_PORT="$DEFAULT_SSH_PORT"
}

save_config(){
  mkdir -p "$BASE"
  cat > "$CONFIG" <<CFG
XHTTP_PORT=$XHTTP_PORT
SSH_PORT=$SSH_PORT
DOMAIN=$DOMAIN
NATIVE_UUID=$NATIVE_UUID
ACME_EMAIL=$ACME_EMAIL
CFG
  chmod 600 "$CONFIG"
}

install_deps(){
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates unzip openssl socat >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates unzip openssl socat >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates unzip openssl socat >/dev/null
  else
    for c in curl unzip openssl; do command -v "$c" >/dev/null 2>&1 || { echo "Falta $c"; return 1; }; done
  fi
}

asset_name(){
  case "$(uname -m)" in
    x86_64|amd64) echo "Xray-linux-64.zip" ;;
    aarch64|arm64) echo "Xray-linux-arm64-v8a.zip" ;;
    *) echo "" ;;
  esac
}

fetch_release(){
  local asset="$1" out="$2" dgst="$3"
  local gh="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${asset}"
  local sf="https://downloads.sourceforge.net/project/xray-core.mirror/v${XRAY_VERSION}/${asset}"
  echo "Descargando Xray Core v$XRAY_VERSION ($asset)..."
  if ! curl -fL --retry 3 --connect-timeout 15 "$gh" -o "$out"; then
    echo -e "${yellow}GitHub no respondió; intentando mirror SourceForge...${reset}"
    curl -fL --retry 3 --connect-timeout 15 "$sf" -o "$out"
  fi
  if ! curl -fL --retry 2 --connect-timeout 15 "${gh}.dgst" -o "$dgst"; then
    curl -fL --retry 2 --connect-timeout 15 "${sf}.dgst" -o "$dgst" || true
  fi
}

verify_download(){
  local zip="$1" dgst="$2" expected="" got=""
  got="$(sha256sum "$zip" | awk '{print tolower($1)}')"
  if [ -s "$dgst" ]; then
    expected="$(grep -Ei 'sha[- ]?256|sha256' "$dgst" | grep -Eio '[0-9a-fA-F]{64}' | head -1 | tr 'A-F' 'a-f' || true)"
  fi
  if [ -n "$expected" ]; then
    [ "$got" = "$expected" ] || { echo -e "${red}SHA-256 del paquete Xray no coincide.${reset}"; return 1; }
    echo -e "${green}✔ SHA-256 oficial verificado: $got${reset}"
  else
    echo -e "${yellow}Aviso: no se pudo interpretar .dgst; se validará versión/binario después de extraer.${reset}"
    echo "SHA-256 descargado: $got"
  fi
}

install_xray(){
  install_deps || return 1
  local asset tmpdir zip dgst version_line
  asset="$(asset_name)"
  [ -n "$asset" ] || { echo -e "${red}Arquitectura no soportada: $(uname -m)${reset}"; return 1; }
  tmpdir="$(mktemp -d)"; zip="$tmpdir/xray.zip"; dgst="$tmpdir/xray.zip.dgst"
  fetch_release "$asset" "$zip" "$dgst" || return 1
  verify_download "$zip" "$dgst" || return 1
  unzip -q "$zip" -d "$tmpdir/unpack"
  [ -x "$tmpdir/unpack/xray" ] || chmod +x "$tmpdir/unpack/xray" 2>/dev/null || true
  [ -f "$tmpdir/unpack/xray" ] || { echo -e "${red}El paquete no contiene xray.${reset}"; return 1; }
  version_line="$("$tmpdir/unpack/xray" version 2>/dev/null | head -1 || true)"
  echo "$version_line"
  echo "$version_line" | grep -q "$XRAY_VERSION" || { echo -e "${red}Versión Xray inesperada.${reset}"; return 1; }
  install -m 0755 "$tmpdir/unpack/xray" "$BIN"
  rm -rf "$tmpdir"
}

generate_uuid_if_needed(){
  if ! valid_uuid "$NATIVE_UUID"; then
    NATIVE_UUID="$(cat /proc/sys/kernel/random/uuid)"
    save_config
  fi
}

write_xray_config(){
  load_config
  generate_uuid_if_needed
  [ -n "$DOMAIN" ] && valid_domain "$DOMAIN" || { echo -e "${red}Falta dominio válido. Configúralo primero.${reset}"; return 1; }
  [ -s "$CERT" ] && [ -s "$KEY" ] || { echo -e "${red}Falta certificado en $TLS_DIR. Usa la opción de certificado.${reset}"; return 1; }
  mkdir -p "$BASE"
  cat > "$XRAY_CONFIG" <<JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "sf-xhttp-native",
      "listen": "0.0.0.0",
      "port": $XHTTP_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {"id": "$NATIVE_UUID", "email": "superflash-xhttp-native"}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h2"],
          "minVersion": "1.2",
          "maxVersion": "1.3",
          "rejectUnknownSni": false,
          "certificates": [
            {"certificateFile": "$CERT", "keyFile": "$KEY"}
          ]
        },
        "xhttpSettings": {
          "path": "/xhttp",
          "mode": "auto"
        }
      }
    }
  ],
  "outbounds": [
    {"tag": "block", "protocol": "blackhole", "settings": {}},
    {"tag": "ssh-local", "protocol": "freedom", "settings": {}}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["sf-xhttp-native"],
        "network": "tcp",
        "ip": ["127.0.0.1"],
        "port": "$SSH_PORT",
        "outboundTag": "ssh-local"
      },
      {
        "type": "field",
        "inboundTag": ["sf-xhttp-native"],
        "outboundTag": "block"
      }
    ]
  }
}
JSON
  chmod 600 "$XRAY_CONFIG"
  "$BIN" run -test -config "$XRAY_CONFIG" >/dev/null
}

write_service(){
  cat > "$UNIT" <<UNIT
[Unit]
Description=SuperFlash XHTTP Native Xray Engine
After=network-online.target ssh.service sshd.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN run -config $XRAY_CONFIG
Restart=always
RestartSec=1
LimitNOFILE=262144
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
}

open_firewall(){
  if command -v ufw >/dev/null 2>&1; then ufw allow "${XHTTP_PORT}/tcp" >/dev/null 2>&1 || true; fi
}

switch_from_legacy(){
  # Port 443 belongs to only one XHTTP engine. Preserve the legacy files for rollback,
  # but stop/disable only its XHTTP service. BHTTP :80 is never touched.
  systemctl stop "$LEGACY_SERVICE" >/dev/null 2>&1 || true
  systemctl disable "$LEGACY_SERVICE" >/dev/null 2>&1 || true
}

install_all(){
  need_root; load_config; install_xray || return 1; generate_uuid_if_needed
  write_xray_config || return 1; write_service; switch_from_legacy; open_firewall
  systemctl restart "$SERVICE"
  sleep 1
  echo -e "${green}✔ XHTTP Native instalado y activo.${reset}"
  echo -e "${cyan}Native UUID: $NATIVE_UUID${reset}"
  echo "Cópialo al campo XHTTP · Native UUID del Generador v1.3.0."
  status
}

ensure_443_free_for_acme(){
  systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  systemctl stop "$LEGACY_SERVICE" >/dev/null 2>&1 || true
  sleep 1
}

install_acme(){
  if [ ! -x "$ACME" ]; then
    if [ -n "$ACME_EMAIL" ]; then
      curl -fsSL https://get.acme.sh | sh -s email="$ACME_EMAIL"
    else
      curl -fsSL https://get.acme.sh | sh
    fi
  fi
  [ -x "$ACME" ]
}

configure_cert(){
  need_root; load_config; install_deps || return 1
  echo "Dominio actual: ${DOMAIN:-<sin configurar>}"
  read -r -p "Dominio XHTTP que apunta a esta VPS [${DOMAIN:-}]: " d
  d="${d:-$DOMAIN}"; d="${d,,}"
  valid_domain "$d" || { echo -e "${red}Dominio inválido.${reset}"; return 1; }
  read -r -p "Email Let's Encrypt (opcional) [${ACME_EMAIL:-}]: " e
  [ -n "$e" ] && ACME_EMAIL="$e"
  DOMAIN="$d"; save_config
  ensure_443_free_for_acme
  install_acme || { echo -e "${red}No se pudo instalar acme.sh.${reset}"; return 1; }
  mkdir -p "$TLS_DIR"
  "$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  "$ACME" --issue --alpn -d "$DOMAIN" --server letsencrypt --keylength ec-256 || return 1
  "$ACME" --install-cert -d "$DOMAIN" --ecc \
    --key-file "$KEY" --fullchain-file "$CERT" \
    --reloadcmd "systemctl restart $SERVICE >/dev/null 2>&1 || true"
  chmod 600 "$KEY"; chmod 644 "$CERT"
  if [ -x "$BIN" ]; then
    write_xray_config && write_service && switch_from_legacy && systemctl restart "$SERVICE"
  fi
  echo -e "${green}✔ Certificado instalado para $DOMAIN.${reset}"
}

rotate_uuid(){
  need_root; load_config
  NATIVE_UUID="$(cat /proc/sys/kernel/random/uuid)"; save_config
  if [ -x "$BIN" ] && [ -s "$CERT" ] && [ -s "$KEY" ]; then
    write_xray_config && systemctl restart "$SERVICE"
  fi
  echo -e "${yellow}UUID rotado. Actualiza el generador/catálogo antes de probar la app.${reset}"
  echo -e "${cyan}Native UUID: $NATIVE_UUID${reset}"
}

set_ssh_port(){
  need_root; load_config
  read -r -p "Puerto SSH local en esta VPS [$SSH_PORT]: " p; p="${p:-$SSH_PORT}"
  valid_port "$p" || { echo -e "${red}Puerto inválido.${reset}"; return 1; }
  SSH_PORT="$p"; save_config
  if [ -x "$BIN" ] && [ -s "$CERT" ] && [ -s "$KEY" ]; then write_xray_config && systemctl restart "$SERVICE"; fi
}

status(){
  load_config
  echo "SUPERFLASH XHTTP NATIVE MANAGER v$MANAGER_VERSION"
  echo "Motor        : Xray Core v$XRAY_VERSION"
  echo "Dominio      : ${DOMAIN:-<sin configurar>}"
  echo "XHTTP Native : :$XHTTP_PORT -> VLESS/XHTTP/TLS"
  echo "SSH permitido: 127.0.0.1:$SSH_PORT SOLAMENTE"
  echo "BHTTP :80    : NO SE TOCA"
  if [ -x "$BIN" ]; then "$BIN" version 2>/dev/null | head -1 || true; else echo "Binario       : NO INSTALADO"; fi
  systemctl is-active --quiet "$SERVICE" 2>/dev/null && echo "Servicio      : ✔ ON" || echo "Servicio      : ✘ OFF"
  ss -lnt 2>/dev/null | grep -qE "[:.]$XHTTP_PORT[[:space:]]" && echo "Puerto $XHTTP_PORT    : ✔ LISTEN" || echo "Puerto $XHTTP_PORT    : ✘ NO LISTEN"
  if valid_uuid "$NATIVE_UUID"; then echo "Native UUID   : $NATIVE_UUID"; else echo "Native UUID   : <sin generar>"; fi
}

self_test(){
  need_root; load_config
  [ -x "$BIN" ] || { echo "Xray no instalado"; return 1; }
  [ -s "$XRAY_CONFIG" ] || { echo "Config nativa no encontrada"; return 1; }
  echo "1) Sintaxis Xray:"
  "$BIN" run -test -config "$XRAY_CONFIG" && echo -e "${green}✔ CONFIG PASS${reset}" || return 1
  echo; echo "2) Servicio/puerto:"
  systemctl is-active --quiet "$SERVICE" && echo -e "${green}✔ SERVICE ACTIVE${reset}" || return 1
  ss -lnt | grep -qE "[:.]$XHTTP_PORT[[:space:]]" && echo -e "${green}✔ TCP $XHTTP_PORT LISTEN${reset}" || return 1
  echo; echo "3) TLS + ALPN h2:"
  [ -n "$DOMAIN" ] || return 1
  local alpn
  alpn="$(echo | timeout 8 openssl s_client -connect "127.0.0.1:$XHTTP_PORT" -servername "$DOMAIN" -alpn h2 2>/dev/null | tr -d '\000' | grep -a -E '^ALPN protocol:' | tail -1 || true)"
  echo "$alpn"
  echo "$alpn" | grep -q 'h2' && echo -e "${green}✔ NATIVE XHTTP TLS/H2 LISTO${reset}" || return 1
  echo; echo -e "${cyan}Native UUID: $NATIVE_UUID${reset}"
  echo "Path         : /xhttp"
  echo "Servidor     : $DOMAIN:$XHTTP_PORT"
  echo "Backend      : 127.0.0.1:$SSH_PORT (único destino permitido)"
}

show_logs(){ journalctl -u "$SERVICE" -n 120 --no-pager; }

menu(){
  need_root
  while true; do
    clear || true
    load_config
    echo "=========================================================="
    echo " SUPERFLASH XHTTP NATIVE XRAY MANAGER v$MANAGER_VERSION"
    echo "=========================================================="
    status || true
    echo
    echo "1) Instalar/ACTUALIZAR XHTTP Native (Xray v$XRAY_VERSION)"
    echo "2) Configurar dominio + certificado Let's Encrypt"
    echo "3) Rotar/crear Native UUID"
    echo "4) Configurar puerto SSH local"
    echo "5) Estado"
    echo "6) Autoprueba Xray + TLS/H2"
    echo "7) Ver logs"
    echo "8) Reiniciar XHTTP Native"
    echo "9) Detener XHTTP Native"
    echo "10) Mostrar UUID/datos para Generador"
    echo "0) Salir"
    read -r -p "> " op
    case "$op" in
      1) install_all; pause ;;
      2) configure_cert; pause ;;
      3) rotate_uuid; pause ;;
      4) set_ssh_port; pause ;;
      5) status; pause ;;
      6) self_test; pause ;;
      7) show_logs; pause ;;
      8) systemctl restart "$SERVICE"; pause ;;
      9) systemctl stop "$SERVICE"; pause ;;
      10) echo "Native UUID: ${NATIVE_UUID:-<sin generar>}"; echo "Path: /xhttp"; echo "Port: $XHTTP_PORT"; echo "Verify Name: ${DOMAIN:-<sin dominio>}"; pause ;;
      0) exit 0 ;;
      *) echo "Opción inválida"; sleep 1 ;;
    esac
  done
}

need_root
menu
