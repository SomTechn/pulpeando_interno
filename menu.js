/* ==========================================================================
   Menú lateral compartido.

   Se comporta distinto según el aparato, pero es el mismo código:
     · Escritorio ancho  → desplegado, se puede plegar a solo iconos
     · Tablet            → arranca en iconos, se despliega por encima
     · Celular           → cajón que entra desde la izquierda

   Uso:
     import { montarMenu } from './menu.js';
     const menu = montarMenu({
       contenedor: '#menu',
       modulo: 'caja',
       ctx,
       alSalir: () => sb.auth.signOut(),
       secciones: [{ titulo:'Categorías', items:[...] }]
     });
     menu.actualizarSeccion('categorias', items);
   ========================================================================== */

const ICONOS = {
  caja:      '<path d="M3 10h18M7 15h4M3 7a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  compras:   '<path d="M3 4h2l2.4 11.2a2 2 0 0 0 2 1.6h7.7a2 2 0 0 0 2-1.5L21 8H6"/><circle cx="10" cy="20" r="1.2"/><circle cx="18" cy="20" r="1.2"/>',
  pedidos:   '<path d="M9 3h6a1 1 0 0 1 1 1v2H8V4a1 1 0 0 1 1-1z"/><path d="M8 6H6a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-2"/><path d="M9 12h6M9 16h4"/>',
  inventario:'<path d="M3 7l9-4 9 4v10l-9 4-9-4z"/><path d="M3 7l9 4 9-4M12 21V11"/>',
  reportes:  '<path d="M4 20V10M10 20V4M16 20v-7M22 20H2"/>',
  ajustes:   '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-1.8-.3 1.6 1.6 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1A1.6 1.6 0 0 0 9 19.4a1.6 1.6 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0 .3-1.8 1.6 1.6 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1A1.6 1.6 0 0 0 4.6 9a1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 1.8.3H9a1.6 1.6 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 1 1.5 1.6 1.6 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8V9a1.6 1.6 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1z"/>',
  etiqueta:  '<path d="M20.6 13.4 12 22l-9-9V4a1 1 0 0 1 1-1h9z"/><circle cx="7.5" cy="7.5" r="1.3"/>',
  todos:     '<path d="M4 6h16M4 12h16M4 18h16"/>',
  salir:     '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/>'
};

const svg = d => `<svg viewBox="0 0 24 24" width="19" height="19" fill="none"
  stroke="currentColor" stroke-width="1.9" stroke-linecap="round"
  stroke-linejoin="round">${d}</svg>`;

/* Los módulos del sistema y desde qué rol se ven.
   nivel: 0 repartidor · 1 auxiliar · 2 supervisor · 3 gerente · 4 admin */
const MODULOS = [
  { id:'caja',    nombre:'Caja',        url:'index.html',   icono:'caja',    nivel:1 },
  { id:'pedidos', nombre:'Pedidos',     url:'pedidos.html', icono:'pedidos', nivel:1 },
  { id:'compras', nombre:'Compras',     url:'compras.html', icono:'compras', nivel:2 }
];

/* Guardar preferencias sin reventar si el navegador las tiene bloqueadas */
const recordar = {
  leer(k, def){ try{ const v = localStorage.getItem(k); return v === null ? def : v; }catch(e){ return def; } },
  poner(k, v){ try{ localStorage.setItem(k, v); }catch(e){} }
};

export function montarMenu({ contenedor, modulo, ctx, alSalir, secciones = [] }){
  const raiz = typeof contenedor === 'string' ? document.querySelector(contenedor) : contenedor;
  const nivel = ctx?.usuario?.nivel ?? 0;

  // Un solo velo, aunque el menú se vuelva a montar
  let velo = document.querySelector('.menu-velo');
  if (!velo){
    velo = document.createElement('div');
    velo.className = 'menu-velo';
    document.body.appendChild(velo);
  }
  velo.classList.remove('visible');

  raiz.className = 'menu';
  raiz.innerHTML = `
    <div class="menu-arriba">
      <i class="menu-marca">◧</i>
      <div class="menu-nombre">
        <b>${escapar(ctx?.organizacion?.nombre || 'Pulpeando')}</b>
        <small>${escapar(ctx?.sucursales?.[0]?.nombre || '')}</small>
      </div>
      <button class="menu-plegar" data-m="plegar" aria-label="Plegar menú">
        ${svg('<path d="M15 18l-6-6 6-6"/>')}
      </button>
    </div>

    <div class="menu-cuerpo">
      <div class="menu-titulo">Operación</div>
      <div id="menu-modulos"></div>
      <div id="menu-secciones"></div>
    </div>

    <div class="menu-abajo">
      <button class="menu-usuario" data-m="salir">
        <span class="menu-avatar">${iniciales(ctx?.usuario?.nombre)}</span>
        <span class="menu-quien">
          <b>${escapar(ctx?.usuario?.nombre || '')}</b>
          <small>${escapar(ctx?.usuario?.rol || '')}</small>
        </span>
        <span class="menu-icono">${svg(ICONOS.salir)}</span>
      </button>
    </div>`;

  // ---- módulos ----
  raiz.querySelector('#menu-modulos').innerHTML = MODULOS
    .filter(m => nivel >= m.nivel)
    .map(m => `
      <a class="menu-item ${m.id === modulo ? 'activo' : ''}" href="${m.url}"
         data-nombre="${m.nombre}">
        <span class="menu-icono">${svg(ICONOS[m.icono])}</span>
        <span class="menu-texto">${m.nombre}</span>
      </a>`).join('');

  // ---- secciones propias de la pantalla ----
  const zona = raiz.querySelector('#menu-secciones');

  function pintarSecciones(lista){
    zona.innerHTML = lista.map(s => `
      <div data-seccion="${s.id || ''}">
        <div class="menu-titulo">${escapar(s.titulo)}</div>
        ${s.items.map(it => `
          <button class="menu-item ${it.activo ? 'activo' : ''}"
                  data-valor="${escapar(it.valor)}" data-nombre="${escapar(it.nombre)}">
            <span class="menu-icono">${svg(ICONOS[it.icono] || ICONOS.etiqueta)}</span>
            <span class="menu-texto">${escapar(it.nombre)}</span>
            ${it.cuenta !== undefined ? `<span class="menu-cuenta">${it.cuenta}</span>` : ''}
          </button>`).join('')}
      </div>`).join('');
  }
  pintarSecciones(secciones);

  // ---- plegar / abrir ----
  const esCelular = () => window.matchMedia('(max-width:820px)').matches;
  const esTablet  = () => window.matchMedia('(max-width:1180px)').matches;

  if (!esTablet() && recordar.leer('menu-plegado', '0') === '1')
    raiz.classList.add('angosto');

  function alternar(){
    if (esCelular()){
      const abierto = raiz.classList.toggle('abierto');
      velo.classList.toggle('visible', abierto);
    } else if (esTablet()){
      raiz.classList.toggle('ancho');
      velo.classList.toggle('visible', raiz.classList.contains('ancho'));
    } else {
      const plegado = raiz.classList.toggle('angosto');
      recordar.poner('menu-plegado', plegado ? '1' : '0');
    }
  }

  function cerrarEnMovil(){
    raiz.classList.remove('abierto', 'ancho');
    velo.classList.remove('visible');
  }

  velo.addEventListener('click', cerrarEnMovil);
  document.addEventListener('keydown', e => { if (e.key === 'Escape') cerrarEnMovil(); });
  window.addEventListener('resize', () => {
    if (!esCelular() && !esTablet()) cerrarEnMovil();
  });

  const manejadores = { alElegir: null };

  raiz.addEventListener('click', e => {
    const b = e.target.closest('[data-m]');
    if (b){
      if (b.dataset.m === 'plegar') alternar();
      if (b.dataset.m === 'salir')  alSalir?.();
      return;
    }
    const item = e.target.closest('[data-valor]');
    if (item){
      raiz.querySelectorAll('[data-valor]').forEach(x =>
        x.classList.toggle('activo', x === item));
      manejadores.alElegir?.(item.dataset.valor);
      if (esCelular() || esTablet()) cerrarEnMovil();
      return;
    }
    // navegar a otro módulo cierra el cajón
    if (e.target.closest('a.menu-item') && esCelular()) cerrarEnMovil();
  });

  return {
    alternar,
    cerrar: cerrarEnMovil,
    alElegir(fn){ manejadores.alElegir = fn; },
    actualizar(lista){ pintarSecciones(lista); },
    marcar(valor){
      raiz.querySelectorAll('[data-valor]').forEach(x =>
        x.classList.toggle('activo', x.dataset.valor === String(valor)));
    }
  };
}

export function iniciales(n){
  return (n || '··').trim().split(/\s+/).slice(0,2).map(x => x[0] || '').join('').toUpperCase();
}

export function escapar(s){
  return String(s ?? '').replace(/[&<>"']/g, c =>
    ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
