#!/usr/bin/env bash
# Instal·la NOMÉS l'agent del core (la crida core5g.sh), sense preguntes:
#   agent5g (mTLS al port 9543 per al panell i al 9544 per a les ràdios, que hi truquen soles)
#   + captura NGAP/SBI + model del mòbil (User-Agent),
#   tots tres com a serveis systemd que es reinicien sempre (també després d'un reinici
#   del PC, de Docker o del panell).
# Al final imprimeix el CODI D'EMPARELLAMENT de cada ràdio (CORE5G_RADIOS="aula1 aula2" o,
# si hi ha terminal, ho pregunta). Més endavant: sudo emparella-radio <nom>.
# La IP del core (IP_LAN) és l'única que ha de ser fixa: les ràdios hi truquen.
#
#   sudo ./install_core.sh <carpeta_docker_open5gs> <fitxer_compose> <IP_LAN> [carpeta_certs]
#
# carpeta_certs (per defecte /root/certs-5g): si no hi ha CA, se'n crea una (gen_certs.sh --core).
# Hi queden també els certificats del panell (panel/), per quan s'instal·li.
# Tornar-lo a executar és segur: no canvia els certificats existents.
set -euo pipefail
PROJ=${1:?carpeta del projecte docker_open5gs}
COMPOSE=${2:?fitxer compose (sa-deploy.yaml o sa-vonr-deploy.yaml)}
IP=${3:?IP LAN del core}
CERTS=${4:-/root/certs-5g}
[[ $EUID -eq 0 ]] || { echo "Executa amb sudo"; exit 1; }
SRC=$(cd "$(dirname "$0")/.." && pwd)
PORT=9543
[[ -f "$PROJ/.env" && -f "$PROJ/$COMPOSE" ]] || { echo "No trobo $PROJ/.env o $PROJ/$COMPOSE"; exit 1; }
[[ $IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "IP invàlida: $IP"; exit 1; }
info() { echo "    $*"; }

# ---- 1. certificats
if [[ ! -f "$CERTS/ca/ca.crt" ]]; then
  ( umask 077; bash "$SRC/scripts/gen_certs.sh" --core "$IP" "$CERTS" >/dev/null )
  info "certificats nous a $CERTS (CA pròpia)"
else
  info "certificats existents a $CERTS"
fi
[[ -f "$CERTS/agent-core/agent-core.crt" ]] \
  || { echo "A $CERTS falta agent-core/: torna a generar-los amb gen_certs.sh --core $IP $CERTS"; exit 1; }

# ---- 2. paquets (tshark sense preguntes: sense captura per a usuaris no root)
if ! command -v tshark >/dev/null || ! command -v dumpcap >/dev/null; then
  echo "wireshark-common wireshark-common/install-setuid boolean false" | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tshark >/dev/null
  info "tshark instal·lat"
fi
command -v python3 >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 >/dev/null

# ---- 3. agent
install -d -m 755 /opt/agent5g
install -m 755 "$SRC/agent/agent5g.py" "$SRC/agent/ua_capture.py" /opt/agent5g/
install -d -m 700 /etc/agent5g /etc/agent5g/certs /var/lib/agent5g
install -m 600 "$CERTS/agent-core/ca.crt" "$CERTS/agent-core/agent-core.crt" "$CERTS/agent-core/agent-core.key" /etc/agent5g/certs/
# Configuració generada a partir del compose real: tots els seus contenidors es poden
# veure; es poden recrear tots menys mongo/mysql (les bases de dades no es toquen).
SERVEIS=$(cd "$PROJ" && docker compose -f "$COMPOSE" config --services 2>/dev/null | sort -u | tr '\n' ' ')
[[ -n $SERVEIS ]] || { echo "docker compose config ha fallat a $PROJ/$COMPOSE"; exit 1; }
PROJ="$PROJ" COMPOSE="$COMPOSE" SERVEIS="$SERVEIS" python3 - <<'PY'
import json, os
f = '/etc/agent5g/agent5g.json'
old = {}
if os.path.isfile(f):
    with open(f) as fh:
        old = json.load(fh)
serveis = os.environ['SERVEIS'].split()
ims = {'dns', 'mysql', 'rtpengine', 'pyhss', 'icscf', 'scscf', 'pcscf', 'smsc'}
nucli = [s for s in serveis if s not in ims]          # els IMS els gestiona el bloc "voip"
cfg = {
    'role': 'core', 'name': old.get('name', 'Core 5G'),
    'listen': '0.0.0.0', 'port': 9543,
    # les ràdios truquen al core (enllaç ràdio -> core): al core li és igual la IP de la ràdio
    'enllac': old.get('enllac') or {'listen': '0.0.0.0', 'port': 9544},
    'cert': '/etc/agent5g/certs/agent-core.crt', 'key': '/etc/agent5g/certs/agent-core.key',
    'ca': '/etc/agent5g/certs/ca.crt', 'allowed_client_cn': ['panel5g'],
    'project_dir': os.environ['PROJ'], 'env_file': '.env',
    'compose_files': [os.environ['COMPOSE']], 'compose_project': None,
    'editable_keys': old.get('editable_keys') or {
        'MCC': '^[0-9]{3}$', 'MNC': '^[0-9]{2,3}$',
        'DOCKER_HOST_IP': '^([0-9]{1,3}\\.){3}[0-9]{1,3}$',
        'UPF_ADVERTISE_IP': '^([0-9]{1,3}\\.){3}[0-9]{1,3}$'},
    'containers': nucli,
    'services': [s for s in nucli if s not in ('mongo',)],
    'log_files': {}, 'backup_dir': '/var/lib/agent5g/backups', 'audit_log': '/var/lib/agent5g/audit.log',
    'docker_bin': '/usr/bin/docker', 'max_log_lines': 2000, 'max_backups': 50, 'apply_timeout': 300,
    'ue_capture': {'dir': '/var/lib/agent5g/ngap'},
    'voip': {'permes': True, 'compose_file': 'sa-vonr-deploy.yaml'},
}
for k in ('pyhss', 'project_actions'):          # personalitzacions que es conserven
    if k in old:
        cfg[k] = old[k]
with open(f + '.nou', 'w') as fh:
    json.dump(cfg, fh, indent=2, ensure_ascii=False)
os.chmod(f + '.nou', 0o600)
os.replace(f + '.nou', f)
PY
info "agent: /etc/agent5g/agent5g.json ($(wc -w <<<"$SERVEIS") serveis a $COMPOSE)"
install -m 644 "$SRC/agent/agent5g.service" "$SRC/agent/ngap-capture.service" "$SRC/agent/ua-capture.service" /etc/systemd/system/
install -d /etc/systemd/system/agent5g.service.d
printf '[Service]\nReadWritePaths=%s\n' "$PROJ" > /etc/systemd/system/agent5g.service.d/projecte.conf
systemctl daemon-reload
systemctl enable --now ngap-capture ua-capture agent5g >/dev/null 2>&1
systemctl restart ngap-capture ua-capture agent5g

# ---- 4. eines d'emparellament (emparella-radio <nom>); la IP del core va dins del codi
printf '%s\n' "$IP" > /etc/agent5g/core_ip
install -d -m 755 /opt/agent5g/eines
install -m 755 "$SRC/scripts/gen_certs.sh" "$SRC/scripts/emparella_radio.sh" /opt/agent5g/eines/
ln -sf /opt/agent5g/eines/emparella_radio.sh /usr/local/sbin/emparella-radio
# perquè emparella-radio trobi els certificats encara que no siguin a /root/certs-5g
sed -i "s#^CERTS=\${2:-/root/certs-5g}#CERTS=\${2:-$CERTS}#" /opt/agent5g/eines/emparella_radio.sh

sleep 3
for s in agent5g ngap-capture ua-capture; do
  systemctl is-active -q "$s" && info "$s: actiu (s'inicia sol en arrencar i es reinicia sempre)" \
    || echo "    AVÍS: $s no està actiu (journalctl -u $s)"
done
info "certificats del panell (per quan l'instal·lis): $CERTS/panel"
info "$CERTS/ca/ca.key és la clau de la CA: no la copiïs enlloc (emparella-radio la necessita aquí)"

# ---- 5. codi d'emparellament de les ràdios
RADIOS=${CORE5G_RADIOS:-}
if [[ -z $RADIOS && -t 0 ]]; then
  read -r -p "    Nom de la ràdio (o ràdios, separats per espais; p. ex. aula1) a emparellar ara [buit = més tard]: " RADIOS || RADIOS=""
fi
for R in $RADIOS; do
  /usr/local/sbin/emparella-radio "$R" "$CERTS" || echo "    AVÍS: no s'ha pogut emparellar $R"
done
[[ -n $RADIOS ]] || info "per emparellar una ràdio més endavant: sudo emparella-radio <nom> (p. ex. aula1)"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
  info "AVÍS: ufw és actiu i no el toco. Perquè les ràdios hi puguin trucar: sudo ufw allow 9544/tcp comment agent5g-radios"
fi
