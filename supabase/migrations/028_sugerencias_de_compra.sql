-- ===========================================================================
-- 028 · Sugerencias de compra
--
-- Contesta "¿que le pido a este proveedor hoy, y cuanto?" con la cuenta que
-- hace un comprador de supermercado:
--
--   venta diaria   lo vendido en los ultimos N dias (ventas menos
--                  devoluciones), dividido entre los dias en que HUBO
--                  producto. Un dia agotado no vendio cero porque nadie lo
--                  quisiera; contarlo bajaria el promedio y la sugerencia
--                  volveria a quedarse corta. Es el error clasico.
--
--   disponible     existencia - lo apartado por pedidos + lo que ya viene en
--                  una compra en borrador (ya se pidio, aun no entra)
--
--   punto de pedido   venta diaria x dias de entrega del proveedor
--                     + stock minimo
--                     Si lo disponible esta en o debajo de esto, hay que
--                     pedir: lo que queda no alcanza a que llegue lo nuevo.
--
--   objetivo       venta diaria x (dias de entrega + dias de cobertura del
--                  producto) + stock minimo, sin pasar del stock maximo
--
--   sugerido       objetivo - disponible, redondeado hacia ARRIBA a la caja
--                  del proveedor (la presentacion de compra o las unidades
--                  por caja del producto): no se puede pedir media caja.
--
-- Prioridad:
--   agotado    no hay nada disponible
--   urgente    se acaba antes de que llegue el pedido
--   pedir      bajo el punto de pedido
--
-- Productos sin venta en el periodo solo se sugieren si estan bajo su stock
-- minimo (para no llenar la bodega de cosas que no se mueven).
--
-- Permisos: supervisor en adelante (es quien recibe y pide). El costo
-- estimado solo lo ve el gerente, igual que en el resto del sistema.
-- ===========================================================================

create or replace function fn_sugerencias_compra(
  p_sucursal_id  uuid default null,
  p_proveedor_id uuid default null,
  p_dias         int  default 28,
  p_categoria_id uuid default null,
  p_todos        boolean default false    -- true: incluye los que no hace falta pedir
) returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org   uuid;
  v_tz    text;
  v_suc   uuid;
  v_ve    boolean;
  v_dias  int;
  v_hoy   date;
  v_ini   timestamptz;
  v_fin   timestamptz;
  r       jsonb;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('supervisor'))) then
    raise exception 'Las sugerencias de compra son para supervisor en adelante';
  end if;

  v_suc  := app.sucursal_para_reporte(p_sucursal_id);
  v_tz   := app.zona(v_org);
  v_ve   := app.es_admin() or app.tiene_nivel('gerente');
  v_dias := least(greatest(coalesce(p_dias, 28), 7), 120);
  v_hoy  := (now() at time zone v_tz)::date;
  -- El periodo termina AYER: el dia de hoy va a medias y bajaria el promedio
  v_ini  := (v_hoy - v_dias)::timestamp at time zone v_tz;
  v_fin  := v_hoy::timestamp at time zone v_tz;

  if p_proveedor_id is not null then
    perform 1 from proveedores where id = p_proveedor_id and organizacion_id = v_org;
    if not found then raise exception 'Ese proveedor no es de su negocio'; end if;
  end if;

  with
  prods as materialized (
    select p.id, p.nombre, p.sku, p.unidad_base, p.proveedor_id,
           p.stock_minimo, p.stock_maximo, p.unidades_empaque,
           coalesce(nullif(p.dias_cobertura, 0), 15) as cobertura,
           c.nombre as categoria
    from productos p
    left join categorias c on c.id = p.categoria_id
    where p.organizacion_id = v_org and p.activo and p.se_compra and p.tipo <> 'servicio'
      and (p_proveedor_id is null or p.proveedor_id = p_proveedor_id)
      and (p_categoria_id is null or p.categoria_id = p_categoria_id
           or c.padre_id = p_categoria_id)
  ),
  -- Venta neta por dia en el periodo
  ventas_dia as (
    select k.producto_id, (k.ocurrido_en at time zone v_tz)::date as dia,
           sum(-k.cantidad) as u
    from kardex k
    where k.sucursal_id = v_suc
      and k.tipo in ('venta', 'devolucion_venta')
      and k.ocurrido_en >= v_ini and k.ocurrido_en < v_fin
      and k.producto_id in (select id from prods)
    group by 1, 2
  ),
  -- Dias en que hubo producto: el saldo al abrir era positivo o se vendio
  -- algo. Se saca del saldo corrido del kardex, sin fotos diarias.
  dias_con as (
    select pr.id as producto_id, count(*)::int as n
    from prods pr
    cross join generate_series(v_hoy - v_dias, v_hoy - 1, interval '1 day') g(d)
    where exists (select 1 from ventas_dia v where v.producto_id = pr.id and v.dia = g.d::date and v.u > 0)
       or coalesce((select k.saldo_cantidad from kardex k
                     where k.producto_id = pr.id and k.sucursal_id = v_suc
                       and k.ocurrido_en < (g.d::date)::timestamp at time zone v_tz
                     order by k.ocurrido_en desc, k.id desc limit 1), 0) > 0
    group by pr.id
  ),
  base as (
    select pr.*,
           coalesce((select sum(v.u) from ventas_dia v where v.producto_id = pr.id), 0) as vendido,
           coalesce(dc.n, 0) as dias_con,
           coalesce((select sum(e.cantidad) from existencias e
                      where e.producto_id = pr.id and e.sucursal_id = v_suc), 0) as existencia,
           coalesce((select sum(rv.cantidad) from pedido_reservas rv
                      where rv.producto_id = pr.id and rv.sucursal_id = v_suc
                        and rv.liberada_en is null), 0) as apartado,
           -- Lo que ya se registro en una compra en borrador
           coalesce((select sum(d.cantidad * coalesce(ps.factor, 1))
                      from factura_compra_detalle d
                      join facturas_compra f on f.id = d.factura_compra_id
                      left join presentaciones ps on ps.id = d.presentacion_id
                      where d.producto_id = pr.id and f.sucursal_id = v_suc
                        and f.estado = 'borrador'), 0) as en_camino,
           pv.nombre as proveedor,
           coalesce(pv.dias_entrega, 3) as dias_entrega,
           pv.dia_visita,
           -- La caja en que se compra: la presentacion de compra, o las
           -- unidades por caja del producto, o de una en una.
           (select jsonb_build_object('id', ps.id, 'nombre', ps.nombre, 'factor', ps.factor)
              from presentaciones ps
             where ps.producto_id = pr.id and ps.activa and ps.es_compra
             order by ps.factor desc limit 1) as presentacion,
           (select pc.ultimo_costo from producto_costos pc
             where pc.producto_id = pr.id and pc.sucursal_id = v_suc) as ultimo_costo
    from prods pr
    left join dias_con dc on dc.producto_id = pr.id
    left join proveedores pv on pv.id = pr.proveedor_id
  ),
  calc as (
    select b.*,
           -- Con menos de una semana de datos el promedio es puro ruido: se
           -- divide entre 7 como minimo.
           case when b.vendido > 0 then b.vendido / greatest(b.dias_con, 7) else 0 end as diario,
           b.existencia - b.apartado + b.en_camino as disponible,
           coalesce((b.presentacion->>'factor')::numeric,
                    nullif(b.unidades_empaque, 0), 1) as caja
    from base b
  ),
  plan as (
    select c.*,
           c.diario * c.dias_entrega + c.stock_minimo as punto,
           case when c.stock_maximo is not null and c.stock_maximo > 0
                then least(c.diario * (c.dias_entrega + c.cobertura) + c.stock_minimo, c.stock_maximo)
                else c.diario * (c.dias_entrega + c.cobertura) + c.stock_minimo end as objetivo
    from calc c
  ),
  fin as (
    select p.*,
           greatest(p.objetivo - p.disponible, 0) as falta,
           ceil(greatest(p.objetivo - p.disponible, 0) / p.caja) as cajas,
           case
             when p.diario = 0 and p.disponible > p.stock_minimo then 'ok'
             when p.diario = 0 and p.stock_minimo = 0 then 'ok'
             when p.disponible <= 0 then 'agotado'
             when p.diario > 0 and p.disponible < p.diario * p.dias_entrega then 'urgente'
             when p.disponible <= p.punto then 'pedir'
             else 'ok' end as estado,
           case when p.diario > 0 then floor(greatest(p.disponible, 0) / p.diario) end as dias_alcanza
    from plan p
  ),
  lista as (
    select f.* from fin f
    where (coalesce(p_todos, false) and (f.vendido > 0 or f.existencia <> 0 or f.stock_minimo > 0))
       or (f.estado <> 'ok' and f.cajas > 0)
  )
  select jsonb_build_object(
    'sucursal_id', v_suc,
    'sucursal', (select nombre from sucursales where id = v_suc),
    'dias', v_dias,
    'desde', v_hoy - v_dias,
    'hasta', v_hoy - 1,
    'puede_ver_costos', v_ve,
    'resumen', jsonb_build_object(
      'productos', (select count(*) from lista where estado <> 'ok'),
      'agotados',  (select count(*) from lista where estado = 'agotado'),
      'urgentes',  (select count(*) from lista where estado = 'urgente'),
      'costo',     case when v_ve then (select round(coalesce(sum(cajas * caja * coalesce(ultimo_costo, 0)), 0), 2)
                                         from lista where estado <> 'ok') end),
    'proveedores', coalesce((
      select jsonb_agg(g.j order by g.orden, g.nombre)
      from (
        select coalesce(l.proveedor, 'Sin proveedor habitual') as nombre,
               case when l.proveedor_id is null then 1 else 0 end as orden,
               jsonb_build_object(
                 'proveedor_id', l.proveedor_id,
                 'proveedor', coalesce(l.proveedor, 'Sin proveedor habitual'),
                 'dias_entrega', max(l.dias_entrega),
                 'dia_visita', (select to_jsonb(pv.dia_visita) from proveedores pv where pv.id = l.proveedor_id),
                 'costo', case when v_ve then round(sum(case when l.estado <> 'ok'
                                then l.cajas * l.caja * coalesce(l.ultimo_costo, 0) else 0 end), 2) end,
                 'items', jsonb_agg(jsonb_build_object(
                    'producto_id', l.id,
                    'nombre', l.nombre,
                    'sku', l.sku,
                    'unidad', l.unidad_base,
                    'categoria', l.categoria,
                    'estado', l.estado,
                    'vendido', l.vendido,
                    'dias_con_producto', l.dias_con,
                    'venta_diaria', round(l.diario, 2),
                    'existencia', l.existencia,
                    'apartado', l.apartado,
                    'en_camino', l.en_camino,
                    'disponible', l.disponible,
                    'dias_alcanza', l.dias_alcanza,
                    'stock_minimo', l.stock_minimo,
                    'stock_maximo', l.stock_maximo,
                    'punto_pedido', round(l.punto, 1),
                    'objetivo', round(l.objetivo, 1),
                    'cobertura', l.cobertura,
                    'caja', l.caja,
                    'presentacion', l.presentacion,
                    'cajas', l.cajas,
                    'unidades', l.cajas * l.caja,
                    'ultimo_costo', case when v_ve then l.ultimo_costo end,
                    'costo', case when v_ve then round(l.cajas * l.caja * coalesce(l.ultimo_costo, 0), 2) end)
                    order by case l.estado when 'agotado' then 0 when 'urgente' then 1
                                           when 'pedir' then 2 else 3 end,
                             l.dias_alcanza nulls first, l.nombre)) as j
        from lista l
        group by l.proveedor_id, l.proveedor) g), '[]'::jsonb)
  ) into r;

  return r;
end $fn$;

revoke execute on function fn_sugerencias_compra(uuid, uuid, int, uuid, boolean) from public, anon;
grant execute on function fn_sugerencias_compra(uuid, uuid, int, uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
