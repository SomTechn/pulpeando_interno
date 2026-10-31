/* La factura en PDF: lo que lleva y que cabe en el rollo.
   Necesita jspdf una vez:  npm install jsdom jspdf  */
import { pdfTicket, nombreArchivo } from './ticket-pdf.js';
import { htmlTicket } from './ticket.js';

let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); } else { mal++; console.log('  MAL  ' + n); } };

let jsPDF;
try{ ({ jsPDF } = await import('jspdf')); }
catch(e){ console.log('  (falta jspdf: npm install jspdf)'); console.log('\n0 bien, 1 mal'); process.exit(1); }

const base = (venta, extra = {}) => ({
  negocio:{ nombre:'Pulpería Mejía', razon_social:'Inversiones Mejía', rtn:'08011999123456', moneda:'HNL' },
  sucursal:{ nombre:'Central' }, caja:'Caja 1', cajero:'Ana',
  desglose:{ exento:0, gravado15:100, isv15:15 },
  lineas:[{ producto:'Arroz 5 lb', cantidad:1, precio:115, total:115 }],
  pagos:[{ metodo:'efectivo', monto:115, recibido:200, cambio:85 }],
  venta:{ numero:'T-001-00000001', creada_en:'2026-10-11T15:00:00Z', subtotal:100, impuesto:15,
          descuento:0, total:115, estado:'completada', documento:'ticket',
          codigo_barras:'1950020159636974', ...venta }, ...extra });
// jsPDF guarda el texto sin comprimir: se puede buscar en el PDF
const texto = doc => doc.output();

console.log('\n=== COMPROBANTE ===');
{
  const d = base({});
  const doc = await pdfTicket(d, { jsPDF, logo:null });
  const t = texto(doc);
  chk('80 mm de ancho', Math.round(doc.internal.pageSize.getWidth()) === 80);
  chk('una sola hoja, del alto del ticket', doc.getNumberOfPages() === 1 && doc.internal.pageSize.getHeight() < 300);
  chk('dice COMPROBANTE y su número', /\(COMPROBANTE\)/.test(t) && /T-001-00000001/.test(t));
  chk('sin la leyenda de comprobante interno', !/No es factura/.test(t));
  chk('el total', /\(115\.00\)/.test(t));
  chk('el cambio', /\(Cambio\)/.test(t) && /\(85\.00\)/.test(t));
  chk('las cuatro piezas del código', ['195', '002', '01', '59636974'].every(g => t.includes(`(${g})`)));
  chk('las barras dibujadas', (t.match(/ re\n/g) || []).length > 20);
  chk('el nombre del archivo', nombreArchivo(d) === 'Ticket T-001-00000001.pdf');
}

console.log('\n=== FACTURA EN 58 mm ===');
{
  const d = base({ documento:'factura', numero_fiscal:'000-001-01-00000009', cai:'A1B2C3-D4E5F6' },
    { rango:{ desde:'000-001-01-00000001', hasta:'000-001-01-00000100', fecha_limite:'2027-01-31' } });
  const doc = await pdfTicket(d, { jsPDF, logo:null, ancho:58 });
  const t = texto(doc);
  chk('58 mm de ancho', Math.round(doc.internal.pageSize.getWidth()) === 58);
  chk('dice FACTURA con su número fiscal', /\(FACTURA\)/.test(t) && /000-001-01-00000009/.test(t));
  chk('con CAI y rango', /A1B2C3-D4E5F6/.test(t) && /Rango autorizado/.test(t));
  chk('el total en letras', /CIENTO QUINCE LEMPIRAS/.test(t));
  chk('original para el cliente', /ORIGINAL: CLIENTE/.test(t));
  chk('el archivo dice Factura', nombreArchivo(d) === 'Factura 000-001-01-00000009.pdf');
  // Lo mismo que el ticket impreso, en lo que importa
  const h = htmlTicket(d);
  chk('lo fiscal coincide con el ticket impreso', ['A1B2C3-D4E5F6', '000-001-01-00000009', 'CIENTO QUINCE']
      .every(x => h.includes(x) && t.includes(x)));
}

console.log('\n=== ANULADA ===');
{
  const doc = await pdfTicket(base({ estado:'anulada' }), { jsPDF, logo:null });
  const t = texto(doc);
  chk('dice ANULADA', /\(ANULADA\)/.test(t));
  chk('y no lleva código para devolver', !t.includes('(59636974)'));
}

console.log('\n' + ok + ' bien, ' + mal + ' mal');
process.exit(mal ? 1 : 0);
