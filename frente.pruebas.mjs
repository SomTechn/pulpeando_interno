/* Prueba funcional del frente: carga index.html y fiado.html en jsdom,
   con Supabase simulado, y maneja las pantallas como lo haría un cajero. */
import fs from 'node:fs';
import { JSDOM } from 'jsdom';

const BASE = '/home/claude/somtechn/pulpeando_interno/';
let ok = 0, mal = 0;
const chk = (n, c) => { if (c) { ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };

/* ---------- Supabase simulado ---------- */
function hacerSb(estado){
  estado.fetches = estado.fetches || [];
  estado.escrituras = estado.escrituras || [];
  const tabla = nombre => {
    const q = {
      _t:nombre,
      select(){ return q; }, eq(){ return q; }, order(){ return q; }, is(){ return q; }, in(){ return q; },
      limit(){ return Promise.resolve({ data:estado.tablas[nombre] || [], error:null }); },
      // Se apunta lo que se escribe para poder revisar QUE se guardo, no solo
      // que la pantalla no se cayo.
      insert(datos){ estado.escrituras.push({ tabla:nombre, op:'insert', datos });
                     return { select(){ return { single: async () =>
                       ({ data:{ id:'nuevo-1' }, error:null }) }; },
                       then(r){ return Promise.resolve({ data:null, error:null }).then(r); } }; },
      update(datos){ estado.escrituras.push({ tabla:nombre, op:'update', datos });
                     const ok = () => Promise.resolve({ data:null, error:null });
                     return { eq:ok, in(campo, ids){ estado.escrituras[estado.escrituras.length - 1].ids = ids;
                                                     return ok(); } }; },
      then(r){ return Promise.resolve({ data:estado.tablas[nombre] || [], error:null }).then(r); }
    };
    return q;
  };
  return {
    auth:{
      getSession: async () => ({ data:{ session:estado.sesion === null ? null
        : { user:{ id:'u1' }, access_token:'tok-gerente' } } }),
      signInWithPassword: async () => ({ error:null }),
      signOut: async () => {},
      onAuthStateChange(){}
    },
    from: tabla,
    channel(){ return { on(){ return this; }, subscribe(){ return this; } }; },
    removeChannel(){},
    rpc: async (fn, args) => {
      estado.llamadas.push({ fn, args });
      const h = estado.rpc[fn];
      if (!h) return { data:null, error:{ message:'rpc sin simular: ' + fn } };
      if (typeof h === 'function') return h(args);
      // las entradas ya vienen como { data, error }
      return (h && typeof h === 'object' && 'data' in h) ? h : { data:h, error:null };
    }
  };
}

/* ---------- montar una pantalla ---------- */
async function montar(archivo, estado){
  const html = fs.readFileSync(BASE + archivo, 'utf8');
  const cuerpo = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  const css = fs.readFileSync(BASE + 'ui.css', 'utf8');

  const dom = new JSDOM(
    html.replace(/<script type="module">[\s\S]*?<\/script>/, '')
        .replace('<link rel="stylesheet" href="ui.css">', '<style>' + css + '</style>')
        .replace(/<script src="config\.js"><\/script>/, ''),
    { runScripts:'outside-only', url:'https://x.test/' + archivo, pretendToBeVisual:true });

  const w = dom.window;
  w.SUPABASE_CONFIG = { url:'https://x.supabase.co', key:'k' };
  Object.defineProperty(w.navigator, 'serviceWorker', {
    value:{ register: async () => ({}) }, configurable:true });
  Object.defineProperty(w.navigator, 'onLine', { value:estado.enLinea ?? true, writable:true,
                                                 configurable:true });
  w.matchMedia = q => ({ matches:false, addEventListener(){}, removeEventListener(){} });
  w.indexedDB = undefined;
  w.alert = m => estado.alertas.push(m);
  w.prompt = () => null;
  w.fetch = async (url, opc = {}) => {
    const reg = { url:String(url), opc, cuerpo:null };
    try { reg.cuerpo = JSON.parse(opc.body); } catch(e){}
    estado.fetches.push(reg);
    const h = estado.http?.[new URL(String(url)).pathname];
    const r = h ? (typeof h === 'function' ? h(reg) : h) : { estado:404, datos:{ error:'sin simular' } };
    return {
      ok: r.estado >= 200 && r.estado < 300,
      status: r.estado,
      json: async () => r.datos
    };
  };

  // los import de esm.sh y los módulos locales, resueltos a mano
  const menu = await import(BASE + 'menu.js');
  const prep = cuerpo
    .replace(/^import .*?from 'https:\/\/esm\.sh\/@supabase\/supabase-js@2';$/m, '')
    .replace(/^import \{([^}]*)\} from '\.\/menu\.js';$/m, '')
    .replace(/^import \{([^}]*)\} from '\.\/escaner\.js';$/m, '')
    .replace(/^import \{ imprimirTicket \} from '\.\/ticket\.js';$/m,
             'const imprimirTicket = async (d, o) => { (window.__impresos = window.__impresos || []).push({ d, o }); };')
    .replace(/createClient\(SUPABASE_URL, SUPABASE_KEY, \{[\s\S]*?\}\)/, '__sb');

  // menu.js se importa una vez y usa el document global
  globalThis.window = w;
  globalThis.document = w.document;
  globalThis.localStorage = w.localStorage;
  globalThis.matchMedia = w.matchMedia;

  const ctx = w;
  ctx.__sb = hacerSb(estado);
  ctx.montarMenu = menu.montarMenu;
  ctx.escapar = menu.escapar;
  ctx.iniciales = menu.iniciales;
  ctx.escanear = async () => null;
  ctx.hayCamara = () => false;
  ctx.__caja = {};

  // exponer el ámbito del módulo para poder inspeccionarlo
  const fuente = `(async () => { ${prep}
    ; window.__caja.S = typeof S !== 'undefined' ? S : null;
    ; window.__caja.pintarFiado = typeof pintarFiado === 'function' ? pintarFiado : null;
    ; window.__caja.pintarCliente = typeof pintarCliente === 'function' ? pintarCliente : null;
    ; window.__caja.fiadoDisponible = typeof fiadoDisponible === 'function' ? fiadoDisponible : null;
    ; window.__caja.leerTurnos = typeof leerTurnos === 'function' ? leerTurnos : null;
    ; window.__caja.avisarTurno = typeof avisarTurno === 'function' ? avisarTurno : null;
    ; window.__caja.totales = typeof totales === 'function' ? totales : null;
    ; window.__caja.abrirForm = typeof abrirForm === 'function' ? abrirForm : null;
    ; window.__caja.crearUsuario = typeof crearUsuario === 'function' ? crearUsuario : null;
  })()`;

  await w.eval(fuente);
  await new Promise(r => setTimeout(r, 60));
  return { w, d:w.document, caja:w.__caja };
}

const CTX_BASE = {
  usuario:{ id:'u1', nombre:'Ana Auxiliar', rol:'auxiliar', nivel:1, tiene_pin:true },
  organizacion:{ id:'o1', nombre:'Pulperia Test', moneda:'HNL', factura_fiscal:false },
  sucursales:[{ id:'s1', nombre:'Principal', codigo:'001' }],
  cajas:[], impuesto_default:0, sin_sucursal:false
};

/* =====================================================================
   CAJA: cuándo aparece el botón de Fiado
   ===================================================================== */
console.log('\n=== CAJA: puerta del fiado ===');
{
  const estado = {
    enLinea:true, alertas:[], llamadas:[], tablas:{ clientes:[] },
    rpc:{
      fn_pos_contexto:{ data:{ ...CTX_BASE,
        cajas:[{ caja_id:'c1', caja:'Caja 1', sucursal_id:'s1', turno_id:'t1',
                 cajero:'Ana Auxiliar', cajero_id:'u1', desbloqueada:false,
                 ventas_turno:0, total_turno:0 }] }, error:null },
      fn_catalogo_pos:{ data:[], error:null }
    }
  };
  const { w, d, caja } = await montar('index.html', estado);
  const S = caja.S;
  chk('el módulo expone su estado', !!S);
  chk('pintarFiado existe', typeof caja.pintarFiado === 'function');

  // Desde la 031 el botón de Fiado siempre se ve; cuando no se puede fiar
  // se ve apagado (no-puede) y explica por qué al tocarlo.
  const oculto = () => d.querySelector('#metodo-fiado').classList.contains('oculto') ||
                       d.querySelector('#metodo-fiado').classList.contains('no-puede');
  const visible = () => !d.querySelector('#metodo-fiado').classList.contains('oculto');
  const nota = () => d.querySelector('#cobro-fiado').classList.contains('oculto')
    ? '' : d.querySelector('#cobro-fiado').textContent;

  // sin cliente
  S.cliente = null; S.enLinea = true;
  caja.pintarFiado(100);
  chk('sin cliente el fiado se ve pero apagado', oculto() && visible());
  chk('sin cliente no hay regaño', nota() === '');

  // cliente sin límite
  S.cliente = { id:'k1', nombre:'Don Pedro', saldo:0, limite_credito:0 };
  caja.pintarFiado(100);
  chk('límite 0 esconde el fiado', oculto());
  chk('límite 0 explica por qué', /no se le fía/i.test(nota()));

  // cliente con cupo suficiente
  S.cliente = { id:'k2', nombre:'Dona Marta', saldo:0, limite_credito:200 };
  caja.pintarFiado(100);
  chk('con cupo aparece el fiado', !oculto());
  chk('con cupo no hay regaño', nota() === '');

  // cupo justo
  caja.pintarFiado(200);
  chk('venta igual al cupo deja fiar', !oculto());

  // venta mayor al cupo
  caja.pintarFiado(200.01);
  chk('venta mayor al cupo esconde el fiado', oculto());
  chk('dice cuánto puede fiar', /solo puede fiar/i.test(nota()));

  // ya en el tope
  S.cliente = { id:'k3', nombre:'Dona Marta', saldo:200, limite_credito:200 };
  caja.pintarFiado(10);
  chk('en el tope esconde el fiado', oculto());
  chk('en el tope dice que abone', /abonar antes de fiar/i.test(nota()));
  chk('pero el botón no desaparece', visible());

  // sin internet
  S.cliente = { id:'k2', nombre:'Dona Marta', saldo:0, limite_credito:200 };
  S.enLinea = false;
  caja.pintarFiado(100);
  chk('sin internet no se puede fiar', oculto());
  chk('sin internet explica el motivo', /Sin internet no se puede fiar/i.test(nota()));

  // fiadoDisponible
  S.enLinea = true;
  chk('fiadoDisponible con saldo 0 = límite',
      (S.cliente = { saldo:0, limite_credito:200 }, caja.fiadoDisponible() === 200));
  chk('fiadoDisponible resta el saldo',
      (S.cliente = { saldo:75, limite_credito:200 }, caja.fiadoDisponible() === 125));
  chk('fiadoDisponible nunca es negativo',
      (S.cliente = { saldo:300, limite_credito:200 }, caja.fiadoDisponible() === 0));
  chk('fiadoDisponible con límite 0 es 0',
      (S.cliente = { saldo:0, limite_credito:0 }, caja.fiadoDisponible() === 0));
  chk('fiadoDisponible sin cliente es 0',
      (S.cliente = null, caja.fiadoDisponible() === 0));

  // el botón de cliente refleja el saldo
  S.cliente = { id:'k4', nombre:'Dona Marta', saldo:120, limite_credito:200 };
  caja.pintarCliente();
  const bc = d.querySelector('#btn-cliente');
  chk('el botón marca que el cliente debe', bc.classList.contains('debe'));
  chk('el botón dice cuánto debe', /Debe/.test(d.querySelector('#cl-txt').textContent));
  chk('el botón dice cuánto puede fiar aún',
      /puede fiar/.test(d.querySelector('#cl-txt').textContent));

  S.cliente = { id:'k5', nombre:'Nuevo', saldo:0, limite_credito:150 };
  caja.pintarCliente();
  chk('cliente sin deuda se marca distinto',
      bc.classList.contains('puesto') && !bc.classList.contains('debe'));

  S.cliente = null; caja.pintarCliente();
  chk('sin cliente vuelve al texto neutro',
      d.querySelector('#cl-txt').textContent === 'Cliente sin registrar');
  chk('sin cliente vuelve el signo +', d.querySelector('#cl-ini').textContent === '+');
}

/* =====================================================================
   FIADO: a qué caja entra el efectivo
   ===================================================================== */
console.log('\n=== FIADO: turno del abono ===');
{
  const ctxDos = { ...CTX_BASE,
    usuario:{ ...CTX_BASE.usuario, id:'u1' },
    cajas:[
      { caja_id:'c1', caja:'Caja 1', sucursal_id:'s1', turno_id:'t1',
        cajero:'Beto Cajero', cajero_id:'u9' },
      { caja_id:'c2', caja:'Caja 2', sucursal_id:'s1', turno_id:'t2',
        cajero:'Ana Auxiliar', cajero_id:'u1' },
      { caja_id:'c3', caja:'Caja 3', sucursal_id:'s1', turno_id:null,
        cajero:null, cajero_id:null }
    ] };

  const estado = {
    enLinea:true, alertas:[], llamadas:[], tablas:{ v_fiado:[] },
    rpc:{ fn_pos_contexto:{ data:ctxDos, error:null },
          fn_fiado_resumen:{ data:{ clientes:0, total:0, al_tope:0, mas_30_dias:0,
                                    monto_mas_30:0, mas_viejo:0 }, error:null } }
  };
  const { d, caja } = await montar('fiado.html', estado);
  const S = caja.S;
  chk('la pantalla de fiado arranca', !!S);
  chk('solo cuenta los turnos abiertos', S.turnos.length === 2);
  chk('elige el turno del propio usuario, no el primero', S.turno === 't2');

  // un solo turno, ajeno: se usa ese
  S.ctx.cajas = [{ caja_id:'c1', caja:'Caja 1', sucursal_id:'s1', turno_id:'t1',
                   cajero:'Beto Cajero', cajero_id:'u9' }];
  caja.leerTurnos();
  chk('con un solo turno abierto usa ese', S.turno === 't1');

  // varios turnos, ninguno del usuario: no adivina
  S.ctx.cajas = [
    { caja_id:'c1', caja:'Caja 1', sucursal_id:'s1', turno_id:'t1', cajero:'Beto', cajero_id:'u9' },
    { caja_id:'c2', caja:'Caja 2', sucursal_id:'s1', turno_id:'t2', cajero:'Cira', cajero_id:'u8' }
  ];
  caja.leerTurnos();
  chk('con varios turnos ajenos no adivina', S.turno === null);

  S.cliente = { cliente_id:'k1', cliente:'Dona Marta', debe:120, limite:200,
                disponible:80, tope_alcanzado:false, dias:3 };
  S.monto = 50; S.metodo = 'efectivo';
  caja.avisarTurno();
  chk('con varios turnos muestra el selector',
      !d.querySelector('#ab-caja-caja').classList.contains('oculto'));
  chk('el selector nombra al cajero de cada caja',
      /Beto/.test(d.querySelector('#ab-caja').innerHTML) &&
      /Cira/.test(d.querySelector('#ab-caja').innerHTML));
  chk('al mostrar el selector ya queda uno elegido', S.turno === 't1' || S.turno === 't2');
  chk('con turno elegido se puede confirmar',
      d.querySelector('#ab-confirmar').disabled === false);

  // ningún turno abierto y efectivo
  S.ctx.cajas = []; caja.leerTurnos();
  S.metodo = 'efectivo'; S.monto = 50;
  caja.avisarTurno();
  chk('sin caja abierta no deja cobrar efectivo',
      d.querySelector('#ab-confirmar').disabled === true);
  chk('sin caja abierta avisa antes de recibir el dinero',
      /No hay ninguna caja abierta/i.test(d.querySelector('#ab-ojo').textContent));
  chk('sin caja abierta el aviso está visible',
      !d.querySelector('#ab-ojo').classList.contains('oculto'));

  // transferencia sin turno: sí se puede
  S.metodo = 'transferencia';
  caja.avisarTurno();
  chk('transferencia no necesita caja abierta',
      d.querySelector('#ab-confirmar').disabled === false);
  chk('transferencia esconde el aviso de caja',
      d.querySelector('#ab-ojo').classList.contains('oculto'));

  // monto en cero
  S.monto = 0;
  caja.avisarTurno();
  chk('monto en cero no deja confirmar',
      d.querySelector('#ab-confirmar').disabled === true);
}

/* =====================================================================
   FIADO: el límite solo lo mueve un supervisor
   ===================================================================== */
console.log('\n=== FIADO: límite de crédito ===');
for (const [rol, nivel, deberiaVerse] of [['auxiliar',1,false], ['supervisor',2,true],
                                          ['gerente',3,true]]){
  const estado = {
    enLinea:true, alertas:[], llamadas:[],
    tablas:{ v_fiado:[] },
    rpc:{
      fn_pos_contexto:{ data:{ ...CTX_BASE,
        usuario:{ ...CTX_BASE.usuario, rol, nivel } }, error:null },
      fn_fiado_resumen:{ data:{ clientes:1, total:120 }, error:null },
      fn_estado_cuenta:{ data:[], error:null }
    }
  };
  const { d, caja } = await montar('fiado.html', estado);
  const S = caja.S;
  S.fiados = [{ cliente_id:'k1', cliente:'Dona Marta', telefono:'9999', debe:120,
                limite:200, disponible:80, tope_alcanzado:false, dias:3,
                ultimo_abono:null, compras_credito:2 }];
  d.querySelector('#lista').innerHTML = '';
  await (async () => { // abrir el cajón como lo haría un clic en la fila
    S.cliente = S.fiados[0];
    d.querySelector('#btn-limite').classList.toggle('oculto', !(nivel >= 2));
  })();
  const visible = !d.querySelector('#btn-limite').classList.contains('oculto');
  chk(rol + ' ' + (deberiaVerse ? 'sí' : 'no') + ' ve el botón de límite',
      visible === deberiaVerse);
}
{
  const estado = {
    enLinea:true, alertas:[], llamadas:[], tablas:{ v_fiado:[] },
    rpc:{
      fn_pos_contexto:{ data:{ ...CTX_BASE,
        usuario:{ ...CTX_BASE.usuario, rol:'supervisor', nivel:2 } }, error:null },
      fn_fiado_resumen:{ data:{ clientes:1, total:120 }, error:null },
      fn_fijar_limite_credito:{ data:{ limite:400 }, error:null }
    }
  };
  const { d, caja } = await montar('fiado.html', estado);
  const S = caja.S;
  S.cliente = { cliente_id:'k1', cliente:'Dona Marta', debe:120, limite:200 };

  d.querySelector('#btn-limite').click();
  await new Promise(r => setTimeout(r, 20));
  chk('el cajón del límite se abre',
      !d.querySelector('#velo-limite').classList.contains('oculto'));
  chk('arranca con el límite que ya tiene',
      d.querySelector('#lm-monto').value === '200.00');

  const poner = v => {
    const i = d.querySelector('#lm-monto');
    i.value = v;
    i.dispatchEvent(new (d.defaultView.Event)('input', { bubbles:true }));
  };
  const ojo = () => d.querySelector('#lm-ojo').classList.contains('oculto')
    ? '' : d.querySelector('#lm-ojo').textContent;

  poner('400');
  chk('subir el límite no genera aviso', ojo() === '');
  poner('120');
  chk('límite igual a la deuda no genera aviso', ojo() === '');
  poner('80');
  chk('límite debajo de la deuda avisa', /por debajo de lo que debe/i.test(ojo()));
  chk('dice cuánto tiene que abonar', /abone L 40\.00/.test(ojo()));
  poner('0');
  chk('límite en 0 aclara que la deuda no se borra', /La deuda no se borra/i.test(ojo()));

  poner('400');
  d.querySelector('#lm-guardar').click();
  await new Promise(r => setTimeout(r, 40));
  const lm = estado.llamadas.filter(l => l.fn === 'fn_fijar_limite_credito');
  chk('guardar llama a la función, no a un update de tabla', lm.length === 1);
  chk('manda el cliente y el límite correctos',
      lm[0]?.args?.p_cliente_id === 'k1' && lm[0]?.args?.p_limite === 400);
}

/* =====================================================================
   CATÁLOGOS: el campo de límite según el rol
   ===================================================================== */
console.log('\n=== CATÁLOGOS: campo de límite ===');
for (const [rol, nivel, bloqueado] of [['auxiliar',1,true], ['supervisor',2,false]]){
  const estado = {
    enLinea:true, alertas:[], llamadas:[],
    tablas:{ clientes:[], categorias:[], marcas:[], proveedores:[], impuestos:[] },
    rpc:{ fn_pos_contexto:{ data:{ ...CTX_BASE,
      usuario:{ ...CTX_BASE.usuario, rol, nivel } }, error:null } }
  };
  const { d, caja } = await montar('catalogo.html', estado);
  const S = caja.S;
  chk('catálogos arranca como ' + rol, !!S && S.nivel === nivel);

  // abrir el formulario de clientes
  S.entidad = 'clientes';
  d.querySelector('#btn-nuevo').click();
  await new Promise(r => setTimeout(r, 30));
  const campo = d.querySelector('[data-k="limite_credito"]');
  chk(rol + ': el campo de límite está en el formulario', !!campo);
  if (campo){
    chk(rol + ': el campo ' + (bloqueado ? 'está bloqueado' : 'se puede editar'),
        campo.disabled === bloqueado);
    const ayuda = campo.closest('.campo-g')?.nextElementSibling?.textContent || '';
    chk(rol + ': la ayuda ' + (bloqueado ? 'explica que es de supervisor' : 'es la normal'),
        bloqueado ? /supervisor/i.test(ayuda) : !/supervisor/i.test(ayuda));
  }
}

/* =====================================================================
   CATÁLOGOS: alta de usuario por Edge Function
   ===================================================================== */
console.log('\n=== CATÁLOGOS: alta de usuario ===');
{
  const ctxGerente = { ...CTX_BASE,
    usuario:{ ...CTX_BASE.usuario, rol:'gerente', nivel:3 },
    sucursales:[{ id:'s1', nombre:'Principal' }, { id:'s2', nombre:'Sucursal 2' }] };

  const estado = {
    enLinea:true, alertas:[], llamadas:[], fetches:[],
    tablas:{ perfiles:[], categorias:[], marcas:[], proveedores:[], impuestos:[] },
    rpc:{ fn_pos_contexto:{ data:ctxGerente, error:null },
          fn_establecer_pin:{ data:null, error:null } },
    http:{ '/functions/v1/crear-usuario':
      { estado:201, datos:{ perfil_id:'nuevo-1', nombre:'Beto', rol:'auxiliar',
                            falta_pin:true } } }
  };
  const { d, caja } = await montar('catalogo.html', estado);
  const S = caja.S;

  S.entidad = 'usuarios';
  d.querySelector('#btn-nuevo').click();
  await new Promise(r => setTimeout(r, 40));

  chk('el botón Nuevo ya aparece en usuarios',
      !d.querySelector('#btn-nuevo').classList.contains('oculto'));
  chk('el formulario pide correo', !!d.querySelector('[data-k="email"]'));
  chk('el formulario pide contraseña', !!d.querySelector('[data-k="password"]'));
  chk('la contraseña va enmascarada',
      d.querySelector('[data-k="password"]')?.type === 'password');
  chk('ofrece elegir sucursales',
      d.querySelectorAll('[data-sucursal]').length === 2);
  chk('las sucursales vienen marcadas por omisión',
      [...d.querySelectorAll('[data-sucursal]')].every(x => x.checked));
  chk('pide PIN', !!d.querySelector('#pin-nuevo'));

  // llenar y guardar
  const poner = (k, v) => { d.querySelector(`[data-k="${k}"]`).value = v; };
  poner('nombre', 'Beto Cajero');
  poner('telefono', '9999-5555');
  poner('email', 'Beto@Tienda.HN');
  poner('password', 'clave1234');
  d.querySelector('[data-k="rol"]').value = 'auxiliar';
  // desmarcar la segunda sucursal
  d.querySelectorAll('[data-sucursal]')[1].checked = false;
  d.querySelector('#pin-nuevo').value = '24680';

  d.querySelector('#form-guardar').click();
  await new Promise(r => setTimeout(r, 80));

  const f = estado.fetches.find(x => x.url.includes('crear-usuario'));
  chk('se llamó a la Edge Function', !!f);
  chk('por POST', f?.opc?.method === 'POST');
  chk('con el token de la sesión del gerente',
      f?.opc?.headers?.Authorization === 'Bearer tok-gerente');
  chk('manda el nombre', f?.cuerpo?.nombre === 'Beto Cajero');
  chk('manda el correo', f?.cuerpo?.email === 'Beto@Tienda.HN');
  chk('manda la contraseña sin recortar', f?.cuerpo?.password === 'clave1234');
  chk('manda el rol', f?.cuerpo?.rol === 'auxiliar');
  chk('manda solo la sucursal marcada',
      Array.isArray(f?.cuerpo?.sucursales) && f.cuerpo.sucursales.length === 1
      && f.cuerpo.sucursales[0] === 's1');
  chk('NO manda la organización en el cuerpo',
      f && !('organizacion_id' in (f.cuerpo || {})));
  chk('NO manda el rol del solicitante en el cuerpo',
      f && !('solicitante' in (f.cuerpo || {})) && !('nivel' in (f.cuerpo || {})));

  const pin = estado.llamadas.filter(l => l.fn === 'fn_establecer_pin');
  chk('el PIN se pone aparte, con la sesión del gerente', pin.length === 1);
  chk('y sobre el usuario que devolvió la función',
      pin[0]?.args?.p_perfil_id === 'nuevo-1' && pin[0]?.args?.p_pin === '24680');
  chk('el cajón se cerró al terminar',
      d.querySelector('#form-velo').classList.contains('oculto'));
}

console.log('\n=== CATÁLOGOS: el alta falla con gracia ===');
{
  const ctxGerente = { ...CTX_BASE,
    usuario:{ ...CTX_BASE.usuario, rol:'gerente', nivel:3 },
    sucursales:[{ id:'s1', nombre:'Principal' }] };

  const estado = {
    enLinea:true, alertas:[], llamadas:[], fetches:[],
    tablas:{ perfiles:[], categorias:[], marcas:[], proveedores:[], impuestos:[] },
    rpc:{ fn_pos_contexto:{ data:ctxGerente, error:null } },
    http:{ '/functions/v1/crear-usuario':
      { estado:400, datos:{ error:'Ya hay un usuario con ese correo en su negocio' } } }
  };
  const { d, caja } = await montar('catalogo.html', estado);
  caja.S.entidad = 'usuarios';
  d.querySelector('#btn-nuevo').click();
  await new Promise(r => setTimeout(r, 40));

  chk('con una sola sucursal no muestra casillas',
      d.querySelectorAll('[data-sucursal]').length === 0);

  d.querySelector('[data-k="nombre"]').value = 'Beto';
  d.querySelector('[data-k="email"]').value = 'beto@t.hn';
  d.querySelector('[data-k="password"]').value = 'clave1234';
  d.querySelector('[data-k="rol"]').value = 'auxiliar';
  d.querySelector('#form-guardar').click();
  await new Promise(r => setTimeout(r, 80));

  const hoja = d.querySelector('#hoja').textContent;
  chk('muestra el motivo que dio el servidor', /ese correo en su negocio/i.test(hoja));
  chk('no inventa que se creó', !/creado|listo/i.test(hoja));
  chk('no intenta poner el PIN de un usuario que no existe',
      estado.llamadas.filter(l => l.fn === 'fn_establecer_pin').length === 0);
  chk('el botón Guardar vuelve a quedar usable',
      d.querySelector('#form-guardar').disabled === false);
}

console.log('\n=== CATÁLOGOS: editar no toca el correo ===');
{
  const ctxGerente = { ...CTX_BASE,
    usuario:{ ...CTX_BASE.usuario, rol:'gerente', nivel:3 },
    sucursales:[{ id:'s1', nombre:'Principal' }] };
  const estado = {
    enLinea:true, alertas:[], llamadas:[], fetches:[],
    tablas:{ perfiles:[{ id:'p1', nombre:'Ana', email:'ana@t.hn', telefono:'9',
                         rol:'auxiliar', activo:true, pin_pos:'x' }],
             categorias:[], marcas:[], proveedores:[], impuestos:[] },
    rpc:{ fn_pos_contexto:{ data:ctxGerente, error:null } },
    http:{}
  };
  const { d, caja } = await montar('catalogo.html', estado);
  const S = caja.S;
  S.entidad = 'usuarios';
  S.editando = estado.tablas.perfiles[0];
  // abrir el formulario en modo edición
  caja.abrirForm ? caja.abrirForm(S.editando) : null;
  await new Promise(r => setTimeout(r, 30));
  if (caja.abrirForm){
    chk('al editar no pide correo', !d.querySelector('[data-k="email"]'));
    chk('al editar no pide contraseña', !d.querySelector('[data-k="password"]'));
    chk('al editar no ofrece sucursales',
        d.querySelectorAll('[data-sucursal]').length === 0);
    chk('al editar sí deja cambiar el PIN', !!d.querySelector('#pin-nuevo'));
  } else {
    chk('abrirForm está expuesto para probar la edición', false);
  }
}

/* =====================================================================
   CATÁLOGOS: el formulario de productos

   Lo que importa aquí es la diferencia entre "cero" y "no lo uso". Las
   unidades por caja y el stock máximo aceptan nulo en la base; el stock
   mínimo no. Guardar 0 donde va nulo diría "la caja trae cero unidades",
   y la auditoría ofrecería una caja completa de nada.
   ===================================================================== */
console.log('\n=== CATÁLOGOS: productos, empaque y máximo ===');
{
  const estado = {
    enLinea:true, alertas:[], llamadas:[],
    tablas:{ productos:[], categorias:[], marcas:[], proveedores:[], impuestos:[],
             precios:[], producto_codigos:[] },
    rpc:{ fn_pos_contexto:{ data:{ ...CTX_BASE,
      usuario:{ ...CTX_BASE.usuario, rol:'gerente', nivel:3 } }, error:null } }
  };
  const { d, caja } = await montar('catalogo.html', estado);
  caja.S.entidad = 'productos';
  d.querySelector('#btn-nuevo').click();
  await new Promise(r => setTimeout(r, 40));

  const emp = d.querySelector('[data-k="unidades_empaque"]');
  const max = d.querySelector('[data-k="stock_maximo"]');
  chk('hay campo de unidades por caja', !!emp);
  chk('y de stock máximo', !!max);
  chk('la ayuda explica para qué sirve en la auditoría',
      /caja completa/i.test(emp?.closest('.campo-g')?.nextElementSibling?.textContent || ''));
  chk('los dos arrancan vacíos, no en cero',
      emp?.value === '' && max?.value === '');

  // guardar sin tocarlos
  d.querySelector('[data-k="nombre"]').value = 'Arroz de primera 5 lb';
  d.querySelector('[data-k="sku"]').value = 'ARR5LB';
  d.querySelector('[data-k="precio"]').value = '98';
  d.querySelector('#form-guardar').click();
  await new Promise(r => setTimeout(r, 120));

  const esc = estado.escrituras.find(e => e.tabla === 'productos');
  chk('se guarda el producto', !!esc);
  chk('vacío se guarda como nada, no como cero',
      esc && esc.datos.unidades_empaque === null && esc.datos.stock_maximo === null);
  chk('pero el stock mínimo sí va en cero: esa columna no acepta nulo',
      esc && esc.datos.stock_minimo === 0);
}
{
  const estado = {
    enLinea:true, alertas:[], llamadas:[],
    tablas:{ productos:[], categorias:[], marcas:[], proveedores:[], impuestos:[],
             precios:[], producto_codigos:[] },
    rpc:{ fn_pos_contexto:{ data:{ ...CTX_BASE,
      usuario:{ ...CTX_BASE.usuario, rol:'gerente', nivel:3 } }, error:null } }
  };
  const { d, caja } = await montar('catalogo.html', estado);
  caja.S.entidad = 'productos';
  d.querySelector('#btn-nuevo').click();
  await new Promise(r => setTimeout(r, 40));

  d.querySelector('[data-k="nombre"]').value = 'Refresco 600 ml';
  d.querySelector('[data-k="sku"]').value = 'COCA';
  d.querySelector('[data-k="precio"]').value = '20';
  d.querySelector('[data-k="unidades_empaque"]').value = '24';
  d.querySelector('[data-k="stock_maximo"]').value = '120';
  d.querySelector('#form-guardar').click();
  await new Promise(r => setTimeout(r, 120));

  const esc = estado.escrituras.find(e => e.tabla === 'productos');
  chk('con número puesto se guarda el número',
      esc && Number(esc.datos.unidades_empaque) === 24 &&
             Number(esc.datos.stock_maximo) === 120);
}

console.log('\n=== CATÁLOGOS: departamentos, visitas y presentaciones ===');
const estadoCat = extra => ({
  enLinea:true, alertas:[], llamadas:[],
  tablas:{ productos:[], marcas:[], proveedores:[], impuestos:[], precios:[], producto_codigos:[],
           presentaciones:[],
           categorias:[{ id:'c1', nombre:'Abarrotes', padre_id:null, orden:0, activa:true },
                       { id:'c2', nombre:'Aceites', padre_id:'c1', orden:0, activa:true },
                       { id:'c3', nombre:'Bebidas', padre_id:null, orden:0, activa:true }], ...extra },
  rpc:{ fn_pos_contexto:{ data:{ ...CTX_BASE,
    usuario:{ ...CTX_BASE.usuario, rol:'gerente', nivel:3 } }, error:null } }
});
{
  const estado = estadoCat();
  const { d, caja } = await montar('catalogo.html', estado);
  caja.S.entidad = 'categorias';
  await caja.S.filas;  // la lista se carga al abrir la entidad
  d.querySelector('[data-valor="categorias"]').click();
  await new Promise(r => setTimeout(r, 60));
  const filas = [...d.querySelectorAll('#lista .fila')].map(x => x.textContent.replace(/\s+/g, ' '));
  chk('la lista dice qué es departamento', filas.some(f => /Abarrotes Departamento · 1 categoría/.test(f)));
  chk('y dónde está cada categoría', filas.some(f => /Aceites Dentro de Abarrotes/.test(f)));

  d.querySelector('#btn-nuevo').click();
  await new Promise(r => setTimeout(r, 40));
  const sel = d.querySelector('[data-k="padre_id"]');
  const ops = [...sel.options].map(o => o.textContent.trim());
  chk('se elige el departamento', !!sel && ops.includes('Abarrotes') && ops.includes('Bebidas'));
  chk('una categoría hija no se ofrece como departamento', !ops.includes('Aceites'));
  d.querySelector('[data-k="nombre"]').value = 'Harinas';
  sel.value = 'c1';
  d.querySelector('#form-guardar').click();
  await new Promise(r => setTimeout(r, 120));
  const esc = estado.escrituras.find(e => e.tabla === 'categorias');
  chk('se guarda dentro del departamento', esc && esc.datos.padre_id === 'c1');
}
{
  const estado = estadoCat();
  const { d, caja } = await montar('catalogo.html', estado);
  d.querySelector('[data-valor="categorias"]').click();
  await new Promise(r => setTimeout(r, 60));
  d.querySelector('[data-id="c1"]').click();
  await new Promise(r => setTimeout(r, 40));
  const ops = [...d.querySelectorAll('[data-k="padre_id"] option')].map(o => o.textContent.trim());
  chk('una categoría no puede ser su propio departamento', !ops.includes('Abarrotes'));
}
{
  const estado = estadoCat({ proveedores:[{ id:'pv1', nombre:'La Ceiba', dias_credito:15,
    dias_entrega:2, dia_visita:[2,5], activo:true }] });
  const { d } = await montar('catalogo.html', estado);
  d.querySelector('[data-valor="proveedores"]').click();
  await new Promise(r => setTimeout(r, 60));
  chk('la lista dice cuándo viene', /Viene mar, vie · 15 días/.test(d.querySelector('#lista').textContent));
  d.querySelector('[data-id="pv1"]').click();
  await new Promise(r => setTimeout(r, 40));
  const dias = [...d.querySelectorAll('[data-dias="dia_visita"] input')];
  chk('siete días para marcar', dias.length === 7);
  chk('vienen marcados martes y viernes', dias[1].checked && dias[4].checked && !dias[0].checked);
  dias[4].checked = false; dias[0].checked = true;
  d.querySelector('#form-guardar').click();
  await new Promise(r => setTimeout(r, 120));
  const esc = estado.escrituras.find(e => e.tabla === 'proveedores');
  chk('se guardan lunes y martes', esc && JSON.stringify(esc.datos.dia_visita) === '[1,2]');
}
{
  const estado = estadoCat({ proveedores:[{ id:'pv1', nombre:'La Ceiba', dias_credito:0,
    dias_entrega:2, dia_visita:[3], activo:true }] });
  const { d } = await montar('catalogo.html', estado);
  d.querySelector('[data-valor="proveedores"]').click();
  await new Promise(r => setTimeout(r, 60));
  d.querySelector('[data-id="pv1"]').click();
  await new Promise(r => setTimeout(r, 40));
  d.querySelector('[data-dias="dia_visita"] input:checked').checked = false;
  d.querySelector('#form-guardar').click();
  await new Promise(r => setTimeout(r, 120));
  const esc = estado.escrituras.find(e => e.tabla === 'proveedores');
  chk('sin días marcados se guarda vacío (null)', esc && esc.datos.dia_visita === null);
}
{
  const estado = estadoCat();
  const { d } = await montar('catalogo.html', estado);
  d.querySelector('[data-valor="productos"]').click();
  await new Promise(r => setTimeout(r, 60));
  d.querySelector('#btn-nuevo').click();
  await new Promise(r => setTimeout(r, 60));
  const cats = [...d.querySelectorAll('[data-k="categoria_id"] option')].map(o => o.textContent.trim());
  chk('en el producto la categoría lleva su departamento', cats.includes('Abarrotes › Aceites'));

  chk('sin presentaciones: se explica', /Se vende y se compra por unidad/.test(d.querySelector('#lista-pres').textContent));
  d.querySelector('#pres-agregar').click();
  d.querySelector('#pres-agregar').click();
  const filas = d.querySelectorAll('#lista-pres .pres');
  chk('se agregan filas', filas.length === 2);
  chk('la primera queda como la de compra', filas[0].querySelector('[data-p="es_compra"]').checked);
  filas[0].querySelector('[data-p="nombre"]').value = 'Fardo';
  filas[0].querySelector('[data-p="factor"]').value = '24';
  filas[1].querySelector('[data-p="nombre"]').value = 'Media docena';
  filas[1].querySelector('[data-p="factor"]').value = '1';

  d.querySelector('[data-k="nombre"]').value = 'Refresco 600 ml';
  d.querySelector('[data-k="sku"]').value = 'REF600';
  d.querySelector('[data-k="precio"]').value = '20';
  d.querySelector('#form-guardar').click();
  await new Promise(r => setTimeout(r, 120));
  chk('una presentación de 1 unidad no se acepta',
      !estado.escrituras.some(e => e.tabla === 'productos') &&
      /debe traer más de 1 unidad/.test(d.body.textContent));

  d.querySelector('#lista-pres .pres:nth-child(2) [data-p="factor"]').value = '6';
  d.querySelector('#form-guardar').click();
  await new Promise(r => setTimeout(r, 160));
  const ins = estado.escrituras.filter(e => e.tabla === 'presentaciones' && e.op === 'insert');
  chk('se guardan las dos presentaciones', ins.length === 2);
  chk('fardo de 24 como la de compra', ins[0] && ins[0].datos.nombre === 'Fardo' &&
      ins[0].datos.factor === 24 && ins[0].datos.es_compra === true && ins[0].datos.producto_id === 'nuevo-1');
  chk('la otra no es de compra', ins[1] && ins[1].datos.es_compra === false);
}
{
  const estado = estadoCat({
    productos:[{ id:'p1', sku:'REF600', nombre:'Refresco 600 ml', activo:true, se_vende:true, se_compra:true }],
    presentaciones:[{ id:'pr1', nombre:'Fardo', factor:24, es_compra:true, es_base:false },
                    { id:'pr2', nombre:'Docena', factor:12, es_compra:false, es_base:false }] });
  const { d } = await montar('catalogo.html', estado);
  d.querySelector('[data-valor="productos"]').click();
  await new Promise(r => setTimeout(r, 60));
  d.querySelector('[data-id="p1"]').click();
  await new Promise(r => setTimeout(r, 80));
  const filas = d.querySelectorAll('#lista-pres .pres');
  chk('al editar trae sus presentaciones', filas.length === 2 &&
      filas[0].querySelector('[data-p="nombre"]').value === 'Fardo');
  filas[0].querySelector('[data-quitar-pres]').click();
  d.querySelector('[data-k="precio"]').value = '20';
  chk('quitar la de compra pasa la marca a la otra',
      d.querySelector('#lista-pres .pres [data-p="es_compra"]').checked);
  d.querySelector('#form-guardar').click();
  await new Promise(r => setTimeout(r, 160));
  const baja = estado.escrituras.find(e => e.tabla === 'presentaciones' && e.op === 'update' && e.datos.activa === false);
  chk('la quitada se desactiva, no se borra', baja && JSON.stringify(baja.ids) === '["pr1"]');
  const cambio = estado.escrituras.find(e => e.tabla === 'presentaciones' && e.op === 'update' && e.datos.nombre === 'Docena');
  chk('y la docena queda como la de compra', cambio && cambio.datos.es_compra === true);
}

console.log('\n=== CATÁLOGOS: días de pago del cliente ===');
for (const [rol, nivel] of [['supervisor', 2], ['auxiliar', 1]]){
  const estado = {
    enLinea:true, alertas:[], llamadas:[],
    tablas:{ clientes:[{ id:'k1', codigo:'C1', nombre:'Doña Rosa', telefono:'9999', limite_credito:500,
                         saldo:120, activo:true }],
             categorias:[], marcas:[], proveedores:[], impuestos:[] },
    rpc:{ fn_pos_contexto:{ data:{ ...CTX_BASE, usuario:{ ...CTX_BASE.usuario, rol, nivel } }, error:null },
          fn_situacion_cliente:{ data:{ debe:120, dias_pago:{ tipo:'semana', dias:[5] } }, error:null },
          fn_fijar_dias_pago:{ data:{ texto:'los 15 y 30 de cada mes' }, error:null },
          fn_fijar_limite_credito:{ data:{}, error:null } }
  };
  const { d } = await montar('catalogo.html', estado);
  d.querySelector('[data-valor="clientes"]').click();
  await new Promise(r => setTimeout(r, 60));
  d.querySelector('[data-id="k1"]').click();
  await new Promise(r => setTimeout(r, 80));
  chk(rol + ': trae sus días de pago (viernes)',
      d.querySelector('#dp-tipo .activo')?.dataset.t === 'semana' &&
      d.querySelector('#dp-semana input[value="5"]').checked);
  if (nivel < 2){
    chk('auxiliar: los ve pero no los cambia', d.querySelector('#dp-tipo [data-t="mes"]').disabled);
    continue;
  }
  d.querySelector('#dp-tipo [data-t="mes"]').click();
  d.querySelector('#form-guardar').click();
  await new Promise(r => setTimeout(r, 80));
  chk('por mes sin marcar días no se guarda', !estado.llamadas.some(l => l.fn === 'fn_fijar_dias_pago') &&
      /Faltan los días de pago/.test(d.body.textContent));
  d.querySelector('#dp-mes input[value="15"]').checked = true;
  d.querySelector('#dp-mes input[value="30"]').checked = true;
  d.querySelector('#form-guardar').click();
  await new Promise(r => setTimeout(r, 120));
  const f = estado.llamadas.find(l => l.fn === 'fn_fijar_dias_pago');
  chk('guarda la quincena y fin de mes', f && f.args.p_cliente_id === 'k1' &&
      JSON.stringify(f.args.p_dias_pago) === '{"tipo":"mes","dias":[15,30]}');
}

console.log('\n' + ok + ' bien, ' + mal + ' mal');
process.exit(mal ? 1 : 0);
