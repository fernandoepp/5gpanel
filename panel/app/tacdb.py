"""Model del mòbil a partir del TAC (8 primers dígits de l'IMEI).

Fonts, per ordre:
  1. config/tac.csv (tac,marca,model): els mòbils del laboratori, mana sempre.
  2. Base de dades pública https://github.com/MoazEb/tac-database (MIT, ~276.000 TAC),
     a app/data/tac_full.csv.gz. Es converteix a SQLite en construir la imatge
     (python -m app.tacdb build) perquè el panell no la carregui sencera a memòria
     (el contenidor té 256 MB).
"""
import csv
import gzip
import io
import sqlite3
import sys
from functools import lru_cache
from pathlib import Path

DATA = Path(__file__).resolve().parent / 'data'
CSV_GZ = DATA / 'tac_full.csv.gz'
DB = DATA / 'tac.sqlite'


def build(csv_gz=CSV_GZ, db=DB):
    tmp = db.with_suffix('.tmp')
    if tmp.exists():
        tmp.unlink()
    con = sqlite3.connect(tmp)
    con.execute('CREATE TABLE tac (tac TEXT PRIMARY KEY, marca TEXT, specs TEXT) WITHOUT ROWID')
    n = 0
    with gzip.open(csv_gz, 'rb') as fh:
        rows = csv.reader(io.TextIOWrapper(fh, encoding='utf-8', errors='replace'))
        next(rows, None)                                  # capçalera Brand,TAC,SPECS
        for r in rows:
            if len(r) < 3 or not r[1].strip().isdigit():
                continue
            # els TAC antics venen sense zeros a l'esquerra; si n'hi ha de repetits, mana el primer
            con.execute('INSERT OR IGNORE INTO tac VALUES (?,?,?)',
                        (r[1].strip().zfill(8), r[0].strip(), r[2].strip()))
            n += 1
    con.commit()
    con.close()
    tmp.replace(db)
    return n


class TacDB:
    """Diccionari de només lectura: tacdb.get('35345609') -> 'LG K9' (o None)."""

    def __init__(self, local=None, db=DB):
        self.local = local or {}
        self.db = db
        self._con = None

    def _cur(self):
        if self._con is None and self.db.is_file():
            # immutable=1: el fitxer és dins la imatge i el contenidor és read_only
            self._con = sqlite3.connect(f'file:{self.db}?mode=ro&immutable=1', uri=True,
                                        check_same_thread=False)
        return self._con

    @lru_cache(maxsize=4096)
    def info(self, tac):
        """-> {'model', 'marca', 'detall', 'font'} o None"""
        tac = str(tac or '')[:8]
        if len(tac) != 8 or not tac.isdigit():
            return None
        if tac in self.local:
            return {'model': self.local[tac], 'marca': None, 'detall': None, 'font': 'tac.csv'}
        con = self._cur()
        if con is None:
            return None
        row = con.execute('SELECT marca, specs FROM tac WHERE tac=?', (tac,)).fetchone()
        if not row:
            return None
        marca, specs = row
        # SPECS: "MOTOROLA EDGE 30 FUSION, Motorola XT2243-1, 2022" -> nom comercial = 1a part
        nom = specs.split(',')[0].strip() or f'{marca} (TAC {tac})'
        return {'model': nom, 'marca': marca, 'detall': specs, 'font': 'tac-database'}

    def get(self, tac, default=None):
        i = self.info(tac)
        return i['model'] if i else default

    def __len__(self):
        con = self._cur()
        n = con.execute('SELECT count(*) FROM tac').fetchone()[0] if con else 0
        return n + len(self.local)


if __name__ == '__main__':
    if sys.argv[1:2] == ['build']:
        print(f'tac.sqlite: {build()} TAC')
    else:
        print(TacDB().info(sys.argv[1] if len(sys.argv) > 1 else ''))
