#!/usr/bin/env bash
# Prepara i arrenca el panell.   sudo ./install_panel.sh <carpeta_certs_panel> <IP_LAN_d_aquest_PC>
set -euo pipefail
CERTS=${1:?certs-5g/panel}; IP=${2:?IP LAN d aquest PC}
[[ $EUID -eq 0 ]] || { echo "Executa amb sudo"; exit 1; }
DIR=$(cd "$(dirname "$0")/../panel" && pwd)
install -d -m 750 "$DIR/certs"
cp "$CERTS"/{ca.crt,panel5g-client.crt,panel5g-client.key,panel5g-web.crt,panel5g-web.key,panel5g-session.secret} "$DIR/certs/"
# El contenidor corre com a uid 10001 sense privilegis
chown -R 10001:10001 "$DIR/certs"; chmod 600 "$DIR"/certs/*.key "$DIR/certs/panel5g-session.secret"
if grep -q 'CANVIA-ME' "$DIR/config/panel.yaml"; then
  echo ">> Primer genera la contrasenya d'admin i posa-la a config/panel.yaml:"
  echo "   cd $DIR && PANEL_IP=$IP docker compose build && PANEL_IP=$IP docker compose run --rm --no-deps panel5g python -m app.hashpw"
  exit 1
fi
cd "$DIR" && PANEL_IP="$IP" docker compose up -d --build
echo "Panell a https://$IP:8443"
