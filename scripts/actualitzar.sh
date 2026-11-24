#!/usr/bin/env bash
# Actualitza el core amb l'última versió del panell i de l'agent (v15):
#   * interfície nova: barra lateral, tema clar/fosc, etiquetes llegibles, interruptors
#   * cerca automàtica de ràdios (agents amb certificat de la CA), N ràdios
#   * servei VoIP activable des del panell (Kamailio + PyHSS) i alta automàtica per número
#   - /opt/agent5g/agent5g.py, ua_capture.py i ua-capture.service
#   - panell: tot app/ i config/schema.yaml (amb còpia) -> rebuild del contenidor panel5g
# No toca els contenidors del core, panel.yaml, tac.csv, els certs, ufw ni /etc/agent5g/agent5g.json.
#
# Ús (des del PC on hi ha el paquet desplegat):
#   scp -r panel5g core@192.168.2.99:/tmp/panel5g-ua
#   ssh -t core@192.168.2.99 sudo bash /tmp/panel5g-ua/scripts/actualitzar.sh
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
PANEL_DIR=${PANEL_DIR:-/opt/panel5g/panel}
# IP de la VM per on surt el trànsit (el DHCP la pot canviar): es pot forçar amb PANEL_IP=...
PANEL_IP=${PANEL_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')}
[[ -n $PANEL_IP ]] || { echo "No trobo la IP de la VM: defineix PANEL_IP"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Cal executar-ho amb sudo"; exit 1; }
for f in agent/agent5g.py agent/ua_capture.py agent/ua-capture.service panel/Dockerfile panel/app/data/tac_full.csv.gz \
         panel/app/main.py panel/app/radio.py panel/app/static/app.js panel/config/schema.yaml; do
  [[ -f "$SRC/$f" ]] || { echo "Falta $SRC/$f"; exit 1; }
done
[[ -d "$PANEL_DIR/app" ]] || { echo "No trobo el panell a $PANEL_DIR (defineix PANEL_DIR)"; exit 1; }
command -v tshark >/dev/null || { echo "Falta tshark (ja s'hauria d'haver instal·lat amb l'agent)"; exit 1; }
PYTHONDONTWRITEBYTECODE=1 python3 -c "import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]" "$SRC/agent/agent5g.py" "$SRC/agent/ua_capture.py" "$SRC"/panel/app/*.py

TS=$(date +%Y%m%d-%H%M%S)
BK=/var/lib/agent5g/bak-$TS; install -d -m 700 "$BK"
cp -a /opt/agent5g/agent5g.py "$BK/"
cp -a "$PANEL_DIR/app" "$BK/app"
cp -a "$PANEL_DIR/config/schema.yaml" "$BK/"
echo ">> Còpies a $BK"

install -m 755 -o root -g root "$SRC/agent/agent5g.py"   /opt/agent5g/agent5g.py
install -m 755 -o root -g root "$SRC/agent/ua_capture.py" /opt/agent5g/ua_capture.py
install -m 644 -o root -g root "$SRC/agent/ua-capture.service" /etc/systemd/system/ua-capture.service
OWN=$(stat -c %u:%g "$PANEL_DIR/app/main.py")
install -m 644 -o "${OWN%:*}" -g "${OWN#*:}" "$SRC"/panel/app/*.py "$PANEL_DIR/app/"
install -m 644 -o "${OWN%:*}" -g "${OWN#*:}" "$SRC"/panel/app/static/* "$PANEL_DIR/app/static/"
install -m 644 -o "${OWN%:*}" -g "${OWN#*:}" "$SRC/panel/config/schema.yaml" "$PANEL_DIR/config/"
# base de dades de TAC (model del mòbil) i el Dockerfile que la converteix a SQLite
install -d -m 755 -o "${OWN%:*}" -g "${OWN#*:}" "$PANEL_DIR/app/data"
install -m 644 -o "${OWN%:*}" -g "${OWN#*:}" "$SRC"/panel/app/data/tac_full.csv.gz "$SRC"/panel/app/data/LICENSE-tac-database "$SRC"/panel/app/data/tac_full.VERSIO "$PANEL_DIR/app/data/"
cp -a "$PANEL_DIR/Dockerfile" "$BK/" 2>/dev/null || true
install -m 644 -o "${OWN%:*}" -g "${OWN#*:}" "$SRC/panel/Dockerfile" "$PANEL_DIR/Dockerfile"
# models.csv (codi -> nom comercial): només si encara no n'hi ha, per no trepitjar el teu
if [[ -f "$SRC/panel/config/models.csv" && ! -f "$PANEL_DIR/config/models.csv" ]]; then
  install -m 644 -o "${OWN%:*}" -g "${OWN#*:}" "$SRC/panel/config/models.csv" "$PANEL_DIR/config/"
fi

systemctl daemon-reload
systemctl enable --now ua-capture
systemctl restart agent5g
(cd "$PANEL_DIR" && PANEL_IP="$PANEL_IP" docker compose up -d --build)
sleep 4
systemctl --no-pager --lines=0 status ua-capture agent5g | grep -E '●|Active:'
if systemctl is-active -q ua-capture && systemctl is-active -q agent5g; then
  echo ">> Fet. Panell: https://$PANEL_IP:8443 (Ctrl+F5). Ha de dir 'Versió v15' a la barra lateral."
  echo "   VoIP: Abonats i VoIP > Servei de telefonia > Activat (el core 5G no s'atura)."
  echo "   Ràdios noves: scripts/gen_certs.sh --radio <IP> (on tinguis la CA) i install_agent.sh a la ràdio."
else
  echo ">> ALERTA: algun servei no ha arrencat. Per tornar enrere:"
  echo "   systemctl disable --now ua-capture; cp $BK/agent5g.py /opt/agent5g/; systemctl restart agent5g"
  echo "   cp -a $BK/app/. $PANEL_DIR/app/; cp $BK/schema.yaml $PANEL_DIR/config/"
  echo "   cd $PANEL_DIR && PANEL_IP=$PANEL_IP docker compose up -d --build"
  exit 1
fi
