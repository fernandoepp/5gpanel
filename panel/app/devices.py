"""Vista per dispositiu (UE) del core Open5GS.

Ajunta tres fonts que el panell ja pot llegir a través de l'agent:
  * log de l'AMF  -> SUCI/SUPI, 5G-TMSI, cel·la, registres, service requests,
                     errors d'autenticació, paging, DNN rebutjats, slice de cada sessió
  * log de l'SMF  -> IP assignada a cada sessió PDU (i quan s'allibera)
  * captura NGAP  -> IMEISV/IMEI (model via tac.csv i la base de dades de TAC) i algorisme de xifrat NAS
  * User-Agent HTTP del pla d'usuari (ua_capture.py) -> model i SO, creuant la IP
                     del UE amb la IP que l'SMF li va donar en aquell moment

El resultat és una fitxa per IMSI, no una llista de missatges solts.
"""
import re
from datetime import datetime, timezone

ANSI = re.compile(r'\x1b\[[0-9;]*m')
DOCKER_TS = re.compile(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)\s+(.*)$')
O5GS = re.compile(r'^\d\d/\d\d \d\d:\d\d:\d\d\.\d+: \[(\w+)\] (\w+): (.*?)(?: \(\.\./[^)]*\))?$')
SUCI = re.compile(r'suci-(\d)-(\d{3})-(\d{2,3})-([0-9a-fA-F]+)-(\d+)-(\d+)-([0-9a-fA-F]+)')
SUPI = re.compile(r'imsi-(\d{5,15})')
TAG = re.compile(r'^\[(suci-[^\]]+|imsi-\d+)(?::[^\]]*)?\]\s*(.*)$')

RX = {
    'ids': re.compile(r'RAN_UE_NGAP_ID\[(\d+)\] AMF_UE_NGAP_ID\[(\d+)\](?: TAC\[(\d+)\] CellID\[(0x[0-9a-f]+)\])?'),
    'tmsi': re.compile(r'5G-S_(?:TMSI|GUTI)\[(?:PLMN_ID:0x[0-9a-f]+,)?AMF_ID:(0x[0-9a-f]+),M_TMSI:(0x[0-9a-f]+)\]'),
    'release_suci': re.compile(r'^\s*SUCI\[(suci-[^\]]+)\]'),
    'sess_amf': re.compile(r'UE SUPI\[imsi-(\d+)\] DNN\[([^\]]*)\].*?S_NSSAI\[SST:(\d+) SD:(0x[0-9a-f]+)\]'),
    'dnn_rej': re.compile(r'Ue requested DNN "([^"]+)" Not Supported'),
    'smf_add': re.compile(r'UE SUPI\[imsi-(\d+)\] DNN\[([^\]]*)\] IPv4\[([^\]]*)\] IPv6\[([^\]]*)\]'),
    'smf_del': re.compile(r'Removed Session: UE IMSI:\[imsi-(\d+)\] DNN:\[([^:\]]*):?(\d*)\] IPv4:\[([^\]]*)\]'),
    'reg_reject': re.compile(r'Registration reject \[(\d+)\]'),
}

# Causes 5GMM (TS 24.501 9.11.3.2) més habituals al laboratori
CAUSES = {
    3: 'UE il·legal', 5: 'PEI no acceptat', 6: 'ME il·legal', 7: 'serveis 5GS no permesos',
    9: 'identitat no derivable per la xarxa', 11: 'PLMN no permès', 12: 'àrea de seguiment no permesa',
    13: 'roaming no permès en aquesta TA', 15: 'cap cel·la adequada a la TA', 21: 'fallada de sincronització (SQN)',
    20: 'fallada de MAC', 22: 'congestió', 27: 'N1 no permès', 62: 'cap NSSAI permès',
    65: 'màxim de sessions PDU', 90: 'payload massa gran', 95: 'missatge semànticament incorrecte',
    96: 'informació obligatòria invàlida', 111: 'error de protocol',
}


LOCALE = re.compile(r'^[a-z]{2}(?:[-_][a-zA-Z]{2})?$')
MODEL_CODI = re.compile(r'\b(SM-[A-Z][A-Z0-9]{3,6}|Pixel \d+[a-z]?(?: (?:Pro|XL|a))*|CPH\d{4}|RMX\d{4}|'
                        r'M\d{4}[A-Z]\d+[A-Z]*|[0-9]{4}[A-Z0-9]{3,}[A-Z]|moto [a-z0-9() ]+?|XQ-[A-Z]{2}\d{2}|'
                        r'iPhone\d+,\d+|iPad\d+,\d+)\b')
NO_MODEL = {'K', 'U', 'wv', 'Linux', 'Mobile', 'x86_64'}


def parse_ua(ua):
    """Treu {model, so} d'un User-Agent. Torna None si no hi ha res útil."""
    if not ua:
        return None
    so = model = None
    m = re.search(r'Android ([\d.]+)', ua)
    if m:
        so = f'Android {m.group(1)}'
        par = re.search(r'\(([^()]*Android [^()]*)\)', ua)
        if par:
            toks = [t.strip() for t in par.group(1).split(';')]
            i = next(i for i, t in enumerate(toks) if t.startswith('Android'))
            for t in toks[i + 1:]:
                t = re.sub(r'\s*Build/.*$', '', t).strip()
                if not t or t in NO_MODEL or LOCALE.match(t) or t.startswith(('rv:', 'Mobile')):
                    continue
                model = t
                break
    else:
        m = re.search(r'(?:iPhone|CPU) OS (\d+(?:_\d+)*)', ua) or re.search(r'\biOS[ /](\d+(?:\.\d+)*)', ua)
        if m:
            so = 'iOS ' + m.group(1).replace('_', '.')
        elif 'CFNetwork/' in ua and 'Darwin/' in ua:
            so = 'iOS/iPadOS (Apple)'
        elif re.search(r'Samsung IMS', ua, re.I):
            so = 'Android (Samsung IMS)'
        if 'iPhone' in ua:
            model = 'iPhone'
    c = MODEL_CODI.search(ua)
    if c and (not model or model.lower() in ('iphone', 'k')):
        model = c.group(1)
    if model and model.upper().startswith('SAMSUNG '):
        model = model[8:]
    if not (model or so):
        return None
    return {'model': model, 'so': so}


def _owner_of_ip(devs, ip, ts):
    """IMSI que tenia la IP en aquell moment: l'última assignació (SMF) anterior a ts."""
    best, best_ts = None, ''
    for k, d in devs.items():
        for h in d['historial_ip']:
            if h['ip'] != ip:
                continue
            hts = (h.get('ts') or '')[:19]
            if ts and hts and hts > ts[:19]:
                continue
            if best is None or hts >= best_ts:
                best, best_ts = k, hts
    return best


def _iso(ts):
    return ts if ts else None


def _clean(text):
    """Línies (ts_iso, modul, nivell, missatge) del log de docker amb --timestamps."""
    out = []
    for raw in text.splitlines():
        line = ANSI.sub('', raw).rstrip()
        m = DOCKER_TS.match(line)
        ts, rest = (m.group(1), m.group(2)) if m else (None, line)
        o = O5GS.match(rest)
        if o:
            out.append((ts, o.group(1), o.group(2), o.group(3)))
        elif rest.strip():
            out.append((ts, '', '', rest.strip()))
    return out


def suci_to_imsi(suci):
    """Amb l'esquema nul (protecció 0) el MSIN va en clar dins del SUCI."""
    m = SUCI.search(suci or '')
    if not m:
        return None
    typ, mcc, mnc, _rid, scheme, _hn, msin = m.groups()
    if typ == '0' and scheme == '0' and msin.isdigit():
        return mcc + mnc + msin
    return None


def suci_info(suci):
    m = SUCI.search(suci or '')
    if not m:
        return None
    scheme = {'0': 'nul (sense ocultació)', '1': 'Perfil A (ECIES)', '2': 'Perfil B (ECIES)'}
    return {'plmn': f'{m.group(2)}-{m.group(3)}', 'proteccio': scheme.get(m.group(5), m.group(5))}


class Dev(dict):
    def __init__(self, key):
        super().__init__(
            imsi=None, suci=None, suci_info=None, estat='desconegut', connectat=False,
            registrat=False, tmsi=None, amf_id=None, tmsis=[], tac=None, cell_id=None,
            ran_ue_ngap_id=None, amf_ue_ngap_id=None, gnb_id=None, cella=None, estat_amf=None,
            primer=None, darrer=None,
            ultim_registre=None, sessions={}, historial_ip=[], dnn_rebutjats={},
            comptadors={'registres': 0, 'service_requests': 0, 'auth_fallides': 0,
                        'paging_fallit': 0, 'alliberaments': 0, 'desregistres': 0, 'rebuigs': 0},
            events=[], avisos=[], dispositiu={})
        self['_key'] = key

    def seen(self, ts):
        if ts:
            self['primer'] = self['primer'] or ts
            self['darrer'] = ts

    def event(self, ts, nivell, text, agrupa=False):
        ev = self['events']
        if agrupa and ev and ev[-1]['text'] == text:
            ev[-1]['n'] = ev[-1].get('n', 1) + 1
            ev[-1]['fins'] = ts
            return
        ev.append({'ts': ts, 'nivell': nivell, 'text': text})


def build(amf_log, smf_log='', capture=None, tac_db=None, noms=None, user_agents=None, models=None,
          viu=None):
    devs = {}            # clau: imsi o suci
    suci2imsi = {}
    tmsi2key = {}
    ngap2key = {}        # AMF_UE_NGAP_ID -> clau
    pending = None       # dades de l'últim InitialUEMessage encara sense identitat
    last_key = None

    def key_for(ident):
        if ident.startswith('imsi-'):
            return ident[5:]
        imsi = suci2imsi.get(ident) or suci_to_imsi(ident)
        if imsi:
            suci2imsi[ident] = imsi
            if ident in devs and imsi not in devs:     # fins ara només el coneixíem pel SUCI
                d = devs.pop(ident)
                d['_key'] = imsi
                devs[imsi] = d
            return imsi
        return ident

    def dev(key):
        d = devs.get(key)
        if d is None:
            d = devs[key] = Dev(key)
        if key.isdigit():
            d['imsi'] = key
        return d

    for ts, mod, lvl, msg in _clean(amf_log):
        t = TAG.match(msg)
        ident, body = (t.group(1), t.group(2)) if t else (None, msg)

        # ---- missatges sense identitat del UE
        if msg.startswith('InitialUEMessage'):
            pending = {'ts': ts}
            last_key = None
            continue
        m = RX['ids'].search(msg)
        if m and ident is None:
            ran, amf, tac, cell = m.groups()
            if tac:                                    # línia de l'InitialUEMessage
                pending = dict(pending or {}, ran=ran, amf=amf, tac=tac, cell=cell, ts=ts)
                if amf in ngap2key:
                    last_key = ngap2key[amf]
            else:                                      # línia de l'UE Context Release
                last_key = ngap2key.get(amf, last_key)
            continue
        m = RX['release_suci'].match(msg)
        if m:
            k = key_for(m.group(1))
            d = dev(k)
            d['connectat'] = False
            d['comptadors']['alliberaments'] += 1
            d.seen(ts)
            continue
        if msg.startswith('Registration request') and ident is None:
            if pending is not None:
                pending['proc'] = 'registre'
            continue
        if msg.startswith('Service request') and ident is None:
            if pending is not None:
                pending['proc'] = 'service'
            continue
        if msg.startswith('UE SUPI['):
            m = RX['sess_amf'].search(msg)
            if m:
                imsi, dnn, sst, sd = m.groups()
                d = dev(imsi)
                s = d['sessions'].setdefault(dnn, {'dnn': dnn})
                s.update(sst=int(sst), sd=None if sd == '0xffffff' else sd)
                d.seen(ts)
            continue
        if ident is None:
            continue

        # ---- missatges amb [suci-...] o [imsi-...]
        k = key_for(ident)
        d = dev(k)
        if ident.startswith('suci-'):
            d['suci'] = ident
            d['suci_info'] = suci_info(ident)
        d.seen(ts)
        last_key = k

        if pending is not None and 'amf' in pending:
            ngap2key[pending['amf']] = k
            d.update(ran_ue_ngap_id=pending['ran'], amf_ue_ngap_id=pending['amf'],
                     tac=pending['tac'], cell_id=pending['cell'], connectat=True)
            proc = pending.get('proc')
            if proc == 'registre':
                d['comptadors']['registres'] += 1
                d['ultim_registre'] = ts
                d.event(ts, 'info', 'Registration request')
            elif proc == 'service':
                d['comptadors']['service_requests'] += 1
                d.event(ts, 'info', 'Service request', agrupa=True)
            pending = None if proc else pending

        m = RX['tmsi'].search(body)
        if m:
            amf_id, tmsi = m.groups()
            d['amf_id'] = amf_id
            if d['tmsi'] != tmsi:
                d['tmsi'] = tmsi
                if tmsi not in d['tmsis']:
                    d['tmsis'].append(tmsi)
            tmsi2key[tmsi] = k
            continue
        if body.startswith('Registration complete'):
            d['registrat'] = True
            d.event(ts, 'ok', 'Registre completat')
        elif body.startswith('Deregistration request'):
            d['registrat'] = False
            d['connectat'] = False
            d['comptadors']['desregistres'] += 1
            d.event(ts, 'info', 'Desregistre (el mòbil s\'ha desconnectat de la xarxa)')
        elif body.startswith('Implicit De-registered'):
            d['registrat'] = False
            d['comptadors']['desregistres'] += 1
            d.event(ts, 'warn', 'Desregistre implícit: fa massa estona que no respon')
        elif body.startswith('Mobile Reachable Timer Expired'):
            d.event(ts, 'warn', 'Temporitzador d\'abastabilitat vençut (no s\'ha tornat a sentir)')
        elif body.startswith('Paging failed'):
            d['comptadors']['paging_fallit'] += 1
            d.event(ts, 'warn', 'Paging sense resposta')
        elif body.startswith('Authentication failure'):
            d['comptadors']['auth_fallides'] += 1
            if 'Synch' in body:
                d.event(ts, 'warn', 'Autenticació: SQN desincronitzat (es resincronitza sol)')
            elif 'MAC' in body:
                d.event(ts, 'error', 'Autenticació: fallada de MAC (Ki/OPc no coincideixen)')
            elif not body.startswith('Authentication failure ['):
                d.event(ts, 'warn', body)
        elif body.startswith('Authentication reject'):
            d['comptadors']['rebuigs'] += 1
            d.event(ts, 'error', 'Autenticació rebutjada')
        elif RX['reg_reject'].search(body):
            c = int(RX['reg_reject'].search(body).group(1))
            d['comptadors']['rebuigs'] += 1
            d.event(ts, 'error', f'Registre rebutjat: causa {c} ({CAUSES.get(c, "?")})')
        elif RX['dnn_rej'].search(body):
            dnn = RX['dnn_rej'].search(body).group(1)
            d['dnn_rebutjats'][dnn] = d['dnn_rebutjats'].get(dnn, 0) + 1
            d.event(ts, 'warn', f'Sessió PDU al DNN "{dnn}" rebutjada (no subscrit)', agrupa=True)
        elif body.startswith('Cannot find SUCI'):
            d['comptadors']['rebuigs'] += 1
            d.event(ts, 'error', 'El SUCI no és a la base de dades (subscriptor no donat d\'alta?)')
        elif 'DUPLICATED_PDU_SESSION_ID' in body:
            d.event(ts, 'info', 'Sessió PDU duplicada: es recrea (normal després d\'un re-registre)')
        elif lvl in ('WARNING', 'ERROR', 'FATAL'):
            d.event(ts, 'error' if lvl != 'WARNING' else 'warn', body[:200])

    # ---- SMF: IP de cada sessió
    for ts, mod, lvl, msg in _clean(smf_log):
        m = RX['smf_add'].search(msg)
        if m:
            imsi, dnn, ip4, ip6 = m.groups()
            d = dev(imsi)
            s = d['sessions'].setdefault(dnn, {'dnn': dnn})
            s.update(ipv4=ip4 or None, ipv6=ip6 or None, des_de=ts, activa=True)
            if ip4 and (not d['historial_ip'] or d['historial_ip'][-1]['ip'] != ip4):
                d['historial_ip'].append({'ip': ip4, 'dnn': dnn, 'ts': ts})
            continue
        m = RX['smf_del'].search(msg)
        if m:
            imsi, dnn, psi, ip4 = m.groups()
            d = devs.get(imsi)
            if d and dnn in d['sessions'] and d['sessions'][dnn].get('ipv4') == ip4:
                d['sessions'][dnn]['activa'] = False

    # ---- estat en viu de l'AMF i l'SMF (agent /estat5g, API JSON d'Open5GS). És el que
    # tenen ara a memòria, així que mana sobre el que s'ha deduït dels logs (que es perden).
    viu = viu or {}
    if viu.get('ues') is not None:
        al_amf = set()
        for u in viu['ues']:
            k = u.get('imsi') or u.get('suci')
            if not k:
                continue
            d = dev(k)
            d.seen(viu.get('ts'))
            al_amf.add(k)
            if u.get('suci'):
                d['suci'] = u['suci']
                d['suci_info'] = d['suci_info'] or suci_info(u['suci'])
            mm, cm = u.get('mm_state'), u.get('cm_state')
            d['estat_amf'] = mm
            d['registrat'] = mm == 'registered' if mm else True
            d['connectat'] = cm == 'connected'
            for f in ('tac', 'cell_id', 'gnb_id', 'cella', 'ran_ue_ngap_id', 'amf_ue_ngap_id'):
                if u.get(f) is not None:
                    d[f] = str(u[f]) if f in ('ran_ue_ngap_id', 'amf_ue_ngap_id') else u[f]
            if u.get('tmsi'):
                d['tmsi'] = u['tmsi']
                if u['tmsi'] not in d['tmsis']:
                    d['tmsis'].append(u['tmsi'])
                tmsi2key[u['tmsi']] = k
            info = d['dispositiu']
            for f in ('imeisv', 'imei'):
                if u.get(f):
                    info[f] = u[f]
            if u.get('xifrat'):
                info['ea'] = u['xifrat'].upper()
                info['nas_xifrat'] = u['xifrat'].lower() != 'nea0'
            if u.get('slices'):
                d['slices'] = u['slices']
        for k, d in devs.items():
            if k not in al_amf:                 # l'AMF ja no en té context
                d['registrat'] = d['connectat'] = False
    if viu.get('pdus') is not None:
        for d in devs.values():
            for s in d['sessions'].values():
                s['activa'] = False
        for p in viu['pdus']:
            if not p.get('imsi') or not p.get('dnn'):
                continue
            d = dev(p['imsi'])
            s = d['sessions'].setdefault(p['dnn'], {'dnn': p['dnn']})
            s.update(ipv4=p.get('ipv4'), ipv6=p.get('ipv6'), sst=p.get('sst'), sd=p.get('sd'),
                     psi=p.get('psi'), activa=True, en_repos=p.get('estat') == 'inactive',
                     upf=p.get('upf'), fiveqi=p.get('5qi'))
            ip4 = p.get('ipv4')
            if ip4 and (not d['historial_ip'] or d['historial_ip'][-1]['ip'] != ip4):
                d['historial_ip'].append({'ip': ip4, 'dnn': p['dnn'], 'ts': d['darrer']})

    # ---- captura NGAP (agent): IMEISV i xifrat
    for c in capture or []:
        k = None
        if c.get('imsi') and c['imsi'] in devs:
            k = c['imsi']
        elif c.get('tmsi'):
            try:
                tm = c['tmsi']
                tm = hex(int(tm, 16) if str(tm).startswith('0x') else int(tm))
            except ValueError:
                tm = None
            k = tmsi2key.get(tm)
        if not k:
            continue
        info = devs[k]['dispositiu']
        for f in ('imeisv', 'imei', 'masked_imeisv'):
            if c.get(f):
                info[f] = c[f]
        if c.get('ea'):
            info['ea'] = c['ea']
            info['nas_xifrat'] = c.get('nas_xifrat')

    # ---- User-Agent HTTP del pla d'usuari -> model i SO
    for u in sorted(user_agents or [], key=lambda x: x.get('darrer') or ''):
        k = _owner_of_ip(devs, u.get('ip'), u.get('darrer'))
        if not k:
            continue
        info = devs[k]['dispositiu']
        uas = info.setdefault('user_agents', [])
        uas.append({'ua': u.get('ua'), 'ip': u.get('ip'), 'darrer': u.get('darrer'), 'n': u.get('n')})
        p = parse_ua(u.get('ua'))
        if p:
            if p.get('model'):
                info['model_trafic'] = p['model']
            if p.get('so'):
                info['so'] = p['so']

    # ---- acabats
    out = []
    for k, d in devs.items():
        info = d['dispositiu']
        ident = info.get('imeisv') or info.get('imei') or info.get('masked_imeisv')
        if ident:
            info['tac'] = ident[:8]
            info['emmascarat'] = not (info.get('imeisv') or info.get('imei'))
            ti = tac_db.info(ident[:8]) if hasattr(tac_db, 'info') else None
            if ti:
                info['model'] = ti['model']
                info['model_detall'] = ti['detall']
                info['tac_font'] = ti['font']
            else:
                info['model'] = (tac_db or {}).get(ident[:8])
        if info.get('model_trafic'):
            codi = info['model_trafic']
            nom = (models or {}).get(codi.upper())
            info['model_codi'] = codi
            if nom:
                info['model_trafic'] = f'{nom} ({codi})'
        if not info.get('model') and info.get('model_trafic'):
            info['model'] = info['model_trafic']
            info['model_font'] = 'User-Agent'
        elif info.get('model'):
            info['model_font'] = 'TAC'
        if info.get('user_agents'):
            info['user_agents'] = sorted(info['user_agents'], key=lambda x: x.get('darrer') or '',
                                         reverse=True)[:5]
        d['nom'] = (noms or {}).get(d['imsi'] or '')
        d['estat'] = ('connectat' if d['connectat'] else
                      'inactiu' if d['registrat'] else 'desregistrat')
        d['sessions'] = sorted(d['sessions'].values(), key=lambda s: s['dnn'])
        d['events'] = d['events'][-40:]
        d['historial_ip'] = d['historial_ip'][-10:]
        d['avisos'] = diagnostics(d)
        d.pop('_key', None)
        out.append(dict(d))
    out.sort(key=lambda d: d['darrer'] or '', reverse=True)
    return out


def diagnostics(d):
    av = []
    c = d['comptadors']
    for dnn, n in d['dnn_rebutjats'].items():
        txt = (f'Demana el DNN "{dnn}" i el core el rebutja ({n} cops). ')
        if dnn.lower() == 'ims':
            txt += ('És la veu (VoNR/VoLTE): el mòbil ho reintenta cada pocs segons i genera '
                    'Service Requests i alliberaments contínuament. Afegeix el DNN "ims" al '
                    'subscriptor (WebUI) o desactiva VoLTE/VoNR/Wi-Fi calling al mòbil.')
        else:
            txt += 'Afegeix-lo al subscriptor i a l\'SMF, o treu-lo de l\'APN del mòbil.'
        av.append({'nivell': 'warn', 'text': txt})
    if c['paging_fallit']:
        av.append({'nivell': 'warn', 'text':
                   f'No ha respost al paging {c["paging_fallit"]} cops: probablement ha canviat a '
                   '4G/una altra xarxa, ha perdut cobertura o té el mode avió.'})
    if c['auth_fallides']:
        av.append({'nivell': 'info', 'text':
                   f'{c["auth_fallides"]} fallades d\'autenticació. Si són de sincronització (SQN) és '
                   'normal la primera vegada amb una SIM reprogramada; si són de MAC, revisa Ki/OPc.'})
    if c['rebuigs']:
        av.append({'nivell': 'error', 'text': f'{c["rebuigs"]} rebuigs del core. Mira l\'activitat.'})
    if c['registres'] >= 3 and c['registres'] > 0:
        av.append({'nivell': 'info', 'text':
                   f'S\'ha registrat {c["registres"]} cops: cada re-registre canvia el 5G-TMSI i '
                   're-crea la sessió (IP nova).'})
    dsp = d['dispositiu']
    if not (dsp.get('imeisv') or dsp.get('imei') or dsp.get('masked_imeisv')):
        av.append({'nivell': 'info', 'text':
                   'IMEISV encara desconegut: l\'AMF el rep quan el mòbil completa el registre '
                   '(Security Mode Complete).'})
    if dsp.get('tac') and not dsp.get('model'):
        av.append({'nivell': 'info', 'text':
                   f'Model desconegut: el TAC {dsp["tac"]} no és a la base de dades de TAC; afegeix-lo a config/tac.csv (tac,marca,model). '
                   ''})
    return av
