#!/usr/bin/env bash
# ============================================================================
# desinstala.sh - quita las piezas del panel5g de este PC, las que elijas:
#   1) agente del core    (agent5g + captura NGAP + modelo del móvil + emparella-radio/-upf)
#   2) panel web          (contenedor panel5g)
#   3) agente de la radio (agent5g; el gNB y ocudu no se tocan)
#   4) UPF separado       (agent5g-upf, contenedor upf y red upf5g)
#
# Uso:
#   sudo ./desinstala.sh                      (menú: muestra lo que hay instalado)
#   sudo ./desinstala.sh --core --panel -y    (sin preguntas)
#   opciones: --core --panel --radio --upf --todo  -y (no preguntar)  --purga
#
# Qué NO se toca nunca: el core 5G (docker_open5gs), el gNB, los abonados, la CA y los
# certificados del core (/root/certs-5g o donde estén): las radios y los UPF ya emparejados
# siguen valiendo cuando se vuelve a instalar. Se conservan también /var/lib/agent5g*
# (copias del .env y auditoría) y la configuración del panel (panel.yaml), salvo con --purga.
#
# Para volver a instalar la versión nueva: core5g.sh > Instalar (core y panel),
# install_radio.sh (radio) o install_upf.sh (UPF). Solo se instala lo que falta.
# ============================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Hay que ser root: sudo $0"; exit 1; }
info() { echo "    $*"; }
avis() { echo "    AVISO: $*"; }

T_CORE=0; T_PANELL=0; T_RADIO=0; T_UPF=0; SI=0; PURGA=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --core) T_CORE=1 ;; --panell|--panel) T_PANELL=1 ;; --radio) T_RADIO=1 ;; --upf) T_UPF=1 ;;
        --tot|--todo) T_CORE=1; T_PANELL=1; T_RADIO=1; T_UPF=1 ;;
        -y) SI=1 ;; --purga) PURGA=1 ;;
        -h|--help) sed -n '3,/^# =====/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Opción desconocida: $1"; exit 1 ;;
    esac
    shift
done

# --- qué hay en este PC ---------------------------------------------------------------
rol_agent() { python3 -c 'import json;print(json.load(open("/etc/agent5g/agent5g.json")).get("role",""))' 2>/dev/null || true; }
ROL="$(rol_agent)"
te_unitat() { [[ -f "/etc/systemd/system/$1.service" ]]; }
HI_CORE=0; HI_RADIO=0; HI_PANELL=0; HI_UPF=0
if te_unitat agent5g || [[ -f /etc/agent5g/agent5g.json ]]; then
    [[ "$ROL" == radio ]] && HI_RADIO=1 || HI_CORE=1
fi
docker inspect panel5g >/dev/null 2>&1 && HI_PANELL=1
{ te_unitat agent5g-upf || [[ -d /etc/agent5g-upf ]]; } && HI_UPF=1
estat() { (( $1 )) && echo "[instalado]" || echo "[no está]  "; }

if (( ! T_CORE && ! T_PANELL && ! T_RADIO && ! T_UPF )); then
    [[ -t 0 ]] || { echo "Sin terminal: indica qué quieres quitar (--core --panel --radio --upf)"; exit 1; }
    echo
    echo "¿Qué quieres desinstalar de este PC?"
    echo "   1) agente del core    $(estat $HI_CORE)"
    echo "   2) panel web          $(estat $HI_PANELL)"
    echo "   3) agente de la radio $(estat $HI_RADIO)"
    echo "   4) UPF separado       $(estat $HI_UPF)"
    echo "   (el core 5G, el gNB, los abonados y la CA no se tocan)"
    read -r -p "    Números separados por espacios (p. ej. 1 2), vacío = nada: " tria || tria=""
    for n in $tria; do
        case "$n" in 1) T_CORE=1 ;; 2) T_PANELL=1 ;; 3) T_RADIO=1 ;; 4) T_UPF=1 ;; *) echo "    '$n' no es ninguna opción" ;; esac
    done
fi
(( T_CORE || T_PANELL || T_RADIO || T_UPF )) || { echo "No se quita nada."; exit 0; }
llista=()
(( T_CORE ))   && { (( HI_CORE ))   && llista+=("agente del core")    || info "agente del core: no está"; }
(( T_PANELL )) && { (( HI_PANELL )) && llista+=("panel web")          || info "panel web: no está"; }
(( T_RADIO ))  && { (( HI_RADIO ))  && llista+=("agente de la radio") || info "agente de la radio: no está"; }
(( T_UPF ))    && { (( HI_UPF ))    && llista+=("UPF separado")       || info "UPF separado: no está"; }
(( ${#llista[@]} )) || { echo "No hay nada que quitar."; exit 0; }
if (( ! SI )) && [[ -t 0 ]]; then
    r=""; read -r -p "    Se desinstalará: $(IFS=,; echo "${llista[*]}" | sed 's/,/, /g'). ¿Continuar? [s/N]: " r || true
    [[ "$r" =~ ^[sSyY]$ ]] || { echo "Cancelado."; exit 0; }
fi

treu_unitat() {   # treu_unitat <servicio>
    systemctl disable --now "$1" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$1.service"
    rm -rf "/etc/systemd/system/$1.service.d"
}

# --- agente del core o de la radio (el mismo servicio agent5g) -----------------------
# Guarda el certificado y la IP del core de un agente que llama al core (radio o UPF): al volver a
# instalar, el instalador los usa solo y no hace falta volver a pegar el código.
desa_emparellament() {   # desa_emparellament <json> <carpeta certs> <destino>
    local core
    core="$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print("%s:%s" % (c["core"], c.get("core_port") or 9544) if c.get("core") else "")' "$1" 2>/dev/null || true)"
    [[ -n "$core" && -d "$2" ]] || return 0
    install -d -m 700 "$3"
    cp -p "$2"/*.crt "$2"/*.key "$3"/ 2>/dev/null || return 0
    printf '%s\n' "$core" > "$3/core"
    info "certificado e IP del core guardados en $3 (la reinstalación no pedirá el código)"
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
    info "agente $1 desinstalado (servicio agent5g, /etc/agent5g$( ((PURGA)) && echo ', /var/lib/agent5g'))"
}

if (( T_CORE && HI_CORE )); then
    echo; echo "==> Agente del core"
    # los códigos de emparejamiento y la CA se quedan donde están (la CA no está en /etc/agent5g)
    treu_agent core
    info "la CA y los certificados del core no se han tocado: las radios y los UPF emparejados siguen valiendo"
fi
if (( T_RADIO && HI_RADIO )); then
    echo; echo "==> Agente de la radio"
    treu_agent radio
    info "el gNB (ocudu) sigue como estaba"
fi

# --- panel --------------------------------------------------------------------------
if (( T_PANELL && HI_PANELL )); then
    echo; echo "==> Panel web"
    dir="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' panel5g 2>/dev/null || true)"
    img="$(docker inspect -f '{{.Config.Image}}' panel5g 2>/dev/null || true)"
    if [[ -n "$dir" && -f "$dir/config/panel.yaml" ]]; then
        install -d -m 700 /var/lib/panel5g
        cp -p "$dir/config/panel.yaml" /var/lib/panel5g/panel.yaml
        info "configuración del panel (usuarios, contraseñas) guardada en /var/lib/panel5g/panel.yaml"
    fi
    if [[ -n "$dir" && -f "$dir/docker-compose.yml" ]]; then
        (cd "$dir" && PANEL_IP=127.0.0.1 docker compose down) >/dev/null 2>&1 || true
    fi
    docker rm -f panel5g >/dev/null 2>&1 || true
    [[ -n "$img" ]] && docker image rm "$img" >/dev/null 2>&1 || true
    (( PURGA )) && rm -rf /var/lib/panel5g
    info "contenedor panel5g y su imagen eliminados${dir:+ (el código de $dir se queda)}"
fi

# --- UPF ----------------------------------------------------------------------------
if (( T_UPF && HI_UPF )); then
    echo; echo "==> UPF separado"
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
    info "agent5g-upf, contenedor upf y red upf5g eliminados$( ((PURGA)) && echo "; también $proj y /var/lib/agent5g-upf" || echo " ($proj se queda: la imagen y los ficheros se reaprovechan)")"
    avis "si el core usaba este UPF, en el panel (pestaña UPF) vuelve a juntarlo con el core o elige otro"
fi

# /opt/agent5g/agent5g.py solo si ya no lo usa ningún servicio
if ! te_unitat agent5g && ! te_unitat agent5g-upf; then
    rm -rf /opt/agent5g
    rm -f /usr/local/sbin/agent5g
fi
systemctl daemon-reload
echo
echo "==> Hecho. Para volver a instalarlo (con la versión nueva):"
(( T_CORE || T_PANELL )) && echo "    core y panel: sudo ./core5g.sh > Instalar (solo instala lo que falta)"
(( T_RADIO )) && echo "    radio:  sudo bash 5gpanel/scripts/install_radio.sh   (usa solo el certificado guardado; con --purga, hace falta un código nuevo)"
(( T_UPF ))   && echo "    UPF:    sudo bash 5gpanel/scripts/install_upf.sh     (usa solo el certificado guardado; con --purga, hace falta un código nuevo)"
exit 0
