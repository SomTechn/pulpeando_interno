/* ==========================================================================
   La factura (o el comprobante) en PDF.

   Lo usa Ventas: «PDF» en el detalle de una venta. Sale del ancho del rollo
   (80 o 58 mm), con lo mismo que el ticket impreso: logo, datos del
   negocio, CAI y rango si es factura, las líneas, el desglose del ISV, el
   total en letras, los pagos y el código de barras para la devolución.

   Texto de verdad y barras dibujadas, no una foto del ticket: el PDF pesa
   poco, se lee nítido en el teléfono y la pistola lee las barras impresas.

   jsPDF se carga de esm.sh la primera vez que alguien pide un PDF, así no
   pesa en la pantalla de Ventas. Las pruebas le pasan el suyo.

   Uso:
     import { descargarPdf } from './ticket-pdf.js';
     await descargarPdf(datosDeFnVentaCompleta);
   ========================================================================== */

import { numeroALetras, partesCodigo, urlLogo, n2, cant, METODO, fechaHora, fecha } from './ticket.js';
import { modulosCode128 } from './etiqueta.js';

const JSPDF_URL = 'https://esm.sh/jspdf@2.5.2';

/* El logo como data URL, con su proporción. Si no carga, sin logo. */
async function cargarLogo(url){
  if (!url) return null;
  try{
    const r = await fetch(url, { mode:'cors' });
    if (!r.ok) return null;
    const blob = await r.blob();
    const datos = await new Promise((ok, mal) => {
      const fr = new FileReader();
      fr.onload = () => ok(fr.result); fr.onerror = mal;
      fr.readAsDataURL(blob);
    });
    const dim = await new Promise(ok => {
      const im = new Image();
      im.onload = () => ok({ w:im.naturalWidth, h:im.naturalHeight });
      im.onerror = () => ok(null);
      im.src = datos;
    });
    if (!dim) return null;
    const fmt = /png/i.test(blob.type) ? 'PNG' : /webp/i.test(blob.type) ? 'WEBP' : 'JPEG';
    return { datos, fmt, ...dim };
  }catch(e){ return null; }
}

/* Dibuja todo el ticket en doc y devuelve hasta dónde llegó (mm).
   Se corre dos veces: una para medir y otra en la hoja del alto justo. */
function dibujar(doc, d, op){
  const ancho = op.ancho;
  const m = ancho === 58 ? 3 : 4;                 // margen
  const W = ancho - m * 2;                        // ancho útil
  const fs = ancho === 58 ? 7.4 : 8.6;            // puntos
  const lh = fs * 0.3528 * 1.32;                  // alto de línea en mm
  const v = d.venta, neg = d.negocio || {}, suc = d.sucursal || {};
  const nc = v.documento === 'nota_credito';
  const dev = d.devolucion || null;
  const fiscal = (v.documento === 'factura' || nc) && v.numero_fiscal;
  const titulo = nc ? 'NOTA DE CRÉDITO' : v.documento === 'factura' ? 'FACTURA'
               : dev ? 'DEVOLUCIÓN' : 'COMPROBANTE';
  const mon = neg.moneda === 'HNL' || !neg.moneda ? 'L' : neg.moneda;
  const des = d.desglose || {};
  const pagos = d.pagos || [];
  const cambio = pagos.reduce((a, p) => a + (Number(p.cambio) || 0), 0);
  const anulada = v.estado === 'anulada';
  let y = m;

  const fuente = (tam = fs, negrita = false) => { doc.setFont('courier', negrita ? 'bold' : 'normal'); doc.setFontSize(tam); };
  const centro = (txt, tam = fs, negrita = false) => {
    if (!txt) return;
    fuente(tam, negrita);
    for (const l of doc.splitTextToSize(String(txt), W)){
      y += tam * 0.3528 * 1.32;
      doc.text(l, ancho / 2, y - lh * 0.25, { align:'center' });
    }
  };
  const izq = (txt, tam = fs, negrita = false) => {
    if (!txt) return;
    fuente(tam, negrita);
    for (const l of doc.splitTextToSize(String(txt), W)){
      y += tam * 0.3528 * 1.32;
      doc.text(l, m, y - lh * 0.25);
    }
  };
  const fila = (a, b, negrita = false, tam = fs) => {
    fuente(tam, negrita);
    const bw = doc.getTextWidth(String(b));
    const partes = doc.splitTextToSize(String(a), Math.max(W - bw - 2, W * 0.4));
    partes.forEach((l, i) => {
      y += tam * 0.3528 * 1.32;
      doc.text(l, m, y - lh * 0.25);
      if (i === 0) doc.text(String(b), ancho - m, y - lh * 0.25, { align:'right' });
    });
  };
  const raya = () => {
    y += lh * 0.45;
    doc.setLineDashPattern([0.8, 0.6], 0); doc.setLineWidth(0.2);
    doc.line(m, y, ancho - m, y);
    doc.setLineDashPattern([], 0);
    y += lh * 0.35;
  };
  const sello = txt => {
    y += 1;
    doc.setLineWidth(0.5); doc.rect(m, y, W, lh * 1.6);
    fuente(fs * 1.25, true);
    doc.text(txt, ancho / 2, y + lh * 1.15, { align:'center' });
    y += lh * 1.6 + 1;
  };

  // Logo
  if (op.logo){
    const maxW = W * 0.7, maxH = ancho === 58 ? 16 : 20;
    const k = Math.min(maxW / op.logo.w, maxH / op.logo.h);
    const w = op.logo.w * k, h = op.logo.h * k;
    try{ doc.addImage(op.logo.datos, op.logo.fmt, (ancho - w) / 2, y, w, h); y += h + 1.5; }catch(e){}
  }

  centro(neg.razon_social || neg.nombre, fs * 1.3, true);
  if (neg.razon_social && neg.razon_social !== neg.nombre) centro(neg.nombre);
  if (neg.rtn) centro('RTN: ' + neg.rtn);
  if (neg.direccion) centro(neg.direccion, fs * 0.9);
  if (suc.nombre) centro(suc.nombre + (suc.direccion ? ' · ' + suc.direccion : ''), fs * 0.9);
  if (suc.telefono || neg.telefono) centro('Tel. ' + (suc.telefono || neg.telefono), fs * 0.9);
  if (neg.correo) centro(neg.correo, fs * 0.9);
  raya();
  if (anulada) sello('ANULADA');

  centro(titulo, fs * 1.25, true);
  if (fiscal){
    centro('No. ' + v.numero_fiscal, fs, true);
    izq('CAI: ' + (v.cai || ''), fs * 0.9);
    if (d.rango){
      izq(`Rango autorizado: ${d.rango.desde} al ${d.rango.hasta}`, fs * 0.9);
      izq('Fecha límite de emisión: ' + fecha(d.rango.fecha_limite), fs * 0.9);
    }
  } else {
    centro(v.numero, fs, true);
    if (dev) centro('Devolución interna. No es nota de crédito.', fs * 0.9);
  }
  raya();
  fila('Fecha:', fechaHora(v.creada_en));
  if (d.caja) fila('Caja:', d.caja);
  if (d.cajero) fila('Atendió:', d.cajero);
  if (fiscal){
    fila('Cliente:', d.cliente?.nombre || 'Consumidor final');
    fila('RTN:', d.cliente?.rtn || '-');
  } else if (d.cliente) fila('Cliente:', d.cliente.nombre);
  if (dev){
    fila(nc ? 'Factura que corrige:' : 'Venta:', dev.referencia);
    izq('Motivo: ' + (dev.motivo || ''), fs * 0.9);
  }
  raya();

  for (const l of d.lineas || []){
    izq(l.producto + (l.exento ? ' (E)' : ''));
    fila(`${cant(l.cantidad)} x ${n2(l.precio)}`, n2(l.total));
    if (Number(l.descuento)) fila('  Descuento', '-' + n2(l.descuento));
    y += 0.5;
  }
  raya();

  if (fiscal){
    fila('Importe exento', n2(des.exento));
    fila('Importe exonerado', n2(0));
    fila('Importe gravado 15%', n2(des.gravado15));
    if (Number(des.gravado18)) fila('Importe gravado 18%', n2(des.gravado18));
    if (Number(v.descuento)) fila('Descuento', '-' + n2(v.descuento));
    fila('ISV 15%', n2(des.isv15));
    if (Number(des.isv18)) fila('ISV 18%', n2(des.isv18));
  } else {
    fila('Subtotal', n2(v.subtotal));
    if (Number(v.impuesto)) fila('Impuesto', n2(v.impuesto));
    if (Number(v.descuento)) fila('Descuento', '-' + n2(v.descuento));
  }
  y += 0.6;
  fila('TOTAL ' + mon, n2(v.total), true, fs * 1.25);
  if (fiscal) izq('Son: ' + numeroALetras(v.total), fs * 0.9);
  raya();

  if (dev){
    if (Number(dev.rebaja_fiado)) fila('Rebajado del fiado', n2(dev.rebaja_fiado));
    if (Number(dev.reembolso)) fila('Devuelto en ' + String(METODO[dev.metodo] || dev.metodo || '').toLowerCase(), n2(dev.reembolso), true);
  } else {
    for (const p of pagos)
      fila(METODO[p.metodo] || p.metodo, n2(p.metodo === 'efectivo' && p.recibido ? p.recibido : p.monto));
    if (cambio > 0) fila('Cambio', n2(cambio), true);
  }
  raya();

  if (fiscal && !nc){
    centro('No. correlativo de orden de compra exenta: ____', fs * 0.85);
    centro('No. correlativo constancia de registro exonerado: ____', fs * 0.85);
    centro('No. identificativo registro SAG: ____', fs * 0.85);
    raya();
  }

  // El código de barras: mismo paso por módulo que el impreso
  const pc = !anulada && !dev ? partesCodigo(v.codigo_barras) : null;
  if (pc){
    const mod = modulosCode128(pc.tienda + pc.cajero + pc.caja + pc.ticket);
    const paso = ancho === 58 ? 0.25 : 0.375;
    const total = (mod.length + 20) * paso;
    const alto = ancho === 58 ? 10 : 12;
    let x0 = (ancho - total) / 2 + 10 * paso;
    y += 1.5;
    for (let i = 0; i < mod.length;){
      if (mod[i] === '1'){
        let j = i; while (j < mod.length && mod[j] === '1') j++;
        doc.rect(x0 + i * paso, y, (j - i) * paso, alto, 'F');
        i = j;
      } else i++;
    }
    y += alto;
    // Los cuatro grupos con su nombre debajo, cada uno centrado en su grupo
    const grupos = [[pc.tienda, 'tienda'], [pc.cajero, 'cajero'], [pc.caja, 'caja'], [pc.ticket, 'ticket']];
    fuente(fs * 1.05, true);
    const sep = doc.getTextWidth(' ') * 1.4;
    const anchos = grupos.map(([g]) => doc.getTextWidth(g));
    let x = (ancho - (anchos.reduce((a, b) => a + b, 0) + sep * 3)) / 2;
    const yDig = y + fs * 1.05 * 0.3528 * 1.1;
    const yEtq = yDig + fs * 0.62 * 0.3528 * 1.35;
    grupos.forEach(([g, etq], i) => {
      const cx = x + anchos[i] / 2;
      fuente(fs * 1.05, true); doc.text(g, cx, yDig, { align:'center' });
      fuente(fs * 0.62, false); doc.text(etq, cx, yEtq, { align:'center' });
      x += anchos[i] + sep;
    });
    y = yEtq + lh * 0.4;
    centro('Conserve este ticket para cambios y devoluciones', fs * 0.85);
    raya();
  }

  if (dev){
    y += lh * 2;
    centro('______________________');
    centro('Recibí conforme', fs * 0.9);
  } else centro(neg.mensaje_ticket || '¡Gracias por su compra!');
  if (fiscal){
    if (!nc) centro('La factura es beneficio de todos. Exíjala.', fs * 0.85);
    centro(op.copia ? 'COPIA: EMISOR' : 'ORIGINAL: CLIENTE', fs * 0.85);
  }
  if (anulada) sello('ANULADA');
  return y + m;
}

/* El PDF listo (un jsPDF). opciones: ancho, copia, logoUrl, jsPDF */
export async function pdfTicket(d, opciones = {}){
  const jsPDF = opciones.jsPDF || (await import(/* @vite-ignore */ JSPDF_URL)).jsPDF;
  const ancho = Number(opciones.ancho || d.negocio?.ancho_ticket) === 58 ? 58 : 80;
  const logo = opciones.logo !== undefined ? opciones.logo
             : await cargarLogo(urlLogo(d.negocio || {}, opciones));
  const op = { ancho, logo, copia:!!opciones.copia };

  const borrador = new jsPDF({ unit:'mm', format:[ancho, 2000] });
  const alto = Math.ceil(dibujar(borrador, d, op));
  const doc = new jsPDF({ unit:'mm', format:[ancho, Math.max(alto, 60)] });
  const v = d.venta || {};
  doc.setProperties({ title:(v.numero_fiscal || v.numero || 'Ticket'), creator:'Pulpeando' });
  dibujar(doc, d, op);
  return doc;
}

export function nombreArchivo(d){
  const v = d.venta || {};
  const tipo = v.documento === 'factura' ? 'Factura' : v.documento === 'nota_credito' ? 'Nota de credito' : 'Ticket';
  return `${tipo} ${String(v.numero_fiscal || v.numero || '').replace(/[^\w-]+/g, '-')}.pdf`;
}

/* Descarga el PDF (o lo abre para compartir, según el teléfono). */
export async function descargarPdf(d, opciones = {}){
  const doc = await pdfTicket(d, opciones);
  doc.save(nombreArchivo(d));
  return doc;
}
