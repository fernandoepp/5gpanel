#!/usr/bin/env bash
# Instal·la l'agent en aquest PC.   sudo ./install_agent.sh <core|radio> <carpeta_certs> [IP_panell]
#   carpeta_certs: la sortida de gen_certs.sh per a aquest rol (certs-5g/agent-core o agent-radio)
#   IP_panell: només si el panell és a L'ALTRE PC (la seva IP LAN). Si ufw és actiu,
#              només aquesta IP podrà entrar al port 9543. Si el panell és en aquest
#              mateix PC, no la posis i fes que l'agent escolti a 172.17.0.1.
set -euo pipefail
ROL=${1:?core o radio}; CERTS=${2:?carpeta de certificats}; PANEL_IP=${3:-}
[[ $EUID -eq 0 ]] || { echo "Executa amb sudo"; exit 1; }
[[ $ROL == core || $ROL == radio ]] || { echo "Rol: core o radio"; exit 1; }
DIR=$(cd "$(dirname "$0")/.." && pwd)
case $(stat -f -c %T "$CERTS") in vboxsf|cifs|smb2|smb3|nfs|fuse|9p|v9fs)
  echo "AVÍS: els certificats són en una carpeta compartida. Un cop instal·lat, esborra'ls d'allà." ;;
esac

install -d -m 755 /opt/agent5g
install -m 755 "$DIR/agent/agent5g.py" /opt/agent5g/agent5g.py
install -d -m 700 /etc/agent5g /etc/agent5g/certs /var/lib/agent5g
install -m 600 "$CERTS/ca.crt" "$CERTS/agent-$ROL.crt" "$CERTS/agent-$ROL.key" /etc/agent5g/certs/
if [[ ! -f /etc/agent5g/agent5g.json ]]; then
  install -m 600 "$DIR/agent/agent5g-$ROL.json" /etc/agent5g/agent5g.json
  echo ">> Revisa /etc/agent5g/agent5g.json (listen, project_dir, contenidors) i torna a executar."
fi
PROJ=$(python3 -c 'import json;print(json.load(open("/etc/agent5g/agent5g.json"))["project_dir"])')
[[ -f "$PROJ/.env" ]] || { echo "No trobo $PROJ/.env: corregeix project_dir"; exit 1; }

install -m 644 "$DIR/agent/agent5g.service" /etc/systemd/system/agent5g.service
install -d /etc/systemd/system/agent5g.service.d
printf '[Service]\nReadWritePaths=%s\n' "$PROJ" > /etc/systemd/system/agent5g.service.d/projecte.conf
systemctl daemon-reload
systemctl enable --now agent5g
systemctl restart agent5g

if [[ -n $PANEL_IP ]] && command -v ufw >/dev/null && ufw status | grep -q active; then
  ufw allow from "$PANEL_IP" to any port 9543 proto tcp comment agent5g
  ufw deny 9543/tcp comment agent5g
fi
# Captura NGAP per a la pestanya UEs (només al core)
if [[ $ROL == core ]] && python3 -c 'import json,sys;sys.exit(0 if json.load(open("/etc/agent5g/agent5g.json")).get("ue_capture") else 1)'; then
  command -v dumpcap >/dev/null && command -v tshark >/dev/null || {
    echo ">> Instal·lant tshark (per llegir la captura NGAP)..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tshark >/dev/null; }
  install -m 644 "$DIR/agent/ngap-capture.service" /etc/systemd/system/ngap-capture.service
  systemctl daemon-reload
  systemctl enable --now ngap-capture
  systemctl restart ngap-capture
fi
systemctl --no-pager status agent5g | head -5
