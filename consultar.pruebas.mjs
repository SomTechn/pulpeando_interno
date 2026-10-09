/* Prueba funcional de la pantalla de consulta.

   Lo que se vigila aqui:
     · que escanear un codigo entre directo al producto, sin lista de por medio
     · que el auxiliar NUNCA vea costo, margen ni valor del inventario
     · que los vencimientos se clasifiquen bien (vencido / por vencer / lejos)
     · que el desglose por ubicacion sume siempre la existencia total
     · que mover de lugar no deje mandar cero, ni al mismo lugar
*/
import fs from 'node:fs';
import { JSDOM } from 'jsdom';

const BASE = '/home/claude/somtechn/pulpeando_interno/';
let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };

const dia = n => new Date(Date.now() + n*86400000).toISOString().slice(0,10);

const CTX = (rol = 'gerente', nivel = 3) => ({
  usuario:{ id:'u1', nombre:'Somar', rol, nivel, tiene_pin:true },
  organizacion:{ id:'o1', nombre:'Pulpería Pulpeando', moneda:'HNL', factura_fiscal:false },
  sucursales:[{ id:'s1', nombre:'Central', codigo:'S01' }],
  cajas:[], impuesto_default:0, sin_sucursal:false });

const BUSCA_VARIOS = [
  { producto_id:'p1', nombre:'Leche entera 1 L', sku:'LEC1L', codigo:'7421001234567',
    categoria:'Lácteos', unidad:'UND', precio:28, existencia:60, exacto:false },
  { producto_id:'p2', nombre:'Leche en polvo 400 g', sku:'LECPOL', codigo:null,
    categoria:'Lácteos', unidad:'UND', precio:132.5, existencia:8, exacto:false }
];
const BUSCA_EXACTO = [{ ...BUSCA_VARIOS[0], exacto:true }];

const PERFIL = (ve = true) => ({
  producto_id:'p1', nombre:'Leche entera 1 L', sku:'LEC1L', descripcion:null,
  imagen_url:null, unidad:'UND', tipo:'unidad', activo:true, se_vende:true,
  categoria:'Lácteos', marca:'Sula', proveedor:'Lácteos S.A.',
  tasa_impuesto:0.15, controla_lote:true, controla_vencimiento:true, dias_alerta:10,
  sucursal_id:'s1', sucursal:'Central',
  codigos:['7421001234567'],
  precio:28, precios:[{ nivel:'detalle', desde:1, precio:28 }],
  costo_promedio: ve ? 18.2 : null,
  ultimo_costo:   ve ? 18.2 : null,
  margen:         ve ? 35.0 : null,
  valor_inventario: ve ? 1092 : null,
  existencia:60, apartado:6, disponible:54,
  stock_minimo:10, stock_maximo:null, stock_bajo:false,
  ubicaciones:[
    { ubicacion_id:'u1', nombre:'Piso de ventas', predeterminada:true, cantidad:18 },
    { ubicacion_id:'u2', nombre:'Refrigerador', predeterminada:false, cantidad:12 },
    { ubicacion_id:'u3', nombre:'Bodega', predeterminada:false, cantidad:30 }
  ],
  lotes:[
    { lote_id:'lo0', codigo:'L-VIEJO', vence:dia(-62), dias:-62, cantidad:6 },
    { lote_id:'lo1', codigo:'L-ENE',   vence:dia(7),   dias:7,   cantidad:24 },
    { lote_id:'lo2', codigo:'L-FEB',   vence:dia(45),  dias:45,  cantidad:30 }
  ],
  sin_lote:0,
  otras_sucursales:[{ sucursal:'El Carmen', cantidad:14 }],
  ultima_compra:{ fecha:dia(-14)+'T18:00:00Z', cantidad:60, costo: ve ? 18.2 : null },
  ultima_venta:dia(-1)+'T22:00:00Z',
  vendido_30d:142,
  conteo_abierto:null,
  ajustes_pendientes:[],
  puede_aprobar:ve,
  puede_ver_costos:ve
});

const PENDIENTE = {
  ajuste_id:'aj1', numero:'AJ-S01-000001', ubicacion:'Piso de ventas',
  ubicacion_id:'u1', lote_id:null, lote:null,
  sistema:18, contado:14, diferencia:-4, motivo:'Conté el estante',
  solicitado_por:'Ana', solicitado_en:dia(0)+'T14:00:00Z' };

const BANDEJA = [{
  ajuste_id:'aj1', numero:'AJ-S01-000001', estado:'pendiente',
  producto_id:'p1', producto:'Leche entera 1 L', sku:'LEC1L', unidad:'UND',
  lote:null, vence:null, ubicacion:'Piso de ventas', sucursal:'Central',
  sistema:18, contado:14, diferencia:-4, valor:-72.8, motivo:'Conté el estante',
  solicitado_por:'Ana', solicitado_en:dia(0)+'T14:00:00Z',
  resuelto_por:null, resuelto_en:null, nota:null, aplicado:null }];

const POR_LOTE = [
  { ubicacion_id:'u1', ubicacion:'Piso de ventas', es_predeterminada:true, orden:10, cantidad:18 },
  { ubicacion_id:'u2', ubicacion:'Refrigerador', es_predeterminada:false, orden:20, cantidad:12 },
  { ubicacion_id:'u3', ubicacion:'Bodega', es_predeterminada:false, orden:200, cantidad:30 }
];

const lunes = k => {
  const x = new Date();
  x.setDate(x.getDate() - ((x.getDay() + 6) % 7) - 7*k);
  return x.toISOString().slice(0,10);
};
const SEMANAS = [
  { semana_inicio:lunes(4), semana_fin:dia(0), unidades:38, importe:1064 },
  { semana_inicio:lunes(3), semana_fin:dia(0), unidades:0,  importe:0 },
  { semana_inicio:lunes(2), semana_fin:dia(0), unidades:51, importe:1428 },
  { semana_inicio:lunes(1), semana_fin:dia(0), unidades:44, importe:1232 },
  { semana_inicio:lunes(0), semana_fin:dia(0), unidades:19, importe:532 }
];

async function montar(estado){
  const html = fs.readFileSync(BASE + 'consultar.html', 'utf8');
  const cuerpo = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  const css = fs.readFileSync(BASE + 'ui.css', 'utf8');

  const dom = new JSDOM(
    html.replace(/<script type="module">[\s\S]*?<\/script>/, '')
        .replace('<link rel="stylesheet" href="ui.css">', '<style>' + css + '</style>')
        .replace(/<script src="config\.js"><\/script>/, ''),
    { runScripts:'outside-only', url:'https://x.test/consultar.html', pretendToBeVisual:true });

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
  w.escanear = async () => estado.codigo || null;
  w.hayCamara = async () => !!estado.camara;

  const prep = cuerpo
    .replace(/^import \{ createClient \} from 'https:\/\/esm\.sh\/@supabase\/supabase-js@2';$/m, '')
    .replace(/^import \{ montarMenu, escapar \} from '\.\/menu\.js';$/m, '')
    .replace(/^import \{ escanear, hayCamara \} from '\.\/escaner\.js';$/m, '')
    .replace(/createClient\(SUPABASE_URL, SUPABASE_KEY, \{[\s\S]*?\}\)/, '__sb');

  w.__p = {};
  await w.eval(`(async () => { ${prep}
    ; window.__p.S = S; window.__p.buscar = buscar; window.__p.abrir = abrir;
    ; window.__p.hojaMover = hojaMover; window.__p.hojaConteo = hojaConteo;
    ; window.__p.escanearCodigo = escanearCodigo;
  })()`);
  await new Promise(r => setTimeout(r, 160));
  return { w, d:w.document, p:w.__p, estado };
}

const esperar = (ms = 80) => new Promise(r => setTimeout(r, ms));

const base = (rol = 'gerente', nivel = 3, extra = {}) => ({
  camara:false,
  rpc:{
    fn_pos_contexto:{ data:CTX(rol, nivel), error:null },
    fn_buscar_para_consulta:{ data:BUSCA_VARIOS, error:null },
    fn_consultar_producto:{ data:PERFIL(nivel >= 2), error:null },
    fn_ventas_producto_semanas:{ data:SEMANAS, error:null },
    fn_mover_entre_ubicaciones:{ data:{ producto:'Leche entera 1 L', desde:'Bodega',
                                        hacia:'Piso de ventas', cantidad:5 }, error:null },
    fn_agregar_a_conteo:{ data:{ conteo_id:'c9', numero:'C-S01-000004',
                                 alcance:'seleccion', conteo_nuevo:true, agregadas:4,
                                 ya_estaba:false, lineas_producto:4,
                                 producto:'Leche entera 1 L' }, error:null },
    fn_ajustes:{ data:[], error:null },
    fn_existencia_ubicacion_lote:{ data:POR_LOTE, error:null },
    fn_solicitar_ajuste: a => ({ data:{
      ajuste_id:'ajN', numero:'AJ-S01-000009',
      ubicacion:'Piso de ventas', producto:'Leche entera 1 L',
      sistema:18, contado:a.p_cantidad, diferencia:a.p_cantidad - 18,
      puede_aprobar:nivel >= 3 }, error:null }),
    fn_resolver_ajuste:{ data:{ numero:'AJ-S01-000001', estado:'aprobado',
      ubicacion:'Piso de ventas', producto:'Leche entera 1 L',
      diferencia:-4, queda_en:14, existencia_total:56, valor:-72.8 }, error:null }
  }, ...extra });

/* ===================================================================== */
console.log('\n=== ARRANQUE ===');
{
  const estado = base();
  const { d } = await montar(estado);
  chk('entra', !d.querySelector('#app').classList.contains('oculto'));
  chk('dice la sucursal', d.querySelector('#h-sucursal').textContent === 'Central');
  chk('no busca nada todavía',
      !estado.llamadas.some(l => l.fn === 'fn_buscar_para_consulta'));
  chk('explica para qué sirve', /escanee/i.test(d.querySelector('#cuerpo').textContent));
  chk('sin cámara no ofrece escanear',
      d.querySelector('#btn-camara').classList.contains('oculto'));
}

{
  const estado = base();
  estado.camara = true;
  const { d } = await montar(estado);
  chk('con cámara sí ofrece escanear',
      !d.querySelector('#btn-camara').classList.contains('oculto'));
}

console.log('\n=== EL REPARTIDOR NO ENTRA ===');
{
  const estado = base('repartidor', 0);
  const { d } = await montar(estado);
  chk('lo bloquea', !d.querySelector('#p-bloqueado').classList.contains('oculto'));
  chk('no monta la pantalla', d.querySelector('#app').classList.contains('oculto'));
  chk('no pide ningún producto',
      !estado.llamadas.some(l => l.fn === 'fn_consultar_producto'));
}

console.log('\n=== BUSCAR ===');
{
  const estado = base();
  const { d, p } = await montar(estado);
  p.S.busqueda = 'leche';
  await p.buscar();
  await esperar();
  chk('muestra los dos', d.querySelectorAll('.res').length === 2);
  chk('manda la sucursal', estado.llamadas.find(l => l.fn === 'fn_buscar_para_consulta')
        .args.p_sucursal_id === 's1');
  chk('no abre ninguno solo', p.S.vista === 'resultados');
  chk('la categoría va primero en el renglón chico',
      /^Lácteos · LEC1L/.test(d.querySelector('.res-sub').textContent.trim()));
  chk('muestra la existencia de cada uno',
      /60 UND/.test(d.querySelectorAll('.res')[0].textContent));
}

{
  const estado = base();
  estado.rpc.fn_buscar_para_consulta = { data:[], error:null };
  const { d, p } = await montar(estado);
  p.S.busqueda = 'xyz';
  await p.buscar();
  await esperar();
  chk('sin resultados lo dice con el término buscado',
      /xyz/.test(d.querySelector('#cuerpo').textContent));
  chk('y sugiere qué hacer', /Catálogos/.test(d.querySelector('#cuerpo').textContent));
}

console.log('\n=== ESCANEAR ENTRA DIRECTO ===');
{
  const estado = base();
  estado.camara = true;
  estado.codigo = '7421001234567';
  estado.rpc.fn_buscar_para_consulta = { data:BUSCA_EXACTO, error:null };
  const { d, p } = await montar(estado);
  await p.escanearCodigo();
  await esperar(140);
  chk('no deja una lista de un solo elemento', !d.querySelector('.res'));
  chk('abre el producto', p.S.vista === 'ficha');
  chk('pide el perfil', estado.llamadas.some(l => l.fn === 'fn_consultar_producto'));
  chk('y las semanas en la misma pasada',
      estado.llamadas.some(l => l.fn === 'fn_ventas_producto_semanas'));
  chk('el campo queda con el código para el siguiente',
      d.querySelector('#buscar').value === '7421001234567');
}

{
  // Dos resultados con el mismo codigo no deberia pasar, pero si pasa no se
  // puede adivinar: se muestra la lista.
  const estado = base();
  estado.camara = true;
  estado.codigo = '742';
  const { d, p } = await montar(estado);
  await p.escanearCodigo();
  await esperar(140);
  chk('con varios resultados muestra la lista', d.querySelectorAll('.res').length === 2);
}

console.log('\n=== LA FICHA ===');
{
  const estado = base();
  const { d, p } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  const t = d.querySelector('#cuerpo').textContent;

  chk('el nombre', /Leche entera 1 L/.test(t));
  chk('el precio', /L 28\.00/.test(t));
  chk('el código de barras', /7421001234567/.test(t));
  chk('la existencia total', /60/.test(d.querySelector('.exi-total b').textContent));
  chk('sin decimales de relleno', d.querySelector('.exi-total b').textContent === '60');

  const lug = [...d.querySelectorAll('.lugar-n')].map(e => Number(e.textContent));
  chk('las tres ubicaciones', d.querySelectorAll('.lugares .lugar').length >= 3);
  chk('el desglose suma el total', lug[0] + lug[1] + lug[2] === 60);
  chk('dice dónde cae lo no asignado',
      /Piso de ventas/.test(d.querySelector('.lugar-pie').textContent));
  chk('avisa lo apartado para pedidos', /6 apartado/.test(t));
  chk('muestra la otra sucursal', /El Carmen/.test(t));
}

console.log('\n=== PLATA: SOLO DE SUPERVISOR PARA ARRIBA ===');
{
  const estado = base('auxiliar', 1);
  const { d, p } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  const t = d.querySelector('#cuerpo').textContent;
  chk('la auxiliar no ve costo', !/Costo promedio/.test(t));
  chk('ni margen', !/Margen/.test(t));
  chk('ni el valor del inventario', !/Valor del inventario/.test(t));
  chk('pero sí el precio de venta', /L 28\.00/.test(t));
  chk('y sí la existencia', /60/.test(d.querySelector('.exi-total b').textContent));
  chk('y sí los vencimientos', /L-VIEJO/.test(t));
}
{
  const estado = base('supervisor', 2);
  const { d, p } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  const t = d.querySelector('#cuerpo').textContent;
  chk('el supervisor sí ve costo', /Costo promedio/.test(t) && /L 18\.20/.test(t));
  chk('y el margen', /35%/.test(t));
  chk('y el valor del inventario', /L 1,092\.00/.test(t));
}

console.log('\n=== VENCIMIENTOS ===');
{
  const estado = base();
  const { d, p } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  const lotes = [...d.querySelectorAll('.lote')];
  const vencido = lotes.find(l => /L-VIEJO/.test(l.textContent));
  const cerca   = lotes.find(l => /L-ENE/.test(l.textContent));
  const lejos   = lotes.find(l => /L-FEB/.test(l.textContent));

  chk('el vencido lo dice en palabras', /Vencido hace 62 días/.test(vencido.textContent));
  chk('y lo marca en rojo', vencido.querySelector('.semaforo.vencido') !== null);
  chk('el que vence en 7 días avisa', /Vence en 7 días/.test(cerca.textContent));
  chk('con el margen del producto (10 días), no con el del negocio',
      cerca.querySelector('.semaforo.cerca') !== null);
  chk('el de 45 días no alarma',
      lejos.querySelector('.semaforo.cerca') === null &&
      lejos.querySelector('.semaforo.vencido') === null);
  chk('cada lote trae su cantidad',
      vencido.querySelector('.lote-n').textContent === '6');
}

console.log('\n=== LA GRÁFICA DE 5 SEMANAS ===');
{
  const estado = base();
  const { d, p } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  chk('cinco barras', d.querySelectorAll('.graf .gcol').length === 5);
  chk('la semana sin ventas también sale',
      d.querySelectorAll('.graf .gcol.vacia').length === 1);
  chk('la última está marcada como la de ahora',
      d.querySelectorAll('.graf .gcol')[4].classList.contains('ahora'));
  chk('cada barra lleva su número, no solo color',
      [...d.querySelectorAll('.gnum')].map(e => e.textContent).join(',') === '38,0,51,44,19');
  chk('el total de las 5 semanas', /152 UND/.test(d.querySelector('.graf-tot').textContent));
  chk('y el importe', /L 4,256\.00/.test(d.querySelector('.graf-tot').textContent));
}
{
  // Un producto nuevo no tiene ventas: la grafica no puede reventar
  const estado = base();
  estado.rpc.fn_ventas_producto_semanas = {
    data:SEMANAS.map(s => ({ ...s, unidades:0, importe:0 })), error:null };
  const { d, p } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  chk('sin ninguna venta no divide entre cero',
      d.querySelectorAll('.graf .gcol').length === 5);
  chk('y el total queda en cero', /0 UND/.test(d.querySelector('.graf-tot').textContent));
}

console.log('\n=== MOVER DE LUGAR ===');
{
  const estado = base();
  const { d, p, w } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  p.hojaMover();
  await esperar();

  chk('abre la hoja', !d.querySelector('#velo').classList.contains('oculto'));
  chk('ofrece las tres ubicaciones como origen',
      d.querySelectorAll('#mv-desde option').length === 3);
  chk('el destino no arranca igual que el origen',
      d.querySelector('#mv-desde').value !== d.querySelector('#mv-hacia').value);
  chk('pide el lote', d.querySelector('#mv-lote') !== null);
  chk('la cantidad del lote se ve antes de la fecha',
      /L-VIEJO \(6\) · vence/.test(d.querySelector('#mv-lote').textContent));
  chk('avisa que las cantidades son de todos los lotes',
      /todos los lotes juntos/.test(d.querySelector('#hoja').textContent));

  // mismo lugar
  d.querySelector('#mv-hacia').value = d.querySelector('#mv-desde').value;
  d.querySelector('#mv-cant').value = '5';
  d.querySelector('#mv-si').click();
  await esperar();
  chk('no deja mover al mismo lugar',
      /mismo lugar/.test(d.querySelector('#mv-error').textContent));
  chk('y no llamó al servidor',
      !estado.llamadas.some(l => l.fn === 'fn_mover_entre_ubicaciones'));

  // cantidad vacia
  d.querySelector('#mv-hacia').value = 'u3';
  d.querySelector('#mv-desde').value = 'u1';
  d.querySelector('#mv-cant').value = '';
  d.querySelector('#mv-si').click();
  await esperar();
  chk('no deja mover sin cantidad',
      /cuánto se mueve/.test(d.querySelector('#mv-error').textContent));

  // el signo menos no entra en el campo
  const campo = d.querySelector('#mv-cant');
  campo.value = '-5';
  campo.dispatchEvent(new w.Event('input', { bubbles:true }));
  chk('el campo no acepta negativos', campo.value === '5');

  // ahora sí
  campo.value = '5';
  d.querySelector('#mv-si').click();
  await esperar(140);
  const mov = estado.llamadas.find(l => l.fn === 'fn_mover_entre_ubicaciones');
  chk('manda el movimiento', !!mov);
  chk('con producto, origen, destino, lote y cantidad',
      mov.args.p_producto_id === 'p1' && mov.args.p_desde === 'u1' &&
      mov.args.p_hacia === 'u3' && mov.args.p_cantidad === 5 &&
      mov.args.p_lote_id === 'lo0');
  chk('vuelve a leer la ficha después de mover',
      estado.llamadas.filter(l => l.fn === 'fn_consultar_producto').length >= 2);
}
{
  // El error del servidor se muestra tal cual: "En Bodega solo hay 2" es
  // justo lo que la persona necesita leer.
  const estado = base();
  estado.rpc.fn_mover_entre_ubicaciones = {
    data:null, error:{ message:'En Bodega solo hay 2.000 para mover' } };
  const { d, p } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  p.hojaMover();
  await esperar();
  d.querySelector('#mv-desde').value = 'u1';
  d.querySelector('#mv-hacia').value = 'u3';
  d.querySelector('#mv-cant').value = '99';
  d.querySelector('#mv-si').click();
  await esperar(140);
  chk('muestra el motivo del servidor',
      /solo hay 2/.test(d.querySelector('#mv-error').textContent));
  chk('y la hoja sigue abierta para corregir',
      !d.querySelector('#velo').classList.contains('oculto'));
}
{
  // Una sucursal con una sola ubicacion no tiene a donde mover
  const estado = base();
  const perfil = PERFIL(true);
  perfil.ubicaciones = [{ ubicacion_id:'u1', nombre:'Piso de ventas',
                          predeterminada:true, cantidad:60 }];
  estado.rpc.fn_consultar_producto = { data:perfil, error:null };
  const { d, p } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  p.hojaMover();
  await esperar();
  chk('con una sola ubicación explica que falta configurarlas',
      /Falta configurar ubicaciones/.test(d.querySelector('#hoja').textContent));
  chk('y no muestra el formulario', d.querySelector('#mv-desde') === null);
}

console.log('\n=== GENERAR CONTEO DESDE EL PRODUCTO ===');
{
  const estado = base();
  const { d, p } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  chk('sin conteo abierto el botón dice generar',
      /Generar conteo/.test(d.querySelector('#btn-conteo').textContent));
  p.hojaConteo();
  await esperar();
  chk('explica que sólo lleva lo que se agregue',
      /solo los productos que usted agregue/.test(d.querySelector('#hoja').textContent));
  chk('recuerda que el que cuenta no ve la cifra',
      /no se muestra a quien cuenta/.test(d.querySelector('#hoja').textContent));

  d.querySelector('#ct-si').click();
  await esperar(140);
  const ag = estado.llamadas.find(l => l.fn === 'fn_agregar_a_conteo');
  chk('lo manda al servidor', !!ag);
  chk('sin conteo previo manda null', ag.args.p_conteo_id === null);
  chk('dice el número del conteo', /C-S01-000004/.test(d.querySelector('#hoja').textContent));
  chk('y cuántas líneas quedaron', /4 líneas/.test(d.querySelector('#hoja').textContent));
  chk('ofrece ir al conteo',
      d.querySelector('#hoja a[href="conteo.html"]') !== null);
}
{
  const estado = base();
  const perfil = PERFIL(true);
  perfil.conteo_abierto = { conteo_id:'c1', numero:'C-S01-000001', alcance:'general' };
  estado.rpc.fn_consultar_producto = { data:perfil, error:null };
  estado.rpc.fn_agregar_a_conteo = { data:{ conteo_id:'c1', numero:'C-S01-000001',
    alcance:'general', conteo_nuevo:false, agregadas:0, ya_estaba:true,
    lineas_producto:3, producto:'Leche entera 1 L' }, error:null };
  const { d, p } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  chk('con un conteo abierto el botón nombra ese conteo',
      /C-S01-000001/.test(d.querySelector('#btn-conteo').textContent));
  p.hojaConteo();
  await esperar();
  chk('avisa que se suma al que ya está abierto',
      /ya hay un conteo abierto/i.test(d.querySelector('#hoja').textContent));
  d.querySelector('#ct-si').click();
  await esperar(140);
  const ag = estado.llamadas.find(l => l.fn === 'fn_agregar_a_conteo');
  chk('manda el conteo abierto', ag.args.p_conteo_id === 'c1');
  chk('si ya estaba lo dice sin asustar',
      /Ya estaba en el conteo/.test(d.querySelector('#hoja').textContent));
}
{
  // La auxiliar sin conteo abierto no puede abrirlo: el servidor la para y
  // la pantalla tiene que mostrar ese motivo, no un error crudo.
  const estado = base('auxiliar', 1);
  estado.rpc.fn_agregar_a_conteo = { data:null,
    error:{ message:'Solo un supervisor puede abrir un conteo' } };
  const { d, p } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  p.hojaConteo();
  await esperar();
  d.querySelector('#ct-si').click();
  await esperar(140);
  chk('muestra que hace falta un supervisor',
      /Solo un supervisor/.test(d.querySelector('#ct-error').textContent));
  chk('y el botón vuelve a quedar usable',
      d.querySelector('#ct-si').disabled === false);
}

console.log('\n=== PRODUCTOS RAROS ===');
{
  const estado = base();
  const perfil = PERFIL(true);
  perfil.lotes = []; perfil.sin_lote = 60; perfil.controla_vencimiento = false;
  estado.rpc.fn_consultar_producto = { data:perfil, error:null };
  const { d, p } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  chk('sin lotes no dibuja la sección de vencimientos',
      !/VENCIMIENTOS/.test(d.querySelector('#cuerpo').textContent));
  chk('pero la existencia sigue estando',
      d.querySelector('.exi-total b').textContent === '60');
}
{
  const estado = base();
  const perfil = PERFIL(true);
  perfil.activo = false; perfil.existencia = 4; perfil.stock_bajo = true;
  perfil.ubicaciones = perfil.ubicaciones.map(u => ({ ...u, cantidad: u.predeterminada ? 4 : 0 }));
  perfil.lotes = []; perfil.sin_lote = 4;
  estado.rpc.fn_consultar_producto = { data:perfil, error:null };
  const { d, p } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  chk('marca el producto inactivo', /Inactivo/.test(d.querySelector('.chips').textContent));
  chk('marca que está bajo el mínimo', /Bajo el mínimo/.test(d.querySelector('.chips').textContent));
  chk('y pinta el total en alerta',
      d.querySelector('.exi-total').classList.contains('bajo'));
}
{
  const estado = base();
  const perfil = PERFIL(true);
  perfil.existencia = 0.5; perfil.unidad = 'LB';
  perfil.ubicaciones = [{ ubicacion_id:'u1', nombre:'Piso de ventas',
                          predeterminada:true, cantidad:0.5 }];
  perfil.lotes = []; perfil.sin_lote = 0.5;
  estado.rpc.fn_consultar_producto = { data:perfil, error:null };
  const { d, p } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  chk('media libra se lee como 0.5, no 0.500',
      d.querySelector('.exi-total b').textContent === '0.5');
}
{
  const estado = base();
  estado.rpc.fn_consultar_producto = { data:null,
    error:{ message:'Ese producto no es de su negocio' } };
  const { d, p } = await montar(estado);
  p.S.busqueda = 'leche';
  await p.buscar();
  await esperar();
  await p.abrir('p1');
  await esperar(140);
  chk('un producto ajeno no se pinta', !d.querySelector('.ficha'));
  chk('y avisa por qué', /no es de su negocio/.test(d.querySelector('#hoja').textContent));
}

console.log('\n=== LA BANDEJA DE APROBACIÓN EN LA PORTADA ===');
{
  const estado = base();
  const { d } = await montar(estado);
  chk('sin pendientes no estorba', !d.querySelector('.pend'));
}
{
  const estado = base();
  estado.rpc.fn_ajustes = { data:BANDEJA, error:null };
  const { d, estado:e } = await montar(estado);
  chk('pide solo los pendientes',
      e.llamadas.find(l => l.fn === 'fn_ajustes').args.p_estado === 'pendiente');
  chk('muestra la bandeja', !!d.querySelector('.pend'));
  chk('en singular con uno solo', /Un ajuste espera/.test(d.querySelector('.pend').textContent));
  chk('dice de cuánto a cuánto', /de 18 a 14/.test(d.querySelector('.pend').textContent));
  chk('y la diferencia con signo', d.querySelector('.pend-dif').textContent === '−4');
  chk('el gerente puede tocar para revisar',
      /Toque uno para revisarlo/.test(d.querySelector('.pend-espera').textContent));
}
{
  const estado = base('auxiliar', 1);
  estado.rpc.fn_ajustes = { data:BANDEJA, error:null };
  const { d } = await montar(estado);
  chk('la auxiliar también ve la bandeja', !!d.querySelector('.pend'));
  chk('pero le dice que la aprueba el gerente',
      /El gerente los aprueba/.test(d.querySelector('.pend-espera').textContent));
}

console.log('\n=== EDITAR INVENTARIO ===');
{
  const estado = base();
  const { d, p, w, estado:e } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  chk('hay botón de editar', !!d.querySelector('#btn-editar'));

  d.querySelector('#btn-editar').click();
  await esperar(150);
  chk('pide el desglose del lote',
      e.llamadas.some(l => l.fn === 'fn_existencia_ubicacion_lote'));
  chk('arranca por el lote que vence primero',
      e.llamadas.find(l => l.fn === 'fn_existencia_ubicacion_lote').args.p_lote_id === 'lo0');
  chk('una fila por ubicación', d.querySelectorAll('.edit-fila').length === 3);
  chk('cada una trae lo que dice el sistema',
      [...d.querySelectorAll('.edit-fila input')].map(i => i.value).join(',') === '18,12,30');
  chk('y el nombre del lugar, que es lo que se elige',
      [...d.querySelectorAll('.edit-nom b')].map(e => e.textContent).join(',')
        === 'Piso de ventas,Refrigerador,Bodega');
  chk('avisa que da de baja mercadería',
      /da de.*baja o alta/is.test(d.querySelector('#hoja').textContent));
  chk('y manda a Mover de lugar si está en otro lado',
      /Mover de lugar/.test(d.querySelector('#hoja').textContent));
  chk('pide el motivo', !!d.querySelector('#ed-motivo'));

  // sin cambiar nada
  d.querySelector('#ed-si').click();
  await esperar();
  chk('sin cambios no manda nada',
      /No cambió ningún número/.test(d.querySelector('#ed-error').textContent));
  chk('y no llamó al servidor',
      !e.llamadas.some(l => l.fn === 'fn_solicitar_ajuste'));

  // el renglón se marca al cambiar
  const inp = d.querySelectorAll('.edit-fila input')[0];
  inp.value = '14';
  inp.dispatchEvent(new w.Event('input', { bubbles:true }));
  chk('marca la fila cambiada',
      inp.closest('.edit-fila').classList.contains('cambiada'));
  chk('y muestra la diferencia',
      inp.closest('.edit-fila').querySelector('.edit-dif').textContent === '−4');

  inp.value = '-9';
  inp.dispatchEvent(new w.Event('input', { bubbles:true }));
  chk('el campo no acepta negativos', inp.value === '9');

  inp.value = '14';
  inp.dispatchEvent(new w.Event('input', { bubbles:true }));
  d.querySelector('#ed-motivo').value = 'Conté el estante';
  d.querySelector('#ed-si').click();
  await esperar(160);
  const sol = e.llamadas.filter(l => l.fn === 'fn_solicitar_ajuste');
  chk('manda un solo ajuste, el que cambió', sol.length === 1);
  chk('con ubicación, cantidad, lote y motivo',
      sol[0].args.p_ubicacion_id === 'u1' && sol[0].args.p_cantidad === 14 &&
      sol[0].args.p_lote_id === 'lo0' && sol[0].args.p_motivo === 'Conté el estante');
  chk('dice que se envió a aprobación',
      /Enviado a aprobación/.test(d.querySelector('#hoja').textContent));
  chk('y que el inventario no cambió todavía',
      /no cambió.*todavía/is.test(d.querySelector('#hoja').textContent));
}
{
  // Dos ubicaciones cambiadas a la vez
  const estado = base();
  const { d, p, w, estado:e } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  d.querySelector('#btn-editar').click();
  await esperar(150);
  const campos = d.querySelectorAll('.edit-fila input');
  campos[0].value = '14'; campos[0].dispatchEvent(new w.Event('input', { bubbles:true }));
  campos[2].value = '33'; campos[2].dispatchEvent(new w.Event('input', { bubbles:true }));
  d.querySelector('#ed-si').click();
  await esperar(200);
  const sol = e.llamadas.filter(l => l.fn === 'fn_solicitar_ajuste');
  chk('manda uno por cada lugar cambiado', sol.length === 2);
  chk('y no manda el que quedó igual',
      !sol.some(x => x.args.p_ubicacion_id === 'u2'));
}
{
  // Un lugar que ya tiene un pendiente queda trabado
  const estado = base();
  const perfil = PERFIL(true);
  perfil.ajustes_pendientes = [{ ...PENDIENTE, lote_id:'lo0' }];
  estado.rpc.fn_consultar_producto = { data:perfil, error:null };
  const { d, p } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  d.querySelector('#btn-editar').click();
  await esperar(150);
  const primera = d.querySelectorAll('.edit-fila')[0];
  chk('la fila con ajuste pendiente no se puede escribir',
      primera.querySelector('input').disabled === true);
  chk('y lo dice', /ya tiene un ajuste esperando/.test(primera.textContent));
  chk('las otras sí',
      d.querySelectorAll('.edit-fila')[1].querySelector('input').disabled === false);
}
{
  const estado = base();
  estado.rpc.fn_solicitar_ajuste = { data:null,
    error:{ message:'Ya hay un ajuste pendiente de aprobacion para Leche en Piso de ventas' } };
  const { d, p, w } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  d.querySelector('#btn-editar').click();
  await esperar(150);
  const inp = d.querySelectorAll('.edit-fila input')[0];
  inp.value = '14'; inp.dispatchEvent(new w.Event('input', { bubbles:true }));
  d.querySelector('#ed-si').click();
  await esperar(160);
  chk('si el servidor lo rechaza se ve el motivo',
      /Ya hay un ajuste pendiente/.test(d.querySelector('#ed-error').textContent));
  chk('y la hoja sigue abierta', !!d.querySelector('.edit-fila'));
}

console.log('\n=== APROBAR Y RECHAZAR DESDE EL PRODUCTO ===');
{
  const estado = base();
  const perfil = PERFIL(true);
  perfil.ajustes_pendientes = [PENDIENTE];
  estado.rpc.fn_consultar_producto = { data:perfil, error:null };
  const { d, p, estado:e } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  chk('el pendiente sale arriba del todo',
      d.querySelector('#cuerpo').firstElementChild.classList.contains('pend'));
  chk('con quién lo pidió y por qué',
      /Ana/.test(d.querySelector('.pend').textContent) &&
      /Conté el estante/.test(d.querySelector('.pend').textContent));
  chk('el gerente ve los dos botones',
      !!d.querySelector('[data-aprobar]') && !!d.querySelector('[data-rechazar]'));

  d.querySelector('[data-aprobar]').click();
  await esperar(200);
  const r = e.llamadas.find(l => l.fn === 'fn_resolver_ajuste');
  chk('aprueba en el servidor', r && r.args.p_aprobar === true);
  chk('dice en cuánto queda el lugar', /queda en/.test(d.querySelector('#hoja').textContent));
  chk('y la existencia total del producto', /56/.test(d.querySelector('#hoja').textContent));
  chk('vuelve a leer la ficha',
      e.llamadas.filter(l => l.fn === 'fn_consultar_producto').length >= 2);
}
{
  const estado = base('auxiliar', 1);
  const perfil = PERFIL(false);
  perfil.ajustes_pendientes = [PENDIENTE];
  perfil.puede_aprobar = false;
  estado.rpc.fn_consultar_producto = { data:perfil, error:null };
  const { d, p } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  chk('la auxiliar ve el pendiente', !!d.querySelector('.pend'));
  chk('pero no puede aprobarlo', !d.querySelector('[data-aprobar]'));
  chk('ni rechazarlo', !d.querySelector('[data-rechazar]'));
  chk('y se le explica', /El gerente lo aprueba/.test(d.querySelector('.pend').textContent));
}
{
  const estado = base();
  const perfil = PERFIL(true);
  perfil.ajustes_pendientes = [PENDIENTE];
  estado.rpc.fn_consultar_producto = { data:perfil, error:null };
  const { d, p, estado:e } = await montar(estado);
  await p.abrir('p1');
  await esperar(120);
  d.querySelector('[data-rechazar]').click();
  await esperar();
  chk('rechazar abre su hoja', !!d.querySelector('#rz-motivo'));
  d.querySelector('#rz-si').click();
  await esperar();
  chk('y exige el motivo',
      /Diga por qué se rechaza/.test(d.querySelector('#rz-error').textContent));
  chk('sin motivo no llama al servidor',
      !e.llamadas.some(l => l.fn === 'fn_resolver_ajuste'));
  d.querySelector('#rz-motivo').value = 'Hay que volver a contarlo';
  d.querySelector('#rz-si').click();
  await esperar(200);
  const r = e.llamadas.find(l => l.fn === 'fn_resolver_ajuste');
  chk('con motivo sí lo manda',
      r && r.args.p_aprobar === false && r.args.p_nota === 'Hay que volver a contarlo');
}

console.log(`\n${ok} bien · ${mal} mal`);
process.exit(mal ? 1 : 0);
