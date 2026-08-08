#!/usr/bin/env bash
# GOLDEN ADM PRO - LuciferMX2019 REV25 / FAST PATH + fallback REV25 intacto + APT universal
cd $HOME

# REV25: esta segunda etapa puede ejecutarse directamente o desde el bootstrap.
# Forzar modo no interactivo evita prompts de needrestart/ucf/apt-listchanges.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none
export UCF_FORCE_CONFFOLD=1
export SYSTEMD_PAGER=cat

SCPdir="/etc/newadm"
SCPdir2="${SCPdir}/v2ray"
SCPinstal="$HOME/install"
SCPidioma="${SCPdir}/idioma"
SCPusr="${SCPdir}/ger-user"
SCPfrm3="/etc/adm-lite"
SCPfrm="/etc/ger-frm"
SCPinst="/etc/ger-inst"


# Red robusta: ninguna descarga externa puede dejar el instalador congelado.
NET_TIMEOUT="${GOLDEN_NET_TIMEOUT:-10}"
NET_TRIES="${GOLDEN_NET_TRIES:-2}"
PAYLOAD_TIMEOUT="${GOLDEN_PAYLOAD_TIMEOUT:-20}"
PAYLOAD_TRIES="${GOLDEN_PAYLOAD_TRIES:-3}"

safe_wget() {
    local url="$1" dest="$2" allow_empty="${3:-0}" tmp
    tmp="${dest}.part.$$"
    rm -f -- "$tmp"
    if wget -q -T "$NET_TIMEOUT" -t "$NET_TRIES" -O "$tmp" "$url"; then
        # Por defecto una descarga vacía sigue siendo error. Solo payloads
        # explícitamente marcados (PDirect.py original = 0 bytes) pueden pasar.
        if [[ -s "$tmp" || ( "$allow_empty" == "1" && -e "$tmp" ) ]]; then
            mv -f -- "$tmp" "$dest"
            return 0
        fi
    fi
    rm -f -- "$tmp"
    return 1
}

safe_wget_stdout() {
    wget -q -T "$NET_TIMEOUT" -t "$NET_TRIES" -O- "$1" 2>/dev/null
}


# ---------------- APT UNIVERSAL / NO BLOQUEO ----------------
APT_LOCK_WAIT="${GOLDEN_APT_LOCK_WAIT:-600}"
APT_STEP_TIMEOUT="${GOLDEN_APT_STEP_TIMEOUT:-600}"
ACTIVITY_TIMEOUT="${GOLDEN_ACTIVITY_TIMEOUT:-900}"

apt_lock_pids_client() {
    local -a locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock)
    if command -v fuser >/dev/null 2>&1; then
        fuser "${locks[@]}" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un || true
    elif command -v lsof >/dev/null 2>&1; then
        lsof -t -- "${locks[@]}" 2>/dev/null | sort -un || true
    else
        return 0
    fi
}

wait_apt_client() {
    local waited=0 pids=""
    while :; do
        pids=$(apt_lock_pids_client | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        [[ -z "$pids" ]] && return 0
        sleep 3
        waited=$((waited + 3))
        (( waited < APT_LOCK_WAIT )) || return 1
    done
}

apt_client() {
    wait_apt_client || return 1
    local -a opts=(-o DPkg::Lock::Timeout="$APT_LOCK_WAIT" -o Acquire::Retries=2 -o Acquire::http::Timeout=25 -o Acquire::https::Timeout=25 -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confold)
    if command -v timeout >/dev/null 2>&1; then
        timeout "$APT_STEP_TIMEOUT" apt-get "${opts[@]}" "$@"
    else
        apt-get "${opts[@]}" "$@"
    fi
}

pkg_installed_client() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'; }
pkg_available_client() {
    local c
    c=$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')
    [[ -n "$c" && "$c" != '(none)' ]]
}

last_cmd_detail() {
    local log="$1" line
    line=$(tail -n 40 "$log" 2>/dev/null | grep -aE '^(Get:|Hit:|Ign:|Err:|Fetched |Selecting previously|Preparing to unpack|Unpacking |Setting up |Processing triggers|Reading package|Building dependency|Reading state)' | tail -n1 || true)
    line=$(printf '%s' "$line" | tr '\r\n' '  ' | sed 's/[[:space:]]\+/ /g')
    [[ ${#line} -gt 54 ]] && line="${line:0:51}..."
    printf '%s' "$line"
}

run_exec_activity() {
    local label="$1"; shift
    local log status pid rc elapsed=0 frame=0 detail=""
    local -a spin=('|' '/' '-' '\\')
    log=$(mktemp /tmp/golden-final.XXXXXX)
    status=$(mktemp /tmp/golden-final-status.XXXXXX)
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
        (( elapsed % 2 == 0 )) && detail=$(last_cmd_detail "$log")
        printf '\r\033[K\033[1;33m[%s]\033[0m %s - %ss' "${spin[frame%4]}" "$label" "$elapsed"
        [[ -n "$detail" ]] && printf ' | %s' "$detail"
        frame=$((frame + 1)); sleep 1; elapsed=$((elapsed + 1))
        if (( elapsed >= ACTIVITY_TIMEOUT )); then
            printf '\n'
            echo "[TIMEOUT] $label superó ${ACTIVITY_TIMEOUT}s; se detiene para evitar un bloqueo infinito." >&2
            pkill -TERM -P "$pid" 2>/dev/null || true
            kill -TERM "$pid" 2>/dev/null || true
            sleep 2
            pkill -KILL -P "$pid" 2>/dev/null || true
            kill -KILL "$pid" 2>/dev/null || true
            printf '124\n' >"$status"
            break
        fi
        if ! kill -0 "$pid" 2>/dev/null && [[ ! -s "$status" ]]; then sleep 1; break; fi
    done
    wait "$pid" 2>/dev/null || true
    rc=$(cat "$status" 2>/dev/null || printf '1')
    [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
    rm -f "$log" "$status"
    if (( rc == 0 )); then
        printf '\r\033[K\033[1;32m[OK]\033[0m %s (%ss)\n' "$label" "$elapsed"
    else
        printf '\r\033[K\033[1;33m[AVISO]\033[0m %s no se completó; continuando.\n' "$label"
    fi
    return "$rc"
}

apt_client_install_no_autostart() {
    local created_policy=0 backup=""
    if [[ -e /usr/sbin/policy-rc.d ]]; then
        backup=$(mktemp /tmp/golden-client-policy.XXXXXX)
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
    apt_client install -y --no-install-recommends "$@" || rc=$?

    if (( created_policy == 1 )); then
        rm -f /usr/sbin/policy-rc.d
    elif [[ -n "$backup" && -e "$backup" ]]; then
        cp -a "$backup" /usr/sbin/policy-rc.d 2>/dev/null || true
        rm -f "$backup"
    fi
    return "$rc"
}

install_client_group_no_autostart() {
    local label="$1" required="$2"; shift 2
    local -a todo=(); local p
    for p in "$@"; do
        pkg_installed_client "$p" && continue
        if pkg_available_client "$p"; then
            todo+=("$p")
        elif [[ "$required" == 1 ]]; then
            echo "Paquete requerido no disponible: $p" >&2
            return 1
        fi
    done
    ((${#todo[@]})) || return 0
    run_exec_activity "$label" apt_client_install_no_autostart "${todo[@]}"
}


# REV25: Apache de Golden usa exclusivamente TCP 81. Esta función elimina
# listeners HTTP en 80 de Apache (sin tocar otros servicios), migra VirtualHost
# :80 -> :81, valida la configuración y deja respaldo antes de modificarla.
apache_force_port_81_config() {
    local root="/etc/apache2"
    local backup="/var/backups/golden-apache-port81-$(date +%Y%m%d-%H%M%S).tar.gz"
    [[ -d "$root" && -f "$root/ports.conf" ]] || {
        echo "[ERROR] No existe una instalación Apache válida en $root." >&2
        return 1
    }
    mkdir -p /var/backups
    tar -C /etc -czf "$backup" apache2 >/dev/null 2>&1 || {
        echo "[ERROR] No se pudo crear respaldo de Apache." >&2
        return 1
    }

    if ! python3 - "$root" <<'PYAPACHE'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])

# Solo tocamos directivas que controlan escucha/VHost. No cambiamos ProxyPass,
# URLs, destinos internos ni cualquier otro uso legítimo del puerto 80.
files = []
for rel in ('ports.conf',):
    p = root / rel
    if p.exists(): files.append(p)
for dname in ('conf-available','conf-enabled','sites-available','sites-enabled'):
    d = root / dname
    if d.is_dir():
        files.extend(p for p in d.iterdir() if p.is_file() or p.is_symlink())

seen = set()
for p in files:
    try:
        rp = p.resolve()
    except Exception:
        rp = p
    if rp in seen or not rp.exists() or not rp.is_file():
        continue
    seen.add(rp)
    try:
        text = rp.read_text(encoding='utf-8')
    except UnicodeDecodeError:
        continue
    out = []
    changed = False
    for line in text.splitlines(True):
        body = line.rstrip('\r\n')
        nl = line[len(body):]
        # Listen 80 / Listen 0.0.0.0:80 / Listen [::]:80 / Listen *:80
        m = re.match(r'^(\s*Listen\s+)80(\s*(?:#.*)?)$', body, re.I)
        m2 = re.match(r'^(\s*Listen\s+)(\[[^\]]+\]|[^\s:]+):80(\s*(?:#.*)?)$', body, re.I)
        if m or m2:
            # Se comenta para garantizar que Apache no reserve TCP 80.
            out.append('# Golden REV25: movido a TCP 81 | ' + body + nl)
            changed = True
            continue
        # Apache 2.2 puede tener NameVirtualHost *:80.
        if re.match(r'^\s*NameVirtualHost\s+', body, re.I) and ':80' in body:
            body = re.sub(r':80(?=\s|$)', ':81', body)
            changed = True
        # VHosts de Apache en 80 pasan a 81. Esto no cambia backends/proxies.
        if re.match(r'^\s*<VirtualHost\s+', body, re.I) and ':80' in body:
            body = re.sub(r':80(?=\s|>)', ':81', body)
            changed = True
        out.append(body + nl)
    if changed:
        rp.write_text(''.join(out), encoding='utf-8')

ports = root / 'ports.conf'
text = ports.read_text(encoding='utf-8', errors='ignore')
active81 = False
for ln in text.splitlines():
    if ln.lstrip().startswith('#'):
        continue
    if re.match(r'^\s*Listen\s+(?:\[[^\]]+\]:|[^\s:]+:)?81\s*(?:#.*)?$', ln, re.I):
        active81 = True
        break
if not active81:
    with ports.open('a', encoding='utf-8') as f:
        f.write('\n# Golden System PRO REV25 - Apache exclusivo en TCP 81\nListen 81\n')
PYAPACHE
    then
        echo "[ERROR] No se pudo migrar la configuración Apache a TCP 81." >&2
        return 1
    fi

    # Validación antes de reiniciar. Si falla, restauramos automáticamente.
    if command -v timeout >/dev/null 2>&1; then
        timeout 20 apache2ctl configtest >/tmp/golden-apache-configtest.log 2>&1 || {
            rm -rf /etc/apache2
            tar -C /etc -xzf "$backup" >/dev/null 2>&1 || true
            echo "[ERROR] Apache configtest falló; configuración restaurada." >&2
            cat /tmp/golden-apache-configtest.log >&2 2>/dev/null || true
            return 1
        }
    else
        apache2ctl configtest >/tmp/golden-apache-configtest.log 2>&1 || {
            rm -rf /etc/apache2
            tar -C /etc -xzf "$backup" >/dev/null 2>&1 || true
            echo "[ERROR] Apache configtest falló; configuración restaurada." >&2
            cat /tmp/golden-apache-configtest.log >&2 2>/dev/null || true
            return 1
        }
    fi
    return 0
}

apache_process_listens() {
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

apache_restart_golden() {
    local rc=1
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 35 systemctl restart apache2 >/dev/null 2>&1 && rc=0 || rc=$?
        else
            systemctl restart apache2 >/dev/null 2>&1 && rc=0 || rc=$?
        fi
    fi
    if (( rc != 0 )); then
        if command -v timeout >/dev/null 2>&1; then
            timeout 35 service apache2 restart >/dev/null 2>&1 && rc=0 || rc=$?
        else
            service apache2 restart >/dev/null 2>&1 && rc=0 || rc=$?
        fi
    fi
    return "$rc"
}

install_client_group() {
    local label="$1" required="$2"; shift 2
    local -a todo=(); local p
    for p in "$@"; do
        pkg_installed_client "$p" && continue
        if pkg_available_client "$p"; then
            todo+=("$p")
        elif [[ "$required" == 1 ]]; then
            echo "Paquete requerido no disponible: $p" >&2
            return 1
        fi
    done
    ((${#todo[@]})) || return 0
    run_exec_activity "$label" apt_client install -y --no-install-recommends "${todo[@]}"
}


term_cols() {
    local c
    c=$(tput cols 2>/dev/null || true)
    [[ "$c" =~ ^[0-9]+$ ]] || c=80
    (( c < 50 )) && c=50
    (( c > 120 )) && c=120
    printf '%s' "$c"
}

repeat_char() {
    local n="$1" ch="$2" out=""
    while (( n > 0 )); do out+="$ch"; n=$((n - 1)); done
    printf '%s' "$out"
}

progress_line() {
    local current="$1" total="$2" label="$3" route="${4:-}" width=28 pct filled empty
    (( total > 0 )) || total=1
    pct=$(( current * 100 / total ))
    (( pct > 100 )) && pct=100
    filled=$(( pct * width / 100 ))
    empty=$(( width - filled ))
    printf '\r\033[K\033[1;33m[\033[1;32m%s\033[1;37m%s\033[1;33m]\033[0m %3d%% [%d/%d] %s %s' \
        "$(repeat_char "$filled" '#')" "$(repeat_char "$empty" '-')" "$pct" "$current" "$total" "$label" "$route"
}

fetch_with_activity() {
    local url="$1" dest="$2" current="$3" total="$4" label="$5" route="$6" allow_empty="${7:-0}"
    local pid rc elapsed=0 frame=0
    local -a spin=('|' '/' '-' '\\')

    # REV25: propagar allow_empty hasta safe_wget. REV25 lo recibía en
    # payload_fetch pero lo perdía en esta función intermedia, por lo que
    # PDirect.py (0 bytes legítimos) siempre terminaba en ERROR.
    safe_wget "$url" "$dest" "$allow_empty" &
    pid=$!
    while jobs -pr | grep -Fxq "$pid"; do
        progress_line "$current" "$total" "$label" "${route} ${spin[frame%4]} ${elapsed}s"
        frame=$((frame + 1))
        sleep 1
        elapsed=$((elapsed + 1))
    done
    wait "$pid"
    rc=$?
    printf '\r\033[K'
    return "$rc"
}

server_error_file() {
    local f="$1" size
    [[ -e "$f" ]] || return 0
    # Un archivo existente de 0 bytes puede ser un payload legítimo. En el ZIP
    # original del proyecto, PDirect.py es exactamente así.
    [[ -s "$f" ]] || return 1

    # Los payloads pueden ser binarios ELF aunque terminen en .sh (por ejemplo
    # ADMbot.sh). Nunca meter binarios en una sustitución $(...), porque Bash
    # elimina bytes NUL y muestra "ignored null byte in input".
    size=$(wc -c <"$f" 2>/dev/null || printf '0')
    [[ "$size" =~ ^[0-9]+$ ]] || size=0

    # Los mensajes de error del servidor son textos muy pequeños. Si el archivo
    # es mayor, se considera payload real sin intentar interpretarlo como texto.
    (( size <= 128 )) || return 1

    grep -aFqx 'KEY INVALIDA!' "$f" 2>/dev/null && return 0
    grep -aFqx 'IP DIFERENTE - ACCESO BLOQUEADO' "$f" 2>/dev/null && return 0
    grep -aFqx 'ARCHIVO NO DISPONIBLE!' "$f" 2>/dev/null && return 0
    grep -aFqx 'ERROR PREPARANDO ARCHIVOS!' "$f" 2>/dev/null && return 0
    grep -aFqx 'ERROR LEYENDO ARCHIVO!' "$f" 2>/dev/null && return 0
    return 1
}


run_cmd_activity() {
    local label="$1" command="$2"
    run_exec_activity "$label" bash -c "$command"
}

refresh_legacy_stage() {
    local refresh_url="http://${KEY_HOSTPORT}/${KEY_ID}/${KEY_LIST}/${IP}"
    local tmp="${HOME}/.golden-stage-refresh.$$"
    wget -q -T 8 -t 1 -O "$tmp" "$refresh_url" 2>/dev/null || true
    rm -f -- "$tmp"
}

payload_fetch() {
    local url="$1" dest="$2" current="$3" total="$4" name="$5" route="$6" allow_empty="${7:-0}"
    local old_timeout="$NET_TIMEOUT" old_tries="$NET_TRIES" rc
    NET_TIMEOUT="$PAYLOAD_TIMEOUT"
    NET_TRIES="$PAYLOAD_TRIES"
    if fetch_with_activity "$url" "$dest" "$current" "$total" "$name" "$route" "$allow_empty"; then
        rc=0
    else
        rc=$?
    fi
    NET_TIMEOUT="$old_timeout"
    NET_TRIES="$old_tries"
    return "$rc"
}

download_payload_file() {
    local name="$1" dest="$2" current="$3" total="$4"
    local direct="http://${KEY_HOSTPORT}/${REQUEST}/${name}"
    local legacy="http://${IP}:81/${REQUEST}/${name}"
    local attempt allow_empty=0

    # El archivo original PDirect.py del proyecto es un placeholder de 0 bytes.
    # Aceptarlo explícitamente evita confundirlo con una descarga truncada.
    [[ "$name" == "PDirect.py" ]] && allow_empty=1

    # REV25: intentar siempre la entrega directa por 8888. No dependemos del
    # texto de versión para decidir capacidades: si un servidor antiguo no
    # soporta /KEY/archivo, la respuesta se descarta y se usa el fallback 81.
    rm -f -- "$dest"
    if payload_fetch "$direct" "$dest" "$((current-1))" "$total" "$name" '8888' "$allow_empty"; then
        if ! server_error_file "$dest"; then
            progress_line "$current" "$total" "$name" 'OK 8888'
            printf '\n'
            return 0
        fi
    fi

    # Compatibilidad con generadores antiguos: el puerto 81 era la ruta creada
    # expresamente para los archivos. Se refresca el staging antes de reintentar.
    for attempt in 1 2 3; do
        (( attempt > 1 )) && refresh_legacy_stage && sleep 1
        rm -f -- "$dest"
        if payload_fetch "$legacy" "$dest" "$((current-1))" "$total" "$name" "81 intento ${attempt}/3" "$allow_empty"; then
            if ! server_error_file "$dest"; then
                progress_line "$current" "$total" "$name" 'OK 81'
                printf '\n'
                return 0
            fi
        fi
    done

    # Último recurso: incluso en servidor antiguo algunos archivos pequeños sí
    # pueden salir correctamente por 8888. Se intenta una sola vez al final.
    rm -f -- "$dest"
    if payload_fetch "$direct" "$dest" "$((current-1))" "$total" "$name" '8888 final' "$allow_empty"; then
        if ! server_error_file "$dest"; then
            progress_line "$current" "$total" "$name" 'OK 8888'
            printf '\n'
            return 0
        fi
    fi

    rm -f -- "$dest"
    progress_line "$((current-1))" "$total" "$name" 'ERROR'
    printf '\n'
    return 1
}

bundle_download_with_progress() {
    local url="$1" dest="$2" expected="$3" tmp pid rc current pct width=28 filled empty elapsed=0
    tmp="${dest}.part.$$"
    rm -f -- "$tmp"

    if command -v curl >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 120 curl -fL -sS --connect-timeout 8 --max-time 110 -o "$tmp" "$url" >/dev/null 2>&1 &
        else
            curl -fL -sS --connect-timeout 8 --max-time 110 -o "$tmp" "$url" >/dev/null 2>&1 &
        fi
    else
        if command -v timeout >/dev/null 2>&1; then
            timeout 120 wget -q -T 10 -t 2 -O "$tmp" "$url" >/dev/null 2>&1 &
        else
            wget -q -T 10 -t 2 -O "$tmp" "$url" >/dev/null 2>&1 &
        fi
    fi
    pid=$!

    while jobs -pr | grep -Fxq "$pid"; do
        if [[ -f "$tmp" ]]; then
            current=$(wc -c <"$tmp" 2>/dev/null || printf '0')
        else
            current=0
        fi
        [[ "$current" =~ ^[0-9]+$ ]] || current=0
        if [[ "$expected" =~ ^[0-9]+$ ]] && (( expected > 0 )); then
            pct=$(( current * 100 / expected ))
            (( pct > 99 )) && pct=99
        else
            pct=0
        fi
        filled=$(( pct * width / 100 )); empty=$((width-filled))
        printf '\r\033[K\033[1;33m[\033[1;32m%s\033[1;37m%s\033[1;33m]\033[0m %3d%% Paquete rápido (%ss)' \
            "$(repeat_char "$filled" '#')" "$(repeat_char "$empty" '-')" "$pct" "$elapsed"
        sleep 1
        elapsed=$((elapsed + 1))
    done
    wait "$pid"; rc=$?
    printf '\r\033[K'

    if (( rc != 0 )) || [[ ! -f "$tmp" ]]; then
        rm -f -- "$tmp"
        return 1
    fi
    current=$(wc -c <"$tmp" 2>/dev/null || printf '0')
    if [[ "$expected" =~ ^[0-9]+$ ]] && (( expected >= 0 )) && [[ "$current" != "$expected" ]]; then
        rm -f -- "$tmp"
        return 1
    fi
    mv -f -- "$tmp" "$dest"
    printf '\033[1;32m[%s] 100%%\033[0m Paquete rápido (%s bytes)\n' "$(repeat_char "$width" '#')" "$current"
    return 0
}

try_fast_bundle() {
    local key="$1" manifest="$2" meta bundle meta_url bundle_url expected_hash expected_size expected_count actual_hash actual_count
    local expected_list archive_list name idx=0

    [[ "${GOLDEN_FAST_MODE:-1}" != "0" ]] || return 1
    [[ "${SERVER_REV:-}" == "REV25" ]] || return 1
    command -v tar >/dev/null 2>&1 || return 1
    command -v sha256sum >/dev/null 2>&1 || return 1

    meta="$HOME/.golden-bundle.meta.$$"
    bundle="$HOME/.golden-bundle.tgz.$$"
    expected_list="$HOME/.golden-expected.$$"
    archive_list="$HOME/.golden-archive.$$"
    rm -f -- "$meta" "$bundle" "$expected_list" "$archive_list"

    meta_url="http://${KEY_HOSTPORT}/${key}/golden-bundle.meta"
    bundle_url="http://${KEY_HOSTPORT}/${key}/golden-bundle.tgz"

    safe_wget "$meta_url" "$meta" || { rm -f -- "$meta"; return 1; }
    server_error_file "$meta" && { rm -f -- "$meta"; return 1; }

    expected_hash=$(awk -F= '$1=="sha256"{print $2; exit}' "$meta" | tr -d '\r\n ')
    expected_size=$(awk -F= '$1=="size"{print $2; exit}' "$meta" | tr -d '\r\n ')
    expected_count=$(awk -F= '$1=="count"{print $2; exit}' "$meta" | tr -d '\r\n ')
    [[ "$expected_hash" =~ ^[0-9a-fA-F]{64}$ ]] || { rm -f -- "$meta"; return 1; }
    [[ "$expected_size" =~ ^[0-9]+$ && "$expected_count" =~ ^[0-9]+$ ]] || { rm -f -- "$meta"; return 1; }

    actual_count=$(tr ' \t' '\n' <"$manifest" | grep -cve '^$' 2>/dev/null || echo 0)
    [[ "$actual_count" == "$expected_count" ]] || { rm -f -- "$meta"; return 1; }

    msg -ama "Modo rápido REV25: descargando los ${expected_count} archivos en un solo paquete."
    bundle_download_with_progress "$bundle_url" "$bundle" "$expected_size" || {
        rm -f -- "$meta" "$bundle"
        return 1
    }

    actual_hash=$(sha256sum "$bundle" | awk '{print $1}')
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        msg -ama "El paquete rápido no pasó SHA-256; usando método estable individual."
        rm -f -- "$meta" "$bundle"
        return 1
    fi

    tr ' \t' '\n' <"$manifest" | grep -ve '^$' | LC_ALL=C sort -u >"$expected_list"
    if ! tar -tzf "$bundle" 2>/dev/null | sed 's#^\./##' | awk '
        $0 == "" || $0 == "." || $0 == ".." || $0 ~ /\// || $0 !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ { bad=1 }
        { print }
        END { if (bad) exit 2 }
    ' | LC_ALL=C sort -u >"$archive_list"; then
        rm -f -- "$meta" "$bundle" "$expected_list" "$archive_list"
        return 1
    fi
    if ! cmp -s "$expected_list" "$archive_list"; then
        rm -f -- "$meta" "$bundle" "$expected_list" "$archive_list"
        return 1
    fi

    rm -rf -- "$SCPinstal"
    mkdir -p "$SCPinstal"
    if ! tar -xzf "$bundle" -C "$SCPinstal" --no-same-owner 2>/dev/null; then
        rm -rf -- "$SCPinstal"
        mkdir -p "$SCPinstal"
        rm -f -- "$meta" "$bundle" "$expected_list" "$archive_list"
        return 1
    fi

    while IFS= read -r name || [[ -n "$name" ]]; do
        [[ -n "$name" ]] || continue
        [[ -f "$SCPinstal/$name" ]] || {
            rm -rf -- "$SCPinstal"; mkdir -p "$SCPinstal"
            rm -f -- "$meta" "$bundle" "$expected_list" "$archive_list"
            return 1
        }
    done <"$expected_list"

    for name in $(cat "$manifest"); do
        [[ -n "$name" ]] || continue
        idx=$((idx + 1))
        progress_line "$idx" "$expected_count" "$name" 'INSTALANDO LOCAL'
        verificar_arq "$name"
    done
    printf '\n'

    rm -f -- "$meta" "$bundle" "$expected_list" "$archive_list"
    msg -verd "Modo rápido completado: paquete verificado por SHA-256."
    return 0
}

translate_text() {
    local text="$1" out=""
    if [[ -x /usr/bin/trans ]]; then
        out=$(/usr/bin/trans -b "es:${id:-es}" "$text" 2>/dev/null || true)
    fi
    [[ -n "$out" ]] && printf '%s' "$out" || printf '%s' "$text"
}

declare -A cor=(
[0]="\033[1;37m"
[1]="\033[1;34m"
[2]="\033[1;32m"
[3]="\033[1;36m"
[4]="\033[1;31m"
[5]="\033[1;33m"
)

barra="\033[0m\e[33m=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=\033[1;37m"

mkdir -p /etc/B-ADMuser &>/dev/null

rm -rf /etc/localtime &>/dev/null
ln -s /usr/share/zoneinfo/America/Mexico_City /etc/localtime &>/dev/null

fun_bar () {
    local comando="${1:-true}"
    run_cmd_activity "Procesando" "$comando"
}

pkg_installed_client gawk || run_exec_activity "Instalando gawk" apt_client install -y --no-install-recommends gawk || true
if ! command -v locate >/dev/null 2>&1; then
    if pkg_available_client plocate; then
        run_exec_activity "Instalando locate" apt_client install -y --no-install-recommends plocate || true
    elif pkg_available_client mlocate; then
        run_exec_activity "Instalando locate" apt_client install -y --no-install-recommends mlocate || true
    fi
fi


msg () {
BRAN='\033[1;37m'
VERMELHO='\e[31m'
VERDE='\e[32m'
AMARELO='\e[33m'
AZUL='\e[33m'
MAGENTA='\e[35m'
MAG='\033[1;36m'
NEGRITO='\e[1m'
SEMCOR='\e[0m'

case $1 in
-ne)cor="${VERMELHO}${NEGRITO}" && echo -ne "${cor}${2}${SEMCOR}";;
-ama)cor="${AMARELO}${NEGRITO}" && echo -e "${cor}${2}${SEMCOR}";;
-verm)cor="${AMARELO}${NEGRITO}[!] ${VERMELHO}" && echo -e "${cor}${2}${SEMCOR}";;
-azu)cor="${MAG}${NEGRITO}" && echo -e "${cor}${2}${SEMCOR}";;
-verd)cor="${VERDE}${NEGRITO}" && echo -e "${cor}${2}${SEMCOR}";;
-bra)cor="${BRAN}${NEGRITO}" && echo -ne "${cor}${2}${SEMCOR}";;
"-bar2"|"-bar")cor="${AZUL}=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=×=" && echo -e "${cor}${SEMCOR}";;
esac
}

instalar_logo_login() {

cat >/etc/profile.d/newgolden-login.sh <<'EOF'
#!/bin/bash
[[ $- != *i* ]] && return 0

clear

CYAN=$'\033[1;36m'
GREEN=$'\033[1;32m'
BLUE=$'\033[1;34m'
ORANGE=$'\033[1;31m'
WHITE=$'\033[1;37m'
RESET=$'\033[0m'

cols=$(tput cols 2>/dev/null)
[[ -z "$cols" ]] && cols=80

center() {
    local text="$1"
    local len=${#text}
    local pad=$(( (cols - len) / 2 ))

    [[ $pad -lt 0 ]] && pad=0

    printf "%*s%s\n" "$pad" "" "$text"
}

usuarios_online() {
    local total_file total real_total user DB PID SSH_PID DROP_PID OVPN_PID

    # 1) Si el limitador está activo y ya generó contador, úsalo
    if [[ -s /etc/newadm/USRonlines ]]; then
        total_file=$(tr -cd '0-9' < /etc/newadm/USRonlines)
        if [[ -n "$total_file" && "$total_file" -gt 0 ]]; then
            echo "$total_file"
            return
        fi
    fi

    # 2) Si no hay limitador activo, calcular directo en el login
    real_total=0
    DB=""

    for f in /etc/newadm/ger-user/usuarios.db /root/usuarios.db; do
        [[ -s "$f" ]] && DB="$f" && break
    done

    [[ -z "$DB" ]] && echo "0" && return

    while IFS='|' read -r user pass fecha limite; do
        [[ -z "$user" ]] && continue
        [[ "$user" =~ ^systemd- ]] && continue
        [[ "$user" = "nobody" ]] && continue
        [[ "$user" = "polkitd" ]] && continue

        PID=0

        SSH_PID=$(ps aux | grep "[s]shd" | grep -w "$user" | grep -vc root)
        [[ -z "$SSH_PID" ]] && SSH_PID=0
        PID=$((PID + SSH_PID))

        if command -v dropbear >/dev/null 2>&1; then
            if command -v dropbear_pids >/dev/null 2>&1; then
                DROP_PID=$(dropbear_pids 2>/dev/null | grep -w "$user" | wc -l)
            else
                DROP_PID=$(ps aux | grep "[d]ropbear" | grep -w "$user" | wc -l)
            fi
            [[ -z "$DROP_PID" ]] && DROP_PID=0
            PID=$((PID + DROP_PID))
        fi

        if [[ -e /etc/openvpn/openvpn-status.log ]]; then
            if command -v openvpn_pids >/dev/null 2>&1; then
                OVPN_PID=$(openvpn_pids 2>/dev/null | grep -w "$user" | cut -d'|' -f2)
            else
                OVPN_PID=$(grep -w "$user" /etc/openvpn/openvpn-status.log | wc -l)
            fi
            [[ -z "$OVPN_PID" ]] && OVPN_PID=0
            PID=$((PID + OVPN_PID))
        fi

        [[ "$PID" -gt 0 ]] && real_total=$((real_total + PID))

    done < "$DB"

    echo "$real_total"
}

echo

if [[ "$cols" -lt 70 ]]; then

center "${BLUE}  ____  ___  _     ____  _____ _   _ "
center "${CYAN} / ___|/ _ \| |   |  _ \| ____| \ | |"
center "${CYAN}| |  _| | | | |   | | | |  _| |  \| |"
center "${GREEN}| |_| | |_| | |___| |_| | |___| |\  |"
center "${GREEN} \____|\___/|_____|____/|_____|_| \_|"

center ""

center "${GREEN} __  __ __  __"
center "${CYAN}|  \/  |\ \/ /"
center "${CYAN}| |\/| | \  / "
center "${BLUE}| |  | | /  \ "
center "${BLUE}|_|  |_|/_/\_\\"

else

center "${BLUE}  ____  ___  _     ____  _____ _   _     __  __ __  __"
center "${CYAN} / ___|/ _ \| |   |  _ \| ____| \ | |   |  \/  |\ \/ /"
center "${CYAN}| |  _| | | | |   | | | |  _| |  \| |   | |\/| | \  / "
center "${GREEN}| |_| | |_| | |___| |_| | |___| |\  |   | |  | | /  \ "
center "${GREEN} \____|\___/|_____|____/|_____|_| \_|   |_|  |_|/_/\_\\"

fi

echo

HOSTNAME_SERVER=$(hostname)

if [[ "$HOSTNAME_SERVER" = "localhost" ]]; then
    HOSTNAME_SERVER=$(hostname -I | awk '{print $1}')
fi

center "${WHITE}NOMBRE DEL SERVIDOR : ${HOSTNAME_SERVER}"
center "${WHITE}SERVIDOR ENCENDIDO : $(uptime -p | sed 's/up //')"
center "${WHITE}USUARIOS EN LINEA : $(usuarios_online)"
center "${WHITE}FECHA : $(date +%d-%m-%y)"
center "${WHITE}HORA : $(date +%T)"
center "${CYAN}@GoldenMX"

echo
center "${ORANGE}ESCRIBA ( menu ) PARA ENTRAR.${RESET}"
echo

EOF

chmod +x /etc/profile.d/newgolden-login.sh

cat >/etc/motd <<'EOF'
GOLDEN MX
Escriba menu para entrar.
EOF

}

clear
clear

echo -e "$barra"
msg -ama "\033[1;37mPREPARANDO COMPLEMENTOS FINALES"
echo -e "$barra"

# REV25: no instalar PHP/Node/compiladores durante el arranque. No son
# necesarios para abrir Golden y cada módulo instala sus dependencias cuando
# se utiliza. Esto conserva funciones y acelera Debian/Ubuntu recién creados.
run_exec_activity "Reparando dependencias" apt_client --fix-broken install -y || true
command -v ufw >/dev/null 2>&1 && run_exec_activity "Configurando firewall local" ufw disable || true

echo -e "$barra"
msg -ama "\033[1;37mCOMPLEMENTOS PREPARADOS"

fun_ip () {
MIP=$(hostname -I 2>/dev/null | awk '{print $1}')
MIP2=$(safe_wget_stdout "http://ipv4.icanhazip.com" | tr -d '\r\n ' || true)
if [[ "$MIP2" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    IP="$MIP2"
else
    IP="$MIP"
fi
}

inst_components () {
    # REV25: el bootstrap ya instaló el núcleo ANTES de pedir la key. Aquí no
    # repetimos un apt-get grande después de transferir los 43 archivos.
    # Solo reparamos una ejecución directa/legacy si realmente falta algo.
    local p
    local -a missing=()
    for p in nano bc screen python3 curl unzip zip lsof; do
        pkg_installed_client "$p" || missing+=("$p")
    done
    if ((${#missing[@]})); then
        install_client_group "Núcleo faltante" 1 "${missing[@]}" || return 1
    fi

    if ! pkg_installed_client apache2; then
        install_client_group_no_autostart "Apache faltante" 1 apache2 || return 1
    fi

    msg -verd "Núcleo Golden verificado; no se repite APT después de la KEY."

    # REV25: Apache queda EXCLUSIVAMENTE en TCP 81. No basta con añadir
    # Listen 81: hay que retirar cualquier listener Apache en 80 y migrar
    # VirtualHost *:80, incluyendo variantes de Debian/Ubuntu viejos.
    apache_force_port_81_config || return 1

    if ! apache_restart_golden; then
        echo "[ERROR] Apache no pudo reiniciarse en un máximo de 35s." >&2
        command -v apache2ctl >/dev/null 2>&1 && apache2ctl -t >&2 || true
        command -v systemctl >/dev/null 2>&1 && systemctl status apache2 --no-pager -l 2>/dev/null | tail -n 20 >&2 || true
        return 1
    fi

    if apache_process_listens 81; then
        msg -verd "Apache verificado en TCP 81."
    else
        echo "[ERROR] Apache arrancó pero no se detectó escuchando en TCP 81." >&2
        return 1
    fi
    if apache_process_listens 80; then
        echo "[ERROR] Apache todavía está reservando TCP 80; instalación detenida para no ocupar ese puerto." >&2
        return 1
    fi
    msg -verd "TCP 80 quedó libre de Apache para otros servicios."
    return 0
}
funcao_idioma () {
    if command -v figlet >/dev/null 2>&1; then
        if command -v lolcat >/dev/null 2>&1; then
            figlet "    GOLDEN MX" | lolcat
        else
            figlet "    GOLDEN MX"
        fi
    else
        echo -e "\033[1;33m    GOLDEN MX\033[0m"
    fi

    msg -bar2

    pv="es"

    [[ ${#id} -gt 2 ]] && id="es" || id="$pv"

    byinst="true"
}

install_fim () {

msg -ama "$(translate_text "Instalacion completa, utilize los Comandos")"

msg -bar2

echo -e " menu / adm"

msg -verm "$(translate_text "INICIE SESION CUANDO SE CIERRE ESTA TERMINAL")"

mkdir /etc/nanotxz  > /dev/null 2>&1
mkdir /etc/rom  > /dev/null 2>&1
mkdir /etc/bin  > /dev/null 2>&1

msg -bar2

sleep 10s

sudo reboot
}

ofus () {

unset txtofus

number=$(expr length "$1")

for((i=1; i<$number+1; i++)); do

txt[$i]=$(echo "$1" | cut -b $i)

case ${txt[$i]} in
".")txt[$i]="+";;
"+")txt[$i]=".";;
"1")txt[$i]="@";;
"@")txt[$i]="1";;
"2")txt[$i]="?";;
"?")txt[$i]="2";;
"3")txt[$i]="%";;
"%")txt[$i]="3";;
"/")txt[$i]="K";;
"K")txt[$i]="/";;
esac

txtofus+="${txt[$i]}"

done

echo "$txtofus" | rev
}

migrar_nombres_protocolos() {
    mkdir -p "$SCPinst"
    local old new pair
    for pair in \
        'budp.sh:badvpn.sh' \
        'shadowsocksLive.sh:proxygo.sh' \
        'ssrrmu.sh:haproxy.sh' \
        'shadown.sh:hysteria.sh' \
        'shadowsock.sh:slowdns.sh' \
        'sockspy.sh:websocket.sh'; do
        old="${pair%%:*}"; new="${pair#*:}"
        if [[ -e "$SCPinst/$old" ]]; then
            if [[ ! -e "$SCPinst/$new" ]]; then
                mv -f -- "$SCPinst/$old" "$SCPinst/$new" 2>/dev/null || true
            else
                rm -f -- "$SCPinst/$old"
            fi
        fi
    done
}

migrar_nombres_protocolos

verificar_arq () {

[[ ! -d ${SCPdir} ]] && mkdir ${SCPdir}
[[ ! -d ${SCPdir2} ]] && mkdir ${SCPdir2}
[[ ! -d ${SCPusr} ]] && mkdir ${SCPusr}
[[ ! -d ${SCPfrm} ]] && mkdir ${SCPfrm}
[[ ! -d ${SCPinst} ]] && mkdir ${SCPinst}

if [[ ! -s /etc/newadm/ger-user/tiemlim.log ]]; then
    safe_wget "https://www.dropbox.com/s/sew455tgb0v79wm/tiemlim.log" /etc/newadm/ger-user/tiemlim.log || printf '120\n' >/etc/newadm/ger-user/tiemlim.log
fi

if [[ ! -e /etc/newadm/ger-user/IDT.log ]]; then
    safe_wget "https://www.dropbox.com/s/norz9mhypyto4e2/IDT.log" /etc/newadm/ger-user/IDT.log || : >/etc/newadm/ger-user/IDT.log
fi

case $1 in
"menu"|"message.txt")ARQ="${SCPdir}/";;
"usercodes")ARQ="${SCPusr}/";;
"openssh.sh"|"squid.sh"|"dropbear.sh"|"openvpn.sh"|"ssl.sh"|"proxygo.sh"|"hysteria.sh"|"badvpn.sh"|"slowdns.sh"|"haproxy.sh"|"shadowsocks.sh"|"v2ray.sh"|"websocket.sh"|"compat.sh"|"PDirect.py"|"PPub.py"|"PPriv.py"|"POpen.py"|"PGet.py") ARQ="${SCPinst}/";;
*)ARQ="${SCPfrm}/";;
esac

mv -f ${SCPinstal}/$1 ${ARQ}/$1

chmod +x ${ARQ}/$1
}

post_payload_sanity() {
    local f
    local -a required=(compat.sh badvpn.sh proxygo.sh dropbear.sh openvpn.sh ssl.sh squid.sh haproxy.sh hysteria.sh slowdns.sh v2ray.sh websocket.sh)
    for f in "${required[@]}"; do
        if [[ ! -s "$SCPinst/$f" ]]; then
            echo "[ERROR] Componente requerido ausente o vacío: $SCPinst/$f" >&2
            return 1
        fi
        if head -n1 "$SCPinst/$f" 2>/dev/null | grep -qE '(^#!.*(bash|/sh))'; then
            bash -n "$SCPinst/$f" || {
                echo "[ERROR] Sintaxis inválida en: $SCPinst/$f" >&2
                return 1
            }
        fi
    done
    # compat.sh debe cargar realmente las funciones que usan los protocolos.
    bash -c '. /etc/ger-inst/compat.sh; declare -F golden_apt_wait >/dev/null; declare -F golden_progress_command >/dev/null; declare -F golden_service >/dev/null' || {
        echo "[ERROR] compat.sh no cargó las funciones requeridas." >&2
        return 1
    }
    return 0
}

fun_ip

safe_wget "https://www.dropbox.com/s/dzknghcgew54pc6/trans" /usr/bin/trans || true

safe_wget "https://raw.githubusercontent.com/satanas66666/golden-system2/main/limv2ray" /usr/bin/limv2ray || \
    safe_wget "https://raw.githubusercontent.com/satanas66666/golden-system2/main/limv2ray" /usr/bin/limv2ray || true

[[ -s /usr/bin/limv2ray ]] && chmod +x /usr/bin/limv2ray

safe_wget "https://raw.githubusercontent.com/satanas66666/golden-system2/main/Desbloqueo.sh" /bin/Desbloqueo.sh || \
    safe_wget "https://raw.githubusercontent.com/satanas66666/golden-system2/main/Desbloqueo.sh" /bin/Desbloqueo.sh || true

[[ -s /bin/Desbloqueo.sh ]] && chmod +x /bin/Desbloqueo.sh

msg -bar2
msg -ama "[ INSTALADOR OFICIAL ] [ NEW - GOLDEN ADM PRO ]"
msg -bar2
msg -ama "\033[1;37mESTE ESCRIPT SOLO FUNCIONA EN EL IDIOMA ESPAÑOL"
msg -ama "\033[1;37mINGRESE SU KEY DE INSTALACION SI NO TIENES PONTE EN CONTACTO"
msg -bar2
msg -ama "\033[1;34mTELEGRAM: @ELDIABLOLUCIFER2020"
msg -ama "\033[1;34mWHATSAPP: +52 2292453056"
msg -bar2

[[ $1 = "" ]] && funcao_idioma || {
[[ ${#1} -gt 2 ]] && funcao_idioma || id="$1"
}

download_error_fun () {

msg -bar2
msg -verm "La KEY fue validada, pero falló la entrega de archivos."
msg -ama "No se eliminó la KEY. Revisa/actualiza http-server.sh en la VPS del generador."
msg -ama "El instalador intentó primero TCP 8888 y después el fallback TCP 81."
msg -bar2

[[ -d ${SCPinstal} ]] && rm -rf ${SCPinstal}
exit 2
}

invalid_key () {

echo -e "$barra"

msg -verm "Key Failed! "

msg -bar2

[[ -e $HOME/lista-arq ]] && rm $HOME/lista-arq

exit 1
}

while [[ ! $Key ]]; do
msg -ne "Script Key: "
read Key
tput cuu1 2>/dev/null
tput dl1 2>/dev/null
done

msg -ne "Key: "

cd $HOME

DECODED_KEY="$(ofus "$Key")"
DECODED_KEY="${DECODED_KEY#http://}"
DECODED_KEY="${DECODED_KEY#https://}"
KEY_HOSTPORT="${DECODED_KEY%%/*}"
KEY_PATH="${DECODED_KEY#*/}"
KEY_ID="${KEY_PATH%%/*}"
KEY_LIST="${KEY_PATH#*/}"
KEY_LIST="${KEY_LIST%%/*}"
KEY_URL="http://${KEY_HOSTPORT}/${KEY_ID}/${KEY_LIST}/${IP}"

if fetch_with_activity "$KEY_URL" "$HOME/lista-arq" 0 1 "Verificando KEY" "TCP 8888"; then
    if server_error_file "$HOME/lista-arq"; then
        cat "$HOME/lista-arq" 2>/dev/null || true
        invalid_key
        exit
    fi
    progress_line 1 1 "KEY válida" "OK"
    printf '\n'
else
    echo -e "\033[1;31m Sin respuesta del servidor de keys"
    invalid_key
    exit
fi

SERVER_REV=$(safe_wget_stdout "http://${KEY_HOSTPORT}/__golden_version" 2>/dev/null | tr -d '\r\n ' || true)
if [[ -z "$SERVER_REV" ]]; then
    msg -ama "Servidor sin identificador de versión; se probará TCP 8888 y fallback TCP 81 automáticamente."
else
    msg -ama "Servidor de keys: ${SERVER_REV}. Transferencia rápida + fallback estable habilitados."
fi

if grep -q "KEY INVALIDA!\|IP DIFERENTE - ACCESO BLOQUEADO" "$HOME/lista-arq" 2>/dev/null; then
    cat "$HOME/lista-arq"
    invalid_key
    exit
fi

IP=$(printf '%s' "$KEY_HOSTPORT" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)

echo "$IP" > /usr/bin/vendor_code

sleep 1s

timeout 60 updatedb 2>/dev/null || true

if [[ -e $HOME/lista-arq ]] && [[ ! $(cat $HOME/lista-arq | grep "KEY INVALIDA!") ]]; then

echo -e "$barra"

msg -ama "$(translate_text "BIENVENIDO, GRACIAS POR UTILIZAR"): \033[1;31m[ NEW-GOLDEN ADM PRO ]"

REQUEST="$KEY_ID"

[[ ! -d ${SCPinstal} ]] && mkdir ${SCPinstal}

pontos="."

stopping="$(translate_text "Descargando archivos")"

TOTAL_ARQ=$(tr ' \t' '\n' <"$HOME/lista-arq" | grep -cve '^$' 2>/dev/null || echo 0)
CURRENT_ARQ=0

# REV25 FAST PATH: una sola descarga comprimida y validada. Si cualquier paso
# falla, se conserva exactamente el flujo individual REV25 como fallback.
if try_fast_bundle "$REQUEST" "$HOME/lista-arq"; then
    :
else
    [[ "${SERVER_REV:-}" == "REV25" ]] && msg -ama "Modo rápido no disponible; continuando con método estable archivo por archivo."
    rm -rf -- "$SCPinstal"
    mkdir -p "$SCPinstal"

    for arqx in $(cat "$HOME/lista-arq"); do

    CURRENT_ARQ=$((CURRENT_ARQ + 1))
    DEST="${SCPinstal}/${arqx}"

    # Fallback REV25 SIN CAMBIOS: 8888 -> 81 -> 8888 final.
    if download_payload_file "${arqx}" "$DEST" "$CURRENT_ARQ" "$TOTAL_ARQ"; then
        verificar_arq "${arqx}"
    else
        msg -verm "No se pudo descargar: ${arqx}"
        msg -ama "La KEY es válida. El servidor de archivos no respondió por 8888 ni por 81."
        download_error_fun
    fi

    pontos+="."

    done
fi

if ! post_payload_sanity; then
    msg -verm "La transferencia terminó, pero la validación local de módulos falló."
    msg -ama "No se continuará con una instalación incompleta o mezclada."
    exit 3
fi

sleep 1s

msg -bar2

rm -f "$HOME/lista-arq"

cat /etc/bash.bashrc | grep -v '[[ $UID != 0 ]] && TMOUT=15 && export TMOUT' > /etc/bash.bashrc.2

echo '[[ $UID != 0 ]] && TMOUT=15 && export TMOUT' >> /etc/bash.bashrc.2

mv -f /etc/bash.bashrc.2 /etc/bash.bashrc

echo "${SCPdir}/menu" > /usr/bin/menu
chmod +x /usr/bin/menu

echo "${SCPdir}/menu" > /usr/bin/adm
chmod +x /usr/bin/adm

instalar_logo_login

if ! inst_components; then
    msg -verm "Falló la preparación final del núcleo Golden."
    msg -ama "La KEY y los 43 archivos están correctos; revisa el diagnóstico mostrado arriba."
    exit 4
fi

echo "$Key" > ${SCPdir}/key.txt

[[ -d ${SCPinstal} ]] && rm -rf ${SCPinstal}

[[ ${#id} -gt 2 ]] && echo "pt" > ${SCPidioma} || echo "${id}" > ${SCPidioma}

[[ ${byinst} = "true" ]] && install_fim

else

invalid_key

fi

