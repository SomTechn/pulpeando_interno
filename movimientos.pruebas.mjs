/* Prueba funcional de la pantalla de movimientos (control de inventario).

   Lo que se vigila aqui:
     · que la auxiliar no entre: el kardex es de supervisor para arriba
     · que la tabla traiga todas las columnas del control, en orden
     · que la diferencia (merma desconocida) se marque y se pueda filtrar
     · que el gerente vea costo y lempiras y el supervisor no
     · que escanear, buscar y elegir categoria viajen al servidor
     · que "al dia" pida una sola fecha y esconda lo que esta en cero
     · que el kardex de una fila se abra con los movimientos de ese dia
     · que el CSV salga con las mismas columnas y sin formulas de Excel
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

const FILA = (ve, o) => ({
  producto_id:'p1', dia:'2026-10-01', sku:'ACE500', barras:'7401234567890',
  nombre:'Aceite vegetal 500ml', unidad:'UND', categoria:'Aceites', departamento:'Abarrotes',
  costo: ve ? 10 : null, precio:18, inicial:100, compras:0, ventas:15, merma_dano:0,
  otros:0, teorico:85, ajustes:0, merma_desconocida_registrada:0, final:85, diferencia:0,
  movimientos:2, valor_diferencia: ve ? 0 : null, valor_merma_dano: ve ? 0 : null, ...o });

const CONTROL = (ve, porDia = true, extra = {}) => ({
  desde:'2026-10-01', hasta:'2026-10-05', por_dia:porDia, sucursal_id:'s1', sucursal:'Central',
  puede_ver_costos:ve,
  totales:{ filas:4, productos:1, con_diferencia:1, compras:50, ventas:15, merma_dano:2,
            ajustes:-3, diferencia:-4,
            valor_merma_dano: ve ? 22.22 : null, valor_ajustes: ve ? -33.33 : null,
            valor_diferencia: ve ? -44.44 : null, valor_ventas_costo: ve ? 150 : null },
  por_fecha:[
    { dia:'2026-10-03', productos:1, ajustes:0, merma_desconocida:0, merma_dano:2,
      valor_ajustes: ve ? 0 : null, valor_diferencia: ve ? 0 : null, valor_merma_dano: ve ? 22.22 : null },
    { dia:'2026-10-05', productos:1, ajustes:-3, merma_desconocida:1, merma_dano:0,
      valor_ajustes: ve ? -33.33 : null, valor_diferencia: ve ? -44.44 : null, valor_merma_dano: ve ? 0 : null } ],
  filas: porDia ? [
    FILA(ve, {}),
    FILA(ve, { dia:'2026-10-02', inicial:85, compras:50, ventas:0, teorico:135, final:135, costo: ve ? 11.11 : null }),
    FILA(ve, { dia:'2026-10-03', inicial:135, ventas:0, merma_dano:2, teorico:133, final:133, precio:20,
               valor_merma_dano: ve ? 22.22 : null }),
    FILA(ve, { dia:'2026-10-05', inicial:133, ventas:0, ajustes:-3, merma_desconocida_registrada:1,
               teorico:133, final:129, diferencia:-4, precio:20, valor_diferencia: ve ? -44.44 : null })
  ] : [
    FILA(ve, { dia:null, compras:50, merma_dano:2, ajustes:-3, teorico:133, final:129, diferencia:-4,
               precio:20, valor_diferencia: ve ? -44.44 : null }),
    FILA(ve, { producto_id:'p3', dia:null, sku:'ARR5', barras:null, nombre:'=HYPERLINK("x")',
               inicial:20, ventas:0, teorico:20, final:20 })
  ],
  hay_otros:false, truncado:false, limite:1500, ...extra });

const INV = ve => ({
  desde:'2026-10-09', hasta:'2026-10-09', sucursal_id:'s1', sucursal:'Central', puede_ver_costos:ve,
  totales:{ productos:3, con_movimiento:0, movimientos:0, no_cuadran:0, valor_final: ve ? 1598.6 : null },
  por_tipo:[],
  productos:[
    { producto_id:'p1', nombre:'Aceite vegetal 500ml', sku:'ACE500', unidad:'UND', categoria:'Aceites',
      final:129, ultimo:'2026-10-05T22:00:00Z', valor_final: ve ? 1458.6 : null },
    { producto_id:'p2', nombre:'Agua', sku:'AGU', unidad:'UND', categoria:null,
      final:0, ultimo:'2026-09-01T14:00:00Z', valor_final: ve ? 0 : null },
    { producto_id:'p3', nombre:'Arroz', sku:'ARR5', unidad:'UND', categoria:null,
      final:20, ultimo:'2026-09-15T18:00:00Z', valor_final: ve ? 140 : null } ],
  truncado:false, limite:500 });

const KARDEX = ve => ({
  producto_id:'p1', nombre:'Aceite vegetal 500ml', sku:'ACE500', unidad:'UND',
  sucursal_id:'s1', sucursal:'Central', desde:'2026-10-05', hasta:'2026-10-05',
  puede_ver_costos:ve, inicial:133, final:129, entradas:0, salidas:4,
  total_movimientos:2, truncado:false,
  movimientos:[
    { id:1, fecha:'2026-10-05T22:00:00Z', tipo:'ajuste_negativo', nombre_tipo:'Ajuste (faltante)',
      cantidad:-3, saldo:130, lote:null, documento_tipo:'conteo', documento:'CI-S01-0004',
      usuario:'Ana', notas:null, costo_unitario: ve ? 11.11 : null, costo_promedio: ve ? 11.11 : null },
    { id:2, fecha:'2026-10-06T00:00:00Z', tipo:'merma', nombre_tipo:'Merma',
      cantidad:-1, saldo:129, lote:null, documento_tipo:'merma', documento:'ME-S01-000007',
      usuario:'Kevin', notas:null, costo_unitario: ve ? 11.11 : null, costo_promedio: ve ? 11.11 : null } ]
});

const CATS = [
  { id:'c1', nombre:'Abarrotes', padre_id:null, es_departamento:true },
  { id:'c2', nombre:'Aceites', padre_id:'c1', es_departamento:false },
  { id:'c3', nombre:'Bebidas', padre_id:null, es_departamento:false } ];

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

  w.URL.createObjectURL = b => { estado.blob = b; return 'blob:x'; };
  w.URL.revokeObjectURL = () => {};
  w.HTMLAnchorElement.prototype.click = function(){ estado.descarga = this.download; };

  // escaner.js: la camara no existe en la prueba
  w.hayCamara = async () => estado.camara !== false;
  w.escanear = async () => estado.codigoEscaneado || null;

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
    .replace(/^import \{ escanear, hayCamara \} from '\.\/escaner\.js';$/m, '')
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
const plano = el => el.textContent.replace(/\s+/g, ' ').trim();

const base = (rol = 'gerente', nivel = 3, extra = {}) => ({
  rpc:{
    fn_pos_contexto:{ data:CTX(rol, nivel, extra.sucs || 1), error:null },
    fn_categorias_arbol:{ data:CATS, error:null },
    fn_control_inventario: a => ({ data:{ ...CONTROL(nivel >= 3, a.p_por_dia),
      desde:a.p_desde, hasta:a.p_hasta }, error:null }),
    fn_inventario_por_fecha: a => ({ data:{ ...INV(nivel >= 3), desde:a.p_desde, hasta:a.p_hasta }, error:null }),
    fn_kardex_producto: () => ({ data:KARDEX(nivel >= 3), error:null })
  } });

/* ===================================================================== */
console.log('\n=== QUIÉN ENTRA ===');
{
  const { d } = await montar(base('auxiliar', 1));
  chk('la auxiliar no entra', !d.querySelector('#p-bloqueado').classList.contains('oculto'));
}
{
  const { d } = await montar(base('repartidor', 0));
  chk('el repartidor tampoco', !d.querySelector('#p-bloqueado').classList.contains('oculto'));
}
{
  const { d, estado:e } = await montar(base('supervisor', 2));
  chk('el supervisor sí', !d.querySelector('#app').classList.contains('oculto'));
  chk('y arranca en el control', !!ultima(e, 'fn_control_inventario'));
}

console.log('\n=== LA TABLA · GERENTE ===');
{
  const { d, estado:e } = await montar(base());
  const a = ultima(e, 'fn_control_inventario').args;
  const hoy = new Date();
  chk('arranca en el mes en curso',
      a.p_desde === `${hoy.getFullYear()}-${String(hoy.getMonth()+1).padStart(2,'0')}-01`);
  chk('por día', a.p_por_dia === true);

  const cab = [...d.querySelectorAll('.control thead th')].map(plano);
  const esperado = ['Fecha', 'Descripción', 'Código', 'Código de barras', 'Costo', 'Precio retail',
    'Inv. inicial', 'Compras', 'Ventas', 'Merma por daño', 'Ajustes (conteos)', 'Inv. teórico',
    'Inv. final (sistema)', 'Merma desconocida', 'Merma desc. L'];
  chk('todas las columnas, en orden', JSON.stringify(cab) === JSON.stringify(esperado));
  chk('sin columna de traslados si no hubo', !cab.includes('Traslados / carga'));

  const filas = d.querySelectorAll('.control tbody tr');
  chk('una fila por día con movimiento', filas.length === 4);
  const c = [...filas[0].children].map(plano);
  chk('fecha legible', /1 oct/.test(c[0]));
  chk('descripción', c[1] === 'Aceite vegetal 500ml');
  chk('código y código de barras', c[2] === 'ACE500' && c[3] === '7401234567890');
  chk('costo y precio', c[4] === 'L 10.00' && c[5] === 'L 18.00');
  chk('100 − 15 = 85', c[6] === '100' && c[8] === '15' && c[11] === '85' && c[12] === '85');

  const malas = d.querySelectorAll('.control tr.mal');
  chk('solo el día con diferencia se marca', malas.length === 1);
  const m = [...malas[0].children].map(plano);
  chk('el 5: ajuste −3', m[10] === '−3');
  chk('teórico 133, sistema 129', m[11] === '133' && m[12] === '129');
  chk('merma desconocida −4 en rojo', m[13] === '−4' &&
      malas[0].children[13].classList.contains('neg'));
  chk('y su valor', m[14] === '−L 44.44');

  const pie = [...d.querySelectorAll('.control tfoot td')].map(plano);
  chk('fila de totales', pie[0] === 'Total');
  chk('total compras 50 y ventas 15', pie[7] === '50' && pie[8] === '15');
  chk('con un solo producto: de 100 a 129', pie[6] === '100' && pie[12] === '129');
  chk('teórico total 133, diferencia −4', pie[11] === '133' && pie[13] === '−4');

  const cubos = [...d.querySelectorAll('.cubo')].map(plano);
  chk('merma por daño en lempiras', /L 22\.22/.test(cubos[0]));
  chk('ajustes de conteos', /−L 33\.33/.test(cubos[1]));
  chk('merma desconocida', /−L 44\.44/.test(cubos[2]) &&
      d.querySelectorAll('.cubo')[2].classList.contains('desc'));

  const dias = [...d.querySelectorAll('.dia')].map(plano);
  chk('ajustes por día: dos días', dias.length === 2);
  chk('el 5 con ajuste y desconocida', /5 oct/.test(dias[1]) && /ajustes −3/.test(dias[1]) &&
      /desconocida −1/.test(dias[1]) && /−L 44\.44/.test(dias[1]));

  chk('la descripción queda fija al correr de lado',
      d.querySelector('.control tbody td.fija2') !== null && d.querySelector('.control tbody td.fija1') !== null);
}

console.log('\n=== LA TABLA · SUPERVISOR ===');
{
  const { d } = await montar(base('supervisor', 2));
  const cab = [...d.querySelectorAll('.control thead th')].map(plano);
  chk('sin columna de costo', !cab.includes('Costo'));
  chk('sin valor en lempiras', !cab.includes('Merma desc. L'));
  chk('pero sí el precio', cab.includes('Precio retail'));
  chk('los cubos en unidades', /−4 und/.test(plano(d.querySelectorAll('.cubo')[2])));
  chk('ni un costo en pantalla', !/L 10\.00/.test(d.querySelector('#cuerpo').textContent));
}

console.log('\n=== FILTROS ===');
{
  const { d, estado:e } = await montar(base());
  chk('el escáner aparece si hay cámara', !d.querySelector('#b-escanear').classList.contains('oculto'));

  e.codigoEscaneado = '7401234567890';
  d.querySelector('#b-escanear').click();
  await esperar();
  chk('lo escaneado viaja como búsqueda',
      ultima(e, 'fn_control_inventario').args.p_buscar === '7401234567890');
  chk('y queda escrito', d.querySelector('#f-buscar').value === '7401234567890');

  const b = d.querySelector('#f-buscar');
  b.value = 'ACE500';
  b.dispatchEvent(new window.KeyboardEvent('keydown', { key:'Enter' }));
  await esperar();
  chk('la pistola USB (Enter) busca de una vez',
      ultima(e, 'fn_control_inventario').args.p_buscar === 'ACE500');

  const opciones = [...d.querySelectorAll('#f-categoria option')].map(o => o.textContent.trim());
  chk('el departamento se ofrece completo', opciones.some(o => /Abarrotes · departamento completo/.test(o)));
  chk('con sus subcategorías debajo', opciones.includes('Aceites'));
  const s = d.querySelector('#f-categoria');
  s.value = 'c1';
  s.dispatchEvent(new window.Event('change'));
  await esperar();
  chk('elegir departamento viaja al servidor',
      ultima(e, 'fn_control_inventario').args.p_categoria_id === 'c1');

  d.querySelector('[data-m="periodo"]').click();
  await esperar();
  chk('periodo: una fila por producto', ultima(e, 'fn_control_inventario').args.p_por_dia === false);
  const cab = [...d.querySelectorAll('.control thead th')].map(plano);
  chk('periodo: sin columna de fecha', cab[0] === 'Descripción');
  chk('periodo: dos productos', d.querySelectorAll('.control tbody tr').length === 2);
  chk('el nombre raro se escapa',
      [...d.querySelectorAll('.desc-nom')].some(x => x.textContent.startsWith('=HYPERLINK')));
  const pie = [...d.querySelectorAll('.control tfoot td')].map(plano);
  chk('con varios productos no inventa inicial/final', pie[5] === '' && pie[11] === '');

  d.querySelector('#f-diferencia').checked = true;
  d.querySelector('#f-diferencia').dispatchEvent(new window.Event('change'));
  chk('solo con diferencia: queda el que tiene problema',
      d.querySelectorAll('.control tbody tr').length === 1 &&
      d.querySelector('.control tbody tr').classList.contains('mal'));
}
{
  const estado = base();
  estado.camara = false;
  const { d } = await montar(estado);
  chk('sin cámara no se ofrece el escáner', d.querySelector('#b-escanear').classList.contains('oculto'));
}
{
  const estado = base();
  estado.rpc.fn_categorias_arbol = { data:null, error:{ message:'Could not find the function' } };
  const { d } = await montar(estado);
  chk('sin categorías el filtro se esconde, la pantalla sigue',
      d.querySelector('#f-categoria').classList.contains('oculto') &&
      d.querySelectorAll('.control tbody tr').length === 4);
}
{
  const estado = base();
  estado.rpc.fn_control_inventario = a => ({ data:CONTROL(true, true, {
    hay_otros:true, filas:[FILA(true, { otros:24, teorico:109 })] }), error:null });
  const { d } = await montar(estado);
  const cab = [...d.querySelectorAll('.control thead th')].map(plano);
  chk('si hubo traslados aparece su columna', cab.includes('Traslados / carga'));
  chk('y la leyenda lo explica', /± traslados/.test(d.querySelector('.leyenda').textContent));
}
{
  const { d, estado:e } = await montar(base('gerente', 3, { sucs:2 }));
  const s = d.querySelector('#f-sucursal');
  chk('con dos sucursales aparece el selector', !s.classList.contains('oculto'));
  s.value = 's2';
  s.dispatchEvent(new window.Event('change'));
  await esperar();
  chk('y cambiarla vuelve a leer', ultima(e, 'fn_control_inventario').args.p_sucursal_id === 's2');
}
{
  const { d, estado:e } = await montar(base());
  const n = e.llamadas.filter(l => l.fn === 'fn_control_inventario').length;
  d.querySelector('#f-desde').value = '2026-10-20';
  d.querySelector('#f-desde').dispatchEvent(new window.Event('change'));
  d.querySelector('#f-hasta').value = '2026-10-05';
  d.querySelector('#f-hasta').dispatchEvent(new window.Event('change'));
  await esperar();
  chk('fechas al revés: lo dice sin molestar al servidor',
      /al revés/.test(d.querySelector('#cuerpo').textContent) &&
      e.llamadas.filter(l => l.fn === 'fn_control_inventario').length === n);
}

console.log('\n=== SIN DIFERENCIAS / VACÍO / ERROR ===');
{
  const estado = base();
  estado.rpc.fn_control_inventario = { data:CONTROL(true, true, {
    totales:{ ...CONTROL(true).totales, con_diferencia:0, diferencia:0, valor_diferencia:0 },
    filas:[FILA(true, {})], por_fecha:[] }), error:null };
  const { d } = await montar(estado);
  chk('todo cuadra: el cubo lo dice en verde',
      d.querySelectorAll('.cubo')[2].classList.contains('ok') &&
      /tiene explicación/.test(d.querySelectorAll('.cubo')[2].textContent));
  d.querySelector('#f-diferencia').checked = true;
  d.querySelector('#f-diferencia').dispatchEvent(new window.Event('change'));
  chk('y filtrando diferencias dice que no hay', /Ninguna diferencia/.test(d.querySelector('#cuerpo').textContent));
}
{
  const estado = base();
  estado.rpc.fn_control_inventario = { data:CONTROL(true, true, { filas:[], por_fecha:[] }), error:null };
  const { d } = await montar(estado);
  chk('sin movimientos lo dice', /Sin movimientos/.test(d.querySelector('#cuerpo').textContent));
}
{
  const estado = base();
  estado.rpc.fn_control_inventario = { data:null, error:{ message:
    'Could not find the function public.fn_control_inventario(p_buscar) in the schema cache' } };
  const { d } = await montar(estado);
  const t = d.querySelector('#cuerpo').textContent;
  chk('si falta la migración lo dice en español', /migraciones 025 y 026/.test(t) && !/Could not/.test(t));
}

console.log('\n=== EXISTENCIA AL DÍA ===');
{
  const { d, estado:e } = await montar(base());
  d.querySelector('[data-v="dia"]').click();
  await esperar();
  const a = ultima(e, 'fn_inventario_por_fecha').args;
  chk('pide un solo día', a.p_desde === a.p_hasta);
  chk('esconde la fecha final y las opciones del control',
      d.querySelector('#f-hasta').classList.contains('oculto') &&
      d.querySelector('#opciones').classList.contains('oculto'));
  chk('solo lista lo que tenía existencia', d.querySelectorAll('.prod').length === 2);
  chk('avisa los que están en cero', /1 en cero no se muestran/.test(d.querySelector('#cuerpo').textContent));
  chk('el total del día', /L 1,598\.60/.test(d.querySelector('.ficha').textContent));
}

console.log('\n=== KARDEX DE UNA FILA ===');
{
  const { d, estado:e } = await montar(base());
  d.querySelector('.control tr.mal').click();
  await esperar();
  const a = ultima(e, 'fn_kardex_producto').args;
  chk('abre el producto de la fila', a.p_producto_id === 'p1');
  chk('solo ese día', a.p_desde === '2026-10-05' && a.p_hasta === '2026-10-05');
  const h = plano(d.querySelector('#hoja'));
  chk('dice de qué día es', /el 5 oct 2026/.test(h));
  chk('el ajuste con su conteo y quién', /Ajuste \(faltante\) · CI-S01-0004/.test(h) && /Ana/.test(h));
  chk('la merma con su número', /Merma · ME-S01-000007/.test(h));
}
{
  const { d, estado:e } = await montar(base());
  d.querySelector('[data-m="periodo"]').click();
  await esperar();
  d.querySelector('.control tbody tr').click();
  await esperar();
  const a = ultima(e, 'fn_kardex_producto').args;
  chk('en periodo el kardex trae todo el periodo', a.p_desde !== a.p_hasta);
}

console.log('\n=== CSV ===');
{
  const { d, m, estado:e } = await montar(base());
  const lineas = m.armarCsv(m.S.datos, 'control').replace('﻿', '').split('\r\n');
  chk('BOM y punto y coma', m.armarCsv(m.S.datos, 'control').startsWith('﻿') &&
      lineas[0].startsWith('Fecha;Descripción;Código;Código de barras;Costo;Precio retail'));
  chk('lleva teórico, final y merma desconocida',
      /Inv\. teórico;Inv\. final \(sistema\);Merma desconocida/.test(lineas[0]));
  chk('y departamento y categoría al final', /Departamento;Categoría$/.test(lineas[0]));
  chk('una línea por fila', lineas.length === 5);
  d.querySelector('#b-csv').click();
  chk('nombre del archivo', /^control-inventario-.*\.csv$/.test(e.descarga || ''));
}
{
  const { d, m } = await montar(base());
  d.querySelector('[data-m="periodo"]').click();
  await esperar();
  const csv = m.armarCsv(m.S.datos, 'control');
  chk('una fórmula no se cuela', csv.includes(`"'=HYPERLINK(""x"")"`));
}
{
  const { m } = await montar(base('supervisor', 2));
  const csv = m.armarCsv(m.S.datos, 'control');
  chk('el CSV del supervisor no lleva costo', !/;Costo;/.test(csv) && !/Merma desc\. L/.test(csv));
}

console.log(`\n${ok} bien · ${mal} mal`);
process.exit(mal ? 1 : 0);
