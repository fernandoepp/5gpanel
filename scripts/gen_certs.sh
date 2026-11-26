#!/usr/bin/env bash
# Genera una CA pròpia i els certificats del panell i dels dos agents.
#   ./gen_certs.sh <IP_PC1_core> <IP_PC2_radio> [carpeta_sortida]
# Ràdios (normalment ho fa emparella_radio.sh, al core):
#   ./gen_certs.sh --radio <nom_radio> [carpeta_sortida]     -> <sortida>/agent-radio-<nom>/
#   El nom identifica la ràdio (lletres, xifres, . _ -; p. ex. aula2). NO cal la IP: la ràdio
#   truca al core (enllaç ràdio -> core) i s'identifica amb aquest certificat (CN agent-radio-<nom>).
#   Si el nom és una IP, el certificat també val per a l'accés directe antic a aquella IP.
#   (fa servir la CA que ja hi ha a <sortida>/ca; no en crea cap de nova)
# PCs amb UPF separat (ho fa emparella_upf.sh, al core):
#   ./gen_certs.sh --upf <nom_upf> [carpeta_sortida]           -> <sortida>/agent-upf-<nom>/
# IP nova del core (ho fa el menú "sudo agent5g"): renova agent-core i el web del panell
#   ./gen_certs.sh --renova <IP_nova_core> [carpeta_sortida]
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
  RADIO_NOM=${2:?nom de la ràdio nova}; OUT=${3:-./certs-5g}; DIES=${CORE5G_CERT_DIES:-825}
  [[ $RADIO_NOM =~ ^[A-Za-z0-9_.-]{1,52}$ ]] || { echo "Nom de ràdio invàlid: $RADIO_NOM (lletres, xifres, . _ -)"; exit 1; }
  [[ -f "$OUT/ca/ca.key" && -f "$OUT/ca/ca.crt" ]] || { echo "No trobo la CA a $OUT/ca (ca.key i ca.crt)"; exit 1; }
  NOMES_RADIO=1
elif [[ ${1:-} == --upf ]]; then
  UPF_NOM=${2:?nom del UPF nou}; OUT=${3:-./certs-5g}; DIES=${CORE5G_CERT_DIES:-825}
  [[ $UPF_NOM =~ ^[A-Za-z0-9_.-]{1,52}$ ]] || { echo "Nom de UPF invàlid: $UPF_NOM (lletres, xifres, . _ -)"; exit 1; }
  [[ -f "$OUT/ca/ca.key" && -f "$OUT/ca/ca.crt" ]] || { echo "No trobo la CA a $OUT/ca (ca.key i ca.crt)"; exit 1; }
  NOMES_RADIO=2
elif [[ ${1:-} == --renova ]]; then
  # IP nova del core: es tornen a emetre el certificat de l'agent del core i el web del panell
  # amb la mateixa CA (ràdios, UPF i navegadors que ja confien en la CA no s'han de tocar)
  CORE_IP=${2:?IP nova del core}; OUT=${3:-./certs-5g}; DIES=${CORE5G_CERT_DIES:-825}
  [[ -f "$OUT/ca/ca.key" && -f "$OUT/ca/ca.crt" ]] || { echo "No trobo la CA a $OUT/ca (ca.key i ca.crt)"; exit 1; }
  NOMES_RADIO=3
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
if [[ $NOMES_RADIO == 3 ]]; then
  mkdir -p "$OUT/agent-core" "$OUT/panel"
  emet agent-core    agent-core  serverAuth "IP:$CORE_IP,$LOCAL" "$OUT/agent-core"
  emet panel5g-web   panel5g-web serverAuth "IP:$CORE_IP,DNS:localhost,IP:127.0.0.1" "$OUT/panel"
  echo "Certificats de l'agent del core i del web del panell renovats per a $CORE_IP (mateixa CA)"
  exit 0
fi
if [[ $NOMES_RADIO == 2 ]]; then
  # PC amb UPF: com la ràdio, truca al core (client TLS) i s'identifica pel CN agent-upf-<nom>
  D="$OUT/agent-upf-$UPF_NOM"; mkdir -p "$D"
  emet agent-upf "agent-upf-$UPF_NOM" clientAuth "" "$D"
  echo "Certificats del UPF $UPF_NOM a $D"
  exit 0
fi
if [[ $NOMES_RADIO == 1 ]]; then
  D="$OUT/agent-radio-$RADIO_NOM"; mkdir -p "$D"
  SAN=$LOCAL
  [[ $RADIO_NOM =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && SAN="IP:$RADIO_NOM,$LOCAL"
  # clientAuth: la ràdio és client TLS quan truca al core; serverAuth: accés directe antic
  # mateix nom de fitxers que la ràdio principal: install_agent.sh radio <carpeta> funciona igual
  emet agent-radio "agent-radio-$RADIO_NOM" serverAuth,clientAuth "$SAN" "$D"
  echo "Certificats de la ràdio $RADIO_NOM a $D"
  exit 0
fi
emet panel5g-client panel5g     clientAuth ""                                             "$OUT/panel"
LOCAL="DNS:host.docker.internal,IP:172.17.0.1,IP:127.0.0.1"
emet panel5g-web    panel5g-web serverAuth "IP:$CORE_IP,${RADIO_IP:+IP:$RADIO_IP,}DNS:localhost,IP:127.0.0.1" "$OUT/panel"
emet agent-core     agent-core  serverAuth "IP:$CORE_IP,$LOCAL"  "$OUT/agent-core"
[[ -z $RADIO_IP ]] || emet agent-radio agent-radio serverAuth,clientAuth "IP:$RADIO_IP,$LOCAL" "$OUT/agent-radio"
openssl rand -base64 48 > "$OUT/panel/panel5g-session.secret"

echo "Certificats a $OUT"
echo " - Importa $OUT/ca/ca.crt com a CA de confiança als navegadors del laboratori."
echo " - Guarda $OUT/ca/ca.key fora dels PCs (USB): qui la tingui pot emetre clients vàlids."
