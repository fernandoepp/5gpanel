"""Freqüència central <-> NR-ARFCN, banda i SCS (3GPP TS 38.104, FR1).

La taula de bandes ve de schema.yaml (radio.bandes). Per a cada banda:
  dl_mhz:   [inici, final] de la banda de baixada (MHz)
  duplex:   FDD | TDD
  scs:      SCS permeses (kHz)
  pas:      pas del raster de canal en ARFCN (enter o {scs: pas})
  ample_min (opcional): ample de banda mínim (MHz)
L'ordre de radio.prioritat decideix quina banda es proposa quan se solapen.
"""
import math


def arfcn_to_mhz(n):
    """Freqüència (MHz) d'un NR-ARFCN (38.104, 5.4.2.1)."""
    if n < 600000:
        return n * 0.005
    if n < 2016667:
        return 3000 + (n - 600000) * 0.015
    return 24250.08 + (n - 2016667) * 0.06


def mhz_to_arfcn_f(f):
    """NR-ARFCN (amb decimals) d'una freqüència en MHz (raster global)."""
    if f < 3000:
        return f / 0.005
    if f < 24250:
        return 600000 + (f - 3000) / 0.015
    return 2016667 + (f - 24250.08) / 0.06


def bandes(schema):
    out = {}
    for k, b in (schema.get('bandes') or {}).items():
        if 'dl_mhz' in b:
            out[int(k)] = b
    return out


def prioritat(schema):
    bs = bandes(schema)
    pr = [int(x) for x in schema.get('prioritat', []) if int(x) in bs]
    return pr + sorted(b for b in bs if b not in pr)


def pas(b, scs):
    p = b.get('pas', 20)
    if isinstance(p, dict):
        p = {int(k): v for k, v in p.items()}
        return int(p.get(int(scs) if scs else 0) or min(p.values()))
    return int(p)


def primer_arfcn(b):
    return math.ceil(mhz_to_arfcn_f(b['dl_mhz'][0]) - 1e-6)


def scs_defecte(b):
    sc = [int(x) for x in b.get('scs', [15, 30])]
    pref = 15 if b.get('duplex') == 'FDD' else 30
    return pref if pref in sc else sc[0]


def candidates(schema, f, ample=None):
    """Bandes que contenen la freqüència (i, si es diu, tot el canal), per prioritat."""
    bs = bandes(schema)
    out = []
    for n in prioritat(schema):
        lo, hi = bs[n]['dl_mhz']
        mig = (ample or 0) / 2
        if lo + mig - 1e-9 <= f <= hi - mig + 1e-9:
            out.append(n)
    return out


def ajusta(b, arfcn, scs):
    """ARFCN més proper que cau al raster de canal de la banda."""
    p = pas(b, scs)
    base = primer_arfcn(b)
    return base + round((arfcn - base) / p) * p


def calcula(schema, f=None, arfcn=None, banda=None, scs=None, ample=None, srates=None,
            factor=1.152):
    """Torna la proposta completa per al formulari. Tots els paràmetres són opcionals,
    però cal f (MHz) o arfcn. Els que l'usuari ja ha triat (banda, scs) es respecten
    si són vàlids; si no, es diu per què."""
    bs = bandes(schema)
    errors, avisos = [], []
    if f is None and arfcn is not None:
        f = arfcn_to_mhz(int(arfcn))
    if f is None:
        return {'errors': ['Falta la freqüència.']}
    cands = candidates(schema, f)
    cands_ample = candidates(schema, f, ample) if ample else cands
    if not cands:
        return {'freq_mhz': f, 'bandes': [], 'errors': [
            f'{f:g} MHz no és dins de cap banda NR coneguda pel panell.']}
    triada = int(banda) if banda not in (None, '') else None
    if triada is None or triada not in cands:
        if triada is not None:
            avisos.append(f'n{triada} no conté {f:g} MHz: canviada a n{cands[0]}.')
        triada = next((c for c in cands_ample if c in cands), cands[0])
        if triada != cands[0]:
            avisos.append(f'A n{cands[0]} no hi cap un canal de {ample:g} MHz centrat aquí: proposada n{triada}.')
    b = bs[triada]
    sc_perm = [int(x) for x in b.get('scs', [15, 30])]
    sc = int(scs) if scs not in (None, '') else None
    if sc not in sc_perm:
        if sc is not None:
            avisos.append(f'n{triada} no admet SCS {sc} kHz: proposada {scs_defecte(b)} kHz.')
        sc = scs_defecte(b)
    n = ajusta(b, mhz_to_arfcn_f(f), sc)
    f_real = arfcn_to_mhz(n)
    lo, hi = b['dl_mhz']
    if ample:
        if f_real - ample / 2 < lo - 1e-9 or f_real + ample / 2 > hi + 1e-9:
            errors.append(f'Amb {ample:g} MHz el canal ({f_real - ample / 2:.2f}–{f_real + ample / 2:.2f} MHz) '
                          f'surt de la banda n{triada} ({lo:g}–{hi:g} MHz). Baixa l\'ample o mou la freqüència.')
        if ample < b.get('ample_min', 5):
            errors.append(f'n{triada} necessita com a mínim {b["ample_min"]} MHz.')
        if ample == 5 and sc != 15:
            errors.append('5 MHz només és possible amb SCS 15 kHz.')
    ul = None
    if b.get('ul_mhz'):                      # FDD: pujada aparellada (separació dúplex fixa)
        ulo, uhi = b['ul_mhz']
        ul = {'freq_mhz': round(f_real - (lo - ulo), 4), 'rang_mhz': [ulo, uhi], 'separacio_mhz': lo - ulo}
    srate = None
    if ample and srates:
        need = ample * factor
        ok = sorted(float(x) for x in srates if float(x) + 1e-9 >= need)
        srate = ok[0] if ok else None
    return {
        'freq_mhz': f, 'freq_real_mhz': round(f_real, 4), 'arfcn': n, 'banda': triada,
        'bandes': cands, 'duplex': b.get('duplex'), 'scs': sc, 'scs_permeses': sc_perm,
        'pas_arfcn': pas(b, sc), 'rang_mhz': [lo, hi], 'srate_suggerida': srate,
        'ul': ul, 'errors': errors, 'avisos': avisos,
    }
