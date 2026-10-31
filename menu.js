/* ==========================================================================
   Menú lateral compartido.

   Ordenado por áreas del negocio (Venta, Inventario, Compras, Finanzas,
   Administración). Lo que cada pantalla tiene adentro —las listas de
   Catálogos, las vistas de Compras, las secciones de Finanzas— se despliega
   JUSTO DEBAJO de su opción, no al final del menú, y se puede plegar con la
   flecha.

   Se comporta distinto según el aparato, pero es el mismo código:
     · Escritorio ancho  → desplegado, se puede plegar a solo iconos
     · Tablet            → arranca en iconos, se despliega por encima
     · Celular           → cajón que entra desde la izquierda

   El menú también pinta la marca: el logo del negocio (o sus iniciales) y
   su color, que llega en ctx.organizacion.color.

   Uso:
     import { montarMenu } from './menu.js';
     const menu = montarMenu({
       contenedor: '#menu',
       modulo: 'catalogo',
       ctx,
       alSalir: () => sb.auth.signOut(),
       secciones: [{ titulo:'Catálogos', items:[{ valor, nombre, icono, cuenta, activo }] }]
     });
     menu.alElegir(valor => ...);
   ========================================================================== */

const ICONOS = {
  caja:      '<path d="M3 10h18M7 15h4M3 7a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  compras:   '<path d="M3 4h2l2.4 11.2a2 2 0 0 0 2 1.6h7.7a2 2 0 0 0 2-1.5L21 8H6"/><circle cx="10" cy="20" r="1.2"/><circle cx="18" cy="20" r="1.2"/>',
  pedidos:   '<path d="M9 3h6a1 1 0 0 1 1 1v2H8V4a1 1 0 0 1 1-1z"/><path d="M8 6H6a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-2"/><path d="M9 12h6M9 16h4"/>',
  inventario:'<path d="M3 7l9-4 9 4v10l-9 4-9-4z"/><path d="M3 7l9 4 9-4M12 21V11"/>',
  reportes:  '<path d="M4 20V10M10 20V4M16 20v-7M22 20H2"/>',
  tablero:   '<rect x="3" y="3" width="7" height="9" rx="1.5"/><rect x="14" y="3" width="7" height="5" rx="1.5"/><rect x="14" y="12" width="7" height="9" rx="1.5"/><rect x="3" y="16" width="7" height="5" rx="1.5"/>',
  finanzas:  '<path d="M3 7a2 2 0 0 1 2-2h13a1 1 0 0 1 1 1v2"/><path d="M3 7v11a2 2 0 0 0 2 2h14a1 1 0 0 0 1-1v-3"/><path d="M21 12h-4a2 2 0 0 0 0 4h4a1 1 0 0 0 1-1v-2a1 1 0 0 0-1-1z"/>',
  ajustes:   '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-1.8-.3 1.6 1.6 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1A1.6 1.6 0 0 0 9 19.4a1.6 1.6 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0 .3-1.8 1.6 1.6 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1A1.6 1.6 0 0 0 4.6 9a1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 1.8.3H9a1.6 1.6 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 1 1.5 1.6 1.6 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8V9a1.6 1.6 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1z"/>',
  etiqueta:  '<path d="M20.6 13.4 12 22l-9-9V4a1 1 0 0 1 1-1h9z"/><circle cx="7.5" cy="7.5" r="1.3"/>',
  fiado:     '<path d="M4 5h16a1 1 0 0 1 1 1v3H3V6a1 1 0 0 1 1-1z"/><path d="M3 9v9a1 1 0 0 0 1 1h16a1 1 0 0 0 1-1V9"/><path d="M7 14h5"/>',
  lupa:      '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
  auditar:   '<path d="M3 6h10M3 12h7M3 18h7"/><circle cx="17" cy="15" r="4"/><path d="m20.5 18.5 2 2"/>',
  merma:     '<path d="M3 6h18l-1.5 13a2 2 0 0 1-2 1.8H6.5a2 2 0 0 1-2-1.8z"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/><path d="m10 11 4 5M14 11l-4 5"/>',
  calendario:'<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/><path d="m9 15 2 2 4-4"/>',
  conteo:    '<rect x="5" y="3" width="14" height="18" rx="2"/><path d="M9 8h6M9 12h6M9 16h3"/>',
  inicio:    '<path d="M3 11l9-7 9 7"/><path d="M5 10v10h14V10"/><path d="M10 20v-6h4v6"/>',
  todos:     '<path d="M4 6h16M4 12h16M4 18h16"/>',
  salir:     '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/>',
  flecha:    '<path d="m9 6 6 6-6 6"/>',
  plegar:    '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16"/>'
};

const svg = (d, t = 19) => `<svg viewBox="0 0 24 24" width="${t}" height="${t}" fill="none"
  stroke="currentColor" stroke-width="1.9" stroke-linecap="round"
  stroke-linejoin="round" aria-hidden="true">${d}</svg>`;

/* Los módulos del sistema, por área, y desde qué rol se ven.
   nivel: 0 repartidor · 1 auxiliar · 2 supervisor · 3 gerente · 4 admin */
const GRUPOS = [
  { titulo:null, modulos:[
    { id:'panel',   nombre:'Inicio',      url:'index.html',   icono:'inicio',   nivel:1 },
    { id:'tablero', nombre:'Tablero',     url:'tablero.html', icono:'tablero',  nivel:3 } ] },
  { titulo:'Venta', modulos:[
    { id:'caja',    nombre:'Caja',        url:'caja/',        icono:'caja',     nivel:1 },
    { id:'ventas',  nombre:'Ventas',      url:'ventas.html',  icono:'reportes', nivel:1 },
    { id:'pedidos', nombre:'Pedidos',     url:'pedidos.html', icono:'pedidos',  nivel:1 },
    { id:'fiado',   nombre:'Fiado',       url:'fiado.html',   icono:'fiado',    nivel:1 } ] },
  { titulo:'Inventario', modulos:[
    { id:'consultar', nombre:'Consultar', url:'consultar.html', icono:'lupa',   nivel:1 },
    { id:'catalogo', nombre:'Catálogos',  url:'catalogo.html', icono:'inventario', nivel:1 },
    { id:'conteo',  nombre:'Conteo',      url:'conteo.html',  icono:'conteo',   nivel:1 },
    { id:'auditoria', nombre:'Auditoría', url:'auditoria.html', icono:'auditar', nivel:1 },
    { id:'merma',   nombre:'Merma',       url:'merma.html',   icono:'merma',    nivel:1 },
    { id:'movimientos', nombre:'Movimientos', url:'movimientos.html', icono:'calendario', nivel:2 } ] },
  { titulo:'Compras', modulos:[
    { id:'compras', nombre:'Compras',     url:'compras.html', icono:'compras',  nivel:2 } ] },
  { titulo:'Finanzas', modulos:[
    { id:'finanzas', nombre:'Finanzas',   url:'finanzas.html', icono:'finanzas', nivel:2 } ] },
  { titulo:'Administración', modulos:[
    { id:'configuracion', nombre:'Configuración', url:'configuracion.html', icono:'ajustes', nivel:3 } ] }
];
export const MODULOS = GRUPOS.flatMap(g => g.modulos);

/* Guardar preferencias sin reventar si el navegador las tiene bloqueadas */
const recordar = {
  leer(k, def){ try{ const v = localStorage.getItem(k); return v === null ? def : v; }catch(e){ return def; } },
  poner(k, v){ try{ localStorage.setItem(k, v); }catch(e){} }
};

const ROLES = { repartidor:'Repartidor', auxiliar:'Auxiliar', supervisor:'Supervisor',
                gerente:'Gerente', admin:'Administrador' };

/* El logo del negocio, si lo subió. La dirección pública del bucket "marca". */
function urlLogo(ctx){
  const ruta = ctx?.organizacion?.logo_path;
  const base = (typeof window !== 'undefined' && window.SUPABASE_CONFIG?.url) || '';
  if (!ruta || !base || typeof ruta !== 'string') return null;
  return `${base}/storage/v1/object/public/marca/${ruta}`;
}

export function montarMenu({ contenedor, modulo, ctx, alSalir, secciones = [] }){
  const raiz = typeof contenedor === 'string' ? document.querySelector(contenedor) : contenedor;
  const nivel = ctx?.usuario?.nivel ?? 0;

  // El color del negocio, en cuanto se sabe cuál es.
  if (ctx?.organizacion && typeof window !== 'undefined')
    window.PulpeandoTema?.aplicar(ctx.organizacion.color || null);

  // Un solo velo, aunque el menú se vuelva a montar
  let velo = document.querySelector('.menu-velo');
  if (!velo){
    velo = document.createElement('div');
    velo.className = 'menu-velo';
    document.body.appendChild(velo);
  }
  velo.classList.remove('visible');

  const nombreNeg = ctx?.organizacion?.nombre || 'Pulpeando';
  const logo = urlLogo(ctx);

  raiz.className = 'menu';
  raiz.setAttribute('aria-label', 'Menú principal');
  raiz.innerHTML = `
    <div class="menu-arriba">
      <span class="menu-marca ${logo ? 'con-logo' : ''}">${logo
        ? `<img src="${escapar(logo)}" alt="">`
        : escapar(iniciales(nombreNeg))}</span>
      <div class="menu-nombre">
        <b title="${escapar(nombreNeg)}">${escapar(nombreNeg)}</b>
        <small>${escapar(ctx?.sucursales?.[0]?.nombre || '')}</small>
      </div>
      <button class="menu-plegar" data-m="plegar" aria-label="Plegar o desplegar el menú">
        ${svg(ICONOS.plegar, 18)}
      </button>
    </div>

    <nav class="menu-cuerpo" id="menu-modulos">
      ${GRUPOS.map(g => {
        const visibles = g.modulos.filter(m => nivel >= m.nivel);
        if (!visibles.length) return '';
        return `<div class="menu-grupo">
          ${g.titulo ? `<div class="menu-titulo">${escapar(g.titulo)}</div>` : ''}
          ${visibles.map(m => `
            <div class="menu-nodo ${m.id === modulo ? 'actual' : ''}" data-modulo="${m.id}">
              <a class="menu-item ${m.id === modulo ? 'activo' : ''}" href="${prefijo()}${m.url}"
                 data-nombre="${escapar(m.nombre)}" ${m.id === modulo ? 'aria-current="page"' : ''}>
                <span class="menu-icono">${svg(ICONOS[m.icono])}</span>
                <span class="menu-texto">${escapar(m.nombre)}</span>
              </a>
              ${m.id === modulo ? `<button class="menu-desplegar oculto" data-m="desplegar"
                 aria-label="Mostrar u ocultar las secciones de ${escapar(m.nombre)}"
                 aria-expanded="true" aria-controls="menu-secciones">${svg(ICONOS.flecha, 16)}</button>` : ''}
              ${m.id === modulo ? '<div class="menu-hijos" id="menu-secciones"></div>' : ''}
            </div>`).join('')}
        </div>`;
      }).join('')}
    </nav>

    <div class="menu-abajo">
      <button class="menu-usuario" data-m="salir" title="Cerrar sesión">
        <span class="menu-avatar">${iniciales(ctx?.usuario?.nombre)}</span>
        <span class="menu-quien">
          <b>${escapar(ctx?.usuario?.nombre || '')}</b>
          <small>${escapar(ROLES[ctx?.usuario?.rol] || ctx?.usuario?.rol || '')}</small>
        </span>
        <span class="menu-icono menu-salir">${svg(ICONOS.salir, 18)}</span>
      </button>
    </div>`;

  // Un logo que no carga no deja un cuadro roto: vuelve a las iniciales.
  const img = raiz.querySelector('.menu-marca img');
  if (img) img.addEventListener('error', () => {
    const m = raiz.querySelector('.menu-marca');
    m.classList.remove('con-logo'); m.textContent = iniciales(nombreNeg);
  });

  // ---- las secciones de la pantalla, debajo de su opción ----
  // Si la pantalla actual no está en el menú (o el rol no la ve), van al
  // final, en un grupo con su propio título: no se pierden.
  let zona = raiz.querySelector('#menu-secciones');
  if (!zona){
    zona = document.createElement('div');
    zona.className = 'menu-hijos sueltos';
    zona.id = 'menu-secciones';
    raiz.querySelector('.menu-cuerpo').appendChild(zona);
  }
  const nodoActual = raiz.querySelector('.menu-nodo.actual');
  const btnDesplegar = raiz.querySelector('[data-m="desplegar"]');
  const LLAVE_PLEGADO = 'menu-sub-plegado:' + modulo;

  function fijarDesplegado(abierto){
    if (!nodoActual) return;
    nodoActual.classList.toggle('plegado', !abierto);
    btnDesplegar?.setAttribute('aria-expanded', String(abierto));
    recordar.poner(LLAVE_PLEGADO, abierto ? '0' : '1');
  }

  function pintarSecciones(lista){
    const varias = lista.length > 1;
    const hay = lista.some(s => s.items?.length);
    zona.innerHTML = lista.map(s => `
      <div data-seccion="${escapar(s.id || '')}" role="group" aria-label="${escapar(s.titulo || '')}">
        ${(varias || zona.classList.contains('sueltos')) && s.titulo
          ? `<div class="menu-subtitulo">${escapar(s.titulo)}</div>` : ''}
        ${(s.items || []).map(it => `
          <button class="menu-item menu-sub ${it.activo ? 'activo' : ''}"
                  data-valor="${escapar(it.valor)}" data-nombre="${escapar(it.nombre)}"
                  ${it.activo ? 'aria-current="true"' : ''}>
            <span class="menu-icono">${svg(ICONOS[it.icono] || ICONOS.etiqueta, 17)}</span>
            <span class="menu-texto">${escapar(it.nombre)}</span>
            ${it.cuenta !== undefined && it.cuenta !== null
              ? `<span class="menu-cuenta">${escapar(it.cuenta)}</span>` : ''}
          </button>`).join('')}
      </div>`).join('');
    btnDesplegar?.classList.toggle('oculto', !hay);
    nodoActual?.classList.toggle('con-hijos', hay);
  }
  pintarSecciones(secciones);
  if (nodoActual) fijarDesplegado(recordar.leer(LLAVE_PLEGADO, '0') !== '1');
  // Que la opción en la que se está quede a la vista, aunque el menú sea
  // más largo que la pantalla (Finanzas y Configuración quedan abajo).
  const cuerpo = raiz.querySelector('.menu-cuerpo');
  const alaVista = () => {
    if (!nodoActual || !cuerpo) return;
    const arriba = nodoActual.offsetTop - cuerpo.offsetTop;
    const alto = Math.min(nodoActual.offsetHeight, cuerpo.clientHeight - 40);
    if (arriba + alto > cuerpo.scrollTop + cuerpo.clientHeight || arriba < cuerpo.scrollTop)
      cuerpo.scrollTop = Math.max(0, arriba + alto - cuerpo.clientHeight + 24);
  };
  (window.requestAnimationFrame || setTimeout)(alaVista);

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
      if (b.dataset.m === 'desplegar'){
        e.preventDefault(); e.stopPropagation();
        fijarDesplegado(nodoActual?.classList.contains('plegado'));
      }
      return;
    }
    // Tocar la opción de la pantalla en la que ya está: despliega o pliega
    // sus secciones en vez de recargar la página.
    const propio = e.target.closest('.menu-nodo.actual.con-hijos > .menu-item');
    if (propio && !raiz.classList.contains('angosto')){
      e.preventDefault();
      fijarDesplegado(nodoActual.classList.contains('plegado'));
      return;
    }
    const item = e.target.closest('[data-valor]');
    if (item){
      raiz.querySelectorAll('[data-valor]').forEach(x => {
        x.classList.toggle('activo', x === item);
        if (x === item) x.setAttribute('aria-current', 'true'); else x.removeAttribute('aria-current');
      });
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

/* La caja vive en /caja: sus enlaces al resto llevan "../". */
function prefijo(){
  try { return /\/caja\/?(index\.html)?$/.test(location.pathname) ? '../' : ''; }
  catch(e){ return ''; }
}

export function iniciales(n){
  return (n || '··').trim().split(/\s+/).slice(0,2).map(x => x[0] || '').join('').toUpperCase();
}

export function escapar(s){
  return String(s ?? '').replace(/[&<>"']/g, c =>
    ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
