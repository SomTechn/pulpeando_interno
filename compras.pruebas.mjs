/* Prueba funcional de Compras: dar de alta un producto sin salir de la
   entrada de mercaderia.

   Lo que se vigila aqui:
     · que buscar algo que no existe ofrezca crearlo, con lo escrito ya puesto
     · que un codigo de barras (solo digitos) caiga en su campo y no en el nombre
     · que la pistola USB (Enter sin resultados) abra el formulario
     · que el escaner recuerde el codigo desconocido y lo ofrezca al cerrar
     · que al guardar el producto quede agregado a la entrada
     · que el supervisor no vea el campo de precio y se le explique por que
     · que los errores del servidor (codigo repetido) se muestren en la hoja
*/
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';

const BASE = fileURLToPath(new URL('./', import.meta.url));
let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };

const CTX = (rol = 'gerente', nivel = 3) => ({
  usuario:{ id:'u1', nombre:'Somar', rol, nivel, tiene_pin:true },
  organizacion:{ id:'o1', nombre:'Pulpería Pulpeando', moneda:'HNL', factura_fiscal:false },
  sucursales:[{ id:'s1', nombre:'Central', codigo:'S01' }],
  cajas:[], impuesto_default:0.15, sin_sucursal:false });

const CATALOGO = () => [
  { producto_id:'p1', sku:'ACE500', nombre:'Aceite vegetal 500ml', unidad_base:'UND',
    controla_lote:false, controla_vencimiento:false, tasa_impuesto:0.15, precio_venta:20,
    ultimo_costo:11.11, existencia:129, codigos:['7401234567890'], presentaciones:[] } ];

/* Un query builder de mentira: cualquier cadena de .select().eq().order()…
   termina devolviendo lo que haya en estado.tablas[tabla]. */
function desde(estado, tabla){
  const q = {
    _t:tabla,
    select(){ return q; }, eq(){ return q; }, order(){ return q; }, is(){ return q; },
    limit(){ return q; }, in(){ return q; }, single(){ return q; },
    insert(){ return q; }, update(){ return q; }, delete(){ return q; },
    then(res, rej){
      const h = estado.tablas[tabla];
      const v = typeof h === 'function' ? h() : (h ?? []);
      return Promise.resolve({ data:v, error:null }).then(res, rej);
    }
  };
  return q;
}

async function montar(estado){
  const html = fs.readFileSync(BASE + 'compras.html', 'utf8');
  const cuerpo = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  const css = fs.readFileSync(BASE + 'ui.css', 'utf8');

  const dom = new JSDOM(
    html.replace(/<script type="module">[\s\S]*?<\/script>/, '')
        .replace('<link rel="stylesheet" href="ui.css">', '<style>' + css + '</style>')
        .replace(/<script src="config\.js"><\/script>/, ''),
    { runScripts:'outside-only', url:'https://x.test/compras.html', pretendToBeVisual:true });

  const w = dom.window;
  w.SUPABASE_CONFIG = { url:'https://x.supabase.co', key:'k' };
  Object.defineProperty(w.navigator, 'serviceWorker',
    { value:{ register: async () => ({}) }, configurable:true });
  w.matchMedia = () => ({ matches:false, addEventListener(){}, removeEventListener(){} });

  // escaner.js: el escaner de prueba "lee" lo que diga estado.lecturas
  w.hayCamara = () => true;
  w.escanear = async (op = {}) => {
    if (!op.continuo) return estado.lecturaUnica || null;
    estado.respuestas = [];
    for (const c of (estado.lecturas || [])) estado.respuestas.push(await op.alLeer(c));
    return null;
  };

  globalThis.window = w; globalThis.document = w.document;
  globalThis.localStorage = w.localStorage; globalThis.matchMedia = w.matchMedia;

  estado.llamadas = [];
  w.__sb = {
    auth:{ getSession: async () => ({ data:{ session:{ user:{ id:'u1' } } } }),
           signInWithPassword: async () => ({ error:null }),
           signOut: async () => {}, onAuthStateChange(){} },
    from: t => { estado.llamadas.push({ fn:'from:' + t }); return desde(estado, t); },
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
    .replace(/^import \{ escanear, hayCamara \} from '\.\/escaner\.js';$/m, '')
    .replace(/createClient\(SUPABASE_URL, SUPABASE_KEY, \{[\s\S]*?\}\)/, '__sb');

  w.__m = {};
  await w.eval(`(async () => { ${prep}
    ; window.__m.S = S;
  })()`);
  await new Promise(r => setTimeout(r, 180));
  return { w, d:w.document, m:w.__m, estado };
}

const esperar = (ms = 120) => new Promise(r => setTimeout(r, ms));
const ultima = (e, fn) => [...e.llamadas].reverse().find(l => l.fn === fn);

const base = (rol = 'gerente', nivel = 3) => {
  const estado = {
    catalogo: CATALOGO(),
    tablas:{
      proveedores:[{ id:'pv1', nombre:'Distribuidora La Ceiba', dias_credito:0, dias_entrega:2 }],
      categorias:[{ id:'c1', nombre:'Abarrotes', padre_id:null },
                  { id:'c2', nombre:'Café', padre_id:'c1' }],
      impuestos:[{ id:'i0', nombre:'Exento', tasa:0, es_predeterminado:false },
                 { id:'i1', nombre:'ISV', tasa:0.15, es_predeterminado:true }]
    },
    rpc:{
      fn_pos_contexto:{ data:CTX(rol, nivel), error:null },
      fn_crear_producto_compra: a => {
        const id = 'pn' + (estado.catalogo.length + 1);
        const conPrecio = nivel >= 3 && a.p_precio > 0;
        estado.catalogo.push({ producto_id:id, sku:a.p_sku || 'N0011', nombre:a.p_nombre,
          unidad_base:'UND', controla_lote:false, controla_vencimiento:!!a.p_controla_vencimiento,
          tasa_impuesto:0.15, precio_venta: conPrecio ? a.p_precio : null, ultimo_costo:0,
          existencia:0, codigos: a.p_codigo_barras ? [a.p_codigo_barras] : [], presentaciones:[] });
        return { data:{ producto_id:id, sku:a.p_sku || 'N0011', nombre:a.p_nombre,
          codigo_barras:a.p_codigo_barras, precio: conPrecio ? a.p_precio : null,
          precio_pendiente: !conPrecio, precio_ignorado: nivel < 3 && a.p_precio > 0 }, error:null };
      }
    }
  };
  estado.tablas.v_catalogo_compra = () => estado.catalogo;
  return estado;
};

function buscar(d, w, texto){
  const c = d.querySelector('#f-buscar');
  c.value = texto;
  c.dispatchEvent(new w.Event('input'));
}

/* ===================================================================== */
console.log('\n=== BUSCAR ALGO QUE NO EXISTE ===');
{
  const { d, w } = await montar(base());
  buscar(d, w, 'Café molido');
  const r = d.querySelector('#f-resultados');
  chk('dice que no está', /No está en el catálogo/.test(r.textContent));
  chk('y ofrece crearlo con su nombre', /Crear «Café molido» como producto nuevo/.test(r.textContent));

  r.querySelector('[data-nuevo]').click();
  await esperar();
  chk('abre la hoja de producto nuevo', !d.querySelector('#velo').classList.contains('oculto') &&
      /Producto nuevo/.test(d.querySelector('#hoja h2').textContent));
  chk('con el nombre ya escrito', d.querySelector('#np-nombre').value === 'Café molido');
  chk('el código de barras vacío', d.querySelector('#np-barras').value === '');
  chk('el impuesto predeterminado ya elegido', d.querySelector('#np-imp').value === 'i1');
  const cats = [...d.querySelectorAll('#np-cat option')].map(o => o.textContent);
  chk('las subcategorías con su departamento', cats.includes('Abarrotes › Café'));
  chk('el gerente ve el precio', !!d.querySelector('#np-precio'));
}
{
  const { d, w } = await montar(base());
  buscar(d, w, 'aceite');
  const r = d.querySelector('#f-resultados');
  chk('con resultados igual se puede crear', /¿No es ninguno\? Crear producto nuevo/.test(r.textContent));
  chk('pero el producto encontrado va primero', r.firstElementChild.classList.contains('res'));
}

console.log('\n=== CÓDIGO DE BARRAS ===');
{
  const { d, w } = await montar(base());
  buscar(d, w, '7409999000011');
  d.querySelector('#f-buscar').dispatchEvent(new w.KeyboardEvent('keydown', { key:'Enter' }));
  await esperar();
  chk('la pistola USB con código desconocido abre la hoja', !d.querySelector('#velo').classList.contains('oculto'));
  chk('el código cae en su campo', d.querySelector('#np-barras').value === '7409999000011');
  chk('y el nombre queda vacío para escribirlo', d.querySelector('#np-nombre').value === '');
  chk('con el cursor en el nombre', d.activeElement === d.querySelector('#np-nombre'));
}
{
  const estado = base();
  estado.lecturas = ['7401234567890', '7405555000099'];
  const { d, m } = await montar(estado);
  d.querySelector('#btn-camara').click();
  await esperar();
  chk('el escáner agrega el conocido', m.S.lineas.length === 1 && estado.respuestas[0].ok);
  chk('el desconocido se avisa', !estado.respuestas[1].ok &&
      /Cierre la cámara para crearlo/.test(estado.respuestas[1].texto));
  chk('y al cerrar se ofrece crearlo con su código',
      !d.querySelector('#velo').classList.contains('oculto') &&
      d.querySelector('#np-barras').value === '7405555000099');
}

{
  const estado = base();
  estado.lecturaUnica = '7408888777666';
  const { d, w } = await montar(estado);
  buscar(d, w, 'Leche en polvo');
  d.querySelector('[data-nuevo]').click();
  await esperar();
  d.querySelector('#np-escanear').click();
  await esperar();
  chk('dentro de la hoja se puede escanear el código', d.querySelector('#np-barras').value === '7408888777666');
}

console.log('\n=== GUARDAR ===');
{
  const estado = base();
  const { d, w, m } = await montar(estado);
  d.querySelector('#f-prov').value = 'pv1';
  buscar(d, w, 'Café molido 400 g');
  d.querySelector('[data-nuevo]').click();
  await esperar();
  chk('dice qué proveedor queda de habitual', /Distribuidora La Ceiba/.test(d.querySelector('#hoja .sub').textContent));

  d.querySelector('#np-barras').value = '7409999000011';
  d.querySelector('#np-cat').value = 'c2';
  d.querySelector('#np-precio').value = '45';
  d.querySelector('#np-caja').value = '24';
  d.querySelector('#np-vence').checked = true;
  d.querySelector('#np-si').click();
  await esperar(250);

  const a = ultima(estado, 'fn_crear_producto_compra').args;
  chk('manda el nombre', a.p_nombre === 'Café molido 400 g');
  chk('el código, la categoría y el impuesto', a.p_codigo_barras === '7409999000011' &&
      a.p_categoria_id === 'c2' && a.p_impuesto_id === 'i1');
  chk('el precio y las unidades por caja', a.p_precio === 45 && a.p_unidades_empaque === 24);
  chk('perecedero', a.p_controla_vencimiento === true);
  chk('y el proveedor de la factura', a.p_proveedor_id === 'pv1');
  chk('código interno vacío = automático', a.p_sku === null);

  chk('se cierra la hoja', d.querySelector('#velo').classList.contains('oculto'));
  chk('vuelve a leer el catálogo',
      estado.llamadas.filter(l => l.fn === 'from:v_catalogo_compra').length >= 2);
  chk('y el producto ya está en la entrada',
      m.S.lineas.length === 1 && m.S.lineas[0].nombre === 'Café molido 400 g');
  chk('pide lote y vencimiento porque es perecedero', m.S.lineas[0].pide_vencimiento === true);
  chk('la búsqueda queda limpia', d.querySelector('#f-buscar').value === '');
}
{
  const { d, w, estado } = await montar(base());
  buscar(d, w, 'Galletas');
  d.querySelector('[data-nuevo]').click();
  await esperar();
  d.querySelector('#np-si').click();
  await esperar(250);
  chk('el gerente sin precio: se le avisa que no saldrá en caja',
      /sin precio/.test(d.querySelector('#hoja h2').textContent) &&
      /le ponga precio en Catálogos/.test(d.querySelector('#hoja').textContent));
}
{
  const { d, w, estado } = await montar(base());
  buscar(d, w, 'x');
  d.querySelector('[data-nuevo]').click();
  await esperar();
  d.querySelector('#np-nombre').value = '   ';
  d.querySelector('#np-si').click();
  await esperar();
  chk('sin nombre no se manda nada', !ultima(estado, 'fn_crear_producto_compra') &&
      /Escriba el nombre/.test(d.querySelector('#np-error').textContent));
}
{
  const estado = base();
  estado.rpc.fn_crear_producto_compra = { data:null,
    error:{ message:'P0001: Ese código de barras ya es de «Aceite vegetal 500ml»' } };
  const { d, w, m } = await montar(estado);
  buscar(d, w, 'Aceite nuevo');
  d.querySelector('[data-nuevo]').click();
  await esperar();
  d.querySelector('#np-si').click();
  await esperar();
  chk('el error del servidor se muestra en la hoja, limpio',
      !d.querySelector('#velo').classList.contains('oculto') &&
      d.querySelector('#np-error').textContent === 'Ese código de barras ya es de «Aceite vegetal 500ml»');
  chk('y no agrega nada', m.S.lineas.length === 0);
}
{
  const estado = base();
  estado.rpc.fn_crear_producto_compra = { data:null, error:{ message:
    'Could not find the function public.fn_crear_producto_compra in the schema cache' } };
  const { d, w } = await montar(estado);
  buscar(d, w, 'Algo');
  d.querySelector('[data-nuevo]').click();
  await esperar();
  d.querySelector('#np-si').click();
  await esperar();
  chk('si falta la migración lo dice en español', /migración 027/.test(d.querySelector('#np-error').textContent));
}

console.log('\n=== SUPERVISOR ===');
{
  const estado = base('supervisor', 2);
  const { d, w, m } = await montar(estado);
  buscar(d, w, 'Jabón de cuaba');
  d.querySelector('[data-nuevo]').click();
  await esperar();
  chk('no ve el campo de precio', !d.querySelector('#np-precio'));
  chk('y se le explica', /El precio de venta lo pone el gerente/.test(d.querySelector('#hoja').textContent));
  d.querySelector('#np-si').click();
  await esperar(250);
  chk('no manda precio', ultima(estado, 'fn_crear_producto_compra').args.p_precio === null);
  chk('el producto entra a la factura', m.S.lineas.length === 1);
  chk('y el aviso dice que lo ponga el gerente', /el gerente le ponga precio/.test(d.querySelector('#hoja').textContent));
}

console.log(`\n${ok} bien · ${mal} mal`);
process.exit(mal ? 1 : 0);
