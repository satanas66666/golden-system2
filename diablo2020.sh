#!/usr/bin/env bash
# GOLDEN ADM PRO - bootstrap REV9
# Ubuntu/Debian con APT. Progreso visible, espera segura de locks y timeouts.

set -u
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

C_RESET='\033[0m'
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[1;36m'
NET_TIMEOUT="${GOLDEN_NET_TIMEOUT:-12}"
NET_TRIES="${GOLDEN_NET_TRIES:-3}"
SECOND_STAGE_URL="${GOLDEN_INSTALLER_URL:-https://raw.githubusercontent.com/satanas66666/golden-system2/main/LuciferMX2019.sh}"

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

repeat_char() {
    local n="$1" ch="$2" out=""
    while (( n > 0 )); do out+="$ch"; n=$((n - 1)); done
    printf '%s' "$out"
}

# Barra indeterminada: no inventa un porcentaje de APT; muestra actividad y tiempo.
run_activity() {
    local label="$1"; shift
    local log pid rc elapsed=0 pos=0 dir=1 width=28 i bar
    log=$(mktemp /tmp/golden-step.XXXXXX)
    "$@" >"$log" 2>&1 &
    pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        bar=""
        for ((i=0; i<width; i++)); do
            if (( i == pos )); then bar+="#"; else bar+="-"; fi
        done
        printf '\r\033[K\033[1;33m[%s]\033[0m %-28s %4ss' "$bar" "$label" "$elapsed"
        if (( dir > 0 )); then
            pos=$((pos + 1)); (( pos >= width-1 )) && dir=-1
        else
            pos=$((pos - 1)); (( pos <= 0 )) && dir=1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    wait "$pid"; rc=$?
    if (( rc == 0 )); then
        printf '\r\033[K\033[1;32m[%s] 100%%\033[0m %s (%ss)\n' "$(repeat_char "$width" '#')" "$label" "$elapsed"
    else
        printf '\r\033[K\033[1;31m[%s] ERROR\033[0m %s\n' "$(repeat_char "$width" '!')" "$label"
        tail -n 12 "$log" 2>/dev/null || true
    fi
    rm -f "$log"
    return "$rc"
}

wait_apt() {
    local waited=0 max_wait=300

    # En instalaciones mínimas puede no existir fuser todavía. apt-get ya usa
    # DPkg::Lock::Timeout, así que no debemos abortar por esa ausencia.
    if ! command -v fuser >/dev/null 2>&1; then
        return 0
    fi

    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
        (( waited == 0 )) && msg info "APT/DPKG está ocupado; esperando sin borrar locks..."
        printf '\r\033[KEsperando APT/DPKG: %ss / %ss' "$waited" "$max_wait"
        sleep 3
        waited=$((waited + 3))
        if (( waited >= max_wait )); then
            printf '\n'
            msg err "APT sigue ocupado después de ${max_wait}s."
            return 1
        fi
    done

    if (( waited > 0 )); then
        printf '\r\033[KAPT/DPKG libre después de %ss.\n' "$waited"
    fi
    return 0
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
    local url dest tmp
    url="${1:-}"
    dest="${2:-}"
    [[ -n "$url" && -n "$dest" ]] || return 2
    tmp="${dest}.part.$$"
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
echo "             GOLDEN ADM PRO - INSTALADOR REV8"
echo "======================================================================"
echo "Sistema : ${PRETTY_NAME:-$ID}"
echo "Fase    : Preparando instalación"
echo "======================================================================"

msg info "Comprobando estado de APT/DPKG"
if ! wait_apt; then
    msg err "No fue posible obtener acceso seguro a APT/DPKG."
    exit 1
fi
msg ok "APT/DPKG disponible"
run_activity "Reconfigurando DPKG" dpkg --configure -a || true

run_activity "Actualizando repositorios" apt_run update -y || {
    msg err "apt-get update falló. Revisa los repositorios de esta VPS."
    exit 1
}

run_activity "Instalando dependencias base" apt_run install -y \
    ca-certificates wget curl sudo jq net-tools screen tmux nload make \
    software-properties-common build-essential gcc cmake python3 python3-pip \
    bc zip unzip lsof || {
    msg err "No se pudieron instalar dependencias esenciales."
    exit 1
}

run_activity "Compatibilidad Python" apt_run install -y python-is-python3 || true
run_activity "Complementos visuales" apt_run install -y figlet lolcat || true

if [[ "${ID:-}" == "ubuntu" ]] && command -v add-apt-repository >/dev/null 2>&1; then
    run_activity "Repositorio Universe" add-apt-repository -y universe || true
fi

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
