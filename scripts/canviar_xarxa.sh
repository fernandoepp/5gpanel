#!/usr/bin/env bash
# Canvi de xarxa (el DHCP o un altre laboratori dona IPs noves al core i a la ràdio).
# Reescriu les IPs velles per les noves a tots els fitxers que les porten, amb còpia
# de cada fitxer, i recrea només el que en depèn. No cal sudo (grup docker), excepte
# per a l'agent de la ràdio si la seva configuració no diu "listen": "auto".
#
# Ús:
#   Al core (VM):          bash canviar_xarxa.sh core  <IP_radio_nova>
#   A la ràdio:            bash canviar_xarxa.sh radio <IP_core_nova>
# La IP pròpia es detecta sola (la de la ruta per defecte); es pot forçar amb IP_PROPIA=...
# Opcions: -n  només mostra què canviaria   -y  no demana confirmació
#
# Carpetes (es poden canviar amb variables d'entorn):
#   core:  CORE_DIR  (per defecte ~/docker_open5gs o ~/core5g/*/docker_open5gs)
#          PANEL_DIR (per defecte /opt/panel5g/panel)
#   radio: OCUDU_DIR (per defecte ~/Escritorio/5g/ocudu/docker)
#          UPF_DIR   (per defecte ~/Escritorio/5g/upf_remot)
set -euo pipefail

SEC=0; SIM=0; ARGS=()
for a in "$@"; do
  case $a in -y) SEC=1 ;; -n) SIM=1 ;; *) ARGS+=("$a") ;; esac
done
ROL=${ARGS[0]:-}; ALTRA_NOVA=${ARGS[1]:-}
IP_RX='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
[[ $ROL == core || $ROL == radio ]] && [[ $ALTRA_NOVA =~ $IP_RX ]] || {
  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

PROPIA_NOVA=${IP_PROPIA:-$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')}
[[ $PROPIA_NOVA =~ $IP_RX ]] || { echo "No trobo la IP d'aquest equip: defineix IP_PROPIA=..."; exit 1; }

env_val() { sed -n "s/^$2=\(.*\)$/\1/p" "$1" 2>/dev/null | tail -1 | tr -d '"'"'"; }
DC() { if id -nG | grep -qw docker || [[ $EUID -eq 0 ]]; then docker "$@"; else sg docker -c "docker $(printf '%q ' "$@")"; fi; }
TS=$(date +%Y%m%d-%H%M%S)
FITXERS=()

if [[ $ROL == core ]]; then
  if [[ -z ${CORE_DIR:-} ]]; then
    for d in "$HOME/docker_open5gs" "$HOME"/core5g/*/docker_open5gs; do
      [[ -f $d/.env ]] && { CORE_DIR=$d; break; }
    done
  fi
  [[ -f ${CORE_DIR:-}/.env ]] || { echo "No trobo docker_open5gs: defineix CORE_DIR"; exit 1; }
  PANEL_DIR=${PANEL_DIR:-/opt/panel5g/panel}
  PROPIA_VELLA=$(env_val "$CORE_DIR/.env" DOCKER_HOST_IP)
  # la ràdio vella: la que té el panell a panel.yaml o l'UPF remota a smf.yaml
  ALTRA_VELLA=$(sed -n 's#.*url: *https://\([0-9.]*\):.*#\1#p' "$PANEL_DIR/config/panel.yaml" 2>/dev/null | head -1)
  [[ -n $ALTRA_VELLA ]] || ALTRA_VELLA=$(grep -A3 -E '^\s*upf:' "$CORE_DIR/smf/smf.yaml" 2>/dev/null | sed -n 's/.*address: *\([0-9.]*\).*/\1/p' | head -1)
  for f in .env sa-deploy.yaml smf/smf.yaml smf/smf.yaml.upf_remot; do
    [[ -f $CORE_DIR/$f ]] && FITXERS+=("$CORE_DIR/$f")
  done
  [[ -f $PANEL_DIR/config/panel.yaml ]] && FITXERS+=("$PANEL_DIR/config/panel.yaml")
else
  OCUDU_DIR=${OCUDU_DIR:-$HOME/Escritorio/5g/ocudu/docker}
  UPF_DIR=${UPF_DIR:-$HOME/Escritorio/5g/upf_remot}
  [[ -f $OCUDU_DIR/.env ]] || { echo "No trobo el .env d'ocudu: defineix OCUDU_DIR"; exit 1; }
  PROPIA_VELLA=$(env_val "$OCUDU_DIR/.env" RADIO_IP)
  ALTRA_VELLA=$(env_val "$OCUDU_DIR/.env" CORE_IP)
  FITXERS+=("$OCUDU_DIR/.env")
  [[ -f $UPF_DIR/.env ]] && FITXERS+=("$UPF_DIR/.env")
fi

echo "== Canvi de xarxa ($ROL)"
echo "   aquest equip: ${PROPIA_VELLA:-?} -> $PROPIA_NOVA"
echo "   l'altre:      ${ALTRA_VELLA:-?} -> $ALTRA_NOVA"
SED=()
# amb marques intermèdies, per si les IPs s'intercanvien (la vella d'un és la nova de l'altre)
if [[ -n $PROPIA_VELLA && $PROPIA_VELLA != "$PROPIA_NOVA" ]]; then
  SED+=(-e "s/\\b${PROPIA_VELLA//./\\.}\\b/@@IP_PROPIA@@/g"); fi
if [[ -n $ALTRA_VELLA && $ALTRA_VELLA != "$ALTRA_NOVA" ]]; then
  SED+=(-e "s/\\b${ALTRA_VELLA//./\\.}\\b/@@IP_ALTRA@@/g"); fi
[[ ${#SED[@]} -gt 0 ]] && SED+=(-e "s/@@IP_PROPIA@@/$PROPIA_NOVA/g" -e "s/@@IP_ALTRA@@/$ALTRA_NOVA/g")
if [[ ${#SED[@]} -eq 0 ]]; then
  echo ">> Les IPs ja són les noves: no hi ha res a canviar als fitxers."
else
  echo "   fitxers:"
  for f in "${FITXERS[@]}"; do
    n=$(sed "${SED[@]}" "$f" | diff "$f" - | grep -c '^>' || true)
    echo "     $f ($n línies)"
  done
  if [[ $SIM == 1 ]]; then
    for f in "${FITXERS[@]}"; do sed "${SED[@]}" "$f" | diff -u "$f" - || true; done
    echo ">> Simulació (-n): no s'ha tocat res."; exit 0
  fi
  if [[ $SEC == 0 ]]; then
    read -r -p "Aplico els canvis? [s/N] " r; [[ $r =~ ^[sSyY]$ ]] || { echo "Cancel·lat."; exit 1; }
  fi
  for f in "${FITXERS[@]}"; do
    cp -p "$f" "$f.bak-xarxa-$TS"
    sed -i "${SED[@]}" "$f"
  done
  echo ">> Fet. Còpies: <fitxer>.bak-xarxa-$TS"
fi

if [[ $ROL == core ]]; then
  echo ">> Recreo l'SMF (publica el port PFCP 8805 a la IP del host)"
  (cd "$CORE_DIR" && DC compose -f sa-deploy.yaml up -d --force-recreate --no-deps smf)
  if [[ -f $PANEL_DIR/docker-compose.yml ]]; then
    echo ">> Torno a aixecar el panell a https://$PROPIA_NOVA:8443"
    (cd "$PANEL_DIR" && PANEL_IP=$PROPIA_NOVA DC compose up -d --force-recreate)
  fi
  echo
  echo "Comprova:  docker logs --tail 30 smf | grep -i pfcp   -> PFCP associated [$ALTRA_NOVA]:8805"
  echo "           (apareix quan també hagis executat a la ràdio: canviar_xarxa.sh radio $PROPIA_NOVA)"
  echo "Navegador: https://$PROPIA_NOVA:8443  (avís de certificat: vegeu la guia, pas 5)"
else
  if [[ -f $UPF_DIR/.env ]] && DC ps -a --format '{{.Names}}' | grep -qx upf; then
    echo ">> Recreo l'UPF remota"
    (cd "$UPF_DIR" && DC compose up -d --force-recreate upf)
  fi
  echo ">> Recreo la gNB"
  (cd "$OCUDU_DIR" && DC compose up -d --force-recreate gnb)
  AJ=/etc/agent5g/agent5g.json
  if [[ $EUID -eq 0 ]]; then
    if ! grep -q '"listen": *"auto"' "$AJ"; then
      cp -p "$AJ" "$AJ.bak-xarxa-$TS"
      sed -i 's/"listen": *"[^"]*"/"listen": "auto"/' "$AJ"
      echo ">> Agent: \"listen\": \"auto\" (a partir d'ara segueix la IP sol)"
    fi
    systemctl restart agent5g
  else
    echo ">> Agent de la ràdio: si encara no diu \"listen\": \"auto\", executa un sol cop:"
    echo "   sudo sed -i 's/\"listen\": *\"[^\"]*\"/\"listen\": \"auto\"/' $AJ && sudo systemctl restart agent5g"
  fi
  echo
  echo "Comprova:  docker logs --tail 50 ocudu_gnb | grep -i 'ng setup\\|amf'"
fi
