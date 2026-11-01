/* Prueba funcional de la auditoría de bodega.

   Lo que se vigila aquí:
     · que escanear el mismo producto SUME y lo diga ("llevaba 24")
     · que la caja completa entre propuesta pero se pueda cambiar
     · que al completar se vea qué va a quedar en cero, antes de confirmar
     · que la auxiliar no complete, y que la predeterminada no se audite
*/
import fs from 'node:fs';
import { JSDOM } from 'jsdom';

const BASE = '/home/claude/somtechn/pulpeando_interno/';
let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };

const CTX = (rol = 'supervisor', nivel = 2) => ({
  usuario:{ id:'u1', nombre:'Somar', rol, nivel, tiene_pin:true },
  organizacion:{ id:'o1', nombre:'Pulpería Pulpeando', moneda:'HNL', factura_fiscal:false },
  sucursales:[{ id:'s1', nombre:'Central', codigo:'S01' }],
  cajas:[], impuesto_default:0, sin_sucursal:false });

const hace = h => new Date(Date.now() - h*3600000).toISOString();

const UBIS = [
  { ubicacion_id:'u1', nombre:'Piso de ventas', es_predeterminada:true, orden:10,
    activa:true, tipo:'piso', codigo:'S01-P01', auditada_en:null,
    productos:12, unidades:0 },
  { ubicacion_id:'u2', nombre:'Exhibidor de la entrada', es_predeterminada:false,
    orden:20, activa:true, tipo:'piso', codigo:'S01-P02',
    auditada_en:hace(3), productos:2, unidades:9 },
  { ubicacion_id:'u3', nombre:'Bodega', es_predeterminada:false, orden:200,
    activa:true, tipo:'bodega', codigo:'S01-B01', auditada_en:hace(2),
    productos:8, unidades:140 },
  { ubicacion_id:'u4', nombre:'Bodega de arriba', es_predeterminada:false,
    orden:210, activa:true, tipo:'bodega', codigo:'S01-B02',
    auditada_en:hace(50), productos:3, unidades:22 }
];

const RESUMEN = (extra = {}) => ({
  auditoria_id:'a1', numero:'AU-S01-000007', estado:'abierta',
  ubicacion:'Bodega', codigo:'S01-B01', tipo:'bodega', ubicacion_id:'u3',
  sucursal:'Central', notas:null, motivo_cancelacion:null,
  abierta_por:'Ana', abierta_en:hace(1), cerrada_por:null, cerrada_en:null,
  escaneados:1, unidades:24, sin_escanear:2, puede_completar:true, ...extra });

const LINEAS = [
  { escaneado:true, producto_id:'p1', producto:'Arroz de primera 5 lb', sku:'ARR5LB',
    unidad:'UND', empaque:12, lote_id:null, lote:null, vence:null,
    contado:24, sistema:30, escaneos:2, quien:'Ana', actualizado:hace(0.2) },
  { escaneado:false, producto_id:'p2', producto:'Azúcar refinada 5 lb', sku:'AZU5LB',
    unidad:'UND', empaque:10, lote_id:null, lote:null, vence:null,
    contado:null, sistema:18, escaneos:0, quien:null, actualizado:null },
  { escaneado:false, producto_id:'p3', producto:'Leche entera 1 L', sku:'LEC1L',
    unidad:'UND', empaque:null, lote_id:'lo1', lote:'L-ENE', vence:null,
    contado:null, sistema:6, escaneos:0, quien:null, actualizado:null }
];

const hoyMas = d => { const x = new Date(); x.setDate(x.getDate() + d);
  return x.toISOString().slice(0,10); };
const BODEGA = (id = 'u3', extra = {}) => {
  const u = UBIS.find(x => x.ubicacion_id === id) || { ubicacion_id:id, nombre:'Cuarto frío',
    codigo:'S01-B03', tipo:'bodega', auditada_en:null };
  return { ubicacion_id:u.ubicacion_id, nombre:u.nombre, codigo:u.codigo, tipo:u.tipo,
    activa:true, auditada_en:u.auditada_en, abierta:null,
    productos: id === 'u9' ? [] : [
      { producto_id:'p1', nombre:'Arroz de primera 5 lb', sku:'ARR5LB', unidad:'UND',
        cantidad:24, empaque:12, vence:null },
      { producto_id:'p3', nombre:'Leche entera 1 L', sku:'LEC1L', unidad:'UND',
        cantidad:6, empaque:null, vence:hoyMas(10) },
      { producto_id:'p4', nombre:'Yogur fresa', sku:'YOG', unidad:'UND',
        cantidad:4, empaque:null, vence:hoyMas(-2) }
    ], ...extra };
};

async function montar(estado){
  const html = fs.readFileSync(BASE + 'auditoria.html', 'utf8');
  const cuerpo = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  const css = fs.readFileSync(BASE + 'ui.css', 'utf8');

  const dom = new JSDOM(
    html.replace(/<script type="module">[\s\S]*?<\/script>/, '')
        .replace('<link rel="stylesheet" href="ui.css">', '<style>' + css + '</style>')
        .replace(/<script src="config\.js"><\/script>/, ''),
    { runScripts:'outside-only', url:'https://x.test/auditoria.html', pretendToBeVisual:true });

  const w = dom.window;
  w.SUPABASE_CONFIG = { url:'https://x.supabase.co', key:'k' };
  Object.defineProperty(w.navigator, 'serviceWorker',
    { value:{ register: async () => ({}) }, configurable:true });
  w.matchMedia = () => ({ matches:false, addEventListener(){}, removeEventListener(){} });
  w.print = () => { estado.imprimio = true; };

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
  w.escanear = async () => estado.codigo ?? null;
  w.hayCamara = async () => estado.camara !== false;

  const prep = cuerpo
    .replace(/^import \{ createClient \} from 'https:\/\/esm\.sh\/@supabase\/supabase-js@2';$/m, '')
    .replace(/^import \{ montarMenu, escapar \} from '\.\/menu\.js';$/m, '')
    .replace(/^import \{ escanear, hayCamara \} from '\.\/escaner\.js';$/m, '')
    .replace(/createClient\(SUPABASE_URL, SUPABASE_KEY, \{[\s\S]*?\}\)/, '__sb');

  w.__a = {};
  await w.eval(`(async () => { ${prep}
    ; window.__a.S = S; window.__a.escanearUbicacion = escanearUbicacion;
    ; window.__a.escanearProducto = escanearProducto;
    ; window.__a.abrirAuditoria = abrirAuditoria;
    ; window.__a.cargarLugares = cargarLugares;
    ; window.__a.abrirBodega = abrirBodega;
  })()`);
  await new Promise(r => setTimeout(r, 200));
  return { w, d:w.document, a:w.__a, estado };
}

const esperar = (ms = 100) => new Promise(r => setTimeout(r, ms));

const base = (rol = 'supervisor', nivel = 2, extra = {}) => ({
  camara:true,
  rpc:{
    fn_pos_contexto:{ data:CTX(rol, nivel), error:null },
    fn_ubicaciones_detalle:{ data:UBIS, error:null },
    fn_auditorias:{ data:[], error:null },
    fn_abrir_auditoria:{ data:{ auditoria_id:'a1', numero:'AU-S01-000007',
      ubicacion:'Bodega', codigo:'S01-B01', tipo:'bodega', ya_estaba:false }, error:null },
    fn_auditoria_resumen:{ data:RESUMEN({ puede_completar:nivel >= 2 }), error:null },
    fn_auditoria_lineas:{ data:LINEAS, error:null },
    fn_ubicacion_por_codigo:{ data:{ ubicacion_id:'u3', nombre:'Bodega',
      codigo:'S01-B01', tipo:'bodega', predeterminada:false,
      sucursal_id:'s1', sucursal:'Central' }, error:null },
    fn_buscar_para_consulta:{ data:[{ producto_id:'p1',
      nombre:'Arroz de primera 5 lb', sku:'ARR5LB', codigo:'7501001',
      categoria:'Abarrotes', unidad:'UND', precio:98, existencia:40,
      exacto:true }], error:null },
    fn_auditar_producto: a => ({ data:{ producto_id:'p1',
      producto:'Arroz de primera 5 lb', sku:'ARR5LB', unidad:'UND', empaque:12,
      llevaba:24, agregado:a.p_cantidad, total:24 + a.p_cantidad, escaneos:3 },
      error:null }),
    fn_completar_auditoria: a => ({ data:{ numero:'AU-S01-000007',
      ubicacion:'Bodega', codigo:'S01-B01', actualizados:1,
      vaciados:a.p_vaciar_no_escaneados ? 2 : 0, recortados:0, unidades:24 },
      error:null }),
    fn_cancelar_auditoria:{ data:{ numero:'AU-S01-000007', estado:'cancelada' }, error:null },
    fn_bodega_productos: a => ({ data:BODEGA(a.p_ubicacion_id), error:null }),
    fn_crear_bodega: a => ({ data:{ ubicacion_id:'u9', nombre:a.p_nombre, codigo:'S01-B03' }, error:null })
  }, ...extra });

/* ===================================================================== */
console.log('\n=== LAS BODEGAS ===');
{
  const estado = base();
  const { d, estado:e } = await montar(estado);
  chk('entra', !d.querySelector('#app').classList.contains('oculto'));
  chk('el módulo se llama Bodega', d.querySelector('#h-titulo').textContent === 'Bodega');
  chk('pide las ubicaciones con su estado',
      e.llamadas.some(l => l.fn === 'fn_ubicaciones_detalle'));
  chk('solo muestra las bodegas', d.querySelectorAll('.ubi').length === 2);
  chk('ya no lista el piso de ventas',
      !/S01-P0/.test(d.querySelector('#cuerpo').textContent));
  chk('dice cuántas hay', /BODEGAS · 2/.test(d.querySelector('#cuerpo').textContent.toUpperCase()));
  chk('cada una con su código', /S01-B01/.test(d.querySelector('#cuerpo').textContent));
  chk('la auditada hace 2 h en verde',
      [...d.querySelectorAll('.ubi')].find(x => /S01-B01/.test(x.textContent))
        .querySelector('.ubi-sem').classList.contains('ok'));
  chk('la de hace 50 h en ámbar',
      [...d.querySelectorAll('.ubi')].find(x => /S01-B02/.test(x.textContent))
        .querySelector('.ubi-sem').classList.contains('viejo'));
  chk('el supervisor puede crear bodegas', !!d.querySelector('#btn-nueva'));
  chk('y ofrece escanear el QR', !!d.querySelector('#btn-qr'));
  chk('y las etiquetas', !!d.querySelector('#btn-etq'));
  chk('sigue el botón de reponer piso', !!d.querySelector('#btn-reponer'));
}
{
  const estado = base('auxiliar', 1);
  const { d } = await montar(estado);
  chk('la auxiliar no crea bodegas', !d.querySelector('#btn-nueva'));
  chk('pero sí las ve', d.querySelectorAll('.ubi').length === 2);
}
{
  const estado = base();
  estado.rpc.fn_ubicaciones_detalle = { data:UBIS.filter(u => u.tipo !== 'bodega'), error:null };
  const { d } = await montar(estado);
  chk('sin bodegas lo dice e invita a crear',
      /Todavía no hay bodegas[\s\S]*Nueva bodega/.test(d.querySelector('#cuerpo').textContent));
  chk('y no ofrece etiquetas vacías', !d.querySelector('#btn-etq'));
}
{
  const estado = base();
  estado.camara = false;
  const { d } = await montar(estado);
  chk('sin cámara no ofrece escanear pero sí la lista', !d.querySelector('#btn-qr'));
  chk('y las bodegas se pueden tocar', d.querySelectorAll('.ubi').length === 2);
}

console.log('\n=== ENTRAR A UNA BODEGA ===');
{
  const estado = base();
  const { d, estado:e } = await montar(estado);
  [...d.querySelectorAll('.ubi')].find(x => /S01-B01/.test(x.textContent)).click();
  await esperar(200);
  chk('pide lo que tiene esa bodega',
      e.llamadas.find(l => l.fn === 'fn_bodega_productos').args.p_ubicacion_id === 'u3');
  chk('no abre la auditoría solo por entrar',
      !e.llamadas.some(l => l.fn === 'fn_abrir_auditoria'));
  chk('el título es la bodega', d.querySelector('#h-titulo').textContent === 'Bodega');
  chk('lista sus productos', d.querySelectorAll('.bod-prod').length === 3);
  chk('con cantidad', /24/.test(d.querySelector('.bod-prod .bod-cant').textContent));
  chk('dice el total', /3 productos · 34 unidades/.test(d.querySelector('.bod-cab').textContent));
  chk('el empaque', /empaque de 12/.test(d.querySelector('#cuerpo').textContent));
  chk('lo que vence pronto en ámbar', !!d.querySelector('.venc.ojo'));
  chk('lo vencido en rojo', !!d.querySelector('.venc.malo'));
  chk('al día: no avisa', !d.querySelector('#cuerpo .aviso.ojo'));
  const btn = d.querySelector('#bd-auditar');
  chk('ofrece auditar (actualizar)', /Auditar \(actualizar\)/.test(btn.textContent));
  btn.click();
  await esperar(220);
  chk('al tocar abre la auditoría de esa bodega',
      e.llamadas.find(l => l.fn === 'fn_abrir_auditoria').args.p_ubicacion_id === 'u3');
  chk('y pasa a escanear', !!d.querySelector('#btn-prod'));
  d.querySelector('#btn-volver').click();
  await esperar(220);
  chk('al salir de la auditoría vuelve a la bodega', !!d.querySelector('#bd-auditar'));
  d.querySelector('#bd-volver').click();
  await esperar(220);
  chk('y de ahí a la lista', d.querySelectorAll('.ubi').length === 2);
}
{
  const estado = base();
  const { d, a } = await montar(estado);
  await a.abrirBodega('u4');
  await esperar(150);
  chk('la bodega vieja avisa que no está al día',
      /no está al día/.test(d.querySelector('#cuerpo .aviso.ojo').textContent));
}
{
  const estado = base();
  estado.rpc.fn_bodega_productos = { data:BODEGA('u3', { abierta:{ auditoria_id:'a1',
    numero:'AU-S01-000007' } }), error:null };
  const { d } = await montar(estado);
  [...d.querySelectorAll('.ubi')][0].click();
  await esperar(200);
  chk('con auditoría abierta lo dice', /AU-S01-000007/.test(d.querySelector('.bod-cab').textContent));
  chk('y ofrece continuarla', /Continuar auditoría/.test(d.querySelector('#bd-auditar').textContent));
}

console.log('\n=== NUEVA BODEGA ===');
{
  const estado = base();
  const { d, estado:e } = await montar(estado);
  d.querySelector('#btn-nueva').click();
  await esperar(40);
  chk('abre la hoja', /Nueva bodega/.test(d.querySelector('#hoja').textContent));
  d.querySelector('#nb-si').click();
  await esperar(80);
  chk('sin nombre no la crea', !e.llamadas.some(l => l.fn === 'fn_crear_bodega'));
  chk('y lo pide', !d.querySelector('#nb-error').classList.contains('oculto'));
  d.querySelector('#nb-nombre').value = '  Cuarto frío ';
  d.querySelector('#nb-si').click();
  await esperar(250);
  const c = e.llamadas.find(l => l.fn === 'fn_crear_bodega');
  chk('la crea con el nombre limpio', c && c.args.p_nombre === 'Cuarto frío');
  chk('en la sucursal activa', c && c.args.p_sucursal_id === 's1');
  chk('y entra a la bodega nueva', d.querySelector('#h-titulo').textContent === 'Cuarto frío');
  chk('vacía, lo dice', /Está vacía/.test(d.querySelector('#cuerpo').textContent));
}
{
  const estado = base();
  estado.rpc.fn_crear_bodega = { data:null, error:{ message:'Ya hay una bodega con ese nombre' } };
  const { d } = await montar(estado);
  d.querySelector('#btn-nueva').click();
  await esperar(40);
  d.querySelector('#nb-nombre').value = 'Bodega';
  d.querySelector('#nb-si').click();
  await esperar(150);
  chk('un nombre repetido se explica en la hoja',
      /Ya hay una bodega/.test(d.querySelector('#nb-error').textContent));
}

console.log('\n=== ESCANEAR EL QR ===');
{
  const estado = base();
  estado.codigo = 'S01-B01';
  const { d, a, estado:e } = await montar(estado);
  await a.escanearUbicacion();
  await esperar(200);
  chk('resuelve el código',
      e.llamadas.find(l => l.fn === 'fn_ubicacion_por_codigo').args.p_codigo === 'S01-B01');
  chk('y abre esa bodega', e.llamadas.some(l => l.fn === 'fn_bodega_productos'));
  chk('lista para auditar', !!d.querySelector('#bd-auditar'));
}
{
  const estado = base();
  estado.codigo = 'S01-P01';
  estado.rpc.fn_ubicacion_por_codigo = { data:{ ubicacion_id:'u1',
    nombre:'Piso de ventas', codigo:'S01-P01', tipo:'piso', predeterminada:true,
    sucursal_id:'s1', sucursal:'Central' }, error:null };
  const { d, a, estado:e } = await montar(estado);
  await a.escanearUbicacion();
  await esperar(160);
  chk('el QR de la predeterminada no abre nada',
      !e.llamadas.some(l => l.fn === 'fn_abrir_auditoria' || l.fn === 'fn_bodega_productos'));
  chk('y explica por qué',
      /su cantidad es el resto/.test(d.querySelector('#hoja').textContent));
}
{
  const estado = base();
  estado.codigo = 'S01-P02';
  estado.rpc.fn_ubicacion_por_codigo = { data:{ ubicacion_id:'u2',
    nombre:'Exhibidor de la entrada', codigo:'S01-P02', tipo:'piso', predeterminada:false,
    sucursal_id:'s1', sucursal:'Central' }, error:null };
  const { d, a, estado:e } = await montar(estado);
  await a.escanearUbicacion();
  await esperar(160);
  chk('un QR de piso no se audita aquí',
      !e.llamadas.some(l => l.fn === 'fn_bodega_productos'));
  chk('y manda a Consultar', /desde Consultar/.test(d.querySelector('#hoja').textContent));
}
{
  const estado = base();
  estado.codigo = 'XX-99';
  estado.rpc.fn_ubicacion_por_codigo = { data:null,
    error:{ message:'No hay ninguna ubicacion con el codigo XX-99' } };
  const { d, a } = await montar(estado);
  await a.escanearUbicacion();
  await esperar(160);
  chk('un código desconocido se dice con el código',
      /XX-99/.test(d.querySelector('#hoja').textContent));
}

console.log('\n=== AUDITANDO ===');
{
  const estado = base();
  const { d, a, estado:e } = await montar(estado);
  await a.abrirAuditoria('u3');
  await esperar(200);

  chk('el botón grande es escanear producto', !!d.querySelector('#btn-prod'));
  chk('muestra el número y el avance',
      /AU-S01-000007/.test(d.querySelector('#cuerpo').textContent) &&
      /24 unidades/.test(d.querySelector('#cuerpo').textContent));
  chk('dice cuántos faltan', /faltan 2 por escanear/.test(d.querySelector('#cuerpo').textContent));
  chk('separa lo escaneado de lo que falta',
      /ESCANEADO[\s\S]*FALTA ESCANEAR/.test(d.querySelector('#cuerpo').textContent.toUpperCase()));
  chk('la línea escaneada trae lo contado y cuántos escaneos',
      /24/.test(d.querySelector('.ln').textContent) &&
      /2 escaneos/.test(d.querySelector('.ln').textContent));
  chk('la pendiente dice lo que el sistema creía',
      /18/.test(d.querySelector('.ln.pendiente').textContent) &&
      /decía/.test(d.querySelector('.ln.pendiente').textContent));
  chk('hay botón de completar', !!d.querySelector('#btn-completar'));
}

console.log('\n=== ESCANEAR SUMA ===');
{
  const estado = base();
  estado.codigo = '7501001';
  const { d, a, w, estado:e } = await montar(estado);
  await a.abrirAuditoria('u3');
  await esperar(200);
  await a.escanearProducto();
  await esperar(180);

  chk('abre la hoja de cantidad', !!d.querySelector('#ct-cant'));
  chk('con el producto en el título',
      d.querySelector('#hoja h2').textContent.trim() === 'Arroz de primera 5 lb');
  chk('la caja completa entra propuesta', d.querySelector('#ct-cant').value === '12');
  chk('y el botón de caja completa está', !!d.querySelector('#ct-caja'));
  chk('avisa cuánto llevaba en este lugar',
      /ya lleva/.test(d.querySelector('.llevaba').textContent) &&
      /24/.test(d.querySelector('.llevaba').textContent));
  chk('y que se suma', /se.*suma/is.test(d.querySelector('.llevaba').textContent));

  // la cantidad propuesta se puede cambiar
  const campo = d.querySelector('#ct-cant');
  campo.value = '-5';
  campo.dispatchEvent(new w.Event('input', { bubbles:true }));
  chk('el campo no acepta negativos', campo.value === '5');

  d.querySelector('#ct-caja').click();
  chk('el botón de caja completa vuelve a poner el empaque', campo.value === '12');

  campo.value = '7';
  d.querySelector('#ct-si').click();
  await esperar(220);
  const r = e.llamadas.find(l => l.fn === 'fn_auditar_producto');
  chk('manda la cantidad escrita, no la propuesta', r.args.p_cantidad === 7);
  chk('sin reemplazar: suma', !r.args.p_reemplazar);
  chk('muestra la cuenta: llevaba + agregado = total',
      /24[\s\S]*7[\s\S]*31/.test(d.querySelector('#hoja').textContent));
  chk('y ofrece escanear otro de una vez', !!d.querySelector('#su-mas'));
}
{
  // Un producto nuevo en ese lugar: no hay "llevaba"
  const estado = base();
  estado.codigo = '7501001';
  estado.rpc.fn_auditoria_lineas = { data:LINEAS.filter(l => !l.escaneado), error:null };
  const { d, a } = await montar(estado);
  await a.abrirAuditoria('u3');
  await esperar(200);
  await a.escanearProducto();
  await esperar(180);
  chk('sin nada previo no habla de lo que llevaba', !d.querySelector('.llevaba'));
  chk('y el campo arranca vacío porque no se sabe el empaque',
      d.querySelector('#ct-cant').value === '');
}
{
  const estado = base();
  estado.codigo = '9999';
  estado.rpc.fn_buscar_para_consulta = { data:[], error:null };
  const { d, a } = await montar(estado);
  await a.abrirAuditoria('u3');
  await esperar(200);
  await a.escanearProducto();
  await esperar(180);
  chk('un código que no está en el catálogo lo dice',
      /no está en el catálogo/.test(d.querySelector('#hoja').textContent));
  chk('y dice qué hacer', /Catálogos/.test(d.querySelector('#hoja').textContent));
}
{
  const estado = base();
  estado.codigo = '750';
  estado.rpc.fn_buscar_para_consulta = { data:[
    { producto_id:'p1', nombre:'Arroz 5 lb', sku:'A1', codigo:null,
      categoria:'Abarrotes', unidad:'UND', precio:98, existencia:40, exacto:false },
    { producto_id:'p2', nombre:'Arroz 2 lb', sku:'A2', codigo:null,
      categoria:'Abarrotes', unidad:'UND', precio:50, existencia:10, exacto:false }
  ], error:null };
  const { d, a } = await montar(estado);
  await a.abrirAuditoria('u3');
  await esperar(200);
  await a.escanearProducto();
  await esperar(180);
  chk('con varios candidatos deja elegir', d.querySelectorAll('[data-prod]').length === 2);
  d.querySelectorAll('[data-prod]')[1].click();
  await esperar();
  chk('y al elegir abre la cantidad del que se eligió',
      d.querySelector('#hoja h2').textContent.trim() === 'Arroz 2 lb');
}

console.log('\n=== CORREGIR UNA LÍNEA ===');
{
  const estado = base();
  const { d, a, estado:e } = await montar(estado);
  await a.abrirAuditoria('u3');
  await esperar(200);
  d.querySelector('[data-corregir]').click();
  await esperar();
  chk('abre con lo contado', d.querySelector('#cr-cant').value === '24');
  chk('y dice que reemplaza, no suma', /reemplaza/.test(d.querySelector('#hoja').textContent));
  chk('recuerda lo que el sistema decía', /30/.test(d.querySelector('.llevaba').textContent));
  d.querySelector('#cr-cant').value = '20';
  d.querySelector('#cr-si').click();
  await esperar(200);
  const r = e.llamadas.filter(l => l.fn === 'fn_auditar_producto').pop();
  chk('manda reemplazar', r.args.p_reemplazar === true && r.args.p_cantidad === 20);
}

console.log('\n=== COMPLETAR ===');
{
  const estado = base();
  const { d, a, estado:e } = await montar(estado);
  await a.abrirAuditoria('u3');
  await esperar(200);
  d.querySelector('#btn-completar').click();
  await esperar();

  const liso = () => d.querySelector('#hoja').textContent.replace(/\s+/g, ' ');
  chk('dice qué se escaneó', /1 producto, 24 unidades/.test(liso()));
  chk('muestra lo que NO se escaneó antes de confirmar',
      d.querySelectorAll('#hoja .ln.pendiente').length === 2);
  chk('con el nombre de cada uno',
      /Azúcar refinada 5 lb/.test(d.querySelector('#hoja').textContent));
  chk('ofrece las dos salidas', d.querySelectorAll('#cp-ops .opcion').length === 2);
  chk('por omisión vacía lo no escaneado',
      d.querySelectorAll('#cp-ops .opcion')[0].classList.contains('activa'));
  chk('y explica a dónde van esas unidades',
      /pasan al piso de ventas/.test(d.querySelector('#cp-ops').textContent));
  chk('recuerda que no cambia el total',
      /no cambia el total/.test(d.querySelector('#hoja').textContent));

  d.querySelectorAll('#cp-ops .opcion')[1].click();
  await esperar(40);
  chk('se puede cambiar a solo lo escaneado',
      d.querySelectorAll('#cp-ops .opcion')[1].classList.contains('activa'));
  d.querySelectorAll('#cp-ops .opcion')[0].click();
  await esperar(40);

  d.querySelector('#cp-si').click();
  await esperar(220);
  const r = e.llamadas.find(l => l.fn === 'fn_completar_auditoria');
  chk('manda vaciar lo no escaneado', r.args.p_vaciar_no_escaneados === true);
  chk('dice cuántos se actualizaron', /1 producto actualizado/.test(liso()));
  chk('y cuántos quedaron en cero', /2 quedaron en cero/.test(liso()));
}
{
  const estado = base();
  estado.rpc.fn_auditoria_lineas = { data:[LINEAS[0]], error:null };
  estado.rpc.fn_auditoria_resumen = { data:RESUMEN({ sin_escanear:0 }), error:null };
  const { d, a } = await montar(estado);
  await a.abrirAuditoria('u3');
  await esperar(200);
  d.querySelector('#btn-completar').click();
  await esperar();
  chk('si se escaneó todo no pregunta nada', !d.querySelector('#cp-ops'));
  chk('y lo dice', /Se escaneó todo/.test(d.querySelector('#hoja').textContent));
}
{
  const estado = base('auxiliar', 1);
  estado.rpc.fn_auditoria_resumen = { data:RESUMEN({ puede_completar:false }), error:null };
  const { d, a } = await montar(estado);
  await a.abrirAuditoria('u3');
  await esperar(200);
  chk('la auxiliar no tiene botón de completar', !d.querySelector('#btn-completar'));
  chk('y se le dice quién la completa',
      /La completa un supervisor/.test(d.querySelector('#pie').textContent));
  chk('pero sí puede escanear', !!d.querySelector('#btn-prod'));
}
{
  const estado = base();
  estado.rpc.fn_completar_auditoria = { data:{ numero:'AU-S01-000007',
    ubicacion:'Bodega', codigo:'S01-B01', actualizados:3, vaciados:0,
    recortados:1, unidades:90 }, error:null };
  const { d, a } = await montar(estado);
  await a.abrirAuditoria('u3');
  await esperar(200);
  d.querySelector('#btn-completar').click();
  await esperar();
  d.querySelector('#cp-si').click();
  await esperar(220);
  const liso2 = d.querySelector('#hoja').textContent.replace(/\s+/g, ' ');
  chk('si se escaneó más de lo que hay, lo explica',
      /se escaneó más de lo que hay en toda la sucursal/.test(liso2));
  chk('y dice que el faltante está en otra parte', /faltante en otra parte/.test(liso2));
}

console.log('\n=== EL REPARTIDOR NO ENTRA ===');
{
  const estado = base('repartidor', 0);
  const { d } = await montar(estado);
  chk('lo bloquea', !d.querySelector('#p-bloqueado').classList.contains('oculto'));
  chk('y no monta la pantalla', d.querySelector('#app').classList.contains('oculto'));
}

console.log('\n=== ETIQUETAS QR ===');
{
  const estado = base();
  const { d } = await montar(estado);
  d.querySelector('#btn-etq').click();
  await esperar(250);
  chk('una etiqueta por bodega', d.querySelectorAll('.etq').length === 2);
  chk('cada una con su código', /S01-B01/.test(d.querySelector('.etiquetas').textContent));
  chk('y el nombre del lugar',
      /Bodega de arriba/.test(d.querySelector('.etiquetas').textContent));
  chk('explica para qué sirve pegarlas',
      /pegue cada etiqueta en/.test(d.querySelector('#cuerpo').textContent));
  chk('dice que también se puede digitar',
      /digitar/.test(d.querySelector('#cuerpo').textContent));
  chk('hay botón de imprimir', !!d.querySelector('#et-imp'));
  d.querySelector('#et-volver').click();
  await esperar(150);
  chk('y se puede volver', d.querySelectorAll('.ubi').length === 2);
}

console.log('\n=== REPONER PISO ===');
{
  let filas = [
    { producto_id:'p1', sku:'51089', nombre:'Arroz de primera 5 lb', unidad:'UND', capacidad:20, piso:4, bodega:40,
      falta:16, lleno:20, desde_id:'u3', desde:'Bodega', sugerido:16 },
    { producto_id:'p2', sku:'51090', nombre:'Aceite 750 ml', unidad:'UND', capacidad:12, piso:2, bodega:0,
      falta:10, lleno:17, desde_id:null, desde:null, sugerido:0 }];
  const e = base('auxiliar', 1);
  e.rpc.fn_reponer_piso = () => ({ data:{ piso_id:'u1', piso:'Piso de ventas', sin_capacidad:3, filas }, error:null });
  e.rpc.fn_mover_entre_ubicaciones = () => { filas = filas.slice(1); return { data:{ ok:true }, error:null }; };
  const { d, w } = await montar(e);
  await esperar();
  const btn = d.querySelector('#btn-reponer');
  chk('el botón dice cuántos hay que bajar y se destaca', /1 producto para bajar/.test(btn.textContent) && btn.classList.contains('destacada'));
  btn.click(); await esperar(150);
  const t = d.querySelector('#cuerpo').textContent.replace(/\s+/g, ' ');
  chk('separa lo que se baja de lo que hay que comprar', /Bajar de la bodega · 1/.test(t) && /Bajos y sin bodega · 1/.test(t) && /Hay que comprarlo/.test(t));
  chk('enseña piso y capacidad', /en el piso 4 de 20/.test(t));
  chk('avisa los que no tienen capacidad', /3 productos no tienen capacidad/.test(t));
  const inp = d.querySelector('.rp input');
  chk('sugiere la cantidad', inp.value === '16');
  inp.value = '50';
  d.querySelector('[data-pasar="p1"]').click(); await esperar(80);
  chk('no deja pasar más de lo que hay en bodega', !e.llamadas.some(l => l.fn === 'fn_mover_entre_ubicaciones') && /hay 40/.test(d.body.textContent));
  d.querySelector('#hoja .btn, #hoja button')?.click(); await esperar(40);
  d.querySelector('.rp input').value = '16';
  d.querySelector('[data-pasar="p1"]').click(); await esperar(200);
  const m = e.llamadas.find(l => l.fn === 'fn_mover_entre_ubicaciones');
  chk('pasa de la bodega al piso', m && m.args.p_producto_id === 'p1' && m.args.p_hacia === 'u1' && m.args.p_desde === 'u3' && m.args.p_cantidad === 16);
  chk('y vuelve a armar la lista', !d.querySelector('[data-pasar="p1"]'));
  d.querySelector('#rp-volver').click(); await esperar(150);
  chk('vuelve a las ubicaciones', !!d.querySelector('#btn-reponer'));
}

console.log(`\n${ok} bien · ${mal} mal`);
process.exit(mal ? 1 : 0);
