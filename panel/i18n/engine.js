// i18n.js - idioma del panell: ES, EN o CAT (selector a dalt a la dreta).
// El panell està escrit en català; aquest fitxer tradueix el que es mostra (textos, title i
// placeholder, i els avisos confirm/alert) amb el diccionari de sota. El que no hi és es veu
// en català. Es genera amb scripts/i18n_genera.py: per afegir textos, edita panel/i18n/dict.py.
(() => {
  'use strict';
  const IDIOMES = { es: 'ES', en: 'EN', ca: 'CAT' };
  const COL = { es: 0, en: 1 };
  const D = /*DICT*/{}/*FI*/;
  // entrades amb parts variables ({} o {0}{1}...) -> expressions regulars
  const esc = (s) => s.replace(/[.*+?^$()|[\]\\]/g, '\\$&');
  const TPL = [];
  for (const [k, v] of Object.entries(D)) {
    if (!k.includes('{}')) continue;
    const re = new RegExp('^' + k.split('{}').map(esc).join('([\\s\\S]*?)') + '$');
    TPL.push([re, v]);
  }
  TPL.sort((a, b) => b[0].source.length - a[0].source.length);   // les més concretes primer

  let lang = 'es';
  try {
    const d = localStorage.getItem('panel5g-idioma');
    if (d && IDIOMES[d]) lang = d;
    else {
      const n = (navigator.language || 'es').slice(0, 2);
      lang = n === 'ca' ? 'ca' : n === 'en' ? 'en' : 'es';
    }
  } catch (e) { /* sense localStorage: castellà */ }

  function omple(out, vals) {
    let i = 0;
    return out.replace(/\{(\d*)\}/g, (_, n) => (n === '' ? vals[i++] : vals[+n]) ?? '');
  }
  function una(s) {
    const v = D[s];
    if (v) return v[COL[lang]];
    for (const [re, o] of TPL) {
      const m = s.match(re);
      if (m) return omple(o[COL[lang]], m.slice(1).map(una));
    }
    return s;
  }
  function tr(s) {
    if (lang === 'ca' || typeof s !== 'string' || !s.trim()) return s;
    if (s.includes('\n')) return s.split('\n').map(tr).join('\n');
    const m = s.match(/^(\s*)([\s\S]*?)(\s*)$/);
    const t = una(m[2]);
    return t === m[2] ? s : m[1] + t + m[3];
  }

  const SALTA = new Set(['SCRIPT', 'STYLE', 'PRE', 'CODE', 'TEXTAREA', 'INPUT']);
  const salta = (el) => !el || SALTA.has(el.tagName) || (el.closest && el.closest('[data-sense-traduir], pre, code, .log, #idioma'));
  const ATTR = ['title', 'placeholder', 'aria-label'];

  function text(n) {
    if (salta(n.parentElement)) return;
    // si l'aplicació ha canviat el text (no és la nostra traducció), és un original nou
    if (n.__orig === undefined || n.nodeValue !== n.__tr) n.__orig = n.nodeValue;
    const t = tr(n.__orig);
    n.__tr = t;
    if (n.nodeValue !== t) n.nodeValue = t;
  }
  function atributs(el) {
    el.__oa = el.__oa || {}; el.__ta = el.__ta || {};
    for (const a of ATTR) {
      const v = el.getAttribute(a);
      if (v == null) continue;
      if (el.__oa[a] === undefined || v !== el.__ta[a]) el.__oa[a] = v;
      const t = tr(el.__oa[a]);
      el.__ta[a] = t;
      if (v !== t) el.setAttribute(a, t);
    }
  }
  function arbre(root) {
    if (root.nodeType === 3) { text(root); return; }
    if (root.nodeType !== 1 || salta(root)) return;
    atributs(root);
    const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
    let n;
    while ((n = w.nextNode())) {
      if (n.nodeType === 3) text(n);
      else if (!salta(n)) atributs(n);
    }
  }

  const obs = new MutationObserver((ms) => {
    for (const m of ms) {
      if (m.type === 'characterData') text(m.target);
      else if (m.type === 'attributes') { if (!salta(m.target)) atributs(m.target); }
      else m.addedNodes.forEach(arbre);
    }
  });

  // confirm/alert/prompt de l'aplicació
  for (const f of ['confirm', 'alert', 'prompt']) {
    const o = window[f].bind(window);
    window[f] = (msg, ...r) => o(tr(String(msg ?? '')), ...r);
  }

  function selector() {
    const box = document.createElement('div');
    box.id = 'idioma';
    box.setAttribute('role', 'group');
    box.setAttribute('aria-label', 'Idioma / Language');
    for (const [k, nom] of Object.entries(IDIOMES)) {
      const b = document.createElement('button');
      b.type = 'button'; b.textContent = nom; b.dataset.lang = k;
      b.title = { es: 'Español', en: 'English', ca: 'Català' }[k];
      b.addEventListener('click', () => posa(k));
      box.append(b);
    }
    document.body.append(box);
  }
  function marca() {
    document.documentElement.lang = lang;
    document.querySelectorAll('#idioma button').forEach((b) => b.classList.toggle('actiu', b.dataset.lang === lang));
  }
  function posa(k) {
    lang = k;
    try { localStorage.setItem('panel5g-idioma', k); } catch (e) { /* res */ }
    marca();
    arbre(document.body);
    if (document.__titol === undefined) document.__titol = document.title;
    document.title = tr(document.__titol);
  }

  window.I18N = { tr: (s) => tr(s), idioma: () => lang, posa };
  document.addEventListener('DOMContentLoaded', () => {
    selector();
    posa(lang);
    obs.observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ATTR });
  });
})();
