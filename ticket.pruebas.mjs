/* Prueba del ticket impreso: factura, comprobante, devolucion y nota de
   credito, y el total en letras. */
import { htmlTicket, numeroALetras } from './ticket.js';

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

console.log('\n' + ok + ' bien, ' + mal + ' mal');
process.exit(mal ? 1 : 0);
