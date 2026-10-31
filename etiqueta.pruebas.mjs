/* Prueba de la etiqueta de estante: que las barras sean las que la pistola
   lee, y que la etiqueta lleve lo que tiene que llevar.

   Los patrones de referencia salen de python-barcode, una implementacion
   aparte: si las dos coinciden, el dibujo es el del estandar y no una
   interpretacion nuestra. */
import { digitoGS1, modulosEAN13, modulosEAN8, modulosCode128, elegirCodigo,
         barrasSVG, htmlEtiqueta, TAMANOS } from './etiqueta.js';

let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };
const texto = h => h.replace(/<style[\s\S]*?<\/style>/, '').replace(/<svg[\s\S]*?<\/svg>/g, '')
                    .replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');

const REF = {
  e13_4006381333931: '10100011010100111010111101111010001001011001101010100001010000101000010111010010000101100110101',
  e8_96385074:       '1010001011010111101111010110111010101001110111001010001001011100101',
  c128_P1:           '110100100001110111011010011100110101111001001100011101011',
  c128_123456:       '11010011100101100111001000101100011100010110100011011101100011101011'
};

console.log('\n=== BARRAS ===');
chk('digito verificador EAN-13', digitoGS1('400638133393') === 1);
chk('digito verificador UPC', digitoGS1('01234567890') === 5);
chk('EAN-13 igual al de referencia', modulosEAN13('4006381333931') === REF.e13_4006381333931);
chk('EAN-13 mide 95 modulos', modulosEAN13('4006381333931').length === 95);
chk('EAN-8 igual al de referencia', modulosEAN8('96385074') === REF.e8_96385074);
chk('Code 128 B igual al de referencia', modulosCode128('P1') === REF.c128_P1);
chk('Code 128 C (digitos en pares) igual al de referencia', modulosCode128('123456') === REF.c128_123456);

console.log('\n=== QUE CODIGO LLEVA ===');
chk('13 digitos buenos: EAN-13', elegirCodigo('4006381333931').tipo === 'EAN-13');
chk('12 digitos buenos: UPC-A', elegirCodigo('012345678905').tipo === 'UPC-A');
chk('el UPC se dibuja como EAN-13 con 0', elegirCodigo('012345678905').modulos === modulosEAN13('0012345678905'));
chk('8 digitos buenos: EAN-8', elegirCodigo('96385074').tipo === 'EAN-8');
chk('verificador malo: Code 128, no un EAN falso', elegirCodigo('4006381333930').tipo === 'Code 128');
chk('sin codigo: el item en Code 128', elegirCodigo('', 'LCH-001').texto === 'LCH-001');
chk('sin nada: no hay barras', elegirCodigo('', '') === null);

const svg = barrasSVG(REF.e8_96385074);
chk('el SVG tiene un rect por cada barra', (svg.match(/<rect/g) || []).length === 22);
chk('sin bordes difusos', /crispEdges/.test(svg));

console.log('\n=== LA ETIQUETA ===');
const D = { nombre:'Salsa BBQ Original 18 oz', sku:'344470', unidad:'unidad',
            codigo:'4006381333931', precio:136, precio_regular:136, oferta:null };
{
  const h = htmlEtiqueta(D, { tamano:'60x40' });
  const t = texto(h);
  chk('descripcion', /Salsa BBQ Original 18 oz/.test(t));
  chk('item', /Item 344470/.test(t));
  chk('digitos debajo de las barras', /4006381333931/.test(t));
  chk('precio partido L 136 .00', /L 136 \.00/.test(t));
  chk('sin oferta no dice OFERTA', !/OFERTA/.test(t));
  chk('pagina de 60 x 40 mm', /size: 60mm 40mm/.test(h));
  chk('una sola etiqueta', (h.match(/class="et /g) || []).length === 1);
}
{
  const h = htmlEtiqueta({ ...D, precio:119.5, oferta:{ precio:119.5, hasta:'2026-11-06' } },
                         { tamano:'50x30', copias:4 });
  const t = texto(h);
  chk('oferta: dice OFERTA', /OFERTA/.test(t));
  chk('oferta: precio nuevo', /L 119 \.50/.test(t));
  chk('oferta: el de antes', /Antes L 136\.00/.test(t));
  chk('oferta: hasta cuando', /Válido hasta el 06\/11\/26/.test(t));
  chk('cuatro copias, una por pagina', (h.match(/class="et oferta"/g) || []).length === 4);
  chk('pagina de 50 x 30', /size: 50mm 30mm/.test(h));
  chk('en termica la oferta va en negro', /\.et\.oferta \.et-precio\{background:#000/.test(h));
}
{
  const h = htmlEtiqueta(D, { tamano:'carta', copias:21 });
  chk('carta: hoja carta', /size: letter/.test(h));
  chk('carta: 3 columnas', /grid-template-columns:repeat\(3/.test(h));
  chk('carta: precio en amarillo', /#ffd60a/.test(h));
  chk('carta: vista previa sin la hoja', !/class="hoja"/.test(htmlEtiqueta(D, { tamano:'carta', vista:true })));
  chk('copias con tope', (htmlEtiqueta(D, { copias:5000 }).match(/class="et /g) || []).length === 200);
  chk('tres tamanos', Object.keys(TAMANOS).length === 3);
}
{
  const h = htmlEtiqueta({ ...D, nombre:'<b>x</b>' });
  chk('el nombre se escapa', /&lt;b&gt;x&lt;\/b&gt;/.test(h));
}

console.log(`\n${ok} bien · ${mal} mal`);
process.exit(mal ? 1 : 0);
