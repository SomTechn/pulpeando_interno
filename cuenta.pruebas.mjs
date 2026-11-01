/* Prueba del registro de negocios y de la cuenta (prueba gratis, cobro):

     · el aviso de la cuenta en el menú (qué dice, a quién, dónde)
     · registro.html: validaciones de los dos pasos, alta, entrada automática
       y carga del catálogo de muestra; registro cerrado
     · los primeros pasos del Inicio
     · admin.html: solo el admin entra, lista, filtros, pago y ajuste
*/
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';

const BASE = fileURLToPath(new URL('./', import.meta.url));
let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };
const esperar = (ms = 120) => new Promise(r => setTimeout(r, ms));
const txt = el => (el?.textContent || '').replace(/\s+/g, ' ').trim();
function teclear(w, el, v){ el.value = v; el.dispatchEvent(new w.Event('input', { bubbles:true })); }

const menu = await import(BASE + 'menu.js');

/* ===================================================================== */
console.log('\n=== EL AVISO DE LA CUENTA (puro) ===');
{
  const a = menu.avisoCuenta;
  chk('sin cuenta, nada', a(null, 3) === null);
  chk('sin límite, nada', a({ sin_limite:true, dias_restantes:null }, 3) === null);
  chk('prueba con 10 días, nada', a({ en_prueba:true, dias_restantes:10 }, 3) === null);
  const p3 = a({ en_prueba:true, dias_restantes:3 }, 3);
  chk('prueba con 3 días avisa al gerente', p3?.tipo === 'ojo' && /3 días de prueba/.test(p3.texto) && !p3.fijo);
  chk('con un día dice «día»', /1 día de prueba/.test(a({ en_prueba:true, dias_restantes:1 }, 3).texto));
  chk('último día', /último día/.test(a({ en_prueba:true, dias_restantes:0 }, 3).texto));
  chk('al cajero no le avisa la prueba', a({ en_prueba:true, dias_restantes:3 }, 1) === null);
  chk('plan pagado que vence en 2 días', /vence en 2 días/.test(a({ en_prueba:false, dias_restantes:2 }, 3).texto));
  const g = a({ en_gracia:true, dias_restantes:-1, dias_gracia:3 }, 3);
  chk('en gracia: fijo, rojo, cuenta los días que quedan', g.tipo === 'malo' && g.fijo && /En 2 días/.test(g.texto));
  chk('en gracia también lo ve el cajero', a({ en_gracia:true, dias_restantes:-1, dias_gracia:3 }, 1) !== null);
  const v = a({ vencida:true, activa:true }, 1);
  chk('vencida al cajero: avise al dueño, sin botón', /Avísele al dueño/.test(v.texto) && v.accion === null);
  const vg = a({ vencida:true, activa:true }, 3);
  chk('vencida al gerente: con «Ver cómo pagar»', vg.accion?.url === 'configuracion.html#plan');
  chk('suspendida lo dice', /suspendida/.test(a({ vencida:true, activa:false }, 3).texto));
}

console.log('\n=== EL AVISO EN LA PANTALLA ===');
{
  const dom = new JSDOM(`<body><aside id="menu"></aside><div class="principal"><header class="barra">x</header><div class="zona"></div></div></body>`,
    { url:'https://x.test/ventas.html', pretendToBeVisual:true });
  const w = dom.window;
  w.matchMedia = () => ({ matches:false, addEventListener(){}, removeEventListener(){} });
  globalThis.window = w; globalThis.document = w.document; globalThis.localStorage = w.localStorage;
  const ctx = c => ({ usuario:{ nombre:'Rosa', rol:'gerente', nivel:3 },
    organizacion:{ nombre:'La Bendición', cuenta:c }, sucursales:[] });
  menu.montarMenu({ contenedor:'#menu', modulo:'ventas', ctx:ctx({ en_prueba:true, dias_restantes:2 }) });
  const av = w.document.querySelector('.aviso-cuenta');
  chk('se pinta debajo de la barra', av && av.previousElementSibling?.classList.contains('barra'));
  chk('con su enlace a Plan y pago', av?.querySelector('a')?.getAttribute('href') === 'configuracion.html#plan');
  av.querySelector('button').click();
  chk('se oculta con la ×', !w.document.querySelector('.aviso-cuenta'));
  menu.montarMenu({ contenedor:'#menu', modulo:'ventas', ctx:ctx({ en_prueba:true, dias_restantes:2 }) });
  chk('y no vuelve el mismo día', !w.document.querySelector('.aviso-cuenta'));
  menu.montarMenu({ contenedor:'#menu', modulo:'ventas', ctx:ctx({ vencida:true, activa:true }) });
  const v = w.document.querySelector('.aviso-cuenta');
  chk('vencida: se pinta y no tiene ×', v && !v.querySelector('button'));
  menu.montarMenu({ contenedor:'#menu', modulo:'ventas', ctx:ctx({ sin_limite:true }) });
  chk('al volver a montar sin aviso se quita', !w.document.querySelector('.aviso-cuenta'));
  const admin = { usuario:{ nombre:'P', rol:'admin', nivel:4 }, organizacion:{ nombre:'X' }, sucursales:[] };
  menu.montarMenu({ contenedor:'#menu', modulo:'ventas', ctx:admin });
  chk('el admin ve «Pulpeando» en el menú', !!w.document.querySelector('[data-modulo="admin"]'));
  menu.montarMenu({ contenedor:'#menu', modulo:'ventas', ctx:ctx(null) });
  chk('el gerente no', !w.document.querySelector('[data-modulo="admin"]'));
}

/* ===================================================================== */
async function montarPagina(archivo, estado, reemplazos = []){
  const html = fs.readFileSync(BASE + archivo, 'utf8');
  const cuerpo = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  const css = fs.readFileSync(BASE + 'ui.css', 'utf8');
  const dom = new JSDOM(
    html.replace(/<script type="module">[\s\S]*?<\/script>/, '')
        .replace('<link rel="stylesheet" href="ui.css">', '<style>' + css + '</style>')
        .replace(/<script src="(config|tema)\.js"><\/script>/g, ''),
    { runScripts:'outside-only', url:'https://x.test/' + archivo, pretendToBeVisual:true });
  const w = dom.window;
  w.SUPABASE_CONFIG = { url:'https://x.supabase.co', key:'k' };
  Object.defineProperty(w.navigator, 'serviceWorker', { value:{ register: async () => ({}) }, configurable:true });
  w.matchMedia = () => ({ matches:false, addEventListener(){}, removeEventListener(){} });
  w.scrollTo = () => {};
  globalThis.window = w; globalThis.document = w.document; globalThis.localStorage = w.localStorage;
  estado.llamadas = []; estado.fetches = []; estado.entradas = [];
  w.fetch = async (url, op = {}) => {
    estado.fetches.push({ url, op, cuerpo: op.body ? JSON.parse(op.body) : null });
    const r = typeof estado.fetch === 'function' ? estado.fetch(url, op) : estado.fetch;
    return { json: async () => r };
  };
  w.__sb = {
    auth:{ getSession: async () => ({ data:{ session: estado.sesion === false ? null : { user:{ id:'u1' } } } }),
           signInWithPassword: async c => { estado.entradas.push(c); return { error:null }; },
           signOut: async () => {}, onAuthStateChange(){},
           updateUser: async c => { estado.claves = (estado.claves || []).concat(c.password); return { error:null }; } },
    rpc: async (fn, args) => {
      estado.llamadas.push({ fn, args });
      const h = estado.rpc?.[fn];
      if (h === undefined) return { data:null, error:{ message:'sin simular: ' + fn } };
      return typeof h === 'function' ? h(args) : h;
    }
  };
  w.montarMenu = menu.montarMenu; w.escapar = menu.escapar;
  let prep = cuerpo
    .replace(/^import \{ createClient \} from 'https:\/\/esm\.sh\/@supabase\/supabase-js@2';$/m, '')
    .replace(/^import \{ montarMenu, escapar \} from '\.\/menu\.js';$/m, '')
    .replace(/createClient\(CFG\.url, CFG\.key, \{[^\n]*\}\)/, '__sb')
    .replace(/createClient\(CFG\.url, CFG\.key, \{\s*auth:\{ persistSession:true, autoRefreshToken:true \} \}\)/, '__sb');
  for (const [a, b] of reemplazos) prep = prep.replace(a, b);
  w.__m = {};
  await w.eval(`(async () => { ${prep}
  })()`);
  await esperar(150);
  return { w, d:w.document, estado };
}

console.log('\n=== REGISTRO: PASO 1 ===');
const infoAbierto = { ok:true, registro_abierto:true, dias_prueba:21, planes:[], whatsapp:'50499990000' };
{
  const e = { fetch:infoAbierto, rpc:{} };
  const { w, d } = await montarPagina('registro.html', e);
  chk('pide la información al abrir (GET)', e.fetches[0]?.url.endsWith('/functions/v1/registrar-negocio') && !e.fetches[0].op.method);
  chk('muestra los días de prueba de la plataforma', txt(d.querySelector('#dias-prueba')) === '21 días');
  d.querySelector('#b-seguir').click();
  chk('sin nombre no sigue', /nombre del negocio/.test(txt(d.querySelector('#e1'))) && d.querySelector('#paso2').classList.contains('oculto'));
  d.querySelector('#r-negocio').value = 'Pulpería La Bendición';
  d.querySelector('#r-telefono').value = '999';
  d.querySelector('#b-seguir').click();
  chk('teléfono corto no sigue', /8 números/.test(txt(d.querySelector('#e1'))));
  d.querySelector('#r-telefono').value = '+504 99991234';
  d.querySelector('#r-telefono').dispatchEvent(new w.Event('blur'));
  chk('el teléfono se acomoda a 9999-1234', d.querySelector('#r-telefono').value === '9999-1234');
  d.querySelector('#b-seguir').click();
  chk('con todo pasa al paso 2', !d.querySelector('#paso2').classList.contains('oculto') && d.querySelector('#paso1').classList.contains('oculto'));
  d.querySelector('#b-atras').click();
  chk('Atrás vuelve sin perder lo escrito', !d.querySelector('#paso1').classList.contains('oculto') && d.querySelector('#r-negocio').value === 'Pulpería La Bendición');
}

console.log('\n=== REGISTRO: PASO 2 Y ALTA ===');
async function hastaPaso2(e){
  const r = await montarPagina('registro.html', e);
  const { d } = r;
  d.querySelector('#r-negocio').value = 'Pulpería La Bendición';
  d.querySelector('#r-sucursal').value = 'Col. Kennedy';
  d.querySelector('#r-telefono').value = '9999-1234';
  d.querySelector('#b-seguir').click();
  return r;
}
const llenar = (w, d, extra = {}) => {
  const v = { nombre:'Rosa Martínez', email:'Rosa@Correo.hn', clave:'tienda2026', pin:'40719', ...extra };
  d.querySelector('#r-nombre').value = v.nombre;
  d.querySelector('#r-email').value = v.email;
  d.querySelector('#r-clave').value = v.clave;
  teclear(w, d.querySelector('#r-pin'), v.pin);
};
{
  const e = { fetch:infoAbierto, rpc:{} };
  const { w, d } = await hastaPaso2(e);
  llenar(w, d, { email:'rosa' });
  d.querySelector('#b-crear').click(); await esperar(20);
  chk('correo malo no manda nada', /correo/.test(txt(d.querySelector('#e2'))) && e.fetches.length === 1);
  llenar(w, d, { clave:'corta' });
  d.querySelector('#b-crear').click(); await esperar(20);
  chk('contraseña corta no manda nada', /8 caracteres/.test(txt(d.querySelector('#e2'))) && e.fetches.length === 1);
  llenar(w, d, { pin:'11111' });
  d.querySelector('#b-crear').click(); await esperar(20);
  chk('PIN fácil no manda nada', /fácil/.test(txt(d.querySelector('#e2'))) && e.fetches.length === 1);
  llenar(w, d, { pin:'4a0b7c19' });
  chk('el PIN solo acepta números y 5', d.querySelector('#r-pin').value === '40719');
}
{
  const e = { rpc:{ fn_cargar_catalogo_muestra:{ data:{ creados:100 }, error:null } },
    fetch:(url, op) => op.method === 'POST'
      ? { ok:true, negocio:'Pulpería La Bendición', codigo_tienda:'417', prueba_hasta:'2026-11-22', muestra:true }
      : infoAbierto };
  const { w, d } = await hastaPaso2(e);
  llenar(w, d);
  d.querySelector('#b-crear').click(); await esperar(200);
  const post = e.fetches.find(f => f.op.method === 'POST');
  chk('manda el POST con todo', post && post.cuerpo.negocio === 'Pulpería La Bendición' && post.cuerpo.email === 'rosa@correo.hn'
    && post.cuerpo.pin === '40719' && post.cuerpo.sucursal === 'Col. Kennedy' && post.cuerpo.muestra === true);
  chk('con la llave pública en apikey', post?.op.headers.apikey === 'k');
  chk('el campo trampa va vacío', post?.cuerpo.sitio_web === '');
  chk('pantalla de listo con el código y la fecha', !d.querySelector('#listo').classList.contains('oculto')
    && txt(d.querySelector('#l-codigo')) === '417' && /22 de noviembre de 2026/.test(txt(d.querySelector('#l-hasta'))));
  chk('saluda por el nombre', /Listo, Rosa/.test(txt(d.querySelector('#l-titulo'))));
  chk('entra solo con su correo y contraseña', e.entradas[0]?.email === 'rosa@correo.hn' && e.entradas[0]?.password === 'tienda2026');
  chk('y carga la muestra', e.llamadas.some(l => l.fn === 'fn_cargar_catalogo_muestra'));
  chk('el botón de entrar queda listo', !d.querySelector('#b-entrar').disabled);
}
{
  const e = { rpc:{},
    fetch:(url, op) => op.method === 'POST' ? { ok:true, negocio:'X', codigo_tienda:'500', prueba_hasta:'2026-11-22' } : infoAbierto };
  const { w, d } = await hastaPaso2(e);
  llenar(w, d);
  d.querySelector('#r-muestra').checked = false;
  d.querySelector('#b-crear').click(); await esperar(200);
  chk('sin la casilla no carga la muestra', !e.llamadas.some(l => l.fn === 'fn_cargar_catalogo_muestra'));
}
{
  const e = { rpc:{}, fetch:(url, op) => op.method === 'POST' ? { ok:false, error:'Ese correo ya tiene cuenta. Entre con él o use otro' } : infoAbierto };
  const { w, d } = await hastaPaso2(e);
  llenar(w, d);
  d.querySelector('#b-crear').click(); await esperar(150);
  chk('el error del servidor se ve tal cual', /ya tiene cuenta/.test(txt(d.querySelector('#e2'))));
  chk('y se queda en el paso 2', !d.querySelector('#paso2').classList.contains('oculto'));
  chk('sin entrar a nada', e.entradas.length === 0);
}
{
  const e = { rpc:{}, fetch:{ ok:true, registro_abierto:false, whatsapp:'50499990000' } };
  const { d } = await montarPagina('registro.html', e);
  chk('registro cerrado: muestra la pausa', !d.querySelector('#cerrado').classList.contains('oculto') && d.querySelector('#paso1').classList.contains('oculto'));
  chk('con el WhatsApp', d.querySelector('#b-wa-cerrado').getAttribute('href') === 'https://wa.me/50499990000');
}

/* ===================================================================== */
console.log('\n=== PRIMEROS PASOS EN EL INICIO ===');
const ctxG = (cuenta = { en_prueba:true, dias_restantes:12 }, nivel = 3) => ({
  usuario:{ id:'u1', nombre:'Rosa Martínez', rol:nivel >= 4 ? 'admin' : nivel >= 3 ? 'gerente' : 'auxiliar', nivel },
  organizacion:{ id:'o1', nombre:'La Bendición', moneda:'HNL', cuenta }, sucursales:[{ id:'s1', nombre:'Central' }], cajas:[] });
const pasos = (extra = {}) => ({ oculto:false, muestra:0, cuenta:{ en_prueba:true, dias_restantes:12 },
  pasos:[{ id:'productos', hecho:false }, { id:'negocio', hecho:false }, { id:'usuarios', hecho:false },
         { id:'venta', hecho:false }, { id:'compra', hecho:false }], ...extra });
{
  let p = pasos();
  const e = { rpc:{ fn_pos_contexto:{ data:ctxG(), error:null },
    fn_primeros_pasos: () => ({ data:p, error:null }),
    fn_cargar_catalogo_muestra: () => { p = pasos({ muestra:100, pasos:[{ id:'productos', hecho:true }, ...p.pasos.slice(1)] }); return { data:{}, error:null }; },
    fn_quitar_catalogo_muestra: () => { p = pasos(); return { data:{}, error:null }; },
    fn_ocultar_primeros_pasos:{ data:null, error:null } } };
  const { d } = await montarPagina('index.html', e);
  const s = d.querySelector('.pasos');
  chk('se ven los cinco pasos', s && s.querySelectorAll('.paso').length === 5);
  chk('dice cuántos lleva y los días de prueba', /0 de 5 listos · le quedan 12 días de prueba/.test(txt(s)));
  d.querySelector('#pasos-muestra').click(); await esperar(120);
  chk('«Probar con 100» carga la muestra', e.llamadas.some(l => l.fn === 'fn_cargar_catalogo_muestra'));
  chk('y queda el paso tachado', d.querySelector('.paso.hecho') && /1 de 5/.test(txt(d.querySelector('.pasos'))));
  const q = d.querySelector('#pasos-quitar');
  chk('ofrece quitar la muestra', /100 productos de muestra/.test(txt(d.querySelector('.muestra-fila'))));
  q.click(); await esperar(60);
  chk('el primer toque solo pregunta', !e.llamadas.some(l => l.fn === 'fn_quitar_catalogo_muestra') && /Seguro/.test(q.textContent));
  q.click(); await esperar(120);
  chk('el segundo quita', e.llamadas.some(l => l.fn === 'fn_quitar_catalogo_muestra'));
  d.querySelector('#pasos-ocultar').click(); await esperar(60);
  chk('Ocultar los guarda y los quita', e.llamadas.some(l => l.fn === 'fn_ocultar_primeros_pasos' && l.args.p_oculto === true)
    && !d.querySelector('.pasos'));
}
{
  const e = { rpc:{ fn_pos_contexto:{ data:ctxG(undefined, 1), error:null }, fn_primeros_pasos:{ data:pasos(), error:null } } };
  const { d } = await montarPagina('index.html', e);
  chk('la cajera no ve los primeros pasos', !d.querySelector('.pasos') && !e.llamadas.some(l => l.fn === 'fn_primeros_pasos'));
}
{
  const e = { rpc:{ fn_pos_contexto:{ data:ctxG(), error:null }, fn_primeros_pasos:{ data:pasos({ oculto:true }), error:null } } };
  const { d } = await montarPagina('index.html', e);
  chk('ocultos no se pintan', !d.querySelector('.pasos'));
}
{
  const e = { sesion:false, rpc:{} };
  const { d } = await montarPagina('index.html', e);
  chk('el inicio de sesión invita a registrarse', d.querySelector('#p-sesion a[href="registro.html"]') !== null);
}

/* ===================================================================== */
console.log('\n=== ADMIN.HTML ===');
const NEG = () => [
  { id:'n1', nombre:'Pulpería La Bendición', codigo_tienda:'417', creada_en:new Date().toISOString(), origen:'registro',
    telefono:'9999-1234', notas:null, usuarios:1, productos:100, ventas_30d:4, ultima_venta:'2026-10-30', pagado_total:0,
    dueno:{ nombre:'Rosa Martínez', email:'rosa@correo.hn', telefono:'9999-1234' },
    cuenta:{ plan:'prueba', activa:true, en_prueba:true, dias_restantes:2, prueba_hasta:'2026-11-03', vence:'2026-11-03' } },
  { id:'n2', nombre:'Mini Súper Don Chepe', codigo_tienda:'233', creada_en:'2026-08-01', origen:'manual',
    usuarios:3, productos:420, ventas_30d:900, ultima_venta:'2026-10-31', pagado_total:1350,
    dueno:{ nombre:'José', email:'chepe@x.hn', telefono:null },
    cuenta:{ plan:'basico', activa:true, en_prueba:false, dias_restantes:40, pagado_hasta:'2026-12-10', vence:'2026-12-10' } },
  { id:'n3', nombre:'Pulpería El Sol', codigo_tienda:'801', creada_en:'2026-09-01', origen:'registro',
    usuarios:1, productos:30, ventas_30d:0, ultima_venta:null, pagado_total:0,
    dueno:{ nombre:'Ana', email:'ana@x.hn' }, cuenta:{ plan:'prueba', activa:true, vencida:true, dias_restantes:-20 } }
];
const CONF = () => ({ registro_abierto:true, dias_prueba:14, dias_gracia:3, whatsapp:'50499990000', pago_instrucciones:'BAC',
  planes:[{ id:'basico', nombre:'Básico', precio:450, detalle:'1 sucursal' }, { id:'negocio', nombre:'Negocio', precio:850 }] });
{
  const e = { rpc:{ fn_pos_contexto:{ data:ctxG(undefined, 3), error:null } } };
  const { d } = await montarPagina('admin.html', e);
  chk('un gerente no entra', !d.querySelector('#p-bloqueado').classList.contains('oculto') && d.querySelector('#app').classList.contains('oculto'));
}
{
  const e = { rpc:{ fn_pos_contexto:{ data:ctxG({ sin_limite:true }, 4), error:null },
    fn_admin_negocios: () => ({ data:NEG(), error:null }), fn_admin_config: () => ({ data:CONF(), error:null }),
    fn_admin_registrar_pago:{ data:{}, error:null }, fn_admin_actualizar_cuenta:{ data:{}, error:null },
    fn_admin_guardar_config:{ data:{}, error:null } } };
  const { w, d } = await montarPagina('admin.html', e);
  chk('el admin entra y ve la lista', d.querySelectorAll('.neg').length === 3);
  chk('cifras: 3 negocios, 1 en prueba, 1 al día', /Negocios ?3/.test(txt(d.querySelector('.cifras'))) && /En prueba ?1/.test(txt(d.querySelector('.cifras'))) && /Al día ?1/.test(txt(d.querySelector('.cifras'))));
  chk('estados en palabras', /Prueba · 2 d/.test(txt(d.querySelector('[data-id="n1"]'))) && /Vencida/.test(txt(d.querySelector('[data-id="n3"]'))));
  d.querySelector('[data-f="cobrar"]').click();
  chk('«Por cobrar» junta la prueba por acabar y la vencida', [...d.querySelectorAll('.neg')].map(x => x.dataset.id).join() === 'n1,n3');
  d.querySelector('[data-f="todos"]').click();
  teclear(w, d.querySelector('#f-buscar'), 'chepe');
  chk('busca por correo del dueño', [...d.querySelectorAll('.neg')].map(x => x.dataset.id).join() === 'n2');
  teclear(w, d.querySelector('#f-buscar'), '');
  d.querySelector('[data-id="n1"]').click(); await esperar(30);
  chk('el detalle es una pantalla, con Volver', !!d.querySelector('#d-volver') && !d.querySelector('.velo:not(.oculto)'));
  chk('trae el WhatsApp del dueño con 504', d.querySelector('a[href="https://wa.me/50499991234"]') !== null);
  chk('el monto se sugiere con el plan', d.querySelector('#p-monto').value === '450');
  teclear(w, d.querySelector('#p-meses'), '3');
  chk('y se multiplica por los meses', d.querySelector('#p-monto').value === '1350');
  d.querySelector('#p-ref').value = 'BAC 99';
  d.querySelector('#p-guardar').click(); await esperar(150);
  const pago = e.llamadas.find(l => l.fn === 'fn_admin_registrar_pago');
  chk('registra el pago con todo', pago && pago.args.p_org === 'n1' && pago.args.p_meses === 3 && pago.args.p_monto === 1350
    && pago.args.p_plan === 'basico' && pago.args.p_referencia === 'BAC 99');
  d.querySelector('#a-activa').checked = false;
  d.querySelector('#a-notas').value = 'Llamar el lunes';
  d.querySelector('#a-guardar').click(); await esperar(150);
  const aj = e.llamadas.find(l => l.fn === 'fn_admin_actualizar_cuenta');
  chk('el ajuste manda activa y notas', aj && aj.args.p_cambios.activa === false && aj.args.p_cambios.notas === 'Llamar el lunes'
    && aj.args.p_cambios.prueba_hasta === '2026-11-03');
  d.querySelector('[data-valor="config"]').click(); await esperar(120);
  chk('planes y registro: dos filas de plan', d.querySelectorAll('.plan-fila').length === 2);
  d.querySelector('#c-mas-plan').click();
  const f = [...d.querySelectorAll('.plan-fila')].at(-1);
  f.querySelector('[data-k="id"]').value = 'Grande'; f.querySelector('[data-k="nombre"]').value = 'Grande';
  f.querySelector('[data-k="precio"]').value = '1500';
  d.querySelector('.plan-fila [data-quitar]').click();
  d.querySelector('#c-prueba').value = '30';
  d.querySelector('#c-wa').value = '+504 9999-0000';
  d.querySelector('#c-guardar').click(); await esperar(120);
  const g = e.llamadas.find(l => l.fn === 'fn_admin_guardar_config')?.args.p_datos;
  chk('guarda los planes que quedaron, id en minúsculas', g && g.planes.map(p => p.id).join() === 'negocio,grande' && g.planes[1].precio === 1500);
  chk('días de prueba y WhatsApp limpio', g?.dias_prueba === 30 && g?.whatsapp === '50499990000');
  d.querySelector('#c-clave1').value = 'corta'; d.querySelector('#c-clave').click(); await esperar(40);
  chk('contraseña corta no se manda', !e.claves);
  d.querySelector('#c-clave1').value = 'NuevaClave2026'; d.querySelector('#c-clave2').value = 'otra';
  d.querySelector('#c-clave').click(); await esperar(40);
  chk('si no coinciden no se manda', !e.claves);
  d.querySelector('#c-clave2').value = 'NuevaClave2026'; d.querySelector('#c-clave').click(); await esperar(60);
  chk('el admin cambia su contraseña', e.claves?.[0] === 'NuevaClave2026' && d.querySelector('#c-clave1').value === '');
}

console.log(`\n${ok} bien, ${mal} mal`);
if (mal) process.exit(1);
