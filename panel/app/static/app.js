'use strict';
// Tot el contingut que ve dels agents (logs, valors) s'insereix amb textContent.

const $ = (s) => document.querySelector(s);
const VERSIO = 'v17';
function mostraError(txt) {
  let d = document.getElementById('error-global');
  if (!d) { d = document.createElement('div'); d.id = 'error-global'; document.body.prepend(d); }
  d.textContent = `Error del panell (${VERSIO}): ${txt}. Envia aquest text a qui manté el panell.`;
}
window.addEventListener('error', (e) => mostraError(`${e.message} @ ${(e.filename || '').split('/').pop()}:${e.lineno}:${e.colno}`));
window.addEventListener('unhandledrejection', (e) => mostraError(String(e.reason && (e.reason.stack || e.reason.message) || e.reason)));
let ME = null;
let timerUpf = null, timerEstat = null, timerLogs = null, timerUE = null, timerGnb = null, timerVoip = null, timerRadio = null;

function el(tag, attrs = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') e.className = v;
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else if (v !== false && v != null) e.setAttribute(k, v === true ? '' : v);
  }
  for (const k of kids.flat()) if (k != null) e.append(k instanceof Node ? k : String(k));
  return e;
}

async function api(method, url, body) {
  const h = { 'Accept': 'application/json' };
  if (body !== undefined) h['Content-Type'] = 'application/json';
  if (ME && method !== 'GET') h['X-CSRF-Token'] = ME.csrf;
  const r = await fetch(url, { method, headers: h, credentials: 'same-origin',
                               body: body === undefined ? undefined : JSON.stringify(body) });
  let data = {};
  try { data = await r.json(); } catch (_) { /* buit */ }
  if (r.status === 401 && url !== '/api/login') { mostraLogin(); throw new Error('sessió caducada'); }
  if (!r.ok && r.status !== 422) throw new Error(data.detail || `error ${r.status}`);
  data._status = r.status;
  return data;
}

// ------------------------------------------------------------ sessió
function mostraLogin() {
  ME = null;
  clearInterval(timerEstat); clearInterval(timerLogs); clearInterval(timerUE); clearInterval(timerGnb); clearInterval(timerRadio);
  document.querySelectorAll('.tab').forEach((t) => (t.hidden = true));
  $('#lateral').hidden = true; document.body.classList.remove('amb-lateral'); $('#login').hidden = false;
}

// ------------------------------------------------------------ tema clar / fosc
function temaActual() {
  const t = document.documentElement.getAttribute('data-theme');
  if (t) return t;
  return window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}
function pintaBotoTema() { $('#tema-text').textContent = temaActual() === 'dark' ? 'Tema fosc' : 'Tema clar'; }
$('#tema').addEventListener('click', () => {
  const nou = temaActual() === 'dark' ? 'light' : 'dark';
  document.documentElement.setAttribute('data-theme', nou);
  try { localStorage.setItem('panel5g-tema', nou === 'dark' ? 'fosc' : 'clar'); } catch (_) { /* res */ }
  pintaBotoTema();
});
pintaBotoTema();

// ------------------------------------------------------------ equips (fixos i descoberts)
const SELECTS_TOTS = ['#log-desti', '#his-desti'];
const SELECTS_CORE = ['#ue-desti', '#gnb-desti', '#sub-desti', '#upf-desti'];
function omplirSelects() {
  const omple = (id, llista) => {
    const s = $(id), cur = s.value;
    const vals = llista.map((d) => d);
    if ([...s.options].map((o) => o.value).join('|') === vals.join('|')) return;
    s.replaceChildren(...llista.map((d) => el('option', { value: d, selected: d === cur }, ME.titols[d] || d)));
  };
  SELECTS_TOTS.forEach((id) => omple(id, ME.destins));
  // el PC del UPF no té paràmetres propis: els hi passa el core
  omple('#par-desti', ME.destins.filter((d) => (ME.rols || {})[d] !== 'upf'));
  SELECTS_CORE.forEach((id) => omple(id, ME.destins.filter((d) => (ME.rols || {})[d] === 'core')));
}
async function refrescaEquips() {
  try {
    const m = await api('GET', '/api/me');
    Object.assign(ME, { destins: m.destins, titols: m.titols, rols: m.rols, descoberts: m.descoberts });
    omplirSelects();
  } catch (_) { /* res */ }
}

async function inici() {
  try { ME = await api('GET', '/api/me'); } catch (_) { mostraLogin(); return; }
  $('#login').hidden = true; $('#lateral').hidden = false; document.body.classList.add('amb-lateral');
  $('#usuari').textContent = `${ME.usuari} · ${ME.rol === 'admin' ? 'administrador' : 'lectura'}`;
  $('#versio').textContent = `Versió ${VERSIO}`;
  document.querySelectorAll('[data-admin]').forEach((b) => (b.hidden = ME.rol !== 'admin'));
  omplirSelects();
  tab('estat');
}

$('#form-login').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const f = new FormData(ev.target);
  $('#login-error').textContent = '';
  try {
    await api('POST', '/api/login', { usuari: f.get('usuari'), contrasenya: f.get('contrasenya') });
    ev.target.reset();
    inici();
  } catch (e) { $('#login-error').textContent = e.message; }
});

$('#sortir').addEventListener('click', async () => { await api('POST', '/api/logout', {}); mostraLogin(); });

function tab(nom) {
  document.querySelectorAll('nav button').forEach((b) => b.classList.toggle('actiu', b.dataset.tab === nom));
  document.querySelectorAll('.tab').forEach((t) => (t.hidden = t.id !== `tab-${nom}`));
  clearInterval(timerEstat); clearInterval(timerLogs); clearInterval(timerUE); clearInterval(timerGnb); clearInterval(timerRadio);
  clearInterval(timerVoip); timerVoip = null; clearInterval(timerUpf);
  if (nom !== 'estat') refrescaEquips();
  if (nom === 'upf') { carregaUpf(); timerUpf = setInterval(() => $('#upf-auto-ref').checked && !document.hidden && carregaUpf(), 5000); }
  if (nom === 'estat') { carregaEstat(); timerEstat = setInterval(carregaEstat, 5000); }
  if (nom === 'parametres') carregaParametres();
  if (nom === 'logs') { carregaFonts().then(carregaLogs); timerLogs = setInterval(() => $('#log-auto').checked && carregaLogs(), 3000); }
  if (nom === 'historial') carregaHistorial();
  if (nom === 'gnbs') { carregaGnbs(); timerGnb = setInterval(() => $('#gnb-auto').checked && carregaGnbs(), 10000); }
  if (nom === 'subs') carregaSubs();
  if (nom === 'ues') {
    carregaUEs(); timerUE = setInterval(() => $('#ue-auto').checked && carregaUEs(), 10000);
    // les mètriques de ràdio canvien cada segon: es refresquen soles, sense tornar a demanar les fitxes
    timerRadio = setInterval(() => $('#ue-auto').checked && !document.hidden && carregaRadioUE($('#ue-desti').value), 3000);
  }
}
document.querySelectorAll('nav button').forEach((b) => b.addEventListener('click', () => tab(b.dataset.tab)));

// ------------------------------------------------------------ estat
// Docker dona les hores en UTC: es mostren en l'hora local del navegador
function local(iso) {
  if (!iso || iso.startsWith('0001')) return '';
  const d = new Date(iso);
  return isNaN(d) ? iso : d.toLocaleString();
}

function estatClasse(c) {
  if (c.status === 'running') return c.health && c.health !== 'healthy' ? 'warn' : 'ok';
  return 'error';
}

let EQUIPS_N = 0, estatTick = 0;
async function pintaEquips(forca) {
  const box = $('#estat-equips');
  let r;
  try { r = forca ? await api('POST', '/api/equips/descobreix', {}) : await api('GET', '/api/equips'); }
  catch (e) { box.replaceChildren(el('p', { class: 'error' }, e.message)); return; }
  const ds = r.descobriment || {}, en = r.enllac || {};
  const btn = el('button', { type: 'button', disabled: ME.rol !== 'admin' || ds.en_curs }, ds.en_curs ? 'Cercant…' : 'Actualitza');
  btn.addEventListener('click', async () => { btn.disabled = true; btn.textContent = 'Cercant…'; await pintaEquips(true); });
  const quanD = ds.darrera ? new Date(ds.darrera * 1000).toLocaleTimeString() : 'encara no';
  const titolEq = (e) => e.enllac
    ? `${e.rol === 'upf' ? 'El PC del UPF' : 'La ràdio'} truca al core amb el seu certificat de la CA (ara des de ${e.ip || '?'}${e.des_de ? ', connectat des de ' + new Date(e.des_de).toLocaleString() : ''})`
    : e.descobert ? 'Trobat per la cerca a la xarxa: certificat de la CA del panell vàlid per a aquesta IP' : 'Definit a la configuració del panell';
  const errs = Object.entries(en.errors || {});
  const notes = [el('p', { class: 'nota' }, 'Les ràdios es connecten soles al core (port 9544) amb el certificat del codi d\'emparellament: no cal saber-ne la IP. Ràdio nova: al core, sudo emparella-radio <nom>. PC amb UPF: sudo emparella-upf <nom>.')];
  if (errs.length) notes.push(el('p', { class: 'error' }, errs.map(([t, m]) => `No puc preguntar a ${ME.titols[t] || t} quines ràdios té: ${m}`).join(' · ')));
  if (ds.actiu) notes.push(el('p', { class: 'nota' }, `També cerca agents antics a ${(ds.xarxes || []).join(', ') || '—'} (port ${ds.port || '?'}). Darrera cerca: ${quanD}.`));
  box.replaceChildren(el('div', { class: 'card' },
    el('div', { class: 'cap-card' }, el('h2', {}, 'Equips gestionats'), btn),
    el('div', { class: 'equips' }, r.equips.map((e) => el('span', { class: `pastilla ${e.descobert ? 'ok' : ''}`, title: titolEq(e) },
      `${e.titol}${e.enllac ? (e.rol === 'upf' ? ' · connectat al core' : ' · connectada al core') : e.descobert ? ' · descobert' : ''}`))),
    ...notes));
  if (r.equips.length !== EQUIPS_N) { EQUIPS_N = r.equips.length; refrescaEquips(); }
}

async function carregaEstat() {
  let d;
  if (estatTick++ % 6 === 0 || !$('#estat-equips').children.length) pintaEquips(false);
  try { d = await api('GET', '/api/status'); } catch (e) { return; }
  const g = $('#estat-graella'); g.replaceChildren();
  for (const t of d.destins) {
    const card = el('div', { class: 'card' }, el('h2', {}, ME.titols[t.desti] || t.desti));
    if (!t.ok) {
      card.append(el('p', { class: 'error' }, `Agent no accessible: ${t.error}`));
    } else {
      const m = el('table', {}, el('tbody', {}, t.metriques.map((x) =>
        el('tr', {}, el('th', {}, x.etiqueta),
           el('td', { class: x.obsolet ? 'warn' : (x.valor ? '' : 'nota') },
              x.obsolet ? `contenidor aturat${x.valor ? ` (darrer: ${x.valor})` : ''}` : (x.valor ?? 'sense dades')),
           el('td', { class: 'nota' }, local(x.quan))))));
      const c = el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, 'Contenidor'), el('th', {}, 'Estat'), el('th', {}, 'Des de'))),
        el('tbody', {}, t.contenidors.map((x) => el('tr', {},
          el('td', {}, x.name), el('td', { class: estatClasse(x) }, x.status + (x.health ? ` (${x.health})` : '')),
          el('td', { class: 'nota' }, local(x.started_at))))));
      card.append(m, el('h3', {}, 'Contenidors'), c);
    }
    if (ME.rol === 'admin' && t.ok && t.agent.project_actions) {
      const out = el('pre', { hidden: true });
      const accio = (a, txt) => el('button', { type: 'button', onclick: async (ev) => {
        if (!confirm(`${txt}: ${ME.titols[t.desti] || t.desti}?`)) return;
        const b = ev.target; b.disabled = true; clearInterval(timerEstat);
        try {
          const r = await api('POST', `/api/project/${t.desti}`, { accio: a });
          out.hidden = false; out.textContent = (r.ok ? 'OK\n' : `Error (rc=${r.rc})\n`) + (r.output || '');
        } catch (e) { out.hidden = false; out.textContent = e.message; }
        b.disabled = false; timerEstat = setInterval(carregaEstat, 5000);
      } }, txt);
      const fila = el('div', { class: 'fila' });
      if (t.agent.project_actions.includes('up')) fila.append(accio('up', 'Arrenca tot'));
      if (t.agent.project_actions.includes('stop')) fila.append(accio('stop', 'Atura tot'));
      card.append(fila, out);
    }
    if (t.pendents && t.pendents.length)
      card.append(el('p', { class: 'warn' }, `Canvis pendents d'aplicar: ${t.pendents.join(', ')}`));
    g.append(card);
  }
}

// ------------------------------------------------------------ paràmetres
let PAR = null;

function input(c) {
  const v = c.valor ?? '';
  if (c.enum) {
    const s = el('select', { name: c.clau });
    const opts = c.enum.map(String);
    if (!opts.includes(String(v))) opts.unshift(String(v));
    opts.forEach((o) => s.append(el('option', { value: o, selected: o === String(v) }, o)));
    return s;
  }
  const a = { name: c.clau, value: v };
  if (c.tipus === 'int' || c.tipus === 'float') {
    a.type = 'number'; a.step = c.tipus === 'int' ? '1' : 'any';
    if (c.min != null) a.min = c.min; if (c.max != null) a.max = c.max;
  }
  return el('input', a);
}

async function carregaParametres() {
  const t = $('#par-desti').value;
  $('#par-resultat').replaceChildren();
  try { PAR = await api('GET', `/api/env/${t}`); } catch (e) {
    $('#form-par').replaceChildren(el('p', { class: 'error' }, e.message)); return;
  }
  const admin = ME.rol === 'admin';
  const f = $('#form-par'); f.replaceChildren();
  for (const c of PAR.camps) {
    const i = input(c);
    const usable = admin && c.existeix && c.editable_agent;
    i.disabled = !usable;
    i.addEventListener('input', () => i.parentElement.classList.toggle('canviat', String(i.value) !== String(c.valor ?? '')));
    const nota = !c.existeix ? 'no definit en aquest equip' : (!c.editable_agent ? 'només lectura en aquest equip' : '');
    f.append(el('label', { 'data-clau': c.clau }, c.etiqueta || c.clau, i,
                el('span', { class: 'camp-error' }), nota ? el('span', { class: 'nota' }, nota) : null));
  }
  if (PAR.camps.some((c) => c.clau === 'DL_ARFCN')) muntaFreq(f);
  if (admin) {
    f.append(el('div', { class: 'accions' },
      el('button', { type: 'button', onclick: () => enviaPar(false) }, 'Validar'),
      el('button', { type: 'submit', class: 'primari' }, 'Desa')));
  }
  pintaPendents(PAR.pendents);
  carregaTdd(t);
  carregaPlmn(t);
}

// ---- freqüència central -> DL_ARFCN, BAND i SCS (el càlcul el fa el servidor, 38.104)
function arfcnAMhz(n) {
  if (n < 600000) return n * 0.005;
  if (n < 2016667) return 3000 + (n - 600000) * 0.015;
  return 24250.08 + (n - 2016667) * 0.06;
}
const campPar = (k) => $(`#form-par [name="${k}"]`);
function posa(k, v) {
  const i = campPar(k);
  if (!i || i.disabled || v === null || v === undefined || String(i.value) === String(v)) return;
  if (i.tagName === 'SELECT' && ![...i.options].some((o) => o.value === String(v))) i.append(el('option', { value: String(v) }, String(v)));
  i.value = String(v);
  i.dispatchEvent(new Event('input'));
}
function opcions(k, vals, nota) {
  const i = campPar(k);
  if (!i || i.tagName !== 'SELECT') return;
  const cur = i.value;
  const vs = vals.map(String);
  if (!vs.includes(cur)) vs.push(cur);
  i.replaceChildren(...vs.map((v) => el('option', { value: v, selected: v === cur },
    vals.map(String).includes(v) ? (nota ? nota(v) : v) : `${v} (no vàlid aquí)`)));
}

// ---- selector d'espectre: tria la banda (n28, n40, n77, n78) i pica la freqüència al dibuix.
// En FDD (n28) es dibuixa també la pujada aparellada: no es configura, el mòbil hi transmet sol.
// sv() (SVG) és més avall, amb els gràfics; les declaracions de funció es pugen soles.
const fmtMhz = (x) => `${+(+x).toFixed(2)}`;
function muntaEspectre(abans, fi, nomesLectura, triaBanda, recalcula) {
  const box = el('div', { class: 'espectre' });
  abans.before(box);
  const botons = el('div', { class: 'espectre-bandes', role: 'radiogroup', 'aria-label': 'Banda' });
  const dib = el('div', { class: 'espectre-dib' });
  const peu = el('p', { class: 'nota' });
  box.append(el('div', { class: 'espectre-cap' }, el('strong', {}, 'Espectre'),
    el('span', { class: 'nota' }, ' Tria la banda i pica la freqüència central al dibuix.')), botons, dib, peu);
  let B = null, darrer = null;
  api('GET', '/api/radio/bandes').then((d) => {
    B = d;
    botons.replaceChildren(...d.espectre.map((n) => {
      const b = d.bandes[n];
      const txt = `n${n} (${fmtMhz(b.dl_mhz[0])}–${fmtMhz(b.dl_mhz[1])} MHz · ${b.duplex})`;
      const bt = el('button', { type: 'button', class: 'pastilla-boto', 'data-banda': n, role: 'radio', disabled: nomesLectura }, txt);
      bt.addEventListener('click', () => {
        const [lo, hi] = b.dl_mhz;
        const ample = parseFloat(campPar('BANDWIDTH_MHZ')?.value) || 0;
        const f = parseFloat(fi.value);
        triaBanda(n);
        // si la freqüència actual no hi cap, al mig de la banda
        if (!(f - ample / 2 >= lo && f + ample / 2 <= hi)) fi.value = fmtMhz((lo + hi) / 2);
        recalcula();
      });
      return bt;
    }));
    if (darrer) dibuixa(darrer);
  }).catch(() => box.remove());

  function dibuixa(r) {
    darrer = r;
    if (!B) return;
    botons.querySelectorAll('button').forEach((bt) => bt.setAttribute('aria-checked', String(+bt.dataset.banda === r.banda)));
    const b = B.bandes[r.banda];
    if (!b) {
      dib.replaceChildren(); peu.textContent = `n${r.banda} no és al selector (${B.espectre.map((n) => 'n' + n).join(', ')}).`;
      return;
    }
    const ample = parseFloat(campPar('BANDWIDTH_MHZ')?.value) || 0;
    const [dlo, dhi] = b.dl_mhz, ul = b.ul_mhz;
    const xmin = Math.min(dlo, ul ? ul[0] : dlo), xmax = Math.max(dhi, ul ? ul[1] : dhi);
    const pad = (xmax - xmin) * 0.04;
    const a0 = xmin - pad, a1 = xmax + pad, W = 800, H = 118, M = 14;
    const X = (f) => M + (f - a0) / (a1 - a0) * (W - 2 * M);
    const F = (x) => a0 + (x - M) / (W - 2 * M) * (a1 - a0);
    const svg = sv('svg', { viewBox: `0 0 ${W} ${H}`, class: 'espectre-svg', role: 'img',
      'aria-label': `Banda n${r.banda}, canal a ${fmtMhz(r.freq_real_mhz)} MHz` });
    const yB = 30, hB = 44;
    // eix i marques
    const rang = a1 - a0, pasos = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500];
    const step = pasos.find((p) => rang / p <= 9) || 500;
    svg.append(sv('line', { x1: M, x2: W - M, y1: yB + hB + 8, y2: yB + hB + 8, class: 'eix' }));
    for (let t = Math.ceil(a0 / step) * step; t <= a1; t += step) {
      svg.append(sv('line', { x1: X(t), x2: X(t), y1: yB + hB + 5, y2: yB + hB + 11, class: 'eix' }),
        sv('text', { x: X(t), y: yB + hB + 25, class: 'eix-txt', 'text-anchor': 'middle' }, `${t}`));
    }
    svg.append(sv('text', { x: W - M, y: H - 2, class: 'eix-txt', 'text-anchor': 'end' }, 'MHz'));
    // bandes
    const zona = (lo, hi, cls, etiqueta) => {
      svg.append(sv('rect', { x: X(lo), y: yB, width: X(hi) - X(lo), height: hB, rx: 4, class: cls }),
        sv('text', { x: (X(lo) + X(hi)) / 2, y: yB - 8, class: 'zona-txt', 'text-anchor': 'middle' }, etiqueta));
    };
    if (ul) {
      zona(ul[0], ul[1], 'zona-ul', `Pujada (UL) ${ul[0]}–${ul[1]}`);
      zona(dlo, dhi, 'zona-dl', `Baixada (DL) ${dlo}–${dhi} · pica aquí`);
    } else {
      zona(dlo, dhi, 'zona-dl', `n${r.banda} TDD ${dlo}–${dhi} (baixada i pujada a la mateixa freqüència) · pica aquí`);
    }
    // canals
    const canal = (fc, cls, txt) => {
      const x0 = X(fc - ample / 2), x1 = X(fc + ample / 2);
      svg.append(sv('rect', { x: x0, y: yB + 4, width: Math.max(2, x1 - x0), height: hB - 8, rx: 3, class: cls }),
        sv('line', { x1: X(fc), x2: X(fc), y1: yB, y2: yB + hB, class: cls + '-mig' }),
        x1 - x0 >= 58   // si el canal és estret (n77/n78), l'etiqueta va al costat
          ? sv('text', { x: X(fc), y: yB + hB / 2 + 4, class: 'canal-txt', 'text-anchor': 'middle' }, txt)
          : sv('text', { x: x1 + 5, y: yB + hB / 2 + 4, class: 'canal-txt fora' }, `${txt} MHz`));
    };
    const fc = r.freq_real_mhz;
    canal(fc, 'canal-dl', fmtMhz(fc));
    if (r.ul) canal(r.ul.freq_mhz, 'canal-ul', fmtMhz(r.ul.freq_mhz));
    // cursor i clic: la freqüència es limita perquè hi càpiga tot el canal
    const guia = sv('line', { y1: yB - 2, y2: yB + hB + 2, class: 'guia', visibility: 'hidden' });
    const guiaTxt = sv('text', { y: yB + hB + 38, class: 'eix-txt guia-txt', 'text-anchor': 'middle', visibility: 'hidden' });
    svg.append(guia, guiaTxt);
    const clampF = (f) => Math.min(dhi - ample / 2, Math.max(dlo + ample / 2, f));
    const deEvent = (ev) => {
      const pt = svg.getBoundingClientRect();
      return F((ev.clientX - pt.left) / pt.width * W);
    };
    if (!nomesLectura) {
      const hit = sv('rect', { x: X(dlo), y: yB - 4, width: X(dhi) - X(dlo), height: hB + 8, class: 'hit' });
      hit.addEventListener('pointermove', (ev) => {
        const f = clampF(deEvent(ev));
        for (const n of [guia]) { n.setAttribute('x1', X(f)); n.setAttribute('x2', X(f)); n.setAttribute('visibility', 'visible'); }
        guiaTxt.setAttribute('x', X(f)); guiaTxt.setAttribute('visibility', 'visible');
        guiaTxt.textContent = `${fmtMhz(f)} MHz` + (ul ? ` (UL ${fmtMhz(f - (dlo - ul[0]))})` : '');
      });
      hit.addEventListener('pointerleave', () => { guia.setAttribute('visibility', 'hidden'); guiaTxt.setAttribute('visibility', 'hidden'); });
      hit.addEventListener('click', (ev) => {
        fi.value = fmtMhz(Math.round(clampF(deEvent(ev)) * 10) / 10);
        fi.dispatchEvent(new Event('input'));
        recalcula();
      });
      svg.append(hit);
    }
    dib.replaceChildren(svg);
    peu.textContent = r.ul
      ? `Baixada ${fmtMhz(fc)} MHz (${fmtMhz(fc - ample / 2)}–${fmtMhz(fc + ample / 2)}) · pujada ${fmtMhz(r.ul.freq_mhz)} MHz ` +
        `(${fmtMhz(r.ul.freq_mhz - ample / 2)}–${fmtMhz(r.ul.freq_mhz + ample / 2)}). La pujada no es configura: és la baixada menys ` +
        `${r.ul.separacio_mhz} MHz (separació dúplex de n${r.banda}) i el mòbil hi transmet sol.`
      : `Canal ${fmtMhz(fc - ample / 2)}–${fmtMhz(fc + ample / 2)} MHz. En TDD la pujada i la baixada fan servir aquesta mateixa freqüència, alternant en el temps (patró TDD).`;
  }
  return { dibuixa };
}

function muntaFreq(f) {
  const arf = campPar('DL_ARFCN');
  if (!arf) return;
  const n0 = parseInt(arf.value, 10);
  const fi = el('input', { type: 'number', step: 'any', min: '410', max: '7125', name: '_FREQ',
    value: Number.isFinite(n0) ? +arfcnAMhz(n0).toFixed(4) : '', disabled: arf.disabled });
  const info = el('span', { class: 'nota' });
  const err = el('span', { class: 'camp-error' });
  const lab = el('label', { 'data-clau': '_FREQ', class: 'freq' }, 'Freqüència central (MHz)', fi, info, err);
  arf.parentElement.before(lab);
  const esp = muntaEspectre(lab, fi, arf.disabled, (banda) => {
    bandaManual = true; scsManual = false;
    posa('BAND', banda);
  }, () => calcula('freq'));

  // La banda i la SCS es proposen soles; només es respecten si les has triat a mà
  // (o, en carregar, les que ja hi ha al .env). Canviar la banda torna la SCS a automàtica.
  let timer = null, seq = 0, inicial = true, bandaManual = false, scsManual = false;
  async function calcula(origen) {
    const q = new URLSearchParams();
    if (origen === 'arfcn') q.set('arfcn', arf.value); else if (fi.value) q.set('freq', fi.value); else return;
    const usa = { banda: inicial || bandaManual, scs: inicial || scsManual, ample: true };
    inicial = false;
    for (const [k, p] of [['BAND', 'banda'], ['SCS', 'scs'], ['BANDWIDTH_MHZ', 'ample']]) {
      const i = campPar(k);
      if (i && i.value && usa[p]) q.set(p, i.value);
    }
    const my = ++seq;
    let r;
    try { r = await api('GET', `/api/radio/calcula?${q}`); } catch (e) { err.textContent = e.message; return; }
    if (my !== seq) return;
    err.textContent = (r.errors || []).join(' ');
    if (!r.arfcn) { info.textContent = ''; return; }
    if (origen === 'arfcn') fi.value = r.freq_mhz;
    else posa('DL_ARFCN', r.arfcn);
    opcions('BAND', r.bandes, (v) => (v === String(r.banda) ? `n${v} (${r.duplex})` : `n${v}`));
    posa('BAND', r.banda);
    opcions('SCS', r.scs_permeses);
    posa('SCS', r.scs);
    const sr = campPar('SRATE');
    if (sr && r.srate_suggerida && parseFloat(sr.value) + 1e-9 < r.srate_suggerida) posa('SRATE', r.srate_suggerida);
    const ajust = Math.abs(r.freq_real_mhz - r.freq_mhz) > 1e-6 ? ` (ajustada al raster: ${r.freq_real_mhz} MHz)` : '';
    esp.dibuixa(r);
    info.textContent = `ARFCN ${r.arfcn}${ajust} · n${r.banda} ${r.duplex} ${r.rang_mhz[0]}–${r.rang_mhz[1]} MHz` +
      (r.bandes.length > 1 ? ` · també cau a ${r.bandes.filter((b) => b !== r.banda).map((b) => `n${b}`).join(', ')}` : '') +
      ` · SCS ${r.scs} kHz` + ((r.avisos || []).length ? ` · ${r.avisos.join(' ')}` : '');
  }
  const prog = (origen) => { clearTimeout(timer); timer = setTimeout(() => calcula(origen), 350); };
  fi.addEventListener('input', () => prog('freq'));
  arf.addEventListener('change', () => prog('arfcn'));
  for (const k of ['BAND', 'SCS', 'BANDWIDTH_MHZ']) {
    const i = campPar(k);
    if (!i) continue;
    i.addEventListener('change', () => {
      if (k === 'BAND') { bandaManual = true; scsManual = false; }
      if (k === 'SCS') scsManual = true;
      prog(fi.value ? 'freq' : 'arfcn');
    });
  }
  if (fi.value) calcula('arfcn');
}

// ---- patró TDD (afegeix/treu les variables del .env i el bloc tdd_ul_dl_cfg del compose)
const TDD_CAMPS = [
  ['PERIOD_TDD', 'Període (slots)'], ['DL_SLOTS', 'Slots de baixada'], ['DL_SYMBOLS', 'Símbols DL a l\'slot especial'],
  ['UL_SLOTS', 'Slots de pujada'], ['UL_SYMBOLS', 'Símbols UL a l\'slot especial'],
];
function pintaTrama(v) {
  if (!v || !(v.trama || []).length) return null;
  const tip = { D: 'Baixada', U: 'Pujada', F: 'Flexible (sense ús)', S: `Especial: ${v.dl_especial} DL · ${14 - v.dl_especial - v.ul_especial} guarda · ${v.ul_especial} UL` };
  return el('div', { class: 'trama' }, v.trama.map((x, i) => el('span', { class: `slot s-${x}`, title: `Slot ${i}: ${tip[x]}` },
    x === 'S' ? el('span', { class: 'sim' }, ...Array.from({ length: 14 }, (_, k) =>
      el('i', { class: k < v.dl_especial ? 'd' : k >= 14 - v.ul_especial ? 'u' : 'g' }))) : x)));
}
async function carregaTdd(t) {
  const box = $('#par-tdd'); box.replaceChildren();
  let st;
  try { st = await api('GET', `/api/tdd/${t}`); } catch (_) { return; }   // aquest equip no en té
  const admin = ME.rol === 'admin';
  const chk = el('input', { type: 'checkbox', checked: st.actiu, disabled: !admin || st.manual });
  const ins = {};
  const camps = el('div', { class: 'graella-tdd' }, TDD_CAMPS.map(([k, txt]) => {
    const [lo, hi] = st.limits[k];
    const v = st.env[k] ?? st.defecte[k];
    ins[k] = el('input', { type: 'number', min: lo, max: hi, step: 1, value: v, disabled: !admin });
    return el('label', {}, txt, ins[k], el('span', { class: 'nota' }, `per defecte ${st.defecte[k]}`));
  }));
  const res = el('div', {});
  const estat = el('p', { class: 'nota' }, st.manual ? 'La configuració del gNB ja té un patró TDD definit manualment: el panell no el modifica.'
    : st.actiu ? 'Patró personalitzat actiu.' : 'Desactivat: el gNB fa servir el patró TDD per defecte.');
  const valors = () => Object.fromEntries(TDD_CAMPS.map(([k]) => [k, ins[k].value]));
  function pinta(v) {
    res.replaceChildren(...[
      v.resum ? el('p', {}, el('b', {}, 'Trama: '), v.resum) : null, pintaTrama(v),
      ...(v.errors || []).map((m) => el('p', { class: 'error' }, m)),
      ...(v.warnings || []).map((m) => el('p', { class: 'warn' }, m))].filter(Boolean));
  }
  let tm = null;
  const revalida = () => { clearTimeout(tm); tm = setTimeout(async () => {
    try { pinta(await api('POST', `/api/tdd/${t}/validate`, { activa: chk.checked, valors: valors() })); } catch (e) { res.replaceChildren(el('p', { class: 'error' }, e.message)); }
  }, 300); };
  const sync = () => { camps.hidden = !chk.checked; revalida(); };
  const pastilla = el('span', { class: `pastilla ${st.actiu ? 'ok' : ''}` }, st.manual ? 'Manual' : st.actiu ? 'Activat' : 'Desactivat');
  chk.addEventListener('change', sync);
  Object.values(ins).forEach((i) => i.addEventListener('input', revalida));
  const btn = el('button', { type: 'button', class: 'primari', disabled: !admin || st.manual }, 'Desa');
  btn.addEventListener('click', async () => {
    btn.disabled = true;
    try {
      const r = await api('POST', `/api/tdd/${t}`, { activa: chk.checked, valors: chk.checked ? valors() : {} });
      pinta(r);
      estat.textContent = r.activa ? 'Patró personalitzat actiu.' : 'Desactivat: el gNB fa servir el patró TDD per defecte.';
      pastilla.className = `pastilla ${r.activa ? 'ok' : ''}`; pastilla.textContent = r.activa ? 'Activat' : 'Desactivat';
      res.append(el('p', { class: 'ok' }, `Desat amb còpia de seguretat. Recrea el gNB (Aplicar canvis) perquè tingui efecte.`));
      pintaPendents(r.pendents);
    } catch (e) { res.append(el('p', { class: 'error' }, e.message)); }
    btn.disabled = !admin;
  });
  chk.setAttribute('role', 'switch');
  box.append(el('div', { class: 'caixa' },
    el('div', { class: 'cap-card' }, el('h3', {}, 'Patró TDD personalitzat'), pastilla),
    el('p', { class: 'nota' }, `Banda n${st.banda ?? '?'} · SCS ${st.scs ?? '?'} kHz. Defineix quants slots i símbols de cada trama són de baixada i de pujada.`),
    el('label', { class: 'interruptor' }, chk, 'Activat'), estat, camps, res,
    admin ? el('div', { class: 'fila' }, btn) : null));
  camps.hidden = !chk.checked;
  pinta(st.validacio);
}

// ---- diversos PLMN (opció avançada: interruptor activar/desactivar)
async function carregaPlmn(t) {
  const box = $('#par-plmn'); box.replaceChildren();
  let st;
  try { st = await api('GET', `/api/plmn/${t}`); } catch (_) { return; }
  const admin = ME.rol === 'admin';
  const core = st.rol === 'core';
  const titol = core ? 'Segon PLMN al core' : 'Segon PLMN a la cel·la';
  const caixa = el('div', { class: 'caixa' });
  box.append(caixa);
  const chk = el('input', { type: 'checkbox', role: 'switch', checked: st.actiu, disabled: !admin });
  const ins = {};
  const camps = core
    ? [['MCC_2', 'MCC del segon PLMN', 3], ['MNC_2', 'MNC del segon PLMN', 3]]
    : [['PLMN_2', 'Segon PLMN (MCC + MNC)', 6]];
  const form = el('div', { class: 'fila' }, camps.map(([k, txt, n]) => {
    ins[k] = el('input', { class: 'w9', value: st.env[k] ?? '', maxlength: n, inputmode: 'numeric', disabled: !admin });
    return el('label', {}, txt, ins[k]);
  }));
  const res = el('div', {});
  const valors = () => Object.fromEntries(Object.entries(ins).map(([k, i]) => [k, i.value.trim()]));
  const pinta = (v) => res.replaceChildren(...[...(v.errors || []).map((m) => el('p', { class: 'error' }, llegible(m))),
    ...(v.warnings || []).map((m) => el('p', { class: 'warn' }, llegible(m)))]);
  let tm = null;
  const revalida = () => { clearTimeout(tm); tm = setTimeout(async () => {
    try { pinta(await api('POST', `/api/plmn/${t}/validate`, { activa: chk.checked, valors: valors() })); } catch (e) { res.replaceChildren(el('p', { class: 'error' }, e.message)); }
  }, 300); };
  chk.addEventListener('change', () => { form.hidden = !chk.checked; revalida(); });
  Object.values(ins).forEach((i) => i.addEventListener('input', revalida));
  const pastilla = el('span', { class: `pastilla ${st.actiu ? 'ok' : st.parcial ? 'warn' : ''}` },
    st.actiu ? 'Activat' : st.parcial ? 'Incomplet' : 'Desactivat');
  const estat = el('p', { class: st.parcial ? 'warn' : 'nota' }, st.parcial
    ? 'Configuració incompleta: desa (activat o desactivat) per deixar-la coherent.'
    : st.actiu ? `PLMN principal ${st.plmn1 || '?'} + segon PLMN ${core ? `${st.env.MCC_2}${st.env.MNC_2}` : st.env.PLMN_2}.`
      : `Només el PLMN ${st.plmn1 || '?'}.`);
  const btn = el('button', { type: 'button', class: 'primari', disabled: !admin }, 'Desa');
  btn.addEventListener('click', async () => {
    btn.disabled = true;
    try {
      const r = await api('POST', `/api/plmn/${t}`, { activa: chk.checked, valors: chk.checked ? valors() : {} });
      pinta(r);
      res.append(el('p', { class: 'ok' }, r.canvis.length
        ? `Desat amb còpia de seguretat de cada fitxer. Recrea ${core ? 'l\'AMF i l\'NRF' : 'el gNB'} (Aplicar canvis) perquè tingui efecte.`
        : 'No hi havia res a canviar.'));
      pintaPendents(r.pendents);
      estat.className = 'nota';
      estat.textContent = r.activa ? `PLMN principal ${st.plmn1 || '?'} + segon PLMN ${Object.values(r.valors || {}).join('')}.`
        : `Només el PLMN ${st.plmn1 || '?'}.`;
      pastilla.className = `pastilla ${r.activa ? 'ok' : ''}`; pastilla.textContent = r.activa ? 'Activat' : 'Desactivat';
    } catch (e) { res.append(el('p', { class: 'error' }, e.message)); }
    btn.disabled = !admin;
  });
  caixa.append(el('div', { class: 'cap-card' }, el('h3', {}, titol), pastilla),
    el('p', { class: 'nota' }, core
      ? 'Fa que l\'AMF i l\'NRF acceptin un segon PLMN (MOCN): xarxa compartida amb dos identificadors d\'operador.'
      : 'La cel·la anuncia també el segon PLMN, perquè s\'hi puguin connectar SIM de tots dos operadors.'),
    el('label', { class: 'interruptor' }, chk, 'Activat'), estat, form, res, admin ? el('div', { class: 'fila' }, btn) : null);
  form.hidden = !chk.checked;
  if (chk.checked) revalida();
}

function canvis() {
  const out = {};
  for (const c of PAR.camps) {
    const i = $(`#form-par [name="${c.clau}"]`);
    if (i && !i.disabled && String(i.value) !== String(c.valor ?? '')) out[c.clau] = String(i.value);
  }
  return out;
}

// els missatges del servidor poden portar el nom intern d'un paràmetre: es mostra la seva etiqueta
function llegible(txt) {
  let t = String(txt ?? '');
  for (const c of (PAR && PAR.camps) || []) if (c.etiqueta) t = t.replace(new RegExp(`\\b${c.clau}\\b`, 'g'), `«${c.etiqueta}»`);
  for (const [k, v] of Object.entries(NOMS_EXTRA)) t = t.replace(new RegExp(`\\b${k}\\b`, 'g'), `«${v}»`);
  return t;
}
const NOMS_EXTRA = { PERIOD_TDD: 'Període', DL_SLOTS: 'Slots de baixada', DL_SYMBOLS: 'Símbols de baixada',
  UL_SLOTS: 'Slots de pujada', UL_SYMBOLS: 'Símbols de pujada', MCC_2: 'MCC del segon PLMN',
  MNC_2: 'MNC del segon PLMN', PLMN_2: 'Segon PLMN', PLMN_1: 'PLMN', DOCKER_HOST_IP: 'IP del core',
  CORE_IP: 'IP del core', DL_ARFCN: 'ARFCN de baixada', BAND: 'Banda', SCS: 'Espaiat de subportadora', SRATE: 'Taxa de mostreig' };

function pintaValidacio(r) {
  document.querySelectorAll('#form-par label').forEach((l) => {
    const e = r.field_errors && r.field_errors[l.dataset.clau];
    if (e) l.querySelector('.camp-error').textContent = llegible(e);
  });
  const box = el('div', { class: 'caixa' });
  (r.errors || []).forEach((m) => box.append(el('p', { class: 'error' }, llegible(m))));
  (r.warnings || []).forEach((m) => box.append(el('p', { class: 'warn' }, llegible(m))));
  if (r.ok) box.append(el('p', { class: 'ok' }, r.desat ? `Desat (còpia de seguretat ${r.copia}).` : (r.missatge === 'cap canvi' ? 'No hi ha canvis.' : r.missatge || 'Valors vàlids.')));
  $('#par-resultat').replaceChildren(box);
}

async function enviaPar(desar) {
  const t = $('#par-desti').value;
  const ch = canvis();
  document.querySelectorAll('#form-par .camp-error').forEach((s) => (s.textContent = ''));
  if (!Object.keys(ch).length) { pintaValidacio({ ok: true, missatge: 'No has canviat res.' }); return; }
  try {
    const r = await api('POST', desar ? `/api/env/${t}` : `/api/validate/${t}`, { canvis: ch });
    pintaValidacio(r);
    if (desar && r.desat) { await carregaParametres(); pintaValidacio(r); }
  } catch (e) { $('#par-resultat').replaceChildren(el('p', { class: 'error' }, e.message)); }
}

$('#form-par').addEventListener('submit', (ev) => { ev.preventDefault(); enviaPar(true); });
$('#par-desti').addEventListener('change', carregaParametres);

function pintaPendents(p) {
  const box = $('#par-pendents'); box.replaceChildren();
  if (ME.rol !== 'admin') return;
  const t = $('#par-desti').value;
  const caixa = el('div', { class: 'caixa' }, el('h3', {}, 'Aplicar canvis (recrear serveis)'));
  if (!p || !p.length)
    caixa.append(el('p', { class: 'nota' }, 'Cap servei pendent de recrear. Si cal, tria\'ls a mà.'));
  const disponibles = (PAR && PAR.serveis_agent) || [];
  const llista = [...new Set([...(p || []), ...disponibles])];
  const checks = llista.map((s) => el('label', { class: 'check' },
    el('input', { type: 'checkbox', value: s, checked: (p || []).includes(s) }), s));
  caixa.append(el('div', { class: 'fila' }, checks));
  const btn = el('button', { class: 'primari', type: 'button' }, 'Aplicar');
  const out = el('pre', { hidden: true });
  btn.addEventListener('click', async () => {
    const svcs = checks.map((l) => l.querySelector('input')).filter((i) => i.checked).map((i) => i.value);
    if (!svcs.length) return;
    btn.disabled = true; btn.textContent = 'Aplicant…';
    try {
      const r = await api('POST', `/api/apply/${t}`, { serveis: svcs });
      out.hidden = false; out.textContent = (r.ok ? 'OK\n' : `Error (rc=${r.rc})\n`) + (r.output || '');
      PAR.pendents = r.pendents;
    } catch (e) { out.hidden = false; out.textContent = e.message; }
    btn.disabled = false; btn.textContent = 'Aplicar';
  });
  caixa.append(btn, out);
  box.append(caixa);
}

// ------------------------------------------------------------ logs
async function carregaFonts() {
  const t = $('#log-desti').value;
  const s = $('#log-font');
  let info = null;
  try { info = (await api('GET', '/api/status')).destins.find((x) => x.desti === t); } catch (_) { /* res */ }
  if ($('#log-desti').value !== t) return;          // l'usuari ha canviat d'equip mentrestant
  s.replaceChildren(); s.dataset.desti = t;
  const ag = info && info.agent;
  (ag ? ag.containers : []).forEach((c) => s.append(el('option', { value: `c:${c}` }, c)));
  (ag ? ag.log_files : []).forEach((f) => s.append(el('option', { value: `f:${f}` }, `fitxer ${f}`)));
}

async function carregaLogs() {
  const t = $('#log-desti').value, f = $('#log-font').value, n = $('#log-linies').value || 300;
  if (!f || $('#log-font').dataset.desti !== t) return;
  const url = f.startsWith('c:')
    ? `/api/logs/${t}?container=${encodeURIComponent(f.slice(2))}&tail=${n}`
    : `/api/logfile/${t}?name=${encodeURIComponent(f.slice(2))}&tail=${n}`;
  try {
    const d = await api('GET', url);
    let text = d.log || '';
    const q = $('#log-filtre').value.trim();
    if (q) {
      let rx; try { rx = new RegExp(q, 'i'); } catch (_) { rx = null; }
      text = text.split('\n').filter((l) => (rx ? rx.test(l) : l.includes(q))).join('\n');
    }
    const pre = $('#log-text');
    const avall = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 20;
    pre.textContent = text;
    if (avall) pre.scrollTop = pre.scrollHeight;
  } catch (e) { $('#log-text').textContent = e.message; }
}
$('#log-desti').addEventListener('change', () => carregaFonts().then(carregaLogs));
$('#log-font').addEventListener('change', carregaLogs);
$('#log-filtre').addEventListener('input', carregaLogs);

// ------------------------------------------------------------ UEs (una fitxa per dispositiu)
const ESTATS = {
  connectat: ['ok', 'Connectat', 'Té context radio actiu amb el gNB ara mateix'],
  // CM-IDLE: el mòbil està registrat i localitzable (pausa de ràdio), per tant segueix connectat
  inactiu: ['ok', 'Connectat (en repòs)', 'Registrat al core; sense trànsit ara mateix (CM-IDLE). Es reactiva sol quan cal.'],
  desregistrat: ['muted', 'Desregistrat', 'S\'ha desregistrat o el core l\'ha donat de baixa'],
};
const NIVELLS = { ok: 'ok', info: 'nota', warn: 'warn', error: 'error' };

function quan(iso) {
  if (!iso) return '';
  const d = new Date(iso), s = Math.round((Date.now() - d) / 1000);
  const rel = s < 60 ? `fa ${s} s` : s < 3600 ? `fa ${Math.round(s / 60)} min` : s < 86400 ? `fa ${Math.round(s / 3600)} h` : d.toLocaleDateString();
  return rel;
}
function horaCurta(iso) { return iso ? new Date(iso).toLocaleTimeString() : ''; }
function hexDec(h) { try { return String(parseInt(h, 16)); } catch (_) { return ''; } }

async function omplirDestinsUE() {
  // Només els equips amb rol core (tenen AMF i MongoDB)
  omplirSelects();
}

function kv(rows) {
  return el('dl', { class: 'kv' }, rows.filter((r) => r && r[1] !== null && r[1] !== undefined && r[1] !== '')
    .flatMap(([k, v, title]) => [el('dt', {}, k), el('dd', title ? { title } : {}, v)]));
}

function fitxaUE(u) {
  const [cls, txt, tip] = ESTATS[u.estat] || ['muted', u.estat, ''];
  const dsp = u.dispositiu || {};
  const titol = u.nom || dsp.model || (u.imsi ? `IMSI ${u.imsi}` : u.suci || 'UE desconegut');
  const sub = [u.nom && dsp.model, u.imsi && (u.nom || dsp.model) ? `IMSI ${u.imsi}` : null].filter(Boolean).join(' · ');
  const actives = (u.sessions || []).filter((x) => x.activa !== false);

  const cap = el('div', { class: 'ue-cap' },
    el('div', {}, el('h2', {}, titol), sub ? el('div', { class: 'nota' }, sub) : null),
    el('span', { class: `insignia ${cls}`, title: tip }, txt));

  const ident = kv([
    ['IMSI / SUPI', u.imsi],
    ['SUCI', u.suci_info ? `${u.suci_info.proteccio}` : null, u.suci],
    ['IMEISV', dsp.imeisv || dsp.imei || (dsp.masked_imeisv ? `${dsp.masked_imeisv.slice(0, 10)}····${dsp.masked_imeisv.slice(14)} (emmascarat)` : 'desconegut'),
      dsp.masked_imeisv && !dsp.imeisv ? 'Masked IMEISV de l\'NGAP: els dígits 11-14 no s\'envien, però el TAC (8 primers) sí' : ''],
    ['Model', dsp.model ? `${dsp.model}${dsp.model_font === 'User-Agent' ? ' (pel trànsit)' : ''}` : (dsp.tac ? `TAC ${dsp.tac} (afegeix-lo a tac.csv)` : null),
      dsp.model_font === 'User-Agent' ? 'Tret del User-Agent HTTP o SIP (REGISTER d\'IMS) del mòbil; el nom comercial ve de config/models.csv' : (dsp.model_font === 'TAC' ? `Del TAC ${dsp.tac} de l'IMEI${dsp.tac_font === 'tac.csv' ? ' (config/tac.csv)' : ' (base de dades MoazEb/tac-database)'}${dsp.model_detall ? ': ' + dsp.model_detall : ''}` : '')],
    ['Sistema', dsp.so],
    ['MAC', 'no en té', 'Un mòbil 5G no fa servir Ethernet/Wi-Fi cap al core: la sessió PDU és IP pura i no hi viatja cap MAC. Les MAC de les captures són del gNB i del core. L\'identificador de maquinari equivalent és l\'IMEI.'],
    ['5G-TMSI', u.tmsi ? `${u.tmsi} (${hexDec(u.tmsi)})` : null, u.tmsis && u.tmsis.length > 1 ? `Anteriors: ${u.tmsis.slice(0, -1).join(', ')}` : ''],
    ['Xifrat NAS', dsp.ea ? (dsp.nas_xifrat ? `sí (${dsp.ea})` : `no (${dsp.ea})`) : null],
  ]);
  const xarxa = kv([
    ['Cel·la', u.cell_id ? `TAC ${u.tac} · CellID ${u.cell_id}` : null],
    ['gNB', u.gnb_id != null ? `gNB-ID ${u.gnb_id}${u.cella != null ? ` · cel·la ${u.cella}` : ''}` : null],
    ['Estat a l\'AMF', u.estat_amf],
    ['NGAP ID', u.amf_ue_ngap_id ? `RAN ${u.ran_ue_ngap_id} · AMF ${u.amf_ue_ngap_id}` : null],
    ['Últim registre', u.ultim_registre ? `${horaCurta(u.ultim_registre)} (${quan(u.ultim_registre)})` : null],
    ['Vist per últim cop', u.darrer ? `${horaCurta(u.darrer)} (${quan(u.darrer)})` : null],
  ]);

  const sess = el('div', { class: 'ue-sessions' },
    el('h3', {}, 'Sessions PDU'),
    (u.sessions || []).length ? el('table', {}, el('tbody', {}, u.sessions.map((x) => el('tr', { class: x.activa === false ? 'nota' : '' },
      el('td', {}, el('b', {}, x.dnn)),
      el('td', {}, x.ipv4 || '—', x.ipv6 ? ` / ${x.ipv6}` : ''),
      el('td', {}, x.sst ? `SST ${x.sst}${x.sd ? ` · SD ${x.sd}` : ''}` : ''),
      el('td', {}, x.activa === false ? 'tancada' : x.en_repos ? 'activa (en repòs)' : 'activa'),
      el('td', {}, x.upf ? `UPF ${x.upf}` : ''))))) : el('p', { class: 'nota' }, 'Cap sessió vista.'),
    Object.keys(u.dnn_rebutjats || {}).length ? el('p', { class: 'warn' },
      'Rebutjades: ', Object.entries(u.dnn_rebutjats).map(([k, n]) => `${k} (×${n})`).join(', ')) : null);

  const c = u.comptadors || {};
  const xips = [
    ['Registres', c.registres], ['Service req.', c.service_requests], ['Alliberaments', c.alliberaments],
    ['Paging fallit', c.paging_fallit, c.paging_fallit ? 'warn' : ''], ['Auth fallides', c.auth_fallides, c.auth_fallides ? 'warn' : ''],
    ['Rebuigs', c.rebuigs, c.rebuigs ? 'error' : ''], ['Desregistres', c.desregistres],
  ];
  const comptes = el('div', { class: 'xips' }, xips.map(([k, v, cl]) => el('span', { class: `xip ${cl || ''}` }, el('b', {}, v ?? 0), ' ', k)));

  const avisos = (u.avisos || []).length ? el('ul', { class: 'avisos' },
    u.avisos.map((a) => el('li', { class: NIVELLS[a.nivell] || '' }, a.text))) : null;

  const ips = (u.historial_ip || []).length > 1 ? el('p', { class: 'nota' }, 'IPs anteriors: ',
    u.historial_ip.slice(0, -1).map((x) => `${x.ip} (${horaCurta(x.ts)})`).join(', ')) : null;

  const uas = (dsp.user_agents || []).length ? el('details', {}, el('summary', {}, `User-Agents HTTP vistos (${dsp.user_agents.length})`),
    el('ol', { class: 'timeline' }, dsp.user_agents.map((x) => el('li', {}, el('time', {}, horaCurta(x.darrer)), ' ',
      el('code', {}, x.ua), el('span', { class: 'nota' }, ` · ${x.ip} · ×${x.n}`))))) : null;

  const clau = u.imsi || u.suci || '';
  const act = el('details', { open: OBERTS.has(clau), ontoggle: (ev) => (ev.target.open ? OBERTS.add(clau) : OBERTS.delete(clau)) }, el('summary', {}, `Activitat recent (${(u.events || []).length})`),
    el('ol', { class: 'timeline' }, (u.events || []).slice().reverse().map((e) =>
      el('li', { class: NIVELLS[e.nivell] || '' }, el('time', {}, horaCurta(e.ts)), ' ', e.text,
        e.n > 1 ? el('span', { class: 'nota' }, ` ×${e.n} (fins ${horaCurta(e.fins)})`) : null))));

  const radio = el('div', { class: 'ue-radio', 'data-imsi': u.imsi || '', 'data-estat': u.estat || '', 'data-titol': titol });
  omplirRadio(radio);
  return el('article', { class: `card ue estat-${cls}` }, cap,
    el('div', { class: 'ue-cols' }, el('div', {}, el('h3', {}, 'Identitat'), ident), el('div', {}, el('h3', {}, 'Xarxa'), xarxa)),
    radio, sess, ips, comptes, avisos, uas, act);
}

const OBERTS = new Set();   // fitxes amb l'activitat desplegada (es manté en refrescar)
// Dues passades: primer l'estat en viu (API de l'AMF/SMF, ràpid) i es pinta de seguida;
// després l'historial dels logs, que substitueix les fitxes quan arriba. Un comptador evita
// que una resposta vella trepitgi una de més nova si es refresca o es canvia d'equip.
let SEQ_UE = 0;
const HIST_UE = {};   // últim historial per equip i dispositiu: en refrescar no es perd mentre es recarrega
function pintaUEs(box, d, t, carregant) {
  const f = d.fonts || {};
  const clau = (u) => u.imsi || u.suci || '';
  if (carregant) d.dispositius.forEach((u) => { const h = (HIST_UE[t] || {})[clau(u)]; if (h && !(u.events || []).length) u.events = h; });
  else HIST_UE[t] = Object.fromEntries(d.dispositius.map((u) => [clau(u), u.events || []]));
  $('#ue-fonts').textContent = `Font: estat en viu de l'AMF i l'SMF (${f.estat_viu || '—'}); historial dels logs (${carregant ? 'carregant…' : (f.historial || '—')}). Actualitzat ${new Date().toLocaleTimeString()}.`;
  if (!d.dispositius.length) { box.replaceChildren(el('p', { class: 'nota' }, 'L\'AMF no té cap dispositiu ara mateix.')); return; }
  const n = (e) => d.dispositius.filter((u) => u.estat === e).length;
  box.replaceChildren(
    el('p', { class: 'resum' }, `${d.dispositius.length} dispositius · `, el('span', { class: 'ok' }, `${n('connectat') + n('inactiu')} connectats`),
      n('inactiu') ? ` (${n('inactiu')} en repòs)` : '', ' · ', `${n('desregistrat')} desregistrats`,
      carregant ? el('span', { class: 'nota' }, ' · carregant l\'historial…') : null),
    el('div', { id: 'ue-radio-sense' }),
    el('div', { class: 'graella ues' }, d.dispositius.map(fitxaUE)));
  pintaRadioSense();
}

// ------------------------------------------------------------ mètriques de ràdio per mòbil
// Venen del gNB (ocudu) cada segon. Es demanen a part, després de pintar les fitxes: si la ràdio
// no respon, les fitxes del core surten igualment i aquí només es diu per què no hi ha dades.
const RADIO_UE = {};   // per equip core: última resposta de /api/ues/{t}/radio
let SEQ_RADIO = 0;
function mbps(b) { return b == null ? '—' : b >= 1e6 ? `${(b / 1e6).toFixed(1)} Mbit/s` : `${Math.round(b / 1e3)} kbit/s`; }
function rebutjats(ok, ko) {
  if (ok == null && ko == null) return '—';
  const tot = (ok || 0) + (ko || 0);
  return tot ? `${ko || 0} de ${tot} (${(100 * (ko || 0) / tot).toFixed(1)} %)` : 'cap bloc';
}
function riTxt(v) { return v == null ? '—' : Number.isInteger(v) ? String(v) : v.toFixed(1); }
function blocRadio(m) {
  const cqiCls = m.cqi == null || m.cqi < 0 ? '' : m.cqi >= 10 ? 'ok' : m.cqi >= 6 ? 'warn' : 'error';
  const pct = (ok, ko) => ((ok || 0) + (ko || 0) ? (ko || 0) / ((ok || 0) + (ko || 0)) : 0);
  const blerCls = (ok, ko) => (pct(ok, ko) > 0.1 ? 'error' : pct(ok, ko) > 0.02 ? 'warn' : '');
  const xips = [
    ['CQI', m.cqi == null || m.cqi < 0 ? '—' : `${m.cqi}/15`, cqiCls, 'Qualitat del canal que informa el mòbil (0–15). Com més alt, millor canal i més velocitat possible. Per sota de 6 el canal és dolent.'],
    ['↓', mbps(m.dl_brate), '', 'Velocitat de baixada (gNB → mòbil) lliurada correctament en l\'últim segon'],
    ['↑', mbps(m.ul_brate), '', 'Velocitat de pujada (mòbil → gNB) rebuda correctament en l\'últim segon'],
    ['SNR ↑', m.pusch_snr_db != null ? `${m.pusch_snr_db.toFixed(1)} dB` : '—', '', 'Relació senyal/soroll del que rep el gNB del mòbil. Per sobre de 20 dB és molt bona; per sota de 5 dB, dolenta.'],
    ['MCS', `${m.dl_mcs ?? '—'}/${m.ul_mcs ?? '—'}`, '', 'Modulació de baixada / pujada (0–28). Més alt = més bits per símbol.'],
    ['KO ↓', m.dl_nof_ok == null && m.dl_nof_nok == null ? '—' : `${(100 * (m.dl_nof_nok || 0) / Math.max(1, (m.dl_nof_ok || 0) + (m.dl_nof_nok || 0))).toFixed(1)} %`,
      blerCls(m.dl_nof_ok, m.dl_nof_nok), 'Blocs de baixada que s\'han hagut de repetir en l\'últim segon. Per sobre del 10 % el canal va just.'],
  ];
  const fila = el('div', { class: 'xips' }, xips.map(([k, v, cl, tip]) => el('span', { class: `xip ${cl}`, title: tip }, el('b', {}, v), ' ', k)));
  const d = kv([
    ['Capes MIMO (RI)', `baixada ${riTxt(m.dl_ri ?? m.ri)} · pujada ${riTxt(m.ul_ri)}`, 'Rank Indicator: quants fluxos de dades en paral·lel admet el canal. 1 = sense MIMO; 2 = MIMO 2x2 (cal TX_ANTENA/RX_ANTENA a 2). Si surt amb decimals és la mitjana de l\'últim segon.'],
    ['Modulació (MCS)', `baixada ${m.dl_mcs ?? '—'} · pujada ${m.ul_mcs ?? '—'}`, 'Esquema de modulació i codificació (0–27 o 28). Més alt = més bits per símbol; el gNB l\'adapta segons el CQI i els errors.'],
    ['Blocs repetits ↓', el('span', { class: blerCls(m.dl_nof_ok, m.dl_nof_nok) }, rebutjats(m.dl_nof_ok, m.dl_nof_nok)), 'Blocs de baixada que el mòbil no ha pogut descodificar a la primera (HARQ KO) en l\'últim segon. Per sobre del 10 % el canal va just.'],
    ['Blocs repetits ↑', el('span', { class: blerCls(m.ul_nof_ok, m.ul_nof_nok) }, rebutjats(m.ul_nof_ok, m.ul_nof_nok)), 'Blocs de pujada que el gNB no ha pogut descodificar (CRC KO) en l\'últim segon.'],
    ['SNR de pujada', m.pusch_snr_db != null ? `${m.pusch_snr_db.toFixed(1)} dB` : (m.pucch_snr_db != null ? `${m.pucch_snr_db.toFixed(1)} dB (PUCCH)` : null), 'Relació senyal/soroll del que rep el gNB del mòbil (canal de dades PUSCH). Per sobre de 20 dB és molt bona; per sota de 5 dB, dolenta.'],
    ['RSRP de pujada', m.pusch_rsrp_db != null ? `${m.pusch_rsrp_db.toFixed(1)} dB` : null, 'Potència dels senyals de referència del mòbil tal com arriben al gNB. És relativa (escala digital de l\'SDR, no calibrada en dBm): serveix per comparar, no com a valor absolut.'],
    ['Avançament (TA)', m.ta_ns != null ? `${Math.round(m.ta_ns)} ns (≈ ${Math.round(m.ta_ns * 0.15)} m)` : null, 'Timing Advance: quant s\'ha d\'avançar el mòbil perquè el senyal arribi a temps. La distància és aproximada (llum: 0,15 m per ns d\'anada i tornada) i a pocs metres no és fiable.'],
    ['Marge de potència', m.last_phr != null ? `${m.last_phr} dB` : null, 'Power Headroom: quanta potència li queda al mòbil abans d\'arribar al màxim. Negatiu = ja transmet al màxim.'],
  ]);
  const ass = m.associacio === 'deduida' ? 'deduït (és l\'únic mòbil connectat a aquest gNB)' : 'pel log del gNB';
  const peu = el('p', { class: 'nota' }, `RNTI ${m.rnti} · ${m.radio} · associat ${ass} · fa ${m.edat_s ?? '?'} s`);
  return { fila, detall: d, peu };
}
const TIP_RADIO = 'Del planificador del gNB (ocudu), cada segon. No hi ha RSRP/RSSI de baixada per mòbil: el gNB no el mesura.';
function capRadio(box) {
  const imsi = box.dataset.imsi, h = HIST_RADIO[imsi];
  const b = el('button', { type: 'button', class: 'petit', disabled: !(h && h.size),
    title: h && h.size ? 'Gràfics dels últims 5 minuts' : 'Encara no hi ha cap mostra de ràdio d\'aquest mòbil',
    onclick: () => obreGrafics(imsi, box.dataset.titol) }, 'Gràfics');
  return el('div', { class: 'radio-cap' }, el('h3', { title: TIP_RADIO }, 'Ràdio'), b);
}

// ---- gràfics: historial per IMSI acumulat al navegador (el gNB canvia el RNTI a cada connexió,
// però aquí s'ajunta tot per mòbil). Finestra de 5 minuts; un forat de més de 5 s talla la línia.
const HIST_RADIO = {};          // imsi -> Map(t -> mostra)
const FINESTRA_S = 300;
let HOVER = null;               // {clau, t}: es manté en refrescar cada 3 s
function acumulaHist(imsi, m) {
  const camps = m.hist_camps || [];
  const h = HIST_RADIO[imsi] || (HIST_RADIO[imsi] = new Map());
  for (const fila of m.hist || []) {
    const o = Object.fromEntries(camps.map((c, i) => [c, fila[i]]));
    if (typeof o.t === 'number') h.set(o.t, o);
  }
  const tmax = Math.max(...h.keys());
  for (const t of h.keys()) if (t < tmax - FINESTRA_S) h.delete(t);
}
const pctKO = (ok, ko) => (ok == null && ko == null ? null : (ok || 0) + (ko || 0) ? (100 * (ko || 0)) / ((ok || 0) + (ko || 0)) : 0);
const GRAFS = [
  { id: 'vel', titol: 'Velocitat', unitat: 'Mbit/s', min: 0, dec: 1,
    series: [['Baixada', (x) => (x.dl_brate == null ? null : x.dl_brate / 1e6)], ['Pujada', (x) => (x.ul_brate == null ? null : x.ul_brate / 1e6)]] },
  { id: 'cqi', titol: 'Qualitat del canal (CQI)', unitat: '', min: 0, max: 15, dec: 0, series: [['CQI', (x) => (x.cqi == null || x.cqi < 0 ? null : x.cqi)]] },
  { id: 'mcs', titol: 'Modulació (MCS)', unitat: '', min: 0, max: 28, dec: 0, series: [['Baixada', (x) => x.dl_mcs], ['Pujada', (x) => x.ul_mcs]] },
  { id: 'ko', titol: 'Blocs repetits', unitat: '%', min: 0, dec: 1,
    series: [['Baixada', (x) => pctKO(x.dl_nof_ok, x.dl_nof_nok)], ['Pujada', (x) => pctKO(x.ul_nof_ok, x.ul_nof_nok)]] },
  { id: 'snr', titol: 'SNR de pujada', unitat: 'dB', dec: 1, series: [['SNR', (x) => x.pusch_snr_db]] },
  { id: 'ri', titol: 'Capes MIMO (RI)', unitat: '', min: 0, dec: 1, series: [['Baixada', (x) => x.dl_ri], ['Pujada', (x) => x.ul_ri]] },
  { id: 'rsrp', titol: 'RSRP de pujada (relatiu)', unitat: 'dB', dec: 1, series: [['RSRP', (x) => x.pusch_rsrp_db]] },
];
const SVGNS = 'http://www.w3.org/2000/svg';
function sv(tag, attrs = {}, ...kids) {
  const e = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs)) if (v != null) e.setAttribute(k, v);
  for (const k of kids.flat()) if (k != null) e.append(k instanceof Node ? k : document.createTextNode(String(k)));
  return e;
}
function arrodoneix(v) {
  if (v <= 0) return 1;
  const p = 10 ** Math.floor(Math.log10(v)), f = v / p;
  return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * p;
}
function fmtNum(v, dec) { return v == null || Number.isNaN(v) ? '—' : v.toFixed(dec); }
function grafic(imsi, g, mostres, tmax) {
  const W = 300, H = 92, ml = 34, mr = 6, mt = 8, mb = 18, pw = W - ml - mr, ph = H - mt - mb;
  const vals = mostres.flatMap((x) => g.series.map(([, f]) => f(x))).filter((v) => v != null && !Number.isNaN(v));
  let lo = g.min ?? (vals.length ? Math.min(...vals) : 0), hi = g.max ?? (vals.length ? Math.max(...vals) : 1);
  if (g.max == null) hi = g.min === 0 ? arrodoneix(Math.max(hi, g.unitat === '%' ? 5 : 1)) : hi;
  if (hi - lo < 1e-9) { lo -= 1; hi += 1; }
  if (g.min == null) { const marge = (hi - lo) * 0.1; lo = Math.floor(lo - marge); hi = Math.ceil(hi + marge); }
  const t0 = tmax - FINESTRA_S;
  const X = (t) => ml + ((t - t0) / FINESTRA_S) * pw, Y = (v) => mt + ph - ((v - lo) / (hi - lo)) * ph;
  const fills = [];
  for (let i = 0; i <= 2; i++) {
    const v = lo + ((hi - lo) * i) / 2, y = Y(v);
    fills.push(sv('line', { x1: ml, x2: W - mr, y1: y, y2: y, class: 'graf-reixa' }),
      sv('text', { x: ml - 4, y: y + 3, 'text-anchor': 'end', class: 'graf-eix' }, fmtNum(v, Math.abs(hi - lo) < 3 && g.dec ? 1 : 0)));
  }
  fills.push(sv('text', { x: ml, y: H - 4, class: 'graf-eix' }, '−5 min'), sv('text', { x: W - mr, y: H - 4, 'text-anchor': 'end', class: 'graf-eix' }, 'ara'));
  g.series.forEach(([, f], si) => {
    let d = '', prev = null;
    for (const x of mostres) {
      const v = f(x);
      if (v == null || Number.isNaN(v)) { prev = null; continue; }
      d += `${prev == null || x.t - prev > 5 ? 'M' : 'L'}${X(x.t).toFixed(1)},${Y(v).toFixed(1)}`;
      prev = x.t;
    }
    if (d) fills.push(sv('path', { d, class: `graf-linia serie-${si}` }));
  });
  const marca = sv('g', { class: 'graf-marca' });
  const zona = sv('rect', { x: ml, y: mt, width: pw, height: ph, class: 'graf-zona' });
  const svg = sv('svg', { viewBox: `0 0 ${W} ${H}`, role: 'img', 'aria-label': `${g.titol}, últims 5 minuts` }, fills, marca, zona);
  const tip = el('div', { class: 'graf-tip', hidden: true });
  const clau = `${imsi}|${g.id}`;
  const mostra = (t) => {
    if (!mostres.length) return;
    let x = mostres[0];
    for (const m of mostres) if (Math.abs(m.t - t) < Math.abs(x.t - t)) x = m;
    marca.replaceChildren(sv('line', { x1: X(x.t), x2: X(x.t), y1: mt, y2: mt + ph, class: 'graf-cursor' }),
      g.series.map(([, f], si) => { const v = f(x); return v == null ? null : sv('circle', { cx: X(x.t), cy: Y(v), r: 4, class: `graf-punt serie-${si}` }); }));
    tip.replaceChildren(el('b', {}, new Date(x.t * 1000).toLocaleTimeString()),
      ...g.series.map(([nom, f], si) => el('div', {}, el('span', { class: `graf-mostra serie-${si}` }), ` ${nom}: ${fmtNum(f(x), g.dec)}${g.unitat ? ' ' + g.unitat : ''}`)));
    tip.hidden = false;
    tip.classList.toggle('esquerra', X(x.t) > W * 0.6);
    HOVER = { clau, t: x.t };
  };
  zona.addEventListener('pointermove', (ev) => {
    const r = svg.getBoundingClientRect();
    const vx = ((ev.clientX - r.left) / r.width) * W;
    mostra(t0 + ((vx - ml) / pw) * FINESTRA_S);
  });
  zona.addEventListener('pointerleave', () => { marca.replaceChildren(); tip.hidden = true; if (HOVER && HOVER.clau === clau) HOVER = null; });
  if (HOVER && HOVER.clau === clau) mostra(HOVER.t);
  const ultim = mostres.length ? mostres[mostres.length - 1] : null;
  const llegenda = g.series.length > 1 ? el('span', { class: 'graf-llegenda' },
    g.series.map(([nom], si) => el('span', {}, el('span', { class: `graf-mostra serie-${si}` }), ` ${nom}`))) : null;
  const actual = ultim ? g.series.map(([, f]) => fmtNum(f(ultim), g.dec)).join(' / ') + (g.unitat ? ` ${g.unitat}` : '') : '—';
  return el('figure', { class: 'graf' },
    el('figcaption', {}, el('span', {}, g.titol, ' ', el('b', {}, actual)), llegenda),
    el('div', { class: 'graf-cos' }, svg, tip));
}
function grafics(imsi) {
  const h = HIST_RADIO[imsi];
  if (!h || !h.size) return null;
  const mostres = [...h.values()].sort((a, b) => a.t - b.t);
  const tmax = mostres[mostres.length - 1].t;
  const usats = GRAFS.filter((g) => mostres.some((x) => g.series.some(([, f]) => f(x) != null)));
  return [el('p', { class: 'nota' }, `Últims 5 minuts · ${mostres.length} mostres (una per segon) · els forats són estones sense connexió de ràdio (repòs).`),
    el('div', { class: 'grafs' }, usats.map((g) => grafic(imsi, g, mostres, tmax)))];
}
// Finestra dels gràfics: una sola, es refresca amb les dades noves mentre és oberta.
let DLG = null, DLG_IMSI = null, DLG_TITOL = '';
function obreGrafics(imsi, titol) {
  if (!DLG) {
    DLG = el('dialog', { class: 'dlg-grafs', onclose: () => { DLG_IMSI = null; HOVER = null; } });
    document.body.append(DLG);
  }
  DLG_IMSI = imsi; DLG_TITOL = titol || `IMSI ${imsi}`;
  pintaDialeg();
  if (!DLG.open) DLG.showModal();
}
function pintaDialeg() {
  if (!DLG || !DLG_IMSI) return;
  const r = RADIO_UE[$('#ue-desti').value], m = r ? r.per_imsi[DLG_IMSI] : null;
  const cos = DLG.querySelector('.dlg-cos');
  const scroll = cos ? cos.scrollTop : 0;
  const nou = el('div', { class: 'dlg-cos' },
    m ? el('div', { class: 'dlg-ara' }, blocRadio(m).fila, blocRadio(m).detall, blocRadio(m).peu)
      : el('p', { class: 'nota' }, 'Ara mateix no té connexió de ràdio (en repòs o desconnectat): es mostra el que s\'ha vist abans.'),
    grafics(DLG_IMSI) || el('p', { class: 'nota' }, 'Encara no hi ha mostres.'));
  DLG.replaceChildren(el('div', { class: 'dlg-cap' }, el('h2', {}, `Ràdio · ${DLG_TITOL}`),
    el('button', { type: 'button', onclick: () => DLG.close(), 'aria-label': 'Tanca' }, 'Tanca')), nou);
  nou.scrollTop = scroll;
}
function omplirRadio(box) {
  const t = $('#ue-desti').value, r = RADIO_UE[t];
  const imsi = box.dataset.imsi, estat = box.dataset.estat;
  const m = r && imsi ? r.per_imsi[imsi] : null;
  if (m) { const b = blocRadio(m); box.replaceChildren(capRadio(box), b.fila, b.peu); return; }
  // Sempre el mateix espai: la fitxa no canvia de mida quan el mòbil entra o surt de repòs.
  const txt = estat === 'inactiu' ? 'En repòs: el gNB no el té connectat ara mateix, no hi ha mètriques.'
    : estat !== 'connectat' ? 'Sense connexió de ràdio.'
      : !r ? 'Carregant les mètriques de ràdio…'
        : `Sense mètriques del gNB per a aquest mòbil${Object.values(r.fonts || {}).some((x) => x !== 'ok') ? ` (${Object.entries(r.fonts).filter(([, v]) => v !== 'ok').map(([k, v]) => `${k}: ${v}`).join('; ')})` : ''}.`;
  box.replaceChildren(capRadio(box), el('p', { class: 'nota' }, txt));
}
function pintaRadioSense() {
  const box = $('#ue-radio-sense'), r = RADIO_UE[$('#ue-desti').value];
  if (!box) return;
  const ss = (r && r.sense_mobil) || [];
  box.replaceChildren(...(ss.length ? [el('p', { class: 'warn' },
    `El gNB té ${ss.length} connexió(ns) de ràdio sense mòbil associat: `,
    ss.map((m) => `RNTI ${m.rnti} (${m.radio}, CQI ${m.cqi ?? '—'}, ↓ ${mbps(m.dl_brate)})`).join(', '),
    '. Per associar-les cal rrc_level i ngap_level a info (o debug) a la secció log del gNB.')] : []));
}
async function carregaRadioUE(t) {
  if (!t) return;
  const seq = ++SEQ_RADIO;
  try {
    const r = await api('GET', `/api/ues/${t}/radio`);
    if (seq !== SEQ_RADIO || t !== $('#ue-desti').value) return;
    RADIO_UE[t] = r;
    for (const [imsi, m] of Object.entries(r.per_imsi || {})) acumulaHist(imsi, m);
  } catch (e) {
    if (seq !== SEQ_RADIO) return;
    RADIO_UE[t] = { per_imsi: {}, sense_mobil: [], fonts: { 'ràdio': e.message } };
  }
  document.querySelectorAll('#ue-taula .ue-radio').forEach(omplirRadio);
  pintaDialeg();
  pintaRadioSense();
}
async function carregaUEs() {
  await omplirDestinsUE();
  const t = $('#ue-desti').value;
  const box = $('#ue-taula');
  if (!t) { box.replaceChildren(el('p', { class: 'error' }, 'Cap equip amb AMF accessible.')); return; }
  if (!box.children.length) box.replaceChildren(el('p', { class: 'nota' }, 'Llegint l\'estat de l\'AMF i l\'SMF…'));
  const seq = ++SEQ_UE;
  try {
    const d = await api('GET', `/api/ues/${t}?historial=false`);
    if (seq !== SEQ_UE) return;
    pintaUEs(box, d, t, true);
    carregaRadioUE(t);          // en paral·lel amb l'historial; no l'espera ningú
  } catch (e) {
    if (seq === SEQ_UE) box.replaceChildren(el('p', { class: 'error' }, e.message));
    return;
  }
  try {
    const d = await api('GET', `/api/ues/${t}`);
    if (seq === SEQ_UE) pintaUEs(box, d, t, false);
  } catch (e) {
    if (seq === SEQ_UE) $('#ue-fonts').textContent += ` No s'ha pogut carregar l'historial: ${e.message}`;
  }
}
$('#ue-refresca').addEventListener('click', carregaUEs);
$('#ue-desti').addEventListener('change', () => { $('#ue-taula').replaceChildren(); carregaUEs(); });

// ------------------------------------------------------------ gNodeB
function fitxaGnb(g) {
  const conn = g.connectat === true ? ['ok', 'Connectat', 'Associació SCTP (N2) oberta amb l\'AMF']
    : g.connectat === false ? ['muted', 'Desconnectat', ''] : g.connectat_probable ? ['ok', 'Connectat (probable)', 'L\'últim NG Setup va anar bé; el log de l\'AMF no arriba tan enrere']
      : ['muted', 'Desconegut', ''];
  const loc = g.local;
  const titol = g.nom || (loc ? `gNB local (${loc.titol || loc.desti})` : `gNB ${g.ip}`);
  const sub = [g.nom && loc ? `gNB local (${loc.titol || loc.desti})` : null, `${g.ip}${g.port ? `:${g.port}` : ''}`].filter(Boolean).join(' · ');
  const cap = el('div', { class: 'ue-cap' },
    el('div', {}, el('h2', {}, titol), el('div', { class: 'nota' }, sub)),
    el('span', { class: `insignia ${conn[0]}`, title: conn[2] }, conn[1]));
  const sl = (g.slices || []).map((x) => `SST ${x.sst}${x.sd ? ` · SD ${x.sd}` : ''}`).join(', ');
  const us = g.ultim_setup;
  const ident = kv([
    ['gNB-ID', g.gnb_id != null ? `${g.gnb_id} (0x${g.gnb_id.toString(16)}, ${g.gnb_bits} bits)` : null],
    ['PLMN', g.mcc ? `${g.mcc}${g.mnc} (MCC ${g.mcc} · MNC ${g.mnc})` : null],
    ['TAC', (g.tacs || []).join(', ') || null],
    ['Slices', sl || null],
    ['Paging DRX', g.drx],
    ['AMF', g.amf ? `${g.amf}${g.capacitat ? ` (capacitat ${g.capacitat})` : ''}` : null],
  ]);
  const estat = kv([
    [g.connectat ? 'Connectat des de' : 'Últim canvi', g.des_de ? `${horaCurta(g.des_de)} (${quan(g.des_de)})` : null],
    ['Últim NG Setup', us ? `${us.resultat === 'ok' ? 'acceptat' : us.resultat}${us.causa ? ` (${us.causa})` : ''} · ${horaCurta(us.ts)}` : null],
    ['Connexions / talls', g.connexions || g.desconnexions ? `${g.connexions} / ${g.desconnexions}` : null],
    ['UEs connectats', String(g.n_ues ?? 0)],
  ]);
  const cols = [el('div', {}, el('h3', {}, 'Identitat (NG Setup)'), ident), el('div', {}, el('h3', {}, 'Estat N2'), estat)];
  let local = null;
  if (loc) {
    const gc = (loc.contenidors || []).filter((c) => /gnb/i.test(c.name));
    local = el('div', {}, el('h3', {}, 'Configuració del gNB'), loc.error ? el('p', { class: 'error' }, loc.error) : kv([
      ['Contenidor', gc.map((c) => `${c.name}: ${c.status}`).join(', ') || null],
      ['Freqüència', loc.freq_mhz ? `${loc.freq_mhz} MHz (ARFCN ${loc.DL_ARFCN})` : null],
      ['Banda / ample', loc.BAND ? `n${loc.BAND} · ${loc.BANDWIDTH_MHZ || '?'} MHz · SCS ${loc.SCS || '?'} kHz` : null],
      ['PCI', loc.PCI], ['PLMN / TAC', loc.PLMN_1 ? `${loc.PLMN_1} / ${loc.TAC ?? '?'}` : null],
      ['Taxa de mostreig', loc.SRATE ? `${loc.SRATE} MHz` : null],
      ['Guanys TX / RX', loc.TX_GAIN ? `${loc.TX_GAIN} / ${loc.RX_GAIN} dB` : null],
      ['Antenes DL / UL', loc.RX_ANTENA ? `${loc.RX_ANTENA} / ${loc.TX_ANTENA}` : null],
      ['IP del core', loc.CORE_IP],
    ]));
  }
  const ues = (g.ues || []).length ? el('div', { class: 'ue-sessions' }, el('h3', {}, 'UEs'),
    el('table', {}, el('tbody', {}, g.ues.map((u) => el('tr', { class: ['connectat', 'inactiu'].includes(u.estat) ? '' : 'nota' },
      el('td', {}, el('b', {}, u.nom || (u.imsi ? `IMSI ${u.imsi}` : 'UE'))),
      el('td', {}, `cel·la ${u.cella}`), el('td', {}, (ESTATS[u.estat] || [0, u.estat])[1])))))) : null;
  const avisos = (g.avisos || []).length ? el('ul', { class: 'avisos' },
    g.avisos.map((a) => el('li', { class: NIVELLS[a.nivell] || '' }, a.text))) : null;
  const evs = [...(g.events || []), ...(g.setups || []).map((x) => ({ ts: x.ts, nivell: x.resultat === 'ok' ? 'ok' : 'error',
    text: `NG Setup ${x.resultat === 'ok' ? 'acceptat' : x.resultat}${x.causa ? `: ${x.causa}` : ''}` }))]
    .sort((a, b) => String(a.ts).localeCompare(String(b.ts)));
  const act = evs.length ? el('details', {}, el('summary', {}, `Activitat (${evs.length})`),
    el('ol', { class: 'timeline' }, evs.slice().reverse().map((e) =>
      el('li', { class: NIVELLS[e.nivell] || '' }, el('time', {}, horaCurta(e.ts)), ' ', e.text)))) : null;
  return el('article', { class: `card ue estat-${conn[0]}` }, cap,
    el('div', { class: 'ue-cols' }, ...cols, local), ues, avisos, act);
}

let SEQ_GNB = 0;
const HIST_GNB = {};
function pintaGnbs(box, d, t, carregant) {
  const f = d.fonts || {};
  const clau = (g) => String(g.ip ?? g.gnb_id ?? g.nom ?? '');
  if (carregant) d.gnbs.forEach((g) => { const h = (HIST_GNB[t] || {})[clau(g)];
    if (h) { if (!(g.events || []).length) g.events = h.events; if (!(g.setups || []).length) g.setups = h.setups; } });
  else HIST_GNB[t] = Object.fromEntries(d.gnbs.map((g) => [clau(g), { events: g.events || [], setups: g.setups || [] }]));
  $('#gnb-fonts').textContent = `Font: estat en viu de l'AMF (${f.estat_viu || '—'}); historial del log (${carregant ? 'carregant…' : (f.historial || '—')}). ` +
    (d.n_gnbs_amf != null ? `L'AMF diu que té ${d.n_gnbs_amf} gNB. ` : '') + `Actualitzat ${new Date().toLocaleTimeString()}.`;
  if (!d.gnbs.length) { box.replaceChildren(el('p', { class: 'nota' }, 'L\'AMF no té cap gNB connectat ara mateix.')); return; }
  const n = d.gnbs.filter((g) => g.connectat || g.connectat_probable).length;
  box.replaceChildren(el('p', { class: 'resum' }, `${d.gnbs.length} gNB · `, el('span', { class: 'ok' }, `${n} connectats`),
    carregant ? el('span', { class: 'nota' }, ' · carregant l\'historial…') : null),
    el('div', { class: 'graella ues' }, d.gnbs.map(fitxaGnb)));
}
async function carregaGnbs() {
  await omplirDestinsUE('#gnb-desti');
  const t = $('#gnb-desti').value;
  const box = $('#gnb-llista');
  if (!t) { box.replaceChildren(el('p', { class: 'error' }, 'Cap equip amb AMF accessible.')); return; }
  if (!box.children.length) box.replaceChildren(el('p', { class: 'nota' }, 'Llegint l\'estat de l\'AMF i l\'SMF…'));
  const seq = ++SEQ_GNB;
  try {
    const d = await api('GET', `/api/gnbs/${t}?historial=false`);
    if (seq !== SEQ_GNB) return;
    pintaGnbs(box, d, t, true);
  } catch (e) {
    if (seq === SEQ_GNB) box.replaceChildren(el('p', { class: 'error' }, e.message));
    return;
  }
  try {
    const d = await api('GET', `/api/gnbs/${t}`);
    if (seq === SEQ_GNB) pintaGnbs(box, d, t, false);
  } catch (e) {
    if (seq === SEQ_GNB) $('#gnb-fonts').textContent += ` No s'ha pogut carregar l'historial: ${e.message}`;
  }
}
$('#gnb-refresca').addEventListener('click', carregaGnbs);
$('#gnb-desti').addEventListener('change', () => { $('#gnb-llista').replaceChildren(); carregaGnbs(); });

// ------------------------------------------------------------ subscriptors (substitueix la WebUI) i VoIP
const UNITATS = ['bps', 'Kbps', 'Mbps', 'Gbps', 'Tbps'];
const TIPUS_PDU = { 1: 'IPv4', 2: 'IPv6', 3: 'IPv4v6' };
let SUBS = [], VOIP = null;
const ambr = (v, u) => ({ downlink: { value: v, unit: u }, uplink: { value: v, unit: u } });
// mateixos valors que la WebUI i que els teus abonats que funcionen
const SES_INTERNET = () => ({ name: 'internet', type: 1, qos_index: 9, arp_priority: 8, arp_capability: 1,
  arp_vulnerability: 1, ambr: ambr(1, 3) });
const SES_IMS = () => ({ name: 'ims', type: 1, qos_index: 5, arp_priority: 1, arp_capability: 1,
  arp_vulnerability: 1, ambr: { downlink: { value: 3850, unit: 1 }, uplink: { value: 1530, unit: 1 } } });
const fmtAmbr = (a) => a && a.downlink && a.downlink.value != null
  ? `${a.downlink.value} ${UNITATS[a.downlink.unit] || '?'} ↓ / ${a.uplink.value} ${UNITATS[a.uplink.unit] || '?'} ↑` : '';

function selUnitat(v, cls) {
  return el('select', { class: cls }, UNITATS.map((u, i) => el('option', { value: i, selected: i === v }, u)));
}
function numIn(cls, v, min, max, w) {
  return el('input', { class: `${cls} w${w || 6}`, type: 'number', value: v ?? '', min, max });
}

function filaSessio(se) {
  const tr = el('tr', { class: 'ses' },
    el('td', {}, el('input', { class: 's-name', value: se.name || '', size: 10, required: true })),
    el('td', {}, el('select', { class: 's-type' }, Object.entries(TIPUS_PDU).map(([k, v]) =>
      el('option', { value: k, selected: Number(k) === (se.type || 1) }, v)))),
    el('td', {}, numIn('s-qi', se.qos_index ?? 9, 1, 255, 4)),
    el('td', {}, numIn('s-arp', se.arp_priority ?? 8, 1, 15, 4)),
    el('td', {}, numIn('s-dl', se.ambr?.downlink?.value ?? 1, 0, 2147483647), selUnitat(se.ambr?.downlink?.unit ?? 3, 's-dlu')),
    el('td', {}, numIn('s-ul', se.ambr?.uplink?.value ?? 1, 0, 2147483647), selUnitat(se.ambr?.uplink?.unit ?? 3, 's-ulu')),
    el('td', {}, el('button', { type: 'button', onclick: () => tr.remove() }, '✕')));
  // camps que no s'editen aquí però es conserven
  tr._extra = { arp_capability: se.arp_capability ?? 1, arp_vulnerability: se.arp_vulnerability ?? 1,
    ipv4: se.ipv4 || null, ipv6: se.ipv6 || null };
  if (se.pcc_rules) tr.title = `${se.pcc_rules} regles PCC (es conserven)`;
  return tr;
}

function blocSlice(sl) {
  const tbody = el('tbody', {}, (sl.sessions || []).map(filaSessio));
  const box = el('fieldset', { class: 'slice' },
    el('legend', {}, 'Slice'),
    el('div', { class: 'fila' },
      el('label', {}, 'SST ', numIn('sl-sst', sl.sst ?? 1, 1, 255, 4)),
      el('label', {}, 'SD ', el('input', { class: 'sl-sd', value: sl.sd || '', placeholder: 'cap', size: 7, pattern: '[0-9a-fA-F]{6}' })),
      el('label', { class: 'check' }, el('input', { class: 'sl-def', type: 'checkbox', checked: sl.default_indicator !== false }), ' per defecte'),
      el('button', { type: 'button', onclick: () => box.remove() }, 'Treu el slice')),
    el('table', {}, el('thead', {}, el('tr', {}, ['DNN', 'Tipus', '5QI', 'ARP', 'AMBR ↓', 'AMBR ↑', ''].map((h) => el('th', {}, h)))), tbody),
    el('div', { class: 'fila' },
      el('button', { type: 'button', onclick: () => tbody.append(filaSessio(SES_INTERNET())) }, '+ DNN'),
      el('button', { type: 'button', onclick: () => {
        if ([...tbody.querySelectorAll('.s-name')].some((i) => i.value === 'ims')) return;
        tbody.append(filaSessio(SES_IMS()));
      } }, '+ DNN ims (VoNR)')));
  return box;
}

// plantilla per defecte d'un abonat nou: la configuració de slices/DNN més repetida
function plantillaComuna() {
  const n = {};
  let millor = null;
  for (const s of SUBS) {
    const k = JSON.stringify(s.slices.map((sl) => [sl.sst, sl.sd, sl.sessions.map((x) => x.name)]));
    n[k] = (n[k] || 0) + 1;
    if (!millor || n[k] > n[millor[0]]) millor = [k, s];
  }
  return millor ? millor[1] : null;
}

function obreEditor(sub, plantilla) {
  const nou = !sub;
  const base = sub || SUBS.find((s) => s.imsi === plantilla) || plantillaComuna();
  // en un abonat nou no es copien les IP fixes de la plantilla
  const slices = base ? base.slices.map((s) => ({ ...s, sessions: s.sessions.map((x) => (nou ? { ...x, ipv4: null, ipv6: null } : { ...x })) }))
    : [{ sst: 1, sd: null, default_indicator: true, sessions: [SES_INTERNET()] }];
  const ue = base ? base.ambr : ambr(1, 3);
  const slicesBox = el('div', {}, slices.map(blocSlice));
  const msg = el('div');
  const form = el('form', { class: 'card', id: 'sub-form' },
    el('h2', {}, nou ? 'Nou abonat' : `Edita ${sub.imsi}`),
    nou && SUBS.length ? el('div', { class: 'fila' }, el('label', {}, 'Slices i DNN com ',
      el('select', { onchange: (ev) => obreEditor(null, ev.target.value) },
        SUBS.map((s) => el('option', { value: s.imsi, selected: base && s.imsi === base.imsi },
          `${s.imsi} (${s.slices.map((sl) => sl.sessions.map((x) => x.name).join('+')).join(' | ')})`))))) : null,
    el('div', { class: 'fila' },
      el('label', {}, 'IMSI ', el('input', { name: 'imsi', value: sub ? sub.imsi : '', required: true, pattern: '[0-9]{6,15}',
        size: 16, readonly: !nou })),
      el('label', {}, 'Número de telèfon (MSISDN)', el('input', { name: 'msisdn', value: sub ? sub.msisdn.join(',') : '', placeholder: 'opcional; amb VoIP actiu, permet trucar', size: 30 })),
      el('label', {}, 'AMF ', el('input', { name: 'amf', value: sub ? sub.security.amf || '8000' : '8000', size: 5, pattern: '[0-9a-fA-F]{4}' }))),
    el('div', { class: 'fila' },
      nou ? null : el('button', { type: 'button', title: 'Mostra K i OPc (queda registrat a l\'auditoria)', onclick: async (ev) => {
        try {
          const c = await api('POST', `/api/subs/${$('#sub-desti').value}`, { accio: 'claus', imsi: sub.imsi });
          form.querySelector('[name=k]').value = c.k || '';
          form.querySelector('[name=opc]').value = c.opc || '';
          if (c.op && !c.opc) msg.replaceChildren(el('p', { class: 'nota' }, `Aquest abonat té OP (no OPc): ${c.op}`));
          ev.target.textContent = 'Claus carregades';
        } catch (e) { msg.replaceChildren(el('p', { class: 'error' }, e.message)); }
      } }, 'Mostra claus'),
      el('label', {}, 'K ', el('input', { name: 'k', size: 36, autocomplete: 'off', spellcheck: 'false',
        placeholder: nou ? '32 hex' : (sub.security.te_k ? '(sense canvis)' : 'falta!'), required: nou })),
      el('label', {}, 'OPc ', el('input', { name: 'opc', size: 36, autocomplete: 'off', spellcheck: 'false',
        placeholder: nou ? '32 hex' : (sub.security.te_opc ? '(sense canvis)' : (sub.security.te_op ? 'ara té OP' : 'falta!')), required: nou }))),
    el('div', { class: 'fila' }, el('span', {}, 'AMBR de l\'UE: '),
      numIn('ue-dl', ue.downlink.value, 0, 2147483647), selUnitat(ue.downlink.unit, 'ue-dlu'), ' ↓ ',
      numIn('ue-ul', ue.uplink.value, 0, 2147483647), selUnitat(ue.uplink.unit, 'ue-ulu'), ' ↑'),
    slicesBox,
    el('div', { class: 'fila' },
      el('button', { type: 'button', onclick: () => slicesBox.append(blocSlice({ sst: 1, sd: null, default_indicator: false, sessions: [SES_INTERNET()] })) }, '+ Slice'),
      el('button', { type: 'submit', class: 'primari' }, nou ? 'Dona d\'alta' : 'Desa'),
      el('button', { type: 'button', onclick: () => $('#sub-editor').replaceChildren() }, 'Cancel·la')),
    msg);
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const f = new FormData(form);
    const q = (c, root = form) => root.querySelector(c);
    const body = {
      imsi: f.get('imsi').trim(), k: f.get('k').trim(), opc: f.get('opc').trim(), amf: f.get('amf').trim(),
      msisdn: f.get('msisdn').split(',').map((x) => x.trim().replace(/^\+/, '')).filter(Boolean),
      ambr: { downlink: { value: Number(q('.ue-dl').value), unit: Number(q('.ue-dlu').value) },
              uplink: { value: Number(q('.ue-ul').value), unit: Number(q('.ue-ulu').value) } },
      slices: [...slicesBox.querySelectorAll('fieldset.slice')].map((b) => ({
        sst: Number(q('.sl-sst', b).value), sd: q('.sl-sd', b).value.trim() || null, default_indicator: q('.sl-def', b).checked,
        sessions: [...b.querySelectorAll('tr.ses')].map((tr) => ({
          name: q('.s-name', tr).value.trim(), type: Number(q('.s-type', tr).value), qos_index: Number(q('.s-qi', tr).value),
          arp_priority: Number(q('.s-arp', tr).value), ...tr._extra,
          ambr: { downlink: { value: Number(q('.s-dl', tr).value), unit: Number(q('.s-dlu', tr).value) },
                  uplink: { value: Number(q('.s-ul', tr).value), unit: Number(q('.s-ulu', tr).value) } } })) })),
    };
    msg.replaceChildren(el('p', { class: 'nota' }, 'Desant…'));
    try {
      const r = await api('POST', `/api/subs/${$('#sub-desti').value}`, { accio: 'desa', nou, sub: body });
      $('#sub-editor').replaceChildren(el('p', { class: r.voip && r.voip.startsWith('AVÍS') ? 'warn' : 'ok' }, `${r.imsi} desat.${r.voip ? ' ' + r.voip : ''}`));
      carregaSubs();
    } catch (e) { msg.replaceChildren(el('p', { class: 'error' }, e.message)); }
  });
  $('#sub-editor').replaceChildren(form);
  form.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

async function esborraSub(s) {
  const v = (VOIP?.abonats || []).find((x) => x.imsi === s.imsi);
  if (!confirm(`Esborrar l'abonat ${s.imsi}?` + (v ? `\nTambé se li treurà el número VoIP ${v.msisdn}.` : '') +
               '\nNo es pot desfer (les K/OPc no es poden recuperar).')) return;
  try {
    await api('POST', `/api/subs/${$('#sub-desti').value}`, { accio: 'esborra', imsi: s.imsi });
    carregaSubs();
  } catch (e) { alert(e.message); }
}

function pintaSubs() {
  const box = $('#sub-llista');
  const q = $('#sub-filtre').value.trim();
  const veu = {};
  (VOIP?.abonats || []).forEach((v) => (veu[v.imsi] = v.msisdn));
  const ll = SUBS.filter((s) => !q || s.imsi.includes(q) || s.msisdn.some((m) => m.includes(q)) || (veu[s.imsi] || '').includes(q));
  if (!ll.length) { box.replaceChildren(el('p', { class: 'nota' }, SUBS.length ? 'Cap coincidència.' : 'No hi ha cap abonat.')); return; }
  box.replaceChildren(el('p', { class: 'resum' }, `${ll.length} de ${SUBS.length} abonats`),
    el('table', { class: 'subs' },
      el('thead', {}, el('tr', {}, ['IMSI', 'Números', 'Slices i DNN', 'AMBR UE', 'Claus', 'VoIP', ''].map((h) => el('th', {}, h)))),
      el('tbody', {}, ll.map((s) => el('tr', {},
        el('td', { class: 'mono' }, s.imsi),
        el('td', {}, s.msisdn.join(', ')),
        el('td', {}, s.slices.map((sl) => el('div', {},
          `SST ${sl.sst}${sl.sd ? '/' + sl.sd : ''}${sl.default_indicator ? '' : ' (no per defecte)'}: `,
          sl.sessions.map((x) => `${x.name} (${TIPUS_PDU[x.type] || x.type}, 5QI ${x.qos_index})`).join(', ')))),
        el('td', {}, fmtAmbr(s.ambr)),
        el('td', { class: s.security.te_k && (s.security.te_opc || s.security.te_op) ? '' : 'error' },
          `${s.security.te_k ? 'K' : 'sense K'} + ${s.security.te_opc ? 'OPc' : (s.security.te_op ? 'OP' : 'res')}`),
        el('td', {}, veu[s.imsi] || ''),
        el('td', { class: 'accions' },
          el('button', { type: 'button', onclick: () => obreEditor(s) }, 'Edita'),
          el('button', { type: 'button', onclick: () => esborraSub(s) }, 'Esborra')))))));
}

function pintaVoip() {
  const box = $('#sub-voip');
  if (!VOIP) { box.replaceChildren(); return; }
  const inf = VOIP.info || {};
  if (!inf.activa) { box.replaceChildren(); return; }     // el servei VoIP està desactivat (vegeu la targeta de dalt)
  const t = $('#sub-desti').value;
  const imsiSel = el('select', { name: 'imsi', required: true },
    el('option', { value: '' }, '— tria l\'abonat —'),
    (VOIP.sense_voip || []).map((i) => el('option', { value: i }, i)));
  const num = el('input', { name: 'msisdn', required: true, pattern: '\\+?[0-9]{1,15}', placeholder: 'p. ex. 1003', size: 10 });
  const msg = el('div');
  const passos = (r) => el('ul', { class: 'avisos' }, (r.passos || []).map((p) => el('li', {}, p)));
  const alta = async (imsi, msisdn) => {
    msg.replaceChildren(el('p', { class: 'nota' }, `Configurant ${imsi} ↔ ${msisdn} a Open5GS i PyHSS…`));
    try {
      const r = await api('POST', `/api/voip/${t}`, { accio: 'alta', imsi, msisdn });
      await carregaSubs();
      $('#voip-msg').replaceChildren(el('p', { class: 'ok' }, `Fet: ${r.imsi} té el número ${r.msisdn}. El mòbil l'agafa al proper registre IMS (mode avió i tornar).`), passos(r));
    } catch (e) { msg.replaceChildren(el('p', { class: 'error' }, e.message)); }
  };
  const form = el('form', { class: 'fila' },
    el('label', {}, 'Abonat ', imsiSel), el('label', {}, 'Número ', num),
    el('button', { type: 'submit', class: 'primari' }, 'Assigna número'));
  form.addEventListener('submit', (ev) => { ev.preventDefault(); alta(imsiSel.value, num.value.trim()); });
  const files = (VOIP.abonats || []).map((v) => {
    const nou = el('input', { value: v.msisdn || '', size: 10 });
    return el('tr', {},
      el('td', { class: 'mono' }, v.imsi),
      el('td', {}, nou),
      el('td', { class: v.ok ? 'ok' : 'warn' }, v.ok ? 'correcte' : el('ul', { class: 'avisos' }, v.avisos.map((a) => el('li', {}, a)))),
      el('td', {}, v.registrat_scscf ? local(v.registrat_scscf) : 'mai'),
      el('td', { class: 'accions' },
        el('button', { type: 'button', title: 'Desa el número i torna a sincronitzar claus, APN i DNN ims',
          onclick: () => alta(v.imsi, nou.value.trim()) }, v.ok ? 'Desa' : 'Repara'),
        el('button', { type: 'button', onclick: async () => {
          if (!confirm(`Treure el número ${v.msisdn} a ${v.imsi}? L'abonat 5G es manté.`)) return;
          try { await api('POST', `/api/voip/${t}`, { accio: 'baixa', imsi: v.imsi }); carregaSubs(); }
          catch (e) { alert(e.message); }
        } }, 'Treu VoIP')));
  });
  box.replaceChildren(el('div', { class: 'card' },
    el('h2', {}, 'Números de telèfon'),
    el('p', { class: 'nota' }, `Domini IMS ${inf.domini}. Un abonat amb número de telèfon queda donat d'alta per trucar: `,
      'en desar-lo a la llista d\'abonats es configura sol. També pots assignar-ne un aquí.'),
    form, msg, el('div', { id: 'voip-msg' }),
    files.length ? el('table', { class: 'subs' },
      el('thead', {}, el('tr', {}, ['IMSI', 'Número', 'Estat', 'Últim registre IMS', ''].map((h) => el('th', {}, h)))),
      el('tbody', {}, files)) : el('p', { class: 'nota' }, 'Cap abonat amb número VoIP encara.')));
}

// ---- servei VoIP (Kamailio + PyHSS): activar / desactivar
let VOIPDEP = null, VOIPDEP_MSG = null;
const NOMS_IMS = { dns: 'DNS', mysql: 'MySQL', rtpengine: 'RTPengine', pyhss: 'PyHSS (HSS)', icscf: 'I-CSCF',
  scscf: 'S-CSCF', pcscf: 'P-CSCF', smsc: 'SMSC' };
function pintaVoipDep(t) {
  const box = $('#sub-voipdep');
  const d = VOIPDEP;
  if (!d) { box.replaceChildren(); return; }
  if (d.error) { box.replaceChildren(el('p', { class: 'nota' }, `Servei VoIP: ${d.error}`)); return; }
  const f = d.feina || {};
  const admin = ME.rol === 'admin';
  const possible = d.compose_existeix && !(d.carpetes_falten || []).length;
  const chk = el('input', { type: 'checkbox', role: 'switch', checked: f.en_curs ? f.accio === 'activa' : (d.activa || d.parcial),
    disabled: !admin || f.en_curs || (!possible && !d.activa && !d.parcial) });
  chk.addEventListener('change', async () => {
    const accio = chk.checked ? 'activa' : 'desactiva';
    if (accio === 'desactiva' && !confirm('Aturar el servei VoIP? Les trucades deixaran de funcionar; els abonats i els números es conserven.')) { chk.checked = true; return; }
    if (accio === 'activa' && !confirm('Activar el servei VoIP? Es desplegaran els contenidors IMS (pot trigar uns minuts si cal baixar imatges). El core 5G no s\'atura.')) { chk.checked = false; return; }
    chk.disabled = true;
    VOIPDEP_MSG = null;
    try { await api('POST', `/api/voipdeploy/${t}`, { accio }); } catch (e) { VOIPDEP_MSG = e.message; }
    seguimentVoip(t);
  });
  const msg = VOIPDEP_MSG;
  const estatTxt = f.en_curs ? (f.accio === 'activa' ? 'Activant…' : 'Aturant…') : d.activa ? 'Activat' : d.parcial ? 'Incomplet' : 'Desactivat';
  const pastilla = el('span', { class: `pastilla ${f.en_curs ? 'warn' : d.activa ? 'ok' : d.parcial ? 'warn' : ''}` }, estatTxt);
  const conts = el('div', { class: 'equips' }, Object.entries(d.contenidors || {}).map(([c, st]) =>
    el('span', { class: `pastilla ${st === 'running' ? 'ok' : st === 'absent' ? '' : 'error'}`, title: st }, `${NOMS_IMS[c] || c}`)));
  const avisos = [];
  if (!d.compose_existeix) avisos.push(`Aquesta instal·lació del core no inclou la definició IMS (${d.compose_file}): cal la versió del core amb VoIP.`);
  if ((d.carpetes_falten || []).length) avisos.push(`Falten carpetes de configuració IMS: ${d.carpetes_falten.join(', ')}.`);
  const log = (f.log || []).length ? el('pre', { class: 'registre' }, f.log.join('\n')) : null;
  if (log) setTimeout(() => (log.scrollTop = log.scrollHeight), 0);
  box.replaceChildren(el('div', { class: 'card' },
    el('div', { class: 'cap-card' }, el('h2', {}, 'Servei de telefonia (VoIP / IMS)'), pastilla),
    el('p', { class: 'nota' }, 'Desplega Kamailio (P/I/S-CSCF), PyHSS, MySQL, DNS i RTPengine al costat del core 5G, sense aturar-lo. ',
      'En activar-lo, tots els abonats que tenen número de telèfon queden donats d\'alta per trucar.'),
    el('label', { class: 'interruptor' }, chk, 'Activat'),
    avisos.length ? el('ul', { class: 'avisos' }, avisos.map((a) => el('li', { class: 'warn' }, a))) : null,
    msg ? el('p', { class: 'error' }, msg) : null,
    el('h3', {}, 'Components'), conts,
    f.inici ? el('p', { class: f.en_curs ? 'nota' : f.ok ? 'ok' : 'error' }, f.en_curs ? `En curs des de ${local(f.inici)}`
      : `Darrera operació (${f.accio === 'activa' ? 'activar' : 'aturar'}): ${f.ok ? 'correcta' : 'amb errors'} · ${local(f.fi)}`) : null,
    log ? el('details', { open: f.en_curs || f.ok === false }, el('summary', {}, 'Registre de l\'operació'), log) : null));
}
async function carregaVoipDep(t) {
  try { VOIPDEP = await api('GET', `/api/voipdeploy/${t}`); } catch (e) { VOIPDEP = { error: e.message }; }
  pintaVoipDep(t);
  return VOIPDEP;
}
function seguimentVoip(t) {
  clearInterval(timerVoip);
  const pas = async () => {
    const d = await carregaVoipDep(t);
    if (!d || d.error || !(d.feina || {}).en_curs) { clearInterval(timerVoip); timerVoip = null; carregaSubs(); }
  };
  timerVoip = setInterval(pas, 3000);
  pas();
}

async function carregaSubs() {
  await omplirDestinsUE('#sub-desti');
  const t = $('#sub-desti').value;
  if (!t) { $('#sub-llista').replaceChildren(el('p', { class: 'error' }, 'Cap core accessible.')); return; }
  if (!$('#sub-llista').children.length) $('#sub-llista').replaceChildren(el('p', { class: 'nota' }, 'Carregant abonats…'));
  // la llista no espera el VoIP (si PyHSS va lent o no respon, els abonats surten igual)
  const ps = api('GET', `/api/subs/${t}`).then((r) => { SUBS = r.subscriptors; pintaSubs(); })
    .catch((e) => $('#sub-llista').replaceChildren(el('p', { class: 'error' }, e.message)));
  carregaVoipDep(t).then((d) => { if (d && (d.feina || {}).en_curs && !timerVoip) seguimentVoip(t); });
  const pv = api('GET', `/api/voip/${t}`).then((r) => { VOIP = r; })
    .catch((e) => { VOIP = { info: { activa: false, motiu: e.message } }; })
    .then(() => { pintaVoip(); pintaSubs(); });
  await Promise.all([ps, pv]);
}

function obreCsv() {
  const ta = el('textarea', { rows: 6, cols: 70, spellcheck: 'false', placeholder: 'imsi,k,opc[,msisdn]\n001010000000010,465B5CE8B199B49FAA5F0A2EE238A6BC,E8ED289DEBA952E4283B54E88E6183CA,1010' });
  const plant = el('select', {}, el('option', { value: '' }, 'internet (SST 1, sense SD)'),
    SUBS.map((s) => el('option', { value: s.imsi }, `com ${s.imsi}`)));
  if (SUBS.length) plant.value = SUBS[SUBS.length - 1].imsi;
  const out = el('ul', { class: 'avisos' });
  const go = async () => {
    const t = $('#sub-desti').value;
    const base = SUBS.find((s) => s.imsi === plant.value);
    const linies = ta.value.split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !/^imsi\b/i.test(l));
    out.replaceChildren();
    for (const l of linies) {
      const [imsi, k, opc, msisdn] = l.split(/[,;\t]/).map((x) => (x || '').trim());
      const sub = { imsi, k, opc, amf: '8000', msisdn: msisdn ? [msisdn.replace(/^\+/, '')] : [],
        ambr: base ? base.ambr : ambr(1, 3),
        slices: base ? base.slices.map((sl) => ({ ...sl, sessions: sl.sessions.map((x) => ({ ...x, ipv4: null, ipv6: null })) })) : [{ sst: 1, sd: null, default_indicator: true, sessions: [SES_INTERNET()] }] };
      try {
        const r = await api('POST', `/api/subs/${t}`, { accio: 'desa', nou: true, sub });
        out.append(el('li', { class: r.voip && r.voip.startsWith('AVÍS') ? 'warn' : 'ok' }, `${imsi}: alta feta${r.voip ? ` · ${r.voip}` : ''}`));
      } catch (e) { out.append(el('li', { class: 'error' }, `${imsi || l}: ${e.message}`)); }
    }
    carregaSubs();
  };
  $('#sub-csv').replaceChildren(el('div', { class: 'card' }, el('h2', {}, 'Importa abonats'),
    el('p', { class: 'nota' }, 'Una línia per SIM: imsi,k,opc i, opcionalment, el número. Les claus només es guarden a la base de dades del core.'),
    ta, el('div', { class: 'fila' }, el('label', {}, 'Slices i DNN ', plant),
      el('button', { type: 'button', class: 'primari', onclick: go }, 'Importa'),
      el('button', { type: 'button', onclick: () => $('#sub-csv').replaceChildren() }, 'Tanca')), out));
}

$('#sub-refresca').addEventListener('click', carregaSubs);
$('#sub-nou').addEventListener('click', () => {
  try { obreEditor(null); } catch (e) { mostraError(`Nou abonat: ${e.message} ${e.stack || ''}`); }
});
$('#sub-csv-obre').addEventListener('click', obreCsv);
$('#sub-filtre').addEventListener('input', pintaSubs);
$('#sub-desti').addEventListener('change', () => { $('#sub-llista').replaceChildren(); carregaSubs(); });

// ------------------------------------------------------------ historial
async function carregaHistorial() {
  const t = $('#his-desti').value;
  const ul = $('#his-copies'); ul.replaceChildren();
  try {
    const b = await api('GET', `/api/backups/${t}`);
    for (const n of b.backups) {
      const li = el('li', {}, n, ' ');
      if (ME.rol === 'admin') li.append(el('button', { type: 'button', onclick: async () => {
        if (!confirm(`Restaurar ${n}? Es farà una còpia de l'actual i quedarà pendent d'aplicar.`)) return;
        try { await api('POST', `/api/restore/${t}`, { nom: n }); carregaHistorial(); } catch (e) { alert(e.message); }
      } }, 'Restaurar'));
      ul.append(li);
    }
    if (!b.backups.length) ul.append(el('li', { class: 'nota' }, 'Encara no hi ha còpies.'));
  } catch (e) { ul.append(el('li', { class: 'error' }, e.message)); }
  const tb = $('#his-audit tbody'); tb.replaceChildren();
  try {
    const a = await api('GET', `/api/audit/${t}?tail=200`);
    for (const r of a.audit.reverse())
      tb.append(el('tr', {}, el('td', {}, r.ts.replace('T', ' ').slice(0, 19)), el('td', {}, r.user),
        el('td', {}, r.action), el('td', { class: r.ok ? 'ok' : 'error' }, r.ok ? 'sí' : 'no'),
        el('td', {}, JSON.stringify(r.detail))));
  } catch (e) { tb.append(el('tr', {}, el('td', { colspan: 5, class: 'error' }, e.message))); }
}
$('#his-desti').addEventListener('change', carregaHistorial);

// ------------------------------------------------------------ UPF separat
// El PC del UPF truca al core (com la ràdio). El core el fa servir sol si el mode
// automàtic és actiu; aquí es veu on és el UPF, es pot separar o tornar a ajuntar.
const UPF_METRIQUES = [
  ['fivegs_upffunction_upf_sessionnbr', 'Sessions al UPF', 0],
  ['fivegs_ep_n3_gtp_indatapktn3upf', 'Paquets GTP rebuts de la gNB (N3)', 0],
  ['fivegs_ep_n3_gtp_outdatapktn3upf', 'Paquets GTP enviats a la gNB (N3)', 0],
  ['fivegs_ep_n3_gtp_indatavolumeqosleveln3upf', 'Dades de pujada (N3)', 'b'],
  ['fivegs_ep_n3_gtp_outdatavolumeqosleveln3upf', 'Dades de baixada (N3)', 'b'],
  ['fivegs_upffunction_sm_n4sessionestabreq', 'Peticions de sessió de l\'SMF (N4)', 0],
  ['fivegs_upffunction_sm_n4sessionreport', 'Informes de sessió a l\'SMF (N4)', 0],
  ['fivegs_upffunction_sm_n4sessionreportsucc', 'Informes acceptats (N4)', 0],
];
function bytes(n) {
  if (n == null) return '—';
  const u = ['B', 'kB', 'MB', 'GB', 'TB']; let i = 0;
  while (n >= 1000 && i < u.length - 1) { n /= 1000; i++; }
  return `${n.toFixed(i ? 1 : 0)} ${u[i]}`;
}
function taulaMetriquesUpf(m) {
  if (!m) return el('p', { class: 'nota' }, 'Sense mètriques.');
  const parts = [];
  if (!m.ok) parts.push(el('p', { class: 'warn' }, `No puc llegir les mètriques (${m.url}): ${m.error || '?'}`));
  const tot = m.total || {};
  const files = UPF_METRIQUES.filter(([k]) => k in tot).map(([k, txt, u]) =>
    el('tr', {}, el('th', {}, txt), el('td', {}, u === 'b' ? bytes(tot[k]) : String(Math.round(tot[k])))));
  if (files.length) parts.push(el('table', {}, el('tbody', {}, files)));
  const ifs = Object.entries(m.interficies || {});
  if (ifs.length) parts.push(el('h3', {}, 'Interfícies del contenidor'),
    el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, 'Interfície'), el('th', {}, 'Rebut'), el('th', {}, 'Enviat'))),
      el('tbody', {}, ifs.map(([n, c]) => el('tr', { title: n.startsWith('ogstun') ? 'Túnel dels mòbils: el que hi entra i en surt és el seu trànsit' : '' },
        el('td', {}, n), el('td', {}, `${bytes(c.rx_bytes)} · ${c.rx_paquets} paq.`), el('td', {}, `${bytes(c.tx_bytes)} · ${c.tx_paquets} paq.`))))));
  const altres = Object.entries(tot).filter(([k]) => k.startsWith('fivegs_') && !UPF_METRIQUES.some(([x]) => x === k));
  if (altres.length) {
    const d = el('details', {}, el('summary', {}, `Totes les mètriques (${altres.length} més)`),
      el('table', {}, el('tbody', {}, altres.map(([k, v]) => el('tr', {}, el('td', {}, k), el('td', {}, String(v)))))));
    parts.push(d);
  }
  if (m.hora) parts.push(el('p', { class: 'nota' }, `Llegit per HTTP del servidor de mètriques del UPF a les ${horaCurta(m.hora)}.`));
  return el('div', {}, ...parts);
}
function textPfcp(p) {
  if (!p) return el('span', { class: 'nota' }, 'el log no en diu res');
  return el('span', { class: p.associat ? 'ok' : 'error' },
    `${p.associat ? 'associat' : 'desassociat'} amb ${p.ip || '?'}${p.quan ? ' · ' + local(p.quan) : ''}`);
}
let UPF_ENVIANT = false;
async function accioUpf(t, cos, txt) {
  if (txt && !confirm(txt)) return;
  UPF_ENVIANT = true;
  const box = $('#upf-estat');
  box.prepend(el('p', { class: 'nota', id: 'upf-treballant' }, 'Aplicant… (recrea l\'SMF; pot trigar uns segons)'));
  try {
    const r = await api('POST', `/api/upf/${t}`, cos);
    const canviat = (r.canviat || []).join(', ');
    UPF_ENVIANT = false;
    await carregaUpf();
    $('#upf-estat').prepend(el('p', { class: 'ok' }, `Fet.${canviat ? ' Fitxers canviats: ' + canviat + ' (amb còpia).' : ' No calia canviar cap fitxer.'}`));
  } catch (e) {
    UPF_ENVIANT = false;
    await carregaUpf();
    $('#upf-estat').prepend(el('p', { class: 'error' }, e.message));
  }
}
async function carregaUpf() {
  if (UPF_ENVIANT) return;
  const t = $('#upf-desti').value, box = $('#upf-estat'), llista = $('#upf-llista');
  if (!t) { box.replaceChildren(el('p', { class: 'nota' }, 'No hi ha cap core.')); llista.replaceChildren(); return; }
  let d;
  try { d = await api('GET', `/api/upf/${t}`); }
  catch (e) { box.replaceChildren(el('div', { class: 'card' }, el('p', { class: 'error' }, e.message))); llista.replaceChildren(); return; }
  const admin = ME.rol === 'admin';
  const remot = d.mode === 'remot';
  const upfs = d.upfs || [];
  const sel = upfs.find((u) => u.id === d.upf_id);
  const files = [
    ['On és el UPF', remot ? `separat, en un altre PC (${d.ip})${sel ? ' · ' + sel.id : d.upf_id ? '' : ' · sense agent'}` : 'dins del core'],
    ['PFCP de l\'SMF (N4)', textPfcp(d.pfcp)],
  ];
  if (remot) files.push(['L\'SMF s\'anuncia com a', d.advertise || '—']);
  const card = el('div', { class: 'card' }, el('h2', {}, 'Estat'), kv(files));
  if (admin) {
    const auto = el('input', { type: 'checkbox', role: 'switch', checked: !!d.auto });
    auto.addEventListener('change', () => accioUpf(t, { accio: 'auto', valor: auto.checked }));
    card.append(el('label', { class: 'interruptor', title: 'Quan un PC amb UPF truca al core, el core el fa servir sol (si el core té el seu UPF o el UPF triat no hi és).' },
      auto, ' Fer servir sol el UPF que truqui al core'));
    const fila = el('div', { class: 'fila' });
    if (remot) {
      fila.append(el('button', { type: 'button', onclick: () => accioUpf(t, { accio: 'ajunta' },
        'Tornar a posar el UPF dins del core? L\'SMF es recrea i el UPF remot s\'atura (les sessions dels mòbils es tornen a fer).') }, 'Torna a ajuntar el UPF al core'));
    }
    const ip = el('input', { placeholder: '192.168.2.101', size: 15 });
    fila.append(el('label', { title: 'Per a un UPF muntat a mà, sense agent: el core no el pot configurar ni en veurà les mètriques.' }, 'UPF sense agent a la IP ', ip),
      el('button', { type: 'button', onclick: () => accioUpf(t, { accio: 'separa', ip: ip.value.trim() },
        `Separar el UPF cap a ${ip.value.trim()}? Aquell PC ha de tenir un UPF que accepti aquest SMF.`) }, 'Separa'));
    card.append(fila);
    if (!d.auto && !remot && upfs.some((u) => u.connectat)) card.append(el('p', { class: 'nota' }, 'El mode automàtic és aturat (s\'ha ajuntat a mà): tria un UPF de la llista o torna\'l a activar.'));
  }
  if (!d.rep_upfs) card.append(el('p', { class: 'warn' }, 'L\'agent del core no rep equips (enllaç desactivat): actualitza l\'agent.'));
  if (!remot && d.metriques) card.append(el('h3', {}, 'UPF del core'), taulaMetriquesUpf(d.metriques));
  box.replaceChildren(card);

  const lc = el('div', { class: 'card' }, el('h2', {}, 'PCs amb UPF connectats al core'));
  if (!upfs.length) lc.append(el('p', { class: 'nota' }, 'Cap. Per afegir-ne un: al core, sudo emparella-upf <nom>, i al PC del UPF, l\'ordre que surt (install_upf.sh amb el codi). La resta es fa sol.'));
  for (const u of upfs) {
    const e = u.estat || {};
    const triat = remot && d.upf_id === u.id;
    const cap = el('div', { class: 'cap-card' }, el('h3', {}, `UPF ${u.id}`),
      el('span', { class: `pastilla ${triat ? 'ok' : u.connectat ? '' : 'error'}` },
        triat ? 'en ús pel core' : u.connectat ? 'connectat, no en ús' : 'desconnectat'));
    const b = el('div', {}, cap, kv([
      ['IP (la que veu el core)', u.ip || '—'],
      ['Connectat des de', u.des_de ? local(u.des_de) : '—'],
      ['Contenidor upf', e.corrent ? el('span', { class: 'ok' }, 'en marxa') : el('span', { class: 'nota' }, 'aturat')],
      ['PFCP del UPF', e.corrent ? textPfcp(e.pfcp) : '—'],
      ['Mòbils (internet / IMS)', e.env ? `${e.env.UE_IPV4_INTERNET || '—'} / ${e.env.UE_IPV4_IMS || '—'}` : '—'],
      ['GTP-U (on envia la gNB)', e.env ? `${e.env.UPF_ADVERTISE_IP || '—'}${e.config && e.config.gnb_local ? ' (gNB al mateix PC)' : ''}` : '—'],
    ]));
    if (u.error) b.append(el('p', { class: 'error' }, u.error));
    if (admin && u.connectat && !triat) b.append(el('div', { class: 'fila' }, el('button', { type: 'button', class: 'primari', onclick: () => accioUpf(t, { accio: 'separa', upf_id: u.id },
      `Fer servir el UPF ${u.id} (${u.ip})? L'SMF es recrea i ${remot ? 'l\'actual s\'atura' : 'el UPF del core s\'atura'}.`) }, 'Fes servir aquest UPF')));
    if (e.metriques) b.append(taulaMetriquesUpf(e.metriques));
    lc.append(b);
  }
  llista.replaceChildren(lc);
}
$('#upf-refresca').addEventListener('click', carregaUpf);
$('#upf-desti').addEventListener('change', carregaUpf);

inici();
