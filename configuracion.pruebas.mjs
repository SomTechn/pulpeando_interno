/* Prueba funcional de Configuración: datos del negocio y del ticket, rangos
   de facturación (CAI), sucursales, cajas e impuestos.

   Lo que se vigila aqui:
     · que solo el gerente entre
     · que el RTN, el CAI y el prefijo se validen antes de ir al servidor
     · que la facturación no se encienda sin un rango vigente
     · que un rango usado no ofrezca borrarse
     · que el aviso de CAI por acabarse o vencido se vea
     · que solo quede un impuesto predeterminado
*/
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';

const BASE = fileURLToPath(new URL('./', import.meta.url));
let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };

const CTX = (nivel = 3) => ({
  usuario:{ id:'u1', nombre:'Somar', rol:nivel >= 3 ? 'gerente' : 'supervisor', nivel },
  organizacion:{ id:'o1', nombre:'Pulpería La Esquina', moneda:'HNL', factura_fiscal:false },
  sucursales:[{ id:'s1', nombre:'Central' }], cajas:[] });

function tablas(){
  return {
    organizaciones:{ id:'o1', nombre:'Pulpería La Esquina', identificacion_fiscal:null,
      facturacion_fiscal_activa:false, config:{ mensaje_ticket:'Vuelva pronto' }, moneda:'HNL' },
    sucursales:[{ id:'s1', codigo:'S01', nombre:'Central', direccion:'Col. Las Flores', telefono:'2669-0000',
      es_principal:true, activa:true, acepta_domicilio:true, costo_envio:25, pedido_minimo:100 },
      { id:'s2', codigo:'S02', nombre:'Choloma', direccion:null, telefono:null,
      es_principal:false, activa:true, acepta_domicilio:false, costo_envio:0, pedido_minimo:0 }],
    cajas:[{ id:'c1', sucursal_id:'s1', codigo:'C01', nombre:'Caja 1', activa:true }],
    impuestos:[{ id:'i0', nombre:'Exento', tasa:0, incluido_en_precio:true, es_predeterminado:false, activo:true },
               { id:'i1', nombre:'ISV 15%', tasa:0.15, incluido_en_precio:true, es_predeterminado:true, activo:true }]
  };
}

const RANGOS = () => [
  { id:'r1', sucursal_id:'s1', sucursal:'Central', tipo:'factura', cai:'A1B2C3-D4E5F6-A1B2C3-D4E5F6-A1B2C3-0F',
    prefijo:'000-001-01', inicial:1, final:500, siguiente:461, usadas:460, quedan:40,
    fecha_limite:'2026-12-31', dias:82, activa:true, vigente:true },
  { id:'r2', sucursal_id:'s1', sucursal:'Central', tipo:'factura', cai:'FFFFFF-FFFFFF-FFFFFF-FFFFFF-FFFFFF-FF',
    prefijo:'000-001-01', inicial:501, final:1000, siguiente:501, usadas:0, quedan:500,
    fecha_limite:'2027-06-30', dias:263, activa:true, vigente:true }
];

function desde(estado, tabla){
  const reg = { tabla, op:'select', filtros:[] };
  const q = {
    select(){ return q; }, order(){ return q; },
    eq(c, v){ reg.filtros.push([c, v]); return q; },
    single(){ reg.single = true; return q; },
    insert(d){ reg.op = 'insert'; reg.datos = d; estado.escrituras.push(reg); return q; },
    update(d){ reg.op = 'update'; reg.datos = d; estado.escrituras.push(reg); return q; },
    delete(){ reg.op = 'delete'; estado.escrituras.push(reg); return q; },
    then(res, rej){
      if (reg.op !== 'select'){
        const e = estado.errores?.[tabla + ':' + reg.op];
        return Promise.resolve({ data:null, error:e || null }).then(res, rej);
      }
      return Promise.resolve({ data:estado.tablas[tabla], error:null }).then(res, rej);
    }
  };
  return q;
}

async function montar(estado){
  const html = fs.readFileSync(BASE + 'configuracion.html', 'utf8');
  const cuerpo = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  const css = fs.readFileSync(BASE + 'ui.css', 'utf8');
  const dom = new JSDOM(
    html.replace(/<script type="module">[\s\S]*?<\/script>/, '')
        .replace('<link rel="stylesheet" href="ui.css">', '<style>' + css + '</style>')
        .replace(/<script src="config\.js"><\/script>/, ''),
    { runScripts:'outside-only', url:'https://x.test/configuracion.html', pretendToBeVisual:true });
  const w = dom.window;
  w.SUPABASE_CONFIG = { url:'https://x.supabase.co', key:'k' };
  Object.defineProperty(w.navigator, 'serviceWorker', { value:{ register: async () => ({}) }, configurable:true });
  w.matchMedia = () => ({ matches:false, addEventListener(){}, removeEventListener(){} });
  globalThis.window = w; globalThis.document = w.document;
  globalThis.localStorage = w.localStorage; globalThis.matchMedia = w.matchMedia;

  estado.escrituras = []; estado.llamadas = []; estado.impresos = [];
  w.__imprimir = async (d, o) => estado.impresos.push({ d, o });
  w.__sb = {
    auth:{ getSession: async () => ({ data:{ session:{ user:{ id:'u1' } } } }),
           signInWithPassword: async () => ({ error:null }), signOut: async () => {} },
    from: t => desde(estado, t),
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
    .replace(/^import \{ imprimirTicket \} from '\.\/ticket\.js';$/m, 'const imprimirTicket = window.__imprimir;')
    .replace(/createClient\(SUPABASE_URL, SUPABASE_KEY, \{[\s\S]*?\}\)/, '__sb');
  w.__m = {};
  await w.eval(`(async () => { ${prep}
    ; window.__m.S = S; window.__m.abrir = abrir;
  })()`);
  await new Promise(r => setTimeout(r, 150));
  return { w, d:w.document, m:w.__m, estado };
}

const esperar = (ms = 120) => new Promise(r => setTimeout(r, ms));
const txt = el => el.textContent.replace(/\s+/g, ' ').trim();
const escrito = (e, tabla, op) => e.escrituras.filter(x => x.tabla === tabla && x.op === op);

const base = (nivel = 3, rangos = RANGOS(), extra = {}) => ({
  tablas:tablas(),
  rpc:{ fn_pos_contexto:{ data:CTX(nivel), error:null },
        fn_estado_facturacion:{ data:{ activa:false, rangos }, error:null } },
  ...extra
});

const ir = async (d, v) => { d.querySelector(`[data-valor="${v}"]`).click(); await esperar(80); };
function teclear(w, el, v){ el.value = v; el.dispatchEvent(new w.Event('input', { bubbles:true })); }

/* ===================================================================== */
console.log('\n=== QUIÉN ENTRA ===');
{
  const { d } = await montar(base(2));
  chk('el supervisor no entra', !d.querySelector('#p-bloqueado').classList.contains('oculto'));
}
{
  const { d } = await montar(base());
  chk('el gerente sí', !d.querySelector('#app').classList.contains('oculto'));
  chk('con sus cuatro secciones', d.querySelectorAll('#menu-secciones [data-valor]').length === 4);
}

console.log('\n=== NEGOCIO Y TICKET ===');
{
  const estado = base();
  const { w, d } = await montar(estado);
  chk('trae lo guardado', d.querySelector('#n-nombre').value === 'Pulpería La Esquina' &&
      d.querySelector('#n-msj').value === 'Vuelva pronto');
  chk('80 mm por defecto', d.querySelector('#n-ancho .activo').dataset.a === '80');

  d.querySelector('#n-rtn').value = '0501-1990-1234';
  d.querySelector('#n-guardar').click();
  await esperar();
  chk('un RTN corto no se manda', !escrito(estado, 'organizaciones', 'update').length &&
      /14 dígitos/.test(d.querySelector('#hoja').textContent));
  d.querySelector('#ok').click();

  d.querySelector('#n-rtn').value = '0501-1990-123456';
  d.querySelector('#n-razon').value = 'Inversiones Mejía S. de R.L.';
  d.querySelector('#n-dir').value = 'Choloma, Cortés';
  d.querySelector('#n-ancho [data-a="58"]').click();
  d.querySelector('#n-guardar').click();
  await esperar();
  const u = escrito(estado, 'organizaciones', 'update')[0];
  chk('guarda el RTN sin guiones', u && u.datos.identificacion_fiscal === '05011990123456');
  chk('y lo del ticket en la configuración', u && u.datos.config.razon_social === 'Inversiones Mejía S. de R.L.' &&
      u.datos.config.direccion_fiscal === 'Choloma, Cortés' && u.datos.config.ancho_ticket === 58);
  chk('sin perder lo que ya había', u && u.datos.config.mensaje_ticket === 'Vuelva pronto');
  chk('no toca el plan ni la cuenta', u && !('plan' in u.datos) && !('activa' in u.datos));

  d.querySelector('#ok').click();
  d.querySelector('#n-prueba').click();
  await esperar(50);
  chk('imprime una prueba al ancho elegido', estado.impresos.length === 1 && estado.impresos[0].o.ancho === 58 &&
      estado.impresos[0].d.negocio.rtn === '05011990123456');
}

console.log('\n=== FACTURACIÓN ===');
{
  const estado = base();
  const { d } = await montar(estado);
  await ir(d, 'facturacion');
  const rangos = d.querySelectorAll('.rango');
  chk('los dos rangos', rangos.length === 2);
  chk('el que se acaba, en alerta', rangos[0].classList.contains('alerta') && /Por acabarse/.test(txt(rangos[0])));
  chk('dice cuántas quedan y la siguiente', /Quedan 40/.test(txt(rangos[0])) &&
      /Siguiente 000-001-01-00000461/.test(txt(rangos[0])));
  chk('un rango usado no se puede borrar', !rangos[0].querySelector('[data-borrar-rango]'));
  chk('uno sin usar sí', !!rangos[1].querySelector('[data-borrar-rango]'));

  d.querySelector('#f-activa').click();
  await esperar();
  const u = escrito(estado, 'organizaciones', 'update')[0];
  chk('con rango vigente se enciende la facturación', u && u.datos.facturacion_fiscal_activa === true);
  chk('y avisa la sucursal que no tiene rango', /Choloma no tiene rango vigente/.test(txt(d.querySelector('#cuerpo'))));
}
{
  const estado = base(3, []);
  const { d } = await montar(estado);
  await ir(d, 'facturacion');
  d.querySelector('#f-activa').click();
  await esperar();
  chk('sin rango no se enciende', !escrito(estado, 'organizaciones', 'update').length &&
      /Primero el rango/.test(d.querySelector('#hoja').textContent));
}
{
  const estado = base(3, [{ ...RANGOS()[0], quedan:0, vigente:false }]);
  const { d } = await montar(estado);
  await ir(d, 'facturacion');
  chk('un rango agotado se marca', /Agotado/.test(txt(d.querySelector('.rango'))) &&
      d.querySelector('.rango').classList.contains('malo'));
}
{
  const estado = base();
  const { w, d } = await montar(estado);
  await ir(d, 'facturacion');
  d.querySelector('#f-nuevo').click();
  await esperar(30);
  chk('con dos sucursales pregunta cuál', !!d.querySelector('#r-suc'));
  teclear(w, d.querySelector('#r-cai'), 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c30f');
  chk('el CAI se arma solo en grupos', d.querySelector('#r-cai').value === 'A1B2C3-D4E5F6-A1B2C3-D4E5F6-A1B2C3-0F');
  teclear(w, d.querySelector('#r-pre'), '00000201');
  chk('y el prefijo también', d.querySelector('#r-pre').value === '000-002-01');
  d.querySelector('#r-ini').value = '500'; d.querySelector('#r-fin').value = '100';
  d.querySelector('#r-lim').value = '2027-01-31';
  d.querySelector('#r-si').click();
  await esperar(30);
  chk('rango al revés no se manda', !escrito(estado, 'series_fiscales', 'insert').length &&
      /mayor o igual/.test(d.querySelector('#r-err').textContent));
  d.querySelector('#r-ini').value = '1'; d.querySelector('#r-fin').value = '250';
  d.querySelector('#r-suc').value = 's2';
  d.querySelector('#r-si').click();
  await esperar();
  const ins = escrito(estado, 'series_fiscales', 'insert')[0];
  chk('registra el rango completo', ins && ins.datos.cai === 'A1B2C3-D4E5F6-A1B2C3-D4E5F6-A1B2C3-0F' &&
      ins.datos.prefijo === '000-002-01' && ins.datos.correlativo_inicial === 1 &&
      ins.datos.correlativo_final === 250 && ins.datos.correlativo_actual === 1 &&
      ins.datos.fecha_limite_emision === '2027-01-31' && ins.datos.sucursal_id === 's2');
}
{
  const estado = base();
  const { w, d } = await montar(estado);
  await ir(d, 'facturacion');
  d.querySelector('#f-nuevo').click();
  await esperar(30);
  teclear(w, d.querySelector('#r-cai'), 'ZZZ');
  d.querySelector('#r-si').click();
  await esperar(30);
  chk('un CAI mal escrito se explica', /32 caracteres/.test(d.querySelector('#r-err').textContent));
}
{
  const estado = base(3, RANGOS(), { errores:{ 'series_fiscales:insert':
    { message:'P0001: Ese rango se encima con otro del mismo prefijo' } } });
  const { w, d } = await montar(estado);
  await ir(d, 'facturacion');
  d.querySelector('#f-nuevo').click();
  await esperar(30);
  teclear(w, d.querySelector('#r-cai'), 'A1B2C3D4E5F6A1B2C3D4E5F6A1B2C30F');
  teclear(w, d.querySelector('#r-pre'), '00000101');
  d.querySelector('#r-ini').value = '400'; d.querySelector('#r-fin').value = '600';
  d.querySelector('#r-lim').value = '2027-01-31';
  d.querySelector('#r-si').click();
  await esperar();
  chk('el error del servidor se muestra en la hoja', /se encima/.test(d.querySelector('#r-err').textContent));
}

console.log('\n=== SUCURSALES Y CAJAS ===');
{
  const estado = base();
  const { d } = await montar(estado);
  await ir(d, 'sucursales');
  const t = txt(d.querySelector('#cuerpo'));
  chk('las sucursales con su código', /Central · S01/.test(t) && /Choloma · S02/.test(t));
  chk('y el domicilio', /envío L 25\.00, mínimo L 100\.00/.test(t) && /No hace domicilio/.test(t));
  chk('las cajas debajo de su sucursal', /Caja 1/.test(t));

  d.querySelector('#s-nueva').click();
  await esperar(30);
  chk('el código de la nueva se propone', d.querySelector('#su-cod').value === 'S03');
  d.querySelector('#su-nom').value = 'Villanueva';
  d.querySelector('#su-si').click();
  await esperar();
  const ins = escrito(estado, 'sucursales', 'insert')[0];
  chk('crea la sucursal', ins && ins.datos.nombre === 'Villanueva' && ins.datos.codigo === 'S03' &&
      ins.datos.organizacion_id === 'o1');
}
{
  const estado = base();
  const { d } = await montar(estado);
  await ir(d, 'sucursales');
  d.querySelector('[data-nueva-caja="s2"]').click();
  await esperar(30);
  chk('caja nueva con nombre y código propuestos', d.querySelector('#c-nom').value === 'Caja 1' &&
      d.querySelector('#c-cod').value === 'C01');
  d.querySelector('#c-si').click();
  await esperar();
  const ins = escrito(estado, 'cajas', 'insert')[0];
  chk('crea la caja en esa sucursal', ins && ins.datos.sucursal_id === 's2' && ins.datos.codigo === 'C01');
}

console.log('\n=== IMPUESTOS ===');
{
  const estado = base();
  const { d } = await montar(estado);
  await ir(d, 'impuestos');
  chk('el predeterminado se marca', /ISV 15% 15% Predeterminado/.test(txt(d.querySelector('#cuerpo'))));
  d.querySelector('[data-pred="i0"]').click();
  await esperar();
  const ups = escrito(estado, 'impuestos', 'update');
  chk('primero apaga todos y luego enciende uno', ups.length === 2 &&
      ups[0].datos.es_predeterminado === false && ups[1].datos.es_predeterminado === true &&
      ups[1].filtros.some(([c, v]) => c === 'id' && v === 'i0'));
}
{
  const estado = base();
  const { d } = await montar(estado);
  await ir(d, 'impuestos');
  d.querySelector('[data-imp="i1"]').click();
  await esperar(30);
  chk('el predeterminado no se desactiva', !escrito(estado, 'impuestos', 'update').length &&
      /Elija otro como predeterminado/.test(d.querySelector('#hoja').textContent));
}
{
  const estado = base();
  const { d } = await montar(estado);
  await ir(d, 'impuestos');
  d.querySelector('#i-nuevo').click();
  await esperar(30);
  d.querySelector('#i-nom').value = 'ISV 18%';
  d.querySelector('#i-tasa').value = '18';
  d.querySelector('#i-si').click();
  await esperar();
  const ins = escrito(estado, 'impuestos', 'insert')[0];
  chk('la tasa se guarda como fracción', ins && ins.datos.tasa === 0.18 && ins.datos.incluido_en_precio === true);
}

console.log(`\n${ok} bien · ${mal} mal`);
process.exit(mal ? 1 : 0);
