/* Prueba de Finanzas y del menú nuevo: quién entra, el estado de
   resultados, las secciones colgando de su opción, los egresos y el color
   de la marca. */
import fs from 'node:fs';
import { JSDOM } from 'jsdom';

const BASE = new URL('./', import.meta.url).pathname;
let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };
const esperar = (ms = 80) => new Promise(r => setTimeout(r, ms));

const CTX = (nivel, color = '#7C3AED') => ({
  usuario:{ id:'u1', nombre:'Doña Marta', rol: nivel >= 3 ? 'gerente' : nivel === 2 ? 'supervisor' : 'auxiliar', nivel },
  organizacion:{ id:'o1', nombre:'Abarrotería El Buen Precio', moneda:'HNL', color, logo_path:null },
  sucursales:[{ id:'s1', nombre:'Central' }] });

const RESUMEN = (ve = true) => ({
  desde:'2026-10-01', hasta:'2026-10-31', dias:31, hoy:'2026-10-31', puede_ver_utilidad:ve,
  resultados: ve ? { venta_bruta:1150, isv:150, devoluciones:0, venta_neta:1000, costo_ventas:750,
    utilidad_bruta:250, merma:10, gastos:300, gastos_por_clase:{ operativo:300 },
    utilidad_neta:-60, retiros_dueno:100 } : null,
  gastos_por_categoria:[{ categoria:'Alquiler', clase:'operativo', monto:300, veces:1 }],
  indicadores:{ margen_bruto: ve ? 25 : null, markup: ve ? 33.3 : null, margen_neto: ve ? -6 : null,
    gasto_sobre_venta:30, punto_equilibrio: ve ? 1240 : null, venta_diaria:37.1, ticket_promedio:115,
    inventario: ve ? 5000 : null, rotacion: ve ? 1.8 : null, dias_inventario: ve ? 200 : null,
    fiado:0, dias_cobro:null, merma_sobre_venta:0.87 },
  caja:{ turnos:2, cuadrados:1, faltante:-30, sobrante:0, arqueos:1, anuladas:1, monto_anulado:60,
    devoluciones:0, monto_devuelto:0, abortadas:2, monto_abortado:230.5, suspendidas:3,
    monto_suspendido:90, retomadas:2, descartadas:1, lineas_quitadas:4, monto_quitado:120 },
  flujo:{ cobros:{ efectivo:900, tarjeta:250 }, egresos:400, egresos_por_origen:{ banco:300, caja:100 }, compras:800 } });

const EGRESOS = [
  { id:'e1', fecha:'2026-10-20', categoria:'Alquiler', clase:'operativo', concepto:'Local', monto:300,
    metodo:'transferencia', origen:'banco', registro:'Doña Marta', anulado:false },
  { id:'e2', fecha:'2026-10-18', categoria:'Agua', clase:'operativo', concepto:'Garrafones', monto:40,
    metodo:'efectivo', origen:'caja', caja:'Caja 1', registro:'Doña Marta', anulado:true, motivo_anulacion:'Duplicado' }];

async function montar(estado, hash = ''){
  const html = fs.readFileSync(BASE + 'finanzas.html', 'utf8');
  const cuerpo = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  const dom = new JSDOM(
    html.replace(/<script type="module">[\s\S]*?<\/script>/, '')
        .replace(/<script src="(config|tema)\.js"><\/script>/g, ''),
    { runScripts:'outside-only', url:'https://x.test/finanzas.html' + hash, pretendToBeVisual:true });
  const w = dom.window;
  w.SUPABASE_CONFIG = { url:'https://x.supabase.co', key:'k' };
  Object.defineProperty(w.navigator, 'serviceWorker',
    { value:{ register: async () => ({}) }, configurable:true });
  w.matchMedia = () => ({ matches:false, addEventListener(){}, removeEventListener(){} });
  globalThis.window = w; globalThis.document = w.document;
  globalThis.localStorage = w.localStorage; globalThis.matchMedia = w.matchMedia;
  globalThis.location = w.location;
  // el tema de verdad, para ver que el menú lo aplique
  w.eval(fs.readFileSync(BASE + 'tema.js', 'utf8'));

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

const base = (nivel = 3, extra = {}) => ({ rpc:{
  fn_pos_contexto:{ data:CTX(nivel), error:null },
  fn_finanzas_resumen:{ data:RESUMEN(nivel >= 3), error:null },
  fn_finanzas_lista: a => ({ data: a.p_seccion === 'egresos' ? EGRESOS : [], error:null }),
  fn_categorias_egreso:{ data:[{ id:'c1', nombre:'Alquiler', clase:'operativo' },
                              { id:'c2', nombre:'Retiro del dueño', clase:'retiro_dueno' }], error:null },
  fn_cajas_abiertas:{ data:[{ turno_id:'t1', caja:'Caja 1', cajero:'Ana', en_gaveta:500 }], error:null },
  fn_registrar_egreso:{ data:{ ok:true }, error:null },
  fn_anular_egreso:{ data:true, error:null },
  ...extra } });

console.log('\n=== QUIÉN ENTRA ===');
{
  const estado = base(1);
  const { d } = await montar(estado);
  chk('la auxiliar no entra', !d.querySelector('#p-bloqueado').classList.contains('oculto'));
  chk('ni se pide el resumen', !estado.llamadas.some(l => l.fn === 'fn_finanzas_resumen'));
}

console.log('\n=== EL MENÚ NUEVO ===');
{
  const estado = base(3);
  const { w, d } = await montar(estado);
  const nodo = d.querySelector('.menu-nodo.actual');
  chk('Finanzas está marcada como la pantalla actual', nodo?.dataset.modulo === 'finanzas');
  chk('sus secciones cuelgan justo debajo de ella, no al final',
      nodo && nodo.querySelector('#menu-secciones [data-valor="egresos"]'));
  chk('son nueve', d.querySelectorAll('#menu-secciones [data-valor]').length === 9);
  chk('están agrupadas por área', [...d.querySelectorAll('.menu-titulo')].map(t => t.textContent)
      .join(',') === 'Venta,Inventario,Compras,Finanzas,Administración');
  chk('el gerente ve Tablero y Configuración',
      d.querySelector('[data-modulo="tablero"]') && d.querySelector('[data-modulo="configuracion"]'));
  const flecha = d.querySelector('[data-m="desplegar"]');
  chk('la flecha para plegar se ve', flecha && !flecha.classList.contains('oculto'));
  flecha.click();
  chk('y pliega las secciones', nodo.classList.contains('plegado') && flecha.getAttribute('aria-expanded') === 'false');
  flecha.click();
  chk('y las vuelve a abrir', !nodo.classList.contains('plegado'));
  chk('las iniciales del negocio en la marca', d.querySelector('.menu-marca').textContent.trim() === 'AE');
  chk('el color de la marca se aplicó',
      d.documentElement.style.getPropertyValue('--marca').toUpperCase() === '#7C3AED');
  chk('con un tono legible para texto', /^#[0-9A-F]{6}$/i.test(d.documentElement.style.getPropertyValue('--marca-tinta')));
}
{
  const estado = base(2);
  const { d } = await montar(estado);
  chk('el supervisor no ve Tablero ni Configuración en el menú',
      !d.querySelector('[data-modulo="tablero"]') && !d.querySelector('[data-modulo="configuracion"]'));
}

console.log('\n=== EL RESUMEN ===');
{
  const estado = base(3);
  const { d } = await montar(estado);
  const t = d.querySelector('#contenido').textContent;
  const pide = estado.llamadas.find(l => l.fn === 'fn_finanzas_resumen');
  chk('pide el resumen del mes', pide && /-01$/.test(pide.args.p_desde));
  chk('el estado de resultados', /Estado de resultados/.test(t) && /Utilidad neta/.test(t));
  chk('la utilidad neta en negativo se marca', d.querySelector('.er tr.total.neg'));
  chk('el markup al lado del margen', /Markup 33\.3%/.test(t));
  chk('el retiro del dueño aparte, no como gasto', /Retiros del dueño/.test(t));
  chk('el punto de equilibrio dice cuánto falta', /Faltan .*240\.00/.test(t));
  chk('los contadores de la caja', d.querySelectorAll('.ctrl [data-ir]').length === 7);
  chk('las abortadas con su monto', /Ventas abortadas/.test(t) && /230\.50/.test(t));
  d.querySelector('.ctrl [data-ir="abortadas"]').click();
  await esperar();
  chk('tocar un contador lleva a su sección',
      estado.llamadas.some(l => l.fn === 'fn_finanzas_lista' && l.args.p_seccion === 'abortadas'));
  chk('y el menú la marca', d.querySelector('#menu-secciones [data-valor="abortadas"]').classList.contains('activo'));
}
{
  const estado = base(2);
  const { d } = await montar(estado);
  const t = d.querySelector('#contenido').textContent;
  chk('el supervisor no ve el estado de resultados', !/Estado de resultados/.test(t));
  chk('ni el markup', !/Markup/.test(t));
  chk('pero sí la caja', /Faltantes de caja/.test(t));
}

console.log('\n=== EGRESOS ===');
{
  const estado = base(3);
  const { w, d } = await montar(estado, '#egresos');
  chk('entra directo a la sección del enlace',
      estado.llamadas.some(l => l.fn === 'fn_finanzas_lista' && l.args.p_seccion === 'egresos'));
  chk('la lista', d.querySelectorAll('.tabla tbody tr').length === 2);
  chk('el anulado se ve tachado', d.querySelector('.tabla tr.anulado'));
  chk('el total no cuenta el anulado', /total L 300\.00/.test(d.querySelector('.pie-lista').textContent));
  chk('cada dato lleva su etiqueta para el celular', d.querySelector('.tabla td[data-l="Monto"]'));

  d.querySelector('#b-nuevo').click();
  await esperar(120);
  chk('abre la hoja de egreso', /Registrar egreso/.test(d.querySelector('#hoja').textContent));
  d.querySelector('#eg-si').click();
  await esperar();
  chk('sin concepto no registra', /Escriba en qué se gastó/.test(d.querySelector('#eg-error').textContent));
  d.querySelector('#eg-concepto').value = 'Garrafones';
  d.querySelector('#eg-monto').value = '1,250.50';
  d.querySelector('#eg-origen [data-o="caja"]').click();
  chk('de la gaveta pide la caja', !d.querySelector('#eg-caja-g').classList.contains('oculto'));
  chk('y avisa que el arqueo ya lo cuenta', !d.querySelector('#eg-aviso-caja').classList.contains('oculto'));
  d.querySelector('#eg-si').click();
  await esperar(120);
  const reg = estado.llamadas.find(l => l.fn === 'fn_registrar_egreso');
  chk('registra con el monto bien leído', reg && reg.args.p_monto === 1250.5);
  chk('desde la gaveta con su turno', reg && reg.args.p_origen === 'caja' && reg.args.p_turno_id === 't1');
  chk('y cierra la hoja', d.querySelector('#velo').classList.contains('oculto'));

  d.querySelector('[data-anular="e1"]').click();
  await esperar();
  d.querySelector('#an-motivo').value = 'Se registró dos veces';
  d.querySelector('#an-si').click();
  await esperar(120);
  chk('anula con su motivo', estado.llamadas.some(l => l.fn === 'fn_anular_egreso'
      && l.args.p_egreso_id === 'e1' && l.args.p_motivo === 'Se registró dos veces'));
}
{
  const estado = base(2);
  const { d } = await montar(estado, '#egresos');
  chk('el supervisor no tiene botón de anular', !d.querySelector('[data-anular]'));
}

console.log('\n=== EL TEMA ===');
{
  const dom = new JSDOM('<!doctype html><html><head><meta name="theme-color" content="#000"></head><body></body></html>',
    { runScripts:'outside-only', url:'https://x.test/' });
  const w = dom.window;
  w.eval(fs.readFileSync(BASE + 'tema.js', 'utf8'));
  const T = w.PulpeandoTema;
  chk('sin color guardado usa el de fábrica',
      w.document.documentElement.style.getPropertyValue('--marca') === T.FABRICA);
  const am = T.tonos('#FACC15');
  chk('un amarillo lleva letra oscura encima', am['--marca-sobre'] === '#0F1729');
  chk('y su versión para texto tiene contraste 4.5', T.contraste(am['--marca-tinta'], '#FFFFFF') >= 4.5);
  const az = T.tonos('#1D4ED8');
  chk('un azul fuerte lleva letra blanca', az['--marca-sobre'] === '#FFFFFF');
  chk('y se usa tal cual para texto', az['--marca-tinta'] === '#1D4ED8');
  chk('un color mal escrito no se aplica', T.tonos('red; x')['--marca'] === T.FABRICA);
  T.aplicar('#BE123C');
  chk('aplicar lo recuerda para la próxima vez', w.localStorage.getItem('pulpeando.color') === '#BE123C');
  chk('y pinta la barra del navegador', w.document.querySelector('meta[name="theme-color"]').content === '#BE123C');
  chk('todos los sugeridos se leen con su letra encima',
      T.SUGERIDOS.every(([c]) => T.contraste(c, T.tonos(c)['--marca-sobre']) >= 4.5));
}

console.log(`\n${ok} bien · ${mal} mal`);
process.exit(mal ? 1 : 0);
