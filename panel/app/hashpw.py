"""Genera el hash d'una contrasenya per a panel.yaml (python -m app.hashpw)."""
import getpass
import os
import sys

from .auth import hash_password

if __name__ == '__main__':
    p1 = getpass.getpass('Contrasenya: ')
    p2 = getpass.getpass('Repeteix-la: ')
    if p1 != p2:
        sys.exit('No coincideixen.')
    minim = int(os.environ.get('PANEL_MIN_PASS', '8'))
    if len(p1) < minim:
        sys.exit(f'Mínim {minim} caràcters (canvia-ho amb PANEL_MIN_PASS).')
    print(hash_password(p1))
