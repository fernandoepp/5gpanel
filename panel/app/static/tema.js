// S'executa abans de pintar la pàgina: aplica el tema desat (clar/fosc) sense parpelleig.
(function () {
  var t = null;
  try { t = localStorage.getItem('panel5g-tema'); } catch (e) { /* navegador sense emmagatzematge */ }
  if (t === 'clar' || t === 'fosc') document.documentElement.setAttribute('data-theme', t === 'fosc' ? 'dark' : 'light');
})();
