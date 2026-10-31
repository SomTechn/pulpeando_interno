/* Pruebas de Vencimientos, Importar y precios, Promociones, y de la cuenta
   de promociones (promos.js), con los mismos casos que t_042.sql: la caja y
   el servidor tienen que dar el mismo centavo. */
import fs from 'node:fs';
import { JSDOM } from 'jsdom';
import { calcularPromos, nombreCorto } from './promos.js';

const BASE = new URL('./', import.meta.url).pathname;
let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };
const esperar = (ms = 80) => new Promise(r => setTimeout(r, ms));
const igual = (a, b) => JSON.stringify(a) === JSON.stringify(b);

const CTX = nivel => ({ usuario:{ id:'u1', nombre:'Doña Marta', rol:'gerente', nivel },
  organizacion:{ id:'o1', nombre:'Abarrotería El Buen Precio', moneda:'HNL' },
  sucursales:[{ id:'s1', nombre:'Central' }] });

async function montar(pagina, estado, hash = ''){
  const html = fs.readFileSync(BASE + pagina, 'utf8');
  const cuerpo = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
  const dom = new JSDOM(
    html.replace(/<script type="module">[\s\S]*?<\/script>/, '')
        .replace(/<script src="(config|tema)\.js"><\/script>/g, ''),
    { runScripts:'outside-only', url:'https://x.test/' + pagina + hash, pretendToBeVisual:true });
  const w = dom.window;
  w.SUPABASE_CONFIG = { url:'https://x.supabase.co', key:'k' };
  Object.defineProperty(w.navigator, 'serviceWorker', { value:{ register: async () => ({}) }, configurable:true });
  w.matchMedia = () => ({ matches:false, addEventListener(){}, removeEventListener(){} });
  globalThis.window = w; globalThis.document = w.document;
  globalThis.localStorage = w.localStorage; globalThis.matchMedia = w.matchMedia;
  estado.llamadas = [];
  const tabla = t => ({ select(){ return this; }, order(){ return this; }, eq(){ return this; }, or(){ return this; },
    limit(){ return this; }, then(r, j){ return Promise.resolve({ data:(estado.tablas || {})[t] || [], error:null }).then(r, j); } });
  w.__sb = {
    auth:{ getSession: async () => ({ data:{ session:{ user:{ id:'u1' } } } }), signInWithPassword: async () => ({}), signOut: async () => {} },
    rpc: async (fn, args) => {
      estado.llamadas.push({ fn, args });
      const h = estado.rpc[fn];
      if (h === undefined) return { data:null, error:{ message:'sin simular: ' + fn } };
      return typeof h === 'function' ? h(args) : h;
    },
    from: t => tabla(t)
  };
  const menu = await import(BASE + 'menu.js');
  w.montarMenu = menu.montarMenu; w.escapar = menu.escapar; w.nombreCorto = nombreCorto;
  const prep = cuerpo
    .replace(/^import \{ createClient \} from 'https:\/\/esm\.sh\/@supabase\/supabase-js@2';$/m, '')
    .replace(/^import \{ montarMenu, escapar \} from '\.\/menu\.js';$/m, '')
    .replace(/^import \{ nombreCorto \} from '\.\/promos\.js';$/m, '')
    .replace(/createClient\(SUPABASE_URL, SUPABASE_KEY, \{[\s\S]*?\}\)/, '__sb');
  await w.eval(`(async () => { ${prep} })()`);
  await esperar(160);
  return { w, d:w.document };
}

console.log('\n=== LA CUENTA DE PROMOCIONES (igual que el servidor) ===');
{
  const nxm = [{ id:'a', nombre:'2x1', tipo:'nxm', lleva:2, paga:1, producto_ids:['coca'] }];
  let r = calcularPromos([{ producto_id:'coca', cantidad:5, precio:50 }], nxm);
  chk('5 cocas en 2x1: L 100 de descuento (como en t_042)', igual(r.descuentos, [100]));
  chk('y dice qué promo la tocó', igual(r.porLinea, [['a']]) && r.aplicadas[0].descuento === 100);

  const paq = [{ id:'b', nombre:'3 por 120', tipo:'paquete', lleva:3, precio_paquete:120, producto_ids:['coca','pepsi'] }];
  r = calcularPromos([{ producto_id:'coca', cantidad:2, precio:50 }, { producto_id:'pepsi', cantidad:2, precio:40 }], paq);
  chk('paquete mezclado: 14.28 y 5.72 (como en t_042)', igual(r.descuentos, [14.28, 5.72]));

  const pct = [{ id:'c', nombre:'-12.5%', tipo:'porcentaje', porcentaje:12.5, producto_ids:['pepsi'] }];
  r = calcularPromos([{ producto_id:'pepsi', cantidad:1.5, precio:40 }], pct);
  chk('12.5% sobre 1.5 de L 40: 7.50 (como en t_042)', igual(r.descuentos, [7.5]));

  r = calcularPromos([{ producto_id:'coca', cantidad:1, precio:50 }], nxm);
  chk('con uno solo no hay 2x1', igual(r.descuentos, [0]) && !r.aplicadas.length);

  r = calcularPromos([{ producto_id:'q', cantidad:1.75, precio:60 }],
    [{ id:'x', nombre:'2x1 queso', tipo:'nxm', lleva:2, paga:1, producto_ids:['q'] }]);
  chk('lo que se vende por peso no entra en 2x1 (1.75 lb no son dos unidades)', igual(r.descuentos, [0]));

  // dos promos sobre lo mismo: cada unidad entra en una sola
  r = calcularPromos([{ producto_id:'coca', cantidad:3, precio:50 }],
    [...nxm, { id:'d', nombre:'-10%', tipo:'porcentaje', porcentaje:10, producto_ids:['coca'] }]);
  chk('una unidad no entra en dos promos: 2x1 a dos, 10% a la tercera', igual(r.descuentos, [55]));

  // 2x1 entre precios distintos: la gratis es la más barata
  r = calcularPromos([{ producto_id:'coca', cantidad:1, precio:50 }, { producto_id:'pepsi', cantidad:1, precio:40 }],
    [{ id:'e', nombre:'2x1 mezcla', tipo:'nxm', lleva:2, paga:1, producto_ids:['coca','pepsi'] }]);
  chk('en el 2x1 mezclado sale gratis la más barata', igual(r.descuentos, [0, 40]));

  // un paquete que costaría más que suelto no cobra de más
  r = calcularPromos([{ producto_id:'pepsi', cantidad:3, precio:30 }],
    [{ id:'f', nombre:'3 por 100', tipo:'paquete', lleva:3, precio_paquete:100, producto_ids:['pepsi'] }]);
  chk('si el paquete sale más caro que suelto, no se aplica', igual(r.descuentos, [0]));

  // centavos que no se reparten exacto
  r = calcularPromos([{ producto_id:'a1', cantidad:1, precio:33.33 }, { producto_id:'a2', cantidad:1, precio:33.33 },
                      { producto_id:'a3', cantidad:1, precio:33.34 }],
    [{ id:'g', nombre:'3 por 90', tipo:'paquete', lleva:3, precio_paquete:90, producto_ids:['a1','a2','a3'] }]);
  chk('el descuento de un paquete suma exacto al centavo',
      Math.round(r.descuentos.reduce((s, x) => s + x, 0) * 100) === 1000);

  chk('nombres cortos', nombreCorto(nxm[0]) === '2x1' && nombreCorto(pct[0]) === '−12.5%'
      && nombreCorto(paq[0]) === '3 por L 120.00');
}

console.log('\n=== VENCIMIENTOS ===');
{
  const LOTES = [
    { lote_id:'l1', lote:'L-VIEJO', vence:'2026-10-28', dias:-3, producto_id:'p1', nombre:'Leche Sula 1 L', sku:'LEC', unidad:'UND',
      sucursal:'Central', cantidad:4, costo:20, valor:80, precio:28, en_oferta:false, merma_pendiente:false },
    { lote_id:'l2', lote:'L-PRONTO', vence:'2026-11-05', dias:5, producto_id:'p2', nombre:'Yogurt fresa', sku:'YOG', unidad:'UND',
      sucursal:'Central', cantidad:12, costo:10, valor:120, precio:18, en_oferta:false, merma_pendiente:false },
    { lote_id:'l3', lote:'L-MES', vence:'2026-11-20', dias:20, producto_id:'p3', nombre:'Queso crema', sku:'QCR', unidad:'UND',
      sucursal:'Central', cantidad:6, costo:30, valor:180, precio:45, en_oferta:true, merma_pendiente:false }];
  const estado = { rpc:{
    fn_pos_contexto:{ data:CTX(3), error:null },
    fn_vencimientos:{ data:{ hoy:'2026-10-31', puede_ver_costos:true, puede_ofertar:true, lotes:LOTES }, error:null },
    fn_fijar_oferta:{ data:'o1', error:null },
    fn_causas_merma:{ data:[{ causa_id:'c1', nombre:'Vencimiento', clase:'dano' }], error:null },
    fn_registrar_merma:{ data:{ merma_id:'m1' }, error:null } } };
  const { d } = await montar('vencimientos.html', estado);
  const t = d.querySelector('#contenido').textContent;
  chk('los tres grupos, de lo urgente a lo que espera', /Vencido[\s\S]*Vence esta semana[\s\S]*Vence este mes/.test(t));
  chk('cuenta los días', /venció hace 3 días/.test(t) && /vence en 5 días/.test(t));
  chk('el resumen con valor', /L 80\.00/.test(d.querySelector('#resumen').textContent));
  chk('lo vencido no se ofrece en oferta', !d.querySelector('[data-oferta="l1"]'));
  chk('lo que ya está en oferta tampoco', !d.querySelector('[data-oferta="l3"]') && /En oferta/.test(t));
  d.querySelector('[data-oferta="l2"]').click();
  await esperar();
  chk('la oferta sugiere 20% menos', d.querySelector('#of-p').value === '14.00');
  chk('y dice el markdown', /markdown\) de 22%/.test(d.querySelector('#of-md').textContent));
  d.querySelector('#of-si').click();
  await esperar(120);
  const of = estado.llamadas.find(l => l.fn === 'fn_fijar_oferta');
  chk('pone la oferta hasta el día que vence', of && of.args.p_precio === 14 && of.args.p_hasta === '2026-11-05');

  d.querySelector('[data-baja="l1"]').click();
  await esperar(120);
  d.querySelector('#bj-c').value = '10';
  d.querySelector('#bj-si').click();
  await esperar();
  chk('no da de baja más de lo que hay', /solo hay 4/.test(d.querySelector('#bj-e').textContent));
  d.querySelector('#bj-c').value = '4';
  d.querySelector('#bj-si').click();
  await esperar(120);
  const m = estado.llamadas.find(l => l.fn === 'fn_registrar_merma');
  chk('la baja es una merma por vencimiento de ese lote', m && m.args.p_causa_id === 'c1' && m.args.p_lote_id === 'l1' && m.args.p_cantidad === 4);

  d.querySelector('#resumen [data-f="semana"]').click();
  chk('tocar "esta semana" filtra', d.querySelectorAll('.lt').length === 1);
}

console.log('\n=== IMPORTAR ===');
{
  const estado = { rpc:{ fn_pos_contexto:{ data:CTX(3), error:null },
    fn_importar_productos: a => ({ data:{ filas:a.p_filas.length, creados:a.p_filas.length - 1, actualizados:1,
      existencias:1, omitidos:0, errores:[], avisos:[{ fila:1, mensaje:'Ya tenía existencia' }] }, error:null }) } };
  const { w, d } = await montar('importar.html', estado);
  const I = w.__importar;
  chk('reconoce encabezados con tildes y sinónimos',
      igual(I.mapear(['Descripción', 'Código de barras', 'PVP', 'Stock', 'Item', 'Costo unitario']),
            { sku:4, nombre:0, codigo:1, precio:2, costo:5, existencia:3 }));
  chk('"Código" solo es el de barras', I.mapear(['Codigo', 'Nombre']).codigo === 0);
  chk('números como los escribe la gente', I.numero('L 1,250.50') === 1250.5 && I.numero('1.250,50') === 1250.5
      && I.numero('15,5') === 15.5 && I.numero('') === null && I.numero('abc') === null);
  const csv = I.leerCSV('﻿Nombre;Precio;Código\n"Arroz ""Progreso"" 5 lb";98,50;7421\nQueso;78;\n\n');
  chk('lee CSV con punto y coma y comillas', csv.length === 3 && csv[1][0] === 'Arroz "Progreso" 5 lb' && csv[1][1] === '98,50');

  // flujo completo con un archivo
  const archivo = new w.File(['Item,Nombre,Precio,Costo,Existencia\nA1,Arroz,98,78,40\nA2,Frijol,30,,10\n,,,,\nA3,Azúcar,abc,20,\n'],
                             'lista.csv', { type:'text/csv' });
  const input = d.querySelector('#arch');
  Object.defineProperty(input, 'files', { value:[archivo] });
  input.dispatchEvent(new w.Event('change'));
  await esperar(200);
  chk('lee el archivo', /3 filas/.test(d.querySelector('#arch-sub').textContent));
  chk('marca las filas con problemas', d.querySelectorAll('.tabla tr.mal').length === 2);
  chk('explica cuál es el problema', /existencia sin costo/.test(d.body.textContent) && /precio no es número/.test(d.body.textContent));
  d.querySelector('#b-importar').click();
  await esperar(250);
  const imp = estado.llamadas.find(l => l.fn === 'fn_importar_productos');
  chk('manda solo las buenas', imp && imp.args.p_filas.length === 1 && imp.args.p_filas[0].sku === 'A1');
  chk('con los números limpios', imp && imp.args.p_filas[0].precio === '98' && imp.args.p_filas[0].existencia === '40');
  chk('enseña el resultado', /Productos nuevos/.test(d.body.textContent) && /Ya tenía existencia/.test(d.body.textContent));
}
{
  const estado = { rpc:{ fn_pos_contexto:{ data:CTX(3), error:null },
    fn_cambiar_precios: a => ({ data:{ productos:2, sin_costo:0, aplicado:a.p_aplicar, lista:[
      { producto_id:'p1', nombre:'Coca 3 L', actual:75, nuevo:82.5, costo:58, margen:15.7 },
      { producto_id:'p2', nombre:'Pepsi 3 L', actual:70, nuevo:70, costo:52, margen:13.5 }] }, error:null }) },
    tablas:{ categorias:[{ id:'cat1', nombre:'Bebidas' }], marcas:[], proveedores:[] } };
  const { w, d } = await montar('importar.html', estado, '#precios');
  await esperar(120);
  chk('entra a cambiar precios por el enlace', /Cambiar precios en lote/.test(d.body.textContent));
  d.querySelector('#p-valor').value = '10';
  d.querySelector('#b-ver').click();
  await esperar(150);
  const v = estado.llamadas.find(l => l.fn === 'fn_cambiar_precios');
  chk('primero pide la vista previa', v && v.args.p_aplicar === false && v.args.p_filtro.categoria_id === 'cat1'
      && v.args.p_modo === 'porcentaje' && v.args.p_redondeo === 0.5);
  chk('dice cuántos cambian', /1 cambian de precio/.test(d.body.textContent));
  d.querySelector('#b-aplicar').click();
  chk('pide confirmar antes', /Seguro/.test(d.querySelector('#b-aplicar').textContent)
      && !estado.llamadas.some(l => l.fn === 'fn_cambiar_precios' && l.args.p_aplicar));
  d.querySelector('#b-aplicar').click();
  await esperar(150);
  chk('y luego aplica', estado.llamadas.some(l => l.fn === 'fn_cambiar_precios' && l.args.p_aplicar === true));
}
{
  const estado = { rpc:{ fn_pos_contexto:{ data:CTX(2), error:null } } };
  const { d } = await montar('importar.html', estado);
  chk('el supervisor no importa', !d.querySelector('#p-bloqueado').classList.contains('oculto'));
}

console.log('\n=== PROMOCIONES ===');
{
  const LISTA = [
    { id:'pr1', nombre:'2x1 Coca 3 L', tipo:'nxm', lleva:2, paga:1, alcance:'productos', producto_ids:['p1'],
      productos:[{ id:'p1', nombre:'Coca-Cola 3 L' }], vigente_desde:'2026-10-01', vigente_hasta:'2026-11-30',
      dias_semana:[6, 0], activa:true, estado:'vigente', usos_30d:14, descuento_30d:700 },
    { id:'pr2', nombre:'Navidad', tipo:'porcentaje', porcentaje:15, alcance:'categoria', categoria_id:'cat1', categoria:'Bebidas',
      vigente_desde:'2026-12-01', activa:true, estado:'programada', usos_30d:0, descuento_30d:0 }];
  const estado = { rpc:{ fn_pos_contexto:{ data:CTX(3), error:null }, fn_promociones:{ data:LISTA, error:null },
                         fn_guardar_promocion:{ data:'nueva', error:null } },
    tablas:{ categorias:[{ id:'cat1', nombre:'Bebidas' }], marcas:[{ id:'m1', nombre:'Pepsi' }],
             productos:[{ id:'p9', nombre:'Pepsi 3 L', sku:'PEP3' }] } };
  const { w, d } = await montar('promociones.html', estado);
  const t = d.querySelector('#contenido').textContent;
  chk('las vigentes primero', d.querySelectorAll('.pc').length === 1 && /2x1 Coca 3 L/.test(t));
  chk('en una frase', /Lleva 2 y paga 1 en Coca-Cola 3 L, del 1 oct al 30 nov, solo sábados, domingos/.test(t));
  chk('con lo que ha dado', /L 700\.00/.test(t));
  d.querySelector('#pest [data-e="programada"]').click();
  chk('las programadas en su pestaña', /15% de descuento en toda la categoría Bebidas/.test(d.querySelector('#contenido').textContent));

  d.querySelector('#b-nueva').click();
  await esperar(120);
  d.querySelector('#f-tipo [data-t="paquete"]').click();
  d.querySelector('#f-paquete').value = '100';
  d.querySelector('#f-paquete').dispatchEvent(new w.Event('input'));
  d.querySelector('#f-si').click();
  await esperar();
  chk('sin productos no guarda', /al menos un producto/.test(d.querySelector('#f-err').textContent));
  d.querySelector('#f-alc [data-a="marca"]').click();
  await esperar();
  chk('se pone el nombre solo', d.querySelector('#f-nombre').value === '3 por L 100.00 Pepsi');
  chk('y se ve en una frase', /3 por L 100\.00 en toda la marca Pepsi/.test(d.querySelector('#f-ley').textContent));
  d.querySelector('#f-dias [data-d="5"]').click();
  d.querySelector('#f-si').click();
  await esperar(120);
  const g = estado.llamadas.find(l => l.fn === 'fn_guardar_promocion');
  chk('guarda el paquete por marca con su día', g && g.args.p.tipo === 'paquete' && g.args.p.lleva === 3
      && g.args.p.precio_paquete === 100 && g.args.p.alcance === 'marca' && g.args.p.marca_id === 'm1'
      && igual(g.args.p.dias_semana, [5]));
}
{
  const estado = { rpc:{ fn_pos_contexto:{ data:CTX(2), error:null }, fn_promociones:{ data:[], error:null } } };
  const { d } = await montar('promociones.html', estado);
  chk('el supervisor las ve pero no crea', !d.querySelector('#b-nueva') && d.querySelector('#p-bloqueado').classList.contains('oculto'));
}

console.log(`\n${ok} bien · ${mal} mal`);
process.exit(mal ? 1 : 0);
