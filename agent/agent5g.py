#!/usr/bin/env python3
"""agent5g: agent mínim que corre a cada PC (core o ràdio).

Només atén clients amb certificat signat per la CA del panell (mTLS) i amb un CN
permès. Només sap fer operacions d'una llista blanca:

  GET  /health                 -> estat de l'agent
  GET  /env                    -> claus del .env (secrets amagats)
  POST /env                    -> {"changes": {"CLAU": "valor"}} (només claus editables)
  GET  /env/backups            -> còpies de seguretat del .env
  POST /env/restore            -> {"name": "env-20261117-101500.bak"}
  GET  /containers             -> estat dels contenidors permesos
  GET  /logs?container=X&tail=N
  GET  /logfile?name=X&tail=N  -> fitxers de log declarats a la config
  POST /apply                  -> {"services": ["gnb"]}  (docker compose up -d --no-deps)
  POST /project                -> {"accio": "up"|"stop"}  (tot el projecte)
  GET  /subs                   -> subscriptors de MongoDB (sense K/OP/OPc)
  POST /subs                   -> {"accio": "desa", "nou": bool, "sub": {...}} | {"accio": "esborra", "imsi"}
  GET  /voip                   -> estat VoIP (PyHSS) per IMSI, amb avisos de coherència
  POST /voip                   -> {"accio": "alta", "imsi", "msisdn"} | {"accio": "baixa", "imsi"}
  GET  /voip/desplegament      -> contenidors IMS (Kamailio, PyHSS, MySQL...), imatges i feina en curs
  POST /voip/desplegament      -> {"accio": "activa"|"desactiva"}: up/stop dels serveis IMS en segon
                                  pla; en activar, alta VoIP dels abonats amb número de telèfon
  GET  /plmn                   -> diversos PLMN: actiu? fitxers afectats
  POST /plmn                   -> {"activa": true, "valors": {"MCC_2","MNC_2"} | {"PLMN_2"}}
                                  core: amf.yaml, nrf.yaml, amf_init.sh, nrf_init.sh i .env
                                  ràdio: plmn_list i additional_plmns al compose i .env
  GET  /tdd                    -> patró TDD: actiu al docker-compose? valors del .env
  POST /tdd                    -> {"activa": true, "valors": {...}} afegeix les 5 variables al .env
                                  i el bloc tdd_ul_dl_cfg (entre marques) al compose; false els treu
  GET  /ues                    -> UEs vistos a la captura NGAP (només si "ue_capture")
                                  i User-Agents HTTP per IP del UE (ua_capture.py)
  GET  /gnbs                   -> gNB que han fet NG Setup (captura NGAP + /var/lib/agent5g/gnbs.json)
  GET  /estat5g                -> estat en viu de l'AMF i l'SMF (API JSON d'Open5GS: gNB, UEs, sessions PDU)
  GET  /radio_ues              -> mètriques de ràdio per UE del gNB (CQI, RI, MCS, velocitat...)
                                  amb els identificadors NGAP de cada RNTI (log del gNB)
  GET  /audit?tail=N
  GET  /radios                 -> (core) ràdios connectades al core per l'enllaç ràdio -> core
  GET|POST /radio/<id>/<camí>  -> (core) reenvia la petició a aquella ràdio per l'enllaç
  GET  /upf                    -> (core) on és el UPF (dins o separat), PFCP de l'SMF, PCs amb UPF connectats
  POST /upf                    -> (core) {"accio": "separa", "upf_id"|"ip"} | {"accio": "ajunta"} |
                                  {"accio": "auto", "valor": bool}: smf.yaml + compose i recrea l'smf
  GET  /upfs                   -> (core) PCs amb UPF connectats per l'enllaç
  GET|POST /upf/<id>/<camí>    -> (core) reenvia la petició a aquell PC amb UPF
  POST /upf_configura          -> (PC del UPF) {"actiu", "env"}: el core li diu la configuració
  GET  /upf_estat              -> (PC del UPF) contenidor, .env, PFCP i mètriques
  GET  /upf_metriques          -> (PC del UPF) mètriques HTTP del UPF (Prometheus d'Open5GS) + ogstun

Enllaç ràdio -> core: amb "core": "IP_del_core" a la configuració, la ràdio no escolta cap
port; és ella qui obre connexions mTLS cap al port 9544 de l'agent del core (com la gNodeB
amb l'AMF). Al core li és igual la IP de la ràdio. Vegeu la secció "enllaç" més avall.

Només fa servir la biblioteca estàndard de Python (>= 3.8), per instal·lar-lo
sense pip al host. Mai crida cap shell: tots els subprocessos van amb llista d'arguments.
"""
import argparse
import datetime as dt
import ipaddress
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import urllib.error
import urllib.request
from urllib.parse import parse_qs, urlparse

MAX_BODY = 64 * 1024
LINE_RE = re.compile(r'^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*=\s*)(.*?)(\r?)$')
SECRET_RE = re.compile(r'(PASS|SECRET|TOKEN|KEY|PWD)', re.I)
NAME_RE = re.compile(r'^[A-Za-z0-9_.-]{1,128}$')
BACKUP_RE = re.compile(r'^env-\d{8}-\d{6}(-\d+)?\.bak$')

CFG = {}
LOCK = threading.Lock()


def now():
    return dt.datetime.now().astimezone().isoformat(timespec='seconds')


def load_config(path):
    with open(path) as f:
        cfg = json.load(f)
    cfg.setdefault('port', 9543)
    cfg.setdefault('allowed_client_cn', ['panel5g'])
    cfg.setdefault('env_file', '.env')
    cfg.setdefault('compose_files', ['docker-compose.yml'])
    cfg.setdefault('editable_keys', {})
    cfg.setdefault('local_ip_keys', [])
    cfg.setdefault('project_actions', ['up', 'stop'])
    cfg.setdefault('ue_capture', None)
    cfg.setdefault('containers', [])
    cfg.setdefault('services', [])
    cfg.setdefault('log_files', {})
    cfg.setdefault('docker_bin', '/usr/bin/docker')
    cfg.setdefault('max_log_lines', 2000)
    cfg.setdefault('max_backups', 50)
    cfg.setdefault('apply_timeout', 300)
    for k in ('project_dir', 'backup_dir', 'audit_log', 'cert', 'key', 'ca'):
        if k not in cfg:
            sys.exit(f'config: falta "{k}"')
    # "listen": on escolta el panell directament (opcional; null = no escolta). Una ràdio amb
    # "core": "IP_del_core" no escolta res: és ella qui truca al core (enllaç ràdio -> core).
    cfg.setdefault('listen', None)
    if cfg.get('role') == 'core':
        cfg.setdefault('enllac', {'listen': '0.0.0.0', 'port': 9544})
    if not cfg['listen'] and not cfg.get('core') and not cfg.get('enllac'):
        sys.exit('config: cal "listen" (escoltar el panell) o "core" (IP del core, enllaç ràdio -> core)')
    if cfg.get('role') == 'core':            # TAC del core (amf.yaml): un o diversos, separats per comes
        cfg['editable_keys'].setdefault('TAC', TAC_RE_TXT)
        # La IP del core només es canvia per terminal (sudo agent5g): regenera certificats,
        # codis d'emparellament i reinicia el core i el panell. Des del panell, només lectura.
        for k in ('DOCKER_HOST_IP', 'UPF_ADVERTISE_IP'):
            cfg['editable_keys'].pop(k, None)
    cfg['_editable'] = {k: re.compile(v) for k, v in cfg['editable_keys'].items()}
    # contenidors IMS: es poden veure (estat i logs) si la VoIP és permesa en aquest equip
    v = cfg.get('voip') or {}
    if v.get('permes', cfg.get('role') == 'core'):
        extra = [c for c in v.get('serveis', VOIP_SERVEIS) if c not in cfg['containers']]
        cfg['containers'] = cfg['containers'] + extra
        cfg['_voip_containers'] = set(extra)
    else:
        cfg['_voip_containers'] = set()
    cfg['_env_path'] = os.path.join(cfg['project_dir'], cfg['env_file'])
    os.makedirs(cfg['backup_dir'], mode=0o700, exist_ok=True)
    os.makedirs(os.path.dirname(cfg['audit_log']) or '.', mode=0o700, exist_ok=True)
    return cfg


# ---------------------------------------------------------------- .env
def read_env():
    out = {}
    with open(CFG['_env_path']) as f:
        for line in f:
            m = LINE_RE.match(line.rstrip('\n'))
            if m:
                out[m.group(2)] = m.group(4)
    return out


def public_env():
    env = read_env()
    res = {}
    for k, v in env.items():
        hidden = SECRET_RE.search(k) and k not in CFG['_editable']
        res[k] = {'value': '***' if hidden else v, 'editable': k in CFG['_editable']}
    if CFG.get('role') == 'core' and 'TAC' not in res and 'TAC' in CFG['_editable']:
        # el .env no el té: el valor és el que hi ha escrit a amf.yaml (si és un número)
        lit = tac_amf_literal()
        res['TAC'] = {'value': lit or '', 'editable': True, 'font': 'amf.yaml'}
    return res


def backup_env():
    stamp = dt.datetime.now().strftime('%Y%m%d-%H%M%S')
    name = f'env-{stamp}.bak'
    i = 1
    while os.path.exists(os.path.join(CFG['backup_dir'], name)):
        name = f'env-{stamp}-{i}.bak'
        i += 1
    dst = os.path.join(CFG['backup_dir'], name)
    with open(CFG['_env_path'], 'rb') as src, open(dst, 'wb') as out:
        out.write(src.read())
    os.chmod(dst, 0o600)
    baks = sorted(f for f in os.listdir(CFG['backup_dir']) if BACKUP_RE.match(f))
    for old in baks[:-CFG['max_backups']]:
        os.remove(os.path.join(CFG['backup_dir'], old))
    return name


def atomic_write(path, data):
    st = os.stat(path)
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix='.env.', dir=d)
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(data)
        os.chmod(tmp, st.st_mode & 0o777)
        try:
            os.chown(tmp, st.st_uid, st.st_gid)
        except PermissionError:
            pass
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


def is_local_ip(ip):
    """Cert si la IP és d'una interfície d'aquest equip (bind de prova)."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.bind((ip, 0))
        return True
    except OSError:
        return False


def write_env(changes):
    if not isinstance(changes, dict) or not changes:
        raise ValueError('changes buit')
    for k, v in changes.items():
        if k not in CFG['_editable']:
            raise ValueError(f'clau no editable: {k}')
        if not isinstance(v, str) or '\n' in v or '\r' in v:
            raise ValueError(f'valor invàlid per {k}')
        if not CFG['_editable'][k].fullmatch(v):
            raise ValueError(f'{k}={v!r} no compleix el patró permès')
        if k in CFG['local_ip_keys'] and not is_local_ip(v):
            raise ValueError(f'{k}={v} no és cap IP d\'aquest equip')
    with open(CFG['_env_path']) as f:
        lines = f.read().split('\n')
    seen = set()
    old = {}
    for i, line in enumerate(lines):
        m = LINE_RE.match(line)
        if m and m.group(2) in changes:
            k = m.group(2)
            old[k] = m.group(4)
            lines[i] = f'{m.group(1)}{k}{m.group(3)}{changes[k]}{m.group(5)}'
            seen.add(k)
    missing = set(changes) - seen
    tac_core = CFG.get('role') == 'core' and 'TAC' in changes
    if tac_core and 'TAC' in missing:            # .env sense TAC (instal·lacions antigues): s'afegeix
        lines = env_set_managed(lines, {'TAC': changes['TAC']}, TAC_ENV_COMMENT, ('MNC', 'MCC'))
        old['TAC'] = tac_amf_literal()
        missing.discard('TAC')
    if missing:
        raise ValueError(f'claus inexistents al .env: {sorted(missing)}')
    if tac_core:
        files = tac_amf_fitxers()                # amf.yaml (tac: [TAC]) i amf_init.sh (sed de TAC)
        files[CFG['_env_path']] = lines
        baks = _commit(files)
        return baks.get(os.path.basename(CFG['_env_path'])), old
    bak = backup_env()
    atomic_write(CFG['_env_path'], '\n'.join(lines))
    return bak, old


def restore_env(name):
    if not isinstance(name, str) or not BACKUP_RE.match(name):
        raise ValueError('nom de còpia invàlid')
    src = os.path.join(CFG['backup_dir'], name)
    if not os.path.isfile(src):
        raise ValueError('la còpia no existeix')
    with open(src) as f:
        data = f.read()
    bak = backup_env()
    atomic_write(CFG['_env_path'], data)
    return bak


# ---------------------------------------------------------------- patró TDD (ocudu)
# Variables del patró TDD i valors per defecte d'ocudu
# (apps/units/flexible_o_du/o_du_high/du_high/du_high_config.h, tdd_ul_dl_pattern_unit_config)
TDD_KEYS = [('PERIOD_TDD', 'dl_ul_tx_period', 10, 2, 80), ('DL_SLOTS', 'nof_dl_slots', 6, 0, 80),
            ('DL_SYMBOLS', 'nof_dl_symbols', 8, 0, 13), ('UL_SLOTS', 'nof_ul_slots', 3, 0, 80),
            ('UL_SYMBOLS', 'nof_ul_symbols', 0, 0, 13)]
TDD_INI = '# >>> panel5g: patró TDD (l\'afegeix i el treu el panell)'
TDD_FI = '# <<< panel5g: patró TDD'
TDD_ENV_COMMENT = '# Proporció TDD (panel5g)'


def tdd_enabled():
    return CFG.get('tdd', CFG.get('role') == 'radio')


def _compose_path():
    return os.path.join(CFG['project_dir'], CFG['compose_files'][0])


def _tdd_compose_state(lines):
    """(gestionat, manual): bloc del panell present / tdd_ul_dl_cfg escrit a mà."""
    gest = any(l.strip() == TDD_INI for l in lines)
    manual = any(re.match(r'^\s*tdd_ul_dl_cfg\s*:', l) for l in lines) and not gest
    return gest, manual


def tdd_status():
    if not tdd_enabled():
        raise LookupError
    with open(_compose_path()) as f:
        lines = f.read().split('\n')
    gest, manual = _tdd_compose_state(lines)
    env = read_env()
    return {'compose': CFG['compose_files'][0], 'actiu': gest or manual, 'gestionat': gest, 'manual': manual,
            'env': {k: env.get(k) for k, *_ in TDD_KEYS},
            'defecte': {k: d for k, _, d, *_ in TDD_KEYS},
            'limits': {k: [lo, hi] for k, _, _, lo, hi in TDD_KEYS}}


def _tdd_compose(lines, activa):
    out = []
    skip = False
    for l in lines:                                   # treu el bloc del panell, si hi és
        if l.strip() == TDD_INI:
            skip = True
            continue
        if skip:
            if l.strip() == TDD_FI:
                skip = False
            continue
        out.append(l)
    if skip:
        raise ValueError('bloc TDD del panell sense tancar al compose: revisa\'l a mà')
    if not activa:
        return out
    idx = next((i for i, l in enumerate(out) if re.match(r'^\s*cell_cfg\s*:\s*$', l)), None)
    if idx is None:
        raise ValueError('no trobo "cell_cfg:" al docker-compose')
    base = len(out[idx]) - len(out[idx].lstrip())
    end, ind = len(out), None
    for j in range(idx + 1, len(out)):
        if not out[j].strip():
            continue
        lead = len(out[j]) - len(out[j].lstrip())
        if lead <= base:
            end = j
            break
        if ind is None:
            ind = lead
        last = j
    if ind is None:
        raise ValueError('"cell_cfg:" està buit al docker-compose')
    sp = ' ' * ind
    bloc = [sp + TDD_INI, sp + 'tdd_ul_dl_cfg:']
    bloc += [f'{sp}  {yk}: ${{{ek}}}' for ek, yk, *_ in TDD_KEYS]
    bloc.append(sp + TDD_FI)
    pos = last + 1
    return out[:pos] + bloc + out[pos:]


def _tdd_env(lines, valors):
    keys = [k for k, *_ in TDD_KEYS]
    coment = re.compile(r'^#\s*Pro\w*ci[oó] TDD', re.I)      # també el "#Propoció TDD" escrit a mà
    out = []
    for l in lines:
        m = LINE_RE.match(l)
        if m and m.group(2) in keys:
            continue
        if coment.match(l.strip()):
            if out and not out[-1].strip():
                out.pop()                                   # la línia en blanc d'abans del bloc
            continue
        out.append(l)
    if valors is None:
        return out
    # després de l'última clau de ràdio coneguda (MIMO), o al final
    anchors = ('TX_ANTENA', 'RX_ANTENA', 'PCI', 'SRATE', 'SCS', 'BANDWIDTH_MHZ')
    pos = None
    for i, l in enumerate(out):
        m = LINE_RE.match(l)
        if m and m.group(2) in anchors:
            pos = i
    pos = len(out) if pos is None else pos + 1
    bloc = ['', TDD_ENV_COMMENT] + [f'{k}={valors[k]}' for k in keys]
    return out[:pos] + bloc + out[pos:]


def _backup_file(path, prefix):
    stamp = dt.datetime.now().strftime('%Y%m%d-%H%M%S')
    dst, i = os.path.join(CFG['backup_dir'], f'{prefix}-{stamp}.bak'), 1
    while os.path.exists(dst):
        dst, i = os.path.join(CFG['backup_dir'], f'{prefix}-{stamp}-{i}.bak'), i + 1
    with open(path, 'rb') as a, open(dst, 'wb') as b:
        b.write(a.read())
    os.chmod(dst, 0o600)
    return os.path.basename(dst)


def tdd_set(activa, valors):
    if not tdd_enabled():
        raise LookupError
    if not isinstance(activa, bool):
        raise ValueError('"activa" ha de ser true/false')
    net = None
    if activa:
        if not isinstance(valors, dict):
            raise ValueError('falten els valors TDD')
        net = {}
        for k, _, d, lo, hi in TDD_KEYS:
            v = str(valors.get(k, d)).strip()
            if not re.fullmatch(r'[0-9]{1,2}', v) or not lo <= int(v) <= hi:
                raise ValueError(f'{k}={v!r} fora de rang ({lo}-{hi})')
            net[k] = str(int(v))
        p, dls, uls = int(net['PERIOD_TDD']), int(net['DL_SLOTS']), int(net['UL_SLOTS'])
        if dls + uls > p:
            raise ValueError('DL_SLOTS + UL_SLOTS supera PERIOD_TDD')
    cpath = _compose_path()
    with open(cpath) as f:
        clines = f.read().split('\n')
    gest, manual = _tdd_compose_state(clines)
    if manual:
        raise ValueError('el docker-compose ja té un tdd_ul_dl_cfg escrit a mà: treu-lo o '
                         'deixa\'l i edita només els valors del .env')
    with open(CFG['_env_path']) as f:
        elines = f.read().split('\n')
    new_c = _tdd_compose(clines, activa)
    new_e = _tdd_env(elines, net)
    bak_e = backup_env()
    bak_c = _backup_file(cpath, 'compose')
    atomic_write(CFG['_env_path'], '\n'.join(new_e))
    atomic_write(cpath, '\n'.join(new_c))
    return {'backup_env': bak_e, 'backup_compose': bak_c, 'activa': activa, 'valors': net}


# ---------------------------------------------------------------- blocs gestionats (marques)
def _mk(ident, ind):
    return f'{ind}# >>> panel5g: {ident}', f'{ind}# <<< panel5g: {ident}'


def strip_blocks(lines, ident):
    out, skip = [], False
    for l in lines:
        t = l.strip()
        if t == f'# >>> panel5g: {ident}':
            skip = True
            continue
        if skip:
            if t == f'# <<< panel5g: {ident}':
                skip = False
            continue
        out.append(l)
    if skip:
        raise ValueError(f'bloc "{ident}" sense tancar: revisa el fitxer a mà')
    return out


def has_block(lines, ident):
    return any(l.strip() == f'# >>> panel5g: {ident}' for l in lines)


def _indent(l):
    return len(l) - len(l.lstrip())


def dup_first_item(lines, key_rx, repl, ident, start=0):
    """Duplica el primer element de la llista YAML que penja de key_rx, aplicant-hi repl
    (llista de (vell, nou)), i l'insereix just després entre marques."""
    k = next((i for i in range(start, len(lines)) if re.match(key_rx, lines[i])), None)
    if k is None:
        raise ValueError(f'no trobo {key_rx!r}')
    a = next((i for i in range(k + 1, len(lines)) if lines[i].strip()), None)
    if a is None or not lines[a].lstrip().startswith('- '):
        raise ValueError(f'{key_rx!r} no és una llista')
    ind = _indent(lines[a])
    b = len(lines)
    for j in range(a + 1, len(lines)):
        if lines[j].strip() and _indent(lines[j]) <= ind:
            b = j
            break
    while b > a + 1 and not lines[b - 1].strip():
        b -= 1
    item = lines[a:b]
    if '# >>> panel5g' in '\n'.join(item):
        raise ValueError('el primer element ja és un bloc del panell')
    nou = []
    for l in item:
        for old, new in repl:
            l = re.sub(re.escape(old) + r'(?![A-Za-z0-9_])', lambda _m, n=new: n, l)
        nou.append(l)
    if nou == item:
        raise ValueError(f'el primer element de {key_rx!r} no té el que s\'esperava ({repl[0][0]})')
    ini, fi = _mk(ident, ' ' * ind)
    return lines[:b] + [ini] + nou + [fi] + lines[b:]


def insert_after(lines, rx, block, ident, keep_indent=True):
    i = next((n for n, l in enumerate(lines) if re.match(rx, l)), None)
    if i is None:
        raise ValueError(f'no trobo {rx!r}')
    ind = ' ' * _indent(lines[i]) if keep_indent else ''
    ini, fi = _mk(ident, ind)
    return lines[:i + 1] + [ini] + [ind + b for b in block] + [fi] + lines[i + 1:]


def env_set_managed(lines, values, comment, after_keys):
    """Posa claus al .env. Si ja hi eren, en canvia el valor (i es queden en desactivar);
    si no, les afegeix sota un comentari del panell (i es treuen en desactivar)."""
    out = list(lines)
    pending = dict(values)
    for i, l in enumerate(out):
        m = LINE_RE.match(l)
        if m and m.group(2) in pending:
            out[i] = f'{m.group(1)}{m.group(2)}{m.group(3)}{pending.pop(m.group(2))}{m.group(5)}'
    if pending:
        pos = None
        for i, l in enumerate(out):
            m = LINE_RE.match(l)
            if m and m.group(2) in after_keys:
                pos = i
        pos = len(out) if pos is None else pos + 1
        out = out[:pos] + [comment] + [f'{k}={v}' for k, v in pending.items()] + out[pos:]
    return out


def env_unset_managed(lines, keys, comment):
    out, i = [], 0
    while i < len(lines):
        if lines[i].strip() == comment:
            i += 1
            while i < len(lines) and LINE_RE.match(lines[i]) and LINE_RE.match(lines[i]).group(2) in keys:
                i += 1
            continue
        out.append(lines[i])
        i += 1
    return out


def _read_lines(path):
    with open(path) as f:
        return f.read().split('\n')


def _commit(files):
    """files: {path: noves_línies}. Còpia de cadascun i escriptura atòmica."""
    baks = {}
    for path, lines in files.items():
        if path == CFG['_env_path']:
            baks[os.path.basename(path)] = backup_env()
        else:
            baks[os.path.relpath(path, CFG['project_dir'])] = _backup_file(
                path, re.sub(r'[^A-Za-z0-9]+', '_', os.path.relpath(path, CFG['project_dir'])))
    for path, lines in files.items():
        atomic_write(path, '\n'.join(lines))
    return baks


# ---------------------------------------------------------------- TAC del core (amf.yaml)
# A docker_open5gs l'AMF llegeix el TAC de amf/amf.yaml (llista "tai"). La versió actual hi
# té "tac: TAC" i amf_init.sh el substitueix pel TAC del .env; versions antigues hi tenen el
# número escrit i/o no tenen TAC al .env. En desar el TAC des del panell es deixa sempre així:
#   amf.yaml      tac: [TAC]          (llista: admet un TAC o diversos, "1,2,3", un per gNB)
#   amf_init.sh   sed -i 's|TAC|'$TAC'|g' ...   (s'afegeix entre marques si no hi és)
#   .env          TAC=1  o  TAC=1,2
# i cal recrear l'AMF. El TAC és de 24 bits (0-16777215).
TAC_RE_TXT = r'^[0-9]{1,8}(,[0-9]{1,8}){0,15}$'
TAC_ID = 'TAC'
TAC_ENV_COMMENT = '# TAC de l\'AMF (panel5g)'
TAC_LINE = re.compile(r'^(\s*)tac:\s*(TAC|\[\s*TAC\s*\]|\[?\s*[0-9]+(\s*,\s*[0-9]+)*\s*\]?)\s*(#.*)?$')


def _amf_paths():
    pd = CFG['project_dir']
    return os.path.join(pd, 'amf', 'amf.yaml'), os.path.join(pd, 'amf', 'amf_init.sh')


def tac_amf_literal():
    """TAC escrit a mà a amf.yaml (p. ex. "1" o "1,2"), o None si fa servir TAC del .env."""
    try:
        lines = _read_lines(_amf_paths()[0])
    except OSError:
        return None
    for l in lines:
        m = TAC_LINE.match(l)
        if m and 'TAC' not in m.group(2):
            return re.sub(r'[\s\[\]]', '', m.group(2))
    return None


def tac_amf_fitxers():
    """Línies noves de amf.yaml i amf_init.sh perquè l'AMF agafi el TAC del .env."""
    yml, init = _amf_paths()
    out = {}
    a = _read_lines(yml)
    n = [TAC_LINE.sub(lambda m: f'{m.group(1)}tac: [TAC]', l) for l in a]
    if not any(TAC_LINE.match(l) for l in a):
        raise ValueError('no trobo cap "tac:" a amf/amf.yaml')
    if n != a:
        out[yml] = n
    i = _read_lines(init)
    if not any(re.match(r"^\s*sed -i 's\|TAC\|'\$TAC'\|g'", l) for l in i):
        out[init] = insert_after(i, r'^cp /mnt/amf/amf\.yaml', [
            "sed -i 's|TAC|'$TAC'|g' install/etc/open5gs/amf.yaml"], TAC_ID)
    return out


# ---------------------------------------------------------------- diversos PLMN
PLMN_ID = 'multi-PLMN'
PLMN_ENV_COMMENT = '# PLMN addicional (panel5g)'


def _plmn_paths():
    pd = CFG['project_dir']
    if CFG.get('role') == 'core':
        return {'amf': os.path.join(pd, 'amf', 'amf.yaml'), 'amf_init': os.path.join(pd, 'amf', 'amf_init.sh'),
                'nrf': os.path.join(pd, 'nrf', 'nrf.yaml'), 'nrf_init': os.path.join(pd, 'nrf', 'nrf_init.sh')}
    return {'compose': _compose_path()}


def plmn_status():
    paths = _plmn_paths()
    estat = {}
    for k, pth in paths.items():
        try:
            estat[k] = has_block(_read_lines(pth), PLMN_ID)
        except OSError:
            estat[k] = None
    env = read_env()
    keys = ['MCC_2', 'MNC_2'] if CFG.get('role') == 'core' else ['PLMN_2']
    actiu = all(estat.values()) and bool(estat)
    return {'rol': CFG.get('role'), 'actiu': actiu, 'parcial': any(estat.values()) and not actiu,
            'fitxers': {k: os.path.relpath(p, CFG['project_dir']) for k, p in paths.items()},
            'estat_fitxers': estat, 'env': {k: env.get(k) for k in keys},
            'plmn1': (env.get('MCC', '') + env.get('MNC', '')) if CFG.get('role') == 'core' else env.get('PLMN_1')}


def plmn_set(activa, valors):
    if not isinstance(activa, bool):
        raise ValueError('"activa" ha de ser true/false')
    role = CFG.get('role')
    paths = _plmn_paths()
    cur = {k: _read_lines(p) for k, p in paths.items()}
    elines = _read_lines(CFG['_env_path'])
    new = {k: strip_blocks(v, PLMN_ID) for k, v in cur.items()}
    keys = ['MCC_2', 'MNC_2'] if role == 'core' else ['PLMN_2']
    new_env = env_unset_managed(elines, keys, PLMN_ENV_COMMENT)
    vals = None
    if activa:
        if not isinstance(valors, dict):
            raise ValueError('falten els valors del PLMN 2')
        if role == 'core':
            mcc, mnc = str(valors.get('MCC_2', '')).strip(), str(valors.get('MNC_2', '')).strip()
            if not re.fullmatch(r'[0-9]{3}', mcc) or not re.fullmatch(r'[0-9]{2,3}', mnc):
                raise ValueError('MCC_2 ha de tenir 3 xifres i MNC_2, 2 o 3')
            vals = {'MCC_2': mcc, 'MNC_2': mnc}
            r = [('mcc: MCC', 'mcc: MCC_2'), ('mnc: MNC', 'mnc: MNC_2')]
            a = new['amf']
            a = dup_first_item(a, r'^\s*guami\s*:\s*$', r + [('set: 1', 'set: 2')], PLMN_ID)
            a = dup_first_item(a, r'^\s*tai\s*:\s*$', r, PLMN_ID)
            a = dup_first_item(a, r'^\s*plmn_support\s*:\s*$', r, PLMN_ID)
            new['amf'] = a
            new['nrf'] = dup_first_item(new['nrf'], r'^\s*serving\s*:', r, PLMN_ID)
            for nf in ('amf', 'nrf'):
                new[f'{nf}_init'] = insert_after(
                    new[f'{nf}_init'], rf'^cp /mnt/{nf}/{nf}\.yaml', [
                        f"sed -i 's|MCC_2|'$MCC_2'|g' install/etc/open5gs/{nf}.yaml",
                        f"sed -i 's|MNC_2|'$MNC_2'|g' install/etc/open5gs/{nf}.yaml"], PLMN_ID)
            new_env = env_set_managed(new_env, vals, PLMN_ENV_COMMENT, ('MNC', 'MCC'))
        else:
            plmn = str(valors.get('PLMN_2', '')).strip()
            if not re.fullmatch(r'[0-9]{5,6}', plmn):
                raise ValueError('PLMN_2 ha de tenir 5 o 6 xifres (MCC+MNC)')
            vals = {'PLMN_2': plmn}
            c = new['compose']
            c = dup_first_item(c, r'^\s*plmn_list\s*:\s*$', [('${PLMN_1}', '${PLMN_2}')], PLMN_ID)
            c = insert_after(c, r'^\s*plmn:\s*"\$\{PLMN_1\}"\s*$', ['additional_plmns: "${PLMN_2}"'], PLMN_ID)
            new['compose'] = c
            new_env = env_set_managed(new_env, vals, PLMN_ENV_COMMENT, ('PLMN_1',))
    files = {paths[k]: v for k, v in new.items() if v != cur[k]}
    if new_env != elines:
        files[CFG['_env_path']] = new_env
    if not files:
        return {'activa': activa, 'valors': vals, 'copies': {}, 'canvis': []}
    baks = _commit(files)
    return {'activa': activa, 'valors': vals, 'copies': baks,
            'canvis': sorted(os.path.relpath(p, CFG['project_dir']) for p in files)}


# ---------------------------------------------------------------- subscriptors (MongoDB d'Open5GS)
# Tipus segons lib/dbi/subscription.c: si un enter no és int32 (o sqn no és int64), Open5GS
# l'ignora en silenci. Per això el document es construeix en EJSON canònic i mongosh el
# llegeix amb EJSON.parse(..., {relaxed: false}). Les dades van per stdin, mai per argv.
HEX32 = re.compile(r'^[0-9A-Fa-f]{32}$')
SUB_MARK = 'P5:'


def I32(n):
    return {'$numberInt': str(int(n))}


def _oid():
    return {'$oid': os.urandom(12).hex()}


def subs_enabled():
    return CFG.get('role') == 'core' and 'mongo' in CFG.get('containers', [])


def _mongo(script, data=None, timeout=30):
    m = CFG.get('mongo') or {}
    cont, db = m.get('container', 'mongo'), m.get('db', 'open5gs')
    if not NAME_RE.match(cont) or not NAME_RE.match(db):
        raise ValueError('config mongo invàlida')
    p = subprocess.run([CFG['docker_bin'], 'exec', '-i', cont, 'mongosh', '--quiet', '--norc', db,
                        '--eval', script], input=json.dumps(data or {}).encode(),
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    out = p.stdout.decode('utf-8', 'replace')
    line = next((l for l in reversed(out.splitlines()) if l.startswith(SUB_MARK)), None)
    if p.returncode != 0 or line is None:
        raise RuntimeError('mongosh: ' + out.strip()[-300:])
    return json.loads(line[len(SUB_MARK):])


_JS_IN = 'const D = EJSON.parse(require("fs").readFileSync(0, "utf8"), {relaxed: false});'
_JS_OUT = 'print("' + SUB_MARK + '" + EJSON.stringify(R, {relaxed: false}));'


def _num(v):
    if isinstance(v, dict):
        for k in ('$numberInt', '$numberLong', '$numberDouble'):
            if k in v:
                return int(float(v[k]))
    return v


def _public_sub(d):
    sec = d.get('security') or {}
    def ambr(a):
        a = a or {}
        return {x: {'value': _num((a.get(x) or {}).get('value')), 'unit': _num((a.get(x) or {}).get('unit'))}
                for x in ('downlink', 'uplink')}
    slices = []
    for sl in d.get('slice') or []:
        ses = []
        for se in sl.get('session') or []:
            q = se.get('qos') or {}
            arp = q.get('arp') or {}
            ue = se.get('ue') or {}
            ses.append({'name': se.get('name'), 'type': _num(se.get('type')), 'qos_index': _num(q.get('index')),
                        'arp_priority': _num(arp.get('priority_level')),
                        'arp_capability': _num(arp.get('pre_emption_capability')),
                        'arp_vulnerability': _num(arp.get('pre_emption_vulnerability')),
                        'ambr': ambr(se.get('ambr')), 'ipv4': ue.get('ipv4'), 'ipv6': ue.get('ipv6'),
                        'pcc_rules': len(se.get('pcc_rule') or [])})
        slices.append({'sst': _num(sl.get('sst')), 'sd': sl.get('sd'),
                       'default_indicator': bool(sl.get('default_indicator')), 'sessions': ses})
    return {'imsi': d.get('imsi'), 'msisdn': d.get('msisdn') or [], 'imeisv': d.get('imeisv') or [],
            'ambr': ambr(d.get('ambr')), 'slices': slices,
            'subscriber_status': _num(d.get('subscriber_status')),
            'operator_determined_barring': _num(d.get('operator_determined_barring')),
            'security': {'amf': sec.get('amf'), 'te_k': bool(sec.get('te_k') or sec.get('k')),
                         'te_opc': bool(sec.get('te_opc') or sec.get('opc')),
                         'te_op': bool(sec.get('te_op') or sec.get('op')), 'sqn': _num(sec.get('sqn'))}}


def subs_list():
    if not subs_enabled():
        raise LookupError
    # les claus no surten mai del contenidor: només se'n torna si n'hi ha
    js = ('const R = db.subscribers.find({}).sort({imsi: 1}).limit(2000).toArray().map(d => {'
          'const s = d.security || {}; d.security = {amf: s.amf, sqn: s.sqn, '
          'te_k: !!s.k, te_opc: !!s.opc, te_op: !!s.op}; return d; });' + _JS_OUT)
    return [_public_sub(d) for d in _mongo(js)]


def _ambr_doc(a, camp):
    if not isinstance(a, dict):
        raise ValueError(f'{camp}: AMBR invàlid')
    out = {}
    for x in ('downlink', 'uplink'):
        v = a.get(x) or {}
        val, unit = v.get('value'), v.get('unit')
        if not isinstance(val, int) or not 0 <= val < 2 ** 31 or unit not in (0, 1, 2, 3, 4):
            raise ValueError(f'{camp}.{x}: valor 0..2147483647 i unitat 0-4 (bps, Kbps, Mbps, Gbps, Tbps)')
        out[x] = {'value': I32(val), 'unit': I32(unit)}
    return out


def _build_sub(s, old=None):
    """Valida el que ve del panell i construeix el document (EJSON canònic)."""
    if not isinstance(s, dict):
        raise ValueError('subscriptor invàlid')
    imsi = str(s.get('imsi', ''))
    if not re.fullmatch(r'[0-9]{6,15}', imsi):
        raise ValueError('IMSI: 6-15 xifres')
    msisdn = s.get('msisdn') or []
    if not isinstance(msisdn, list) or len(msisdn) > 2 or not all(
            isinstance(x, str) and re.fullmatch(r'[0-9]{1,15}', x) for x in msisdn):
        raise ValueError('MSISDN: fins a 2, només xifres')
    sec_old = (old or {}).get('security') or {}
    k, opc, op = (_norm(s.get(x)) for x in ('k', 'opc', 'op'))
    amf = str(s.get('amf') or sec_old.get('amf') or '8000').strip()
    for nom, v in (('K', k), ('OPc', opc), ('OP', op)):
        if v and not HEX32.match(v):
            raise ValueError(f'{nom}: 32 xifres hexadecimals')
    if not re.fullmatch(r'[0-9A-Fa-f]{4}', amf):
        raise ValueError('AMF: 4 xifres hexadecimals')
    if opc and op:
        raise ValueError('Posa OPc o OP, no tots dos')
    sec = dict(sec_old)
    # mateix format que la WebUI (grups de 8 amb espais), perquè tots els abonats quedin iguals
    if k:
        sec['k'] = _webui_hex(k)
    if opc:
        sec['opc'], sec['op'] = _webui_hex(opc), None
    if op:
        sec['op'], sec['opc'] = _webui_hex(op), None
    sec['amf'] = amf.upper()
    if not sec.get('k') or not (sec.get('opc') or sec.get('op')):
        raise ValueError('Un subscriptor nou necessita K i OPc (o OP)')
    status = s.get('subscriber_status', 0)
    if status not in (0, 1):
        raise ValueError('estat: 0 (servei concedit) o 1 (barrat)')
    slices_in = s.get('slices')
    if not isinstance(slices_in, list) or not 1 <= len(slices_in) <= 8:
        raise ValueError('Cal entre 1 i 8 slices')
    # sessions antigues (per conservar pcc_rule, smf i _id) per (sst, sd, dnn)
    vell, vell_sl = {}, {}
    for sl in (old or {}).get('slice') or []:
        vell_sl[(_num(sl.get('sst')), sl.get('sd'))] = sl
        for se in sl.get('session') or []:
            vell[(_num(sl.get('sst')), sl.get('sd'), se.get('name'))] = se
    slices, defs, vistos = [], 0, set()
    for i, sl in enumerate(slices_in):
        sst, sd = sl.get('sst'), (sl.get('sd') or None)
        if not isinstance(sst, int) or not 1 <= sst <= 255:
            raise ValueError(f'slice {i + 1}: SST 1-255')
        if sd is not None:
            sd = str(sd).lower()
            if not re.fullmatch(r'[0-9a-f]{6}', sd):
                raise ValueError(f'slice {i + 1}: SD de 6 xifres hexadecimals')
        if (sst, sd) in vistos:
            raise ValueError(f'slice {i + 1}: repetit')
        vistos.add((sst, sd))
        dflt = bool(sl.get('default_indicator'))
        defs += dflt
        ses_in = sl.get('sessions')
        if not isinstance(ses_in, list) or not 1 <= len(ses_in) <= 8:
            raise ValueError(f'slice {i + 1}: entre 1 i 8 DNN')
        sessions, noms = [], set()
        for se in ses_in:
            name = str(se.get('name') or '')
            if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{0,62}', name) or name in noms:
                raise ValueError(f'slice {i + 1}: DNN "{name}" invàlid o repetit')
            noms.add(name)
            # per defecte, els valors de la WebUI i dels teus abonats que funcionen (IPv4, 5QI 9, ARP 8, 1, 1)
            typ, qi = se.get('type', 1), se.get('qos_index', 9)
            pl, cap, vul = se.get('arp_priority', 8), se.get('arp_capability', 1), se.get('arp_vulnerability', 1)
            if typ not in (1, 2, 3):
                raise ValueError(f'{name}: tipus 1 (IPv4), 2 (IPv6) o 3 (IPv4v6)')
            if not isinstance(qi, int) or not 1 <= qi <= 255:
                raise ValueError(f'{name}: 5QI 1-255')
            if not isinstance(pl, int) or not 1 <= pl <= 15 or cap not in (1, 2) or vul not in (1, 2):
                raise ValueError(f'{name}: ARP prioritat 1-15, capacitat i vulnerabilitat 1 o 2')
            old_se = vell.get((sst, sd, name)) or {}
            # es conserven els camps que el panell no edita (lbo_roaming_allowed, smf, ue...)
            doc = {k: v for k, v in old_se.items() if k not in ('ue',)}
            doc.update({'name': name, 'type': I32(typ),
                   'qos': {'index': I32(qi), 'arp': {'priority_level': I32(pl),
                                                     'pre_emption_capability': I32(cap),
                                                     'pre_emption_vulnerability': I32(vul)}},
                   'ambr': _ambr_doc(se.get('ambr'), name),
                   'pcc_rule': old_se.get('pcc_rule') or [], '_id': old_se.get('_id') or _oid()})
            ue = {}
            for fam, rx in (('ipv4', None), ('ipv6', None)):
                v = str(se.get(fam) or '').strip()
                if v:
                    try:
                        ipaddress.ip_address(v)
                    except ValueError:
                        raise ValueError(f'{name}: {fam} invàlida') from None
                    ue[fam] = v
            if ue:
                doc['ue'] = ue
            sessions.append(doc)
        old_sl = vell_sl.get((sst, sd)) or {}
        d = {k: v for k, v in old_sl.items() if k not in ('sd',)}
        d.update({'sst': I32(sst), 'default_indicator': dflt, 'session': sessions,
                  '_id': old_sl.get('_id') or _oid()})
        if sd:
            d['sd'] = sd
        slices.append(d)
    if defs < 1:
        raise ValueError('Com a mínim un slice ha de ser el per defecte')
    base = dict(old or {})
    if not old:
        sec.setdefault('sqn', {'$numberLong': '64'})
        base.update({'_id': _oid(), 'schema_version': I32(1), 'imeisv': [], 'mme_host': [], 'mme_realm': [],
                     'purge_flag': [], 'access_restriction_data': I32(32), 'network_access_mode': I32(0),
                     'subscribed_rau_tau_timer': I32(12), '__v': I32(0)})
    base.update({'imsi': imsi, 'msisdn': msisdn, 'security': sec, 'ambr': _ambr_doc(s.get('ambr'), 'AMBR'),
                 'slice': slices, 'subscriber_status': I32(status),
                 'operator_determined_barring': I32(int(s.get('operator_determined_barring') or 0))})
    return base


def _get_full(imsi):
    js = _JS_IN + 'const R = db.subscribers.findOne({imsi: D.imsi});' + _JS_OUT
    return _mongo(js, {'imsi': imsi})


def subs_save(sub, nou):
    if not subs_enabled():
        raise LookupError
    imsi = str((sub or {}).get('imsi', ''))
    if not re.fullmatch(r'[0-9]{6,15}', imsi):
        raise ValueError('IMSI: 6-15 xifres')
    old = _get_full(imsi)
    if nou and old:
        raise ValueError(f'L\'IMSI {imsi} ja existeix')
    if not nou and not old:
        raise ValueError(f'L\'IMSI {imsi} no existeix')
    doc = _build_sub(sub, old)
    # un número de telèfon només pot ser d'un abonat (si no, les trucades no saben on anar)
    if doc.get('msisdn'):
        dup = _mongo(_JS_IN + 'const R = db.subscribers.find({msisdn: {$in: D.m}, imsi: {$ne: D.imsi}}, '
                     '{imsi: 1, msisdn: 1, _id: 0}).toArray();' + _JS_OUT, {'m': doc['msisdn'], 'imsi': imsi})
        if dup:
            n = next((x for x in doc['msisdn'] if x in (dup[0].get('msisdn') or [])), doc['msisdn'][0])
            raise ValueError(f'El número {n} ja és de l\'abonat {dup[0].get("imsi")}')
    if nou:
        js = _JS_IN + 'db.subscribers.insertOne(D); const R = {ok: 1};' + _JS_OUT
    else:
        js = _JS_IN + 'const r = db.subscribers.replaceOne({imsi: D.imsi}, D); const R = {ok: r.matchedCount};' + _JS_OUT
    r = _mongo(js, doc)
    if not _num(r.get('ok')):
        raise RuntimeError('no s\'ha desat')
    out = {'imsi': imsi, 'nou': nou}
    # VoIP automàtic: si el VoIP del core està actiu, el primer MSISDN és el número de telèfon.
    #   número nou o canviat (o claus canviades) -> alta VoIP (idempotent, sincronitza claus)
    #   sense número però amb VoIP -> baixa VoIP
    info = pyhss_info()
    if info.get('activa'):
        out['voip'] = _voip_sync(imsi, doc, old, info)
    return out


def _voip_sync(imsi, doc, old, info):
    """Mai fa fallar el desat de l'abonat: torna un text amb el que ha fet o l'avís."""
    nums = doc.get('msisdn') or []
    try:
        prev = _hss_get(info, f'/ims_subscriber/ims_subscriber_imsi/{imsi}', 'ims_subscriber_id')
        if nums:
            sec_n, sec_o = doc.get('security') or {}, (old or {}).get('security') or {}
            claus = any(_norm(sec_n.get(x)) != _norm(sec_o.get(x)) for x in ('k', 'opc', 'amf'))
            if prev and prev.get('msisdn') == nums[0] and not claus:
                return None
            r = voip_alta(imsi, nums[0])
            return f'VoIP {imsi} ↔ {nums[0]}: ' + '; '.join(r['passos'])
        if prev:
            voip_baixa(imsi, info)
            return 'Sense número de telèfon: VoIP donat de baixa a PyHSS'
    except (ValueError, RuntimeError) as e:
        return f'AVÍS VoIP: {_redact(e)}'
    return None


def subs_keys(imsi):
    """K/OPc/OP d'un abonat, només a petició explícita d'un admin (queda a l'auditoria, sense les claus)."""
    if not subs_enabled():
        raise LookupError
    if not re.fullmatch(r'[0-9]{6,15}', str(imsi or '')):
        raise ValueError('IMSI invàlid')
    d = _get_full(str(imsi))
    if not d:
        raise ValueError(f'L\'IMSI {imsi} no existeix')
    sec = d.get('security') or {}
    return {'imsi': imsi, 'k': _norm(sec.get('k')) or None, 'opc': _norm(sec.get('opc')) or None,
            'op': _norm(sec.get('op')) or None, 'amf': _norm(sec.get('amf')) or None}


def subs_delete(imsi):
    if not subs_enabled():
        raise LookupError
    if not re.fullmatch(r'[0-9]{6,15}', str(imsi or '')):
        raise ValueError('IMSI invàlid')
    voip = None
    info = pyhss_info()
    if info.get('activa'):
        try:
            voip = voip_baixa(imsi, info)['passos']
        except ValueError:
            pass        # no tenia VoIP
    r = _mongo(_JS_IN + 'const r = db.subscribers.deleteOne({imsi: D.imsi}); const R = {n: r.deletedCount};' + _JS_OUT,
               {'imsi': imsi})
    if not _num(r.get('n')):
        raise ValueError(f'L\'IMSI {imsi} no existeix')
    return {'imsi': imsi, 'voip': voip}


# ---------------------------------------------------------------- VoIP (IMS: PyHSS + Kamailio)
# Només s'activa si el contenidor pyhss està en marxa (versió VoIP del core).
# PyHSS es fa servir NOMÉS per la seva API REST (la mateixa que documenta docker_open5gs):
# valida, desa l'operation_log i no depèn de l'esquema intern de MySQL.
# Gotxes de PyHSS 1.0.x comprovades amb la teva còpia:
#   * un GET que no troba res torna `null` (amb 200 o 400), no un 404;
#   * els errors porten la SQL sencera, amb Ki/OPc: mai es reenvien tal qual.
#   * ims_subscriber.msisdn és UNIQUE; auc.imsi i subscriber.imsi també.
# Coherència: les K/OPc/AMF de PyHSS (auc) es copien SEMPRE de MongoDB; si no coincideixen,
# el 5G registra però el REGISTER IMS falla (és el que va passar el setembre).
VOIP_APNS = ('internet', 'ims')
# sessió "ims" de MongoDB igual que la dels teus abonats 1001/1002 (i el README de docker_open5gs)
def _ims_session(old=None):
    def br(v):
        return {'downlink': {'value': I32(v), 'unit': I32(1)}, 'uplink': {'value': I32(v), 'unit': I32(1)}}
    def pcc(idx, prio, mbr):
        return {'qos': {'index': I32(idx),
                        'arp': {'priority_level': I32(prio), 'pre_emption_capability': I32(2),
                                'pre_emption_vulnerability': I32(2)},
                        'mbr': br(mbr), 'gbr': br(mbr)},
                'flow': [], '_id': _oid()}
    se = dict(old or {})
    se.update({'name': 'ims', 'type': I32(1),
               'qos': {'index': I32(5), 'arp': {'priority_level': I32(1), 'pre_emption_capability': I32(1),
                                                'pre_emption_vulnerability': I32(1)}},
               'ambr': {'downlink': {'value': I32(3850), 'unit': I32(1)},
                        'uplink': {'value': I32(1530), 'unit': I32(1)}},
               '_id': se.get('_id') or _oid()})
    if not se.get('pcc_rule'):
        se['pcc_rule'] = [pcc(1, 2, 128), pcc(2, 4, 512)]
    return se


def _redact(txt):
    txt = str(txt or '')
    txt = txt.split('[SQL')[0].split('[parameters')[0]
    return HEX32.sub('<clau>', re.sub(r'[0-9A-Fa-f]{32}', '<clau>', txt)).strip()[:300]


def pyhss_info():
    """Estat del contenidor pyhss i dominis IMS, tal com els calcula pyhss_init.sh."""
    try:
        p = subprocess.run([CFG['docker_bin'], 'inspect', 'pyhss'], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=15)
        d = json.loads(p.stdout or b'[]')[0] if p.returncode == 0 else None
    except (subprocess.SubprocessError, ValueError, IndexError, OSError):
        d = None
    if not d:
        return {'activa': False, 'motiu': 'no hi ha contenidor pyhss (versió sense VoIP)'}
    env = dict(x.split('=', 1) for x in (d.get('Config') or {}).get('Env') or [] if '=' in x)
    running = bool((d.get('State') or {}).get('Running'))
    mcc, mnc = env.get('MCC', ''), env.get('MNC', '')
    out = {'activa': running, 'mcc': mcc, 'mnc': mnc}
    if not running:
        out['motiu'] = 'el contenidor pyhss està aturat'
    if not (re.fullmatch(r'[0-9]{3}', mcc) and re.fullmatch(r'[0-9]{2,3}', mnc)):
        out.update(activa=False, motiu='MCC/MNC del contenidor pyhss invàlids')
        return out
    dom = f'ims.mnc{mnc if len(mnc) == 3 else "0" + mnc}.mcc{mcc}.3gppnetwork.org'
    api = (CFG.get('pyhss') or {}).get('api')
    if not api:
        ip = env.get('PYHSS_IP', '')
        try:
            ipaddress.ip_address(ip)
        except ValueError:
            ip = '127.0.0.1'
        api = f'http://{ip}:8080'
    out.update(domini=dom, api=api, scscf=f'sip:scscf.{dom}:6060', scscf_peer=f'scscf.{dom}')
    return out


def _hss(info, method, path, body=None, timeout=15):
    """Crida l'API de PyHSS. Torna el JSON, o None si PyHSS diu que no hi ha res."""
    import urllib.request
    import urllib.error
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(info['api'] + path, data=data, method=method,
                                 headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            j = json.loads(raw or b'null')
        except ValueError:
            j = None
        if j is None and method == 'GET':
            return None
        reason = (j or {}).get('reason') if isinstance(j, dict) else None
        raise RuntimeError(f'PyHSS {method} {path.split("?")[0]}: {_redact(reason) or e.code}') from None
    except (urllib.error.URLError, OSError) as e:
        raise RuntimeError(f'PyHSS no respon a {info["api"]} ({type(e).__name__})') from None
    try:
        j = json.loads(raw or b'null')
    except ValueError:
        raise RuntimeError(f'PyHSS {method} {path}: resposta no JSON') from None
    if isinstance(j, dict) and j.get('result') == 'Failed':
        raise RuntimeError(f'PyHSS {method} {path.split("?")[0]}: {_redact(j.get("reason"))}')
    return j


def _hss_get(info, path, idkey):
    j = _hss(info, 'GET', path)
    return j if isinstance(j, dict) and j.get(idkey) is not None else None


def _hss_all(info, kind):
    out, page = [], 0
    while page < 100:
        j = _hss(info, 'GET', f'/{kind}/list?page={page}&page_size=200')
        if not isinstance(j, list):
            break
        out += [x for x in j if isinstance(x, dict)]
        if len(j) < 200:
            break
        page += 1
    return out


def _mongo_keys():
    """{imsi: (k, opc, op, amf, msisdn, te_ims)} de MongoDB. Les claus es queden a l'agent."""
    js = ('const R = db.subscribers.find({}, {imsi: 1, msisdn: 1, security: 1, "slice.session.name": 1})'
          '.toArray().map(d => [d.imsi, (d.security || {}).k || null, (d.security || {}).opc || null, '
          '(d.security || {}).op || null, (d.security || {}).amf || null, d.msisdn || [], '
          '(d.slice || []).some(s => (s.session || []).some(x => x.name === "ims"))]);' + _JS_OUT)
    return {r[0]: r[1:] for r in _mongo(js) if r and r[0]}


def _norm(x):
    # la WebUI d'Open5GS desa K/OPc en grups de 8 amb espais ("465B5CE8 B199B49F ..."); PyHSS, sense
    return re.sub(r'\s+', '', str(x or '')).upper()


def _webui_hex(x):
    x = _norm(x)
    return ' '.join(x[i:i + 8] for i in range(0, len(x), 8))


def voip_status():
    if not subs_enabled():
        raise LookupError
    info = pyhss_info()
    if not info.get('activa'):
        return {'info': info, 'abonats': []}
    m = _mongo_keys()
    aucs = {a.get('imsi'): a for a in _hss_all(info, 'auc')}
    subs = {s.get('imsi'): s for s in _hss_all(info, 'subscriber')}
    ims = {s.get('imsi'): s for s in _hss_all(info, 'ims_subscriber')}
    apn_ids = {}
    for a in sorted(_hss_all(info, 'apn'), key=lambda a: a.get('apn_id') or 0):
        apn_ids.setdefault((a.get('apn') or '').lower(), a.get('apn_id'))   # el més antic, com l'alta
    rows = []
    for imsi in sorted(set(ims) | set(subs) | set(aucs)):
        a, s, i, mo = aucs.get(imsi), subs.get(imsi), ims.get(imsi), m.get(imsi)
        avisos = []
        if not mo:
            avisos.append('No existeix a Open5GS (MongoDB): el 5G no el deixarà registrar.')
        else:
            k, opc, op, amf = mo[0], mo[1], mo[2], mo[3]
            if a and (_norm(a.get('ki')) != _norm(k) or _norm(a.get('opc')) != _norm(opc or '')
                      or _norm(a.get('amf')) != _norm(amf)):
                avisos.append('Les K/OPc/AMF de PyHSS no coincideixen amb les d\'Open5GS: '
                              'el REGISTER IMS fallarà. Torna a fer l\'alta VoIP per sincronitzar-les.')
            if not mo[5]:
                avisos.append('A Open5GS li falta la sessió (DNN) "ims".')
            if i and i.get('msisdn') and i.get('msisdn') not in (mo[4] or []):
                avisos.append('El número d\'Open5GS (MSISDN) no és el mateix que el de l\'IMS.')
        if not a:
            avisos.append('Falta l\'AuC a PyHSS.')
        if not s:
            avisos.append('Falta el subscriber a PyHSS.')
        elif s:
            ids = {x.strip() for x in str(s.get('apn_list') or '').split(',')}
            if apn_ids.get('ims') is None or str(apn_ids.get('ims')) not in ids:
                avisos.append('El subscriber de PyHSS no té l\'APN ims a apn_list.')
        if not i:
            avisos.append('Falta l\'IMS subscriber a PyHSS (sense número).')
        if not imsi.startswith(info['mcc'] + info['mnc']):
            avisos.append(f'L\'IMSI no és del PLMN del core IMS ({info["mcc"]}{info["mnc"]}): '
                          f'el mòbil buscarà un altre domini IMS.')
        rows.append({'imsi': imsi, 'msisdn': (i or {}).get('msisdn') or (s or {}).get('msisdn'),
                     'registrat_scscf': (i or {}).get('scscf_timestamp'),
                     'pcscf': (i or {}).get('pcscf_timestamp'),
                     'a_open5gs': bool(mo), 'avisos': avisos, 'ok': not avisos})
    candidats = sorted(x for x in m if x not in ims)
    return {'info': {k: v for k, v in info.items() if k != 'api'}, 'abonats': rows,
            'apns': apn_ids, 'sense_voip': candidats}


def _check_msisdn(n):
    n = str(n or '').strip().lstrip('+')
    if not re.fullmatch(r'[0-9]{1,15}', n):
        raise ValueError('Número: només xifres (1-15)')
    return n


def voip_alta(imsi, msisdn):
    """Alta (o actualització) VoIP d'un abonat que ja existeix a Open5GS. Idempotent."""
    if not subs_enabled():
        raise LookupError
    imsi = str(imsi or '')
    if not re.fullmatch(r'[0-9]{6,15}', imsi):
        raise ValueError('IMSI: 6-15 xifres')
    msisdn = _check_msisdn(msisdn)
    info = pyhss_info()
    if not info.get('activa'):
        raise ValueError(f'VoIP no disponible: {info.get("motiu")}')
    passos = []
    # 1) Open5GS: l'abonat ha d'existir; d'aquí surten K/OPc/AMF
    old = _get_full(imsi)
    if not old:
        raise ValueError(f'L\'IMSI {imsi} no existeix a Open5GS: dona\'l d\'alta primer a Subscriptors.')
    sec = old.get('security') or {}
    k, opc, amf = _norm(sec.get('k')), _norm(sec.get('opc')), _norm(sec.get('amf') or '8000')
    if not HEX32.match(k):
        raise ValueError('L\'abonat no té una K vàlida a Open5GS.')
    if not HEX32.match(opc):
        raise ValueError('L\'abonat té OP i no OPc: PyHSS necessita l\'OPc. Posa l\'OPc a Subscriptors.')
    # 2) número lliure (ims_subscriber.msisdn és UNIQUE)
    other = _hss_get(info, f'/ims_subscriber/ims_subscriber_msisdn/{msisdn}', 'ims_subscriber_id')
    if other and other.get('imsi') != imsi:
        raise ValueError(f'El número {msisdn} ja és de l\'IMSI {other.get("imsi")}.')
    altres_m = _mongo(_JS_IN + 'const R = db.subscribers.find({msisdn: D.m, imsi: {$ne: D.imsi}}, '
                      '{imsi: 1, _id: 0}).toArray().map(x => x.imsi);' + _JS_OUT, {'m': msisdn, 'imsi': imsi})
    if altres_m:
        raise ValueError(f'El número {msisdn} ja el té a Open5GS l\'IMSI {", ".join(altres_m)}.')
    # 3) APN internet i ims a PyHSS (es creen una sola vegada)
    apns = {}
    for a in sorted(_hss_all(info, 'apn'), key=lambda a: a.get('apn_id') or 0):
        apns.setdefault((a.get('apn') or '').lower(), a.get('apn_id'))
    creats = []
    for nom in VOIP_APNS:
        if apns.get(nom) is None:
            r = _hss(info, 'PUT', '/apn/', {'apn': nom, 'apn_ambr_dl': 0, 'apn_ambr_ul': 0})
            if not isinstance(r, dict) or r.get('apn_id') is None:
                raise RuntimeError(f'PyHSS no ha creat l\'APN {nom}')
            apns[nom] = r['apn_id']
            passos.append(f'APN {nom} creat a PyHSS (id {r["apn_id"]})')
    # 4) Open5GS: sessió ims al slice per defecte + MSISDN (el document vell es guarda per desfer)
    new = json.loads(json.dumps(old))
    slices = new.get('slice') or []
    sl = next((x for x in slices if x.get('default_indicator')), slices[0] if slices else None)
    if sl is None:
        raise ValueError('L\'abonat no té cap slice a Open5GS.')
    ses = sl.setdefault('session', [])
    tot = [x for s_ in slices for x in s_.get('session') or []]
    if not any(x.get('name') == 'ims' for x in tot):
        if len(ses) >= 8:
            raise ValueError('El slice per defecte ja té 8 DNN.')
        ses.append(_ims_session())
        passos.append('Afegit el DNN "ims" a Open5GS (5QI 5, 3850/1530 kbps, regles PCC 5QI 1 i 2)')
    # el número VoIP passa a ser el primer MSISDN; el número IMS anterior (si en canvia) es treu
    i_prev = _hss_get(info, f'/ims_subscriber/ims_subscriber_imsi/{imsi}', 'ims_subscriber_id') or {}
    new['msisdn'] = [msisdn] + [x for x in (new.get('msisdn') or [])
                                if x not in (msisdn, i_prev.get('msisdn'))][:1]
    canvi_mongo = new != old
    if canvi_mongo:
        _mongo_replace(new)
        passos.append(f'MSISDN {msisdn} a Open5GS')
    try:
        # 5) AuC: mateixes claus que Open5GS
        a = _hss_get(info, f'/auc/imsi/{imsi}', 'auc_id')
        if a:
            if (_norm(a.get('ki')), _norm(a.get('opc')), _norm(a.get('amf'))) != (k, opc, amf):
                _hss(info, 'PATCH', f'/auc/{int(a["auc_id"])}', {'ki': k, 'opc': opc, 'amf': amf})
                passos.append('K/OPc/AMF de PyHSS sincronitzades amb Open5GS')
            auc_id = int(a['auc_id'])
        else:
            r = _hss(info, 'PUT', '/auc/', {'ki': k, 'opc': opc, 'amf': amf, 'sqn': 0, 'imsi': imsi})
            if not isinstance(r, dict) or r.get('auc_id') is None:
                raise RuntimeError('PyHSS no ha creat l\'AuC')
            auc_id = int(r['auc_id'])
            creats.append(('auc', auc_id))
            passos.append(f'AuC creat a PyHSS (id {auc_id})')
        # 6) subscriber (EPC/IMS): APN per defecte internet, llista internet+ims
        s = _hss_get(info, f'/subscriber/imsi/{imsi}', 'subscriber_id')
        llista = [str(apns['internet']), str(apns['ims'])]
        if s:
            ids = [x.strip() for x in str(s.get('apn_list') or '').split(',') if x.strip()]
            llista = ids + [x for x in llista if x not in ids]
            patch = {'auc_id': auc_id, 'apn_list': ','.join(llista), 'msisdn': msisdn, 'enabled': True}
            if any(s.get(x) != v for x, v in patch.items()):
                _hss(info, 'PATCH', f'/subscriber/{int(s["subscriber_id"])}', patch)
                passos.append('Subscriber de PyHSS actualitzat')
        else:
            r = _hss(info, 'PUT', '/subscriber/', {
                'imsi': imsi, 'enabled': True, 'auc_id': auc_id, 'default_apn': int(apns['internet']),
                'apn_list': ','.join(llista), 'msisdn': msisdn, 'ue_ambr_dl': 0, 'ue_ambr_ul': 0,
                'nam': 0, 'roaming_enabled': True, 'subscribed_rau_tau_timer': 300})
            if not isinstance(r, dict) or r.get('subscriber_id') is None:
                raise RuntimeError('PyHSS no ha creat el subscriber')
            creats.append(('subscriber', int(r['subscriber_id'])))
            passos.append(f'Subscriber creat a PyHSS (id {r["subscriber_id"]})')
        # 7) IMS subscriber: el número de telèfon
        i = _hss_get(info, f'/ims_subscriber/ims_subscriber_imsi/{imsi}', 'ims_subscriber_id')
        if i:
            patch = {'msisdn': msisdn, 'msisdn_list': f'[{msisdn}]'}
            if any(i.get(x) != v for x, v in patch.items()):
                _hss(info, 'PATCH', f'/ims_subscriber/{int(i["ims_subscriber_id"])}', patch)
                passos.append(f'Número de l\'IMS canviat a {msisdn}')
        else:
            r = _hss(info, 'PUT', '/ims_subscriber/', {
                'imsi': imsi, 'msisdn': msisdn, 'msisdn_list': f'[{msisdn}]', 'ifc_path': 'default_ifc.xml',
                'sh_profile': 'string', 'scscf': info['scscf'], 'scscf_realm': info['domini'],
                'scscf_peer': info['scscf_peer']})
            if not isinstance(r, dict) or r.get('ims_subscriber_id') is None:
                raise RuntimeError('PyHSS no ha creat l\'IMS subscriber')
            creats.append(('ims_subscriber', int(r['ims_subscriber_id'])))
            passos.append(f'IMS subscriber creat a PyHSS: {imsi} ↔ {msisdn}')
    except Exception:
        # desfer: el que s'ha creat ara (en ordre invers) i el document de MongoDB
        for kind, oid in reversed(creats):
            try:
                _hss(info, 'DELETE', f'/{kind}/{oid}')
            except RuntimeError:
                pass
        if canvi_mongo:
            try:
                _mongo_replace(old)
            except RuntimeError:
                pass
        raise
    # 8) verificació llegint-ho tot de nou
    a = _hss_get(info, f'/auc/imsi/{imsi}', 'auc_id') or {}
    s = _hss_get(info, f'/subscriber/imsi/{imsi}', 'subscriber_id') or {}
    i = _hss_get(info, f'/ims_subscriber/ims_subscriber_imsi/{imsi}', 'ims_subscriber_id') or {}
    m = _mongo_keys().get(imsi)
    errs = []
    if (_norm(a.get('ki')), _norm(a.get('opc'))) != (k, opc):
        errs.append('AuC')
    if str(apns['ims']) not in str(s.get('apn_list') or '').split(',') or s.get('auc_id') != a.get('auc_id'):
        errs.append('subscriber')
    if i.get('msisdn') != msisdn:
        errs.append('IMS subscriber')
    if not m or not m[5] or msisdn not in (m[4] or []):
        errs.append('Open5GS')
    if errs:
        raise RuntimeError('Verificació fallida a: ' + ', '.join(errs))
    if not passos:
        passos.append('Ja estava tot bé: cap canvi')
    return {'imsi': imsi, 'msisdn': msisdn, 'passos': passos, 'domini': info['domini']}


def voip_baixa(imsi, info=None):
    if not subs_enabled():
        raise LookupError
    imsi = str(imsi or '')
    if not re.fullmatch(r'[0-9]{6,15}', imsi):
        raise ValueError('IMSI invàlid')
    info = info or pyhss_info()
    if not info.get('activa'):
        raise ValueError(f'VoIP no disponible: {info.get("motiu")}')
    passos = []
    # ordre per les claus foranes: ims_subscriber, subscriber (depèn d'auc), auc
    for kind, path, idk in (('ims_subscriber', f'/ims_subscriber/ims_subscriber_imsi/{imsi}', 'ims_subscriber_id'),
                            ('subscriber', f'/subscriber/imsi/{imsi}', 'subscriber_id'),
                            ('auc', f'/auc/imsi/{imsi}', 'auc_id')):
        o = _hss_get(info, path, idk)
        if o:
            _hss(info, 'DELETE', f'/{kind}/{int(o[idk])}')
            passos.append(f'{kind} esborrat de PyHSS')
    if not passos:
        raise ValueError(f'L\'IMSI {imsi} no té VoIP')
    return {'imsi': imsi, 'passos': passos}


def _mongo_replace(doc):
    js = (_JS_IN + 'const r = db.subscribers.replaceOne({_id: D._id, imsi: D.imsi}, D); '
          'const R = {ok: r.matchedCount};' + _JS_OUT)
    if not _num(_mongo(js, doc).get('ok')):
        raise RuntimeError('MongoDB: no s\'ha desat (l\'abonat ha canviat o no existeix)')



# ---------------------------------------------------------------- VoIP: desplegar Kamailio + PyHSS
# Activa la part IMS de docker_open5gs (la mateixa definició que sa-vonr-deploy.yaml) sense
# tocar els contenidors del core 5G: `docker compose -f sa-vonr-deploy.yaml up -d --no-deps`
# NOMÉS dels serveis IMS. Desactivar-la els atura (stop): les dades de MySQL es conserven.
# Les imatges que no tenen "build" al compose (Kamailio) es baixen de ghcr.io i s'etiqueten
# tal com diu el README de docker_open5gs; dns i rtpengine les construeix el compose.
VOIP_SERVEIS = ['dns', 'mysql', 'rtpengine', 'pyhss', 'icscf', 'scscf', 'pcscf', 'smsc']
VOIP_IMATGES = {
    'docker_kamailio': 'ghcr.io/herlesupreeth/docker_kamailio:master',
    'docker_pyhss': 'ghcr.io/herlesupreeth/docker_pyhss:master',
    'docker_mysql': 'ghcr.io/herlesupreeth/docker_mysql:master',
}
VOIP_JOB = {'en_curs': False, 'accio': None, 'inici': None, 'fi': None, 'ok': None,
            'log': deque(maxlen=600)}
VOIP_JOB_LOCK = threading.Lock()


def voip_cfg():
    v = dict(CFG.get('voip') or {})
    v.setdefault('permes', CFG.get('role') == 'core')
    v.setdefault('compose_file', 'sa-vonr-deploy.yaml')
    v.setdefault('serveis', VOIP_SERVEIS)
    v.setdefault('timeout', 1800)
    return v


def _voip_compose():
    v = voip_cfg()
    f = os.path.join(CFG['project_dir'], v['compose_file'])
    args = [CFG['docker_bin'], 'compose', '--project-directory', CFG['project_dir'],
            '--env-file', CFG['_env_path']]
    if CFG.get('compose_project'):
        args += ['-p', CFG['compose_project']]
    return args + ['-f', f], f


def _docker_env():
    # l'agent corre amb ProtectHome=read-only: el client docker (buildx) necessita una carpeta seva
    e = dict(os.environ)
    d = os.path.join(os.path.dirname(CFG['audit_log']) or '/var/lib/agent5g', 'docker-client')
    os.makedirs(d, mode=0o700, exist_ok=True)
    e['DOCKER_CONFIG'] = d
    return e


def voip_desplegament():
    v = voip_cfg()
    if not v['permes']:
        raise LookupError
    _, f = _voip_compose()
    falten = [d for d in v['serveis'] if d != 'mysql' and not os.path.isdir(os.path.join(CFG['project_dir'], d))]
    estat = {}
    for c in v['serveis']:
        rc, out = run([CFG['docker_bin'], 'inspect', '--format', '{{.State.Status}}', c], timeout=15)
        estat[c] = out.strip() if rc == 0 else 'absent'
    imatges = {}
    for img in VOIP_IMATGES:
        rc, _ = run([CFG['docker_bin'], 'image', 'inspect', '--format', '{{.Id}}', img], timeout=15)
        imatges[img] = rc == 0
    en_marxa = [c for c, s in estat.items() if s == 'running']
    with VOIP_JOB_LOCK:
        job = {k: (list(x) if k == 'log' else x) for k, x in VOIP_JOB.items()}
    info = pyhss_info()
    return {'compose_file': v['compose_file'], 'compose_existeix': os.path.isfile(f),
            'carpetes_falten': falten, 'contenidors': estat, 'imatges': imatges,
            'activa': len(en_marxa) == len(v['serveis']), 'parcial': 0 < len(en_marxa) < len(v['serveis']),
            'pyhss': {k: x for k, x in info.items() if k != 'api'}, 'feina': job}


def _jlog(txt):
    with VOIP_JOB_LOCK:
        for l in str(txt).splitlines() or ['']:
            VOIP_JOB['log'].append(f'{dt.datetime.now().strftime("%H:%M:%S")} {_redact_log(l)}')


def _redact_log(l):
    return re.sub(r'[0-9A-Fa-f]{32}', '<clau>', l)[:400]


def _run_log(args, timeout):
    """Executa (sense shell) i va abocant la sortida al registre de la feina."""
    p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=CFG['project_dir'],
                         env=_docker_env())
    t = threading.Timer(timeout, p.kill)
    t.start()
    try:
        for line in iter(p.stdout.readline, b''):
            l = line.decode('utf-8', 'replace').rstrip()
            if l:
                _jlog('  ' + l)
        return p.wait()
    finally:
        t.cancel()


def _voip_espera_pyhss(segons=240):
    import time
    fi = time.time() + segons
    while time.time() < fi:
        info = pyhss_info()
        if info.get('activa'):
            try:
                _hss(info, 'GET', '/apn/list?page=0&page_size=1', timeout=5)
                return info
            except (RuntimeError, OSError):
                pass
        time.sleep(5)
    return None


def voip_provisiona_tots():
    """Alta VoIP de tots els abonats d'Open5GS que tenen número de telèfon (MSISDN)."""
    ok, errs = 0, 0
    for imsi, row in sorted(_mongo_keys().items()):
        nums = row[4] or []
        if not nums:
            continue
        try:
            with LOCK:
                r = voip_alta(imsi, nums[0])
            ok += 1
            _jlog(f'{imsi} ↔ {nums[0]}: ' + '; '.join(r['passos']))
        except (ValueError, RuntimeError) as e:
            errs += 1
            _jlog(f'{imsi} ↔ {nums[0]}: ERROR {_redact(e)}')
    return ok, errs


def _voip_feina(accio):
    v = voip_cfg()
    base, f = _voip_compose()
    ok = False
    try:
        if accio == 'activa':
            _jlog(f'Activant VoIP amb {os.path.basename(f)}: {", ".join(v["serveis"])}')
            for img, ref in VOIP_IMATGES.items():
                rc, _ = run([CFG['docker_bin'], 'image', 'inspect', '--format', '{{.Id}}', img], timeout=15)
                if rc == 0:
                    _jlog(f'Imatge {img}: ja hi és')
                    continue
                _jlog(f'Imatge {img}: baixant {ref}')
                if _run_log([CFG['docker_bin'], 'pull', ref], v['timeout']) == 0:
                    run([CFG['docker_bin'], 'tag', ref, img], timeout=30)
                elif img == 'docker_kamailio':
                    raise RuntimeError('no s\'ha pogut baixar la imatge de Kamailio (cal Internet a ghcr.io)')
                else:
                    _jlog(f'  no s\'ha pogut baixar: el compose la construirà des de ./{img[7:]}')
            _jlog('docker compose up -d --no-deps (els contenidors del core 5G no es toquen)')
            rc = _run_log(base + ['up', '-d', '--no-deps', '--build'] + v['serveis'], v['timeout'])
            if rc != 0:
                raise RuntimeError(f'docker compose up ha fallat (rc={rc})')
            _jlog('Esperant l\'API de PyHSS (port 8080)…')
            if not _voip_espera_pyhss():
                raise RuntimeError('PyHSS no respon: mira el log del contenidor pyhss')
            _jlog('PyHSS respon. Alta VoIP dels abonats amb número de telèfon:')
            n, e = voip_provisiona_tots()
            _jlog(f'Fet: {n} abonats amb VoIP, {e} errors.' if n or e else
                  'Cap abonat té número de telèfon: posa\'l a Subscriptors i es donarà d\'alta sol.')
            ok = e == 0
        else:
            _jlog(f'Aturant VoIP: {", ".join(reversed(v["serveis"]))} (les dades de MySQL es conserven)')
            rc = _run_log(base + ['stop'] + list(reversed(v['serveis'])), v['timeout'])
            ok = rc == 0
            if not ok:
                raise RuntimeError(f'docker compose stop ha fallat (rc={rc})')
            _jlog('Aturat.')
    except Exception as e:  # noqa: BLE001
        _jlog(f'ERROR: {_redact(e) if isinstance(e, (RuntimeError, ValueError)) else type(e).__name__}')
        ok = False
    finally:
        with VOIP_JOB_LOCK:
            VOIP_JOB.update(en_curs=False, fi=now(), ok=ok)


def voip_desplega(accio):
    v = voip_cfg()
    if not v['permes']:
        raise LookupError
    if accio not in ('activa', 'desactiva'):
        raise ValueError('acció invàlida')
    _, f = _voip_compose()
    if accio == 'activa':
        if not os.path.isfile(f):
            raise ValueError(f'Aquesta versió del core no té {v["compose_file"]}: cal la versió amb VoIP (normal+ip).')
        falten = [d for d in v['serveis'] if d != 'mysql' and not os.path.isdir(os.path.join(CFG['project_dir'], d))]
        if falten:
            raise ValueError(f'Falten carpetes de configuració IMS al projecte: {", ".join(falten)}')
    with VOIP_JOB_LOCK:
        if VOIP_JOB['en_curs']:
            raise ValueError('Ja hi ha una operació VoIP en curs')
        VOIP_JOB.update(en_curs=True, accio=accio, inici=now(), fi=None, ok=None)
        VOIP_JOB['log'].clear()
    threading.Thread(target=_voip_feina, args=(accio,), daemon=True).start()
    return {'accio': accio, 'inici': VOIP_JOB['inici']}


# ---------------------------------------------------------------- docker
def run(args, timeout=30):
    p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       timeout=timeout, cwd=CFG['project_dir'])
    return p.returncode, p.stdout.decode('utf-8', 'replace')


def container_status():
    res = []
    for c in CFG['containers']:
        rc, out = run([CFG['docker_bin'], 'inspect', '--format', '{{json .State}}', c])
        if rc != 0:
            if c not in CFG.get('_voip_containers', ()):    # IMS no desplegat: no és cap error
                res.append({'name': c, 'status': 'absent'})
            continue
        try:
            st = json.loads(out.strip())
        except ValueError:
            res.append({'name': c, 'status': 'unknown'})
            continue
        res.append({'name': c, 'status': st.get('Status'), 'running': st.get('Running'),
                    'started_at': st.get('StartedAt'), 'restarting': st.get('Restarting'),
                    'exit_code': st.get('ExitCode'),
                    'health': (st.get('Health') or {}).get('Status')})
    return res


def tail_n(qs):
    try:
        n = int(qs.get('tail', ['200'])[0])
    except ValueError:
        n = 200
    return max(1, min(n, CFG['max_log_lines']))


def container_logs(name, n):
    if name not in CFG['containers']:
        raise ValueError('contenidor no permès')
    rc, out = run([CFG['docker_bin'], 'logs', '--tail', str(n), '--timestamps', name])
    return out


def file_log(name, n):
    path = CFG['log_files'].get(name)
    if not path:
        raise ValueError('fitxer de log no permès')
    if not os.path.isfile(path):
        return ''
    with open(path, 'rb') as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(max(0, size - 4 * 1024 * 1024))
        data = f.read().decode('utf-8', 'replace')
    return '\n'.join(deque(data.splitlines(), maxlen=n))


def apply_services(services):
    if not isinstance(services, list) or not services:
        raise ValueError('services buit')
    for s in services:
        if s not in CFG['services']:
            raise ValueError(f'servei no permès: {s}')
    if 'upf' in services and upf_gestionat() and upf_estat_fitxers()['mode'] == 'remot':
        # UPF separat: anomenar-lo a "up" l'arrencaria igualment (el perfil no l'atura)
        services = [s for s in services if s != 'upf']
        if not services:
            return 0, 'UPF separat: el upf d\'aquest core no s\'arrenca'
    args = compose_base() + ['up', '-d', '--no-deps'] + list(dict.fromkeys(services))
    rc, out = run(args, timeout=CFG['apply_timeout'])
    return rc, out[-8000:]


def compose_base():
    args = [CFG['docker_bin'], 'compose', '--project-directory', CFG['project_dir'],
            '--env-file', CFG['_env_path']]
    if CFG.get('compose_project'):
        args += ['-p', CFG['compose_project']]
    for f in CFG['compose_files']:
        args += ['-f', os.path.join(CFG['project_dir'], f)]
    return args


def project_action(accio):
    if accio not in CFG['project_actions']:
        raise ValueError('acció no permesa')
    extra = {'up': ['up', '-d'], 'stop': ['stop'], 'down': ['down']}[accio]
    rc, out = run(compose_base() + extra, timeout=CFG['apply_timeout'])
    return rc, out[-8000:]


# ---------------------------------------------------------------- UEs (captura NGAP)
# Un servei a part (dumpcap) desa l'N2 en un buffer circular. Aquí només es llegeix
# amb tshark i es treuen els identificadors. L'IMEISV només és llegible si el NAS no
# va xifrat (5G-EA0); si no, es marca com a xifrat.
UE_RX = [
    ('ran', re.compile(r'\bRAN-UE-NGAP-ID: (\d+)')),
    ('amf', re.compile(r'\bAMF-UE-NGAP-ID: (\d+)')),
    ('mcc', re.compile(r'Mobile Country Code \(MCC\): .*?\(?(\d{3})\)?$')),
    ('mnc', re.compile(r'Mobile Network Code \(MNC\): .*?\(?(\d{2,3})\)?$')),
    ('msin', re.compile(r'\bMSIN: (\d+)')),
    ('imeisv', re.compile(r'\bIMEISV: (\d{15,16})')),
    # NGAP InitialContextSetupRequest: en clar, amb els dígits 11-14 emmascarats (ff)
    ('masked', re.compile(r'\bMaskedIMEISV: ([0-9a-fA-F]{16})')),
    ('imei', re.compile(r'\bIMEI: (\d{14,15})')),
    ('tmsi', re.compile(r'5G-TMSI: (0x[0-9a-fA-F]+|\d+)')),
    ('msg', re.compile(r'Message type: (.+?) \(0x[0-9a-fA-F]+\)$')),
    ('dnn', re.compile(r'\bDNN: (\S+)')),
    ('ip', re.compile(r'PDU address information(?: IPv4)?: (\d+\.\d+\.\d+\.\d+)')),
    ('sst', re.compile(r'Slice/service type \(SST\): .*?(\d+)\)?$')),
    ('ea', re.compile(r'Type of ciphering algorithm: (.+)$')),
    ('ts', re.compile(r'Epoch (?:Arrival )?Time: ([\d.]+)')),
]
_UE_CACHE = {'key': None, 'ues': []}


def parse_ues(text):
    """Agrupa els identificadors per UE seguint RAN/AMF-UE-NGAP-ID i, al final, per IMSI."""
    recs, link = {}, {}

    def rec(key):
        return recs.setdefault(key, {'missatges': []})

    def flush(fr):
        if not fr:
            return
        ran, amf = fr.get('ran'), fr.get('amf')
        if ran and amf:
            old = ('ran', ran)
            link[ran] = amf
            if old in recs:                       # fusiona el que s'havia vist només amb RAN-ID
                r = rec(('amf', amf))
                o = recs.pop(old)
                r['missatges'] = o['missatges'] + r['missatges']
                for k, v in o.items():
                    if k != 'missatges':
                        r.setdefault(k, v)
        if amf:
            key = ('amf', amf)
        elif ran:
            key = ('amf', link[ran]) if ran in link else ('ran', ran)
        else:
            return
        r = rec(key)
        for k in ('mcc', 'mnc', 'msin', 'imeisv', 'imei', 'masked', 'tmsi', 'dnn', 'ip', 'sst', 'ea'):
            if fr.get(k):
                r[k] = fr[k]
        if fr.get('ts'):
            r.setdefault('primer', fr['ts'])
            r['darrer'] = fr['ts']
        for m in fr.get('msgs', []):
            if not r['missatges'] or r['missatges'][-1] != m:
                r['missatges'].append(m)

    fr = None
    for line in text.splitlines():
        if line.startswith('Frame '):
            flush(fr)
            fr = {'msgs': []}
            continue
        if fr is None:
            continue
        for k, rx in UE_RX:
            m = rx.search(line)
            if m:
                if k == 'msg':
                    fr['msgs'].append(m.group(1))
                elif k == 'ea' and 'ea' in fr:
                    pass
                else:
                    fr[k] = m.group(1)
    flush(fr)

    per_imsi = {}
    for r in recs.values():
        imsi = (r.get('mcc', '') + r.get('mnc', '') + r['msin']) if r.get('msin') else None
        r['imsi'] = imsi
        r['missatges'] = r['missatges'][-15:]
        key = imsi or r.get('tmsi') or id(r)
        if key in per_imsi:
            prev = per_imsi[key]
            for k, v in r.items():
                if v and (k not in prev or float(r.get('darrer') or 0) >= float(prev.get('darrer') or 0)):
                    prev[k] = v
        else:
            per_imsi[key] = r
    out = list(per_imsi.values())
    for r in out:
        ea = r.get('ea', '')
        r['nas_xifrat'] = bool(ea) and 'EA0' not in ea and 'null' not in ea.lower()
    out.sort(key=lambda r: float(r.get('darrer') or 0), reverse=True)
    return out


SBI_IMSI = re.compile(rb'imsi-(\d{5,15})')
SBI_PEI = re.compile(rb'imeisv-(\d{16})|imei-(\d{15})')


def _tshark(cap, f, args):
    # Ubuntu té un perfil d'AppArmor per a tshark que no el deixa obrir fitxers fora
    # de $HOME/tmp, ni tan sols com a root: l'agent obre el fitxer i el passa per stdin.
    with open(f, 'rb') as fh:
        p = subprocess.run([cap.get('tshark', '/usr/bin/tshark'), '-r', '-', '-n'] + args,
                           stdin=fh, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=60, cwd='/')
    return p.stdout.decode('utf-8', 'replace')


def sbi_pei(cap, f):
    """PEI (IMEISV) que l'AMF envia en clar a l'UDM/SMF per SBI (HTTP/2, JSON sense comprimir).
    El cos porta el SUPI (supi o deregCallbackUri) i el PEI al mateix missatge."""
    port = str(int(cap.get('sbi_port', 7777)))
    out = _tshark(cap, f, ['-Y', f'tcp.port=={port} && frame contains "imei"',
                           '-T', 'fields', '-e', 'tcp.payload'])
    res = {}
    for line in out.splitlines():
        try:
            raw = bytes.fromhex(line.strip().replace(':', ''))
        except ValueError:
            continue
        i, p = SBI_IMSI.search(raw), SBI_PEI.search(raw)
        if i and p:
            res[i.group(1).decode()] = {'imeisv': (p.group(1) or b'').decode() or None,
                                        'imei': (p.group(2) or b'').decode() or None}
    return res


def _store_path(cap):
    return cap.get('store', '/var/lib/agent5g/ues.json')


def load_store(cap):
    try:
        with open(_store_path(cap)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_store(cap, store, path=None):
    path = path or _store_path(cap)
    fd, tmp = tempfile.mkstemp(prefix='.ues.', dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(store, f, ensure_ascii=False, indent=1)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


def remember(store, imsi, ts, **vals):
    """Desa el que és estable del dispositiu (no canvia entre registres) per IMSI."""
    rec = store.setdefault(imsi, {})
    changed = False
    for k, v in vals.items():
        if v and rec.get(k) != v:
            rec[k] = v
            changed = True
    if changed or 'vist' not in rec:
        rec['vist'] = ts or now()
    return changed


def ue_list():
    cap = CFG.get('ue_capture')
    if not cap:
        raise LookupError
    d = cap['dir']
    files = sorted((os.path.join(d, f) for f in os.listdir(d) if '.pcap' in f),
                   key=os.path.getmtime)[-int(cap.get('max_files', 3)):]
    key = tuple((f, os.path.getmtime(f), os.path.getsize(f)) for f in files)
    if key == _UE_CACHE['key']:
        return _UE_CACHE['ues']
    text, pei = [], {}
    # L'AMF pot negociar 5G-EA0: llavors el NAS "xifrat" va en clar i Wireshark el
    # descodifica amb aquesta preferència (Security Mode Complete -> IMEISV, etc.)
    args = ['-o', 'nas-5gs.null_decipher:TRUE', '-Y', 'ngap', '-O', 'frame,ngap,nas-5gs']
    for f in files:
        text.append(_tshark(cap, f, args))
        if cap.get('sbi', True):
            pei.update(sbi_pei(cap, f))
    ues = parse_ues('\n'.join(text))

    with LOCK:
        store = load_store(cap)
        dirty = False
        for u in ues:
            if u.get('imsi'):
                m = (u.get('masked') or '').lower()
                dirty |= remember(store, u['imsi'], None, imeisv=u.get('imeisv'), imei=u.get('imei'),
                                  masked_imeisv=m or None)
        for imsi, v in pei.items():
            dirty |= remember(store, imsi, None, imeisv=v['imeisv'], imei=v['imei'], font_pei='sbi')
        if dirty:
            save_store(cap, store)
    seen = set()
    for u in ues:
        st = store.get(u.get('imsi') or '')
        if st:
            seen.add(u['imsi'])
            for k in ('imeisv', 'imei', 'masked_imeisv'):
                if st.get(k) and not u.get(k):
                    u[k] = st[k]
        if u.get('masked') and not u.get('masked_imeisv'):
            u['masked_imeisv'] = u['masked'].lower()
        u.pop('masked', None)
    for imsi, st in store.items():           # vistos abans però ja fora de la captura
        if imsi not in seen:
            ues.append({'imsi': imsi, 'imeisv': st.get('imeisv'), 'imei': st.get('imei'),
                        'masked_imeisv': st.get('masked_imeisv'), 'missatges': [],
                        'nomes_desat': True, 'vist': st.get('vist')})
    _UE_CACHE.update(key=key, ues=ues)
    return ues


# ---------------------------------------------------------------- gNB (NG Setup)
GNB_RX = [
    ('ts', re.compile(r'Epoch (?:Arrival )?Time: ([\d.]+)')),
    ('ips', re.compile(r'^Internet Protocol Version [46], Src: (\S+), Dst: (\S+)')),
    ('ports', re.compile(r'^Stream Control Transmission Protocol, Src Port: (\d+).*?Dst Port: (\d+)')),
    ('pdu', re.compile(r'NGAP-PDU: (initiatingMessage|successfulOutcome|unsuccessfulOutcome)')),
    ('gnb_id', re.compile(r'gNB-ID: ([0-9a-fA-F]+) \[bit length (\d+).*?decimal value (\d+)')),
    ('nom', re.compile(r'\bRANNodeName: (.+)$')),
    ('mcc', re.compile(r'Mobile Country Code \(MCC\): .*?\(?(\d{3})\)?$')),
    ('mnc', re.compile(r'Mobile Network Code \(MNC\): .*?\(?(\d{2,3})\)?$')),
    ('tac', re.compile(r'\btAC: (\d+)')),
    ('sst', re.compile(r'\bsST: ([0-9a-fA-F]+)')),
    ('sd', re.compile(r'\bsD: ([0-9a-fA-F]+)')),
    ('drx', re.compile(r'\bPagingDRX: (\w+)')),
    ('amf', re.compile(r'\bAMFName: (.+)$')),
    ('capacitat', re.compile(r'\bRelativeAMFCapacity: (\d+)')),
    ('causa', re.compile(r'^\s+(?:radioNetwork|transport|nas|protocol|misc): (\S+)')),
]
_GNB_CACHE = {'key': None, 'gnbs': []}


def parse_gnbs(text):
    """NG Setup Request/Response/Failure -> una fitxa per gNB (clau: IP del gNB)."""
    frames, fr = [], None
    for line in text.splitlines():
        if line.startswith('Frame '):
            fr = {'tacs': [], 'slices': []}
            frames.append(fr)
            continue
        if fr is None:
            continue
        for k, rx in GNB_RX:
            m = rx.search(line)
            if not m:
                continue
            if k == 'ips':
                fr['src'], fr['dst'] = m.groups()
            elif k == 'ports':
                fr['sport'], fr['dport'] = m.groups()
            elif k == 'gnb_id':
                fr['gnb_id'], fr['gnb_bits'] = int(m.group(3)), int(m.group(2))
            elif k == 'tac':
                if m.group(1) not in fr['tacs']:
                    fr['tacs'].append(m.group(1))
            elif k == 'sst':
                fr['slices'].append({'sst': int(m.group(1), 16)})
            elif k == 'sd':
                if fr['slices']:
                    fr['slices'][-1]['sd'] = m.group(1).lower()
            elif k in ('mcc', 'mnc'):
                fr.setdefault(k, m.group(1))
            else:
                fr.setdefault(k, m.group(1).strip())
    gnbs = {}
    for fr in frames:
        ts = float(fr['ts']) if fr.get('ts') else None
        if fr.get('pdu') == 'initiatingMessage':
            ip = fr.get('src')
            if not ip:
                continue
            g = gnbs.setdefault(ip, {'ip': ip, 'setups': []})
            for k in ('gnb_id', 'gnb_bits', 'nom', 'mcc', 'mnc', 'drx'):
                if fr.get(k) is not None:
                    g[k] = fr[k]
            g['port'] = fr.get('sport')
            if fr['tacs']:
                g['tacs'] = fr['tacs']
            uniq = []
            for sl in fr['slices']:
                if sl not in uniq:
                    uniq.append(sl)
            if uniq:
                g['slices'] = uniq
            g['setups'].append({'ts': ts, 'resultat': 'sense resposta'})
        else:
            g = gnbs.get(fr.get('dst'))
            if not g or not g['setups']:
                continue
            st = g['setups'][-1]
            if fr.get('pdu') == 'successfulOutcome':
                st['resultat'] = 'ok'
                for k in ('amf', 'capacitat'):
                    if fr.get(k):
                        g[k] = fr[k]
            else:
                st['resultat'] = 'rebutjat'
                st['causa'] = fr.get('causa')
    for g in gnbs.values():
        g['setups'] = g['setups'][-20:]
    return list(gnbs.values())


def gnb_list():
    cap = CFG.get('ue_capture')
    if not cap:
        raise LookupError
    d = cap['dir']
    files = sorted((os.path.join(d, f) for f in os.listdir(d) if '.pcap' in f),
                   key=os.path.getmtime)[-int(cap.get('max_files', 3)):]
    key = tuple((f, os.path.getmtime(f), os.path.getsize(f)) for f in files)
    if key == _GNB_CACHE['key']:
        return _GNB_CACHE['gnbs']
    args = ['-Y', 'ngap.procedureCode == 21', '-O', 'frame,ngap']
    vistos = parse_gnbs('\n'.join(_tshark(cap, f, args) for f in files))
    f = cap.get('gnb_store', '/var/lib/agent5g/gnbs.json')
    with LOCK:
        try:
            with open(f) as fh:
                store = json.load(fh)
        except (OSError, ValueError):
            store = {}
        for g in vistos:
            old = store.get(g['ip'], {})
            hist = old.get('setups', []) + [s for s in g['setups'] if s not in old.get('setups', [])]
            merged = dict(old, **g)
            merged['setups'] = sorted(hist, key=lambda x: x.get('ts') or 0)[-20:]
            store[g['ip']] = merged
        save_store(cap, store, f)
    out = list(store.values())
    _GNB_CACHE.update(key=key, gnbs=out)
    return out


# ---------------------------------------------------------------- estat en viu (API JSON d'Open5GS)
# Des de la v2.7.7, el servidor de mètriques de l'AMF i de l'SMF (port 9091 a docker_open5gs)
# també serveix /gnb-info i /ue-info (AMF) i /pdu-info (SMF) en JSON. És l'estat que l'AMF i
# l'SMF tenen a memòria: no depèn de la captura ni de quantes línies de log queden.
# Config opcional: "open5gs_api": {"amf": "http://IP:9091", "smf": "http://IP:9091", "port": 9091,
# "timeout": 3}. Per defecte agafa AMF_IP i SMF_IP del .env.
_O5GS = urllib.request.build_opener(urllib.request.ProxyHandler({}))   # mai per un proxy


def _o5gs_base(nf):
    api = CFG.get('open5gs_api') or {}
    if api.get(nf):
        return api[nf].rstrip('/')
    ip = read_env().get(f'{nf.upper()}_IP')
    if not ip:
        raise LookupError(f'{nf.upper()}_IP no és al .env')
    return f'http://{ip}:{int(api.get("port", 9091))}'


def _o5gs_items(nf, path):
    """Totes les pàgines d'un dels JSON d'Open5GS (màxim 100 elements per pàgina)."""
    base = _o5gs_base(nf)
    timeout = float((CFG.get('open5gs_api') or {}).get('timeout', 3))
    items = []
    for page in range(50):
        with _O5GS.open(f'{base}{path}?page={page}&page_size=100', timeout=timeout) as r:
            d = json.loads(r.read().decode('utf-8', 'replace'))
        items += d.get('items') or []
        if not (d.get('pager') or {}).get('next'):
            break
    return items


def _peer(txt):
    """'[192.168.1.31]:38412' -> ('192.168.1.31', '38412')"""
    m = re.match(r'^\[?([0-9a-fA-F.:]+?)\]?:(\d+)$', txt or '')
    return (m.group(1), m.group(2)) if m else (txt or None, None)


def _slices(lst):
    out = []
    for x in lst or []:
        sl = {'sst': x.get('sst')}
        if x.get('sd') and x['sd'].lower() != 'ffffff':
            sl['sd'] = x['sd'].lower()
        if sl not in out:
            out.append(sl)
    return out


def _o5gs_gnb(g):
    ip, port = _peer(((g.get('ng') or {}).get('sctp') or {}).get('peer'))
    tacs, slices, plmns = [], [], []
    for ta in g.get('supported_ta_list') or []:
        try:
            tac = str(int(ta.get('tac'), 16))
        except (TypeError, ValueError):
            tac = None
        if tac and tac not in tacs:
            tacs.append(tac)
        for b in ta.get('bplmns') or []:
            if b.get('plmn') and b['plmn'] not in plmns:
                plmns.append(b['plmn'])
            for sl in _slices(b.get('snssai')):
                if sl not in slices:
                    slices.append(sl)
    return {'ip': ip, 'port': port, 'gnb_id': g.get('gnb_id'), 'nom': g.get('name') or None,
            'plmn': g.get('plmn'), 'plmns': plmns, 'tacs': tacs, 'slices': slices,
            'setup_ok': bool((g.get('ng') or {}).get('setup_success')),
            'n_ues': g.get('num_connected_ues'), 'amf': (g.get('network') or {}).get('amf_name')}


def _o5gs_ue(u):
    supi = u.get('supi') or ''
    pei = u.get('pei') or ''
    loc = u.get('location') or {}
    cgi = loc.get('nr_cgi') or {}
    gnb = u.get('gnb') or {}
    sec = u.get('security') or {}
    nci = cgi.get('nci')
    mt = u.get('m_tmsi')
    return {
        'imsi': supi[5:] if supi.startswith('imsi-') else None, 'suci': u.get('suci'),
        'imeisv': pei[7:] if pei.startswith('imeisv-') else None,
        'imei': pei[5:] if pei.startswith('imei-') else None,
        'mm_state': u.get('mm_state'), 'cm_state': u.get('cm_state'), 'guti': u.get('guti'),
        'tmsi': hex(mt) if isinstance(mt, int) else None,
        'gnb_id': gnb.get('gnb_id', cgi.get('gnb_id')), 'cella': gnb.get('cell_id', cgi.get('cell_id')),
        'cell_id': hex(nci) if isinstance(nci, int) else None,
        'tac': str((loc.get('nr_tai') or {}).get('tac')) if (loc.get('nr_tai') or {}).get('tac') is not None else None,
        'plmn': (loc.get('nr_tai') or {}).get('plmn'),
        'ran_ue_ngap_id': gnb.get('ran_ue_ngap_id'), 'amf_ue_ngap_id': gnb.get('amf_ue_ngap_id'),
        'xifrat': sec.get('enc'), 'integritat': sec.get('int'),
        'slices': _slices(u.get('allowed_slices')), 'ambr': u.get('ambr'),
    }


def _o5gs_pdus(item):
    supi = item.get('supi') or ''
    imsi = supi[5:] if supi.startswith('imsi-') else None
    out = []
    for p in item.get('pdu') or []:
        sn = p.get('snssai') or {}
        n3 = p.get('n3') or {}
        sd = (sn.get('sd') or '').lower()
        out.append({'imsi': imsi, 'psi': p.get('psi'), 'dnn': p.get('dnn') or p.get('apn'),
                    'ipv4': p.get('ipv4'), 'ipv6': p.get('ipv6'), 'sst': sn.get('sst'),
                    'sd': sd if sd and sd != 'ffffff' else None, 'estat': p.get('pdu_state'),
                    '5qi': [q.get('5qi', q.get('qci')) for q in p.get('qos_flows') or []],
                    'upf': _peer((n3.get('upf') or {}).get('addr'))[0],
                    'gnb_n3': _peer((n3.get('gnb') or {}).get('addr'))[0],
                    'activitat_ue': item.get('ue_activity')})
    return out


def estat5g():
    """gNB, UEs i sessions PDU tal com les tenen ara l'AMF i l'SMF. Cada part pot fallar sola."""
    conts = CFG.get('containers', [])
    if 'amf' not in conts:
        raise LookupError
    out = {'ts': now(), 'gnbs': None, 'ues': None, 'pdus': None, 'errors': {}}
    parts = [('gnbs', 'amf', '/gnb-info', _o5gs_gnb), ('ues', 'amf', '/ue-info', _o5gs_ue)]
    if 'smf' in conts:
        parts.append(('pdus', 'smf', '/pdu-info', None))
    for key, nf, path, conv in parts:
        try:
            items = _o5gs_items(nf, path)
            if conv:
                out[key] = [conv(x) for x in items if isinstance(x, dict)]
            else:
                out[key] = [p for x in items if isinstance(x, dict) for p in _o5gs_pdus(x)]
        except LookupError as e:
            out['errors'][key] = str(e) or 'no configurat'
        except urllib.error.HTTPError as e:
            out['errors'][key] = (f'{nf.upper()} sense {path}: Open5GS anterior a la v2.7.7?'
                                  if e.code in (400, 404) else f'{nf.upper()} {path}: HTTP {e.code}')
        except (OSError, ValueError) as e:
            out['errors'][key] = f'{nf.upper()} {path}: {type(e).__name__}'
    return out


def ua_list():
    """User-Agents HTTP per IP del UE (els escriu ua_capture.py). Mai URLs ni contingut."""
    cap = CFG.get('ue_capture') or {}
    f = cap.get('ua_file', '/var/lib/agent5g/ua.json')
    try:
        with open(f) as fh:
            ents = json.load(fh).get('entrades', [])
    except (OSError, ValueError, AttributeError):
        return []
    keep = ('ip', 'ua', 'primer', 'darrer', 'n')
    return [{k: e.get(k) for k in keep} for e in ents if isinstance(e, dict)][:500]


# ---------------------------------------------------------------- mètriques de ràdio per UE (ocudu)
# El gNB (ocudu, derivat de srsRAN Project) publica cada segon, pel control remot WebSocket
# (remote_control, port 8001; cal metrics.enable_json: true), un JSON amb les mètriques del
# planificador per cel·la i per UE: CQI, RI, MCS, velocitat, blocs OK/KO, SNR, temps d'avançament...
# Cada UE ve identificat pel seu RNTI (identificador de ràdio, canvia a cada connexió). Per saber de
# quin mòbil és, el log del gNB (rrc_level i ngap_level a info o debug) diu:
#   [RRC   ] [I] ue=19 c-rnti=0x4848: "RRC Setup Procedure" started   -> índex del CU <-> RNTI
#   [NGAP  ] [I] Rx PDU ue=19 ran_ue=18 amf_ue=19: InitialContextSetupRequest
#                                                     -> índex del CU <-> identificadors NGAP
# (Compte: a les línies [DU-F1] el "ue=" és un altre índex, el del DU; no serveixen.)
# i l'AMF d'Open5GS diu quin IMSI té cada amf_ue_ngap_id. Sense aquests logs, el panell només
# pot deduir-ho quan hi ha un sol mòbil connectat al gNB.
RADIO_CAMPS = ('pci', 'cqi', 'dl_ri', 'ul_ri', 'ri', 'dl_mcs', 'ul_mcs', 'dl_brate', 'ul_brate',
               'dl_nof_ok', 'dl_nof_nok', 'ul_nof_ok', 'ul_nof_nok', 'pusch_snr_db', 'pusch_rsrp_db',
               'pucch_snr_db', 'ta_ns', 'pusch_ta_ns', 'last_phr', 'bsr', 'dl_bs')
# Historial curt per als gràfics del panell: una mostra per segon i per RNTI, 5 minuts.
HIST_CAMPS = ('cqi', 'dl_ri', 'ul_ri', 'dl_mcs', 'ul_mcs', 'dl_brate', 'ul_brate', 'dl_nof_ok', 'dl_nof_nok',
              'ul_nof_ok', 'ul_nof_nok', 'pusch_snr_db', 'pusch_rsrp_db')
HIST_MAX = 300
RADIO = {'ues': {}, 'hist': {}, 'connectat': False, 'error': None, 'darrer': None, 'versio': None,
         'fil': None, 'demanat': 0.0, 'log': {'ino': None, 'pos': 0, 'rnti': {}, 'idx': {}, 'ids': {}, 'linies': 0}}
RADIO_LOCK = threading.Lock()
RE_RNTI = re.compile(r'\[(?:RRC|CU-CP)\s*\].*?\bue=(\d+) c-rnti=(0x[0-9a-fA-F]+)')
RE_NGAP = re.compile(r'\[NGAP\s*\].*?\bue=(\d+) ran_ue=(\d+)(?: amf_ue=(\d+))?')


def _radio_cfg():
    c = CFG.get('gnb_metrics')
    if c is False or (c is None and CFG.get('role') != 'radio'):
        return None
    c = dict(c or {})
    c.setdefault('ws', 'ws://127.0.0.1:8001')
    c.setdefault('log', 'gnb.log')            # nom d'un dels log_files
    c.setdefault('caducitat', 5)              # s: un UE sense mètriques en aquest temps ja no hi és
    return c


def _ws_connecta(url, timeout):
    """Client WebSocket mínim (RFC 6455) amb la biblioteca estàndard: només text, sense extensions."""
    u = urlparse(url)
    if u.scheme != 'ws' or not u.hostname:
        raise ValueError('gnb_metrics.ws ha de ser ws://IP:port')
    s = socket.create_connection((u.hostname, u.port or 80), timeout=timeout)
    clau = __import__('base64').b64encode(os.urandom(16)).decode()
    s.sendall((f'GET {u.path or "/"} HTTP/1.1\r\nHost: {u.hostname}:{u.port or 80}\r\n'
               f'Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {clau}\r\n'
               'Sec-WebSocket-Version: 13\r\n\r\n').encode())
    cap = b''
    while b'\r\n\r\n' not in cap:
        b = s.recv(4096)
        if not b:
            raise ConnectionError('el gNB ha tancat la connexió')
        cap += b
        if len(cap) > 16384:
            raise ConnectionError('resposta HTTP massa llarga')
    cap, resta = cap.split(b'\r\n\r\n', 1)
    if b' 101 ' not in cap.split(b'\r\n', 1)[0]:
        raise ConnectionError('el gNB no accepta WebSocket: ' + cap.split(b'\r\n', 1)[0].decode('latin-1')[:80])
    return s, bytearray(resta)


def _ws_envia(s, text, opcode=1):
    dades = text.encode() if isinstance(text, str) else text
    mask = os.urandom(4)
    n = len(dades)
    cap = bytes([0x80 | opcode])
    if n < 126:
        cap += bytes([0x80 | n])
    elif n < 65536:
        cap += bytes([0x80 | 126]) + n.to_bytes(2, 'big')
    else:
        cap += bytes([0x80 | 127]) + n.to_bytes(8, 'big')
    s.sendall(cap + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(dades)))


def _ws_llegeix(s, buf, maxim=8 << 20):
    """Torna el següent missatge de text complet (ajunta fragments; respon els ping)."""
    def cal(n):
        while len(buf) < n:
            b = s.recv(65536)
            if not b:
                raise ConnectionError('el gNB ha tancat la connexió')
            buf.extend(b)
    msg = bytearray()
    while True:
        cal(2)
        fin, op, ln = buf[0] & 0x80, buf[0] & 0x0F, buf[1] & 0x7F
        mascara, pos = buf[1] & 0x80, 2
        if ln == 126:
            cal(4)
            ln, pos = int.from_bytes(buf[2:4], 'big'), 4
        elif ln == 127:
            cal(10)
            ln, pos = int.from_bytes(buf[2:10], 'big'), 10
        if ln > maxim:
            raise ConnectionError('missatge massa gran')
        if mascara:
            pos += 4
        cal(pos + ln)
        dades = bytes(buf[pos:pos + ln])
        if mascara:
            m = buf[pos - 4:pos]
            dades = bytes(b ^ m[i % 4] for i, b in enumerate(dades))
        del buf[:pos + ln]
        if op == 8:
            raise ConnectionError('el gNB ha tancat el WebSocket')
        if op == 9:
            _ws_envia(s, dades, opcode=10)
            continue
        if op == 10:
            continue
        msg += dades
        if len(msg) > maxim:
            raise ConnectionError('missatge massa gran')
        if fin:
            return msg.decode('utf-8', 'replace')


def _rnti(v):
    if isinstance(v, int):
        return v
    try:
        return int(str(v), 0)
    except ValueError:
        return None


def _radio_missatge(d):
    """Desa les mètriques per UE d'un missatge del gNB. Formats: ocudu ('cells' -> 'ue_list' amb
    els camps a dins) i srsRAN Project antic ('ue_list' -> 'ue_container')."""
    if not isinstance(d, dict):
        return
    if 'metrics_version' in d or d.get('cmd') == 'metrics_subscribe':
        RADIO['versio'] = d.get('metrics_version') or (d.get('result') or {}).get('metrics_version')
    cells = d.get('cells')
    if not isinstance(cells, list):
        return
    t = time.time()
    with RADIO_LOCK:
        for c in cells:
            if not isinstance(c, dict):
                continue
            pci_cel = (c.get('cell_metrics') or {}).get('pci')
            for ev in c.get('event_list') or []:
                if isinstance(ev, dict) and ev.get('event_type') == 'ue_rem':
                    RADIO['ues'].pop((pci_cel, _rnti(ev.get('rnti'))), None)
                    RADIO['hist'].pop((pci_cel, _rnti(ev.get('rnti'))), None)
            for x in c.get('ue_list') or []:
                u = x.get('ue_container', x) if isinstance(x, dict) else None
                if not isinstance(u, dict):
                    continue
                rnti = _rnti(u.get('rnti'))
                if rnti is None:
                    continue
                m = {k: u[k] for k in RADIO_CAMPS if k in u and isinstance(u[k], (int, float))}
                m.setdefault('pci', pci_cel)
                m['rnti'] = rnti
                m['du_ue'] = u.get('ue')
                m['t'] = t
                RADIO['ues'][(m.get('pci'), rnti)] = m
                h = RADIO['hist'].setdefault((m.get('pci'), rnti), deque(maxlen=HIST_MAX))
                h.append([round(t, 1)] + [m.get(k) for k in HIST_CAMPS])
        RADIO['darrer'] = t


def _radio_fil():
    """Fil de fons: subscripció a les mètriques del gNB; es torna a connectar sol."""
    espera = 2
    while True:
        cfg = _radio_cfg()
        if time.time() - RADIO['demanat'] > 300:      # ningú mira el panell: no cal estar subscrit
            RADIO['connectat'] = False
            time.sleep(2)
            continue
        s = None
        try:
            s, buf = _ws_connecta(cfg['ws'], 5)
            _ws_envia(s, json.dumps({'cmd': 'metrics_subscribe'}))
            s.settimeout(15)                            # el gNB n'envia cada segon
            RADIO['connectat'], RADIO['error'], espera = True, None, 2
            while time.time() - RADIO['demanat'] <= 300:
                txt = _ws_llegeix(s, buf)
                try:
                    _radio_missatge(json.loads(txt))
                except ValueError:
                    pass
        except (OSError, ConnectionError, ValueError) as e:
            RADIO['error'] = (f'sense connexió amb el control remot del gNB ({cfg["ws"]}): '
                              f'{type(e).__name__}{": " + str(e) if str(e) else ""}')[:300]
        finally:
            RADIO['connectat'] = False
            if s:
                try:
                    s.close()
                except OSError:
                    pass
        time.sleep(espera)
        espera = min(espera * 2, 30)


def _radio_log(cfg):
    """Llegeix només el que s'ha afegit al log del gNB des de l'última vegada (com 'tail -f')."""
    path = CFG['log_files'].get(cfg['log'])
    st = RADIO['log']
    if not path:
        return 'sense log del gNB a la configuració'
    try:
        info = os.stat(path)
    except OSError:
        return 'no puc llegir el log del gNB'
    if st['ino'] != info.st_ino or info.st_size < st['pos']:   # fitxer nou (gNB reiniciat)
        st.update(ino=info.st_ino, pos=max(0, info.st_size - (8 << 20)), rnti={}, idx={}, ids={}, linies=0)
    if info.st_size == st['pos']:
        return None
    with open(path, 'rb') as fh:
        fh.seek(st['pos'])
        dades = fh.read(32 << 20)
    tall = dades.rfind(b'\n') + 1                     # només línies senceres
    st['pos'] += tall
    for l in dades[:tall].decode('utf-8', 'replace').splitlines():
        m = RE_RNTI.search(l)
        if m:
            idx, rnti = int(m.group(1)), int(m.group(2), 16)
            if st['idx'].get(idx) != rnti:            # índex reaprofitat o RNTI nou: oblida l'anterior
                st['ids'].pop(idx, None)
                st['idx'][idx] = rnti
            st['rnti'][rnti] = idx                    # el darrer UE amb aquest RNTI
            st['linies'] += 1
            continue
        m = RE_NGAP.search(l)
        if m:
            idx = int(m.group(1))
            ids = st['ids'].setdefault(idx, {})
            ids['ran_ue_ngap_id'] = int(m.group(2))
            if m.group(3):
                ids['amf_ue_ngap_id'] = int(m.group(3))
            st['linies'] += 1
    return None


def radio_ues():
    cfg = _radio_cfg()
    if not cfg:
        raise LookupError
    RADIO['demanat'] = time.time()
    if not RADIO['fil'] or not RADIO['fil'].is_alive():
        RADIO['fil'] = threading.Thread(target=_radio_fil, daemon=True)
        RADIO['fil'].start()
        for _ in range(30):                           # primera vegada: espera el primer missatge
            if RADIO['darrer'] or RADIO['error']:
                break
            time.sleep(0.1)
    with RADIO_LOCK:
        err_log = _radio_log(cfg)
        lim = time.time() - float(cfg['caducitat'])
        for k in [k for k, m in RADIO['ues'].items() if m['t'] < lim]:
            del RADIO['ues'][k]
            RADIO['hist'].pop(k, None)
        st = RADIO['log']
        out = []
        for m in sorted(RADIO['ues'].values(), key=lambda m: (m.get('pci') or 0, m['rnti'])):
            hist = [list(x) for x in RADIO['hist'].get((m.get('pci'), m['rnti']), ())]
            m = dict(m, hist=hist)
            m['rnti'] = f'0x{m["rnti"]:04x}'
            idx = st['rnti'].get(int(m['rnti'], 16))
            m['cu_ue'] = idx
            m.update(st['ids'].get(idx, {}) if idx is not None else {})
            m['edat_s'] = round(time.time() - m.pop('t'), 1)
            out.append(m)
    return {'ts': now(), 'connectat': RADIO['connectat'], 'error': RADIO['error'],
            'darrer': dt.datetime.fromtimestamp(RADIO['darrer'], dt.timezone.utc).isoformat(timespec='seconds')
            if RADIO['darrer'] else None,
            'radio_ip': read_env().get('RADIO_IP'), 'ues': out, 'hist_camps': ['t', *HIST_CAMPS],
            'log': err_log or ('ok' if st['linies'] else 'el log del gNB no té línies RRC/NGAP (cal rrc_level i ngap_level: info)')}


# ---------------------------------------------------------------- audit
def audit(client, user, action, detail, ok=True):
    rec = {'ts': now(), 'client': client, 'user': user, 'action': action,
           'ok': ok, 'detail': detail}
    with open(CFG['audit_log'], 'a') as f:
        f.write(json.dumps(rec, ensure_ascii=False) + '\n')
    os.chmod(CFG['audit_log'], 0o600)


def audit_tail(n):
    if not os.path.isfile(CFG['audit_log']):
        return []
    with open(CFG['audit_log']) as f:
        lines = deque(f, maxlen=n)
    return [json.loads(l) for l in lines if l.strip()]


# ---------------------------------------------------------------- HTTP
# ---------------------------------------------------------------- UPF separat
# Com la ràdio: és el PC del UPF qui truca al core (agent amb "role": "upf" i "core": IP),
# amb un certificat de la CA amb CN agent-upf-<nom>. Al core li és igual la IP del UPF:
# la treu de la mateixa connexió (i la seva pròpia IP, la que veu el UPF, també).
#
# Quan un UPF truca, el core li passa la configuració que ha de tenir (subxarxes dels
# mòbils, interfícies, IP de l'SMF...) i, si el mode automàtic és actiu, el selecciona:
#   smf/smf.yaml   pfcp server: advertise <IP del core>   pfcp client upf: <IP del UPF>
#   compose        upf amb profiles: ["upf_local"] (no arrenca) i 8805/udp de l'smf publicat
# i recrea l'smf. "Ajuntar" ho desfà i torna a arrencar el upf del core. Només un UPF
# seleccionat alhora: els altres que truquin queden connectats però amb el upf aturat.
# L'estat (mode, IP, quin UPF) es llegeix sempre dels fitxers; upf.json només guarda
# quin UPF és el seleccionat i si el mode automàtic és actiu.
UPF_MARCA = '# panel5g: UPF separat'
UPF_MARCA_CORE5G = '# core5g: sense UPF'
UPF_ID_RE = re.compile(r'^[A-Za-z0-9_.-]{1,64}$')
UPF_LOCK = threading.Lock()
# claus del .env del core que el UPF necessita (upf_init.sh) i que el core li passa
UPF_ENV_CLAUS = ('UE_IPV4_INTERNET', 'UE_IPV4_IMS', 'MAX_NUM_UE', 'UPF_TUNTAP_MODE',
                 'UPF_INTERNET_APN_IF_NAME', 'UPF_IMS_APN_IF_NAME', 'PCSCF_IP', 'MCC', 'MNC')
_IP_RX = r'(\d{1,3}\.){3}\d{1,3}'
UPF_ENV_RX = {
    'UE_IPV4_INTERNET': re.compile(_IP_RX + r'/\d{1,2}'), 'UE_IPV4_IMS': re.compile(_IP_RX + r'/\d{1,2}'),
    'MAX_NUM_UE': re.compile(r'\d{1,6}'), 'UPF_TUNTAP_MODE': re.compile(r'tun|tap'),
    'UPF_INTERNET_APN_IF_NAME': re.compile(r'[A-Za-z0-9_.-]{1,15}'),
    'UPF_IMS_APN_IF_NAME': re.compile(r'[A-Za-z0-9_.-]{1,15}'),
    'PCSCF_IP': re.compile(_IP_RX), 'MCC': re.compile(r'\d{3}'), 'MNC': re.compile(r'\d{2,3}'),
    'SMF_IP': re.compile(_IP_RX), 'UPF_HOST_IP': re.compile(_IP_RX),
}


def upf_id(cn):
    """agent-upf-aula2 -> aula2; agent-upf -> upf."""
    if not cn or not cn.startswith('agent-upf'):
        return None
    uid = cn[len('agent-upf'):].lstrip('-') or 'upf'
    return uid if UPF_ID_RE.match(uid) else None


def _ip_ok(ip):
    try:
        return ipaddress.ip_address(ip).version == 4
    except (ValueError, TypeError):
        return False


def _ip_cap_a(ip):
    """IP d'aquest equip per on surt el trànsit cap a `ip` (no envia res)."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.connect((ip, 8805))
        return s.getsockname()[0]


def _upf_estat_path():
    return CFG.get('upf_estat') or os.path.join(os.path.dirname(CFG['backup_dir'].rstrip('/')), 'upf.json')


def upf_json():
    try:
        with open(_upf_estat_path()) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def upf_json_desa(**kw):
    d = upf_json()
    d.update(kw)
    p = _upf_estat_path()
    with open(p + '.tmp', 'w') as f:
        json.dump(d, f, indent=1)
    os.replace(p + '.tmp', p)
    return d


def _smf_path():
    return os.path.join(CFG['project_dir'], 'smf', 'smf.yaml')


def _upf_composes():
    return [p for p in (os.path.join(CFG['project_dir'], f) for f in CFG['compose_files']) if os.path.isfile(p)]


def upf_gestionat():
    return CFG.get('role') == 'core' and os.path.isfile(_smf_path()) and bool(_upf_composes())


def _ind(l):
    return len(l) - len(l.lstrip(' '))


def smf_pfcp(lines):
    """Posicions del bloc pfcp de smf.yaml: adreça del servidor, advertise i adreça del UPF."""
    r = {'srv': None, 'adv': None, 'cli': None, 'upf': None}
    p_ind = None
    part = None
    for i, l in enumerate(lines):
        s = l.strip()
        if not s or s.startswith('#'):
            continue
        if p_ind is None:
            if re.match(r'^\s*pfcp:\s*(#.*)?$', l):
                p_ind = _ind(l)
            continue
        if _ind(l) <= p_ind:                       # fi del bloc pfcp
            break
        m = re.match(r'^\s*(server|client):\s*(#.*)?$', l)
        if m:
            part = m.group(1)
            continue
        if part == 'server' and r['srv'] is None:
            if re.match(r'^\s*-\s*address:\s*\S+', l):
                r['srv'] = i
        elif part == 'server' and r['adv'] is None and r['srv'] is not None:
            if re.match(r'^\s*advertise:\s*\S+', l) and _ind(l) > _ind(lines[r['srv']]):
                r['adv'] = i
        if part == 'client':
            if re.match(r'^\s*upf:\s*(#.*)?$', l):
                part = 'client-upf'
        elif part == 'client-upf' and r['cli'] is None:
            m = re.match(r'^(\s*-\s*address:\s*)(\S+)(.*)$', l)
            if m:
                r['cli'], r['upf'] = i, m.group(2)
    return r


def smf_transforma(lines, upf_ip, core_ip):
    """upf_ip/core_ip = None torna al UPF del core (UPF_IP, sense advertise)."""
    r = smf_pfcp(lines)
    if r['srv'] is None or r['cli'] is None:
        raise RuntimeError('smf/smf.yaml no té el format esperat (pfcp: server address / client upf address)')
    out = list(lines)
    m = re.match(r'^(\s*-\s*address:\s*)(\S+)(.*)$', out[r['cli']])
    out[r['cli']] = m.group(1) + (upf_ip or 'UPF_IP')
    srv = out[r['srv']]
    adv_txt = ' ' * (_ind(srv) + 2) + f'advertise: {core_ip}   {UPF_MARCA}' if core_ip else None
    if r['adv'] is not None:
        if adv_txt:
            out[r['adv']] = adv_txt
        else:
            del out[r['adv']]
    elif adv_txt:
        out.insert(r['srv'] + 1, adv_txt)
    return out


def _serveis(lines):
    """{nom_servei: (inici, fi)} dels serveis del compose (capçaleres a 2 espais)."""
    res, act, ini = {}, None, None
    for i, l in enumerate(lines):
        m = re.match(r'^  ([A-Za-z0-9_.-]+):\s*(#.*)?$', l)
        if m or (l and not l.startswith(' ') and not l.startswith('#')):
            if act:
                res[act] = (ini, i)
            act, ini = (m.group(1), i) if m else (None, None)
    if act:
        res[act] = (ini, len(lines))
    return res


def compose_transforma(lines, separa):
    out = list(lines)
    if not separa:
        out = [l for l in out if not (l.rstrip().endswith(UPF_MARCA) or l.rstrip().endswith(UPF_MARCA_CORE5G))]
    sv = _serveis(out)
    if 'smf' not in sv:
        return out
    if separa:
        ini, fi = sv['smf']
        bloc = out[ini:fi]
        if not any('8805:8805/udp' in l for l in bloc):
            pi = next((ini + j for j, l in enumerate(bloc) if re.match(r'^    ports:\s*(#.*)?$', l)), None)
            if pi is not None:
                out.insert(pi + 1, f'      - "8805:8805/udp"  {UPF_MARCA}')
            else:
                out[ini + 1:ini + 1] = [f'    ports:  {UPF_MARCA}', f'      - "8805:8805/udp"  {UPF_MARCA}']
        sv = _serveis(out)
        if 'upf' in sv:
            ini, fi = sv['upf']
            if not any(re.match(r'^    profiles:', l) for l in out[ini:fi]):
                out.insert(ini + 1, f'    profiles: ["upf_local"]  {UPF_MARCA}')
        return out
    # ajuntar també desfà un muntatge fet a mà (sense marques): perfil upf_local i 8805 de l'smf
    if 'upf' in sv:
        ini, fi = sv['upf']
        out = out[:ini] + [l for l in out[ini:fi]
                           if not re.match(r'^    profiles:\s*\[\s*"?upf_local"?\s*\]\s*(#.*)?$', l)] + out[fi:]
    sv = _serveis(out)
    ini, fi = sv['smf']
    bloc = [l for l in out[ini:fi] if not re.match(r'^\s*-\s*"?8805:8805/udp"?\s*(#.*)?$', l)]
    net = []
    for j, l in enumerate(bloc):                   # "ports:" que s'ha quedat sense cap element
        if re.match(r'^    ports:\s*(#.*)?$', l):
            seg = next((x for x in bloc[j + 1:] if x.strip() and not x.strip().startswith('#')), '')
            if _ind(seg) <= 4:
                continue
        net.append(l)
    return out[:ini] + net + out[fi:]


def upf_estat_fitxers():
    lines = _read_lines(_smf_path())
    r = smf_pfcp(lines)
    upf = r['upf']
    adv = None
    if r['adv'] is not None:
        adv = lines[r['adv']].split('advertise:', 1)[1].split('#', 1)[0].strip()
    mode = 'local' if upf in (None, 'UPF_IP') else 'remot'
    perfil = False
    for p in _upf_composes():
        c = _read_lines(p)
        sv = _serveis(c)
        if 'upf' in sv and any(re.match(r'^    profiles:\s*\[\s*"?upf_local', l) for l in c[sv['upf'][0]:sv['upf'][1]]):
            perfil = True
    return {'mode': mode, 'ip': upf if mode == 'remot' else None, 'advertise': adv, 'perfil_upf_local': perfil}


def _upf_contenidor_del_core():
    rc, out = run([CFG['docker_bin'], 'inspect', '-f',
                   '{{index .Config.Labels "com.docker.compose.project.working_dir"}}', 'upf'])
    if rc != 0:
        return False
    try:
        return os.path.realpath(out.strip()) == os.path.realpath(CFG['project_dir'])
    except OSError:
        return False


def upf_aplica(separa, upf_ip=None, core_ip=None):
    """Canvia els fitxers (amb còpia) i recrea l'smf. Cal tenir LOCK."""
    if not upf_gestionat():
        raise LookupError('aquest equip no és un core amb smf.yaml')
    if separa and not (_ip_ok(upf_ip) and _ip_ok(core_ip)):
        raise ValueError('IP del UPF o del core invàlida')
    files = {}
    smf = _read_lines(_smf_path())
    n = smf_transforma(smf, upf_ip if separa else None, core_ip if separa else None)
    if n != smf:
        files[_smf_path()] = n
    for p in _upf_composes():
        c = _read_lines(p)
        nc = compose_transforma(c, separa)
        if nc != c:
            files[p] = nc
    baks = _commit(files) if files else {}
    out = ''
    if separa:
        if _upf_contenidor_del_core():
            rc, o = run([CFG['docker_bin'], 'rm', '-f', 'upf'], timeout=60)
            out += o
        rc, o = run(compose_base() + ['up', '-d', '--no-deps', '--force-recreate', 'smf'], timeout=CFG['apply_timeout'])
    else:
        rc, o = run(compose_base() + ['up', '-d', '--no-deps', 'upf'], timeout=CFG['apply_timeout'])
        out += o
        if rc == 0:
            rc, o = run(compose_base() + ['up', '-d', '--no-deps', '--force-recreate', 'smf'],
                        timeout=CFG['apply_timeout'])
    out += o
    if rc != 0:
        raise RuntimeError('docker compose ha fallat: ' + out[-600:])
    return {'copies': baks, 'canviat': sorted(os.path.relpath(p, CFG['project_dir']) for p in files),
            'sortida': out[-2000:]}


def _upf_env_per_al_upf(core_ip, upf_ip):
    env = read_env()
    d = {k: env[k] for k in UPF_ENV_CLAUS if env.get(k) and UPF_ENV_RX[k].fullmatch(env[k])}
    d['SMF_IP'] = core_ip            # al PC del UPF, l'SMF és la IP del core (8805 publicat)
    d['UPF_HOST_IP'] = upf_ip        # Node ID PFCP del UPF: la IP per on el veu el core
    return d


def _upf_connectats():
    return {u['id']: u for u in (ENLLAC.upfs() if ENLLAC else []) if u['connectat']}


def _upf_configura(uid, actiu, core_ip=None, upf_ip=None):
    cos = {'actiu': bool(actiu)}
    if actiu:
        cos['env'] = _upf_env_per_al_upf(core_ip, upf_ip)
    codi, _ct, dades = ENLLAC.peticio('upf:' + uid, 'POST', '/upf_configura', 'core',
                                     json.dumps(cos).encode(), timeout=CFG['apply_timeout'] + 30)
    try:
        r = json.loads(dades or b'{}')
    except ValueError:
        r = {}
    if codi != 200:
        raise RuntimeError(f'UPF {uid}: {r.get("error") or codi}')
    return r


def _upf_atura_altres(excepte=None):
    """Atura el upf de tots els PCs connectats menys `excepte`: només un UPF parla amb l'SMF."""
    for altre in _upf_connectats():
        if altre != excepte:
            try:
                _upf_configura(altre, False)
            except Exception:  # noqa: BLE001
                pass


def upf_selecciona(uid, user='core', auto=True):
    """Fa servir el UPF `uid` (connectat al core): li passa la configuració i separa el core."""
    con = _upf_connectats()
    if uid not in con:
        raise LookupError(f'el UPF "{uid}" no està connectat al core')
    u = con[uid]
    upf_ip, core_ip = u['ip'], u['ip_core']
    r_upf = _upf_configura(uid, True, core_ip, upf_ip)
    with LOCK:
        est = upf_estat_fitxers()
        if est['mode'] == 'remot' and est['ip'] == upf_ip and est['advertise'] == core_ip and est['perfil_upf_local']:
            r = {'canviat': [], 'copies': {}}
        else:
            r = upf_aplica(True, upf_ip, core_ip)
        upf_json_desa(upf_id=uid, darrer_upf=uid, ip=upf_ip, auto=auto, des_de=now())
    _upf_atura_altres(uid)                  # un sol UPF actiu
    audit('core', user, 'upf-separa', {'upf': uid, 'ip': upf_ip, 'core_ip': core_ip, 'canviat': r['canviat']})
    print(f'agent5g: UPF "{uid}" ({upf_ip}) seleccionat; l\'SMF hi apunta (anunciant {core_ip})', flush=True)
    return {'upf_id': uid, 'ip': upf_ip, 'core_ip': core_ip, 'upf': r_upf, **r}


def upf_separa_ip(ip, user):
    """Separa cap a un UPF sense agent (muntatge fet a mà)."""
    if not _ip_ok(ip):
        raise ValueError('IP del UPF invàlida')
    core_ip = _ip_cap_a(ip)
    with LOCK:
        r = upf_aplica(True, ip, core_ip)
        upf_json_desa(upf_id=None, ip=ip, auto=False, des_de=now())
    _upf_atura_altres()
    audit('core', user, 'upf-separa', {'ip': ip, 'core_ip': core_ip, 'canviat': r['canviat']})
    return {'upf_id': None, 'ip': ip, 'core_ip': core_ip, **r}


def upf_ajunta(user):
    sel = upf_json().get('upf_id')
    with LOCK:
        r = upf_aplica(False)
        upf_json_desa(upf_id=None, ip=None, auto=False, des_de=now())   # no es torna a separar sol
    _upf_atura_altres()                     # que cap UPF remot continuï parlant amb l'SMF
    audit('core', user, 'upf-ajunta', {'abans': sel, 'canviat': r['canviat']})
    print('agent5g: UPF de nou dins del core', flush=True)
    return {'upf_id': None, **r}


def upf_auto(valor, user):
    """Activa/desactiva el mode automàtic. En activar-lo amb el UPF dins del core i algun UPF
    connectat, el fa servir ja (el darrer que es va fer servir, si hi és)."""
    j = upf_json_desa(auto=valor)
    if valor and upf_gestionat() and upf_estat_fitxers()['mode'] == 'local':
        con = _upf_connectats()
        if con:
            uid = j.get('darrer_upf') if j.get('darrer_upf') in con else sorted(con)[0]
            return {**upf_selecciona(uid, user, auto=True), 'auto': True}
    return {'auto': valor}


def upf_rebut(uid):
    """Un UPF acaba de trucar al core (o ha canviat d'IP): decideix si se selecciona."""
    # Si el core en fa servir un altre que ara no hi és (p. ex. acaba de reiniciar-se el core i
    # encara no ha tornat a trucar), se li donen 30 s abans de canviar-lo per aquest.
    sel = upf_json().get('upf_id')
    for _ in range(15):
        if not sel or sel == uid or sel in _upf_connectats():
            break
        time.sleep(2)
    with UPF_LOCK:
        try:
            if not upf_gestionat():
                return
            j = upf_json()
            est = upf_estat_fitxers()
            con = _upf_connectats()
            sel = j.get('upf_id')
            if sel == uid and est['mode'] == 'remot':
                tria = True                     # el mateix UPF (potser amb una IP nova)
            elif not j.get('auto', True):
                tria = False                    # s'ha ajuntat a mà: no es torna a separar sol
            elif est['mode'] == 'local':
                tria = True
            else:                               # ja n'hi ha un altre: només si aquell no hi és
                tria = not (sel and sel in con)
            if tria:
                upf_selecciona(uid, 'auto', auto=True)
            else:
                _upf_configura(uid, False)
                print(f'agent5g: UPF "{uid}" connectat però no seleccionat (el core fa servir '
                      f'{"el seu UPF" if est["mode"] == "local" else est["ip"]})', flush=True)
        except Exception as e:  # noqa: BLE001
            print(f'agent5g: UPF "{uid}": no s\'ha pogut configurar: {type(e).__name__}: {str(e)[:200]}', flush=True)


def prom_parse(txt):
    """Text de Prometheus -> {nom: suma}, [{nom, etiquetes, valor}]."""
    tot, det = {}, []
    for l in txt.splitlines():
        if not l or l.startswith('#'):
            continue
        m = re.match(r'^([A-Za-z_:][A-Za-z0-9_:]*)(\{([^}]*)\})?\s+([-+0-9.eE]+|NaN|[+-]Inf)', l)
        if not m:
            continue
        try:
            v = float(m.group(4))
        except ValueError:
            continue
        nom = m.group(1)
        tot[nom] = tot.get(nom, 0) + v
        if len(det) < 400:
            det.append({'nom': nom, 'etiquetes': m.group(3) or '', 'valor': v})
    return tot, det


def upf_metriques(ip, port=9091):
    """Mètriques de l'UPF per HTTP (servidor de mètriques d'Open5GS) + comptadors de les ogstun."""
    res = {'url': f'http://{ip}:{port}/metrics', 'ok': False}
    try:
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(res['url'], timeout=4) as r:
            tot, det = prom_parse(r.read(4 << 20).decode('utf-8', 'replace'))
        res.update(ok=True, total=tot, detall=det)
    except (OSError, urllib.error.URLError, ValueError) as e:
        res['error'] = f'{type(e).__name__}: {str(e)[:150]}'
    rc, out = run([CFG['docker_bin'], 'exec', 'upf', 'cat', '/proc/net/dev'], timeout=10)
    ifs = {}
    if rc == 0:
        for l in out.splitlines()[2:]:
            nom, _, rest = l.partition(':')
            nom, c = nom.strip(), rest.split()
            if len(c) >= 10 and nom != 'lo':
                ifs[nom] = {'rx_bytes': int(c[0]), 'rx_paquets': int(c[1]), 'tx_bytes': int(c[8]),
                            'tx_paquets': int(c[9])}
    res['interficies'] = ifs
    res['hora'] = now()
    return res


def pfcp_log(contenidor, n=3000):
    """Darrera associació PFCP que diu el log (Open5GS: "PFCP associated [ip]:8805")."""
    rc, out = run([CFG['docker_bin'], 'logs', '--tail', str(n), '--timestamps', contenidor], timeout=20)
    if rc != 0:
        return None
    for l in reversed(out.splitlines()):
        m = re.search(r'PFCP (de-)?associated\s*\[?([0-9a-fA-F.:]+?)\]?(:\d+)?\s*$', l) or \
            re.search(r'PFCP (de-)?associated.*?\[([0-9a-fA-F.:]+)\]', l)
        if m:
            return {'associat': not m.group(1), 'ip': m.group(2), 'quan': l.split(' ', 1)[0], 'linia': l[-200:]}
    return None


def upf_core_estat():
    if not upf_gestionat():
        raise LookupError('aquest equip no gestiona UPF')
    est = upf_estat_fitxers()
    j = upf_json()
    con = ENLLAC.upfs() if ENLLAC else []
    out = {**est, 'auto': j.get('auto', True), 'upf_id': j.get('upf_id') if est['mode'] == 'remot' else None,
           'des_de': j.get('des_de'), 'upfs': con, 'pfcp': pfcp_log('smf'), 'rep_upfs': ENLLAC is not None}
    if est['mode'] == 'local':
        env = read_env()
        if _ip_ok(env.get('UPF_IP')):
            out['metriques'] = upf_metriques(env['UPF_IP'])
    return out


# ---- costat UPF (agent amb "role": "upf")
def _upf_cfg():
    u = CFG.get('upf') or {}
    return {'gnb_local': bool(u.get('gnb_local')), 'xarxa': u.get('xarxa') or '172.23.0.0/24',
            'upf_ip': u.get('upf_ip') or '172.23.0.8', 'regla_main': bool(u.get('regla_main'))}


def _env_posa(lines, valors):
    out, pend = list(lines), dict(valors)
    for i, l in enumerate(out):
        m = LINE_RE.match(l)
        if m and m.group(2) in pend:
            out[i] = f'{m.group(1)}{m.group(2)}{m.group(3)}{pend.pop(m.group(2))}{m.group(5)}'
    if pend:
        fi = len(out)
        while fi and not out[fi - 1].strip():      # abans de les línies buides del final
            fi -= 1
        out[fi:fi] = ['# del core (panel5g)'] + [f'{k}={v}' for k, v in pend.items()]
    return out


def _upf_corrent():
    rc, out = run([CFG['docker_bin'], 'inspect', '-f', '{{.State.Running}}', 'upf'])
    return rc == 0 and out.strip() == 'true'


def _regla_main():
    """Amb una VPN de túnel complet, el trànsit dels mòbils ha de sortir per la LAN (taula main)."""
    u = _upf_cfg()
    if not u['regla_main']:
        return
    rc, out = run(['ip', 'rule', 'show'])
    if f'from {u["xarxa"]} lookup main' not in out:
        run(['ip', 'rule', 'add', 'from', u['xarxa'], 'lookup', 'main', 'priority', '100'])


def upf_configura(data):
    """(PC del UPF) El core diu la configuració i si aquest UPF ha d'estar actiu."""
    if CFG.get('role') != 'upf':
        raise LookupError('aquest equip no és un UPF')
    if not isinstance(data, dict):
        raise ValueError('cos invàlid')
    actiu = bool(data.get('actiu'))
    canviat = False
    if actiu:
        env = data.get('env')
        if not isinstance(env, dict):
            raise ValueError('falta env')
        nous = {}
        for k, v in env.items():
            if k not in UPF_ENV_RX or not isinstance(v, str) or not UPF_ENV_RX[k].fullmatch(v):
                raise ValueError(f'clau o valor no permès: {k}')
            nous[k] = v
        for k in ('SMF_IP', 'UPF_HOST_IP'):
            if k not in nous:
                raise ValueError(f'falta {k}')
        u = _upf_cfg()
        nous['UPF_IP'] = u['upf_ip']
        nous['TEST_NETWORK'] = u['xarxa']
        # GTP-U (N3): amb la gNB al mateix PC, la gNB arriba al contenidor pel pont de Docker
        # (el 2152 del host ja és seu); si no, la gNB hi arriba per la IP del PC.
        nous['UPF_ADVERTISE_IP'] = u['upf_ip'] if u['gnb_local'] else nous['UPF_HOST_IP']
        env_ara = read_env()
        dif = {k: v for k, v in nous.items() if env_ara.get(k) != v}
        if dif:
            backup_env()
            atomic_write(CFG['_env_path'], '\n'.join(_env_posa(_read_lines(CFG['_env_path']), dif)))
            canviat = True
        _regla_main()
        if canviat or not _upf_corrent():
            args = compose_base() + ['up', '-d', '--no-deps'] + (['--force-recreate'] if canviat else []) + ['upf']
            rc, out = run(args, timeout=CFG['apply_timeout'])
            if rc != 0:
                pista = (' — un altre contenidor ja fa servir el port (el UPF antic?): al PC del UPF, '
                         'docker ps --filter publish=8805/udp, i atura\'l amb docker stop <nom> && '
                         'docker update --restart=no <nom>') if 'port is already allocated' in out else ''
                raise RuntimeError('docker compose up upf ha fallat: ' + out[-600:] + pista)
        print(f'agent5g: UPF actiu (SMF {nous["SMF_IP"]}, anunciant {nous["UPF_HOST_IP"]}'
              f'{", configuració nova" if canviat else ""})', flush=True)
    else:
        if _upf_corrent():
            run(compose_base() + ['stop', 'upf'], timeout=CFG['apply_timeout'])
            print('agent5g: UPF aturat (el core no el fa servir)', flush=True)
    upf_json_desa(actiu=actiu, des_de=now())
    return {'actiu': actiu, 'canviat': canviat, 'corrent': _upf_corrent()}


def upf_propi_estat():
    if CFG.get('role') != 'upf':
        raise LookupError('aquest equip no és un UPF')
    u = _upf_cfg()
    env = read_env()
    return {'actiu': upf_json().get('actiu'), 'corrent': _upf_corrent(), 'config': u,
            'env': {k: env.get(k) for k in ('SMF_IP', 'UPF_HOST_IP', 'UPF_ADVERTISE_IP', 'UPF_IP',
                                            'UE_IPV4_INTERNET', 'UE_IPV4_IMS')},
            'pfcp': pfcp_log('upf') if _upf_corrent() else None,
            'metriques': upf_metriques(u['upf_ip']) if _upf_corrent() else None}


class Handler(BaseHTTPRequestHandler):
    server_version = 'agent5g'
    timeout = 30
    sys_version = ''

    def log_message(self, fmt, *args):
        sys.stderr.write('%s %s %s\n' % (now(), self.client_address[0], fmt % args))

    def client_cn(self):
        cert = self.connection.getpeercert() or {}
        for rdn in cert.get('subject', ()):
            for k, v in rdn:
                if k == 'commonName':
                    return v
        return None

    def send_json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        cn = self.client_cn()
        if cn not in CFG['allowed_client_cn']:
            self.send_json(403, {'error': 'client no autoritzat'})
            return None
        return cn

    def body(self):
        n = int(self.headers.get('Content-Length') or 0)
        if n > MAX_BODY:
            raise ValueError('cos massa gran')
        data = self.rfile.read(n) if n else b'{}'
        return json.loads(data or b'{}')

    def user(self):
        u = self.headers.get('X-Panel-User', '-')
        return u if NAME_RE.match(u) else '?'

    def via_enllac(self, method):
        """(core) /radios i /radio/<id>/... -> enllaç amb les ràdios. True si l'ha atès."""
        path = urlparse(self.path).path
        if path == '/upfs' or path.startswith('/upf/'):
            return self.via_enllac_upf(method, path)
        if path != '/radios' and not path.startswith('/radio/'):
            return False
        if ENLLAC is None:
            self.send_json(404, {'error': 'aquest equip no rep ràdios (enllaç desactivat)'})
            return True
        if path == '/radios':
            self.send_json(200, {'radios': ENLLAC.radios()})
            return True
        resta = self.path[len('/radio/'):]
        rid, _, cami = resta.partition('/')
        try:
            body = self.body_raw() if method == 'POST' else None
            # aplicar / arrencar el projecte pot trigar minuts
            llarg = method == 'POST' and urlparse('/' + cami).path in ('/apply', '/project', '/plmn', '/tdd')
            codi, ctype, dades = ENLLAC.peticio(rid, method, '/' + cami, self.user(), body,
                                                timeout=CFG['apply_timeout'] + 30 if llarg else 120)
        except LookupError as e:
            self.send_json(503, {'error': str(e)})
            return True
        except ValueError as e:
            self.send_json(400, {'error': str(e)})
            return True
        except Exception as e:  # noqa: BLE001
            self.send_json(502, {'error': f'ràdio {rid}: {type(e).__name__}'})
            return True
        self.send_response(codi)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(dades)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(dades)
        return True

    def via_enllac_upf(self, method, path):
        if ENLLAC is None:
            self.send_json(404, {'error': 'aquest equip no rep UPF (enllaç desactivat)'})
            return True
        if path == '/upfs':
            self.send_json(200, {'upfs': ENLLAC.upfs()})
            return True
        uid, _, cami = self.path[len('/upf/'):].partition('/')
        try:
            body = self.body_raw() if method == 'POST' else None
            codi, ctype, dades = ENLLAC.peticio('upf:' + uid, method, '/' + cami, self.user(), body,
                                                timeout=CFG['apply_timeout'] + 30 if method == 'POST' else 60)
        except LookupError as e:
            self.send_json(503, {'error': str(e)})
            return True
        except ValueError as e:
            self.send_json(400, {'error': str(e)})
            return True
        except Exception as e:  # noqa: BLE001
            self.send_json(502, {'error': f'UPF {uid}: {type(e).__name__}'})
            return True
        self.send_response(codi)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(dades)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(dades)
        return True

    def body_raw(self):
        n = int(self.headers.get('Content-Length') or 0)
        if n > MAX_BODY:
            raise ValueError('cos massa gran')
        return self.rfile.read(n) if n else b'{}'

    def do_GET(self):
        cn = self.authorized()
        if not cn:
            return
        if self.via_enllac('GET'):
            return
        url = urlparse(self.path)
        qs = parse_qs(url.query)
        try:
            if url.path == '/health':
                self.send_json(200, {'ok': True, 'role': CFG.get('role'), 'time': now(),
                                     'env_file': CFG['_env_path'],
                                     'containers': CFG['containers'],
                                     'services': CFG['services'],
                                     'log_files': sorted(CFG['log_files']),
                                     'project_actions': CFG['project_actions'],
                                     'ue_capture': bool(CFG.get('ue_capture')),
                                     'estat5g': 'amf' in CFG['containers'],
                                     'nom': CFG.get('name'), 'voip': bool(voip_cfg()['permes']),
                                     'radio_ues': bool(_radio_cfg()),
                                     'enllac': ({**ENLLAC_ESTAT, 'connectat': ENLLAC_ESTAT['connexions'] > 0}
                                                if CFG.get('core') else None),
                                     'rep_radios': ENLLAC is not None,
                                     'upf_gestionat': upf_gestionat(),
                                     'upf': ({'actiu': upf_json().get('actiu'), **_upf_cfg()}
                                             if CFG.get('role') == 'upf' else None)})
            elif url.path == '/env':
                self.send_json(200, {'env': public_env()})
            elif url.path == '/env/backups':
                baks = sorted((f for f in os.listdir(CFG['backup_dir']) if BACKUP_RE.match(f)),
                              reverse=True)
                self.send_json(200, {'backups': baks})
            elif url.path == '/containers':
                self.send_json(200, {'containers': container_status()})
            elif url.path == '/logs':
                name = qs.get('container', [''])[0]
                self.send_json(200, {'log': container_logs(name, tail_n(qs))})
            elif url.path == '/logfile':
                name = qs.get('name', [''])[0]
                self.send_json(200, {'log': file_log(name, tail_n(qs))})
            elif url.path == '/audit':
                self.send_json(200, {'audit': audit_tail(tail_n(qs))})
            elif url.path == '/voip/desplegament':
                try:
                    self.send_json(200, voip_desplegament())
                except LookupError:
                    self.send_json(404, {'error': 'VoIP no permesa en aquest equip'})
            elif url.path == '/voip':
                try:
                    self.send_json(200, voip_status())
                except LookupError:
                    self.send_json(404, {'error': 'aquest equip no té MongoDB'})
            elif url.path == '/subs':
                try:
                    self.send_json(200, {'subscriptors': subs_list()})
                except LookupError:
                    self.send_json(404, {'error': 'aquest equip no té MongoDB'})
            elif url.path == '/plmn':
                self.send_json(200, plmn_status())
            elif url.path == '/tdd':
                try:
                    self.send_json(200, tdd_status())
                except LookupError:
                    self.send_json(404, {'error': 'TDD no gestionat en aquest equip'})
            elif url.path == '/gnbs':
                try:
                    self.send_json(200, {'gnbs': gnb_list()})
                except LookupError:
                    self.send_json(404, {'error': 'captura no configurada'})
            elif url.path == '/estat5g':
                try:
                    self.send_json(200, estat5g())
                except LookupError:
                    self.send_json(404, {'error': 'aquest equip no té AMF'})
            elif url.path == '/upf':
                try:
                    self.send_json(200, upf_core_estat())
                except LookupError as e:
                    self.send_json(404, {'error': str(e)})
            elif url.path == '/upf_estat':
                try:
                    self.send_json(200, upf_propi_estat())
                except LookupError as e:
                    self.send_json(404, {'error': str(e)})
            elif url.path == '/upf_metriques':
                if CFG.get('role') != 'upf':
                    self.send_json(404, {'error': 'aquest equip no és un UPF'})
                else:
                    self.send_json(200, upf_metriques(_upf_cfg()['upf_ip']))
            elif url.path == '/radio_ues':
                try:
                    self.send_json(200, radio_ues())
                except LookupError:
                    self.send_json(404, {'error': 'aquest equip no té gNB'})
            elif url.path == '/ues':
                try:
                    self.send_json(200, {'ues': ue_list(), 'user_agents': ua_list()})
                except LookupError:
                    self.send_json(404, {'error': 'captura no configurada'})
            else:
                self.send_json(404, {'error': 'no trobat'})
        except ValueError as e:
            self.send_json(400, {'error': str(e)})
        except Exception as e:  # noqa: BLE001
            self.send_json(500, {'error': type(e).__name__})

    def do_POST(self):
        cn = self.authorized()
        if not cn:
            return
        if self.via_enllac('POST'):         # sense LOCK: no bloqueja les operacions del core
            return
        path = urlparse(self.path).path
        user = self.user()
        try:
            data = self.body()
            if path == '/upf':                    # (core) cada funció agafa LOCK quan toca fitxers
                acc = data.get('accio')
                try:
                    with UPF_LOCK:
                        if acc == 'separa' and data.get('upf_id'):
                            if not UPF_ID_RE.match(str(data['upf_id'])):
                                raise ValueError('UPF invàlid')
                            r = upf_selecciona(str(data['upf_id']), user)
                        elif acc == 'separa':
                            r = upf_separa_ip(data.get('ip'), user)
                        elif acc == 'ajunta':
                            r = upf_ajunta(user)
                        elif acc == 'auto':
                            r = upf_auto(bool(data.get('valor')), user)
                            audit(cn, user, 'upf-auto', {'auto': r['auto']})
                        else:
                            raise ValueError('acció invàlida')
                except LookupError as e:
                    self.send_json(404, {'error': str(e)})
                else:
                    self.send_json(200, {'ok': True, **r})
                return
            with LOCK:
                if path == '/upf_configura':
                    try:
                        r = upf_configura(data)
                    except LookupError as e:
                        self.send_json(404, {'error': str(e)})
                    else:
                        audit(cn, user, 'upf-configura', {'actiu': r['actiu'], 'canviat': r['canviat']})
                        self.send_json(200, {'ok': True, **r})
                elif path == '/env':
                    bak, old = write_env(data.get('changes'))
                    audit(cn, user, 'env', {'old': old, 'new': data['changes'], 'backup': bak})
                    self.send_json(200, {'ok': True, 'backup': bak, 'old': old})
                elif path == '/env/restore':
                    bak = restore_env(data.get('name'))
                    audit(cn, user, 'restore', {'from': data['name'], 'backup': bak})
                    self.send_json(200, {'ok': True, 'backup': bak})
                elif path == '/project':
                    rc, out = project_action(data.get('accio'))
                    audit(cn, user, 'project', {'accio': data['accio'], 'rc': rc}, ok=rc == 0)
                    self.send_json(200, {'ok': rc == 0, 'rc': rc, 'output': out})
                elif path == '/voip/desplegament':
                    try:
                        r = voip_desplega(data.get('accio'))
                    except LookupError:
                        self.send_json(404, {'error': 'VoIP no permesa en aquest equip'})
                    else:
                        audit(cn, user, f'voip-{r["accio"]}', r)
                        self.send_json(200, {'ok': True, **r})
                elif path == '/voip':
                    acc = data.get('accio')
                    try:
                        if acc == 'alta':
                            r = voip_alta(data.get('imsi'), data.get('msisdn'))
                        elif acc == 'baixa':
                            r = voip_baixa(data.get('imsi'))
                        else:
                            raise ValueError('acció invàlida')
                    except LookupError:
                        self.send_json(404, {'error': 'aquest equip no té MongoDB'})
                    else:
                        audit(cn, user, f'voip-{acc}', {'imsi': r.get('imsi'), 'msisdn': r.get('msisdn')})
                        self.send_json(200, {'ok': True, **r})
                elif path == '/subs':
                    acc = data.get('accio')
                    try:
                        if acc == 'desa':
                            r = subs_save(data.get('sub'), bool(data.get('nou')))
                        elif acc == 'esborra':
                            r = subs_delete(data.get('imsi'))
                        elif acc == 'claus':
                            r = subs_keys(data.get('imsi'))
                        else:
                            raise ValueError('acció invàlida')
                    except LookupError:
                        self.send_json(404, {'error': 'aquest equip no té MongoDB'})
                    else:
                        # mai K/OPc a l'auditoria: només qui les ha consultat i de quin IMSI
                        audit(cn, user, f'subs-{acc}', {'imsi': r.get('imsi'), 'nou': r.get('nou'), 'voip': r.get('voip')}
                              if acc == 'claus' or 'k' in r else r)
                        self.send_json(200, {'ok': True, **r})
                elif path == '/plmn':
                    r = plmn_set(data.get('activa'), data.get('valors'))
                    audit(cn, user, 'plmn', r)
                    self.send_json(200, {'ok': True, **r})
                elif path == '/tdd':
                    try:
                        r = tdd_set(data.get('activa'), data.get('valors'))
                    except LookupError:
                        self.send_json(404, {'error': 'TDD no gestionat en aquest equip'})
                    else:
                        audit(cn, user, 'tdd', r)
                        self.send_json(200, {'ok': True, **r})
                elif path == '/apply':
                    rc, out = apply_services(data.get('services'))
                    audit(cn, user, 'apply', {'services': data['services'], 'rc': rc}, ok=rc == 0)
                    self.send_json(200, {'ok': rc == 0, 'rc': rc, 'output': out})
                else:
                    self.send_json(404, {'error': 'no trobat'})
        except (ValueError, json.JSONDecodeError, RuntimeError) as e:
            audit(cn, user, path.strip('/'), {'error': str(e)[:300]}, ok=False)
            self.send_json(400, {'error': str(e)})
        except subprocess.TimeoutExpired:
            audit(cn, user, path.strip('/'), {'error': 'timeout'}, ok=False)
            self.send_json(504, {'error': 'timeout'})
        except Exception as e:  # noqa: BLE001
            audit(cn, user, path.strip('/'), {'error': type(e).__name__}, ok=False)
            self.send_json(500, {'error': type(e).__name__})


# ---------------------------------------------------------------- enllaç ràdio -> core
# Com la gNodeB amb l'AMF: és la RÀDIO qui truca al CORE, i al core li és igual quina IP
# tingui la ràdio. L'única IP fixa és la del core.
#
#   ràdio (agent5g, "core": "IP_core")  --mTLS-->  agent del core, port 9544 ("enllac")
#
# La ràdio obre i manté unes quantes connexions TLS cap al core (amb el seu certificat de
# la CA; el core es comprova pel certificat, CN agent-core). Cada connexió queda en espera
# i, quan el panell vol parlar amb aquella ràdio, l'agent del core hi escriu UNA petició
# HTTP i la ràdio la respon amb el mateix Handler de sempre (mateixa llista blanca).
# Després la connexió es tanca i la ràdio n'obre una de nova. El panell hi arriba a través
# de l'agent del core: GET /radios i /radio/<id>/<camí de sempre>.
#
# Si la xarxa no hi és (arrencada, cable, DHCP...), la ràdio ho reintenta sola cada pocs
# segons sense límit. Les connexions en espera es renoven cada minut, així que un canvi
# d'IP de la ràdio es nota en menys d'un minut.
ENLLAC_PORT = 9544
ENLLAC_CONNS = 3          # connexions en espera per ràdio (peticions en paral·lel del panell)
ENLLAC_EDAT = 60          # el core no fa servir connexions en espera de més de 60 s (les tanca)
ENLLAC_ESPERA = 90        # la ràdio, si en 90 s no rep res, la tanca i n'obre una altra
ENLLAC_HOLA = b'agent5g-enllac 1\n'   # el core l'envia quan ha acceptat el certificat de la ràdio
RADIO_ID_RE = re.compile(r'^[A-Za-z0-9_.-]{1,64}$')
ENLLAC_ESTAT = {'core': None, 'connectat': False, 'des_de': None, 'darrer_error': None,
                'connexions': 0}


def _cn(cert):
    for rdn in (cert or {}).get('subject', ()):
        for k, v in rdn:
            if k == 'commonName':
                return v
    return None


def radio_id(cn):
    """agent-radio-aula2 -> aula2; agent-radio (certificat antic sense nom) -> radio."""
    if not cn or not cn.startswith('agent-radio'):
        return None
    rid = cn[len('agent-radio'):].lstrip('-') or 'radio'
    return rid if RADIO_ID_RE.match(rid) else None


class Enllac:
    """Costat core: ràdios connectades i les seves connexions en espera."""

    def __init__(self):
        self.cond = threading.Condition()
        self.pool = {}          # id -> [(sslsock, t, ip)]
        self.info = {}          # id -> {ip, des_de, darrer, cn}
        self.avisos = {}

    # -- acceptar ràdios
    def escolta(self, listen, port):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.verify_mode = ssl.CERT_REQUIRED      # la ràdio ha de portar certificat de la CA
        ctx.load_cert_chain(CFG['cert'], CFG['key'])
        ctx.load_verify_locations(CFG['ca'])
        while True:
            try:
                srv = socket.create_server((listen, port))
                break
            except OSError as e:         # p. ex. la xarxa encara no hi és o el port és ocupat
                print(f'agent5g: no puc escoltar ràdios a {listen}:{port} ({e}); ho reintento', flush=True)
                time.sleep(10)
        print(f'agent5g: esperant ràdios i UPF a {listen}:{port} (enllaç cap al core)', flush=True)
        threading.Thread(target=self._neteja, daemon=True).start()
        while True:
            try:
                raw, addr = srv.accept()
            except OSError:
                time.sleep(1)
                continue
            threading.Thread(target=self._nova, args=(ctx, raw, addr), daemon=True).start()

    def _nova(self, ctx, raw, addr):
        try:
            raw.settimeout(10)
            s = ctx.wrap_socket(raw, server_side=True)
            cn = _cn(s.getpeercert())
            rid = radio_id(cn)
            if not rid and upf_id(cn):           # PC del UPF: clau "upf:<nom>"
                rid = 'upf:' + upf_id(cn)
            if not rid:
                self._avis(addr[0], f'enllaç rebutjat de {addr[0]}: el certificat no és de ràdio ni de UPF (CN={cn})')
                s.close()
                return
            s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            s.sendall(ENLLAC_HOLA)            # la ràdio sap que el core l'ha acceptada
        except (OSError, ssl.SSLError) as e:
            raw.close()
            self._avis(addr[0], f'enllaç fallit de {addr[0]}: {type(e).__name__}: {str(e)[:120]}')
            return
        t = time.time()
        with self.cond:
            # nova = no la veiem fa més de 15 s (les connexions es renoven cada minut)
            nou = rid not in self.info or t - self.info[rid].get('darrer', 0) > 15
            inf = self.info.setdefault(rid, {'des_de': now()})
            canvi = nou or inf.get('ip') != addr[0]
            if canvi:
                inf['des_de'] = now()
                print(f'agent5g: ' + (f'UPF "{rid[4:]}" connectat' if rid.startswith('upf:') else
                                      f'ràdio "{rid}" connectada') + f' des de {addr[0]}', flush=True)
            try:
                ip_core = s.getsockname()[0]        # la IP del core que veu aquest equip
            except OSError:
                ip_core = None
            inf.update(ip=addr[0], darrer=t, cn=cn, ip_core=ip_core)
            lst = self.pool.setdefault(rid, [])
            lst.append((s, t, addr[0]))
            while len(lst) > 2 * ENLLAC_CONNS:   # una ràdio no pot acumular connexions
                lst.pop(0)[0].close()
            self.cond.notify_all()
        if canvi and rid.startswith('upf:'):     # un UPF ha trucat: el core decideix si el fa servir
            threading.Thread(target=self._upf_nou, args=(rid[4:],), daemon=True).start()

    def _upf_nou(self, uid):
        time.sleep(1)                             # que hi hagi alguna connexió més en espera
        upf_rebut(uid)

    def _avis(self, ip, txt):
        """El mateix error de la mateixa IP, com a molt un cop cada 5 minuts (la ràdio reintenta)."""
        ara = time.time()
        clau = (ip, txt)
        if ara - self.avisos.get(clau, 0) > 300:
            self.avisos[clau] = ara
            print('agent5g: ' + txt, flush=True)

    def _neteja(self):
        """Tanca les connexions massa velles o que la ràdio ja ha tancat."""
        import select
        while True:
            time.sleep(5)
            with self.cond:
                ara = time.time()
                for rid, lst in self.pool.items():
                    vives = []
                    for c in lst:
                        s, t, _ip = c
                        try:
                            tancada = bool(select.select([s], [], [], 0)[0])   # EOF: la ràdio ha tancat
                        except (OSError, ValueError):
                            tancada = True
                        if tancada or ara - t > ENLLAC_EDAT:
                            try:
                                s.close()
                            except OSError:
                                pass
                        else:
                            vives.append(c)
                    lst[:] = vives
                    if vives and rid in self.info:     # encara hi és: "vista ara"
                        self.info[rid]['darrer'] = ara

    def _agafa(self, rid, espera=8.0):
        fi = time.time() + espera
        with self.cond:
            while True:
                lst = self.pool.get(rid) or []
                while lst:
                    s, t, _ip = lst.pop()          # la més nova
                    if time.time() - t <= ENLLAC_EDAT:
                        return s
                    s.close()
                resta = fi - time.time()
                if resta <= 0 or rid not in self.info:
                    return None
                self.cond.wait(resta)

    def radios(self):
        ara = time.time()
        with self.cond:
            out = []
            for rid, inf in sorted(self.info.items()):
                if ':' in rid:
                    continue
                n = len(self.pool.get(rid) or [])
                connectada = n > 0 or ara - inf.get('darrer', 0) < 15
                out.append({'id': rid, 'ip': inf.get('ip'), 'connectada': connectada,
                            'connexions': n, 'des_de': inf.get('des_de'),
                            'darrer_s': round(ara - inf.get('darrer', ara))})
            return out

    def upfs(self):
        ara = time.time()
        with self.cond:
            out = []
            for rid, inf in sorted(self.info.items()):
                if not rid.startswith('upf:'):
                    continue
                n = len(self.pool.get(rid) or [])
                out.append({'id': rid[4:], 'ip': inf.get('ip'), 'ip_core': inf.get('ip_core'),
                            'connectat': n > 0 or ara - inf.get('darrer', 0) < 15, 'connexions': n,
                            'des_de': inf.get('des_de'), 'darrer_s': round(ara - inf.get('darrer', ara))})
            return out

    def peticio(self, rid, method, path, user, body=None, timeout=120):
        """Envia una petició HTTP a la ràdio per una connexió en espera -> (codi, ctype, cos)."""
        import http.client
        if not RADIO_ID_RE.match((rid or '').replace('upf:', '', 1)) or rid not in self.info:
            raise LookupError('equip desconegut')
        intents = 2 if method == 'GET' else 1
        for i in range(intents):
            s = self._agafa(rid)
            if s is None:
                raise LookupError('l\'equip no està connectat al core')
            try:
                s.settimeout(timeout)
                cap = (f'{method} {path} HTTP/1.0\r\nHost: radio\r\nX-Panel-User: {user}\r\n'
                       'Connection: close\r\n')
                if body is not None:
                    cap += f'Content-Type: application/json\r\nContent-Length: {len(body)}\r\n'
                s.sendall(cap.encode('latin-1') + b'\r\n' + (body or b''))
                r = http.client.HTTPResponse(s)
                r.begin()
                dades = r.read(64 * 1024 * 1024)
                with self.cond:
                    self.info[rid]['darrer'] = time.time()
                return r.status, r.getheader('Content-Type', 'application/json'), dades
            except (OSError, http.client.HTTPException, ssl.SSLError):
                if i + 1 >= intents:
                    raise
            finally:
                try:
                    s.close()
                except OSError:
                    pass


ENLLAC = None


def _ctx_cap_al_core():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.check_hostname = False       # el core s'identifica pel certificat (CN), no per la IP
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.load_verify_locations(CFG['ca'])
    ctx.load_cert_chain(CFG['cert'], CFG['key'])
    return ctx


class _ServidorFals:
    """BaseRequestHandler només necessita un objecte 'server'."""
    server_name = 'agent5g'
    server_port = 0


class HandlerEnllac(Handler):
    """El mateix Handler, però per una connexió que ha obert la ràdio cap al core: l'altre
    extrem ja s'ha comprovat (certificat de la CA amb CN agent-core), i és l'agent del core,
    que només reenvia peticions del panell autenticat."""

    def authorized(self):
        return 'panel5g-via-core'

    def log_message(self, fmt, *args):
        sys.stderr.write('%s core %s\n' % (now(), fmt % args))


def _enllac_fil(core, port, ctx, n):
    import select
    espera, darrer_avis = 2, 0
    while True:
        try:
            raw = socket.create_connection((core, port), timeout=10)
            raw.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            s = ctx.wrap_socket(raw)
            cn = _cn(s.getpeercert())
            if cn != 'agent-core':
                s.close()
                raise ssl.SSLError(f'l\'altre extrem no és l\'agent del core (CN={cn})')
            # Amb TLS 1.3 el core comprova el nostre certificat DESPRÉS del handshake: esperem
            # la salutació per saber que ens ha acceptat (si no, arriba l'error del certificat).
            s.settimeout(10)
            hola = b''
            while not hola.endswith(b'\n') and len(hola) < 64:
                b = s.recv(64 - len(hola))
                if not b:
                    break
                hola += b
            if hola != ENLLAC_HOLA:
                s.close()
                raise ConnectionError('el core ha tancat la connexió sense acceptar-nos '
                                      '(certificat antic, d\'una altra CA, o agent del core antic?)')
        except (OSError, ssl.SSLError) as e:
            err = f'{type(e).__name__}: {str(e)[:160]}'
            if 'certificat' in err.lower() or 'CERT' in err:
                err += (' (torna a emparellar: al core, sudo emparella-upf <nom>)' if CFG.get('role') == 'upf' else
                        ' (si el certificat és d\'abans de l\'enllaç ràdio->core, torna a '
                        'emparellar: al core, sudo emparella-radio <nom>)')
            if n == 0 and (ENLLAC_ESTAT['darrer_error'] != err or time.time() - darrer_avis > 300):
                darrer_avis = time.time()
                print(f'agent5g: no puc connectar amb el core {core}:{port}: {err}; '
                      f'ho torno a provar sol', flush=True)
            ENLLAC_ESTAT.update(darrer_error=err)
            if n == 0:
                ENLLAC_ESTAT['connectat'] = False
            time.sleep(espera)
            espera = min(espera * 2, 30)
            continue
        espera = 2
        with LOCK_ENLLAC:
            if not ENLLAC_ESTAT['connectat']:
                print(f'agent5g: connectat al core {core}:{port}', flush=True)
                ENLLAC_ESTAT.update(connectat=True, des_de=now(), darrer_error=None)
            ENLLAC_ESTAT['connexions'] += 1
        try:
            if not s.pending() and not select.select([s], [], [], ENLLAC_ESPERA)[0]:
                continue                     # cap petició: es renova la connexió
            HandlerEnllac(s, (core, port), _ServidorFals())
        except Exception as e:  # noqa: BLE001 - un error en una petició no atura l'enllaç
            print(f'agent5g: error atenent el core: {type(e).__name__}', flush=True)
        finally:
            with LOCK_ENLLAC:
                ENLLAC_ESTAT['connexions'] -= 1
            try:
                s.close()
            except OSError:
                pass


LOCK_ENLLAC = threading.Lock()


def enllac_radio():
    """Costat ràdio: manté ENLLAC_CONNS connexions obertes cap al core."""
    core, port = CFG['core'], int(CFG.get('core_port') or ENLLAC_PORT)
    ENLLAC_ESTAT['core'] = f'{core}:{port}'
    ctx = _ctx_cap_al_core()
    print(f'agent5g: enllaç cap al core {core}:{port} ({CFG.get("role")} truca al core)', flush=True)
    fils = [threading.Thread(target=_enllac_fil, args=(core, port, ctx, i), daemon=True)
            for i in range(int(CFG.get('enllac_connexions') or ENLLAC_CONNS))]
    for f in fils:
        f.start()
    return fils


def main():
    global CFG
    ap = argparse.ArgumentParser()
    ap.add_argument('-c', '--config', default='/etc/agent5g/agent5g.json')
    a = ap.parse_args()
    CFG = load_config(a.config)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.load_cert_chain(CFG['cert'], CFG['key'])
    ctx.load_verify_locations(CFG['ca'])
    global ENLLAC
    enl = CFG.get('enllac')
    if enl:                                   # core: rep les ràdios que hi truquen
        ENLLAC = Enllac()
        threading.Thread(target=ENLLAC.escolta, daemon=True,
                         args=(enl.get('listen') or '0.0.0.0', int(enl.get('port') or ENLLAC_PORT))).start()
    if CFG.get('core'):                       # ràdio: truca al core
        enllac_radio()
    if not CFG['listen']:                     # no escolta cap port: només l'enllaç
        print(f'agent5g ({CFG.get("role")}): sense port d\'escolta, només enllaç amb el core', flush=True)
        while True:
            time.sleep(3600)
    listen, auto = CFG['listen'], CFG['listen'] == 'auto'
    if auto:
        listen = ip_lan()
    try:
        srv = ThreadingHTTPServer((listen, CFG['port']), Handler)
    except OSError as e:
        # 99 = la IP de "listen" ja no és d'aquest equip (la xarxa/DHCP ha canviat).
        # Abans l'agent moria i systemd el reiniciava en bucle; ara escolta a la IP actual.
        try:
            pont = ipaddress.ip_address(listen) in ipaddress.ip_network('172.16.0.0/12')
        except ValueError:
            pont = True
        if e.errno != 99 or pont:             # el pont de Docker (agent del core) no es toca
            raise
        nova = ip_lan()
        print(f'agent5g: {listen} ja no és d\'aquest equip; escolto a {nova}. '
              f'Posa "listen": "auto" a la configuració per no veure aquest avís.', flush=True)
        listen, auto = nova, True
        srv = ThreadingHTTPServer((listen, CFG['port']), Handler)
    # Handshake al fil del client: un client lent no bloqueja l'accept.
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True, do_handshake_on_connect=False)
    print(f'agent5g escoltant a https://{listen}:{CFG["port"]} ({CFG.get("role")})', flush=True)
    if auto:
        threading.Thread(target=vigila_ip, args=(listen,), daemon=True).start()
    srv.serve_forever()


def ip_lan():
    """IP per on surt el trànsit (la de la LAN). No envia res: només tria la ruta."""
    for _ in range(30):                       # en arrencar, la xarxa pot trigar uns segons
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect(('1.1.1.1', 53))
                return s.getsockname()[0]
        except OSError:
            time.sleep(2)
    sys.exit('agent5g: no trobo cap IP de LAN (no hi ha ruta per defecte)')


def vigila_ip(actual):
    """Si el DHCP canvia la IP, surt perquè systemd reiniciï l'agent a la IP nova."""
    while True:
        time.sleep(30)
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect(('1.1.1.1', 53))
                ara = s.getsockname()[0]
        except OSError:
            continue
        if ara != actual:
            print(f'agent5g: la IP ha canviat ({actual} -> {ara}); reinicio', flush=True)
            os._exit(0)


if __name__ == '__main__':
    main()
