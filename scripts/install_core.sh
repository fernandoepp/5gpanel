#!/usr/bin/env bash
# Instala SOLO el agente del core (lo llama core5g.sh), sin preguntas:
#   agent5g (mTLS en el puerto 9543 para el panel y en el 9544 para las radios, que llaman solas)
#   + captura NGAP/SBI + modelo del móvil (User-Agent),
#   los tres como servicios systemd que se reinician siempre (también tras un reinicio
#   del PC, de Docker o del panel).
# Al final imprime el CÓDIGO DE EMPAREJAMIENTO de cada radio (CORE5G_RADIOS="aula1 aula2" o,
# si hay terminal, lo pregunta). Más adelante: sudo emparella-radio <nombre>.
# La IP del core (IP_LAN) es la única que tiene que ser fija: las radios llaman a ella.
#
#   sudo ./install_core.sh <carpeta_docker_open5gs> <fichero_compose> <IP_LAN> [carpeta_certs]
#
# carpeta_certs (por defecto /root/certs-5g): si no hay CA, se crea una (gen_certs.sh --core).
# Ahí quedan también los certificados del panel (panel/), para cuando se instale.
# Volver a ejecutarlo es seguro: no cambia los certificados existentes.
set -euo pipefail
PROJ=${1:?carpeta del proyecto docker_open5gs}
COMPOSE=${2:?fichero compose (sa-deploy.yaml o sa-vonr-deploy.yaml)}
IP=${3:?IP LAN del core}
CERTS=${4:-/root/certs-5g}
[[ $EUID -eq 0 ]] || { echo "Ejecútalo con sudo"; exit 1; }
SRC=$(cd "$(dirname "$0")/.." && pwd)
PORT=9543
[[ -f "$PROJ/.env" && -f "$PROJ/$COMPOSE" ]] || { echo "No encuentro $PROJ/.env o $PROJ/$COMPOSE"; exit 1; }
[[ $IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "IP no válida: $IP"; exit 1; }
info() { echo "    $*"; }

# ---- 1. certificados
if [[ ! -f "$CERTS/ca/ca.crt" ]]; then
  ( umask 077; bash "$SRC/scripts/gen_certs.sh" --core "$IP" "$CERTS" >/dev/null )
  info "certificados nuevos en $CERTS (CA propia)"
else
  info "certificados existentes en $CERTS"
fi
[[ -f "$CERTS/agent-core/agent-core.crt" ]] \
  || { echo "En $CERTS falta agent-core/: vuelve a generarlos con gen_certs.sh --core $IP $CERTS"; exit 1; }

# ---- 2. paquetes (tshark sin preguntas: sin captura para usuarios no root)
if ! command -v tshark >/dev/null || ! command -v dumpcap >/dev/null; then
  echo "wireshark-common wireshark-common/install-setuid boolean false" | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tshark >/dev/null
  info "tshark instalado"
fi
command -v python3 >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 >/dev/null

# ---- 3. agente
install -d -m 755 /opt/agent5g
install -m 755 "$SRC/agent/agent5g.py" "$SRC/agent/ua_capture.py" /opt/agent5g/
install -d -m 755 /opt/agent5g; install -m 755 "$SRC/scripts/agent5g_menu.sh" /opt/agent5g/agent5g_menu.sh; ln -sf /opt/agent5g/agent5g_menu.sh /usr/local/sbin/agent5g   # menú: sudo agent5g
git -C "$SRC" log -1 --format='%h · %cd (instalación)' --date=format:'%Y-%m-%d %H:%M' > /opt/agent5g/VERSIO 2>/dev/null || true
install -d -m 700 /etc/agent5g /etc/agent5g/certs /var/lib/agent5g
install -m 600 "$CERTS/agent-core/ca.crt" "$CERTS/agent-core/agent-core.crt" "$CERTS/agent-core/agent-core.key" /etc/agent5g/certs/
# Configuración generada a partir del compose real: todos sus contenedores se pueden
# ver; se pueden recrear todos menos mongo/mysql (las bases de datos no se tocan).
SERVEIS=$(cd "$PROJ" && docker compose -f "$COMPOSE" config --services 2>/dev/null | sort -u | tr '\n' ' ')
[[ -n $SERVEIS ]] || { echo "docker compose config ha fallado en $PROJ/$COMPOSE"; exit 1; }
PROJ="$PROJ" COMPOSE="$COMPOSE" SERVEIS="$SERVEIS" python3 - <<'PY'
import json, os
f = '/etc/agent5g/agent5g.json'
old = {}
if os.path.isfile(f):
    with open(f) as fh:
        old = json.load(fh)
serveis = os.environ['SERVEIS'].split()
ims = {'dns', 'mysql', 'rtpengine', 'pyhss', 'icscf', 'scscf', 'pcscf', 'smsc'}
nucli = [s for s in serveis if s not in ims]          # los IMS los gestiona el bloque "voip"
cfg = {
    'role': 'core', 'name': old.get('name', 'Core 5G'),
    'listen': '0.0.0.0', 'port': 9543,
    # las radios llaman al core (enlace radio -> core): al core le da igual la IP de la radio
    'enllac': old.get('enllac') or {'listen': '0.0.0.0', 'port': 9544},
    'cert': '/etc/agent5g/certs/agent-core.crt', 'key': '/etc/agent5g/certs/agent-core.key',
    'ca': '/etc/agent5g/certs/ca.crt', 'allowed_client_cn': ['panel5g'],
    'project_dir': os.environ['PROJ'], 'env_file': '.env',
    'compose_files': [os.environ['COMPOSE']], 'compose_project': None,
    'editable_keys': old.get('editable_keys') or {
        'MCC': '^[0-9]{3}$', 'MNC': '^[0-9]{2,3}$'},   # la IP del core: sudo agent5g
    'containers': nucli,
    'services': [s for s in nucli if s not in ('mongo',)],
    'log_files': {}, 'backup_dir': '/var/lib/agent5g/backups', 'audit_log': '/var/lib/agent5g/audit.log',
    'docker_bin': '/usr/bin/docker', 'max_log_lines': 2000, 'max_backups': 50, 'apply_timeout': 300,
    'ue_capture': {'dir': '/var/lib/agent5g/ngap'},
    'voip': {'permes': True, 'compose_file': 'sa-vonr-deploy.yaml'},
}
for k in ('pyhss', 'project_actions'):          # personalizaciones que se conservan
    if k in old:
        cfg[k] = old[k]
with open(f + '.nou', 'w') as fh:
    json.dump(cfg, fh, indent=2, ensure_ascii=False)
os.chmod(f + '.nou', 0o600)
os.replace(f + '.nou', f)
PY
info "agente: /etc/agent5g/agent5g.json ($(wc -w <<<"$SERVEIS") servicios en $COMPOSE)"
install -m 644 "$SRC/agent/agent5g.service" "$SRC/agent/ngap-capture.service" "$SRC/agent/ua-capture.service" /etc/systemd/system/
install -d /etc/systemd/system/agent5g.service.d
printf '[Service]\nReadWritePaths=%s\n' "$PROJ" > /etc/systemd/system/agent5g.service.d/projecte.conf
systemctl daemon-reload
systemctl enable --now ngap-capture ua-capture agent5g >/dev/null 2>&1
systemctl restart ngap-capture ua-capture agent5g

# ---- 4. herramientas de emparejamiento (emparella-radio <nombre>); la IP del core va dentro del código
printf '%s\n' "$IP" > /etc/agent5g/core_ip
install -d -m 755 /opt/agent5g/eines
install -m 755 "$SRC/scripts/gen_certs.sh" "$SRC/scripts/emparella_radio.sh" "$SRC/scripts/emparella_upf.sh" /opt/agent5g/eines/
ln -sf /opt/agent5g/eines/emparella_radio.sh /usr/local/sbin/emparella-radio
ln -sf /opt/agent5g/eines/emparella_upf.sh /usr/local/sbin/emparella-upf
# para que emparella-radio/-upf encuentren los certificados aunque no estén en /root/certs-5g
sed -i "s#^CERTS=\${2:-/root/certs-5g}#CERTS=\${2:-$CERTS}#" /opt/agent5g/eines/emparella_radio.sh /opt/agent5g/eines/emparella_upf.sh

sleep 3
for s in agent5g ngap-capture ua-capture; do
  systemctl is-active -q "$s" && info "$s: activo (se inicia solo al arrancar y se reinicia siempre)" \
    || echo "    AVISO: $s no está activo (journalctl -u $s)"
done
info "certificados del panel (para cuando lo instales): $CERTS/panel"
info "$CERTS/ca/ca.key es la clave de la CA: no la copies a ningún sitio (emparella-radio la necesita aquí)"

# ---- 5. código de emparejamiento de las radios
RADIOS=${CORE5G_RADIOS:-}
# core5g.sh lo hace él al final de todo (CORE5G_EMPARELLAR_DESPRES=1), cuando el panel ya está en marcha
[[ ${CORE5G_EMPARELLAR_DESPRES:-0} == 1 ]] && exit 0
if [[ -z $RADIOS && -t 0 ]]; then
  read -r -p "    Nombre de la radio (o radios, separados por espacios; p. ej. aula1) para emparejar ahora [vacío = más tarde]: " RADIOS || RADIOS=""
fi
for R in $RADIOS; do
  /usr/local/sbin/emparella-radio "$R" "$CERTS" || echo "    AVISO: no se ha podido emparejar $R"
done
[[ -n $RADIOS ]] || info "para emparejar una radio más adelante: sudo emparella-radio <nombre> (p. ej. aula1)"
info "UPF en otro PC: sudo emparella-upf <nombre> (p. ej. upf1) y, en ese PC, install_upf.sh con el código"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
  info "AVISO: ufw está activo y no lo toco. Para que las radios puedan llamar: sudo ufw allow 9544/tcp comment agent5g-radios-upf"
fi
