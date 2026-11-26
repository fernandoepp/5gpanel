#!/usr/bin/env bash
# Passa una ràdio JA INSTAL·LADA a l'enllaç ràdio -> core: a partir d'ara és la ràdio qui
# truca al core (port 9544) i l'agent deixa d'escoltar el 9543. No toca el gNB, el .env
# ni el docker-compose; de /etc/agent5g/agent5g.json només canvia listen/core/core_port.
#
#   (al core)    sudo emparella-radio <nom>            -> codi d'emparellament
#   (a la ràdio) sudo bash scripts/enllaca_radio.sh codi.txt
#                (sense fitxer: enganxa el codi quan el demani)
# Tornar enrere: es desa còpia de l'agent, la configuració i els certificats a /var/lib/agent5g/bak-enllac-*.
set -euo pipefail
SRC="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
[[ $EUID -eq 0 ]] || { echo "Cal executar-ho amb sudo"; exit 1; }
[[ -f /etc/agent5g/agent5g.json ]] || { echo "Aquesta ràdio no té l'agent instal·lat: fes servir install_radio.sh"; exit 1; }
CODI=""
if [[ -n ${1:-} ]]; then CODI="$(cat "$1")"
else
  echo "Enganxa el codi d'emparellament (de la línia BEGIN a la línia END):"
  while IFS= read -r l; do CODI+="$l"$'\n'; [[ "$l" == "-----END 5GPANEL EMPARELLAMENT-----" ]] && break; done
fi
NOM="$(sed -n 's/^-----BEGIN 5GPANEL EMPARELLAMENT \([A-Za-z0-9_.-]*\)-----$/\1/p' <<<"$CODI" | head -1)"
[[ -n $NOM ]] || { echo "No trobo el codi (al core: sudo emparella-radio <nom>)"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sed -n '/^-----BEGIN/,/^-----END/{/^-----/d;p}' <<<"$CODI" | base64 -d | tar xzf - -C "$T" \
  || { echo "El codi està malmès (copia'l sencer)"; exit 1; }
for f in ca.crt agent-radio.crt agent-radio.key core; do
  [[ -s "$T/$f" ]] || { echo "Al codi hi falta $f: torna'l a generar al core amb la versió nova (sudo emparella-radio $NOM)"; exit 1; }
done
openssl verify -CAfile "$T/ca.crt" -purpose sslclient "$T/agent-radio.crt" >/dev/null 2>&1 \
  || { echo "El certificat del codi no serveix per trucar al core: torna'l a generar (sudo emparella-radio $NOM)"; exit 1; }
CORE="$(tr -d '[:space:]' < "$T/core")"
[[ $CORE =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]] || { echo "IP del core del codi invàlida: $CORE"; exit 1; }
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
if not cfg.get('name') or re.search(r'\d+\.\d+\.\d+\.\d+', cfg['name']):   # nom amb la IP: ja no té sentit
    cfg['name'] = f"Ràdio {os.environ['NOM']}"
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
  echo ">> Fet. La ràdio \"$NOM\" truca al core $CORE i ja surt al panell (còpia: $BK)."
  echo "   Certificats: /etc/agent5g/certs/ · configuració: /etc/agent5g/agent5g.json"
else
  echo ">> L'agent encara no ha pogut connectar amb el core $CORE (ho reintenta sol cada pocs segons)."
  echo "   Comprova que el core té l'agent nou (escolta al 9544) i mira: journalctl -u agent5g -n 20"
  echo "   Tornar enrere: cp -a $BK/agent5g.py /opt/agent5g/; cp -a $BK/agent5g.json /etc/agent5g/;"
  echo "                  cp -a $BK/certs/. /etc/agent5g/certs/; systemctl restart agent5g"
fi
