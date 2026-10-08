/* Prueba funcional de la pantalla de conteo. */
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

const LINEAS_SUP = [
  { linea_id:'l1', producto_id:'p1', producto:'Arroz 5lb', sku:'P1', categoria:'Abarrotes',
    lote_id:null, lote:null, vence:null, unidad:'unidad',
    contada:48, sistema:50, diferencia:-2, valor_dif:-80,
    contado_por:'Ana', contado_en:new Date().toISOString(), nota:null },
  { linea_id:'l2', producto_id:'p2', producto:'Azúcar 2lb', sku:'P2', categoria:'Abarrotes',
    lote_id:null, lote:null, vence:null, unidad:'unidad',
    contada:23, sistema:20, diferencia:3, valor_dif:45,
    contado_por:'Ana', contado_en:new Date().toISOString(), nota:null },
  { linea_id:'l3', producto_id:'p3', producto:'Leche litro', sku:'P3', categoria:'Lácteos',
    lote_id:'lo1', lote:'L-ENE', vence:new Date(Date.now()+8*86400000).toISOString().slice(0,10),
    unidad:'unidad', contada:null, sistema:null, diferencia:null, valor_dif:null,
    contado_por:null, contado_en:null, nota:null },
  { linea_id:'l4', producto_id:'p3', producto:'Leche litro', sku:'P3', categoria:'Lácteos',
    lote_id:'lo2', lote:'L-FEB', vence:new Date(Date.now()+40*86400000).toISOString().slice(0,10),
    unidad:'unidad', contada:12, sistema:12, diferencia:0, valor_dif:0,
    contado_por:'Ana', contado_en:new Date().toISOString(), nota:null }
];
// lo mismo visto por una auxiliar: sin sistema ni diferencia
const LINEAS_AUX = LINEAS_SUP.map(l => ({ ...l, sistema:null, diferencia:null, valor_dif:null }));

const RESUMEN_SUP = { conteo_id:'c1', numero:'C-S01-000001', estado:'abierto',
  alcance:'general', notas:'Conteo del lunes', sucursal:'Central', categoria:null,
  proveedor:null, abierto_por:'Somar', abierto_en:new Date().toISOString(),
  cerrado_por:null, cerrado_en:null, motivo_cancelacion:null,
  lineas:4, contadas:3, pendientes:1, con_diferencia:2, sobrantes:1, faltantes:1,
  valor_diferencia:-35, valor_aplicado:null };
const RESUMEN_AUX = { ...RESUMEN_SUP, con_diferencia:null, sobrantes:null,
  faltantes:null, valor_diferencia:null };

const CONTEOS = [
  { conteo_id:'c1', numero:'C-S01-000001', estado:'abierto', alcance:'general',
    detalle:'Todo el inventario', sucursal:'Central', abierto_por:'Somar',
    abierto_en:new Date().toISOString(), cerrado_en:null, lineas:4, contadas:3, valor:null },
  { conteo_id:'c0', numero:'C-S01-000000', estado:'aplicado', alcance:'categoria',
    detalle:'Abarrotes', sucursal:'Central', abierto_por:'Somar',
    abierto_en:new Date(Date.now()-86400000).toISOString(),
    cerrado_en:new Date(Date.now()-86000000).toISOString(), lineas:9, contadas:9, valor:-120 }
];

async function montar(estado){
  const html = fs.readFileSync(BASE + 'conteo.html', 'utf8');
  const cuerpo = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  const css = fs.readFileSync(BASE + 'ui.css', 'utf8');

  const dom = new JSDOM(
    html.replace(/<script type="module">[\s\S]*?<\/script>/, '')
        .replace('<link rel="stylesheet" href="ui.css">', '<style>' + css + '</style>')
        .replace(/<script src="config\.js"><\/script>/, ''),
    { runScripts:'outside-only', url:'https://x.test/conteo.html', pretendToBeVisual:true });

  const w = dom.window;
  w.SUPABASE_CONFIG = { url:'https://x.supabase.co', key:'k' };
  Object.defineProperty(w.navigator, 'serviceWorker',
    { value:{ register: async () => ({}) }, configurable:true });
  w.matchMedia = () => ({ matches:false, addEventListener(){}, removeEventListener(){} });

  globalThis.window = w; globalThis.document = w.document;
  globalThis.localStorage = w.localStorage; globalThis.matchMedia = w.matchMedia;

  estado.llamadas = [];
  const tabla = nombre => {
    const q = { select(){ return q; }, eq(){ return q; },
      order(){ return Promise.resolve({ data:estado.tablas?.[nombre] || [], error:null }); },
      then(r){ return Promise.resolve({ data:estado.tablas?.[nombre] || [], error:null }).then(r); } };
    return q;
  };
  w.__sb = {
    auth:{ getSession: async () => ({ data:{ session:{ user:{id:'u1'} } } }),
           signInWithPassword: async () => ({ error:null }),
           signOut: async () => {}, onAuthStateChange(){} },
    from: tabla,
    rpc: async (fn, args) => {
      estado.llamadas.push({ fn, args });
      const h = estado.rpc[fn];
      if (h === undefined) return { data:null, error:{ message:'sin simular: ' + fn } };
      return typeof h === 'function' ? h(args) : h;
    }
  };

  const menu = await import(BASE + 'menu.js');
  w.montarMenu = menu.montarMenu; w.escapar = menu.escapar;
  w.escanear = async () => estado.codigo || null;
  w.hayCamara = () => !!estado.camara;

  const prep = cuerpo
    .replace(/^import \{ createClient \} from 'https:\/\/esm\.sh\/@supabase\/supabase-js@2';$/m, '')
    .replace(/^import \{ montarMenu, escapar \} from '\.\/menu\.js';$/m, '')
    .replace(/^import \{ escanear, hayCamara \} from '\.\/escaner\.js';$/m, '')
    .replace(/createClient\(SUPABASE_URL, SUPABASE_KEY, \{[\s\S]*?\}\)/, '__sb');

  w.__caja = {};
  await w.eval(`(async () => { ${prep}
    ; window.__caja.S = S; window.__caja.abrirConteo = abrirConteo;
    ; window.__caja.cargarLista = cargarLista;
  })()`);
  await new Promise(r => setTimeout(r, 140));
  return { w, d:w.document, caja:w.__caja, estado };
}

const esperar = (ms = 70) => new Promise(r => setTimeout(r, ms));

const base = (rol = 'gerente', nivel = 3, extra = {}) => ({
  camara:false, tablas:{ categorias:[{id:'cat1',nombre:'Abarrotes'}],
                         proveedores:[{id:'pv1',nombre:'Distribuidora'}] },
  rpc:{
    fn_pos_contexto:{ data:CTX(rol, nivel), error:null },
    fn_conteos:{ data:CONTEOS, error:null },
    fn_conteo_resumen:{ data: nivel >= 2 ? RESUMEN_SUP : RESUMEN_AUX, error:null },
    fn_conteo_lineas:{ data: nivel >= 2 ? LINEAS_SUP : LINEAS_AUX, error:null },
    fn_abrir_conteo:{ data:{ conteo_id:'c1', numero:'C-S01-000001', lineas:4,
                             sucursal:'Central' }, error:null },
    fn_contar:{ data:{ linea_id:'l3', contado:5, sistema:6, diferencia:-1 }, error:null },
    fn_aplicar_conteo:{ data:{ numero:'C-S01-000001', sobrantes:1, faltantes:1,
                               sin_cambio:1, sin_contar:1, valor_diferencia:-35 }, error:null },
    fn_cancelar_conteo:{ data:null, error:null }
  }, ...extra });

/* ===================================================================== */
console.log('\n=== LA LISTA DE CONTEOS ===');
{
  const estado = base();
  const { d } = await montar(estado);
  chk('entra', !d.querySelector('#app').classList.contains('oculto'));
  chk('pide los conteos', estado.llamadas.some(l => l.fn === 'fn_conteos'));
  chk('pinta los dos', d.querySelectorAll('.fila').length === 2);
  chk('marca el abierto', /abierto/.test(d.querySelector('.sello-c').textContent));
  chk('avisa que hay uno abierto',
      /Hay un conteo abierto/.test(d.querySelector('.aviso').textContent));
  chk('dice cuántos lleva contados', /3 de 4/.test(d.querySelector('#zona').textContent));
  chk('el aplicado dice que falta y cuánto',
      /Falta L 120\.00/.test(d.querySelectorAll('.fila')[1].textContent));
  chk('con uno abierto no ofrece empezar otro', !d.querySelector('#btn-nuevo'));
}

console.log('\n=== QUIÉN PUEDE EMPEZAR UNO ===');
for (const [rol, nivel, puede] of [['auxiliar',1,false], ['supervisor',2,true],
                                   ['gerente',3,true]]){
  const estado = base(rol, nivel);
  estado.rpc.fn_conteos = { data:[], error:null };
  const { d } = await montar(estado);
  chk(rol + (puede ? ' sí' : ' no') + ' puede empezar un conteo',
      !!d.querySelector('#btn-nuevo') === puede);
  if (!puede)
    chk('  ...y se le dice a quién pedírselo',
        /su supervisor/.test(d.querySelector('.vacio').textContent));
}

console.log('\n=== EMPEZAR UN CONTEO ===');
{
  const estado = base();
  estado.rpc.fn_conteos = { data:[], error:null };
  const { d, caja } = await montar(estado);
  d.querySelector('#btn-nuevo').click();
  await esperar();
  chk('pregunta el alcance', !d.querySelector('#velo').classList.contains('oculto'));
  chk('explica que se puede seguir vendiendo',
      /se puede seguir vendiendo/.test(d.querySelector('#hoja').textContent));
  chk('y que lo vendido después no se pierde',
      /no se pierde/.test(d.querySelector('#hoja').textContent));
  chk('la categoría está escondida al inicio',
      d.querySelector('#caja-cat').classList.contains('oculto'));

  d.querySelector('#al-alcance').value = 'categoria';
  d.querySelector('#al-alcance').dispatchEvent(new (d.defaultView.Event)('change'));
  chk('al elegir categoría aparece el selector',
      !d.querySelector('#caja-cat').classList.contains('oculto'));
  chk('y el de proveedor sigue escondido',
      d.querySelector('#caja-pro').classList.contains('oculto'));

  d.querySelector('#al-notas').value = 'Conteo del lunes';
  d.querySelector('#al-si').click();
  await esperar(140);
  const a = estado.llamadas.find(l => l.fn === 'fn_abrir_conteo');
  chk('abre con el alcance elegido', a?.args?.p_alcance === 'categoria');
  chk('manda la categoría', a?.args?.p_categoria_id === 'cat1');
  chk('no manda proveedor', a?.args?.p_proveedor_id === null);
  chk('manda la nota', a?.args?.p_notas === 'Conteo del lunes');
  chk('y entra a contar', caja.S.vista === 'contando');
}

console.log('\n=== CONTANDO: lo que ve el SUPERVISOR ===');
{
  const estado = base('supervisor', 2);
  const { d, caja } = await montar(estado);
  await caja.abrirConteo('c1');
  await esperar(120);

  chk('pinta una línea por producto y lote',
      d.querySelectorAll('.linea').length === 4);
  chk('la leche sale dos veces, una por lote',
      [...d.querySelectorAll('.linea')].filter(l => /Leche/.test(l.textContent)).length === 2);
  chk('se ve el código del lote', /L-ENE/.test(d.querySelector('#lista').textContent));
  chk('y la fecha de vencimiento', /vence/.test(d.querySelector('#lista').textContent));
  chk('el que vence pronto se marca', !!d.querySelector('.vence-pronto'));

  chk('ve la diferencia', /-2/.test(d.querySelectorAll('.linea')[0].textContent));
  chk('y lo que decía el sistema',
      /sistema 50/.test(d.querySelectorAll('.linea')[0].textContent));
  chk('el que cuadra lo dice',
      [...d.querySelectorAll('.linea')].some(l => /cuadra/.test(l.textContent)));
  chk('la línea con diferencia se resalta',
      d.querySelectorAll('.linea')[0].classList.contains('difiere'));
  chk('la que cuadra se marca distinto',
      d.querySelectorAll('.linea')[3].classList.contains('contada'));

  const tjs = d.querySelectorAll('.tj');
  chk('muestra cuántos lleva', /3 de 4/.test(tjs[0].textContent));
  chk('cuántos faltan', /1/.test(tjs[1].textContent));
  chk('cuántos difieren', [...tjs].some(t => /Con diferencia/.test(t.textContent)));
  chk('dice que falta, en palabras y sin signo',
      [...tjs].some(t => /Falta/.test(t.textContent) && /L 35\.00/.test(t.textContent)
                         && !/-35/.test(t.textContent)));
  chk('y en rojo',
      [...tjs].some(t => /Falta/.test(t.textContent) && t.classList.contains('malo')));

  chk('el supervisor puede cancelar', !!d.querySelector('#btn-cancelar'));
  chk('pero NO aplicar', !d.querySelector('#btn-aplicar'));
}

console.log('\n=== CONTANDO: lo que ve la AUXILIAR (conteo ciego) ===');
{
  const estado = base('auxiliar', 1);
  const { d, caja } = await montar(estado);
  await caja.abrirConteo('c1');
  await esperar(120);

  chk('ve las líneas', d.querySelectorAll('.linea').length === 4);
  chk('pero NO ve el sistema',
      !/sistema/.test(d.querySelector('#lista').textContent));
  chk('ni la diferencia', !d.querySelector('.dif.mas') && !d.querySelector('.dif.menos'));
  chk('ni la tarjeta de diferencias',
      ![...d.querySelectorAll('.tj')].some(t => /Con diferencia/.test(t.textContent)));
  chk('ni cuánto vale',
      ![...d.querySelectorAll('.tj')].some(t => /Vale/.test(t.textContent)));
  chk('no le ofrecen el filtro de diferencias', !d.querySelector('[data-f="diferencias"]'));
  chk('no puede cancelar', !d.querySelector('#btn-cancelar'));
  chk('ni aplicar', !d.querySelector('#btn-aplicar'));
  chk('pero sí puede escribir cantidades',
      [...d.querySelectorAll('input[data-prod]')].every(i => !i.disabled));
}

console.log('\n=== CONTAR UN PRODUCTO ===');
{
  const estado = base('supervisor', 2);
  const { d, caja } = await montar(estado);
  await caja.abrirConteo('c1');
  await esperar(120);

  const campo = [...d.querySelectorAll('input[data-prod]')]
    .find(i => i.dataset.lote === 'lo1');
  campo.value = '5';
  campo.dispatchEvent(new (d.defaultView.Event)('change'));
  await esperar(140);

  const c = estado.llamadas.find(l => l.fn === 'fn_contar');
  chk('manda la cuenta', !!c);
  chk('del producto correcto', c?.args?.p_producto_id === 'p3');
  chk('y del lote correcto', c?.args?.p_lote_id === 'lo1');
  chk('con la cantidad', c?.args?.p_cantidad === 5);
  chk('y recarga para ver la diferencia',
      estado.llamadas.filter(l => l.fn === 'fn_conteo_lineas').length >= 2);

  // sin lote
  const sinLote = [...d.querySelectorAll('input[data-prod]')]
    .find(i => i.dataset.lote === '');
  sinLote.value = '7';
  sinLote.dispatchEvent(new (d.defaultView.Event)('change'));
  await esperar(140);
  const c2 = [...estado.llamadas].reverse().find(l => l.fn === 'fn_contar');
  chk('un producto sin lote manda lote nulo', c2?.args?.p_lote_id === null);

  // vacío no manda nada
  const antes = estado.llamadas.filter(l => l.fn === 'fn_contar').length;
  sinLote.value = '';
  sinLote.dispatchEvent(new (d.defaultView.Event)('change'));
  await esperar(80);
  chk('dejarlo en blanco no manda nada',
      estado.llamadas.filter(l => l.fn === 'fn_contar').length === antes);

  // negativo
  sinLote.value = '-3';
  sinLote.dispatchEvent(new (d.defaultView.Event)('change'));
  await esperar(80);
  chk('un negativo no se manda',
      estado.llamadas.filter(l => l.fn === 'fn_contar').length === antes);
  chk('y se avisa', /No puede ser negativo/.test(d.querySelector('#hoja').textContent));
}

console.log('\n=== FILTROS Y ESCÁNER ===');
{
  const estado = base('supervisor', 2);
  estado.camara = true; estado.codigo = '7501234567890';
  const { d, caja } = await montar(estado);
  await caja.abrirConteo('c1');
  await esperar(120);

  chk('con cámara aparece el botón de escanear', !!d.querySelector('#btn-camara'));

  d.querySelector('[data-f="pendientes"]').click();
  await esperar(90);
  let u = [...estado.llamadas].reverse().find(l => l.fn === 'fn_conteo_lineas');
  chk('el filtro de pendientes va al servidor', u?.args?.p_solo_pendientes === true);

  d.querySelector('[data-f="diferencias"]').click();
  await esperar(90);
  u = [...estado.llamadas].reverse().find(l => l.fn === 'fn_conteo_lineas');
  chk('y el de diferencias también', u?.args?.p_solo_diferencias === true);

  d.querySelector('#btn-camara').click();
  await esperar(140);
  u = [...estado.llamadas].reverse().find(l => l.fn === 'fn_conteo_lineas');
  chk('escanear busca por el código', u?.args?.p_buscar === '7501234567890');
}

console.log('\n=== APLICAR ===');
{
  const estado = base('gerente', 3);
  const { d, caja } = await montar(estado);
  await caja.abrirConteo('c1');
  await esperar(120);

  chk('el gerente sí ve aplicar', !!d.querySelector('#btn-aplicar'));
  d.querySelector('#btn-aplicar').click();
  await esperar(70);

  const h = d.querySelector('#hoja').textContent;
  chk('avisa de los que faltan por contar', /1 productos sin contar/.test(h));
  chk('y que esos no se tocan', /no se tocan/.test(h));
  chk('muestra sobrantes y faltantes', /Sobrantes/.test(h) && /Faltantes/.test(h));
  chk('y lo que falta, en palabras', /Falta/.test(h) && /L 35\.00/.test(h));
  chk('con faltante advierte antes de aplicar',
      /vale la pena revisar/.test(h));

  d.querySelector('#ap-si').click();
  await esperar(180);
  chk('aplica', estado.llamadas.some(l => l.fn === 'fn_aplicar_conteo'));
  chk('y cuenta el resultado en palabras',
      /1 productos subieron/.test(d.querySelector('#hoja').textContent));
  chk('diciendo cuántos quedaron sin contar',
      /1 quedaron sin contar/.test(d.querySelector('#hoja').textContent));
}

console.log('\n=== APLICAR: el servidor se niega ===');
{
  const estado = base('gerente', 3);
  estado.rpc.fn_aplicar_conteo = { data:null, error:{ message:
    'Ya no hay suficiente Arroz 5lb para aplicar el ajuste: se vendio despues de contarlo. Vuelva a contar ese producto y aplique de nuevo' } };
  const { d, caja } = await montar(estado);
  await caja.abrirConteo('c1');
  await esperar(120);
  d.querySelector('#btn-aplicar').click();
  await esperar(70);
  d.querySelector('#ap-si').click();
  await esperar(140);
  chk('muestra el motivo completo',
      /Vuelva a contar ese producto/.test(d.querySelector('#ap-error').textContent));
  chk('no cierra la pregunta', !d.querySelector('#velo').classList.contains('oculto'));
}

console.log('\n=== UN CONTEO YA CERRADO ===');
{
  const estado = base('gerente', 3);
  estado.rpc.fn_conteo_resumen = { data:{ ...RESUMEN_SUP, estado:'aplicado',
    cerrado_por:'Somar', cerrado_en:new Date().toISOString(),
    valor_aplicado:-35 }, error:null };
  const { d, caja } = await montar(estado);
  await caja.abrirConteo('c1');
  await esperar(120);
  chk('avisa que ya se aplicó',
      /ya se aplicó/.test(d.querySelector('.aviso').textContent));
  chk('los campos quedan bloqueados',
      [...d.querySelectorAll('input[data-prod]')].every(i => i.disabled));
  chk('no deja aplicar otra vez', !d.querySelector('#btn-aplicar'));
  chk('ni cancelar', !d.querySelector('#btn-cancelar'));
  chk('solo deja volver', !!d.querySelector('#btn-volver'));
}
{
  const estado = base('gerente', 3);
  estado.rpc.fn_conteo_resumen = { data:{ ...RESUMEN_SUP, estado:'cancelado',
    motivo_cancelacion:'me equivoqué de alcance' }, error:null };
  const { d, caja } = await montar(estado);
  await caja.abrirConteo('c1');
  await esperar(120);
  chk('un cancelado lo dice con su motivo',
      /me equivoqué de alcance/.test(d.querySelector('.aviso').textContent));
  chk('y aclara que no cambió nada',
      /No cambió nada/.test(d.querySelector('.aviso').textContent));
}

console.log('\n=== CANCELAR ===');
{
  const estado = base('supervisor', 2);
  const { d, caja } = await montar(estado);
  await caja.abrirConteo('c1');
  await esperar(120);
  d.querySelector('#btn-cancelar').click();
  await esperar(70);
  chk('explica que no cambia el inventario',
      /No se cambia nada del inventario/.test(d.querySelector('#hoja').textContent));
  d.querySelector('#cc-si').click();
  await esperar(70);
  chk('sin motivo no cancela',
      !estado.llamadas.some(l => l.fn === 'fn_cancelar_conteo'));
  d.querySelector('#cc-motivo').value = 'me equivoqué';
  d.querySelector('#cc-si').click();
  await esperar(150);
  const c = estado.llamadas.find(l => l.fn === 'fn_cancelar_conteo');
  chk('con motivo sí', c?.args?.p_motivo === 'me equivoqué');
  chk('y vuelve a la lista', caja.S.vista === 'lista');
}

console.log('\n' + ok + ' bien, ' + mal + ' mal');
process.exit(mal ? 1 : 0);
