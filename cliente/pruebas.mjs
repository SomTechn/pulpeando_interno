/* Prueba funcional de la app del cliente, manejada como la manejaria alguien
   desde su telefono: entrar, elegir pulperia, armar el pedido, mandarlo. */
import fs from 'node:fs';
import { JSDOM } from 'jsdom';

const RUTA = '/home/claude/somtechn/pulpeando_interno/cliente/index.html';
let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };

const TIENDAS = [
  { organizacion_id:'o1', negocio:'Pulpería La Esquina', sucursal_id:'s1',
    sucursal:'La Esquina', direccion:'Col. Las Flores', telefono:'9999-1',
    moneda:'HNL', acepta_domicilio:true, costo_envio:25, pedido_minimo:100,
    productos:12, ya_soy_cliente:false },
  { organizacion_id:'o2', negocio:'Pulpería Doña Chus', sucursal_id:'s2',
    sucursal:'Doña Chus', direccion:'Col. El Centro', telefono:'9999-2',
    moneda:'HNL', acepta_domicilio:false, costo_envio:0, pedido_minimo:0,
    productos:5, ya_soy_cliente:true }
];

const CATALOGO = [
  { producto_id:'p1', nombre:'Arroz 5lb', categoria:'Abarrotes', precio:60,
    unidad:'unidad', disponible:true, sucursal_id:'s1', imagen_url:null, categoria_id:'c1' },
  { producto_id:'p2', nombre:'Frijol 1lb', categoria:'Abarrotes', precio:30,
    unidad:'unidad', disponible:true, sucursal_id:'s1', imagen_url:null, categoria_id:'c1' },
  { producto_id:'p3', nombre:'Huevo', categoria:'Lácteos', precio:5,
    unidad:'unidad', disponible:false, sucursal_id:'s1', imagen_url:null, categoria_id:'c2' }
];

async function montar(estado){
  const html = fs.readFileSync(RUTA, 'utf8');
  const cuerpo = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  const dom = new JSDOM(
    html.replace(/<script type="module">[\s\S]*?<\/script>/, '')
        .replace(/<script src="\.\.\/config\.js"><\/script>/, ''),
    { runScripts:'outside-only', url:'https://x.test/cliente/', pretendToBeVisual:true });

  const w = dom.window;
  w.SUPABASE_CONFIG = { url:'https://x.supabase.co', key:'k' };
  Object.defineProperty(w.navigator, 'serviceWorker',
    { value:{ register: async () => ({}) }, configurable:true });
  w.alert = m => estado.alertas.push(m);
  w.confirm = () => estado.confirmar !== false;
  w.scrollTo = () => {};
  w.Element.prototype.scrollIntoView = function(){};

  estado.llamadas = [];
  const sb = {
    auth:{
      getSession: async () => ({ data:{ session:estado.sesion
        ? { user:{ id:'u1' }, access_token:'tok' } : null } }),
      signInWithPassword: async (a) => { estado.llamadas.push({ fn:'signIn', a });
        return estado.signIn || { data:{ session:{ user:{ id:'u1' } } }, error:null }; },
      signUp: async (a) => { estado.llamadas.push({ fn:'signUp', a });
        return estado.signUp || { data:{ session:{ user:{ id:'u1' } } }, error:null }; },
      signOut: async () => {},
      onAuthStateChange(){}
    },
    rpc: async (fn, args) => {
      estado.llamadas.push({ fn, args });
      const h = estado.rpc[fn];
      if (h === undefined) return { data:null, error:{ message:'rpc sin simular: ' + fn } };
      return typeof h === 'function' ? h(args) : h;
    }
  };

  const prep = cuerpo
    .replace(/^import \{ createClient \} from 'https:\/\/esm\.sh\/@supabase\/supabase-js@2';$/m, '')
    .replace(/createClient\(URL_SB, KEY_SB, \{[\s\S]*?\}\)/, '__sb');

  w.__sb = sb;
  w.__caja = {};
  await w.eval(`(async () => { ${prep}
    ; window.__caja.S = S;
    ; window.__caja.irA = irA;
    ; window.__caja.sumar = sumar;
    ; window.__caja.plata = plata;
    ; window.__caja.mensaje = mensaje;
    ; window.__caja.cargarTiendas = cargarTiendas;
  })()`);
  await new Promise(r => setTimeout(r, 60));
  return { w, d:w.document, caja:w.__caja, estado };
}

const esperar = (ms = 40) => new Promise(r => setTimeout(r, ms));

/* =====================================================================
   Entrar
   ===================================================================== */
console.log('\n=== ENTRAR ===');
{
  const estado = { sesion:false, alertas:[], rpc:{} };
  const { d } = await montar(estado);
  chk('sin sesión muestra la portada',
      !d.querySelector('#p-entrar').classList.contains('oculto'));
  chk('y esconde la app', d.querySelector('#app').classList.contains('oculto'));

  d.querySelector('#e-correo').value = 'noesuncorreo';
  d.querySelector('#e-clave').value = 'secreta123';
  d.querySelector('#e-btn').click();
  await esperar();
  chk('un correo mal escrito no llega al servidor',
      estado.llamadas.filter(l => l.fn === 'signIn').length === 0);
  chk('y lo dice', /correo válido/i.test(d.querySelector('#e-error').textContent));

  d.querySelector('#e-correo').value = 'luz@correo.hn';
  d.querySelector('#e-clave').value = '123';
  d.querySelector('#e-btn').click();
  await esperar();
  chk('una contraseña corta tampoco',
      estado.llamadas.filter(l => l.fn === 'signIn').length === 0);
  chk('y lo dice', /6 caracteres/i.test(d.querySelector('#e-error').textContent));

  // cambiar a crear cuenta
  d.querySelector('#e-cambiar').click();
  chk('se puede pasar a crear cuenta',
      d.querySelector('#e-btn').textContent === 'Crear mi cuenta');
  chk('y el texto de abajo cambia',
      /Ya tengo cuenta/.test(d.querySelector('#e-cambiar').textContent));
  d.querySelector('#e-cambiar').click();
  chk('y se puede volver a entrar',
      d.querySelector('#e-btn').textContent === 'Entrar');
}

console.log('\n=== ENTRAR: el servidor rechaza ===');
{
  const estado = { sesion:false, alertas:[], rpc:{},
    signIn:{ data:null, error:{ message:'Invalid login credentials' } } };
  const { d } = await montar(estado);
  d.querySelector('#e-correo').value = 'luz@correo.hn';
  d.querySelector('#e-clave').value = 'equivocada';
  d.querySelector('#e-btn').click();
  await esperar();
  chk('traduce el error a algo entendible',
      /no coinciden/i.test(d.querySelector('#e-error').textContent));
  chk('el botón vuelve a quedar usable',
      d.querySelector('#e-btn').disabled === false
      && d.querySelector('#e-btn').textContent === 'Entrar');
  chk('sigue en la portada',
      !d.querySelector('#p-entrar').classList.contains('oculto'));
}

console.log('\n=== CREAR CUENTA que pide confirmar el correo ===');
{
  const estado = { sesion:false, alertas:[], rpc:{},
    signUp:{ data:{ session:null, user:{ id:'u1' } }, error:null } };
  const { d } = await montar(estado);
  d.querySelector('#e-cambiar').click();
  d.querySelector('#e-correo').value = 'luz@correo.hn';
  d.querySelector('#e-clave').value = 'secreta123';
  d.querySelector('#e-btn').click();
  await esperar();
  chk('no entra a la app sin sesión',
      d.querySelector('#app').classList.contains('oculto'));
  chk('le dice que revise su correo',
      /confirmar su cuenta/i.test(d.querySelector('#lema').textContent));
  chk('y lo deja listo para entrar',
      d.querySelector('#e-btn').textContent === 'Entrar');
}

/* =====================================================================
   Las pulperías
   ===================================================================== */
console.log('\n=== LAS PULPERÍAS ===');
{
  const estado = { sesion:true, alertas:[], rpc:{
    fn_tiendas_disponibles:{ data:TIENDAS, error:null },
    fn_mis_pedidos:{ data:[], error:null }
  }};
  const { d, caja } = await montar(estado);
  await esperar(80);

  chk('con sesión entra a la app',
      !d.querySelector('#app').classList.contains('oculto'));
  chk('pide las tiendas al entrar',
      estado.llamadas.some(l => l.fn === 'fn_tiendas_disponibles'));

  const rotulos = d.querySelectorAll('.rotulo');
  chk('pinta un rótulo por pulpería', rotulos.length === 2);
  chk('con el nombre del negocio',
      /La Esquina/.test(rotulos[0].textContent));
  chk('dice cuánto cobra el envío', /L 25\.00/.test(rotulos[0].textContent));
  chk('dice el pedido mínimo', /L 100\.00/.test(rotulos[0].textContent));
  chk('la que no reparte se dibuja distinto',
      rotulos[1].classList.contains('sin-envio'));
  chk('y dice que es solo para recoger',
      /Solo para recoger/.test(rotulos[1].textContent));
  chk('no muestra mínimo donde no hay',
      !/Desde/.test(rotulos[1].textContent));
  chk('marca donde ya pidió', /Ya pidió aquí/.test(rotulos[1].textContent));
  chk('no lo marca donde no', !/Ya pidió aquí/.test(rotulos[0].textContent));
  chk('no hay barra de carrito todavía',
      d.querySelector('#carrito-barra').classList.contains('oculto'));
  chk('la flecha de regresar está escondida en el inicio',
      d.querySelector('#atras').classList.contains('oculto'));
}

/* =====================================================================
   Armar el pedido
   ===================================================================== */
console.log('\n=== ARMAR EL PEDIDO ===');
{
  const estado = { sesion:true, alertas:[], rpc:{
    fn_tiendas_disponibles:{ data:TIENDAS, error:null },
    fn_catalogo_cliente:{ data:CATALOGO, error:null },
    fn_mis_pedidos:{ data:[], error:null }
  }};
  const { d, caja } = await montar(estado);
  await esperar(80);

  d.querySelector('[data-suc="s1"]').click();
  await esperar(80);

  chk('abre la pulpería', caja.S.tienda?.sucursal_id === 's1');
  chk('el título es el nombre del negocio',
      d.querySelector('#titulo').textContent === 'Pulpería La Esquina');
  chk('aparece la flecha de regresar',
      !d.querySelector('#atras').classList.contains('oculto'));
  chk('pide el catálogo de ESA sucursal',
      estado.llamadas.find(l => l.fn === 'fn_catalogo_cliente')?.args?.p_sucursal_id === 's1');
  chk('avisa cuánto cobra el envío',
      /domicilio por L 25\.00/.test(d.querySelector('.aviso').textContent));
  chk('y desde cuánto', /L 100\.00 o más/.test(d.querySelector('.aviso').textContent));

  const renglones = d.querySelectorAll('.renglon');
  chk('pinta un renglón por producto', renglones.length === 3);
  chk('agrupa por categoría', d.querySelectorAll('.rubro').length === 2);
  chk('el agotado se marca',
      [...renglones].some(r => r.classList.contains('agotado')));
  chk('y dice que se acabó',
      /Se acabó por hoy/.test(d.querySelector('.renglon.agotado').textContent));
  chk('el agotado no se puede agregar',
      d.querySelector('.renglon.agotado [data-mas]') === null);

  // agregar dos arroces
  d.querySelector('[data-mas="p1"]').click();
  await esperar(20);
  chk('al agregar aparece la barra del carrito',
      !d.querySelector('#carrito-barra').classList.contains('oculto'));
  chk('la barra cuenta una pieza',
      d.querySelector('#carrito-cuenta').textContent === '1');
  chk('y suma el precio',
      d.querySelector('#carrito-total').textContent === 'L 60.00');
  chk('el renglón cambia a contador',
      !!d.querySelector('[data-menos="p1"]'));

  d.querySelector('[data-mas="p1"]').click();
  await esperar(20);
  chk('dos piezas', d.querySelector('#carrito-cuenta').textContent === '2');
  chk('y L 120', d.querySelector('#carrito-total').textContent === 'L 120.00');

  d.querySelector('[data-menos="p1"]').click();
  await esperar(20);
  chk('se puede quitar uno', d.querySelector('#carrito-cuenta').textContent === '1');
  d.querySelector('[data-menos="p1"]').click();
  await esperar(20);
  chk('al llegar a cero sale del carrito', caja.S.carrito.length === 0);
  chk('y la barra se esconde',
      d.querySelector('#carrito-barra').classList.contains('oculto'));
  chk('el renglón vuelve al botón de más', !!d.querySelector('[data-mas="p1"]'));
}

/* =====================================================================
   Cambiar de pulpería con el carrito lleno
   ===================================================================== */
console.log('\n=== CAMBIAR DE PULPERÍA ===');
{
  const estado = { sesion:true, alertas:[], confirmar:false, rpc:{
    fn_tiendas_disponibles:{ data:TIENDAS, error:null },
    fn_catalogo_cliente:{ data:CATALOGO, error:null },
    fn_mis_pedidos:{ data:[], error:null }
  }};
  const { d, caja } = await montar(estado);
  await esperar(80);
  d.querySelector('[data-suc="s1"]').click();
  await esperar(80);
  d.querySelector('[data-mas="p1"]').click();
  await esperar(20);

  // regresar y entrar a la otra
  d.querySelector('#atras').click();
  await esperar(40);
  chk('vuelve al inicio', caja.S.vista === 'tiendas');
  chk('el carrito sigue lleno', caja.S.carrito.length === 1);

  d.querySelector('[data-suc="s2"]').click();
  await esperar(60);
  chk('si dice que no, no cambia de pulpería', caja.S.tienda?.sucursal_id === 's1');
  chk('y el carrito no se toca', caja.S.carrito.length === 1);

  estado.confirmar = true;
  d.querySelector('[data-suc="s2"]').click();
  await esperar(80);
  chk('si dice que sí, cambia', caja.S.tienda?.sucursal_id === 's2');
  chk('y el carrito se vacía', caja.S.carrito.length === 0);
  chk('en una tienda sin reparto arranca en recoger',
      caja.S.entrega === 'recoge_en_tienda');
}

/* =====================================================================
   El mínimo y el envío en el carrito
   ===================================================================== */
console.log('\n=== EL CARRITO ===');
{
  const estado = { sesion:true, alertas:[], rpc:{
    fn_tiendas_disponibles:{ data:TIENDAS, error:null },
    fn_catalogo_cliente:{ data:CATALOGO, error:null },
    fn_mis_pedidos:{ data:[], error:null }
  }};
  const { d, caja } = await montar(estado);
  await esperar(80);
  d.querySelector('[data-suc="s1"]').click();
  await esperar(80);

  // un frijol de L30: por debajo del minimo de L100
  d.querySelector('[data-mas="p2"]').click();
  await esperar(20);
  d.querySelector('#carrito-btn').click();
  await esperar(40);

  chk('entra al carrito', caja.S.vista === 'carrito');
  chk('la barra de abajo se esconde en el carrito',
      d.querySelector('#carrito-barra').classList.contains('oculto'));
  chk('avisa cuánto falta para el mínimo',
      /faltan L 70\.00/.test(d.querySelector('.aviso').textContent));
  chk('y no deja mandarlo', d.querySelector('#c-enviar').disabled === true);
  chk('el envío sale en la cuenta', /L 25\.00/.test(d.querySelector('.cuenta-lineas').textContent));
  chk('el total suma mercadería más envío',
      /L 55\.00/.test(d.querySelector('.cl.gorda').textContent));

  // pasar a recoger: sin envio y sin minimo
  d.querySelector('[data-entrega="recoge_en_tienda"]').click();
  await esperar(30);
  chk('al pasar a recoger no cobra envío',
      /Sin costo/.test(d.querySelector('.cuenta-lineas').textContent));
  chk('el total baja a la mercadería',
      /L 30\.00/.test(d.querySelector('.cl.gorda').textContent));
  chk('y ya deja mandarlo', d.querySelector('#c-enviar').disabled === false);
  chk('esconde la dirección cuando lo pasa a traer',
      d.querySelector('#caja-dir').classList.contains('oculto'));

  d.querySelector('[data-entrega="domicilio"]').click();
  await esperar(30);
  chk('al volver a domicilio pide la dirección',
      !d.querySelector('#caja-dir').classList.contains('oculto'));

  // subir a L120 con dos arroces
  d.querySelector('[data-menos="p2"]').click();
  await esperar(20);
  d.querySelector('#c-seguir') && d.querySelector('#c-seguir').click();
  await esperar(40);
}

/* =====================================================================
   Mandar el pedido
   ===================================================================== */
console.log('\n=== MANDAR EL PEDIDO ===');
{
  const estado = { sesion:true, alertas:[], rpc:{
    fn_tiendas_disponibles:{ data:TIENDAS, error:null },
    fn_catalogo_cliente:{ data:CATALOGO, error:null },
    fn_mis_pedidos:{ data:[], error:null },
    fn_crear_pedido:{ data:{ pedido_id:'pe1', numero:'P-001-000001',
      negocio:'Pulpería La Esquina', subtotal:120, impuesto:0, envio:25, total:145 },
      error:null }
  }};
  const { d, caja } = await montar(estado);
  await esperar(80);
  d.querySelector('[data-suc="s1"]').click();
  await esperar(80);
  d.querySelector('[data-mas="p1"]').click();
  d.querySelector('[data-mas="p1"]').click();
  await esperar(30);
  d.querySelector('#carrito-btn').click();
  await esperar(40);

  chk('con L120 ya no avisa del mínimo',
      !/faltan/.test(d.querySelector('.aviso').textContent));

  // mandar sin nombre
  d.querySelector('#c-enviar').click();
  await esperar(40);
  chk('sin nombre no manda nada',
      estado.llamadas.filter(l => l.fn === 'fn_crear_pedido').length === 0);
  chk('y pide el nombre', /nombre/i.test(d.querySelector('#c-error').textContent));

  d.querySelector('#c-nombre').value = 'Doña Luz';
  d.querySelector('#c-enviar').click();
  await esperar(40);
  chk('sin teléfono tampoco',
      estado.llamadas.filter(l => l.fn === 'fn_crear_pedido').length === 0);
  chk('y pide el teléfono', /teléfono/i.test(d.querySelector('#c-error').textContent));

  d.querySelector('#c-tel').value = '9999-1111';
  d.querySelector('#c-enviar').click();
  await esperar(40);
  chk('a domicilio sin dirección tampoco',
      estado.llamadas.filter(l => l.fn === 'fn_crear_pedido').length === 0);
  chk('y pide la dirección', /dónde/i.test(d.querySelector('#c-error').textContent));

  d.querySelector('#c-dir').value = 'Col. Las Flores, casa verde';
  d.querySelector('#c-paga').value = '200';
  d.querySelector('#c-notas').value = 'Toque el portón';
  d.querySelector('#c-enviar').click();
  await esperar(90);

  const p = estado.llamadas.find(l => l.fn === 'fn_crear_pedido');
  chk('ahora sí lo manda', !!p);
  chk('con la sucursal elegida', p?.args?.p_sucursal_id === 's1');
  chk('con los dos arroces',
      p?.args?.p_items?.length === 1 && p.args.p_items[0].cantidad === 2);
  chk('manda solo producto y cantidad, no el precio',
      p && Object.keys(p.args.p_items[0]).sort().join(',') === 'cantidad,producto_id');
  chk('NO manda el costo del envío', p && !('p_costo_envio' in p.args));
  chk('NO manda el cliente', p && !('p_cliente_id' in p.args));
  chk('con el nombre y el teléfono',
      p?.args?.p_nombre_contacto === 'Doña Luz'
      && p?.args?.p_telefono_contacto === '9999-1111');
  chk('con la dirección', p?.args?.p_direccion_texto === 'Col. Las Flores, casa verde');
  chk('con el vuelto', p?.args?.p_paga_con === 200);
  chk('con la nota', p?.args?.p_notas === 'Toque el portón');

  chk('vacía el carrito', caja.S.carrito.length === 0);
  chk('lleva a sus pedidos', caja.S.vista === 'pedidos');
  chk('y confirma con el número del pedido',
      /P-001-000001/.test(d.querySelector('#vista').textContent));
}

console.log('\n=== MANDAR EL PEDIDO: el servidor lo rechaza ===');
{
  const estado = { sesion:true, alertas:[], rpc:{
    fn_tiendas_disponibles:{ data:TIENDAS, error:null },
    fn_catalogo_cliente:{ data:CATALOGO, error:null },
    fn_mis_pedidos:{ data:[], error:null },
    fn_crear_pedido:{ data:null, error:{ message:
      'Esta pulperia lleva a domicilio desde 100.00. Su pedido va en 60.00' } }
  }};
  const { d, caja } = await montar(estado);
  await esperar(80);
  d.querySelector('[data-suc="s1"]').click();
  await esperar(80);
  d.querySelector('[data-mas="p1"]').click();
  d.querySelector('[data-mas="p1"]').click();
  await esperar(30);
  d.querySelector('#carrito-btn').click();
  await esperar(40);
  d.querySelector('#c-nombre').value = 'Doña Luz';
  d.querySelector('#c-tel').value = '9999-1111';
  d.querySelector('#c-dir').value = 'Col. Las Flores';
  d.querySelector('#c-enviar').click();
  await esperar(90);

  chk('muestra el motivo del servidor',
      /lleva a domicilio desde/i.test(d.querySelector('#c-error').textContent));
  chk('NO vacía el carrito', caja.S.carrito.length === 1);
  chk('se queda en el carrito', caja.S.vista === 'carrito');
  chk('el botón vuelve a quedar usable',
      d.querySelector('#c-enviar').disabled === false);
}

/* =====================================================================
   Sus pedidos
   ===================================================================== */
console.log('\n=== SUS PEDIDOS ===');
{
  const PEDIDOS = [
    { pedido_id:'pe1', numero:'P-001-000003', estado:'en_ruta',
      creado_en:'2026-10-07T18:00:00Z', entregado_en:null, total:145, costo_envio:25,
      tipo_entrega:'domicilio', direccion:'Col. Las Flores', repartidor:'Beto',
      lineas:2, negocio:'Pulpería La Esquina' },
    { pedido_id:'pe2', numero:'P-001-000002', estado:'nuevo',
      creado_en:'2026-10-07T17:00:00Z', entregado_en:null, total:60, costo_envio:0,
      tipo_entrega:'recoge_en_tienda', direccion:null, repartidor:null,
      lineas:1, negocio:'Pulpería La Esquina' },
    { pedido_id:'pe3', numero:'P-001-000001', estado:'cancelado',
      creado_en:'2026-10-06T10:00:00Z', entregado_en:null, total:30, costo_envio:0,
      tipo_entrega:'domicilio', direccion:'Col. Las Flores', repartidor:null,
      lineas:1, negocio:'Pulpería La Esquina' }
  ];
  const estado = { sesion:true, alertas:[], rpc:{
    fn_tiendas_disponibles:{ data:TIENDAS, error:null },
    fn_mis_pedidos:{ data:PEDIDOS, error:null },
    fn_cancelar_mi_pedido:{ data:null, error:null }
  }};
  const { d, caja } = await montar(estado);
  await esperar(90);

  chk('el globo cuenta los pedidos vivos',
      d.querySelector('#globo-pedidos').textContent === '2');
  chk('y se ve', !d.querySelector('#globo-pedidos').classList.contains('oculto'));

  d.querySelector('#btn-pedidos').click();
  await esperar(60);

  const ps = d.querySelectorAll('.pedido');
  chk('pinta los tres pedidos', ps.length === 3);
  chk('dice que ya va en camino', /Ya va en camino/.test(ps[0].textContent));
  chk('y con quién va', /con Beto/.test(ps[0].textContent));
  chk('la pista muestra el avance',
      ps[0].querySelectorAll('.tramo.hecho').length === 5);
  chk('el nuevo va al principio de la pista',
      ps[1].querySelectorAll('.tramo.hecho').length === 1);
  chk('el cancelado no lleva pista',
      ps[2].querySelectorAll('.tramo').length === 0);
  chk('y se dice cancelado', /Cancelado/.test(ps[2].textContent));
  chk('el de recoger lo dice', /Lo pasa a traer/.test(ps[1].textContent));
  chk('el de domicilio muestra la dirección', /Col\. Las Flores/.test(ps[0].textContent));

  chk('solo el nuevo se puede cancelar',
      d.querySelectorAll('[data-cancelar]').length === 1);
  chk('y es el nuevo',
      d.querySelector('[data-cancelar]').dataset.cancelar === 'pe2');

  d.querySelector('[data-cancelar]').click();
  await esperar(70);
  const c = estado.llamadas.find(l => l.fn === 'fn_cancelar_mi_pedido');
  chk('cancela el pedido correcto', c?.args?.p_pedido_id === 'pe2');
  chk('con un motivo', !!c?.args?.p_motivo);
}

console.log('\n=== SUS PEDIDOS: vacío ===');
{
  const estado = { sesion:true, alertas:[], rpc:{
    fn_tiendas_disponibles:{ data:TIENDAS, error:null },
    fn_mis_pedidos:{ data:[], error:null }
  }};
  const { d } = await montar(estado);
  await esperar(90);
  chk('el globo no se ve sin pedidos',
      d.querySelector('#globo-pedidos').classList.contains('oculto'));
  d.querySelector('#btn-pedidos').click();
  await esperar(50);
  chk('el vacío invita a pedir',
      /Elija una pulpería/.test(d.querySelector('.vacio').textContent));
}

/* =====================================================================
   Sin pulperías y sin conexión
   ===================================================================== */
console.log('\n=== CASOS FEOS ===');
{
  const estado = { sesion:true, alertas:[], rpc:{
    fn_tiendas_disponibles:{ data:[], error:null },
    fn_mis_pedidos:{ data:[], error:null }
  }};
  const { d } = await montar(estado);
  await esperar(90);
  chk('sin pulperías explica qué pasa',
      /Cuando una pulpería de su zona/.test(d.querySelector('.vacio').textContent));
}
{
  const estado = { sesion:true, alertas:[], rpc:{
    fn_tiendas_disponibles:{ data:null, error:{ message:'TypeError: Failed to fetch' } },
    fn_mis_pedidos:{ data:[], error:null }
  }};
  const { d, caja } = await montar(estado);
  await esperar(90);
  chk('sin conexión lo dice en palabras claras',
      /No hay conexión/.test(d.querySelector('#vista').textContent));
  chk('y no culpa al usuario con jerga',
      !/TypeError|fetch/.test(d.querySelector('#vista').textContent));
  chk('traduce el JWT vencido',
      /sesión venció/i.test(caja.mensaje({ message:'JWT expired' })));
}

console.log('\n' + ok + ' bien, ' + mal + ' mal');
process.exit(mal ? 1 : 0);
