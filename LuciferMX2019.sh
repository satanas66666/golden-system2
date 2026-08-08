#!/usr/bin/env bash
# GOLDEN ADM PRO - LuciferMX2019 REV14 / binarios + payload vacío legítimo / progreso visible
cd $HOME

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
    local url="$1" dest="$2" current="$3" total="$4" label="$5" route="$6"
    local pid rc elapsed=0 frame=0
    local -a spin=('|' '/' '-' '\\')

    safe_wget "$url" "$dest" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
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
    local label="$1" command="$2" pid rc elapsed=0 frame=0
    local -a spin=('|' '/' '-' '\\')
    if command -v timeout >/dev/null 2>&1; then
        timeout 900 bash -c "$command" >/dev/null 2>&1 &
    else
        bash -c "$command" >/dev/null 2>&1 &
    fi
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r\033[K\033[1;33m[%s]\033[0m %s - %ss' "${spin[frame%4]}" "$label" "$elapsed"
        frame=$((frame + 1))
        sleep 1
        elapsed=$((elapsed + 1))
    done
    wait "$pid"; rc=$?
    if (( rc == 0 )); then
        printf '\r\033[K\033[1;32m[OK]\033[0m %s (%ss)\n' "$label" "$elapsed"
    else
        printf '\r\033[K\033[1;33m[AVISO]\033[0m %s no se completó; continuando.\n' "$label"
    fi
    return "$rc"
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

    # Servidores REV11/REV12: descarga directa por 8888 es la ruta principal.
    if [[ "${SERVER_REV:-}" == "REV11" || "${SERVER_REV:-}" == "REV12" ]]; then
        rm -f -- "$dest"
        if payload_fetch "$direct" "$dest" "$((current-1))" "$total" "$name" '8888' "$allow_empty"; then
            if ! server_error_file "$dest"; then
                progress_line "$current" "$total" "$name" 'OK 8888'
                printf '\n'
                return 0
            fi
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
comando="$1"
(
[[ -e $HOME/fim ]] && rm $HOME/fim
if command -v timeout >/dev/null 2>&1; then timeout 900 bash -c "$comando" > /dev/null 2>&1; else bash -c "$comando" > /dev/null 2>&1; fi
touch $HOME/fim
) &

echo -ne "\033[1;33m ["

while true; do
   for((i=0; i<18; i++)); do
   echo -ne "\033[1;31m##"
   sleep 0.1
   done

   [[ -e $HOME/fim ]] && rm $HOME/fim && break

   echo -e "\033[1;33m]"
   sleep 1
   tput cuu1 2>/dev/null
   tput dl1 2>/dev/null
   echo -ne "\033[1;33m ["
done

echo -e "\033[1;33m]\033[1;31m -\033[1;32m 100%\033[1;37m"
}

[[ $(dpkg -l | grep -w gawk) ]] || apt-get install gawk -y &>/dev/null
command -v locate >/dev/null 2>&1 || apt-get install plocate -y &>/dev/null || apt-get install mlocate -y &>/dev/null || true


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

# REV7: el bootstrap ya instaló las dependencias esenciales. Aquí solo se
# verifican/reparan extras sin repetir una docena de apt-get innecesarios.
run_cmd_activity "Reparando dependencias" "apt-get --fix-broken install -y" || true
command -v ufw >/dev/null 2>&1 && run_cmd_activity "Configurando firewall local" "ufw disable" || true
command -v php >/dev/null 2>&1 || run_cmd_activity "Instalando PHP" "apt-get install -y php" || true
command -v node >/dev/null 2>&1 || run_cmd_activity "Instalando NodeJS" "apt-get install -y nodejs" || true

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

[[ $(dpkg -l | grep -w nano) ]] || apt-get install nano -y &>/dev/null
[[ $(dpkg -l | grep -w bc) ]] || apt-get install bc -y &>/dev/null
[[ $(dpkg -l | grep -w screen) ]] || apt-get install screen -y &>/dev/null
[[ $(dpkg -l | grep -w python3) ]] || apt-get install python3 -y &>/dev/null

apt-get install python3-pip -y &>/dev/null

[[ $(dpkg -l | grep -w curl) ]] || apt-get install curl -y &>/dev/null
[[ $(dpkg -l | grep -w ufw) ]] || apt-get install ufw -y &>/dev/null
[[ $(dpkg -l | grep -w unzip) ]] || apt-get install unzip -y &>/dev/null
[[ $(dpkg -l | grep -w zip) ]] || apt-get install zip -y &>/dev/null
[[ $(dpkg -l | grep -w lsof) ]] || apt-get install lsof -y &>/dev/null

apt-get install apache2 -y &>/dev/null

sed -i "s;Listen 80;Listen 81;g" /etc/apache2/ports.conf > /dev/null 2>&1

systemctl restart apache2 2>/dev/null || service apache2 restart > /dev/null 2>&1

[[ $(dpkg -l | grep -w apache2) ]]
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
"openssh.sh"|"squid.sh"|"dropbear.sh"|"openvpn.sh"|"ssl.sh"|"shadowsocksLive.sh"|"shadown.sh"|"budp.sh"|"shadowsock.sh"|"ssrrmu.sh"|"shadowsocks.sh"|"v2ray.sh"|"sockspy.sh"|"PDirect.py"|"PPub.py"|"PPriv.py"|"POpen.py"|"PGet.py") ARQ="${SCPinst}/";;
*)ARQ="${SCPfrm}/";;
esac

mv -f ${SCPinstal}/$1 ${ARQ}/$1

chmod +x ${ARQ}/$1
}

fun_ip

safe_wget "https://www.dropbox.com/s/dzknghcgew54pc6/trans" /usr/bin/trans || true

safe_wget "https://raw.githubusercontent.com/satanas66666/golden-system/main/limv2ray" /usr/bin/limv2ray || true

[[ -s /usr/bin/limv2ray ]] && chmod +x /usr/bin/limv2ray

safe_wget "https://raw.githubusercontent.com/satanas66666/golden-system/refs/heads/main/Desbloqueo.sh" /bin/Desbloqueo.sh || true

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
if [[ "$SERVER_REV" != "REV11" && "$SERVER_REV" != "REV12" ]]; then
    msg -ama "Servidor legacy detectado (${SERVER_REV:-sin-version}). Se priorizará TCP 81 con reintentos y refresco automático."
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

for arqx in $(cat "$HOME/lista-arq"); do

CURRENT_ARQ=$((CURRENT_ARQ + 1))
DEST="${SCPinstal}/${arqx}"

# REV7: barra de progreso real por archivos + actividad visible durante cada red.
# La KEY ya fue validada antes de entrar aquí, por lo que un fallo en este punto
# se reporta como problema de entrega y nunca como "key inválida".
if download_payload_file "${arqx}" "$DEST" "$CURRENT_ARQ" "$TOTAL_ARQ"; then
    verificar_arq "${arqx}"
else
    msg -verm "No se pudo descargar: ${arqx}"
    msg -ama "La KEY es válida. El servidor de archivos no respondió por 8888 ni por 81."
    download_error_fun
fi

pontos+="."

done

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

inst_components

echo "$Key" > ${SCPdir}/key.txt

[[ -d ${SCPinstal} ]] && rm -rf ${SCPinstal}

[[ ${#id} -gt 2 ]] && echo "pt" > ${SCPidioma} || echo "${id}" > ${SCPidioma}

[[ ${byinst} = "true" ]] && install_fim

else

invalid_key

fi

