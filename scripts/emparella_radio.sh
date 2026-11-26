#!/usr/bin/env bash
# Emite el certificado de una radio e imprime el CÓDIGO DE EMPAREJAMIENTO que hay que pegar
# en install_radio.sh. Se ejecuta en el core, que es donde está la CA.
#
#   sudo emparella-radio <nombre_de_la_radio> [carpeta_certs]      (por defecto /root/certs-5g)
#   sudo emparella-radio --nou <nombre>   (certificado nuevo: para renovarlo en la radio con sudo agent5g)
#
# El nombre identifica la radio en el panel (p. ej. aula2, radio1; letras, cifras, . _ -).
# NO hace falta saber la IP de la radio: es la radio la que llama al core (como la gNodeB al AMF).
# El código lleva: ca.crt, el certificado y la clave del agente de esta radio y la IP:puerto del
# core al que tiene que llamar. Nunca lleva ca.key. Se guarda también en <certs>/emparellament-<nombre>.txt.
# IP del core: CORE5G_CORE_IP=... o la que guardó install_core.sh (/etc/agent5g/core_ip).
set -euo pipefail
# --nou (o --nuevo): vuelve a emitir el certificado aunque ya haya uno (renovarlo). También se
# renueva solo si caduca en menos de 30 días o si no es de la CA actual.
NOU=0; a=(); for x in "$@"; do if [[ $x == --nou || $x == --nuevo ]]; then NOU=1; else a+=("$x"); fi; done; set -- "${a[@]}"
NOM=${1:?nombre de la radio (p. ej. aula2)}
CERTS=${2:-/root/certs-5g}
[[ $EUID -eq 0 ]] || { echo "Ejecútalo con sudo"; exit 1; }
[[ $NOM =~ ^[A-Za-z0-9_.-]{1,52}$ ]] || { echo "Nombre no válido: $NOM (letras, cifras, . _ -)"; exit 1; }
SRC=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
[[ -f "$CERTS/ca/ca.key" ]] || { echo "No encuentro la CA en $CERTS/ca (se instala con el core)"; exit 1; }
CORE_IP=${CORE5G_CORE_IP:-$(cat /etc/agent5g/core_ip 2>/dev/null || true)}
[[ -n $CORE_IP ]] || CORE_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
[[ $CORE_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "No sé la IP del core: CORE5G_CORE_IP=<IP> emparella-radio $NOM"; exit 1; }
PORT=${CORE5G_ENLLAC_PORT:-9544}
D="$CERTS/agent-radio-$NOM"
# certificado nuevo si no lo hay, si se pide (--nou), si es de antes del enlace radio -> core
# (sin clientAuth), si no es de la CA actual o si caduca en menos de 30 días
C="$D/agent-radio.crt"
if (( NOU )) || [[ ! -f "$C" ]] \
   || ! openssl x509 -in "$C" -noout -ext extendedKeyUsage 2>/dev/null | grep -q 'Client Authentication' \
   || ! openssl verify -CAfile "$CERTS/ca/ca.crt" "$C" >/dev/null 2>&1 \
   || ! openssl x509 -in "$C" -noout -checkend 2592000 >/dev/null 2>&1; then
  bash "$SRC/gen_certs.sh" --radio "$NOM" "$CERTS" >/dev/null
  echo "Certificado nuevo para la radio $NOM (caduca el $(openssl x509 -in "$C" -noout -enddate | cut -d= -f2))"
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
echo "================ CÓDIGO DE EMPAREJAMIENTO DE LA RADIO \"$NOM\" ================"
echo " 1. Copia desde la línea BEGIN hasta la línea END (incluidas)."
echo " 2. En la radio, ejecuta el instalador y pégalo cuando lo pida:"
echo "      git clone https://github.com/fernandoepp/5gpanel && sudo bash 5gpanel/scripts/install_radio.sh"
echo "    (radio ya instalada: sudo agent5g > Renovar el certificado, o sudo bash 5gpanel/scripts/enllaca_radio.sh)"
echo " La radio llamará sola al core $CORE_IP:$PORT: no hace falta saber su IP."
echo
cat "$OUT"
echo
echo " Dónde queda cada cosa:"
echo "   Core (este PC):    código          $OUT"
echo "                      certificado     $D/agent-radio.crt (y la clave agent-radio.key)"
echo "                      CA              $CERTS/ca/ (ca.key nunca sale de aquí)"
echo "   Radio:             certificados    /etc/agent5g/certs/ (ca.crt, agent-radio.crt, agent-radio.key)"
echo "                      configuración   /etc/agent5g/agent5g.json (\"core\": \"$CORE_IP\", \"core_port\": $PORT)"
echo " El código lleva la clave privada de esta radio: no lo publiques."
echo "==========================================================================="
