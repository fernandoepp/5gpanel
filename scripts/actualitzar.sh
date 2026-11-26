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
install -d -m 755 /opt/agent5g; install -m 755 "$SRC/scripts/agent5g_menu.sh" /opt/agent5g/agent5g_menu.sh; ln -sf /opt/agent5g/agent5g_menu.sh /usr/local/sbin/agent5g   # menú: sudo agent5g
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

# Enllaç ràdio -> core: ara són les ràdios les que truquen a l'agent del core (port 9544).
#  - eines d'emparellament noves (emparella-radio <nom>; el codi porta la IP del core)
#  - la ràdio fixa de panel.yaml (agents.radio amb la IP de la ràdio) es comenta: la ràdio
#    apareix sola quan truca al core (a la ràdio: sudo bash scripts/enllaca_radio.sh codi.txt)
CERTS_EINES=$(sed -n 's#^CERTS=\${2:-\(.*\)}$#\1#p' /opt/agent5g/eines/emparella_radio.sh 2>/dev/null | head -1 || true)
if [[ -z $CERTS_EINES ]]; then                 # instal·lacions antigues: on és la CA?
  for c in /root/certs-5g /opt/panel5g/certs-5g; do [[ -f $c/ca/ca.key ]] && { CERTS_EINES=$c; break; }; done
fi
if [[ -n $CERTS_EINES ]]; then
  install -d -m 755 /opt/agent5g/eines
  install -m 755 "$SRC/scripts/gen_certs.sh" "$SRC/scripts/emparella_radio.sh" "$SRC/scripts/emparella_upf.sh" /opt/agent5g/eines/
  sed -i "s#^CERTS=\${2:-/root/certs-5g}#CERTS=\${2:-$CERTS_EINES}#" /opt/agent5g/eines/emparella_radio.sh /opt/agent5g/eines/emparella_upf.sh
  ln -sf /opt/agent5g/eines/emparella_radio.sh /usr/local/sbin/emparella-radio
  ln -sf /opt/agent5g/eines/emparella_upf.sh /usr/local/sbin/emparella-upf
  echo ">> emparella-radio <nom> i emparella-upf <nom> instal·lats (CA a $CERTS_EINES)"
else
  echo ">> AVÍS: no trobo la CA (ca/ca.key): emparella_radio.sh <nom> <carpeta_certs> a mà"
fi
[[ -s /etc/agent5g/core_ip ]] || printf '%s\n' "$PANEL_IP" > /etc/agent5g/core_ip
cp -a "$PANEL_DIR/config/panel.yaml" "$BK/"
python3 - "$PANEL_DIR/config/panel.yaml" <<'PY'
import re, sys
f = sys.argv[1]
ls = open(f).read().split('\n')
out, dins, canvi, sec = [], False, False, None
for l in ls:
    m = re.match(r'^([A-Za-z_]\w*):', l)
    if m:
        sec = m.group(1)                 # només dins de "agents:" (estat_logs també té "radio:")
    if sec == 'agents' and re.match(r'^  radio:', l):
        dins = True
        canvi = True
        out.append('  # (enllaç ràdio -> core: la ràdio ja no va aquí, truca sola al core)')
        out.append('# ' + l)
        continue
    if dins and re.match(r'^    \S', l):
        out.append('# ' + l)
        continue
    dins = False
    out.append(l)
if canvi:
    print('>> panel.yaml: comentada la ràdio fixa (ara la ràdio truca al core)')
# indicadors de l'estat dels PCs amb UPF separat (rol "upf"), si encara no hi són
txt = '\n'.join(out)
if re.search(r'^estat_logs:', txt, re.M) and not re.search(r'^  upf:', txt, re.M):
    txt = re.sub(r'^estat_logs:[^\n]*\n', lambda m: m.group(0) +
                 '  upf:\n'
                 '    - {etiqueta: "Sessions UPF",            contenidor: upf, regex: "Number of UPF-Sessions is now (\\\\d+)"}\n'
                 '    - {etiqueta: "PFCP amb l\'SMF",          contenidor: upf, regex: "(PFCP (?:de-)?associated.*)$"}\n',
                 txt, count=1, flags=re.M)
    canvi = True
    print('>> panel.yaml: afegit l\'estat dels PCs amb UPF')
if canvi:
    open(f, 'w').write(txt)
PY
systemctl daemon-reload
systemctl enable --now ua-capture
systemctl restart agent5g
(cd "$PANEL_DIR" && PANEL_IP="$PANEL_IP" docker compose up -d --build)
sleep 4
systemctl --no-pager --lines=0 status ua-capture agent5g | grep -E '●|Active:'
if systemctl is-active -q ua-capture && systemctl is-active -q agent5g; then
  echo ">> Fet. Panell: https://$PANEL_IP:8443 (Ctrl+F5). Ha de dir 'Versió v17' a la barra lateral."
  echo "   VoIP: Abonats i VoIP > Servei de telefonia > Activat (el core 5G no s'atura)."
  echo "   Ràdios: al core, sudo emparella-radio <nom>; a la ràdio, sudo bash scripts/enllaca_radio.sh codi.txt"
  echo "   (ràdio ja instal·lada) o install_radio.sh (nova). La ràdio truca sola al core $PANEL_IP:9544."
  echo "   UPF en un altre PC: al core, sudo emparella-upf <nom>; en aquell PC, sudo bash scripts/install_upf.sh"
  echo "   (pestanya UPF del panell: separar o tornar a ajuntar el UPF)."
else
  echo ">> ALERTA: algun servei no ha arrencat. Per tornar enrere:"
  echo "   systemctl disable --now ua-capture; cp $BK/agent5g.py /opt/agent5g/; systemctl restart agent5g"
  echo "   cp -a $BK/app/. $PANEL_DIR/app/; cp $BK/schema.yaml $BK/panel.yaml $PANEL_DIR/config/"
  echo "   cd $PANEL_DIR && PANEL_IP=$PANEL_IP docker compose up -d --build"
  exit 1
fi
