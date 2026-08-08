#!/usr/bin/env bash
# REV26: BASE REV26 ESTABLE + FAST BUNDLE OPCIONAL + UI MODERNA
# INSTALADOR GOLDEN SYSTEM PRO
# Compatible con Ubuntu/Debian basados en APT, desde versiones antiguas con
# systemd hasta versiones modernas. Usa los archivos locales si están junto al
# instalador; si no, los descarga del repositorio configurado.

set -Eeuo pipefail
umask 022

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export LC_ALL=C
export LANG=C

REPO_DEFAULT="https://raw.githubusercontent.com/satanas66666/golden-system2/main"
REPO="${GOLDEN_REPO:-$REPO_DEFAULT}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP_DIR=""
LOG_FILE="/var/log/golden-installer.log"
BACKUP_DIR=""
# El protocolo heredado de instalación espera Apache en 81. El puerto de
# keys sí viaja dentro de la key y puede personalizarse.
PORT_FILES="81"
PORT_KEYS="${GOLDEN_HTTP_PORT:-8888}"
declare -a APT_DISABLED_FILES=()

C_RESET=$'\033[0m'
C_RED=$'\033[1;31m'
C_GREEN=$'\033[1;32m'
C_YELLOW=$'\033[1;33m'
C_CYAN=$'\033[1;36m'

log() {
    local level="$1"
    shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" | tee -a "$LOG_FILE"
}
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
die() { log ERROR "$@"; exit 1; }

restore_extra_sources() {
    local item original disabled
    for item in "${APT_DISABLED_FILES[@]:-}"; do
        original="${item%%|*}"
        disabled="${item#*|}"
        [[ -e "$disabled" && ! -e "$original" ]] && mv -f -- "$disabled" "$original" 2>/dev/null || true
    done
    APT_DISABLED_FILES=()
}

cleanup() {
    local rc=$?
    restore_extra_sources
    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf -- "$TMP_DIR"
    if (( rc != 0 )); then
        echo -e "${C_RED}Instalación interrumpida. Revisa: $LOG_FILE${C_RESET}" >&2
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'die "Error en línea $LINENO: $BASH_COMMAND"' ERR

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Ejecuta el instalador como root."
}

load_os() {
    OS_ID=""
    OS_LIKE=""
    OS_VERSION=""
    OS_CODENAME=""
    PRETTY_NAME=""

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_LIKE="${ID_LIKE:-}"
        OS_VERSION="${VERSION_ID:-}"
        OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
        PRETTY_NAME="${PRETTY_NAME:-}"
    elif [[ -r /etc/lsb-release ]]; then
        # Ubuntu antiguos (por ejemplo 10.04/12.04).
        # shellcheck disable=SC1091
        . /etc/lsb-release
        OS_ID="ubuntu"
        OS_LIKE="debian"
        OS_VERSION="${DISTRIB_RELEASE:-}"
        OS_CODENAME="${DISTRIB_CODENAME:-}"
        PRETTY_NAME="${DISTRIB_DESCRIPTION:-Ubuntu $OS_VERSION}"
    elif [[ -r /etc/debian_version ]]; then
        OS_ID="debian"
        OS_LIKE=""
        OS_VERSION="$(cut -d/ -f1 /etc/debian_version | sed 's/[^0-9.].*$//')"
        OS_CODENAME=""
        PRETTY_NAME="Debian $OS_VERSION"
    else
        die "No se pudo identificar Ubuntu/Debian."
    fi

    OS_ID="${OS_ID,,}"
    OS_LIKE="${OS_LIKE,,}"
    OS_VERSION="${OS_VERSION:-0}"
    case " $OS_ID $OS_LIKE " in
        *" ubuntu "*|*" debian "*) ;;
        *) die "Sistema no compatible: ${PRETTY_NAME:-$OS_ID}. Solo Ubuntu/Debian." ;;
    esac

    ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    info "Sistema detectado: ${PRETTY_NAME:-$OS_ID $OS_VERSION}; arquitectura: $ARCH"

    case "$ARCH" in
        amd64|x86_64) ;;
        *)
            warn "El núcleo Bash/Python se instalará, pero 25 herramientas heredadas son ELF x86_64."
            warn "En $ARCH esas herramientas concretas no pueden ejecutarse sin su código fuente."
            ;;
    esac

    (( BASH_VERSINFO[0] >= 4 )) || die "Se requiere Bash 4 o superior."
}

apt_lock_pids() {
    # Detecta propietarios REALES de los locks. No usa pgrep como primera
    # opción porque unattended-upgrades o procesos zombie pueden existir sin
    # bloquear APT y provocar esperas falsas.
    local -a locks=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
    )
    local f pids=""

    if command -v fuser >/dev/null 2>&1; then
        pids=$(fuser "${locks[@]}" 2>/dev/null || true)
    elif command -v lsof >/dev/null 2>&1; then
        pids=$(lsof -t -- "${locks[@]}" 2>/dev/null || true)
    else
        # No adivinar por nombre de proceso: unattended-upgrade-shutdown puede
        # vivir durante días sin poseer ningún lock. apt-get aplicará su propio
        # DPkg::Lock::Timeout si fuser/lsof todavía no están instalados.
        pids=""
    fi

    for f in $pids; do
        [[ "$f" =~ ^[0-9]+$ ]] && printf '%s\n' "$f"
    done | sort -un
}

wait_for_apt() {
    local waited=0 max_wait=600 pids shown=""

    while :; do
        pids=$(apt_lock_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        [[ -z "$pids" ]] && {
            (( waited > 0 )) && printf '\n'
            return 0
        }

        if [[ "$pids" != "$shown" || $((waited % 15)) -eq 0 ]]; then
            (( waited > 0 )) && printf '\n'
            info "APT/DPKG ocupado por PID(s): $pids. Esperando sin borrar locks..."
            ps -o pid=,stat=,etime=,comm= -p ${pids// /,} 2>/dev/null | tee -a "$LOG_FILE" || true
            shown="$pids"
        fi

        printf '\rEsperando APT/DPKG: %3ss / %3ss' "$waited" "$max_wait"
        sleep 3
        waited=$((waited + 3))

        if (( waited >= max_wait )); then
            printf '\n'
            warn "APT/DPKG continúa ocupado después de ${max_wait}s."
            warn "No se borraron locks ni se mataron procesos. Revisa: ps aux | grep -E '[a]pt|[d]pkg|unattended'"
            return 1
        fi
    done
}

backup_sources() {
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "/var/backups/golden-apt-$ts"
    cp -a /etc/apt/sources.list "/var/backups/golden-apt-$ts/" 2>/dev/null || true
    cp -a /etc/apt/sources.list.d "/var/backups/golden-apt-$ts/" 2>/dev/null || true
}

ubuntu_is_archived() {
    case "$OS_VERSION" in
        10.*|11.*|12.04|12.10|13.*|14.04|14.10|15.*|16.04|16.10|17.*|18.04|18.10|19.*|20.04|20.10|21.*|22.10|23.*|24.10|25.*) return 0 ;;
        *) return 1 ;;
    esac
}

debian_is_archived() {
    local major="${OS_VERSION%%.*}"
    [[ "$major" =~ ^[0-9]+$ ]] && (( major <= 10 ))
}

repair_eol_sources() {
    local f changed=0
    if [[ "$OS_ID" == "ubuntu" ]] && ubuntu_is_archived; then
        warn "La versión Ubuntu $OS_VERSION está archivada; ajustando mirrors a old-releases."
        backup_sources
        for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
            [[ -f "$f" ]] || continue
            sed -Ei \
                -e 's#https?://([a-z]{2}\.)?archive\.ubuntu\.com/ubuntu/?#http://old-releases.ubuntu.com/ubuntu/#g' \
                -e 's#https?://security\.ubuntu\.com/ubuntu/?#http://old-releases.ubuntu.com/ubuntu/#g' \
                -e 's#https?://ports\.ubuntu\.com/ubuntu-ports/?#http://old-releases.ubuntu.com/ubuntu/#g' \
                "$f"
            if [[ "$f" == /etc/apt/sources.list.d/* ]]; then
                sed -Ei '/^[[:space:]]*deb / { /old-releases\.ubuntu\.com/! s/^/# Golden EOL: /; }' "$f"
            fi
            changed=1
        done
        mkdir -p /etc/apt/apt.conf.d
        cat >/etc/apt/apt.conf.d/99golden-archive <<'EOF'
Acquire::Check-Valid-Until "false";
EOF
    elif [[ "$OS_ID" == "debian" ]] && debian_is_archived; then
        warn "La versión Debian $OS_VERSION está archivada; ajustando mirrors a archive.debian.org."
        backup_sources
        for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
            [[ -f "$f" ]] || continue
            sed -Ei \
                -e 's#https?://(deb|ftp)\.debian\.org/debian/?#http://archive.debian.org/debian/#g' \
                -e 's#https?://[a-z]{2}\.deb\.debian\.org/debian/?#http://archive.debian.org/debian/#g' \
                -e 's#https?://ftp\.[a-z]{2}\.debian\.org/debian/?#http://archive.debian.org/debian/#g' \
                -e 's#https?://httpredir\.debian\.org/debian/?#http://archive.debian.org/debian/#g' \
                -e 's#https?://security\.debian\.org/debian-security/?#http://archive.debian.org/debian-security/#g' \
                -e 's#https?://security\.debian\.org/?#http://archive.debian.org/debian-security/#g' \
                "$f"
            # updates/backports antiguos suelen desaparecer del archivo.
            sed -Ei '/^[[:space:]]*deb .*-(updates|backports)[[:space:]]/ s/^/# Golden EOL: /' "$f"
            if [[ "$f" == /etc/apt/sources.list.d/* ]]; then
                sed -Ei '/^[[:space:]]*deb / { /archive\.debian\.org/! s/^/# Golden EOL: /; }' "$f"
            fi
            changed=1
        done
        cat >/etc/apt/apt.conf.d/99golden-archive <<'EOF'
Acquire::Check-Valid-Until "false";
Acquire::AllowInsecureRepositories "true";
APT::Get::AllowUnauthenticated "false";
EOF
    fi
    return $((changed == 0))
}

temporarily_disable_extra_sources() {
    local f disabled content
    for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        content="$(tr '[:upper:]' '[:lower:]' <"$f" 2>/dev/null || true)"
        # Conserva fuentes oficiales de la distribución. Los repositorios de
        # proveedores se apartan solamente durante esta instalación.
        if [[ "$content" == *ubuntu.com/ubuntu* ||
              "$content" == *debian.org/debian* ||
              "$content" == *debian.org/debian-security* ||
              "$content" == *old-releases.ubuntu.com* ||
              "$content" == *archive.debian.org* ]]; then
            continue
        fi
        disabled="${f}.golden-disabled.$$"
        mv -f -- "$f" "$disabled" || continue
        APT_DISABLED_FILES+=("$f|$disabled")
        warn "Fuente adicional apartada temporalmente: $f"
    done
}

apt_update() {
    wait_for_apt
    if apt-get -o DPkg::Lock::Timeout=600 -o Acquire::Retries=2 -o Acquire::http::Timeout=25 -o Acquire::https::Timeout=25 update >>"$LOG_FILE" 2>&1; then
        return 0
    fi

    warn "apt-get update falló; reintentando sin repositorios adicionales."
    backup_sources
    temporarily_disable_extra_sources
    wait_for_apt
    if apt-get -o DPkg::Lock::Timeout=600 -o Acquire::Retries=2 -o Acquire::http::Timeout=25 -o Acquire::https::Timeout=25 update >>"$LOG_FILE" 2>&1; then
        return 0
    fi

    warn "APT sigue fallando; comprobando si la distribución es EOL."
    if ! repair_eol_sources; then
        die "APT falló y la versión no debe cambiarse a mirrors archivados. Revisa red/DNS y $LOG_FILE."
    fi
    wait_for_apt
    apt-get -o DPkg::Lock::Timeout=600 -o Acquire::Retries=2 -o Acquire::http::Timeout=25 -o Acquire::https::Timeout=25 -o Acquire::Check-Valid-Until=false update >>"$LOG_FILE" 2>&1 ||
        die "APT sigue fallando después de reparar mirrors EOL."
}

pkg_available() {
    local candidate
    candidate="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

install_packages() {
    # "required" es el núcleo real. El resto se instala cuando existe en la
    # versión concreta, evitando que un paquete renombrado aborte todo.
    local -a required=(
        bash ca-certificates curl wget unzip tar gzip
        bc screen lsof procps psmisc openssl apache2 util-linux
        coreutils findutils grep sed perl passwd
    )
    local -a optional=(
        zip xz-utils nano less net-tools gnupg gpgv jq socat python3 cron
        iptables sudo locales lsb-release
        apt-transport-https software-properties-common
    )
    local -a install_list=()
    local p ip_pkg=""

    for p in "${required[@]}"; do
        pkg_available "$p" || die "Paquete requerido no disponible: $p"
        install_list+=("$p")
    done

    # El paquete se llamó iproute en releases antiguas e iproute2 en modernas.
    if pkg_available iproute2; then
        ip_pkg="iproute2"
    elif pkg_available iproute; then
        ip_pkg="iproute"
    else
        die "No está disponible iproute2/iproute."
    fi
    install_list+=("$ip_pkg")

    for p in "${optional[@]}"; do
        pkg_available "$p" && install_list+=("$p")
    done

    mkdir -p /etc/apt/apt.conf.d
    cat >/etc/apt/apt.conf.d/99golden-lock-timeout <<'EOF'
DPkg::Lock::Timeout "300";
APT::Get::Assume-Yes "true";
EOF

    wait_for_apt
    info "Instalando dependencias disponibles..."
    apt-get -o DPkg::Lock::Timeout=600 -o Acquire::Retries=2 \
        -o Acquire::http::Timeout=25 -o Acquire::https::Timeout=25 \
        -o Dpkg::Options::=--force-confold \
        install -y --no-install-recommends "${install_list[@]}" >>"$LOG_FILE" 2>&1 ||
        die "No se pudieron instalar dependencias. Revisa $LOG_FILE."

    update-ca-certificates >>"$LOG_FILE" 2>&1 || true

    if ! command -v socat >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
        die "Se necesita socat o python3 para el servidor de keys."
    fi
}

download_file() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 4 --retry-delay 2 --connect-timeout 15 "$url" -o "$out"
    else
        wget --tries=4 --timeout=20 -O "$out" "$url"
    fi
}

prepare_artifacts() {
    local local_zip="$SCRIPT_DIR/golden.zip"
    local local_http="$SCRIPT_DIR/http-server.sh"

    ZIP_FILE="$TMP_DIR/golden.zip"
    HTTP_FILE="$TMP_DIR/http-server.sh"

    if [[ -s "$local_zip" ]]; then
        info "Usando golden.zip local."
        cp -f "$local_zip" "$ZIP_FILE"
    else
        info "Descargando golden.zip desde el repositorio."
        download_file "$REPO/golden.zip" "$ZIP_FILE" >>"$LOG_FILE" 2>&1 ||
            die "No se pudo descargar golden.zip."
    fi

    if [[ -s "$local_http" ]]; then
        info "Usando http-server.sh local."
        cp -f "$local_http" "$HTTP_FILE"
    else
        info "Descargando http-server.sh desde el repositorio."
        download_file "$REPO/http-server.sh" "$HTTP_FILE" >>"$LOG_FILE" 2>&1 ||
            die "No se pudo descargar http-server.sh."
    fi

    unzip -t "$ZIP_FILE" >>"$LOG_FILE" 2>&1 || die "golden.zip está dañado."
    bash -n "$HTTP_FILE" || die "http-server.sh contiene errores de sintaxis."

    mkdir -p "$TMP_DIR/extract"
    unzip -q -o "$ZIP_FILE" -d "$TMP_DIR/extract"
    [[ -d "$TMP_DIR/extract/golden/SCRIPT" ]] || die "El ZIP no contiene golden/SCRIPT."
    [[ -f "$TMP_DIR/extract/golden/gerar.sh" ]] || die "El ZIP no contiene golden/gerar.sh."
    bash -n "$TMP_DIR/extract/golden/gerar.sh" || die "gerar.sh contiene errores de sintaxis."

    # REV26: el instalador no continúa con un catálogo incompleto o mezclado.
    local -a required_payloads=(
      menu PGet.py ports.sh badvpn.sh ADMbot.sh message.txt usercodes websocket.sh
      POpen.py PPriv.py PPub.py PDirect.py speedtest.py speed.sh utils.sh
      dropbear.sh apacheon.sh openvpn.sh shadowsocks.sh ssl.sh squid.sh dados.sh
      Crear-Demo.sh squidpass.sh htop.sh gestor.sh proxygo.sh cambiarpass.sh
      Proxy-Publico.py Proxy-Privado.py haproxy.sh hysteria.sh hora.sh panelweb.sh
      optimizar.sh v2ray.sh passvulrt.sh nload.sh bbr.sh ban_iptables.sh slowdns.sh
      proxy_manager.sh compat.sh
    )
    local payload
    for payload in "${required_payloads[@]}"; do
        [[ -f "$TMP_DIR/extract/golden/SCRIPT/$payload" ]] ||
            die "golden.zip incompleto: falta $payload."
    done
    [[ "$(tr -d '\r\n ' <"$TMP_DIR/extract/golden/.golden_revision" 2>/dev/null || true)" == "REV26" ]] ||
        die "golden.zip no corresponde a REV26; evita mezclar revisiones."
}

backup_current() {
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    BACKUP_DIR="/var/backups/golden-$ts"
    mkdir -p "$BACKUP_DIR"
    for p in /etc/SCRIPT /etc/golden /usr/local/bin/gerar /usr/local/lib/golden /etc/systemd/system/golden-http.service; do
        [[ -e "$p" ]] && cp -a "$p" "$BACKUP_DIR/" 2>/dev/null || true
    done
    info "Respaldo anterior: $BACKUP_DIR"
}

install_files() {
    local src="$TMP_DIR/extract/golden"
    local p name

    mkdir -p /etc/SCRIPT /etc/http-shell /etc/golden /etc/default \
        /etc/newadm/ger-user /etc/ger-frm /etc/ger-inst /etc/nanotxz \
        /usr/local/bin /usr/local/lib/golden /var/log /var/www/golden

    # Sustitución atómica del catálogo, sin dejar archivos de versiones anteriores.
    rm -rf /etc/SCRIPT.new
    mkdir -p /etc/SCRIPT.new
    for p in "$src/SCRIPT"/*; do
        [[ -f "$p" ]] || continue
        name="${p##*/}"
        install -m 0755 "$p" "/etc/SCRIPT.new/$name"
    done
    rm -rf /etc/SCRIPT.old
    [[ -d /etc/SCRIPT ]] && mv /etc/SCRIPT /etc/SCRIPT.old
    mv /etc/SCRIPT.new /etc/SCRIPT
    rm -rf /etc/SCRIPT.old

    install -m 0755 "$src/gerar.sh" /usr/local/bin/gerar
    install -m 0755 "$HTTP_FILE" /usr/local/lib/golden/http-server.sh

    ln -sfn /usr/local/bin/gerar /usr/bin/gerar
    ln -sfn /usr/local/bin/gerar /usr/bin/gerar.sh
    ln -sfn /usr/local/lib/golden/http-server.sh /usr/bin/http-server.sh

    # /bin puede estar fusionado con /usr/bin; ln -sfn sigue siendo idempotente.
    ln -sfn /usr/local/bin/gerar /bin/gerar
    ln -sfn /usr/local/lib/golden/http-server.sh /bin/http-server.sh

    printf '%s\n' "$REPO" >/etc/golden/repo
    cat >/etc/default/golden-http <<EOF
GOLDEN_HTTP_PORT=$PORT_KEYS
GOLDEN_FILES_PORT=$PORT_FILES
GOLDEN_STAGE_TTL=180
GOLDEN_WEB_ROOT=/var/www/golden
GOLDEN_ALT_WEB_ROOT=/var/www/golden
EOF

    [[ -f /etc/http-instas ]] || printf '0\n' >/etc/http-instas
    touch /etc/gerar-sh-log /var/log/golden-http.log
    chmod 700 /etc/SCRIPT /etc/http-shell /etc/golden
    chmod 600 /etc/http-instas /etc/gerar-sh-log /var/log/golden-http.log
    # Una instalación/reinstalación deja el servidor habilitado por defecto.
    rm -f /etc/golden/server-disabled
}

port_owner() {
    local port="$1" out=""
    if command -v ss >/dev/null 2>&1; then
        out="$(ss -ltnp 2>/dev/null | awk -v p=":$port" 'NR > 1 && index($4,p) {print; exit}')"
    fi
    if [[ -z "$out" ]] && command -v lsof >/dev/null 2>&1; then
        out="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR == 2 {print; exit}')"
    fi
    printf '%s' "$out"
}


# REV26: el Apache del generador no debe reservar TCP 80. La entrega de
# archivos Golden usa únicamente TCP 81; TCP 80 queda disponible para otros
# servicios/protocolos del administrador.
apache_force_port_81_configs() {
    local root="/etc/apache2"
    local backup="/var/backups/golden-generator-apache81-$(date +%Y%m%d-%H%M%S).tar.gz"
    [[ -d "$root" && -f "$root/ports.conf" ]] || return 1
    mkdir -p /var/backups
    tar -C /etc -czf "$backup" apache2 >>"$LOG_FILE" 2>&1 || return 1

    python3 - "$root" <<'PYAPACHE'
from pathlib import Path
import re, sys
root=Path(sys.argv[1])
files=[]
p=root/'ports.conf'
if p.exists(): files.append(p)
for dname in ('conf-available','conf-enabled','sites-available','sites-enabled'):
    d=root/dname
    if d.is_dir(): files.extend(x for x in d.iterdir() if x.is_file() or x.is_symlink())
seen=set()
for p in files:
    try: rp=p.resolve()
    except Exception: rp=p
    if rp in seen or not rp.exists() or not rp.is_file(): continue
    seen.add(rp)
    try: text=rp.read_text(encoding='utf-8')
    except UnicodeDecodeError: continue
    out=[]; changed=False
    for line in text.splitlines(True):
        body=line.rstrip('\r\n'); nl=line[len(body):]
        m=re.match(r'^(\s*Listen\s+)80(\s*(?:#.*)?)$', body, re.I)
        m2=re.match(r'^(\s*Listen\s+)(\[[^\]]+\]|[^\s:]+):80(\s*(?:#.*)?)$', body, re.I)
        if m or m2:
            out.append('# Golden REV26: movido a TCP 81 | '+body+nl); changed=True; continue
        if re.match(r'^\s*NameVirtualHost\s+', body, re.I) and ':80' in body:
            body=re.sub(r':80(?=\s|$)', ':81', body); changed=True
        if re.match(r'^\s*<VirtualHost\s+', body, re.I) and ':80' in body:
            body=re.sub(r':80(?=\s|>)', ':81', body); changed=True
        out.append(body+nl)
    if changed: rp.write_text(''.join(out), encoding='utf-8')
ports=root/'ports.conf'
text=ports.read_text(encoding='utf-8', errors='ignore')
active=False
for ln in text.splitlines():
    if ln.lstrip().startswith('#'): continue
    if re.match(r'^\s*Listen\s+(?:\[[^\]]+\]:|[^\s:]+:)?81\s*(?:#.*)?$', ln, re.I): active=True; break
if not active:
    with ports.open('a',encoding='utf-8') as f:
        f.write('\n# Golden System PRO REV26 - Apache exclusivo en TCP 81\nListen 81\n')
PYAPACHE
}

apache_is_on_port() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -H -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" && $0 ~ /apache2/ {found=1} END{exit !found}'
        return $?
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 && $1 ~ /^apache2?$/ {found=1} END{exit !found}'
        return $?
    fi
    return 2
}

configure_apache() {
    local ports_conf=/etc/apache2/ports.conf owner
    [[ -f "$ports_conf" ]] || die "Apache no instaló ports.conf."

    apache_force_port_81_configs || die "No se pudo reservar Apache exclusivamente para TCP 81."

    owner="$(port_owner "$PORT_FILES" || true)"
    if [[ -n "$owner" && "$owner" != *apache2* ]]; then
        die "El puerto $PORT_FILES está ocupado por otro proceso: $owner"
    fi

    local apache_ver access_rules
    apache_ver="$(apache2 -v 2>/dev/null | awk -F/ '/Server version/{print $2}' | awk '{print $1}')"
    if [[ "$apache_ver" == 2.2* ]]; then
        access_rules=$'        Order allow,deny\n        Allow from all'
    else
        access_rules=$'        Require all granted'
    fi

    cat >/etc/apache2/sites-available/golden-files.conf <<EOF
<VirtualHost *:${PORT_FILES}>
    ServerName localhost
    DocumentRoot /var/www/golden
    <Directory /var/www/golden>
        Options -Indexes +FollowSymLinks
        AllowOverride None
${access_rules}
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/golden-error.log
    CustomLog \${APACHE_LOG_DIR}/golden-access.log combined
</VirtualHost>
EOF

    if command -v a2ensite >/dev/null 2>&1; then
        a2ensite golden-files.conf >>"$LOG_FILE" 2>&1 || true
    else
        ln -sfn ../sites-available/golden-files.conf /etc/apache2/sites-enabled/golden-files.conf
    fi

    apache2ctl configtest >>"$LOG_FILE" 2>&1 || die "Configuración Apache inválida."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable apache2 >>"$LOG_FILE" 2>&1 || true
        systemctl restart apache2 >>"$LOG_FILE" 2>&1 ||
            service apache2 restart >>"$LOG_FILE" 2>&1 ||
            die "No se pudo iniciar Apache."
    else
        service apache2 restart >>"$LOG_FILE" 2>&1 || /etc/init.d/apache2 restart >>"$LOG_FILE" 2>&1 ||
            die "No se pudo iniciar Apache."
    fi

    apache_is_on_port "$PORT_FILES" || die "Apache no quedó escuchando en TCP $PORT_FILES."
    if apache_is_on_port 80; then
        die "Apache sigue reservando TCP 80; se aborta para no bloquear ese puerto."
    fi
    info "Apache verificado: TCP $PORT_FILES activo y TCP 80 libre de Apache."
}

install_service() {
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        cat >/etc/systemd/system/golden-http.service <<'EOF'
[Unit]
Description=Golden System PRO key server
After=network-online.target apache2.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/golden-http
ExecStartPre=/usr/local/lib/golden/http-server.sh --check
ExecStart=/usr/local/lib/golden/http-server.sh --listen
Restart=always
RestartSec=2
TimeoutStartSec=30
TimeoutStopSec=10
KillMode=mixed
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable golden-http.service >>"$LOG_FILE" 2>&1
        systemctl restart golden-http.service >>"$LOG_FILE" 2>&1 ||
            warn "No se pudo iniciar golden-http con systemd; puedes iniciarlo desde 'gerar'."
    else
        cat >/etc/init.d/golden-http <<'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          golden-http
# Required-Start:    $network $remote_fs
# Required-Stop:     $network $remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Golden System PRO key server
### END INIT INFO
PIDFILE=/var/run/golden-http.pid
DAEMON=/usr/local/lib/golden/http-server.sh
if [ -r /etc/default/golden-http ]; then
  set -a
  . /etc/default/golden-http
  set +a
fi
case "$1" in
  start)
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && exit 0
    nohup "$DAEMON" --listen >/var/log/golden-http-console.log 2>&1 &
    echo $! >"$PIDFILE"
    ;;
  stop)
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
    ;;
  restart) "$0" stop; sleep 1; "$0" start ;;
  status)
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
    ;;
  *) echo "Uso: $0 {start|stop|restart|status}"; exit 2 ;;
esac
EOF
        chmod 0755 /etc/init.d/golden-http
        command -v update-rc.d >/dev/null 2>&1 && update-rc.d golden-http defaults >>"$LOG_FILE" 2>&1 || true
        /etc/init.d/golden-http restart >>"$LOG_FILE" 2>&1 ||
            warn "No se pudo iniciar golden-http; puedes iniciarlo desde 'gerar'."
    fi
}

install_watchdog() {
    # Autorecuperación: Restart=always cubre procesos muertos; este watchdog
    # también cubre un listener que sigue vivo pero dejó de responder.
    cat >/usr/local/lib/golden/golden-watchdog.sh <<'EOF'
#!/bin/sh
SERVER=/usr/local/lib/golden/http-server.sh
LOG=/var/log/golden-watchdog.log

# Respeta la opción manual "PARAR SERVIDOR" del menú.
[ -f /etc/golden/server-disabled ] && exit 0

if "$SERVER" --health >/dev/null 2>&1; then
    exit 0
fi

printf '%s listener sin respuesta; reiniciando golden-http\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$LOG" 2>/dev/null || true

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl restart golden-http.service >/dev/null 2>&1 || true
elif [ -x /etc/init.d/golden-http ]; then
    /etc/init.d/golden-http restart >/dev/null 2>&1 || true
elif command -v service >/dev/null 2>&1; then
    service golden-http restart >/dev/null 2>&1 || true
fi

sleep 2
if "$SERVER" --health >/dev/null 2>&1; then
    printf '%s listener recuperado correctamente\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$LOG" 2>/dev/null || true
    exit 0
fi
printf '%s ERROR listener sigue sin responder\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$LOG" 2>/dev/null || true
exit 1
EOF
    chmod 0755 /usr/local/lib/golden/golden-watchdog.sh
    touch /var/log/golden-watchdog.log
    chmod 0600 /var/log/golden-watchdog.log

    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        cat >/etc/systemd/system/golden-http-watchdog.service <<'EOF'
[Unit]
Description=Golden System PRO listener health check
After=golden-http.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/golden/golden-watchdog.sh
EOF
        cat >/etc/systemd/system/golden-http-watchdog.timer <<'EOF'
[Unit]
Description=Golden System PRO automatic listener recovery

[Timer]
OnBootSec=60s
OnUnitActiveSec=120s
AccuracySec=20s
Persistent=true
Unit=golden-http-watchdog.service

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload
        systemctl enable --now golden-http-watchdog.timer >>"$LOG_FILE" 2>&1 ||
            warn "No se pudo activar el watchdog systemd."
    else
        cat >/etc/cron.d/golden-http-watchdog <<'EOF'
*/2 * * * * root /usr/local/lib/golden/golden-watchdog.sh >/dev/null 2>&1
EOF
        chmod 0644 /etc/cron.d/golden-http-watchdog
        if command -v service >/dev/null 2>&1; then
            service cron restart >/dev/null 2>&1 || service crond restart >/dev/null 2>&1 || true
        fi
    fi
}

open_firewall_if_active() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow "$PORT_FILES/tcp" >>"$LOG_FILE" 2>&1 || true
        ufw allow "$PORT_KEYS/tcp" >>"$LOG_FILE" 2>&1 || true
        info "UFW activo: abiertos TCP $PORT_FILES y $PORT_KEYS."
    fi
}

self_test() {
    local rc=0
    bash -n /usr/local/bin/gerar || rc=1
    /usr/local/lib/golden/http-server.sh --check || rc=1
    apache2ctl configtest >>"$LOG_FILE" 2>&1 || rc=1

    sleep 1
    /usr/local/lib/golden/http-server.sh --health >/dev/null 2>&1 || rc=1
    local server_rev=""
    if command -v curl >/dev/null 2>&1; then
        server_rev=$(curl -fsS --connect-timeout 2 --max-time 4 http://127.0.0.1:8888/__golden_version 2>/dev/null || true)
    elif command -v wget >/dev/null 2>&1; then
        server_rev=$(wget -qO- --timeout=4 http://127.0.0.1:8888/__golden_version 2>/dev/null || true)
    fi
    [[ "$server_rev" == "REV26" ]] || { warn "Servidor esperado REV26, detectado: ${server_rev:-sin-respuesta}"; rc=1; }

    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        systemctl is-active --quiet apache2 || rc=1
        systemctl is-active --quiet golden-http.service || rc=1
        systemctl is-enabled --quiet golden-http-watchdog.timer || rc=1
    elif [[ -x /etc/init.d/golden-http ]]; then
        /etc/init.d/golden-http status >/dev/null 2>&1 || rc=1
    fi

    (( rc == 0 )) || die "La instalación terminó con fallos de autoprueba."
}

main() {
    require_root
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    echo -e "${C_CYAN}Instalando Golden System PRO...${C_RESET}"
    load_os

    TMP_DIR="$(mktemp -d /tmp/golden-install.XXXXXX)"
    apt_update
    install_packages
    prepare_artifacts
    backup_current
    install_files
    configure_apache
    install_service
    install_watchdog
    open_firewall_if_active
    self_test

    trap - ERR
    echo -e "${C_CYAN}--------------------------------------------------------------------${C_RESET}"
    echo -e "${C_GREEN} INSTALACION COMPLETA ✔${C_RESET}"
    echo -e "${C_YELLOW} Use el comando: ${C_RED}gerar${C_YELLOW} para generar keys.${C_RESET}"
    echo -e "${C_YELLOW} Apache archivos: TCP $PORT_FILES | Keys: TCP $PORT_KEYS${C_RESET}"
    echo -e "${C_YELLOW} Log: $LOG_FILE${C_RESET}"
    echo -e "${C_CYAN}--------------------------------------------------------------------${C_RESET}"
}

main "$@"
