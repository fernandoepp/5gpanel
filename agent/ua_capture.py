#!/usr/bin/env python3
"""ua_capture: model del mòbil a partir del User-Agent HTTP/SIP del pla d'usuari (GTP-U).

Escolta UDP 2152 (N3) amb tshark i NOMÉS es queda, de cada petició HTTP en clar
que surt d'un UE: IP del UE, User-Agent i hora. No desa URLs, hosts, cookies ni
contingut, ni cap paquet a disc. El resultat (com a molt MAX_ENTRADES parelles
IP+User-Agent) va a /var/lib/agent5g/ua.json, que l'agent5g serveix al panell.

Limitació: només funciona amb trànsit HTTP sense TLS (p. ex. apps o serveis de
fabricant que encara en fan servir); el que va per HTTPS no exposa el User-Agent.
"""
import datetime as dt
import json
import os
import subprocess
import sys
import tempfile
import time

TSHARK = os.environ.get('UA_TSHARK', '/usr/bin/tshark')
IFACE = os.environ.get('UA_IFACE', 'any')
OUT = os.environ.get('UA_OUT', '/var/lib/agent5g/ua.json')
MAX_ENTRADES = int(os.environ.get('UA_MAX', '300'))
MAX_UA = 400            # caràcters per User-Agent
DESA_CADA = 10          # segons


def iso(epoch):
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def carrega():
    try:
        with open(OUT) as f:
            return {(e['ip'], e['ua']): e for e in json.load(f).get('entrades', [])}
    except (OSError, ValueError, KeyError, TypeError):
        return {}


def desa(entrades):
    vals = sorted(entrades.values(), key=lambda e: e['darrer'], reverse=True)[:MAX_ENTRADES]
    d = os.path.dirname(OUT)
    fd, tmp = tempfile.mkstemp(dir=d, prefix='.ua-')
    with os.fdopen(fd, 'w') as f:
        json.dump({'actualitzat': iso(time.time()), 'entrades': vals}, f, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.replace(tmp, OUT)
    return {(e['ip'], e['ua']): e for e in vals}


def main():
    # -E occurrence=l: dins del túnel GTP-U hi ha dues capçaleres IP; l'última és la del UE.
    # -M: reinicia l'estat intern de tshark cada N paquets perquè no creixi la memòria.
    cmd = [TSHARK, '-i', IFACE, '-n', '-l',
           '-f', 'udp port 2152', '-M', '50000',
           # HTTP en clar o SIP (REGISTER d'IMS/VoNR) del UE dins del túnel
           '-Y', 'gtp && ((http.request && http.user_agent) || sip.User-Agent)',
           '-T', 'fields', '-E', 'occurrence=l', '-E', 'separator=/t',
           '-e', 'frame.time_epoch', '-e', 'ip.src', '-e', 'http.user_agent',
           '-e', 'sip.User-Agent']
    entrades = carrega()
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=sys.stderr, cwd='/',
                         text=True, errors='replace', bufsize=1)
    brut, ultim = False, 0.0
    for linia in p.stdout:
        parts = linia.rstrip('\n').split('\t')
        if len(parts) < 3:
            continue
        ua = (parts[2] if len(parts) == 3 or parts[2] else parts[3]).strip()
        if not ua:
            continue
        try:
            ts = float(parts[0])
        except ValueError:
            continue
        ip, ua = parts[1].strip(), ua[:MAX_UA]
        e = entrades.get((ip, ua))
        nou = e is None
        if nou:
            e = entrades[(ip, ua)] = {'ip': ip, 'ua': ua, 'primer': iso(ts), 'n': 0}
            print(f'nou User-Agent de {ip}: {ua}', flush=True)
        e['darrer'] = iso(ts)
        e['n'] += 1
        brut = True
        if nou or time.time() - ultim >= DESA_CADA:
            entrades = desa(entrades)
            brut, ultim = False, time.time()
    if brut:
        desa(entrades)
    sys.exit(p.wait() or 1)


if __name__ == '__main__':
    main()
