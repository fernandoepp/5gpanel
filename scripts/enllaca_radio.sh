#!/usr/bin/env bash
# Pasa una radio YA INSTALADA al enlace radio -> core: a partir de ahora es la radio la que
# llama al core (puerto 9544) y el agente deja de escuchar en el 9543. No toca el gNB, el .env
# ni el docker-compose; de /etc/agent5g/agent5g.json solo cambia listen/core/core_port.
#
#   (en el core)   sudo emparella-radio <nombre>         -> código de emparejamiento
#   (en la radio)  sudo bash scripts/enllaca_radio.sh codigo.txt
#                  (sin fichero: pega el código cuando lo pida)
# Volver atrás: se guarda copia del agente, la configuración y los certificados en /var/lib/agent5g/bak-enllac-*.
set -euo pipefail
SRC="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
[[ $EUID -eq 0 ]] || { echo "Hay que ejecutarlo con sudo"; exit 1; }
[[ -f /etc/agent5g/agent5g.json ]] || { echo "Esta radio no tiene el agente instalado: usa install_radio.sh"; exit 1; }
CODI=""
if [[ -n ${1:-} ]]; then CODI="$(cat "$1")"
else
  echo "Pega el código de emparejamiento (de la línea BEGIN a la línea END):"
  while IFS= read -r l; do CODI+="$l"$'\n'; [[ "$l" == "-----END 5GPANEL EMPARELLAMENT-----" ]] && break; done
fi
NOM="$(sed -n 's/^-----BEGIN 5GPANEL EMPARELLAMENT \([A-Za-z0-9_.-]*\)-----$/\1/p' <<<"$CODI" | head -1)"
[[ -n $NOM ]] || { echo "No encuentro el código (en el core: sudo emparella-radio <nombre>)"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sed -n '/^-----BEGIN/,/^-----END/{/^-----/d;p}' <<<"$CODI" | base64 -d | tar xzf - -C "$T" \
  || { echo "El código está dañado (cópialo entero)"; exit 1; }
for f in ca.crt agent-radio.crt agent-radio.key core; do
  [[ -s "$T/$f" ]] || { echo "Al código le falta $f: vuelve a generarlo en el core con la versión nueva (sudo emparella-radio $NOM)"; exit 1; }
done
openssl verify -CAfile "$T/ca.crt" -purpose sslclient "$T/agent-radio.crt" >/dev/null 2>&1 \
  || { echo "El certificado del código no sirve para llamar al core: vuelve a generarlo (sudo emparella-radio $NOM)"; exit 1; }
CORE="$(tr -d '[:space:]' < "$T/core")"
[[ $CORE =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]] || { echo "IP del core del código no válida: $CORE"; exit 1; }
PYTHONDONTWRITEBYTECODE=1 python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SRC/agent/agent5g.py"

BK=/var/lib/agent5g/bak-enllac-$(date +%Y%m%d-%H%M%S); install -d -m 700 "$BK"
cp -a /opt/agent5g/agent5g.py /etc/agent5g/agent5g.json /etc/agent5g/certs "$BK/"
install -m 755 -o root -g root "$SRC/agent/agent5g.py" /opt/agent5g/agent5g.py
install -m 600 "$T/ca.crt" "$T/agent-radio.crt" "$T/agent-radio.key" /etc/agent5g/certs/
NOM="$NOM" CORE="$CORE" python3 - <<'PY'
import json, os, re
f = '/etc/agent5g/agent5g.json'
cfg = json.load(open(f))
ip, port = os.environ['CORE'].rsplit(':', 1)
cfg.update(listen=None, core=ip, core_port=int(port),
           cert='/etc/agent5g/certs/agent-radio.crt', key='/etc/agent5g/certs/agent-radio.key',
           ca='/etc/agent5g/certs/ca.crt')
if not cfg.get('name') or re.search(r'\d+\.\d+\.\d+\.\d+', cfg['name']):   # nombre con la IP: ya no tiene sentido
    cfg['name'] = f"Radio {os.environ['NOM']}"
with open(f + '.nou', 'w') as fh:
    json.dump(cfg, fh, indent=2, ensure_ascii=False)
os.chmod(f + '.nou', 0o600)
os.replace(f + '.nou', f)
PY
systemctl restart agent5g
for _ in $(seq 1 10); do
  journalctl -u agent5g --since "-30s" --no-pager 2>/dev/null | grep -q "connectat al core" && break
  sleep 1
done
if journalctl -u agent5g --since "-30s" --no-pager 2>/dev/null | grep -q "connectat al core"; then
  echo ">> Hecho. La radio \"$NOM\" llama al core $CORE y ya sale en el panel (copia: $BK)."
  echo "   Certificados: /etc/agent5g/certs/ · configuración: /etc/agent5g/agent5g.json"
else
  echo ">> El agente todavía no ha podido conectar con el core $CORE (lo reintenta solo cada pocos segundos)."
  echo "   Comprueba que el core tiene el agente nuevo (escucha en el 9544) y mira: journalctl -u agent5g -n 20"
  echo "   Volver atrás: cp -a $BK/agent5g.py /opt/agent5g/; cp -a $BK/agent5g.json /etc/agent5g/;"
  echo "                  cp -a $BK/certs/. /etc/agent5g/certs/; systemctl restart agent5g"
fi
