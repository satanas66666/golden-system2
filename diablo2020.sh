#!/usr/bin/env bash
# GOLDEN ADM PRO - bootstrap REV26.1 ROOT REAL + CLOUD APT FAILOVER + GOLD UI
# Ubuntu/Debian antiguos y modernos con APT.
# Si la VPS inicia como ubuntu/debian/admin/ec2-user/etc:
#   1) detecta proveedor;
#   2) usa sudo SOLO para preparar root;
#   3) pide NUEVA contraseña root;
#   4) habilita login SSH root + password;
#   5) valida/reinicia SSH;
#   6) termina para que el usuario vuelva a entrar REALMENTE como root.
# Ya conectado como root, al ejecutar este mismo instalador continúa Golden.

set -u
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
C_RESET='\033[0m'
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[1;36m'
NET_TIMEOUT="${GOLDEN_NET_TIMEOUT:-12}"
NET_TRIES="${GOLDEN_NET_TRIES:-3}"
APT_LOCK_WAIT="${GOLDEN_APT_LOCK_WAIT:-600}"
APT_STEP_TIMEOUT="${GOLDEN_APT_STEP_TIMEOUT:-600}"
APT_UPDATE_TIMEOUT="${GOLDEN_APT_UPDATE_TIMEOUT:-45}"
APT_UPDATE_NET_TIMEOUT="${GOLDEN_APT_UPDATE_NET_TIMEOUT:-8}"
SECOND_STAGE_URL="${GOLDEN_INSTALLER_URL:-https://raw.githubusercontent.com/satanas66666/golden-system2/main/LuciferMX2019.sh}"
APT_BACKUP_DIR=""

msg_early() {
    case "${1:-}" in
        info) echo -e "${C_CYAN}[•]${C_RESET} $2" ;;
        ok)   echo -e "${C_GREEN}[✓]${C_RESET} $2" ;;
        warn) echo -e "${C_YELLOW}[!]${C_RESET} $2" ;;
        err)  echo -e "${C_RED}[✗]${C_RESET} $2" ;;
    esac
}

gold_bar() {
    echo -e "${C_YELLOW}=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=${C_RESET}"
}

detect_provider() {
    local data="" low=""
    for f in /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name \
             /sys/class/dmi/id/board_vendor /sys/class/dmi/id/product_version; do
        [[ -r "$f" ]] && data+="$(tr '\n' ' ' <"$f" 2>/dev/null) "
    done
    low="${data,,}"
    case "$low" in
        *amazon*|*ec2*)                         echo "Amazon AWS / EC2" ;;
        *google*|*compute\ engine*)             echo "Google Cloud Platform" ;;
        *microsoft*|*azure*)                    echo "Microsoft Azure" ;;
        *oracle*|*oci*)                         echo "Oracle Cloud" ;;
        *digitalocean*)                         echo "DigitalOcean" ;;
        *hetzner*)                              echo "Hetzner Cloud" ;;
        *vultr*)                                echo "Vultr" ;;
        *linode*|*akamai*)                      echo "Akamai / Linode" ;;
        *contabo*)                              echo "Contabo" ;;
        *openstack*)                            echo "OpenStack Cloud" ;;
        *vmware*)                               echo "VMware VPS" ;;
        *xen*)                                  echo "Xen VPS" ;;
        *kvm*|*qemu*|*bochs*)                  echo "KVM/QEMU VPS" ;;
        *)                                      echo "VPS/Cloud no identificado" ;;
    esac
}

prepare_real_root_login() {
    [[ "$(id -u)" -ne 0 ]] || return 0

    local provider user helper rc
    provider="$(detect_provider)"
    user="$(id -un 2>/dev/null || echo usuario)"

    echo
    gold_bar
    echo -e "${C_YELLOW}       GOLDEN ADM PRO - CONVERTIR ACCESO A ROOT REAL${C_RESET}"
    gold_bar
    echo "Proveedor detectado : $provider"
    echo "Usuario actual       : $user"
    echo "UID                  : $(id -u)"
    echo
    echo "Golden NO continuará todavía."
    echo "Primero se preparará el usuario root con SU PROPIA contraseña."
    echo "Después debes volver a entrar por SSH como root."
    gold_bar

    if ! command -v sudo >/dev/null 2>&1; then
        msg_early err "Este usuario no tiene sudo disponible."
        msg_early err "Se necesita un usuario administrador para configurar root."
        exit 1
    fi

    helper="$(mktemp /tmp/golden-root-prep.XXXXXX.sh)"
    cat >"$helper" <<'EOF_ROOT_HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail

C_RESET='\033[0m'
C_GOLD='\033[1;33m'
gold_bar() {
    echo -e "${C_GOLD}=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=${C_RESET}"
}

provider="${1:-VPS/Cloud}"
orig_user="${2:-usuario}"
SSHCFG="/etc/ssh/sshd_config"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/golden-root-ssh-$STAMP"

[[ "$(id -u)" -eq 0 ]] || { echo "ERROR: helper sin privilegios root."; exit 1; }
[[ -f "$SSHCFG" ]] || { echo "ERROR: no existe $SSHCFG"; exit 1; }
[[ -t 0 ]] || { echo "ERROR: se necesita una terminal interactiva para crear la contraseña root."; exit 1; }

mkdir -p "$BACKUP"
cp -a "$SSHCFG" "$BACKUP/sshd_config"
[[ -d /etc/ssh/sshd_config.d ]] && cp -a /etc/ssh/sshd_config.d "$BACKUP/" 2>/dev/null || true

echo
gold_bar
echo -e "${C_GOLD}                 CREAR CONTRASEÑA DE ROOT${C_RESET}"
gold_bar
echo "Proveedor : $provider"
echo "Usuario   : $orig_user"
echo
echo "Ahora escribe la NUEVA contraseña que vas a usar cuando ingreses como:"
echo "    usuario: root"
echo
echo "La contraseña se solicitará DOS veces y NO se guardará en Golden."
gold_bar
echo

if ! passwd root; then
    echo "ERROR: no se pudo establecer la contraseña de root."
    exit 1
fi

root_state="$(passwd -S root 2>/dev/null | awk '{print $2}' || true)"
case "$root_state" in
    P|PS) ;;
    *)
        echo "ERROR: la cuenta root no quedó con contraseña utilizable (estado: ${root_state:-desconocido})."
        exit 1
        ;;
esac

# El bloque se coloca AL PRINCIPIO del sshd_config para que sus valores
# globales sean los primeros encontrados por OpenSSH.
tmp="$(mktemp)"
awk '
BEGIN { skip=0 }
/^# BEGIN GOLDEN ROOT PASSWORD LOGIN$/ { skip=1; next }
/^# END GOLDEN ROOT PASSWORD LOGIN$/   { skip=0; next }
skip==0 { print }
' "$SSHCFG" >"$tmp"

{
    echo '# BEGIN GOLDEN ROOT PASSWORD LOGIN'
    echo 'PermitRootLogin yes'
    echo 'PasswordAuthentication yes'
    echo 'AuthenticationMethods any'
    echo 'PermitEmptyPasswords no'
    echo '# END GOLDEN ROOT PASSWORD LOGIN'
    cat "$tmp"
} >"$SSHCFG"
rm -f "$tmp"
chmod 600 "$SSHCFG"

sshd_bin="$(command -v sshd || true)"
[[ -n "$sshd_bin" ]] || [[ ! -x /usr/sbin/sshd ]] || sshd_bin=/usr/sbin/sshd
[[ -n "$sshd_bin" ]] || {
    cp -a "$BACKUP/sshd_config" "$SSHCFG"
    echo "ERROR: no se encontró sshd."
    exit 1
}

if ! "$sshd_bin" -t; then
    echo "ERROR: sshd rechazó la configuración. Restaurando..."
    cp -a "$BACKUP/sshd_config" "$SSHCFG"
    "$sshd_bin" -t >/dev/null 2>&1 || true
    exit 1
fi

effective="$("$sshd_bin" -T -C user=root,host="$(hostname)",addr=127.0.0.1 2>/dev/null || "$sshd_bin" -T 2>/dev/null || true)"
permit="$(printf '%s\n' "$effective" | awk '$1=="permitrootlogin"{print $2; exit}')"
passauth="$(printf '%s\n' "$effective" | awk '$1=="passwordauthentication"{print $2; exit}')"
authmethods="$(printf '%s\n' "$effective" | awk '$1=="authenticationmethods"{print $2; exit}')"

if [[ "$permit" != "yes" || "$passauth" != "yes" ]]; then
    echo "ERROR: SSH efectivo no permite todavía root+password."
    echo "PermitRootLogin efectivo    : ${permit:-desconocido}"
    echo "PasswordAuthentication      : ${passauth:-desconocido}"
    echo "AuthenticationMethods       : ${authmethods:-desconocido}"
    echo "Restaurando configuración SSH anterior..."
    cp -a "$BACKUP/sshd_config" "$SSHCFG"
    exit 1
fi

restart_ok=0
for svc in ssh sshd; do
    if systemctl list-unit-files "$svc.service" >/dev/null 2>&1; then
        if systemctl restart "$svc.service"; then
            restart_ok=1
            break
        fi
    fi
done

if (( restart_ok == 0 )); then
    if command -v service >/dev/null 2>&1; then
        service ssh restart >/dev/null 2>&1 && restart_ok=1 || true
        (( restart_ok == 1 )) || service sshd restart >/dev/null 2>&1 && restart_ok=1 || true
    fi
fi

if (( restart_ok == 0 )); then
    echo "ERROR: no se pudo reiniciar SSH. Restaurando..."
    cp -a "$BACKUP/sshd_config" "$SSHCFG"
    systemctl restart ssh.service >/dev/null 2>&1 || systemctl restart sshd.service >/dev/null 2>&1 || true
    exit 1
fi

sleep 1
if ! "$sshd_bin" -t; then
    echo "ERROR: SSH quedó inválido tras reinicio. Restaurando..."
    cp -a "$BACKUP/sshd_config" "$SSHCFG"
    systemctl restart ssh.service >/dev/null 2>&1 || systemctl restart sshd.service >/dev/null 2>&1 || true
    exit 1
fi

echo
gold_bar
echo -e "${C_GOLD}                       ROOT PREPARADO${C_RESET}"
gold_bar
echo "[PASS] Contraseña propia de root configurada."
echo "[PASS] PermitRootLogin efectivo       : $permit"
echo "[PASS] PasswordAuthentication efectivo : $passauth"
echo "[PASS] SSH validado y reiniciado."
echo "[BACKUP] $BACKUP"
echo
echo "NO cierres esta sesión todavía."
echo "Abre OTRA sesión SSH y prueba:"
echo
echo "    Usuario    : root"
echo "    Contraseña : la que acabas de crear"
echo
echo "Cuando logres entrar como root, vuelve a ejecutar el instalador Golden."
gold_bar
EOF_ROOT_HELPER
    chmod 700 "$helper"

    if sudo -n true >/dev/null 2>&1; then
        msg_early ok "SUDO administrativo disponible."
    else
        msg_early info "SUDO solicitará la contraseña del usuario actual '$user'."
        if ! sudo -v; then
            rm -f "$helper"
            msg_early err "No se pudo obtener privilegio administrativo con sudo."
            exit 1
        fi
    fi

    sudo bash "$helper" "$provider" "$user"
    rc=$?
    rm -f "$helper"

    if (( rc == 0 )); then
        echo
        msg_early ok "Preparación root terminada."
        msg_early info "Este instalador se detiene aquí a propósito."
        msg_early info "Vuelve a entrar por SSH como root y ejecútalo otra vez."
    fi
    exit "$rc"
}

# Si NO eres root, prepara root real y termina.
# Si YA eres root, continúa la instalación Golden normal.
prepare_real_root_login

if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${C_RED}Debes volver a entrar realmente como usuario root para continuar.${C_RESET}" >&2
    exit 1
fi

OS_ID=""; OS_VERSION=""; PRETTY_NAME=""
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION="${VERSION_ID:-}"
    PRETTY_NAME="${PRETTY_NAME:-}"
elif [[ -r /etc/lsb-release ]]; then
    # shellcheck disable=SC1091
    . /etc/lsb-release
    OS_ID="ubuntu"
    OS_VERSION="${DISTRIB_RELEASE:-}"
    PRETTY_NAME="${DISTRIB_DESCRIPTION:-Ubuntu $OS_VERSION}"
elif [[ -r /etc/debian_version ]]; then
    OS_ID="debian"
    OS_VERSION="$(sed 's/[^0-9.].*$//' /etc/debian_version)"
    PRETTY_NAME="Debian $OS_VERSION"
else
    echo -e "${C_RED}No se pudo identificar Ubuntu/Debian.${C_RESET}" >&2
    exit 1
fi
OS_ID="${OS_ID,,}"
case "$OS_ID" in ubuntu|debian) ;; *) echo -e "${C_RED}Sistema no soportado: ${PRETTY_NAME:-$OS_ID}${C_RESET}" >&2; exit 1 ;; esac
command -v apt-get >/dev/null 2>&1 || { echo -e "${C_RED}APT no está disponible.${C_RESET}" >&2; exit 1; }

msg() {
    case "${1:-}" in
        info) echo -e "${C_CYAN}[•]${C_RESET} $2" ;;
        ok)   echo -e "${C_GREEN}[✓]${C_RESET} $2" ;;
        warn) echo -e "${C_YELLOW}[!]${C_RESET} $2" ;;
        err)  echo -e "${C_RED}[✗]${C_RESET} $2" ;;
    esac
}

repeat_char() { local n="$1" ch="$2" out=""; while (( n > 0 )); do out+="$ch"; n=$((n-1)); done; printf '%s' "$out"; }
last_activity_line() {
    local log="$1" line
    line=$(tail -n 60 "$log" 2>/dev/null | grep -aE '^(Get:|Hit:|Ign:|Err:|Fetched |Reading package|Building dependency|Reading state|Selecting previously|Preparing to unpack|Unpacking |Setting up |Processing triggers|Downloading |Installing |Removing )' | tail -n1 || true)
    line=$(printf '%s' "$line" | tr '\r\n' '  ' | sed 's/[[:space:]]\+/ /g')
    [[ ${#line} -gt 58 ]] && line="${line:0:55}..."
    printf '%s' "$line"
}
run_activity() {
    local label="$1"; shift
    local log status pid rc elapsed=0 pos=0 dir=1 width=28 i bar detail=""
    log=$(mktemp /tmp/golden-step.XXXXXX)
    status=$(mktemp /tmp/golden-status.XXXXXX)
    rm -f "$status"
    (
        set +e
        "$@"
        rc=$?
        printf '%s\n' "$rc" >"$status"
        exit "$rc"
    ) >"$log" 2>&1 &
    pid=$!
    while [[ ! -s "$status" ]]; do
        bar=""
        for ((i=0; i<width; i++)); do [[ $i -eq $pos ]] && bar+="#" || bar+="-"; done
        (( elapsed % 2 == 0 )) && detail=$(last_activity_line "$log")
        printf '\r\033[K\033[1;33m[%s]\033[0m %-27s %4ss' "$bar" "$label" "$elapsed"
        [[ -n "$detail" ]] && printf ' | %s' "$detail"
        if (( dir > 0 )); then pos=$((pos+1)); (( pos >= width-1 )) && dir=-1; else pos=$((pos-1)); (( pos <= 0 )) && dir=1; fi
        sleep 1
        elapsed=$((elapsed+1))
        if (( elapsed >= APT_STEP_TIMEOUT )); then
            printf '\n'
            msg err "$label superó ${APT_STEP_TIMEOUT}s; cancelando para evitar bloqueo infinito."
            kill -TERM "$pid" 2>/dev/null || true
            sleep 2
            kill -KILL "$pid" 2>/dev/null || true
            printf '124\n' >"$status"
            break
        fi
        if ! kill -0 "$pid" 2>/dev/null && [[ ! -s "$status" ]]; then sleep 1; break; fi
    done
    wait "$pid" 2>/dev/null || true
    rc=$(cat "$status" 2>/dev/null || printf '1')
    [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
    if (( rc == 0 )); then
        printf '\r\033[K\033[1;32m[%s] 100%%\033[0m %s (%ss)\n' "$(repeat_char "$width" '#')" "$label" "$elapsed"
    else
        printf '\r\033[K\033[1;31m[%s] ERROR\033[0m %s\n' "$(repeat_char "$width" '!')" "$label"
        tail -n 15 "$log" 2>/dev/null || true
    fi
    rm -f "$log" "$status"
    return "$rc"
}
apt_lock_pids() {
    local -a locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock)
    if command -v fuser >/dev/null 2>&1; then
        fuser "${locks[@]}" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un || true
    elif command -v lsof >/dev/null 2>&1; then
        lsof -t -- "${locks[@]}" 2>/dev/null | sort -un || true
    else
        return 0
    fi
}
wait_apt() {
    local waited=0 pids=""
    while :; do
        pids=$(apt_lock_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        [[ -z "$pids" ]] && { (( waited > 0 )) && printf '\r\033[KAPT/DPKG disponible después de %ss.\n' "$waited"; return 0; }
        (( waited == 0 || waited % 15 == 0 )) && msg info "APT/DPKG ocupado por PID(s): $pids"
        printf '\r\033[KEsperando APT/DPKG: %ss / %ss' "$waited" "$APT_LOCK_WAIT"
        sleep 3; waited=$((waited+3))
        (( waited < APT_LOCK_WAIT )) || { printf '\n'; msg err "APT/DPKG sigue bloqueado después de ${APT_LOCK_WAIT}s."; return 1; }
    done
}
apt_run() {
    wait_apt || return 1
    local cmd="${1:-}" step_timeout="$APT_STEP_TIMEOUT" retries=2 net_timeout=25
    local -a ipopt=()

    # apt update is the network-discovery phase: fail fast on a dead cloud mirror
    # instead of leaving the installer waiting for many minutes.
    if [[ "$cmd" == "update" ]]; then
        step_timeout="$APT_UPDATE_TIMEOUT"
        retries=0
        net_timeout="$APT_UPDATE_NET_TIMEOUT"
    fi

    # Avoid a broken/partial IPv6 route causing long APT stalls when IPv4 exists.
    if command -v ip >/dev/null 2>&1 && ip -4 route get 1.1.1.1 >/dev/null 2>&1; then
        ipopt=(-o Acquire::ForceIPv4=true)
    fi

    local -a opts=(
        -o DPkg::Lock::Timeout="$APT_LOCK_WAIT"
        -o Acquire::Retries="$retries"
        -o Acquire::http::Timeout="$net_timeout"
        -o Acquire::https::Timeout="$net_timeout"
        -o Dpkg::Use-Pty=0
        -o Dpkg::Options::=--force-confold
        "${ipopt[@]}"
    )
    if command -v timeout >/dev/null 2>&1; then
        timeout "$step_timeout" apt-get "${opts[@]}" "$@"
    else
        apt-get "${opts[@]}" "$@"
    fi
}
backup_sources() {
    [[ -n "$APT_BACKUP_DIR" ]] && return 0
    APT_BACKUP_DIR="/var/backups/golden-client-apt-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$APT_BACKUP_DIR"
    cp -a /etc/apt/sources.list "$APT_BACKUP_DIR/" 2>/dev/null || true
    cp -a /etc/apt/sources.list.d "$APT_BACKUP_DIR/" 2>/dev/null || true
}

repair_cloud_ubuntu_mirror() {
    [[ "$OS_ID" == "ubuntu" ]] || return 1

    local arch target f changed=1
    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    case "$arch" in
        amd64|i386|x86_64) target="http://archive.ubuntu.com/ubuntu/" ;;
        arm64|armhf|aarch64) target="http://ports.ubuntu.com/ubuntu-ports/" ;;
        *) target="http://archive.ubuntu.com/ubuntu/" ;;
    esac

    # Only touch a regional/cloud Ubuntu archive hostname; leave security,
    # PPAs and any custom repositories untouched.
    if ! grep -RqsE 'https?://[^[:space:]]+\.archive\.ubuntu\.com/ubuntu/?' \
         /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
        return 1
    fi

    backup_sources
    msg warn "Mirror regional/cloud de Ubuntu no respondió; aplicando fallback oficial."

    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        if grep -qE 'https?://[^[:space:]]+\.archive\.ubuntu\.com/ubuntu/?' "$f" 2>/dev/null; then
            python3 - "$f" "$target" <<'PY_MIRROR'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
target = sys.argv[2]
text = p.read_text(encoding="utf-8", errors="surrogateescape")
# Examples matched:
# us-east-1.ec2.archive.ubuntu.com
# us-west1.gce.archive.ubuntu.com
# azure.archive.ubuntu.com
# us.archive.ubuntu.com
new = re.sub(
    r'https?://(?!archive\.ubuntu\.com(?:/|$))[A-Za-z0-9.-]+\.archive\.ubuntu\.com/ubuntu/?',
    target,
    text,
)
p.write_text(new, encoding="utf-8", errors="surrogateescape")
PY_MIRROR
            changed=0
        fi
    done

    if (( changed == 0 )); then
        rm -rf /var/lib/apt/lists/partial 2>/dev/null || true
        mkdir -p /var/lib/apt/lists/partial
        msg ok "Fallback APT aplicado: $target"
        msg info "Respaldo de repositorios: $APT_BACKUP_DIR"
    fi
    return "$changed"
}
ubuntu_eol_candidate() {
    case "$OS_VERSION" in
        10.*|11.*|12.*|13.*|14.*|15.*|16.*|17.*|18.*|19.*|20.10|21.*|22.10|23.*|24.10|25.*) return 0 ;;
        *) return 1 ;;
    esac
}
debian_eol_candidate() { local m="${OS_VERSION%%.*}"; [[ "$m" =~ ^[0-9]+$ ]] && (( m <= 10 )); }
repair_eol_sources() {
    local f changed=1
    backup_sources
    if [[ "$OS_ID" == ubuntu ]] && ubuntu_eol_candidate; then
        msg warn "Repositorios de Ubuntu $OS_VERSION parecen EOL; usando old-releases."
        for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
            [[ -f "$f" ]] || continue
            sed -Ei \
              -e 's#https?://([a-z]{2}\.)?archive\.ubuntu\.com/ubuntu/?#http://old-releases.ubuntu.com/ubuntu/#g' \
              -e 's#https?://security\.ubuntu\.com/ubuntu/?#http://old-releases.ubuntu.com/ubuntu/#g' \
              -e 's#https?://ports\.ubuntu\.com/ubuntu-ports/?#http://old-releases.ubuntu.com/ubuntu/#g' "$f"
        done
        mkdir -p /etc/apt/apt.conf.d
        printf 'Acquire::Check-Valid-Until "false";\n' >/etc/apt/apt.conf.d/99golden-eol
        changed=0
    elif [[ "$OS_ID" == debian ]] && debian_eol_candidate; then
        msg warn "Repositorios de Debian $OS_VERSION parecen EOL; usando archive.debian.org."
        for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
            [[ -f "$f" ]] || continue
            sed -Ei \
              -e 's#https?://(deb|ftp)\.debian\.org/debian/?#http://archive.debian.org/debian/#g' \
              -e 's#https?://[a-z]{2}\.deb\.debian\.org/debian/?#http://archive.debian.org/debian/#g' \
              -e 's#https?://security\.debian\.org/debian-security/?#http://archive.debian.org/debian-security/#g' \
              -e 's#https?://security\.debian\.org/?#http://archive.debian.org/debian-security/#g' "$f"
            [[ "$f" == *.list ]] && sed -Ei '/^[[:space:]]*deb .*-(updates|backports)[[:space:]]/ s/^/# Golden EOL: /' "$f" || true
        done
        mkdir -p /etc/apt/apt.conf.d
        printf 'Acquire::Check-Valid-Until "false";\n' >/etc/apt/apt.conf.d/99golden-eol
        changed=0
    fi
    return "$changed"
}
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'; }
pkg_available() {
    local c
    c=$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')
    [[ -n "$c" && "$c" != '(none)' ]]
}
install_group() {
    local label="$1" required="$2"; shift 2
    local -a todo=(); local p
    for p in "$@"; do
        pkg_installed "$p" && continue
        if pkg_available "$p"; then todo+=("$p"); elif [[ "$required" == 1 ]]; then msg err "Paquete requerido no disponible: $p"; return 1; else msg warn "Paquete opcional omitido: $p"; fi
    done
    ((${#todo[@]})) || { msg ok "$label: ya estaba listo"; return 0; }
    run_activity "$label" apt_run install -y --no-install-recommends "${todo[@]}"
}
apt_install_no_autostart() {
    local created_policy=0 backup=""
    if [[ -e /usr/sbin/policy-rc.d ]]; then
        backup=$(mktemp /tmp/golden-policy-rc.d.XXXXXX)
        cp -a /usr/sbin/policy-rc.d "$backup" 2>/dev/null || backup=""
    else
        cat >/usr/sbin/policy-rc.d <<'EOF_POLICY'
#!/bin/sh
exit 101
EOF_POLICY
        chmod 0755 /usr/sbin/policy-rc.d
        created_policy=1
    fi
    local rc=0
    apt_run install -y --no-install-recommends "$@" || rc=$?
    if (( created_policy == 1 )); then
        rm -f /usr/sbin/policy-rc.d
    elif [[ -n "$backup" && -e "$backup" ]]; then
        cp -a "$backup" /usr/sbin/policy-rc.d 2>/dev/null || true
        rm -f "$backup"
    fi
    return "$rc"
}
install_group_no_autostart() {
    local label="$1" required="$2"; shift 2
    local -a todo=(); local p
    for p in "$@"; do
        pkg_installed "$p" && continue
        if pkg_available "$p"; then
            todo+=("$p")
        elif [[ "$required" == 1 ]]; then
            msg err "Paquete requerido no disponible: $p"
            return 1
        else
            msg warn "Paquete opcional omitido: $p"
        fi
    done
    ((${#todo[@]})) || { msg ok "$label: ya estaba listo"; return 0; }
    run_activity "$label" apt_install_no_autostart "${todo[@]}"
}
safe_wget() {
    local url="${1:-}" dest="${2:-}" tmp
    [[ -n "$url" && -n "$dest" ]] || return 2
    tmp="${dest}.part.$$"; rm -f -- "$tmp"
    if command -v wget >/dev/null 2>&1; then
        wget -q -T "$NET_TIMEOUT" -t "$NET_TRIES" -O "$tmp" "$url" || { rm -f -- "$tmp"; return 1; }
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout "$NET_TIMEOUT" --max-time 60 --retry "$NET_TRIES" -o "$tmp" "$url" || { rm -f -- "$tmp"; return 1; }
    else return 1; fi
    [[ -s "$tmp" ]] || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$dest"
}

clear 2>/dev/null || true
gold_bar
echo -e "${C_YELLOW}        GOLDEN ADM PRO - INSTALADOR REV26.1 UNIVERSAL${C_RESET}"
gold_bar
echo "Sistema   : ${PRETTY_NAME:-$OS_ID $OS_VERSION}"
echo "Proveedor : $(detect_provider)"
echo "Usuario   : root (elevación verificada)"
echo "Fase      : Preparando instalación"
gold_bar
msg info "Comprobando estado real de APT/DPKG"
wait_apt || exit 1
msg ok "APT/DPKG disponible"
run_activity "Reconfigurando DPKG" dpkg --configure -a || true

if ! run_activity "Actualizando repositorios" apt_run update; then
    if repair_cloud_ubuntu_mirror; then
        run_activity "Repositorios Ubuntu fallback" apt_run update || {
            if repair_eol_sources; then
                run_activity "Repositorios EOL reparados" apt_run update || { msg err "APT sigue fallando después de los fallbacks."; exit 1; }
            else
                msg err "APT sigue fallando después del fallback de mirror."
                exit 1
            fi
        }
    elif repair_eol_sources; then
        run_activity "Repositorios EOL reparados" apt_run update || { msg err "APT sigue fallando después de reparar repositorios."; exit 1; }
    else
        msg err "apt-get update falló. Revisa red/DNS/repositorios de esta VPS."
        exit 1
    fi
fi
mkdir -p /var/cache/golden 2>/dev/null || true
touch /var/cache/golden/apt-update.stamp 2>/dev/null || true
install_group "Red y certificados" 1 ca-certificates wget curl || exit 1
install_group "Núcleo de ejecución" 1 python3 bc unzip zip lsof procps psmisc gawk || exit 1
install_group "Utilidades Golden" 0 nano screen jq net-tools nload || true
install_group_no_autostart "Servidor web Apache" 1 apache2 || exit 1
if pkg_available python-is-python3 && ! pkg_installed python-is-python3; then
    run_activity "Compatibilidad Python" apt_run install -y --no-install-recommends python-is-python3 || true
fi
if [[ "$OS_ID" == ubuntu ]] && pkg_available software-properties-common && ! pkg_installed software-properties-common; then
    run_activity "Herramientas Ubuntu" apt_run install -y --no-install-recommends software-properties-common || true
fi
if [[ -f /etc/pam.d/common-password ]] && grep -q 'pam_cracklib\.so' /etc/pam.d/common-password; then
    cp -a /etc/pam.d/common-password /etc/pam.d/common-password.golden.bak 2>/dev/null || true
    sed -i 's/.*pam_cracklib.so.*/password sufficient pam_unix.so sha512 shadow nullok try_first_pass/' /etc/pam.d/common-password || true
fi
msg info "Descargando instalador principal"
SECOND_STAGE="$HOME/LuciferMX2019.sh"
if ! safe_wget "$SECOND_STAGE_URL" "$SECOND_STAGE"; then msg err "No se pudo descargar LuciferMX2019.sh."; exit 1; fi
if ! bash -n "$SECOND_STAGE"; then msg err "LuciferMX2019.sh contiene un error de sintaxis."; rm -f "$SECOND_STAGE"; exit 1; fi
chmod 700 "$SECOND_STAGE"
msg ok "Bootstrap terminado. Iniciando instalador principal..."
gold_bar
sleep 1
exec bash "$SECOND_STAGE"
