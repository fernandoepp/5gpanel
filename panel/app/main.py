"""Panell web 5G: interfície i orquestració. No té accés a Docker ni als fitxers
dels projectes: tot passa pels agents (mTLS), que apliquen la seva llista blanca."""
import asyncio
import ipaddress
import os
import re
import secrets
import ssl
import time
from collections import defaultdict
from pathlib import Path
from urllib.parse import urlparse

import httpx
import yaml
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from starlette.middleware.sessions import SessionMiddleware

from .auth import DUMMY, RateLimiter, verify_password
from .devices import build as build_devices
from .gnbs import build as build_gnbs
from .tacdb import TacDB
from .radio import calcula as radio_calc
from .radio_ues import associa
from .validation import services_for, validate, validate_plmn, validate_tdd

CONFIG_DIR = Path(os.environ.get('PANEL_CONFIG_DIR', '/config'))
STATIC = Path(__file__).parent / 'static'
NAME_RE = re.compile(r'^[A-Za-z0-9_.-]{1,128}$')


def load_yaml(name):
    with open(CONFIG_DIR / name) as f:
        return yaml.safe_load(f) or {}


CFG = load_yaml('panel.yaml')
SCHEMA = load_yaml('schema.yaml')
RESTART = load_yaml('restart_map.yaml')
# Equips: els de panel.yaml i els que es descobreixen (agent amb certificat de la nostra CA).
# AGENTS[nom] = {url, rol (core|radio), titol, descobert, ip}
AGENTS = {}
for _n, _a in (CFG.get('agents') or {}).items():
    _rol = _a.get('rol') or ('core' if _n.startswith('core') else 'radio')
    AGENTS[_n] = {'url': _a['url'], 'rol': _rol, 'descobert': False,
                  'titol': _a.get('titol') or SCHEMA.get(_rol, {}).get('titol', _n),
                  'ip': urlparse(_a['url']).hostname}
PENDING = defaultdict(list)             # serveis pendents de recrear per destí


def targets():
    return list(AGENTS)


def rol(t):
    return AGENTS[t]['rol'] if t in AGENTS else t


def titol(t):
    return AGENTS[t]['titol'] if t in AGENTS else t
LIMITER = RateLimiter()


def _secret():
    s = os.environ.get('PANEL_SECRET')
    f = os.environ.get('PANEL_SECRET_FILE')
    if not s and f and os.path.isfile(f):
        s = Path(f).read_text().strip()
    return s or secrets.token_urlsafe(48)   # sense secret fix: sessions es perden en reiniciar


def _ssl_ctx():
    ctx = ssl.create_default_context(cafile=CFG['ca'])
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    # Els agents s'identifiquen pel certificat (signat per LA NOSTRA CA i amb CN agent-*),
    # no per la IP: així un canvi de xarxa (DHCP) no obliga a tornar a emetre certificats.
    # El CN es comprova a cada resposta (_check_peer).
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.load_cert_chain(CFG['client_cert'], CFG['client_key'])
    return ctx


def _peer_cn(r):
    stream = r.extensions.get('network_stream')
    sslobj = stream.get_extra_info('ssl_object') if stream else None
    cert = sslobj.getpeercert() if sslobj else None
    for rdn in (cert or {}).get('subject', ()):
        for k, v in rdn:
            if k == 'commonName':
                return v
    return None


def _check_peer(r):
    """Només acceptem agents: certificat de la CA (ja verificat pel TLS) amb CN agent-core o agent-radio*."""
    cn = _peer_cn(r) or ''
    if not (cn == 'agent-core' or cn.startswith('agent-radio') or cn.startswith('agent-upf')):
        raise httpx.ConnectError(f'certificat no és d\'un agent (CN={cn or "?"})')
    return cn


_CTX = None


def client(target, timeout=15.0):
    global _CTX
    if target not in AGENTS:
        raise HTTPException(404, 'destí desconegut')
    if _CTX is None:
        _CTX = _ssl_ctx()
    return httpx.AsyncClient(base_url=AGENTS[target]['url'], verify=_CTX, timeout=timeout, trust_env=False)


async def agent(target, method, path, user='-', timeout=15.0, **kw):
    try:
        async with client(target, timeout) as c:
            # en streaming: el certificat de l'agent només es pot llegir amb la connexió oberta
            r = await c.send(c.build_request(method, path, headers={'X-Panel-User': user}, **kw), stream=True)
            try:
                _check_peer(r)
                await r.aread()
            finally:
                await r.aclose()
    except httpx.HTTPError as e:
        raise HTTPException(502, f'agent {target} no accessible: {type(e).__name__}')
    data = r.json() if r.headers.get('content-type', '').startswith('application/json') else {}
    if r.status_code >= 400:
        raise HTTPException(r.status_code if r.status_code < 500 else 502,
                            data.get('error', f'error {r.status_code}'))
    return data


# ---------------------------------------------------------------- descobriment d'equips
# El panell busca agents a les xarxes del laboratori. Només s'afegeix un equip si:
#   * respon al port de l'agent amb un certificat signat per LA NOSTRA CA,
#   * el certificat és per a aquella IP (SAN) i
#   * accepta el certificat client del panell (/health amb rol core o radio).
# Un agent sense certificat de la CA no pot aparèixer. Si deixa de respondre 3 cerques
# seguides, es treu de la llista.
DESC_CFG = CFG.get('descobriment') or {}
DESC = {'en_curs': False, 'darrera': None, 'xarxes': [], 'port': None, 'trobats': 0}
_FALLADES = defaultdict(int)


def _desc_port():
    if DESC_CFG.get('port'):
        return int(DESC_CFG['port'])
    for a in AGENTS.values():
        if a['rol'] == 'radio' and not a['descobert']:
            return urlparse(a['url']).port or 9543
    return 9543


def _desc_xarxes():
    xs = DESC_CFG.get('xarxes')
    if xs is None:      # per defecte: la /24 del panell (PANEL_IP) i la de cada agent de panel.yaml amb IP de LAN
        xs = []
        for a in [{'ip': os.environ.get('PANEL_IP')}] + list(AGENTS.values()):
            try:
                ip = ipaddress.ip_address(a['ip'] or '')
            except ValueError:
                continue
            if ip.version == 4 and ip.is_private and not ip.is_loopback and ip not in ipaddress.ip_network('172.16.0.0/12'):
                n = str(ipaddress.ip_network(f'{ip}/24', strict=False))
                if n not in xs:
                    xs.append(n)
    out = []
    for x in xs:
        try:
            n = ipaddress.ip_network(str(x), strict=False)
        except ValueError:
            continue
        if n.version == 4 and n.num_addresses <= 1024:       # com a molt una /22
            out.append(n)
    return out


async def _prova(ip, port):
    try:
        _, w = await asyncio.wait_for(asyncio.open_connection(str(ip), port), 0.7)
        w.close()
    except (OSError, asyncio.TimeoutError):
        return None
    global _CTX
    if _CTX is None:
        _CTX = _ssl_ctx()
    url = f'https://{ip}:{port}'
    try:
        async with httpx.AsyncClient(base_url=url, verify=_CTX, timeout=5.0, trust_env=False) as c:
            r = await c.send(c.build_request('GET', '/health', headers={'X-Panel-User': 'descobriment'}), stream=True)
            try:
                _check_peer(r)
                await r.aread()
            finally:
                await r.aclose()
        h = r.json()
    except (httpx.HTTPError, ValueError, ssl.SSLError):
        return None
    if r.status_code != 200 or h.get('role') not in ('core', 'radio'):
        return None
    return url, h


async def descobreix():
    if DESC['en_curs']:
        return DESC
    DESC['en_curs'] = True
    try:
        port, xarxes = _desc_port(), _desc_xarxes()
        DESC.update(port=port, xarxes=[str(x) for x in xarxes])
        fixos = {a['ip'] for a in AGENTS.values() if not a['descobert']}
        ips = [ip for n in xarxes for ip in n.hosts() if str(ip) not in fixos]
        sem = asyncio.Semaphore(64)

        async def una(ip):
            async with sem:
                return str(ip), await _prova(ip, port)
        trobats = set()
        for ip, r in await asyncio.gather(*(una(ip) for ip in ips)):
            if not r:
                continue
            url, h = r
            # el core ja configurat a panel.yaml (p. ex. host.docker.internal) no es duplica
            # quan el seu agent també respon per la IP de la LAN
            if h['role'] == 'core' and any(x['rol'] == 'core' and not x['descobert'] for x in AGENTS.values()):
                continue
            nom = f"{h['role']}-{ip}"
            trobats.add(nom)
            _FALLADES.pop(nom, None)
            def_t = ('Ràdio' if h['role'] == 'radio' else 'Core') + f' {ip}'
            AGENTS[nom] = {'url': url, 'rol': h['role'], 'descobert': True, 'ip': ip,
                           'titol': str(h.get('nom') or def_t)[:60]}
        for nom in [n for n, a in AGENTS.items() if a['descobert'] and not a.get('via') and n not in trobats]:
            _FALLADES[nom] += 1
            if _FALLADES[nom] >= 3:
                AGENTS.pop(nom, None)
                _FALLADES.pop(nom, None)
        DESC.update(darrera=time.time(), trobats=len(trobats))
    finally:
        DESC['en_curs'] = False
    return DESC


# ---------------------------------------------------------------- ràdios que truquen al core
# Arquitectura principal: la ràdio truca al core (com la gNodeB a l'AMF). L'agent del core
# té les ràdios connectades (GET /radios) i hi reenvia les peticions (/radio/<id>/...).
# Al panell li és igual la IP de la ràdio: només parla amb l'agent del core.
ENLLAC = {'darrera': None, 'errors': {}}
_ENLLAC_FALLADES = defaultdict(int)


async def radios_enllac():
    vistes = set()
    cores = [(t, a) for t, a in list(AGENTS.items()) if a['rol'] == 'core' and not a.get('via')]
    for t, a in cores:
        try:
            r = await agent(t, 'GET', '/radios', 'enllac', timeout=8.0)
        except HTTPException as e:
            ENLLAC['errors'][t] = str(e.detail)
            continue
        ENLLAC['errors'].pop(t, None)
        for rd in r.get('radios') or []:
            rid = str(rd.get('id') or '')
            if not NAME_RE.match(rid) or not rd.get('connectada'):
                continue
            nom = f'radio-{rid}'
            vistes.add(nom)
            _ENLLAC_FALLADES.pop(nom, None)
            ant = AGENTS.get(nom)
            AGENTS[nom] = {'url': a['url'].rstrip('/') + f'/radio/{rid}', 'rol': 'radio', 'descobert': True,
                           'via': t, 'ip': rd.get('ip'), 'id': rid, 'des_de': rd.get('des_de'),
                           'titol': ant['titol'] if ant and ant.get('via') == t else f'Ràdio {rid}'}
            if not ant or ant.get('via') != t:      # nom visible ("name" de l'agent de la ràdio)
                try:
                    h = await agent(nom, 'GET', '/health', 'enllac', timeout=8.0)
                    if h.get('nom'):
                        AGENTS[nom]['titol'] = str(h['nom'])[:60]
                except HTTPException:
                    pass
        # PCs amb UPF: també truquen al core (agent-upf-<nom>); es veuen com equips "upf"
        try:
            ru = await agent(t, 'GET', '/upfs', 'enllac', timeout=8.0)
        except HTTPException:
            ru = {}
        for u in ru.get('upfs') or []:
            uid = str(u.get('id') or '')
            if not NAME_RE.match(uid) or not u.get('connectat'):
                continue
            nom = f'upf-{uid}'
            vistes.add(nom)
            _ENLLAC_FALLADES.pop(nom, None)
            ant = AGENTS.get(nom)
            AGENTS[nom] = {'url': a['url'].rstrip('/') + f'/upf/{uid}', 'rol': 'upf', 'descobert': True,
                           'via': t, 'ip': u.get('ip'), 'id': uid, 'des_de': u.get('des_de'),
                           'titol': ant['titol'] if ant and ant.get('via') == t else f'UPF {uid}'}
            if not ant or ant.get('via') != t:
                try:
                    h = await agent(nom, 'GET', '/health', 'enllac', timeout=8.0)
                    if h.get('nom'):
                        AGENTS[nom]['titol'] = str(h['nom'])[:60]
                except HTTPException:
                    pass
    # una ràdio (o UPF) que ja no hi és desapareix al cap de 2 consultes (uns 20 s)
    for nom in [n for n, a in AGENTS.items() if a.get('via') and n not in vistes]:
        _ENLLAC_FALLADES[nom] += 1
        if _ENLLAC_FALLADES[nom] >= 2:
            AGENTS.pop(nom, None)
            _ENLLAC_FALLADES.pop(nom, None)
    ENLLAC['darrera'] = time.time()


async def _bucle_enllac():
    await asyncio.sleep(1)
    while True:
        try:
            await radios_enllac()
        except Exception:  # noqa: BLE001 - mai ha de tombar el panell
            pass
        await asyncio.sleep(10)


async def _bucle_descobriment():
    await asyncio.sleep(3)
    while True:
        try:
            await descobreix()
        except Exception:  # noqa: BLE001 - la cerca mai ha de tombar el panell
            DESC['en_curs'] = False
        await asyncio.sleep(max(30, int(DESC_CFG.get('interval_s', 120))))


app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
app.add_middleware(SessionMiddleware, secret_key=_secret(), session_cookie='panel5g',
                   max_age=int(CFG.get('sessio_hores', 8)) * 3600, same_site='strict',
                   https_only=True)


@app.middleware('http')
async def security_headers(request: Request, call_next):
    resp = await call_next(request)
    h = resp.headers
    h['Content-Security-Policy'] = ("default-src 'self'; img-src 'self' data:; "
                                    "frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
    h['X-Content-Type-Options'] = 'nosniff'
    h['Referrer-Policy'] = 'no-referrer'
    h['X-Frame-Options'] = 'DENY'
    h['Strict-Transport-Security'] = 'max-age=31536000'
    if request.url.path.startswith('/api/'):
        h['Cache-Control'] = 'no-store'
    else:
        # que el navegador no faci servir un app.js o index.html vell després d'actualitzar
        h['Cache-Control'] = 'no-cache'
    return resp


@app.on_event('startup')
async def _arrenca():
    app.state.enllac = asyncio.create_task(_bucle_enllac())
    # la cerca per la xarxa (el panell busca agents que escolten) ja no cal amb l'enllaç
    # ràdio -> core; només si es demana a panel.yaml (descobriment: {actiu: true}).
    if DESC_CFG.get('actiu', False):
        app.state.desc = asyncio.create_task(_bucle_descobriment())


# ---------------------------------------------------------------- sessió
def current_user(request: Request):
    s = request.session
    if not s.get('user') or s.get('exp', 0) < time.time():
        request.session.clear()
        raise HTTPException(401, 'cal iniciar sessió')
    return s


def admin(request: Request, s=Depends(current_user)):
    if s.get('rol') != 'admin':
        raise HTTPException(403, 'cal rol admin')
    tok = request.headers.get('X-CSRF-Token', '')
    if not secrets.compare_digest(tok, s.get('csrf', '')):
        raise HTTPException(403, 'token CSRF invàlid')
    return s


def admin_read(s=Depends(current_user)):
    if s.get('rol') != 'admin':
        raise HTTPException(403, 'cal rol admin')
    return s


@app.post('/api/login')
async def login(request: Request):
    ip = request.client.host if request.client else '?'
    if LIMITER.blocked(ip):
        raise HTTPException(429, 'massa intents, espera uns minuts')
    body = await request.json()
    user, pw = str(body.get('usuari', '')), str(body.get('contrasenya', ''))
    u = CFG.get('usuaris', {}).get(user)
    ok = verify_password(pw, u['hash'] if u else DUMMY) and u is not None
    if not ok:
        LIMITER.fail(ip)
        raise HTTPException(401, 'usuari o contrasenya incorrectes')
    LIMITER.reset(ip)
    request.session.clear()
    request.session.update({'user': user, 'rol': u.get('rol', 'lector'),
                            'csrf': secrets.token_urlsafe(32),
                            'exp': time.time() + int(CFG.get('sessio_hores', 8)) * 3600})
    return {'usuari': user, 'rol': request.session['rol'], 'csrf': request.session['csrf']}


@app.post('/api/logout')
async def logout(request: Request):
    request.session.clear()
    return {'ok': True}


@app.get('/api/me')
async def me(s=Depends(current_user)):
    return {'usuari': s['user'], 'rol': s['rol'], 'csrf': s['csrf'], 'destins': targets(),
            'titols': {t: titol(t) for t in AGENTS}, 'rols': {t: rol(t) for t in AGENTS},
            'descoberts': [t for t, a in AGENTS.items() if a['descobert']]}


@app.get('/api/equips')
async def equips(s=Depends(current_user)):
    return {'equips': [{'desti': t, 'rol': a['rol'], 'titol': a['titol'], 'descobert': a['descobert'],
                        'ip': a['ip'], 'enllac': bool(a.get('via')), 'des_de': a.get('des_de')}
                       for t, a in AGENTS.items()],
            'descobriment': {**DESC, 'actiu': bool(DESC_CFG.get('actiu', False))},
            'enllac': {'darrera': ENLLAC['darrera'], 'errors': ENLLAC['errors']}}


@app.post('/api/equips/descobreix')
async def equips_descobreix(s=Depends(admin)):
    await radios_enllac()
    if DESC_CFG.get('actiu', False):
        await descobreix()
    return await equips(s)


# ---------------------------------------------------------------- estat
def extract_metrics(patterns, logs):
    out = []
    for p in patterns:
        txt = logs.get(p['contenidor'], '')
        val, when = None, None
        rx = re.compile(p['regex'])
        for line in reversed(txt.splitlines()):
            m = rx.search(line)
            if m:
                ts = line.split(' ', 1)[0] if line[:4].isdigit() else None
                val = m.group(1) if m.groups() else 'sí'
                when = ts
                break
        out.append({'etiqueta': p['etiqueta'], 'valor': val, 'quan': when})
    return out


async def target_status(t, user):
    try:
        health = await agent(t, 'GET', '/health', user)
        cont = (await agent(t, 'GET', '/containers', user))['containers']
    except HTTPException as e:
        return {'desti': t, 'rol': rol(t), 'ok': False, 'error': e.detail, 'pendents': PENDING[t]}
    el = CFG.get('estat_logs', {})
    patterns = el.get(t) if t in el else el.get(rol(t), [])
    names = sorted({p['contenidor'] for p in patterns} & set(health.get('containers', [])))
    n = int(CFG.get('estat_linies', 1000))
    logs = {}
    for name in names:
        try:
            logs[name] = (await agent(t, 'GET', '/logs', user,
                                      params={'container': name, 'tail': n}))['log']
        except HTTPException:
            logs[name] = ''
    mets = extract_metrics(patterns, logs)
    running = {c['name'] for c in cont if c.get('status') == 'running'}
    for m, p in zip(mets, patterns):
        # Un log d'un contenidor aturat no diu l'estat actual
        m['obsolet'] = p['contenidor'] not in running
    return {'desti': t, 'rol': rol(t), 'ok': True, 'agent': health, 'contenidors': cont,
            'metriques': mets, 'pendents': PENDING[t]}


@app.get('/api/status')
async def status(s=Depends(current_user)):
    res = await asyncio.gather(*(target_status(t, s['user']) for t in targets()))
    return {'destins': res}


# ---------------------------------------------------------------- .env
async def env_values(t, user):
    env = (await agent(t, 'GET', '/env', user))['env']
    return {k: v['value'] for k, v in env.items()}, env


@app.get('/api/env/{t}')
async def get_env(t: str, s=Depends(current_user)):
    vals, raw = await env_values(t, s['user'])
    camps = SCHEMA.get(rol(t), {}).get('camps', {})
    fields = [{'clau': k, 'valor': vals.get(k), 'existeix': k in vals,
               'editable_agent': raw.get(k, {}).get('editable', False), **spec}
              for k, spec in camps.items()]
    health = await agent(t, 'GET', '/health', s['user'])
    return {'desti': t, 'titol': titol(t), 'camps': fields,
            'pendents': PENDING[t], 'serveis_agent': health.get('services', [])}


async def _validate(t, changes, user):
    if not isinstance(changes, dict) or not all(isinstance(k, str) for k in changes):
        raise HTTPException(400, 'format invàlid')
    vals, _ = await env_values(t, user)
    # regles creuades core<->ràdio: contra cada equip de l'altre rol
    res = None
    for o in targets():
        if o == t or rol(o) == rol(t):
            continue
        try:
            ov, _ = await env_values(o, user)
        except HTTPException:
            continue
        r = validate(SCHEMA, rol(t), vals, changes, {rol(o): ov})
        if res is None:
            res = r
        else:
            res['warnings'] += [w for w in r['warnings'] if w not in res['warnings']]
    return vals, res or validate(SCHEMA, rol(t), vals, changes, {})


@app.get('/api/radio/bandes')
async def radio_bandes(s=Depends(current_user)):
    """Bandes per al selector d'espectre (Paràmetres > Ràdio)."""
    sch = SCHEMA.get('radio', {})
    bs = sch.get('bandes') or {}
    sel = [int(n) for n in (sch.get('espectre') or [28, 40, 77, 78]) if n in bs or str(n) in bs]
    out = {}
    for n in sel:
        b = bs.get(n) or bs.get(str(n))
        out[n] = {'duplex': b.get('duplex'), 'dl_mhz': b['dl_mhz'], 'ul_mhz': b.get('ul_mhz'),
                  'scs': b.get('scs'), 'ample_min': b.get('ample_min', 5)}
    return {'espectre': sel, 'bandes': out}


@app.get('/api/radio/calcula')
async def radio_calcula(freq: float | None = None, arfcn: int | None = None, banda: int | None = None,
                        scs: int | None = None, ample: float | None = None, s=Depends(current_user)):
    """Freqüència central -> DL_ARFCN, banda i SCS (no toca res; només calcula)."""
    sch = SCHEMA.get('radio', {})
    dev = sch.get('dispositiu', {})
    if freq is not None and not 0 < freq < 7125:
        raise HTTPException(400, 'freqüència fora de FR1')
    if arfcn is not None and not 0 <= arfcn <= 3279165:
        raise HTTPException(400, 'ARFCN invàlid')
    r = radio_calc(sch, f=freq, arfcn=arfcn, banda=banda, scs=scs, ample=ample,
                   srates=dev.get('srate_permeses'), factor=dev.get('factor_srate_ample', 1.152))
    f = r.get('freq_real_mhz')
    if f is not None and not dev.get('freq_min_mhz', 0) <= f <= dev.get('freq_max_mhz', 1e9):
        r.setdefault('errors', []).append(f'{f:g} MHz és fora del rang de la {dev.get("model", "SDR")}.')
    return r


@app.post('/api/validate/{t}')
async def post_validate(t: str, request: Request, s=Depends(current_user)):
    body = await request.json()
    _, res = await _validate(t, body.get('canvis', {}), s['user'])
    return res


@app.post('/api/env/{t}')
async def post_env(t: str, request: Request, s=Depends(admin)):
    body = await request.json()
    vals, res = await _validate(t, body.get('canvis', {}), s['user'])
    if not res['ok']:
        return JSONResponse(res, status_code=422)
    changes = {k: v for k, v in res['normalized'].items() if vals.get(k) != v}
    if not changes:
        return {**res, 'desat': False, 'missatge': 'cap canvi', 'pendents': PENDING[t]}
    r = await agent(t, 'POST', '/env', s['user'], json={'changes': changes})
    for svc in services_for(RESTART, rol(t), changes):
        if svc not in PENDING[t]:
            PENDING[t].append(svc)
    return {**res, 'desat': True, 'canvis': changes, 'copia': r.get('backup'),
            'pendents': PENDING[t]}


# ---------------------------------------------------------------- patró TDD (ràdio)
TDD_KEYS = ['PERIOD_TDD', 'DL_SLOTS', 'DL_SYMBOLS', 'UL_SLOTS', 'UL_SYMBOLS']


@app.get('/api/tdd/{t}')
async def get_tdd(t: str, s=Depends(current_user)):
    st = await agent(t, 'GET', '/tdd', s['user'])
    vals, _ = await env_values(t, s['user'])
    actuals = {k: (st['env'].get(k) if st['env'].get(k) is not None else st['defecte'][k]) for k in TDD_KEYS}
    v = validate_tdd(SCHEMA.get(rol(t), {}), vals, st['actiu'], actuals)
    return {**st, 'banda': vals.get('BAND'), 'scs': vals.get('SCS'), 'validacio': v}


@app.post('/api/tdd/{t}/validate')
async def post_tdd_validate(t: str, request: Request, s=Depends(current_user)):
    body = await request.json()
    vals, _ = await env_values(t, s['user'])
    return validate_tdd(SCHEMA.get(rol(t), {}), vals, bool(body.get('activa')), body.get('valors') or {})


@app.post('/api/tdd/{t}')
async def post_tdd(t: str, request: Request, s=Depends(admin)):
    body = await request.json()
    activa = body.get('activa')
    if not isinstance(activa, bool):
        raise HTTPException(400, '"activa" ha de ser true o false')
    valors = body.get('valors') or {}
    if not isinstance(valors, dict) or set(valors) - set(TDD_KEYS):
        raise HTTPException(400, 'valors TDD invàlids')
    vals, _ = await env_values(t, s['user'])
    v = validate_tdd(SCHEMA.get(rol(t), {}), vals, activa, valors)
    if not v['ok']:
        return JSONResponse(v, status_code=422)
    r = await agent(t, 'POST', '/tdd', s['user'], json={'activa': activa, 'valors': valors if activa else None})
    for svc in services_for(RESTART, rol(t), TDD_KEYS):
        if svc not in PENDING[t]:
            PENDING[t].append(svc)
    return {**v, **r, 'pendents': PENDING[t]}


# ---------------------------------------------------------------- diversos PLMN (opció avançada)
PLMN_SERVEIS = {'core': ['amf', 'nrf'], 'radio': ['gnb']}


async def _altre_env(t, user):
    out = {}
    for o in targets():
        if o != t and rol(o) != rol(t):
            try:
                v, _ = await env_values(o, user)
                out.update(v)
            except HTTPException:
                pass
    return out


@app.get('/api/plmn/{t}')
async def get_plmn(t: str, s=Depends(current_user)):
    return await agent(t, 'GET', '/plmn', s['user'])


@app.post('/api/plmn/{t}/validate')
async def post_plmn_validate(t: str, request: Request, s=Depends(current_user)):
    body = await request.json()
    st = await agent(t, 'GET', '/plmn', s['user'])
    vals, _ = await env_values(t, s['user'])
    return validate_plmn(st['rol'], vals, bool(body.get('activa')), body.get('valors') or {},
                         await _altre_env(t, s['user']))


@app.post('/api/plmn/{t}')
async def post_plmn(t: str, request: Request, s=Depends(admin)):
    body = await request.json()
    activa = body.get('activa')
    valors = body.get('valors') or {}
    if not isinstance(activa, bool) or not isinstance(valors, dict) or \
            set(valors) - {'MCC_2', 'MNC_2', 'PLMN_2'}:
        raise HTTPException(400, 'petició invàlida')
    st = await agent(t, 'GET', '/plmn', s['user'])
    vals, _ = await env_values(t, s['user'])
    v = validate_plmn(st['rol'], vals, activa, valors, await _altre_env(t, s['user']))
    if not v['ok']:
        return JSONResponse(v, status_code=422)
    r = await agent(t, 'POST', '/plmn', s['user'], json={'activa': activa, 'valors': valors if activa else None})
    if r.get('canvis'):
        for svc in PLMN_SERVEIS.get(st['rol'], []):
            if svc not in PENDING[t]:
                PENDING[t].append(svc)
    return {**v, **r, 'pendents': PENDING[t]}


# ---------------------------------------------------------------- subscriptors (substitueix la WebUI)
@app.get('/api/subs/{t}')
async def get_subs(t: str, s=Depends(admin_read)):
    return await agent(t, 'GET', '/subs', s['user'], timeout=30.0)


@app.post('/api/subs/{t}')
async def post_subs(t: str, request: Request, s=Depends(admin)):
    body = await request.json()
    acc = body.get('accio')
    if acc == 'desa':
        if not isinstance(body.get('sub'), dict) or not isinstance(body.get('nou'), bool):
            raise HTTPException(400, 'petició invàlida')
        payload = {'accio': 'desa', 'nou': body['nou'], 'sub': body['sub']}
    elif acc in ('esborra', 'claus'):
        payload = {'accio': acc, 'imsi': str(body.get('imsi', ''))}
    else:
        raise HTTPException(400, 'acció invàlida')
    return await agent(t, 'POST', '/subs', s['user'], timeout=30.0, json=payload)


@app.get('/api/voip/{t}')
async def get_voip(t: str, s=Depends(admin_read)):
    return await agent(t, 'GET', '/voip', s['user'], timeout=30.0)


@app.post('/api/voip/{t}')
async def post_voip(t: str, request: Request, s=Depends(admin)):
    body = await request.json()
    acc = body.get('accio')
    if acc not in ('alta', 'baixa'):
        raise HTTPException(400, 'acció invàlida')
    payload = {'accio': acc, 'imsi': str(body.get('imsi', ''))}
    if acc == 'alta':
        payload['msisdn'] = str(body.get('msisdn', ''))
    return await agent(t, 'POST', '/voip', s['user'], timeout=60.0, json=payload)


@app.get('/api/voipdeploy/{t}')
async def get_voipdeploy(t: str, s=Depends(admin_read)):
    return await agent(t, 'GET', '/voip/desplegament', s['user'], timeout=30.0)


@app.post('/api/voipdeploy/{t}')
async def post_voipdeploy(t: str, request: Request, s=Depends(admin)):
    body = await request.json()
    if body.get('accio') not in ('activa', 'desactiva'):
        raise HTTPException(400, 'acció invàlida')
    return await agent(t, 'POST', '/voip/desplegament', s['user'], json={'accio': body['accio']})


@app.post('/api/apply/{t}')
async def post_apply(t: str, request: Request, s=Depends(admin)):
    body = await request.json()
    svcs = body.get('serveis')
    if not isinstance(svcs, list) or not svcs or not all(
            isinstance(x, str) and NAME_RE.match(x) for x in svcs):
        raise HTTPException(400, 'llista de serveis invàlida')
    r = await agent(t, 'POST', '/apply', s['user'], timeout=330.0, json={'services': svcs})
    if r.get('ok'):
        PENDING[t] = [x for x in PENDING[t] if x not in svcs]
    return {**r, 'pendents': PENDING[t]}


@app.get('/api/backups/{t}')
async def backups(t: str, s=Depends(current_user)):
    return await agent(t, 'GET', '/env/backups', s['user'])


@app.post('/api/restore/{t}')
async def restore(t: str, request: Request, s=Depends(admin)):
    body = await request.json()
    name = body.get('nom')
    if not isinstance(name, str) or not NAME_RE.match(name):
        raise HTTPException(400, 'nom invàlid')
    r = await agent(t, 'POST', '/env/restore', s['user'], json={'name': name})
    keys = list(SCHEMA.get(rol(t), {}).get('camps', {}))
    for svc in services_for(RESTART, rol(t), keys):
        if svc not in PENDING[t]:
            PENDING[t].append(svc)
    return {**r, 'pendents': PENDING[t]}


# ---------------------------------------------------------------- UPF separat
# El PC del UPF truca al core (com la ràdio). El panell només parla amb l'agent del core:
# GET /upf (mode, UPF connectats, PFCP) i /upf/<id>/upf_estat (mètriques per HTTP del UPF).
def _core_de(t):
    if t not in AGENTS or AGENTS[t]['rol'] != 'core':
        raise HTTPException(404, 'cal un core')
    return t


@app.get('/api/upf/{t}')
async def get_upf(t: str, s=Depends(current_user)):
    _core_de(t)
    st = await agent(t, 'GET', '/upf', s['user'], timeout=30.0)
    con = [u for u in st.get('upfs') or [] if u.get('connectat') and NAME_RE.match(str(u.get('id') or ''))]
    res = await asyncio.gather(*(_safe(agent(t, 'GET', f"/upf/{u['id']}/upf_estat", s['user'], timeout=20.0), None)
                                 for u in con))
    for u, (d, err) in zip(con, res):
        u['estat'], u['error'] = d, err
    return st


@app.post('/api/upf/{t}')
async def post_upf(t: str, request: Request, s=Depends(admin)):
    _core_de(t)
    body = await request.json()
    acc = body.get('accio')
    if acc not in ('separa', 'ajunta', 'auto'):
        raise HTTPException(400, 'acció invàlida')
    cos = {'accio': acc}
    if acc == 'separa':
        if body.get('upf_id'):
            if not NAME_RE.match(str(body['upf_id'])):
                raise HTTPException(400, 'UPF invàlid')
            cos['upf_id'] = str(body['upf_id'])
        else:
            try:
                cos['ip'] = str(ipaddress.IPv4Address(str(body.get('ip', '')).strip()))
            except ValueError:
                raise HTTPException(400, 'IP del UPF invàlida')
    if acc == 'auto':
        cos['valor'] = bool(body.get('valor'))
    return await agent(t, 'POST', '/upf', s['user'], timeout=float(CFG.get('apply_timeout', 300)) + 60, json=cos)


@app.post('/api/project/{t}')
async def project(t: str, request: Request, s=Depends(admin)):
    body = await request.json()
    accio = body.get('accio')
    if accio not in ('up', 'stop', 'down'):
        raise HTTPException(400, 'acció invàlida')
    return await agent(t, 'POST', '/project', s['user'], timeout=330.0, json={'accio': accio})


# ---------------------------------------------------------------- UEs
def load_tac():
    """tac.csv opcional: tac,marca,model (8 dígits). Si no hi és, no es mostra model."""
    out = {}
    f = CONFIG_DIR / 'tac.csv'
    if f.is_file():
        for line in f.read_text(errors='replace').splitlines():
            parts = [x.strip() for x in line.split(',')]
            if len(parts) >= 3 and parts[0].isdigit():
                out[parts[0].zfill(8)] = f'{parts[1]} {parts[2]}'.strip()
    return out


TAC = TacDB(load_tac())   # tac.csv del laboratori + base de dades pública de TAC


def load_noms():
    """dispositius.csv opcional: imsi,nom (p. ex. 001010000000001,Mòbil 3 del lab)."""
    out = {}
    f = CONFIG_DIR / 'dispositius.csv'
    if f.is_file():
        for line in f.read_text(errors='replace').splitlines():
            parts = [x.strip() for x in line.split(',', 1)]
            if len(parts) == 2 and parts[0].isdigit():
                out[parts[0]] = parts[1]
    return out


def load_models():
    """models.csv opcional: codi,nom comercial (p. ex. SM-G990B,Samsung Galaxy S21 FE 5G)."""
    out = {}
    f = CONFIG_DIR / 'models.csv'
    if f.is_file():
        for line in f.read_text(errors='replace').splitlines():
            parts = [x.strip() for x in line.split(',', 1)]
            if len(parts) == 2 and parts[0] and not parts[0].startswith('#'):
                out[parts[0].upper()] = parts[1]
    return out


MODELS = load_models()


async def _safe(coro, default):
    try:
        return await coro, None
    except HTTPException as e:
        return default, str(e.detail)


async def _core_data(t, user, gnbs=False, historial=True):
    """Quins dispositius i gNB hi ha: NOMÉS l'estat en viu de l'AMF i l'SMF (agent /estat5g,
    API JSON d'Open5GS). Els logs de l'AMF/SMF només afegeixen l'historial d'aquests mateixos
    dispositius i gNB. Sense captura (tshark). Amb historial=False no llegeix els logs (resposta
    ràpida: el navegador pinta això primer i després demana l'historial). -> (health, devs, extra, fonts)"""
    health = await agent(t, 'GET', '/health', user)
    conts = health.get('containers', [])
    if 'amf' not in conts:
        raise HTTPException(404, 'aquest equip no té AMF')
    n = 2000

    async def logs_of(c):
        if not historial or c not in conts:
            return ''
        return (await agent(t, 'GET', '/logs', user, params={'container': c, 'tail': n}))['log']

    async def estat():
        if not health.get('estat5g'):
            raise HTTPException(502, 'agent sense /estat5g (actualitza l\'agent)')
        return await agent(t, 'GET', '/estat5g', user, timeout=30.0)

    (viu, e5), (amf, e1), (smf, e2) = await asyncio.gather(
        _safe(estat(), {}), _safe(logs_of('amf'), ''), _safe(logs_of('smf'), ''))
    errs = (viu or {}).get('errors') or {}
    fonts = {'estat_viu': e5 or ('; '.join(sorted(set(errs.values()))) if errs else 'ok'),
             'historial': ('ok' if not (e1 or e2) else '; '.join(x for x in (e1, e2) if x))
             if historial else 'pendent'}
    devs = build_devices(amf, smf, None, TAC, load_noms(), models=MODELS, viu=viu, nomes_viu=True)
    extra = {'amf_log': amf, 'viu': viu, 'gnbs': None}
    return health, devs, extra, fonts


@app.get('/api/ues/{t}')
async def ues(t: str, historial: bool = True, s=Depends(admin_read)):
    # Només admin: IMSI i IMEI són dades personals dels qui connecten el mòbil
    _, devs, _, fonts = await _core_data(t, s['user'], historial=historial)
    return {'dispositius': devs, 'fonts': fonts}


async def _radio_ues_de(t, user):
    try:
        return {'desti': t, 'titol': titol(t), 'dades': await agent(t, 'GET', '/radio_ues', user, timeout=8.0)}
    except HTTPException as e:
        err = 'agent sense /radio_ues (actualitza l\'agent de la ràdio)' if e.status_code == 404 else str(e.detail)
        return {'desti': t, 'titol': titol(t), 'error': err}


@app.get('/api/ues/{t}/radio')
async def ues_radio(t: str, s=Depends(admin_read)):
    """Mètriques de ràdio de cada mòbil (CQI, RI, MCS, velocitat...). Es demana després de pintar
    les fitxes: si una ràdio no respon, les fitxes ja hi són igualment."""
    radios = [o for o in targets() if o != t and rol(o) == 'radio']
    viu, err = await _safe(agent(t, 'GET', '/estat5g', s['user'], timeout=15.0), {})
    res = associa(viu, await asyncio.gather(*(_radio_ues_de(o, s['user']) for o in radios)))
    if err:
        res['fonts']['AMF'] = err
    if not radios:
        res['fonts']['ràdio'] = 'cap equip de ràdio al panell'
    return res


async def _radio_info(t, user):
    try:
        vals, _ = await env_values(t, user)
        if 'RADIO_IP' not in vals:
            return None
        cont = (await agent(t, 'GET', '/containers', user))['containers']
        return {'desti': t, 'titol': titol(t), 'env': vals, 'contenidors': cont}
    except HTTPException as e:
        return {'desti': t, 'error': str(e.detail), 'env': {}}


@app.get('/api/gnbs/{t}')
async def gnbs(t: str, historial: bool = True, s=Depends(current_user)):
    _, devs, extra, fonts = await _core_data(t, s['user'], gnbs=True, historial=historial)
    radios = [r for r in await asyncio.gather(*(_radio_info(o, s['user']) for o in targets() if o != t)) if r]
    res = build_gnbs(extra['amf_log'], extra.get('gnbs'), devs, radios,
                     viu=(extra.get('viu') or {}).get('gnbs'), nomes_viu=True)
    if s['rol'] != 'admin':                       # el lector no veu IMSI
        for g in res['gnbs']:
            g['ues'] = [{k: v for k, v in u.items() if k not in ('imsi', 'nom')} for u in g['ues']]
    res['fonts'] = fonts
    return res


# ---------------------------------------------------------------- logs i auditoria
def _tail(n):
    return max(1, min(int(n), 2000))


@app.get('/api/logs/{t}')
async def logs(t: str, container: str, tail: int = 300, s=Depends(current_user)):
    return await agent(t, 'GET', '/logs', s['user'],
                       params={'container': container, 'tail': _tail(tail)})


@app.get('/api/logfile/{t}')
async def logfile(t: str, name: str, tail: int = 300, s=Depends(current_user)):
    return await agent(t, 'GET', '/logfile', s['user'], params={'name': name, 'tail': _tail(tail)})


@app.get('/api/audit/{t}')
async def audit(t: str, tail: int = 200, s=Depends(current_user)):
    return await agent(t, 'GET', '/audit', s['user'], params={'tail': _tail(tail)})


# ---------------------------------------------------------------- web
app.mount('/static', StaticFiles(directory=STATIC), name='static')


@app.get('/')
async def index():
    return FileResponse(STATIC / 'index.html')
