#!/usr/bin/env bash
# Golden System PRO - servidor HTTP de llaves (REV16 fast-bundle + stream-fix + self-healing + legacy)
# Compatible con Ubuntu/Debian antiguos y modernos que dispongan de Bash 4+.
#
# Modos:
#   http-server.sh --listen   Inicia el listener TCP
#   http-server.sh --request  Atiende una sola solicitud por stdin/stdout
#   http-server.sh --check    Valida la instalación
#   http-server.sh --health   Comprueba que el listener responde realmente
#
# Compatibilidad con la sintaxis anterior:
#   -start, -s, -iniciar, -install, -i

set -u
umask 077

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ROOT_DIR="${GOLDEN_KEY_DIR:-/etc/http-shell}"
WEB_ROOT="${GOLDEN_WEB_ROOT:-/var/www/html}"
ALT_WEB_ROOT="${GOLDEN_ALT_WEB_ROOT:-/var/www}"
COUNTER_FILE="${GOLDEN_COUNTER_FILE:-/etc/http-instas}"
LOG_FILE="${GOLDEN_HTTP_LOG:-/var/log/golden-http.log}"
PORT="${GOLDEN_HTTP_PORT:-8888}"
STAGE_TTL="${GOLDEN_STAGE_TTL:-180}"
INSTALL_LIST="${GOLDEN_INSTALL_LIST:-orp-nedlog}"
TOOL_LIST="${GOLDEN_TOOL_LIST:-lista-arq}"
BUNDLE_NAME="golden-bundle.tgz"
BUNDLE_META="golden-bundle.meta"
SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

[[ "$STAGE_TTL" =~ ^[0-9]+$ ]] && (( STAGE_TTL >= 10 && STAGE_TTL <= 86400 )) || STAGE_TTL=180

mkdir -p "$ROOT_DIR" "$(dirname "$COUNTER_FILE")" "$(dirname "$LOG_FILE")" 2>/dev/null || true
[[ -f "$COUNTER_FILE" ]] || printf '0\n' >"$COUNTER_FILE" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true
chmod 600 "$LOG_FILE" "$COUNTER_FILE" 2>/dev/null || true

log_msg() {
    local level="$1"
    shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

safe_component() {
    # Evita traversal, espacios, barras, bytes de control y nombres ocultos de control.
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] &&
    [[ "$1" != "." && "$1" != ".." ]]
}

normalise_ip() {
    local ip="${1:-}"
    ip="${ip#[}"
    ip="${ip%]}"
    ip="${ip#::ffff:}"
    printf '%s' "$ip"
}

peer_ip() {
    local ip="" ssh_client="${SSH_CLIENT:-}"
    # socat exporta SOCAT_PEERADDR. El fallback Python exporta REMOTE_ADDR.
    for ip in "${SOCAT_PEERADDR:-}" "${REMOTE_ADDR:-}" "${TCPREMOTEIP:-}" "${ssh_client%% *}"; do
        [[ -n "$ip" ]] && {
            normalise_ip "$ip"
            return 0
        }
    done
    printf 'unknown'
}

http_reply() {
    local code="$1"
    local reason="$2"
    local body="$3"
    local method="${4:-GET}"
    local length
    length=$(printf '%s' "$body" | wc -c | tr -d ' ')

    printf 'HTTP/1.1 %s %s\r\n' "$code" "$reason"
    printf 'Date: %s\r\n' "$(LC_ALL=C date -R 2>/dev/null || date)"
    printf 'Server: GoldenShellHTTP/2.0\r\n'
    printf 'Content-Type: text/plain; charset=utf-8\r\n'
    printf 'Content-Length: %s\r\n' "$length"
    printf 'Cache-Control: no-store\r\n'
    printf 'Connection: close\r\n'
    printf '\r\n'
    [[ "$method" == "HEAD" ]] || printf '%s' "$body"
}

http_file_reply() {
    local code="$1" reason="$2" file="$3" method="${4:-GET}" length
    [[ -f "$file" && ! -L "$file" ]] || return 1
    length=$(wc -c <"$file" 2>/dev/null | tr -d ' ')
    [[ "$length" =~ ^[0-9]+$ ]] || return 1

    printf 'HTTP/1.1 %s %s\r\n' "$code" "$reason"
    printf 'Date: %s\r\n' "$(LC_ALL=C date -R 2>/dev/null || date)"
    printf 'Server: GoldenShellHTTP/2.2\r\n'
    printf 'Content-Type: application/octet-stream\r\n'
    printf 'Content-Length: %s\r\n' "$length"
    printf 'Cache-Control: no-store\r\n'
    printf 'Connection: close\r\n'
    printf '\r\n'
    [[ "$method" == "HEAD" ]] || cat -- "$file"
}

file_in_manifest() {
    local key_dir="$1" wanted="$2" manifest line token
    for manifest in "$key_dir/$INSTALL_LIST" "$key_dir/$TOOL_LIST"; do
        [[ -f "$manifest" && ! -L "$manifest" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            for token in $line; do
                [[ "$token" == "$wanted" ]] && return 0
            done
        done <"$manifest"
    done
    return 1
}

counter_increment() {
    local n
    if command -v flock >/dev/null 2>&1; then
        (
            flock -x 9
            n=$(cat "$COUNTER_FILE" 2>/dev/null)
            [[ "$n" =~ ^[0-9]+$ ]] || n=0
            printf '%s\n' "$((n + 1))" >"$COUNTER_FILE"
        ) 9>"${COUNTER_FILE}.lock"
    else
        local lock="${COUNTER_FILE}.lockdir"
        local tries=0
        while ! mkdir "$lock" 2>/dev/null; do
            sleep 0.1
            tries=$((tries + 1))
            (( tries > 100 )) && return 0
        done
        n=$(cat "$COUNTER_FILE" 2>/dev/null)
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        printf '%s\n' "$((n + 1))" >"$COUNTER_FILE"
        rmdir "$lock" 2>/dev/null || true
    fi
}

stage_payload() {
    local key="$1"
    local list_file="$2"
    local key_dir="${ROOT_DIR}/${key}"
    local file name token token_file root stage
    local -a names=() roots=()

    # REV7: publica temporalmente en todas las raíces históricas conocidas.
    # Así el fallback por Apache/81 sigue funcionando aunque el generador haya
    # sido instalado con una revisión anterior que usaba otro DocumentRoot.
    for root in "$WEB_ROOT" "$ALT_WEB_ROOT" /var/www/golden /var/www/html /var/www; do
        [[ -n "$root" ]] || continue
        local seen=0 r
        for r in "${roots[@]}"; do [[ "$r" == "$root" ]] && seen=1 && break; done
        (( seen == 0 )) && roots+=("$root")
    done

    for root in "${roots[@]}"; do
        mkdir -p "$root" 2>/dev/null || continue
        stage="${root}/${key}"
        rm -rf -- "$stage" 2>/dev/null || true
        mkdir -p "$stage" 2>/dev/null || continue
        chmod 0755 "$stage" 2>/dev/null || true
    done

    while IFS= read -r file || [[ -n "$file" ]]; do
        IFS=$' \t' read -r -a names <<<"$file"
        for name in "${names[@]}"; do
            safe_component "$name" || {
                log_msg WARN "archivo rechazado en lista key=$key nombre=$name"
                continue
            }
            [[ -f "${key_dir}/${name}" && ! -L "${key_dir}/${name}" ]] || {
                log_msg WARN "archivo ausente key=$key nombre=$name"
                continue
            }
            for root in "${roots[@]}"; do
                stage="${root}/${key}"
                [[ -d "$stage" ]] || continue
                cp -f -- "${key_dir}/${name}" "${stage}/${name}" 2>/dev/null || continue
                chmod 0644 "${stage}/${name}" 2>/dev/null || true
            done
        done
    done <"$list_file"

    token="$(date +%s 2>/dev/null).$$.$RANDOM"
    token_file="/tmp/golden-stage-${key}.token"
    printf '%s\n' "$token" >"$token_file"
    (
        sleep "$STAGE_TTL"
        if [[ "$(cat "$token_file" 2>/dev/null)" == "$token" ]]; then
            for root in "${roots[@]}"; do
                rm -rf -- "${root}/${key}" 2>/dev/null || true
            done
            rm -f -- "$token_file"
        fi
    ) >/dev/null 2>&1 &

    return 0
}

handle_request() {
    local request_line method target protocol path key arq key_dir file fixed saved_ip usr_ip body
    local legacy_ip extra
    IFS= read -r request_line || request_line=""
    request_line="${request_line%$'\r'}"

    # REV11: consumir todos los encabezados HTTP antes de escribir la respuesta.
    # Evita bloqueos de tubería en kernels con buffers pequeños cuando socat
    # ejecuta el handler mediante EXEC y la respuesta supera ~16 KiB.
    local header_line
    while IFS= read -r header_line; do
        header_line="${header_line%$'\r'}"
        [[ -z "$header_line" ]] && break
    done

    method="${request_line%% *}"
    target="${request_line#* }"
    if [[ "$target" == "$request_line" ]]; then
        http_reply 400 "Bad Request" "SOLICITUD INVALIDA!" GET
        return 0
    fi
    protocol="${target##* }"
    target="${target% *}"

    [[ "$method" == "GET" || "$method" == "HEAD" ]] || {
        http_reply 405 "Method Not Allowed" "METODO NO PERMITIDO!" GET
        return 0
    }

    # También acepta una URL absoluta enviada por algunos proxies.
    target="${target#http://}"
    target="${target#https://}"
    [[ "$target" == /* ]] || target="/${target#*/}"
    path="${target%%\?*}"
    path="${path#/}"

    # Endpoints internos de salud/versión para watchdog y diagnóstico.
    if [[ "$path" == "__golden_health" ]]; then
        http_reply 200 "OK" "OK" "$method"
        return 0
    fi
    if [[ "$path" == "__golden_version" ]]; then
        http_reply 200 "OK" "REV16" "$method"
        return 0
    fi

    # Formatos admitidos:
    #   /KEY/orp-nedlog
    #   /KEY/orp-nedlog/IP-DEL-CLIENTE       (legacy)
    #   /KEY/NOMBRE-DE-ARCHIVO               (REV6, descarga directa)
    # El tercer segmento se tolera por compatibilidad pero nunca se usa como IP real.
    IFS='/' read -r key arq legacy_ip extra <<<"$path"
    if [[ -n "${extra:-}" ]] || ! safe_component "${key:-}" || ! safe_component "${arq:-}"; then
        http_reply 200 "OK" "KEY INVALIDA!" "$method"
        log_msg WARN "ruta invalida peer=$(peer_ip) request=$request_line"
        return 0
    fi
    if [[ -n "${legacy_ip:-}" && ! "$legacy_ip" =~ ^[0-9A-Fa-f:.]+$ ]]; then
        http_reply 200 "OK" "KEY INVALIDA!" "$method"
        log_msg WARN "segmento legacy invalido peer=$(peer_ip) request=$request_line"
        return 0
    fi

    key_dir="${ROOT_DIR}/${key}"
    usr_ip="$(peer_ip)"
    if [[ ! -d "$key_dir" ]]; then
        http_reply 200 "OK" "KEY INVALIDA!" "$method"
        log_msg WARN "key inexistente key=$key peer=$usr_ip"
        return 0
    fi

    # IP fija: siempre se valida contra la IP real del socket.
    fixed="${key_dir}/keyfixa"
    if [[ -s "$fixed" ]]; then
        saved_ip="$(tr -d '\r\n[:space:]' <"$fixed")"
        saved_ip="$(normalise_ip "$saved_ip")"
        if [[ -z "$saved_ip" || "$usr_ip" == "unknown" || "$usr_ip" != "$saved_ip" ]]; then
            http_reply 200 "OK" "IP DIFERENTE - ACCESO BLOQUEADO" "$method"
            printf 'USUARIO: %s IP FIJA: %s USO IP: %s\n' \
                "$(cat "${ROOT_DIR}/${key}.name" 2>/dev/null || printf 'sin-nombre')" \
                "$saved_ip" "$usr_ip" >>/etc/gerar-sh-log 2>/dev/null || true
            printf '%s\n' '--------------------------------------------------------------------' >>/etc/gerar-sh-log 2>/dev/null || true
            log_msg WARN "ip bloqueada key=$key esperada=$saved_ip recibida=$usr_ip"
            return 0
        fi
    fi

    # REV16: ruta rápida opcional. El bundle solo existe para keys nuevas creadas
    # por REV16. Si no existe, el cliente vuelve automáticamente al flujo 43/43.
    if [[ "$arq" == "$BUNDLE_NAME" || "$arq" == "$BUNDLE_META" ]]; then
        file="${key_dir}/${arq}"
        if [[ ! -f "$file" || -L "$file" || ! -f "${key_dir}/.fast" ]]; then
            http_reply 404 "Not Found" "ARCHIVO NO DISPONIBLE!" "$method"
            log_msg WARN "bundle no disponible key=$key file=$arq peer=$usr_ip"
            return 0
        fi
        http_file_reply 200 "OK" "$file" "$method" || {
            http_reply 500 "Internal Server Error" "ERROR LEYENDO ARCHIVO!" "$method"
            return 0
        }
        log_msg INFO "bundle key=$key file=$arq peer=$usr_ip"
        return 0
    fi

    # Solicitud de manifiesto/lista: mantiene staging por puerto 81 para instaladores viejos.
    if [[ "$arq" == "$INSTALL_LIST" || "$arq" == "$TOOL_LIST" ]]; then
        file="${key_dir}/${arq}"
        if [[ ! -f "$file" || -L "$file" ]]; then
            http_reply 200 "OK" "KEY INVALIDA!" "$method"
            log_msg WARN "lista inexistente key=$key file=$arq peer=$usr_ip"
            return 0
        fi
        if ! stage_payload "$key" "$file"; then
            http_reply 500 "Internal Server Error" "ERROR PREPARANDO ARCHIVOS!" "$method"
            log_msg ERROR "fallo staging key=$key file=$arq peer=$usr_ip"
            return 0
        fi
        body="$(cat "$file" 2>/dev/null)"
        http_reply 200 "OK" "$body" "$method"
        printf '%s|%s|%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$usr_ip" "$arq" >"${key_dir}/.used" 2>/dev/null || true
        counter_increment
        log_msg INFO "entrega correcta key=$key file=$arq peer=$usr_ip"
        return 0
    fi

    # REV6: entrega directa del archivo por el mismo puerto 8888. Solo permite
    # archivos que estén incluidos explícitamente en alguno de los manifiestos.
    file="${key_dir}/${arq}"
    if ! file_in_manifest "$key_dir" "$arq" || [[ ! -f "$file" || -L "$file" ]]; then
        http_reply 404 "Not Found" "ARCHIVO NO DISPONIBLE!" "$method"
        log_msg WARN "archivo directo rechazado key=$key file=$arq peer=$usr_ip"
        return 0
    fi
    http_file_reply 200 "OK" "$file" "$method" || {
        http_reply 500 "Internal Server Error" "ERROR LEYENDO ARCHIVO!" "$method"
        return 0
    }
    log_msg INFO "archivo directo key=$key file=$arq peer=$usr_ip"
}

python_listener() {
    command -v python3 >/dev/null 2>&1 || {
        log_msg ERROR "no existe socat ni python3"
        echo "ERROR: instala socat o python3." >&2
        return 1
    }

    exec python3 - "$PORT" "$SELF" <<'PY'
from __future__ import print_function
import os
import socket
import subprocess
import sys
import threading

port = int(sys.argv[1])
script = sys.argv[2]

def client_worker(conn, addr):
    try:
        conn.settimeout(20)
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 65536:
            part = conn.recv(4096)
            if not part:
                break
            data += part
        env = os.environ.copy()
        env["REMOTE_ADDR"] = addr[0]
        proc = subprocess.Popen(
            [script, "--request"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
        out, err = proc.communicate(data)
        if out:
            conn.sendall(out)
    except Exception:
        try:
            conn.sendall(b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        except Exception:
            pass
    finally:
        try:
            conn.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass
        conn.close()

family = socket.AF_INET6 if os.environ.get("GOLDEN_LISTEN_IPV6") == "1" else socket.AF_INET
bind_addr = "::" if family == socket.AF_INET6 else "0.0.0.0"
server = socket.socket(family, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
try:
    server.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
except Exception:
    pass
server.bind((bind_addr, port))
server.listen(128)
while True:
    conn, addr = server.accept()
    t = threading.Thread(target=client_worker, args=(conn, addr))
    t.daemon = True
    t.start()
PY
}

listen_server() {
    is_valid_port "$PORT" || {
        echo "ERROR: puerto inválido: $PORT" >&2
        return 1
    }
    mkdir -p "$ROOT_DIR" "$WEB_ROOT" "$ALT_WEB_ROOT" || return 1
    log_msg INFO "iniciando listener puerto=$PORT"

    # REV11: Python 3 es el listener principal. Lee la petición completa antes
    # de ejecutar el handler y evita el atasco observado exactamente a 16 KiB
    # con socat/EXEC en algunas VPS. Los archivos de Golden son pequeños y la
    # respuesta se envía mediante sendall().
    if command -v python3 >/dev/null 2>&1; then
        python_listener
        return $?
    fi

    # Fallback para instalaciones antiguas sin Python 3. El handler REV11
    # consume todos los encabezados, reduciendo también el riesgo de deadlock.
    if command -v socat >/dev/null 2>&1; then
        exec socat -T 30 "TCP-LISTEN:${PORT},reuseaddr,fork" "EXEC:${SELF} --request"
    fi

    echo "ERROR: instala python3 o socat." >&2
    return 1
}

healthcheck() {
    local url="http://127.0.0.1:${PORT}/__golden_health" out=""

    if command -v curl >/dev/null 2>&1; then
        out=$(curl -fsS --connect-timeout 2 --max-time 4 "$url" 2>/dev/null || true)
    elif command -v wget >/dev/null 2>&1; then
        out=$(wget -qO- --timeout=4 "$url" 2>/dev/null || true)
    else
        # Bash /dev/tcp como último recurso para sistemas muy antiguos.
        out=$(
            exec 9<>"/dev/tcp/127.0.0.1/${PORT}" || exit 1
            printf 'GET /__golden_health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n' >&9
            cat <&9
        ) 2>/dev/null || true
        out="${out##*$'\r\n\r\n'}"
    fi

    if [[ "$out" == "OK" ]]; then
        echo "OK: listener Golden HTTP responde en puerto $PORT"
        return 0
    fi
    echo "ERROR: listener Golden HTTP no responde en puerto $PORT" >&2
    return 1
}

check_install() {
    local rc=0
    [[ -d "$ROOT_DIR" ]] || { echo "FALTA: $ROOT_DIR"; rc=1; }
    [[ -x "$SELF" ]] || { echo "SIN PERMISO DE EJECUCION: $SELF"; rc=1; }
    is_valid_port "$PORT" || { echo "PUERTO INVALIDO: $PORT"; rc=1; }
    if ! command -v socat >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
        echo "FALTA: socat o python3"
        rc=1
    fi
    if (( rc == 0 )); then
        echo "OK: Golden HTTP REV16 listo en puerto $PORT"
    fi
    return "$rc"
}

case "${1:-}" in
    --listen|-start|-Start|-s|-S|-iniciar|-Iniciar|-install|-Install|-i|-I|-instalar|-Instalar)
        listen_server
        ;;
    --request)
        handle_request
        ;;
    --check)
        check_install
        ;;
    --health)
        healthcheck
        ;;
    --help|-h)
        sed -n '2,12p' "$SELF"
        ;;
    "")
        handle_request
        ;;
    *)
        echo "Uso: $0 [--listen|--request|--check|--health]" >&2
        exit 2
        ;;
esac
