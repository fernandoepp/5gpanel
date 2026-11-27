#!/usr/bin/env bash
# ============================================================================
# instalar_core.sh - instala el núcleo 5G (Open5GS de herlesupreeth/docker_open5gs)
# con la configuración del despliegue del TFG. SIN agente ni panel web.
#
# Uso:
#   sudo bash instalar_core.sh            (menú: eliges las IP y le das a "Instalar")
#   sudo bash instalar_core.sh --ip 192.168.1.100 [--plmn 00101] [--tac 1]
#                              [--upf-remoto 192.168.1.31] [--dir RUTA] [--si]
#
#   --ip IP           IP de este PC en la red del laboratorio (la que usa la radio)
#   --plmn MCCMNC     código de red, 5 o 6 cifras (por defecto 00101)
#   --tac N           código de zona (por defecto 1)
#   --upf-remoto IP   el UPF va en otro PC (instalado con instalar_upf.sh); sin esto, UPF aquí
#   --dir RUTA        dónde se descarga (por defecto ~/core5g_simple/docker_open5gs)
#   --si              no preguntar nada: instalar directamente con lo que se ha pasado
#
# Qué hace (lo mismo que en el TFG):
#   - Docker (si falta) y descarga del repositorio de herlesupreeth
#   - .env: MCC/MNC/TAC, DOCKER_HOST_IP y UPF_ADVERTISE_IP = IP de este PC
#   - publica 38412/sctp (AMF, conexión de control con la radio) y 2152/udp (UPF, datos)
#   - si el UPF va en otro PC: el SMF le habla por 8805/udp y el UPF de aquí no arranca
#   - construye las imágenes y arranca sa-deploy.yaml (5G SA, slice SST 1)
# Volver a ejecutarlo es seguro: no vuelve a descargar y reaplica la configuración.
# ============================================================================
set -euo pipefail

REPO="${REPO:-https://github.com/herlesupreeth/docker_open5gs}"
USUARI="${SUDO_USER:-$(id -un)}"
HOME_U="$(getent passwd "$USUARI" | cut -d: -f6)"; HOME_U="${HOME_U:-/root}"
DIR="$HOME_U/core5g_simple/docker_open5gs"
COMPOSE=sa-deploy.yaml
IP=""; PLMN=00101; TAC=1; UPF_REMOTO=""; SI=0
MARCA="# instalar_core: UPF remoto"

pas()   { echo; echo "==> $*"; }
info()  { echo "    $*"; }
avis()  { echo "    AVISO: $*"; }
error() { echo "ERROR: $*" >&2; exit 1; }
es_ip() { [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
          local o; for o in "${BASH_REMATCH[@]:1}"; do (( o <= 255 )) || return 1; done; }
ips_pc() { { ip -4 -o addr show scope global 2>/dev/null || true; } | awk '{split($4,a,"/"); print a[1]" ("$2")"}'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)         IP="${2:?}"; shift ;;
        --plmn)       PLMN="${2:?}"; shift ;;
        --tac)        TAC="${2:?}"; shift ;;
        --upf-remoto) UPF_REMOTO="${2:?}"; shift ;;
        --dir)        DIR="${2:?}"; shift ;;
        --si|-y)      SI=1 ;;
        -h|--help)    sed -n '3,/^# =====/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            error "opción desconocida: $1 (mira --help)" ;;
    esac
    shift
done
[[ $EUID -eq 0 ]] || error "hay que ejecutarlo como root: sudo bash $0"

# IP por defecto: la de la ruta por defecto
[[ -n "$IP" ]] || IP="$( { ip -4 route get 8.8.8.8 2>/dev/null || true; } | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"

validar() {
    es_ip "$IP" || { echo "    Falta la IP de este PC (o no es válida): '$IP'"; return 1; }
    [[ "$PLMN" =~ ^[0-9]{5,6}$ ]] || { echo "    El PLMN tiene que tener 5 o 6 cifras: '$PLMN'"; return 1; }
    [[ "$TAC" =~ ^[0-9]+$ ]] && (( TAC >= 0 && TAC <= 16777215 )) || { echo "    TAC no válido: '$TAC'"; return 1; }
    if [[ -n "$UPF_REMOTO" ]]; then
        es_ip "$UPF_REMOTO" || { echo "    IP del UPF remoto no válida: '$UPF_REMOTO'"; return 1; }
        [[ "$UPF_REMOTO" != "$IP" ]] || { echo "    La IP del UPF remoto no puede ser la de este PC"; return 1; }
    fi
}

menu() {
    local op v
    while true; do
        echo
        echo "=============================================="
        echo " Instalar el núcleo 5G (Open5GS, sin agente)"
        echo "=============================================="
        echo " 1) IP de este PC (core) ......... ${IP:-<falta>}"
        echo " 2) PLMN (MCC+MNC) ............... $PLMN"
        echo " 3) TAC (código de zona) ......... $TAC"
        echo " 4) UPF .......................... $( [[ -n "$UPF_REMOTO" ]] && echo "en otro PC: $UPF_REMOTO" || echo "en este PC")"
        echo " 5) Carpeta ...................... $DIR"
        echo " 6) INSTALAR"
        echo " 0) Salir"
        read -r -p " Opción: " op || exit 1
        case "$op" in
            1) echo "    IP de este PC:"; ips_pc | sed 's/^/      /'
               read -r -p "    IP [$IP]: " v; IP="${v:-$IP}" ;;
            2) read -r -p "    PLMN, 5 o 6 cifras [$PLMN]: " v; PLMN="${v:-$PLMN}" ;;
            3) read -r -p "    TAC [$TAC]: " v; TAC="${v:-$TAC}" ;;
            4) echo "    El UPF es la pieza por donde pasan los datos de los móviles hacia internet."
               echo "    Escribe la IP del PC donde lo instalarás con instalar_upf.sh,"
               echo "    o 'local' para tenerlo en este mismo PC."
               read -r -p "    IP del PC del UPF [${UPF_REMOTO:-local}]: " v
               case "$v" in "") ;; local|LOCAL|l) UPF_REMOTO="" ;; *) UPF_REMOTO="$v" ;; esac ;;
            5) read -r -p "    Carpeta [$DIR]: " v; DIR="${v:-$DIR}" ;;
            6) validar && return 0 ;;
            0) exit 0 ;;
            *) echo "    Opción no válida" ;;
        esac
    done
}

if (( SI )) || [[ ! -t 0 ]]; then validar || exit 1; else menu; fi
MCC="${PLMN:0:3}"; MNC="${PLMN:3}"

# --- 1. programas ---------------------------------------------------------------------
pas "1/6 Programas (git, curl, Docker)"
falta=()
for c in git curl; do command -v "$c" >/dev/null || falta+=("$c"); done
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

# --- 2. descarga ------------------------------------------------------------------------
pas "2/6 Repositorio de herlesupreeth"
if [[ -f "$DIR/$COMPOSE" ]]; then
    info "ya descargado en $DIR (no se vuelve a descargar)"
else
    mkdir -p "$(dirname "$DIR")"
    git clone -q --depth 1 "$REPO" "$DIR" || error "no se ha podido clonar $REPO"
    info "descargado en $DIR"
fi
cd "$DIR"
# copias del original la primera vez: así cada ejecución parte de lo mismo
for f in .env smf/smf.yaml sa-deploy.yaml; do [[ -f "$f.orig" ]] || cp -p "$f" "$f.orig"; done
cp -p .env.orig .env; cp -p smf/smf.yaml.orig smf/smf.yaml; cp -p sa-deploy.yaml.orig sa-deploy.yaml

# --- 3. configuración ---------------------------------------------------------------------
pas "3/6 Configuración"
poner() { if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi; }
poner MCC "$MCC"; poner MNC "$MNC"; poner TAC "$TAC"
poner DOCKER_HOST_IP "$IP"; poner UPF_ADVERTISE_IP "$IP"
poner COMPOSE_FILE "$COMPOSE"     # así "docker compose up -d" funciona sin -f
info ".env: PLMN $MCC/$MNC, TAC $TAC, IP del PC $IP"

# Puertos hacia la radio: N2 (AMF, 38412/sctp) y N3 (UPF, 2152/udp)
sed -i -z \
    -e 's|    # ports:\n    #   - "2152:2152/udp"|    ports:\n      - "2152:2152/udp"|' \
    -e 's|    # ports:\n    #   - "38412:38412/sctp"|    ports:\n      - "38412:38412/sctp"|' "$COMPOSE"
grep -q '"38412:38412/sctp"' "$COMPOSE" || avis "no he podido publicar el 38412/sctp en $COMPOSE"
info "puertos publicados: 38412/sctp (AMF) y 2152/udp (UPF)"

# Algunos *_init.sh sustituyen solo MCC_2/MNC_2 y dejan "MCC"/"MNC" sin cambiar (PLMN 000/000)
for init in */*_init.sh; do
    comp="$(dirname "$init")"; yaml="$comp/$comp.yaml"
    [[ -f "$yaml" ]] && grep -q "install/etc/open5gs/$comp.yaml" "$init" && grep -q '^cd install/bin' "$init" || continue
    for tok in MCC MNC; do
        grep -qw "$tok" "$yaml" && ! grep -qF "s|$tok|" "$init" || continue
        sed -i "0,/^cd install\/bin/s//sed -i 's|$tok|'\$$tok'|g' install\/etc\/open5gs\/$comp.yaml\ncd install\/bin/" "$init"
        info "parche: $init ahora sustituye $tok"
    done
done

# UPF en otro PC
if [[ -n "$UPF_REMOTO" ]]; then
    # smf.yaml: el SMF anuncia la IP del PC y su cliente PFCP apunta al UPF remoto
    awk -v ip="$IP" -v upf="$UPF_REMOTO" '
        /^    [A-Za-z_]+:/ { pfcp = ($0 ~ /^    pfcp:/); part = "" }
        pfcp && /^      server:/ { part = "server" }
        pfcp && /^      client:/ { part = "client" }
        pfcp && part == "server" && !adv && /^        - address: SMF_IP[[:space:]]*$/ {
            print; print "          advertise: " ip; adv = 1; next }
        pfcp && part == "client" && /^          - address: UPF_IP[[:space:]]*$/ { sub(/UPF_IP/, upf); cli = 1 }
        { print }
        END { exit !(adv && cli) }
    ' smf/smf.yaml.orig > smf/smf.yaml || error "smf/smf.yaml no tiene el formato esperado"
    # compose: el upf de aquí no arranca (perfil upf_local) y el smf publica el 8805/udp
    awk -v m="$MARCA" '
        { print }
        /^  upf:[[:space:]]*$/ { print "    profiles: [\"upf_local\"]  " m }
        /^  smf:[[:space:]]*$/ { print "    ports:  " m; print "      - \"8805:8805/udp\"  " m }
    ' sa-deploy.yaml.orig > "$COMPOSE.tmp"
    # los puertos de antes se vuelven a aplicar sobre el fichero nuevo
    sed -i -z \
        -e 's|    # ports:\n    #   - "2152:2152/udp"|    ports:\n      - "2152:2152/udp"|' \
        -e 's|    # ports:\n    #   - "38412:38412/sctp"|    ports:\n      - "38412:38412/sctp"|' "$COMPOSE.tmp"
    mv "$COMPOSE.tmp" "$COMPOSE"
    info "UPF en otro PC ($UPF_REMOTO): el SMF le habla por 8805/udp; el UPF de aquí no se arranca"
else
    info "UPF en este PC"
fi
chown -R "$USUARI": "$DIR"
docker compose -f "$COMPOSE" config -q || error "$COMPOSE ha quedado mal; los originales están en *.orig"

# --- 4. otros núcleos en marcha ------------------------------------------------------------
pas "4/6 Otros núcleos en este PC"
otros="$(for c in amf smf nrf mongo upf; do
            docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project"}}' "$c" 2>/dev/null || true
        done | sort -u | grep -v "^$DIR|" || true)"
if [[ -n "$otros" ]]; then
    echo "    Hay otro núcleo con los mismos nombres de contenedor:"
    cut -d'|' -f1 <<<"$otros" | sed 's/^/      /'
    r=s; (( SI )) || [[ ! -t 0 ]] || read -r -p "    ¿Lo paro (no se borra nada de su carpeta)? [S/n]: " r
    [[ "${r:-s}" =~ ^[sSyY]$ ]] || error "no pueden funcionar dos núcleos a la vez: páralo y vuelve a ejecutarlo"
    while IFS='|' read -r d p; do
        [[ -n "$p" ]] && docker compose -p "$p" down --remove-orphans >/dev/null 2>&1 || true
        info "parado: ${d:-$p}"
    done <<<"$otros"
    docker rm -f amf smf nrf mongo upf >/dev/null 2>&1 || true
else
    info "ninguno"
fi

# --- 5. imágenes ------------------------------------------------------------------------
pas "5/6 Imágenes (la primera vez tarda 20-30 minutos)"
if docker image inspect docker_open5gs >/dev/null 2>&1; then
    info "la imagen docker_open5gs ya existe"
else
    docker build -t docker_open5gs base || error "ha fallado la construcción de la imagen (vuelve a ejecutarlo)"
fi
docker compose -f "$COMPOSE" build || error "ha fallado docker compose build"
docker compose -f "$COMPOSE" pull --ignore-pull-failures --quiet || true

# --- 6. arranque ------------------------------------------------------------------------
pas "6/6 Arranque"
docker compose -f "$COMPOSE" up -d --remove-orphans || error "no ha arrancado: docker compose logs"
[[ -n "$UPF_REMOTO" ]] && docker rm -f upf >/dev/null 2>&1 || true
info "esperando 20 s a que arranquen..."
sleep 20
docker compose -f "$COMPOSE" ps --format '    {{.Name}}: {{.State}}' 2>/dev/null || docker compose -f "$COMPOSE" ps
if [[ -n "$UPF_REMOTO" ]]; then
    if docker logs smf 2>&1 | grep -q "PFCP associated"; then
        info "el SMF ya está conectado con el UPF de $UPF_REMOTO"
    else
        avis "el SMF aún no está conectado con el UPF de $UPF_REMOTO (¿está instalado y arrancado? se conecta solo)"
    fi
fi

echo
echo "==> Hecho. Núcleo instalado en $DIR"
echo "    Abonados (WebUI):  http://$IP:9999   (usuario admin, contraseña 1423)"
echo "    Para la radio:     AMF = $IP (38412/sctp) · PLMN $MCC$MNC · TAC $TAC · slice SST 1"
[[ -n "$UPF_REMOTO" ]] && echo "    UPF:               en $UPF_REMOTO (en ese PC: sudo bash instalar_upf.sh, core = $IP)"
echo "    Ver registros:     cd $DIR && docker compose logs -f amf smf"
echo "    Parar / arrancar:  cd $DIR && docker compose down  /  docker compose up -d"
