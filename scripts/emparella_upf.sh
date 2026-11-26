#!/usr/bin/env bash
# Emet el certificat d'un PC amb UPF i imprimeix el CODI D'EMPARELLAMENT que cal enganxar
# a install_upf.sh. S'executa al core, que és on hi ha la CA.
#
#   sudo emparella-upf <nom_del_upf> [carpeta_certs]      (per defecte /root/certs-5g)
#
# Com la ràdio: NO cal saber la IP del PC del UPF. És el PC del UPF qui truca al core; el
# core el reconeix pel certificat (CN agent-upf-<nom>), li passa la configuració i, si el
# mode automàtic és actiu, el fa servir (separa el UPF del core). El codi porta ca.crt, el
# certificat i la clau d'aquest UPF i la IP:port del core. No porta mai ca.key.
set -euo pipefail
NOM=${1:?nom del UPF (p. ex. upf1)}
CERTS=${2:-/root/certs-5g}
[[ $EUID -eq 0 ]] || { echo "Executa amb sudo"; exit 1; }
[[ $NOM =~ ^[A-Za-z0-9_.-]{1,52}$ ]] || { echo "Nom invàlid: $NOM (lletres, xifres, . _ -)"; exit 1; }
SRC=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
[[ -f "$CERTS/ca/ca.key" ]] || { echo "No trobo la CA a $CERTS/ca (s'instal·la amb el core)"; exit 1; }
CORE_IP=${CORE5G_CORE_IP:-$(cat /etc/agent5g/core_ip 2>/dev/null || true)}
[[ -n $CORE_IP ]] || CORE_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
[[ $CORE_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "No sé la IP del core: CORE5G_CORE_IP=<IP> emparella-upf $NOM"; exit 1; }
PORT=${CORE5G_ENLLAC_PORT:-9544}
D="$CERTS/agent-upf-$NOM"
[[ -f "$D/agent-upf.crt" ]] || bash "$SRC/gen_certs.sh" --upf "$NOM" "$CERTS" >/dev/null
printf '%s:%s\n' "$CORE_IP" "$PORT" > "$D/core"
OUT="$CERTS/emparellament-upf-$NOM.txt"
(
  umask 077
  {
    echo "-----BEGIN 5GPANEL UPF $NOM-----"
    tar czf - -C "$D" ca.crt agent-upf.crt agent-upf.key core | base64 -w 76
    echo "-----END 5GPANEL UPF-----"
  } > "$OUT"
)
echo
echo "================ CODI D'EMPARELLAMENT DEL UPF \"$NOM\" ================"
echo " 1. Copia des de la línia BEGIN fins a la línia END (incloses)."
echo " 2. Al PC del UPF, executa l'instal·lador i enganxa-ho quan ho demani:"
echo "      git clone https://github.com/fernandoepp/5gpanel && sudo bash 5gpanel/scripts/install_upf.sh"
echo " El PC del UPF trucarà sol al core $CORE_IP:$PORT. Quan truqui, el core li passarà la"
echo " configuració i, si el panell té el mode automàtic actiu, el farà servir (UPF separat)."
echo
cat "$OUT"
echo
echo " On queda cada cosa:"
echo "   Core (aquest PC):  codi            $OUT"
echo "                      certificat      $D/agent-upf.crt (i la clau agent-upf.key)"
echo "                      CA              $CERTS/ca/ (ca.key no surt mai d'aquí)"
echo "   PC del UPF:        certificats     /etc/agent5g-upf/certs/ (ca.crt, agent-upf.crt, agent-upf.key)"
echo "                      configuració    /etc/agent5g-upf/agent5g.json (\"core\": \"$CORE_IP\", \"core_port\": $PORT)"
echo "                      projecte UPF    /opt/upf5g/ (docker-compose.yml, .env, upf/)"
echo " El codi porta la clau privada d'aquest UPF: no el publiquis."
echo "======================================================================"
