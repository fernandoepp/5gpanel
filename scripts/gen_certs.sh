#!/usr/bin/env bash
# Genera una CA propia y los certificados del panel y de los dos agentes.
#   ./gen_certs.sh <IP_PC1_core> <IP_PC2_radio> [carpeta_sortida]
# Radios (normalmente lo hace emparella_radio.sh, en el core):
#   ./gen_certs.sh --radio <nombre_radio> [carpeta_salida]   -> <salida>/agent-radio-<nombre>/
#   El nombre identifica la radio (letras, cifras, . _ -; p. ej. aula2). NO hace falta la IP: la radio
#   llama al core (enlace radio -> core) y se identifica con este certificado (CN agent-radio-<nombre>).
#   Si el nombre es una IP, el certificado también vale para el acceso directo antiguo a esa IP.
#   (usa la CA que ya hay en <salida>/ca; no crea ninguna nueva)
# PCs con UPF separado (lo hace emparella_upf.sh, en el core):
#   ./gen_certs.sh --upf <nombre_upf> [carpeta_salida]         -> <salida>/agent-upf-<nombre>/
# IP nueva del core (lo hace el menú "sudo agent5g"): renueva agent-core y el web del panel
#   ./gen_certs.sh --renova <IP_nueva_core> [carpeta_salida]
# Solo core + panel (sin radio; las radios se añaden después con --radio):
#   ./gen_certs.sh --core <IP_core> [carpeta_salida]
# Resultat:
#   <salida>/ca/            ca.key (GUÁRDALA FUERA DE LOS PCs) y ca.crt
#   <salida>/panel/         para panel/certs (en el PC donde vaya el panel)
#   <salida>/agent-core/    para /etc/agent5g/certs en el PC1
#   <salida>/agent-radio/   para /etc/agent5g/certs en el PC2
# Los certificados valen para cualquier ubicación del panel: cada agente lleva su
# IP LAN y también host.docker.internal/172.17.0.1 (cuando el panel está en el mismo PC).
set -euo pipefail
if [[ ${1:-} == --radio ]]; then
  RADIO_NOM=${2:?nombre de la radio nueva}; OUT=${3:-./certs-5g}; DIES=${CORE5G_CERT_DIES:-825}
  [[ $RADIO_NOM =~ ^[A-Za-z0-9_.-]{1,52}$ ]] || { echo "Nombre de radio no válido: $RADIO_NOM (letras, cifras, . _ -)"; exit 1; }
  [[ -f "$OUT/ca/ca.key" && -f "$OUT/ca/ca.crt" ]] || { echo "No encuentro la CA en $OUT/ca (ca.key y ca.crt)"; exit 1; }
  NOMES_RADIO=1
elif [[ ${1:-} == --upf ]]; then
  UPF_NOM=${2:?nombre del UPF nuevo}; OUT=${3:-./certs-5g}; DIES=${CORE5G_CERT_DIES:-825}
  [[ $UPF_NOM =~ ^[A-Za-z0-9_.-]{1,52}$ ]] || { echo "Nombre de UPF no válido: $UPF_NOM (letras, cifras, . _ -)"; exit 1; }
  [[ -f "$OUT/ca/ca.key" && -f "$OUT/ca/ca.crt" ]] || { echo "No encuentro la CA en $OUT/ca (ca.key y ca.crt)"; exit 1; }
  NOMES_RADIO=2
elif [[ ${1:-} == --renova ]]; then
  # IP nueva del core: se vuelven a emitir el certificado del agente del core y el web del panel
  # con la misma CA (radios, UPF y navegadores que ya confían en la CA no se tienen que tocar)
  CORE_IP=${2:?IP nueva del core}; OUT=${3:-./certs-5g}; DIES=${CORE5G_CERT_DIES:-825}
  [[ -f "$OUT/ca/ca.key" && -f "$OUT/ca/ca.crt" ]] || { echo "No encuentro la CA en $OUT/ca (ca.key y ca.crt)"; exit 1; }
  NOMES_RADIO=3
elif [[ ${1:-} == --core ]]; then
  NOMES_RADIO=0; CORE_IP=${2:?IP del core}; RADIO_IP=""; OUT=${3:-./certs-5g}
else
  NOMES_RADIO=0
fi
if [[ $NOMES_RADIO == 0 ]]; then
if [[ ${1:-} != --core ]]; then
CORE_IP=${1:?IP del PC1 (core)}
RADIO_IP=${2:?IP del PC2 (radio)}
OUT=${3:-./certs-5g}
fi
DIES=${CORE5G_CERT_DIES:-825}
umask 077
mkdir -p "$OUT"/{ca,panel,agent-core,agent-radio}
fi
umask 077

if [[ $NOMES_RADIO == 0 && ! -f "$OUT/ca/ca.key" ]]; then
  openssl ecparam -name prime256v1 -genkey -noout -out "$OUT/ca/ca.key"
  openssl req -x509 -new -key "$OUT/ca/ca.key" -sha256 -days 3650 \
    -subj "/CN=CA Panell 5G" -out "$OUT/ca/ca.crt" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
fi

# emet <nombre> <CN> <uso: serverAuth|clientAuth> <SAN o vacío> <carpeta>
emet() {
  local nom=$1 cn=$2 us=$3 san=$4 dir=$5 ext
  ext=$(mktemp)
  {
    echo "basicConstraints=critical,CA:FALSE"
    echo "keyUsage=critical,digitalSignature"
    echo "extendedKeyUsage=$us"
    [[ -n $san ]] && echo "subjectAltName=$san"
  } > "$ext"
  openssl ecparam -name prime256v1 -genkey -noout -out "$dir/$nom.key"
  openssl req -new -key "$dir/$nom.key" -subj "/CN=$cn" -out "$dir/$nom.csr"
  openssl x509 -req -in "$dir/$nom.csr" -CA "$OUT/ca/ca.crt" -CAkey "$OUT/ca/ca.key" \
    -CAcreateserial -days "$DIES" -sha256 -extfile "$ext" -out "$dir/$nom.crt" 2>/dev/null
  rm -f "$dir/$nom.csr" "$ext"
  cp "$OUT/ca/ca.crt" "$dir/ca.crt"
}

LOCAL="DNS:host.docker.internal,IP:172.17.0.1,IP:127.0.0.1"
if [[ $NOMES_RADIO == 3 ]]; then
  mkdir -p "$OUT/agent-core" "$OUT/panel"
  emet agent-core    agent-core  serverAuth "IP:$CORE_IP,$LOCAL" "$OUT/agent-core"
  emet panel5g-web   panel5g-web serverAuth "IP:$CORE_IP,DNS:localhost,IP:127.0.0.1" "$OUT/panel"
  echo "Certificados del agente del core y del web del panel renovados para $CORE_IP (misma CA)"
  exit 0
fi
if [[ $NOMES_RADIO == 2 ]]; then
  # PC con UPF: como la radio, llama al core (cliente TLS) y se identifica por el CN agent-upf-<nombre>
  D="$OUT/agent-upf-$UPF_NOM"; mkdir -p "$D"
  emet agent-upf "agent-upf-$UPF_NOM" clientAuth "" "$D"
  echo "Certificados del UPF $UPF_NOM en $D"
  exit 0
fi
if [[ $NOMES_RADIO == 1 ]]; then
  D="$OUT/agent-radio-$RADIO_NOM"; mkdir -p "$D"
  SAN=$LOCAL
  [[ $RADIO_NOM =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && SAN="IP:$RADIO_NOM,$LOCAL"
  # clientAuth: la radio es cliente TLS cuando llama al core; serverAuth: acceso directo antiguo
  # mismo nombre de ficheros que la radio principal: install_agent.sh radio <carpeta> funciona igual
  emet agent-radio "agent-radio-$RADIO_NOM" serverAuth,clientAuth "$SAN" "$D"
  echo "Certificados de la radio $RADIO_NOM en $D"
  exit 0
fi
emet panel5g-client panel5g     clientAuth ""                                             "$OUT/panel"
LOCAL="DNS:host.docker.internal,IP:172.17.0.1,IP:127.0.0.1"
emet panel5g-web    panel5g-web serverAuth "IP:$CORE_IP,${RADIO_IP:+IP:$RADIO_IP,}DNS:localhost,IP:127.0.0.1" "$OUT/panel"
emet agent-core     agent-core  serverAuth "IP:$CORE_IP,$LOCAL"  "$OUT/agent-core"
[[ -z $RADIO_IP ]] || emet agent-radio agent-radio serverAuth,clientAuth "IP:$RADIO_IP,$LOCAL" "$OUT/agent-radio"
openssl rand -base64 48 > "$OUT/panel/panel5g-session.secret"

echo "Certificados en $OUT"
echo " - Importa $OUT/ca/ca.crt como CA de confianza en los navegadores del laboratorio."
echo " - Guarda $OUT/ca/ca.key fuera de los PCs (USB): quien la tenga puede emitir clientes válidos."
