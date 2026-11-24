#!/usr/bin/env bash
# ============================================================================
# install_radio.sh - instal·la la part ràdio (PC2) tal com la descriu la guia de
# desplegament (apartats 2 i 4): Docker, ocudu, docker-compose.yml i .env unificats,
# imatge del gNodeB i arrencada; i, a més, l'agent del panell (agent5g) com a servei
# que s'inicia sol i es reinicia sempre.
#
# Ús:
#   sudo ./install_radio.sh                       (pregunta el que falti)
#   sudo ./install_radio.sh --emparellament codi.txt --core 192.168.1.100
#
# Opcions:
#   --core IP            IP del core (AMF). Obligatòria (es pregunta si no hi és)
#   --radio IP           IP d'aquest PC (per defecte, la de la ruta cap al core)
#   --emparellament F    fitxer amb el codi d'emparellament (sudo emparella-radio <IP> al core);
#                        sense aquesta opció es demana que l'enganxis
#   --ocudu DIR          on es clona ocudu (per defecte ~/ocudu de l'usuari)
#   --sense-build        no construir la imatge ni arrencar el gNB (només configurar + agent)
#   --sense-agent        no instal·lar l'agent del panell
#
# Paràmetres de la cel·la (variables d'entorn; per defecte, els de la guia, Annex B):
#   PLMN=00101 TAC=1 SST=1 TX_GAIN=80 RX_GAIN=40 DL_ARFCN=470000 BAND=40
#   BANDWIDTH_MHZ=20 SCS=30 SRATE=23.04 PCI=1 TX_ANTENA=1 RX_ANTENA=1
#   Si el .env ja els té, es conserven els valors actuals.
#
# Diferències amb la guia (perquè el panell pugui gestionar la ràdio):
#   * el PLMN es diu PLMN_1 al .env (el panell hi afegeix PLMN_2 per al segon PLMN);
#   * nombre d'antenes parametritzat (RX_ANTENA/TX_ANTENA, per defecte 1 = com a la guia);
#   * el gNB s'arrenca en segon pla (-d): el log és a "docker logs -f ocudu_gnb".
# ============================================================================
set -euo pipefail
OCUDU_REPO="${OCUDU_REPO:-https://gitlab.com/ocudu/ocudu.git}"
PORT_AGENT=9543
CORE_IP=""; RADIO_IP=""; EMPAR=""; OCUDU=""; AMB_BUILD=1; AMB_AGENT=1

pas()   { echo; echo "==> [$1] $2"; }
info()  { echo "    $*"; }
avis()  { echo "    AVÍS: $*"; }
error() { echo "ERROR: $*" >&2; exit 1; }
es_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --core)          CORE_IP="${2:?}"; shift ;;
        --radio)         RADIO_IP="${2:?}"; shift ;;
        --emparellament) EMPAR="$(realpath "${2:?}")"; shift ;;
        --ocudu)         OCUDU="${2:?}"; shift ;;
        --sense-build)   AMB_BUILD=0 ;;
        --sense-agent)   AMB_AGENT=0 ;;
        -h|--help)       sed -n '3,/^# =====/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)               error "opció desconeguda: $1" ;;
    esac
    shift
done
[[ $EUID -eq 0 ]] || error "cal ser root: sudo $0"
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
USUARI="${SUDO_USER:-$(id -un)}"
HOME_USUARI="$(getent passwd "$USUARI" | cut -d: -f6)"
OCUDU="${OCUDU:-$HOME_USUARI/ocudu}"
DOCKER_DIR="$OCUDU/docker"

pregunta() {   # pregunta <text> <variable> [per defecte]
    local txt="$1" var="$2" def="${3:-}" r
    [[ -t 0 ]] || { printf -v "$var" '%s' "$def"; return; }
    read -r -p "    $txt${def:+ [$def]}: " r || true
    printf -v "$var" '%s' "${r:-$def}"
}

# --- 0. dades -----------------------------------------------------------------
pas 0 "Dades de la ràdio"
[[ -n "$CORE_IP" ]] || pregunta "IP del core (AMF, PC1)" CORE_IP "${CORE_IP_DEFECTE:-192.168.1.100}"
es_ip "$CORE_IP" || error "IP del core invàlida: '$CORE_IP'"
if [[ -z "$RADIO_IP" ]]; then
    det="$(ip -4 route get "$CORE_IP" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
    pregunta "IP d'aquest PC (ràdio, PC2)" RADIO_IP "$det"
fi
es_ip "$RADIO_IP" || error "IP de la ràdio invàlida: '$RADIO_IP'"
ip -4 -o addr show | grep -q " $RADIO_IP/" || error "$RADIO_IP no és una IP d'aquest PC"
info "core $CORE_IP · ràdio $RADIO_IP · ocudu a $OCUDU"

# codi d'emparellament (abans de la part lenta, per no haver d'esperar-se 40 minuts)
CODI=""
if (( AMB_AGENT )); then
    if [[ -n "$EMPAR" ]]; then
        CODI="$(cat "$EMPAR")"
    elif [[ -t 0 ]]; then
        echo "    Al core, executa:  sudo emparella-radio $RADIO_IP"
        echo "    i enganxa aquí el codi (de la línia BEGIN a la línia END):"
        while IFS= read -r l; do
            CODI+="$l"$'\n'
            [[ "$l" == "-----END 5GPANEL EMPARELLAMENT-----" ]] && break
        done
    fi
    grep -q "^-----BEGIN 5GPANEL EMPARELLAMENT $RADIO_IP-----" <<<"$CODI" \
        || error "falta el codi d'emparellament d'aquesta ràdio ($RADIO_IP). Genera'l al core amb: sudo emparella-radio $RADIO_IP"
    TMPC="$(mktemp -d)"; trap 'rm -rf "$TMPC"' EXIT
    sed -n '/^-----BEGIN/,/^-----END/{/^-----/d;p}' <<<"$CODI" | base64 -d | tar xzf - -C "$TMPC" \
        || error "el codi d'emparellament està malmès (copia'l sencer)"
    for f in ca.crt agent-radio.crt agent-radio.key; do [[ -s "$TMPC/$f" ]] || error "al codi hi falta $f"; done
    openssl verify -CAfile "$TMPC/ca.crt" "$TMPC/agent-radio.crt" >/dev/null 2>&1 \
        || error "el certificat de la ràdio no és de la CA del codi"
    openssl x509 -in "$TMPC/agent-radio.crt" -noout -ext subjectAltName 2>/dev/null | grep -qE "IP Address:${RADIO_IP//./\\.}(,|\$)" \
        || error "el certificat no és per a $RADIO_IP: genera'l al core per a aquesta IP"
    info "codi d'emparellament correcte"
fi

# --- 1. programari (guia, apartat 2) -------------------------------------------
pas 1 "git, curl i Docker"
falta=()
command -v git  >/dev/null || falta+=(git)
command -v curl >/dev/null || falta+=(curl)
command -v openssl >/dev/null || falta+=(openssl)
command -v python3 >/dev/null || falta+=(python3)
if (( ${#falta[@]} )); then
    apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${falta[@]}" >/dev/null
    info "instal·lat: ${falta[*]}"
fi
if ! docker compose version >/dev/null 2>&1; then
    gd="$(mktemp)"
    curl -fsSL --retry 3 https://get.docker.com -o "$gd" || error "no s'ha pogut descarregar get.docker.com"
    sh "$gd" >/dev/null || error "no s'ha pogut instal·lar Docker"
    rm -f "$gd"
    info "Docker instal·lat (get.docker.com)"
fi
id -nG "$USUARI" | grep -qw docker || { usermod -aG docker "$USUARI"; info "$USUARI afegit al grup docker (efectiu en tornar a entrar)"; }
info "$(docker --version)"

# --- 2. projecte (guia, apartat 4.1) --------------------------------------------
pas 2 "Projecte ocudu"
if [[ -d "$OCUDU/.git" ]]; then
    info "ja clonat a $OCUDU (no es toca el codi)"
else
    sudo -u "$USUARI" git clone -q "$OCUDU_REPO" "$OCUDU" || error "no s'ha pogut clonar $OCUDU_REPO"
    info "clonat a $OCUDU"
fi
[[ -f "$DOCKER_DIR/Dockerfile" ]] || error "no trobo $DOCKER_DIR/Dockerfile"

# --- 3. docker-compose.yml unificat (guia, apartat 4.2 i Annex A) ---------------
pas 3 "docker/docker-compose.yml"
C="$DOCKER_DIR/docker-compose.yml"
if [[ -f "$C" && ! -f "$C.orig" ]] && ! grep -q 'container_name: ocudu_gnb' "$C"; then
    cp -a "$C" "$C.orig"; info "original desat a $C.orig"
elif [[ -f "$C" ]]; then
    cp -a "$C" "$C.$(date +%Y%m%d-%H%M%S).bak"
fi
cat > "$C" <<'YAML'
# SPDX-FileCopyrightText: Copyright (C) 2021-2026 Software Radio Systems Limited
# SPDX-License-Identifier: BSD-3-Clause-Open-MPI
# Generat per install_radio.sh (guia de desplegament, Annex A): un únic servei, el gNB,
# en mode host i amb tota la configuració aquí, parametritzada amb el .env.
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
        bind_addr: 0.0.0.0
        enabled: true
      log:
        filename: /tmp/gnb.log
        all_level: warning
      pcap:
        mac_enable: false
        mac_filename: /tmp/gnb_mac.pcap
        ngap_enable: false
        ngap_filename: /tmp/gnb_ngap.pcap
volumes:
  gnb-storage:
YAML
chown "$USUARI": "$C"
info "escrit (un sol servei gnb, network_mode: host, sense el 5gc integrat ni xarxes internes)"

# --- 4. .env (guia, apartat 4.3 i Annex B) ------------------------------------------
pas 4 "docker/.env"
E="$DOCKER_DIR/.env"
[[ -f "$E" ]] || touch "$E"
[[ -f "$E.orig" ]] || cp -a "$E" "$E.orig"
val() {   # val <VAR> <per defecte>: valor actual del .env > variable d'entorn > per defecte
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
[[ "${V[PLMN_1]}" =~ ^[0-9]{5,6}$ ]] || error "PLMN invàlid: ${V[PLMN_1]}"
TMPE="$(mktemp)"
cat > "$TMPE" <<ENV
# ==========================================
# CONFIGURACIÓ DE XARXA (MÀQUINES VIRTUALS)
# ==========================================
# IP de la màquina on s'executa Open5GS (PC1)
CORE_IP=$CORE_IP
# IP d'aquesta mateixa màquina on s'executa el gNB (PC2)
RADIO_IP=$RADIO_IP
# ==========================================
# IDENTIFICADORS DE XARXA 5G (CORE)
# ==========================================
# PLMN = MCC + MNC del core (docker_open5gs/.env)
PLMN_1=${V[PLMN_1]}
TAC=${V[TAC]}
SST=${V[SST]}
# ==========================================
# PARÀMETRES DE RADIOFREQÜÈNCIA (ETTUS B210)
# ==========================================
# Guanys de transmissió i recepció
TX_GAIN=${V[TX_GAIN]}
RX_GAIN=${V[RX_GAIN]}
# Freqüència (ARFCN) i banda (470000 = 2350 MHz, centre de la banda 40)
DL_ARFCN=${V[DL_ARFCN]}
BAND=${V[BAND]}
# Ample de banda i espaiat de subportadora
BANDWIDTH_MHZ=${V[BANDWIDTH_MHZ]}
SCS=${V[SCS]}
# Taxa de mostreig per a l'ample de banda
SRATE=${V[SRATE]}
# Identificador físic de cel·la
PCI=${V[PCI]}
# Antenes (1 = SISO; 2 = MIMO 2x2, com a molt 20 MHz amb la B210)
RX_ANTENA=${V[RX_ANTENA]}
TX_ANTENA=${V[TX_ANTENA]}
# ==========================================
ENV
# la resta del .env (mètriques, Telegraf, Grafana...) es conserva tal qual, sense les claus d'aquí dalt
CLAUS='^(CORE_IP|RADIO_IP|PLMN|PLMN_1|TAC|SST|TX_GAIN|RX_GAIN|DL_ARFCN|BAND|BANDWIDTH_MHZ|SCS|SRATE|PCI|RX_ANTENA|TX_ANTENA)='
awk -v c="$CLAUS" '
  /^# =+$/ || /^# (CONFIGURACIÓ DE XARXA|IDENTIFICADORS DE XARXA|PARÀMETRES DE RADIOFREQ|IP de la màquina|IP d.aquesta mateixa|PLMN = MCC|Guanys de transmissió|Freqüència \(ARFCN\)|Ample de banda i espaiat|Taxa de mostreig|Identificador [Ff]ísic|Antenes \()/ { next }
  $0 ~ c { next }
  { print }' "$E" >> "$TMPE"
cat "$TMPE" > "$E"; rm -f "$TMPE"
chown "$USUARI": "$E"
info "CORE_IP=$CORE_IP RADIO_IP=$RADIO_IP PLMN_1=${V[PLMN_1]} TAC=${V[TAC]} ARFCN=${V[DL_ARFCN]} n${V[BAND]} ${V[BANDWIDTH_MHZ]} MHz"
info "comprova que el PLMN i el TAC són els del core (MCC+MNC i TAC de docker_open5gs/.env)"

# --- 5. imatges de la FPGA de la B210 (guia, apartat 4.5) -------------------------------
pas 5 "Imatges UHD de l'USRP"
if compgen -G "/usr/share/uhd/images/usrp_b2*_fpga.bin" >/dev/null; then
    info "ja hi són (/usr/share/uhd/images)"
else
    command -v uhd_images_downloader >/dev/null \
        || { apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq uhd-host >/dev/null; }
    mkdir -p /usr/share/uhd/images
    uhd_images_downloader -t b2xx -i /usr/share/uhd/images >/dev/null \
        && info "descarregades a /usr/share/uhd/images" \
        || avis "no s'han pogut descarregar: executa 'sudo uhd_images_downloader -t b2xx' abans d'arrencar el gNB"
fi

# --- 6. imatge i arrencada (guia, apartats 4.4 i 4.5) ----------------------------------
if (( AMB_BUILD )); then
    pas 6 "Construcció de la imatge del gNB (la part lenta: ~40 min la primera vegada)"
    info "el missatge 'pull access denied for ocudu/gnb' és normal: la imatge es construeix aquí"
    (cd "$OCUDU" && docker compose -f docker/docker-compose.yml build) || error "la construcció de la imatge ha fallat"
    pas 7 "Arrencada del gNB"
    (cd "$OCUDU" && docker compose -f docker/docker-compose.yml up -d) || error "no s'ha pogut arrencar el gNB"
    info "en marxa: docker logs -f ocudu_gnb"
else
    info "sense construir ni arrencar (--sense-build): cd $OCUDU && sudo docker compose -f docker/docker-compose.yml build && sudo docker compose -f docker/docker-compose.yml up -d"
fi

# --- 8. agent del panell -------------------------------------------------------------
if (( AMB_AGENT )); then
    pas 8 "Agent del panell (agent5g)"
    install -d -m 755 /opt/agent5g
    install -m 755 "$SRC/agent/agent5g.py" /opt/agent5g/agent5g.py
    install -d -m 700 /etc/agent5g /etc/agent5g/certs /var/lib/agent5g
    install -m 600 "$TMPC/ca.crt" "$TMPC/agent-radio.crt" "$TMPC/agent-radio.key" /etc/agent5g/certs/
    PROJ="$DOCKER_DIR" RIP="$RADIO_IP" PORT="$PORT_AGENT" python3 - <<'PY'
import json, os
f = '/etc/agent5g/agent5g.json'
old = {}
if os.path.isfile(f):
    with open(f) as fh:
        old = json.load(fh)
ip = r'^([0-9]{1,3}\.){3}[0-9]{1,3}$'
cfg = {
    'role': 'radio', 'name': old.get('name', f"Ràdio {os.environ['RIP']}"),
    'listen': 'auto', 'port': int(os.environ['PORT']),   # segueix la IP de la LAN encara que canviï
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
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
        XARXA="$(python3 -c "import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1] + '/24', strict=False))" "$RADIO_IP")"
        avis "ufw està actiu i no el toco: perquè el panell arribi a l'agent, obre el port amb"
        avis "  sudo ufw allow from $XARXA to any port $PORT_AGENT proto tcp comment agent5g"
    fi
    sleep 2
    if systemctl is-active -q agent5g; then
        info "agent5g actiu a https://$RADIO_IP:$PORT_AGENT (s'inicia sol en arrencar i es reinicia sempre)"
        info "el panell el trobarà sol en la següent cerca (cada 2 min)"
    else
        avis "agent5g no ha arrencat: journalctl -u agent5g -n 30"
    fi
fi

echo
echo "==> Fet. Ràdio $RADIO_IP connectada al core $CORE_IP."
echo "    Log del gNB:   docker logs -f ocudu_gnb   (ha de dir 'Connection to AMF ... completed')"
echo "    Configuració:  $DOCKER_DIR/.env  (o des del panell, Paràmetres)"
