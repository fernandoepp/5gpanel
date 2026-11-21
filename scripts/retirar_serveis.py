#!/usr/bin/env python3
"""Retira (o restaura) serveis del docker-compose del core i de la configuració de l'agent.

  sudo python3 retirar_serveis.py grafana metrics          # els comenta al compose i esborra els contenidors
  sudo python3 retirar_serveis.py --restaurar grafana      # els torna a deixar com estaven

Al compose, cada línia del bloc del servei queda comentada amb "#panel5g-retirat# " (reversible).
Treu els serveis de "containers" i "services" de /etc/agent5g/agent5g.json i reinicia l'agent.
No toca els volums (grafana_data es queda; esborra'l a mà si vols: docker volume rm grafana_data).
"""
import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys

MARCA = '#panel5g-retirat# '
CFG = '/etc/agent5g/agent5g.json'


def bloc(lines, nom):
    """(inici, fi) del bloc "  nom:" dins de services."""
    ini = next((i for i, l in enumerate(lines) if re.match(rf'^  {re.escape(nom)}:\s*$', l)), None)
    if ini is None:
        return None
    fi = len(lines)
    for j in range(ini + 1, len(lines)):
        l = lines[j]
        if l.strip() and not l.startswith('   ') and not l.startswith(MARCA):
            fi = j
            break
    while fi > ini + 1 and not lines[fi - 1].strip():
        fi -= 1
    return ini, fi


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('serveis', nargs='+')
    ap.add_argument('--restaurar', action='store_true')
    a = ap.parse_args()
    if os.geteuid() != 0:
        sys.exit('Cal executar-ho amb sudo')
    for s in a.serveis:
        if not re.fullmatch(r'[a-z0-9_-]{1,40}', s):
            sys.exit(f'nom invàlid: {s}')
        if s in ('amf', 'smf', 'upf', 'nrf', 'scp', 'ausf', 'udm', 'udr', 'pcf', 'bsf', 'nssf', 'mongo'):
            sys.exit(f'{s} és una NF del core: no es retira')
    cfg = json.load(open(CFG))
    compose = os.path.join(cfg['project_dir'], cfg['compose_files'][0])
    lines = open(compose).read().split('\n')
    ts = dt.datetime.now().strftime('%Y%m%d-%H%M%S')
    shutil.copy2(compose, f'{compose}.bak-{ts}')
    shutil.copy2(CFG, f'{CFG}.bak-{ts}')
    docker = cfg.get('docker_bin', '/usr/bin/docker')
    for s in a.serveis:
        if a.restaurar:
            ini = next((i for i, l in enumerate(lines) if l == f'{MARCA}  {s}:'), None)
            if ini is None:
                print(f'- {s}: no estava retirat')
                continue
            j = ini
            while j < len(lines) and lines[j].startswith(MARCA):
                lines[j] = lines[j][len(MARCA):]
                j += 1
                if j < len(lines) and re.match(rf'^{re.escape(MARCA)}  [a-z0-9_-]+:\s*$', lines[j]):
                    break
            for k in ('containers', 'services'):
                if s not in cfg.get(k, []):
                    cfg.setdefault(k, []).append(s)
            print(f'+ {s}: restaurat al compose (engega\'l amb el botó Encendre o docker compose up -d {s})')
        else:
            b = bloc(lines, s)
            if not b:
                print(f'- {s}: no és al compose ({compose})')
            else:
                for i in range(*b):
                    lines[i] = MARCA + lines[i]
                print(f'- {s}: comentat al compose')
            subprocess.run([docker, 'rm', '-f', s], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for k in ('containers', 'services'):
                cfg[k] = [x for x in cfg.get(k, []) if x != s]
    with open(compose, 'w') as f:
        f.write('\n'.join(lines))
    with open(CFG, 'w') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    os.chmod(CFG, 0o600)
    rc = subprocess.run([docker, 'compose', '--project-directory', cfg['project_dir'], '-f', compose, 'config', '-q'],
                        cwd=cfg['project_dir'])
    if rc.returncode != 0:
        print(f'ALERTA: el compose no valida. Torna enrere: cp {compose}.bak-{ts} {compose}')
        sys.exit(1)
    subprocess.run(['systemctl', 'restart', 'agent5g'])
    print(f'Fet. Còpies: {compose}.bak-{ts} i {CFG}.bak-{ts}')


if __name__ == '__main__':
    main()
