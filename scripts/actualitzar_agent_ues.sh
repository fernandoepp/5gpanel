#!/usr/bin/env bash
# Actualitza NOMÉS l'agent5g del core i el servei de captura (IMEISV per als UEs).
#   - /opt/agent5g/agent5g.py                    (NAS amb 5G-EA0 descodificat, Masked IMEISV,
#                                                 PEI per SBI, magatzem /var/lib/agent5g/ues.json)
#   - /etc/systemd/system/ngap-capture.service   (filtre: N2 + SBI tcp/7777)
# No toca els contenidors del core, el panell, ufw ni /etc/agent5g/agent5g.json.
#
# Ús (des d'aquest PC):
#   scp agent5g.py ngap-capture.service actualitzar_agent_ues.sh core@192.168.2.99:/tmp/agent_ues/
#   ssh -t core@192.168.2.99 sudo bash /tmp/agent_ues/actualitzar_agent_ues.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "Cal executar-ho amb sudo"; exit 1; }
for f in agent5g.py ngap-capture.service; do
  [[ -f "$DIR/$f" ]] || { echo "Falta $DIR/$f"; exit 1; }
done
python3 -m py_compile "$DIR/agent5g.py"

TS=$(date +%Y%m%d-%H%M%S)
cp -a /opt/agent5g/agent5g.py "/opt/agent5g/agent5g.py.bak-$TS"
cp -a /etc/systemd/system/ngap-capture.service "/var/lib/agent5g/ngap-capture.service.bak-$TS"
echo ">> Còpies: /opt/agent5g/agent5g.py.bak-$TS i /var/lib/agent5g/ngap-capture.service.bak-$TS"

install -m 755 -o root -g root "$DIR/agent5g.py" /opt/agent5g/agent5g.py
install -m 644 -o root -g root "$DIR/ngap-capture.service" /etc/systemd/system/ngap-capture.service
systemctl daemon-reload
systemctl restart ngap-capture agent5g
sleep 3
systemctl --no-pager --lines=0 status ngap-capture agent5g | grep -E '●|Active:'
if systemctl is-active -q ngap-capture && systemctl is-active -q agent5g; then
  echo ">> Fet. Els UEs agafaran l'IMEISV al proper registre complet del mòbil."
else
  echo ">> ALERTA: algun servei no ha arrencat. Per tornar enrere:"
  echo "   cp /opt/agent5g/agent5g.py.bak-$TS /opt/agent5g/agent5g.py"
  echo "   cp /var/lib/agent5g/ngap-capture.service.bak-$TS /etc/systemd/system/ngap-capture.service"
  echo "   systemctl daemon-reload && systemctl restart ngap-capture agent5g"
  exit 1
fi
