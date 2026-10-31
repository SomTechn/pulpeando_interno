/* ==========================================================================
   La cuenta de las promociones, del lado de la caja.

   Es la MISMA cuenta que hace el servidor en app.descuentos_promo (migración
   042): la caja la hace para enseñar el descuento antes de cobrar, y el
   servidor la vuelve a hacer al registrar la venta, que es la que vale.
   Para que den el mismo centavo, las dos trabajan con enteros: precios en
   centavos y cantidades en milésimas.

     calcularPromos(lineas, promos)
       lineas  [{ producto_id, cantidad, precio }] en el orden del ticket
       promos  lo que devuelve fn_promociones_activas, ya ordenado
       →       { descuentos:[número por línea], porLinea:[[ids]], aplicadas:[{id, nombre, descuento}] }

   Tipos:
     nxm         lleva N paga M: en cada grupo de N unidades (de la más cara
                 a la más barata) las N−M más baratas salen gratis
     paquete     N unidades por un precio fijo; el descuento se reparte
                 entre las unidades según su precio
     porcentaje  rebaja el % a toda la cantidad que quede
   ========================================================================== */

const centavos = v => Math.round(Number((Number(v) * 100).toFixed(6)));
const milesimas = v => Math.round(Number((Number(v) * 1000).toFixed(6)));

export function calcularPromos(lineas = [], promos = []){
  const n = lineas.length;
  const ids  = lineas.map(l => l.producto_id);
  const prc  = lineas.map(l => centavos(l.precio || 0));
  const rest = lineas.map(l => milesimas(l.cantidad || 0));
  const dsc  = lineas.map(() => 0);
  const quien = lineas.map(() => []);
  const aplicadas = [];
  const marcar = (i, id) => { if (!quien[i].includes(id)) quien[i].push(id); };

  for (const pr of promos){
    const cubre = new Set(pr.producto_ids || []);
    const sel = [];
    for (let i = 0; i < n; i++)
      if (rest[i] > 0 && prc[i] > 0 && cubre.has(ids[i])) sel.push(i);
    if (!sel.length) continue;
    let dprom = 0;

    if (pr.tipo === 'porcentaje'){
      const pct = BigInt(Math.round(Number(pr.porcentaje) * 100));
      for (const i of sel){
        // milésimas × centavos × centésimas de %, redondeado a la mitad (como el servidor)
        const num = BigInt(rest[i]) * BigInt(prc[i]) * pct;
        const d = Number((num * 2n + 10000000n) / 20000000n);
        dsc[i] += d; dprom += d;
        if (d > 0) marcar(i, pr.id);
        rest[i] = 0;
      }
    } else {
      const lleva = Number(pr.lleva);
      const u = [];
      for (const i of sel)
        for (let g = 1; g <= Math.floor(rest[i] / 1000); g++) u.push({ i, p:prc[i], g });
      u.sort((a, b) => b.p - a.p || a.i - b.i || a.g - b.g);
      const grupos = Math.floor(u.length / lleva);
      for (let g = 0; g < grupos; g++){
        const grupo = u.slice(g * lleva, g * lleva + lleva).map(x => x.i);
        if (pr.tipo === 'nxm'){
          for (let k = Number(pr.paga); k < lleva; k++){
            const i = grupo[k];
            dsc[i] += prc[i]; dprom += prc[i];
            marcar(i, pr.id);
          }
        } else {
          const tot = grupo.reduce((s, i) => s + prc[i], 0);
          const d = tot - centavos(pr.precio_paquete);
          if (d > 0){
            let repartido = 0;
            grupo.forEach((i, k) => {
              if (k < lleva - 1){
                const parte = Math.floor((d * prc[i]) / tot);
                dsc[i] += parte; repartido += parte;
              } else dsc[i] += d - repartido;
              marcar(i, pr.id);
            });
            dprom += d;
          }
        }
        for (const i of grupo) rest[i] -= 1000;
      }
    }
    if (dprom > 0) aplicadas.push({ id:pr.id, nombre:pr.nombre, descuento:dprom / 100 });
  }

  return { descuentos:dsc.map(c => c / 100), porLinea:quien, aplicadas };
}

/* Cómo se le dice a la cajera y al cliente, en corto. */
export function nombreCorto(pr){
  if (pr.tipo === 'nxm') return `${pr.lleva}x${pr.paga}`;
  if (pr.tipo === 'paquete') return `${pr.lleva} por L ${Number(pr.precio_paquete).toLocaleString('es-HN', { minimumFractionDigits:2, maximumFractionDigits:2 })}`;
  return `−${Number(pr.porcentaje).toLocaleString('es-HN', { maximumFractionDigits:2 })}%`;
}
