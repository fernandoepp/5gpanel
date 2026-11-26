#!/usr/bin/env bash
# ============================================================================
# agent5g - menú de terminal per configurar l'agent del panel5g d'aquest PC.
#
#   sudo agent5g
#
# Al core:
#   1) Veure la configuració (IP, certificats, carpetes)
#   2) Canviar la IP del core: .env, smf.yaml, codis d'emparellament, certificats
#      (mateixa CA), panell i reinici del core amb la IP nova
#   3) Renovar els certificats (mateixa IP)
# A la ràdio o al PC del UPF:
#   1) Veure la configuració
#   2) Canviar la IP del core al qual truca (i reiniciar el que en depèn)
# A tots: Actualitzar des de GitHub (baixa l'última versió i la instal·la; amb còpia).
#   Font: AGENT5G_REPO (per defecte https://github.com/fernandoepp/5gpanel) i
#   AGENT5G_BRANCA (per defecte main), p. ex.  sudo AGENT5G_BRANCA=proves agent5g
#
# La IP del core NO es canvia des del navegador (camp de només lectura): es fa aquí,
# perquè afecta els certificats, el panell i tot el core alhora.
# ============================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Cal ser root: sudo agent5g"; exit 1; }
IP_RX='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
TS=$(date +%Y%m%d-%H%M%S)
info() { echo "    $*"; }
avis() { echo "    AVÍS: $*"; }
error() { echo "ERROR: $*" >&2; exit 1; }
pregunta() {   # pregunta <text> <variable> [per defecte]
    local r; read -r -p "    $1${3:+ [$3]}: " r || true
    printf -v "$2" '%s' "${r:-${3:-}}"
}
si_no() { local r; read -r -p "    $1 [s/N]: " r || true; [[ "$r" =~ ^[sSyY]$ ]]; }
jget() {   # jget <fitxer> <clau> [<subclau>]
    python3 - "$@" <<'PY' 2>/dev/null || true
import json, sys
c = json.load(open(sys.argv[1]))
for k in sys.argv[2:]:
    c = c.get(k) if isinstance(c, dict) else None
print('' if c is None else (json.dumps(c) if isinstance(c, (list, dict)) else c))
PY
}
jset() {   # jset <fitxer> <clau> <valor>  (amb còpia)
    cp -p "$1" "$1.bak-$TS"
    python3 - "$@" <<'PY'
import json, os, sys
f, k, v = sys.argv[1:4]
c = json.load(open(f))
c[k] = v
open(f + '.nou', 'w').write(json.dumps(c, indent=2, ensure_ascii=False))
os.chmod(f + '.nou', 0o600)
os.replace(f + '.nou', f)
PY
}
env_get() { sed -n "s/^$2=\(.*\)$/\1/p" "$1" 2>/dev/null | tail -1 | tr -d '"'"'"; }
ips_locals() { ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1] " (" $2 ")"}'; }
es_local() { ip -4 -o addr show 2>/dev/null | grep -q " $1/"; }
ip_ruta() { ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p'; }

REPO="${AGENT5G_REPO:-https://github.com/fernandoepp/5gpanel}"
BRANCA="${AGENT5G_BRANCA:-main}"
VERSIO_F=/opt/agent5g/VERSIO
versio_actual() { cat "$VERSIO_F" 2>/dev/null || echo "desconeguda (instal·lada abans que hi hagués aquesta opció)"; }

CFG_A=/etc/agent5g/agent5g.json
CFG_U=/etc/agent5g-upf/agent5g.json
ROL=""; [[ -f $CFG_A ]] && ROL="$(jget $CFG_A role)"
TE_UPF=0; [[ -f $CFG_U ]] && TE_UPF=1
[[ -n "$ROL" || $TE_UPF == 1 ]] || error "en aquest PC no hi ha cap agent del panel5g (/etc/agent5g ni /etc/agent5g-upf)"

# --- core ------------------------------------------------------------------------------
certs_core() {   # carpeta amb la CA (on la fan servir emparella-radio/-upf)
    local c
    c="$(sed -n 's#^CERTS=\${2:-\(.*\)}$#\1#p' /opt/agent5g/eines/emparella_radio.sh 2>/dev/null | head -1 || true)"
    [[ -n "$c" && -f "$c/ca/ca.key" ]] && { echo "$c"; return; }
    for c in /root/certs-5g /opt/panel5g/certs-5g; do [[ -f $c/ca/ca.key ]] && { echo "$c"; return; }; done
}
panell_dir() { docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' panel5g 2>/dev/null || true; }
proj_core() { jget $CFG_A project_dir; }
compose_core() {   # compose_core <args...>: el compose del core amb el .env del projecte
    local p f args=()
    p="$(proj_core)"
    while read -r f; do [[ -n "$f" ]] && args+=(-f "$p/$f"); done < <(python3 -c 'import json;[print(x) for x in json.load(open("/etc/agent5g/agent5g.json")).get("compose_files") or ["docker-compose.yml"]]')
    docker compose --project-directory "$p" --env-file "$p/.env" "${args[@]}" "$@"
}
ip_core_actual() {
    local i
    i="$(cat /etc/agent5g/core_ip 2>/dev/null || true)"
    [[ $i =~ $IP_RX ]] || i="$(env_get "$(proj_core)/.env" DOCKER_HOST_IP)"
    echo "$i"
}

mostra_cert() {   # mostra_cert <fitxer>
    [[ -f "$1" ]] || { info "$1: no hi és"; return; }
    local cn san fi
    cn="$(openssl x509 -in "$1" -noout -subject -nameopt multiline 2>/dev/null | sed -n 's/^ *commonName *= *//p')"
    san="$(openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ' || true)"
    fi="$(openssl x509 -in "$1" -noout -enddate 2>/dev/null | cut -d= -f2)"
    info "$1"
    info "   CN $cn${san:+ · $san} · caduca $fi"
}

veure_core() {
    local p certs pd
    p="$(proj_core)"; certs="$(certs_core)"; pd="$(panell_dir)"
    echo
    echo "--- Configuració de l'agent del core ---"
    info "versió:             $(versio_actual)"
    info "IP del core:        $(ip_core_actual)   (IPs d'aquest PC: $(ips_locals | tr '\n' ' '))"
    info "projecte:           $p"
    info ".env:               DOCKER_HOST_IP=$(env_get "$p/.env" DOCKER_HOST_IP)  UPF_ADVERTISE_IP=$(env_get "$p/.env" UPF_ADVERTISE_IP)"
    info "agent:              $(systemctl is-active agent5g 2>/dev/null || true) · panell al 9543, ràdios i UPF al $(jget $CFG_A enllac port)"
    info "panell web:         ${pd:-no instal·lat}"
    info "CA i certificats:   ${certs:-no la trobo}"
    mostra_cert /etc/agent5g/certs/agent-core.crt
    [[ -n "$pd" ]] && mostra_cert "$pd/certs/panel5g-web.crt"
}

renova_certs() {   # renova_certs <IP>: agent-core i web del panell, mateixa CA
    local ip="$1" certs pd
    certs="$(certs_core)"
    [[ -n "$certs" ]] || { avis "no trobo la CA (ca/ca.key): no es renoven els certificats"; return 1; }
    mkdir -p "$certs/bak-$TS"
    cp -a "$certs/agent-core" "$certs/panel" "$certs/bak-$TS/" 2>/dev/null || true
    bash /opt/agent5g/eines/gen_certs.sh --renova "$ip" "$certs" >/dev/null
    install -m 600 "$certs/agent-core/agent-core.crt" "$certs/agent-core/agent-core.key" /etc/agent5g/certs/
    info "certificat de l'agent del core renovat (anterior a $certs/bak-$TS)"
    pd="$(panell_dir)"
    if [[ -n "$pd" && -d "$pd/certs" ]]; then
        install -m 644 "$certs/panel/panel5g-web.crt" "$pd/certs/panel5g-web.crt"
        install -m 600 "$certs/panel/panel5g-web.key" "$pd/certs/panel5g-web.key"
        chown 10001:10001 "$pd/certs/panel5g-web.crt" "$pd/certs/panel5g-web.key"
        info "certificat web del panell renovat per a https://$ip:8443"
    fi
}

canvia_ip_core() {
    local vella nova def p pd certs smf f n
    vella="$(ip_core_actual)"; def="$(ip_ruta)"; p="$(proj_core)"
    echo
    echo "--- Canviar la IP del core ---"
    info "IP actual de la configuració: ${vella:-?}"
    info "IPs d'aquest PC:"; ips_locals | sed 's/^/        /'
    pregunta "IP nova del core" nova "$def"
    [[ $nova =~ $IP_RX ]] || { echo "    IP invàlida."; return; }
    if ! es_local "$nova"; then
        if [[ -f /etc/netplan/90-core5g.yaml ]] && grep -qF "$vella/" /etc/netplan/90-core5g.yaml; then
            avis "$nova encara no és d'aquest PC. La IP fixa la posa core5g.sh a /etc/netplan/90-core5g.yaml."
            avis "Si estàs connectat per SSH a $vella, perdràs la connexió i hauràs d'entrar per $nova."
            si_no "Canvio també la IP fixa del PC ($vella -> $nova) amb netplan?" || return
            cp -p /etc/netplan/90-core5g.yaml "/etc/netplan/90-core5g.yaml.bak-$TS"
            sed -i "s#\b${vella//./\\.}/#$nova/#" /etc/netplan/90-core5g.yaml
            CANVI_NETPLAN=1
        else
            echo "    $nova no és cap IP d'aquest PC. Canvia primer la xarxa (o el DHCP) i torna-hi."
            return
        fi
    fi
    [[ "$nova" != "$vella" ]] || { si_no "La IP ja és $nova. Ho torno a aplicar igualment (certificats i reinici)?" || return; }
    echo
    info "Es farà:"
    info " · .env: DOCKER_HOST_IP=$nova$( [[ "$(env_get "$p/.env" UPF_ADVERTISE_IP)" == "$vella" ]] && echo " i UPF_ADVERTISE_IP=$nova")"
    info " · smf.yaml: l'SMF s'anuncia amb $nova (si el UPF és separat)"
    info " · certificats de l'agent i del panell per a $nova (mateixa CA: ràdios i UPF continuen valent)"
    info " · codis d'emparellament amb la IP nova; /etc/agent5g/core_ip"
    info " · reinici del core sencer, del panell (https://$nova:8443) i de l'agent"
    si_no "Continuar?" || return

    (( ${CANVI_NETPLAN:-0} )) && { netplan apply; sleep 3; es_local "$nova" || error "netplan no ha posat $nova (còpia a /etc/netplan/90-core5g.yaml.bak-$TS)"; info "IP fixa del PC: $nova"; }

    # .env (còpia al format de l'agent, perquè surti a "Còpies i auditoria" del panell)
    install -d -m 700 /var/lib/agent5g/backups
    cp -p "$p/.env" "/var/lib/agent5g/backups/env-$TS.bak"
    sed -i "s/^DOCKER_HOST_IP=.*/DOCKER_HOST_IP=$nova/" "$p/.env"
    if [[ -n "$vella" && "$(env_get "$p/.env" UPF_ADVERTISE_IP)" == "$vella" ]]; then
        sed -i "s/^UPF_ADVERTISE_IP=.*/UPF_ADVERTISE_IP=$nova/" "$p/.env"
    fi
    info ".env actualitzat (còpia: env-$TS.bak)"
    smf="$p/smf/smf.yaml"
    if [[ -n "$vella" && -f "$smf" ]] && grep -qE "^\s*advertise:\s*${vella//./\\.}\b" "$smf"; then
        cp -p "$smf" "/var/lib/agent5g/backups/smf_smf_yaml-$TS.bak"
        sed -i -E "s/^(\s*advertise:\s*)${vella//./\\.}\b/\1$nova/" "$smf"
        info "smf.yaml: l'SMF s'anuncia amb $nova"
    fi
    printf '%s\n' "$nova" > /etc/agent5g/core_ip
    if [[ -f /etc/core5g.conf && -n "$vella" ]]; then
        cp -p /etc/core5g.conf "/etc/core5g.conf.bak-$TS"
        sed -i "s#\b${vella//./\\.}/#$nova/#g" /etc/core5g.conf
    fi
    renova_certs "$nova" || true

    # codis d'emparellament amb la IP nova (els certificats de cada ràdio/UPF no canvien)
    certs="$(certs_core)"
    if [[ -n "$certs" ]]; then
        for f in "$certs"/agent-radio-*/core; do
            [[ -f "$f" ]] || continue
            n="$(basename "$(dirname "$f")")"; n="${n#agent-radio-}"
            CORE5G_CORE_IP="$nova" /opt/agent5g/eines/emparella_radio.sh "$n" "$certs" >/dev/null 2>&1 \
                && info "codi de la ràdio $n regenerat ($certs/emparellament-$n.txt)"
        done
        for f in "$certs"/agent-upf-*/core; do
            [[ -f "$f" ]] || continue
            n="$(basename "$(dirname "$f")")"; n="${n#agent-upf-}"
            CORE5G_CORE_IP="$nova" /opt/agent5g/eines/emparella_upf.sh "$n" "$certs" >/dev/null 2>&1 \
                && info "codi del UPF $n regenerat ($certs/emparellament-upf-$n.txt)"
        done
    fi

    echo; info "reiniciant el core amb la IP nova (tots els contenidors)..."
    compose_core up -d --force-recreate 2>&1 | tail -n 3 | sed 's/^/      /' || avis "docker compose ha fallat: mira-ho amb docker ps -a"
    pd="$(panell_dir)"
    if [[ -n "$pd" && -f "$pd/docker-compose.yml" ]]; then
        (cd "$pd" && PANEL_IP="$nova" docker compose up -d --force-recreate) >/dev/null 2>&1 \
            && info "panell: https://$nova:8443" || avis "el panell no s'ha pogut tornar a aixecar (cd $pd && sudo PANEL_IP=$nova docker compose up -d)"
    fi
    systemctl restart agent5g && info "agent del core reiniciat"
    echo
    echo "==> Fet. IP del core: $nova"
    echo "    Ràdios i PCs amb UPF continuen trucant a ${vella:-la IP vella}: a cada un, executa"
    echo "      sudo agent5g   ->  Canviar la IP del core  ->  $nova"
    echo "    (no cal tornar a emparellar: el certificat continua valent)"
}

# --- ràdio / UPF ---------------------------------------------------------------------------
veure_client() {   # veure_client <json> <nom>
    echo
    echo "--- $2 ---"
    info "versió:             $(versio_actual)"
    info "truca al core:      $(jget "$1" core):$(jget "$1" core_port)"
    info "projecte:           $(jget "$1" project_dir)"
    mostra_cert "$(jget "$1" cert)"
}

canvia_core_client() {   # canvia_core_client <json> <servei> <nom>
    local j="$1" svc="$2" nom="$3" vella nova p
    vella="$(jget "$j" core)"; p="$(jget "$j" project_dir)"
    echo
    echo "--- $nom: canviar la IP del core ---"
    pregunta "IP nova del core" nova "$vella"
    [[ $nova =~ $IP_RX ]] || { echo "    IP invàlida."; return; }
    si_no "Canvio $vella -> $nova i reinicio el que en depèn?" || return
    jset "$j" core "$nova"
    info "$j: \"core\": \"$nova\" (còpia .bak-$TS)"
    if [[ "$svc" == agent5g && -f "$p/.env" ]] && grep -q '^CORE_IP=' "$p/.env"; then
        cp -p "$p/.env" "$p/.env.bak-$TS"
        sed -i "s/^CORE_IP=.*/CORE_IP=$nova/" "$p/.env"
        info "gNB: CORE_IP=$nova al .env; recreo el gNB"
        local args=() f
        while read -r f; do [[ -n "$f" ]] && args+=(-f "$p/$f"); done < <(python3 -c 'import json,sys;[print(x) for x in json.load(open(sys.argv[1])).get("compose_files") or ["docker-compose.yml"]]' "$j")
        local cp_; cp_="$(jget "$j" compose_project)"
        docker compose --project-directory "$p" --env-file "$p/.env" ${cp_:+-p "$cp_"} "${args[@]}" up -d --force-recreate >/dev/null 2>&1 \
            || avis "no s'ha pogut recrear el gNB: mira-ho amb docker ps -a"
    fi
    systemctl restart "$svc"
    sleep 4
    if journalctl -u "$svc" --since "-10s" --no-pager 2>/dev/null | grep -q "connectat al core"; then
        info "connectat al core $nova"
    else
        avis "encara no ha connectat amb $nova (ho reintenta sol): journalctl -u $svc -n 20"
    fi
    [[ "$svc" == agent5g-upf ]] && info "el core li tornarà a passar la configuració (SMF $nova) quan connecti"
}

# --- actualitzar des de GitHub (tots els rols) ---------------------------------------------
baixa_codi() {   # baixa_codi <carpeta>: deixa el repo a <carpeta>/5gpanel i imprimeix la versió
    local d="$1"
    if command -v git >/dev/null && git clone -q --depth 1 --branch "$BRANCA" "$REPO" "$d/5gpanel" 2>/dev/null; then
        git -C "$d/5gpanel" log -1 --format="%h · %cd ($BRANCA)" --date=format:'%Y-%m-%d %H:%M'
    elif curl -fsSL "$REPO/archive/refs/heads/$BRANCA.tar.gz" 2>/dev/null | tar xz -C "$d" 2>/dev/null; then
        mv "$d"/*-"${BRANCA//\//-}" "$d/5gpanel" 2>/dev/null || mv "$d"/*/ "$d/5gpanel"
        echo "$BRANCA, $(date +%Y-%m-%d) (baixada sense git)"
    else
        return 1
    fi
}

actualitza_agent() {   # agent de ràdio i/o UPF: agent5g.py + menú, i reinici dels serveis
    local S="$1" bk serveis=() s ok=1
    bk=/var/lib/agent5g/bak-$TS; [[ -d /var/lib/agent5g ]] || bk=/var/lib/agent5g-upf/bak-$TS
    install -d -m 700 "$bk"
    cp -a /opt/agent5g/agent5g.py "$bk/" 2>/dev/null || true
    cp -a /opt/agent5g/agent5g_menu.sh "$bk/" 2>/dev/null || true
    install -m 755 "$S/agent/agent5g.py" /opt/agent5g/agent5g.py
    install -m 755 "$S/scripts/agent5g_menu.sh" /opt/agent5g/.agent5g_menu.nou
    mv -f /opt/agent5g/.agent5g_menu.nou /opt/agent5g/agent5g_menu.sh
    ln -sf /opt/agent5g/agent5g_menu.sh /usr/local/sbin/agent5g
    info "agent5g.py i el menú copiats (còpia de l'anterior a $bk)"
    [[ "$ROL" == radio ]] && serveis+=(agent5g)
    (( TE_UPF )) && serveis+=(agent5g-upf)
    for s in "${serveis[@]}"; do systemctl restart "$s" || true; done
    sleep 3
    for s in "${serveis[@]}"; do
        if systemctl is-active -q "$s"; then info "$s: en marxa"; else avis "$s no ha arrencat"; ok=0; fi
    done
    if (( ! ok )); then
        avis "torno a la versió anterior"
        cp -a "$bk/agent5g.py" /opt/agent5g/agent5g.py
        for s in "${serveis[@]}"; do systemctl restart "$s" || true; done
        return 1
    fi
}

actualitza() {
    local tmp nova S
    echo
    echo "--- Actualitzar des de GitHub ---"
    info "versió instal·lada: $(versio_actual)"
    info "font:               $REPO (branca $BRANCA)"
    case "$ROL" in
        core)  info "s'actualitza: agent del core, eines d'emparellament, menú i panell web (si és en aquest PC)" ;;
        radio) info "s'actualitza: agent de la ràdio i menú (el gNB no es toca)" ;;
    esac
    (( TE_UPF )) && info "s'actualitza: agent del UPF (el contenidor upf no es toca)"
    info "no es toquen: el core 5G, els certificats, la configuració ni els abonats"
    si_no "Descarrego l'última versió i la instal·lo?" || return 0
    tmp="$(mktemp -d /tmp/agent5g-act.XXXXXX)"
    if ! nova="$(baixa_codi "$tmp")"; then
        avis "no he pogut baixar $REPO (branca $BRANCA): mira la connexió a internet"
        [[ "$tmp" == /tmp/agent5g-act.* ]] && rm -rf -- "$tmp"
        return 0
    fi
    S="$tmp/5gpanel"
    if [[ ! -f "$S/agent/agent5g.py" || ! -f "$S/scripts/agent5g_menu.sh" ]] \
       || ! python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$S/agent/agent5g.py" \
       || ! bash -n "$S/scripts/agent5g_menu.sh"; then
        avis "el codi baixat no és complet o té errors: no instal·lo res"
        [[ "$tmp" == /tmp/agent5g-act.* ]] && rm -rf -- "$tmp"
        return 0
    fi
    info "versió nova: $nova"
    echo
    local ok=1
    if [[ "$ROL" == core ]]; then
        if ! PANEL_IP="$(ip_core_actual)" bash "$S/scripts/actualitzar.sh" 2>&1 | sed 's/^/      /'; then
            ok=0; avis "actualitzar.sh ha fallat: llegeix els missatges de dalt (còpies a /var/lib/agent5g/bak-*)"
        fi
        if (( ok && TE_UPF )); then systemctl restart agent5g-upf || true; fi
    else
        actualitza_agent "$S" || ok=0
    fi
    [[ "$tmp" == /tmp/agent5g-act.* ]] && rm -rf -- "$tmp"
    (( ok )) || return 0
    printf '%s\n' "$nova" > "$VERSIO_F"
    echo
    echo "==> Actualitzat a $nova"
    echo "    Torna a obrir el menú (sudo agent5g) per fer servir la versió nova."
    exit 0
}

# --- menú ----------------------------------------------------------------------------------
while true; do
    echo
    echo "=================================================================="
    echo " agent5g · configuració de l'agent del panel5g"
    echo "=================================================================="
    opcions=()
    case "$ROL" in
        core)  opcions+=("veure_core|Veure la configuració del core"
                         "canvia_ip_core|Canviar la IP del core (i regenerar els certificats)"
                         "renova|Renovar els certificats (mateixa IP)") ;;
        radio) opcions+=("veure_radio|Veure la configuració de la ràdio"
                         "core_radio|Canviar la IP del core al qual truca la ràdio") ;;
    esac
    if (( TE_UPF )); then
        opcions+=("veure_upf|Veure la configuració del UPF"
                  "core_upf|Canviar la IP del core al qual truca el UPF")
    fi
    opcions+=("actualitza|Actualitzar des de GitHub (última versió)")
    i=1; for o in "${opcions[@]}"; do echo " $i) ${o#*|}"; i=$((i + 1)); done
    echo " $i) Sortir"
    read -r -p "    Opció: " op || { echo; exit 0; }   # Ctrl+D o sense terminal: surt
    [[ "$op" =~ ^[0-9]+$ ]] || continue
    (( op == i )) && exit 0
    (( op >= 1 && op < i )) || continue
    case "${opcions[$((op - 1))]%%|*}" in
        veure_core)     veure_core ;;
        canvia_ip_core) canvia_ip_core ;;
        renova)         si_no "Renovo el certificat de l'agent i del web del panell per a $(ip_core_actual)?" \
                            && renova_certs "$(ip_core_actual)" \
                            && { pd="$(panell_dir)"; [[ -z "$pd" ]] || (cd "$pd" && PANEL_IP="$(ip_core_actual)" docker compose up -d --force-recreate >/dev/null 2>&1); systemctl restart agent5g; info "fet (agent i panell reiniciats)"; } ;;
        veure_radio)    veure_client $CFG_A "Agent de la ràdio" ;;
        core_radio)     canvia_core_client $CFG_A agent5g "Ràdio" ;;
        veure_upf)      veure_client $CFG_U "Agent del UPF" ;;
        core_upf)       canvia_core_client $CFG_U agent5g-upf "UPF" ;;
        actualitza)     actualitza ;;
    esac
done
