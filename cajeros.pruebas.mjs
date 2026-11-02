/* Prueba de la pantalla de Cajeros: indicadores por cajero y permisos. */
import fs from 'node:fs';
import { JSDOM } from 'jsdom';
import { fileURLToPath } from 'node:url';

const BASE = fileURLToPath(new URL('./', import.meta.url));
let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); } else { mal++; console.log('  MAL  ' + n); } };
const esperar = (ms = 100) => new Promise(r => setTimeout(r, ms));

const CTX = nivel => ({ usuario:{ id:'u1', nombre:'Somar', rol:nivel >= 3 ? 'gerente' : nivel === 2 ? 'supervisor' : 'auxiliar', nivel },
  organizacion:{ id:'o1', nombre:'Pulpería', moneda:'HNL' }, sucursales:[{ id:'s1', nombre:'Central' }] });
const DATOS = { desde:'2026-10-27', hasta:'2026-11-02', cajeros:[
  { id:'a', nombre:'Ana', rol:'auxiliar', activo:true, numero:2, codigo:'ANA', ventas:120, total:15000, ticket_promedio:125,
    unidades:900, lineas:600, horas:40, horas_activas:40, turnos:5, articulos_hora:15, ventas_hora:3, segundos_venta:95, ventas_medidas:100,
    anuladas:1, quitadas:4, canceladas:2, descuadre:-50, en_turno:true },
  { id:'b', nombre:'Beto', rol:'auxiliar', activo:true, numero:3, codigo:null, ventas:200, total:9000, ticket_promedio:45,
    unidades:500, lineas:400, horas:20, horas_activas:20, turnos:3, articulos_hora:20, ventas_hora:10, segundos_venta:60, ventas_medidas:200,
    anuladas:0, quitadas:0, canceladas:0, descuadre:0, en_turno:false } ] };

async function montar(estado, url = 'https://x.test/cajeros.html'){
  const html = fs.readFileSync(BASE + 'cajeros.html', 'utf8');
  const cuerpo = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  const dom = new JSDOM(html.replace(/<script type="module">[\s\S]*?<\/script>/, '')
      .replace(/<script src="(config|tema)\.js"><\/script>/g, ''),
    { runScripts:'outside-only', url, pretendToBeVisual:true });
  const w = dom.window;
  w.SUPABASE_CONFIG = { url:'https://x.supabase.co', key:'k' };
  w.matchMedia = () => ({ matches:false, addEventListener(){}, removeEventListener(){} });
  globalThis.window = w; globalThis.document = w.document; globalThis.localStorage = w.localStorage;
  estado.llamadas = [];
  w.__sb = { auth:{ getSession: async () => ({ data:{ session:{ user:{ id:'u1' } } } }), signOut: async () => {}, onAuthStateChange(){} },
    rpc: async (fn, args) => { estado.llamadas.push({ fn, args }); const h = estado.rpc[fn];
      return h === undefined ? { data:null, error:{ message:'sin simular' } } : (typeof h === 'function' ? h(args) : h); } };
  const menu = await import(BASE + 'menu.js');
  w.montarMenu = menu.montarMenu; w.escapar = menu.escapar;
  const prep = cuerpo.replace(/^import .*$/mg, '').replace(/createClient\([^)]*\{[\s\S]*?\}\s*\}\)/, '__sb');
  await w.eval(`(async () => { ${prep} })()`);
  await esperar(150);
  return { w, d:w.document, estado };
}

console.log('\n=== CAJEROS ===');
{
  const estado = { rpc:{ fn_pos_contexto:{ data:CTX(3), error:null }, fn_cajeros_indicadores:{ data:DATOS, error:null } } };
  const { d } = await montar(estado);
  const t = d.querySelector('#contenido').textContent.replace(/\s+/g, ' ');
  chk('pide los indicadores de los últimos 7 días', estado.llamadas.some(l => l.fn === 'fn_cajeros_indicadores' && l.args.p_desde && l.args.p_hasta));
  chk('una fila por cajero', d.querySelectorAll('tbody tr').length === 2);
  chk('ordena por ventas: Beto primero', /Beto/.test(d.querySelector('tbody tr').textContent));
  chk('artículos por hora y tiempo por venta', /20/.test(d.querySelector('tbody tr').textContent) && /1:00/.test(d.querySelector('tbody tr').textContent));
  chk('el ID y el código del cajero', /ID 002 · ANA/.test(t));
  chk('quién está en turno', !!d.querySelector('.punto'));
  chk('el descuadre en rojo', !!d.querySelector('td.malo'));
  chk('arriba los totales', /Ventas en caja\s*320/i.test(t) && /Artículos por hora\s*16\.7/.test(t) && /1:12/.test(t));
  d.querySelector('[data-orden="total"]').click();
  await esperar(20);
  chk('se puede ordenar por lo vendido', /Ana/.test(d.querySelector('tbody tr').textContent));
  d.querySelector('[data-r="hoy"]').click();
  await esperar(60);
  const ult = estado.llamadas.filter(l => l.fn === 'fn_cajeros_indicadores').pop();
  chk('Hoy pide un solo día', ult.args.p_desde === ult.args.p_hasta);
}
{
  const estado = { rpc:{ fn_pos_contexto:{ data:CTX(1), error:null } } };
  const { d } = await montar(estado);
  chk('la cajera no entra', !d.querySelector('#p-bloqueado').classList.contains('oculto'));
}

console.log('\n=== CIERRES DE CAJA ===');
{
  const CIERRES = { desde:'2026-10-27', hasta:'2026-11-02', abiertos:1, cierres:[
    { turno_id:'t1', sucursal:'Central', caja:'Caja 1', cajero:'Ana', abierto_en:'2026-11-01T14:00:00Z', cerrado_en:'2026-11-02T06:00:00Z',
      automatico:true, monto_inicial:500, esperado:1872, declarado:null, diferencia:null, cerro:null,
      notas:'Cerrado automáticamente a medianoche', ventas:12, total:1600, metodos:{ efectivo:1400, tarjeta:200 },
      abonos:50, devoluciones:0, fondos:0, retiros:78 },
    { turno_id:'t2', sucursal:'Central', caja:'Caja 2', cajero:'Beto', abierto_en:'2026-11-01T13:00:00Z', cerrado_en:'2026-11-01T23:00:00Z',
      automatico:false, monto_inicial:300, esperado:900, declarado:880, diferencia:-20, cerro:'Somar',
      notas:null, ventas:8, total:800, metodos:{ efectivo:600, credito:200 }, abonos:0, devoluciones:0, fondos:0, retiros:0 } ] };
  const estado = { rpc:{ fn_pos_contexto:{ data:CTX(2), error:null }, fn_cierres_caja:{ data:CIERRES, error:null },
                         fn_cajeros_indicadores:{ data:DATOS, error:null } } };
  const { w, d } = await montar(estado, 'https://x.test/cajeros.html?vista=cierres');
  const t = () => d.querySelector('#contenido').textContent.replace(/\s+/g, ' ');
  chk('con ?vista=cierres abre los cierres', estado.llamadas.some(l => l.fn === 'fn_cierres_caja')
      && !estado.llamadas.some(l => l.fn === 'fn_cajeros_indicadores'));
  chk('la pestaña marcada y el título', d.querySelector('[data-v="cierres"]').classList.contains('si')
      && d.querySelector('.barra-titulo b').textContent === 'Cierres de caja');
  chk('una fila por cierre', d.querySelectorAll('tbody tr.ci').length === 2);
  chk('el automático lleva su sello y dice sin contar', /Automático/.test(d.querySelector('tbody tr.ci').textContent)
      && /Sin contar/.test(d.querySelector('tbody tr.ci').textContent));
  chk('cada forma de pago en su columna', /L 1,400\.00/.test(t()) && /L 200\.00/.test(t()));
  chk('el faltante en rojo', d.querySelector('tbody tr.ci:nth-of-type(2) td.malo')?.textContent.includes('-20') ||
      [...d.querySelectorAll('td.malo')].some(x => /-L 20\.00|L -20\.00|-20/.test(x.textContent)));
  chk('arriba: automáticos y abiertos', /Automáticos\s*1/.test(t()) && /Abiertos ahora\s*1/.test(t()));
  const fila = d.querySelector('tbody tr.ci');
  fila.focus();
  fila.dispatchEvent(new w.KeyboardEvent('keydown', { key:'Enter', bubbles:true }));
  await esperar(20);
  chk('con Enter se abre el detalle', !!d.querySelector('tr.ci-det') && /Fondo inicial/.test(t()) && /El sistema, a medianoche/.test(t()));
  d.querySelector('[data-v="indicadores"]').click();
  await esperar(80);
  chk('la otra pestaña vuelve a los indicadores', estado.llamadas.some(l => l.fn === 'fn_cajeros_indicadores'));
}

console.log(`\n${ok} bien · ${mal} mal`);
process.exit(mal ? 1 : 0);
