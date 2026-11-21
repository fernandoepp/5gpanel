"""Validació en llista blanca dels valors del .env i regles creuades."""
import ipaddress
import re

from . import radio
from .radio import arfcn_to_mhz  # noqa: F401 (compatibilitat)


def _conv(tipus, raw):
    if tipus == 'int':
        if not re.fullmatch(r'-?[0-9]+', raw):
            raise ValueError('ha de ser un enter')
        return int(raw)
    if tipus == 'float':
        if not re.fullmatch(r'-?[0-9]+(\.[0-9]+)?', raw):
            raise ValueError('ha de ser un número')
        return float(raw)
    if tipus == 'ipv4':
        ipaddress.IPv4Address(raw)
        return raw
    return raw


def check_field(spec, raw):
    """Torna (valor_convertit, None) o (None, missatge d'error)."""
    raw = str(raw).strip()
    try:
        v = _conv(spec.get('tipus', 'str'), raw)
    except ValueError as e:
        return None, str(e) or 'valor invàlid'
    if 'enum' in spec and v not in spec['enum']:
        return None, f'valors permesos: {spec["enum"]}'
    if 'min' in spec and v < spec['min']:
        return None, f'mínim {spec["min"]}'
    if 'max' in spec and v > spec['max']:
        return None, f'màxim {spec["max"]}'
    if 'regex' in spec and not re.fullmatch(spec['regex'], raw):
        return None, 'format invàlid'
    return v, None


def _num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def rules_radio(schema, env, errors, warnings):
    dev = schema.get('dispositiu', {})
    srate = _num(env.get('SRATE'))
    bw = _num(env.get('BANDWIDTH_MHZ'))
    band = env.get('BAND')
    arfcn = env.get('DL_ARFCN')
    mimo = any(str(env.get(k, '1')).strip() == '2' for k in ('TX_ANTENA', 'RX_ANTENA'))

    if srate is not None and bw is not None:
        need = bw * dev.get('factor_srate_ample', 1.152)
        if srate + 1e-9 < need:
            errors.append(f'SRATE {srate} és massa baixa per {bw:g} MHz (mínim {need:.2f}).')
    if srate is not None:
        smax = dev.get('srate_max_mimo' if mimo else 'srate_max_siso')
        if smax and srate > smax:
            errors.append(f'SRATE {srate} supera el màxim de la {dev.get("model", "SDR")} '
                          f'{"en MIMO 2x2" if mimo else ""} ({smax}).')
    if mimo and bw is not None and dev.get('ample_max_mimo') and bw > dev['ample_max_mimo']:
        errors.append(f'Amb MIMO 2x2 l\'ample màxim és {dev["ample_max_mimo"]} MHz.')

    try:
        band_i, arfcn_i = int(band), int(arfcn)
    except (TypeError, ValueError):
        return
    f = arfcn_to_mhz(arfcn_i)
    if not dev.get('freq_min_mhz', 0) <= f <= dev.get('freq_max_mhz', 1e9):
        errors.append(f'{f:.2f} MHz és fora del rang de la {dev.get("model", "SDR")}.')
    b = radio.bandes(schema).get(band_i)
    if not b:
        errors.append(f'Banda n{band_i} desconeguda pel panell (afegeix-la a schema.yaml).')
        return
    lo, hi = b['dl_mhz']
    cands = radio.candidates(schema, f)
    if not lo <= f <= hi:
        on = f' (és de {", ".join(f"n{c}" for c in cands)})' if cands else ''
        errors.append(f'DL_ARFCN {arfcn_i} = {f:.3f} MHz no és dins de n{band_i} ({lo:g}–{hi:g} MHz){on}.')
        return
    scs = env.get('SCS')
    try:
        scs_i = int(scs)
    except (TypeError, ValueError):
        scs_i = None
    sc_perm = [int(x) for x in b.get('scs', [15, 30])]
    if scs_i is not None and scs_i not in sc_perm:
        errors.append(f'n{band_i} no admet SCS {scs_i} kHz (permeses: {sc_perm}).')
    if bw is not None:
        if f - bw / 2 < lo - 1e-9 or f + bw / 2 > hi + 1e-9:
            errors.append(f'Amb {bw:g} MHz el canal ({f - bw / 2:.2f}–{f + bw / 2:.2f} MHz) surt de '
                          f'n{band_i} ({lo:g}–{hi:g} MHz).')
        if bw < b.get('ample_min', 5):
            errors.append(f'n{band_i} necessita com a mínim {b["ample_min"]} MHz d\'ample.')
        if bw == 5 and scs_i not in (None, 15):
            errors.append('5 MHz només és possible amb SCS 15 kHz.')
    p = radio.pas(b, scs_i)
    if (arfcn_i - radio.primer_arfcn(b)) % p:
        warnings.append(f'DL_ARFCN {arfcn_i} no cau al raster de n{band_i} (pas {p}): '
                        f'el més proper és {radio.ajusta(b, arfcn_i, scs_i)}.')
    if b.get('duplex') == 'FDD' and scs_i == 30:
        warnings.append(f'n{band_i} és FDD: el normal és SCS 15 kHz.')


def rules_cross(envs, errors, warnings):
    core, radio = envs.get('core') or {}, envs.get('radio') or {}
    cip, hip = radio.get('CORE_IP'), core.get('DOCKER_HOST_IP')
    if cip and hip and cip != hip:
        warnings.append(f'CORE_IP del gNB ({cip}) diferent de la IP del core ({hip}): '
                        'el gNB no trobarà l\'AMF.')
    mcc, mnc, plmn = core.get('MCC'), core.get('MNC'), radio.get('PLMN_1')
    core_plmns = [p for p in (f'{mcc}{mnc}' if mcc and mnc else None,
                              f'{core["MCC_2"]}{core["MNC_2"]}' if core.get('MCC_2') and core.get('MNC_2') else None) if p]
    if core_plmns and plmn and str(plmn) not in core_plmns:
        warnings.append(f'PLMN del gNB ({plmn}) no és cap dels del core ({", ".join(core_plmns)}): '
                        'el gNB no s\'associarà a l\'AMF.')


def validate(schemas, target, current, changes, other_envs=None):
    """current/changes: dict clau->str. Torna dict amb errors per camp i globals."""
    schema = schemas.get(target)
    if not schema:
        return {'ok': False, 'field_errors': {}, 'errors': [f'destí desconegut: {target}'],
                'warnings': []}
    camps = schema.get('camps', {})
    field_errors, errors, warnings = {}, [], []
    for k, v in changes.items():
        if k not in camps:
            field_errors[k] = 'clau no permesa pel panell'
            continue
        _, err = check_field(camps[k], v)
        if err:
            field_errors[k] = err
    merged = dict(current)
    merged.update({k: str(v).strip() for k, v in changes.items()})
    if target == 'radio':
        rules_radio(schema, merged, errors, warnings)
    envs = dict(other_envs or {})
    envs[target] = merged
    rules_cross(envs, errors, warnings)
    return {'ok': not field_errors and not errors, 'field_errors': field_errors,
            'errors': errors, 'warnings': warnings,
            'normalized': {k: str(v).strip() for k, v in changes.items()}}


def services_for(restart_map, target, keys):
    m = restart_map.get(target) or {}
    out = []
    for k in keys:
        for s in m.get(k, m.get('*', [])) or []:
            if s not in out:
                out.append(s)
    return out


# ---------------------------------------------------------------- patró TDD
TDD_PERIODES_MS = (0.5, 0.625, 1, 1.25, 2, 2.5, 3, 4, 5, 10)   # 38.331 (+ v1530: 3 i 4 ms)


def validate_tdd(schema, env, activa, valors):
    """Torna {'ok', 'errors', 'warnings', 'resum', 'trama'} per al patró TDD de la ràdio."""
    errors, warnings = [], []
    try:
        band = int(env.get('BAND'))
    except (TypeError, ValueError):
        band = None
    b = radio.bandes(schema).get(band) if band else None
    duplex = (b or {}).get('duplex')
    if not activa:
        if duplex == 'TDD':
            warnings.append(f'n{band} és TDD: sense el bloc, ocudu fa servir el patró per defecte '
                            '(10 slots: 6 DL, especial 8 DL + 0 UL símbols, 3 UL).')
        return {'ok': True, 'errors': [], 'warnings': warnings}
    if duplex == 'FDD':
        errors.append(f'n{band} és FDD: el patró TDD no hi té sentit i ocudu el rebutjarà. Desactiva\'l.')
    try:
        p, dls, dsy, uls, usy = (int(str(valors.get(k, '')).strip()) for k in
                                 ('PERIOD_TDD', 'DL_SLOTS', 'DL_SYMBOLS', 'UL_SLOTS', 'UL_SYMBOLS'))
    except ValueError:
        return {'ok': False, 'errors': errors + ['Tots els valors TDD han de ser enters.'], 'warnings': warnings}
    try:
        scs = int(env.get('SCS') or 30)
    except ValueError:
        scs = 30
    ms = p * 15 / scs
    if not 2 <= p <= 80:
        errors.append('PERIOD_TDD ha d\'estar entre 2 i 80 slots.')
    elif not any(abs(ms - x) < 1e-9 for x in TDD_PERIODES_MS):
        bons = [int(x * scs / 15) for x in TDD_PERIODES_MS if abs(x * scs / 15 - round(x * scs / 15)) < 1e-9
                and 2 <= x * scs / 15 <= 80]
        errors.append(f'{p} slots amb SCS {scs} kHz són {ms:g} ms, que no és una periodicitat 3GPP. '
                      f'Valors vàlids: {", ".join(map(str, sorted(set(bons))))} slots.')
    for nom, v in (('DL_SYMBOLS', dsy), ('UL_SYMBOLS', usy)):
        if not 0 <= v <= 13:
            errors.append(f'{nom} ha d\'estar entre 0 i 13.')
    if dls < 1:
        errors.append('Cal com a mínim 1 slot de baixada (SSB, PDCCH, SIB1).')
    if uls < 1:
        errors.append('Cal com a mínim 1 slot de pujada (PRACH, PUCCH).')
    if dls + uls > p:
        errors.append(f'DL_SLOTS + UL_SLOTS ({dls + uls}) supera el període ({p}).')
    elif dls + uls == p:
        if dsy or usy:
            errors.append('No queda cap slot especial: DL_SYMBOLS i UL_SYMBOLS han de ser 0.')
    else:
        if dsy + usy > 13:
            errors.append(f'Slot especial: {dsy} + {usy} símbols no deixen cap símbol de guarda (màxim 13).')
        lliures = p - dls - uls - 1
        if lliures > 0:
            warnings.append(f'{lliures} slot(s) flexibles queden sense fer servir (ni DL ni UL).')
    trama = []
    if not errors or dls + uls <= p:
        for i in range(max(p, 0)):
            if i < dls:
                trama.append('D')
            elif i >= p - uls:
                trama.append('U')
            elif i == dls:
                trama.append('S')
            else:
                trama.append('F')
    dl_eq = dls + dsy / 14
    ul_eq = uls + usy / 14
    resum = None
    if p > 0 and dl_eq + ul_eq > 0:
        resum = (f'{ms:g} ms · DL {100 * dl_eq / p:.0f} % · UL {100 * ul_eq / p:.0f} % '
                 f'(DL/UL ≈ {dl_eq / ul_eq:.2f})' if ul_eq else f'{ms:g} ms')
    if not errors:
        warnings.append('Comprova al log del gNB que arrenca: si les ocasions PRACH cauen en un slot que '
                        'no és de pujada, ocudu no arrenca amb aquest patró.')
    return {'ok': not errors, 'errors': errors, 'warnings': warnings, 'resum': resum, 'trama': trama,
            'dl_especial': dsy, 'ul_especial': usy}


# ---------------------------------------------------------------- diversos PLMN
def validate_plmn(role, env, activa, valors, altre=None):
    """env: .env actual d'aquest equip; altre: .env de l'altre equip (core<->ràdio)."""
    errors, warnings = [], []
    altre = altre or {}
    if not activa:
        if role == 'radio' and altre.get('MCC_2'):
            warnings.append('El core continuarà acceptant dos PLMN; aquest gNB només n\'anunciarà un.')
        return {'ok': True, 'errors': [], 'warnings': warnings}
    if role == 'core':
        mcc2, mnc2 = str(valors.get('MCC_2', '')).strip(), str(valors.get('MNC_2', '')).strip()
        if not re.fullmatch(r'[0-9]{3}', mcc2):
            errors.append('MCC_2 ha de tenir 3 xifres.')
        if not re.fullmatch(r'[0-9]{2,3}', mnc2):
            errors.append('MNC_2 ha de tenir 2 o 3 xifres.')
        p1, p2 = f'{env.get("MCC", "")}{env.get("MNC", "")}', f'{mcc2}{mnc2}'
        if p1 == p2:
            errors.append(f'El PLMN 2 ({p2}) és el mateix que el principal (MCC+MNC).')
        if p2 == '00101':
            warnings.append('nrf.yaml ja serveix 001/01 per defecte: no passa res, però queda repetit.')
        radio_p = [altre.get(k) for k in ('PLMN_1', 'PLMN_2') if altre.get(k)]
        if radio_p and p2 not in radio_p:
            warnings.append(f'El gNB anuncia {", ".join(radio_p)}: perquè els UEs del PLMN {p2} hi entrin, '
                            'activa també els diversos PLMN a la ràdio amb PLMN_2=' + p2 + '.')
        warnings.append(f'Les SIM del PLMN {p2} han d\'estar donades d\'alta a la WebUI amb IMSI que comenci per {p2}.')
    else:
        p2 = str(valors.get('PLMN_2', '')).strip()
        if not re.fullmatch(r'[0-9]{5,6}', p2):
            errors.append('PLMN_2 ha de tenir 5 o 6 xifres (MCC+MNC).')
        if p2 == str(env.get('PLMN_1', '')):
            errors.append(f'PLMN_2 ({p2}) és igual que PLMN_1.')
        core_p = [f'{altre.get(a, "")}{altre.get(b, "")}' for a, b in (('MCC', 'MNC'), ('MCC_2', 'MNC_2'))
                  if altre.get(a) and altre.get(b)]
        if core_p and p2 not in core_p:
            warnings.append(f'El core només accepta {", ".join(core_p)}: el PLMN {p2} no s\'hi registrarà '
                            'fins que no l\'activis també al core.')
    return {'ok': not errors, 'errors': errors, 'warnings': warnings}
