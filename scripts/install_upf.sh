#!/usr/bin/env bash
# ============================================================================
# install_upf.sh - instala un UPF separado del core (el plano de usuario: por donde pasan los
# datos de los móviles) y su agente, que LLAMA AL CORE (como la radio).
#
# Uso:
#   sudo ./install_upf.sh                         (pide el código de emparejamiento)
#   sudo ./install_upf.sh --emparejamiento codigo.txt
#
# Solo hace falta el código de emparejamiento (en el core: sudo emparella-upf <nombre>), que lleva la IP
# del core y el certificado. El resto se hace solo: cuando el agente llama, el core le pasa la
# configuración (subredes de los móviles, IP del SMF...), arranca el UPF y, si el panel tiene
# el modo automático activo, el SMF del core pasa a usar este UPF.
#
# Opciones:
#   --emparejamiento F   fichero con el código (si no, se pide que lo pegues)
#   --imagen F.tar       imagen docker_open5gs guardada con "docker save" (si no, se construye)
#   --imagen-de U@IP     copia la imagen por ssh de un PC que ya la tiene (p. ej. core@192.168.2.99)
#   --gnb-local s|n      ¿hay una gNB en este mismo PC? (por defecto se detecta)
#   --red CIDR           red Docker del UPF (por defecto 172.23.0.0/24; UPF en .8)
#   --proyecto DIR       dónde se crea el proyecto (por defecto /opt/upf5g)
#   --forzar             volver a instalarlo aunque ya esté (versión nueva)
#   --sin-agente         solo el UPF, sin el agente del panel: no hace falta código, pero sí la IP
#                        del core (--core IP o se pregunta). El core se tiene que separar a mano
#                        (core5g.sh, extra "sin UPF" con la IP de este PC) y las subredes
#                        de los móviles del .env tienen que coincidir con las del core.
#   --core IP            IP del core (solo con --sin-agente; con agente va dentro del código)
#   (también valen los nombres antiguos en catalán: --emparellament, --imatge, --forcar, --sense-agent...)
# Queda:
#   /opt/upf5g/                    docker-compose.yml, .env, upf/ (upf.yaml i upf_init.sh)
#   /etc/agent5g-upf/              agent5g.json i certs/ (ca.crt, agent-upf.crt, agent-upf.key)
#   /var/lib/agent5g-upf/          copias, auditoría y estado
#   servicio agent5g-upf           (independiente del agente de la radio si lo hay)
# Si ya está instalado no se toca nada (versión nueva: desinstala.sh --upf y volver a
# ejecutarlo, o --forzar). Después de desinstala.sh usa solo el certificado guardado
# (/var/lib/agent5g-upf/emparellament): no hace falta volver a pegar el código.
# ============================================================================
set -euo pipefail
DKO_REPO="${DKO_REPO:-https://github.com/herlesupreeth/docker_open5gs}"
EMPAR=""; IMATGE_TAR=""; IMATGE_DE=""; GNB_LOCAL=""; XARXA="172.23.0.0/24"; PROJ="/opt/upf5g"; FORCAR=0
AMB_AGENT=1; CORE_IP=""

pas()   { echo; echo "==> [$1] $2"; }
info()  { echo "    $*"; }
avis()  { echo "    AVISO: $*"; }
error() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --emparellament|--emparejamiento) EMPAR="$(realpath "${2:?}")"; shift ;;
        --imatge|--imagen)        IMATGE_TAR="$(realpath "${2:?}")"; shift ;;
        --imatge-de|--imagen-de)  IMATGE_DE="${2:?}"; shift ;;
        --gnb-local)     GNB_LOCAL="${2:?}"; shift ;;
        --xarxa|--red)            XARXA="${2:?}"; shift ;;
        --projecte|--proyecto)    PROJ="${2:?}"; shift ;;
        --forcar|--forzar)        FORCAR=1 ;;
        --sense-agent|--sin-agente)  AMB_AGENT=0 ;;
        --core)          CORE_IP="${2:?}"; shift ;;
        -h|--help)       sed -n '3,/^# =====/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)               error "opción desconocida: $1" ;;
    esac
    shift
done
[[ $EUID -eq 0 ]] || error "hay que ser root: sudo $0"
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
USUARI="${SUDO_USER:-$(id -un)}"
[[ "$XARXA" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.0/24$ ]] || error "--red tiene que ser una /24 (p. ej. 172.23.0.0/24)"
UPF_IP="${XARXA%.0/24}.8"

if (( ! FORCAR && ! AMB_AGENT )) && [[ -f "$PROJ/docker-compose.yml" ]] && docker inspect upf >/dev/null 2>&1; then
    echo "==> El UPF (sin agente) ya está instalado en $PROJ: no se toca nada (--forzar para rehacerlo)."
    exit 0
fi
if (( ! FORCAR && AMB_AGENT )) && [[ -f /etc/systemd/system/agent5g-upf.service && -f /etc/agent5g-upf/agent5g.json ]]; then
    echo "==> El UPF ya está instalado en este PC: no se toca nada."
    echo "    Estado: agent5g-upf $(systemctl is-active agent5g-upf 2>/dev/null || true) · journalctl -u agent5g-upf -n 20"
    echo "    Versión nueva: sudo bash $(dirname "$0")/desinstala.sh --upf y vuelve a ejecutar este script (o --forzar)."
    exit 0
fi

# --- 0. código de emparejamiento (o, sin agente, la IP del core) ---------------------------
DESAT=/var/lib/agent5g-upf/emparellament
CODI=""
TMPC="$(mktemp -d)"; trap 'rm -rf "$TMPC"' EXIT
if (( ! AMB_AGENT )); then
    pas 0 "IP del core (UPF sin agente)"
    if [[ -z "$CORE_IP" && -t 0 ]]; then read -r -p "    IP del core (donde está el SMF): " CORE_IP || true; fi
    [[ "$CORE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || error "IP del core no válida: '$CORE_IP' (--core IP)"
    NOM="upf"; CORE_ENLLAC="$CORE_IP:9544"
    info "UPF sin agente: el SMF del core $CORE_IP"
else
pas 0 "Código de emparejamiento"
if [[ -z "$EMPAR" && -s "$DESAT/agent-upf.crt" && -s "$DESAT/core" ]]; then
    cn="$(openssl x509 -in "$DESAT/agent-upf.crt" -noout -subject -nameopt multiline 2>/dev/null | sed -n 's/^ *commonName *= *//p')"
    n="${cn#agent-upf}"; n="${n#-}"; n="${n:-upf}"
    CODI="$( { echo "-----BEGIN 5GPANEL UPF $n-----"
               tar czf - -C "$DESAT" ca.crt agent-upf.crt agent-upf.key core | base64 -w 76
               echo "-----END 5GPANEL UPF-----"; } )"
    info "uso el emparejamiento guardado ($DESAT)"
elif [[ -n "$EMPAR" ]]; then
    CODI="$(cat "$EMPAR")"
elif [[ -t 0 ]]; then
    echo "    En el core, ejecuta:  sudo emparella-upf <nombre_de_este_upf>   (p. ej. upf1)"
    echo "    y pega aquí el código (de la línea BEGIN a la línea END):"
    while IFS= read -r l; do
        CODI+="$l"$'\n'
        [[ "$l" == "-----END 5GPANEL UPF-----" ]] && break
    done
fi
NOM="$(sed -n 's/^-----BEGIN 5GPANEL UPF \([A-Za-z0-9_.-]*\)-----$/\1/p' <<<"$CODI" | head -1)"
[[ -n "$NOM" ]] || error "falta el código de emparejamiento del UPF. Genéralo en el core con: sudo emparella-upf <nombre>"
sed -n '/^-----BEGIN/,/^-----END/{/^-----/d;p}' <<<"$CODI" | base64 -d | tar xzf - -C "$TMPC" \
    || error "el código de emparejamiento está dañado (cópialo entero)"
for f in ca.crt agent-upf.crt agent-upf.key core; do [[ -s "$TMPC/$f" ]] || error "al código le falta $f"; done
openssl verify -CAfile "$TMPC/ca.crt" -purpose sslclient "$TMPC/agent-upf.crt" >/dev/null 2>&1 \
    || error "el certificado del código no es válido para esta CA: vuelve a generarlo en el core (sudo emparella-upf $NOM)"
CORE_ENLLAC="$(tr -d '[:space:]' < "$TMPC/core")"
[[ "$CORE_ENLLAC" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]] || error "IP del core del código no válida: $CORE_ENLLAC"
CORE_IP="${CORE_ENLLAC%:*}"
info "UPF \"$NOM\": llamará al core $CORE_ENLLAC"
fi

# --- 1. programas -------------------------------------------------------------------
pas 1 "git, curl, python3 i Docker"
falta=()
for c in git curl openssl python3; do command -v $c >/dev/null || falta+=($c); done
if (( ${#falta[@]} )); then
    apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${falta[@]}" >/dev/null
    info "instalado: ${falta[*]}"
fi
if ! docker compose version >/dev/null 2>&1; then
    gd="$(mktemp)"
    curl -fsSL --retry 3 https://get.docker.com -o "$gd" || error "no se ha podido descargar get.docker.com"
    sh "$gd" >/dev/null || error "no se ha podido instalar Docker"
    rm -f "$gd"; info "Docker instalado (get.docker.com)"
fi
info "$(docker --version)"

# --- 2. un UPF que ya haya en este PC ---------------------------------------------------
pas 2 "UPF que ya haya en este PC"
if docker inspect upf >/dev/null 2>&1; then
    dir="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' upf 2>/dev/null || true)"
    if [[ "$(readlink -f "${dir:-/x}")" == "$(readlink -f "$PROJ")" ]]; then
        info "el contenedor upf ya es de este proyecto ($PROJ)"
    elif [[ -n "$dir" && ( -f "$dir/sa-deploy.yaml" || -d "$dir/amf" ) ]]; then
        error "en este PC hay un core docker_open5gs ($dir) con su UPF: el UPF separado va en otro PC"
    else
        info "hay un contenedor upf de otro proyecto (${dir:-hecho a mano}): se usará el nuevo, en $PROJ"
        r=s; [[ -t 0 ]] && read -r -p "    ¿Lo paro y lo quito (su proyecto no se borra)? [S/n]: " r
        [[ "${r:-s}" =~ ^[sSyY]$ ]] || error "no puede haber dos contenedores upf: para el antiguo y vuelve a ejecutarlo"
        if [[ -n "$dir" && -d "$dir" ]]; then (cd "$dir" && docker compose down) >/dev/null 2>&1 || true; fi
        docker rm -f upf >/dev/null 2>&1 || true
        info "UPF antiguo parado (el proyecto ${dir:-} se queda donde estaba)"
    fi
fi

# --- 3. imagen docker_open5gs y ficheros del UPF ----------------------------------------
pas 3 "Imagen docker_open5gs"
DKO="$PROJ/src/docker_open5gs"
mkdir -p "$PROJ/src"
if [[ -d "$DKO/.git" ]]; then
    info "ficheros de docker_open5gs ya descargados ($DKO)"
else
    git clone -q --depth 1 "$DKO_REPO" "$DKO" || error "no se ha podido clonar $DKO_REPO"
    info "descargado $DKO_REPO en $DKO"
fi
if docker image inspect docker_open5gs >/dev/null 2>&1; then
    info "la imagen docker_open5gs ya está (no se vuelve a construir)"
elif [[ -n "$IMATGE_TAR" ]]; then
    docker load -i "$IMATGE_TAR" >/dev/null || error "no se ha podido cargar $IMATGE_TAR"
    info "imagen cargada de $IMATGE_TAR"
elif [[ -n "$IMATGE_DE" ]]; then
    info "copiando la imagen de $IMATGE_DE (unos 2 GB, sin fichero intermedio)..."
    sudo -u "$USUARI" ssh "$IMATGE_DE" docker save docker_open5gs | docker load >/dev/null \
        || error "no se ha podido copiar la imagen de $IMATGE_DE"
else
    info "construyendo la imagen (la parte lenta: unos 20-30 minutos la primera vez)"
    info "(para ir más rápido: --imagen-de usuario@IP_del_core, si el core ya la tiene)"
    (cd "$DKO/base" && docker build -q -t docker_open5gs .) >/dev/null || error "la construcción de la imagen ha fallado"
    info "imagen docker_open5gs construida"
fi

pas 4 "Proyecto del UPF ($PROJ)"
mkdir -p "$PROJ/upf" "$PROJ/log"
for f in upf_init.sh tun_if.py ip_utils.py upf.yaml; do
    [[ -f "$DKO/upf/$f" ]] || error "en $DKO/upf no está $f"
    cp -f "$DKO/upf/$f" "$PROJ/upf/$f"
done
# Node ID PFCP: el UPF se anuncia con la IP del PC (UPF_HOST_IP), no con la del contenedor
python3 - "$PROJ/upf/upf.yaml" <<'PY'
import re, sys
p = sys.argv[1]
l = open(p).read().split('\n')
out, pfcp, srv, fet = [], False, False, False
for x in l:
    out.append(x)
    if re.match(r'^\s*pfcp:\s*$', x): pfcp = True; continue
    if pfcp and re.match(r'^\s*server:\s*$', x): srv = True; continue
    if pfcp and srv and not fet and re.match(r'^(\s*)-\s*address:\s*UPF_IP\s*$', x):
        out.append(' ' * (len(x) - len(x.lstrip()) + 2) + 'advertise: UPF_HOST_IP   # Node ID PFCP = IP del PC')
        fet = True
if not fet:
    sys.exit('upf.yaml: no encuentro "pfcp: server: - address: UPF_IP"')
open(p, 'w').write('\n'.join(out))
PY
grep -q 'UPF_HOST_IP' "$PROJ/upf/upf_init.sh" || \
    sed -i "/^sed -i 's|UPF_ADVERTISE_IP|/a sed -i 's|UPF_HOST_IP|'\$UPF_HOST_IP'|g' install/etc/open5gs/upf.yaml" "$PROJ/upf/upf_init.sh"
grep -q 'UPF_HOST_IP' "$PROJ/upf/upf_init.sh" || error "no he podido añadir UPF_HOST_IP a upf_init.sh"
chmod +x "$PROJ/upf/upf_init.sh"

# ¿gNB en el mismo PC? El 2152/udp del PC ya es de la gNB: el UPF no lo publica y la gNB
# llega por el puente de Docker (UPF_ADVERTISE_IP = IP del contenedor).
if [[ -z "$GNB_LOCAL" ]]; then
    det=n
    { ss -Hlun 2>/dev/null | grep -q ':2152\b' || docker inspect ocudu_gnb >/dev/null 2>&1; } && det=s
    GNB_LOCAL=$det
    [[ -t 0 ]] && { read -r -p "    ¿Hay una gNB (radio) en este mismo PC? [$det]: " r; GNB_LOCAL="${r:-$det}"; }
fi
[[ "$GNB_LOCAL" =~ ^[sSyY] ]] && GNB_LOCAL=1 || GNB_LOCAL=0
# VPN de túnel completo: el tráfico de los móviles tiene que salir por la LAN, no por la VPN
DEV_DEF="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | head -1)"
REGLA_MAIN=0; [[ "$DEV_DEF" =~ ^(tun|wg|ppp|tap) ]] && REGLA_MAIN=1

if (( GNB_LOCAL )); then
    PORTS_GTP="      # GTP-U (N3) no se publica: el 2152 del PC es de la gNB, que llega al UPF por el puente"
else
    PORTS_GTP='      - "2152:2152/udp"   # GTP-U (N3): la gNB envía los datos a la IP del PC'
fi
cat > "$PROJ/docker-compose.yml" <<EOF
# UPF separado del core (panel5g). Lo genera install_upf.sh: no lo edites a mano.
# La configuración (.env) la pone el agente con lo que le dice el core.
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
      - "8805:8805/udp"   # PFCP (N4): l'SMF del core
$PORTS_GTP
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
E="$PROJ/.env"
IP_PC="$(ip -4 route get "$CORE_IP" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
if [[ ! -f "$E" ]]; then
    cat > "$E" <<EOF
# UPF separado (panel5g). Los valores del core (SMF_IP, subredes de los móviles...) los
# escribe el agente cuando el core lo configura; TEST_NETWORK y UPF_IP son de este PC.
TEST_NETWORK=$XARXA
UPF_IP=$UPF_IP
UPF_ADVERTISE_IP=$UPF_IP
UPF_HOST_IP=${IP_PC:-$CORE_IP}
SMF_IP=$CORE_IP
UPF_TUNTAP_MODE=tun
UPF_INTERNET_APN_IF_NAME=ogstun
UPF_IMS_APN_IF_NAME=ogstun2
UE_IPV4_INTERNET=192.168.100.0/24
UE_IPV4_IMS=192.168.101.0/24
PCSCF_IP=172.22.0.21
MAX_NUM_UE=1024
EOF
    info "creado $E (el core pondrá sus valores)"
else
    sed -i "s|^TEST_NETWORK=.*|TEST_NETWORK=$XARXA|; s|^UPF_IP=.*|UPF_IP=$UPF_IP|" "$E"
    info "$E ya existía: se conserva (el core lo actualiza)"
fi
chmod 600 "$E"
(cd "$PROJ" && docker compose config -q) || error "el docker-compose.yml generado no es válido"
info "gNB en el mismo PC: $( ((GNB_LOCAL)) && echo "sí (N3 por el puente de Docker, $UPF_IP)" || echo "no (N3 por la IP del PC, 2152/udp publicado)")"
(( REGLA_MAIN )) && info "ruta por defecto por $DEV_DEF (VPN): el tráfico de los móviles saldrá por la LAN (ip rule)"

# --- 5. sin agente: se arranca el UPF y listo ---------------------------------------------
if (( ! AMB_AGENT )); then
    pas 5 "Arranque del UPF (sin agente)"
    (cd "$PROJ" && docker compose -p upf5g up -d) || error "el UPF no ha arrancado: cd $PROJ && docker compose -p upf5g logs"
    if (( REGLA_MAIN )) && ! ip rule show | grep -q "from $XARXA lookup main"; then
        ip rule add from "$XARXA" lookup main priority 100 || true
        avis "regla ip (from $XARXA lookup main) puesta a mano: no se mantiene tras un reinicio"
    fi
    echo
    echo "==> Hecho. UPF arrancado en $PROJ (sin agente del panel)."
    echo "    Ahora, en el core, haz que el SMF use este UPF: core5g.sh > versión genérica > extra"
    echo "    \"sin UPF\" con la IP de este PC (${IP_PC:-?}). Comprueba que UE_IPV4_INTERNET y UE_IPV4_IMS"
    echo "    de $PROJ/.env son las del .env del core."
    echo "    Registro: docker logs -f upf"
    exit 0
fi

# --- 5. agente ----------------------------------------------------------------------
pas 5 "Agente del UPF (agent5g-upf)"
install -d -m 755 /opt/agent5g
install -m 755 "$SRC/agent/agent5g.py" /opt/agent5g/agent5g.py
install -d -m 755 /opt/agent5g; install -m 755 "$SRC/scripts/agent5g_menu.sh" /opt/agent5g/agent5g_menu.sh; ln -sf /opt/agent5g/agent5g_menu.sh /usr/local/sbin/agent5g   # menú: sudo agent5g
git -C "$SRC" log -1 --format='%h · %cd (instalación)' --date=format:'%Y-%m-%d %H:%M' > /opt/agent5g/VERSIO 2>/dev/null || true
install -d -m 700 /etc/agent5g-upf /etc/agent5g-upf/certs /var/lib/agent5g-upf
install -m 600 "$TMPC/ca.crt" "$TMPC/agent-upf.crt" "$TMPC/agent-upf.key" /etc/agent5g-upf/certs/
rm -rf "$DESAT"
PROJ="$PROJ" NOM="$NOM" CORE="$CORE_ENLLAC" GNB_LOCAL="$GNB_LOCAL" XARXA="$XARXA" UPF_IP="$UPF_IP" \
REGLA_MAIN="$REGLA_MAIN" python3 - <<'PY'
import json, os
e = os.environ
f = '/etc/agent5g-upf/agent5g.json'
cfg = {
    'role': 'upf', 'name': f"UPF {e['NOM']}",
    # llama al core (como la radio): no escucha ningún puerto
    'listen': None, 'core': e['CORE'].rsplit(':', 1)[0], 'core_port': int(e['CORE'].rsplit(':', 1)[1]),
    'cert': '/etc/agent5g-upf/certs/agent-upf.crt', 'key': '/etc/agent5g-upf/certs/agent-upf.key',
    'ca': '/etc/agent5g-upf/certs/ca.crt', 'allowed_client_cn': ['panel5g'],
    'project_dir': e['PROJ'], 'env_file': '.env', 'compose_files': ['docker-compose.yml'],
    'compose_project': 'upf5g', 'editable_keys': {}, 'project_actions': ['up', 'stop'],
    'containers': ['upf'], 'services': ['upf'],
    'log_files': {'upf.log': os.path.join(e['PROJ'], 'log', 'upf.log')},
    'backup_dir': '/var/lib/agent5g-upf/backups', 'audit_log': '/var/lib/agent5g-upf/audit.log',
    'docker_bin': '/usr/bin/docker', 'max_log_lines': 2000, 'max_backups': 50, 'apply_timeout': 300,
    'voip': {'permes': False},
    'upf': {'gnb_local': e['GNB_LOCAL'] == '1', 'xarxa': e['XARXA'], 'upf_ip': e['UPF_IP'],
            'regla_main': e['REGLA_MAIN'] == '1'},
}
with open(f + '.nou', 'w') as fh:
    json.dump(cfg, fh, indent=2, ensure_ascii=False)
os.chmod(f + '.nou', 0o600)
os.replace(f + '.nou', f)
PY
sed -e 's#^Description=.*#Description=agent5g-upf - agente del UPF separado (llama al core)#' \
    -e 's#-c /etc/agent5g/agent5g.json#-c /etc/agent5g-upf/agent5g.json#' \
    -e "s#^ReadWritePaths=/var/lib/agent5g\$#ReadWritePaths=/var/lib/agent5g-upf $PROJ#" \
    -e 's#^RestrictAddressFamilies=.*#RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK#' \
    "$SRC/agent/agent5g.service" > /etc/systemd/system/agent5g-upf.service
systemctl daemon-reload
systemctl enable agent5g-upf >/dev/null 2>&1
systemctl restart agent5g-upf
info "esperando a que llame al core y que el core lo configure (hasta 40 s)..."
ok=0
for _ in $(seq 1 20); do
    sleep 2
    if journalctl -u agent5g-upf --since "-60s" --no-pager 2>/dev/null | grep -qE "UPF (actiu|aturat)"; then ok=1; break; fi
done
if ! systemctl is-active -q agent5g-upf; then
    avis "agent5g-upf no ha arrancado: journalctl -u agent5g-upf -n 30"
elif (( ok )); then
    journalctl -u agent5g-upf --since "-60s" --no-pager -o cat 2>/dev/null | grep -E "connectat al core|UPF (actiu|aturat)" | tail -2 | sed 's/^/    /'
else
    avis "todavía no ha recibido la configuración del core (lo reintenta solo). Mira: journalctl -u agent5g-upf -n 20"
    avis "en el core, el agente tiene que ser de esta versión (actualitzar.sh) y el puerto 9544/tcp abierto"
fi

echo
echo "==> Hecho. UPF \"$NOM\" instalado; llama al core $CORE_ENLLAC."
echo "    En el panel, pestaña UPF: se ve conectado y, en modo automático, en uso por el core."
echo "    Proyecto:       $PROJ   (docker logs -f upf)"
echo "    Certificados:   /etc/agent5g-upf/certs/   ·  configuración: /etc/agent5g-upf/agent5g.json"
echo "    Registro:       journalctl -u agent5g-upf -f"
