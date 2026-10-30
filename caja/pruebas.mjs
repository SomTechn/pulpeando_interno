/* Prueba funcional de la caja, manejada como la manejaria una cajera de
   supermercado: sin soltar la pistola y sin tocar la pantalla.

   Lo que se vigila aqui:
     · que escanear agregue y que volver a escanear sume
     · que "3 *" ponga la cantidad de lo que se escanee despues
     · que la cantidad acepte decimales (producto por peso digitado a mano)
     · que por monto se diga el importe real, no el que se pidio
     · que suspender y retomar no pierda ni invente lineas
     · que el pago partido mande dos formas y el vuelto salga del efectivo
     · que nunca se pueda cobrar de menos
*/
import fs from 'node:fs';
import { JSDOM } from 'jsdom';

const BASE = '/home/claude/somtechn/pulpeando_interno/';
let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };

const CTX = {
  usuario:{ id:'u1', nombre:'Ana Maradiaga', rol:'auxiliar', nivel:1, tiene_pin:true },
  organizacion:{ id:'o1', nombre:'Pulpería Pulpeando', moneda:'HNL', factura_fiscal:false },
  sucursales:[{ id:'s1', nombre:'Central', codigo:'S01' }],
  cajas:[{ caja_id:'c1', caja:'Caja 1', turno_id:null, cajero_id:null, cajero:null,
           ventas_turno:0 }],
  impuesto_default:0, sin_sucursal:false
};

const CATALOGO = [
  { producto_id:'p1', sku:'ARR5LB', nombre:'Arroz de primera 5 lb', imagen_url:null,
    unidad_base:'UND', categoria_id:'ca1', categoria:'Abarrotes', precio:98,
    existencia:40, stock_bajo:false, vence_el:null, codigos:['7501001'],
    tasa_impuesto:0 },
  { producto_id:'p2', sku:'QUESO', nombre:'Queso fresco', imagen_url:null,
    unidad_base:'LB', categoria_id:'ca2', categoria:'Lácteos', precio:60,
    existencia:12, stock_bajo:false, vence_el:null, codigos:['7501002'],
    tasa_impuesto:0 },
  { producto_id:'p3', sku:'COCA', nombre:'Refresco 600 ml', imagen_url:null,
    unidad_base:'UND', categoria_id:'ca3', categoria:'Bebidas', precio:20,
    existencia:50, stock_bajo:false, vence_el:null, codigos:['7501003'],
    tasa_impuesto:0 }
];

async function montar(estado){
  const html = fs.readFileSync(BASE + 'caja/index.html', 'utf8');
  const cuerpo = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  const css = fs.readFileSync(BASE + 'ui.css', 'utf8');

  const dom = new JSDOM(
    html.replace(/<script type="module">[\s\S]*?<\/script>/, '')
        .replace('<link rel="stylesheet" href="ui.css">', '<style>' + css + '</style>')
        .replace(/<script src="config\.js"><\/script>/, ''),
    { runScripts:'outside-only', url:'https://x.test/caja/', pretendToBeVisual:true });

  const w = dom.window;
  w.SUPABASE_CONFIG = { url:'https://x.supabase.co', key:'k' };
  Object.defineProperty(w.navigator, 'serviceWorker',
    { value:{ register: async () => ({}) }, configurable:true });
  Object.defineProperty(w.navigator, 'onLine',
    { get: () => estado.enLinea, configurable:true });
  w.matchMedia = () => ({ matches:false, addEventListener(){}, removeEventListener(){} });

  globalThis.window = w; globalThis.document = w.document;
  globalThis.localStorage = w.localStorage; globalThis.matchMedia = w.matchMedia;
  // node 22 trae navigator de solo lectura: se redefine la propiedad.
  Object.defineProperty(globalThis, 'navigator',
    { value:w.navigator, configurable:true, writable:true });

  estado.llamadas = [];
  estado.encoladas = [];

  // La tablet pareada: su llave vive en el almacenamiento, antes de que el
  // guion corra, igual que en la vida real.
  if (estado.aparato) w.localStorage.setItem('pulpeando.aparato',
                                             JSON.stringify(estado.aparato));

  estado.pedidos = [];
  w.fetch = async (url, opc) => {
    estado.pedidos.push({ url, cuerpo:JSON.parse(opc.body) });
    if (estado.fetch === 'cae') throw new Error('sin red');
    return { json: async () => estado.fetch };
  };

  estado.sesiones = [];
  w.__sb = {
    auth:{ getSession: async () => ({ data:{ session:
             estado.sesion === undefined ? { user:{id:'u1'} } : estado.sesion } }),
           setSession: async t => { estado.sesiones.push(t);
                                    return { error:estado.setSessionFalla || null }; },
           signOut: async () => { estado.salio = true; },
           onAuthStateChange(){} },
    rpc: async (fn, args) => {
      estado.llamadas.push({ fn, args });
      const h = estado.rpc[fn];
      if (h === undefined) return { data:null, error:{ message:'sin simular: ' + fn } };
      return typeof h === 'function' ? h(args) : h;
    },
    from: t => {
      const datos = () => (estado.tablas && estado.tablas[t]) || estado.catalogo;
      const q = { select(){ return q; }, eq(){ return q; }, order(){ return q; }, limit(){ return q; },
                  then(r, j){ return Promise.resolve({ data:datos(), error:null }).then(r, j); } };
      return q;
    }
  };

  const menu = await import(BASE + 'menu.js');
  w.montarMenu = menu.montarMenu; w.escapar = menu.escapar; w.iniciales = menu.iniciales;

  const prep = cuerpo
    .replace(/^import \{ createClient \} from 'https:\/\/esm\.sh\/@supabase\/supabase-js@2';$/m, '')
    .replace(/^import \{ iniciales, escapar \} from '\.\.\/menu\.js';$/m, '')
    .replace(/^import \{ escanear, hayCamara \} from '\.\.\/escaner\.js';$/m,
             'const escanear = async () => null; const hayCamara = async () => false;')
    .replace(/^import \{ imprimirTicket \} from '\.\.\/ticket\.js';$/m,
             'const imprimirTicket = async (d, o) => { (window.__impresos = window.__impresos || []).push({ d, o }); };')
    .replace(/createClient\(SUPABASE_URL, SUPABASE_KEY, \{[\s\S]*?\}\)/, '__sb');

  w.__c = {};
  await w.eval(`(async () => { ${prep}
    ; const C = window.__c;
    ; C.S = S; C.agregar = agregar; C.fijarCant = fijarCant; C.quitarLinea = quitarLinea;
    ; C.pintar = pintar; C.totales = totales; C.suspender = suspender;
    ; C.hojaSuspendidas = hojaSuspendidas; C.hojaCantidad = hojaCantidad;
    ; C.retomar = retomar; C.guardadas = guardadas; C.mover = mover;
    ; C.abrirPOS = abrirPOS; C.resto = resto; C.cantTxt = cantTxt;
    ; C.DB = DB;
    ; C.abrirGaveta = abrirGaveta; C.hojaGaveta = hojaGaveta;
    ; C.entrarCaja = entrarCaja; C.pedirCredencial = pedirCredencial;
    ; C.aparato = aparato; C.bloquear = bloquear; C.abrirBuscador = abrirBuscador;
  })()`);
  await new Promise(r => setTimeout(r, 140));

  // Para probar la entrada se para aqui: sin sesion y sin turno, que es como
  // amanece la tablet.
  if (estado.entrada) return { w, d:w.document, C:w.__c, estado };

  // La caja real arranca con PIN y turno; aqui se entra directo al mostrador.
  const C = w.__c;
  C.S.ctx = CTX; C.S.cajero = CTX.usuario; C.S.moneda = 'L';
  C.S.sucursal = 's1'; C.S.caja = 'c1'; C.S.turno = 't1';
  C.S.desbloqueo = 'ok'; C.S.catalogo = estado.catalogo;
  C.S.enLinea = estado.enLinea;
  // IndexedDB no existe en jsdom: la cola se finge en memoria.
  C.DB.encolar = async v => { estado.encoladas.push(v); };
  C.DB.pendientes = async () => [];
  C.DB.guardarCatalogo = async () => {};
  C.DB.leerCatalogo = async () => null;
  C.abrirPOS();
  /* En la app, al abrir el turno se esconde "Elija su caja". Aquí se entra
     directo, así que hay que esconderla a mano: si queda encima, la caja
     (con razón) no escucha el teclado. */
  w.document.querySelectorAll('.oscura').forEach(o => o.classList.add('oculto'));
  await new Promise(r => setTimeout(r, 60));

  return { w, d:w.document, C, estado };
}

const esperar = (ms = 60) => new Promise(r => setTimeout(r, ms));

/* Contar la gaveta como lo hace una persona: cuántos de cada billete. */
function contar(w, d, cuantos){
  for (const [den, n] of Object.entries(cuantos)){
    const i = d.querySelector(`.den-c[data-d="${den}"]`);
    if (!i) throw new Error('no hay casilla para ' + den);
    i.value = String(n);
    i.dispatchEvent(new w.Event('input', { bubbles:true }));
  }
}

const base = (extra = {}) => ({
  enLinea:true,
  catalogo:JSON.parse(JSON.stringify(CATALOGO)),
  rpc:{
    fn_pos_contexto:{ data:CTX, error:null },
    /* Como el servidor de verdad: el total es la suma de los montos y el
       vuelto es lo recibido menos el total. Tenerlo quemado en un numero
       hacia pasar pruebas que median otra venta. */
    fn_registrar_venta: a => {
      const pagos = a.p_pagos || [];
      const total = pagos.reduce((s,p) => s + Number(p.monto), 0);
      const recibido = pagos.reduce((s,p) => s + Number(p.recibido ?? p.monto), 0);
      return { data:{ venta_id:'v-123', documento:'ticket', numero:'T-S01-00000004',
                      numero_fiscal:null, total, pagado:total, fiado:0,
                      cambio:Math.max(0, Math.round((recibido - total) * 100) / 100) },
               error:null };
    },
    ...extra
  }
});

/* Teclear en el buscador como lo haria una persona o la pistola. */
function teclear(w, d, texto, { pistola = false } = {}){
  const caja = d.querySelector('#buscar');
  caja.focus();
  if (pistola){
    // La pistola manda las teclas seguidas y cierra con Enter.
    for (const ch of texto)
      caja.dispatchEvent(new w.KeyboardEvent('keydown', { key:ch, bubbles:true }));
    caja.dispatchEvent(new w.KeyboardEvent('keydown', { key:'Enter', bubbles:true }));
    return;
  }
  caja.value = texto;
  caja.dispatchEvent(new w.Event('input', { bubbles:true }));
}
const tecla = (w, d, key, destino) =>
  (destino || d.body).dispatchEvent(new w.KeyboardEvent('keydown', { key, bubbles:true }));

console.log('\n=== ESCANEAR Y SUMAR ===');
{
  const { w, d, C } = await montar(base());
  teclear(w, d, '7501001', { pistola:true });
  await esperar();
  chk('escanear un código agrega la línea', C.S.ticket.length === 1);
  chk('con una unidad', C.S.ticket[0].cantidad === 1);
  chk('y deja el buscador limpio', d.querySelector('#buscar').value === '');

  teclear(w, d, '7501001', { pistola:true });
  await esperar();
  chk('volver a escanear suma, no duplica la línea',
      C.S.ticket.length === 1 && C.S.ticket[0].cantidad === 2);
  chk('la línea recién escaneada queda marcada',
      !!d.querySelector('.linea.puesto') &&
      d.querySelector('.linea.puesto').dataset.l === 'p1');

  teclear(w, d, '9999999', { pistola:true });
  await esperar();
  chk('un código que no existe no agrega nada', C.S.ticket.length === 1);
}
{
  const { w, d, C } = await montar(base());
  teclear(w, d, 'refresco');
  await esperar();
  chk('escribir deja un solo producto a la vista',
      d.querySelectorAll('.prod').length === 1);
  tecla(w, d, 'Enter', d.querySelector('#buscar'));
  await esperar();
  chk('Enter con un solo resultado lo agrega sin tocar la pantalla',
      C.S.ticket.length === 1 && C.S.ticket[0].producto_id === 'p3');
}
{
  const { w, d, C } = await montar(base());
  teclear(w, d, 'a');
  await esperar();
  chk('con varios resultados Enter no adivina',
      d.querySelectorAll('.prod').length > 1);
  tecla(w, d, 'Enter', d.querySelector('#buscar'));
  await esperar();
  chk('y no agrega nada', C.S.ticket.length === 0);
}

{
  /* La miniatura del producto en la línea: a diferencia de la caja de Maxi,
     que es puro texto. Confirma de un vistazo que entró lo que se creía. */
  const estado = base();
  estado.catalogo[0].imagen_url = 'https://ejemplo.hn/arroz.jpg';
  const { w, d, C } = await montar(estado);
  C.agregar('p1');   // con foto
  C.agregar('p3');   // sin foto
  await esperar();

  const imgs = [...d.querySelectorAll('.linea-img')];
  chk('cada línea del ticket lleva su miniatura', imgs.length === 2);
  chk('la del producto con foto la pinta de fondo',
      /ejemplo\.hn\/arroz\.jpg/.test(imgs[0].getAttribute('style') || ''));
  chk('y sin foto queda la inicial, que al menos distingue',
      !imgs[1].getAttribute('style') && imgs[1].textContent.trim() === 'R');
}

console.log('\n=== CANTIDAD ANTES DE ESCANEAR (3 y *) ===');
{
  const { w, d, C } = await montar(base());
  teclear(w, d, '3');
  tecla(w, d, '*', d.querySelector('#buscar'));
  await esperar();
  chk('el multiplicador queda a la vista',
      !d.querySelector('#multi').classList.contains('oculto'));
  chk('y dice cuánto', /3/.test(d.querySelector('#multi').textContent));
  chk('el buscador se limpia solo', d.querySelector('#buscar').value === '');

  teclear(w, d, '7501003', { pistola:true });
  await esperar();
  chk('lo que se escanea después entra con esa cantidad',
      C.S.ticket[0].cantidad === 3);
  chk('y el multiplicador se gasta',
      C.S.ticket.length === 1 && d.querySelector('#multi').classList.contains('oculto'));

  teclear(w, d, '7501003', { pistola:true });
  await esperar();
  chk('el siguiente ya entra de a uno', C.S.ticket[0].cantidad === 4);
}
{
  const { w, d, C } = await montar(base());
  // La pistola nunca manda un asterisco suelto, así que no debe disparar nada.
  teclear(w, d, '7501*03', { pistola:true });
  await esperar();
  chk('un * dentro de la ráfaga de la pistola no es multiplicador',
      C.S.multi == null);
}
{
  /* El caso que de verdad importa: una cajera rápida en el teclado numérico.
     Escribe 6 y enseguida *, con unos 70 ms entre tecla y tecla. Eso es
     claramente una persona (una pistola teclea en 1-10 ms), pero antes caía
     por debajo del umbral de la ráfaga y el * se le iba como texto: lo que
     escaneara después entraba de a uno sin avisar. */
  const { w, d, C } = await montar(base());
  const caja = d.querySelector('#buscar');
  caja.focus();
  caja.dispatchEvent(new w.KeyboardEvent('keydown', { key:'6', bubbles:true }));
  caja.value = '6';
  caja.dispatchEvent(new w.Event('input', { bubbles:true }));
  await esperar(70);
  caja.dispatchEvent(new w.KeyboardEvent('keydown', { key:'*', bubbles:true }));
  await esperar();
  chk('escribiendo rápido, 6 y * sí ponen la cantidad', C.S.multi === 6);
  chk('y el campo queda limpio para escanear', caja.value === '');

  teclear(w, d, '7501003', { pistola:true });
  await esperar();
  chk('lo escaneado entra de a 6', C.S.ticket[0]?.cantidad === 6);
}
{
  // Pegado a la tecla anterior (menos de 30 ms) sigue siendo la pistola.
  const { w, d, C } = await montar(base());
  const caja = d.querySelector('#buscar');
  caja.focus();
  caja.dispatchEvent(new w.KeyboardEvent('keydown', { key:'6', bubbles:true }));
  caja.value = '6';
  caja.dispatchEvent(new w.KeyboardEvent('keydown', { key:'*', bubbles:true }));
  await esperar();
  chk('pegado a la tecla anterior no cuenta: eso es la pistola',
      C.S.multi == null);
}

console.log('\n=== PRODUCTO POR PESO, DIGITADO ===');
{
  const { w, d, C } = await montar(base());
  C.agregar('p2');
  await esperar();
  C.hojaCantidad();
  await esperar();
  chk('la hoja de cantidad dice la unidad del producto',
      /LB/.test(d.querySelector('#hoja').textContent));

  const campo = d.querySelector('#cn-valor');
  campo.value = '0.75';
  campo.dispatchEvent(new w.Event('input', { bubbles:true }));
  chk('media libra y cuarto se puede escribir',
      /45\.00/.test(d.querySelector('#cn-res').textContent));
  d.querySelector('#cn-si').click();
  await esperar();
  chk('queda la cantidad quebrada en el ticket', C.S.ticket[0].cantidad === 0.75);
  chk('y se pinta sin ceros de relleno',
      /0\.75/.test(d.querySelector('.linea .qty span').textContent));
  chk('y la unidad va con el precio, que es donde explica algo',
      /por LB/.test(d.querySelector('.linea .linea-nom small').textContent));
  chk('el importe sale de la cantidad quebrada',
      Math.abs(C.totales().total - 45) < 0.001);
}
{
  const { w, d, C } = await montar(base());
  C.agregar('p2');
  await esperar();
  C.hojaCantidad();
  await esperar();
  d.querySelector('#cn-modo [data-m="monto"]').click();
  await esperar();
  chk('por monto cambia la pregunta',
      /cuánto/i.test(d.querySelector('#cn-rot').textContent));
  const campo = d.querySelector('#cn-valor');
  campo.value = '20';
  campo.dispatchEvent(new w.Event('input', { bubbles:true }));
  const res = d.querySelector('#cn-res').textContent;
  chk('dice cuántas libras son', /0\.333/.test(res));
  chk('y advierte el importe real, que no cae en los 20 exactos',
      /19\.98/.test(res));
  d.querySelector('#cn-si').click();
  await esperar();
  chk('se guarda la cantidad, no el monto', C.S.ticket[0].cantidad === 0.333);
}
{
  const { w, d, C } = await montar(base());
  C.agregar('p2');
  await esperar();
  C.hojaCantidad();
  await esperar();
  const campo = d.querySelector('#cn-valor');
  campo.value = '99';
  campo.dispatchEvent(new w.Event('input', { bubbles:true }));
  d.querySelector('#cn-si').click();
  await esperar();
  chk('no deja vender más de lo que hay',
      /Solo hay 12/.test(d.querySelector('#cn-error').textContent));
  chk('y la hoja sigue abierta', !!d.querySelector('#cn-valor'));
}

console.log('\n=== MOVERSE Y QUITAR CON EL TECLADO ===');
{
  const { w, d, C } = await montar(base());
  C.agregar('p1'); C.agregar('p2'); C.agregar('p3');
  await esperar();
  chk('el puesto queda en lo último agregado', C.S.puesto === 'p3');
  tecla(w, d, 'ArrowUp');
  chk('la flecha sube una línea', C.S.puesto === 'p2');
  tecla(w, d, 'ArrowUp'); tecla(w, d, 'ArrowUp');
  chk('y no se pasa de la primera', C.S.puesto === 'p1');
  tecla(w, d, 'ArrowDown');
  chk('la flecha baja', C.S.puesto === 'p2');

  tecla(w, d, 'F4');
  await esperar();
  chk('F4 quita la línea donde está parado',
      !C.S.ticket.some(l => l.producto_id === 'p2'));
  chk('y el puesto pasa a la que ocupó su lugar', C.S.puesto === 'p3');

  tecla(w, d, 'Delete');
  await esperar();
  chk('Supr hace lo mismo', C.S.ticket.length === 1);
}
{
  const { w, d, C } = await montar(base());
  C.agregar('p1');
  await esperar();
  tecla(w, d, '+');
  chk('+ sube la cantidad de la línea', C.S.ticket[0].cantidad === 2);
  tecla(w, d, '-');
  chk('- la baja', C.S.ticket[0].cantidad === 1);
  tecla(w, d, '-');
  await esperar();
  chk('y bajando de uno se quita la línea', C.S.ticket.length === 0);
}
{
  const { w, d, C } = await montar(base());
  C.agregar('p1');
  await esperar();
  tecla(w, d, 'F3');
  chk('F3 abre la búsqueda de verdad, con el cursor listo',
      !d.querySelector('#velo-buscar').classList.contains('oculto') &&
      d.activeElement === d.querySelector('#bs-q'));
  tecla(w, d, 'Escape', d.querySelector('#bs-q'));
  chk('Esc la cierra y vuelve al buscador de la caja',
      d.querySelector('#velo-buscar').classList.contains('oculto') &&
      d.activeElement === d.querySelector('#buscar'));
  teclear(w, d, 'queso');
  tecla(w, d, 'Escape');
  await esperar();
  chk('Escape limpia la búsqueda', d.querySelector('#buscar').value === '');
  chk('pero no toca el ticket', C.S.ticket.length === 1);
}

console.log('\n=== SUSPENDER Y RETOMAR ===');
{
  const { w, d, C } = await montar(base());
  C.agregar('p1'); C.agregar('p3');
  await esperar();
  const antes = C.totales().total;
  tecla(w, d, 'F7');
  await esperar();
  chk('F7 deja la venta en espera y limpia el ticket', C.S.ticket.length === 0);
  chk('la venta quedó guardada', C.guardadas().length === 1);
  chk('con su total', Math.abs(C.guardadas()[0].total - antes) < 0.001);
  chk('el atajo de retomar aparece con la cuenta',
      /F8/.test(d.querySelector('#atajos').textContent));

  C.agregar('p2');
  await esperar();
  tecla(w, d, 'F8');
  await esperar();
  chk('F8 abre la lista', /en espera/i.test(d.querySelector('#hoja').textContent));
  d.querySelector('[data-sp]').click();
  await esperar(120);
  chk('retomar trae la venta de vuelta',
      C.S.ticket.length === 2 && Math.abs(C.totales().total - antes) < 0.001);
  chk('y lo que estaba en pantalla no se perdió: se suspendió',
      C.guardadas().length === 1 && C.guardadas()[0].total === 60);
}
{
  // Sobrevivir a que se recargue la pantalla es lo que de verdad importa.
  const estado = base();
  const a = await montar(estado);
  a.C.agregar('p1');
  await esperar();
  a.C.suspender();
  await esperar();
  const crudo = a.w.localStorage.getItem('pulp:susp:s1:c1');
  chk('la espera se guarda en el navegador de esta caja', !!crudo);

  const b = await montar(estado);
  b.w.localStorage.setItem('pulp:susp:s1:c1', crudo);
  chk('y se vuelve a leer después de recargar', b.C.guardadas().length === 1);
}
{
  const estado = base();
  const { w, d, C } = await montar(estado);
  C.agregar('p1');
  await esperar();
  C.suspender();
  await esperar();
  // El producto se agotó mientras la venta estaba en espera.
  C.S.catalogo = C.S.catalogo.filter(p => p.producto_id !== 'p1');
  C.retomar(C.guardadas()[0].id);
  await esperar(120);
  chk('si un producto ya no está, no se arrastra al ticket', C.S.ticket.length === 0);
  chk('y se avisa en vez de cobrarlo callado',
      /ya no está disponible/.test(d.body.textContent));
}

console.log('\n=== COBRO: UNA SOLA FORMA ===');
{
  const { w, d, C } = await montar(base());
  C.agregar('p1');  // 98
  await esperar();
  tecla(w, d, 'F10');
  await esperar();
  chk('F10 abre el cobro',
      !d.querySelector('#velo-cobro').classList.contains('oculto'));
  chk('arranca en efectivo', C.S.metodo === 'efectivo');
  chk('sin dividir', C.S.partido === false);
  chk('y con el botón de dividir a la vista',
      !d.querySelector('#btn-partir').classList.contains('oculto'));
  chk('no deja confirmar sin recibir nada',
      d.querySelector('#confirmar-cobro').disabled);

  const r = d.querySelector('#recibido');
  r.value = '100'; r.dispatchEvent(new w.Event('input', { bubbles:true }));
  chk('con 100 el cambio es 2', /2\.00/.test(d.querySelector('#cambio').textContent));
  chk('y ya se puede confirmar', !d.querySelector('#confirmar-cobro').disabled);
}

console.log('\n=== COBRO: PAGO PARTIDO ===');
{
  const { w, d, C, estado } = await montar(base());
  C.agregar('p1'); C.agregar('p3'); C.agregar('p3');  // 98 + 40 = 138
  await esperar();
  d.querySelector('#btn-cobrar').click();
  await esperar();
  const total = C.totales().total;

  d.querySelector('#btn-partir').click();
  await esperar();
  chk('dividir abre las dos partes',
      !d.querySelector('#partes').classList.contains('oculto'));
  chk('y esconde el botón de dividir',
      d.querySelector('#btn-partir').classList.contains('oculto'));

  const p1 = d.querySelector('#p1-monto');
  p1.value = '100'; p1.dispatchEvent(new w.Event('input', { bubbles:true }));
  await esperar();
  chk('el resto se calcula solo',
      /38\.00/.test(d.querySelector('#p2-monto').textContent));
  const rap = [...d.querySelectorAll('#rapidos .rapido')].map(b => Number(b.dataset.r));
  chk('los billetes rápidos son del resto, no del total',
      rap.includes(38) && !rap.includes(138));
  chk('y el "Exacto" es el resto exacto',
      d.querySelector('#rapidos .rapido').textContent === 'Exacto' &&
      Number(d.querySelector('#rapidos .rapido').dataset.r) === 38);

  const r = d.querySelector('#recibido');
  r.value = '40'; r.dispatchEvent(new w.Event('input', { bubbles:true }));
  chk('el vuelto sale del efectivo, no del total',
      /2\.00/.test(d.querySelector('#cambio').textContent));

  d.querySelector('#confirmar-cobro').click();
  await esperar(160);
  const v = estado.llamadas.find(l => l.fn === 'fn_registrar_venta');
  chk('se mandan las dos formas de pago', v && v.args.p_pagos.length === 2);
  chk('la primera con su monto y sin recibido',
      v.args.p_pagos[0].metodo === 'tarjeta' && v.args.p_pagos[0].monto === 100 &&
      v.args.p_pagos[0].recibido === undefined);
  chk('la segunda en efectivo con lo que entregó el cliente',
      v.args.p_pagos[1].metodo === 'efectivo' && v.args.p_pagos[1].monto === 38 &&
      v.args.p_pagos[1].recibido === 40);
  chk('y los montos suman el total',
      Math.abs(v.args.p_pagos.reduce((s,p) => s + p.monto, 0) - total) < 0.001);
}
{
  const { w, d, C } = await montar(base());
  C.agregar('p1');
  await esperar();
  d.querySelector('#btn-cobrar').click();
  await esperar();
  d.querySelector('#btn-partir').click();
  await esperar();

  const p1 = d.querySelector('#p1-monto');
  p1.value = '98'; p1.dispatchEvent(new w.Event('input', { bubbles:true }));
  await esperar();
  chk('si la parte 1 se come todo el total no hay división que valga',
      d.querySelector('#confirmar-cobro').disabled);

  p1.value = '0'; p1.dispatchEvent(new w.Event('input', { bubbles:true }));
  await esperar();
  chk('y con cero tampoco', d.querySelector('#confirmar-cobro').disabled);

  d.querySelector('#no-partir').click();
  await esperar();
  chk('se puede volver a una sola forma', C.S.partido === false);
  chk('y vuelve el botón de dividir',
      !d.querySelector('#btn-partir').classList.contains('oculto'));
}
{
  const { w, d, C } = await montar(base());
  C.agregar('p1');
  await esperar();
  d.querySelector('#btn-cobrar').click();
  await esperar();
  d.querySelector('#btn-partir').click();
  await esperar();
  const p1 = d.querySelector('#p1-monto');
  p1.value = '50'; p1.dispatchEvent(new w.Event('input', { bubbles:true }));
  const r = d.querySelector('#recibido');
  r.value = '40'; r.dispatchEvent(new w.Event('input', { bubbles:true }));
  await esperar();
  chk('con el efectivo corto no deja confirmar',
      d.querySelector('#confirmar-cobro').disabled);
  chk('y dice que falta', /Falta/.test(d.querySelector('#cambio-caja').textContent));
}

{
  // Cobrar sin soltar el teclado.
  const { w, d, C, estado } = await montar(base());
  C.agregar('p1');
  await esperar();
  tecla(w, d, 'F10');
  await esperar();
  const r = d.querySelector('#recibido');
  r.focus();
  r.value = '50'; r.dispatchEvent(new w.Event('input', { bubbles:true }));
  tecla(w, d, 'Enter', r);
  await esperar(140);
  chk('con el efectivo corto, Enter no cobra',
      !estado.llamadas.some(l => l.fn === 'fn_registrar_venta'));
  r.value = '100'; r.dispatchEvent(new w.Event('input', { bubbles:true }));
  tecla(w, d, 'Enter', r);
  await esperar(180);
  chk('y alcanzando, Enter cierra la venta',
      estado.llamadas.some(l => l.fn === 'fn_registrar_venta'));
}

console.log('\n=== EL VUELTO, GRANDE Y CON LA RESTA A LA VISTA ===');
{
  const { w, d, C } = await montar(base());
  C.agregar('p1'); C.agregar('p3'); C.agregar('p3');  // 138
  await esperar();
  d.querySelector('#btn-cobrar').click();
  await esperar();
  const r = d.querySelector('#recibido');
  r.value = '200'; r.dispatchEvent(new w.Event('input', { bubbles:true }));
  d.querySelector('#confirmar-cobro').click();
  await esperar(180);
  chk('se muestra el paso de listo',
      !d.querySelector('#paso-listo').classList.contains('oculto'));
  chk('con el vuelto a entregar',
      /62\.00/.test(d.querySelector('#listo-cambio').textContent));
  chk('y la resta a la vista para que nadie discuta',
      !d.querySelector('#listo-cuentas').classList.contains('oculto') &&
      /200/.test(d.querySelector('#listo-recibio').textContent) &&
      /138/.test(d.querySelector('#listo-era').textContent));
}
{
  const { w, d, C } = await montar(base());
  C.agregar('p1');
  await esperar();
  d.querySelector('#btn-cobrar').click();
  await esperar();
  d.querySelector('#metodos [data-m="tarjeta"]').click();
  await esperar();
  const r = d.querySelector('#recibido');
  r.value = '0'; r.dispatchEvent(new w.Event('input', { bubbles:true }));
  d.querySelector('#confirmar-cobro').click();
  await esperar(180);
  chk('pagando con tarjeta no se habla de vuelto',
      d.querySelector('#caja-entregar').classList.contains('oculto'));
}

console.log('\n=== SIN INTERNET ===');
{
  const estado = base();
  estado.enLinea = false;
  const { w, d, C } = await montar(estado);
  C.S.enLinea = false;
  C.agregar('p1'); C.agregar('p3'); C.agregar('p3');
  await esperar();
  d.querySelector('#btn-cobrar').click();
  await esperar();
  d.querySelector('#btn-partir').click();
  await esperar();
  const p1 = d.querySelector('#p1-monto');
  p1.value = '100'; p1.dispatchEvent(new w.Event('input', { bubbles:true }));
  const r = d.querySelector('#recibido');
  r.value = '50'; r.dispatchEvent(new w.Event('input', { bubbles:true }));
  await esperar();
  d.querySelector('#confirmar-cobro').click();
  await esperar(180);
  chk('la venta se encola con las dos formas de pago',
      estado.encoladas.length === 1 && estado.encoladas[0].pagos.length === 2);
  chk('y el vuelto que se calculó aquí también sale del efectivo',
      /12\.00/.test(d.querySelector('#listo-cambio').textContent));
}

console.log('\n=== TICKET IMPRESO ===');
async function cobrarUna(estado, w2){
  const r = await montar(estado);
  r.C.agregar('p1');
  await esperar();
  r.d.querySelector('#btn-cobrar').click();
  await esperar();
  const rec = r.d.querySelector('#recibido');
  rec.value = '200'; rec.dispatchEvent(new r.w.Event('input', { bubbles:true }));
  r.d.querySelector('#confirmar-cobro').click();
  await esperar(200);
  return r;
}
const VENTA_COMPLETA = { data:{ venta:{ id:'v-123', numero:'T-S01-00000004', documento:'ticket',
  total:100, creada_en:new Date().toISOString() }, negocio:{ nombre:'La Esquina' }, lineas:[], pagos:[] }, error:null };
{
  const estado = base({ fn_venta_completa:VENTA_COMPLETA });
  const { w, d } = await cobrarUna(estado);
  chk('después de cobrar se ofrece imprimir', !d.querySelector('#btn-imprimir').classList.contains('oculto'));
  chk('sin imprimir solo (la opción viene apagada)', !(w.__impresos || []).length);
  d.querySelector('#btn-imprimir').click();
  await esperar(120);
  const pide = estado.llamadas.find(l => l.fn === 'fn_venta_completa');
  chk('pide la venta recién hecha', pide && pide.args.p_venta_id === 'v-123');
  chk('y la manda a la impresora', (w.__impresos || []).length === 1 &&
      w.__impresos[0].d.venta.numero === 'T-S01-00000004');

  const auto = d.querySelector('#imprimir-auto');
  auto.checked = true; auto.dispatchEvent(new w.Event('change'));
  chk('«imprimir siempre» se recuerda', w.localStorage.getItem('imprimir-auto') === '1');
}
{
  const estado = base({ fn_venta_completa:VENTA_COMPLETA });
  const r = await montar(estado);
  r.w.localStorage.setItem('imprimir-auto', '1');
  r.C.agregar('p1');
  await esperar();
  r.d.querySelector('#btn-cobrar').click();
  await esperar();
  const rec = r.d.querySelector('#recibido');
  rec.value = '200'; rec.dispatchEvent(new r.w.Event('input', { bubbles:true }));
  r.d.querySelector('#confirmar-cobro').click();
  await esperar(250);
  chk('con «imprimir siempre» sale solo al cobrar', (r.w.__impresos || []).length === 1);
  chk('y la casilla aparece marcada', r.d.querySelector('#imprimir-auto').checked);
}
{
  const estado = base({
    fn_venta_completa:VENTA_COMPLETA,
    fn_estado_facturacion:{ data:{ activa:true, rangos:[{ tipo:'factura', vigente:true, quedan:12, dias:4 }] }, error:null }
  });
  const orig = estado.rpc.fn_registrar_venta;
  estado.rpc.fn_registrar_venta = a => { const r = orig(a); r.data.documento = 'factura';
    r.data.numero_fiscal = '000-001-01-00000489'; return r; };
  const { d } = await cobrarUna(estado);
  const av = d.querySelector('#listo-rango');
  chk('al facturar avisa si el CAI se acaba o vence',
      !av.classList.contains('oculto') && /quedan 12 facturas/.test(av.textContent) &&
      /vence en 4 días/.test(av.textContent));
}
{
  const estado = base({
    fn_registrar_venta:{ data:null, error:{ message:'P0001: No hay rango de facturacion autorizado disponible' } }
  });
  const { d } = await cobrarUna(estado);
  chk('sin CAI vigente se explica qué hacer',
      /El gerente lo registra en Configuración/.test(d.querySelector('#cobro-error').textContent));
}
{
  const estado = base();
  estado.enLinea = false;
  const r = await montar(estado);
  r.C.S.enLinea = false;
  r.C.agregar('p1');
  await esperar();
  r.d.querySelector('#btn-cobrar').click();
  await esperar();
  const rec = r.d.querySelector('#recibido');
  rec.value = '200'; rec.dispatchEvent(new r.w.Event('input', { bubbles:true }));
  r.d.querySelector('#confirmar-cobro').click();
  await esperar(200);
  chk('sin internet no se ofrece imprimir (aún no hay número)',
      r.d.querySelector('#btn-imprimir').classList.contains('oculto'));
}

console.log('\n=== FIADO: PARTE AHORA Y PARTE DEBIENDO ===');
const CLIENTES = () => [
  { id:'k1', nombre:'Doña Rosa', telefono:'9999', saldo:300, limite_credito:1000, activo:true },
  { id:'k2', nombre:'Don Pedro', telefono:'8888', saldo:0, limite_credito:0, activo:true } ];
const SITUACION = { debe:300, limite:1000, disponible:700, dias_pago_texto:'los viernes',
  proximo_pago:'2026-10-16', le_toca_hoy:false, atrasado:true };
function conClientes(extra = {}){
  const e = base({ ...extra });
  e.tablas = { clientes:CLIENTES() };
  // como el servidor: la situación es la del cliente pedido, con su saldo real
  e.rpc.fn_situacion_cliente = a => {
    const c = e.tablas.clientes.find(x => x.id === a.p_cliente_id) || { saldo:0, limite_credito:0 };
    return { data:{ ...SITUACION, debe:Number(c.saldo), atrasado:c.saldo > 0 && SITUACION.atrasado }, error:null };
  };
  const abonar = e.rpc.fn_registrar_abono;
  if (abonar) e.rpc.fn_registrar_abono = a => {
    const c = e.tablas.clientes.find(x => x.id === a.p_cliente_id);
    if (c) c.saldo = c.saldo - a.p_monto;
    return abonar(a);
  };
  return e;
}
async function elegirCliente(d, id){
  d.querySelector('#btn-cliente').click();
  await esperar(80);
  d.querySelector(`.cl-fila[data-id="${id}"]`).click();
  await esperar(80);
}
{
  const estado = conClientes();
  const { w, d, C } = await montar(estado);
  C.agregar('p1'); C.agregar('p1');   // 196
  await esperar();
  d.querySelector('#btn-cobrar').click();
  await esperar();
  const f = d.querySelector('#metodo-fiado');
  chk('el fiado se ve aunque no haya cliente', !f.classList.contains('oculto'));
  f.click();
  await esperar(100);
  chk('sin cliente, tocar Fiado abre la lista de clientes',
      !d.querySelector('#velo-cliente').classList.contains('oculto'));
  d.querySelector('.cl-fila[data-id="k1"]').click();
  await esperar(120);
  chk('al elegirlo vuelve al cobro con el fiado marcado',
      d.querySelector('#velo-cliente').classList.contains('oculto') &&
      d.querySelector('#metodo-fiado').classList.contains('activo') && C.S.metodo === 'credito');
  chk('pregunta si paga algo ahora', !d.querySelector('#bloque-abono').classList.contains('oculto'));
  chk('sin abono todo queda fiado', /196\.00/.test(d.querySelector('#cambio').textContent));

  const a = d.querySelector('#abono-ahora');
  a.value = '100'; a.dispatchEvent(new w.Event('input', { bubbles:true }));
  chk('paga 100 y queda debiendo 96', /96\.00/.test(d.querySelector('#cambio').textContent) &&
      /Paga L 100\.00 ahora y queda debiendo L 96\.00/.test(d.querySelector('#abono-nota').textContent));
  d.querySelector('#confirmar-cobro').click();
  await esperar(200);
  const v = estado.llamadas.find(l => l.fn === 'fn_registrar_venta');
  chk('manda efectivo y fiado', v && v.args.p_pagos.length === 2 &&
      v.args.p_pagos[0].metodo === 'efectivo' && v.args.p_pagos[0].monto === 100 &&
      v.args.p_pagos[1].metodo === 'credito' && v.args.p_pagos[1].monto === 96);
  chk('a nombre del cliente', v && v.args.p_cliente_id === 'k1');
}
{
  const estado = conClientes();
  const { w, d, C } = await montar(estado);
  await elegirCliente(d, 'k1');
  C.agregar('p1');   // 98
  await esperar();
  d.querySelector('#btn-cobrar').click();
  await esperar();
  d.querySelector('#metodo-fiado').click();
  await esperar();
  const a = d.querySelector('#abono-ahora');
  a.value = '98'; a.dispatchEvent(new w.Event('input', { bubbles:true }));
  chk('si paga todo, no es fiado: no deja confirmar', d.querySelector('#confirmar-cobro').disabled &&
      /cobre en efectivo/.test(d.querySelector('#cambio-caja').textContent));
}
{
  const estado = conClientes();
  const r = await montar(estado);
  r.C.S.cliente = { id:'k9', nombre:'Doña Chepa', saldo:950, limite_credito:1000 };
  r.C.agregar('p1');   // 98, solo puede fiar 50
  await esperar();
  r.d.querySelector('#btn-cobrar').click();
  await esperar();
  r.d.querySelector('#metodo-fiado').click();
  await esperar();
  chk('sin cupo para todo, igual deja elegir fiado', r.C.S.metodo === 'credito');
  chk('pero no deja confirmar', r.d.querySelector('#confirmar-cobro').disabled &&
      /Que pague una parte ahora/.test(r.d.querySelector('#cobro-fiado').textContent));
  const a = r.d.querySelector('#abono-ahora');
  a.value = '50'; a.dispatchEvent(new r.w.Event('input', { bubbles:true }));
  chk('pagando 50 ya le alcanza el cupo', !r.d.querySelector('#confirmar-cobro').disabled);
}
{
  const estado = conClientes();
  const { d, C } = await montar(estado);
  await elegirCliente(d, 'k2');
  C.agregar('p1');
  await esperar();
  d.querySelector('#btn-cobrar').click();
  await esperar();
  d.querySelector('#metodo-fiado').click();
  await esperar();
  chk('a quien no se le fía, se explica y no cambia', C.S.metodo === 'efectivo' &&
      /no se le fía/i.test(d.querySelector('#cobro-fiado').textContent));
}

console.log('\n=== LA DEUDA DEL CLIENTE A LA VISTA ===');
{
  const estado = conClientes({ fn_registrar_abono: a => ({ data:{ abono_id:'ab1', cliente:'Doña Rosa',
    abonado:a.p_monto, saldo_anterior:300, saldo_nuevo:300 - a.p_monto, queda_libre:a.p_monto >= 300 }, error:null }) });
  const { w, d, C } = await montar(estado);
  await elegirCliente(d, 'k1');
  await esperar(80);
  const z = d.querySelector('#cl-deuda');
  chk('al elegir un cliente que debe se ve la deuda', !z.classList.contains('oculto') &&
      /Debe L 300\.00/.test(z.textContent));
  chk('con sus días de pago y si va atrasado', /paga los viernes/.test(z.textContent) &&
      /Atrasado/.test(z.textContent) && z.classList.contains('atrasado'));
  d.querySelector('#btn-cobrar-deuda').click();
  await esperar(50);
  chk('cobrar abre el abono con todo lo que debe', d.querySelector('#ab-monto').value === '300.00');
  const m = d.querySelector('#ab-monto');
  m.value = '150'; m.dispatchEvent(new w.Event('input', { bubbles:true }));
  const rc = d.querySelector('#ab-recibe');
  rc.value = '200'; rc.dispatchEvent(new w.Event('input', { bubbles:true }));
  chk('calcula el cambio', /50\.00/.test(d.querySelector('#ab-cambio').textContent));
  d.querySelector('#ab-si').click();
  await esperar(150);
  const ab = estado.llamadas.find(l => l.fn === 'fn_registrar_abono');
  chk('registra el abono en el turno de la caja', ab && ab.args.p_cliente_id === 'k1' &&
      ab.args.p_monto === 150 && ab.args.p_metodo === 'efectivo' && ab.args.p_turno_id === 't1');
  chk('dice cuánto queda debiendo y el cambio', /Ahora debe L 150\.00/.test(d.querySelector('#hoja').textContent) &&
      /L 50\.00/.test(d.querySelector('#hoja').textContent));
  chk('y el saldo del cliente se actualiza', Number(C.S.cliente.saldo) === 150);
}
{
  const estado = conClientes();
  const { w, d } = await montar(estado);
  await elegirCliente(d, 'k1');
  d.querySelector('#btn-cobrar-deuda').click();
  await esperar(50);
  const m = d.querySelector('#ab-monto');
  m.value = '400'; m.dispatchEvent(new w.Event('input', { bubbles:true }));
  chk('no deja cobrar más de lo que debe', d.querySelector('#ab-si').disabled &&
      /Más de lo que debe/.test(d.querySelector('#ab-cambio-caja').textContent));
}
{
  const estado = conClientes();
  const { d } = await montar(estado);
  await elegirCliente(d, 'k2');
  chk('quien no debe no muestra deuda', d.querySelector('#cl-deuda').classList.contains('oculto'));
}

/* ===================================================================
   LA GAVETA

   Lo que de verdad importa aquí: que la pantalla NUNCA enseñe cuánto
   debería haber en la gaveta. Un arqueo donde el que cuenta ya vio la
   respuesta no mide nada, y la 033 se diseñó entera alrededor de eso.
   =================================================================== */
console.log('\n=== LA GAVETA ===');
{
  const estado = base();
  estado.rpc.fn_movimientos_turno = { data:[
    { movimiento_id:'m1', tipo:'fondo', monto:500, diferencia:null,
      motivo:'Del fondo de la tienda', autorizo:'Somar Hernández',
      cuando:new Date().toISOString() },
    { movimiento_id:'m2', tipo:'retiro', monto:1200, diferencia:null,
      motivo:'Se lleva al banco', autorizo:'Somar Hernández',
      cuando:new Date().toISOString() },
    { movimiento_id:'m3', tipo:'arqueo', monto:4380, diferencia:-120,
      motivo:'Arqueo de media tarde', autorizo:'Somar Hernández',
      cuando:new Date().toISOString() }
  ], error:null };
  const { d, C } = await montar(estado);
  C.abrirGaveta();
  await esperar(120);

  const h = d.querySelector('#hoja-gaveta').textContent;
  chk('la gaveta ofrece las cuatro cosas',
      /Ingresar fondo/.test(h) && /Retiro parcial/.test(h) &&
      /Arqueo sorpresivo/.test(h) && /Cerrar el turno/.test(h));
  chk('dice que lo autoriza un supervisor o el gerente',
      /supervisor o el gerente/.test(h));
  chk('se ven los movimientos del turno',
      d.querySelectorAll('.gav-mov').length === 3);
  chk('la diferencia del arqueo lleva el signo delante de la moneda',
      /−L\s*120\.00/.test(h) && !/L\s*-120/.test(h));
  chk('el retiro se lee como salida y el fondo como entrada',
      /−L\s*1,200\.00/.test(h) && /\+L\s*500\.00/.test(h));
}
{
  const { d, C } = await montar(base());
  C.hojaGaveta('arqueo');
  await esperar();
  const h = d.querySelector('#hoja-gaveta').textContent;
  chk('el arqueo pide contar antes de escribir', /Cuente el efectivo/.test(h));
  chk('y explica por qué no se enseña lo esperado',
      /no se enseña cuánto debería haber/.test(h));
  chk('en ninguna parte de la hoja aparece un esperado',
      !/esperado/i.test(h));
  chk('pide código y PIN de quien autoriza',
      !!d.querySelector('#gv-codigo') && !!d.querySelector('#gv-pin'));
}
{
  const { d, C, w, estado } = await montar(base());
  C.hojaGaveta('fondo');
  await esperar();
  d.querySelector('#gv-si').click();
  await esperar(120);
  chk('sin contar nada no se manda nada',
      /Escriba cuántos billetes/.test(d.querySelector('#gv-error').textContent) &&
      !estado.llamadas.some(l => l.fn === 'fn_movimiento_caja'));

  contar(w, d, { 500:1 });
  d.querySelector('#gv-si').click();
  await esperar(120);
  chk('con monto pero sin credencial tampoco',
      /código y el PIN/.test(d.querySelector('#gv-error').textContent) &&
      !estado.llamadas.some(l => l.fn === 'fn_movimiento_caja'));
}
{
  const estado = base();
  estado.rpc.fn_movimiento_caja = a => ({ data:{
    ok:true, movimiento_id:'m9', tipo:a.p_tipo, monto:a.p_monto,
    autorizo:'Somar Hernández', en_gaveta:4820 }, error:null });
  const { d, C, w } = await montar(estado);
  C.hojaGaveta('fondo');
  await esperar();
  contar(w, d, { 100:4, 50:2 });
  d.querySelector('#gv-codigo').value = 'SOM';
  d.querySelector('#gv-pin').value = '12345';
  d.querySelector('#gv-si').click();
  await esperar(180);

  const lm = estado.llamadas.find(l => l.fn === 'fn_movimiento_caja');
  chk('manda el turno, el tipo, el monto y la credencial',
      lm && lm.args.p_turno_id === 't1' && lm.args.p_tipo === 'fondo' &&
      lm.args.p_monto === 500 && lm.args.p_codigo === 'SOM' && lm.args.p_pin === '12345');
  chk('y el desglose con lo que se contó',
      lm && JSON.stringify(lm.args.p_detalle) === JSON.stringify({ '100':4, '50':2 }));
  const h = d.querySelector('#hoja-gaveta').textContent;
  chk('confirma el fondo y quién autorizó',
      /Fondo ingresado/.test(h) && /Somar Hernández/.test(h));
  chk('y NO enseña cuánto quedó en la gaveta: eso mataría el arqueo',
      !/4,820/.test(h) && !/4820/.test(h));
}
{
  /* El PIN malo no llega como error: la función termina bien y responde
     {ok:false}, para que el intento fallido quede contado del otro lado. */
  const estado = base();
  estado.rpc.fn_movimiento_caja = { data:{ ok:false,
    error:'Codigo o PIN incorrecto' }, error:null };
  const { d, C, w } = await montar(estado);
  C.hojaGaveta('retiro');
  await esperar();
  contar(w, d, { 100:3 });
  d.querySelector('#gv-codigo').value = 'XXX';
  d.querySelector('#gv-pin').value = '00000';
  d.querySelector('#gv-si').click();
  await esperar(180);
  chk('la credencial mala se dice en la hoja, no se traga',
      /PIN incorrecto/i.test(d.querySelector('#gv-error').textContent));
  chk('la pantalla sigue abierta para reintentar', !!d.querySelector('#gv-si'));
  chk('y el conteo NO se borra: contar otra vez por un PIN mal puesto es cruel',
      d.querySelector('.den-c[data-d="100"]').value === '3');
  chk('y el PIN se borra', d.querySelector('#gv-pin').value === '');
}
{
  const estado = base();
  estado.rpc.fn_arqueo_caja = { data:{ ok:true, arqueo_id:'a1', contado:4700,
    esperado:4820, diferencia:-120, autorizo:'Somar Hernández',
    cuando:new Date().toISOString() }, error:null };
  const { d, C, w } = await montar(estado);
  C.hojaGaveta('arqueo');
  await esperar();
  contar(w, d, { 500:9, 100:2 });
  d.querySelector('#gv-codigo').value = 'SOM';
  d.querySelector('#gv-pin').value = '12345';
  d.querySelector('#gv-si').click();
  await esperar(180);
  const h = d.querySelector('#hoja-gaveta').textContent;
  chk('el arqueo dice que no cuadra', /no cuadra/i.test(h));
  chk('y de qué lado está la diferencia', /Falta en la gaveta/.test(h));
  chk('con la diferencia en positivo, que es como se lee',
      /L\s*120\.00/.test(h) && !/-120/.test(h));
  chk('ahora SÍ se enseña lo esperado: ya se contó',
      /4,820\.00/.test(h) && /4,700\.00/.test(h));
}
{
  const estado = base();
  estado.rpc.fn_arqueo_caja = { data:{ ok:true, arqueo_id:'a2', contado:4820,
    esperado:4820, diferencia:0, autorizo:'Somar Hernández',
    cuando:new Date().toISOString() }, error:null };
  const { d, C, w } = await montar(estado);
  C.hojaGaveta('arqueo');
  await esperar();
  contar(w, d, { 500:9, 100:3, 20:1 });
  d.querySelector('#gv-codigo').value = 'SOM';
  d.querySelector('#gv-pin').value = '12345';
  d.querySelector('#gv-si').click();
  await esperar(180);
  chk('si cuadra, lo dice sin alarmar',
      /La gaveta cuadra/.test(d.querySelector('#hoja-gaveta').textContent));
}
{
  const estado = base();
  estado.rpc.fn_cerrar_turno_con_arqueo = { data:{ ok:true, monto_inicial:500,
    efectivo_ventas:4000, abonos_fiado:0, fondos:500, retiros:200,
    devoluciones:0, esperado:4800, declarado:4800, diferencia:0,
    cerro:'Somar Hernández' }, error:null };
  const { d, C, w, estado:e } = await montar(estado);
  C.hojaGaveta('cierre');
  await esperar();
  contar(w, d, { 500:9, 100:3 });
  d.querySelector('#gv-codigo').value = 'SOM';
  d.querySelector('#gv-pin').value = '12345';
  d.querySelector('#gv-si').click();
  await esperar(180);
  const lc = e.llamadas.find(l => l.fn === 'fn_cerrar_turno_con_arqueo');
  chk('el cierre pasa por el que exige credencial',
      lc && lc.args.p_monto_declarado === 4800 && lc.args.p_codigo === 'SOM');
  chk('con su desglose', lc && lc.args.p_detalle['500'] === 9 && lc.args.p_detalle['100'] === 3);
  chk('y lo confirma',
      /Turno cerrado/.test(d.querySelector('#hoja-gaveta').textContent));
}


/* ===================================================================
   EL CONTEO POR DENOMINACIÓN
   =================================================================== */
console.log('\n=== EL CONTEO POR DENOMINACIÓN ===');
{
  const { d, C, w } = await montar(base());
  C.hojaGaveta('arqueo');
  await esperar();
  const casillas = [...d.querySelectorAll('.den-c')];
  chk('sin configurar salen las trece de Honduras', casillas.length === 13);
  chk('de mayor a menor, empezando por 500',
      casillas[0].dataset.d === '500' && casillas[12].dataset.d === '0.05');
  const grupos = [...d.querySelectorAll('.pg-grupo')].map(g => g.textContent);
  chk('billetes y monedas van separados',
      grupos.length === 2 && /Billetes/.test(grupos[0]) && /Monedas/.test(grupos[1]));
  chk('los centavos se leen como centavos', /50 ¢/.test(grupos[1]) && /5 ¢/.test(grupos[1]));

  contar(w, d, { 500:3, 20:2 });
  const fila = d.querySelector('.den[data-d="500"]');
  chk('cada fila dice su subtotal', /L\s*1,500\.00/.test(fila.textContent));
  chk('y queda marcada como contada', fila.classList.contains('lleno'));
  chk('el total suma todo', /L\s*1,540\.00/.test(d.querySelector('#pg-total').textContent));
  chk('y cuenta las piezas', /5 billetes · 0 monedas/.test(d.querySelector('#pg-piezas').textContent));

  /* 0.1 + 0.2 en coma flotante da 0.30000000000000004. Un arqueo que no
     cuadra por eso sería el peor aviso posible. */
  contar(w, d, { 500:0, 20:0, 0.1:3 });
  chk('los centavos se suman sin error de redondeo',
      /L\s*0\.30/.test(d.querySelector('#pg-total').textContent));

  contar(w, d, { 100:'1a2' });
  chk('una cantidad solo acepta dígitos',
      d.querySelector('.den-c[data-d="100"]').value === '12');
}
{
  const { d, C, w } = await montar(base());
  C.hojaGaveta('fondo');
  await esperar();
  const c = [...d.querySelectorAll('.den-c')];
  c[0].focus();
  c[0].dispatchEvent(new w.KeyboardEvent('keydown', { key:'Enter', bubbles:true }));
  chk('Enter baja a la siguiente denominación', d.activeElement === c[1]);
  c[12].focus();
  c[12].dispatchEvent(new w.KeyboardEvent('keydown', { key:'Enter', bubbles:true }));
  chk('y de la última pasa al código de quien autoriza',
      d.activeElement === d.querySelector('#gv-codigo'));
}
{
  const { d, C } = await montar(base());
  C.abrirGaveta();
  await esperar(120);
  chk('la gaveta ocupa la pantalla: tiene su barra y su salida a la caja',
      !!d.querySelector('#hoja-gaveta .pg-barra') &&
      /Volver a la caja/.test(d.querySelector('#gv-x').textContent));
  d.querySelector('#gv-x').click();
  chk('y "Volver a la caja" la cierra',
      d.querySelector('#velo-gaveta').classList.contains('oculto'));
}
{
  /* La lista es del negocio: si el gerente la cambió, se cuenta con esa. */
  const estado = base();
  estado.rpc.fn_denominaciones = { data:{ denominaciones:[1000, 500, 100, 0.5],
                                          por_defecto:false }, error:null };
  const { d, C } = await montar(estado);
  C.abrirGaveta();
  await esperar(120);
  C.hojaGaveta('arqueo');
  await esperar(120);
  const den = [...d.querySelectorAll('.den-c')].map(i => i.dataset.d);
  chk('se cuenta con las denominaciones del negocio',
      den.join(',') === '1000,500,100,0.5');
}
{
  /* Gaveta vacía en un arqueo: posible pero rara. Se pide confirmar tocando
     otra vez, no con un diálogo del navegador. */
  const estado = base();
  estado.rpc.fn_arqueo_caja = { data:{ ok:true, arqueo_id:'a0', contado:0,
    esperado:0, diferencia:0, autorizo:'Somar Hernández' }, error:null };
  const { d, C } = await montar(estado);
  C.hojaGaveta('arqueo');
  await esperar();
  d.querySelector('#gv-codigo').value = 'SOM';
  d.querySelector('#gv-pin').value = '12345';
  d.querySelector('#gv-si').click();
  await esperar(120);
  chk('el arqueo sin nada contado pide confirmar',
      /toque Comparar otra vez/.test(d.querySelector('#gv-error').textContent) &&
      !estado.llamadas.some(l => l.fn === 'fn_arqueo_caja'));
  d.querySelector('#gv-si').click();
  await esperar(160);
  const la = estado.llamadas.find(l => l.fn === 'fn_arqueo_caja');
  chk('y al segundo toque sí va, con el desglose en null',
      la && la.args.p_contado === 0 && la.args.p_detalle === null);
}
{
  /* Tocar un movimiento enseña de qué billetes estaba hecho. */
  const estado = base();
  estado.rpc.fn_movimientos_turno = { data:[
    { movimiento_id:'m1', tipo:'arqueo', monto:980, diferencia:-20,
      motivo:null, autorizo:'Somar Hernández', cuando:new Date().toISOString() }
  ], error:null };
  estado.rpc.fn_detalle_movimiento = { data:{ movimiento_id:'m1',
    detalle:{ '100':4, '500':1, '0.5':2 } }, error:null };
  const { d, C } = await montar(estado);
  C.abrirGaveta();
  await esperar(120);
  d.querySelector('.gav-mov[data-id="m1"]').click();
  await esperar(120);
  const t = d.querySelector('.gav-desglose')?.textContent || '';
  chk('tocar un movimiento enseña su desglose, de mayor a menor',
      /1 × L 500 · 4 × L 100 · 2 × 50 ¢/.test(t));
  d.querySelector('.gav-mov[data-id="m1"]').click();
  await esperar(60);
  chk('y tocarlo otra vez lo esconde', !d.querySelector('.gav-desglose'));
}

/* ===================================================================
   BUSCAR PRODUCTO (F3)
   =================================================================== */
console.log('\n=== BUSCAR PRODUCTO (F3) ===');
{
  const { w, d, C } = await montar(base());
  d.querySelector('.atajo[data-k="F3"]').click();
  await esperar();
  chk('el botón Buscar también la abre',
      !d.querySelector('#velo-buscar').classList.contains('oculto'));
  const q = d.querySelector('#bs-q');
  q.value = 'QUESO'; q.dispatchEvent(new w.Event('input', { bubbles:true }));
  chk('encuentra sin importar mayúsculas',
      d.querySelectorAll('.bs-fila').length === 1 && /Queso fresco/.test(d.querySelector('.bs-fila').textContent));
  chk('y enseña el precio y lo que hay',
      /L\s*60\.00/.test(d.querySelector('.bs-fila').textContent) &&
      /hay 12/.test(d.querySelector('.bs-fila').textContent));
  q.value = 'e'; q.dispatchEvent(new w.Event('input', { bubbles:true }));
  const filas = d.querySelectorAll('.bs-fila').length;
  tecla(w, d, 'ArrowDown', q);
  chk('las flechas mueven la selección',
      filas > 1 && d.querySelectorAll('.bs-fila')[1].classList.contains('sel'));
  tecla(w, d, 'Enter', q);
  await esperar();
  chk('Enter agrega el elegido y cierra',
      C.S.ticket.length === 1 && d.querySelector('#velo-buscar').classList.contains('oculto'));
}
{
  const { w, d, C } = await montar(base());
  C.abrirBuscador('vender', '7501003');
  await esperar();
  chk('un código exacto da ese producto y nada más',
      d.querySelectorAll('.bs-fila').length === 1 && /Refresco/.test(d.querySelector('.bs-fila').textContent));
  d.querySelector('.bs-fila').click();
  await esperar();
  chk('y tocarlo lo agrega', C.S.ticket.length === 1 && C.S.ticket[0].producto_id === 'p3');
}

/* ===================================================================
   CANTIDAD ANTES DE ESCANEAR, Y + / - DE UNO EN UNO
   =================================================================== */
console.log('\n=== 12 Y ESCANEAR ===');
{
  const { w, d, C } = await montar(base());
  const caja = d.querySelector('#buscar');
  caja.value = '12';            // lo escrito a mano
  teclear(w, d, '7501003', { pistola:true });
  await esperar();
  chk('digitar 12 y escanear agrega 12, sin asterisco',
      C.S.ticket.length === 1 && C.S.ticket[0].cantidad === 12);
  chk('y el buscador queda limpio', caja.value === '');

  teclear(w, d, '7501003', { pistola:true });
  await esperar();
  chk('escanear otra vez sin número suma uno', C.S.ticket[0].cantidad === 13);

  tecla(w, d, '+', caja);
  chk('+ con el buscador vacío sube uno', C.S.ticket[0].cantidad === 14);
  tecla(w, d, '-', caja);
  tecla(w, d, '-', caja);
  chk('- baja uno', C.S.ticket[0].cantidad === 12);

  caja.value = '7';
  tecla(w, d, '-', caja);
  chk('con algo escrito, - es texto y no toca la línea', C.S.ticket[0].cantidad === 12);
}
{
  const { w, d, C } = await montar(base());
  const caja = d.querySelector('#buscar');
  caja.value = '3';
  teclear(w, d, '9999999', { pistola:true });
  await esperar();
  chk('si el código no existe, no agrega nada', C.S.ticket.length === 0);
  chk('y deja la cantidad puesta para volver a escanear', caja.value === '3');
}
{
  const { w, d, C } = await montar(base());
  const caja = d.querySelector('#buscar');
  caja.value = '7501002';       // escrito a mano, sin ráfaga
  tecla(w, d, 'Enter', caja);
  await esperar();
  chk('un código escrito a mano completo también entra, de a uno',
      C.S.ticket.length === 1 && C.S.ticket[0].producto_id === 'p2' && C.S.ticket[0].cantidad === 1);
}

/* ===================================================================
   LA CAJA BLOQUEADA
   =================================================================== */
console.log('\n=== LA CAJA BLOQUEADA ===');
{
  const { w, d, C, estado } = await montar(base());
  C.bloquear();
  await esperar();
  chk('enseña la hora', /\d{1,2}:\d{2}/.test(d.querySelector('#b-hora').textContent));
  chk('el cajero', /Ana Maradiaga/.test(d.querySelector('#b-cajero').textContent));
  chk('y el nombre del negocio si no hay logo',
      /Pulpería Pulpeando/.test(d.querySelector('#b-logo').textContent));

  /* La pistola teclea en ráfaga: eso es un producto, no el PIN. */
  for (const ch of '7501001') tecla(w, d, ch);
  tecla(w, d, 'Enter');
  await esperar(120);
  chk('escanear con la caja bloqueada enseña el precio',
      /Arroz de primera/.test(d.querySelector('#b-precio-res').textContent) &&
      /L\s*98\.00/.test(d.querySelector('#b-precio-res').textContent));
  chk('y NO toca el PIN: escanear no gasta intentos',
      C.S.pin === '' && !estado.llamadas.some(l => l.fn === 'fn_desbloquear_caja'));

  /* A mano, una tecla a la vez, sí es el PIN. */
  for (const ch of '12'){ tecla(w, d, ch); await esperar(90); }
  chk('los dígitos a mano van al PIN', C.S.pin === '12' &&
      d.querySelectorAll('#b-puntos .punto.on').length === 2);

  tecla(w, d, 'q');
  chk('una letra empieza a buscar el precio por nombre',
      d.activeElement === d.querySelector('#b-precio') && d.querySelector('#b-precio').value === 'q');
}
{
  const { w, d, C } = await montar(base());
  C.bloquear();
  await esperar();
  tecla(w, d, 'F3');
  chk('F3 lleva a la consulta de precio', d.activeElement === d.querySelector('#b-precio'));
  const c = d.querySelector('#b-precio');
  c.value = 'refresco';
  tecla(w, d, 'Enter', c);
  chk('buscar por nombre da el precio',
      /Refresco 600 ml/.test(d.querySelector('#b-precio-res').textContent) &&
      /L\s*20\.00/.test(d.querySelector('#b-precio-res').textContent));
  c.value = 'zzz';
  tecla(w, d, 'Enter', c);
  chk('y si no hay nada lo dice', /No se encontró/.test(d.querySelector('#b-precio-res').textContent));
}

/* ===================================================================
   ABRIR TURNO
   =================================================================== */
console.log('\n=== ABRIR TURNO ===');
{
  const { d } = await montar(base());
  chk('el fondo arranca vacío, no con ceros', d.querySelector('#t-monto').value === '');
  chk('el PIN no se ve mientras se escribe', d.querySelector('#t-pin').type === 'password');
}
{
  /* Con "Elija su caja" encima, el teclado es de ese formulario: antes los
     dígitos del fondo se iban al buscador de productos. */
  const { w, d } = await montar(base());
  d.querySelector('#p-turno').classList.remove('oculto');
  const m = d.querySelector('#t-monto');
  m.focus();
  tecla(w, d, '5', m);
  chk('escribir el fondo no se lo roba el buscador', d.activeElement === m);
}

/* ===================================================================
   LA ENTRADA DE LA CAJERA

   En el mostrador no se escribe correo ni contrasena. Se marca el codigo y
   el PIN, y lo que hace que un PIN de cinco digitos alcance es que la tablet
   ya esta pareada: la llave del aparato es el otro candado.
   =================================================================== */
console.log('\n=== LA ENTRADA DE LA CAJERA ===');

const TABLET = { id:'aaaa0000-1111-4222-8333-444455556666', llave:'a'.repeat(48),
                 negocio:'Pulpería Pulpeando', caja:'Caja 1' };

/* OJO: base() extiende el mapa de rpc, no el estado. Aqui se arma el estado
   completo, que es otra cosa: sin sesion y con la tablet pareada. */
const entrada = (extra = {}) => ({ ...base(), entrada:true, sesion:null,
                                   aparato:TABLET, ...extra });

{
  const { d } = await montar(entrada({ aparato:null }));
  chk('sin parear no se pide PIN, se avisa que falta parear',
      !d.querySelector('#p-aparato').classList.contains('oculto') &&
      d.querySelector('#p-sesion').classList.contains('oculto'));
  chk('y manda al resto del sistema, no ofrece entrar con correo',
      d.querySelector('#p-aparato a').getAttribute('href') === '../' &&
      !/contrase/i.test(d.querySelector('#p-aparato').textContent));
}

{
  const { d } = await montar(entrada());
  chk('pareada, pide codigo y PIN',
      !d.querySelector('#p-sesion').classList.contains('oculto') &&
      d.querySelector('#p-aparato').classList.contains('oculto'));
  chk('y dice de que caja es', /Pulpería Pulpeando/.test(d.querySelector('#s-caja').textContent));
  chk('en ningun lado se ofrece correo ni contrasena',
      !d.querySelector('#s-email') && !d.querySelector('#s-clave'));
}

{
  /* El teclado: cinco digitos y se va sola, sin boton de Entrar. */
  const { d, C, w, estado:e } = await montar(entrada({
    fetch:{ ok:true, sesion:{ access_token:'at', refresh_token:'rt' },
            cajera:{ perfil_id:'u1', nombre:'Ana Maradiaga', rol:'auxiliar' },
            caja:{ organizacion_id:'o1', sucursal_id:'s1', caja_id:'c1' } } }));

  d.querySelector('#s-codigo').value = 'c7';
  const teclas = [...d.querySelectorAll('#s-teclado .tecla')];
  const marcar = n => teclas.find(t => t.textContent.trim() === n).click();
  '4567'.split('').forEach(marcar);
  chk('los puntos van marcando lo que lleva',
      d.querySelectorAll('#s-puntos .punto.on').length === 4);
  /* Hay dos teclados de PIN en la pagina. Que uno pinte los puntos del otro
     deja a la cajera marcando a ciegas, y se ve igual que si no funcionara. */
  chk('y no toca los puntos de la pantalla bloqueada',
      d.querySelectorAll('#b-puntos .punto.on').length === 0);
  chk('con cuatro digitos todavia no manda nada', e.pedidos.length === 0);

  marcar('8');
  await esperar(140);
  chk('al quinto digito entra sola, sin boton', e.pedidos.length === 1);

  const p = e.pedidos[0];
  chk('toca la funcion de borde', /\/functions\/v1\/entrar-caja$/.test(p.url));
  chk('manda la llave del aparato, no solo el PIN',
      p.cuerpo.aparato === TABLET.id && p.cuerpo.llave === TABLET.llave);
  chk('manda el codigo y el PIN marcados',
      p.cuerpo.codigo === 'c7' && p.cuerpo.pin === '45678');
  chk('NO manda el negocio ni la caja: esos salen del aparato en el servidor',
      p.cuerpo.organizacion_id === undefined && p.cuerpo.caja_id === undefined);
  chk('abre la sesion con lo que devolvio',
      e.sesiones.length === 1 && e.sesiones[0].access_token === 'at');
  chk('y limpia el PIN de la pantalla',
      d.querySelectorAll('#s-puntos .punto.on').length === 0);
}

{
  const { d, C, estado:e } = await montar(entrada({
    fetch:{ ok:false, error:'credencial', mensaje:'Codigo o PIN incorrecto' } }));
  d.querySelector('#s-codigo').value = 'C7';
  const teclas = [...d.querySelectorAll('#s-teclado .tecla')];
  '00000'.split('').forEach(n => teclas.find(t => t.textContent.trim() === n).click());
  await esperar(140);
  chk('el PIN malo lo dice', /incorrecto/i.test(d.querySelector('#s-error').textContent));
  chk('borra el PIN para que vuelva a marcar',
      d.querySelectorAll('#s-puntos .punto.on').length === 0);
  chk('pero deja el codigo escrito: no fue culpa del codigo',
      d.querySelector('#s-codigo').value === 'C7');
  chk('y no abre ninguna sesion', e.sesiones.length === 0);
  chk('sigue pidiendo credencial, no manda a parear',
      d.querySelector('#p-aparato').classList.contains('oculto'));
}

{
  /* Si al gerente le revocaron la tablet, seguir pidiendo PIN seria cruel:
     marcaria bien mil veces y no entraria nunca. */
  const { d } = await montar(entrada({
    fetch:{ ok:false, error:'aparato',
            mensaje:'Este aparato ya no tiene permiso para abrir caja' } }));
  d.querySelector('#s-codigo').value = 'C7';
  const teclas = [...d.querySelectorAll('#s-teclado .tecla')];
  '45678'.split('').forEach(n => teclas.find(t => t.textContent.trim() === n).click());
  await esperar(140);
  chk('la tablet revocada deja de pedir PIN y manda a parear',
      !d.querySelector('#p-aparato').classList.contains('oculto'));
}

{
  const { d } = await montar(entrada({
    fetch:{ ok:false, error:'aparato_bloqueado',
            mensaje:'Demasiados intentos en este aparato. Espere unos minutos' } }));
  d.querySelector('#s-codigo').value = 'C7';
  const teclas = [...d.querySelectorAll('#s-teclado .tecla')];
  '45678'.split('').forEach(n => teclas.find(t => t.textContent.trim() === n).click());
  await esperar(140);
  chk('el aparato enfriado lo dice con su mensaje',
      /Espere unos minutos/.test(d.querySelector('#s-error').textContent));
  chk('y no manda a parear: la llave sigue buena',
      d.querySelector('#p-aparato').classList.contains('oculto'));
}

{
  const { d } = await montar(entrada({ fetch:'cae' }));
  d.querySelector('#s-codigo').value = 'C7';
  const teclas = [...d.querySelectorAll('#s-teclado .tecla')];
  '45678'.split('').forEach(n => teclas.find(t => t.textContent.trim() === n).click());
  await esperar(140);
  chk('sin senal lo dice en lugar de quedarse pensando',
      /conexi/i.test(d.querySelector('#s-error').textContent));
}

{
  const { d, estado:e } = await montar(entrada());
  const teclas = [...d.querySelectorAll('#s-teclado .tecla')];
  '45678'.split('').forEach(n => teclas.find(t => t.textContent.trim() === n).click());
  await esperar(140);
  chk('sin codigo no se molesta al servidor', e.pedidos.length === 0);
  chk('y pide el codigo', /c[oó]digo/i.test(d.querySelector('#s-error').textContent));
}

{
  const { d, estado:e } = await montar(entrada({
    fetch:{ ok:true, sesion:{ access_token:'at', refresh_token:'rt' },
            cajera:{}, caja:{} } }));
  d.querySelector('#s-codigo').value = 'C7';
  const teclas = [...d.querySelectorAll('#s-teclado .tecla')];
  const borrar = teclas.find(t => t.dataset.accion === 'borrar');
  '456'.split('').forEach(n => teclas.find(t => t.textContent.trim() === n).click());
  borrar.click();
  chk('borrar quita un digito', d.querySelectorAll('#s-puntos .punto.on').length === 2);
  teclas.find(t => t.dataset.accion === 'limpiar').click();
  chk('limpiar deja todo en blanco',
      d.querySelectorAll('#s-puntos .punto.on').length === 0 &&
      d.querySelector('#s-codigo').value === '');
  chk('y no mando nada al servidor', e.pedidos.length === 0);
}

{
  /* La cajera que llega a relevar no usa el PIN de la que esta adentro. */
  const { d, estado:e } = await montar(base());
  d.querySelector('#b-otra').click();
  await esperar(60);
  chk('"Entra otra cajera" cierra la sesion de verdad', e.salio === true);
}


console.log(`\n${ok} bien · ${mal} mal`);
process.exit(mal ? 1 : 0);
