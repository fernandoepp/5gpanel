#!/usr/bin/env bash
# ============================================================================
# core5g.sh - instalador de la red 5G del laboratorio. Primero pregunta el ROL de este PC:
#   1) Core   núcleo 5G (Open5GS / docker_open5gs) y, si quieres, agente y panel web
#   2) Radio  gNodeB ocudu (scripts/install_radio.sh) y, si quieres, su agente del panel
#   3) UPF    UPF separado del core (scripts/install_upf.sh) y, si quieres, su agente
#   4) Desinstalar (agente, panel, radio, UPF)
#
# Uso:
#   sudo ./core5g.sh
#   (o, sin descargar nada antes:  curl -fsSL https://raw.githubusercontent.com/fernandoepp/5gpanel/main/core5g.sh -o core5g.sh)
#
# Radio y UPF: el código de panel5g se descarga de GitHub (CORE5G_PANELL_REPO / _BRANCA).
# Con agente hace falta el código de emparejamiento (en el core: sudo emparella-radio <nombre>
# o sudo emparella-upf <nombre>); sin agente, solo la IP del core.
#
# Menú del core:
#   1) Configurar la IP, la interfaz y la puerta de enlace
#   2) Seleccionar la versión:
#        prueba    proyectos de prueba del Drive, con abonados: normal, VoIP o roaming
#        genérica  repositorio oficial herlesupreeth/docker_open5gs: normal o VoIP,
#                  con los extras "sin UPF" (UPF remoto) y "panel5g" (agente + panel web)
#   3) Instalar
#   4) Información de los programas que se instalan
#   5) Desinstalar: agente del core, panel web, agente de la radio o UPF (los que elijas)
#   6) Cancelar
#
# Instalar solo instala lo que falta: si el agente o el panel ya están, no se tocan
# (para poner la versión nueva: 5) Desinstalar y después 3) Instalar; o --forzar).
#
# Opciones avanzadas (no hace falta usarlas):
#   --local RUTA   no descargar del Drive: usar una carpeta (USB, NFS...),
#                  un .zip/.tar local o una URL http(s) de un servidor del aula.
#                  Si la carpeta tiene una subcarpeta con el nombre de la versión
#                  ("normal", "normal+ip", "roaming"), se usa esa.
#                  En la URL, {versio} se sustituye por el nombre de la versión.
#                  Recomendado para una clase entera: el Drive limita las
#                  descargas simultáneas.
#   --forzar       volver a descargar, reconstruir y restaurar los datos
#   --panell RUTA  código de panel5g (carpeta o .tar.gz) en lugar de GitHub
#   --sin-panel    no instalar panel5g aunque esté elegido en el menú
#   --continuar    uso interno: continúa la instalación después del reinicio
#
# Variables de entorno (opcionales, p. ej. sudo CORE5G_DOCKER_VERSIO=27.5.1 ./core5g.sh):
#   CORE5G_DOCKER_VERSIO  versión de Docker que se instala (vacío = la última)
#   CORE5G_MYSQL_PASS     contraseña root de MySQL (vacío = MYSQL_ROOT_PASSWORD
#                         del .env del proyecto o, si no está, "ims")
#   CORE5G_INTENTS        intentos de descarga del Drive (por defecto 4)
#   CORE5G_INTENTS_BUILD  intentos de construcción de cada imagen Docker (por defecto 3)
#   CORE5G_PANELL_REPO    repositorio git del agente y el panel (por defecto PANELL_REPO)
#   CORE5G_PANELL_BRANCA  rama del repositorio (por defecto main)
#   CORE5G_CERTS          CA y certificados del agente (por defecto /root/certs-5g)
#   CORE5G_RADIOS         nombres de las radios a emparejar al terminar (p. ej. "radio1 aula2"; "-" = ninguna)
#
# Todo se instala en ~/core5g/<versión>/docker_open5gs del usuario que ejecuta
# sudo. Volver a ejecutarlo sobre una instalación existente no descarga nada
# ni borra abonados: vuelve a aplicar la red, el .env, el roaming y el "sin UPF",
# y reinicia.
# ============================================================================
set -euo pipefail

# --- configuración por defecto ------------------------------------------------
DRIVE_URL="https://drive.google.com/drive/folders/15v6FBhmeoR42UWarafswyiIj_dVY5Ri7"
REPO_GENERIC="https://github.com/herlesupreeth/docker_open5gs"
MYSQL_PASS="${CORE5G_MYSQL_PASS:-}"              # vacío = la del .env o "ims"
MYSQL_PASS_DEFECTE="ims"                          # la del contenedor mysql de los proyectos del Drive
DOCKER_VERSIO="${CORE5G_DOCKER_VERSIO:-}"         # vacío = la última de get.docker.com
INTENTS="${CORE5G_INTENTS:-4}"                    # intentos de descarga del Drive
INTENTS_BUILD="${CORE5G_INTENTS_BUILD:-3}"        # intentos de construcción de cada imagen
SWAP_FILE="${SWAP_FILE:-/swapfile}"
SWAP_SIZE="4G"
FSTAB="${FSTAB:-/etc/fstab}"
NETPLAN_DIR="${NETPLAN_DIR:-/etc/netplan}"
NETPLAN_FITXER="$NETPLAN_DIR/90-core5g.yaml"      # el único fichero de netplan que toca el script
DNS="8.8.8.8, 8.8.4.4"
TIMEOUT=180
# Agente del panel en el core (mTLS, puerto 9543). Código en GitHub; se puede dar una carpeta con --panell.
PANELL_REPO="${CORE5G_PANELL_REPO:-https://github.com/fernandoepp/5gpanel}"
PANELL_BRANCA="${CORE5G_PANELL_BRANCA:-main}"
PANELL_CERTS="${CORE5G_CERTS:-/root/certs-5g}"

CONF="${CORE5G_CONF:-/etc/core5g.conf}"                    # configuración guardada
SCRIPT_FIX="${CORE5G_SCRIPT_FIX:-/usr/local/sbin/core5g.sh}" # copia para el reinicio
SERVEI="core5g-continuar.service"
SERVEI_FITXER="${CORE5G_SYSTEMD_DIR:-/etc/systemd/system}/$SERVEI"
REGISTRE="${CORE5G_LOG:-/var/log/core5g.log}"
ESTAT_DIR="${CORE5G_ESTAT_DIR:-/var/lib/core5g}"
AVIS="${CORE5G_PROFILE_D:-/etc/profile.d}/core5g-avis.sh"

# Partes del proyecto genérico ajenas al núcleo (radio y UE simulados)
GENERIC_ESBORRAR_DIRS=(ueransim srslte srsran oai swu_client sim)
GENERIC_ESBORRAR_YAML=(nr-gnb.yaml nr-ue.yaml oaienb.yaml oaignb.yaml srsenb.yaml srsenb_zmq.yaml
                       srsgnb.yaml srsgnb_zmq.yaml srsue_5g_zmq.yaml srsue_zmq.yaml swu_client.yaml
                       deploy-all.yaml)
GENERIC_ENV_CAPCALERES='^# (SRSLTE ENB|UERANSIM|OAI ENB|SRSLTE UE|SRSRAN GNB|SWU CLIENT|PORTAINER)[[:space:]]*$'
GENERIC_ENV_VARS='^(SRS_ENB_IP|NR_GNB_IP|NR_UE_IP|UE1_[A-Z]+|OAI_ENB_IP|SRS_UE_IP|SRS_GNB_IP|SWU_CLIENT_IP|PORTAINER_IP)='

# --- utilidades ---------------------------------------------------------------
pas()   { echo; echo "==> [$1] $2"; }
info()  { echo "    $*"; }
avis()  { echo "    AVISO: $*"; }
error() { echo "ERROR: $*" >&2; exit 1; }

esperar() {   # esperar <nombre> <orden...>
    local nom="$1"; shift
    local t=0
    printf "    esperando %s " "$nom"
    until "$@" >/dev/null 2>&1; do
        (( t >= TIMEOUT )) && { echo; error "$nom no responde después de ${TIMEOUT}s"; }
        printf "."; sleep 3; t=$((t + 3))
    done
    echo " listo (${t}s)"
}

compose() { docker compose --project-directory "$PROJECTE" -f "$PROJECTE/$COMPOSE_FILE" "$@"; }

es_ipv4() { [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] \
            && (( BASH_REMATCH[1] <= 255 && BASH_REMATCH[2] <= 255 && BASH_REMATCH[3] <= 255 && BASH_REMATCH[4] <= 255 )); }
es_plmn() { [[ "$1" =~ ^[0-9]{5,6}$ ]]; }
ip2int()  { local IFS=.; read -r a b c d <<<"$1"; echo $(( (a<<24) | (b<<16) | (c<<8) | d )); }
int2ip()  { echo "$(( ($1>>24)&255 )).$(( ($1>>16)&255 )).$(( ($1>>8)&255 )).$(( $1&255 ))"; }

preguntar() {   # preguntar <texto> <variable> [por defecto]
    local resp
    if [[ -n "${3:-}" ]]; then
        read -r -p "$1 [$3]: " resp || exit 1
        resp="${resp:-$3}"
    else
        read -r -p "$1: " resp || exit 1
    fi
    printf -v "$2" '%s' "$resp"
}

si_no() {       # si_no <texto> -> 0 si la respuesta es s
    local resp
    while true; do
        read -r -p "$1 (s/n): " resp || exit 1
        case "${resp,,}" in
            s|si|sí) return 0 ;;
            n|no)    return 1 ;;
        esac
    done
}

# --- argumentos ---------------------------------------------------------------
ORIGEN_LOCAL=""; FORCAR=0; CONTINUAR=0; PANELL_LOCAL=""; NO_PANELL_CLI=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --local)     ORIGEN_LOCAL="${2:?falta la ruta después de --local}"
                     [[ "$ORIGEN_LOCAL" =~ ^https?:// ]] || ORIGEN_LOCAL="$(realpath "$ORIGEN_LOCAL")"
                     shift ;;
        --forcar|--forzar) FORCAR=1 ;;
        --continuar) CONTINUAR=1 ;;
        --panell|--panel) PANELL_LOCAL="$(realpath "${2:?falta la ruta después de --panell}")"; shift ;;
        --sense-panell|--sin-panel) NO_PANELL_CLI=1 ;;
        -h|--help)   sed -n '3,/^# =====/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           error "opción desconocida: $1 (el script se usa con el menú: sudo $0)" ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] || error "hay que ser root. Ejecuta: sudo $0"

USUARI="${SUDO_USER:-$(id -un)}"
[[ "$USUARI" != root ]] || USUARI="$(stat -c %U "$0" 2>/dev/null || echo root)"
HOME_USUARI="$(getent passwd "$USUARI" | cut -d: -f6)"
[[ -n "$HOME_USUARI" && -d "$HOME_USUARI" ]] || error "no encuentro el directorio personal de '$USUARI'"
BASE="$HOME_USUARI/core5g"
VENV="$BASE/.venv"

# --- estado de la configuración -----------------------------------------------
MODE=""            # prueba: normal | normal-ip | roaming   ·   genérica: generica
SUBVERSIO=""       # para la genérica: normal | voip
# Extras (solo genérica)
SENSE_UPF=0        # 1 = el núcleo no arranca UPF propio; el SMF habla con un UPF remoto
UPF_REMOT=""       # IP del PC donde está el UPF remoto
PANELL_JA_HI_ERA=0
AMB_PANELL=0       # 1 = instalar panel5g (agente del core + panel web)
PANELL_HASH=""     # hash scrypt de la contraseña de admin del panel (nunca la contraseña)
XARXA="actual"     # actual (no se toca) | fixa (netplan)
IFACE=""; CIDR=""; GW=""
R_PLMN=""; P_PLMN=(); P_IP=()

desar_config() {
    mkdir -p "$(dirname "$CONF")"
    (
        umask 077
        echo "# Configuración de core5g.sh ($(date '+%F %T'))"
        USUARI_DESAT="$USUARI"
        declare -p MODE SUBVERSIO XARXA IFACE CIDR GW R_PLMN P_PLMN P_IP ORIGEN_LOCAL FORCAR USUARI_DESAT MYSQL_PASS \
                   PANELL_LOCAL AMB_PANELL SENSE_UPF UPF_REMOT PANELL_HASH \
            | sed 's/^declare -\([a-zA-Z-]*\) /declare -g\1 /; s/^declare -g- /declare -g /'
    ) > "$CONF"
    chmod 600 "$CONF"   # contiene el hash de la contraseña del panel
}

carregar_config() {
    [[ -f "$CONF" ]] || return 1
    local cli_panell="$PANELL_LOCAL"
    # shellcheck disable=SC1090
    source "$CONF"
    # Las opciones de la línea de órdenes mandan sobre las guardadas
    [[ -z "$cli_panell" ]] || PANELL_LOCAL="$cli_panell"
    # Configuraciones de una versión anterior del script: no tenían los extras
    : "${AMB_PANELL:=0}" "${PANELL_LOCAL:=}" "${SENSE_UPF:=0}" "${UPF_REMOT:=}" "${PANELL_HASH:=}"
    # La variable de entorno manda sobre la contraseña guardada
    [[ -z "${CORE5G_MYSQL_PASS:-}" ]] || MYSQL_PASS="$CORE5G_MYSQL_PASS"
}

# --- versiones ----------------------------------------------------------------
#   CARPETA_DRIVE  subcarpeta de versions_core en el Drive ("" = GitHub)
#   COMPOSE_FILE   fichero compose que se arranca
#   IMATGES        imagen:carpeta_del_Dockerfile que hay que construir a mano
#   AMB_IMS        1 si hay que restaurar MySQL (PyHSS / Kamailio)
definir_versio() {
    ROAMING=0
    case "$MODE" in
        normal)    CARPETA_DRIVE="normal";    COMPOSE_FILE="sa-deploy.yaml"
                   IMATGES=("docker_open5gs:base"); AMB_IMS=0 ;;
        normal-ip) CARPETA_DRIVE="normal+ip"; COMPOSE_FILE="sa-vonr-deploy.yaml"
                   IMATGES=("docker_open5gs:base" "docker_kamailio:ims_base"); AMB_IMS=1 ;;
        roaming)   CARPETA_DRIVE="roaming";   COMPOSE_FILE="sa-deploy.yaml"
                   IMATGES=("docker_open5gs:base"); AMB_IMS=0; ROAMING=1 ;;
        generica)  CARPETA_DRIVE=""
                   if [[ "$SUBVERSIO" == voip ]]; then
                       COMPOSE_FILE="sa-vonr-deploy.yaml"
                       IMATGES=("docker_open5gs:base" "docker_kamailio:ims_base"); AMB_IMS=1
                   else
                       COMPOSE_FILE="sa-deploy.yaml"
                       IMATGES=("docker_open5gs:base"); AMB_IMS=0
                   fi ;;
        *) error "versión desconocida: '$MODE'" ;;
    esac
    # Los extras solo existen en la genérica
    if [[ "$MODE" != generica ]]; then SENSE_UPF=0; AMB_PANELL=0; fi
    (( ! NO_PANELL_CLI )) || AMB_PANELL=0
    DESTI="$BASE/$MODE"
    NOU="$DESTI.nou"
}

nom_versio() {
    case "$MODE" in
        normal)    echo "prueba · normal (5G SA, Drive)" ;;
        normal-ip) echo "prueba · VoIP (5G SA + IMS/VoNR, Drive)" ;;
        roaming)   echo "prueba · roaming (5G SA + SEPP/N32, Drive)" ;;
        generica)  echo "genérica · $( [[ "$SUBVERSIO" == voip ]] && echo "VoIP (5G SA + IMS)" || echo "normal (5G SA)") (GitHub herlesupreeth)$(text_extres)" ;;
        *)         echo "(ninguna)" ;;
    esac
}

text_extres() {
    [[ "$MODE" == generica ]] || return 0
    local t=""
    (( SENSE_UPF )) && t+=" + sin UPF (UPF remoto en $UPF_REMOT)"
    (( AMB_PANELL )) && t+=" + panel5g"
    echo "$t"
}

# --- red ----------------------------------------------------------------------
iface_ruta_defecte() {
    ip -4 route show default 2>/dev/null | awk '{for (i=1; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}'
}
ip_de_iface() { ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4; exit}'; }
gw_de_iface() { ip -4 route show default dev "$1" 2>/dev/null | awk '{print $3; exit}'; }

# Deja IP, CIDR, GW e IFACE listos a partir de la configuración de red
resoldre_xarxa() {
    if [[ "$XARXA" == fixa ]]; then
        IP="${CIDR%/*}"
        return 0
    fi
    [[ -n "$IFACE" ]] || IFACE="$(iface_ruta_defecte)"
    [[ -n "$IFACE" ]] || return 1
    CIDR="$(ip_de_iface "$IFACE")"
    [[ -n "$CIDR" ]] || return 1
    IP="${CIDR%/*}"
    GW="$(gw_de_iface "$IFACE")"
}

text_xarxa() {
    if [[ "$XARXA" == fixa ]]; then
        echo "IP fija $CIDR en $IFACE, puerta de enlace $GW (netplan)"
    elif resoldre_xarxa; then
        echo "IP actual $CIDR en $IFACE${GW:+, puerta de enlace $GW} (no se modifica)"
    else
        echo "IP actual: no detectada (configúrala en la opción 1)"
    fi
}

llistar_ifaces() {
    mapfile -t IFACES < <(ip -br link show | awk '$1!="lo" && $1!~/^(docker|br-|veth|ogstun)/ {sub(/@.*/, "", $1); print $1}')
    local i a
    for i in "${!IFACES[@]}"; do
        a="$(ip_de_iface "${IFACES[$i]}")"
        printf '   %d) %-16s %s\n' "$((i + 1))" "${IFACES[$i]}" "${a:-(sin IPv4)}"
    done
}

triar_iface() {   # triar_iface <interfaz por defecto> -> IFACE
    local n def=1 i
    llistar_ifaces
    (( ${#IFACES[@]} )) || { echo "   No hay ninguna interfaz disponible."; return 1; }
    for i in "${!IFACES[@]}"; do [[ "${IFACES[$i]}" == "${1:-}" ]] && def=$((i + 1)); done
    while true; do
        preguntar "   Número de interfaz" n "$def"
        if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#IFACES[@]} )); then
            IFACE="${IFACES[$((n - 1))]}"; return 0
        fi
        echo "   Número no válido."
    done
}

menu_xarxa() {
    local opc cidr gw
    echo
    echo "--- 1) IP, interfaz y puerta de enlace ---"
    echo "   a) Mantener la IP actual del PC (no se toca la red)"
    echo "   b) Fijar una IP estática (netplan, permanente)"
    echo "   c) Volver"
    preguntar "Opción" opc "a"
    case "${opc,,}" in
        a)
            echo "Interfaces (por defecto, la de la ruta por defecto):"
            triar_iface "$(iface_ruta_defecte)" || return
            if [[ -z "$(ip_de_iface "$IFACE")" ]]; then
                echo "   $IFACE no tiene IPv4. Conéctala o fija una IP (opción b)."
                IFACE=""; return
            fi
            XARXA="actual"; CIDR=""; GW="" ;;
        b)
            echo "Interfaz que va a la red del laboratorio:"
            triar_iface "$IFACE" || return
            while true; do
                preguntar "   IP/máscara (p. ej. 10.112.66.252/24)" cidr "${CIDR:-}"
                if [[ "$cidr" =~ ^([0-9.]+)/([0-9]{1,2})$ ]]; then
                    local _ip="${BASH_REMATCH[1]}" _pref="${BASH_REMATCH[2]}"
                    if es_ipv4 "$_ip" && (( _pref >= 1 && _pref <= 30 )); then
                        break
                    fi
                fi
                echo "   Formato no válido (IP/máscara, máscara entre /1 y /30)."
            done
            local ip="${cidr%/*}" pref="${cidr#*/}" mask red
            mask=$(( (0xFFFFFFFF << (32 - pref)) & 0xFFFFFFFF ))
            red=$(( $(ip2int "$ip") & mask ))
            while true; do
                preguntar "   Puerta de enlace" gw "$(int2ip $(( red + 1 )))"
                if ! es_ipv4 "$gw"; then echo "   No es una IPv4."
                elif (( ( $(ip2int "$gw") & mask ) != red )); then echo "   No está en la red de $cidr."
                elif [[ "$gw" == "$ip" ]]; then echo "   Coincide con la IP del PC."
                else break
                fi
            done
            XARXA="fixa"; CIDR="$cidr"; GW="$gw" ;;
        *) return ;;
    esac
    echo "   Red: $(text_xarxa)"
}

# --- menú de versiones --------------------------------------------------------
menu_versio() {
    local opc
    echo
    echo "--- 2) Versión ---"
    echo "   1) prueba    Proyectos de prueba del Drive, con los abonados de prueba ya cargados."
    echo "                Elige después: normal, VoIP o roaming."
    echo "   2) genérica  Proyecto oficial herlesupreeth/docker_open5gs de GitHub, sin radio"
    echo "                ni abonados. Elige después: normal o VoIP, y los extras"
    echo "                (sin UPF, panel5g)."
    echo "   3) Volver"
    preguntar "Opción" opc
    case "$opc" in
        1) menu_prova || return ;;
        2) menu_generica || return ;;
        *) return ;;
    esac
    echo "   Versión: $(nom_versio)"
}

menu_prova() {
    local p
    echo
    echo "   --- prueba ---"
    echo "   a) normal   Núcleo 5G SA (Open5GS) con WebUI, métricas y Grafana (carpeta \"normal\")."
    echo "   b) VoIP     Núcleo 5G SA + IMS para llamadas VoNR: Kamailio, PyHSS, MySQL"
    echo "               (carpeta \"normal+ip\"), con abonados 5G e IMS."
    echo "   c) roaming  Núcleo 5G SA con SEPP/N32 para hacer roaming entre núcleos (carpeta \"roaming\")."
    echo "               Pide el PLMN de este núcleo y el PLMN y la IP de cada socio."
    echo "   d) Volver"
    preguntar "   Opción" p "a"
    case "${p,,}" in
        a) MODE="normal" ;;
        b) MODE="normal-ip" ;;
        c) demanar_roaming; MODE="roaming" ;;
        *) return 1 ;;
    esac
    SUBVERSIO=""; SENSE_UPF=0; UPF_REMOT=""; AMB_PANELL=0
}

demanar_roaming() {
    local p i
    while true; do
        preguntar "   PLMN de este núcleo (MCC+MNC, p. ej. 00101)" p "${R_PLMN:-}"
        es_plmn "$p" && break
        echo "   PLMN no válido: 5 o 6 cifras."
    done
    R_PLMN="$p"; P_PLMN=(); P_IP=()
    echo "   Socios (el otro núcleo). Deja el PLMN en blanco para terminar."
    while true; do
        preguntar "   PLMN del socio $(( ${#P_PLMN[@]} + 1 ))" p ""
        if [[ -z "$p" ]]; then
            (( ${#P_PLMN[@]} )) && break
            echo "   Hace falta al menos un socio."; continue
        fi
        es_plmn "$p" || { echo "   PLMN no válido."; continue; }
        [[ "$p" != "$R_PLMN" && " ${P_PLMN[*]} " != *" $p "* ]] \
            || { echo "   Ese PLMN ya está en uso: dos núcleos no pueden compartir PLMN."; continue; }
        preguntar "   IP del PC del socio $p" i ""
        es_ipv4 "$i" || { echo "   IP no válida."; continue; }
        [[ " ${P_IP[*]} " != *" $i "* ]] || { echo "   IP repetida."; continue; }
        P_PLMN+=("$p"); P_IP+=("$i")
    done
}

menu_generica() {
    local p i
    echo
    echo "   --- genérica ---"
    echo "   a) normal (5G SA, sa-deploy.yaml)"
    echo "   b) VoIP   (5G SA + IMS/VoNR, sa-vonr-deploy.yaml)"
    echo "   c) Volver"
    preguntar "   Cuál quieres arrancar" p "a"
    case "${p,,}" in
        a) SUBVERSIO="normal" ;;
        b) SUBVERSIO="voip" ;;
        *) return 1 ;;
    esac
    MODE="generica"

    echo
    echo "   Extras de la genérica:"
    echo "   · sin UPF: el núcleo no arranca su UPF (la pieza que lleva los datos de los"
    echo "     móviles hacia internet); el SMF lo busca en otro PC (UPF remoto, puerto 8805/udp)."
    if si_no "   ¿Instalar sin UPF (UPF en otro PC)?"; then
        while true; do
            preguntar "   IP del PC donde está el UPF remoto" i "${UPF_REMOT:-}"
            es_ipv4 "$i" && break
            echo "   IP no válida."
        done
        SENSE_UPF=1; UPF_REMOT="$i"
        if [[ "$SUBVERSIO" == voip ]]; then
            echo "   AVISO: con el UPF remoto, la voz (IMS) no funciona si este PC no tiene ruta hacia"
            echo "          la red interna del UPF remoto; los datos sí funcionan."
        fi
    else
        SENSE_UPF=0; UPF_REMOT=""
    fi

    echo "   · panel5g: panel web (https://<IP>:8443) para ver el estado y cambiar parámetros,"
    echo "     más el agente del core que usa el panel (puerto 9543, con certificados)."
    if si_no "   ¿Instalar panel5g?"; then
        AMB_PANELL=1
        if [[ -n "$PANELL_HASH" ]] && si_no "   Ya hay una contraseña de admin guardada. ¿Mantenerla?"; then
            :
        else
            demanar_contrasenya_panell || { AMB_PANELL=0; echo "   panel5g no elegido."; }
        fi
    else
        AMB_PANELL=0
    fi
}

# Pide la contraseña del usuario admin del panel y guarda solo su hash
# (scrypt, el mismo formato que panel/app/auth.py).
demanar_contrasenya_panell() {
    local p1 p2
    command -v python3 >/dev/null || { echo "   Hace falta python3 para preparar la contraseña."; return 1; }
    while true; do
        read -r -s -p "   Contraseña del usuario admin del panel (mínimo 8 caracteres): " p1 || return 1; echo
        (( ${#p1} >= 8 )) || { echo "   Demasiado corta."; continue; }
        read -r -s -p "   Repítela: " p2 || return 1; echo
        [[ "$p1" == "$p2" ]] && break
        echo "   No coinciden."
    done
    PANELL_HASH="$(printf '%s' "$p1" | python3 -I -c '
import base64, hashlib, os, sys
pw = sys.stdin.read()
n, r, p = 2 ** 15, 8, 1
salt = os.urandom(16)
dk = hashlib.scrypt(pw.encode(), salt=salt, n=n, r=r, p=p, maxmem=64 * 1024 * 1024)
b = lambda x: base64.b64encode(x).decode()
print(f"scrypt${n}${r}${p}${b(salt)}${b(dk)}")')" || { echo "   No se ha podido calcular el hash."; return 1; }
    echo "   Contraseña preparada (solo se guarda su hash)."
}

# --- información --------------------------------------------------------------
estat_prog() { if eval "$1" >/dev/null 2>&1; then echo "[sí]"; else echo "[no]"; fi; }

menu_info() {
    echo
    echo "--- 4) Programas que se instalan ---"
    printf '   %-22s %-6s %s\n' "git" "$(estat_prog 'command -v git')" \
        "Descarga la versión genérica desde GitHub."
    printf '   %-22s %-6s %s\n' "curl" "$(estat_prog 'command -v curl')" \
        "Descarga Docker (get.docker.com; versión fijable con CORE5G_DOCKER_VERSIO)."
    printf '   %-22s %-6s %s\n' "Docker Engine" "$(estat_prog 'command -v docker')" \
        "Ejecuta cada función del núcleo (AMF, SMF, UPF...) en un contenedor."
    printf '   %-22s %-6s %s\n' "Docker Compose" "$(estat_prog 'docker compose version')" \
        "Arranca todos los contenedores juntos a partir de los ficheros .yaml."
    printf '   %-22s %-6s %s\n' "grupo docker" "$(estat_prog "id -nG $USUARI | grep -qw docker")" \
        "Permite a $USUARI usar docker sin sudo (hay que reiniciar la sesión)."
    printf '   %-22s %-6s %s\n' "unzip" "$(estat_prog 'command -v unzip')" \
        "Descomprime el proyecto descargado del Drive."
    printf '   %-22s %-6s %s\n' "python3-venv + gdown" "$(estat_prog "test -x $VENV/bin/python")" \
        "Descarga las carpetas del Drive (solo versiones del Drive)."
    printf '   %-22s %-6s %s\n' "agent5g (panel5g)" "$(estat_prog 'systemctl is-active -q agent5g')" \
        "Solo genérica + panel5g. Agente del core (mTLS, puerto 9543) y captura NGAP (tshark)."
    printf '   %-22s %-6s %s\n' "panel web (panel5g)" "$(estat_prog 'docker inspect -f "{{.State.Running}}" panel5g | grep -qx true')" \
        "Solo genérica + panel5g. https://<IP>:8443, usuario admin. Radios: sudo emparella-radio <nombre>."
    printf '   %-22s %-6s %s\n' "swap (4 GB)" "$(estat_prog "swapon --show=NAME --noheadings | grep -Fxq $SWAP_FILE")" \
        "Memoria de intercambio para que la construcción de las imágenes no se quede sin RAM."
    echo
    echo "   Si Docker Compose no estaba, después de instalarlo hay que reiniciar el equipo;"
    echo "   el script puede volver a ejecutarse solo en el siguiente arranque."
}

# --- desinstalar ----------------------------------------------------------------
# Usa scripts/desinstala.sh del panel5g (el de la última instalación o, si no lo hay,
# el de GitHub). El core 5G, los abonados y la CA no se tocan nunca.
menu_desinstalar() {
    local s="$BASE/panel5g/scripts/desinstala.sh" tmp=""
    if [[ ! -f "$s" ]]; then
        tmp="$(mktemp -d)"
        if git clone -q --depth 1 --branch "$PANELL_BRANCA" "$PANELL_REPO" "$tmp/p" 2>/dev/null; then
            s="$tmp/p/scripts/desinstala.sh"
        fi
    fi
    if [[ -f "$s" ]]; then
        bash "$s" || true
    else
        echo "   No encuentro desinstala.sh ($PANELL_REPO, rama $PANELL_BRANCA)."
    fi
    [[ -z "$tmp" ]] || rm -rf "$tmp"
}

# --- menú principal -----------------------------------------------------------
menu_principal() {
    local opc
    if carregar_config; then
        echo "Se ha cargado la configuración guardada en $CONF."
    fi
    rm -f "$AVIS" "$ESTAT_DIR/estat" 2>/dev/null || true
    while true; do
        echo
        echo "=================================================================="
        echo " core5g · instalador del núcleo 5G"
        echo "=================================================================="
        echo " Red:     $(text_xarxa)"
        echo " Versión: $(nom_versio)"
        if [[ "$MODE" == roaming ]]; then
            local k s=""
            for k in "${!P_PLMN[@]}"; do s+=" ${P_PLMN[$k]}@${P_IP[$k]}"; done
            echo "          PLMN $R_PLMN, socios:$s"
        fi
        echo "------------------------------------------------------------------"
        echo " 1) Configurar la IP, la interfaz y la puerta de enlace"
        echo " 2) Seleccionar la versión"
        echo " 3) Instalar"
        echo " 4) Información de los programas que se instalan"
        echo " 5) Desinstalar (agente, panel, radio, UPF)"
        echo " 6) Cancelar"
        preguntar "Opción" opc
        case "$opc" in
            1) menu_xarxa ;;
            2) menu_versio ;;
            3)
                [[ -n "$MODE" ]] || { echo "   Primero elige una versión (opción 2)."; continue; }
                resoldre_xarxa || { echo "   No hay IP: configura la red (opción 1)."; continue; }
                echo
                echo "Se hará la instalación:"
                echo "   Red:     $(text_xarxa)"
                echo "   Versión: $(nom_versio)"
                echo "   Destino: $BASE/$MODE/docker_open5gs"
                si_no "¿Continuar?" && return 0 ;;
            4) menu_info ;;
            5) menu_desinstalar ;;
            6) echo "Cancelado."; exit 0 ;;
            *) echo "   Opción no válida." ;;
        esac
    done
}

# ==============================================================================
# INSTALACIÓN
# ==============================================================================

comprovar() {
    pas 0 "Comprobaciones (versión: $MODE, usuario: $USUARI, destino: $DESTI)"
    if [[ "$XARXA" == fixa ]]; then
        ip link show "$IFACE" >/dev/null 2>&1 || error "la interfaz '$IFACE' no existe"
        command -v netplan >/dev/null || error "netplan no está instalado"
        info "red: se fijará $CIDR en $IFACE (puerta de enlace $GW) con netplan"
    else
        resoldre_xarxa || error "no se puede detectar la IP actual: configura la red (opción 1)"
        info "red: no se toca; IP actual $CIDR en $IFACE${GW:+ (puerta de enlace $GW)}"
        info "     si esta IP cambia (DHCP), vuelve a ejecutar el script para actualizar el .env"
    fi
    IP="${CIDR%/*}"
    if (( SENSE_UPF )); then
        es_ipv4 "$UPF_REMOT" || error "falta la IP del UPF remoto (opción 2)"
        [[ "$UPF_REMOT" != "$IP" ]] || error "la IP del UPF remoto ($UPF_REMOT) es la de este PC"
        info "sin UPF: el SMF usará el UPF remoto de $UPF_REMOT (PFCP 8805/udp)"
    fi
    if (( AMB_PANELL )); then
        [[ "$PANELL_HASH" == scrypt\$* ]] || error "panel5g elegido pero sin contraseña de admin: vuelve a elegir la versión (opción 2)"
        info "panel5g: agente del core + panel web en https://$IP:8443"
    fi
    if (( ROAMING )); then
        es_plmn "$R_PLMN" || error "falta el PLMN de este núcleo (opción 2)"
        (( ${#P_PLMN[@]} )) || error "falta al menos un socio de roaming (opción 2)"
        R_NOM="plmn$R_PLMN"
        P_NOM=()
        local k
        for k in "${!P_PLMN[@]}"; do
            [[ "${P_IP[$k]}" != "$IP" ]] || error "la IP del socio ${P_PLMN[$k]} es la de este PC"
            P_NOM[$k]="plmn${P_PLMN[$k]}"
        done
        info "roaming: este núcleo $R_NOM (PLMN $R_PLMN, $IP)"
        for k in "${!P_PLMN[@]}"; do
            info "         socio ${P_NOM[$k]} (PLMN ${P_PLMN[$k]}, ${P_IP[$k]})"
        done
    fi
    info "ok"
}

# --- 1. red (netplan) ---------------------------------------------------------
# Escribe SOLO $NETPLAN_FITXER (90-core5g.yaml). Netplan lee los ficheros en
# orden alfabético y, para la misma interfaz, los valores simples del último
# fichero mandan: el "dhcp4: no" de aquí anula el "dhcp4: true" del
# instalador. Las listas (addresses, routes) en cambio se juntan, por eso se
# comprueba que ningún otro fichero ponga direcciones o rutas a la misma
# interfaz. "renderer: networkd" solo para esta interfaz: si el PC usa
# NetworkManager, netplan le dice que no la gestione y el resto (wifi, otras
# tarjetas) sigue igual. Va primero: sin esta IP el PC no tiene salida a
# internet.

# Versiones antiguas del script sobrescribían todos los *.yaml y guardaban el
# original en *.yaml.orig-core5g: se vuelven a poner los originales.
restaurar_netplan_antic() {
    local orig f
    for orig in "$NETPLAN_DIR"/*.yaml.orig-core5g; do
        [[ -f "$orig" ]] || continue
        f="${orig%.orig-core5g}"
        [[ -f "$f" ]] && cp -p "$f" "$f.prev-core5g"
        cp -p "$orig" "$f"          # el .orig-core5g se borra cuando netplan acepta el conjunto
        NETPLAN_CANVIS+=("$f")
        info "restaurado el original de $f (lo sobrescribió una versión antigua de core5g.sh)"
    done
}

# Lista los otros ficheros de netplan que dan direcciones, rutas o gateway a $IFACE
conflictes_netplan() {
    local f
    for f in "$NETPLAN_DIR"/*.yaml; do
        [[ -f "$f" && "$f" != "$NETPLAN_FITXER" ]] || continue
        if command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
            python3 -I - "$f" "$IFACE" <<'PY' && echo "$f"
import sys, yaml
f, iface = sys.argv[1], sys.argv[2]
try:
    d = yaml.safe_load(open(f)) or {}
except Exception:
    sys.exit(1)
xarxa = d.get("network") or {}
for tipus in ("ethernets", "bonds", "bridges", "vlans", "wifis"):
    cfg = (xarxa.get(tipus) or {}).get(iface)
    if isinstance(cfg, dict) and any(k in cfg for k in ("addresses", "routes", "gateway4")):
        sys.exit(0)
sys.exit(1)
PY
        else
            # Sin python3-yaml: aproximación (puede dar falsos positivos)
            grep -qE "^[[:space:]]+$IFACE:" "$f" && grep -qE '^[[:space:]]+(addresses|routes|gateway4):' "$f" \
                && echo "$f"
        fi
    done
    return 0
}

pas_xarxa() {
    if [[ "$XARXA" != fixa ]]; then
        pas 1 "Red: sin cambios (IP actual $IP en $IFACE)"
        return
    fi
    pas 1 "Red por netplan: $IFACE $CIDR, puerta de enlace $GW"

    NETPLAN_CANVIS=()
    restaurar_netplan_antic

    local tmp f; tmp="$(mktemp)"
    cat > "$tmp" <<YAML
# Lo escribe core5g.sh: IP fija para el núcleo 5G. Los otros ficheros no se tocan.
network:
  version: 2
  ethernets:
    $IFACE:
      renderer: networkd
      dhcp4: false
      dhcp6: false
      addresses:
        - $CIDR
      routes:
        - to: default
          via: $GW
      nameservers:
        addresses: [$DNS]
YAML

    if [[ -f "$NETPLAN_FITXER" ]] && cmp -s "$tmp" "$NETPLAN_FITXER"; then
        info "$NETPLAN_FITXER ya tiene esta configuración"
    else
        [[ -f "$NETPLAN_FITXER" ]] && cp -p "$NETPLAN_FITXER" "$NETPLAN_FITXER.prev-core5g"
        install -m 600 "$tmp" "$NETPLAN_FITXER"
        NETPLAN_CANVIS+=("$NETPLAN_FITXER")
        info "escrito $NETPLAN_FITXER"
    fi
    rm -f "$tmp"

    desfer_netplan() {
        for f in "${NETPLAN_CANVIS[@]}"; do
            if [[ -f "$f.prev-core5g" ]]; then
                mv "$f.prev-core5g" "$f"
            elif [[ "$f" == "$NETPLAN_FITXER" ]]; then
                rm -f "$f"
            fi
        done
    }

    local conflictes
    conflictes="$(conflictes_netplan)"
    if [[ -n "$conflictes" ]]; then
        desfer_netplan
        error "estos ficheros ya ponen direcciones o rutas a $IFACE y chocarían con la IP fija:
$(sed 's/^/       /' <<<"$conflictes")
       Quita la parte de $IFACE (o déjala con dhcp4: true) y vuelve a ejecutar el script,
       o elige \"Mantener la IP actual\" en la opción 1."
    fi
    (( ${#NETPLAN_CANVIS[@]} )) || return 0

    if ! netplan generate; then
        desfer_netplan
        error "netplan rechaza la configuración; se han restaurado los ficheros"
    fi
    for f in "${NETPLAN_CANVIS[@]}"; do rm -f "$f.prev-core5g" "$f.orig-core5g"; done
    netplan apply
    info "aplicada (permanente) en $NETPLAN_FITXER; para deshacerla, bórralo y haz: sudo netplan apply"
    sleep 3
}

# --- 2. programas necesarios --------------------------------------------------
instal_lar_servei_continuacio() {
    install -m 755 "$0" "$SCRIPT_FIX"
    mkdir -p "$(dirname "$SERVEI_FITXER")" "$ESTAT_DIR"
    cat > "$SERVEI_FITXER" <<UNIT
[Unit]
Description=core5g: continúa la instalación del núcleo 5G después del reinicio
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=$SCRIPT_FIX --continuar
StandardOutput=append:$REGISTRE
StandardError=append:$REGISTRE
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable "$SERVEI" >/dev/null 2>&1
    echo "en espera: la instalación continuará sola después del reinicio" > "$ESTAT_DIR/estat"
    mkdir -p "$(dirname "$AVIS")"
    cat > "$AVIS" <<'SH'
# Aviso de core5g.sh: estado de la instalación automática después del reinicio
if [ -r /var/lib/core5g/estat ]; then
    printf '\n*** core5g: %s\n    Registro: sudo tail -f /var/log/core5g.log\n\n' "$(cat /var/lib/core5g/estat)"
fi
SH
}

pas_programari() {
    pas 2 "Programas necesarios"
    local falta=() docker_nou=0

    command -v git  >/dev/null || falta+=(git)
    command -v curl >/dev/null || falta+=(curl)
    if [[ -n "$CARPETA_DRIVE" || -n "$ORIGEN_LOCAL" ]]; then
        command -v unzip >/dev/null || falta+=(unzip)
    fi
    if [[ -n "$CARPETA_DRIVE" && -z "$ORIGEN_LOCAL" ]]; then
        command -v python3 >/dev/null || falta+=(python3)
        python3 -c 'import ensurepip' >/dev/null 2>&1 || falta+=(python3-venv)
    fi
    if (( ${#falta[@]} )); then
        info "instalando: ${falta[*]}"
        apt-get update -qq
        apt-get install -y -qq "${falta[@]}" >/dev/null
    else
        info "git y curl ya están"
    fi

    if docker compose version >/dev/null 2>&1; then
        info "Docker y Docker Compose ya están"
    else
        if command -v docker >/dev/null; then
            info "Docker está pero falta Docker Compose: se instala el complemento"
            apt-get update -qq
            apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 \
                || apt-get install -y -qq docker-compose-v2 >/dev/null \
                || error "no se ha podido instalar Docker Compose"
        else
            local gd; gd="$(mktemp)"
            curl -fsSL --retry 3 https://get.docker.com -o "$gd" || error "no se ha podido descargar get.docker.com"
            if [[ -n "$DOCKER_VERSIO" ]]; then
                info "instalando Docker $DOCKER_VERSIO con el instalador oficial (get.docker.com)"
                sh "$gd" --version "$DOCKER_VERSIO" || { rm -f "$gd"; error "no se ha podido instalar Docker $DOCKER_VERSIO (¿existe para esta versión de Ubuntu?)"; }
                # Misma versión en todos los PCs: que apt no la actualice sola
                apt-mark hold docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1 || true
                info "Docker fijado en $DOCKER_VERSIO (para desfijarlo: apt-mark unhold docker-ce docker-ce-cli)"
            else
                info "instalando la última versión de Docker (get.docker.com); para fijar una: CORE5G_DOCKER_VERSIO=..."
                sh "$gd" || { rm -f "$gd"; error "no se ha podido instalar Docker"; }
            fi
            rm -f "$gd"
        fi
        docker compose version >/dev/null 2>&1 || error "Docker Compose no funciona después de instalarlo"
        docker_nou=1
    fi
    info "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'), $(docker compose version --short 2>/dev/null || echo 'Compose ?')"

    if id -nG "$USUARI" | grep -qw docker; then
        info "$USUARI ya está en el grupo docker"
    else
        usermod -aG docker "$USUARI"
        info "$USUARI añadido al grupo docker"
    fi

    (( docker_nou && ! CONTINUAR )) || return 0

    desar_config
    echo
    echo "Docker Compose se acaba de instalar: hay que reiniciar el equipo para que todo quede activo"
    echo "(servicio de Docker y permisos del grupo docker para $USUARI)."
    if si_no "¿Reiniciar ahora? La instalación continuará sola después del reinicio"; then
        instal_lar_servei_continuacio
        echo "Reiniciando... Cuando vuelvas a entrar, el progreso está en: sudo tail -f $REGISTRE"
        sleep 3
        reboot
        exit 0
    fi
    echo
    echo "La configuración se ha guardado en $CONF."
    echo "Reinicia el equipo y vuelve a ejecutar:  sudo $0"
    echo "(el menú recuperará la configuración; elige 3) Instalar)"
    exit 0
}

# --- 3. swap ------------------------------------------------------------------
pas_swap() {
    pas 3 "Swap $SWAP_SIZE en $SWAP_FILE"
    if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAP_FILE"; then
        info "ya está activa"
    else
        if [[ ! -f "$SWAP_FILE" ]]; then
            fallocate -l "$SWAP_SIZE" "$SWAP_FILE"
            chmod 600 "$SWAP_FILE"
            mkswap "$SWAP_FILE" >/dev/null
        fi
        swapon "$SWAP_FILE"
        info "activada"
    fi
    grep -Eq "^${SWAP_FILE}[[:space:]]" "$FSTAB" \
        || { echo "$SWAP_FILE none swap sw 0 0" >> "$FSTAB"; info "añadida a $FSTAB"; }
}

# --- 4. descarga --------------------------------------------------------------
preparar_gdown() {
    if [[ -x "$VENV/bin/python" ]] && "$VENV/bin/python" -I -c 'import gdown' 2>/dev/null; then
        return
    fi
    info "creando el entorno Python con gdown en $VENV"
    python3 -m venv "$VENV"
    "$VENV/bin/python" -m pip install -q --upgrade pip
    "$VENV/bin/python" -m pip install -q 'gdown>=6,<7'
}

escriure_ajudant() {
    cat > "$VENV/descarrega_drive.py" <<'PY'
"""Descarga solo la subcarpeta del Drive que corresponde a la versión.

Con muchos PCs a la vez el Drive responde "too many requests" o corta por cuota:
cada paso se reintenta con esperas crecientes y un poco de azar para que los PCs
no vuelvan a chocar todos en el mismo segundo.
"""
import os
import random
import sys
import time

import gdown

url, sortida, carpeta = sys.argv[1], sys.argv[2], sys.argv[3]
intents = max(1, int(sys.argv[4])) if len(sys.argv) > 4 else 4


def amb_reintents(nom, fn):
    for n in range(1, intents + 1):
        try:
            r = fn()
            if r:
                return r
            motiu = "el Drive no ha devuelto nada"
        except Exception as e:  # gdown lanza excepciones distintas según la versión
            motiu = str(e).strip().splitlines()[0] if str(e).strip() else type(e).__name__
        if n == intents:
            break
        espera = min(300, 20 * 2 ** (n - 1)) + random.uniform(0, 15)
        print(f"    {nom}: intento {n}/{intents} fallido ({motiu}); vuelvo a probar dentro de {espera:.0f}s",
              file=sys.stderr)
        time.sleep(espera)
    sys.exit(f"{nom}: no se ha podido descargar después de {intents} intentos ({motiu}).\n"
             "Si se está instalando en muchos PCs a la vez, el Drive limita las descargas:\n"
             "copia la carpeta del Drive a un USB o a un servidor del aula y usa\n"
             "  sudo ./core5g.sh --local /ruta/a/la/carpeta   (o --local http://servidor/{versio}.zip)")


entrades = amb_reintents("lista del Drive",
                         lambda: gdown.download_folder(url=url, skip_download=True, quiet=True))

def primera(p):
    return p.replace("\\", "/").split("/")[0]

tops = sorted({primera(e.path) for e in entrades})
triades = [t for t in tops if t.strip().lower() == carpeta.strip().lower()]

if len(triades) != 1:
    print("No existe la subcarpeta '" + carpeta + "' en el Drive. Disponibles:", file=sys.stderr)
    for t in tops:
        print("   - " + t, file=sys.stderr)
    sys.exit(2)

sel = triades[0]
for e in entrades:
    if primera(e.path) != sel:
        continue
    desti = os.path.join(sortida, e.path)
    os.makedirs(os.path.dirname(desti), exist_ok=True)
    amb_reintents(e.path, lambda e=e, desti=desti:
                  gdown.download(id=e.id, output=desti, quiet=False, resume=True))

print(os.path.join(sortida, sel))
PY
}

pas_descarrega() {
    pas 4 "Obtener el proyecto ($MODE)"
    INSTAL_LACIO_NOVA=0

    if [[ -d "$DESTI" && $FORCAR -eq 0 ]] && find "$DESTI" -name "$COMPOSE_FILE" -print -quit | grep -q .; then
        info "ya existe en $DESTI (no se vuelve a descargar)"
        return
    fi

    # Se descarga en <destino>.nou: si algo falla, la instalación anterior queda intacta
    rm -rf "$NOU"
    mkdir -p "$NOU/descarrega" "$BASE"
    trap 'rm -rf "$NOU"' EXIT

    if [[ "$ORIGEN_LOCAL" =~ ^https?:// ]]; then
        # Servidor del aula: {versio} se sustituye por el nombre de la carpeta ("+" codificado)
        local versio="${CARPETA_DRIVE:-$MODE}" url nom
        url="${ORIGEN_LOCAL//\{versio\}/${versio//+/%2B}}"
        nom="$(basename "${url%%\?*}")"; [[ "$nom" == *.* ]] || nom="projecte.zip"
        info "descargando del servidor del aula: $url"
        curl -fL --retry 5 --retry-delay 10 --retry-connrefused -o "$NOU/descarrega/$nom" "$url" \
            || error "no se ha podido descargar $url"
    elif [[ -n "$ORIGEN_LOCAL" ]]; then
        local origen="$ORIGEN_LOCAL"
        # Copia entera de la carpeta del Drive: se elige la subcarpeta de la versión
        if [[ -d "$origen" && -n "$CARPETA_DRIVE" && -d "$origen/$CARPETA_DRIVE" ]]; then
            origen="$origen/$CARPETA_DRIVE"
        fi
        [[ -e "$origen" ]] || error "no existe el origen local $origen"
        info "origen local: $origen"
        if [[ -d "$origen" ]]; then cp -a "$origen/." "$NOU/descarrega/"
        else cp -a "$origen" "$NOU/descarrega/"; fi
    elif [[ -z "$CARPETA_DRIVE" ]]; then
        info "clonando $REPO_GENERIC"
        git clone -q --depth 1 "$REPO_GENERIC" "$NOU/descarrega/docker_open5gs"
    else
        preparar_gdown
        escriure_ajudant
        info "descargando '$CARPETA_DRIVE' de $DRIVE_URL (hasta $INTENTS intentos)"
        "$VENV/bin/python" -I "$VENV/descarrega_drive.py" \
            "$DRIVE_URL" "$NOU/descarrega" "$CARPETA_DRIVE" "$INTENTS" >/dev/null \
            || error "descarga del Drive fallida. Con muchos PCs a la vez, usa --local (USB o servidor del aula); ver sudo $0 --help"
    fi

    local f n=0
    while IFS= read -r -d '' f; do
        info "extrayendo $(basename "$f")"
        case "$f" in
            *.zip) unzip -q -o "$f" -d "$(dirname "$f")" ;;
            *)     tar -xf "$f" -C "$(dirname "$f")" ;;
        esac
        n=$((n + 1))
    done < <(find "$NOU/descarrega" -type f -not -path '*/.git/*' \( -name '*.zip' -o -name '*.tar' -o -name '*.tar.gz' \
                -o -name '*.tgz' -o -name '*.tar.xz' -o -name '*.tar.bz2' \) -print0)
    rm -rf "$NOU/descarrega/__MACOSX"

    find "$NOU" -name "$COMPOSE_FILE" -print -quit | grep -q . \
        || error "lo descargado no contiene $COMPOSE_FILE; no se toca la instalación anterior"
    rm -rf "$DESTI"
    mv "$NOU" "$DESTI"
    trap - EXIT
    INSTAL_LACIO_NOVA=1
}

# --- 5. localizar el proyecto y adaptarlo -------------------------------------
inserir_abans_de_cd() {   # inserir_abans_de_cd <fichero> <línea>
    local f="$1" linia="$2" tmp
    grep -q '^cd install/bin' "$f" || return 1
    tmp="$(mktemp)"
    awk -v l="$linia" '!h && /^cd install\/bin/ {print l; h=1} {print}' "$f" > "$tmp"
    cat "$tmp" > "$f"; rm -f "$tmp"
}

# Algunos *_init.sh solo sustituyen MCC_2/MNC_2 y dejan "MCC"/"MNC" literales
# en el YAML: Open5GS los lee como PLMN 000/000. Se añade la que falte.
pegat_plmn() {
    local init comp yaml tok n=0
    for init in "$PROJECTE"/*/*_init.sh; do
        comp="$(basename "$(dirname "$init")")"
        yaml="$PROJECTE/$comp/$comp.yaml"
        [[ -f "$yaml" ]] || continue
        grep -q "install/etc/open5gs/$comp.yaml" "$init" || continue
        for tok in MCC MNC; do
            grep -qw "$tok" "$yaml" || continue
            grep -qF "s|$tok|" "$init" && continue
            if inserir_abans_de_cd "$init" "sed -i 's|$tok|'\$$tok'|g' install/etc/open5gs/$comp.yaml"; then
                info "parche en $comp/${comp}_init.sh: faltaba sustituir $tok"
                n=$((n + 1))
            else
                avis "$comp/${comp}_init.sh no sustituye $tok y no sé dónde añadirlo"
            fi
        done
    done
    (( n )) || info "sustitución de MCC/MNC correcta en todos los *_init.sh"
}

# Quita un servicio y su volumen de un fichero compose
treure_servei() {   # treure_servei <fichero> <servicio> [volumen]
    local f="$1" s="$2" v="${3:-}" tmp
    grep -qE "^  $s:[[:space:]]*$" "$f" || return 1
    tmp="$(mktemp)"
    awk -v s="$s" -v v="$v" '
        /^[^ #]/            { sec = $1; skip = 0 }
        sec == "services:" && $0 ~ "^  [A-Za-z0-9_-]+:[[:space:]]*$" { skip = ($0 ~ "^  " s ":") }
        sec == "volumes:"  && v != "" && $0 ~ "^  [A-Za-z0-9_-]+:[[:space:]]*$" { skip = ($0 ~ "^  " v ":") }
        !skip { print }
    ' "$f" > "$tmp"
    cat "$tmp" > "$f"; rm -f "$tmp"
}

# Puertos hacia la radio externa: N2 (AMF, 38412/sctp) y N3 (UPF, 2152/udp)
obrir_ports() {   # obrir_ports <fichero>
    local f="$1"
    sed -i -z \
        -e 's|    # ports:\n    #   - "2152:2152/udp"|    ports:\n       - "2152:2152/udp"|' \
        -e 's|    # ports:\n    #   - "38412:38412/sctp"|    ports:\n       - "38412:38412/sctp"|' "$f"
}

pas_adaptar() {
    local f d n
    # Portainer fuera de todos los ficheros compose y del .env
    for f in "$PROJECTE"/*.yaml; do
        treure_servei "$f" portainer portainer_data && info "Portainer quitado de $(basename "$f")"
    done
    sed -i -E '/^# PORTAINER[[:space:]]*$/d; /^PORTAINER_IP=/d' "$PROJECTE/.env"
    if docker inspect portainer >/dev/null 2>&1; then
        docker rm -f portainer >/dev/null && info "contenedor portainer eliminado"
    fi
    if docker image inspect portainer/portainer-ce:latest >/dev/null 2>&1; then
        docker rmi portainer/portainer-ce:latest >/dev/null && info "imagen de portainer eliminada"
    fi

    # Los dos ficheros del núcleo con los puertos hacia la radio, se arranque el que se arranque
    for f in sa-deploy.yaml sa-vonr-deploy.yaml; do
        [[ -f "$PROJECTE/$f" ]] || continue
        obrir_ports "$PROJECTE/$f"
        grep -q '"38412:38412/sctp"' "$PROJECTE/$f" && grep -q '"2152:2152/udp"' "$PROJECTE/$f" \
            && info "$f: puertos 38412/sctp (AMF) y 2152/udp (UPF) publicados" \
            || avis "$f: no he encontrado dónde publicar los puertos 38412/2152"
    done

    [[ "$MODE" == generica ]] || return 0

    # Genérica: fuera todo lo que no es núcleo (radio y UE simulados)
    n=0
    for d in "${GENERIC_ESBORRAR_DIRS[@]}"; do
        [[ -e "$PROJECTE/$d" ]] && { rm -rf "${PROJECTE:?}/$d"; n=$((n + 1)); }
    done
    for f in "${GENERIC_ESBORRAR_YAML[@]}"; do
        [[ -e "$PROJECTE/$f" ]] && { rm -f "$PROJECTE/$f"; n=$((n + 1)); }
    done
    awk -v cap="$GENERIC_ENV_CAPCALERES" -v var="$GENERIC_ENV_VARS" '
        $0 ~ cap { salta = 1; next }
        salta && /^[[:space:]]*$/ { salta = 0 }
        salta { next }
        $0 ~ var { next }
        { print }
    ' "$PROJECTE/.env" > "$PROJECTE/.env.tmp" && cat "$PROJECTE/.env.tmp" > "$PROJECTE/.env" && rm -f "$PROJECTE/.env.tmp"
    info "genérica: $n elemento(s) de radio/UE eliminados (UERANSIM, srsRAN, srsLTE, OAI, SWu) y sus variables del .env"
}

pas_localitzar() {
    pas 5 "Localizar y adaptar el proyecto"

    local candidats c amb_env=()
    mapfile -t candidats < <(find "$DESTI" -type f -name "$COMPOSE_FILE" -not -path '*/__MACOSX/*' \
                                -printf '%d %h\n' | sort -n | cut -d' ' -f2-)
    (( ${#candidats[@]} )) || error "no encuentro $COMPOSE_FILE dentro de $DESTI"
    for c in "${candidats[@]}"; do [[ -f "$c/.env" ]] && amb_env+=("$c"); done
    (( ${#amb_env[@]} )) && candidats=("${amb_env[@]}")
    PROJECTE="${candidats[0]}"

    local fix="$DESTI/docker_open5gs"
    if [[ "$PROJECTE" != "$fix" ]]; then
        [[ -e "$fix" ]] && error "$fix ya existe y no es el proyecto encontrado; usa --forzar"
        mv "$PROJECTE" "$fix"
        PROJECTE="$fix"
    fi
    info "proyecto: $PROJECTE"

    [[ -f "$PROJECTE/.env" ]] || error "el proyecto no trae .env"
    local img
    for img in "${IMATGES[@]}"; do
        [[ -d "$PROJECTE/${img##*:}" ]] || error "falta la carpeta ${img##*:}/ en el proyecto"
    done

    MONGO_ARCHIVE="$(find "$DESTI" -type f -name '*.archive' -not -path '*/__MACOSX/*' -print -quit)"
    IMS_SQL="$(find "$DESTI" -type f -name 'ims_backup*.sql' -not -path '*/__MACOSX/*' -print -quit)"
    if [[ "$MODE" != generica ]]; then
        info "abonados 5G: ${MONGO_ARCHIVE:-(no encontrado)}"
        if (( AMB_IMS )); then info "IMS:         ${IMS_SQL:-(no encontrado)}"; fi
    fi

    find "$PROJECTE" -type f -name '*.sh' -exec chmod +x {} +
    local crlf
    crlf=$(grep -rlI $'\r' --include='*.sh' --include='.env' --include='*.yaml' "$PROJECTE" 2>/dev/null || true)
    if [[ -n "$crlf" ]]; then
        info "corrigiendo finales de línea de Windows (CRLF) en $(wc -l <<<"$crlf") fichero(s)"
        xargs -d '\n' sed -i 's/\r$//' <<<"$crlf"
    fi

    pegat_plmn
    pas_adaptar
    chown -R "$USUARI": "$BASE"
}

# --- 6. .env ------------------------------------------------------------------
posar_env() {   # posar_env <VAR> <valor>
    local env="$PROJECTE/.env"
    if grep -qE "^$1=" "$env"; then
        sed -i "s|^$1=.*|$1=$2|" "$env"
    else
        echo "$1=$2" >> "$env"
    fi
}

pas_env() {
    local env="$PROJECTE/.env" var
    pas 6 ".env → DOCKER_HOST_IP y UPF_ADVERTISE_IP = $IP"
    [[ -f "$env.orig" ]] || cp "$env" "$env.orig"
    for var in DOCKER_HOST_IP UPF_ADVERTISE_IP; do
        posar_env "$var" "$IP"
    done
    chown "$USUARI": "$env" "$env.orig"
    grep -E '^(DOCKER_HOST_IP|UPF_ADVERTISE_IP)=' "$env" | sed 's/^/    /'
}

# --- 7. roaming ---------------------------------------------------------------
pas_roaming() {
    (( ROAMING )) || return 0
    pas 7 "Roaming: este núcleo PLMN $R_PLMN ($R_NOM)"
    local env="$PROJECTE/.env" f k
    for f in roaming/gen_env.sh roaming/render_roaming.sh roaming/roaming_lib.sh sepp/sepp_init.sh; do
        [[ -f "$PROJECTE/$f" ]] || error "el proyecto no trae $f (¿es la carpeta 'roaming' del Drive?)"
    done
    grep -qE '^  sepp:' "$PROJECTE/$COMPOSE_FILE" || error "$COMPOSE_FILE no tiene el servicio sepp"
    grep -q '^#ROAMING_POLICY$' "$PROJECTE/pcf/pcf.yaml" \
        || avis "pcf/pcf.yaml no tiene #ROAMING_POLICY: los visitantes no tendrán política local"
    chmod +x "$PROJECTE"/roaming/*.sh "$PROJECTE/sepp/sepp_init.sh"

    # Los marcadores "ROAMING (fuente)" / "FIN FUENTE" son los del proyecto de
    # roaming del Drive (gen_env.sh) y pueden depender de ellos: no se cambian.
    sed -i '/^# --- ROAMING (fuente)/,/^# --- FIN FUENTE/d' "$env"
    {
        echo "# --- ROAMING (fuente) --- Lo escribe core5g.sh en cada ejecución."
        echo "CORE_NAME=$R_NOM"
        echo "CORE_PLMN=$R_PLMN"
        echo "CORE_IP=$IP"
        for k in "${!P_PLMN[@]}"; do
            echo "PEER_NAME_$((k + 1))=${P_NOM[$k]}"
            echo "PEER_PLMN_$((k + 1))=${P_PLMN[$k]}"
            echo "PEER_HOST_$((k + 1))=${P_IP[$k]}"
        done
        echo "# --- FIN FUENTE ---"
    } >> "$env"

    "$PROJECTE/roaming/gen_env.sh" | sed 's/^/    /'
    grep -E '^(MCC|MNC)=' "$env" | sed 's/^/    /'
    chown -R "$USUARI": "$PROJECTE"
}

# --- 7. sin UPF (solo genérica) -----------------------------------------------
# Igual que el montaje upf_remot: el contenedor upf del núcleo queda detrás del
# perfil "upf_local" (docker compose no lo arranca si no se pide), el SMF publica
# el 8805/udp en la IP del PC y su PFCP apunta al UPF remoto. En los dos lados
# se anuncia la IP de la LAN ("advertise") para que ninguno vea las IP internas
# de Docker del otro. Todo lo que se añade lleva la marca MARCA_SENSE_UPF: volver
# a ejecutar el script sin el extra lo quita y deja el núcleo como estaba.
# (La marca se deja en catalán a propósito: así las dos versiones del script
# reconocen y deshacen los cambios de la otra.)
MARCA_SENSE_UPF="# core5g: sense UPF"

# Quita del compose las líneas que puso el script
treure_marques_compose() {   # treure_marques_compose <fichero>
    sed -i "/$MARCA_SENSE_UPF\$/d" "$1"
}

# Añade líneas justo después de la cabecera de un servicio ("  <servicio>:")
afegir_a_servei() {   # afegir_a_servei <fichero> <servicio> <línea>...
    local f="$1" svc="$2" tmp; shift 2
    grep -qE "^  $svc:[[:space:]]*$" "$f" || return 1
    tmp="$(mktemp)"
    LINIES="$(printf '%s\n' "$@")" awk -v svc="$svc" '
        { print }
        !fet && $0 ~ "^  " svc ":[[:space:]]*$" { print ENVIRON["LINIES"]; fet = 1 }
    ' "$f" > "$tmp"
    cat "$tmp" > "$f"; rm -f "$tmp"
}

# ¿Tiene ya el servicio una clave "ports:" propia (no puesta por el script)?
servei_te_ports() {   # servei_te_ports <fichero> <servicio>
    awk -v svc="$2" '
        /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { dins = ($0 ~ "^  " svc ":") }
        dins && /^    ports:/ { trobat = 1 }
        END { exit !trobat }
    ' "$1"
}

pas_sense_upf() {
    local smf="$PROJECTE/smf/smf.yaml" orig="$PROJECTE/smf/smf.yaml.orig-core5g" f
    [[ "$MODE" == generica ]] || return 0
    if (( ! SENSE_UPF )); then
        # Deshacer una instalación anterior "sin UPF", si la había
        local desfet=0
        [[ -f "$orig" ]] && { cp -p "$orig" "$smf"; rm -f "$orig"; desfet=1; }
        for f in "$PROJECTE"/sa-deploy.yaml "$PROJECTE"/sa-vonr-deploy.yaml; do
            [[ -f "$f" ]] && grep -q "$MARCA_SENSE_UPF\$" "$f" && { treure_marques_compose "$f"; desfet=1; }
        done
        (( ! desfet )) || { pas 7 "UPF local"; info "se ha vuelto al UPF dentro del núcleo (se han deshecho los cambios de \"sin UPF\")"; }
        return 0
    fi

    pas 7 "Sin UPF: el SMF usa el UPF remoto $UPF_REMOT"
    [[ -f "$smf" ]] || error "no encuentro $smf"
    [[ -f "$orig" ]] || cp -p "$smf" "$orig"

    # smf.yaml: se regenera siempre desde el original (así un cambio de IP se vuelve a aplicar)
    local tmp; tmp="$(mktemp)"
    awk -v ip="$IP" -v upf="$UPF_REMOT" '
        /^    [A-Za-z_]+:/ { pfcp = ($0 ~ /^    pfcp:/); part = "" }
        pfcp && /^      server:/ { part = "server" }
        pfcp && /^      client:/ { part = "client" }
        pfcp && part == "server" && !adv && /^        - address: SMF_IP[[:space:]]*$/ {
            print; print "          advertise: " ip; adv = 1; next }
        pfcp && part == "client" && /^          - address: UPF_IP[[:space:]]*$/ {
            sub(/UPF_IP/, upf); cli = 1 }
        { print }
        END { exit !(adv && cli) }
    ' "$orig" > "$tmp" || { rm -f "$tmp"; error "smf/smf.yaml no tiene el formato esperado (pfcp: server SMF_IP / client upf UPF_IP); no se puede quitar el UPF"; }
    cat "$tmp" > "$smf"; rm -f "$tmp"
    info "smf/smf.yaml: PFCP hacia $UPF_REMOT, anunciando $IP (original en smf.yaml.orig-core5g)"

    # Ficheros compose: upf en el perfil upf_local y 8805/udp del SMF publicado
    for f in "$PROJECTE"/sa-deploy.yaml "$PROJECTE"/sa-vonr-deploy.yaml; do
        [[ -f "$f" ]] || continue
        treure_marques_compose "$f"
        afegir_a_servei "$f" upf "    profiles: [\"upf_local\"]  $MARCA_SENSE_UPF" \
            || avis "$(basename "$f"): no hay servicio upf"
        if servei_te_ports "$f" smf; then
            avis "$(basename "$f"): el smf ya tiene ports:, añádele a mano \"8805:8805/udp\""
        else
            afegir_a_servei "$f" smf "    ports:  $MARCA_SENSE_UPF" \
                "      - \"8805:8805/udp\"  $MARCA_SENSE_UPF"
        fi
        info "$(basename "$f"): upf desactivado (perfil upf_local) y 8805/udp del smf publicado"
    done
    chown "$USUARI": "$smf" "$orig" "$PROJECTE"/sa-*deploy.yaml

    # Un upf de este mismo proyecto arrancado antes seguiría funcionando: se quita
    if [[ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' upf 2>/dev/null)" == "$PROJECTE" ]]; then
        docker rm -f upf >/dev/null && info "contenedor upf local de este núcleo eliminado"
    fi
    info "en el PC $UPF_REMOT tiene que haber un UPF que escuche en el 8805/udp y acepte este SMF"
}

# Antes de construir: que no haya ningún apt en marcha (después de un reinicio, Ubuntu hace
# las actualizaciones automáticas y, si actualiza Docker o una biblioteca, reinicia dockerd y
# la construcción acaba en "context canceled") y que Docker responda.
apt_ocupat() {   # cert si algun apt/dpkg té el bloqueig (fcntl, com apt)
    python3 - <<'PY' 2>/dev/null
import fcntl, sys
for p in ('/var/lib/dpkg/lock-frontend', '/var/lib/dpkg/lock', '/var/lib/apt/lists/lock'):
    try:
        f = open(p, 'a')
    except OSError:
        continue
    try:
        fcntl.lockf(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit(0)            # ocupat
sys.exit(1)
PY
}

esperar_apt_i_docker() {
    local t=0 avisat=0
    # Solo el bloqueo de dpkg/apt (el mismo que usa apt); no el nombre de los procesos:
    # unattended-upgrade-shutdown está siempre en marcha y no significa que se esté actualizando.
    while apt_ocupat; do
        (( avisat )) || { info "esperando a que terminen las actualizaciones automáticas de Ubuntu (apt)..."; avisat=1; }
        (( t >= 900 )) && { avis "apt sigue ocupado después de 15 minutos: construyo igualmente"; break; }
        sleep 10; t=$((t + 10))
    done
    esperar "Docker" docker info
}

# construir <descripción> <orden...>: vuelve a probar si falla. Los errores habituales son de
# fuera: un mirror de Ubuntu a medio sincronizar ("File has unexpected size... Mirror sync in
# progress"), una red lenta o Docker reiniciado ("context canceled"). Las capas ya construidas
# quedan en la caché, así que cada intento sigue donde se había quedado.
construir() {
    local desc="$1" n=1; shift
    while true; do
        esperar_apt_i_docker
        if "$@"; then return 0; fi
        (( n < INTENTS_BUILD )) || error "la construcción de $desc ha fallado $INTENTS_BUILD veces (mira el error justo encima)"
        avis "la construcción de $desc ha fallado (intento $n de $INTENTS_BUILD); suele ser un mirror de Ubuntu a medio sincronizar o la red: lo vuelvo a probar en $((n * 60)) s"
        sleep $((n * 60))
        n=$((n + 1))
        if (( n == INTENTS_BUILD )); then
            info "último intento: vacío la caché de construcción (docker builder prune)"
            docker builder prune -f >/dev/null 2>&1 || true
        fi
    done
}

# --- 8. imágenes --------------------------------------------------------------
pas_imatges() {
    pas 8 "Imágenes Docker"
    local par img dir
    for par in "${IMATGES[@]}"; do
        img="${par%%:*}"; dir="${par##*:}"
        if docker image inspect "$img" >/dev/null 2>&1 && (( ! FORCAR )); then
            info "$img ya existe"
        else
            info "construyendo $img desde $PROJECTE/$dir (tarda unos minutos)"
            construir "$img" docker build -t "$img" "$PROJECTE/$dir"
        fi
    done
    info "resto de imágenes locales del compose"
    construir "las imágenes del compose" compose build
    info "descargando imágenes públicas (mongo, grafana...)"
    compose pull --ignore-pull-failures --quiet || true
}

# --- 9. arranque y datos ------------------------------------------------------
# Todas las versiones comparten nombres de contenedor y red: hay que parar las otras
aturar_altres() {
    local d f
    for d in "$BASE"/*/docker_open5gs; do
        [[ -d "$d" ]] || continue
        for f in sa-vonr-deploy.yaml sa-deploy.yaml; do
            [[ -f "$d/$f" ]] || continue
            [[ "$d" == "$PROJECTE" && "$f" == "$COMPOSE_FILE" ]] && continue
            docker compose --project-directory "$d" -f "$d/$f" down --remove-orphans >/dev/null 2>&1 || true
        done
    done
}

pas_arrencada() {
    pas 9 "Arranque de $COMPOSE_FILE"
    aturar_altres
    compose down --remove-orphans >/dev/null 2>&1 || true
    compose up -d --remove-orphans
}

pas_dades() {
    pas 10 "Datos"
    if [[ "$MODE" == generica ]]; then
        info "versión genérica: sin abonados precargados; dalos de alta en la WebUI (http://$IP:9999)"
    elif (( ! INSTAL_LACIO_NOVA && ! FORCAR )); then
        info "instalación existente: no se restauran copias (se conservan los abonados actuales)"
    else
        if [[ -n "$MONGO_ARCHIVE" ]]; then
            esperar mongo docker exec mongo mongosh --quiet --eval 'db.runCommand({ping:1}).ok'
            docker cp "$MONGO_ARCHIVE" mongo:/tmp/open5gs.archive
            docker exec mongo mongorestore --archive=/tmp/open5gs.archive --drop --quiet
            info "abonados 5G restaurados"
        else
            avis "sin copia de MongoDB; habrá que dar de alta los abonados en la WebUI"
        fi
        if (( AMB_IMS )); then
            if [[ -n "$IMS_SQL" ]]; then
                # Contraseña: CORE5G_MYSQL_PASS > MYSQL_ROOT_PASSWORD del .env > "ims".
                # Va por MYSQL_PWD: no sale en la línea de órdenes (ps) ni da el aviso de seguridad.
                local pass="$MYSQL_PASS"
                [[ -n "$pass" ]] || pass="$(sed -n 's/^MYSQL_ROOT_PASSWORD=//p' "$PROJECTE/.env" | tail -1)"
                pass="${pass:-$MYSQL_PASS_DEFECTE}"
                esperar mysql docker exec -e MYSQL_PWD="$pass" mysql mysqladmin -u root ping
                docker exec -i -e MYSQL_PWD="$pass" mysql mysql -u root < "$IMS_SQL" \
                    && info "IMS restaurado" \
                    || avis "la restauración de $IMS_SQL ha dado errores (¿contraseña root? se puede fijar con CORE5G_MYSQL_PASS)"
            else
                avis "sin copia de MySQL; habrá que crear los abonados IMS en PyHSS"
            fi
        fi
        info "reiniciando para que los servicios lean los datos"
        compose down
        compose up -d
    fi

    if (( ROAMING )); then
        esperar mongo docker exec mongo mongosh --quiet --eval 'db.runCommand({ping:1}).ok'
        docker exec mongo mongosh open5gs --quiet --eval \
            'const r = db.subscribers.updateMany({}, {$set: {"slice.$[].session.$[].lbo_roaming_allowed": true}}); print("LBO activado en " + r.matchedCount + " abonado(s)")' \
            | sed 's/^/    /' || avis "no se ha podido activar el LBO en los abonados"
    fi
}

# --- 12. panel5g (solo genérica) ----------------------------------------------
# 12a. Agente del core (mTLS + captura NGAP/SBI + modelo del móvil), como servicios que se
#      reinician siempre, y código de emparejamiento de cada radio. La lógica está en el
#      repositorio del panel (scripts/install_core.sh), versionada con el código.
# 12b. Panel web (contenedor panel5g en https://<IP>:8443) con la contraseña de admin
#      elegida en el menú (scripts/install_panel.sh).
# Si algo falla, el núcleo queda instalado igualmente (solo un aviso).
pas_panell() {
    (( AMB_PANELL )) || return 0
    pas 12 "panel5g: agente del core y panel web"
    # Solo se instala lo que falta: lo que ya está no se toca (versión nueva: menú 5
    # Desinstalar y volver a instalar, o --forzar)
    local agent_ja=0 panell_ja=0
    if (( ! FORCAR )) && [[ -f /etc/systemd/system/agent5g.service && -f /etc/agent5g/agent5g.json ]]; then agent_ja=1; fi
    if (( ! FORCAR )) && docker inspect panel5g >/dev/null 2>&1; then panell_ja=1; fi
    if (( agent_ja )); then
        printf '%s\n' "$IP" > /etc/agent5g/core_ip
        info "el agente del core ya está instalado: no se toca"
    fi
    (( ! panell_ja )) || info "el panel web ya está instalado: no se toca"
    if (( agent_ja && panell_ja )); then
        info "(para poner la versión nueva: menú 5) Desinstalar y después 3) Instalar)"
        PANELL_JA_HI_ERA=1
        return 0
    fi
    local src="$BASE/panel5g" tmp conf_ant=""
    # La configuración del panel (usuarios, radios...) se conserva entre reinstalaciones
    if [[ -f "$src/panel/config/panel.yaml" ]] && ! grep -q 'CANVIA-ME' "$src/panel/config/panel.yaml"; then
        conf_ant="$(mktemp)"; cp -p "$src/panel/config/panel.yaml" "$conf_ant"
    fi
    if [[ -n "$PANELL_LOCAL" ]]; then
        rm -rf "$src.nou"; mkdir -p "$src.nou"
        if [[ -d "$PANELL_LOCAL" ]]; then
            cp -a "$PANELL_LOCAL/." "$src.nou/"
        else
            tar xzf "$PANELL_LOCAL" -C "$src.nou" || { avis "no puedo descomprimir $PANELL_LOCAL"; return 0; }
        fi
        # el .tar.gz lleva una carpeta panel5g/ dentro
        tmp="$(dirname "$(find "$src.nou" -path '*/scripts/install_core.sh' -print -quit 2>/dev/null)")"
        [[ "$tmp" != . && -n "$tmp" ]] || { avis "en $PANELL_LOCAL no hay scripts/install_core.sh"; rm -rf "$src.nou"; return 0; }
        rm -rf "$src"; mv "$(dirname "$tmp")" "$src"; rm -rf "$src.nou"
        info "código del panel copiado de $PANELL_LOCAL"
    else
        rm -rf "$src.nou"
        if git clone -q --depth 1 --branch "$PANELL_BRANCA" "$PANELL_REPO" "$src.nou"; then
            rm -rf "$src"; mv "$src.nou" "$src"
            info "código del panel: $PANELL_REPO ($PANELL_BRANCA, $(git -C "$src" rev-parse --short HEAD))"
        elif [[ -f "$src/scripts/install_core.sh" ]]; then
            rm -rf "$src.nou"; avis "no se ha podido descargar $PANELL_REPO: uso la copia anterior"
        else
            rm -rf "$src.nou"; avis "no se ha podido descargar $PANELL_REPO: se omite panel5g"
            return 0
        fi
    fi
    chown -R root:root "$src"

    if (( ! agent_ja )); then
    info "agente del core:"
    if ! CORE5G_EMPARELLAR_DESPRES=1 bash "$src/scripts/install_core.sh" "$PROJECTE" "$COMPOSE_FILE" "$IP" "$PANELL_CERTS"; then
        avis "la instalación del agente ha fallado (vuelve a probarla: sudo bash $src/scripts/install_core.sh $PROJECTE $COMPOSE_FILE $IP)"
        return 0
    fi

    fi
    (( ! panell_ja )) || return 0
    info "panel web:"
    local cfg="$src/panel/config/panel.yaml"
    [[ -f "$cfg" && -f "$src/scripts/install_panel.sh" ]] || { avis "el código no trae panel/ o scripts/install_panel.sh"; return 0; }
    if [[ -n "$conf_ant" ]]; then
        cp -p "$conf_ant" "$cfg"; rm -f "$conf_ant"
        info "se conserva la configuración anterior del panel (panel.yaml)"
    elif [[ -f /var/lib/panel5g/panel.yaml ]]; then
        cp -p /var/lib/panel5g/panel.yaml "$cfg"
        info "se recupera la configuración del panel guardada al desinstalarlo (/var/lib/panel5g/panel.yaml)"
    fi
    # La contraseña elegida en el menú es la del usuario admin
    posar_hash_panell "$cfg" || avis "no he encontrado el usuario admin en panel.yaml: la contraseña no se ha cambiado"
    if grep -q 'CANVIA-ME' "$cfg"; then
        avis "panel.yaml todavía tiene CANVIA-ME: el panel no se arranca"; return 0
    fi
    [[ -d "$PANELL_CERTS/panel" ]] || { avis "no hay certificados del panel en $PANELL_CERTS/panel"; return 0; }
    if ! bash "$src/scripts/install_panel.sh" "$PANELL_CERTS/panel" "$IP"; then
        avis "el panel web no se ha podido arrancar (sudo bash $src/scripts/install_panel.sh $PANELL_CERTS/panel $IP)"
    fi
}

# Pone PANELL_HASH como hash del usuario admin (bloque "usuaris: / admin:" de panel.yaml)
posar_hash_panell() {   # posar_hash_panell <panel.yaml>
    local f="$1" tmp
    tmp="$(mktemp)"
    HASH="$PANELL_HASH" awk '
        /^[^ #]/          { usu = ($0 ~ /^usuaris:/); adm = 0 }
        usu && /^  [^ ]/  { adm = ($0 ~ /^  admin:/) }
        usu && adm && !fet && /^    hash:/ { print "    hash: \"" ENVIRON["HASH"] "\""; fet = 1; next }
        { print }
        END { exit !fet }
    ' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$f"; rm -f "$tmp"
}

# --- 11. verificación ---------------------------------------------------------
pas_verificar() {
    pas 11 "Verificación"
    local c restes
    sleep 10
    for c in nrf amf smf ausf udm udr pcf nssf bsf scp upf sepp; do
        docker inspect "$c" >/dev/null 2>&1 || continue
        restes="$(docker exec "$c" sh -c 'grep -HnwE "MCC|MNC" /open5gs/install/etc/open5gs/*.yaml' 2>/dev/null \
                  | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
        [[ -z "$restes" ]] || { avis "$c tiene MCC/MNC sin sustituir:"; sed 's/^/      /' <<<"$restes"; }
    done
    info "PLMN que sirve el NRF:"
    docker exec nrf grep -A3 'serving' /open5gs/install/etc/open5gs/nrf.yaml 2>/dev/null | sed 's/^/      /' \
        || info "      (no se puede leer nrf.yaml)"
    if (( SENSE_UPF )); then
        if docker logs smf 2>&1 | grep -q "PFCP associated.*$UPF_REMOT"; then
            info "PFCP asociado con el UPF remoto $UPF_REMOT"
        else
            avis "el SMF todavía no se ha asociado con el UPF de $UPF_REMOT (¿está arrancado? ¿puerto 8805/udp abierto?)"
            info "      compruébalo más tarde: docker logs smf 2>&1 | grep -i pfcp | tail"
        fi
    fi
    if (( ROAMING )); then
        info "N32 (una línea 'established' por socio cuando el otro núcleo también esté arrancado):"
        docker logs sepp 2>&1 | grep -E 'established|terminated|ERROR' | tail -5 | sed 's/^/      /' || true
    fi
}

resum() {
    echo
    echo "==> Hecho: $(nom_versio) en $PROJECTE"
    compose ps --format 'table {{.Name}}\t{{.State}}' | sed 's/^/    /'
    echo
    info "WebUI:              http://$IP:9999"
    info "Grafana:            http://$IP:3000"
    info "AMF para el gNB:    $IP:38412"
    if (( SENSE_UPF )); then
        info "UPF:                remoto en $UPF_REMOT (este núcleo no arranca ninguno)"
        info "   para volver a tenerlo aquí: vuelve a ejecutar el script sin el extra \"sin UPF\""
    fi
    if (( AMB_PANELL )) && docker inspect -f '{{.State.Running}}' panel5g 2>/dev/null | grep -qx true; then
        info "Panel web:          https://$IP:8443 (usuario admin; importa $PANELL_CERTS/ca/ca.crt en el navegador)"
    fi
    if (( AMB_PANELL )) && systemctl is-active -q agent5g 2>/dev/null; then
        info "Agente del panel:   https://$IP:9543 (activo; se reinicia siempre)"
        info "Radios:             llaman solas al core en $IP:9544 (con el certificado del código de emparejamiento)"
        info "Emparejar radio:    sudo emparella-radio <nombre>  (y pega el código en install_radio.sh de la radio)"
        info "   CA y certificados del core: $PANELL_CERTS (ca.key no sale nunca de aquí)"
        local cod; for cod in "$PANELL_CERTS"/emparellament-*.txt; do
            [[ -f "$cod" ]] && info "   código ya generado: $cod"
        done
    fi
    info "Órdenes (desde $PROJECTE):"
    info "   parar:   docker compose -f $COMPOSE_FILE down"
    info "   logs:    docker logs -f amf"
    if (( ROAMING )); then
        info "   N32:     docker logs sepp 2>&1 | grep established"
        info "Radio: si esta es la red VISITADA, la celda tiene que emitir el PLMN $R_PLMN."
    fi
}

# Al final de todo: código de emparejamiento de cada radio, para copiar y pegar en el instalador
# de la radio (install_radio.sh). La radio llamará sola al core ($IP:9544): no hace falta saber su IP.
emparellar_radios() {
    (( AMB_PANELL )) || return 0
    (( ! PANELL_JA_HI_ERA )) || return 0
    [[ -x /usr/local/sbin/emparella-radio ]] || return 0
    local noms="${CORE5G_RADIOS:-}" n
    if [[ -z "$noms" && -t 0 ]]; then
        echo
        echo "==> Emparejar radios con este core"
        info "Cada radio necesita un código de emparejamiento (certificado + IP del core). Ponle un nombre"
        info "(p. ej. radio1, aula2; varios separados por espacios). \"-\" = más tarde (sudo emparella-radio <nombre>)."
        read -r -p "    Nombre de la radio [radio1]: " noms || noms=""
        noms="${noms:-radio1}"
    fi
    [[ "$noms" == "-" ]] && noms=""
    for n in $noms; do
        CORE5G_CORE_IP="$IP" /usr/local/sbin/emparella-radio "$n" "$PANELL_CERTS" || avis "no se ha podido emparejar la radio $n"
    done
    [[ -n "$noms" ]] || info "Para emparejar una radio más adelante: sudo emparella-radio <nombre>  (el código se guarda en $PANELL_CERTS/emparellament-<nombre>.txt)"
}

instal_lar() {
    definir_versio
    comprovar
    pas_xarxa
    pas_programari
    desar_config
    pas_swap
    pas_descarrega
    pas_localitzar
    pas_env
    pas_roaming
    pas_sense_upf
    pas_imatges
    pas_arrencada
    pas_dades
    pas_verificar
    pas_panell
    resum
    emparellar_radios
}


# ==============================================================================
# ROL DE ESTE PC: core, radio o UPF
# ==============================================================================

# Descarga el código de panel5g (scripts de radio/UPF y agente) en una carpeta propia,
# sin tocar la del panel del core ($BASE/panel5g) si la hay.
obtenir_codi_instal() {   # -> CODI_DIR
    CODI_DIR="$BASE/5gpanel-instal"
    if [[ -n "$PANELL_LOCAL" ]]; then
        local t
        t="$(find "$PANELL_LOCAL" -maxdepth 3 -path '*/scripts/install_radio.sh' -print -quit 2>/dev/null || true)"
        [[ -n "$t" ]] || error "en $PANELL_LOCAL no hay scripts/install_radio.sh"
        CODI_DIR="$(dirname "$(dirname "$t")")"
        info "código de panel5g: $CODI_DIR"
        return 0
    fi
    command -v git >/dev/null || { apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git >/dev/null; }
    install -d -o "$USUARI" "$BASE"
    rm -rf "$CODI_DIR.nou"
    if git clone -q --depth 1 --branch "$PANELL_BRANCA" "$PANELL_REPO" "$CODI_DIR.nou"; then
        rm -rf "$CODI_DIR"; mv "$CODI_DIR.nou" "$CODI_DIR"
        info "código de panel5g: $PANELL_REPO ($PANELL_BRANCA, $(git -C "$CODI_DIR" rev-parse --short HEAD))"
    elif [[ -f "$CODI_DIR/scripts/install_radio.sh" ]]; then
        rm -rf "$CODI_DIR.nou"; avis "no se ha podido descargar $PANELL_REPO: uso la copia anterior ($CODI_DIR)"
    else
        error "no se ha podido descargar $PANELL_REPO (¿hay internet?)"
    fi
}

rol_radio() {
    local args=()
    echo
    echo "=================================================================="
    echo " Radio: gNodeB ocudu (USRP B210)"
    echo "=================================================================="
    echo " Se instala Docker, ocudu y la imagen de la gNodeB, y se arranca."
    echo " Con el agente, la radio aparece en el panel del core y se configura desde allí;"
    echo " hace falta el código de emparejamiento (en el core: sudo emparella-radio <nombre>)."
    if si_no "¿Instalar también el agente del panel?"; then
        :
    else
        args+=(--sense-agent)
    fi
    (( FORCAR )) && args+=(--forcar)
    si_no "¿Continuar?" || { echo "Cancelado."; exit 0; }
    obtenir_codi_instal
    bash "$CODI_DIR/scripts/install_radio.sh" "${args[@]}"
}

rol_upf() {
    local args=()
    echo
    echo "=================================================================="
    echo " UPF separado del core (plano de usuario)"
    echo "=================================================================="
    echo " Se instala Docker y la imagen docker_open5gs (20-30 min la primera vez) y el UPF."
    echo " Con el agente, el core le pasa la configuración y lo selecciona solo (pestaña UPF"
    echo " del panel); hace falta el código de emparejamiento (en el core: sudo emparella-upf <nombre>)."
    echo " Sin agente, solo pide la IP del core y el core se separa a mano (versión genérica,"
    echo " extra \"sin UPF\" con la IP de este PC)."
    if si_no "¿Instalar también el agente del panel?"; then
        :
    else
        args+=(--sense-agent)
    fi
    (( FORCAR )) && args+=(--forcar)
    si_no "¿Continuar?" || { echo "Cancelado."; exit 0; }
    obtenir_codi_instal
    bash "$CODI_DIR/scripts/install_upf.sh" "${args[@]}"
}

menu_rol() {
    local opc
    while true; do
        echo
        echo "=================================================================="
        echo " core5g · instalador de la red 5G"
        echo "=================================================================="
        echo " ¿Qué rol tiene este PC?"
        echo " 1) Core   (núcleo 5G; agente y panel web opcionales)"
        echo " 2) Radio  (gNodeB ocudu; agente del panel opcional)"
        echo " 3) UPF    (UPF separado del core; agente del panel opcional)"
        echo " 4) Desinstalar (agente, panel, radio, UPF)"
        echo " 5) Salir"
        preguntar "Opción" opc
        case "$opc" in
            1) ROL_PC=core; return 0 ;;
            2) ROL_PC=radio; return 0 ;;
            3) ROL_PC=upf; return 0 ;;
            4) menu_desinstalar ;;
            5) echo "Cancelado."; exit 0 ;;
            *) echo "   Opción no válida." ;;
        esac
    done
}

# ==============================================================================
if (( CONTINUAR )); then
    # Ejecución automática después del reinicio (servicio systemd)
    echo; echo "===== core5g: continuación automática $(date '+%F %T') ====="
    # No volverá a arrancar en el próximo reinicio; el fichero de la unidad se quita al terminar
    # (no mientras se ejecuta, para que systemd no toque nada del trabajo en curso)
    systemctl disable "$SERVEI" >/dev/null 2>&1 || true
    trap 'rm -f "$SERVEI_FITXER"; systemctl daemon-reload >/dev/null 2>&1 || true' EXIT
    mkdir -p "$ESTAT_DIR"
    echo "instalación automática en curso" > "$ESTAT_DIR/estat"
    trap 'echo "la instalación automática ha fallado (revisa el registro)" > "$ESTAT_DIR/estat"' ERR
    carregar_config || error "no hay configuración guardada en $CONF"
    # En el servicio systemd no hay SUDO_USER: el usuario es el de la configuración guardada
    USUARI="${USUARI_DESAT:-$USUARI}"
    HOME_USUARI="$(getent passwd "$USUARI" | cut -d: -f6)"
    BASE="$HOME_USUARI/core5g"
    VENV="$BASE/.venv"
    instal_lar
    echo "instalación automática terminada correctamente ($(nom_versio), IP $IP)" > "$ESTAT_DIR/estat"
else
    menu_rol
    case "$ROL_PC" in
        core)  menu_principal; instal_lar ;;
        radio) rol_radio ;;
        upf)   rol_upf ;;
    esac
fi
