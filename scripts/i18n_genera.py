#!/usr/bin/env python3
"""Genera panel/app/static/i18n.js a partir de panel/i18n/dict.py i panel/i18n/engine.js.

Ús: python3 scripts/i18n_genera.py   (després de tocar el diccionari)
"""
import json, os, runpy, sys
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
D = runpy.run_path(os.path.join(R, 'panel/i18n/dict.py'))['D']
dic, dup = {}, []
for ca, es, en in D:
    if ca in dic and dic[ca] != [es, en]:
        dup.append(ca)
    dic[ca] = [es, en]
for k, (es, en) in dic.items():          # mateix nombre de parts variables
    n = k.count('{}')
    for t in (es, en):
        if t.count('{}') + sum(t.count('{%d}' % i) for i in range(n)) != n:
            sys.exit(f'parts variables diferents: {k!r} -> {t!r}')
eng = open(os.path.join(R, 'panel/i18n/engine.js'), encoding='utf-8').read()
a, b = eng.index('/*DICT*/'), eng.index('/*FI*/')
out = eng[:a] + json.dumps(dic, ensure_ascii=False, indent=0) + eng[b + 6:]
out = '// FITXER GENERAT per scripts/i18n_genera.py: no l\'editis a mà.\n' + out
open(os.path.join(R, 'panel/app/static/i18n.js'), 'w', encoding='utf-8').write(out)
print(f'i18n.js: {len(dic)} textos' + (f' (repetits amb traducció diferent: {dup})' if dup else ''))
