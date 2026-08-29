#!/usr/bin/env bash
# VeltrixProxy BHTTP Manager
# Compatible con Ubuntu 14.04+ y Debian 8+ (systemd recomendado).
# En versiones EOL puede reparar los repositorios APT bajo confirmacion.
#
# Este script NO reemplaza el instalador oficial de VeltrixProxy:
# descarga y ejecuta https://raw.githubusercontent.com/TelksBr/VeltrixProxy/main/install.sh
# para instalar/actualizar el proxy y conserva la configuracion/token oficial.
#
# Uso:
#   bash veltrix-bhttp-manager.sh
#   bash veltrix-bhttp-manager.sh --install
#   bash veltrix-bhttp-manager.sh --update
#   bash veltrix-bhttp-manager.sh --tune
#   bash veltrix-bhttp-manager.sh --diagnose

set -u
umask 077

SCRIPT_VERSION="1.0.0"
OFFICIAL_INSTALL="https://raw.githubusercontent.com/TelksBr/VeltrixProxy/main/install.sh"
OFFICIAL_MENU="https://raw.githubusercontent.com/TelksBr/VeltrixProxy/main/vt.sh"

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

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Ejecuta el script como root: sudo bash $0"
    exit 1
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

version_ge() {
  # version_ge 4.3 4.2 -> true
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

load_os() {
  OS_ID=""
  OS_VERSION=""
  OS_CODENAME=""
  OS_PRETTY="Linux"

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION="${VERSION_ID:-}"
    OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    OS_PRETTY="${PRETTY_NAME:-Linux}"
  elif have lsb_release; then
    OS_ID="$(lsb_release -si 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    OS_VERSION="$(lsb_release -sr 2>/dev/null)"
    OS_CODENAME="$(lsb_release -sc 2>/dev/null)"
    OS_PRETTY="$(lsb_release -sd 2>/dev/null)"
  fi

  case "$OS_ID" in
    ubuntu|debian) ;;
    *)
      err "Sistema no soportado: ${OS_PRETTY}. Este manager es solo para Ubuntu/Debian."
      exit 1
      ;;
  esac
}

check_minimum_os() {
  local major="${OS_VERSION%%.*}"
  case "$OS_ID" in
    ubuntu)
      if [ -n "$major" ] && [ "$major" -lt 14 ]; then
        err "Ubuntu ${OS_VERSION} es demasiado antiguo. Minimo recomendado: Ubuntu 14.04."
        exit 1
      fi
      ;;
    debian)
      if [ -n "$major" ] && [ "$major" -lt 8 ]; then
        err "Debian ${OS_VERSION} es demasiado antiguo. Minimo recomendado: Debian 8."
        exit 1
      fi
      ;;
  esac

  local bash_ver="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
  if ! version_ge "$bash_ver" "4.3"; then
    err "VeltrixProxy oficial usa funciones de Bash 4.3+. Detectado Bash ${bash_ver}."
    err "Actualiza bash antes de instalar VeltrixProxy."
    exit 1
  fi
}

header() {
  clear 2>/dev/null || true
  echo -e "${BLUE}${BOLD}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║          VELTRIXPROXY BHTTP MANAGER  v${SCRIPT_VERSION}               ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e " Sistema : ${BOLD}${OS_PRETTY}${NC}"
  echo -e " Kernel  : ${BOLD}$(uname -r)${NC}"
  echo -e " Arq.    : ${BOLD}$(uname -m)${NC}"
  echo
}

apt_update() {
  DEBIAN_FRONTEND=noninteractive apt-get update
}

repair_eol_apt() {
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  warn "Esta opcion modifica los repositorios APT y crea una copia de seguridad."
  read -r -p "¿Continuar? [s/N]: " ans
  case "${ans:-n}" in s|S|y|Y) ;; *) return 1 ;; esac

  cp -a /etc/apt/sources.list "/etc/apt/sources.list.veltrix.${ts}.bak" 2>/dev/null || true
  if [ -d /etc/apt/sources.list.d ]; then
    tar -C /etc/apt -czf "/etc/apt/sources.list.d.veltrix.${ts}.tgz" sources.list.d 2>/dev/null || true
  fi

  if [ "$OS_ID" = "ubuntu" ]; then
    info "Cambiando mirrors EOL de Ubuntu a old-releases.ubuntu.com..."
    sed -Ei \
      -e 's|https?://([a-z]{2}\.)?archive\.ubuntu\.com/ubuntu/?|http://old-releases.ubuntu.com/ubuntu/|g' \
      -e 's|https?://security\.ubuntu\.com/ubuntu/?|http://old-releases.ubuntu.com/ubuntu/|g' \
      -e 's|https?://ports\.ubuntu\.com/ubuntu-ports/?|http://old-releases.ubuntu.com/ubuntu/|g' \
      /etc/apt/sources.list 2>/dev/null || true
  else
    info "Cambiando mirrors EOL de Debian a archive.debian.org..."
    sed -Ei \
      -e 's|https?://deb\.debian\.org/debian/?|http://archive.debian.org/debian/|g' \
      -e 's|https?://security\.debian\.org[^ ]*|http://archive.debian.org/debian-security|g' \
      -e 's|https?://ftp\.[^/ ]+/debian/?|http://archive.debian.org/debian/|g' \
      /etc/apt/sources.list 2>/dev/null || true
    cat > "$APT_ARCHIVE_CONF" <<'EOF'
Acquire::Check-Valid-Until "false";
Acquire::AllowInsecureRepositories "false";
EOF
  fi

  if apt_update; then
    ok "APT reparado."
  else
    err "APT sigue fallando. Restauracion manual disponible en las copias .veltrix.*.bak."
    return 1
  fi
}

ensure_dependencies() {
  local pkgs="curl ca-certificates coreutils iptables python3 procps iproute2 tar gzip"
  info "Comprobando dependencias..."

  if apt_update >/tmp/veltrix-apt-update.log 2>&1; then
    :
  else
    warn "apt-get update fallo."
    cat /tmp/veltrix-apt-update.log | tail -n 20
    echo
    read -r -p "¿Intentar reparar repositorios de una distribucion EOL? [s/N]: " ans
    case "${ans:-n}" in
      s|S|y|Y) repair_eol_apt || return 1 ;;
      *) err "No se pueden instalar dependencias hasta reparar APT."; return 1 ;;
    esac
  fi

  DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs
  hash -r 2>/dev/null || true

  for c in curl sha256sum iptables python3 tar; do
    if ! have "$c"; then
      err "Dependencia faltante despues de instalar: $c"
      return 1
    fi
  done
  ok "Dependencias listas."
}

backup_veltrix() {
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" 2>/dev/null || true
  local stamp out list=()
  stamp="$(date +%Y%m%d-%H%M%S)"
  out="${BACKUP_DIR}/veltrix-${stamp}.tar.gz"

  [ -e /etc/proxy ] && list+=("/etc/proxy")
  [ -e /etc/vtproxy ] && list+=("/etc/vtproxy")
  [ -e /etc/udpgw ] && list+=("/etc/udpgw")
  [ -e /etc/proxy-version ] && list+=("/etc/proxy-version")
  [ -e /etc/udpgw-version ] && list+=("/etc/udpgw-version")
  [ -e /etc/vt-menu-revision ] && list+=("/etc/vt-menu-revision")

  if [ "${#list[@]}" -eq 0 ]; then
    warn "No hay configuracion Veltrix existente para respaldar."
    return 0
  fi

  tar -czf "$out" "${list[@]}" 2>/dev/null
  chmod 600 "$out"
  ok "Respaldo creado: $out"
}

download_official() {
  local target="$1" url="$2"
  curl --fail --location --silent --show-error \
    --connect-timeout 15 --retry 3 --retry-delay 2 \
    "${url}?$(date +%s)" -o "$target"
  [ -s "$target" ] || return 1
}

run_official_installer() {
  local mode="$1"
  local tmp
  tmp="$(mktemp /tmp/veltrix-install.XXXXXX.sh)"
  trap 'rm -f "$tmp"' RETURN

  info "Descargando instalador oficial VeltrixProxy..."
  download_official "$tmp" "$OFFICIAL_INSTALL" || {
    err "No se pudo descargar el instalador oficial."
    return 1
  }
  chmod 700 "$tmp"

  # Validaciones simples para evitar ejecutar HTML/error.
  if ! grep -q 'TelksBr/VeltrixProxy' "$tmp" || ! grep -q 'proxy-server' "$tmp"; then
    err "El archivo descargado no parece ser el instalador oficial esperado."
    return 1
  fi

  case "$mode" in
    install)
      info "Instalacion oficial interactiva..."
      bash "$tmp" --install --latest
      ;;
    update)
      backup_veltrix
      info "Actualizando proxy, udpgw y menu oficial..."
      bash "$tmp" --update --yes
      ;;
    reinstall)
      backup_veltrix
      info "Reinstalando binarios/menu y preservando configuraciones existentes..."
      bash "$tmp" --reinstall --latest --yes
      ;;
    *)
      err "Modo interno invalido: $mode"
      return 1
      ;;
  esac
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
    return 0
  fi
  return 1
}

enable_bbr_if_available() {
  modprobe tcp_bbr >/dev/null 2>&1 || true
  modprobe sch_fq >/dev/null 2>&1 || true

  local available
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if echo " $available " | grep -q ' bbr '; then
    append_sysctl_if_supported net.core.default_qdisc fq "Qdisc recomendado para BBR" || true
    append_sysctl_if_supported net.ipv4.tcp_congestion_control bbr "BBR disponible en este kernel" || true
    ok "BBR disponible y habilitado."
  else
    warn "BBR no existe en kernel $(uname -r). Se conserva el control de congestion actual."
  fi
}

apply_systemd_nofile() {
  if ! have systemctl; then
    warn "systemd no disponible; se aplicaran limites PAM/ulimit solamente."
    return 0
  fi

  local units=() u d
  while IFS= read -r u; do
    [ -n "$u" ] && units+=("$u")
  done < <(
    {
      systemctl list-unit-files --type=service --no-legend 'proxy-*.service' 2>/dev/null | awk '{print $1}'
      for d in /etc/systemd/system/proxy-*.service; do
        [ -f "$d" ] && basename "$d"
      done
    } | sort -u
  )

  for u in "${units[@]}"; do
    [ -n "$u" ] || continue
    d="/etc/systemd/system/${u}.d"
    mkdir -p "$d"
    cat > "${d}/99-veltrix-bhttp.conf" <<'EOF'
[Service]
LimitNOFILE=65536
EOF
  done

  systemctl daemon-reload >/dev/null 2>&1 || true
}

apply_bhttp_tuning() {
  info "Aplicando optimizacion BHTTP segura/adaptativa..."

  mkdir -p /etc/sysctl.d
  cat > "$BHTTP_SYSCTL" <<'EOF'
# VeltrixProxy BHTTP - generado automaticamente.
# Solo se agregan parametros presentes en el kernel actual.
EOF

  append_sysctl_if_supported net.ipv4.ip_forward 1 "Forwarding IPv4" || true
  append_sysctl_if_supported net.ipv4.tcp_tw_reuse 1 "Reutilizacion segura de sockets TIME_WAIT" || true
  append_sysctl_if_supported net.ipv4.tcp_fin_timeout 15 "Liberar sockets cerrados mas rapido" || true
  append_sysctl_if_supported net.ipv4.tcp_max_tw_buckets 131072 "Limite de TIME_WAIT" || true
  append_sysctl_if_supported net.ipv4.ip_local_port_range "10240 65535" "Mayor rango de puertos efimeros" || true
  append_sysctl_if_supported net.core.somaxconn 8192 "Cola de accept" || true
  append_sysctl_if_supported net.ipv4.tcp_max_syn_backlog 8192 "Cola SYN" || true
  append_sysctl_if_supported net.core.netdev_max_backlog 8192 "Backlog de red" || true
  append_sysctl_if_supported net.ipv4.tcp_slow_start_after_idle 0 "Evita reiniciar cwnd tras pausas cortas" || true
  append_sysctl_if_supported net.ipv4.tcp_fastopen 3 "TCP Fast Open cliente/servidor" || true
  append_sysctl_if_supported net.core.rmem_default 65536 "Buffer RX inicial" || true
  append_sysctl_if_supported net.core.wmem_default 65536 "Buffer TX inicial" || true
  append_sysctl_if_supported net.core.rmem_max 8388608 "Buffer RX max 8 MiB" || true
  append_sysctl_if_supported net.core.wmem_max 8388608 "Buffer TX max 8 MiB" || true
  append_sysctl_if_supported net.ipv4.tcp_rmem "4096 87380 8388608" "TCP RX autotuning" || true
  append_sysctl_if_supported net.ipv4.tcp_wmem "4096 65536 8388608" "TCP TX autotuning" || true

  enable_bbr_if_available

  if [ -d /etc/security ]; then
    mkdir -p /etc/security/limits.d
    cat > "$BHTTP_LIMITS" <<'EOF'
# VeltrixProxy BHTTP - limites de archivos/sockets
* soft nofile 65536
* hard nofile 65536
root soft nofile 65536
root hard nofile 65536
EOF
  fi

  ulimit -n 65536 2>/dev/null || true
  apply_systemd_nofile

  sysctl -p "$BHTTP_SYSCTL" >/dev/null 2>&1 || true
  ok "Optimizacion BHTTP aplicada."
}

remove_bhttp_tuning() {
  warn "Esto solo elimina los ajustes creados por ESTE manager."
  read -r -p "¿Eliminar tuning BHTTP local? [s/N]: " ans
  case "${ans:-n}" in s|S|y|Y) ;; *) return 0 ;; esac

  rm -f "$BHTTP_SYSCTL" "$BHTTP_LIMITS"
  if have systemctl; then
    local d
    for d in /etc/systemd/system/proxy-*.service.d; do
      [ -d "$d" ] || continue
      rm -f "$d/99-veltrix-bhttp.conf"
      rmdir "$d" 2>/dev/null || true
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  sysctl --system >/dev/null 2>&1 || true
  ok "Tuning local eliminado. Reinicia la VPS para restaurar completamente valores runtime previos."
}

proxy_version() {
  if [ -x /usr/local/bin/proxy-server ]; then
    /usr/local/bin/proxy-server --version 2>/dev/null | head -n1 || true
  elif [ -f /etc/proxy-version ]; then
    cat /etc/proxy-version
  else
    echo "no instalado"
  fi
}

show_status() {
  header
  echo -e "${BOLD}Diagnostico Veltrix/BHTTP${NC}"
  echo "--------------------------------------------------------------"
  echo "OS          : $OS_PRETTY"
  echo "Kernel      : $(uname -r)"
  echo "Bash        : $BASH_VERSION"
  echo "Arquitectura: $(uname -m)"
  echo "Proxy       : $(proxy_version)"
  echo "Menu vt     : $( [ -x /usr/local/bin/vt ] && echo instalado || echo no-instalado )"
  echo "ulimit -n   : $(ulimit -n 2>/dev/null || echo '?')"
  echo "TCP CC      : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  echo "Qdisc       : $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
  echo "Port range  : $(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || echo '?')"
  echo "somaxconn   : $(sysctl -n net.core.somaxconn 2>/dev/null || echo '?')"
  echo "TIME_WAIT   : $(ss -ant state time-wait 2>/dev/null | tail -n +2 | wc -l 2>/dev/null || echo '?')"
  echo

  if have systemctl; then
    echo -e "${BOLD}Servicios proxy:${NC}"
    systemctl list-units --type=service --all --no-legend 'proxy-*.service' 2>/dev/null || true
    echo
    echo -e "${BOLD}Servicios UDPgw:${NC}"
    systemctl list-units --type=service --all --no-legend 'udpgw*.service' 2>/dev/null || true
  fi
  echo

  echo -e "${BOLD}Puertos escuchando (proxy/ssh/openvpn/v2ray):${NC}"
  if have ss; then
    ss -lntup 2>/dev/null | grep -E 'proxy-server|sshd|openvpn|v2ray|:22 |:53 |:80 |:443 |:1194 ' || true
  else
    netstat -lntup 2>/dev/null | grep -E 'proxy-server|sshd|openvpn|v2ray|:22 |:53 |:80 |:443 |:1194 ' || true
  fi
}

restart_services() {
  if ! have systemctl; then
    err "systemd no esta disponible."
    return 1
  fi

  local found=0 u
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    found=1
    info "Reiniciando $u"
    systemctl restart "$u" || warn "Fallo: $u"
  done < <(
    {
      systemctl list-unit-files --type=service --no-legend 'proxy-*.service' 2>/dev/null | awk '{print $1}'
      systemctl list-unit-files --type=service --no-legend 'udpgw*.service' 2>/dev/null | awk '{print $1}'
    } | sort -u
  )

  [ "$found" -eq 1 ] && ok "Reinicio solicitado." || warn "No se encontraron services Veltrix."
}

show_logs() {
  if ! have journalctl; then
    err "journalctl no disponible."
    return 1
  fi
  echo
  echo "1) Proxy (ultimas 100 lineas)"
  echo "2) UDPgw (ultimas 100 lineas)"
  echo "3) Seguir logs del proxy en vivo"
  echo "0) Volver"
  read -r -p "Opcion: " op
  case "$op" in
    1)
      journalctl --no-pager -n 100 $(systemctl list-unit-files --type=service --no-legend 'proxy-*.service' 2>/dev/null | awk '{print "-u "$1}') 2>/dev/null || true
      ;;
    2)
      journalctl --no-pager -n 100 $(systemctl list-unit-files --type=service --no-legend 'udpgw*.service' 2>/dev/null | awk '{print "-u "$1}') 2>/dev/null || true
      ;;
    3)
      journalctl -f $(systemctl list-unit-files --type=service --no-legend 'proxy-*.service' 2>/dev/null | awk '{print "-u "$1}') 2>/dev/null || true
      ;;
  esac
}

open_vt() {
  if [ -x /usr/local/bin/vt ]; then
    exec /usr/local/bin/vt
  fi

  warn "Menu vt no encontrado. ¿Descargar solamente vt.sh oficial?"
  read -r -p "[s/N]: " ans
  case "${ans:-n}" in
    s|S|y|Y)
      download_official /usr/local/bin/vt "$OFFICIAL_MENU" || {
        err "No se pudo descargar vt.sh"
        return 1
      }
      chmod 755 /usr/local/bin/vt
      exec /usr/local/bin/vt
      ;;
  esac
}

menu() {
  while true; do
    header
    echo -e "${BOLD} 1)${NC} Instalar VeltrixProxy (latest, oficial)"
    echo -e "${BOLD} 2)${NC} Actualizar VeltrixProxy + UDPgw + menu"
    echo -e "${BOLD} 3)${NC} Reinstalar/repair VeltrixProxy"
    echo -e "${BOLD} 4)${NC} Aplicar/actualizar optimizacion BHTTP"
    echo -e "${BOLD} 5)${NC} Diagnostico completo"
    echo -e "${BOLD} 6)${NC} Reiniciar servicios Veltrix"
    echo -e "${BOLD} 7)${NC} Ver logs"
    echo -e "${BOLD} 8)${NC} Abrir menu oficial: vt"
    echo -e "${BOLD} 9)${NC} Crear respaldo manual"
    echo -e "${BOLD}10)${NC} Reparar APT de Ubuntu/Debian EOL"
    echo -e "${BOLD}11)${NC} Quitar tuning creado por este manager"
    echo -e "${BOLD} 0)${NC} Salir"
    echo
    read -r -p "Selecciona una opcion: " op
    case "$op" in
      1)
        ensure_dependencies && run_official_installer install && apply_bhttp_tuning
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
      4) apply_bhttp_tuning; pause ;;
      5) show_status; pause ;;
      6) restart_services; pause ;;
      7) show_logs; pause ;;
      8) open_vt ;;
      9) backup_veltrix; pause ;;
      10) repair_eol_apt; pause ;;
      11) remove_bhttp_tuning; pause ;;
      0) exit 0 ;;
      *) warn "Opcion invalida."; sleep 1 ;;
    esac
  done
}

main() {
  require_root
  load_os
  check_minimum_os

  case "${1:-}" in
    --install)
      ensure_dependencies
      run_official_installer install
      apply_bhttp_tuning
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
    --tune)
      apply_bhttp_tuning
      ;;
    --diagnose)
      show_status
      ;;
    --help|-h)
      cat <<EOF
VeltrixProxy BHTTP Manager v${SCRIPT_VERSION}

Uso:
  bash $0                 Menu interactivo
  bash $0 --install       Instalar latest + tuning BHTTP
  bash $0 --update        Actualizar + tuning BHTTP
  bash $0 --reinstall     Reinstalar + tuning BHTTP
  bash $0 --tune          Aplicar tuning BHTTP
  bash $0 --diagnose      Mostrar diagnostico

Compatibilidad:
  Ubuntu 14.04 o superior
  Debian 8 o superior

Nota:
  El soporte real del binario VeltrixProxy depende de los artefactos que
  publique el proyecto oficial para la arquitectura de la VPS.
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

