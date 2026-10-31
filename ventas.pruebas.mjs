/* Prueba funcional del historial de ventas, manejado como lo manejaria el
   dueño: filtrar, abrir un ticket, anular. */
import fs from 'node:fs';
import { JSDOM } from 'jsdom';

const BASE = '/home/claude/somtechn/pulpeando_interno/';
let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };

/* La fecha del DÍA DE AQUÍ, no la de UTC. La pantalla manda la local (así se
   arregló lo de "días en hora de Honduras"), y toISOString devuelve la de UTC:
   entre las 6 de la tarde y medianoche en Honduras son días distintos y estas
   pruebas fallaban solo de noche, pareciendo intermitentes. */
const iso = d => new Date(d.getTime() - d.getTimezoneOffset() * 60000)
                   .toISOString().slice(0,10);
const hoyISO = iso(new Date());

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
    .replace(/^import \{ escanear, hayCamara \} from '\.\/escaner\.js';$/m,
             'const escanear = async () => window.__escaneo ?? null; const hayCamara = () => !!window.__hayCamara;')
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
      ultimo()?.args?.p_desde === iso(ayer)
      && ultimo()?.args?.p_hasta === iso(ayer));
  chk('y mueve las cajas de fecha',
      d.querySelector('#f-desde').value === iso(ayer));

  d.querySelector('[data-p="semana"]').click();
  await esperar();
  const sem = new Date(); sem.setDate(sem.getDate()-6);
  chk('7 días pide desde hace 6',
      ultimo()?.args?.p_desde === iso(sem));
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

/* ===================================================================== */
const TICKET_DV = { ...TICKET,
  venta:{ ...TICKET.venta, sucursal_id:'s1', devuelto:0 },
  lineas:[
    { detalle_id:'d1', producto:'Arroz 5lb', cantidad:3, devuelto:1, precio:60, descuento:0, total:180, costo:40 },
    { detalle_id:'d2', producto:'Leche 1L', cantidad:1, devuelto:0, precio:30, descuento:0, total:30, costo:22 }],
  pagos:[{ metodo:'efectivo', monto:90, recibido:90, cambio:0 },
         { metodo:'credito', monto:120, recibido:null, cambio:0 }],
  devoluciones:[{ id:'dv0', numero:'DV-S01-00000001', numero_fiscal:null, documento:'ticket',
    total:60, motivo:'venía rota', rebaja_fiado:60, reembolso:0, metodo:null, por:'Sup' }] };
const CTX_CAJA = { ...CTX, cajas:[
  { caja_id:'c1', caja:'Caja 1', sucursal_id:'s1', turno_id:'t1', cajero:'Ana' },
  { caja_id:'c2', caja:'Caja 2', sucursal_id:'s1', turno_id:null, cajero:null },
  { caja_id:'c9', caja:'Otra', sucursal_id:'s9', turno_id:'t9', cajero:'Zoe' }] };

console.log('\n=== DEVOLVER PARTE DE UNA VENTA ===');
{
  const estado = baseEstado();
  estado.rpc.fn_pos_contexto = { data:CTX_CAJA, error:null };
  estado.rpc.fn_venta_completa = { data:TICKET_DV, error:null };
  estado.rpc.fn_devolver_venta = { data:{ devolucion_id:'dv1', numero:'DV-S01-00000002',
    documento:'ticket', total:90, rebaja_fiado:60, reembolso:30, metodo:'efectivo',
    falta_nota_credito:false, saldo_cliente:0 }, error:null };
  estado.rpc.fn_devolucion_completa = { data:{ venta:{ numero:'DV-S01-00000002', documento:'devolucion' },
    devolucion:{ motivo:'x' } }, error:null };
  const { d } = await montar(estado);
  d.querySelector('.venta').click();
  await esperar(90);
  const t = d.querySelector('#cajon-cuerpo').textContent;
  chk('el ticket muestra lo devuelto por línea', /Devuelto: 1/.test(t));
  chk('y la devolución anterior con su motivo', /DV-S01-00000001/.test(t) && /venía rota/.test(t));
  chk('dice que se rebajó del fiado', /rebajó L 60\.00 del fiado/.test(t));
  chk('con devoluciones ya no se anula entera',
      d.querySelector('#btn-anular').classList.contains('oculto'));
  chk('pero sí se puede devolver lo que queda',
      !d.querySelector('#btn-devolver').classList.contains('oculto'));

  d.querySelector('#btn-devolver').click();
  await esperar(80);
  const h = () => d.querySelector('#hoja');
  chk('abre la hoja de devolución', /Devolver de/.test(h().textContent));
  chk('ofrece solo lo que queda del arroz', /puede devolver 2/.test(h().textContent));
  chk('ofrece la leche', /Leche 1L/.test(h().textContent));
  const cajas = [...h().querySelectorAll('#dv-caja option')];
  chk('solo cajas abiertas de la sucursal de la venta',
      cajas.length === 1 && cajas[0].value === 't1');

  // sin productos no manda nada
  d.querySelector('#dv-motivo').value = 'vencido';
  d.querySelector('#dv-si').click();
  await esperar(40);
  chk('sin productos no registra', !estado.llamadas.some(l => l.fn === 'fn_devolver_venta'));
  chk('y lo pide', /Marque al menos/.test(d.querySelector('#dv-error').textContent));

  // + tres veces al arroz: no pasa de 2
  const mas = h().querySelector('[data-mas="d1"]');
  mas.click(); mas.click(); mas.click();
  chk('no deja pasar de lo que queda', h().querySelector('[data-cant="d1"]').value === '2');
  h().querySelector('[data-menos="d1"]').click();
  h().querySelector('[data-mas="d2"]').click();
  chk('suma lo que se devuelve', /L 90\.00/.test(d.querySelector('#dv-total').textContent));
  chk('explica que primero rebaja el fiado',
      /rebajan L 60\.00 del fiado y se le devuelven L 30\.00/.test(d.querySelector('#dv-nota').textContent));

  d.querySelector('#dv-si').click();
  await esperar(140);
  const ll = estado.llamadas.find(l => l.fn === 'fn_devolver_venta');
  chk('registra la devolución', !!ll);
  chk('de la venta correcta', ll?.args?.p_venta_id === 'v1');
  chk('con las cantidades por línea', JSON.stringify(ll?.args?.p_lineas) ===
      JSON.stringify([{ detalle_id:'d1', cantidad:1 }, { detalle_id:'d2', cantidad:1 }]));
  chk('con el motivo', ll?.args?.p_motivo === 'vencido');
  chk('el efectivo sale de la caja abierta', ll?.args?.p_turno_id === 't1' && ll?.args?.p_metodo === 'efectivo');
  chk('dice cuánto entregar', /Entregue L 30\.00 en efectivo/.test(h().textContent));
  chk('y cuánto se rebajó del fiado', /rebajaron L 60\.00 del fiado/.test(h().textContent));
  d.querySelector('#dv-imprimir').click();
  await esperar(60);
  const imp = d.defaultView.__impresos || [];
  chk('imprime el comprobante de la devolución',
      estado.llamadas.some(l => l.fn === 'fn_devolucion_completa' && l.args.p_devolucion_id === 'dv1')
      && imp.some(x => x.d?.venta?.documento === 'devolucion'));
}

console.log('\n=== LO DEVUELTO EN EL RESUMEN ===');
{
  const estado = baseEstado();
  estado.rpc.fn_ventas_resumen = { data:{ ventas:2, total:215, bruto:275, devuelto:60, devoluciones:1,
    efectivo:155, fiado:60, anuladas:0, ganancia:70 }, error:null };
  estado.rpc.fn_historial_ventas = { data:[{ ...VENTAS[0], devuelto:60 }, VENTAS[1]], error:null };
  const { d } = await montar(estado);
  const tjs = [...d.querySelectorAll('.tj')];
  chk('lo vendido sale neto', tjs.some(t => /Vendido neto/.test(t.textContent) && /L 215\.00/.test(t.textContent)));
  chk('y lo devuelto aparte', tjs.some(t => /Devuelto/.test(t.textContent) && /L 60\.00/.test(t.textContent)));
  chk('la venta con devolución se marca', /Devolución/.test(d.querySelectorAll('.venta')[0].textContent));
  chk('la que no, no', !/Devolución/.test(d.querySelectorAll('.venta')[1].textContent));
}

console.log('\n=== DEVOLVER POR TRANSFERENCIA Y SIN CAJA ===');
{
  const estado = baseEstado();
  estado.rpc.fn_pos_contexto = { data:CTX, error:null };   // sin cajas abiertas
  estado.rpc.fn_venta_completa = { data:{ ...TICKET_DV, devoluciones:[],
    pagos:[{ metodo:'efectivo', monto:210, recibido:210, cambio:0 }],
    venta:{ ...TICKET_DV.venta, documento:'factura', numero_fiscal:'000-001-01-00000009' },
    lineas:TICKET_DV.lineas.map(l => ({ ...l, devuelto:0 })) }, error:null };
  estado.rpc.fn_devolver_venta = { data:{ devolucion_id:'dv2', numero:'DV-S01-00000003',
    documento:'ticket', total:30, rebaja_fiado:0, reembolso:30, metodo:'transferencia',
    falta_nota_credito:true, saldo_cliente:null }, error:null };
  const { d } = await montar(estado);
  d.querySelector('.venta').click();
  await esperar(90);
  chk('sin devoluciones todavía se puede anular',
      !d.querySelector('#btn-anular').classList.contains('oculto'));
  d.querySelector('#btn-devolver').click();
  await esperar(80);
  chk('avisa que no hay caja abierta', !!d.querySelector('#dv-sin-caja'));
  d.querySelector('[data-mas="d2"]').click();
  d.querySelector('#dv-motivo').value = 'no la quiso';
  d.querySelector('#dv-si').click();
  await esperar(60);
  chk('en efectivo sin caja no registra', !estado.llamadas.some(l => l.fn === 'fn_devolver_venta'));
  chk('y explica por qué', /caja abierta/.test(d.querySelector('#dv-error').textContent));
  d.querySelector('[data-m="transferencia"]').click();
  chk('por transferencia no pide caja', d.querySelector('#dv-caja-campo').classList.contains('oculto'));
  d.querySelector('#dv-si').click();
  await esperar(140);
  const ll = estado.llamadas.find(l => l.fn === 'fn_devolver_venta');
  chk('registra por transferencia sin turno', ll?.args?.p_metodo === 'transferencia' && ll?.args?.p_turno_id === null);
  chk('avisa que faltó el rango de notas de crédito',
      /no hay rango de notas de crédito/.test(d.querySelector('#hoja').textContent));
}

console.log('\n=== DEVOLVER: sin la actualización instalada ===');
{
  const estado = baseEstado();
  estado.rpc.fn_pos_contexto = { data:CTX_CAJA, error:null };
  estado.rpc.fn_venta_completa = { data:TICKET_DV, error:null };
  estado.rpc.fn_devolver_venta = { data:null, error:{ message:'Could not find the function public.fn_devolver_venta' } };
  const { d } = await montar(estado);
  d.querySelector('.venta').click();
  await esperar(90);
  d.querySelector('#btn-devolver').click();
  await esperar(80);
  d.querySelector('[data-mas="d2"]').click();
  d.querySelector('#dv-motivo').value = 'x';
  d.querySelector('#dv-si').click();
  await esperar(120);
  chk('dice en claro que falta instalar la 032', /Falta instalar/.test(d.querySelector('#dv-error').textContent));
}

console.log('\n=== UNA AUXILIAR NO DEVUELVE ===');
{
  const estado = baseEstado();
  estado.rpc.fn_pos_contexto = { data:{ ...CTX, usuario:{ ...CTX.usuario, nivel:1 } }, error:null };
  estado.rpc.fn_venta_completa = { data:TICKET_DV, error:null };
  const { d } = await montar(estado);
  d.querySelector('.venta').click();
  await esperar(90);
  chk('no le aparece el botón de devolver', d.querySelector('#btn-devolver').classList.contains('oculto'));
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

console.log('\n=== ESCANEAR EL TICKET PARA DEVOLVER ===');
{
  const COD = '8040020117867778';
  const estado = baseEstado();
  estado.rpc.fn_buscar_ticket = a => a.p_codigo.replace(/\D/g, '') === COD
    ? { data:{ ok:true, venta_id:'v9' }, error:null }
    : { data:{ ok:false, mensaje:'Ese ticket es de otra tienda' }, error:null };
  const { w, d } = await montar(estado);
  const b = d.querySelector('#buscar');
  const teclear = txt => { b.value = txt; b.dispatchEvent(new w.Event('input', { bubbles:true })); };
  const enter = () => b.dispatchEvent(new w.KeyboardEvent('keydown', { key:'Enter', bubbles:true }));

  const antes = estado.llamadas.filter(l => l.fn === 'fn_historial_ventas').length;
  teclear(COD);
  await esperar(400);
  chk('los 16 dígitos no se buscan en el historial',
      estado.llamadas.filter(l => l.fn === 'fn_historial_ventas').length === antes);
  enter();
  await esperar(80);
  chk('con el Enter de la pistola busca el ticket',
      estado.llamadas.some(l => l.fn === 'fn_buscar_ticket' && l.args.p_codigo === COD));
  chk('y abre esa venta, sin mirar las fechas',
      estado.llamadas.some(l => l.fn === 'fn_venta_completa' && l.args.p_venta_id === 'v9'));
  chk('el buscador queda limpio para el siguiente', b.value === '');

  teclear('804-002-01-17867778'); enter(); await esperar(80);
  chk('con guiones también',
      estado.llamadas.filter(l => l.fn === 'fn_venta_completa').length === 2);

  teclear('1110020117867778'); enter(); await esperar(80);
  chk('el de otra tienda lo dice', /otra tienda/.test(d.querySelector('#hoja').textContent));

  teclear('T-001'); enter(); await esperar(400);
  chk('un número de ticket normal sigue buscando en el historial',
      estado.llamadas.some(l => l.fn === 'fn_historial_ventas' && l.args.p_buscar === 'T-001'));
  chk('sin cámara no se ve el botón', d.querySelector('#btn-camara').classList.contains('oculto'));

  w.__escaneo = COD;
  d.querySelector('#btn-camara').click(); await esperar(80);
  chk('con la cámara abre la venta',
      estado.llamadas.filter(l => l.fn === 'fn_venta_completa').length === 3);
  w.__escaneo = '7421110100553';
  d.querySelector('#btn-camara').click(); await esperar(80);
  chk('un código de producto no es un ticket', /Ese no es un ticket/.test(d.querySelector('#hoja').textContent));
}

{
  const estado = baseEstado();
  estado.rpc.fn_buscar_ticket = { data:null, error:{ message:'Could not find the function public.fn_buscar_ticket' } };
  const { w, d } = await montar(estado);
  const b = d.querySelector('#buscar');
  b.value = '8040020117867778';
  b.dispatchEvent(new w.KeyboardEvent('keydown', { key:'Enter', bubbles:true }));
  await esperar(80);
  chk('sin la 043 en la base, lo dice', /043/.test(d.querySelector('#hoja').textContent));
}

console.log('\n' + ok + ' bien, ' + mal + ' mal');
process.exit(mal ? 1 : 0);
