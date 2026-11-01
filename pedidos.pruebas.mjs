/* Prueba de Pedidos: cancelar en cualquier punto antes de entregarse, con la
   venta anulada en el mismo paso cuando ya se cobró. */
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';

const BASE = fileURLToPath(new URL('./', import.meta.url));
let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); } else { mal++; console.log('  MAL  ' + n); } };
const esperar = (ms = 120) => new Promise(r => setTimeout(r, ms));

const CTX = nivel => ({ usuario:{ id:'u1', nombre:'Somar', rol:nivel >= 2 ? 'supervisor' : 'auxiliar', nivel },
  organizacion:{ id:'o1', nombre:'Pulpería', moneda:'HNL' }, sucursales:[{ id:'s1', nombre:'Central' }], cajas:[] });

const PEDIDO = (extra = {}) => ({ id:'p1', numero:'P-S01-000001', estado:'listo', tipo_entrega:'domicilio', origen:'mostrador',
  creado_en:new Date().toISOString(), total:150, costo_envio:25, metodo_pago:'efectivo', venta_id:'v1', cliente:'Don Pedro',
  telefono:'9999-2222', direccion:'Col. Kennedy', repartidor_id:null, repartidor:null, lineas:1, unidades:2, minutos:30,
  tiene_faltantes:false, incidencia:null, ...extra });

async function montar(estado){
  const html = fs.readFileSync(BASE + 'pedidos.html', 'utf8');
  const cuerpo = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  const dom = new JSDOM(html.replace(/<script type="module">[\s\S]*?<\/script>/, '').replace(/<script src="(config|tema)\.js"><\/script>/g, ''),
    { runScripts:'outside-only', url:'https://x.test/pedidos.html', pretendToBeVisual:true });
  const w = dom.window;
  w.SUPABASE_CONFIG = { url:'https://x.supabase.co', key:'k' };
  Object.defineProperty(w.navigator, 'serviceWorker', { value:{ register: async () => ({}) }, configurable:true });
  w.matchMedia = () => ({ matches:false, addEventListener(){}, removeEventListener(){} });
  globalThis.window = w; globalThis.document = w.document; globalThis.localStorage = w.localStorage;
  estado.llamadas = [];
  const q = datos => { const o = { select(){ return o; }, eq(){ return o; }, order(){ return o; }, in(){ return o; }, gte(){ return o; },
    then(r, j){ return Promise.resolve({ data:datos(), error:null }).then(r, j); } }; return o; };
  w.__sb = {
    auth:{ getSession: async () => ({ data:{ session:{ user:{ id:'u1' } } } }), onAuthStateChange(){}, signOut: async () => {} },
    from: t => q(() => t === 'v_pedidos_tablero' ? estado.pedidos : []),
    channel: () => ({ on(){ return this; }, subscribe(){ return this; } }), removeChannel(){},
    rpc: async (fn, args) => { estado.llamadas.push({ fn, args }); const h = estado.rpc[fn];
      if (h === undefined) return { data:null, error:null }; return typeof h === 'function' ? h(args) : h; }
  };
  const menu = await import(BASE + 'menu.js');
  w.montarMenu = menu.montarMenu; w.escapar = menu.escapar;
  const prep = cuerpo
    .replace(/^import \{ createClient \} from 'https:\/\/esm\.sh\/@supabase\/supabase-js@2';$/m, '')
    .replace(/^import \{ montarMenu, escapar \} from '\.\/menu\.js';$/m, '')
    .replace(/createClient\(SUPABASE_URL, SUPABASE_KEY, \{[\s\S]*?\}\)/, '__sb');
  w.__m = {};
  await w.eval(`(async () => { ${prep}
    ; window.__m.abrirPedido = abrirPedido; window.__m.S = S; })()`);
  await esperar(200);
  return { w, d:w.document, m:w.__m, estado };
}
const botones = d => [...d.querySelectorAll('#d-pasos [data-a]')].map(b => b.dataset.a + ':' + b.textContent.trim());

console.log('\n=== CANCELAR UN PEDIDO ===');
{
  const e = { pedidos:[PEDIDO()], rpc:{ fn_pos_contexto:{ data:CTX(2), error:null }, fn_pedido_lineas:{ data:[], error:null },
    fn_cancelar_pedido:{ data:{ ok:true, venta_anulada:true, venta:'T-S01-00000004', efectivo:150, turno_cerrado:true }, error:null } } };
  const { d, m } = await montar(e);
  await m.abrirPedido('p1'); await esperar();
  chk('el pedido cobrado y listo ofrece cancelar (antes quedaba pegado)', botones(d).includes('cancelar:Cancelar y anular la venta'));
  d.querySelector('[data-a="cancelar"]').click(); await esperar(40);
  chk('avisa que se anula la venta', /se anula esa venta/.test(d.querySelector('#hoja').textContent));
  d.querySelector('#mt-valor').value = 'El cliente ya no lo quiere';
  d.querySelector('#mt-si').click(); await esperar(150);
  const c = e.llamadas.find(l => l.fn === 'fn_cancelar_pedido');
  chk('usa fn_cancelar_pedido con el motivo', c && c.args.p_pedido_id === 'p1' && c.args.p_motivo === 'El cliente ya no lo quiere');
  chk('ya no usa el cambio de estado para cancelar', !e.llamadas.some(l => l.fn === 'fn_cambiar_estado_pedido'));
  const t = d.querySelector('#hoja').textContent;
  chk('dice qué venta se anuló, cuánto devolver y que el cierre cambia', /T-S01-00000004/.test(t) && /L 150.00/.test(t) && /cierre de caja/.test(t));
}
{
  const e = { pedidos:[PEDIDO({ estado:'en_ruta', repartidor_id:'r1', repartidor:'Luis' })],
    rpc:{ fn_pos_contexto:{ data:CTX(2), error:null }, fn_pedido_lineas:{ data:[], error:null } } };
  const { d, m } = await montar(e);
  await m.abrirPedido('p1'); await esperar();
  chk('en ruta también se puede cancelar', botones(d).some(b => b.startsWith('cancelar')) && botones(d).some(b => b.startsWith('entregado')));
}
{
  const e = { pedidos:[PEDIDO({ venta_id:null })], rpc:{ fn_pos_contexto:{ data:CTX(1), error:null }, fn_pedido_lineas:{ data:[], error:null } } };
  const { d, m } = await montar(e);
  await m.abrirPedido('p1'); await esperar();
  chk('la auxiliar no ve cancelar en un pedido listo', !botones(d).some(b => b.startsWith('cancelar')) && botones(d).some(b => b.startsWith('facturar')));
}
{
  const e = { pedidos:[PEDIDO({ venta_id:null })], rpc:{ fn_pos_contexto:{ data:CTX(2), error:null }, fn_pedido_lineas:{ data:[], error:null },
    fn_cancelar_pedido:{ data:{ ok:true, venta_anulada:false }, error:null } } };
  const { d, m } = await montar(e);
  await m.abrirPedido('p1'); await esperar();
  chk('sin cobrar dice solo «Cancelar pedido»', botones(d).includes('cancelar:Cancelar pedido'));
  d.querySelector('[data-a="cancelar"]').click(); await esperar(40);
  d.querySelector('#mt-no').click(); await esperar(60);
  chk('si se arrepiente no cancela', !e.llamadas.some(l => l.fn === 'fn_cancelar_pedido'));
}

console.log(`\n${ok} bien · ${mal} mal`);
process.exit(mal ? 1 : 0);
