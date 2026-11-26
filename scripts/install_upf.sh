#!/usr/bin/env bash
# ============================================================================
# install_upf.sh - instal·la un UPF separat del core (el pla d'usuari: per on passen les
# dades dels mòbils) i el seu agent, que TRUCA AL CORE (com la ràdio).
#
# Ús:
#   sudo ./install_upf.sh                         (demana el codi d'emparellament)
#   sudo ./install_upf.sh --emparellament codi.txt
#
# Només cal el codi d'emparellament (al core: sudo emparella-upf <nom>), que porta la IP
# del core i el certificat. La resta es fa sol: quan l'agent truca, el core li passa la
# configuració (subxarxes dels mòbils, IP de l'SMF...), arrenca el UPF i, si el panell té
# el mode automàtic actiu, l'SMF del core passa a fer servir aquest UPF.
#
# Opcions:
#   --emparellament F    fitxer amb el codi (si no, es demana que l'enganxis)
#   --imatge F.tar       imatge docker_open5gs desada amb "docker save" (si no, es construeix)
#   --imatge-de U@IP     copia la imatge d'un PC que ja la té per ssh (p. ex. core@192.168.2.99)
#   --gnb-local s|n      hi ha una gNB en aquest mateix PC? (per defecte es detecta)
#   --xarxa CIDR         xarxa Docker del UPF (per defecte 172.23.0.0/24; UPF a .8)
#   --projecte DIR       on es crea el projecte (per defecte /opt/upf5g)
#   --forcar             tornar-lo a instal·lar encara que ja hi sigui (versió nova)
#   --sense-agent        només el UPF, sense l'agent del panell: no cal codi, però sí la IP
#                        del core (--core IP o es pregunta). El core s'ha de separar a mà
#                        (core5g.sh, extra "sin UPF" amb la IP d'aquest PC) i les subxarxes
#                        dels mòbils del .env han de coincidir amb les del core.
#   --core IP            IP del core (només amb --sense-agent; amb agent ve dins del codi)
#
# Queda:
#   /opt/upf5g/                    docker-compose.yml, .env, upf/ (upf.yaml i upf_init.sh)
#   /etc/agent5g-upf/              agent5g.json i certs/ (ca.crt, agent-upf.crt, agent-upf.key)
#   /var/lib/agent5g-upf/          còpies, auditoria i estat
#   servei agent5g-upf             (independent de l'agent de la ràdio si n'hi ha)
# Si ja està instal·lat no es toca res (versió nova: desinstala.sh --upf i tornar-lo a
# executar, o --forcar). Després de desinstala.sh fa servir sol el certificat desat
# (/var/lib/agent5g-upf/emparellament): no cal tornar a enganxar el codi.
# ============================================================================
set -euo pipefail
DKO_REPO="${DKO_REPO:-https://github.com/herlesupreeth/docker_open5gs}"
EMPAR=""; IMATGE_TAR=""; IMATGE_DE=""; GNB_LOCAL=""; XARXA="172.23.0.0/24"; PROJ="/opt/upf5g"; FORCAR=0
AMB_AGENT=1; CORE_IP=""

pas()   { echo; echo "==> [$1] $2"; }
info()  { echo "    $*"; }
avis()  { echo "    AVÍS: $*"; }
error() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --emparellament) EMPAR="$(realpath "${2:?}")"; shift ;;
        --imatge)        IMATGE_TAR="$(realpath "${2:?}")"; shift ;;
        --imatge-de)     IMATGE_DE="${2:?}"; shift ;;
        --gnb-local)     GNB_LOCAL="${2:?}"; shift ;;
        --xarxa)         XARXA="${2:?}"; shift ;;
        --projecte)      PROJ="${2:?}"; shift ;;
        --forcar)        FORCAR=1 ;;
        --sense-agent)   AMB_AGENT=0 ;;
        --core)          CORE_IP="${2:?}"; shift ;;
        -h|--help)       sed -n '3,/^# =====/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)               error "opció desconeguda: $1" ;;
    esac
    shift
done
[[ $EUID -eq 0 ]] || error "cal ser root: sudo $0"
SRC=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
USUARI="${SUDO_USER:-$(id -un)}"
[[ "$XARXA" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.0/24$ ]] || error "--xarxa ha de ser una /24 (p. ex. 172.23.0.0/24)"
UPF_IP="${XARXA%.0/24}.8"

if (( ! FORCAR && ! AMB_AGENT )) && [[ -f "$PROJ/docker-compose.yml" ]] && docker inspect upf >/dev/null 2>&1; then
    echo "==> El UPF (sense agent) ja està instal·lat a $PROJ: no es toca res (--forcar per tornar-lo a fer)."
    exit 0
fi
if (( ! FORCAR && AMB_AGENT )) && [[ -f /etc/systemd/system/agent5g-upf.service && -f /etc/agent5g-upf/agent5g.json ]]; then
    echo "==> El UPF ja està instal·lat en aquest PC: no es toca res."
    echo "    Estat: agent5g-upf $(systemctl is-active agent5g-upf 2>/dev/null || true) · journalctl -u agent5g-upf -n 20"
    echo "    Versió nova: sudo bash $(dirname "$0")/desinstala.sh --upf i torna a executar aquest script (o --forcar)."
    exit 0
fi

# --- 0. codi d'emparellament (o, sense agent, la IP del core) ---------------------------
DESAT=/var/lib/agent5g-upf/emparellament
CODI=""
TMPC="$(mktemp -d)"; trap 'rm -rf "$TMPC"' EXIT
if (( ! AMB_AGENT )); then
    pas 0 "IP del core (UPF sense agent)"
    if [[ -z "$CORE_IP" && -t 0 ]]; then read -r -p "    IP del core (on hi ha l'SMF): " CORE_IP || true; fi
    [[ "$CORE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || error "IP del core invàlida: '$CORE_IP' (--core IP)"
    NOM="upf"; CORE_ENLLAC="$CORE_IP:9544"
    info "UPF sense agent: l'SMF del core $CORE_IP"
else
pas 0 "Codi d'emparellament"
if [[ -z "$EMPAR" && -s "$DESAT/agent-upf.crt" && -s "$DESAT/core" ]]; then
    cn="$(openssl x509 -in "$DESAT/agent-upf.crt" -noout -subject -nameopt multiline 2>/dev/null | sed -n 's/^ *commonName *= *//p')"
    n="${cn#agent-upf}"; n="${n#-}"; n="${n:-upf}"
    CODI="$( { echo "-----BEGIN 5GPANEL UPF $n-----"
               tar czf - -C "$DESAT" ca.crt agent-upf.crt agent-upf.key core | base64 -w 76
               echo "-----END 5GPANEL UPF-----"; } )"
    info "faig servir l'emparellament desat ($DESAT)"
elif [[ -n "$EMPAR" ]]; then
    CODI="$(cat "$EMPAR")"
elif [[ -t 0 ]]; then
    echo "    Al core, executa:  sudo emparella-upf <nom_d_aquest_upf>   (p. ex. upf1)"
    echo "    i enganxa aquí el codi (de la línia BEGIN a la línia END):"
    while IFS= read -r l; do
        CODI+="$l"$'\n'
        [[ "$l" == "-----END 5GPANEL UPF-----" ]] && break
    done
fi
NOM="$(sed -n 's/^-----BEGIN 5GPANEL UPF \([A-Za-z0-9_.-]*\)-----$/\1/p' <<<"$CODI" | head -1)"
[[ -n "$NOM" ]] || error "falta el codi d'emparellament del UPF. Genera'l al core amb: sudo emparella-upf <nom>"
sed -n '/^-----BEGIN/,/^-----END/{/^-----/d;p}' <<<"$CODI" | base64 -d | tar xzf - -C "$TMPC" \
    || error "el codi d'emparellament està malmès (copia'l sencer)"
for f in ca.crt agent-upf.crt agent-upf.key core; do [[ -s "$TMPC/$f" ]] || error "al codi hi falta $f"; done
openssl verify -CAfile "$TMPC/ca.crt" -purpose sslclient "$TMPC/agent-upf.crt" >/dev/null 2>&1 \
    || error "el certificat del codi no és vàlid per a aquesta CA: torna'l a generar al core (sudo emparella-upf $NOM)"
CORE_ENLLAC="$(tr -d '[:space:]' < "$TMPC/core")"
[[ "$CORE_ENLLAC" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]] || error "IP del core del codi invàlida: $CORE_ENLLAC"
CORE_IP="${CORE_ENLLAC%:*}"
info "UPF \"$NOM\": trucarà al core $CORE_ENLLAC"
fi

# --- 1. programari -----------------------------------------------------------------
pas 1 "git, curl, python3 i Docker"
falta=()
for c in git curl openssl python3; do command -v $c >/dev/null || falta+=($c); done
if (( ${#falta[@]} )); then
    apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${falta[@]}" >/dev/null
    info "instal·lat: ${falta[*]}"
fi
if ! docker compose version >/dev/null 2>&1; then
    gd="$(mktemp)"
    curl -fsSL --retry 3 https://get.docker.com -o "$gd" || error "no s'ha pogut descarregar get.docker.com"
    sh "$gd" >/dev/null || error "no s'ha pogut instal·lar Docker"
    rm -f "$gd"; info "Docker instal·lat (get.docker.com)"
fi
info "$(docker --version)"

# --- 2. un UPF que ja hi hagi en aquest PC ---------------------------------------------
pas 2 "UPF que ja hi hagi en aquest PC"
if docker inspect upf >/dev/null 2>&1; then
    dir="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' upf 2>/dev/null || true)"
    if [[ "$(readlink -f "${dir:-/x}")" == "$(readlink -f "$PROJ")" ]]; then
        info "el contenidor upf ja és d'aquest projecte ($PROJ)"
    elif [[ -n "$dir" && ( -f "$dir/sa-deploy.yaml" || -d "$dir/amf" ) ]]; then
        error "en aquest PC hi ha un core docker_open5gs ($dir) amb el seu UPF: el UPF separat va en un altre PC"
    else
        info "hi ha un contenidor upf d'un altre projecte (${dir:-fet a mà}): es farà servir el nou, a $PROJ"
        r=s; [[ -t 0 ]] && read -r -p "    L'aturo i el trec (el seu projecte no s'esborra)? [S/n]: " r
        [[ "${r:-s}" =~ ^[sSyY]$ ]] || error "no es pot tenir dos contenidors upf: atura l'antic i torna-ho a executar"
        if [[ -n "$dir" && -d "$dir" ]]; then (cd "$dir" && docker compose down) >/dev/null 2>&1 || true; fi
        docker rm -f upf >/dev/null 2>&1 || true
        info "UPF antic aturat (el projecte ${dir:-} es queda on era)"
    fi
fi

# --- 3. imatge docker_open5gs i fitxers del UPF ----------------------------------------
pas 3 "Imatge docker_open5gs"
DKO="$PROJ/src/docker_open5gs"
mkdir -p "$PROJ/src"
if [[ -d "$DKO/.git" ]]; then
    info "fitxers de docker_open5gs ja descarregats ($DKO)"
else
    git clone -q --depth 1 "$DKO_REPO" "$DKO" || error "no s'ha pogut clonar $DKO_REPO"
    info "descarregat $DKO_REPO a $DKO"
fi
if docker image inspect docker_open5gs >/dev/null 2>&1; then
    info "la imatge docker_open5gs ja hi és (no es torna a construir)"
elif [[ -n "$IMATGE_TAR" ]]; then
    docker load -i "$IMATGE_TAR" >/dev/null || error "no s'ha pogut carregar $IMATGE_TAR"
    info "imatge carregada de $IMATGE_TAR"
elif [[ -n "$IMATGE_DE" ]]; then
    info "copiant la imatge de $IMATGE_DE (uns 2 GB, sense fitxer intermedi)..."
    sudo -u "$USUARI" ssh "$IMATGE_DE" docker save docker_open5gs | docker load >/dev/null \
        || error "no s'ha pogut copiar la imatge de $IMATGE_DE"
else
    info "construint la imatge (la part lenta: uns 20-30 minuts la primera vegada)"
    info "(per anar més de pressa: --imatge-de usuari@IP_del_core, si el core ja la té)"
    (cd "$DKO/base" && docker build -q -t docker_open5gs .) >/dev/null || error "la construcció de la imatge ha fallat"
    info "imatge docker_open5gs construïda"
fi

pas 4 "Projecte del UPF ($PROJ)"
mkdir -p "$PROJ/upf" "$PROJ/log"
for f in upf_init.sh tun_if.py ip_utils.py upf.yaml; do
    [[ -f "$DKO/upf/$f" ]] || error "a $DKO/upf no hi ha $f"
    cp -f "$DKO/upf/$f" "$PROJ/upf/$f"
done
# Node ID PFCP: el UPF s'anuncia amb la IP del PC (UPF_HOST_IP), no amb la del contenidor
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
    sys.exit('upf.yaml: no trobo "pfcp: server: - address: UPF_IP"')
open(p, 'w').write('\n'.join(out))
PY
grep -q 'UPF_HOST_IP' "$PROJ/upf/upf_init.sh" || \
    sed -i "/^sed -i 's|UPF_ADVERTISE_IP|/a sed -i 's|UPF_HOST_IP|'\$UPF_HOST_IP'|g' install/etc/open5gs/upf.yaml" "$PROJ/upf/upf_init.sh"
grep -q 'UPF_HOST_IP' "$PROJ/upf/upf_init.sh" || error "no he pogut afegir UPF_HOST_IP a upf_init.sh"
chmod +x "$PROJ/upf/upf_init.sh"

# gNB al mateix PC? El 2152/udp del PC ja és de la gNB: el UPF no el publica i la gNB hi
# arriba pel pont de Docker (UPF_ADVERTISE_IP = IP del contenidor).
if [[ -z "$GNB_LOCAL" ]]; then
    det=n
    { ss -Hlun 2>/dev/null | grep -q ':2152\b' || docker inspect ocudu_gnb >/dev/null 2>&1; } && det=s
    GNB_LOCAL=$det
    [[ -t 0 ]] && { read -r -p "    Hi ha una gNB (ràdio) en aquest mateix PC? [$det]: " r; GNB_LOCAL="${r:-$det}"; }
fi
[[ "$GNB_LOCAL" =~ ^[sSyY] ]] && GNB_LOCAL=1 || GNB_LOCAL=0
# VPN de túnel complet: el trànsit dels mòbils ha de sortir per la LAN, no per la VPN
DEV_DEF="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | head -1)"
REGLA_MAIN=0; [[ "$DEV_DEF" =~ ^(tun|wg|ppp|tap) ]] && REGLA_MAIN=1

if (( GNB_LOCAL )); then
    PORTS_GTP="      # GTP-U (N3) no es publica: el 2152 del PC és de la gNB, que arriba al UPF pel pont"
else
    PORTS_GTP='      - "2152:2152/udp"   # GTP-U (N3): la gNB envia les dades a la IP del PC'
fi
cat > "$PROJ/docker-compose.yml" <<EOF
# UPF separat del core (panel5g). El genera install_upf.sh: no l'editis a mà.
# La configuració (.env) la hi posa l'agent amb el que li diu el core.
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
# UPF separat (panel5g). Els valors del core (SMF_IP, subxarxes dels mòbils...) els hi
# escriu l'agent quan el core el configura; TEST_NETWORK i UPF_IP són d'aquest PC.
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
    info "creat $E (el core hi posarà els seus valors)"
else
    sed -i "s|^TEST_NETWORK=.*|TEST_NETWORK=$XARXA|; s|^UPF_IP=.*|UPF_IP=$UPF_IP|" "$E"
    info "$E ja hi era: es conserva (el core l'actualitza)"
fi
chmod 600 "$E"
(cd "$PROJ" && docker compose config -q) || error "el docker-compose.yml generat no és vàlid"
info "gNB al mateix PC: $( ((GNB_LOCAL)) && echo "sí (N3 pel pont de Docker, $UPF_IP)" || echo "no (N3 per la IP del PC, 2152/udp publicat)")"
(( REGLA_MAIN )) && info "ruta per defecte per $DEV_DEF (VPN): el trànsit dels mòbils sortirà per la LAN (ip rule)"

# --- 5. sense agent: s'arrenca el UPF i prou ----------------------------------------------
if (( ! AMB_AGENT )); then
    pas 5 "Arrencada del UPF (sense agent)"
    (cd "$PROJ" && docker compose -p upf5g up -d) || error "el UPF no ha arrencat: cd $PROJ && docker compose -p upf5g logs"
    if (( REGLA_MAIN )) && ! ip rule show | grep -q "from $XARXA lookup main"; then
        ip rule add from "$XARXA" lookup main priority 100 || true
        avis "regla ip (from $XARXA lookup main) posada a mà: no es manté després d'un reinici"
    fi
    echo
    echo "==> Fet. UPF arrencat a $PROJ (sense agent del panell)."
    echo "    Ara, al core, fes que l'SMF faci servir aquest UPF: core5g.sh > versió genèrica > extra"
    echo "    \"sin UPF\" amb la IP d'aquest PC (${IP_PC:-?}). Comprova que UE_IPV4_INTERNET i UE_IPV4_IMS"
    echo "    de $PROJ/.env són les del .env del core."
    echo "    Registre: docker logs -f upf"
    exit 0
fi

# --- 5. agent ------------------------------------------------------------------------
pas 5 "Agent del UPF (agent5g-upf)"
install -d -m 755 /opt/agent5g
install -m 755 "$SRC/agent/agent5g.py" /opt/agent5g/agent5g.py
install -d -m 755 /opt/agent5g; install -m 755 "$SRC/scripts/agent5g_menu.sh" /opt/agent5g/agent5g_menu.sh; ln -sf /opt/agent5g/agent5g_menu.sh /usr/local/sbin/agent5g   # menú: sudo agent5g
git -C "$SRC" log -1 --format='%h · %cd (instal·lació)' --date=format:'%Y-%m-%d %H:%M' > /opt/agent5g/VERSIO 2>/dev/null || true
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
    # truca al core (com la ràdio): no escolta cap port
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
sed -e 's#^Description=.*#Description=agent5g-upf - agent del UPF separat (truca al core)#' \
    -e 's#-c /etc/agent5g/agent5g.json#-c /etc/agent5g-upf/agent5g.json#' \
    -e "s#^ReadWritePaths=/var/lib/agent5g\$#ReadWritePaths=/var/lib/agent5g-upf $PROJ#" \
    -e 's#^RestrictAddressFamilies=.*#RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK#' \
    "$SRC/agent/agent5g.service" > /etc/systemd/system/agent5g-upf.service
systemctl daemon-reload
systemctl enable agent5g-upf >/dev/null 2>&1
systemctl restart agent5g-upf
info "esperant que truqui al core i que el core el configuri (fins a 40 s)..."
ok=0
for _ in $(seq 1 20); do
    sleep 2
    if journalctl -u agent5g-upf --since "-60s" --no-pager 2>/dev/null | grep -qE "UPF (actiu|aturat)"; then ok=1; break; fi
done
if ! systemctl is-active -q agent5g-upf; then
    avis "agent5g-upf no ha arrencat: journalctl -u agent5g-upf -n 30"
elif (( ok )); then
    journalctl -u agent5g-upf --since "-60s" --no-pager -o cat 2>/dev/null | grep -E "connectat al core|UPF (actiu|aturat)" | tail -2 | sed 's/^/    /'
else
    avis "encara no ha rebut la configuració del core (ho reintenta sol). Mira: journalctl -u agent5g-upf -n 20"
    avis "al core, l'agent ha de ser d'aquesta versió (actualitzar.sh) i el port 9544/tcp obert"
fi

echo
echo "==> Fet. UPF \"$NOM\" instal·lat; truca al core $CORE_ENLLAC."
echo "    Al panell, pestanya UPF: es veu connectat i, en mode automàtic, en ús pel core."
echo "    Projecte:       $PROJ   (docker logs -f upf)"
echo "    Certificats:    /etc/agent5g-upf/certs/   ·  configuració: /etc/agent5g-upf/agent5g.json"
echo "    Registre:       journalctl -u agent5g-upf -f"
