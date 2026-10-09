/* Prueba funcional de la pantalla de movimientos (inventario por fecha).

   Lo que se vigila aqui:
     · que la auxiliar no entre: el kardex es de supervisor para arriba
     · que el gerente vea la cuenta en lempiras y el supervisor solo cantidades
     · que "al dia" pida una sola fecha y esconda lo que esta en cero
     · que un producto que no cuadra se note
     · que el kardex de un producto se abra con su documento y quien lo hizo
     · que el CSV no deje pasar formulas de Excel
*/
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';

const BASE = fileURLToPath(new URL('./', import.meta.url));
let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };

const CTX = (rol = 'gerente', nivel = 3, sucs = 1) => ({
  usuario:{ id:'u1', nombre:'Somar', rol, nivel, tiene_pin:true },
  organizacion:{ id:'o1', nombre:'Pulpería Pulpeando', moneda:'HNL', factura_fiscal:false },
  sucursales:[{ id:'s1', nombre:'Central', codigo:'S01' },
              { id:'s2', nombre:'Choloma', codigo:'S02' }].slice(0, sucs),
  cajas:[], impuesto_default:0, sin_sucursal:false });

const INV = (ve, extra = {}) => ({
  desde:'2026-10-01', hasta:'2026-10-03', sucursal_id:'s1', sucursal:'Central',
  puede_ver_costos:ve,
  totales:{ productos:3, con_movimiento:2, movimientos:6, no_cuadran:0,
            valor_inicial: ve ? 1140 : null, valor_entradas: ve ? 650 : null,
            valor_salidas: ve ? 191.4 : null, valor_final: ve ? 1598.6 : null },
  por_tipo:[
    { tipo:'compra', nombre:'Compra', entrada:true, movimientos:1, unidades:50, valor: ve ? 650 : null },
    { tipo:'venta',  nombre:'Venta',  entrada:false, movimientos:2, unidades:15, valor: ve ? 150 : null },
    { tipo:'merma',  nombre:'Merma',  entrada:false, movimientos:1, unidades:2,  valor: ve ? 22 : null } ],
  productos:[
    { producto_id:'p1', nombre:'Aceite vegetal 500ml', sku:'ACE500', unidad:'UND', categoria:'Básicos',
      inicial:100, entradas:50, salidas:17, final:133, movimientos:4, ultimo:'2026-10-03T14:00:00Z',
      cuadra:true, valor_inicial: ve ? 1000 : null, valor_entradas: ve ? 650 : null,
      valor_salidas: ve ? 191.4 : null, valor_final: ve ? 1458.6 : null },
    { producto_id:'p2', nombre:'=HYPERLINK("x")', sku:'RARO', unidad:'UND', categoria:null,
      inicial:0, entradas:0, salidas:0, final:0, movimientos:0, ultimo:'2026-09-01T14:00:00Z',
      cuadra:true, valor_inicial: ve ? 0 : null, valor_entradas: ve ? 0 : null,
      valor_salidas: ve ? 0 : null, valor_final: ve ? 0 : null },
    { producto_id:'p3', nombre:'Arroz de primera 5 lb', sku:'ARR5', unidad:'UND', categoria:'Básicos',
      inicial:20, entradas:0, salidas:0, final:20, movimientos:0, ultimo:'2026-09-15T18:00:00Z',
      cuadra:true, valor_inicial: ve ? 140 : null, valor_entradas: ve ? 0 : null,
      valor_salidas: ve ? 0 : null, valor_final: ve ? 140 : null } ],
  truncado:false, limite:500, ...extra });

const KARDEX = ve => ({
  producto_id:'p1', nombre:'Aceite vegetal 500ml', sku:'ACE500', unidad:'UND',
  sucursal_id:'s1', sucursal:'Central', desde:'2026-10-01', hasta:'2026-10-03',
  puede_ver_costos:ve, inicial:100, final:133, entradas:50, salidas:17,
  valor_inicial: ve ? 1000 : null, valor_final: ve ? 1458.6 : null,
  total_movimientos:4, truncado:false,
  movimientos:[
    { id:1, fecha:'2026-10-01T15:00:00Z', tipo:'venta', nombre_tipo:'Venta', cantidad:-10, saldo:90,
      lote:null, documento_tipo:'venta', documento:'T-S01-00000042', usuario:'Ana', notas:null,
      costo_unitario: ve ? 10 : null, costo_total: ve ? 100 : null,
      costo_promedio: ve ? 10 : null, saldo_valor: ve ? 900 : null },
    { id:2, fecha:'2026-10-02T17:00:00Z', tipo:'compra', nombre_tipo:'Compra', cantidad:50, saldo:140,
      lote:'L-OCT', documento_tipo:'factura_compra', documento:'FC-881', usuario:'Somar', notas:null,
      costo_unitario: ve ? 13 : null, costo_total: ve ? 650 : null,
      costo_promedio: ve ? 11.07 : null, saldo_valor: ve ? 1550 : null } ]
});

async function montar(estado){
  const html = fs.readFileSync(BASE + 'movimientos.html', 'utf8');
  const cuerpo = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  const css = fs.readFileSync(BASE + 'ui.css', 'utf8');

  const dom = new JSDOM(
    html.replace(/<script type="module">[\s\S]*?<\/script>/, '')
        .replace('<link rel="stylesheet" href="ui.css">', '<style>' + css + '</style>')
        .replace(/<script src="config\.js"><\/script>/, ''),
    { runScripts:'outside-only', url:'https://x.test/movimientos.html', pretendToBeVisual:true });

  const w = dom.window;
  w.SUPABASE_CONFIG = { url:'https://x.supabase.co', key:'k' };
  Object.defineProperty(w.navigator, 'serviceWorker',
    { value:{ register: async () => ({}) }, configurable:true });
  w.matchMedia = () => ({ matches:false, addEventListener(){}, removeEventListener(){} });

  // El CSV se arma en un Blob; aqui se atrapa en vez de descargarlo.
  estado.csv = null;
  w.URL.createObjectURL = b => { estado.blob = b; return 'blob:x'; };
  w.URL.revokeObjectURL = () => {};
  w.HTMLAnchorElement.prototype.click = function(){ estado.descarga = this.download; };

  globalThis.window = w; globalThis.document = w.document;
  globalThis.localStorage = w.localStorage; globalThis.matchMedia = w.matchMedia;

  estado.llamadas = [];
  w.__sb = {
    auth:{ getSession: async () => ({ data:{ session:{ user:{ id:'u1' } } } }),
           signInWithPassword: async () => ({ error:null }),
           signOut: async () => {}, onAuthStateChange(){} },
    rpc: async (fn, args) => {
      estado.llamadas.push({ fn, args });
      const h = estado.rpc[fn];
      if (h === undefined) return { data:null, error:{ message:'sin simular: ' + fn } };
      return typeof h === 'function' ? h(args) : h;
    }
  };

  const menu = await import(BASE + 'menu.js');
  w.montarMenu = menu.montarMenu; w.escapar = menu.escapar;

  const prep = cuerpo
    .replace(/^import \{ createClient \} from 'https:\/\/esm\.sh\/@supabase\/supabase-js@2';$/m, '')
    .replace(/^import \{ montarMenu, escapar \} from '\.\/menu\.js';$/m, '')
    .replace(/createClient\(SUPABASE_URL, SUPABASE_KEY, \{[\s\S]*?\}\)/, '__sb');

  w.__m = {};
  await w.eval(`(async () => { ${prep}
    ; window.__m.S = S; window.__m.cargar = cargar; window.__m.armarCsv = armarCsv;
  })()`);
  await new Promise(r => setTimeout(r, 180));
  return { w, d:w.document, m:w.__m, estado };
}

const esperar = (ms = 120) => new Promise(r => setTimeout(r, ms));
const ultima = (e, fn) => [...e.llamadas].reverse().find(l => l.fn === fn);

const base = (rol = 'gerente', nivel = 3, extra = {}) => ({
  rpc:{
    fn_pos_contexto:{ data:CTX(rol, nivel, extra.sucs || 1), error:null },
    fn_inventario_por_fecha: a => ({ data: { ...INV(nivel >= 3),
      desde:a.p_desde, hasta:a.p_hasta }, error:null }),
    fn_kardex_producto: a => ({ data: KARDEX(nivel >= 3), error:null })
  } });

/* ===================================================================== */
console.log('\n=== QUIÉN ENTRA ===');
{
  const { d } = await montar(base('auxiliar', 1));
  chk('la auxiliar no entra', !d.querySelector('#p-bloqueado').classList.contains('oculto'));
  chk('y se le dice por qué', /supervisor o el gerente/.test(d.querySelector('#bl-texto').textContent));
}
{
  const { d } = await montar(base('repartidor', 0));
  chk('el repartidor tampoco', !d.querySelector('#p-bloqueado').classList.contains('oculto'));
}
{
  const { d, estado:e } = await montar(base('supervisor', 2));
  chk('el supervisor sí', !d.querySelector('#app').classList.contains('oculto'));
  chk('y lee al arrancar', !!ultima(e, 'fn_inventario_por_fecha'));
}

console.log('\n=== PERIODO · GERENTE ===');
{
  const { d, estado:e } = await montar(base());
  const a = ultima(e, 'fn_inventario_por_fecha').args;
  const hoy = new Date();
  const primero = `${hoy.getFullYear()}-${String(hoy.getMonth()+1).padStart(2,'0')}-01`;
  chk('arranca en el mes en curso', a.p_desde === primero);
  chk('hasta hoy', a.p_hasta >= a.p_desde);
  chk('en la sucursal del usuario', a.p_sucursal_id === 's1');
  chk('el atajo "Este mes" queda marcado',
      d.querySelector('.atajo.activo')?.textContent === 'Este mes');

  const cubos = d.querySelectorAll('.cubo');
  chk('cuatro cubos de la cuenta', cubos.length === 4);
  chk('empieza con L 1,140.00', /L 1,140\.00/.test(cubos[0].textContent));
  chk('entró L 650.00', /L 650\.00/.test(cubos[1].textContent));
  chk('salió L 191.40', /L 191\.40/.test(cubos[2].textContent));
  chk('terminó con L 1,598.60', /L 1,598\.60/.test(cubos[3].textContent));

  const tipos = [...d.querySelectorAll('.tipo')].map(t => t.textContent.replace(/\s+/g, ' '));
  chk('por tipo: primero lo que entra', /Compra/.test(tipos[0]) && /\+50/.test(tipos[0]));
  chk('luego lo que sale, en negativo', /Venta/.test(tipos[1]) && /−15/.test(tipos[1]));
  chk('con su valor para el gerente', /L 150\.00/.test(tipos[1]));

  const p1 = d.querySelector('[data-p="p1"]');
  chk('el producto: de 100 a 133', /100\s*→\s*133/.test(p1.textContent));
  chk('con lo que entró y salió', /\+50/.test(p1.textContent) && /−17/.test(p1.textContent));
  chk('y lo que vale al final', /L 1,458\.60/.test(p1.textContent));
  chk('el que no se movió se ve apagado',
      d.querySelector('[data-p="p3"]').classList.contains('quieto'));
  chk('el nombre raro se escapa, no se ejecuta',
      d.querySelector('[data-p="p2"] b').textContent.startsWith('=HYPERLINK'));
}

console.log('\n=== PERIODO · SUPERVISOR ===');
{
  const { d } = await montar(base('supervisor', 2));
  const t = d.querySelector('#cuerpo').textContent;
  chk('no aparece ni un lempira', !/L \d/.test(t));
  chk('cuenta productos y movimientos en vez de plata',
      /Se movieron/.test(t) && /Entradas/.test(t));
  chk('pero sí ve las cantidades',
      /100\s*→\s*133/.test(d.querySelector('[data-p="p1"]').textContent));
}

console.log('\n=== FILTROS ===');
{
  const { d, estado:e } = await montar(base());
  d.querySelector('[data-a="pasado"]').click();
  await esperar();
  const a = ultima(e, 'fn_inventario_por_fecha').args;
  const hoy = new Date();
  const ini = new Date(hoy.getFullYear(), hoy.getMonth() - 1, 1);
  const fin = new Date(hoy.getFullYear(), hoy.getMonth(), 0);
  const iso = x => `${x.getFullYear()}-${String(x.getMonth()+1).padStart(2,'0')}-${String(x.getDate()).padStart(2,'0')}`;
  chk('mes pasado: del 1', a.p_desde === iso(ini));
  chk('al último día', a.p_hasta === iso(fin));

  d.querySelector('#f-movidos').checked = true;
  d.querySelector('#f-movidos').dispatchEvent(new window.Event('change'));
  await esperar();
  chk('solo con movimiento viaja al servidor',
      ultima(e, 'fn_inventario_por_fecha').args.p_solo_movidos === true);

  const b = d.querySelector('#f-buscar');
  b.value = 'aceite';
  b.dispatchEvent(new window.Event('input'));
  await esperar(500);
  chk('la búsqueda viaja al servidor',
      ultima(e, 'fn_inventario_por_fecha').args.p_buscar === 'aceite');

  const n = e.llamadas.filter(l => l.fn === 'fn_inventario_por_fecha').length;
  d.querySelector('#f-desde').value = '2026-10-20';
  d.querySelector('#f-desde').dispatchEvent(new window.Event('change'));
  d.querySelector('#f-hasta').value = '2026-10-05';
  d.querySelector('#f-hasta').dispatchEvent(new window.Event('change'));
  await esperar();
  chk('fechas al revés: lo dice', /al revés/.test(d.querySelector('#cuerpo').textContent));
  chk('y no molesta al servidor por eso',
      e.llamadas.filter(l => l.fn === 'fn_inventario_por_fecha').length === n);
  chk('cambiar una fecha a mano desmarca el atajo', !d.querySelector('.atajo.activo'));
}
{
  const { d, estado:e } = await montar(base('gerente', 3, { sucs:2 }));
  chk('con dos sucursales aparece el selector',
      !d.querySelector('#f-sucursal').classList.contains('oculto'));
  const s = d.querySelector('#f-sucursal');
  s.value = 's2';
  s.dispatchEvent(new window.Event('change'));
  await esperar();
  chk('y cambiarla vuelve a leer esa sucursal',
      ultima(e, 'fn_inventario_por_fecha').args.p_sucursal_id === 's2');
  chk('y lo dice arriba', d.querySelector('#h-sucursal').textContent === 'Choloma');
}
{
  const { d } = await montar(base());
  chk('con una sola sucursal no estorba el selector',
      d.querySelector('#f-sucursal').classList.contains('oculto'));
}

console.log('\n=== EXISTENCIA AL DÍA ===');
{
  const { d, estado:e } = await montar(base());
  d.querySelector('[data-v="dia"]').click();
  await esperar();
  const a = ultima(e, 'fn_inventario_por_fecha').args;
  chk('pide un solo día', a.p_desde === a.p_hasta);
  chk('no filtra por movimiento (lo quieto también existe)', a.p_solo_movidos === false);
  chk('esconde la fecha final', d.querySelector('#f-hasta').classList.contains('oculto'));
  chk('y el interruptor de movidos', d.querySelector('#l-movidos').classList.contains('oculto'));
  chk('ofrece el cierre del mes pasado', !!d.querySelector('[data-a="cierre"]'));
  chk('solo lista lo que tenía existencia', d.querySelectorAll('.prod').length === 2);
  chk('y avisa cuántos en cero no se muestran',
      /1 en cero no se muestran/.test(d.querySelector('#cuerpo').textContent));
  chk('el total en lempiras del día', /L 1,598\.60/.test(d.querySelector('.ficha').textContent));

  d.querySelector('[data-a="cierre"]').click();
  await esperar();
  const hoy = new Date();
  const fin = new Date(hoy.getFullYear(), hoy.getMonth(), 0);
  const iso = `${fin.getFullYear()}-${String(fin.getMonth()+1).padStart(2,'0')}-${String(fin.getDate()).padStart(2,'0')}`;
  chk('cierre del mes pasado = su último día',
      ultima(e, 'fn_inventario_por_fecha').args.p_hasta === iso);
}

console.log('\n=== NO CUADRA ===');
{
  const estado = base();
  estado.rpc.fn_inventario_por_fecha = { data:INV(true, {
    totales:{ ...INV(true).totales, no_cuadran:1 },
    productos:[{ ...INV(true).productos[0], cuadra:false }] }), error:null };
  const { d } = await montar(estado);
  chk('el aviso arriba', /no cuadran/.test(d.querySelector('.aviso.malo')?.textContent || ''));
  chk('y el producto marcado', d.querySelector('[data-p="p1"]').classList.contains('descuadre'));
}

console.log('\n=== DEMASIADOS PRODUCTOS ===');
{
  const estado = base();
  estado.rpc.fn_inventario_por_fecha = { data:INV(true, { truncado:true, limite:500,
    totales:{ ...INV(true).totales, productos:812 } }), error:null };
  const { d } = await montar(estado);
  chk('avisa que hay más y cómo verlos',
      /primeros 500 productos de 812/.test(d.querySelector('#cuerpo').textContent.replace(/\s+/g, ' ')));
}

console.log('\n=== VACÍO Y ERROR ===');
{
  const estado = base();
  estado.rpc.fn_inventario_por_fecha = { data:INV(true, { productos:[], por_tipo:[] }), error:null };
  const { d } = await montar(estado);
  chk('sin movimientos lo dice', /Sin movimientos/.test(d.querySelector('#cuerpo').textContent));
}
{
  const estado = base();
  estado.rpc.fn_inventario_por_fecha = { data:null,
    error:{ message:'P0001: El periodo puede ser de un año como máximo' } };
  const { d } = await montar(estado);
  chk('el error del servidor se muestra limpio',
      /El periodo puede ser de un año como máximo/.test(d.querySelector('#cuerpo').textContent) &&
      !/P0001/.test(d.querySelector('#cuerpo').textContent));
}

console.log('\n=== KARDEX DE UN PRODUCTO ===');
{
  const { d, estado:e } = await montar(base());
  d.querySelector('[data-p="p1"]').click();
  await esperar();
  const a = ultima(e, 'fn_kardex_producto').args;
  chk('pide el producto tocado', a.p_producto_id === 'p1');
  chk('con las mismas fechas de la lista',
      a.p_desde === e.llamadas.find(l => l.fn === 'fn_inventario_por_fecha').args.p_desde);
  const h = d.querySelector('#hoja').textContent.replace(/\s+/g, ' ');
  chk('abre la hoja', !d.querySelector('#velo').classList.contains('oculto'));
  chk('la cuenta del producto', /Empezó\s*100/.test(h) && /Terminó\s*133/.test(h));
  chk('cada movimiento con su documento', /Venta · T-S01-00000042/.test(h) && /Compra · FC-881/.test(h));
  chk('quién lo hizo', /Ana/.test(h));
  chk('el lote', /lote L-OCT/.test(h));
  chk('lo que quedó después', /queda 90/.test(h) && /queda 140/.test(h));
  chk('la salida en negativo', d.querySelector('.mov-fin b.menos').textContent === '−10');
  chk('el gerente ve a cómo entró', /a L 13\.00 c\/u/.test(h));
  d.querySelector('#k-cerrar').click();
  chk('y se cierra', d.querySelector('#velo').classList.contains('oculto'));
}
{
  const { d } = await montar(base('supervisor', 2));
  d.querySelector('[data-p="p1"]').click();
  await esperar();
  chk('el supervisor no ve costos en el kardex', !/c\/u/.test(d.querySelector('#hoja').textContent));
}
{
  const { d, estado:e } = await montar(base());
  d.querySelector('[data-v="dia"]').click();
  await esperar();
  d.querySelector('[data-p="p1"]').click();
  await esperar();
  const a = ultima(e, 'fn_kardex_producto').args;
  chk('desde "al día" el kardex trae el mes hasta ese día',
      a.p_desde.endsWith('-01') && a.p_desde.slice(0, 7) === a.p_hasta.slice(0, 7));
}

console.log('\n=== CSV ===');
{
  const { d, m, estado:e } = await montar(base());
  const csv = m.armarCsv(m.S.datos, 'periodo');
  const lineas = csv.replace('﻿', '').split('\r\n');
  chk('lleva BOM para que Excel lea las tildes', csv.startsWith('﻿'));
  chk('separado por punto y coma', lineas[0].startsWith('Producto;SKU;Categoría'));
  chk('el gerente lleva valores', /Valor final/.test(lineas[0]));
  chk('una línea por producto', lineas.length === 4);
  chk('una fórmula no se cuela',
      lineas.some(l => l.startsWith(`"'=HYPERLINK(""x"")"`)));

  d.querySelector('#b-csv').click();
  chk('descarga con nombre de las fechas', /^movimientos-.*-a-.*\.csv$/.test(e.descarga || ''));
}
{
  const { m } = await montar(base('supervisor', 2));
  const csv = m.armarCsv(m.S.datos, 'periodo');
  chk('el CSV del supervisor no lleva valores', !/Valor/.test(csv));
}
{
  const { d, m } = await montar(base());
  d.querySelector('[data-v="dia"]').click();
  await esperar();
  const csv = m.armarCsv(m.S.datos, 'dia').split('\r\n');
  chk('al día: sin los que están en cero', csv.length === 3);
  chk('al día: columna de existencia', /Existencia/.test(csv[0]));
}

console.log(`\n${ok} bien · ${mal} mal`);
process.exit(mal ? 1 : 0);
