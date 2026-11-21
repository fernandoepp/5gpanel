#!/usr/bin/env bash
# Emet el certificat d'una ràdio i imprimeix el CODI D'EMPARELLAMENT que cal enganxar
# a install_radio.sh. S'executa al core, que és on hi ha la CA.
#
#   sudo ./emparella_radio.sh <IP_de_la_ràdio> [carpeta_certs]      (per defecte /root/certs-5g)
#
# El codi porta ca.crt + el certificat i la clau de l'agent d'aquesta ràdio (val només
# per a aquesta IP). No porta mai ca.key. Es desa també a <certs>/emparellament-<IP>.txt
# per si el vols copiar amb scp en lloc d'enganxar-lo.
set -euo pipefail
RIP=${1:?IP de la ràdio}
CERTS=${2:-/root/certs-5g}
[[ $EUID -eq 0 ]] || { echo "Executa amb sudo"; exit 1; }
[[ $RIP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "IP invàlida: $RIP"; exit 1; }
SRC=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
[[ -f "$CERTS/ca/ca.key" ]] || { echo "No trobo la CA a $CERTS/ca (s'instal·la amb el core)"; exit 1; }
D="$CERTS/agent-radio-$RIP"
if [[ ! -f "$D/agent-radio.crt" ]]; then
  bash "$SRC/gen_certs.sh" --radio "$RIP" "$CERTS" >/dev/null
fi
OUT="$CERTS/emparellament-$RIP.txt"
(
  umask 077
  {
    echo "-----BEGIN 5GPANEL EMPARELLAMENT $RIP-----"
    tar czf - -C "$D" ca.crt agent-radio.crt agent-radio.key | base64 -w 76
    echo "-----END 5GPANEL EMPARELLAMENT-----"
  } > "$OUT"
)
echo
echo "================ CODI D'EMPARELLAMENT DE LA RÀDIO $RIP ================"
echo "Copia des de la línia BEGIN fins a la línia END (incloses) i enganxa-ho"
echo "quan install_radio.sh ho demani. Conté la clau privada de l'agent d'aquesta ràdio:"
echo "no el publiquis. Desat també a $OUT"
echo
cat "$OUT"
echo
echo "======================================================================"
