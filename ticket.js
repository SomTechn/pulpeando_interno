/* ==========================================================================
   Ticket y factura impresos.
   Compartido por la caja (al cobrar) y por Ventas (reimprimir).

   Recibe lo que devuelve fn_venta_completa y arma el comprobante para
   impresora termica de 58 u 80 mm (se elige en Configuracion). Se imprime
   desde un iframe escondido: la pantalla de la caja no se mueve, y el
   navegador manda solo el ticket a la impresora.

   Con facturacion fiscal lleva todo lo que la SAR pide en la factura:
   RTN y domicilio del emisor, CAI, rango autorizado y fecha limite de
   emision, numero de factura, RTN o nombre del comprador, el desglose de
   importe exento / gravado 15% / gravado 18% con su ISV, el total en letras
   y la leyenda de original y copia. Sin facturacion es un comprobante
   interno, y lo dice.

   Uso:
     import { imprimirTicket, htmlTicket } from './ticket.js';
     const { data } = await sb.rpc('fn_venta_completa', { p_venta_id:id });
     await imprimirTicket(data);
   ========================================================================== */

const esc = s => String(s ?? '').replace(/[&<>"']/g, c =>
  ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

const n2 = v => (Number(v) || 0).toLocaleString('es-HN',
  { minimumFractionDigits:2, maximumFractionDigits:2 });
const cant = v => (Number(v) || 0).toLocaleString('es-HN', { maximumFractionDigits:3 });

/* ---------- total en letras ---------- */
const UNI = ['', 'UNO', 'DOS', 'TRES', 'CUATRO', 'CINCO', 'SEIS', 'SIETE', 'OCHO', 'NUEVE',
  'DIEZ', 'ONCE', 'DOCE', 'TRECE', 'CATORCE', 'QUINCE', 'DIECISÉIS', 'DIECISIETE',
  'DIECIOCHO', 'DIECINUEVE', 'VEINTE', 'VEINTIUNO', 'VEINTIDÓS', 'VEINTITRÉS',
  'VEINTICUATRO', 'VEINTICINCO', 'VEINTISÉIS', 'VEINTISIETE', 'VEINTIOCHO', 'VEINTINUEVE'];
const DEC = ['', '', '', 'TREINTA', 'CUARENTA', 'CINCUENTA', 'SESENTA', 'SETENTA', 'OCHENTA', 'NOVENTA'];
const CEN = ['', 'CIENTO', 'DOSCIENTOS', 'TRESCIENTOS', 'CUATROCIENTOS', 'QUINIENTOS',
  'SEISCIENTOS', 'SETECIENTOS', 'OCHOCIENTOS', 'NOVECIENTOS'];

function centenas(n){
  if (n === 0) return '';
  if (n === 100) return 'CIEN';
  const c = Math.floor(n / 100), r = n % 100;
  let t = CEN[c];
  if (r){
    const d = r < 30 ? UNI[r] : DEC[Math.floor(r / 10)] + (r % 10 ? ' Y ' + UNI[r % 10] : '');
    t = (t ? t + ' ' : '') + d;
  }
  return t;
}

export function numeroALetras(valor, moneda = 'LEMPIRAS'){
  const total = Math.round((Number(valor) || 0) * 100);
  const entero = Math.floor(total / 100);
  const cent = total % 100;
  let t;
  if (entero === 0) t = 'CERO';
  else {
    const mill = Math.floor(entero / 1000000);
    const miles = Math.floor((entero % 1000000) / 1000);
    const resto = entero % 1000;
    const partes = [];
    if (mill) partes.push(mill === 1 ? 'UN MILLÓN' : centenas(mill).replace(/UNO$/, 'UN') + ' MILLONES');
    if (miles) partes.push(miles === 1 ? 'MIL' : centenas(miles).replace(/VEINTIUNO$/, 'VEINTIÚN').replace(/UNO$/, 'UN') + ' MIL');
    if (resto) partes.push(centenas(resto));
    t = partes.join(' ');
  }
  // "UN LEMPIRA", "VEINTIÚN LEMPIRAS", "UN MILLÓN DE LEMPIRAS"
  t = t.replace(/VEINTIUNO( MIL)?$/, 'VEINTIÚN$1').replace(/UNO( MIL)?$/, 'UN$1')
       .replace(/VEINTIUNO MIL/g, 'VEINTIÚN MIL');
  if (entero >= 1000000 && entero % 1000000 === 0) t += ' DE';
  const mon = entero === 1 ? moneda.replace(/S$/, '') : moneda;
  return `${t} ${mon} CON ${String(cent).padStart(2, '0')}/100`;
}

/* ---------- el comprobante ---------- */
const METODO = { efectivo:'Efectivo', tarjeta:'Tarjeta', transferencia:'Transferencia',
                 credito:'Crédito (fiado)', otro:'Otro' };

function fechaHora(v){
  const d = new Date(v);
  const f = d.toLocaleDateString('es-HN', { day:'2-digit', month:'2-digit', year:'numeric' });
  const h = d.toLocaleTimeString('es-HN', { hour:'2-digit', minute:'2-digit' });
  return `${f} ${h}`;
}
function fecha(v){
  if (!v) return '';
  const [a, m, d] = String(v).slice(0, 10).split('-');
  return `${d}/${m}/${a}`;
}

export function htmlTicket(d, opciones = {}){
  const ancho = Number(opciones.ancho || d.negocio?.ancho_ticket) === 58 ? 58 : 80;
  const v = d.venta, neg = d.negocio || {}, suc = d.sucursal || {};
  const fiscal = v.documento === 'factura' && v.numero_fiscal;
  const mon = neg.moneda === 'HNL' || !neg.moneda ? 'L' : neg.moneda;
  const des = d.desglose || {};
  const lineas = d.lineas || [];
  const pagos = d.pagos || [];
  const cambio = pagos.reduce((a, p) => a + (Number(p.cambio) || 0), 0);
  const anulada = v.estado === 'anulada';

  const fila = (izq, der, fuerte = false) =>
    `<div class="f ${fuerte ? 'b' : ''}"><span>${izq}</span><span>${der}</span></div>`;

  return `<!doctype html><html lang="es"><head><meta charset="utf-8">
<title>${esc(fiscal ? v.numero_fiscal : v.numero)}</title>
<style>
@page{size:${ancho}mm auto;margin:0}
*{box-sizing:border-box;margin:0;padding:0}
body{width:${ancho}mm;padding:${ancho === 58 ? '2mm 2.5mm' : '3mm 4mm'} 6mm;
  font-family:'Courier New',ui-monospace,monospace;font-size:${ancho === 58 ? '10.5px' : '12px'};
  line-height:1.3;color:#000;-webkit-print-color-adjust:exact}
.c{text-align:center}
.neg{font-size:1.35em;font-weight:700;line-height:1.15}
.b{font-weight:700}
.g{font-size:1.25em}
hr{border:none;border-top:1px dashed #000;margin:4px 0}
.f{display:flex;justify-content:space-between;gap:6px}
.f span:last-child{text-align:right;white-space:nowrap}
.it{margin:2px 0}
.it .n{overflow-wrap:anywhere}
.chico{font-size:.88em}
.anulada{border:2px solid #000;text-align:center;font-weight:700;font-size:1.3em;padding:3px;margin:4px 0}
</style></head><body>
<div class="c">
  <div class="neg">${esc(neg.razon_social || neg.nombre)}</div>
  ${neg.razon_social && neg.razon_social !== neg.nombre ? `<div>${esc(neg.nombre)}</div>` : ''}
  ${neg.rtn ? `<div>RTN: ${esc(neg.rtn)}</div>` : ''}
  ${neg.direccion ? `<div class="chico">${esc(neg.direccion)}</div>` : ''}
  ${suc.nombre ? `<div class="chico">${esc(suc.nombre)}${suc.direccion ? ' · ' + esc(suc.direccion) : ''}</div>` : ''}
  ${suc.telefono || neg.telefono ? `<div class="chico">Tel. ${esc(suc.telefono || neg.telefono)}</div>` : ''}
  ${neg.correo ? `<div class="chico">${esc(neg.correo)}</div>` : ''}
</div>
<hr>
${anulada ? '<div class="anulada">ANULADA</div>' : ''}
${fiscal ? `
<div class="c b g">FACTURA</div>
<div class="c b">No. ${esc(v.numero_fiscal)}</div>
<div class="chico">CAI: ${esc(v.cai)}</div>
${d.rango ? `<div class="chico">Rango autorizado: ${esc(d.rango.desde)} al ${esc(d.rango.hasta)}</div>
<div class="chico">Fecha límite de emisión: ${esc(fecha(d.rango.fecha_limite))}</div>` : ''}
` : `
<div class="c b g">COMPROBANTE</div>
<div class="c b">${esc(v.numero)}</div>
<div class="c chico">Comprobante interno. No es factura.</div>
`}
<hr>
${fila('Fecha:', esc(fechaHora(v.creada_en)))}
${d.caja ? fila('Caja:', esc(d.caja)) : ''}
${d.cajero ? fila('Atendió:', esc(d.cajero)) : ''}
${fiscal ? `${fila('Cliente:', esc(d.cliente?.nombre || 'Consumidor final'))}
${fila('RTN:', esc(d.cliente?.rtn || '—'))}`
  : d.cliente ? fila('Cliente:', esc(d.cliente.nombre)) : ''}
<hr>
${lineas.map(l => `<div class="it">
  <div class="n">${esc(l.producto)}${l.exento ? ' (E)' : ''}</div>
  ${fila(`${cant(l.cantidad)} x ${n2(l.precio)}`, n2(l.total))}
  ${Number(l.descuento) ? fila('  Descuento', '-' + n2(l.descuento)) : ''}
</div>`).join('')}
<hr>
${fiscal ? `
${fila('Importe exento', n2(des.exento))}
${fila('Importe exonerado', n2(0))}
${fila('Importe gravado 15%', n2(des.gravado15))}
${Number(des.gravado18) ? fila('Importe gravado 18%', n2(des.gravado18)) : ''}
${Number(v.descuento) ? fila('Descuento', '-' + n2(v.descuento)) : ''}
${fila('ISV 15%', n2(des.isv15))}
${Number(des.isv18) ? fila('ISV 18%', n2(des.isv18)) : ''}
` : `
${fila('Subtotal', n2(v.subtotal))}
${Number(v.impuesto) ? fila('Impuesto', n2(v.impuesto)) : ''}
${Number(v.descuento) ? fila('Descuento', '-' + n2(v.descuento)) : ''}
`}
${fila('TOTAL ' + esc(mon), n2(v.total), true).replace('class="f b"', 'class="f b g"')}
${fiscal ? `<div class="chico" style="margin-top:3px">Son: ${esc(numeroALetras(v.total))}</div>` : ''}
<hr>
${pagos.map(p => fila(esc(METODO[p.metodo] || p.metodo),
  n2(p.metodo === 'efectivo' && p.recibido ? p.recibido : p.monto))).join('')}
${cambio > 0 ? fila('Cambio', n2(cambio), true) : ''}
<hr>
${fiscal ? `<div class="c chico">
  No. correlativo de orden de compra exenta: ____<br>
  No. correlativo constancia de registro exonerado: ____<br>
  No. identificativo registro SAG: ____
</div><hr>` : ''}
<div class="c">${esc(neg.mensaje_ticket || '¡Gracias por su compra!')}</div>
${fiscal ? `<div class="c chico" style="margin-top:4px">La factura es beneficio de todos. Exíjala.</div>
<div class="c chico">${opciones.copia ? 'COPIA: EMISOR' : 'ORIGINAL: CLIENTE'}</div>` : ''}
${anulada ? `<div class="anulada">ANULADA</div>` : ''}
</body></html>`;
}

/* Imprime en un iframe escondido. Devuelve cuando el dialogo de impresion
   se cerro (o al ratito, en navegadores que no avisan). */
export function imprimirTicket(datos, opciones = {}){
  return new Promise(resolver => {
    const marco = document.createElement('iframe');
    marco.setAttribute('aria-hidden', 'true');
    marco.style.cssText = 'position:fixed;right:0;bottom:0;width:0;height:0;border:0;visibility:hidden';
    document.body.appendChild(marco);

    const fin = () => { setTimeout(() => { marco.remove(); resolver(); }, 300); };
    const doc = marco.contentDocument || marco.contentWindow?.document;
    doc.open();
    doc.write(htmlTicket(datos, opciones));
    doc.close();

    const w = marco.contentWindow;
    const disparar = () => {
      try{
        w.focus();
        w.onafterprint = fin;
        w.print();
        // Safari y algunos Android no disparan onafterprint
        setTimeout(fin, 60000);
      }catch(e){ fin(); }
    };
    // Esperar a que el documento se pinte antes de imprimir
    if (doc.readyState === 'complete') setTimeout(disparar, 120);
    else marco.onload = () => setTimeout(disparar, 120);
  });
}
