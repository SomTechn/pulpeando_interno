/* Instalar la app en el aparato.

   Va como script clásico en el <head>, antes que todo: Chrome dispara
   «beforeinstallprompt» una sola vez y temprano, y si nadie lo está
   escuchando se pierde. Aquí se guarda y luego cualquier pantalla monta su
   botón con PulpeandoInstalar.montar(contenedor).

   Tres casos:
   - directo: Chrome / Edge / Samsung ofrecen instalar; el botón abre su
     cuadro de instalación.
   - ios: Safari no tiene ese cuadro; se dice cómo hacerlo con «Compartir».
   - manual: otros navegadores, o Chrome cuando ya está instalada en otra
     pestaña; se dice dónde está la opción en el menú del navegador.
   Ya abierta como app (pantalla completa) no se enseña nada.

   El mismo archivo vive en pulpeando_interno y en pulpeando_clientes. */
(function () {
  'use strict';
  if (window.PulpeandoInstalar) return;

  const est = { evento: null, instalada: comoApp(), oyentes: [] };
  const ua = navigator.userAgent || '';
  const ios = /iphone|ipad|ipod/i.test(ua) ||
              (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);

  function comoApp() {
    try {
      return window.matchMedia('(display-mode: standalone)').matches ||
             window.matchMedia('(display-mode: fullscreen)').matches ||
             window.navigator.standalone === true;
    } catch (e) { return false; }
  }
  function avisar() { est.oyentes.forEach(fn => { try { fn(modo()); } catch (e) {} }); }

  window.addEventListener('beforeinstallprompt', e => {
    e.preventDefault();          // el botón propio la ofrece cuando toca
    est.evento = e;
    avisar();
  });
  window.addEventListener('appinstalled', () => {
    est.evento = null; est.instalada = true; avisar();
  });

  function modo() {
    if (est.instalada || comoApp()) return 'instalada';
    if (est.evento) return 'directo';
    return ios ? 'ios' : 'manual';
  }

  async function instalar() {
    const e = est.evento;
    if (!e) return modo();
    est.evento = null;
    e.prompt();
    let r = null;
    try { r = await e.userChoice; } catch (x) {}
    if (r && r.outcome === 'accepted') est.instalada = true;
    avisar();
    return r ? r.outcome : 'dismissed';
  }

  function pasos(m) {
    m = m || modo();
    if (m === 'ios') return 'En Safari toque Compartir (el cuadro con la flecha hacia arriba) y luego «Agregar a inicio».';
    if (m === 'manual') return 'Abra el menú del navegador (⋮ arriba a la derecha) y toque «Instalar app» o «Agregar a la pantalla principal». Si ya la instaló, ábrala desde su pantalla de inicio.';
    return '';
  }

  /* El botón. tema: 'claro' (fondo blanco) u 'oscuro' (sobre fondo oscuro).
     texto: lo que dice el botón. */
  let estilo = false;
  function ponerEstilo() {
    if (estilo) return; estilo = true;
    const s = document.createElement('style');
    s.textContent = `
.pi-zona{display:flex;flex-direction:column;gap:8px}
.pi-zona.oculto,.pi-ayuda.oculto{display:none}
.pi-btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;min-height:44px;
  padding:0 16px;border-radius:999px;font:inherit;font-size:14px;font-weight:800;cursor:pointer;
  border:1px solid currentColor;background:transparent;color:inherit}
.pi-btn svg{flex:0 0 auto}
.pi-zona.claro .pi-btn{color:var(--marca,#12427A);border-color:rgba(18,66,122,.35);background:#fff}
.pi-zona.oscuro .pi-btn{color:#fff;border-color:rgba(255,255,255,.35)}
.pi-ayuda{font-size:13px;line-height:1.45;opacity:.9}
.pi-zona.claro .pi-ayuda{color:var(--tenue,#5B6577)}`;
    document.head.appendChild(s);
  }
  const ICONO = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M5 21h14"/></svg>';

  function montar(el, opciones) {
    if (!el) return null;
    const o = Object.assign({ tema: 'claro', texto: 'Instalar la app' }, opciones || {});
    ponerEstilo();
    el.classList.add('pi-zona', o.tema);
    el.innerHTML = `<button type="button" class="pi-btn">${ICONO}<span></span></button>
      <div class="pi-ayuda oculto" role="note"></div>`;
    el.querySelector('.pi-btn span').textContent = o.texto;
    const ayuda = el.querySelector('.pi-ayuda');
    const pintar = () => {
      const m = modo();
      el.classList.toggle('oculto', m === 'instalada');
      if (m === 'directo') ayuda.classList.add('oculto');
    };
    el.querySelector('.pi-btn').addEventListener('click', async () => {
      const m = modo();
      if (m === 'directo') { await instalar(); pintar(); return; }
      ayuda.textContent = pasos(m);
      ayuda.classList.toggle('oculto');
    });
    est.oyentes.push(pintar);
    pintar();
    return { pintar };
  }

  window.PulpeandoInstalar = {
    modo, instalar, pasos, montar,
    alCambiar(fn) { est.oyentes.push(fn); }
  };
})();
