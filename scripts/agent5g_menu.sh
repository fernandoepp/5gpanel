#!/usr/bin/env bash
# ============================================================================
# agent5g - menú de terminal para configurar el agente del panel5g de este PC.
#
#   sudo agent5g
#
# En el core:
#   1) Ver la configuración (IP, certificados, carpetas)
#   2) Cambiar la IP del core: .env, smf.yaml, códigos de emparejamiento, certificados
#      (misma CA), panel y reinicio del core con la IP nueva
#   3) Renovar los certificados (misma IP)
#   4) Añadir una radio o un UPF: pide el nombre y muestra el código de emparejamiento que se
#      pega en el instalador de ese PC (es lo mismo que sudo emparella-radio/-upf <nombre>)
# En la radio o en el PC del UPF:
#   1) Ver la configuración
#   2) Cambiar la IP del core al que llama (y reiniciar lo que depende de ella)
#   3) Renovar el certificado: pegas el código que da el core (sudo emparella-radio <nombre> o
#      sudo emparella-upf <nombre>); lleva la CA, el certificado, la clave y la IP del core.
# En todos: Actualizar desde GitHub (descarga la última versión y la instala; con copia).
#   Origen: AGENT5G_REPO (por defecto https://github.com/fernandoepp/5gpanel) y
#   AGENT5G_BRANCA (por defecto main), p. ej.  sudo AGENT5G_BRANCA=pruebas agent5g
#
# La IP del core NO se cambia desde el navegador (campo de solo lectura): se hace aquí,
# porque afecta a los certificados, al panel y a todo el core a la vez.
# ============================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Hay que ser root: sudo agent5g"; exit 1; }
IP_RX='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
TS=$(date +%Y%m%d-%H%M%S)
info() { echo "    $*"; }
avis() { echo "    AVISO: $*"; }
error() { echo "ERROR: $*" >&2; exit 1; }
pregunta() {   # pregunta <texto> <variable> [por defecto]
    local r; read -r -p "    $1${3:+ [$3]}: " r || true
    printf -v "$2" '%s' "${r:-${3:-}}"
}
si_no() { local r; read -r -p "    $1 [s/N]: " r || true; [[ "$r" =~ ^[sSyY]$ ]]; }
jget() {   # jget <fichero> <clave> [<subclave>]
    python3 - "$@" <<'PY' 2>/dev/null || true
import json, sys
c = json.load(open(sys.argv[1]))
for k in sys.argv[2:]:
    c = c.get(k) if isinstance(c, dict) else None
print('' if c is None else (json.dumps(c) if isinstance(c, (list, dict)) else c))
PY
}
jset() {   # jset <fichero> <clave> <valor>  (con copia)
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
versio_actual() { cat "$VERSIO_F" 2>/dev/null || echo "desconocida (instalada antes de que existiera esta opción)"; }

CFG_A=/etc/agent5g/agent5g.json
CFG_U=/etc/agent5g-upf/agent5g.json
ROL=""; [[ -f $CFG_A ]] && ROL="$(jget $CFG_A role)"
TE_UPF=0; [[ -f $CFG_U ]] && TE_UPF=1
[[ -n "$ROL" || $TE_UPF == 1 ]] || error "en este PC no hay ningún agente del panel5g (/etc/agent5g ni /etc/agent5g-upf)"

# --- core ------------------------------------------------------------------------------
certs_core() {   # carpeta con la CA (donde la usan emparella-radio/-upf)
    local c
    c="$(sed -n 's#^CERTS=\${2:-\(.*\)}$#\1#p' /opt/agent5g/eines/emparella_radio.sh 2>/dev/null | head -1 || true)"
    [[ -n "$c" && -f "$c/ca/ca.key" ]] && { echo "$c"; return; }
    for c in /root/certs-5g /opt/panel5g/certs-5g; do [[ -f $c/ca/ca.key ]] && { echo "$c"; return; }; done
}
panell_dir() { docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' panel5g 2>/dev/null || true; }
proj_core() { jget $CFG_A project_dir; }
compose_core() {   # compose_core <args...>: el compose del core con el .env del proyecto
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

mostra_cert() {   # mostra_cert <fichero>
    [[ -f "$1" ]] || { info "$1: no existe"; return; }
    local cn san fi
    cn="$(openssl x509 -in "$1" -noout -subject -nameopt multiline 2>/dev/null | sed -n 's/^ *commonName *= *//p' || true)"
    san="$(openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ' || true)"
    fi="$(openssl x509 -in "$1" -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
    info "$1"
    [[ -n "$cn" ]] || { info "   (no es un certificado válido)"; return 0; }
    info "   CN $cn${san:+ · $san} · caduca el $fi"
}

veure_core() {
    local p certs pd
    p="$(proj_core)"; certs="$(certs_core)"; pd="$(panell_dir)"
    echo
    echo "--- Configuración del agente del core ---"
    info "versión:            $(versio_actual)"
    info "IP del core:        $(ip_core_actual)   (IPs de este PC: $(ips_locals | tr '\n' ' '))"
    info "proyecto:           $p"
    info ".env:               DOCKER_HOST_IP=$(env_get "$p/.env" DOCKER_HOST_IP)  UPF_ADVERTISE_IP=$(env_get "$p/.env" UPF_ADVERTISE_IP)"
    info "agente:             $(systemctl is-active agent5g 2>/dev/null || true) · panel en el 9543, radios y UPF en el $(jget $CFG_A enllac port)"
    info "panel web:          ${pd:-no instalado}"
    info "CA y certificados:  ${certs:-no la encuentro}"
    info "radios emparejadas: $(equips radio | tr '\n' ' ')"
    info "UPF emparejados:    $(equips upf | tr '\n' ' ')"
    mostra_cert /etc/agent5g/certs/agent-core.crt
    [[ -n "$pd" ]] && mostra_cert "$pd/certs/panel5g-web.crt"
}

renova_certs() {   # renova_certs <IP>: agent-core y web del panel, misma CA
    local ip="$1" certs pd
    certs="$(certs_core)"
    [[ -n "$certs" ]] || { avis "no encuentro la CA (ca/ca.key): no se renuevan los certificados"; return 1; }
    mkdir -p "$certs/bak-$TS"
    cp -a "$certs/agent-core" "$certs/panel" "$certs/bak-$TS/" 2>/dev/null || true
    bash /opt/agent5g/eines/gen_certs.sh --renova "$ip" "$certs" >/dev/null
    install -m 600 "$certs/agent-core/agent-core.crt" "$certs/agent-core/agent-core.key" /etc/agent5g/certs/
    info "certificado del agente del core renovado (el anterior en $certs/bak-$TS)"
    pd="$(panell_dir)"
    if [[ -n "$pd" && -d "$pd/certs" ]]; then
        install -m 644 "$certs/panel/panel5g-web.crt" "$pd/certs/panel5g-web.crt"
        install -m 600 "$certs/panel/panel5g-web.key" "$pd/certs/panel5g-web.key"
        chown 10001:10001 "$pd/certs/panel5g-web.crt" "$pd/certs/panel5g-web.key"
        info "certificado web del panel renovado para https://$ip:8443"
    fi
}

canvia_ip_core() {
    local vella nova def p pd certs smf f n
    vella="$(ip_core_actual)"; def="$(ip_ruta)"; p="$(proj_core)"
    echo
    echo "--- Cambiar la IP del core ---"
    info "IP actual de la configuración: ${vella:-?}"
    info "IPs de este PC:"; ips_locals | sed 's/^/        /'
    pregunta "IP nueva del core" nova "$def"
    [[ $nova =~ $IP_RX ]] || { echo "    IP no válida."; return; }
    if ! es_local "$nova"; then
        if [[ -f /etc/netplan/90-core5g.yaml ]] && grep -qF "$vella/" /etc/netplan/90-core5g.yaml; then
            avis "$nova todavía no es de este PC. La IP fija la pone core5g.sh en /etc/netplan/90-core5g.yaml."
            avis "Si estás conectado por SSH a $vella, perderás la conexión y tendrás que entrar por $nova."
            si_no "¿Cambio también la IP fija del PC ($vella -> $nova) con netplan?" || return
            cp -p /etc/netplan/90-core5g.yaml "/etc/netplan/90-core5g.yaml.bak-$TS"
            sed -i "s#\b${vella//./\\.}/#$nova/#" /etc/netplan/90-core5g.yaml
            CANVI_NETPLAN=1
        else
            echo "    $nova no es ninguna IP de este PC. Cambia primero la red (o el DHCP) y vuelve."
            return
        fi
    fi
    [[ "$nova" != "$vella" ]] || { si_no "La IP ya es $nova. ¿Lo vuelvo a aplicar igualmente (certificados y reinicio)?" || return; }
    echo
    info "Se hará:"
    info " · .env: DOCKER_HOST_IP=$nova$( [[ "$(env_get "$p/.env" UPF_ADVERTISE_IP)" == "$vella" ]] && echo " y UPF_ADVERTISE_IP=$nova")"
    info " · smf.yaml: el SMF se anuncia con $nova (si el UPF está separado)"
    info " · certificados del agente y del panel para $nova (misma CA: radios y UPF siguen valiendo)"
    info " · códigos de emparejamiento con la IP nueva; /etc/agent5g/core_ip"
    info " · reinicio del core entero, del panel (https://$nova:8443) y del agente"
    si_no "¿Continuar?" || return

    (( ${CANVI_NETPLAN:-0} )) && { netplan apply; sleep 3; es_local "$nova" || error "netplan no ha puesto $nova (copia en /etc/netplan/90-core5g.yaml.bak-$TS)"; info "IP fija del PC: $nova"; }

    # .env (copia en el formato del agente, para que salga en "Copias y auditoría" del panel)
    install -d -m 700 /var/lib/agent5g/backups
    cp -p "$p/.env" "/var/lib/agent5g/backups/env-$TS.bak"
    sed -i "s/^DOCKER_HOST_IP=.*/DOCKER_HOST_IP=$nova/" "$p/.env"
    if [[ -n "$vella" && "$(env_get "$p/.env" UPF_ADVERTISE_IP)" == "$vella" ]]; then
        sed -i "s/^UPF_ADVERTISE_IP=.*/UPF_ADVERTISE_IP=$nova/" "$p/.env"
    fi
    info ".env actualizado (copia: env-$TS.bak)"
    smf="$p/smf/smf.yaml"
    if [[ -n "$vella" && -f "$smf" ]] && grep -qE "^\s*advertise:\s*${vella//./\\.}\b" "$smf"; then
        cp -p "$smf" "/var/lib/agent5g/backups/smf_smf_yaml-$TS.bak"
        sed -i -E "s/^(\s*advertise:\s*)${vella//./\\.}\b/\1$nova/" "$smf"
        info "smf.yaml: el SMF se anuncia con $nova"
    fi
    printf '%s\n' "$nova" > /etc/agent5g/core_ip
    if [[ -f /etc/core5g.conf && -n "$vella" ]]; then
        cp -p /etc/core5g.conf "/etc/core5g.conf.bak-$TS"
        sed -i "s#\b${vella//./\\.}/#$nova/#g" /etc/core5g.conf
    fi
    renova_certs "$nova" || true

    # códigos de emparejamiento con la IP nueva (los certificados de cada radio/UPF no cambian)
    certs="$(certs_core)"
    if [[ -n "$certs" ]]; then
        for f in "$certs"/agent-radio-*/core; do
            [[ -f "$f" ]] || continue
            n="$(basename "$(dirname "$f")")"; n="${n#agent-radio-}"
            CORE5G_CORE_IP="$nova" /opt/agent5g/eines/emparella_radio.sh "$n" "$certs" >/dev/null 2>&1 \
                && info "código de la radio $n regenerado ($certs/emparellament-$n.txt)"
        done
        for f in "$certs"/agent-upf-*/core; do
            [[ -f "$f" ]] || continue
            n="$(basename "$(dirname "$f")")"; n="${n#agent-upf-}"
            CORE5G_CORE_IP="$nova" /opt/agent5g/eines/emparella_upf.sh "$n" "$certs" >/dev/null 2>&1 \
                && info "código del UPF $n regenerado ($certs/emparellament-upf-$n.txt)"
        done
    fi

    echo; info "reiniciando el core con la IP nueva (todos los contenedores)..."
    compose_core up -d --force-recreate 2>&1 | tail -n 3 | sed 's/^/      /' || avis "docker compose ha fallado: míralo con docker ps -a"
    pd="$(panell_dir)"
    if [[ -n "$pd" && -f "$pd/docker-compose.yml" ]]; then
        (cd "$pd" && PANEL_IP="$nova" docker compose up -d --force-recreate) >/dev/null 2>&1 \
            && info "panel: https://$nova:8443" || avis "el panel no se ha podido volver a levantar (cd $pd && sudo PANEL_IP=$nova docker compose up -d)"
    fi
    systemctl restart agent5g && info "agente del core reiniciado"
    echo
    echo "==> Hecho. IP del core: $nova"
    echo "    Las radios y los PCs con UPF siguen llamando a ${vella:-la IP antigua}: en cada uno, ejecuta"
    echo "      sudo agent5g   ->  Cambiar la IP del core  ->  $nova"
    echo "    (no hace falta volver a emparejar: el certificado sigue valiendo)"
}

equips() {   # equips <radio|upf>: nombres ya emparejados (carpetas agent-<tipo>-<nombre> de la CA)
    local certs d
    certs="$(certs_core)"; [[ -n "$certs" ]] || return 0
    for d in "$certs"/agent-"$1"-*/; do
        [[ -f "$d/agent-$1.crt" ]] && { d="${d%/}"; echo "${d##*/agent-$1-}"; }
    done
    return 0
}

# Añade una radio o un UPF: emite su certificado (misma CA) y muestra el código de
# emparejamiento con la IP del core. El equipo llama solo al core: no hace falta su IP.
afegeix_equip() {   # afegeix_equip <radio|upf>
    local tipus="$1" certs eina nom def n i=1 args=() lst
    certs="$(certs_core)"; eina="/opt/agent5g/eines/emparella_$tipus.sh"
    [[ -n "$certs" ]] || { avis "no encuentro la CA (ca/ca.key): no se pueden emitir certificados en este PC"; return 0; }
    [[ -x "$eina" ]] || { avis "falta $eina: actualiza el agente (opción Actualizar desde GitHub)"; return 0; }
    echo
    if [[ $tipus == radio ]]; then echo "--- Añadir una radio ---"; else echo "--- Añadir un UPF ---"; fi
    mapfile -t lst < <(equips "$tipus")
    info "ya emparejados: ${lst[*]:-ninguno}"
    while printf '%s\n' "${lst[@]}" | grep -qx "$tipus$i"; do i=$((i + 1)); done
    def="$tipus$i"
    pregunta "Nombre (letras, cifras, . _ -; así sale en el panel)" nom "$def"
    [[ $nom =~ ^[A-Za-z0-9_.-]{1,52}$ ]] || { echo "    Nombre no válido."; return 0; }
    if printf '%s\n' "${lst[@]}" | grep -qx -- "$nom"; then
        info "\"$nom\" ya existe: si no dices que sí, se vuelve a mostrar su código (mismo certificado, IP del core al día)"
        si_no "¿Emito un certificado nuevo para \"$nom\" (el antiguo sigue valiendo hasta que caduque)?" && args+=(--nou)
    fi
    info "IP del core que llevará el código: $(ip_core_actual)"
    "$eina" "${args[@]}" "$nom" "$certs" || { avis "no se ha podido generar el código"; return 0; }
    echo
    if [[ $tipus == radio ]]; then
        info "En la radio: instala con core5g.sh (rol radio) y pega el código; si ya tiene agente:"
        info "sudo agent5g > Renovar el certificado de la radio."
    else
        info "En el PC del UPF: instala con core5g.sh (rol UPF) y pega el código; si ya tiene agente:"
        info "sudo agent5g > Renovar el certificado del UPF. En modo automático el core lo usará al conectar."
    fi
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active' && ! ufw status 2>/dev/null | grep -q '^9544/tcp'; then
        avis "ufw está activo y no deja pasar el 9544/tcp: sudo ufw allow 9544/tcp"
    fi
    return 0
}

# --- radio / UPF ---------------------------------------------------------------------------
veure_client() {   # veure_client <json> <nombre>
    echo
    echo "--- $2 ---"
    info "versión:            $(versio_actual)"
    info "llama al core:      $(jget "$1" core):$(jget "$1" core_port)"
    info "proyecto:           $(jget "$1" project_dir)"
    mostra_cert "$(jget "$1" cert)"
}

canvia_core_client() {   # canvia_core_client <json> <servicio> <nombre>
    local j="$1" svc="$2" nom="$3" vella nova p
    vella="$(jget "$j" core)"; p="$(jget "$j" project_dir)"
    echo
    echo "--- $nom: cambiar la IP del core ---"
    pregunta "IP nueva del core" nova "$vella"
    [[ $nova =~ $IP_RX ]] || { echo "    IP no válida."; return; }
    si_no "¿Cambio $vella -> $nova y reinicio lo que depende de ella?" || return
    jset "$j" core "$nova"
    info "$j: \"core\": \"$nova\" (copia .bak-$TS)"
    [[ "$svc" == agent5g ]] && ip_core_gnb "$j" "$nova"
    reinicia_client "$svc" "$nova"
}

ip_core_gnb() {   # ip_core_gnb <json> <IP>: CORE_IP del .env del gNB (ocudu) y recrea el gNB
    local j="$1" nova="$2" p args=() f cp_
    p="$(jget "$j" project_dir)"
    [[ -f "$p/.env" ]] && grep -q '^CORE_IP=' "$p/.env" || return 0
    [[ "$(env_get "$p/.env" CORE_IP)" != "$nova" ]] || return 0
    cp -p "$p/.env" "$p/.env.bak-$TS"
    sed -i "s/^CORE_IP=.*/CORE_IP=$nova/" "$p/.env"
    info "gNB: CORE_IP=$nova en el .env; recreo el gNB"
    while read -r f; do [[ -n "$f" ]] && args+=(-f "$p/$f"); done < <(python3 -c 'import json,sys;[print(x) for x in json.load(open(sys.argv[1])).get("compose_files") or ["docker-compose.yml"]]' "$j")
    cp_="$(jget "$j" compose_project)"
    docker compose --project-directory "$p" --env-file "$p/.env" ${cp_:+-p "$cp_"} "${args[@]}" up -d --force-recreate >/dev/null 2>&1 \
        || avis "no se ha podido recrear el gNB: míralo con docker ps -a"
}

reinicia_client() {   # reinicia_client <servicio> <IP core>
    local svc="$1" nova="$2"
    systemctl restart "$svc"
    sleep 4
    if journalctl -u "$svc" --since "-10s" --no-pager 2>/dev/null | grep -q "connectat al core"; then
        info "conectado al core $nova"
    else
        avis "todavía no ha conectado con $nova (lo reintenta solo): journalctl -u $svc -n 20"
    fi
    [[ "$svc" == agent5g-upf ]] && info "el core le volverá a pasar la configuración (SMF $nova) cuando conecte"
    return 0
}

# Renueva el certificado de una radio o de un UPF con un código de emparejamiento nuevo del core
# (en el core: sudo emparella-radio <nombre> o sudo emparella-upf <nombre>). El código lleva la CA, el
# certificado y la clave de este equipo y la IP del core: se instalan y el agente vuelve a llamar.
renova_cert_client() {   # renova_cert_client <json> <servicio> <radio|upf>
    local j="$1" svc="$2" tipus="$3" dir capca fi_ codi="" l nom t core ip port vell nou
    dir="$(dirname "$j")/certs"
    if [[ $tipus == radio ]]; then capca="EMPARELLAMENT"; fi_="-----END 5GPANEL EMPARELLAMENT-----"
    else capca="UPF"; fi_="-----END 5GPANEL UPF-----"; fi
    echo
    echo "--- Renovar el certificado ($tipus) ---"
    mostra_cert "$(jget "$j" cert)"
    info "En el core, ejecuta:  sudo emparella-$tipus --nou <nombre>   (el mismo nombre para conservarlo en el panel;"
    info "                      --nou emite uno nuevo; sin --nou da el mismo certificado con la IP del core al día)"
    info "y pega aquí el código entero (de la línea BEGIN a la línea END):"
    while IFS= read -r l; do
        codi+="$l"$'\n'
        [[ "$l" == "$fi_" ]] && break
    done
    nom="$(sed -n "s/^-----BEGIN 5GPANEL $capca \([A-Za-z0-9_.-]*\)-----\$/\1/p" <<<"$codi" | head -1)"
    [[ -n "$nom" ]] || { avis "no es un código de $tipus (tiene que empezar por -----BEGIN 5GPANEL $capca <nombre>-----)"; return 0; }
    t="$(mktemp -d /tmp/agent5g-cert.XXXXXX)"
    if ! sed -n '/^-----BEGIN/,/^-----END/{/^-----/d;p}' <<<"$codi" | base64 -d 2>/dev/null | tar xzf - -C "$t" 2>/dev/null; then
        avis "el código está dañado (cópialo entero)"; [[ "$t" == /tmp/agent5g-cert.* ]] && rm -rf -- "$t"; return 0
    fi
    for f in ca.crt "agent-$tipus.crt" "agent-$tipus.key" core; do
        [[ -s "$t/$f" ]] || { avis "al código le falta $f"; [[ "$t" == /tmp/agent5g-cert.* ]] && rm -rf -- "$t"; return 0; }
    done
    if ! openssl verify -CAfile "$t/ca.crt" -purpose sslclient "$t/agent-$tipus.crt" >/dev/null 2>&1; then
        avis "el certificado del código no es válido para su CA: vuelve a generarlo en el core"
        [[ "$t" == /tmp/agent5g-cert.* ]] && rm -rf -- "$t"; return 0
    fi
    core="$(tr -d '[:space:]' < "$t/core")"
    [[ $core =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]] || { avis "IP del core del código no válida: $core"; [[ "$t" == /tmp/agent5g-cert.* ]] && rm -rf -- "$t"; return 0; }
    ip="${core%:*}"; port="${core##*:}"
    vell="$(openssl x509 -in "$(jget "$j" cert)" -noout -subject -nameopt multiline 2>/dev/null | sed -n 's/^ *commonName *= *//p' || true)"
    nou="$(openssl x509 -in "$t/agent-$tipus.crt" -noout -subject -nameopt multiline 2>/dev/null | sed -n 's/^ *commonName *= *//p')"
    info "código de \"$nom\" ($nou), core $core, caduca el $(openssl x509 -in "$t/agent-$tipus.crt" -noout -enddate | cut -d= -f2)"
    [[ -z "$vell" || "$vell" == "$nou" ]] || avis "el nombre cambia ($vell -> $nou): en el panel saldrá como un equipo nuevo"
    si_no "¿Instalo este certificado y reinicio el agente?" || { [[ "$t" == /tmp/agent5g-cert.* ]] && rm -rf -- "$t"; return 0; }
    install -d -m 700 "$dir/bak-$TS"
    cp -a "$dir"/*.crt "$dir"/*.key "$dir/bak-$TS/" 2>/dev/null || true
    install -m 600 "$t/ca.crt" "$t/agent-$tipus.crt" "$t/agent-$tipus.key" "$dir/"
    [[ "$t" == /tmp/agent5g-cert.* ]] && rm -rf -- "$t"
    info "certificado instalado en $dir (el anterior en $dir/bak-$TS)"
    cp -p "$j" "$j.bak-$TS"
    J="$j" D="$dir" TIPUS="$tipus" NOM="$nom" IP="$ip" PORT="$port" python3 - <<'PY'
import json, os
e = os.environ
f = e['J']
c = json.load(open(f))
c.update(core=e['IP'], core_port=int(e['PORT']), listen=None,
         cert=f"{e['D']}/agent-{e['TIPUS']}.crt", key=f"{e['D']}/agent-{e['TIPUS']}.key", ca=f"{e['D']}/ca.crt",
         name=('Radio ' if e['TIPUS'] == 'radio' else 'UPF ') + e['NOM'])
open(f + '.nou', 'w').write(json.dumps(c, indent=2, ensure_ascii=False))
os.chmod(f + '.nou', 0o600)
os.replace(f + '.nou', f)
PY
    info "$j: core $ip:$port (copia .bak-$TS)"
    [[ $tipus == radio ]] && ip_core_gnb "$j" "$ip"
    reinicia_client "$svc" "$ip"
}

# --- actualizar desde GitHub (todos los roles) ---------------------------------------------
baixa_codi() {   # baixa_codi <carpeta>: deja el repo en <carpeta>/5gpanel e imprime la versión
    local d="$1"
    if command -v git >/dev/null && git clone -q --depth 1 --branch "$BRANCA" "$REPO" "$d/5gpanel" 2>/dev/null; then
        git -C "$d/5gpanel" log -1 --format="%h · %cd ($BRANCA)" --date=format:'%Y-%m-%d %H:%M'
    elif curl -fsSL "$REPO/archive/refs/heads/$BRANCA.tar.gz" 2>/dev/null | tar xz -C "$d" 2>/dev/null; then
        mv "$d"/*-"${BRANCA//\//-}" "$d/5gpanel" 2>/dev/null || mv "$d"/*/ "$d/5gpanel"
        echo "$BRANCA, $(date +%Y-%m-%d) (descargada sin git)"
    else
        return 1
    fi
}

actualitza_agent() {   # agente de radio y/o UPF: agent5g.py + menú, y reinicio de los servicios
    local S="$1" bk serveis=() s ok=1
    bk=/var/lib/agent5g/bak-$TS; [[ -d /var/lib/agent5g ]] || bk=/var/lib/agent5g-upf/bak-$TS
    install -d -m 700 "$bk"
    cp -a /opt/agent5g/agent5g.py "$bk/" 2>/dev/null || true
    cp -a /opt/agent5g/agent5g_menu.sh "$bk/" 2>/dev/null || true
    install -m 755 "$S/agent/agent5g.py" /opt/agent5g/agent5g.py
    install -m 755 "$S/scripts/agent5g_menu.sh" /opt/agent5g/.agent5g_menu.nou
    mv -f /opt/agent5g/.agent5g_menu.nou /opt/agent5g/agent5g_menu.sh
    ln -sf /opt/agent5g/agent5g_menu.sh /usr/local/sbin/agent5g
    info "agent5g.py y el menú copiados (copia del anterior en $bk)"
    [[ "$ROL" == radio ]] && serveis+=(agent5g)
    (( TE_UPF )) && serveis+=(agent5g-upf)
    for s in "${serveis[@]}"; do systemctl restart "$s" || true; done
    sleep 3
    for s in "${serveis[@]}"; do
        if systemctl is-active -q "$s"; then info "$s: en marcha"; else avis "$s no ha arrancado"; ok=0; fi
    done
    if (( ! ok )); then
        avis "vuelvo a la versión anterior"
        cp -a "$bk/agent5g.py" /opt/agent5g/agent5g.py
        for s in "${serveis[@]}"; do systemctl restart "$s" || true; done
        return 1
    fi
}

actualitza() {
    local tmp nova S
    echo
    echo "--- Actualizar desde GitHub ---"
    info "versión instalada: $(versio_actual)"
    info "origen:            $REPO (rama $BRANCA)"
    case "$ROL" in
        core)  info "se actualiza: agente del core, herramientas de emparejamiento, menú y panel web (si está en este PC)" ;;
        radio) info "se actualiza: agente de la radio y menú (el gNB no se toca)" ;;
    esac
    (( TE_UPF )) && info "se actualiza: agente del UPF (el contenedor upf no se toca)"
    info "no se tocan: el core 5G, los certificados, la configuración ni los abonados"
    si_no "¿Descargo la última versión y la instalo?" || return 0
    tmp="$(mktemp -d /tmp/agent5g-act.XXXXXX)"
    if ! nova="$(baixa_codi "$tmp")"; then
        avis "no he podido descargar $REPO (rama $BRANCA): mira la conexión a internet"
        [[ "$tmp" == /tmp/agent5g-act.* ]] && rm -rf -- "$tmp"
        return 0
    fi
    S="$tmp/5gpanel"
    if [[ ! -f "$S/agent/agent5g.py" || ! -f "$S/scripts/agent5g_menu.sh" ]] \
       || ! python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$S/agent/agent5g.py" \
       || ! bash -n "$S/scripts/agent5g_menu.sh"; then
        avis "el código descargado no está completo o tiene errores: no instalo nada"
        [[ "$tmp" == /tmp/agent5g-act.* ]] && rm -rf -- "$tmp"
        return 0
    fi
    info "versión nueva: $nova"
    echo
    local ok=1
    if [[ "$ROL" == core ]]; then
        if ! PANEL_IP="$(ip_core_actual)" bash "$S/scripts/actualitzar.sh" 2>&1 | sed 's/^/      /'; then
            ok=0; avis "actualitzar.sh ha fallado: lee los mensajes de arriba (copias en /var/lib/agent5g/bak-*)"
        fi
        if (( ok && TE_UPF )); then systemctl restart agent5g-upf || true; fi
    else
        actualitza_agent "$S" || ok=0
    fi
    [[ "$tmp" == /tmp/agent5g-act.* ]] && rm -rf -- "$tmp"
    (( ok )) || return 0
    printf '%s\n' "$nova" > "$VERSIO_F"
    echo
    echo "==> Actualizado a $nova"
    echo "    Vuelve a abrir el menú (sudo agent5g) para usar la versión nueva."
    exit 0
}

# --- menú ----------------------------------------------------------------------------------
while true; do
    echo
    echo "=================================================================="
    echo " agent5g · configuración del agente del panel5g"
    echo "=================================================================="
    opcions=()
    case "$ROL" in
        core)  opcions+=("veure_core|Ver la configuración del core"
                         "canvia_ip_core|Cambiar la IP del core (y regenerar los certificados)"
                         "renova|Renovar los certificados (misma IP)"
                         "afegeix_radio|Añadir una radio (muestra su código de emparejamiento)"
                         "afegeix_upf|Añadir un UPF (muestra su código de emparejamiento)") ;;
        radio) opcions+=("veure_radio|Ver la configuración de la radio"
                         "core_radio|Cambiar la IP del core al que llama la radio"
                         "cert_radio|Renovar el certificado de la radio (pegando el código del core)") ;;
    esac
    if (( TE_UPF )); then
        opcions+=("veure_upf|Ver la configuración del UPF"
                  "core_upf|Cambiar la IP del core al que llama el UPF"
                  "cert_upf|Renovar el certificado del UPF (pegando el código del core)")
    fi
    opcions+=("actualitza|Actualizar desde GitHub (última versión)")
    i=1; for o in "${opcions[@]}"; do echo " $i) ${o#*|}"; i=$((i + 1)); done
    echo " $i) Salir"
    read -r -p "    Opción: " op || { echo; exit 0; }   # Ctrl+D o sin terminal: sale
    [[ "$op" =~ ^[0-9]+$ ]] || continue
    (( op == i )) && exit 0
    (( op >= 1 && op < i )) || continue
    case "${opcions[$((op - 1))]%%|*}" in
        veure_core)     veure_core ;;
        canvia_ip_core) canvia_ip_core ;;
        renova)         si_no "¿Renuevo el certificado del agente y del web del panel para $(ip_core_actual)?" \
                            && renova_certs "$(ip_core_actual)" \
                            && { pd="$(panell_dir)"; [[ -z "$pd" ]] || (cd "$pd" && PANEL_IP="$(ip_core_actual)" docker compose up -d --force-recreate >/dev/null 2>&1); systemctl restart agent5g; info "hecho (agente y panel reiniciados)"; } ;;
        veure_radio)    veure_client $CFG_A "Agente de la radio" ;;
        core_radio)     canvia_core_client $CFG_A agent5g "Radio" ;;
        veure_upf)      veure_client $CFG_U "Agente del UPF" ;;
        core_upf)       canvia_core_client $CFG_U agent5g-upf "UPF" ;;
        cert_radio)     renova_cert_client $CFG_A agent5g radio ;;
        cert_upf)       renova_cert_client $CFG_U agent5g-upf upf ;;
        afegeix_radio)  afegeix_equip radio ;;
        afegeix_upf)    afegeix_equip upf ;;
        actualitza)     actualitza ;;
    esac
done
