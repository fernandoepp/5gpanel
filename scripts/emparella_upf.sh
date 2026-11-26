#!/usr/bin/env bash
# Emite el certificado de un PC con UPF e imprime el CÓDIGO DE EMPAREJAMIENTO que hay que pegar
# en install_upf.sh. Se ejecuta en el core, que es donde está la CA.
#
#   sudo emparella-upf <nombre_del_upf> [carpeta_certs]      (por defecto /root/certs-5g)
#   sudo emparella-upf --nou <nombre>   (certificado nuevo: para renovarlo en el PC del UPF con sudo agent5g)
#
# Como la radio: NO hace falta saber la IP del PC del UPF. Es el PC del UPF el que llama al core; el
# core lo reconoce por el certificado (CN agent-upf-<nombre>), le pasa la configuración y, si el
# modo automático está activo, lo usa (separa el UPF del core). El código lleva ca.crt, el
# certificado y la clave de este UPF y la IP:puerto del core. Nunca lleva ca.key.
set -euo pipefail
# --nou (o --nuevo): vuelve a emitir el certificado aunque ya haya uno (renovarlo). También se
# renueva solo si caduca en menos de 30 días o si no es de la CA actual.
NOU=0; a=(); for x in "$@"; do if [[ $x == --nou || $x == --nuevo ]]; then NOU=1; else a+=("$x"); fi; done; set -- "${a[@]}"
NOM=${1:?nombre del UPF (p. ej. upf1)}
CERTS=${2:-/root/certs-5g}
[[ $EUID -eq 0 ]] || { echo "Ejecútalo con sudo"; exit 1; }
[[ $NOM =~ ^[A-Za-z0-9_.-]{1,52}$ ]] || { echo "Nombre no válido: $NOM (letras, cifras, . _ -)"; exit 1; }
SRC=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
[[ -f "$CERTS/ca/ca.key" ]] || { echo "No encuentro la CA en $CERTS/ca (se instala con el core)"; exit 1; }
CORE_IP=${CORE5G_CORE_IP:-$(cat /etc/agent5g/core_ip 2>/dev/null || true)}
[[ -n $CORE_IP ]] || CORE_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
[[ $CORE_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "No sé la IP del core: CORE5G_CORE_IP=<IP> emparella-upf $NOM"; exit 1; }
PORT=${CORE5G_ENLLAC_PORT:-9544}
D="$CERTS/agent-upf-$NOM"
C="$D/agent-upf.crt"
if (( NOU )) || [[ ! -f "$C" ]] \
   || ! openssl verify -CAfile "$CERTS/ca/ca.crt" "$C" >/dev/null 2>&1 \
   || ! openssl x509 -in "$C" -noout -checkend 2592000 >/dev/null 2>&1; then
  bash "$SRC/gen_certs.sh" --upf "$NOM" "$CERTS" >/dev/null
  echo "Certificado nuevo para el UPF $NOM (caduca el $(openssl x509 -in "$C" -noout -enddate | cut -d= -f2))"
fi
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
echo "================ CÓDIGO DE EMPAREJAMIENTO DEL UPF \"$NOM\" ================"
echo " 1. Copia desde la línea BEGIN hasta la línea END (incluidas)."
echo " 2. En el PC del UPF, ejecuta el instalador y pégalo cuando lo pida:"
echo "      git clone https://github.com/fernandoepp/5gpanel && sudo bash 5gpanel/scripts/install_upf.sh"
echo " El PC del UPF llamará solo al core $CORE_IP:$PORT. Cuando llame, el core le pasará la"
echo " configuración y, si el panel tiene el modo automático activo, lo usará (UPF separado)."
echo
cat "$OUT"
echo
echo " Dónde queda cada cosa:"
echo "   Core (este PC):    código          $OUT"
echo "                      certificado     $D/agent-upf.crt (y la clave agent-upf.key)"
echo "                      CA              $CERTS/ca/ (ca.key nunca sale de aquí)"
echo "   PC del UPF:        certificados    /etc/agent5g-upf/certs/ (ca.crt, agent-upf.crt, agent-upf.key)"
echo "                      configuración   /etc/agent5g-upf/agent5g.json (\"core\": \"$CORE_IP\", \"core_port\": $PORT)"
echo "                      proyecto UPF    /opt/upf5g/ (docker-compose.yml, .env, upf/)"
echo " El código lleva la clave privada de este UPF: no lo publiques."
echo "======================================================================"
