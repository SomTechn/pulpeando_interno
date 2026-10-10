/* Prueba funcional de la app del repartidor, manejada como la usaria en la
   calle: entrar, ver a donde va, salir, cobrar, entregar o reportar que no
   se pudo. */
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';

const RUTA = fileURLToPath(new URL('./index.html', import.meta.url));
let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };

const JORNADA = (extra = {}) => ({ nombre:'Rafa Mejía', rol:'repartidor', negocio:'Pulpería La Esquina',
  moneda:'HNL', entregados:1, efectivo:150, envios:25,
  hoy:[{ numero:'P-000009', cliente:'Juan', total:150, metodo_pago:'efectivo',
         entregado_en:new Date().toISOString() }], ...extra });

const ENTREGAS = () => [
  { pedido_id:'e1', numero:'P-000011', estado:'en_ruta', tienda:'La Esquina', tienda_dir:'Col. Las Flores',
    tienda_tel:'9999-1', cliente:'Doña Marta', telefono:'9988-7766',
    direccion:'Col. López Arellano, casa 12', referencia:'Portón verde frente a la iglesia',
    latitud:15.61, longitud:-87.95, total:230, costo_envio:30, metodo_pago:'efectivo', paga_con:500,
    cobrado:true, notas:'Tocar fuerte', productos:4, incidencia:null, programado_para:null,
    creado_en:new Date().toISOString() },
  { pedido_id:'e2', numero:'P-000012', estado:'listo', tienda:'La Esquina', tienda_dir:'Col. Las Flores',
    tienda_tel:null, cliente:'Juan Pérez', telefono:null, direccion:'Res. Choloma, bloque 4',
    referencia:null, latitud:null, longitud:null, total:150, costo_envio:25,
    metodo_pago:'transferencia', paga_con:null, cobrado:true, notas:null, productos:1,
    incidencia:'No abren', programado_para:null, creado_en:new Date().toISOString() }
];

async function montar(estado){
  const html = fs.readFileSync(RUTA, 'utf8');
  const cuerpo = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  const dom = new JSDOM(
    html.replace(/<script type="module">[\s\S]*?<\/script>/, '')
        .replace(/<script src="\.\.\/config\.js"><\/script>/, ''),
    { runScripts:'outside-only', url:'https://x.test/repartidor/', pretendToBeVisual:true });

  const w = dom.window;
  w.SUPABASE_CONFIG = { url:'https://x.supabase.co', key:'k' };
  Object.defineProperty(w.navigator, 'serviceWorker',
    { value:{ register: async () => ({}) }, configurable:true });
  estado.vibro = 0;
  Object.defineProperty(w.navigator, 'vibrate', { value:() => { estado.vibro++; return true; },
    configurable:true });
  w.setInterval = () => 0;      // la recarga automatica se prueba llamando a cargar()

  estado.llamadas = [];
  w.__sb = {
    auth:{
      getSession: async () => ({ data:{ session:estado.sesion === false ? null : { user:{ id:'r1' } } } }),
      signInWithPassword: async () => ({ error:estado.malaClave ? { message:'x' } : null }),
      signOut: async () => {}
    },
    rpc: async (fn, args) => {
      estado.llamadas.push({ fn, args });
      const h = estado.rpc[fn];
      if (h === undefined) return { data:null, error:{ message:'sin simular: ' + fn } };
      return typeof h === 'function' ? h(args) : h;
    }
  };

  const prep = cuerpo
    .replace(/^import \{ createClient \} from 'https:\/\/esm\.sh\/@supabase\/supabase-js@2';$/m, '')
    .replace(/createClient\(SUPABASE_URL, SUPABASE_KEY, \{[\s\S]*?\}\)/, '__sb');

  w.__m = {};
  await w.eval(`(async () => { ${prep}
    ; window.__m.S = S; window.__m.cargar = cargar;
  })()`);
  await new Promise(r => setTimeout(r, 150));
  return { w, d:w.document, m:w.__m, estado };
}

const esperar = (ms = 120) => new Promise(r => setTimeout(r, ms));
const ultima = (e, fn) => [...e.llamadas].reverse().find(l => l.fn === fn);
const txt = el => el.textContent.replace(/\s+/g, ' ').trim();

function base(){
  const estado = { entregas:ENTREGAS(), jornada:JORNADA(), rpc:{} };
  estado.rpc.fn_mi_jornada = () => ({ data:estado.jornada, error:null });
  estado.rpc.fn_mis_entregas = () => ({ data:estado.entregas, error:null });
  estado.rpc.fn_pedido_lineas = { data:[
    { producto:'Arroz 5 lb', cantidad:2, cantidad_surtida:null },
    { producto:'Aceite 500 ml', cantidad:3, cantidad_surtida:1 },
    { producto:'Frijol', cantidad:1, cantidad_surtida:0 } ], error:null };
  estado.rpc.fn_cambiar_estado_pedido = a => {
    const e = estado.entregas.find(x => x.pedido_id === a.p_pedido_id);
    if (a.p_estado === 'entregado'){
      estado.entregas = estado.entregas.filter(x => x !== e);
      estado.jornada = { ...estado.jornada, entregados:estado.jornada.entregados + 1,
        efectivo:estado.jornada.efectivo + (e.metodo_pago === 'efectivo' ? e.total : 0) };
    } else e.estado = a.p_estado;
    return { data:null, error:null };
  };
  estado.rpc.fn_entrega_fallida = a => {
    const e = estado.entregas.find(x => x.pedido_id === a.p_pedido_id);
    e.estado = 'listo'; e.incidencia = a.p_motivo;
    return { data:null, error:null };
  };
  return estado;
}

/* ===================================================================== */
console.log('\n=== ENTRAR ===');
{
  const estado = base(); estado.sesion = false;
  const { d } = await montar(estado);
  chk('sin sesión pide entrar', !d.querySelector('#p-entrar').classList.contains('oculto'));
}
{
  const estado = base();
  estado.jornada = JORNADA({ rol:'auxiliar' });
  const { d } = await montar(estado);
  chk('un auxiliar no usa esta app', !d.querySelector('#p-otro').classList.contains('oculto') &&
      d.querySelector('#app').classList.contains('oculto'));
}

console.log('\n=== LA CABECERA ===');
{
  const { d } = await montar(base());
  chk('su nombre y la tienda', d.querySelector('#c-nombre').textContent === 'Rafa Mejía' &&
      /La Esquina/.test(d.querySelector('#c-negocio').textContent));
  chk('el efectivo que lleva', d.querySelector('#c-efectivo').textContent === 'L 150.00');
  chk('lo entregado hoy', d.querySelector('#c-entregados').textContent === '1');
  chk('cuántas le faltan', /Por entregar \(2\)/.test(d.querySelector('#t-pend').textContent));
}

console.log('\n=== UNA ENTREGA ===');
{
  const { d } = await montar(base());
  const [a, b] = d.querySelectorAll('.ent');
  chk('primero la que va en camino', a.classList.contains('ruta') && /En camino/.test(txt(a)));
  chk('cliente, dirección y referencia', /Doña Marta/.test(txt(a)) && /López Arellano/.test(txt(a)) &&
      /Portón verde/.test(txt(a)));
  chk('la nota del cliente', /Tocar fuerte/.test(txt(a)));
  const [tel, wa, mapa] = a.querySelectorAll('.acc');
  chk('llamar', tel.getAttribute('href') === 'tel:9988-7766');
  chk('WhatsApp con 504 delante', wa.getAttribute('href') === 'https://wa.me/50499887766');
  chk('cómo llegar con las coordenadas', /destination=15.61,-87.95/.test(mapa.getAttribute('href')));
  chk('cuánto cobrar en efectivo', /Cobrar en efectivo/.test(txt(a)) && /L 230\.00/.test(txt(a)));
  chk('y el vuelto que debe llevar', /lleve de vuelto L 270\.00/.test(txt(a)));

  chk('la otra: por recoger en la tienda', /Por recoger/.test(txt(b)) && /Recójalo en La Esquina/.test(txt(b)));
  chk('pagada por transferencia: no cobre', /No cobre efectivo/.test(txt(b)) && /transferencia/.test(txt(b)));
  chk('sin teléfono los botones se apagan',
      b.querySelectorAll('.acc')[0].getAttribute('aria-disabled') === 'true' &&
      b.querySelectorAll('.acc')[1].getAttribute('aria-disabled') === 'true');
  chk('sin coordenadas el mapa busca la dirección',
      /search\/\?api=1&query=Res\.%20Choloma/.test(b.querySelectorAll('.acc')[2].getAttribute('href')));
  chk('la incidencia anterior se ve', /No se pudo entregar: No abren/.test(txt(b)));
}
{
  const estado = base();
  const { d } = await montar(estado);
  d.querySelector('[data-prods="e1"]').click();
  await esperar();
  const items = [...d.querySelectorAll('.ent')[0].querySelectorAll('.prods li')].map(txt);
  chk('ver lo que lleva: lo surtido, sin lo que faltó', items.length === 2 &&
      items[0] === '2 Arroz 5 lb' && items[1] === '1 Aceite 500 ml');
}

console.log('\n=== SALIR Y ENTREGAR ===');
{
  const estado = base();
  const { d } = await montar(estado);
  d.querySelector('[data-salir="e2"]').click();
  await esperar();
  chk('«salgo» la pone en ruta', ultima(estado, 'fn_cambiar_estado_pedido').args.p_estado === 'en_ruta');
  chk('y la tarjeta cambia', d.querySelectorAll('.ent.ruta').length === 2);

  d.querySelector('[data-entregar="e1"]').click();
  await esperar(50);
  const h = txt(d.querySelector('#hoja'));
  chk('pide confirmar lo cobrado', /Confirme que recibió L 230\.00/.test(h) && /dio L 270\.00 de vuelto/.test(h));
  d.querySelector('#h-si').click();
  await esperar(200);
  chk('marca entregado', estado.llamadas.some(l => l.fn === 'fn_cambiar_estado_pedido' &&
      l.args.p_pedido_id === 'e1' && l.args.p_estado === 'entregado'));
  chk('suma al efectivo que lleva', d.querySelector('#c-efectivo').textContent === 'L 380.00');
  chk('lo avisa', /Lleva L 380\.00 en efectivo/.test(d.querySelector('#flot').textContent));
  chk('y sale de la lista', d.querySelectorAll('.ent').length === 1);
}
{
  const estado = base();
  estado.rpc.fn_cambiar_estado_pedido = { data:null, error:{ message:
    'P0001: El pedido P-000012 todavía no está cobrado. Cóbrelo en «Cobrar y despachar» antes de que salga' } };
  const { d } = await montar(estado);
  d.querySelector('[data-salir="e2"]').click();
  await esperar();
  chk('si la tienda no cobró, se le dice claro', /todavía no está cobrado/.test(d.querySelector('#flot').textContent));
  chk('y el botón vuelve', !d.querySelector('[data-salir="e2"]').disabled);
}

console.log('\n=== NO SE PUDO ENTREGAR ===');
{
  const estado = base();
  const { d } = await montar(estado);
  d.querySelector('[data-fallo="e1"]').click();
  await esperar(50);
  d.querySelector('#h-si').click();
  await esperar(50);
  chk('sin motivo no se manda', !ultima(estado, 'fn_entrega_fallida') &&
      /Elija un motivo/.test(d.querySelector('#h-err').textContent));
  d.querySelector('[data-m="1"]').click();
  d.querySelector('#h-texto').value = 'Llamé 3 veces';
  d.querySelector('#h-si').click();
  await esperar(200);
  const a = ultima(estado, 'fn_entrega_fallida').args;
  chk('manda el motivo elegido y lo escrito', a.p_pedido_id === 'e1' &&
      a.p_motivo === 'No contesta el teléfono. Llamé 3 veces');
  chk('avisa que la tienda ya sabe', /la tienda ya sabe/.test(d.querySelector('#flot').textContent));
  chk('vuelve a «por recoger» con el motivo', /Por recoger/.test(txt(d.querySelector('.ent'))) &&
      /No contesta el teléfono/.test(txt(d.querySelector('.ent'))));
}

console.log('\n=== ENTREGADOS HOY ===');
{
  const { d } = await montar(base());
  d.querySelector('[data-v="hoy"]').click();
  const t = txt(d.querySelector('#lista'));
  chk('lo que tiene que entregar en la tienda', /Entregue en la tienda ?L 150\.00/.test(t));
  chk('el detalle de cada entrega', /Juan/.test(t) && /P-000009/.test(t));
}

console.log('\n=== AVISOS ===');
{
  const estado = base();
  const { d, m } = await montar(estado);
  estado.entregas = [...estado.entregas, { ...ENTREGAS()[1], pedido_id:'e3', numero:'P-000013', incidencia:null }];
  await m.cargar(true);
  chk('una entrega nueva avisa y vibra', /Nueva entrega: P-000013/.test(d.querySelector('#flot').textContent) &&
      estado.vibro > 0);
}
{
  const estado = base();
  estado.entregas = [];
  const { d } = await montar(estado);
  chk('sin pendientes lo dice', /Sin entregas pendientes/.test(d.querySelector('#lista').textContent));
}
{
  const estado = base();
  estado.rpc.fn_mis_entregas = { data:null, error:{ message:'Failed to fetch' } };
  const { d } = await montar(estado);
  chk('sin señal lo dice', /Sin señal/.test(d.querySelector('#lista').textContent) &&
      !d.querySelector('#sin-red').classList.contains('oculto'));
}

console.log(`\n${ok} bien · ${mal} mal`);
process.exit(mal ? 1 : 0);
