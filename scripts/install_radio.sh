#!/usr/bin/env bash
# ============================================================================
# install_radio.sh - instala la parte radio (PC2) tal como la describe la guía de
# despliegue (apartados 2 y 4): Docker, ocudu, docker-compose.yml y .env unificados,
# imagen del gNodeB y arranque; y, además, el agente del panel (agent5g) como servicio
# que arranca solo y se reinicia siempre.
#
# Uso:
#   sudo ./install_radio.sh                       (pregunta lo que falte)
#   sudo ./install_radio.sh --emparejamiento codigo.txt
#
# La radio LLAMA AL CORE (como la gNodeB al AMF): el agente del panel no escucha ningún puerto,
# abre él las conexiones hacia el core (puerto 9544) y las mantiene; si la red llega tarde o
# se cae, lo reintenta solo. Al core le da igual la IP de la radio: la única IP fija es la del core.
#
# Opciones:
#   --core IP              IP del core (AMF). Por defecto, la que lleva el código de emparejamiento
#   --radio IP             IP de este PC (por defecto, la de la ruta hacia el core)
#   --emparejamiento F     fichero con el código de emparejamiento (en el core: sudo emparella-radio <nombre>);
#                          sin esta opción se pide que lo pegues
#   --ocudu DIR            dónde se clona ocudu (por defecto ~/ocudu del usuario)
#   --sin-build            no construir la imagen ni arrancar el gNB (solo configurar + agente)
#   --sin-agente           no instalar el agente del panel
#   --forzar               volver a instalar el agente aunque ya esté
#
# Volver a ejecutarlo no rehace lo que ya está: si el agente ya está instalado no se toca
# (para poner la versión nueva: sudo agent5g > Actualizar desde GitHub, o desinstala.sh --radio y
# volver a ejecutar este script, o --forzar). Si el agente se había desinstalado, usa solo el certificado
# que se guardó (/var/lib/agent5g/emparellament) y no hace falta volver a pegar el código.
#
# Parámetros de la celda (variables de entorno; por defecto, los de la guía, Anexo B):
#   PLMN=00101 TAC=1 SST=1 TX_GAIN=80 RX_GAIN=40 DL_ARFCN=470000 BAND=40
#   BANDWIDTH_MHZ=20 SCS=30 SRATE=23.04 PCI=1 TX_ANTENA=1 RX_ANTENA=1
#   Si el .env ya los tiene, se conservan los valores actuales.
#
# Diferencias con la guía (para que el panel pueda gestionar la radio):
#   * el PLMN se llama PLMN_1 en el .env (el panel añade PLMN_2 para el segundo PLMN);
#   * número de antenas parametrizado (RX_ANTENA/TX_ANTENA, por defecto 1 = como en la guía);
#   * el gNB se arranca en segundo plano (-d): el log está en "docker logs -f ocudu_gnb".
# ============================================================================
set -euo pipefail
OCUDU_REPO="${OCUDU_REPO:-https://gitlab.com/ocudu/ocudu.git}"
CORE_IP=""; RADIO_IP=""; EMPAR=""; OCUDU=""; AMB_BUILD=1; AMB_AGENT=1; FORCAR=0

pas()   { echo; echo "==> [$1] $2"; }
info()  { echo "    $*"; }
avis()  { echo "    AVISO: $*"; }
error() { echo "ERROR: $*" >&2; exit 1; }
es_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --core)          CORE_IP="${2:?}"; shift ;;
        --radio)         RADIO_IP="${2:?}"; shift ;;
        --emparellament|--emparejamiento) EMPAR="$(realpath "${2:?}")"; shift ;;
        --ocudu)         OCUDU="${2:?}"; shift ;;
        --sense-build|--sin-build)   AMB_BUILD=0 ;;
        --sense-agent|--sin-agente)  AMB_AGENT=0 ;;
        --forcar|--forzar)           FORCAR=1 ;;
        -h|--help)       sed -n '3,/^# =====/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)               error "opción desconocida: $1" ;;
    esac
    shift
done
[[ $EUID -eq 0 ]] || error "hay que ser root: sudo $0"
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
USUARI="${SUDO_USER:-$(id -un)}"
HOME_USUARI="$(getent passwd "$USUARI" | cut -d: -f6)"
OCUDU="${OCUDU:-$HOME_USUARI/ocudu}"
DOCKER_DIR="$OCUDU/docker"

pregunta() {   # pregunta <texto> <variable> [por defecto]
    local txt="$1" var="$2" def="${3:-}" r
    [[ -t 0 ]] || { printf -v "$var" '%s' "$def"; return; }
    read -r -p "    $txt${def:+ [$def]}: " r || true
    printf -v "$var" '%s' "${r:-$def}"
}

# ¿agente ya instalado? Entonces no se toca (ni se pide el código)
AGENT_JA=0; CORE_ENLLAC=""
if (( AMB_AGENT && ! FORCAR )) && [[ -f /etc/systemd/system/agent5g.service && -f /etc/agent5g/agent5g.json ]] \
   && [[ "$(python3 -c 'import json;print(json.load(open("/etc/agent5g/agent5g.json")).get("role",""))' 2>/dev/null)" == radio ]]; then
    AGENT_JA=1; AMB_AGENT=0
    CORE_ENLLAC="$(python3 -c 'import json; c=json.load(open("/etc/agent5g/agent5g.json")); print("%s:%s" % (c["core"], c.get("core_port") or 9544) if c.get("core") else "")' 2>/dev/null || true)"
    echo "    El agente del panel ya está instalado: no se toca (versión nueva: sudo agent5g > Actualizar, o --forzar)."
fi
DESAT=/var/lib/agent5g/emparellament
# código de emparejamiento (antes de la parte lenta, para no tener que esperar 40 minutos)
CODI=""; NOM_RADIO=""
if (( AMB_AGENT )); then
    if [[ -z "$EMPAR" && -s "$DESAT/agent-radio.crt" && -s "$DESAT/core" ]]; then
        # reinstalación después de desinstala.sh: el certificado y la IP del core ya están
        cn="$(openssl x509 -in "$DESAT/agent-radio.crt" -noout -subject -nameopt multiline 2>/dev/null | sed -n 's/^ *commonName *= *//p')"
        n="${cn#agent-radio}"; n="${n#-}"; n="${n:-radio}"
        CODI="$( { echo "-----BEGIN 5GPANEL EMPARELLAMENT $n-----"
                   tar czf - -C "$DESAT" ca.crt agent-radio.crt agent-radio.key core | base64 -w 76
                   echo "-----END 5GPANEL EMPARELLAMENT-----"; } )"
        echo "    Uso el emparejamiento guardado ($DESAT): radio \"$n\", core $(cat "$DESAT/core")"
    elif [[ -n "$EMPAR" ]]; then
        CODI="$(cat "$EMPAR")"
    elif [[ -t 0 ]]; then
        echo "    En el core, ejecuta:  sudo emparella-radio <nombre_de_esta_radio>   (p. ej. aula2)"
        echo "    y pega aquí el código (de la línea BEGIN a la línea END):"
        while IFS= read -r l; do
            CODI+="$l"$'\n'
            [[ "$l" == "-----END 5GPANEL EMPARELLAMENT-----" ]] && break
        done
    fi
    NOM_RADIO="$(sed -n 's/^-----BEGIN 5GPANEL EMPARELLAMENT \([A-Za-z0-9_.-]*\)-----$/\1/p' <<<"$CODI" | head -1)"
    [[ -n "$NOM_RADIO" ]] \
        || error "falta el código de emparejamiento de esta radio. Genéralo en el core con: sudo emparella-radio <nombre>"
    TMPC="$(mktemp -d)"; trap 'rm -rf "$TMPC"' EXIT
    sed -n '/^-----BEGIN/,/^-----END/{/^-----/d;p}' <<<"$CODI" | base64 -d | tar xzf - -C "$TMPC" \
        || error "el código de emparejamiento está dañado (cópialo entero)"
    for f in ca.crt agent-radio.crt agent-radio.key; do [[ -s "$TMPC/$f" ]] || error "al código le falta $f"; done
    openssl verify -CAfile "$TMPC/ca.crt" -purpose sslclient "$TMPC/agent-radio.crt" >/dev/null 2>&1 \
        || error "el código es antiguo o de otra CA: vuelve a generarlo en el core (sudo emparella-radio $NOM_RADIO)"
    [[ -s "$TMPC/core" ]] || error "el código no lleva la IP del core (es antiguo): vuelve a generarlo en el core (sudo emparella-radio $NOM_RADIO)"
    CORE_ENLLAC="$(tr -d '[:space:]' < "$TMPC/core")"
    [[ "$CORE_ENLLAC" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]] || error "IP del core del código no válida: $CORE_ENLLAC"
    info "código de emparejamiento correcto: radio \"$NOM_RADIO\", llamará al core ${CORE_ENLLAC}"
fi

pas 0 "Datos de la radio"
# --- 0. datos -----------------------------------------------------------------
[[ -n "$CORE_IP" ]] || pregunta "IP del core (AMF, PC1)" CORE_IP "${CORE_ENLLAC%:*}"
[[ -n "$CORE_IP" ]] || pregunta "IP del core (AMF, PC1)" CORE_IP "${CORE_IP_DEFECTE:-192.168.1.100}"
es_ip "$CORE_IP" || error "IP del core no válida: '$CORE_IP'"
if [[ -z "$RADIO_IP" ]]; then
    det="$(ip -4 route get "$CORE_IP" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
    pregunta "IP de este PC (radio, PC2)" RADIO_IP "$det"
fi
es_ip "$RADIO_IP" || error "IP de la radio no válida: '$RADIO_IP'"
ip -4 -o addr show | grep -q " $RADIO_IP/" || error "$RADIO_IP no es una IP de este PC"
info "core $CORE_IP · radio $RADIO_IP · ocudu en $OCUDU"

# --- 1. programas (guía, apartado 2) -------------------------------------------
pas 1 "git, curl y Docker"
falta=()
command -v git  >/dev/null || falta+=(git)
command -v curl >/dev/null || falta+=(curl)
command -v openssl >/dev/null || falta+=(openssl)
command -v python3 >/dev/null || falta+=(python3)
if (( ${#falta[@]} )); then
    apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${falta[@]}" >/dev/null
    info "instalado: ${falta[*]}"
fi
if ! docker compose version >/dev/null 2>&1; then
    gd="$(mktemp)"
    curl -fsSL --retry 3 https://get.docker.com -o "$gd" || error "no se ha podido descargar get.docker.com"
    sh "$gd" >/dev/null || error "no se ha podido instalar Docker"
    rm -f "$gd"
    info "Docker instalado (get.docker.com)"
fi
id -nG "$USUARI" | grep -qw docker || { usermod -aG docker "$USUARI"; info "$USUARI añadido al grupo docker (efectivo al volver a entrar)"; }
info "$(docker --version)"

# --- 2. proyecto (guía, apartado 4.1) --------------------------------------------
pas 2 "Proyecto ocudu"
if [[ -d "$OCUDU/.git" ]]; then
    info "ya clonado en $OCUDU (no se toca el código)"
else
    sudo -u "$USUARI" git clone -q "$OCUDU_REPO" "$OCUDU" || error "no se ha podido clonar $OCUDU_REPO"
    info "clonado en $OCUDU"
fi
[[ -f "$DOCKER_DIR/Dockerfile" ]] || error "no encuentro $DOCKER_DIR/Dockerfile"

# --- 3. docker-compose.yml unificado (guía, apartado 4.2 y Anexo A) ---------------
pas 3 "docker/docker-compose.yml"
C="$DOCKER_DIR/docker-compose.yml"
if [[ -f "$C" && ! -f "$C.orig" ]] && ! grep -q 'container_name: ocudu_gnb' "$C"; then
    cp -a "$C" "$C.orig"; info "original guardado en $C.orig"
elif [[ -f "$C" ]]; then
    cp -a "$C" "$C.$(date +%Y%m%d-%H%M%S).bak"
fi
cat > "$C" <<'YAML'
# SPDX-FileCopyrightText: Copyright (C) 2021-2026 Software Radio Systems Limited
# SPDX-License-Identifier: BSD-3-Clause-Open-MPI
# Generado por install_radio.sh (guía de despliegue, Anexo A): un único servicio, el gNB,
# en modo host y con toda la configuración aquí, parametrizada con el .env.
services:
  gnb:
    container_name: ocudu_gnb
    network_mode: host
    image: ocudu/gnb
    build:
      context: ..
      dockerfile: docker/Dockerfile
      args:
        OS: ${OS:-ubuntu}
        OS_VERSION: ${OS_VERSION:-26.04}
    privileged: true
    cap_add:
      - SYS_NICE
      - CAP_SYS_PTRACE
    volumes:
      - /dev/bus/usb/:/dev/bus/usb/
      - /usr/share/uhd/images:/usr/share/uhd/images
      - gnb-storage:/tmp
    configs:
      - source: gnb_config
        target: /gnb_config.yml
    command: gnb -c /gnb_config.yml
configs:
  gnb_config:
    content: |
      cu_cp:
        amf:
          addrs: ${CORE_IP}
          port: 38412
          bind_addrs: ${RADIO_IP}
          supported_tracking_areas:
            - tac: ${TAC}
              plmn_list:
                - plmn: "${PLMN_1}"
                  tai_slice_support_list:
                    - sst: ${SST}
      ru_sdr:
        device_driver: uhd
        device_args: type=b200,num_recv_frames=64,num_send_frames=64
        srate: ${SRATE}
        otw_format: sc12
        tx_gain: ${TX_GAIN}
        rx_gain: ${RX_GAIN}
      cell_cfg:
        dl_arfcn: ${DL_ARFCN}
        band: ${BAND}
        channel_bandwidth_MHz: ${BANDWIDTH_MHZ}
        common_scs: ${SCS}
        plmn: "${PLMN_1}"
        tac: ${TAC}
        pci: ${PCI}
        nof_antennas_dl: ${RX_ANTENA:-1}
        nof_antennas_ul: ${TX_ANTENA:-1}
      expert_phy:
        pusch_channel_estimator_td_strategy: average
        pusch_channel_estimator_cfo_compensation: true
      metrics:
        autostart_stdout_metrics: true
        enable_json: true
      remote_control:
        # solo local: el WebSocket no tiene contraseña y acepta órdenes (quit, ssb_set...).
        # El agente del panel lee aquí las métricas por móvil desde este mismo PC.
        bind_addr: 127.0.0.1
        enabled: true
      log:
        filename: /tmp/gnb.log
        all_level: warning
        # RRC y NGAP en info: el panel lee qué RNTI tiene cada móvil (métricas por móvil)
        rrc_level: info
        ngap_level: info
      pcap:
        mac_enable: false
        mac_filename: /tmp/gnb_mac.pcap
        ngap_enable: false
        ngap_filename: /tmp/gnb_ngap.pcap
volumes:
  gnb-storage:
YAML
chown "$USUARI": "$C"
info "escrito (un solo servicio gnb, network_mode: host, sin el 5gc integrado ni redes internas)"

# --- 4. .env (guía, apartado 4.3 y Anexo B) ------------------------------------------
pas 4 "docker/.env"
E="$DOCKER_DIR/.env"
[[ -f "$E" ]] || touch "$E"
[[ -f "$E.orig" ]] || cp -a "$E" "$E.orig"
val() {   # val <VAR> <por defecto>: valor actual del .env > variable de entorno > por defecto
    local v; v="$(sed -n "s/^$1=//p" "$E" | tail -1)"
    [[ -n "$v" ]] || { [[ "$1" == PLMN_1 ]] && v="$(sed -n 's/^PLMN=//p' "$E" | tail -1)"; }
    echo "${v:-${!1:-$2}}"
}
declare -A V=(
  [PLMN_1]="$(PLMN_1="${PLMN:-}" val PLMN_1 00101)" [TAC]="$(val TAC 1)" [SST]="$(val SST 1)"
  [TX_GAIN]="$(val TX_GAIN 80)" [RX_GAIN]="$(val RX_GAIN 40)" [DL_ARFCN]="$(val DL_ARFCN 470000)"
  [BAND]="$(val BAND 40)" [BANDWIDTH_MHZ]="$(val BANDWIDTH_MHZ 20)" [SCS]="$(val SCS 30)"
  [SRATE]="$(val SRATE 23.04)" [PCI]="$(val PCI 1)" [TX_ANTENA]="$(val TX_ANTENA 1)" [RX_ANTENA]="$(val RX_ANTENA 1)"
)
[[ "${V[PLMN_1]}" =~ ^[0-9]{5,6}$ ]] || error "PLMN no válido: ${V[PLMN_1]}"
TMPE="$(mktemp)"
cat > "$TMPE" <<ENV
# ==========================================
# CONFIGURACIÓN DE RED (MÁQUINAS VIRTUALES)
# ==========================================
# IP de la máquina donde se ejecuta Open5GS (PC1)
CORE_IP=$CORE_IP
# IP de esta misma máquina donde se ejecuta el gNB (PC2)
RADIO_IP=$RADIO_IP
# ==========================================
# IDENTIFICADORES DE RED 5G (CORE)
# ==========================================
# PLMN = MCC + MNC del core (docker_open5gs/.env)
PLMN_1=${V[PLMN_1]}
TAC=${V[TAC]}
SST=${V[SST]}
# ==========================================
# PARÁMETROS DE RADIOFRECUENCIA (ETTUS B210)
# ==========================================
# Ganancias de transmisión y recepción
TX_GAIN=${V[TX_GAIN]}
RX_GAIN=${V[RX_GAIN]}
# Frecuencia (ARFCN) y banda (470000 = 2350 MHz, centro de la banda 40)
DL_ARFCN=${V[DL_ARFCN]}
BAND=${V[BAND]}
# Ancho de banda y espaciado de subportadora
BANDWIDTH_MHZ=${V[BANDWIDTH_MHZ]}
SCS=${V[SCS]}
# Tasa de muestreo para el ancho de banda
SRATE=${V[SRATE]}
# Identificador físico de celda
PCI=${V[PCI]}
# Antenas (1 = SISO; 2 = MIMO 2x2, como mucho 20 MHz con la B210)
RX_ANTENA=${V[RX_ANTENA]}
TX_ANTENA=${V[TX_ANTENA]}
# ==========================================
ENV
# el resto del .env (métricas, Telegraf, Grafana...) se conserva tal cual, sin las claves de aquí arriba
CLAUS='^(CORE_IP|RADIO_IP|PLMN|PLMN_1|TAC|SST|TX_GAIN|RX_GAIN|DL_ARFCN|BAND|BANDWIDTH_MHZ|SCS|SRATE|PCI|RX_ANTENA|TX_ANTENA)='
awk -v c="$CLAUS" '
  /^# =+$/ || /^# (CONFIGURACI(Ó|O) DE (XARXA|RED)|IDENTIFICADOR(S|ES) DE (XARXA|RED)|PAR(À|Á)METROS? DE RADIOFREQ|PARÁMETROS DE RADIOFRECUENCIA|IP de la m(à|á)quina|IP d.aquesta mateixa|IP de esta misma|PLMN = MCC|Guanys de transmissió|Ganancias de transmisión|Freqüència \(ARFCN\)|Frecuencia \(ARFCN\)|Ample de banda i espaiat|Ancho de banda y espaciado|Taxa de mostreig|Tasa de muestreo|Identificador [Ff](í|i)sic|Antenes \(|Antenas \()/ { next }
  $0 ~ c { next }
  { print }' "$E" >> "$TMPE"
cat "$TMPE" > "$E"; rm -f "$TMPE"
chown "$USUARI": "$E"
info "CORE_IP=$CORE_IP RADIO_IP=$RADIO_IP PLMN_1=${V[PLMN_1]} TAC=${V[TAC]} ARFCN=${V[DL_ARFCN]} n${V[BAND]} ${V[BANDWIDTH_MHZ]} MHz"
info "comprueba que el PLMN y el TAC son los del core (MCC+MNC y TAC de docker_open5gs/.env)"

# --- 5. imágenes de la FPGA de la B210 (guía, apartado 4.5) -------------------------------
pas 5 "Imágenes UHD del USRP"
if compgen -G "/usr/share/uhd/images/usrp_b2*_fpga.bin" >/dev/null; then
    info "ya están (/usr/share/uhd/images)"
else
    command -v uhd_images_downloader >/dev/null \
        || { apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq uhd-host >/dev/null; }
    mkdir -p /usr/share/uhd/images
    uhd_images_downloader -t b2xx -i /usr/share/uhd/images >/dev/null \
        && info "descargadas en /usr/share/uhd/images" \
        || avis "no se han podido descargar: ejecuta 'sudo uhd_images_downloader -t b2xx' antes de arrancar el gNB"
fi

# --- 6. imagen y arranque (guía, apartados 4.4 y 4.5) ----------------------------------
if (( AMB_BUILD )); then
    pas 6 "Construcción de la imagen del gNB (la parte lenta: ~40 min la primera vez)"
    info "el mensaje 'pull access denied for ocudu/gnb' es normal: la imagen se construye aquí"
    (cd "$OCUDU" && docker compose -f docker/docker-compose.yml build) || error "la construcción de la imagen ha fallado"
    pas 7 "Arranque del gNB"
    (cd "$OCUDU" && docker compose -f docker/docker-compose.yml up -d) || error "no se ha podido arrancar el gNB"
    info "en marcha: docker logs -f ocudu_gnb"
else
    info "sin construir ni arrancar (--sin-build): cd $OCUDU && sudo docker compose -f docker/docker-compose.yml build && sudo docker compose -f docker/docker-compose.yml up -d"
fi

# --- 8. agente del panel -------------------------------------------------------------
if (( AGENT_JA )); then
    pas 8 "Agente del panel (agent5g)"
    info "ya instalado: no se toca ($(systemctl is-active agent5g 2>/dev/null || true); llama al core ${CORE_ENLLAC:-?})"
fi
install -d -m 755 /opt/agent5g; install -m 755 "$SRC/scripts/agent5g_menu.sh" /opt/agent5g/agent5g_menu.sh; ln -sf /opt/agent5g/agent5g_menu.sh /usr/local/sbin/agent5g   # menú: sudo agent5g
git -C "$SRC" log -1 --format='%h · %cd (instalación)' --date=format:'%Y-%m-%d %H:%M' > /opt/agent5g/VERSIO 2>/dev/null || true
if (( AMB_AGENT )); then
    pas 8 "Agente del panel (agent5g)"
    install -d -m 755 /opt/agent5g
    install -m 755 "$SRC/agent/agent5g.py" /opt/agent5g/agent5g.py
    install -d -m 700 /etc/agent5g /etc/agent5g/certs /var/lib/agent5g
    install -m 600 "$TMPC/ca.crt" "$TMPC/agent-radio.crt" "$TMPC/agent-radio.key" /etc/agent5g/certs/
    rm -rf "$DESAT"                      # el emparejamiento guardado ya está en /etc/agent5g
    PROJ="$DOCKER_DIR" NOM="$NOM_RADIO" CORE="$CORE_ENLLAC" python3 - <<'PY'
import json, os
f = '/etc/agent5g/agent5g.json'
old = {}
if os.path.isfile(f):
    with open(f) as fh:
        old = json.load(fh)
ip = r'^([0-9]{1,3}\.){3}[0-9]{1,3}$'
cfg = {
    'role': 'radio', 'name': old.get('name', f"Radio {os.environ['NOM']}"),
    # la radio llama al core (enlace radio -> core): no escucha ningún puerto y le da igual su IP
    'listen': None, 'core': os.environ['CORE'].rsplit(':', 1)[0],
    'core_port': int(os.environ['CORE'].rsplit(':', 1)[1]),
    'cert': '/etc/agent5g/certs/agent-radio.crt', 'key': '/etc/agent5g/certs/agent-radio.key',
    'ca': '/etc/agent5g/certs/ca.crt', 'allowed_client_cn': ['panel5g'],
    'project_dir': os.environ['PROJ'], 'env_file': '.env',
    'compose_files': ['docker-compose.yml'], 'compose_project': 'docker',
    'editable_keys': {
        'CORE_IP': ip, 'RADIO_IP': ip,
        'DL_ARFCN': '^[0-9]{5,7}$', 'BAND': '^[0-9]{1,3}$',
        'BANDWIDTH_MHZ': '^(5|10|15|20|25|30|40|50|60|80|100)$', 'SCS': '^(15|30|60)$',
        'SRATE': '^[0-9]{1,3}(\\.[0-9]{1,2})?$', 'TX_GAIN': '^[0-9]{1,2}$', 'RX_GAIN': '^[0-9]{1,2}$',
        'PCI': '^[0-9]{1,4}$', 'TX_ANTENA': '^(1|2)$', 'RX_ANTENA': '^(1|2)$',
        'PLMN_1': '^[0-9]{5,6}$', 'TAC': '^[0-9]{1,8}$'},
    'local_ip_keys': ['RADIO_IP'],
    'containers': ['ocudu_gnb'], 'services': ['gnb'],
    'log_files': {'gnb.log': '/var/lib/docker/volumes/docker_gnb-storage/_data/gnb.log'},
    'backup_dir': '/var/lib/agent5g/backups', 'audit_log': '/var/lib/agent5g/audit.log',
    'docker_bin': '/usr/bin/docker', 'max_log_lines': 2000, 'max_backups': 50, 'apply_timeout': 300,
    'tdd': True,
}
with open(f + '.nou', 'w') as fh:
    json.dump(cfg, fh, indent=2, ensure_ascii=False)
os.chmod(f + '.nou', 0o600)
os.replace(f + '.nou', f)
PY
    install -m 644 "$SRC/agent/agent5g.service" /etc/systemd/system/agent5g.service
    install -d /etc/systemd/system/agent5g.service.d
    printf '[Service]\nReadWritePaths=%s\n' "$DOCKER_DIR" > /etc/systemd/system/agent5g.service.d/projecte.conf
    systemctl daemon-reload
    systemctl enable agent5g >/dev/null 2>&1
    systemctl restart agent5g
    sleep 4
    if systemctl is-active -q agent5g; then
        info "agent5g activo (arranca solo al encender y se reinicia siempre): llama al core $CORE_ENLLAC"
        info "certificados de esta radio: /etc/agent5g/certs/ (ca.crt, agent-radio.crt, agent-radio.key)"
        info "configuración del agente:   /etc/agent5g/agent5g.json   ·  registro: journalctl -u agent5g"
        if journalctl -u agent5g --since "-20s" --no-pager 2>/dev/null | grep -q "connectat al core"; then
            info "conectado al core: la radio \"$NOM_RADIO\" ya aparece en el panel"
        else
            avis "todavía no ha conectado con el core $CORE_ENLLAC (lo reintenta solo). Mira: journalctl -u agent5g -n 20"
        fi
    else
        avis "agent5g no ha arrancado: journalctl -u agent5g -n 30"
    fi
fi

echo
echo "==> Hecho. Radio $RADIO_IP conectada al core $CORE_IP."
echo "    Log del gNB:   docker logs -f ocudu_gnb   (tiene que decir 'Connection to AMF ... completed')"
echo "    Configuración: $DOCKER_DIR/.env  (o desde el panel, Parámetros)"
