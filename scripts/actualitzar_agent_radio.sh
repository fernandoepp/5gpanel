#!/usr/bin/env bash
# Actualitza NOMÉS l'agent5g de la ràdio (aquest PC, server2core5G): patró TDD, diversos PLMN i la resta
# d'endpoints nous. No toca el gNB, el .env, el docker-compose ni /etc/agent5g/agent5g.json.
#   sudo bash scripts/actualitzar_agent_radio.sh
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
[[ $EUID -eq 0 ]] || { echo "Cal executar-ho amb sudo"; exit 1; }
PYTHONDONTWRITEBYTECODE=1 python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SRC/agent/agent5g.py"
TS=$(date +%Y%m%d-%H%M%S)
cp -a /opt/agent5g/agent5g.py "/opt/agent5g/agent5g.py.bak-$TS"
install -m 755 -o root -g root "$SRC/agent/agent5g.py" /opt/agent5g/agent5g.py
systemctl restart agent5g
sleep 2
if systemctl is-active -q agent5g; then
  echo ">> Fet. Agent de la ràdio actualitzat (còpia: /opt/agent5g/agent5g.py.bak-$TS)."
  grep -rqs 'ReadWritePaths=' /etc/systemd/system/agent5g.service.d/ \
    || echo ">> ALERTA: el servei no té ReadWritePaths a la carpeta del projecte: no podrà desar el .env ni el compose."
else
  echo ">> ALERTA: l'agent no ha arrencat. Torna enrere amb:"
  echo "   cp /opt/agent5g/agent5g.py.bak-$TS /opt/agent5g/agent5g.py && systemctl restart agent5g"
  journalctl -u agent5g -n 20 --no-pager
  exit 1
fi
