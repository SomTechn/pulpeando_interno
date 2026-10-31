/* ==========================================================================
   Selector de varios.

   Somar pidió que en todo filtro se pueda escoger más de una opción. Un
   <select multiple> del navegador es incómodo (Ctrl+clic en la PC, una
   rueda rara en el teléfono), así que este lo cambia por un botón que abre
   una lista con casillas, debajo, en la misma pantalla.

   El <select> de verdad se queda escondido y al día: sus opciones marcadas
   son lo escogido y dispara 'change' como siempre. Así el código de cada
   pantalla lo sigue leyendo igual, con valores(select).

   Uso:
     import { montarMulti, valores } from './multi.js';
     montarMulti(document.querySelector('#f-caja'), { todos:'Todas las cajas' });
     select.addEventListener('change', () => valores(select));   // ['id1','id2']

   Nada escogido = todas. Si se cambian las opciones del select (se llenan
   después de leer la base), el botón se rehace solo.
   ========================================================================== */

const esc = s => String(s ?? '').replace(/[&<>"']/g, c =>
  ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));

/* Lo escogido, como lista. Sirve también con un <select> normal. */
export function valores(sel){
  if (!sel) return [];
  return [...sel.options].filter(o => o.selected && o.value !== '').map(o => o.value);
}

/* Escoger desde el código (por ejemplo, al limpiar los filtros). */
export function fijar(sel, lista = []){
  const quiero = new Set(lista.map(String));
  [...sel.options].forEach(o => { o.selected = quiero.has(o.value); });
  sel._multi?.pintar();
}

let abierto = null;
function cerrarAbierto(){
  if (!abierto) return;
  abierto.panel.hidden = true;
  abierto.boton.setAttribute('aria-expanded', 'false');
  abierto.raiz.classList.remove('abierto');
  abierto = null;
}

export function montarMulti(sel, { todos = 'Todos', unidad = 'escogidas', buscar } = {}){
  if (!sel) return null;
  // Ya montado: solo se le cambian los textos (por ejemplo al pasar de
  // «categorías» a «marcas» en el mismo selector)
  if (sel._multi){
    sel._multi.cfg.todos = todos; sel._multi.cfg.unidad = unidad;
    sel._multi.pintar();
    return sel._multi;
  }
  const cfg = { todos, unidad };
  const doc = sel.ownerDocument;
  sel.multiple = true;
  // La opción vacía ("Todas…") la pone el botón: en la lista sobra
  [...sel.options].forEach(o => { if (o.value === '') o.remove(); });

  const raiz = doc.createElement('div');
  raiz.className = 'multi';
  raiz.innerHTML = `<button type="button" class="multi-btn" aria-haspopup="listbox" aria-expanded="false">
      <span class="multi-txt"></span><span class="multi-cuenta" hidden></span>
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4"
           stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m6 9 6 6 6-6"/></svg>
    </button>
    <div class="multi-panel" role="listbox" aria-multiselectable="true" hidden></div>`;
  sel.insertAdjacentElement('afterend', raiz);
  sel.classList.add('multi-nativo');
  sel.setAttribute('aria-hidden', 'true');
  sel.tabIndex = -1;
  if (sel.id){
    raiz.dataset.para = sel.id;
    // un <label for> que apuntaba al select ahora abre el botón
    doc.querySelectorAll(`label[for="${sel.id}"]`).forEach(l => l.addEventListener('click', e => {
      e.preventDefault(); boton.focus(); }));
  }
  const boton = raiz.querySelector('.multi-btn');
  const panel = raiz.querySelector('.multi-panel');
  const etiqueta = sel.getAttribute('aria-label');
  if (etiqueta) boton.setAttribute('aria-label', etiqueta);

  function pintar(){
    const elegidas = [...sel.options].filter(o => o.selected);
    const txt = raiz.querySelector('.multi-txt');
    const cuenta = raiz.querySelector('.multi-cuenta');
    if (!elegidas.length){ txt.textContent = cfg.todos; cuenta.hidden = true; }
    else if (elegidas.length === 1){ txt.textContent = elegidas[0].textContent.trim(); cuenta.hidden = true; }
    else {
      txt.textContent = elegidas[0].textContent.trim();
      cuenta.textContent = '+' + (elegidas.length - 1);
      cuenta.hidden = false;
      boton.title = elegidas.map(o => o.textContent.trim()).join(', ');
    }
    raiz.classList.toggle('con-valor', elegidas.length > 0);
    // las casillas, si el panel está abierto
    panel.querySelectorAll('[data-v]').forEach(c => {
      const o = [...sel.options].find(x => x.value === c.dataset.v);
      c.querySelector('input').checked = !!o?.selected;
    });
    const t = panel.querySelector('[data-todos] input');
    if (t) t.checked = !elegidas.length;
  }

  function armarPanel(){
    const ops = [...sel.options];
    const conBuscar = buscar ?? ops.length > 8;
    panel.innerHTML = `
      ${conBuscar ? '<input class="multi-buscar" type="search" placeholder="Buscar…" autocomplete="off">' : ''}
      <label class="multi-op multi-todos" data-todos><input type="checkbox"><span>${esc(cfg.todos)}</span></label>
      <div class="multi-lista">${ops.map(o => `
        <label class="multi-op" data-v="${esc(o.value)}"><input type="checkbox">
          <span>${esc(o.textContent.trim())}</span></label>`).join('')}</div>
      <div class="multi-pie"><span class="multi-n"></span><button type="button" class="multi-listo">Listo</button></div>`;
    pintar();
    contar();
  }
  function contar(){
    const n = valores(sel).length;
    const z = panel.querySelector('.multi-n');
    if (z) z.textContent = n ? `${n} ${n === 1 ? cfg.unidad.replace(/e?s$/, '') : cfg.unidad}` : '';
  }
  const avisar = () => { pintar(); contar(); sel.dispatchEvent(new doc.defaultView.Event('change', { bubbles:true })); };

  panel.addEventListener('change', e => {
    const lab = e.target.closest('label'); if (!lab) return;
    if (lab.hasAttribute('data-todos')){
      [...sel.options].forEach(o => { o.selected = false; });
    } else {
      const o = [...sel.options].find(x => x.value === lab.dataset.v);
      if (o) o.selected = e.target.checked;
    }
    avisar();
  });
  panel.addEventListener('input', e => {
    if (!e.target.classList.contains('multi-buscar')) return;
    const q = e.target.value.trim().toLowerCase();
    panel.querySelectorAll('.multi-lista .multi-op').forEach(l =>
      l.hidden = !!q && !l.textContent.toLowerCase().includes(q));
  });
  panel.addEventListener('click', e => { if (e.target.closest('.multi-listo')) { cerrarAbierto(); boton.focus(); } });

  boton.addEventListener('click', () => {
    if (abierto?.raiz === raiz){ cerrarAbierto(); return; }
    cerrarAbierto();
    armarPanel();
    panel.hidden = false;
    raiz.classList.add('abierto');
    boton.setAttribute('aria-expanded', 'true');
    abierto = { raiz, panel, boton };
    // Que no se salga por la derecha en una pantalla angosta
    const r = raiz.getBoundingClientRect?.();
    const ancho = doc.documentElement.clientWidth || 0;
    panel.classList.toggle('a-la-derecha', !!(r && ancho && r.left + 280 > ancho));
    panel.querySelector('.multi-buscar')?.focus();
  });

  // Las opciones se llenan después (de la base): el botón se rehace
  new doc.defaultView.MutationObserver(() => {
    [...sel.options].forEach(o => { if (o.value === '') o.remove(); });
    if (abierto?.raiz === raiz) armarPanel(); else pintar();
  }).observe(sel, { childList:true });
  sel.addEventListener('change', e => { if (e.isTrusted) pintar(); });

  if (!doc._multiCierre){
    doc._multiCierre = true;
    doc.addEventListener('click', e => { if (abierto && !abierto.raiz.contains(e.target)) cerrarAbierto(); }, true);
    doc.addEventListener('keydown', e => { if (e.key === 'Escape' && abierto){ e.stopPropagation(); cerrarAbierto(); } }, true);
  }

  sel._multi = { raiz, boton, panel, pintar, cfg };
  pintar();
  return sel._multi;
}
