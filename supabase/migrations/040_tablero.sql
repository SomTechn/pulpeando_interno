-- ============================================================================
--  Migración 040 · El tablero del dueño
--
--  Una sola llamada, fn_tablero(desde, hasta, sucursal), trae lo que el dueño
--  de una abarrotería quiere ver al llegar: cuánto vendió y cuánto ganó de
--  verdad, contra el período anterior; a qué hora y qué día se vende; qué
--  productos y categorías dejan la plata; cuánto dinero hay parado en la
--  bodega y cuánto de eso no se mueve; lo vencido; lo que le deben (fiado) y
--  lo que debe (facturas de proveedor); la merma; y lo que pasó en las cajas.
--
--  REGLAS DE LAS CIFRAS
--
--    venta neta   = lo cobrado en ventas completadas − devoluciones
--    venta sin ISV= venta neta sin el impuesto: sobre esto se mide el margen,
--                   porque el ISV no es del negocio
--    utilidad     = venta sin ISV − costo de lo vendido (costo promedio al
--                   momento de la venta) − lo que se devolvió, a su costo
--    las anuladas no suman: se cuentan aparte, porque muchas anuladas en un
--    cajero es lo primero que se mira cuando falta plata
--
--  Las fechas son del día de Honduras (app.inicio_dia), no de UTC: la venta
--  de las 7 de la noche es de hoy, no de mañana.
--
--  Solo gerente o admin. Es la información más sensible del negocio.
--
--  ÍNDICES QUE FALTABAN
--
--    venta_detalle(venta_id) y pagos_venta(venta_id) no tenían índice. Con
--    una pulpería no se nota; con una abarrotería de 800 tickets diarios,
--    cada resumen de ventas recorría la tabla entera de líneas.
-- ============================================================================

create index if not exists ix_vd_venta     on venta_detalle (venta_id);
create index if not exists ix_pagos_venta  on pagos_venta (venta_id);
create index if not exists ix_devol_fecha  on devoluciones_venta (organizacion_id, creada_en);
create index if not exists ix_devdet_devol on devolucion_detalle (devolucion_id);


-- ---------------------------------------------------------------------------
-- Los totales de un período. Interna: no revisa permisos, la llama
-- fn_tablero, que sí los revisa. Se usa dos veces: el período y el anterior.
-- ---------------------------------------------------------------------------
create or replace function app.tablero_totales(
  p_org uuid, p_sucs uuid[], p_desde timestamptz, p_hasta timestamptz
) returns jsonb
language sql stable security definer set search_path = public, app as $fn$
  with v as (
    select ve.id, ve.total, ve.impuesto, ve.costo_total, ve.estado
      from ventas ve
     where ve.organizacion_id = p_org and ve.sucursal_id = any(p_sucs)
       and ve.creada_en >= p_desde and ve.creada_en < p_hasta
  ),
  d as (
    select coalesce(sum(dv.total), 0) as total,
           coalesce(sum(dv.subtotal), 0) as subtotal,
           coalesce(sum((select sum(dd.cantidad * coalesce(dd.costo_unitario, 0))
                           from devolucion_detalle dd where dd.devolucion_id = dv.id)), 0) as costo,
           count(*) as n
      from devoluciones_venta dv
     where dv.organizacion_id = p_org and dv.sucursal_id = any(p_sucs)
       and dv.creada_en >= p_desde and dv.creada_en < p_hasta
  ),
  t as (
    select count(*) filter (where estado = 'completada') as tickets,
           coalesce(sum(total) filter (where estado = 'completada'), 0) as bruto,
           coalesce(sum(total - impuesto) filter (where estado = 'completada'), 0) as sin_isv,
           coalesce(sum(costo_total) filter (where estado = 'completada'), 0) as costo,
           count(*) filter (where estado = 'anulada') as anuladas,
           coalesce(sum(total) filter (where estado = 'anulada'), 0) as monto_anulado
      from v
  ),
  u as (
    select coalesce(sum(vd.cantidad), 0) as unidades
      from venta_detalle vd join v on v.id = vd.venta_id and v.estado = 'completada'
  )
  select jsonb_build_object(
    'tickets',       t.tickets,
    'venta',         round(t.bruto - d.total, 2),
    'venta_sin_isv', round(t.sin_isv - d.subtotal, 2),
    'costo',         round(t.costo - d.costo, 2),
    'utilidad',      round((t.sin_isv - d.subtotal) - (t.costo - d.costo), 2),
    'margen',        case when t.sin_isv - d.subtotal > 0
                          then round(((t.sin_isv - d.subtotal) - (t.costo - d.costo))
                                     / (t.sin_isv - d.subtotal) * 100, 1) end,
    'ticket_promedio', case when t.tickets > 0 then round((t.bruto - d.total) / t.tickets, 2) end,
    'unidades',      u.unidades,
    'devuelto',      round(d.total, 2),
    'devoluciones',  d.n,
    'anuladas',      t.anuladas,
    'monto_anulado', round(t.monto_anulado, 2))
  from t, d, u
$fn$;

revoke execute on function app.tablero_totales(uuid, uuid[], timestamptz, timestamptz)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- fn_tablero
-- ---------------------------------------------------------------------------
create or replace function fn_tablero(
  p_desde date default null,
  p_hasta date default null,
  p_sucursal_id uuid default null
) returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org   uuid := app.org_id();
  v_tz    text;
  v_hoy   date;
  v_d     date;
  v_h     date;
  v_dias  int;
  v_ini   timestamptz;
  v_fin   timestamptz;
  v_sucs  uuid[];
  v_costo30 numeric;
  v_valor   numeric;
  r       jsonb;
begin
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('gerente'))) then
    raise exception 'El tablero es para el gerente o el dueño';
  end if;

  v_tz  := app.zona(v_org);
  v_hoy := (now() at time zone v_tz)::date;
  v_h   := least(coalesce(p_hasta, v_hoy), v_hoy);
  v_d   := coalesce(p_desde, v_h - 29);
  if v_d > v_h then
    raise exception 'La fecha de inicio es después de la final';
  end if;
  if v_h - v_d > 366 then
    raise exception 'El tablero llega hasta un año a la vez';
  end if;
  v_dias := v_h - v_d + 1;
  v_ini  := v_d::timestamp at time zone v_tz;
  v_fin  := (v_h + 1)::timestamp at time zone v_tz;

  if p_sucursal_id is not null then
    if not exists (select 1 from sucursales where id = p_sucursal_id and organizacion_id = v_org) then
      raise exception 'Esa sucursal no es de su negocio';
    end if;
    v_sucs := array[p_sucursal_id];
  else
    v_sucs := array(select id from sucursales where organizacion_id = v_org and activa);
  end if;

  -- costo de lo vendido en los últimos 30 días: con esto se sacan los días
  -- de inventario (cuántos días aguanta la bodega al ritmo de hoy)
  select coalesce(sum(ve.costo_total), 0) into v_costo30
    from ventas ve
   where ve.organizacion_id = v_org and ve.sucursal_id = any(v_sucs)
     and ve.estado = 'completada'
     and ve.creada_en >= ((v_hoy - 29)::timestamp at time zone v_tz);

  select coalesce(sum(pc.valor), 0) into v_valor
    from producto_costos pc
   where pc.organizacion_id = v_org and pc.sucursal_id = any(v_sucs);

  with
  vv as (   -- las ventas completadas del período, con su día y hora de Honduras
    select ve.id, ve.sucursal_id, ve.cajero_id, ve.total, ve.impuesto, ve.costo_total,
           (ve.creada_en at time zone v_tz) as local
      from ventas ve
     where ve.organizacion_id = v_org and ve.sucursal_id = any(v_sucs)
       and ve.estado = 'completada'
       and ve.creada_en >= v_ini and ve.creada_en < v_fin
  ),
  lin as (  -- las líneas, con la base sin ISV de cada una
    select vd.producto_id, vd.cantidad,
           case when vd.impuesto_incluido and coalesce(vd.tasa_impuesto, 0) > 0
                then vd.total / (1 + vd.tasa_impuesto) else vd.total end as base,
           vd.total,
           vd.cantidad * coalesce(vd.costo_unitario, 0) as costo
      from venta_detalle vd join vv on vv.id = vd.venta_id
  ),
  exis as ( -- existencia por producto y sucursal, sumando lotes
    select e.producto_id, e.sucursal_id, sum(e.cantidad) as cant
      from existencias e
     where e.organizacion_id = v_org and e.sucursal_id = any(v_sucs)
     group by e.producto_id, e.sucursal_id
  ),
  vendidos30 as (
    select distinct vd.producto_id
      from venta_detalle vd join ventas ve on ve.id = vd.venta_id
     where ve.organizacion_id = v_org and ve.sucursal_id = any(v_sucs)
       and ve.estado = 'completada'
       and ve.creada_en >= ((v_hoy - 29)::timestamp at time zone v_tz)
  ),
  movidos60 as (
    select distinct k.producto_id, k.sucursal_id
      from kardex k
     where k.organizacion_id = v_org and k.sucursal_id = any(v_sucs)
       and k.tipo = 'venta'
       and k.ocurrido_en >= ((v_hoy - 59)::timestamp at time zone v_tz)
  )
  select jsonb_build_object(
    'desde', v_d, 'hasta', v_h, 'dias', v_dias, 'hoy', v_hoy,
    'sucursal_id', p_sucursal_id,
    'sucursales', (select jsonb_agg(jsonb_build_object('id', s.id, 'nombre', s.nombre)
                                    order by s.es_principal desc, s.nombre)
                     from sucursales s where s.organizacion_id = v_org and s.activa),

    'periodo',  app.tablero_totales(v_org, v_sucs, v_ini, v_fin),
    'anterior', app.tablero_totales(v_org, v_sucs,
                  (v_d - v_dias)::timestamp at time zone v_tz, v_ini),
    'hoy_ventas', app.tablero_totales(v_org, v_sucs,
                  v_hoy::timestamp at time zone v_tz, (v_hoy + 1)::timestamp at time zone v_tz),

    -- un punto por día, también los días sin venta
    'por_dia', (select jsonb_agg(jsonb_build_object(
                   'fecha', g.dia::date, 'venta', round(coalesce(x.venta, 0), 2),
                   'utilidad', round(coalesce(x.util, 0), 2), 'tickets', coalesce(x.n, 0))
                   order by g.dia)
                  from generate_series(v_d, v_h, interval '1 day') g(dia)
                  left join (select local::date as dia, sum(total) as venta,
                                    sum(total - impuesto - costo_total) as util, count(*) as n
                               from vv group by 1) x on x.dia = g.dia::date),

    -- día de la semana (0 domingo) × hora: para saber cuándo poner más cajas
    'por_hora', coalesce((select jsonb_agg(jsonb_build_object(
                   'dow', dow, 'hora', hora, 'venta', round(venta, 2), 'tickets', n)
                   order by dow, hora)
                  from (select extract(dow from local)::int as dow,
                               extract(hour from local)::int as hora,
                               sum(total) as venta, count(*) as n
                          from vv group by 1, 2) h), '[]'::jsonb),

    'por_metodo', coalesce((select jsonb_agg(jsonb_build_object('metodo', metodo, 'monto', round(m, 2))
                                             order by m desc)
                  from (select pv.metodo, sum(pv.monto) as m
                          from pagos_venta pv join vv on vv.id = pv.venta_id
                         group by pv.metodo) p), '[]'::jsonb),

    'top_productos', coalesce((select jsonb_agg(jsonb_build_object(
                   'producto_id', pr.id, 'nombre', pr.nombre, 'sku', pr.sku,
                   'unidades', x.u, 'venta', round(x.venta, 2),
                   'utilidad', round(x.util, 2),
                   'margen', case when x.base > 0 then round(x.util / x.base * 100, 1) end)
                   order by x.venta desc)
                  from (select producto_id, sum(cantidad) as u, sum(total) as venta,
                               sum(base) as base, sum(base - costo) as util
                          from lin group by producto_id
                         order by sum(total) desc limit 10) x
                  join productos pr on pr.id = x.producto_id), '[]'::jsonb),

    -- lo que se vende con pérdida o casi: el precio quedó atrás del costo
    'margen_bajo', coalesce((select jsonb_agg(jsonb_build_object(
                   'producto_id', pr.id, 'nombre', pr.nombre, 'venta', round(x.venta, 2),
                   'margen', round(x.util / x.base * 100, 1))
                   order by x.util / x.base)
                  from (select producto_id, sum(total) as venta, sum(base) as base,
                               sum(base - costo) as util
                          from lin group by producto_id
                        having sum(base) > 0 and sum(costo) > 0
                           and sum(base - costo) / sum(base) < 0.08
                         order by sum(base - costo) / sum(base) limit 8) x
                  join productos pr on pr.id = x.producto_id), '[]'::jsonb),

    'por_categoria', coalesce((select jsonb_agg(jsonb_build_object(
                   'categoria', coalesce(c.nombre, 'Sin categoría'),
                   'venta', round(x.venta, 2), 'utilidad', round(x.util, 2))
                   order by x.venta desc)
                  from (select p.categoria_id, sum(l.total) as venta, sum(l.base - l.costo) as util
                          from lin l join productos p on p.id = l.producto_id
                         group by p.categoria_id) x
                  left join categorias c on c.id = x.categoria_id), '[]'::jsonb),

    'por_sucursal', coalesce((select jsonb_agg(jsonb_build_object(
                   'sucursal', s.nombre, 'venta', round(x.venta, 2),
                   'utilidad', round(x.util, 2), 'tickets', x.n)
                   order by x.venta desc)
                  from (select sucursal_id, sum(total) as venta,
                               sum(total - impuesto - costo_total) as util, count(*) as n
                          from vv group by sucursal_id) x
                  join sucursales s on s.id = x.sucursal_id), '[]'::jsonb),

    -- cajeros: lo vendido, lo anulado y lo que faltó o sobró al cerrar
    'por_cajero', coalesce((select jsonb_agg(jsonb_build_object(
                   'cajero', pf.nombre, 'codigo', pf.codigo,
                   'venta', round(coalesce(a.venta, 0), 2), 'tickets', coalesce(a.n, 0),
                   'ticket_promedio', case when a.n > 0 then round(a.venta / a.n, 2) end,
                   'anuladas', coalesce(b.n, 0), 'monto_anulado', round(coalesce(b.m, 0), 2),
                   'turnos', coalesce(c.t, 0), 'diferencia', round(coalesce(c.dif, 0), 2),
                   'faltante', round(coalesce(c.falt, 0), 2))
                   order by coalesce(a.venta, 0) desc)
                  from perfiles pf
                  left join (select cajero_id, sum(total) as venta, count(*) as n
                               from vv group by cajero_id) a on a.cajero_id = pf.id
                  left join (select ve.cajero_id, count(*) as n, sum(ve.total) as m
                               from ventas ve
                              where ve.organizacion_id = v_org and ve.sucursal_id = any(v_sucs)
                                and ve.estado = 'anulada'
                                and ve.creada_en >= v_ini and ve.creada_en < v_fin
                              group by ve.cajero_id) b on b.cajero_id = pf.id
                  left join (select tc.cajero_id, count(*) as t, sum(tc.diferencia) as dif,
                                    sum(least(tc.diferencia, 0)) as falt
                               from turnos_caja tc
                              where tc.organizacion_id = v_org and tc.sucursal_id = any(v_sucs)
                                and tc.estado = 'cerrado'
                                and tc.cerrado_en >= v_ini and tc.cerrado_en < v_fin
                              group by tc.cajero_id) c on c.cajero_id = pf.id
                 where pf.organizacion_id = v_org
                   and (a.n is not null or b.n is not null or c.t is not null)), '[]'::jsonb),

    'caja', (select jsonb_build_object(
                   'turnos', count(*),
                   'con_diferencia', count(*) filter (where abs(coalesce(diferencia, 0)) >= 1),
                   'faltante', round(coalesce(sum(least(diferencia, 0)), 0), 2),
                   'sobrante', round(coalesce(sum(greatest(diferencia, 0)), 0), 2),
                   'abiertos', (select count(*) from turnos_caja t2
                                 where t2.organizacion_id = v_org and t2.sucursal_id = any(v_sucs)
                                   and t2.estado = 'abierto'))
               from turnos_caja tc
              where tc.organizacion_id = v_org and tc.sucursal_id = any(v_sucs)
                and tc.estado = 'cerrado'
                and tc.cerrado_en >= v_ini and tc.cerrado_en < v_fin),

    -- el inventario es de HOY, no del período
    'inventario', jsonb_build_object(
       'valor_costo', round(v_valor, 2),
       'dias_inventario', case when v_costo30 > 0 then round(v_valor / (v_costo30 / 30), 0) end,
       'productos', (select count(distinct producto_id) from exis where cant > 0),
       'bajo_minimo', (select count(*) from exis e join productos p on p.id = e.producto_id
                        where p.activo and p.stock_minimo > 0 and e.cant > 0
                          and e.cant <= p.stock_minimo),
       -- agotado y que se vende: cada día así es venta que se va a la competencia
       'agotados', (select count(*) from (
                      select p.id from productos p
                       where p.organizacion_id = v_org and p.activo and p.se_vende
                         and p.id in (select producto_id from vendidos30)
                         and coalesce((select sum(cant) from exis e where e.producto_id = p.id), 0) <= 0) a),
       'agotados_lista', coalesce((select jsonb_agg(jsonb_build_object('producto_id', p.id, 'nombre', p.nombre))
                      from (select p.id, p.nombre from productos p
                             where p.organizacion_id = v_org and p.activo and p.se_vende
                               and p.id in (select producto_id from vendidos30)
                               and coalesce((select sum(cant) from exis e where e.producto_id = p.id), 0) <= 0
                             order by p.nombre limit 12) p), '[]'::jsonb),
       -- plata parada: hay existencia y no se vendió nada en 60 días
       'sin_movimiento', (select count(*) from exis e
                           where e.cant > 0
                             and not exists (select 1 from movidos60 m
                                              where m.producto_id = e.producto_id
                                                and m.sucursal_id = e.sucursal_id)),
       'valor_sin_movimiento', (select round(coalesce(sum(pc.valor), 0), 2)
                                  from exis e
                                  join producto_costos pc on pc.producto_id = e.producto_id
                                                         and pc.sucursal_id = e.sucursal_id
                                 where e.cant > 0
                                   and not exists (select 1 from movidos60 m
                                                    where m.producto_id = e.producto_id
                                                      and m.sucursal_id = e.sucursal_id))),

    'vencimientos', (select jsonb_build_object(
       'vencidos', count(*) filter (where l.fecha_vencimiento < v_hoy),
       'valor_vencido', round(coalesce(sum(e.cantidad * coalesce(pc.costo_promedio, l.costo_ingreso, 0))
                                       filter (where l.fecha_vencimiento < v_hoy), 0), 2),
       'por_vencer_30', count(*) filter (where l.fecha_vencimiento between v_hoy and v_hoy + 30),
       'valor_por_vencer_30', round(coalesce(sum(e.cantidad * coalesce(pc.costo_promedio, l.costo_ingreso, 0))
                                       filter (where l.fecha_vencimiento between v_hoy and v_hoy + 30), 0), 2))
       from existencias e
       join lotes l on l.id = e.lote_id
       left join producto_costos pc on pc.producto_id = e.producto_id and pc.sucursal_id = e.sucursal_id
      where e.organizacion_id = v_org and e.sucursal_id = any(v_sucs)
        and e.cantidad > 0 and l.fecha_vencimiento is not null),

    -- lo que le deben (el fiado es del negocio entero, no de una sucursal)
    'fiado', (select jsonb_build_object(
       'total', round(coalesce(sum(debe), 0), 2), 'clientes', count(*),
       'atrasado', round(coalesce(sum(debe) filter (where atrasado), 0), 2),
       'clientes_atrasados', count(*) filter (where atrasado),
       'mas_30', round(coalesce(sum(debe) filter (where dias > 30), 0), 2))
       from v_fiado where organizacion_id = v_org and debe > 0),

    -- lo que debe a proveedores
    'por_pagar', (select jsonb_build_object(
       'total', round(coalesce(sum(f.saldo), 0), 2), 'facturas', count(*),
       'vencido', round(coalesce(sum(f.saldo) filter (where f.fecha_vencimiento < v_hoy), 0), 2),
       'vence_7', round(coalesce(sum(f.saldo) filter (where f.fecha_vencimiento between v_hoy and v_hoy + 7), 0), 2))
       from facturas_compra f
      where f.organizacion_id = v_org and f.sucursal_id = any(v_sucs)
        and f.estado = 'confirmado' and f.saldo > 0),

    'compras', (select jsonb_build_object('total', round(coalesce(sum(f.total), 0), 2), 'facturas', count(*))
       from facturas_compra f
      where f.organizacion_id = v_org and f.sucursal_id = any(v_sucs)
        and f.estado = 'confirmado'
        and f.fecha between v_d and v_h),

    'merma', fn_merma_resumen(v_d, v_h, p_sucursal_id) - 'top' - 'dano' - 'desconocida' - 'sobrante',

    'ofertas_activas', (select count(distinct pr.producto_id) from precios pr
                         where pr.organizacion_id = v_org and pr.es_oferta
                           and pr.vigente_desde <= v_hoy and pr.vigente_hasta >= v_hoy)
  ) into r;

  return r;
end $fn$;

revoke execute on function fn_tablero(date, date, uuid) from public, anon;
grant  execute on function fn_tablero(date, date, uuid) to authenticated;

notify pgrst, 'reload schema';
