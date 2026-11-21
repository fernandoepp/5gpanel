#!/usr/bin/env bash
# Genera una CA pròpia i els certificats del panell i dels dos agents.
#   ./gen_certs.sh <IP_PC1_core> <IP_PC2_radio> [carpeta_sortida]
# Ràdios addicionals (el panell les troba sol si tenen agent amb certificat d'aquesta CA):
#   ./gen_certs.sh --radio <IP_radio> [carpeta_sortida]      -> <sortida>/agent-radio-<IP>/
#   (fa servir la CA que ja hi ha a <sortida>/ca; no en crea cap de nova)
# Només core + panell (sense ràdio; les ràdios s'afegeixen després amb --radio):
#   ./gen_certs.sh --core <IP_core> [carpeta_sortida]
# Resultat:
#   <sortida>/ca/            ca.key (GUARDA-LA FORA DELS PCs) i ca.crt
#   <sortida>/panel/         per a panel/certs (al PC on vagi el panell)
#   <sortida>/agent-core/    per a /etc/agent5g/certs al PC1
#   <sortida>/agent-radio/   per a /etc/agent5g/certs al PC2
# Els certificats valen per a qualsevol ubicació del panell: cada agent porta la
# seva IP LAN i també host.docker.internal/172.17.0.1 (quan el panell és al mateix PC).
set -euo pipefail
if [[ ${1:-} == --radio ]]; then
  RADIO_IP=${2:?IP de la ràdio nova}; OUT=${3:-./certs-5g}; DIES=${CORE5G_CERT_DIES:-825}
  [[ $RADIO_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "IP invàlida: $RADIO_IP"; exit 1; }
  [[ -f "$OUT/ca/ca.key" && -f "$OUT/ca/ca.crt" ]] || { echo "No trobo la CA a $OUT/ca (ca.key i ca.crt)"; exit 1; }
  NOMES_RADIO=1
elif [[ ${1:-} == --core ]]; then
  NOMES_RADIO=0; CORE_IP=${2:?IP del core}; RADIO_IP=""; OUT=${3:-./certs-5g}
else
  NOMES_RADIO=0
fi
if [[ $NOMES_RADIO == 0 ]]; then
if [[ ${1:-} != --core ]]; then
CORE_IP=${1:?IP del PC1 (core)}
RADIO_IP=${2:?IP del PC2 (ràdio)}
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

# emet <nom> <CN> <ús: serverAuth|clientAuth> <SAN o buit> <carpeta>
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
if [[ $NOMES_RADIO == 1 ]]; then
  D="$OUT/agent-radio-$RADIO_IP"; mkdir -p "$D"
  # mateix nom de fitxers que la ràdio principal: install_agent.sh radio <carpeta> funciona igual
  emet agent-radio "agent-radio-$RADIO_IP" serverAuth "IP:$RADIO_IP,$LOCAL" "$D"
  echo "Certificats de la ràdio $RADIO_IP a $D"
  echo " - A la ràdio: sudo scripts/install_agent.sh radio $D <IP_del_panell>"
  echo "   (a /etc/agent5g/agent5g.json: \"listen\": \"$RADIO_IP\", \"port\": 9543 i, si vols, \"name\": \"nom visible\")"
  echo " - El panell la troba sol en la següent cerca (cada 2 min) o amb 'Cerca equips'."
  exit 0
fi
emet panel5g-client panel5g     clientAuth ""                                             "$OUT/panel"
LOCAL="DNS:host.docker.internal,IP:172.17.0.1,IP:127.0.0.1"
emet panel5g-web    panel5g-web serverAuth "IP:$CORE_IP,${RADIO_IP:+IP:$RADIO_IP,}DNS:localhost,IP:127.0.0.1" "$OUT/panel"
emet agent-core     agent-core  serverAuth "IP:$CORE_IP,$LOCAL"  "$OUT/agent-core"
[[ -z $RADIO_IP ]] || emet agent-radio agent-radio serverAuth "IP:$RADIO_IP,$LOCAL" "$OUT/agent-radio"
openssl rand -base64 48 > "$OUT/panel/panel5g-session.secret"

echo "Certificats a $OUT"
echo " - Importa $OUT/ca/ca.crt com a CA de confiança als navegadors del laboratori."
echo " - Guarda $OUT/ca/ca.key fora dels PCs (USB): qui la tingui pot emetre clients vàlids."
