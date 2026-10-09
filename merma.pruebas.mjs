/* Prueba funcional de la pantalla de merma.

   Lo que se vigila aqui:
     · que las dos mermas se midan y se vean POR SEPARADO
     · que el sobrante se reste de la desconocida y no se la coma entera
     · que solo el gerente apruebe, y que rechazar exija motivo
     · que la auxiliar no vea plata ni la pestaña de resumen
*/
import fs from 'node:fs';
import { JSDOM } from 'jsdom';

const BASE = '/home/claude/somtechn/pulpeando_interno/';
let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };

const CTX = (rol = 'gerente', nivel = 3) => ({
  usuario:{ id:'u1', nombre:'Somar', rol, nivel, tiene_pin:true },
  organizacion:{ id:'o1', nombre:'Pulpería Pulpeando', moneda:'HNL', factura_fiscal:false },
  sucursales:[{ id:'s1', nombre:'Central', codigo:'S01' }],
  cajas:[], impuesto_default:0, sin_sucursal:false });

const hace = h => new Date(Date.now() - h*3600000).toISOString();

const MERMAS = ve => [
  { merma_id:'m1', numero:'ME-S01-000003', estado:'pendiente', clase:'dano',
    causa:'Vencimiento', producto_id:'p1', producto:'Leche entera 1 L',
    sku:'LEC1L', unidad:'UND', lote:'L-ENE', vence:null,
    ubicacion:'Refrigerador', sucursal:'Central',
    cantidad:3, valor: ve ? 54.6 : null, notas:'Vencieron el martes',
    solicitado_por:'Ana', solicitado_en:hace(2),
    resuelto_por:null, resuelto_en:null, nota:null },
  { merma_id:'m2', numero:'ME-S01-000002', estado:'aprobado', clase:'desconocida',
    causa:'No se sabe, desapareció', producto_id:'p2', producto:'Azúcar 5 lb',
    sku:'AZU5LB', unidad:'UND', lote:null, vence:null,
    ubicacion:'Piso de ventas', sucursal:'Central',
    cantidad:2, valor: ve ? 90 : null, notas:null,
    solicitado_por:'Kevin', solicitado_en:hace(30),
    resuelto_por:'Somar', resuelto_en:hace(29), nota:null },
  { merma_id:'m3', numero:'ME-S01-000001', estado:'rechazado', clase:'dano',
    causa:'Quiebra o derrame', producto_id:'p3', producto:'Aceite 500 ml',
    sku:'ACE500', unidad:'UND', lote:null, vence:null,
    ubicacion:'Bodega', sucursal:'Central',
    cantidad:5, valor: ve ? 150 : null, notas:'Se cayó la caja',
    solicitado_por:'Kevin', solicitado_en:hace(80),
    resuelto_por:'Somar', resuelto_en:hace(79), nota:'Eso lo vi completo' }
];

const RESUMEN = {
  desde:'2026-10-01', hasta:'2026-10-09',
  dano:{ unidades:8, valor:320, por_causa:[
    { causa:'Vencimiento', unidades:5, valor:200 },
    { causa:'Quiebra o derrame', unidades:3, valor:120 } ] },
  desconocida:{ unidades:6, valor:240 },
  sobrante:{ unidades:1, valor:40 },
  desconocida_neta:200,
  total:520,
  venta:14800,
  porcentaje:3.51,
  pendientes:1,
  top:[
    { producto:'Leche entera 1 L', unidades:5, valor:200, clase:'dano' },
    { producto:'Azúcar 5 lb', unidades:2, valor:90, clase:'desconocida' } ]
};

async function montar(estado){
  const html = fs.readFileSync(BASE + 'merma.html', 'utf8');
  const cuerpo = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  const css = fs.readFileSync(BASE + 'ui.css', 'utf8');

  const dom = new JSDOM(
    html.replace(/<script type="module">[\s\S]*?<\/script>/, '')
        .replace('<link rel="stylesheet" href="ui.css">', '<style>' + css + '</style>')
        .replace(/<script src="config\.js"><\/script>/, ''),
    { runScripts:'outside-only', url:'https://x.test/merma.html', pretendToBeVisual:true });

  const w = dom.window;
  w.SUPABASE_CONFIG = { url:'https://x.supabase.co', key:'k' };
  Object.defineProperty(w.navigator, 'serviceWorker',
    { value:{ register: async () => ({}) }, configurable:true });
  w.matchMedia = () => ({ matches:false, addEventListener(){}, removeEventListener(){} });

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
    ; window.__m.S = S; window.__m.cargar = cargar;
  })()`);
  await new Promise(r => setTimeout(r, 180));
  return { w, d:w.document, m:w.__m, estado };
}

const esperar = (ms = 90) => new Promise(r => setTimeout(r, ms));

const base = (rol = 'gerente', nivel = 3, extra = {}) => ({
  rpc:{
    fn_pos_contexto:{ data:CTX(rol, nivel), error:null },
    fn_mermas: a => ({ data: a.p_estado === 'pendiente'
      ? MERMAS(nivel >= 2).filter(m => m.estado === 'pendiente')
      : MERMAS(nivel >= 2), error:null }),
    fn_merma_resumen:{ data:RESUMEN, error:null },
    fn_resolver_merma:{ data:{ numero:'ME-S01-000003', estado:'aprobado',
      producto:'Leche entera 1 L', cantidad:3, existencia_total:57,
      valor:54.6 }, error:null }
  }, ...extra });

/* ===================================================================== */
console.log('\n=== ARRANQUE ===');
{
  const estado = base();
  const { d, estado:e } = await montar(estado);
  chk('entra', !d.querySelector('#app').classList.contains('oculto'));
  chk('arranca en lo que hay que aprobar',
      d.querySelector('.pes.activo').textContent.includes('Por aprobar'));
  chk('y pide solo los pendientes',
      e.llamadas.find(l => l.fn === 'fn_mermas').args.p_estado === 'pendiente');
  chk('el globo dice cuántos', d.querySelector('.globo').textContent === '1');
  chk('en pendientes no estorban las fechas',
      d.querySelector('#fechas').classList.contains('oculto'));
}
{
  const estado = base('repartidor', 0);
  const { d } = await montar(estado);
  chk('el repartidor no entra', !d.querySelector('#p-bloqueado').classList.contains('oculto'));
}

console.log('\n=== POR APROBAR ===');
{
  const estado = base();
  const { d } = await montar(estado);
  chk('una sola merma pendiente', d.querySelectorAll('.mer').length === 1);
  const t = d.querySelector('.mer').textContent;
  chk('el producto', /Leche entera 1 L/.test(t));
  chk('la causa', /Vencimiento/.test(t));
  chk('de dónde sale', /Refrigerador/.test(t));
  chk('quién y cuándo', /Ana · hoy/.test(t));
  chk('lo que escribió', /Vencieron el martes/.test(t));
  chk('la cantidad en negativo', d.querySelector('.mer-fin b').textContent === '−3');
  chk('la clase se ve de un vistazo',
      d.querySelector('.sello.dano').textContent.trim() === 'Por daño');
  chk('el gerente puede aprobar y rechazar',
      !!d.querySelector('[data-aprobar]') && !!d.querySelector('[data-rechazar]'));
}
{
  const estado = base('auxiliar', 1);
  const { d } = await montar(estado);
  chk('la auxiliar ve la pendiente', d.querySelectorAll('.mer').length === 1);
  chk('pero no puede aprobarla', !d.querySelector('[data-aprobar]'));
  chk('y se le explica por qué',
      /El gerente las aprueba/.test(d.querySelector('#cuerpo').textContent));
  chk('ni ve cuánto vale', !/L /.test(d.querySelector('.mer-fin').textContent));
  chk('ni tiene pestaña de resumen', !d.querySelector('[data-v="resumen"]'));
}
{
  const estado = base('supervisor', 2);
  const { d } = await montar(estado);
  chk('el supervisor sí ve el valor',
      /L 54\.60/.test(d.querySelector('.mer-fin').textContent));
  chk('y sí tiene resumen', !!d.querySelector('[data-v="resumen"]'));
  chk('pero tampoco aprueba', !d.querySelector('[data-aprobar]'));
}

console.log('\n=== APROBAR Y RECHAZAR ===');
{
  const estado = base();
  const { d, estado:e } = await montar(estado);
  d.querySelector('[data-aprobar]').click();
  await esperar(180);
  const r = e.llamadas.find(l => l.fn === 'fn_resolver_merma');
  chk('aprueba en el servidor', r && r.args.p_aprobar === true);
  chk('dice cuánto se dio de baja', /Se dieron de baja 3/.test(d.querySelector('#hoja').textContent));
  chk('y cuánto queda', /57/.test(d.querySelector('#hoja').textContent));
  chk('y cuánto costó', /L 54\.60/.test(d.querySelector('#hoja').textContent));
  chk('vuelve a leer la lista',
      e.llamadas.filter(l => l.fn === 'fn_mermas').length >= 2);
}
{
  const estado = base();
  const { d, estado:e } = await montar(estado);
  d.querySelector('[data-rechazar]').click();
  await esperar();
  chk('rechazar abre su hoja', !!d.querySelector('#rz-motivo'));
  d.querySelector('#rz-si').click();
  await esperar();
  chk('exige el motivo',
      /Diga por qué se rechaza/.test(d.querySelector('#rz-error').textContent));
  chk('sin motivo no llama al servidor',
      !e.llamadas.some(l => l.fn === 'fn_resolver_merma'));
  d.querySelector('#rz-motivo').value = 'Eso lo vi completo';
  d.querySelector('#rz-si').click();
  await esperar(180);
  const r = e.llamadas.find(l => l.fn === 'fn_resolver_merma');
  chk('con motivo sí lo manda',
      r && r.args.p_aprobar === false && r.args.p_nota === 'Eso lo vi completo');
}
{
  const estado = base();
  estado.rpc.fn_resolver_merma = { data:null,
    error:{ message:'Ya no hay suficiente Leche entera 1 L para dar de baja' } };
  const { d } = await montar(estado);
  d.querySelector('[data-aprobar]').click();
  await esperar(180);
  chk('si ya no hay stock lo dice con palabras',
      /Ya no hay suficiente/.test(d.querySelector('#hoja').textContent));
}

console.log('\n=== HISTORIAL ===');
{
  const estado = base();
  const { d, estado:e } = await montar(estado);
  d.querySelector('[data-v="historial"]').click();
  await esperar(180);
  chk('pide todo el periodo',
      e.llamadas.filter(l => l.fn === 'fn_mermas').pop().args.p_estado === 'todos');
  chk('con fechas', !!e.llamadas.filter(l => l.fn === 'fn_mermas').pop().args.p_desde);
  chk('aparecen las fechas para cambiarlas',
      !d.querySelector('#fechas').classList.contains('oculto'));
  chk('las tres mermas', d.querySelectorAll('.mer').length === 3);
  chk('la rechazada se ve tachada',
      d.querySelectorAll('.mer')[2].classList.contains('rechazado'));
  chk('y dice por qué se rechazó',
      /Eso lo vi completo/.test(d.querySelectorAll('.mer')[2].textContent));
  chk('la desconocida lleva su sello',
      d.querySelectorAll('.mer')[1].querySelector('.sello.desconocida') !== null);
  // Desde el historial tambien se aprueba: ver una pendiente y tener que
  // cambiar de pestaña para tocarla no le sirve a nadie.
  chk('una pendiente también se aprueba desde el historial',
      d.querySelectorAll('[data-aprobar]').length === 1);
  chk('y solo esa, no las ya resueltas',
      d.querySelectorAll('.mer-acc').length === 1);
}

console.log('\n=== EL RESUMEN: LAS DOS MERMAS POR SEPARADO ===');
{
  const estado = base();
  const { d } = await montar(estado);
  d.querySelector('[data-v="resumen"]').click();
  await esperar(180);

  chk('dos baldes, no uno', d.querySelectorAll('.balde').length === 2);
  const dano = d.querySelector('.balde.dano');
  const desc = d.querySelector('.balde.desc');
  chk('el de daño con su monto', /L 320\.00/.test(dano.textContent));
  chk('y sus unidades', /8 unidades/.test(dano.textContent));
  chk('el desconocido muestra la NETA, no la bruta',
      /L 200\.00/.test(desc.textContent) && !/L 240\.00/.test(desc.querySelector('b').textContent));
  chk('y explica que le restó el sobrante',
      /menos L 40\.00 de sobrante/.test(desc.textContent));
  chk('el total suma los dos', /L 520\.00/.test(d.querySelector('.totalote').textContent));
  chk('y lo pone contra la venta',
      /3\.51% de la venta/.test(d.querySelector('.totalote').textContent));
  chk('el periodo en palabras',
      /1 oct 2026 al 9 oct 2026/.test(d.querySelector('.totalote').textContent));

  chk('desglosa las causas del daño', d.querySelectorAll('.causa').length >= 2);
  chk('la causa más cara primero',
      /Vencimiento/.test(d.querySelectorAll('.causa')[0].textContent));
  chk('los productos que más se pierden',
      /Los que más se pierden/.test(d.querySelector('#cuerpo').textContent));
  chk('explica la diferencia entre las dos',
      /no se registra: sale[\s\S]*de la resta/.test(d.querySelector('#cuerpo').textContent));
}
{
  // Sin sobrante no se inventa la frase
  const estado = base();
  estado.rpc.fn_merma_resumen = { data:{ ...RESUMEN,
    sobrante:{ unidades:0, valor:0 }, desconocida_neta:240, total:560 }, error:null };
  const { d } = await montar(estado);
  d.querySelector('[data-v="resumen"]').click();
  await esperar(180);
  chk('sin sobrante no habla de sobrante',
      !/de sobrante/.test(d.querySelector('.balde.desc').textContent));
  chk('y la neta es la bruta', /L 240\.00/.test(d.querySelector('.balde.desc').textContent));
}
{
  // Un negocio sin ventas en el periodo: nada de dividir entre cero
  const estado = base();
  estado.rpc.fn_merma_resumen = { data:{ ...RESUMEN, venta:0, porcentaje:null }, error:null };
  const { d } = await montar(estado);
  d.querySelector('[data-v="resumen"]').click();
  await esperar(180);
  chk('sin ventas no muestra porcentaje', !d.querySelector('.pct'));
  chk('pero sí el total', /L 520\.00/.test(d.querySelector('.totalote').textContent));
}
{
  // Un mes limpio
  const estado = base();
  estado.rpc.fn_merma_resumen = { data:{ ...RESUMEN,
    dano:{ unidades:0, valor:0, por_causa:[] },
    desconocida:{ unidades:0, valor:0 }, sobrante:{ unidades:0, valor:0 },
    desconocida_neta:0, total:0, porcentaje:0, top:[] }, error:null };
  const { d } = await montar(estado);
  d.querySelector('[data-v="resumen"]').click();
  await esperar(180);
  chk('un mes sin merma se ve en cero',
      /L 0\.00/.test(d.querySelector('.balde.dano').textContent));
  chk('y no inventa tarjetas de causas',
      !/Por qué se dañó/.test(d.querySelector('#cuerpo').textContent));
}

{
  // Lo que destapo el dato real: el sobrante puede superar a la desconocida.
  const estado = base();
  estado.rpc.fn_merma_resumen = { data:{ ...RESUMEN,
    desconocida:{ unidades:0, valor:0 }, sobrante:{ unidades:16, valor:1053.65 },
    desconocida_neta:0, total:320 }, error:null };
  const { d } = await montar(estado);
  d.querySelector('[data-v="resumen"]').click();
  await esperar(180);
  const desc = d.querySelector('.balde:nth-child(2)');
  chk('con mas sobrante que faltante no dice "0 de menos, menos L1053"',
      !/unidades contadas de menos/.test(desc.textContent));
  chk('dice que encontraron de MÁS', /de <b>más<\/b>|de más/.test(desc.innerHTML));
  chk('y cuanto de mas', /L 1,053\.65/.test(desc.textContent));
  chk('deja de pintarlo como alarma roja', !desc.classList.contains('desc'));
  chk('y explica que hay que revisar las compras',
      /revisar las últimas compras/.test(d.querySelector('#cuerpo').textContent));
}

console.log('\n=== LISTAS VACÍAS ===');
{
  const estado = base();
  estado.rpc.fn_mermas = { data:[], error:null };
  const { d } = await montar(estado);
  chk('sin pendientes lo dice y explica dónde se registran',
      /Nada esperando/.test(d.querySelector('#cuerpo').textContent) &&
      /desde Consultar/.test(d.querySelector('#cuerpo').textContent));
  chk('y no pinta el globo', !d.querySelector('.globo'));
}

console.log(`\n${ok} bien · ${mal} mal`);
process.exit(mal ? 1 : 0);
