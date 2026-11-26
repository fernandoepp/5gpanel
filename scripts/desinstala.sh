#!/usr/bin/env bash
# ============================================================================
# desinstala.sh - treu les peces del panel5g d'aquest PC, les que triïs:
#   1) agent del core     (agent5g + captura NGAP + model del mòbil + emparella-radio/-upf)
#   2) panell web         (contenidor panel5g)
#   3) agent de la ràdio  (agent5g; el gNB i ocudu no es toquen)
#   4) UPF separat        (agent5g-upf, contenidor upf i xarxa upf5g)
#
# Ús:
#   sudo ./desinstala.sh                      (menú: mostra què hi ha instal·lat)
#   sudo ./desinstala.sh --core --panell -y   (sense preguntes)
#   opcions: --core --panell --radio --upf --tot  -y (no preguntar)  --purga
#
# Què NO es toca mai: el core 5G (docker_open5gs), el gNB, els abonats, la CA i els
# certificats del core (/root/certs-5g o on siguin): les ràdios i els UPF ja emparellats
# continuen valent quan es torna a instal·lar. Es conserven també /var/lib/agent5g*
# (còpies del .env i auditoria) i la configuració del panell (panel.yaml), llevat de --purga.
#
# Per tornar a instal·lar la versió nova: core5g.sh > Instal·lar (core i panell),
# install_radio.sh (ràdio) o install_upf.sh (UPF). Només s'instal·la el que falta.
# ============================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Cal ser root: sudo $0"; exit 1; }
info() { echo "    $*"; }
avis() { echo "    AVÍS: $*"; }

T_CORE=0; T_PANELL=0; T_RADIO=0; T_UPF=0; SI=0; PURGA=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --core) T_CORE=1 ;; --panell) T_PANELL=1 ;; --radio) T_RADIO=1 ;; --upf) T_UPF=1 ;;
        --tot) T_CORE=1; T_PANELL=1; T_RADIO=1; T_UPF=1 ;;
        -y) SI=1 ;; --purga) PURGA=1 ;;
        -h|--help) sed -n '3,/^# =====/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Opció desconeguda: $1"; exit 1 ;;
    esac
    shift
done

# --- què hi ha en aquest PC -----------------------------------------------------------
rol_agent() { python3 -c 'import json;print(json.load(open("/etc/agent5g/agent5g.json")).get("role",""))' 2>/dev/null || true; }
ROL="$(rol_agent)"
te_unitat() { [[ -f "/etc/systemd/system/$1.service" ]]; }
HI_CORE=0; HI_RADIO=0; HI_PANELL=0; HI_UPF=0
if te_unitat agent5g || [[ -f /etc/agent5g/agent5g.json ]]; then
    [[ "$ROL" == radio ]] && HI_RADIO=1 || HI_CORE=1
fi
docker inspect panel5g >/dev/null 2>&1 && HI_PANELL=1
{ te_unitat agent5g-upf || [[ -d /etc/agent5g-upf ]]; } && HI_UPF=1
estat() { (( $1 )) && echo "[instal·lat]" || echo "[no hi és] "; }

if (( ! T_CORE && ! T_PANELL && ! T_RADIO && ! T_UPF )); then
    [[ -t 0 ]] || { echo "Sense terminal: indica què vols treure (--core --panell --radio --upf)"; exit 1; }
    echo
    echo "Què vols desinstal·lar d'aquest PC?"
    echo "   1) agent del core     $(estat $HI_CORE)"
    echo "   2) panell web         $(estat $HI_PANELL)"
    echo "   3) agent de la ràdio  $(estat $HI_RADIO)"
    echo "   4) UPF separat        $(estat $HI_UPF)"
    echo "   (el core 5G, el gNB, els abonats i la CA no es toquen)"
    read -r -p "    Números separats per espais (p. ex. 1 2), buit = res: " tria || tria=""
    for n in $tria; do
        case "$n" in 1) T_CORE=1 ;; 2) T_PANELL=1 ;; 3) T_RADIO=1 ;; 4) T_UPF=1 ;; *) echo "    '$n' no és cap opció" ;; esac
    done
fi
(( T_CORE || T_PANELL || T_RADIO || T_UPF )) || { echo "No es treu res."; exit 0; }
llista=()
(( T_CORE ))   && { (( HI_CORE ))   && llista+=("agent del core")    || info "agent del core: no hi és"; }
(( T_PANELL )) && { (( HI_PANELL )) && llista+=("panell web")        || info "panell web: no hi és"; }
(( T_RADIO ))  && { (( HI_RADIO ))  && llista+=("agent de la ràdio") || info "agent de la ràdio: no hi és"; }
(( T_UPF ))    && { (( HI_UPF ))    && llista+=("UPF separat")       || info "UPF separat: no hi és"; }
(( ${#llista[@]} )) || { echo "No hi ha res a treure."; exit 0; }
if (( ! SI )) && [[ -t 0 ]]; then
    r=""; read -r -p "    Es desinstal·larà: $(IFS=,; echo "${llista[*]}" | sed 's/,/, /g'). Continuar? [s/N]: " r || true
    [[ "$r" =~ ^[sSyY]$ ]] || { echo "Cancel·lat."; exit 0; }
fi

treu_unitat() {   # treu_unitat <servei>
    systemctl disable --now "$1" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$1.service"
    rm -rf "/etc/systemd/system/$1.service.d"
}

# --- agent del core o de la ràdio (el mateix servei agent5g) -------------------------
# Desa el certificat i la IP del core d'un agent que truca al core (ràdio o UPF): en tornar a
# instal·lar, l'instal·lador els fa servir sols i no cal tornar a enganxar el codi.
desa_emparellament() {   # desa_emparellament <json> <carpeta certs> <destí>
    local core
    core="$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print("%s:%s" % (c["core"], c.get("core_port") or 9544) if c.get("core") else "")' "$1" 2>/dev/null || true)"
    [[ -n "$core" && -d "$2" ]] || return 0
    install -d -m 700 "$3"
    cp -p "$2"/*.crt "$2"/*.key "$3"/ 2>/dev/null || return 0
    printf '%s\n' "$core" > "$3/core"
    info "certificat i IP del core desats a $3 (la reinstal·lació no demanarà el codi)"
}

treu_agent() {   # treu_agent <core|radio>
    [[ $1 == radio ]] && (( ! PURGA )) && desa_emparellament /etc/agent5g/agent5g.json /etc/agent5g/certs /var/lib/agent5g/emparellament
    treu_unitat agent5g
    if [[ $1 == core ]]; then
        treu_unitat ngap-capture; treu_unitat ua-capture
        rm -f /usr/local/sbin/emparella-radio /usr/local/sbin/emparella-upf
        rm -rf /opt/agent5g/eines
        rm -f /opt/agent5g/ua_capture.py
    fi
    rm -rf /etc/agent5g
    (( PURGA )) && rm -rf /var/lib/agent5g
    info "agent $1 desinstal·lat (servei agent5g, /etc/agent5g$( ((PURGA)) && echo ', /var/lib/agent5g'))"
}

if (( T_CORE && HI_CORE )); then
    echo; echo "==> Agent del core"
    # els codis d'emparellament i la CA es queden on són (la CA no és a /etc/agent5g)
    treu_agent core
    info "la CA i els certificats del core no s'han tocat: les ràdios i els UPF emparellats continuen valent"
fi
if (( T_RADIO && HI_RADIO )); then
    echo; echo "==> Agent de la ràdio"
    treu_agent radio
    info "el gNB (ocudu) continua com estava"
fi

# --- panell -------------------------------------------------------------------------
if (( T_PANELL && HI_PANELL )); then
    echo; echo "==> Panell web"
    dir="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' panel5g 2>/dev/null || true)"
    img="$(docker inspect -f '{{.Config.Image}}' panel5g 2>/dev/null || true)"
    if [[ -n "$dir" && -f "$dir/config/panel.yaml" ]]; then
        install -d -m 700 /var/lib/panel5g
        cp -p "$dir/config/panel.yaml" /var/lib/panel5g/panel.yaml
        info "configuració del panell (usuaris, contrasenyes) desada a /var/lib/panel5g/panel.yaml"
    fi
    if [[ -n "$dir" && -f "$dir/docker-compose.yml" ]]; then
        (cd "$dir" && PANEL_IP=127.0.0.1 docker compose down) >/dev/null 2>&1 || true
    fi
    docker rm -f panel5g >/dev/null 2>&1 || true
    [[ -n "$img" ]] && docker image rm "$img" >/dev/null 2>&1 || true
    (( PURGA )) && rm -rf /var/lib/panel5g
    info "contenidor panel5g i la seva imatge eliminats${dir:+ (el codi de $dir es queda)}"
fi

# --- UPF ----------------------------------------------------------------------------
if (( T_UPF && HI_UPF )); then
    echo; echo "==> UPF separat"
    proj="$(python3 -c 'import json;print(json.load(open("/etc/agent5g-upf/agent5g.json"))["project_dir"])' 2>/dev/null || echo /opt/upf5g)"
    xarxa="$(python3 -c 'import json;print((json.load(open("/etc/agent5g-upf/agent5g.json")).get("upf") or {}).get("xarxa",""))' 2>/dev/null || true)"
    (( PURGA )) || desa_emparellament /etc/agent5g-upf/agent5g.json /etc/agent5g-upf/certs /var/lib/agent5g-upf/emparellament
    treu_unitat agent5g-upf
    if [[ -f "$proj/docker-compose.yml" ]]; then
        (cd "$proj" && docker compose -p upf5g down) >/dev/null 2>&1 || true
    fi
    [[ -n "$xarxa" ]] && ip rule del from "$xarxa" lookup main priority 100 2>/dev/null || true
    rm -rf /etc/agent5g-upf
    if (( PURGA )); then rm -rf /var/lib/agent5g-upf "$proj"; fi
    info "agent5g-upf, contenidor upf i xarxa upf5g eliminats$( ((PURGA)) && echo "; també $proj i /var/lib/agent5g-upf" || echo " ($proj es queda: la imatge i els fitxers es reaprofiten)")"
    avis "si el core feia servir aquest UPF, al panell (pestanya UPF) torna a ajuntar-lo al core o tria'n un altre"
fi

# /opt/agent5g/agent5g.py només si ja no el fa servir cap servei
if ! te_unitat agent5g && ! te_unitat agent5g-upf; then
    rm -rf /opt/agent5g
fi
systemctl daemon-reload
echo
echo "==> Fet. Per tornar-ho a instal·lar (amb la versió nova):"
(( T_CORE || T_PANELL )) && echo "    core i panell: sudo ./core5g.sh > Instal·lar (només instal·la el que falta)"
(( T_RADIO )) && echo "    ràdio:  sudo bash 5gpanel/scripts/install_radio.sh   (fa servir sol el certificat desat; amb --purga, cal un codi nou)"
(( T_UPF ))   && echo "    UPF:    sudo bash 5gpanel/scripts/install_upf.sh     (fa servir sol el certificat desat; amb --purga, cal un codi nou)"
exit 0
