/* Prueba funcional del historial de ventas, manejado como lo manejaria el
   dueño: filtrar, abrir un ticket, anular. */
import fs from 'node:fs';
import { JSDOM } from 'jsdom';

const BASE = '/home/claude/somtechn/pulpeando_interno/';
let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };

const hoyISO = new Date().toISOString().slice(0,10);

const VENTAS = [
  { venta_id:'v1', numero:'T-S01-00000003', numero_fiscal:null, documento:'ticket',
    creada_en:new Date().toISOString(), sucursal:'Central', caja:'Caja 1',
    cajero:'Ana', cliente:'Doña Marta', total:180, costo:120, ganancia:60,
    es_credito:true, estado:'completada', metodos:'credito, efectivo', lineas:2,
    anulada_por:null, motivo:null },
  { venta_id:'v2', numero:'T-S01-00000002', numero_fiscal:'001-001-01-00000009',
    documento:'factura', creada_en:new Date().toISOString(), sucursal:'Central',
    caja:'Caja 1', cajero:'Ana', cliente:null, total:95, costo:60, ganancia:35,
    es_credito:false, estado:'completada', metodos:'efectivo', lineas:1,
    anulada_por:null, motivo:null },
  { venta_id:'v3', numero:'T-S01-00000001', numero_fiscal:null, documento:'ticket',
    creada_en:new Date().toISOString(), sucursal:'Central', caja:'Caja 1',
    cajero:'Beto', cliente:null, total:40, costo:25, ganancia:15,
    es_credito:false, estado:'anulada', metodos:'efectivo', lineas:1,
    anulada_por:'Gerente', motivo:'cobro equivocado' }
];

const TICKET = {
  venta:{ id:'v1', numero:'T-S01-00000003', numero_fiscal:null, cai:null,
    documento:'ticket', creada_en:new Date().toISOString(), subtotal:180,
    impuesto:0, descuento:0, total:180, es_credito:true, estado:'completada',
    motivo_anulacion:null, anulada_en:null, costo:120, anulada_por:null },
  negocio:{ nombre:'Pulpería Pulpeando', rtn:null, moneda:'HNL' },
  sucursal:{ nombre:'Central', direccion:'Col. Las Flores', telefono:'9999-1111' },
  caja:'Caja 1', cajero:'Ana',
  cliente:{ nombre:'Doña Marta', telefono:'9999-0001', rtn:null },
  lineas:[{ producto:'Arroz 5lb', cantidad:3, precio:60, descuento:0, total:180, costo:40 }],
  pagos:[{ metodo:'efectivo', monto:60, recibido:60, cambio:0, referencia:null },
         { metodo:'credito', monto:120, recibido:null, cambio:0, referencia:null }]
};

const CTX = {
  usuario:{ id:'u1', nombre:'Gerente', rol:'gerente', nivel:3, tiene_pin:true },
  organizacion:{ id:'o1', nombre:'Pulpería Pulpeando', moneda:'HNL', factura_fiscal:false },
  sucursales:[{ id:'s1', nombre:'Central', codigo:'S01' }],
  cajas:[], impuesto_default:0, sin_sucursal:false
};

async function montar(estado){
  const html = fs.readFileSync(BASE + 'ventas.html', 'utf8');
  const cuerpo = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  const css = fs.readFileSync(BASE + 'ui.css', 'utf8');

  const dom = new JSDOM(
    html.replace(/<script type="module">[\s\S]*?<\/script>/, '')
        .replace('<link rel="stylesheet" href="ui.css">', '<style>' + css + '</style>')
        .replace(/<script src="config\.js"><\/script>/, ''),
    { runScripts:'outside-only', url:'https://x.test/ventas.html', pretendToBeVisual:true });

  const w = dom.window;
  w.SUPABASE_CONFIG = { url:'https://x.supabase.co', key:'k' };
  Object.defineProperty(w.navigator, 'serviceWorker',
    { value:{ register: async () => ({}) }, configurable:true });
  w.matchMedia = () => ({ matches:false, addEventListener(){}, removeEventListener(){} });
  w.print = () => { estado.impresiones++; };
  w.alert = m => estado.alertas.push(m);

  globalThis.window = w; globalThis.document = w.document;
  globalThis.localStorage = w.localStorage; globalThis.matchMedia = w.matchMedia;

  estado.llamadas = [];
  w.__sb = {
    auth:{ getSession: async () => ({ data:{ session:{ user:{id:'u1'} } } }),
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
    .replace(/^import \{ imprimirTicket \} from '\.\/ticket\.js';$/m,
             'const imprimirTicket = async (d, o) => { (window.__impresos = window.__impresos || []).push({ d, o }); };')
    .replace(/createClient\(SUPABASE_URL, SUPABASE_KEY, \{[\s\S]*?\}\)/, '__sb');

  w.__caja = {};
  await w.eval(`(async () => { ${prep}
    ; window.__caja.S = S; window.__caja.cargar = cargar;
    ; window.__caja.ponerPeriodo = ponerPeriodo;
  })()`);
  await new Promise(r => setTimeout(r, 120));
  return { w, d:w.document, caja:w.__caja, estado };
}

const esperar = (ms = 60) => new Promise(r => setTimeout(r, ms));

const baseEstado = (extra = {}) => ({
  alertas:[], impresiones:0,
  rpc:{
    fn_pos_contexto:{ data:CTX, error:null },
    fn_historial_ventas:{ data:VENTAS, error:null },
    fn_ventas_resumen:{ data:{ ventas:2, total:275, efectivo:155, fiado:120,
                               anuladas:1, monto_anulado:40, ganancia:95 }, error:null },
    fn_venta_completa:{ data:TICKET, error:null },
    fn_anular_venta:{ data:null, error:null }
  }, ...extra });

/* ===================================================================== */
console.log('\n=== LA LISTA ===');
{
  const estado = baseEstado();
  const { d, caja } = await montar(estado);

  chk('arranca y entra', !d.querySelector('#app').classList.contains('oculto'));
  chk('pide el historial', estado.llamadas.some(l => l.fn === 'fn_historial_ventas'));
  chk('y el resumen', estado.llamadas.some(l => l.fn === 'fn_ventas_resumen'));

  const h = estado.llamadas.find(l => l.fn === 'fn_historial_ventas');
  chk('arranca en hoy', h?.args?.p_desde === hoyISO && h?.args?.p_hasta === hoyISO);
  chk('acotado a su sucursal', h?.args?.p_sucursal_id === 's1');

  chk('pinta las tres ventas', d.querySelectorAll('.venta').length === 3);
  const vs = d.querySelectorAll('.venta');
  chk('la anulada se marca', vs[2].classList.contains('anulada'));
  chk('y lo dice', /Anulada/.test(vs[2].textContent));
  chk('la fiada se marca', /Fiado/.test(vs[0].textContent));
  chk('la factura se marca', /Factura/.test(vs[1].textContent));
  chk('la factura muestra su numero fiscal', /001-001-01-00000009/.test(vs[1].textContent));
  chk('muestra el cliente cuando hay', /Doña Marta/.test(vs[0].textContent));
  chk('muestra la cajera', /Ana/.test(vs[0].textContent));

  chk('el conteo cuenta solo las buenas',
      /^2 ventas · L 275\.00/.test(d.querySelector('#conteo').textContent));
  chk('y las anuladas van aparte',
      /1 anulada aparte/.test(d.querySelector('#conteo').textContent));

  // resumen
  const tjs = d.querySelectorAll('.tj');
  chk('el resumen muestra lo vendido', /L 275\.00/.test(tjs[0].textContent));
  chk('muestra el efectivo', [...tjs].some(t => /Efectivo/.test(t.textContent)
                                               && /L 155\.00/.test(t.textContent)));
  chk('muestra el fiado', [...tjs].some(t => /Fiado/.test(t.textContent)
                                             && /L 120\.00/.test(t.textContent)));
  chk('al gerente le muestra la ganancia',
      [...tjs].some(t => /Ganancia/.test(t.textContent)));
  chk('y marca las anuladas en rojo',
      [...tjs].some(t => t.classList.contains('malo') && /Anuladas/.test(t.textContent)));
}

console.log('\n=== LA AUXILIAR NO VE COSTOS ===');
{
  const estado = baseEstado();
  estado.rpc.fn_pos_contexto = { data:{ ...CTX,
    usuario:{ ...CTX.usuario, rol:'auxiliar', nivel:1 } }, error:null };
  estado.rpc.fn_ventas_resumen = { data:{ ventas:2, total:275, efectivo:155,
    fiado:120, anuladas:1, monto_anulado:40, ganancia:null }, error:null };
  const { d } = await montar(estado);
  chk('la auxiliar entra', !d.querySelector('#app').classList.contains('oculto'));
  chk('pero no ve tarjeta de ganancia',
      ![...d.querySelectorAll('.tj')].some(t => /Ganancia/.test(t.textContent)));
}

console.log('\n=== LOS FILTROS ===');
{
  const estado = baseEstado();
  const { d, caja } = await montar(estado);
  const ultimo = () => [...estado.llamadas].reverse().find(l => l.fn === 'fn_historial_ventas');

  d.querySelector('[data-p="ayer"]').click();
  await esperar();
  const ayer = new Date(); ayer.setDate(ayer.getDate()-1);
  chk('ayer pide solo ayer',
      ultimo()?.args?.p_desde === ayer.toISOString().slice(0,10)
      && ultimo()?.args?.p_hasta === ayer.toISOString().slice(0,10));
  chk('y mueve las cajas de fecha',
      d.querySelector('#f-desde').value === ayer.toISOString().slice(0,10));

  d.querySelector('[data-p="semana"]').click();
  await esperar();
  const sem = new Date(); sem.setDate(sem.getDate()-6);
  chk('7 días pide desde hace 6',
      ultimo()?.args?.p_desde === sem.toISOString().slice(0,10));
  chk('hasta hoy', ultimo()?.args?.p_hasta === hoyISO);

  d.querySelector('[data-p="mes"]').click();
  await esperar();
  chk('el mes arranca el día 1', /-01$/.test(ultimo()?.args?.p_desde));

  // solo anuladas
  d.querySelector('[data-e="anulada"]').click();
  await esperar();
  chk('solo anuladas lo pide al servidor', ultimo()?.args?.p_estado === 'anulada');
  chk('y el filtro se ve activo',
      d.querySelector('[data-e="anulada"]').classList.contains('activo'));

  d.querySelector('[data-e="anulada"]').click();
  await esperar();
  chk('al tocarlo otra vez se apaga', ultimo()?.args?.p_estado === null);
  chk('y deja de verse activo',
      !d.querySelector('[data-e="anulada"]').classList.contains('activo'));

  // solo fiadas filtra en la pantalla, no en el servidor
  d.querySelector('[data-e="fiado"]').click();
  await esperar();
  chk('solo fiadas deja una sola venta', d.querySelectorAll('.venta').length === 1);
  chk('y es la fiada', /Doña Marta/.test(d.querySelector('.venta').textContent));

  // el periodo no se pierde al filtrar por estado
  d.querySelector('[data-e="fiado"]').click();
  await esperar();
  chk('al apagarlo vuelven las tres', d.querySelectorAll('.venta').length === 3);

  // buscar
  d.querySelector('#buscar').value = 'Marta';
  d.querySelector('#buscar').dispatchEvent(new (d.defaultView.Event)('input', {bubbles:true}));
  await esperar(420);
  chk('la búsqueda va al servidor', ultimo()?.args?.p_buscar === 'Marta');

  // fecha a mano
  d.querySelector('#f-desde').value = '2026-01-01';
  d.querySelector('#f-desde').dispatchEvent(new (d.defaultView.Event)('change', {bubbles:true}));
  await esperar();
  chk('una fecha escrita a mano manda', ultimo()?.args?.p_desde === '2026-01-01');
  chk('y apaga el periodo marcado',
      ![...d.querySelectorAll('.fl[data-p]')].some(x => x.classList.contains('activo')));
}

console.log('\n=== EL TICKET ===');
{
  const estado = baseEstado();
  const { d, caja } = await montar(estado);
  d.querySelector('.venta').click();
  await esperar(90);

  chk('abre el cajón', !d.querySelector('#form-velo').classList.contains('oculto'));
  chk('pide la venta completa',
      estado.llamadas.some(l => l.fn === 'fn_venta_completa' && l.args.p_venta_id === 'v1'));
  const t = d.querySelector('#cajon-cuerpo').textContent;
  chk('con el nombre del negocio', /Pulpería Pulpeando/.test(t));
  chk('la sucursal y su dirección', /Col\. Las Flores/.test(t));
  chk('el producto', /Arroz 5lb/.test(t));
  chk('la cantidad por el precio', /3 × L 60\.00/.test(t));
  chk('el total', /L 180\.00/.test(t));
  chk('los pagos en palabras, no en valores de tabla',
      /Efectivo/.test(t) && /Fiado/.test(t) && !/credito/.test(t));
  chk('al gerente le muestra el costo', /Costo/.test(t));
  chk('y la ganancia', /Ganancia/.test(t));
  chk('el botón de anular aparece para el gerente',
      !d.querySelector('#btn-anular').classList.contains('oculto'));

  d.querySelector('#btn-imprimir').click();
  const imp = (d.defaultView.__impresos || []);
  chk('imprimir manda la venta al ticket térmico', imp.length === 1 && imp[0].d.venta);
  chk('una factura reimpresa sale como copia',
      imp[0]?.o?.copia === (imp[0]?.d.venta.documento === 'factura'));
}

console.log('\n=== EL TICKET DE UNA VENTA ANULADA ===');
{
  const estado = baseEstado();
  estado.rpc.fn_venta_completa = { data:{ ...TICKET,
    venta:{ ...TICKET.venta, estado:'anulada', motivo_anulacion:'cobro equivocado',
            anulada_por:'Gerente', anulada_en:new Date().toISOString() } }, error:null };
  const { d } = await montar(estado);
  d.querySelector('.venta').click();
  await esperar(90);
  const t = d.querySelector('#cajon-cuerpo').textContent;
  chk('avisa que está anulada', /Esta venta se anuló/.test(t));
  chk('dice quién la anuló', /Gerente/.test(t));
  chk('y por qué', /cobro equivocado/.test(t));
  chk('explica que la mercadería volvió', /volvió al inventario/.test(t));
  chk('no deja volver a anularla',
      d.querySelector('#btn-anular').classList.contains('oculto'));
}

console.log('\n=== ANULAR ===');
{
  const estado = baseEstado();
  const { d, caja } = await montar(estado);
  d.querySelector('.venta').click();
  await esperar(90);
  d.querySelector('#btn-anular').click();
  await esperar(40);

  chk('pregunta antes de anular', !d.querySelector('#velo').classList.contains('oculto'));
  chk('explica lo que va a pasar',
      /vuelve al inventario/.test(d.querySelector('#hoja').textContent));
  chk('dice que no se borra',
      /no se borra/.test(d.querySelector('#hoja').textContent));

  // sin motivo
  d.querySelector('#an-si').click();
  await esperar(40);
  chk('sin motivo no anula',
      estado.llamadas.filter(l => l.fn === 'fn_anular_venta').length === 0);
  chk('y pide el motivo',
      /Escriba por qué/.test(d.querySelector('#an-error').textContent));

  d.querySelector('#an-motivo').value = 'se cobró de más';
  d.querySelector('#an-si').click();
  await esperar(120);
  const a = estado.llamadas.find(l => l.fn === 'fn_anular_venta');
  chk('ahora sí anula', !!a);
  chk('la venta correcta', a?.args?.p_venta_id === 'v1');
  chk('con el motivo escrito', a?.args?.p_motivo === 'se cobró de más');
  chk('cierra la pregunta', d.querySelector('#velo').classList.contains('oculto'));
  chk('y recarga la lista',
      estado.llamadas.filter(l => l.fn === 'fn_historial_ventas').length >= 2);
}

console.log('\n=== ANULAR: el servidor dice que no ===');
{
  const estado = baseEstado();
  estado.rpc.fn_anular_venta = { data:null, error:{ message:
    'Solo un supervisor de este negocio puede anular ventas' } };
  const { d } = await montar(estado);
  d.querySelector('.venta').click();
  await esperar(90);
  d.querySelector('#btn-anular').click();
  await esperar(40);
  d.querySelector('#an-motivo').value = 'probando';
  d.querySelector('#an-si').click();
  await esperar(120);
  chk('muestra el motivo del servidor',
      /Solo un supervisor/.test(d.querySelector('#an-error').textContent));
  chk('no cierra la pregunta', !d.querySelector('#velo').classList.contains('oculto'));
  chk('el botón vuelve a quedar usable', d.querySelector('#an-si').disabled === false);
}

console.log('\n=== UNA AUXILIAR NO PUEDE ANULAR ===');
{
  const estado = baseEstado();
  estado.rpc.fn_pos_contexto = { data:{ ...CTX,
    usuario:{ ...CTX.usuario, rol:'auxiliar', nivel:1 } }, error:null };
  estado.rpc.fn_venta_completa = { data:{ ...TICKET,
    venta:{ ...TICKET.venta, costo:null } }, error:null };
  const { d } = await montar(estado);
  d.querySelector('.venta').click();
  await esperar(90);
  chk('no le aparece el botón de anular',
      d.querySelector('#btn-anular').classList.contains('oculto'));
  chk('ni el costo en el ticket',
      !/Costo/.test(d.querySelector('#cajon-cuerpo').textContent));
  chk('pero sí puede imprimir el ticket',
      !d.querySelector('#btn-imprimir').classList.contains('oculto'));
}

console.log('\n=== SIN VENTAS Y SIN CONEXIÓN ===');
{
  const estado = baseEstado();
  estado.rpc.fn_historial_ventas = { data:[], error:null };
  estado.rpc.fn_ventas_resumen = { data:{ ventas:0, total:0, efectivo:0, fiado:0,
    anuladas:0, monto_anulado:0, ganancia:0 }, error:null };
  const { d } = await montar(estado);
  chk('el vacío orienta',
      /No hay ventas en ese periodo/.test(d.querySelector('.vacio').textContent));
}
{
  const estado = baseEstado();
  estado.rpc.fn_historial_ventas = { data:null,
    error:{ message:'TypeError: Failed to fetch' } };
  const { d } = await montar(estado);
  await esperar(60);
  chk('sin conexión lo dice en claro',
      /Sin conexión/.test(d.querySelector('#hoja').textContent));
  chk('sin jerga', !/TypeError/.test(d.querySelector('#hoja').textContent));
}

console.log('\n' + ok + ' bien, ' + mal + ' mal');
process.exit(mal ? 1 : 0);
