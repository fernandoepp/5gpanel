#!/usr/bin/env bash
# Actualiza el core con la última versión del panel y del agente (v15):
#   * interfaz nueva: barra lateral, tema claro/oscuro, etiquetas legibles, interruptores
#   * búsqueda automática de radios (agentes con certificado de la CA), N radios
#   * servicio VoIP activable desde el panel (Kamailio + PyHSS) y alta automática por número
#   - /opt/agent5g/agent5g.py, ua_capture.py i ua-capture.service
#   - panel: todo app/ y config/schema.yaml (con copia) -> rebuild del contenedor panel5g
# No toca los contenedores del core, panel.yaml, tac.csv, los certs, ufw ni /etc/agent5g/agent5g.json.
#
# Uso (desde el PC donde está el paquete desplegado; o, más fácil: sudo agent5g > Actualizar desde GitHub):
#   scp -r panel5g core@192.168.2.99:/tmp/panel5g-ua
#   ssh -t core@192.168.2.99 sudo bash /tmp/panel5g-ua/scripts/actualitzar.sh
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
# Carpeta del panel: PANEL_DIR=..., o la del contenedor panel5g en marcha, o /opt/panel5g/panel.
# Si en este PC no hay panel (solo el agente del core), se actualiza solo el agente.
if [[ -z ${PANEL_DIR:-} ]]; then
  PANEL_DIR=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' panel5g 2>/dev/null || true)
  [[ -d $PANEL_DIR/app ]] || PANEL_DIR=/opt/panel5g/panel
fi
# IP de la VM por donde sale el tráfico (el DHCP la puede cambiar): se puede forzar con PANEL_IP=...
PANEL_IP=${PANEL_IP:-$(cat /etc/agent5g/core_ip 2>/dev/null || true)}
PANEL_IP=${PANEL_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')}
[[ -n $PANEL_IP ]] || { echo "No encuentro la IP de la VM: define PANEL_IP"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Hay que ejecutarlo con sudo"; exit 1; }
for f in agent/agent5g.py agent/ua_capture.py agent/ua-capture.service panel/Dockerfile panel/app/data/tac_full.csv.gz \
         panel/app/main.py panel/app/radio.py panel/app/static/app.js panel/config/schema.yaml; do
  [[ -f "$SRC/$f" ]] || { echo "Falta $SRC/$f"; exit 1; }
done
AMB_PANELL=1
[[ -d "$PANEL_DIR/app" ]] || { AMB_PANELL=0; echo ">> No hay panel en $PANEL_DIR: solo se actualiza el agente (si lo tienes, PANEL_DIR=<carpeta>/panel)"; }
command -v tshark >/dev/null || { echo "Falta tshark (ya se tendría que haber instalado con el agente)"; exit 1; }
PYTHONDONTWRITEBYTECODE=1 python3 -c "import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]" "$SRC/agent/agent5g.py" "$SRC/agent/ua_capture.py" "$SRC"/panel/app/*.py

TS=$(date +%Y%m%d-%H%M%S)
BK=/var/lib/agent5g/bak-$TS; install -d -m 700 "$BK"
cp -a /opt/agent5g/agent5g.py "$BK/"
if (( AMB_PANELL )); then cp -a "$PANEL_DIR/app" "$BK/app"; cp -a "$PANEL_DIR/config/schema.yaml" "$BK/"; fi
echo ">> Copias en $BK"

install -m 755 -o root -g root "$SRC/agent/agent5g.py"   /opt/agent5g/agent5g.py
# menú sudo agent5g: se copia aparte y se renombra (puede ser el mismo menú el que nos ejecuta)
install -m 755 "$SRC/scripts/agent5g_menu.sh" /opt/agent5g/.agent5g_menu.nou
mv -f /opt/agent5g/.agent5g_menu.nou /opt/agent5g/agent5g_menu.sh
ln -sf /opt/agent5g/agent5g_menu.sh /usr/local/sbin/agent5g
git -C "$SRC" log -1 --format='%h · %cd (instalación)' --date=format:'%Y-%m-%d %H:%M' > /opt/agent5g/VERSIO 2>/dev/null || true
install -m 755 -o root -g root "$SRC/agent/ua_capture.py" /opt/agent5g/ua_capture.py
install -m 644 -o root -g root "$SRC/agent/ua-capture.service" /etc/systemd/system/ua-capture.service
if (( AMB_PANELL )); then
OWN=$(stat -c %u:%g "$PANEL_DIR/app/main.py")
install -m 644 -o "${OWN%:*}" -g "${OWN#*:}" "$SRC"/panel/app/*.py "$PANEL_DIR/app/"
install -m 644 -o "${OWN%:*}" -g "${OWN#*:}" "$SRC"/panel/app/static/* "$PANEL_DIR/app/static/"
install -m 644 -o "${OWN%:*}" -g "${OWN#*:}" "$SRC/panel/config/schema.yaml" "$PANEL_DIR/config/"
# base de datos de TAC (modelo del móvil) y el Dockerfile que la convierte a SQLite
install -d -m 755 -o "${OWN%:*}" -g "${OWN#*:}" "$PANEL_DIR/app/data"
install -m 644 -o "${OWN%:*}" -g "${OWN#*:}" "$SRC"/panel/app/data/tac_full.csv.gz "$SRC"/panel/app/data/LICENSE-tac-database "$SRC"/panel/app/data/tac_full.VERSIO "$PANEL_DIR/app/data/"
cp -a "$PANEL_DIR/Dockerfile" "$BK/" 2>/dev/null || true
install -m 644 -o "${OWN%:*}" -g "${OWN#*:}" "$SRC/panel/Dockerfile" "$PANEL_DIR/Dockerfile"
# models.csv (código -> nombre comercial): solo si todavía no existe, para no pisar el tuyo
if [[ -f "$SRC/panel/config/models.csv" && ! -f "$PANEL_DIR/config/models.csv" ]]; then
  install -m 644 -o "${OWN%:*}" -g "${OWN#*:}" "$SRC/panel/config/models.csv" "$PANEL_DIR/config/"
fi
fi   # AMB_PANELL

# Enlace radio -> core: ahora son las radios las que llaman al agente del core (puerto 9544).
#  - herramientas de emparejamiento nuevas (emparella-radio <nombre>; el código lleva la IP del core)
#  - la radio fija de panel.yaml (agents.radio con la IP de la radio) se comenta: la radio
#    aparece sola cuando llama al core (en la radio: sudo bash scripts/enllaca_radio.sh codigo.txt)
CERTS_EINES=$(sed -n 's#^CERTS=\${2:-\(.*\)}$#\1#p' /opt/agent5g/eines/emparella_radio.sh 2>/dev/null | head -1 || true)
if [[ -z $CERTS_EINES ]]; then                 # instalaciones antiguas: ¿dónde está la CA?
  for c in /root/certs-5g /opt/panel5g/certs-5g; do [[ -f $c/ca/ca.key ]] && { CERTS_EINES=$c; break; }; done
fi
if [[ -n $CERTS_EINES ]]; then
  install -d -m 755 /opt/agent5g/eines
  install -m 755 "$SRC/scripts/gen_certs.sh" "$SRC/scripts/emparella_radio.sh" "$SRC/scripts/emparella_upf.sh" /opt/agent5g/eines/
  sed -i "s#^CERTS=\${2:-/root/certs-5g}#CERTS=\${2:-$CERTS_EINES}#" /opt/agent5g/eines/emparella_radio.sh /opt/agent5g/eines/emparella_upf.sh
  ln -sf /opt/agent5g/eines/emparella_radio.sh /usr/local/sbin/emparella-radio
  ln -sf /opt/agent5g/eines/emparella_upf.sh /usr/local/sbin/emparella-upf
  echo ">> emparella-radio <nombre> y emparella-upf <nombre> instalados (CA en $CERTS_EINES)"
else
  echo ">> AVISO: no encuentro la CA (ca/ca.key): emparella_radio.sh <nombre> <carpeta_certs> a mano"
fi
[[ -s /etc/agent5g/core_ip ]] || printf '%s\n' "$PANEL_IP" > /etc/agent5g/core_ip
if (( AMB_PANELL )); then
cp -a "$PANEL_DIR/config/panel.yaml" "$BK/"
python3 - "$PANEL_DIR/config/panel.yaml" <<'PY'
import re, sys
f = sys.argv[1]
ls = open(f).read().split('\n')
out, dins, canvi, sec = [], False, False, None
for l in ls:
    m = re.match(r'^([A-Za-z_]\w*):', l)
    if m:
        sec = m.group(1)                 # solo dentro de "agents:" (estat_logs también tiene "radio:")
    if sec == 'agents' and re.match(r'^  radio:', l):
        dins = True
        canvi = True
        out.append('  # (enlace radio -> core: la radio ya no va aquí, llama sola al core)')
        out.append('# ' + l)
        continue
    if dins and re.match(r'^    \S', l):
        out.append('# ' + l)
        continue
    dins = False
    out.append(l)
if canvi:
    print('>> panel.yaml: comentada la radio fija (ahora la radio llama al core)')
# indicadores del estado de los PCs con UPF separado (rol "upf"), si todavía no están
txt = '\n'.join(out)
if re.search(r'^estat_logs:', txt, re.M) and not re.search(r'^  upf:', txt, re.M):
    txt = re.sub(r'^estat_logs:[^\n]*\n', lambda m: m.group(0) +
                 '  upf:\n'
                 '    - {etiqueta: "Sessions UPF",            contenidor: upf, regex: "Number of UPF-Sessions is now (\\\\d+)"}\n'
                 '    - {etiqueta: "PFCP amb l\'SMF",          contenidor: upf, regex: "(PFCP (?:de-)?associated.*)$"}\n',
                 txt, count=1, flags=re.M)
    canvi = True
    print('>> panel.yaml: añadido el estado de los PCs con UPF')
if canvi:
    open(f, 'w').write(txt)
PY
fi   # AMB_PANELL
systemctl daemon-reload
systemctl enable --now ua-capture
systemctl restart agent5g
if (( AMB_PANELL )); then (cd "$PANEL_DIR" && PANEL_IP="$PANEL_IP" docker compose up -d --build); fi
sleep 4
systemctl --no-pager --lines=0 status ua-capture agent5g | grep -E '●|Active:' || true
if systemctl is-active -q ua-capture && systemctl is-active -q agent5g; then
  echo ">> Hecho. Panel: https://$PANEL_IP:8443 (Ctrl+F5): la versión sale en la barra lateral."
  echo "   VoIP: Abonados y VoIP > Servicio de telefonía > Activado (el core 5G no se para)."
  echo "   Radios: en el core, sudo emparella-radio <nombre>; en la radio, sudo agent5g > Renovar el certificado"
  echo "   (radio ya instalada) o install_radio.sh (nueva). La radio llama sola al core $PANEL_IP:9544."
  echo "   UPF en otro PC: en el core, sudo emparella-upf <nombre>; en ese PC, sudo bash scripts/install_upf.sh"
  echo "   (pestaña UPF del panel: separar o volver a juntar el UPF)."
else
  echo ">> ALERTA: algún servicio no ha arrancado. Para volver atrás:"
  echo "   systemctl disable --now ua-capture; cp $BK/agent5g.py /opt/agent5g/; systemctl restart agent5g"
  echo "   cp -a $BK/app/. $PANEL_DIR/app/; cp $BK/schema.yaml $BK/panel.yaml $PANEL_DIR/config/"
  echo "   cd $PANEL_DIR && PANEL_IP=$PANEL_IP docker compose up -d --build"
  exit 1
fi
