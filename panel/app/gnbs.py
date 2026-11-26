"""Vista per gNB connectat a l'AMF.

Fonts:
  * captura NGAP (agent /gnbs): NG Setup Request/Response/Failure -> gNB-ID, nom,
    PLMN, TAC, slices, Paging DRX, AMF que l'accepta i historial d'intents
  * estat en viu de l'AMF (agent /estat5g, API /gnb-info d'Open5GS): quins gNB hi ha ara
    connectats, amb gNB-ID, nom, PLMN, TAC i slices. Mana sobre el log i la captura.
  * log de l'AMF -> connexions/desconnexions SCTP (N2) per IP i avisos de NG Setup
  * fitxes d'UE (devices.py) -> quins UEs són a cada gNB (pel CellID: gNB-ID + cel·la)
  * agent de la ràdio -> configuració del gNB local (.env d'ocudu) i estat del contenidor
"""
import re
from datetime import datetime, timezone

from .devices import _clean
from .radio import arfcn_to_mhz

RX = {
    'accept': re.compile(r'gNB-N2 accepted\[([0-9a-fA-F.:]+)\]:(\d+) in ng-path'),
    'refused': re.compile(r'gNB-N2\[([0-9a-fA-F.:]+)\] connection refused'),
    'count': re.compile(r'\[(Added|Removed)\] Number of gNBs is now (\d+)'),
    'problema': re.compile(r'NG-?Setup|Served TAI|S[-_]NSSAI|PLMN|gNB', re.I),
}


def _iso_epoch(ts):
    if ts is None:
        return None
    return datetime.fromtimestamp(float(ts), timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def _secs(iso):
    try:
        return datetime.fromisoformat(iso[:19]).replace(tzinfo=timezone.utc).timestamp()
    except (TypeError, ValueError):
        return None


def build(amf_log, captured=None, ues=None, radios=None, viu=None, nomes_viu=False):
    gnbs = {}
    n_gnbs = None

    def g(ip):
        return gnbs.setdefault(ip, {
            'ip': ip, 'connectat': None, 'des_de': None, 'port': None, 'connexions': 0,
            'desconnexions': 0, 'events': [], 'avisos': [], 'setups': [], 'ues': [], 'local': None})

    last_ip, last_ts = None, None
    for ts, mod, lvl, msg in _clean(amf_log or ''):
        m = RX['accept'].search(msg)
        if m:
            d = g(m.group(1))
            d.update(connectat=True, des_de=ts, port=m.group(2))
            d['connexions'] += 1
            d['events'].append({'ts': ts, 'nivell': 'ok', 'text': f'Connexió SCTP (N2) des del port {m.group(2)}'})
            last_ip, last_ts = m.group(1), ts
            continue
        m = RX['refused'].search(msg)
        if m:
            d = g(m.group(1))
            d.update(connectat=False, des_de=ts)
            d['desconnexions'] += 1
            d['events'].append({'ts': ts, 'nivell': 'warn', 'text': 'Desconnectat (SCTP tancat)'})
            continue
        m = RX['count'].search(msg)
        if m:
            n_gnbs = int(m.group(2))
            continue
        if lvl in ('WARNING', 'ERROR', 'FATAL') and last_ip and RX['problema'].search(msg):
            a, b = _secs(ts), _secs(last_ts)
            if a is None or b is None or a - b < 10:
                d = g(last_ip)
                nv = 'error' if lvl != 'WARNING' else 'warn'
                d['events'].append({'ts': ts, 'nivell': nv, 'text': msg.strip()})

    # ---- captura: identitat i NG Setup
    for c in captured or []:
        d = g(c['ip'])
        for k in ('gnb_id', 'gnb_bits', 'nom', 'mcc', 'mnc', 'tacs', 'slices', 'drx', 'amf', 'capacitat'):
            if c.get(k) is not None:
                d[k] = c[k]
        d['port'] = d['port'] or c.get('port')
        for s in c.get('setups', []):
            d['setups'].append({'ts': _iso_epoch(s.get('ts')), 'resultat': s.get('resultat'),
                                'causa': s.get('causa')})
        last = d['setups'][-1] if d['setups'] else None
        if last:
            d['ultim_setup'] = last
            if d['connectat'] is None and last['resultat'] != 'ok':
                d['connectat'] = False

    # ---- estat en viu de l'AMF: el que hi ha connectat ara mateix
    if viu is not None:
        ara = set()
        for v in viu:
            if not v.get('ip'):
                continue
            d = g(v['ip'])
            ara.add(v['ip'])
            d['connectat'] = True
            d['ng_setup_ok'] = v.get('setup_ok')
            d['port'] = v.get('port') or d['port']
            for k in ('gnb_id', 'nom', 'tacs', 'slices', 'amf'):
                if v.get(k) not in (None, []):
                    d[k] = v[k]
            plmn = v.get('plmn') or ''
            if len(plmn) in (5, 6):
                d['mcc'], d['mnc'] = plmn[:3], plmn[3:]
            if v.get('plmns'):
                d['plmns'] = v['plmns']
        for ip, d in gnbs.items():
            if ip not in ara and d['connectat']:
                d['connectat'] = False          # l'AMF ja no el té
        n_gnbs = len(ara)

    # ---- UEs per gNB: NR CellID (36 bits) = gNB-ID (22-32 bits) + cel·la
    for u in ues or []:
        if u.get('gnb_id') is not None:         # l'AMF ja diu a quin gNB és
            cands = [d for d in gnbs.values() if d.get('gnb_id') == u['gnb_id']]
            if cands:
                d = next((x for x in cands if x['connectat']), cands[0])
                d['ues'].append({'imsi': u.get('imsi'), 'nom': u.get('nom') or (u.get('dispositiu') or {}).get('model'),
                                 'estat': u.get('estat'), 'cella': u.get('cella'), 'tac': u.get('tac')})
                continue
        cid = u.get('cell_id')
        if not cid:
            continue
        try:
            cid_i = int(cid, 16)
        except ValueError:
            continue
        cands = [d for d in gnbs.values() if d.get('gnb_id') is not None and d.get('gnb_bits')
                 and cid_i >> (36 - d['gnb_bits']) == d['gnb_id']]
        if not cands:
            continue
        d = next((x for x in cands if x['connectat']), cands[0])   # gNB-ID repetit: el connectat
        bits = d['gnb_bits']
        d['ues'].append({'imsi': u.get('imsi'), 'nom': u.get('nom') or (u.get('dispositiu') or {}).get('model'),
                         'estat': u.get('estat'), 'cella': cid_i & ((1 << (36 - bits)) - 1),
                         'tac': u.get('tac')})

    ids = {}
    for d in gnbs.values():
        if d.get('gnb_id') is not None:
            ids.setdefault(d['gnb_id'], []).append(d['ip'])
    for d in gnbs.values():
        altres = [ip for ip in ids.get(d.get('gnb_id'), []) if ip != d['ip']]
        if altres:
            d['gnb_id_repetit'] = altres

    if nomes_viu:                               # només els gNB que l'AMF té ara; el log, d'historial
        ara = {v.get('ip') for v in viu or []}
        for ip in [ip for ip in gnbs if ip not in ara]:
            del gnbs[ip]

    # ---- gNB local (agent de la ràdio)
    for r in radios or []:
        env = r.get('env') or {}
        ip = env.get('RADIO_IP')
        if not ip:
            continue
        d = g(ip)
        local = {'desti': r['desti'], 'titol': r.get('titol'), 'contenidors': r.get('contenidors', []),
                 'error': r.get('error')}
        for k in ('PCI', 'DL_ARFCN', 'BAND', 'BANDWIDTH_MHZ', 'SCS', 'TAC', 'PLMN_1', 'CORE_IP',
                  'SRATE', 'TX_GAIN', 'RX_GAIN', 'TX_ANTENA', 'RX_ANTENA'):
            if env.get(k) not in (None, ''):
                local[k] = env[k]
        try:
            local['freq_mhz'] = round(arfcn_to_mhz(int(env['DL_ARFCN'])), 3)
        except (KeyError, ValueError, TypeError):
            pass
        d['local'] = local

    # ---- acabats i diagnòstic
    out = []
    for d in gnbs.values():
        d['events'] = d['events'][-40:]
        d['setups'] = d['setups'][-10:]
        if d['connectat'] is None and n_gnbs == 0:
            d['connectat'] = False
        if d['connectat'] is None and d.get('ultim_setup', {}).get('resultat') == 'ok':
            d['connectat_probable'] = True
        d['avisos'] = diagnostics(d)
        d['n_ues'] = len([u for u in d['ues'] if u['estat'] in ('connectat', 'inactiu')])
        out.append(d)
    out.sort(key=lambda d: (not d['connectat'], d['ip']))
    return {'gnbs': out, 'n_gnbs_amf': n_gnbs}


def diagnostics(d):
    av = []
    us = d.get('ultim_setup')
    if us and us['resultat'] == 'rebutjat':
        causa = us.get('causa') or '?'
        txt = f'L\'AMF ha rebutjat l\'NG Setup ({causa}).'
        if 'PLMN' in causa:
            txt += ' El PLMN del gNB no coincideix amb el de l\'AMF (MCC/MNC).'
        elif 'TAI' in causa.upper() or 'TAC' in causa.upper():
            txt += ' El TAC del gNB no és a la llista amf.tai.'
        elif 'slice' in causa.lower() or 'nssai' in causa.lower():
            txt += ' Cap slice del gNB coincideix amb els de l\'AMF.'
        av.append({'nivell': 'error', 'text': txt})
    if us and us['resultat'] == 'sense resposta':
        av.append({'nivell': 'warn', 'text': 'L\'AMF no ha respost l\'últim NG Setup.'})
    if d['desconnexions'] >= 3:
        av.append({'nivell': 'warn', 'text': f'S\'ha desconnectat {d["desconnexions"]} cops: '
                   'mira els logs del gNB (USRP, temps real, CORE_IP).'})
    if d.get('gnb_id_repetit'):
        av.append({'nivell': 'warn', 'text': f'gNB-ID {d["gnb_id"]} repetit amb {", ".join(d["gnb_id_repetit"])}: '
                   'dona a cada gNB un gnb_id diferent (srsRAN/ocudu fan servir 411 per defecte), '
                   'si no els UEs i les cel·les es confonen.'})
    loc = d.get('local') or {}
    if loc:
        plmn = f'{d.get("mcc", "")}{d.get("mnc", "")}'
        if d.get('mcc') and loc.get('PLMN_1') and loc['PLMN_1'] != plmn:
            av.append({'nivell': 'warn', 'text': f'El .env diu PLMN {loc["PLMN_1"]} però el gNB anuncia {plmn}: '
                       'cal recrear el contenidor perquè agafi el canvi.'})
        if d.get('tacs') and loc.get('TAC') and loc['TAC'] not in d['tacs']:
            av.append({'nivell': 'warn', 'text': f'El .env diu TAC {loc["TAC"]} però el gNB anuncia {", ".join(d["tacs"])}.'})
        gnb_c = [c for c in loc.get('contenidors', []) if 'gnb' in c.get('name', '')]
        if gnb_c and all(c.get('status') != 'running' for c in gnb_c) and not d['connectat']:
            av.append({'nivell': 'info', 'text': 'El contenidor del gNB està aturat: encén-lo des de la pestanya Estat.'})
        if not d.get('connexions') and not d.get('setups') and not d['connectat']:
            av.append({'nivell': 'info', 'text': 'Aquest gNB no apareix ni als logs de l\'AMF ni a la captura.'})
    return av
