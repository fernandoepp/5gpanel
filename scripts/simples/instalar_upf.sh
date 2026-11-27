#!/usr/bin/env bash
# ============================================================================
# instalar_upf.sh - instala un UPF separado del núcleo (la pieza por donde pasan los datos
# de los móviles hacia internet), con la imagen de herlesupreeth/docker_open5gs y la
# configuración del despliegue del TFG. SIN agente ni panel web.
#
# Uso:
#   sudo bash instalar_upf.sh              (menú: eliges las IP y le das a "Instalar")
#   sudo bash instalar_upf.sh --core 192.168.1.100 [--ip 192.168.1.31] [--gnb-local s|n]
#                             [--dir RUTA] [--si]
#
#   --core IP         IP del PC del núcleo (donde está el SMF, que controla este UPF)
#   --ip IP           IP de este PC en la red del laboratorio (por defecto, se detecta)
#   --gnb-local s|n   ¿la radio (gNB) está en este mismo PC? (por defecto, se detecta)
#   --dir RUTA        dónde se crea (por defecto ~/core5g_simple)
#   --si              no preguntar nada: instalar directamente con lo que se ha pasado
#
# Montaje (el mismo que funcionó en server2core5G):
#   - red Docker propia 172.23.0.0/24, UPF en 172.23.0.8 (no choca con la 172.22.0.0/24 del core)
#   - publica 8805/udp (PFCP: órdenes del SMF) y 2152/udp (GTP-U: datos de la radio);
#     si la gNB está en este PC, el 2152 ya es suyo: no se publica y la gNB llega por Docker
#   - subredes de los móviles 192.168.100.0/24 (internet) y 192.168.101.0/24 (ims), las del core
# En el core: sudo bash instalar_core.sh, opción "UPF" = IP de este PC.
# ============================================================================
set -euo pipefail

REPO="${REPO:-https://github.com/herlesupreeth/docker_open5gs}"
USUARI="${SUDO_USER:-$(id -un)}"
HOME_U="$(getent passwd "$USUARI" | cut -d: -f6)"; HOME_U="${HOME_U:-/root}"
BASE="$HOME_U/core5g_simple"
XARXA=172.23.0.0/24; UPF_IP=172.23.0.8
CORE=""; IP=""; GNB_LOCAL=""; SI=0

pas()   { echo; echo "==> $*"; }
info()  { echo "    $*"; }
avis()  { echo "    AVISO: $*"; }
error() { echo "ERROR: $*" >&2; exit 1; }
es_ip() { [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
          local o; for o in "${BASH_REMATCH[@]:1}"; do (( o <= 255 )) || return 1; done; }
ips_pc() { { ip -4 -o addr show scope global 2>/dev/null || true; } | awk '{split($4,a,"/"); print a[1]" ("$2")"}'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --core)      CORE="${2:?}"; shift ;;
        --ip)        IP="${2:?}"; shift ;;
        --gnb-local) GNB_LOCAL="${2:?}"; shift ;;
        --dir)       BASE="${2:?}"; shift ;;
        --si|-y)     SI=1 ;;
        -h|--help)   sed -n '3,/^# =====/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           error "opción desconocida: $1 (mira --help)" ;;
    esac
    shift
done
[[ $EUID -eq 0 ]] || error "hay que ejecutarlo como root: sudo bash $0"

# Valores por defecto detectados
[[ -n "$IP" ]] || IP="$( { ip -4 route get 8.8.8.8 2>/dev/null || true; } | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
if [[ -z "$GNB_LOCAL" ]]; then
    GNB_LOCAL=n
    { ss -Hlun 2>/dev/null | grep -q ':2152\b' || docker inspect ocudu_gnb >/dev/null 2>&1; } && GNB_LOCAL=s
fi

validar() {
    es_ip "$CORE" || { echo "    Falta la IP del core (o no es válida): '$CORE'"; return 1; }
    es_ip "$IP"   || { echo "    Falta la IP de este PC (o no es válida): '$IP'"; return 1; }
    [[ "$CORE" != "$IP" ]] || { echo "    La IP del core no puede ser la de este PC (el UPF separado va en otro PC)"; return 1; }
    [[ "$GNB_LOCAL" =~ ^[sSnNyY]$ ]] || { echo "    gNB en este PC: responde s o n"; return 1; }
}

menu() {
    local op v
    while true; do
        echo
        echo "=============================================="
        echo " Instalar un UPF separado (sin agente)"
        echo "=============================================="
        echo " 1) IP del core (SMF) ............ ${CORE:-<falta>}"
        echo " 2) IP de este PC (UPF) .......... ${IP:-<falta>}"
        echo " 3) ¿Radio (gNB) en este PC? ..... $GNB_LOCAL"
        echo " 4) Carpeta ...................... $BASE"
        echo " 5) INSTALAR"
        echo " 0) Salir"
        read -r -p " Opción: " op || exit 1
        case "$op" in
            1) read -r -p "    IP del PC del núcleo [$CORE]: " v; CORE="${v:-$CORE}" ;;
            2) echo "    IP de este PC:"; ips_pc | sed 's/^/      /'
               read -r -p "    IP [$IP]: " v; IP="${v:-$IP}" ;;
            3) read -r -p "    ¿La radio (ocudu) funciona en este mismo PC? s/n [$GNB_LOCAL]: " v; GNB_LOCAL="${v:-$GNB_LOCAL}" ;;
            4) read -r -p "    Carpeta [$BASE]: " v; BASE="${v:-$BASE}" ;;
            5) validar && return 0 ;;
            0) exit 0 ;;
            *) echo "    Opción no válida" ;;
        esac
    done
}

if (( SI )) || [[ ! -t 0 ]]; then validar || exit 1; else menu; fi
[[ "$GNB_LOCAL" =~ ^[sSyY]$ ]] && GNB_LOCAL=1 || GNB_LOCAL=0
SRC="$BASE/docker_open5gs"; PROJ="$BASE/upf"

# --- 1. programas ---------------------------------------------------------------------
pas "1/5 Programas (git, curl, Docker)"
falta=()
for c in git curl python3; do command -v "$c" >/dev/null || falta+=("$c"); done
if (( ${#falta[@]} )); then
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${falta[@]}" >/dev/null
    info "instalado: ${falta[*]}"
fi
if ! docker compose version >/dev/null 2>&1; then
    curl -fsSL --retry 3 https://get.docker.com | sh >/dev/null || error "no se ha podido instalar Docker"
    info "Docker instalado"
fi
usermod -aG docker "$USUARI" 2>/dev/null || true
info "$(docker --version)"

# --- 2. lo que ya haya en este PC ------------------------------------------------------------
pas "2/5 UPF o núcleo que ya haya en este PC"
if docker inspect upf >/dev/null 2>&1; then
    dir="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' upf 2>/dev/null || true)"
    if [[ "$dir" == "$PROJ" ]]; then
        info "el contenedor upf ya es de esta instalación: se rehace"
    elif [[ -n "$dir" && -f "$dir/sa-deploy.yaml" ]]; then
        error "en este PC hay un núcleo completo ($dir): el UPF separado va en otro PC"
    else
        avis "hay otro contenedor upf (${dir:-hecho a mano})"
        r=s; (( SI )) || [[ ! -t 0 ]] || read -r -p "    ¿Lo paro y lo quito (su carpeta no se borra)? [S/n]: " r
        [[ "${r:-s}" =~ ^[sSyY]$ ]] || error "no puede haber dos contenedores upf"
        [[ -n "$dir" && -d "$dir" ]] && (cd "$dir" && docker compose down) >/dev/null 2>&1 || true
        docker rm -f upf >/dev/null 2>&1 || true
        info "UPF antiguo quitado"
    fi
fi
# otros contenedores que ocupen el 8805/udp (p. ej. el upf_antiguo) no dejarían arrancar el nuevo
for c in $(docker ps --filter publish=8805/udp --format '{{.Names}}' 2>/dev/null); do
    [[ "$c" == upf ]] && continue
    avis "el contenedor $c ocupa el puerto 8805/udp"
    r=s; (( SI )) || [[ ! -t 0 ]] || read -r -p "    ¿Lo paro y le quito el arranque automático (no se borra)? [S/n]: " r
    [[ "${r:-s}" =~ ^[sSyY]$ ]] || error "para $c (docker stop $c) y vuelve a ejecutarlo"
    docker update --restart=no "$c" >/dev/null 2>&1 || true
    docker stop "$c" >/dev/null && info "$c parado (para volver a usarlo: docker start $c)"
done

# --- 3. descarga e imagen ---------------------------------------------------------------
pas "3/5 Repositorio de herlesupreeth e imagen (la primera vez tarda 20-30 minutos)"
if [[ -d "$SRC/.git" ]]; then
    info "ya descargado en $SRC"
else
    mkdir -p "$BASE"
    git clone -q --depth 1 "$REPO" "$SRC" || error "no se ha podido clonar $REPO"
    info "descargado en $SRC"
fi
if docker image inspect docker_open5gs >/dev/null 2>&1; then
    info "la imagen docker_open5gs ya existe"
else
    docker build -t docker_open5gs "$SRC/base" || error "ha fallado la construcción de la imagen (vuelve a ejecutarlo)"
fi

# --- 4. proyecto del UPF -------------------------------------------------------------------
pas "4/5 Configuración del UPF ($PROJ)"
mkdir -p "$PROJ/upf" "$PROJ/log"
for f in upf_init.sh tun_if.py ip_utils.py upf.yaml; do
    cp -f "$SRC/upf/$f" "$PROJ/upf/$f"
done
# El UPF se presenta al SMF con la IP del PC (no con la interna de Docker): "advertise" en PFCP
awk '
    /^    pfcp:/ { pfcp = 1 } /^    gtpu:/ { pfcp = 0 }
    { print }
    pfcp && !fet && /^        - address: UPF_IP[[:space:]]*$/ { print "          advertise: UPF_HOST_IP"; fet = 1 }
    END { exit !fet }
' "$SRC/upf/upf.yaml" > "$PROJ/upf/upf.yaml" || error "upf.yaml no tiene el formato esperado"
sed -i "/^sed -i 's|UPF_ADVERTISE_IP|/a sed -i 's|UPF_HOST_IP|'\$UPF_HOST_IP'|g' install/etc/open5gs/upf.yaml" "$PROJ/upf/upf_init.sh"
grep -q UPF_HOST_IP "$PROJ/upf/upf_init.sh" || error "no he podido modificar upf_init.sh"
chmod +x "$PROJ/upf/upf_init.sh"

if (( GNB_LOCAL )); then
    ADV="$UPF_IP"   # la gNB de este PC llega al UPF por el puente de Docker
    GTP="      # 2152/udp no se publica: en este PC ya lo usa la gNB"
else
    ADV="$IP"       # la gNB de otro PC envía los datos a la IP de este PC
    GTP='      - "2152:2152/udp"   # GTP-U (N3): datos de la radio'
fi
cat > "$PROJ/docker-compose.yml" <<EOF
# UPF separado del núcleo. Lo genera instalar_upf.sh (se rehace al volver a ejecutarlo).
services:
  upf:
    image: docker_open5gs
    container_name: upf
    env_file:
      - .env
    environment:
      - COMPONENT_NAME=upf
    volumes:
      - ./upf:/mnt/upf
      - ./log:/open5gs/install/var/log/open5gs
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "8805:8805/udp"   # PFCP (N4): órdenes del SMF del núcleo
$GTP
    cap_add:
      - NET_ADMIN
    privileged: true
    sysctls:
      - net.ipv4.ip_forward=1
    restart: unless-stopped
    networks:
      default:
        ipv4_address: \${UPF_IP}

networks:
  default:
    name: upf5g
    ipam:
      config:
        - subnet: \${TEST_NETWORK}
EOF
cat > "$PROJ/.env" <<EOF
# UPF separado. Lo genera instalar_upf.sh.
TEST_NETWORK=$XARXA
UPF_IP=$UPF_IP
UPF_ADVERTISE_IP=$ADV
UPF_HOST_IP=$IP
SMF_IP=$CORE
UPF_TUNTAP_MODE=tun
UPF_INTERNET_APN_IF_NAME=ogstun
UPF_IMS_APN_IF_NAME=ogstun2
# Tienen que ser las mismas que en el .env del núcleo
UE_IPV4_INTERNET=192.168.100.0/24
UE_IPV4_IMS=192.168.101.0/24
PCSCF_IP=172.22.0.21
MAX_NUM_UE=1024
EOF
chown -R "$USUARI": "$BASE"
(cd "$PROJ" && docker compose config -q) || error "el docker-compose.yml generado no es válido"
info "SMF del núcleo: $CORE · UPF se anuncia como $IP · datos de la radio a $ADV"
info "radio en este PC: $( ((GNB_LOCAL)) && echo sí || echo no)"

# --- 5. arranque ------------------------------------------------------------------------
pas "5/5 Arranque"
(cd "$PROJ" && docker compose -p upf5g up -d --force-recreate) || error "no ha arrancado: docker logs upf"
info "esperando 10 s..."
sleep 10
docker inspect -f '    upf: {{.State.Status}}' upf 2>/dev/null || avis "el contenedor upf no aparece: docker logs upf"
DEV_DEF="$( { ip -4 route show default 2>/dev/null || true; } | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | head -1)"
[[ "$DEV_DEF" =~ ^(tun|wg|ppp|tap) ]] && avis "la salida a internet de este PC va por una VPN ($DEV_DEF): el tráfico de los móviles también saldrá por ahí"
if docker logs upf 2>&1 | grep -q "PFCP associated"; then
    info "conectado con el SMF del núcleo $CORE"
else
    info "aún no conectado con el SMF: se conecta solo cuando el núcleo esté instalado con UPF = $IP"
fi

echo
echo "==> Hecho. UPF instalado en $PROJ"
echo "    En el núcleo ($CORE): sudo bash instalar_core.sh, opción 4 (UPF) = $IP"
echo "    Ver registros:   docker logs -f upf"
echo "    Parar / arrancar: cd $PROJ && docker compose -p upf5g down  /  docker compose -p upf5g up -d"
