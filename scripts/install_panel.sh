#!/usr/bin/env bash
# Prepara y arranca el panel.   sudo ./install_panel.sh <carpeta_certs_panel> <IP_LAN_de_este_PC>
set -euo pipefail
CERTS=${1:?certs-5g/panel}; IP=${2:?IP LAN de este PC}
[[ $EUID -eq 0 ]] || { echo "Ejecútalo con sudo"; exit 1; }
DIR=$(cd "$(dirname "$0")/../panel" && pwd)
install -d -m 750 "$DIR/certs"
cp "$CERTS"/{ca.crt,panel5g-client.crt,panel5g-client.key,panel5g-web.crt,panel5g-web.key,panel5g-session.secret} "$DIR/certs/"
# El contenedor corre como uid 10001 sin privilegios
chown -R 10001:10001 "$DIR/certs"; chmod 600 "$DIR"/certs/*.key "$DIR/certs/panel5g-session.secret"
if grep -q 'CANVIA-ME' "$DIR/config/panel.yaml"; then
  echo ">> Primero genera la contraseña de admin y ponla en config/panel.yaml:"
  echo "   cd $DIR && PANEL_IP=$IP docker compose build && PANEL_IP=$IP docker compose run --rm --no-deps panel5g python -m app.hashpw"
  exit 1
fi
cd "$DIR" && PANEL_IP="$IP" docker compose up -d --build
echo "Panel en https://$IP:8443"
