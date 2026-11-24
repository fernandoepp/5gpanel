"""Mètriques de ràdio per mòbil: ajunta el que diu cada gNB (agent ràdio /radio_ues, per RNTI)
amb el que diu l'AMF (agent core /estat5g, per IMSI).

El gNB només coneix el RNTI (identificador de ràdio, canvia a cada connexió). L'agent de la ràdio
ja tradueix el RNTI als identificadors NGAP (ran_ue_ngap_id, amf_ue_ngap_id) llegint el log del gNB,
i l'AMF diu quin IMSI té cada amf_ue_ngap_id. Si el log no ho diu (nivells de log massa baixos),
només es dedueix quan al gNB hi ha exactament un mòbil sense associar a cada banda.
"""


def _s(v):
    return None if v is None else str(v)


def associa(viu, radios):
    """viu: resposta de /estat5g del core. radios: [{'desti', 'titol', 'dades' | 'error'}].
    -> {'per_imsi': {imsi: mètriques}, 'sense_mobil': [...], 'fonts': {titol: 'ok' | error}}"""
    ues = [u for u in (viu or {}).get('ues') or [] if u.get('imsi')]
    gnb_ip = {g.get('ip'): g.get('gnb_id') for g in (viu or {}).get('gnbs') or [] if g.get('ip')}
    per_amf = {_s(u.get('amf_ue_ngap_id')): u for u in ues if u.get('amf_ue_ngap_id') is not None}
    per_imsi, sense, fonts = {}, [], {}
    for r in radios:
        if r.get('error'):
            fonts[r['titol']] = r['error']
            continue
        d = r.get('dades') or {}
        fonts[r['titol']] = d.get('error') or ('ok' if d.get('connectat') else 'sense dades del gNB')
        if d.get('log') and d.get('log') != 'ok' and d.get('ues'):
            fonts[r['titol']] += f' · associació: {d["log"]}'
        camps = d.get('hist_camps') or []
        pendents = []
        for m in d.get('ues') or []:
            # historial (files amb els camps de hist_camps; t en segons epoch): el navegador l'acumula per IMSI
            m = dict(m, radio=r['titol'], desti=r['desti'], hist_camps=camps)
            u = per_amf.get(_s(m.get('amf_ue_ngap_id')))
            if u and (m.get('ran_ue_ngap_id') is None or u.get('ran_ue_ngap_id') is None
                      or _s(m['ran_ue_ngap_id']) == _s(u['ran_ue_ngap_id'])):
                per_imsi[u['imsi']] = dict(m, associacio='log')
            else:
                pendents.append(m)
        # Deducció: un sol RNTI sense associar i un sol mòbil connectat a aquest gNB sense mètriques.
        gid = gnb_ip.get(d.get('radio_ip'))
        lliures = [u for u in ues if u.get('cm_state') == 'connected' and u['imsi'] not in per_imsi
                   and (gid is None or u.get('gnb_id') == gid)]
        if len(pendents) == 1 and len(lliures) == 1 and (gid is not None or len(gnb_ip) <= 1):
            per_imsi[lliures[0]['imsi']] = dict(pendents[0], associacio='deduida')
        else:
            sense += pendents
    return {'per_imsi': per_imsi, 'sense_mobil': sense, 'fonts': fonts}
