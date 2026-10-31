/* Prueba del ticket impreso: factura, comprobante, devolucion y nota de
   credito, y el total en letras. */
import { htmlTicket, numeroALetras, partesCodigo, urlLogo } from './ticket.js';
import { modulosCode128 } from './etiqueta.js';

let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };
const texto = h => h.replace(/<style[\s\S]*?<\/style>/, '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');

const NEG = { nombre:'Pulpería Mejía', razon_social:'Inversiones Mejía', rtn:'08011999123456',
              moneda:'HNL', mensaje_ticket:'Vuelva pronto' };
const base = (venta, extra = {}) => ({
  negocio:NEG, sucursal:{ nombre:'Central' }, caja:'Caja 1', cajero:'Ana',
  desglose:{ exento:0, gravado15:100, isv15:15, gravado18:0, isv18:0 },
  lineas:[{ producto:'Arroz 5 lb', cantidad:1, precio:115, total:115, exento:false }],
  pagos:[{ metodo:'efectivo', monto:115, recibido:200, cambio:85 }],
  venta:{ numero:'T-S01-00000001', creada_en:'2026-10-11T15:00:00Z', subtotal:100,
          impuesto:15, descuento:0, total:115, estado:'completada', ...venta }, ...extra });

console.log('\n=== EN LETRAS ===');
chk('121 → CIENTO VEINTIÚN', /CIENTO VEINTIÚN LEMPIRAS/.test(numeroALetras(121)));
chk('1,000,000 → UN MILLÓN DE', /^UN MILLÓN DE LEMPIRAS/.test(numeroALetras(1000000)));
chk('centavos', /50\/100/.test(numeroALetras(10.5)));

console.log('\n=== COMPROBANTE ===');
{
  const t = texto(htmlTicket(base({ documento:'ticket' })));
  chk('dice COMPROBANTE', /COMPROBANTE/.test(t));
  chk('aclara que no es factura', /No es factura/.test(t));
  chk('muestra el cambio', /Cambio 85\.00/.test(t));
  chk('el mensaje del negocio', /Vuelva pronto/.test(t));
}

console.log('\n=== FACTURA ===');
{
  const t = texto(htmlTicket(base({ documento:'factura', numero_fiscal:'000-001-01-00000009',
    cai:'A1B2C3-D4E5F6-A1B2C3-D4E5F6-A1B2C3-0F' }), { copia:true }));
  chk('dice FACTURA', /FACTURA/.test(t) && !/NOTA DE CRÉDITO/.test(t));
  chk('con su CAI', /A1B2C3-D4E5F6/.test(t));
  chk('el ISV desglosado', /ISV 15% 15\.00/.test(t));
  chk('el total en letras', /Son: CIENTO QUINCE LEMPIRAS/.test(t));
  chk('la reimpresión dice COPIA', /COPIA: EMISOR/.test(t));
}

console.log('\n=== DEVOLUCIÓN INTERNA ===');
{
  const d = base({ documento:'devolucion', numero:'DV-S01-00000004' }, {
    devolucion:{ motivo:'venía vencido', referencia:'T-S01-00000001', rebaja_fiado:60,
                 reembolso:55, metodo:'efectivo' },
    pagos:[{ metodo:'efectivo', monto:55 }] });
  const t = texto(htmlTicket(d));
  chk('dice DEVOLUCIÓN', /DEVOLUCIÓN/.test(t) && !/COMPROBANTE/.test(t));
  chk('aclara que no es nota de crédito', /No es nota de crédito/.test(t));
  chk('dice de qué venta', /Venta: T-S01-00000001/.test(t));
  chk('y el motivo', /venía vencido/.test(t));
  chk('lo rebajado del fiado', /Rebajado del fiado 60\.00/.test(t));
  chk('lo devuelto en efectivo', /Devuelto en efectivo 55\.00/.test(t));
  chk('pide firma de recibido', /Recibí conforme/.test(t));
  chk('sin "gracias por su compra"', !/Vuelva pronto|Gracias por su compra/.test(t));
}

console.log('\n=== NOTA DE CRÉDITO ===');
{
  const d = base({ documento:'nota_credito', numero:'DV-S01-00000005',
    numero_fiscal:'000-001-03-00000001', cai:'ABCDEF-ABCDEF-ABCDEF-ABCDEF-ABCDEF-34' }, {
    rango:{ desde:'000-001-03-00000001', hasta:'000-001-03-00000100', fecha_limite:'2027-01-31' },
    devolucion:{ motivo:'mal estado', referencia:'000-001-01-00000009', rebaja_fiado:0,
                 reembolso:115, metodo:'tarjeta' } });
  const t = texto(htmlTicket(d));
  chk('dice NOTA DE CRÉDITO', /NOTA DE CRÉDITO/.test(t));
  chk('con su número fiscal y CAI', /000-001-03-00000001/.test(t) && /ABCDEF-ABCDEF/.test(t));
  chk('su rango autorizado', /Rango autorizado: 000-001-03-00000001 al 000-001-03-00000100/.test(t));
  chk('la factura que corrige', /Factura que corrige: 000-001-01-00000009/.test(t));
  chk('el ISV que se revierte', /ISV 15% 15\.00/.test(t));
  chk('el total en letras', /Son: CIENTO QUINCE/.test(t));
  chk('lo devuelto por tarjeta', /Devuelto en tarjeta 115\.00/.test(t));
  chk('sin las casillas de exoneración de la factura', !/orden de compra exenta/.test(t));
  chk('original para el cliente', /ORIGINAL: CLIENTE/.test(t));
}

/* Lee de vuelta las barras del SVG, como lo haría la pistola: de los
   rectángulos a módulos, de los módulos a símbolos de 11, de ahí a dígitos. */
function leerBarras(html){
  const svg = html.match(/<svg[^>]*viewBox="0 0 (\d+) \d+"[\s\S]*?<\/svg>/);
  if (!svg) return null;
  const ancho = Number(svg[1]);
  const m = Array(ancho).fill('0');
  for (const r of svg[0].matchAll(/<rect x="(\d+)" y="0" width="(\d+)"/g))
    for (let i = 0; i < Number(r[2]); i++) m[Number(r[1]) + i] = '1';
  const mod = m.join('').slice(10, -10);                 // sin la zona quieta
  const tabla = {};
  for (let v = 0; v < 100; v++){
    const par = String(v).padStart(2, '0');
    tabla[modulosCode128(par + par).slice(11, 22)] = par;
  }
  if (mod.slice(0, 11) !== modulosCode128('0000').slice(0, 11)) return 'sin Start C';
  let out = '';
  for (let i = 11; i < mod.length - 13 - 11; i += 11) out += tabla[mod.slice(i, i + 11)] ?? '?';
  return out;
}

console.log('\n=== CÓDIGO DEL TICKET ===');
{
  const COD = '8040020117867778';
  const h = htmlTicket(base({ documento:'ticket', codigo_barras:COD }));
  const t = texto(h);
  chk('las piezas del código', JSON.stringify(partesCodigo('804-002-01-17867778')) ===
      JSON.stringify({ tienda:'804', cajero:'002', caja:'01', ticket:'17867778' }));
  chk('un código que no es de 16 no se parte', partesCodigo('12345') === null);
  chk('lleva el código de barras', /<svg/.test(h));
  chk('las barras se leen de vuelta como el código', leerBarras(h) === COD);
  chk('los dígitos agrupados con su etiqueta', /804 tienda 002 cajero 01 caja 17867778 ticket/.test(t));
  chk('pide conservarlo', /cambios y devoluciones/.test(t));
  const w80 = Number(h.match(/class="barras" style="width:([\d.]+)mm/)[1]);
  const w58 = Number(htmlTicket(base({ documento:'ticket', codigo_barras:COD }), { ancho:58 })
                .match(/class="barras" style="width:([\d.]+)mm/)[1]);
  chk(`cabe en 80 mm (${w80} mm de 72 imprimibles)`, w80 <= 72);
  chk(`cabe en 58 mm (${w58} mm de 48 imprimibles)`, w58 <= 48);
  chk('módulo de puntos enteros a 203 ppp (2 y 3 puntos)',
      Math.abs(w58 / 0.25 - Math.round(w58 / 0.25)) < 1e-6 && Math.abs(w80 / 0.375 - Math.round(w80 / 0.375)) < 1e-6);
  chk('sin código, sin barras (ventas viejas)', !/<svg/.test(htmlTicket(base({ documento:'ticket' }))));
  chk('anulada: sin barras', !/<svg/.test(htmlTicket(base({ documento:'ticket', codigo_barras:COD, estado:'anulada' }))));
  const dv = htmlTicket(base({ documento:'devolucion', codigo_barras:COD },
    { devolucion:{ motivo:'x', referencia:'T-1', rebaja_fiado:0, reembolso:0 } }));
  chk('la devolución no lleva barras', !/<svg/.test(dv));
  const f = htmlTicket(base({ documento:'factura', numero_fiscal:'000-001-01-00000009', cai:'X', codigo_barras:COD }));
  chk('la factura también lo lleva', leerBarras(f) === COD);
}

console.log('\n=== LOGO ===');
{
  const conLogo = htmlTicket(base({ documento:'ticket' }), { logoUrl:'https://x.supabase.co/l.png' });
  chk('con logo, va arriba del nombre', /<img class="logo" src="https:\/\/x\.supabase\.co\/l\.png"[^>]*>\s*<div class="neg">/.test(conLogo));
  chk('si no carga, se quita (sin internet)', /onerror="this\.remove\(\)"/.test(conLogo));
  chk('sin logo, sin imagen', !/<img/.test(htmlTicket(base({ documento:'ticket' }))));
  globalThis.window = { SUPABASE_CONFIG:{ url:'https://p.supabase.co' } };
  chk('la URL sale del bucket marca', urlLogo({ logo_path:'org/logo-1.png' }) ===
      'https://p.supabase.co/storage/v1/object/public/marca/org/logo-1.png');
  chk('sin logo_path, nada', urlLogo({}) === null);
  delete globalThis.window;
}

console.log('\n' + ok + ' bien, ' + mal + ' mal');
process.exit(mal ? 1 : 0);
