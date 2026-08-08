#!/usr/bin/env bash
# GOLDEN ADM PRO - bootstrap REV6
# Compatible con Ubuntu/Debian con APT. Evita locks borrados y descargas infinitas.

export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

C_RESET='\033[0m'
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[1;36m'
NET_TIMEOUT="${GOLDEN_NET_TIMEOUT:-15}"
NET_TRIES="${GOLDEN_NET_TRIES:-3}"
SECOND_STAGE_URL="${GOLDEN_INSTALLER_URL:-https://raw.githubusercontent.com/satanas66666/golden-system2/refs/heads/main/LuciferMX2019.sh}"

if [[ $(id -u) -ne 0 ]]; then
    echo -e "${C_RED}Debes ser usuario root para ejecutar el instalador.${C_RESET}" >&2
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    echo -e "${C_RED}No se pudo identificar el sistema operativo.${C_RESET}" >&2
    exit 1
fi
. /etc/os-release
case "${ID:-}" in
    ubuntu|debian) ;;
    *)
        echo -e "${C_RED}Sistema no soportado: ${PRETTY_NAME:-${ID:-desconocido}}${C_RESET}" >&2
        exit 1
        ;;
esac

command -v apt-get >/dev/null 2>&1 || {
    echo -e "${C_RED}APT no está disponible.${C_RESET}" >&2
    exit 1
}

msg() {
    case "${1:-}" in
        info) echo -e "${C_CYAN}[•]${C_RESET} $2" ;;
        ok)   echo -e "${C_GREEN}[✓]${C_RESET} $2" ;;
        warn) echo -e "${C_YELLOW}[!]${C_RESET} $2" ;;
        err)  echo -e "${C_RED}[✗]${C_RESET} $2" ;;
    esac
}

wait_apt() {
    local waited=0 max_wait=300
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
        (( waited == 0 )) && msg info "Esperando a que APT/DPKG quede libre..."
        sleep 3
        waited=$((waited + 3))
        if (( waited >= max_wait )); then
            msg err "APT sigue ocupado después de ${max_wait}s. No se borraron locks para evitar dañar DPKG."
            return 1
        fi
    done
}

apt_run() {
    wait_apt || return 1
    if command -v timeout >/dev/null 2>&1; then
        timeout 900 apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 "$@"
    else
        apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 "$@"
    fi
}

safe_wget() {
    local url="$1" dest="$2" tmp="${dest}.part.$$"
    rm -f -- "$tmp"
    if command -v wget >/dev/null 2>&1; then
        wget -q -T "$NET_TIMEOUT" -t "$NET_TRIES" -O "$tmp" "$url" || { rm -f -- "$tmp"; return 1; }
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout "$NET_TIMEOUT" --max-time 60 --retry "$NET_TRIES" -o "$tmp" "$url" || { rm -f -- "$tmp"; return 1; }
    else
        return 1
    fi
    [[ -s "$tmp" ]] || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$dest"
}

clear 2>/dev/null || true
echo "======================================================================"
echo "             GOLDEN ADM PRO - INSTALADOR REV6"
echo "======================================================================"
echo "Sistema : ${PRETTY_NAME:-$ID}"
echo "Fase    : Preparando instalación"
echo "======================================================================"

msg info "Reconfigurando DPKG"
wait_apt || exit 1
dpkg --configure -a >/dev/null 2>&1 || true

msg info "Actualizando repositorios"
apt_run update -y >/dev/null || {
    msg err "apt-get update falló. Revisa los repositorios de esta VPS."
    exit 1
}

msg info "Instalando dependencias base"
apt_run install -y ca-certificates wget curl sudo jq net-tools screen tmux nload make \
    software-properties-common build-essential gcc cmake python3 python3-pip \
    bc zip unzip lsof >/dev/null || {
    msg err "No se pudieron instalar dependencias esenciales."
    exit 1
}

# python-is-python3 existe en distribuciones modernas, pero no en todas las antiguas.
apt_run install -y python-is-python3 >/dev/null 2>&1 || true
apt_run install -y figlet lolcat >/dev/null 2>&1 || true

# Universe es específico de Ubuntu; en Debian no se intenta ejecutar.
if [[ "${ID:-}" == "ubuntu" ]] && command -v add-apt-repository >/dev/null 2>&1; then
    add-apt-repository -y universe >/dev/null 2>&1 || true
fi

# Conserva la intención del instalador original, pero sin desinstalar bibliotecas PAM.
if [[ -f /etc/pam.d/common-password ]] && grep -q 'pam_cracklib\.so' /etc/pam.d/common-password; then
    cp -a /etc/pam.d/common-password /etc/pam.d/common-password.golden.bak 2>/dev/null || true
    sed -i 's/.*pam_cracklib\.so.*/password sufficient pam_unix.so sha512 shadow nullok try_first_pass/' /etc/pam.d/common-password || true
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
else
    service ssh restart >/dev/null 2>&1 || service sshd restart >/dev/null 2>&1 || true
fi

msg info "Descargando instalador principal"
SECOND_STAGE="$HOME/LuciferMX2019.sh"
if ! safe_wget "$SECOND_STAGE_URL" "$SECOND_STAGE"; then
    msg err "No se pudo descargar LuciferMX2019.sh. La instalación se detuvo sin quedarse congelada."
    exit 1
fi

if ! bash -n "$SECOND_STAGE"; then
    msg err "LuciferMX2019.sh contiene un error de sintaxis."
    rm -f "$SECOND_STAGE"
    exit 1
fi
chmod 700 "$SECOND_STAGE"

msg ok "Bootstrap terminado. Iniciando instalador principal..."
echo "======================================================================"
sleep 1

exec bash "$SECOND_STAGE"
