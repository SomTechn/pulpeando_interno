/* ==========================================================================
   Etiqueta de estante.
   La usa Consultar para imprimir la etiqueta de un producto.

   ¿CÓDIGO DE BARRAS O QR?
   De barras. La pistola de una pulpería es casi siempre lineal (1D): lee
   barras y no lee QR. El producto ya trae su EAN-13 o UPC de fábrica, y la
   etiqueta lo repite tal cual, así que la caja lo reconoce igual que el
   empaque. Si el producto no tiene código, se imprime el item (SKU) en
   Code 128, que la caja también busca.

     13 dígitos con verificador bueno  -> EAN-13
     12 dígitos con verificador bueno  -> UPC-A (se dibuja como EAN-13 con 0)
      8 dígitos con verificador bueno  -> EAN-8
     cualquier otra cosa               -> Code 128

   TAMAÑOS
     60x40  rollo térmico de etiquetas (el más común)
     50x30  rollo térmico chico
     carta  hoja carta, 3 x 7 etiquetas, para impresora normal (a color)

   La térmica imprime solo negro: el precio va en recuadro negro con letra
   blanca cuando es oferta. En hoja carta el precio va en recuadro amarillo,
   como la etiqueta de supermercado.

   Uso:
     import { imprimirEtiquetas, htmlEtiqueta, barrasSVG } from './etiqueta.js';
     const { data } = await sb.rpc('fn_etiqueta_producto', { p_producto_id:id });
     await imprimirEtiquetas(data, { tamano:'60x40', copias:3 });
   ========================================================================== */

const esc = s => String(s ?? '').replace(/[&<>"']/g, c =>
  ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

const n2 = v => (Number(v) || 0).toLocaleString('es-HN',
  { minimumFractionDigits:2, maximumFractionDigits:2 });

export const TAMANOS = {
  '60x40': { nombre:'Rollo 60 × 40 mm', ancho:60, alto:40, termica:true },
  '50x30': { nombre:'Rollo 50 × 30 mm', ancho:50, alto:30, termica:true },
  'carta': { nombre:'Hoja carta (3 × 7)', ancho:66, alto:36, termica:false }
};

/* ---------- dígito verificador GS1 (EAN/UPC) ---------- */
export function digitoGS1(sinVerificador){
  let suma = 0;
  const d = String(sinVerificador);
  for (let i = d.length - 1, peso = 3; i >= 0; i--, peso = 4 - peso)
    suma += Number(d[i]) * peso;
  return (10 - suma % 10) % 10;
}
const gs1Valido = c => /^\d+$/.test(c) && digitoGS1(c.slice(0, -1)) === Number(c.slice(-1));

/* ---------- EAN-13 / EAN-8 ---------- */
const L = ['0001101','0011001','0010011','0111101','0100011','0110001','0101111','0111011','0110111','0001011'];
const R = L.map(p => p.replace(/./g, b => b === '0' ? '1' : '0'));
const G = R.map(p => p.split('').reverse().join(''));
const PARIDAD = ['LLLLLL','LLGLGG','LLGGLG','LLGGGL','LGLLGG','LGGLLG','LGGGLL','LGLGLG','LGLGGL','LGGLGL'];

export function modulosEAN13(c){
  const d = c.split('').map(Number);
  const par = PARIDAD[d[0]];
  let m = '101';
  for (let i = 1; i <= 6; i++) m += (par[i - 1] === 'L' ? L : G)[d[i]];
  m += '01010';
  for (let i = 7; i <= 12; i++) m += R[d[i]];
  return m + '101';
}

export function modulosEAN8(c){
  const d = c.split('').map(Number);
  let m = '101';
  for (let i = 0; i < 4; i++) m += L[d[i]];
  m += '01010';
  for (let i = 4; i < 8; i++) m += R[d[i]];
  return m + '101';
}

/* ---------- Code 128 (B, o C si son puros dígitos en pares) ---------- */
const C128 = ('212222 222122 222221 121223 121322 131222 122213 122312 132212 221213 ' +
  '221312 231212 112232 122132 122231 113222 123122 123221 223211 221132 ' +
  '221231 213212 223112 312131 311222 321122 321221 312212 322112 322211 ' +
  '212123 212321 232121 111323 131123 131321 112313 132113 132311 211313 ' +
  '231113 231311 112133 112331 132131 113123 113321 133121 313121 211331 ' +
  '231131 213113 213311 213131 311123 311321 331121 312113 312311 332111 ' +
  '314111 221411 431111 111224 111422 121124 121421 141122 141221 112214 ' +
  '112412 122114 122411 142112 142211 241211 221114 413111 241112 134111 ' +
  '111242 121142 121241 114212 124112 124211 411212 421112 421211 212141 ' +
  '214121 412121 111143 111341 131141 114113 114311 411113 411311 113141 ' +
  '114131 311141 411131 211412 211214 211232 2331112').split(' ');

export function modulosCode128(texto){
  const t = String(texto);
  const soloDigitos = /^\d+$/.test(t) && t.length % 2 === 0 && t.length >= 4;
  const valores = [];
  if (soloDigitos){
    valores.push(105);                                   // Start C
    for (let i = 0; i < t.length; i += 2) valores.push(Number(t.substr(i, 2)));
  } else {
    valores.push(104);                                   // Start B
    for (const ch of t){
      const v = ch.charCodeAt(0) - 32;
      valores.push(v >= 0 && v <= 94 ? v : 31);          // fuera de rango -> '?'
    }
  }
  let suma = valores[0];
  for (let i = 1; i < valores.length; i++) suma += valores[i] * i;
  valores.push(suma % 103, 106);

  let m = '';
  for (const v of valores){
    const anchos = C128[v];
    for (let i = 0; i < anchos.length; i++)
      m += (i % 2 === 0 ? '1' : '0').repeat(Number(anchos[i]));
  }
  return m;
}

/* El código que va en la etiqueta y cómo se dibuja. */
export function elegirCodigo(codigo, sku){
  const c = String(codigo || '').trim();
  if (c.length === 13 && gs1Valido(c)) return { tipo:'EAN-13', texto:c, modulos:modulosEAN13(c) };
  if (c.length === 12 && gs1Valido(c)) return { tipo:'UPC-A', texto:c, modulos:modulosEAN13('0' + c) };
  if (c.length === 8  && gs1Valido(c)) return { tipo:'EAN-8', texto:c, modulos:modulosEAN8(c) };
  const t = c || String(sku || '').trim();
  if (!t) return null;
  return { tipo:'Code 128', texto:t, modulos:modulosCode128(t) };
}

/* Las barras como SVG: un rect por cada tramo negro. Escala a lo que mida
   su caja; crispEdges para que la térmica no las emborrone. */
export function barrasSVG(modulos, { alto = 40 } = {}){
  const q = 10;                                     // zona quieta a cada lado
  const ancho = modulos.length + q * 2;
  let rects = '';
  for (let i = 0; i < modulos.length;){
    if (modulos[i] === '1'){
      let j = i;
      while (j < modulos.length && modulos[j] === '1') j++;
      rects += `<rect x="${i + q}" y="0" width="${j - i}" height="${alto}"/>`;
      i = j;
    } else i++;
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${ancho} ${alto}"
    preserveAspectRatio="none" shape-rendering="crispEdges" fill="#000">${rects}</svg>`;
}

function fechaCorta(v){
  if (!v) return '';
  const [a, m, d] = String(v).slice(0, 10).split('-');
  return `${d}/${m}/${a.slice(2)}`;
}

/* Precio partido: "L 45" grande y ".50" chico arriba, como en el estante. */
function precioPartido(v){
  const [ent, dec] = n2(v).split('.');
  return `<span class="mon">L</span><span class="ent">${ent}</span><span class="dec">.${dec}</span>`;
}

/* ---------- una etiqueta ---------- */
export function etiquetaHTML(d){
  const cod = elegirCodigo(d.codigo, d.sku);
  const of = d.oferta;
  return `<div class="et ${of ? 'oferta' : ''}">
  <div class="et-desc">${esc(d.nombre)}</div>
  <div class="et-cuerpo">
    <div class="et-izq">
      ${cod ? `<div class="et-barras">${barrasSVG(cod.modulos)}</div>
      <div class="et-digitos">${esc(cod.texto)}</div>` : ''}
      <div class="et-item">Item <b>${esc(d.sku || '—')}</b>${d.unidad ? ' · ' + esc(d.unidad) : ''}</div>
    </div>
    <div class="et-precio">
      ${of ? '<div class="et-tag">OFERTA</div>' : ''}
      <div class="et-monto">${precioPartido(d.precio)}</div>
      ${of ? `<div class="et-antes">Antes L ${n2(d.precio_regular)}</div>` : ''}
    </div>
  </div>
  ${of ? `<div class="et-pie">Válido hasta el ${fechaCorta(of.hasta)}</div>` : ''}
</div>`;
}

/* ---------- el documento a imprimir ---------- */
export function htmlEtiqueta(datos, opciones = {}){
  const tam = TAMANOS[opciones.tamano] || TAMANOS['60x40'];
  const copias = Math.max(1, Math.min(200, Math.floor(Number(opciones.copias) || 1)));
  const color = !tam.termica;                 // hoja carta: impresora a color
  const carta = color && !opciones.vista;     // la vista previa enseña una sola
  // las letras crecen con la etiqueta: todo va en mm relativo al alto
  const k = tam.alto / 40;
  const una = etiquetaHTML(datos);
  const todas = Array.from({ length: copias }, () => una).join('');

  return `<!doctype html><html lang="es"><head><meta charset="utf-8">
<title>Etiqueta</title>
<style>
@page { size: ${carta ? 'letter' : `${tam.ancho}mm ${tam.alto}mm`}; margin: ${carta ? '12mm 8mm' : '0'}; }
*{box-sizing:border-box;margin:0;padding:0}
html,body{background:#fff;color:#000;font-family:Arial,Helvetica,sans-serif;
  -webkit-print-color-adjust:exact;print-color-adjust:exact}
${carta
  ? `.hoja{display:grid;grid-template-columns:repeat(3, ${tam.ancho}mm);grid-auto-rows:${tam.alto}mm;gap:0;justify-content:center}
     .et{border:0.2mm dashed #bbb}`
  : `${color ? '.et{border:0.2mm dashed #bbb}' : ''}
     .et{page-break-after:always;break-after:page}
     .et:last-child{page-break-after:auto;break-after:auto}`}
.et{width:${tam.ancho}mm;height:${tam.alto}mm;padding:${1.6*k}mm ${2*k}mm;overflow:hidden;
  display:flex;flex-direction:column;gap:${0.8*k}mm}
.et-desc{font-weight:700;font-size:${3.3*k}mm;line-height:1.12;max-height:${7.6*k}mm;overflow:hidden;
  display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;text-transform:uppercase}
.et-cuerpo{flex:1;display:flex;gap:${1.6*k}mm;min-height:0}
.et-izq{flex:1 1 55%;display:flex;flex-direction:column;justify-content:flex-end;min-width:0}
.et-barras{height:${12*k}mm}
.et-barras svg{width:100%;height:100%;display:block}
.et-digitos{font-family:"Courier New",monospace;font-size:${2.6*k}mm;letter-spacing:0.3mm;text-align:center;
  line-height:1.1}
.et-item{font-size:${2.4*k}mm;margin-top:${0.6*k}mm;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.et-precio{flex:0 0 45%;display:flex;flex-direction:column;align-items:center;justify-content:center;
  border:${0.5*k}mm solid #000;border-radius:${1.2*k}mm;padding:${0.6*k}mm;
  ${color ? 'background:#ffd60a;border-color:#ffd60a;' : ''}}
.et-monto{display:flex;align-items:flex-start;line-height:.9;font-weight:800;white-space:nowrap}
.et-monto .mon{font-size:${3.4*k}mm;margin:${0.8*k}mm ${0.5*k}mm 0 0}
.et-monto .ent{font-size:${(datos.precio >= 1000 ? 7.5 : 10)*k}mm;letter-spacing:-0.3mm}
.et-monto .dec{font-size:${3.6*k}mm;margin-top:${0.6*k}mm}
.et-tag{font-size:${2.6*k}mm;font-weight:800;letter-spacing:0.6mm;margin-bottom:${0.4*k}mm}
.et-antes{font-size:${2.4*k}mm;text-decoration:line-through;margin-top:${0.5*k}mm}
.et-pie{font-size:${2.2*k}mm;text-align:center;font-weight:700}
/* oferta en térmica: recuadro negro, letra blanca */
.et.oferta .et-precio{${color ? 'background:#e63946;border-color:#e63946;color:#fff' : 'background:#000;color:#fff'}}
</style></head><body>
${carta ? `<div class="hoja">${todas}</div>` : todas}
</body></html>`;
}

/* Imprime en un iframe escondido, como el ticket. */
export function imprimirEtiquetas(datos, opciones = {}){
  return new Promise(resolver => {
    const marco = document.createElement('iframe');
    marco.setAttribute('aria-hidden', 'true');
    marco.style.cssText = 'position:fixed;right:0;bottom:0;width:0;height:0;border:0;visibility:hidden';
    document.body.appendChild(marco);

    const fin = () => { setTimeout(() => { marco.remove(); resolver(); }, 300); };
    const doc = marco.contentDocument || marco.contentWindow?.document;
    doc.open();
    doc.write(htmlEtiqueta(datos, opciones));
    doc.close();

    const w = marco.contentWindow;
    const disparar = () => {
      try{
        w.focus();
        w.onafterprint = fin;
        w.print();
        setTimeout(fin, 60000);
      }catch(e){ fin(); }
    };
    if (doc.readyState === 'complete') setTimeout(disparar, 120);
    else marco.onload = () => setTimeout(disparar, 120);
  });
}
