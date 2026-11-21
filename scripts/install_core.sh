#!/usr/bin/env bash
# Instal·lació completa al PC del core, sense preguntes (la crida core5g.sh):
#   agent5g (mTLS, 172.17.0.1:9543) + captura NGAP/SBI + model del mòbil (User-Agent)
#   + panell web (https://<IP>:8443) amb cerca automàtica de ràdios.
#
#   sudo ./install_core.sh <carpeta_docker_open5gs> <fitxer_compose> <IP_LAN> [carpeta_certs]
#
# carpeta_certs (per defecte /root/certs-5g): si no hi ha CA, se'n crea una amb
# gen_certs.sh --core. Les ràdios s'afegeixen després amb gen_certs.sh --radio <IP>.
# Tornar-lo a executar és segur: no canvia certificats, contrasenya ni panel.yaml
# existents; només actualitza el codi i la configuració de l'agent.
set -euo pipefail
PROJ=${1:?carpeta del projecte docker_open5gs}
COMPOSE=${2:?fitxer compose (sa-deploy.yaml o sa-vonr-deploy.yaml)}
IP=${3:?IP LAN del core}
CERTS=${4:-/root/certs-5g}
[[ $EUID -eq 0 ]] || { echo "Executa amb sudo"; exit 1; }
SRC=$(cd "$(dirname "$0")/.." && pwd)
PANEL_DIR=${PANEL_DIR:-/opt/panel5g/panel}
PORT=9543
DOCKER_BRIDGE=172.17.0.1
[[ -f "$PROJ/.env" && -f "$PROJ/$COMPOSE" ]] || { echo "No trobo $PROJ/.env o $PROJ/$COMPOSE"; exit 1; }
[[ $IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "IP invàlida: $IP"; exit 1; }
ip -4 addr show docker0 2>/dev/null | grep -q "$DOCKER_BRIDGE" \
  || echo "AVÍS: docker0 no té $DOCKER_BRIDGE; l'agent no arrencarà fins que Docker l'hagi creat"
info() { echo "    $*"; }

# ---- 1. certificats
if [[ ! -f "$CERTS/ca/ca.crt" ]]; then
  ( umask 077; bash "$SRC/scripts/gen_certs.sh" --core "$IP" "$CERTS" >/dev/null )
  info "certificats nous a $CERTS (CA pròpia)"
else
  info "certificats existents a $CERTS"
fi
[[ -f "$CERTS/agent-core/agent-core.crt" && -f "$CERTS/panel/panel5g-client.crt" ]] \
  || { echo "A $CERTS falten agent-core/ o panel/: torna a generar-los amb gen_certs.sh --core $IP $CERTS"; exit 1; }

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
    'listen': '172.17.0.1', 'port': 9543,
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

# ---- 4. panell
install -d -m 755 "$(dirname "$PANEL_DIR")"
if [[ -d "$PANEL_DIR/app" ]]; then
  cp -a "$PANEL_DIR/app" "/var/lib/agent5g/panell-app-$(date +%Y%m%d-%H%M%S)"
fi
install -d -m 755 "$PANEL_DIR" "$PANEL_DIR/config"
cp -a "$SRC/panel/Dockerfile" "$SRC/panel/requirements.txt" "$SRC/panel/docker-compose.yml" "$PANEL_DIR/"
rm -rf "$PANEL_DIR/app"; cp -a "$SRC/panel/app" "$PANEL_DIR/app"; find "$PANEL_DIR/app" -name __pycache__ -prune -exec rm -rf {} +
for f in schema.yaml restart_map.yaml; do install -m 644 "$SRC/panel/config/$f" "$PANEL_DIR/config/"; done
for f in tac.csv models.csv; do
  [[ -f "$PANEL_DIR/config/$f" || ! -f "$SRC/panel/config/$f" ]] || install -m 644 "$SRC/panel/config/$f" "$PANEL_DIR/config/"
done
install -d -m 750 "$PANEL_DIR/certs"
cp "$CERTS"/panel/{ca.crt,panel5g-client.crt,panel5g-client.key,panel5g-web.crt,panel5g-web.key,panel5g-session.secret} "$PANEL_DIR/certs/"
chown -R 10001:10001 "$PANEL_DIR/certs"; chmod 600 "$PANEL_DIR"/certs/*.key "$PANEL_DIR/certs/panel5g-session.secret"
CONTRA_FITXER=/root/panel5g-admin.txt
if [[ ! -f "$PANEL_DIR/config/panel.yaml" ]]; then
  PASS=$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')
  HASH=$(printf '%s\n' "$PASS" | PYTHONPATH="$PANEL_DIR" python3 -c 'import sys; from app.auth import hash_password; print(hash_password(sys.stdin.readline().strip()))')
  ( umask 077; printf 'Panell 5G: https://%s:8443\nusuari: admin\ncontrasenya: %s\n' "$IP" "$PASS" > "$CONTRA_FITXER" )
  XARXA=$(python3 -c "import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1] + '/24', strict=False))" "$IP")
  cat > "$PANEL_DIR/config/panel.yaml" <<YAML
# Configuració del panell 5G (generada per install_core.sh). Es munta en només lectura.
sessio_hores: 8
ca: /certs/ca.crt
client_cert: /certs/panel5g-client.crt
client_key: /certs/panel5g-client.key

# L'agent del core escolta al pont de Docker. Les ràdios es troben soles (descobriment).
agents:
  core:
    url: https://host.docker.internal:$PORT

# Cerca de ràdios: agents amb certificat d'aquesta CA (gen_certs.sh --radio <IP>)
descobriment:
  actiu: true
  xarxes: ["$XARXA"]
  port: $PORT
  interval_s: 120

# Usuaris. Nova contrasenya: docker compose run --rm panel5g python -m app.hashpw
usuaris:
  admin:
    rol: admin
    hash: "$HASH"

estat_logs:
  core:
    - {etiqueta: "gNB connectats a l'AMF", contenidor: amf, regex: "Number of gNBs is now (\\\\d+)"}
    - {etiqueta: "UE registrats (AMF)",     contenidor: amf, regex: "Number of AMF-UEs is now (\\\\d+)"}
    - {etiqueta: "Sessions PDU (SMF)",      contenidor: smf, regex: "Number of SMF-Sessions is now (\\\\d+)"}
    - {etiqueta: "Sessions UPF",            contenidor: upf, regex: "Number of UPF-Sessions is now (\\\\d+)"}
  radio:
    - {etiqueta: "N2 amb l'AMF",            contenidor: ocudu_gnb, regex: "Connection to AMF.*completed"}
    - {etiqueta: "Cel·la",                  contenidor: ocudu_gnb, regex: "(Cell pci=.*)$"}
estat_linies: 1000
YAML
  info "panell: panel.yaml nou; usuari admin, contrasenya a $CONTRA_FITXER"
else
  info "panell: es conserva el panel.yaml existent"
fi
chmod 644 "$PANEL_DIR/config/"*
chown 10001:10001 "$PANEL_DIR/config/panel.yaml"; chmod 640 "$PANEL_DIR/config/panel.yaml"   # porta el hash d'admin
(cd "$PANEL_DIR" && PANEL_IP="$IP" docker compose up -d --build >/dev/null 2>&1) \
  || { echo "ERROR: no s'ha pogut arrencar el panell (cd $PANEL_DIR && PANEL_IP=$IP docker compose up -d --build)"; exit 1; }

sleep 3
for s in agent5g ngap-capture ua-capture; do
  systemctl is-active -q "$s" && info "$s: actiu" || echo "    AVÍS: $s no està actiu (journalctl -u $s)"
done
info "panell: https://$IP:8443 (importa $CERTS/ca/ca.crt al navegador)"
info "guarda $CERTS/ca/ca.key fora del PC: amb ella s'emeten els certificats de les ràdios"
