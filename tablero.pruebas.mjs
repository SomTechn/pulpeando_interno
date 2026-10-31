/* Prueba del tablero del dueño: quién lo ve, qué pide al servidor, qué
   enseña y qué alertas levanta. */
import fs from 'node:fs';
import { JSDOM } from 'jsdom';

const BASE = new URL('./', import.meta.url).pathname;
let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };
const esperar = (ms = 80) => new Promise(r => setTimeout(r, ms));

const CTX = nivel => ({ usuario:{ nombre:'Doña Marta', nivel },
  organizacion:{ nombre:'Abarrotería El Buen Precio', moneda:'HNL' },
  sucursales:[{ id:'s1', nombre:'Central' }] });

const DIAS = Array.from({ length:30 }, (_, i) => ({
  fecha:`2026-10-${String(i + 2).padStart(2, '0')}`, venta:50000 + i * 100,
  utilidad:11000, tickets:160 }));

const DATOS = (extra = {}) => ({
  desde:'2026-10-02', hasta:'2026-10-31', dias:30, hoy:'2026-10-31', sucursal_id:null,
  sucursales:[{ id:'s1', nombre:'Central' }, { id:'s2', nombre:'Choloma' }],
  periodo:{ tickets:4800, venta:1500000, utilidad:330000, margen:24.5, ticket_promedio:312.5,
            unidades:21000, anuladas:20, monto_anulado:3000 },
  anterior:{ tickets:4500, venta:1400000, utilidad:340000, ticket_promedio:311 },
  hoy_ventas:{ venta:41000, tickets:130, utilidad:9000 },
  por_dia:DIAS,
  por_hora:[{ dow:1, hora:9, venta:1000, tickets:4 }, { dow:6, hora:18, venta:9000, tickets:30 }],
  por_metodo:[{ metodo:'efectivo', monto:1000000 }, { metodo:'tarjeta', monto:500000 }],
  top_productos:[{ nombre:'Arroz Progreso 5 lb', venta:98000, margen:18, unidades:900 }],
  margen_bajo:[], por_categoria:[{ categoria:'Granos', venta:310000, utilidad:60000 }],
  por_sucursal:[{ sucursal:'Central', venta:1000000, utilidad:220000, tickets:3000 },
                { sucursal:'Choloma', venta:500000, utilidad:110000, tickets:1800 }],
  por_cajero:[{ cajero:'Carlos Mejía', codigo:'C2', venta:500000, tickets:1500, anuladas:15,
                monto_anulado:2500, faltante:-850 }],
  caja:{ turnos:60, con_diferencia:2, faltante:0, sobrante:0, abiertos:1 },
  inventario:{ valor_costo:1800000, dias_inventario:41, productos:2100, bajo_minimo:0,
               agotados:0, agotados_lista:[], sin_movimiento:0, valor_sin_movimiento:0 },
  vencimientos:{ vencidos:0, valor_vencido:0, por_vencer_30:0, valor_por_vencer_30:0 },
  fiado:{ total:0, clientes:0, atrasado:0, clientes_atrasados:0, mas_30:0 },
  por_pagar:{ total:0, facturas:0, vencido:0, vence_7:0 },
  compras:{ total:900000, facturas:30 },
  merma:{ total:5000, porcentaje:0.3, pendientes:0 },
  ofertas_activas:3, ...extra });

async function montar(estado){
  const html = fs.readFileSync(BASE + 'tablero.html', 'utf8');
  const cuerpo = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  const dom = new JSDOM(
    html.replace(/<script type="module">[\s\S]*?<\/script>/, '')
        .replace(/<script src="config\.js"><\/script>/, ''),
    { runScripts:'outside-only', url:'https://x.test/tablero.html', pretendToBeVisual:true });
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
           signInWithPassword: async () => ({ error:null }), signOut: async () => {} },
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
  await w.eval(`(async () => { ${prep} })()`);
  await esperar(160);
  return { w, d:w.document };
}

console.log('\n=== QUIÉN LO VE ===');
{
  const estado = { rpc:{ fn_pos_contexto:{ data:CTX(1), error:null } } };
  const { d } = await montar(estado);
  chk('la auxiliar no lo ve', !d.querySelector('#p-bloqueado').classList.contains('oculto'));
  chk('y ni se pide el tablero', !estado.llamadas.some(l => l.fn === 'fn_tablero'));
}

console.log('\n=== EL GERENTE ===');
{
  const estado = { rpc:{ fn_pos_contexto:{ data:CTX(3), error:null },
                         fn_tablero:{ data:DATOS(), error:null } } };
  const { w, d } = await montar(estado);
  const t = d.body.textContent;
  const pide = estado.llamadas.find(l => l.fn === 'fn_tablero');
  chk('pide el tablero', !!pide);
  chk('de 30 días por defecto', pide && pide.args.p_desde && pide.args.p_hasta && !pide.args.p_sucursal_id);
  chk('la venta en grande', /L 1,500,000/.test(d.querySelector('.kpi.fuerte').textContent));
  chk('sube contra el período anterior', d.querySelector('.kpi.fuerte .delta.sube'));
  chk('la utilidad baja y se marca', d.querySelectorAll('.kpi')[1].querySelector('.delta.baja'));
  chk('el margen', /margen 24\.5%/.test(t));
  chk('la gráfica de días', d.querySelector('#graf-dias svg path'));
  chk('y su tabla, para quien no ve la gráfica', d.querySelectorAll('#tabla-dias tbody tr').length === 30);
  chk('el mapa de horas', d.querySelectorAll('.calor td[style]').length === 2);
  chk('el producto que más se vende', /Arroz Progreso 5 lb/.test(t));
  chk('el cajero con su faltante', /Carlos Mejía/.test(t) && /850\.00/.test(t));
  chk('dos sucursales: aparece el filtro', !d.querySelector('#f-sucursal').classList.contains('oculto'));
  chk('y la tabla de sucursales', /Choloma/.test(d.querySelector('#contenido').textContent));
  chk('sin problemas no inventa alertas', d.querySelector('.todo-bien'));

  d.querySelector('[data-r="7"]').click();
  await esperar();
  const p7 = estado.llamadas.filter(l => l.fn === 'fn_tablero').pop();
  const dias = (new Date(p7.args.p_hasta) - new Date(p7.args.p_desde)) / 864e5 + 1;
  chk('7 días pide 7 días', dias === 7);
  const sel = d.querySelector('#f-sucursal');
  sel.value = 's2'; sel.dispatchEvent(new w.Event('change'));
  await esperar();
  chk('elegir sucursal la manda', estado.llamadas.filter(l => l.fn === 'fn_tablero').pop().args.p_sucursal_id === 's2');
}

console.log('\n=== LO QUE PIDE ATENCIÓN ===');
{
  const estado = { rpc:{ fn_pos_contexto:{ data:CTX(4), error:null },
    fn_tablero:{ data:DATOS({
      vencimientos:{ vencidos:4, valor_vencido:3369.6, por_vencer_30:2, valor_por_vencer_30:500 },
      inventario:{ valor_costo:1, dias_inventario:1, productos:1, bajo_minimo:5, agotados:2,
                   agotados_lista:[{ nombre:'Leche Sula 1 L' }, { nombre:'Atún' }],
                   sin_movimiento:0, valor_sin_movimiento:0 },
      caja:{ turnos:10, con_diferencia:2, faltante:-970, sobrante:0, abiertos:0 },
      por_pagar:{ total:50000, facturas:3, vencido:38900, vence_7:1000 },
      fiado:{ total:2000, clientes:3, atrasado:1200, clientes_atrasados:2, mas_30:0 },
      margen_bajo:[{ nombre:'Azúcar', venta:5000, margen:-2.4 }],
      merma:{ total:30000, porcentaje:1.9, pendientes:1 } }), error:null } } };
  const { d } = await montar(estado);
  const alertas = [...d.querySelectorAll('.alerta')];
  const vis = alertas.filter(a => !a.classList.contains('oculto'));
  chk('los vencidos con su valor', alertas.some(a => /4 lotes vencidos/.test(a.textContent) && /3,369\.60/.test(a.textContent)));
  chk('los agotados con su nombre', alertas.some(a => /Leche Sula/.test(a.textContent)));
  chk('el faltante de caja', alertas.some(a => /Faltante de caja: L 970\.00/.test(a.textContent)));
  chk('las facturas vencidas', alertas.some(a => /38,900\.00/.test(a.textContent)));
  chk('el precio bajo el costo', alertas.some(a => /casi sin ganancia/.test(a.textContent)));
  chk('las rojas van primero', alertas[0].classList.contains('mal'));
  chk('no más de 6 a la vista', vis.length === 6);
  d.querySelector('#b-mas-alertas').click();
  chk('y el resto con un toque', [...d.querySelectorAll('.alerta')].every(a => !a.classList.contains('oculto')));
}

console.log('\n=== UN ERROR NO DEJA LA PANTALLA EN BLANCO ===');
{
  const estado = { rpc:{ fn_pos_contexto:{ data:CTX(3), error:null },
                         fn_tablero:{ data:null, error:{ message:'P0001: El tablero llega hasta un año a la vez' } } } };
  const { d } = await montar(estado);
  chk('dice qué pasó', /hasta un año/.test(d.querySelector('#contenido').textContent));
}

console.log(`\n${ok} bien · ${mal} mal`);
process.exit(mal ? 1 : 0);
