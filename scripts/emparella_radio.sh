#!/usr/bin/env bash
# Emet el certificat d'una ràdio i imprimeix el CODI D'EMPARELLAMENT que cal enganxar
# a install_radio.sh. S'executa al core, que és on hi ha la CA.
#
#   sudo emparella-radio <nom_de_la_ràdio> [carpeta_certs]      (per defecte /root/certs-5g)
#
# El nom identifica la ràdio al panell (p. ex. aula2, radio1; lletres, xifres, . _ -).
# NO cal saber la IP de la ràdio: és la ràdio qui truca al core (com la gNodeB a l'AMF).
# El codi porta: ca.crt, el certificat i la clau de l'agent d'aquesta ràdio i la IP:port del
# core on ha de trucar. No porta mai ca.key. Es desa també a <certs>/emparellament-<nom>.txt.
# IP del core: CORE5G_CORE_IP=... o la que va desar install_core.sh (/etc/agent5g/core_ip).
set -euo pipefail
NOM=${1:?nom de la ràdio (p. ex. aula2)}
CERTS=${2:-/root/certs-5g}
[[ $EUID -eq 0 ]] || { echo "Executa amb sudo"; exit 1; }
[[ $NOM =~ ^[A-Za-z0-9_.-]{1,52}$ ]] || { echo "Nom invàlid: $NOM (lletres, xifres, . _ -)"; exit 1; }
SRC=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
[[ -f "$CERTS/ca/ca.key" ]] || { echo "No trobo la CA a $CERTS/ca (s'instal·la amb el core)"; exit 1; }
CORE_IP=${CORE5G_CORE_IP:-$(cat /etc/agent5g/core_ip 2>/dev/null || true)}
[[ -n $CORE_IP ]] || CORE_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
[[ $CORE_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "No sé la IP del core: CORE5G_CORE_IP=<IP> emparella-radio $NOM"; exit 1; }
PORT=${CORE5G_ENLLAC_PORT:-9544}
D="$CERTS/agent-radio-$NOM"
# certificat nou si no n'hi ha o si és d'abans de l'enllaç ràdio -> core (sense clientAuth)
if [[ ! -f "$D/agent-radio.crt" ]] || ! openssl x509 -in "$D/agent-radio.crt" -noout -ext extendedKeyUsage 2>/dev/null | grep -q 'Client Authentication'; then
  bash "$SRC/gen_certs.sh" --radio "$NOM" "$CERTS" >/dev/null
fi
printf '%s:%s\n' "$CORE_IP" "$PORT" > "$D/core"
OUT="$CERTS/emparellament-$NOM.txt"
(
  umask 077
  {
    echo "-----BEGIN 5GPANEL EMPARELLAMENT $NOM-----"
    tar czf - -C "$D" ca.crt agent-radio.crt agent-radio.key core | base64 -w 76
    echo "-----END 5GPANEL EMPARELLAMENT-----"
  } > "$OUT"
)
echo
echo "============ CODI D'EMPARELLAMENT DE LA RÀDIO \"$NOM\" (core $CORE_IP:$PORT) ============"
echo "Copia des de la línia BEGIN fins a la línia END (incloses) i enganxa-ho quan"
echo "install_radio.sh ho demani. La ràdio trucarà sola al core: no cal saber-ne la IP."
echo "Conté la clau privada de l'agent d'aquesta ràdio: no el publiquis. Desat també a $OUT"
echo
cat "$OUT"
echo
echo "======================================================================================"
