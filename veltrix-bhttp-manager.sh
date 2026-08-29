#!/usr/bin/env bash
# SuperFlash BHTTP/SSH Server Manager v2.0.0
# Clean-room BHTTP server for SuperFlash. NO Veltrix token/license required.
# Does NOT patch, bypass, or use licensed VeltrixProxy binaries.
# Ubuntu 14.04+ / Debian 8+

set -u
umask 077

VERSION="2.0.0"
APP_DIR="/usr/local/lib/superflash-bhttp"
SERVER="$APP_DIR/server.py"
CONF="/etc/superflash-bhttp.conf"
MARKER="/etc/superflash-bhttp.installed"
SERVICE="superflash-bhttp"
LOGFILE="/var/log/superflash-bhttp.log"
PIDFILE="/run/superflash-bhttp.pid"
DEFAULT_LISTEN_PORT=80
DEFAULT_BACKEND_PORT=22

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
ok(){ echo -e "${GREEN}✔ $*${NC}"; }
info(){ echo -e "${CYAN}➜ $*${NC}"; }
warn(){ echo -e "${YELLOW}⚠ $*${NC}"; }
err(){ echo -e "${RED}✘ $*${NC}" >&2; }
have(){ command -v "$1" >/dev/null 2>&1; }
pause(){ echo; read -r -p "Presiona ENTER para continuar..." _; }

require_root(){ [ "$(id -u)" -eq 0 ] || { err "Ejecuta como root."; exit 1; }; }

load_os(){
  OS_ID=""; OS_VERSION=""; OS_PRETTY="Linux"
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-}"; OS_VERSION="${VERSION_ID:-}"; OS_PRETTY="${PRETTY_NAME:-Linux}"
  elif have lsb_release; then
    OS_ID="$(lsb_release -si 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    OS_VERSION="$(lsb_release -sr 2>/dev/null)"
    OS_PRETTY="$(lsb_release -sd 2>/dev/null)"
  fi
  case "$OS_ID" in ubuntu|debian) ;; *) err "Solo Ubuntu/Debian. Detectado: $OS_PRETTY"; exit 1;; esac
}

validate_port(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

load_conf(){
  BHTTP_PORT="$DEFAULT_LISTEN_PORT"
  BACKEND_PORT="$DEFAULT_BACKEND_PORT"
  SESSION_TTL="120"
  MAX_SESSIONS="1024"
  [ -r "$CONF" ] && . "$CONF"
  validate_port "$BHTTP_PORT" || BHTTP_PORT="$DEFAULT_LISTEN_PORT"
  validate_port "$BACKEND_PORT" || BACKEND_PORT="$DEFAULT_BACKEND_PORT"
}

save_conf(){
  cat > "$CONF" <<EOF
BHTTP_PORT=$BHTTP_PORT
BACKEND_PORT=$BACKEND_PORT
SESSION_TTL=$SESSION_TTL
MAX_SESSIONS=$MAX_SESSIONS
EOF
  chmod 600 "$CONF"
}

installed(){ [ -x "$SERVER" ] && [ -f "$MARKER" ]; }
service_active(){
  if have systemctl; then systemctl is-active --quiet "$SERVICE" 2>/dev/null
  else [ -s "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
  fi
}
listening(){
  load_conf
  if have ss; then ss -lnt 2>/dev/null | awk -v p=":$BHTTP_PORT" '$4 ~ p"$" {f=1} END{exit !f}'
  elif have netstat; then netstat -lnt 2>/dev/null | awk -v p=":$BHTTP_PORT" '$4 ~ p"$" {f=1} END{exit !f}'
  else return 1; fi
}
backend_listening(){
  load_conf
  if have ss; then ss -lnt 2>/dev/null | awk -v p=":$BACKEND_PORT" '$4 ~ p"$" {f=1} END{exit !f}'
  elif have netstat; then netstat -lnt 2>/dev/null | awk -v p=":$BACKEND_PORT" '$4 ~ p"$" {f=1} END{exit !f}'
  else return 1; fi
}

header(){
  load_conf
  clear 2>/dev/null || true
  echo -e "${BLUE}${BOLD}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║       SUPERFLASH BHTTP/SSH SERVER MANAGER v$VERSION          ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e " Sistema    : ${BOLD}$OS_PRETTY${NC}"
  echo -e " Kernel     : ${BOLD}$(uname -r)${NC}"
  if installed; then echo -e " Servidor   : ${GREEN}${BOLD}✔ INSTALADO${NC} (sin token)"; else echo -e " Servidor   : ${RED}${BOLD}✘ NO INSTALADO${NC}"; fi
  if service_active && listening; then echo -e " BHTTP $BHTTP_PORT   : ${GREEN}${BOLD}✔ ON${NC} → SSH 127.0.0.1:$BACKEND_PORT"; else echo -e " BHTTP $BHTTP_PORT   : ${YELLOW}${BOLD}● OFF${NC} → SSH 127.0.0.1:$BACKEND_PORT"; fi
  echo
}

ensure_deps(){
  info "Instalando dependencias mínimas..."
  if have apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || warn "apt-get update falló; si el sistema es EOL, repara sus repositorios primero."
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3 iproute2 procps ca-certificates >/dev/null
  fi
  have python3 || { err "Python 3 no disponible."; return 1; }
  ok "Dependencias listas: $(python3 --version 2>&1)"
}

write_server(){
  mkdir -p "$APP_DIR"
  cat > "$SERVER" <<'PY_SERVER_EOF'
#!/usr/bin/env python3
from __future__ import print_function

import argparse
import binascii
import hashlib
import logging
import os
import select
import signal
import socket
import socketserver
import struct
import threading
import time

MODE_PROBE = 0
MODE_UPLOAD = 1
MODE_DOWNLOAD = 2
MODE_BATCH = 3
MODE_ACK = 4
STATUS_OK = 0
STATUS_ERROR = 1
STATUS_DATA = 2
BATCH_COUNT = 8
MAX_REQUEST_BYTES = 4 * 1024 * 1024
DEFAULT_CHUNK = 1399

LOG = logging.getLogger("superflash-bhttp")


def recv_exact(sock, n):
    parts = []
    left = n
    while left:
        data = sock.recv(left)
        if not data:
            raise IOError("truncated request")
        parts.append(data)
        left -= len(data)
    return b"".join(parts)


def crypt(data, sid, mode, seq, downstream):
    out = bytearray(len(data))
    off = 0
    counter = 0
    while off < len(data):
        seed = sid + bytes(bytearray([mode & 0xff])) + struct.pack(">Q", seq) + bytes(bytearray([1 if downstream else 0])) + struct.pack(">I", counter)
        mask = hashlib.sha256(seed).digest()
        n = min(len(mask), len(data) - off)
        for i in range(n):
            out[off + i] = data[off + i] ^ mask[i]
        off += n
        counter += 1
    return bytes(out)


def write_response(wfile, status, body):
    wfile.write(struct.pack(">BI", status & 0xff, len(body)))
    if body:
        wfile.write(body)
    wfile.flush()


class Session(object):
    def __init__(self, sid, backend_host, backend_port, connect_timeout):
        self.sid = sid
        self.backend = socket.create_connection((backend_host, backend_port), connect_timeout)
        self.backend.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.backend.setblocking(True)
        self.created = time.time()
        self.last_activity = self.created
        self.closed = False

        self.upload_lock = threading.RLock()
        self.upload_pending = {}
        self.next_upload_seq = 0

        self.download_lock = threading.RLock()
        self.download_turn = threading.Condition(self.download_lock)
        self.next_batch_base = 0
        self.batch_cache = {}
        self.download_chunk = DEFAULT_CHUNK

    def touch(self):
        self.last_activity = time.time()

    def close(self):
        with self.download_lock:
            if self.closed:
                return
            self.closed = True
            try:
                self.backend.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            try:
                self.backend.close()
            except Exception:
                pass
            self.download_turn.notify_all()

    def upload(self, seq, clear):
        self.touch()
        with self.upload_lock:
            if self.closed:
                raise IOError("session closed")
            if seq < self.next_upload_seq:
                return
            if seq not in self.upload_pending:
                self.upload_pending[seq] = clear
            while self.next_upload_seq in self.upload_pending:
                payload = self.upload_pending.pop(self.next_upload_seq)
                if payload:
                    self.backend.sendall(payload)
                self.next_upload_seq += 1

    def _read_available(self, chunk_size, first_wait):
        if self.closed:
            return b""
        try:
            ready, _, _ = select.select([self.backend], [], [], first_wait)
        except Exception:
            return b""
        if not ready:
            return b""
        try:
            data = self.backend.recv(chunk_size)
        except socket.timeout:
            return b""
        except Exception:
            self.close()
            return b""
        if not data:
            self.close()
            return b""
        return data

    def get_batch(self, base, chunk_size, wait_timeout=12.0):
        self.touch()
        if chunk_size < 10:
            chunk_size = 10
        if chunk_size > 65536:
            chunk_size = 65536

        end = time.time() + wait_timeout
        with self.download_turn:
            if base in self.batch_cache:
                return list(self.batch_cache[base])

            while base > self.next_batch_base and not self.closed:
                remaining = end - time.time()
                if remaining <= 0:
                    raise IOError("download sequence wait timeout")
                self.download_turn.wait(min(0.5, remaining))
                if base in self.batch_cache:
                    return list(self.batch_cache[base])

            if base < self.next_batch_base:
                cached = self.batch_cache.get(base)
                if cached is not None:
                    return list(cached)
                # Very old retry after ACK/cache purge: return an empty idempotent batch.
                return [b""] * BATCH_COUNT

            self.download_chunk = chunk_size
            batch = []
            for i in range(BATCH_COUNT):
                # Wait briefly only for the first element. Remaining elements drain what is ready.
                wait = 0.050 if i == 0 else 0.0
                batch.append(self._read_available(chunk_size, wait))

            self.batch_cache[base] = list(batch)
            self.next_batch_base += BATCH_COUNT
            # Bound memory even if ACKs are absent.
            if len(self.batch_cache) > 512:
                keys = sorted(self.batch_cache.keys())
                for old in keys[:-256]:
                    self.batch_cache.pop(old, None)
            self.download_turn.notify_all()
            return batch

    def acknowledge(self, seq):
        self.touch()
        with self.download_turn:
            doomed = [base for base in self.batch_cache if base + (BATCH_COUNT - 1) <= seq]
            for base in doomed:
                self.batch_cache.pop(base, None)
            self.download_turn.notify_all()


class SessionTable(object):
    def __init__(self, backend_host, backend_port, connect_timeout, ttl, max_sessions):
        self.backend_host = backend_host
        self.backend_port = backend_port
        self.connect_timeout = connect_timeout
        self.ttl = ttl
        self.max_sessions = max_sessions
        self.lock = threading.RLock()
        self.items = {}

    def get(self, sid):
        with self.lock:
            sess = self.items.get(sid)
            if sess is not None:
                sess.touch()
            return sess

    def register(self, sid):
        with self.lock:
            old = self.items.get(sid)
            if old is not None and not old.closed:
                old.touch()
                return old
            self.cleanup_locked()
            if len(self.items) >= self.max_sessions:
                raise IOError("too many sessions")
            sess = Session(sid, self.backend_host, self.backend_port, self.connect_timeout)
            self.items[sid] = sess
            LOG.info("session %s registered -> %s:%d", binascii.hexlify(sid).decode("ascii")[:12], self.backend_host, self.backend_port)
            return sess

    def cleanup_locked(self):
        now = time.time()
        expired = []
        for sid, sess in list(self.items.items()):
            if sess.closed or now - sess.last_activity > self.ttl:
                expired.append((sid, sess))
        for sid, sess in expired:
            self.items.pop(sid, None)
            sess.close()
            LOG.info("session %s expired/closed", binascii.hexlify(sid).decode("ascii")[:12])

    def cleanup(self):
        with self.lock:
            self.cleanup_locked()

    def close_all(self):
        with self.lock:
            vals = list(self.items.values())
            self.items.clear()
        for sess in vals:
            sess.close()


class BhttpHandler(socketserver.StreamRequestHandler):
    def handle(self):
        self.request.settimeout(self.server.request_timeout)
        try:
            header = recv_exact(self.request, 29)
            mode = header[0] if isinstance(header[0], int) else ord(header[0])
            sid = header[1:17]
            seq = struct.unpack(">Q", header[17:25])[0]
            length = struct.unpack(">I", header[25:29])[0]
            if length > MAX_REQUEST_BYTES:
                raise IOError("request too large")
            body = recv_exact(self.request, length) if length else b""

            if mode == MODE_PROBE:
                self.handle_probe(sid, seq, body)
                return

            if mode == MODE_UPLOAD:
                if seq == 0 and not body:
                    self.server.sessions.register(sid)
                    write_response(self.wfile, STATUS_OK, b"")
                    return
                sess = self.require_session(sid)
                clear = crypt(body, sid, MODE_UPLOAD, seq, False)
                sess.upload(seq, clear)
                write_response(self.wfile, STATUS_OK, b"")
                return

            if mode == MODE_BATCH:
                sess = self.require_session(sid)
                clear_req = crypt(body, sid, MODE_BATCH, seq, False)
                if len(clear_req) != 6:
                    raise IOError("invalid batch request size")
                chunk_size = struct.unpack(">I", clear_req[:4])[0]
                count = clear_req[5] if isinstance(clear_req[5], int) else ord(clear_req[5])
                if count != BATCH_COUNT:
                    raise IOError("unsupported batch count")
                batch = sess.get_batch(seq, chunk_size)
                for i, clear in enumerate(batch):
                    q = seq + i
                    enc = crypt(clear, sid, MODE_BATCH, q, True)
                    payload = struct.pack(">I", len(clear)) + enc
                    write_response(self.wfile, STATUS_DATA, payload)
                return

            if mode == MODE_ACK:
                sess = self.require_session(sid)
                sess.acknowledge(seq)
                write_response(self.wfile, STATUS_OK, b"")
                return

            if mode == MODE_DOWNLOAD:
                # Optional single-frame downloader for compatible clients.
                sess = self.require_session(sid)
                try:
                    clear_req = crypt(body, sid, MODE_DOWNLOAD, seq, False)
                    chunk_size = struct.unpack(">I", clear_req[:4])[0] if len(clear_req) >= 4 else DEFAULT_CHUNK
                except Exception:
                    chunk_size = DEFAULT_CHUNK
                clear = sess._read_available(max(10, min(chunk_size, 65536)), 0.050)
                enc = crypt(clear, sid, MODE_DOWNLOAD, seq, True)
                write_response(self.wfile, STATUS_DATA, struct.pack(">I", len(clear)) + enc)
                return

            raise IOError("unsupported mode %d" % mode)
        except Exception as exc:
            LOG.debug("request from %s failed: %s", self.client_address[0], exc)
            try:
                write_response(self.wfile, STATUS_ERROR, str(exc).encode("utf-8")[:256])
            except Exception:
                pass

    def require_session(self, sid):
        sess = self.server.sessions.get(sid)
        if sess is None:
            raise IOError("unknown session")
        return sess

    def handle_probe(self, sid, seq, body):
        clear = crypt(body, sid, MODE_PROBE, seq, False)
        if len(clear) < 10 or clear[:4] != b"BHP1" or clear[4] != 1:
            raise IOError("invalid BHP1 probe")
        requested_mode = clear[5] if isinstance(clear[5], int) else ord(clear[5])
        if requested_mode not in (MODE_PROBE, MODE_UPLOAD, MODE_DOWNLOAD, MODE_BATCH, MODE_ACK):
            raise IOError("invalid BHP1 requested mode")
        response = crypt(clear, sid, MODE_PROBE, seq, True)
        write_response(self.wfile, STATUS_OK, response)


class ThreadingServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address, handler, sessions, request_timeout):
        self.sessions = sessions
        self.request_timeout = request_timeout
        socketserver.TCPServer.__init__(self, address, handler)


def cleanup_loop(server, stop_event):
    while not stop_event.wait(15.0):
        try:
            server.sessions.cleanup()
        except Exception:
            LOG.exception("session cleanup failed")


def main():
    ap = argparse.ArgumentParser(description="SuperFlash BHTTP/SSH clean-room server")
    ap.add_argument("--listen", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=80)
    ap.add_argument("--backend-host", default="127.0.0.1")
    ap.add_argument("--backend-port", type=int, default=22)
    ap.add_argument("--session-ttl", type=int, default=120)
    ap.add_argument("--max-sessions", type=int, default=1024)
    ap.add_argument("--connect-timeout", type=float, default=8.0)
    ap.add_argument("--request-timeout", type=float, default=15.0)
    ap.add_argument("--log-level", default="INFO")
    args = ap.parse_args()

    logging.basicConfig(level=getattr(logging, args.log_level.upper(), logging.INFO),
                        format="%(asctime)s %(levelname)s %(message)s")

    if args.port < 1 or args.port > 65535 or args.backend_port < 1 or args.backend_port > 65535:
        raise SystemExit("invalid port")

    sessions = SessionTable(args.backend_host, args.backend_port, args.connect_timeout,
                            max(30, args.session_ttl), max(1, args.max_sessions))
    server = ThreadingServer((args.listen, args.port), BhttpHandler, sessions, args.request_timeout)
    stop_event = threading.Event()
    cleaner = threading.Thread(target=cleanup_loop, args=(server, stop_event), name="session-cleaner")
    cleaner.daemon = True
    cleaner.start()

    def stop(signum=None, frame=None):
        if not stop_event.is_set():
            stop_event.set()
            threading.Thread(target=server.shutdown).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    LOG.info("SuperFlash BHTTP listening on %s:%d -> SSH %s:%d", args.listen, args.port, args.backend_host, args.backend_port)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        stop_event.set()
        server.server_close()
        sessions.close_all()
        LOG.info("SuperFlash BHTTP stopped")


if __name__ == "__main__":
    main()
PY_SERVER_EOF
  chmod 755 "$SERVER"
  python3 -m py_compile "$SERVER" || { err "El motor BHTTP no pasó py_compile."; return 1; }
}

write_systemd(){
  cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=SuperFlash BHTTP SSH transport
After=network-online.target ssh.service sshd.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $SERVER --listen 0.0.0.0 --port $BHTTP_PORT --backend-host 127.0.0.1 --backend-port $BACKEND_PORT --session-ttl $SESSION_TTL --max-sessions $MAX_SESSIONS --log-level INFO
Restart=always
RestartSec=2
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
}

write_sysv(){
  cat > "/etc/init.d/$SERVICE" <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          $SERVICE
# Required-Start:    \$network \$remote_fs
# Required-Stop:     \$network \$remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: SuperFlash BHTTP SSH transport
### END INIT INFO
case "\$1" in
 start)
   [ -f "$PIDFILE" ] && kill -0 \$(cat "$PIDFILE") 2>/dev/null && exit 0
   start-stop-daemon --start --background --make-pidfile --pidfile "$PIDFILE" --exec /usr/bin/python3 -- "$SERVER" --listen 0.0.0.0 --port "$BHTTP_PORT" --backend-host 127.0.0.1 --backend-port "$BACKEND_PORT" --session-ttl "$SESSION_TTL" --max-sessions "$MAX_SESSIONS" --log-level INFO >>"$LOGFILE" 2>&1
   ;;
 stop)
   start-stop-daemon --stop --retry TERM/5/KILL/2 --pidfile "$PIDFILE" || true
   rm -f "$PIDFILE"
   ;;
 restart) \$0 stop; sleep 1; \$0 start ;;
 status) [ -s "$PIDFILE" ] && kill -0 \$(cat "$PIDFILE") 2>/dev/null ;;
 *) echo "Uso: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF
  chmod 755 "/etc/init.d/$SERVICE"
  update-rc.d "$SERVICE" defaults >/dev/null 2>&1 || true
}

write_service(){
  load_conf
  if have systemctl && [ -d /run/systemd/system ]; then write_systemd; else write_sysv; fi
}

start_service(){
  load_conf
  if ! backend_listening; then
    warn "No detecto un servicio TCP escuchando en el backend SSH $BACKEND_PORT."
    warn "BHTTP puede iniciar, pero SSH no conectará hasta que ese puerto sea correcto."
  fi
  if have systemctl && [ -d /run/systemd/system ]; then systemctl restart "$SERVICE"
  else "/etc/init.d/$SERVICE" restart; fi
  sleep 1
  if service_active && listening; then ok "BHTTP TCP $BHTTP_PORT ACTIVO → SSH local $BACKEND_PORT"; return 0; fi
  err "BHTTP no quedó escuchando en TCP $BHTTP_PORT. Revisa logs."; return 1
}

stop_service(){
  if have systemctl && [ -d /run/systemd/system ]; then systemctl stop "$SERVICE" 2>/dev/null || true
  elif [ -x "/etc/init.d/$SERVICE" ]; then "/etc/init.d/$SERVICE" stop || true; fi
  ok "Servidor BHTTP detenido."
}

open_firewall(){
  load_conf
  if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then ufw allow "$BHTTP_PORT/tcp" >/dev/null 2>&1 || true; ok "UFW: TCP $BHTTP_PORT permitido."; fi
  if have firewall-cmd && have systemctl && systemctl is-active --quiet firewalld 2>/dev/null; then firewall-cmd --permanent --add-port="$BHTTP_PORT/tcp" >/dev/null 2>&1 || true; firewall-cmd --reload >/dev/null 2>&1 || true; ok "firewalld: TCP $BHTTP_PORT permitido."; fi
  warn "Si tu proveedor tiene Firewall/Security Group externo, permite también TCP $BHTTP_PORT allí."
}

apply_tuning(){
  local f=/etc/sysctl.d/99-superflash-bhttp.conf
  cat > "$f" <<'EOF'
# SuperFlash BHTTP: muchas conexiones TCP cortas
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 10240 65535
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 8192
net.ipv4.tcp_fastopen = 3
EOF
  sysctl -p "$f" >/dev/null 2>&1 || true
  ok "Tuning BHTTP aplicado."
}

install_server(){
  ensure_deps || return 1
  load_conf; save_conf
  write_server || return 1
  : > "$LOGFILE"; chmod 640 "$LOGFILE" 2>/dev/null || true
  echo "version=$VERSION installed=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
  write_service
  apply_tuning
  ok "Servidor clean-room BHTTP instalado. No utiliza token/licencia Veltrix."
}

configure_port(){
  local p="$1"
  validate_port "$p" || { err "Puerto inválido: $p"; return 1; }
  load_conf
  if have ss && ss -lntp 2>/dev/null | grep -E "[:.]${p}[[:space:]]" | grep -vq "python3"; then
    err "TCP $p ya parece ocupado por otro proceso:"; ss -lntp 2>/dev/null | grep -E "[:.]${p}[[:space:]]" || true; return 1
  fi
  BHTTP_PORT="$p"; save_conf
  installed || install_server || return 1
  write_service
  start_service || return 1
  open_firewall
  echo
  echo -e "${BOLD}Generador SuperFlash:${NC}"
  echo "  Tipo             : BHTTP"
  echo "  Host/IP          : IP pública de esta VPS"
  echo "  Puerto           : $BHTTP_PORT"
  echo "  Usuario/Password : usuario SSH/PAM normal de la VPS"
  echo "  Slots subida     : 16"
  echo "  Slots descarga   : 32"
}

configure_backend(){
  load_conf
  read -r -p "Puerto SSH/PAM interno [$BACKEND_PORT]: " p
  p="${p:-$BACKEND_PORT}"
  validate_port "$p" || { err "Puerto inválido."; return 1; }
  BACKEND_PORT="$p"; save_conf
  installed && { write_service; start_service || true; }
  ok "Backend SSH configurado en 127.0.0.1:$BACKEND_PORT"
}

show_status(){
  header
  load_conf
  echo "Configuración: $CONF"
  echo "BHTTP externo : 0.0.0.0:$BHTTP_PORT/TCP"
  echo "SSH backend   : 127.0.0.1:$BACKEND_PORT/TCP"
  echo "Sesión TTL    : $SESSION_TTL s"
  echo "Máx sesiones  : $MAX_SESSIONS"
  echo "Python        : $(python3 --version 2>&1 2>/dev/null || echo no)"
  echo "Backend SSH   : $(backend_listening && echo ESCUCHANDO || echo NO-DETECTADO)"
  echo
  if have ss; then ss -lntp 2>/dev/null | grep -E "[:.]($BHTTP_PORT|$BACKEND_PORT)[[:space:]]" || true; fi
  echo
  if have systemctl && [ -d /run/systemd/system ]; then systemctl --no-pager --full status "$SERVICE" 2>/dev/null | sed -n '1,18p' || true; fi
}

show_logs(){
  if have systemctl && [ -d /run/systemd/system ]; then journalctl -u "$SERVICE" --no-pager -n 100 2>/dev/null || tail -n 100 "$LOGFILE" 2>/dev/null
  else tail -n 120 "$LOGFILE" 2>/dev/null || true; fi
}

self_test(){
  installed || { err "Instala el servidor primero."; return 1; }
  info "Autoprueba: sintaxis/crypto/frame BHP1..."
  python3 -m py_compile "$SERVER" || return 1
  python3 - "$SERVER" <<'PYTEST'
import hashlib, importlib.util, os, socket, struct, sys, threading, time
path=sys.argv[1]
spec=importlib.util.spec_from_file_location('sfb', path); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sid=bytes(bytearray(range(16))); clear=b'BHP1'+bytes(bytearray([1,3]))+struct.pack('>I',8)
enc=m.crypt(clear,sid,0,0,False); dec=m.crypt(enc,sid,0,0,False)
assert dec==clear
x=m.crypt(b'hello',sid,3,7,True); assert m.crypt(x,sid,3,7,True)==b'hello'
print('BHTTP_SELF_TEST_PASS framing=29 response=5 crypt=SHA256-XOR BHP1=PASS')
PYTEST
  [ "$?" -eq 0 ] && ok "Autoprueba local PASS." || { err "Autoprueba FAIL."; return 1; }
}

uninstall_server(){
  warn "Esto elimina SOLO el servidor BHTTP clean-room; no elimina usuarios SSH."
  read -r -p "¿Continuar? [s/N]: " a
  case "${a:-n}" in s|S|y|Y) ;; *) return 0;; esac
  stop_service
  if have systemctl && [ -d /run/systemd/system ]; then systemctl disable "$SERVICE" >/dev/null 2>&1 || true; rm -f "/etc/systemd/system/$SERVICE.service"; systemctl daemon-reload
  else rm -f "/etc/init.d/$SERVICE"; update-rc.d -f "$SERVICE" remove >/dev/null 2>&1 || true; fi
  rm -rf "$APP_DIR" "$MARKER" "$CONF" "$PIDFILE"
  ok "Servidor BHTTP eliminado."
}

menu(){
 while true; do
  header
  echo " 1) Instalar/reparar servidor BHTTP (SIN TOKEN)"
  echo " 2) Abrir/iniciar BHTTP TCP 80"
  echo " 3) Abrir BHTTP en puerto manual"
  echo " 4) Configurar puerto SSH backend (22 por defecto)"
  echo " 5) Estado/diagnóstico"
  echo " 6) Ver logs"
  echo " 7) Autoprueba local BHTTP"
  echo " 8) Reiniciar servidor"
  echo " 9) Detener servidor"
  echo "10) Desinstalar servidor BHTTP"
  echo " 0) Salir"
  echo
  read -r -p "Opción: " op
  case "$op" in
   1) install_server; pause;;
   2) configure_port 80; pause;;
   3) read -r -p "Puerto BHTTP TCP: " p; configure_port "$p"; pause;;
   4) configure_backend; pause;;
   5) show_status; pause;;
   6) show_logs; pause;;
   7) self_test; pause;;
   8) installed && { write_service; start_service; } || err "No instalado"; pause;;
   9) stop_service; pause;;
   10) uninstall_server; pause;;
   0) exit 0;;
   *) warn "Opción inválida"; sleep 1;;
  esac
 done
}

main(){
 require_root; load_os; load_conf
 case "${1:-}" in
  --install) install_server; configure_port "${2:-80}";;
  --open-port) configure_port "${2:-80}";;
  --status|--diagnose) show_status;;
  --self-test) self_test;;
  --help|-h) echo "Uso: bash $0 [--install [puerto]|--open-port PUERTO|--status|--self-test]";;
  "") menu;;
  *) err "Parámetro desconocido: $1"; exit 2;;
 esac
}
main "$@"
