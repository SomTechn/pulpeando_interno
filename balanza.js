/* ==========================================================================
   Etiquetas de balanza.

   La balanza imprime un EAN-13 que empieza con 2:

       2 3  0 0 1 2 5  0 1 2 5 0  7
       └┬┘  └───┬───┘  └───┬───┘  └ control
     prefijo   PLU       peso o precio

   · prefijo: 2 dígitos (20–29; cada balanza deja escoger)
   · PLU: el número del producto en la balanza. Aquí es el item de 5 dígitos
     del producto (o cualquiera de sus códigos), con o sin ceros delante.
   · el valor: lo que queda (10 − largo del PLU dígitos). Según la balanza es
     el PESO (con N decimales: 01250 con 3 decimales = 1.250) o el PRECIO
     (con 2 decimales: 01250 = L 12.50, y la cantidad sale de dividir entre
     el precio del producto).

   La forma la escoge el negocio en Configuración y llega en
   ctx.organizacion.balanza. Se prueba solo el código exacto primero: los
   productos de muestra tienen códigos 21x que también empiezan con 2.
   ========================================================================== */

/* Dígito de control de un EAN-13 (sobre los 12 primeros). */
export function digitoEan13(doce){
  let s = 0;
  for (let i = 0; i < 12; i++) s += Number(doce[i]) * (i % 2 ? 3 : 1);
  return (10 - (s % 10)) % 10;
}

/* "20-29" · "20,21,28" · "23" → lista de prefijos de dos dígitos. */
export function prefijosDe(txt){
  const out = new Set();
  for (const parte of String(txt || '20-29').split(',')){
    const m = parte.trim().match(/^(\d{2})(?:\s*-\s*(\d{2}))?$/);
    if (!m) continue;
    const a = Number(m[1]), b = m[2] ? Number(m[2]) : a;
    for (let n = Math.min(a, b); n <= Math.max(a, b); n++)
      if (n >= 20 && n <= 29) out.add(String(n));
  }
  return out;
}

/* Desarma la etiqueta. Devuelve null si no es de balanza con esa forma, o
   { plu, valor, tipo } con valor ya en unidades (kg/lb o lempiras). */
export function leerBalanza(cod, cfg){
  if (!cfg || !cfg.activa) return null;
  const c = String(cod || '').trim();
  if (!/^\d{13}$/.test(c)) return null;
  if (!prefijosDe(cfg.prefijos).has(c.slice(0, 2))) return null;
  if (digitoEan13(c) !== Number(c[12])) return null;
  const largo = Math.min(Math.max(Number(cfg.largo_plu) || 5, 4), 6);
  const plu = c.slice(2, 2 + largo);
  const crudo = Number(c.slice(2 + largo, 12));
  const tipo = cfg.tipo === 'precio' ? 'precio' : 'peso';
  const dec = tipo === 'precio' ? 2 : Math.min(Math.max(Number(cfg.decimales ?? 3), 0), 3);
  const valor = crudo / Math.pow(10, dec);
  if (!(valor > 0)) return null;
  return { plu, valor, tipo };
}

/* Busca el producto del PLU en el catálogo de la caja: por item o por
   código, ignorando ceros delante. */
export function productoDelPlu(plu, catalogo){
  const sin = s => String(s || '').replace(/^0+/, '');
  const p = sin(plu);
  if (!p) return null;
  return (catalogo || []).find(x => sin(x.sku) === p || (x.codigos || []).some(k => sin(k) === p)) || null;
}

/* Todo junto: lo que hay que agregar al ticket, o null.
   { producto, cantidad, etiqueta } — la cantidad con tres decimales. */
export function lineaDeBalanza(cod, cfg, catalogo){
  const l = leerBalanza(cod, cfg);
  if (!l) return null;
  const producto = productoDelPlu(l.plu, catalogo);
  if (!producto) return { producto:null, plu:l.plu };
  let cantidad;
  if (l.tipo === 'peso') cantidad = l.valor;
  else {
    const precio = Number(producto.precio);
    if (!(precio > 0)) return { producto, cantidad:0, plu:l.plu };
    cantidad = l.valor / precio;
  }
  cantidad = Math.round(cantidad * 1000) / 1000;
  return { producto, cantidad, plu:l.plu, monto: l.tipo === 'precio' ? l.valor : null };
}
