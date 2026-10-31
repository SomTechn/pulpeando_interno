/* ==========================================================================
   Vistas en lugar de ventanas flotantes.

   Somar no quiere nada que se vea como modal: un formulario o un detalle se
   abre como una pantalla propia, con «← Volver» arriba, ocupando el espacio
   de la pantalla (el menú de la izquierda se queda donde está).

   En vez de reescribir las 15 pantallas, esto toma las dos piezas que todas
   usan y les cambia la forma:

     .velo  > .hoja      (formularios, confirmaciones, resultados)
     .form-velo > .cajon (el panel lateral de Catálogos, Ventas y Fiado)

   Las mete dentro de .principal y las pinta a pantalla completa. Su código
   sigue igual: se abren y se cierran quitando y poniendo la clase "oculto",
   como siempre.

   LOS MENSAJES CORTOS NO SON PANTALLAS
   Un «Guardado · Entendido» a pantalla completa estorba. Si lo que se abre no
   tiene campos y trae un solo botón, se enseña como un aviso abajo que se va
   solo. Cuando se va, se aprieta su botón por debajo, para que el código que
   esperaba ese «Entendido» siga su camino.

   ATRÁS
   El botón «atrás» del teléfono (y Esc en la PC) cierra la vista en vez de
   salirse de la pantalla.

   Lo importa menu.js, así que llega solo a toda pantalla que tenga menú.
   En las pruebas de jsdom no se activa (las pruebas miran el #hoja tal cual).
   ========================================================================== */

const CANCELAR = /^(←\s*)?(cancelar|cerrar|volver|no|salir|regresar)$/i;
const ENTERADO = /^(entendido|aceptar|listo|ok|cerrar|de acuerdo|continuar)$/i;

let avisoActual = null;
let cerrandoDesdeVolver = false;

function visible(el){ return el && !el.classList.contains('oculto'); }
function textoDe(el){ return (el?.textContent || '').replace(/\s+/g, ' ').trim(); }

/* ¿Es un mensaje corto? Sin campos, sin listas, un solo botón, poco texto. */
export function esMensaje(hoja){
  if (!hoja) return false;
  if (hoja.querySelector('input, select, textarea, table, canvas, video, iframe, .fila, .lista, .girando')) return false;
  const botones = hoja.querySelectorAll('button');
  if (botones.length !== 1) return false;
  return textoDe(hoja).length < 300;
}

function cerrarAviso(apretar){
  const a = avisoActual;
  if (!a) return;
  avisoActual = null;
  clearTimeout(a.reloj);
  a.el.classList.add('saliendo');
  setTimeout(() => a.el.remove(), 180);
  if (apretar && a.boton?.isConnected) a.boton.click();
}

function mostrarAviso(vista, hoja){
  const doc = vista.ownerDocument;
  const boton = hoja.querySelector('button');
  const etiqueta = textoDe(boton);
  const titulo = textoDe(hoja.querySelector('h2, h3, b'));
  let texto = textoDe(hoja);
  if (titulo && texto.startsWith(titulo)) texto = texto.slice(titulo.length).trim();
  if (etiqueta && texto.endsWith(etiqueta)) texto = texto.slice(0, -etiqueta.length).trim();
  const malo = /no se pudo|error|falta|sin conexi|no hay|no es|otra tienda|no encontr/i.test(titulo + ' ' + texto)
            || !!hoja.querySelector('.aviso.malo');
  const enterado = ENTERADO.test(etiqueta);

  cerrarAviso(false);
  vista.classList.add('oculto');

  const el = doc.createElement('div');
  el.className = 'aviso-flotante' + (malo ? ' malo' : '');
  el.setAttribute('role', 'status');
  el.innerHTML = `<div class="af-txt"></div>
    ${enterado ? '' : '<button type="button" class="af-accion"></button>'}
    <button type="button" class="af-x" aria-label="Cerrar">✕</button>`;
  const z = el.querySelector('.af-txt');
  if (titulo){ const b = doc.createElement('b'); b.textContent = titulo; z.appendChild(b); }
  if (texto){ const s = doc.createElement('span'); s.textContent = texto; z.appendChild(s); }
  if (!enterado) el.querySelector('.af-accion').textContent = etiqueta;
  doc.body.appendChild(el);

  const a = { el, boton, reloj:null };
  avisoActual = a;
  // El de "Entendido" se va solo; el que trae otra acción espera al usuario
  if (enterado){
    const ms = Math.min(9000, Math.max(3500, (titulo.length + texto.length) * 55));
    a.reloj = setTimeout(() => cerrarAviso(true), ms);
  }
  el.querySelector('.af-x').onclick = () => cerrarAviso(enterado);
  el.querySelector('.af-accion')?.addEventListener('click', () => cerrarAviso(true));
}

/* «← Volver»: lo mismo que el botón de cancelar de esa vista */
export function volver(vista){
  if (!vista || !visible(vista)) return;
  if (vista.classList.contains('form-velo')){
    const x = vista.querySelector('.cerrar-x, [id$="cerrar"], [id$="cancelar"]');
    if (x){ cerrandoDesdeVolver = true; try{ x.click(); } finally { cerrandoDesdeVolver = false; } }
    if (visible(vista)) vista.classList.add('oculto');
    return;
  }
  const hoja = vista.querySelector('.hoja');
  const cancelar = [...(hoja?.querySelectorAll('button') || [])].find(b => CANCELAR.test(textoDe(b)));
  if (cancelar) cancelar.click();
  if (visible(vista)) vista.classList.add('oculto');
}

/* Con el botón «Volver» se gasta también la entrada del historial que se
   agregó al abrir: así el «atrás» del teléfono no queda apretándose en vano. */
function volverConHistoria(vista){
  const win = vista.ownerDocument.defaultView;
  if (win.history.state?.vista) win.history.back();   // el popstate la cierra
  else volver(vista);
}

function vistaDeArriba(doc){
  const abiertas = [...doc.querySelectorAll('.vista')].filter(visible);
  // la .velo va encima de la .form-velo (un aviso sobre un formulario)
  return abiertas.find(v => v.classList.contains('velo')) || abiertas[0] || null;
}

export function activarVistas(doc = document){
  const principal = doc.querySelector('.principal');
  if (!principal || principal.dataset.vistas) return;
  // La caja tiene sus propias pantallas de cobro: no se toca
  if (/\/caja\//.test(doc.defaultView?.location?.pathname || '')) return;
  principal.dataset.vistas = '1';
  const win = doc.defaultView;

  const vistas = [...doc.querySelectorAll('.velo, .form-velo')];
  for (const v of vistas){
    principal.appendChild(v);
    v.classList.add('vista');

    if (v.classList.contains('velo')){
      const barra = doc.createElement('div');
      barra.className = 'vista-barra';
      barra.innerHTML = '<button type="button" class="vista-volver">← Volver</button>';
      v.insertBefore(barra, v.firstChild);
      barra.querySelector('button').addEventListener('click', () => volverConHistoria(v));
    }

    // El ✕ del panel se ve como «← Volver»: que también gaste el historial
    const x = v.querySelector('.cerrar-x');
    if (x){
      x.setAttribute('aria-label', 'Volver');
      x.addEventListener('click', ev => {
        if (cerrandoDesdeVolver || !win.history.state?.vista) return;
        ev.stopImmediatePropagation(); ev.preventDefault();
        win.history.back();
      }, true);
    }

    let estaba = visible(v);
    const revisar = () => {
      const ahora = visible(v);
      if (ahora && v.classList.contains('velo') && esMensaje(v.querySelector('.hoja'))){
        mostrarAviso(v, v.querySelector('.hoja'));
        estaba = false;
        return;
      }
      if (ahora && !estaba){
        v.scrollTop = 0;
        if (!win.history.state?.vista){
          try{ win.history.pushState({ vista:true }, ''); }catch(e){}
        }
      }
      estaba = ahora;
    };
    new win.MutationObserver(revisar).observe(v, { attributes:true, attributeFilter:['class'] });
    const hoja = v.querySelector('.hoja');
    if (hoja) new win.MutationObserver(() => { if (visible(v)) revisar(); })
      .observe(hoja, { childList:true });
  }

  win.addEventListener('popstate', () => {
    const v = vistaDeArriba(doc);
    if (v) volver(v);
  });
  doc.addEventListener('keydown', e => {
    if (e.key !== 'Escape') return;
    if (avisoActual){ cerrarAviso(true); return; }
    const v = vistaDeArriba(doc);
    if (v){ e.preventDefault(); volver(v); }
  });
}

/* Solo en el navegador de verdad. En jsdom se activa a mano con
   window.__conVistas = true antes de importar. */
if (typeof window !== 'undefined' && typeof document !== 'undefined'){
  const enJsdom = /jsdom/i.test(window.navigator?.userAgent || '');
  if (!enJsdom || window.__conVistas){
    if (document.readyState === 'loading')
      document.addEventListener('DOMContentLoaded', () => activarVistas(document));
    else activarVistas(document);
  }
}
