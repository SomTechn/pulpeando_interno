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
  const html = fs.readFileSync(BASE + 'index.html', 'utf8');
  const cuerpo = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  const css = fs.readFileSync(BASE + 'ui.css', 'utf8');

  const dom = new JSDOM(
    html.replace(/<script type="module">[\s\S]*?<\/script>/, '')
        .replace('<link rel="stylesheet" href="ui.css">', '<style>' + css + '</style>')
        .replace(/<script src="config\.js"><\/script>/, ''),
    { runScripts:'outside-only', url:'https://x.test/', pretendToBeVisual:true });

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

  w.__sb = {
    auth:{ getSession: async () => ({ data:{ session:{ user:{id:'u1'} } } }),
           signInWithPassword: async () => ({ error:null }),
           signOut: async () => {}, onAuthStateChange(){} },
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
    .replace(/^import \{ montarMenu, iniciales, escapar \} from '\.\/menu\.js';$/m, '')
    .replace(/^import \{ escanear, hayCamara \} from '\.\/escaner\.js';$/m,
             'const escanear = async () => null; const hayCamara = async () => false;')
    .replace(/^import \{ imprimirTicket \} from '\.\/ticket\.js';$/m,
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
  })()`);
  await new Promise(r => setTimeout(r, 140));

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
  await new Promise(r => setTimeout(r, 60));

  return { w, d:w.document, C, estado };
}

const esperar = (ms = 60) => new Promise(r => setTimeout(r, ms));

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
  chk('F3 devuelve el foco al buscador',
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

console.log(`\n${ok} bien · ${mal} mal`);
process.exit(mal ? 1 : 0);
