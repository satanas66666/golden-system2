#!/usr/bin/env bash
# VeltrixProxy BHTTP Manager
# v1.1.0
#
# Ubuntu 14.04+ / Debian 8+
#
# - Instala/actualiza VeltrixProxy usando el instalador OFICIAL.
# - Detecta instalaciones previas y muestra marcador INSTALADO.
# - Administra listeners BHTTP TCP (80 por defecto o puerto manual).
# - No modifica ni evita la licencia/token oficial de VeltrixProxy.
#
# Uso:
#   bash veltrix-bhttp-manager.sh
#   bash veltrix-bhttp-manager.sh --install
#   bash veltrix-bhttp-manager.sh --open-port 80
#   bash veltrix-bhttp-manager.sh --diagnose

set -u
umask 077

SCRIPT_VERSION="1.1.0"

OFFICIAL_INSTALL="https://raw.githubusercontent.com/TelksBr/VeltrixProxy/main/install.sh"
OFFICIAL_MENU="https://raw.githubusercontent.com/TelksBr/VeltrixProxy/main/vt.sh"

MANAGER_DIR="/etc/veltrix-bhttp-manager"
INSTALL_MARKER="$MANAGER_DIR/installed"
DEFAULT_BHTTP_PORT="80"

PROXY_DIR="/etc/proxy"
PROXY_CONFIG_DIR="$PROXY_DIR/conf.d"
PROXY_LOG_DIR="/var/log/proxy"
PROXY_TOKEN_VTPROXY="/etc/vtproxy/proxy.token"
PROXY_TOKEN_FILE="$PROXY_DIR/token"
PROXY_TOKEN_HOME="${HOME:-/root}/.proxy_token"

BHTTP_SYSCTL="/etc/sysctl.d/99-veltrix-bhttp.conf"
BHTTP_LIMITS="/etc/security/limits.d/99-veltrix-bhttp.conf"
APT_ARCHIVE_CONF="/etc/apt/apt.conf.d/99veltrix-archive"
BACKUP_DIR="/root/veltrix-backups"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${CYAN}➜ $*${NC}"; }
ok()   { echo -e "${GREEN}✔ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
err()  { echo -e "${RED}✘ $*${NC}" >&2; }

pause() {
  echo
  read -r -p "Presiona ENTER para continuar..." _
}

have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Ejecuta como root: sudo bash $0"
    exit 1
  fi
}

version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

load_os() {
  OS_ID=""
  OS_VERSION=""
  OS_PRETTY="Linux"

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION="${VERSION_ID:-}"
    OS_PRETTY="${PRETTY_NAME:-Linux}"
  elif have lsb_release; then
    OS_ID="$(lsb_release -si 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    OS_VERSION="$(lsb_release -sr 2>/dev/null)"
    OS_PRETTY="$(lsb_release -sd 2>/dev/null)"
  fi

  case "$OS_ID" in
    ubuntu|debian) ;;
    *)
      err "Sistema no soportado: ${OS_PRETTY}. Solo Ubuntu/Debian."
      exit 1
      ;;
  esac
}

check_minimum_os() {
  local major="${OS_VERSION%%.*}"
  case "$OS_ID" in
    ubuntu)
      if [ -n "$major" ] && [ "$major" -lt 14 ]; then
        err "Ubuntu ${OS_VERSION}: minimo recomendado 14.04."
        exit 1
      fi
      ;;
    debian)
      if [ -n "$major" ] && [ "$major" -lt 8 ]; then
        err "Debian ${OS_VERSION}: minimo recomendado Debian 8."
        exit 1
      fi
      ;;
  esac

  local bash_ver="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
  if ! version_ge "$bash_ver" "4.3"; then
    err "Bash 4.3+ requerido por VeltrixProxy. Detectado: $bash_ver"
    exit 1
  fi
}

proxy_bin() {
  if [ -x /usr/local/bin/proxy-server ]; then
    echo /usr/local/bin/proxy-server
  elif [ -x /usr/local/bin/proxy ]; then
    echo /usr/local/bin/proxy
  else
    echo /usr/local/bin/proxy-server
  fi
}

proxy_installed() {
  [ -x "$(proxy_bin)" ]
}

proxy_version() {
  local bin
  bin="$(proxy_bin)"
  if [ -x "$bin" ]; then
    "$bin" --version 2>/dev/null | head -n1 || true
  elif [ -r /etc/proxy-version ]; then
    cat /etc/proxy-version
  else
    echo "no instalado"
  fi
}

sync_install_marker() {
  if proxy_installed; then
    mkdir -p "$MANAGER_DIR"
    if [ ! -f "$INSTALL_MARKER" ]; then
      {
        echo "manager_version=$SCRIPT_VERSION"
        echo "detected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "proxy=$(proxy_version)"
      } > "$INSTALL_MARKER"
      chmod 600 "$INSTALL_MARKER" 2>/dev/null || true
    fi
  fi
}

port_service_name() {
  echo "proxy-$1"
}

port_conf_file() {
  echo "$PROXY_CONFIG_DIR/proxy-$1.conf"
}

port_log_file() {
  echo "$PROXY_LOG_DIR/proxy-$1.log"
}

port_configured() {
  local p="$1"
  [ -f "$(port_conf_file "$p")" ] || \
  [ -f "/etc/systemd/system/$(port_service_name "$p").service" ]
}

port_active() {
  local p="$1"
  have systemctl && systemctl is-active --quiet "$(port_service_name "$p")" 2>/dev/null
}

port_listening() {
  local p="$1"
  if have ss; then
    ss -lnt 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" {found=1} END{exit !found}'
  elif have netstat; then
    netstat -lnt 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" {found=1} END{exit !found}'
  else
    return 1
  fi
}

bhttp_port_status_text() {
  local p="$1"
  if port_active "$p" && port_listening "$p"; then
    echo -e "${GREEN}ON${NC}"
  elif port_configured "$p"; then
    echo -e "${YELLOW}CONFIGURADO/OFF${NC}"
  else
    echo -e "${RED}NO CONFIGURADO${NC}"
  fi
}

header() {
  sync_install_marker
  clear 2>/dev/null || true

  echo -e "${BLUE}${BOLD}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║          VELTRIXPROXY BHTTP MANAGER  v${SCRIPT_VERSION}               ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  echo -e " Sistema : ${BOLD}${OS_PRETTY}${NC}"
  echo -e " Kernel  : ${BOLD}$(uname -r)${NC}"
  echo -e " Arq.    : ${BOLD}$(uname -m)${NC}"

  if proxy_installed; then
    echo -e " Proxy   : ${GREEN}${BOLD}✔ INSTALADO${NC} — $(proxy_version)"
  else
    echo -e " Proxy   : ${RED}${BOLD}✘ NO INSTALADO${NC}"
  fi

  if proxy_installed; then
    echo -e " BHTTP $DEFAULT_BHTTP_PORT: $(bhttp_port_status_text "$DEFAULT_BHTTP_PORT")"
  fi
  echo
}

apt_update() {
  DEBIAN_FRONTEND=noninteractive apt-get update
}

repair_eol_apt() {
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  warn "Esta opcion modifica repositorios APT y crea respaldo."
  read -r -p "¿Continuar? [s/N]: " ans
  case "${ans:-n}" in s|S|y|Y) ;; *) return 1 ;; esac

  cp -a /etc/apt/sources.list "/etc/apt/sources.list.veltrix.${ts}.bak" 2>/dev/null || true

  if [ "$OS_ID" = "ubuntu" ]; then
    sed -Ei \
      -e 's|https?://([a-z]{2}\.)?archive\.ubuntu\.com/ubuntu/?|http://old-releases.ubuntu.com/ubuntu/|g' \
      -e 's|https?://security\.ubuntu\.com/ubuntu/?|http://old-releases.ubuntu.com/ubuntu/|g' \
      -e 's|https?://ports\.ubuntu\.com/ubuntu-ports/?|http://old-releases.ubuntu.com/ubuntu/|g' \
      /etc/apt/sources.list 2>/dev/null || true
  else
    sed -Ei \
      -e 's|https?://deb\.debian\.org/debian/?|http://archive.debian.org/debian/|g' \
      -e 's|https?://security\.debian\.org[^ ]*|http://archive.debian.org/debian-security|g' \
      -e 's|https?://ftp\.[^/ ]+/debian/?|http://archive.debian.org/debian/|g' \
      /etc/apt/sources.list 2>/dev/null || true
    cat > "$APT_ARCHIVE_CONF" <<'EOF'
Acquire::Check-Valid-Until "false";
EOF
  fi

  apt_update
}

ensure_dependencies() {
  local pkgs="curl ca-certificates coreutils iptables python3 procps iproute2 tar gzip"
  info "Comprobando dependencias..."

  if ! apt_update >/tmp/veltrix-apt-update.log 2>&1; then
    warn "apt-get update fallo."
    tail -n 20 /tmp/veltrix-apt-update.log 2>/dev/null || true
    read -r -p "¿Intentar reparar repositorios EOL? [s/N]: " ans
    case "${ans:-n}" in
      s|S|y|Y) repair_eol_apt || return 1 ;;
      *) return 1 ;;
    esac
  fi

  DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs
  hash -r 2>/dev/null || true
}

backup_veltrix() {
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" 2>/dev/null || true

  local stamp out
  local list=()
  stamp="$(date +%Y%m%d-%H%M%S)"
  out="${BACKUP_DIR}/veltrix-${stamp}.tar.gz"

  [ -e /etc/proxy ] && list+=("/etc/proxy")
  [ -e /etc/vtproxy ] && list+=("/etc/vtproxy")
  [ -e /etc/udpgw ] && list+=("/etc/udpgw")
  [ -e /etc/proxy-version ] && list+=("/etc/proxy-version")

  if [ "${#list[@]}" -eq 0 ]; then
    warn "No hay configuracion para respaldar."
    return 0
  fi

  tar -czf "$out" "${list[@]}" 2>/dev/null
  chmod 600 "$out"
  ok "Respaldo: $out"
}

download_official() {
  local target="$1" url="$2"
  curl --fail --location --silent --show-error \
    --connect-timeout 15 --retry 3 --retry-delay 2 \
    "${url}?$(date +%s)" -o "$target"
  [ -s "$target" ]
}

mark_installed() {
  mkdir -p "$MANAGER_DIR"
  {
    echo "manager_version=$SCRIPT_VERSION"
    echo "installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "proxy=$(proxy_version)"
  } > "$INSTALL_MARKER"
  chmod 600 "$INSTALL_MARKER" 2>/dev/null || true
}

run_official_installer() {
  local mode="$1"
  local tmp rc
  tmp="$(mktemp /tmp/veltrix-install.XXXXXX.sh)"

  info "Descargando instalador oficial VeltrixProxy..."
  if ! download_official "$tmp" "$OFFICIAL_INSTALL"; then
    rm -f "$tmp"
    err "No se pudo descargar el instalador oficial."
    return 1
  fi

  chmod 700 "$tmp"
  if ! grep -q 'TelksBr/VeltrixProxy' "$tmp" || ! grep -q 'proxy-server' "$tmp"; then
    rm -f "$tmp"
    err "Descarga inesperada; no se ejecutara."
    return 1
  fi

  rc=0
  case "$mode" in
    install)
      bash "$tmp" --install --latest || rc=$?
      ;;
    update)
      backup_veltrix
      bash "$tmp" --update --yes || rc=$?
      ;;
    reinstall)
      backup_veltrix
      bash "$tmp" --reinstall --latest --yes || rc=$?
      ;;
    *)
      rc=2
      ;;
  esac
  rm -f "$tmp"

  if [ "$rc" -eq 0 ] && proxy_installed; then
    mark_installed
    ok "VeltrixProxy instalado/detectado correctamente."
    return 0
  fi

  err "La instalacion no termino correctamente."
  return "${rc:-1}"
}

load_proxy_token() {
  local f
  for f in "$PROXY_TOKEN_VTPROXY" "$PROXY_TOKEN_FILE" "$PROXY_TOKEN_HOME"; do
    if [ -s "$f" ]; then
      tr -d '\r\n' < "$f"
      return 0
    fi
  done
  return 1
}

validate_proxy_token() {
  local token="$1" bin
  bin="$(proxy_bin)"
  [ -x "$bin" ] || return 1
  [ -n "$token" ] || return 1
  "$bin" --token "$token" --validate >/dev/null 2>&1
}

save_proxy_token() {
  local token="$1"
  mkdir -p /etc/vtproxy "$PROXY_DIR"
  printf '%s' "$token" > "$PROXY_TOKEN_VTPROXY"
  printf '%s' "$token" > "$PROXY_TOKEN_FILE"
  printf '%s' "$token" > "$PROXY_TOKEN_HOME"
  chmod 600 "$PROXY_TOKEN_VTPROXY" "$PROXY_TOKEN_FILE" "$PROXY_TOKEN_HOME" 2>/dev/null || true
}

ensure_proxy_token() {
  local token=""
  token="$(load_proxy_token 2>/dev/null || true)"

  if [ -n "$token" ] && validate_proxy_token "$token"; then
    return 0
  fi

  if [ -n "$token" ]; then
    warn "El token guardado no fue validado por proxy-server."
  else
    warn "No hay token/licencia Proxy configurado."
  fi

  echo
  read -r -p "Token oficial de Veltrix (VT-...): " token
  token="$(printf '%s' "$token" | tr -d '\r\n')"

  if [ -z "$token" ]; then
    err "Token vacio."
    return 1
  fi

  if ! validate_proxy_token "$token"; then
    err "El proxy-server rechazo el token."
    return 1
  fi

  save_proxy_token "$token"
  ok "Token validado y guardado."
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

foreign_port_in_use() {
  local p="$1"
  if port_active "$p"; then
    return 1
  fi
  port_listening "$p"
}

open_firewall_tcp() {
  local p="$1"

  if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${p}/tcp" >/dev/null 2>&1 || true
    info "UFW: TCP $p permitido."
  fi

  if have firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    info "firewalld: TCP $p permitido."
  fi
}

write_bhttp_proxy_conf() {
  local p="$1"
  mkdir -p "$PROXY_CONFIG_DIR" "$PROXY_LOG_DIR"

  cat > "$(port_conf_file "$p")" <<EOF
PORT=$p
SSL_ENABLED=false
SSL_CERT_PATH=
CERT_INTERNAL=true
SSH_ONLY=true
HTTP_RESPONSE=VTProxy
BUFFER_SIZE=32768
DOMAIN=false
MAX_CONNECTIONS=0
WRITE_TIMEOUT=60
IDLE_TIMEOUT=60
LOG_LEVEL=info
SSH_PORT=22
OPENVPN_PORT=1194
V2RAY_PORT=1080
DISPLAY_BANNER=true
BHTTP_MANAGER=true
EOF
  chmod 644 "$(port_conf_file "$p")"
}

write_bhttp_systemd_unit() {
  local p="$1" token="$2" bin unit
  bin="$(proxy_bin)"
  unit="/etc/systemd/system/$(port_service_name "$p").service"

  # El token oficial Veltrix normalmente es VT-... y ya fue validado por el binario.
  # Por seguridad no permitimos espacios/nuevas lineas en ExecStart.
  if printf '%s' "$token" | grep -q '[[:space:]]'; then
    err "El token contiene espacios no soportados por systemd ExecStart."
    return 1
  fi

  cat > "$unit" <<EOF
[Unit]
Description=VTProxy BHTTP/SSH TCP port $p
After=network-online.target
Wants=network-online.target

[Service]
Environment="GOMEMLIMIT=750MiB"
Environment="GOGC=50"
ExecStart=$bin --token=$token --buffer-size=32768 --response=VTProxy --log-file=$(port_log_file "$p") --log-level=info --ssh-port=22 --openvpn-port=1194 --v2ray-port=1080 --max-connections=0 --write-timeout=60 --idle-timeout=60 --port=$p --ssh-only
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$unit"
}

open_bhttp_port() {
  local p="${1:-$DEFAULT_BHTTP_PORT}" token service

  if ! proxy_installed; then
    err "VeltrixProxy no esta instalado. Usa primero la opcion 1."
    return 1
  fi

  if ! validate_port "$p"; then
    err "Puerto invalido: $p"
    return 1
  fi

  if port_active "$p" && port_listening "$p"; then
    ok "BHTTP TCP $p ya esta ACTIVO."
    return 0
  fi

  if foreign_port_in_use "$p"; then
    err "El puerto TCP $p ya esta ocupado por otro proceso."
    if have ss; then
      ss -lntp 2>/dev/null | grep -E "[:.]${p}[[:space:]]" || true
    fi
    return 1
  fi

  ensure_proxy_token || return 1

  token="$(load_proxy_token)"
  mkdir -p "$PROXY_CONFIG_DIR" "$PROXY_LOG_DIR"

  if port_configured "$p"; then
    warn "El puerto $p ya tenia configuracion Veltrix. Se actualizara al perfil BHTTP/SSH."
  fi

  write_bhttp_proxy_conf "$p"
  write_bhttp_systemd_unit "$p" "$token" || return 1

  systemctl daemon-reload
  systemctl enable "$(port_service_name "$p")" >/dev/null 2>&1 || true

  if ! systemctl restart "$(port_service_name "$p")"; then
    err "No se pudo iniciar proxy-$p."
    journalctl -u "$(port_service_name "$p")" --no-pager -n 30 2>/dev/null || true
    return 1
  fi

  open_firewall_tcp "$p"
  sleep 1

  if port_active "$p" && port_listening "$p"; then
    mkdir -p "$MANAGER_DIR"
    printf '%s\n' "$p" > "$MANAGER_DIR/default-bhttp-port"
    ok "BHTTP/SSH ACTIVO en TCP $p."
    echo
    echo -e "  Generador SuperFlash:"
    echo -e "  Host/IP        : ${BOLD}IP DE ESTA VPS${NC}"
    echo -e "  Puerto BHTTP   : ${BOLD}$p${NC}"
    echo -e "  Upload slots   : ${BOLD}16${NC}"
    echo -e "  Download slots : ${BOLD}32${NC}"
    echo
    warn "Si tu proveedor VPS tiene firewall externo/Security Group, permite TCP $p tambien alli."
    return 0
  fi

  err "El servicio arranco pero no se detecto escucha TCP $p."
  return 1
}

list_bhttp_ports() {
  local found=0 f p
  echo
  echo -e "${BOLD}Puertos Veltrix configurados:${NC}"
  echo "--------------------------------------------------------------"

  for f in "$PROXY_CONFIG_DIR"/proxy-*.conf; do
    [ -f "$f" ] || continue
    p="$(basename "$f" .conf | sed -n 's/^proxy-\([0-9][0-9]*\)$/\1/p')"
    [ -n "$p" ] || continue
    found=1
    printf " TCP %-5s  %b\n" "$p" "$(bhttp_port_status_text "$p")"
  done

  if [ "$found" -eq 0 ]; then
    echo " Ninguno."
  fi
}

start_bhttp_port() {
  local p="$1"
  if ! port_configured "$p"; then
    err "Puerto $p no configurado."
    return 1
  fi
  if foreign_port_in_use "$p"; then
    err "Puerto $p ocupado por otro proceso."
    return 1
  fi
  systemctl restart "$(port_service_name "$p")"
  open_firewall_tcp "$p"
  ok "Puerto $p iniciado."
}

stop_bhttp_port() {
  local p="$1"
  if ! port_configured "$p"; then
    err "Puerto $p no configurado."
    return 1
  fi
  systemctl stop "$(port_service_name "$p")" || true
  ok "Puerto $p detenido. La configuracion se conserva."
}

remove_bhttp_port() {
  local p="$1"
  if ! port_configured "$p"; then
    err "Puerto $p no configurado."
    return 1
  fi

  read -r -p "¿Eliminar definitivamente la configuracion del puerto $p? [s/N]: " ans
  case "${ans:-n}" in s|S|y|Y) ;; *) return 0 ;; esac

  systemctl stop "$(port_service_name "$p")" 2>/dev/null || true
  systemctl disable "$(port_service_name "$p")" 2>/dev/null || true
  rm -f "/etc/systemd/system/$(port_service_name "$p").service"
  rm -f "$(port_conf_file "$p")"
  systemctl daemon-reload
  ok "Puerto $p eliminado."
}

ports_menu() {
  while true; do
    header
    echo -e "${BOLD}GESTIONAR PUERTOS BHTTP${NC}"
    echo
    echo " 1) Abrir/configurar BHTTP TCP 80 (recomendado)"
    echo " 2) Abrir/configurar BHTTP en puerto manual"
    echo " 3) Listar/estado de puertos"
    echo " 4) Iniciar puerto configurado"
    echo " 5) Detener puerto"
    echo " 6) Eliminar puerto"
    echo " 0) Volver"
    echo

    read -r -p "Opcion: " op
    case "$op" in
      1)
        open_bhttp_port "$DEFAULT_BHTTP_PORT"
        pause
        ;;
      2)
        read -r -p "Puerto TCP BHTTP: " p
        p="$(printf '%s' "$p" | tr -d '[:space:]')"
        open_bhttp_port "$p"
        pause
        ;;
      3)
        list_bhttp_ports
        pause
        ;;
      4)
        read -r -p "Puerto a iniciar: " p
        start_bhttp_port "$p"
        pause
        ;;
      5)
        read -r -p "Puerto a detener: " p
        stop_bhttp_port "$p"
        pause
        ;;
      6)
        read -r -p "Puerto a eliminar: " p
        remove_bhttp_port "$p"
        pause
        ;;
      0) return 0 ;;
      *) warn "Opcion invalida."; sleep 1 ;;
    esac
  done
}

sysctl_exists() {
  sysctl -n "$1" >/dev/null 2>&1
}

append_sysctl_if_supported() {
  local key="$1" value="$2" comment="${3:-}"
  if sysctl_exists "$key"; then
    [ -n "$comment" ] && echo "# $comment" >> "$BHTTP_SYSCTL"
    echo "$key = $value" >> "$BHTTP_SYSCTL"
    sysctl -w "$key=$value" >/dev/null 2>&1 || true
  fi
}

enable_bbr_if_available() {
  modprobe tcp_bbr >/dev/null 2>&1 || true
  modprobe sch_fq >/dev/null 2>&1 || true

  local available
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if echo " $available " | grep -q ' bbr '; then
    append_sysctl_if_supported net.core.default_qdisc fq
    append_sysctl_if_supported net.ipv4.tcp_congestion_control bbr
    ok "BBR disponible y habilitado."
  else
    warn "BBR no disponible; se conserva congestion control actual."
  fi
}

apply_systemd_nofile() {
  have systemctl || return 0
  local d u
  for u in /etc/systemd/system/proxy-*.service; do
    [ -f "$u" ] || continue
    u="$(basename "$u" .service)"
    d="/etc/systemd/system/${u}.service.d"
    mkdir -p "$d"
    cat > "$d/99-veltrix-bhttp.conf" <<'EOF'
[Service]
LimitNOFILE=65536
EOF
  done
  systemctl daemon-reload >/dev/null 2>&1 || true
}

apply_bhttp_tuning() {
  info "Aplicando optimizacion BHTTP adaptativa..."

  mkdir -p /etc/sysctl.d
  cat > "$BHTTP_SYSCTL" <<'EOF'
# VeltrixProxy BHTTP Manager
EOF

  append_sysctl_if_supported net.ipv4.ip_forward 1
  append_sysctl_if_supported net.ipv4.tcp_tw_reuse 1
  append_sysctl_if_supported net.ipv4.tcp_fin_timeout 15
  append_sysctl_if_supported net.ipv4.tcp_max_tw_buckets 131072
  append_sysctl_if_supported net.ipv4.ip_local_port_range "10240 65535"
  append_sysctl_if_supported net.core.somaxconn 8192
  append_sysctl_if_supported net.ipv4.tcp_max_syn_backlog 8192
  append_sysctl_if_supported net.core.netdev_max_backlog 8192
  append_sysctl_if_supported net.ipv4.tcp_slow_start_after_idle 0
  append_sysctl_if_supported net.ipv4.tcp_fastopen 3
  append_sysctl_if_supported net.core.rmem_default 65536
  append_sysctl_if_supported net.core.wmem_default 65536
  append_sysctl_if_supported net.core.rmem_max 8388608
  append_sysctl_if_supported net.core.wmem_max 8388608
  append_sysctl_if_supported net.ipv4.tcp_rmem "4096 87380 8388608"
  append_sysctl_if_supported net.ipv4.tcp_wmem "4096 65536 8388608"

  enable_bbr_if_available

  if [ -d /etc/security ]; then
    mkdir -p /etc/security/limits.d
    cat > "$BHTTP_LIMITS" <<'EOF'
* soft nofile 65536
* hard nofile 65536
root soft nofile 65536
root hard nofile 65536
EOF
  fi

  ulimit -n 65536 2>/dev/null || true
  apply_systemd_nofile
  sysctl -p "$BHTTP_SYSCTL" >/dev/null 2>&1 || true
  ok "Tuning BHTTP aplicado."
}

remove_bhttp_tuning() {
  read -r -p "¿Quitar tuning creado por este manager? [s/N]: " ans
  case "${ans:-n}" in s|S|y|Y) ;; *) return 0 ;; esac
  rm -f "$BHTTP_SYSCTL" "$BHTTP_LIMITS"
  sysctl --system >/dev/null 2>&1 || true
  ok "Tuning eliminado. Reinicia para limpiar valores runtime restantes."
}

show_status() {
  header
  echo -e "${BOLD}DIAGNOSTICO${NC}"
  echo "--------------------------------------------------------------"
  echo "Proxy binary : $(proxy_bin)"
  echo "Proxy version: $(proxy_version)"
  echo "Menu vt      : $( [ -x /usr/local/bin/vt ] && echo instalado || echo no-instalado )"
  echo "Token        : $( [ -s "$PROXY_TOKEN_VTPROXY" ] || [ -s "$PROXY_TOKEN_FILE" ] && echo configurado || echo no-configurado )"
  echo "ulimit -n    : $(ulimit -n 2>/dev/null || echo '?')"
  echo "TCP CC       : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  echo "Port range   : $(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || echo '?')"
  echo
  list_bhttp_ports
  echo
  echo -e "${BOLD}Sockets escuchando:${NC}"
  if have ss; then
    ss -lntp 2>/dev/null | grep -E 'proxy-server|/proxy|:80 |:53 ' || true
  else
    netstat -lntp 2>/dev/null | grep -E 'proxy-server|/proxy|:80 |:53 ' || true
  fi
}

restart_services() {
  local u found=0
  have systemctl || { err "systemd no disponible."; return 1; }

  for u in /etc/systemd/system/proxy-*.service; do
    [ -f "$u" ] || continue
    found=1
    u="$(basename "$u" .service)"
    info "Reiniciando $u"
    systemctl restart "$u" || warn "Fallo: $u"
  done

  [ "$found" -eq 1 ] && ok "Servicios reiniciados." || warn "No hay puertos proxy configurados."
}

show_logs() {
  local p
  read -r -p "Puerto Veltrix para ver log [80]: " p
  p="${p:-80}"
  if have journalctl; then
    journalctl -u "$(port_service_name "$p")" --no-pager -n 120
  else
    tail -n 120 "$(port_log_file "$p")" 2>/dev/null || true
  fi
}

open_vt() {
  if [ -x /usr/local/bin/vt ]; then
    exec /usr/local/bin/vt
  fi

  warn "Menu vt no encontrado."
  read -r -p "¿Descargar vt.sh oficial? [s/N]: " ans
  case "${ans:-n}" in
    s|S|y|Y)
      download_official /usr/local/bin/vt "$OFFICIAL_MENU" || return 1
      chmod 755 /usr/local/bin/vt
      exec /usr/local/bin/vt
      ;;
  esac
}

post_install_setup() {
  apply_bhttp_tuning
  echo
  read -r -p "¿Abrir/configurar BHTTP TCP 80 ahora? [S/n]: " ans
  case "${ans:-s}" in
    n|N|no|NO) ;;
    *) open_bhttp_port "$DEFAULT_BHTTP_PORT" || true ;;
  esac
}

menu() {
  while true; do
    header
    echo -e "${BOLD} 1)${NC} Instalar VeltrixProxy (oficial)"
    echo -e "${BOLD} 2)${NC} Actualizar VeltrixProxy + UDPgw + menu"
    echo -e "${BOLD} 3)${NC} Reinstalar/repair VeltrixProxy"
    echo -e "${BOLD} 4)${NC} ${CYAN}Gestionar puertos BHTTP (80/manual)${NC}"
    echo -e "${BOLD} 5)${NC} Configurar/validar token Proxy"
    echo -e "${BOLD} 6)${NC} Aplicar/actualizar optimizacion BHTTP"
    echo -e "${BOLD} 7)${NC} Diagnostico completo"
    echo -e "${BOLD} 8)${NC} Reiniciar puertos Veltrix"
    echo -e "${BOLD} 9)${NC} Ver logs de un puerto"
    echo -e "${BOLD}10)${NC} Abrir menu oficial: vt"
    echo -e "${BOLD}11)${NC} Crear respaldo manual"
    echo -e "${BOLD}12)${NC} Reparar APT Ubuntu/Debian EOL"
    echo -e "${BOLD}13)${NC} Quitar tuning creado por este manager"
    echo -e "${BOLD} 0)${NC} Salir"
    echo

    read -r -p "Selecciona una opcion: " op
    case "$op" in
      1)
        ensure_dependencies && run_official_installer install && post_install_setup
        pause
        ;;
      2)
        ensure_dependencies && run_official_installer update && apply_bhttp_tuning
        pause
        ;;
      3)
        ensure_dependencies && run_official_installer reinstall && apply_bhttp_tuning
        pause
        ;;
      4) ports_menu ;;
      5) ensure_proxy_token; pause ;;
      6) apply_bhttp_tuning; pause ;;
      7) show_status; pause ;;
      8) restart_services; pause ;;
      9) show_logs; pause ;;
      10) open_vt ;;
      11) backup_veltrix; pause ;;
      12) repair_eol_apt; pause ;;
      13) remove_bhttp_tuning; pause ;;
      0) exit 0 ;;
      *) warn "Opcion invalida."; sleep 1 ;;
    esac
  done
}

main() {
  require_root
  load_os
  check_minimum_os
  sync_install_marker

  case "${1:-}" in
    --install)
      ensure_dependencies
      run_official_installer install
      post_install_setup
      ;;
    --update)
      ensure_dependencies
      run_official_installer update
      apply_bhttp_tuning
      ;;
    --reinstall)
      ensure_dependencies
      run_official_installer reinstall
      apply_bhttp_tuning
      ;;
    --open-port)
      open_bhttp_port "${2:-80}"
      ;;
    --tune)
      apply_bhttp_tuning
      ;;
    --diagnose)
      show_status
      ;;
    --help|-h)
      cat <<EOF
VeltrixProxy BHTTP Manager v$SCRIPT_VERSION

  bash $0                    Menu
  bash $0 --install          Instalar y ofrecer BHTTP 80
  bash $0 --open-port 80     Abrir/configurar BHTTP TCP 80
  bash $0 --open-port 8080   Abrir/configurar puerto manual
  bash $0 --update           Actualizar
  bash $0 --diagnose         Diagnostico
EOF
      ;;
    "")
      menu
      ;;
    *)
      err "Parametro desconocido: $1"
      exit 2
      ;;
  esac
}

main "$@"
