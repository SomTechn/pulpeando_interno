-- ===========================================================================
-- 024 · Bodega desde la consulta
--
-- Dos cambios chicos que habilitan la hoja de bodega en Consultar:
--
--   1. fn_consultar_producto ahora dice de QUE TIPO es cada ubicacion.
--      La pantalla necesita saber cual es bodega y cual es piso para ofrecer
--      "bajar al piso" en una y "cargar a bodega" en la otra. Antes solo
--      venia el nombre, y adivinar por el nombre ("Bodega de arriba" si,
--      "Cuarto frio" quien sabe) es exactamente el tipo de suposicion que
--      despues se rompe en el negocio de alguien.
--
--   2. fn_mover_entre_ubicaciones ya no toca una ubicacion con auditoria
--      abierta. Si alguien esta contando la bodega y al mismo tiempo otro
--      baja mercaderia de ahi, lo contado deja de corresponder con lo que
--      hay: el auditor ya conto esas cajas y el sistema ya las movio. El
--      conteo quedaria inflado sin que nadie se entere.
--
-- Ninguna tabla cambia.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. El tipo de cada ubicacion en la consulta
--
-- Se reemplaza entera porque plpgsql no deja parchar un pedazo. El unico
-- cambio real esta en el bloque 'ubicaciones'.
-- ---------------------------------------------------------------------------
create or replace function fn_consultar_producto(
  p_producto_id uuid,
  p_sucursal_id uuid default null
) returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org   uuid;
  v_suc   uuid;
  v_ve    boolean;
  p       record;
  v_total numeric;
  v_apart numeric;
  v_prom  numeric;
  v_ult   numeric;
  v_precio numeric;
  r       jsonb;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para consultar productos';
  end if;

  v_suc := coalesce(p_sucursal_id,
                    (select s.id from sucursales s
                      where s.organizacion_id = v_org and s.activa
                      order by s.es_principal desc limit 1));

  select * into p from productos
   where id = p_producto_id and (organizacion_id = v_org or app.es_admin());
  if p.id is null then raise exception 'Ese producto no es de su negocio'; end if;

  perform 1 from sucursales where id = v_suc and (organizacion_id = v_org or app.es_admin());
  if not found then raise exception 'Esa sucursal no es de su negocio'; end if;

  v_ve := app.tiene_nivel('supervisor') or app.es_admin();

  select coalesce(sum(cantidad), 0) into v_total
  from existencias where producto_id = p.id and sucursal_id = v_suc;

  select coalesce(sum(cantidad), 0) into v_apart
  from pedido_reservas
  where producto_id = p.id and sucursal_id = v_suc and liberada_en is null;

  select costo_promedio, ultimo_costo into v_prom, v_ult
  from producto_costos where producto_id = p.id and sucursal_id = v_suc;

  v_precio := fn_precio_vigente(p.id, v_suc, 1);

  select jsonb_build_object(
    'producto_id', p.id,
    'nombre',      p.nombre,
    'sku',         p.sku,
    'descripcion', p.descripcion,
    'imagen_url',  p.imagen_url,
    'unidad',      p.unidad_base,
    'tipo',        p.tipo,
    'activo',      p.activo,
    'se_vende',    p.se_vende,
    'categoria',   (select nombre from categorias  where id = p.categoria_id),
    'marca',       (select nombre from marcas      where id = p.marca_id),
    'proveedor',   (select nombre from proveedores where id = p.proveedor_id),
    'tasa_impuesto', coalesce((select tasa from impuestos where id = p.impuesto_id), 0),
    'controla_lote', p.controla_lote,
    'controla_vencimiento', p.controla_vencimiento,
    'dias_alerta', coalesce(p.dias_alerta_vencim,
                            (select o.dias_alerta_vencimiento from organizaciones o
                              where o.id = p.organizacion_id), 30),
    'unidades_empaque', p.unidades_empaque,

    'sucursal_id', v_suc,
    'sucursal',    (select nombre from sucursales where id = v_suc),

    'codigos', coalesce((select jsonb_agg(pc.codigo order by pc.es_principal desc, pc.codigo)
                          from producto_codigos pc where pc.producto_id = p.id), '[]'::jsonb),

    'precio', v_precio,
    'precios', coalesce((select jsonb_agg(jsonb_build_object(
                            'nivel', pr.nivel, 'desde', pr.cantidad_minima, 'precio', pr.precio)
                            order by pr.nivel, pr.cantidad_minima)
                          from precios pr
                          where pr.producto_id = p.id
                            and (pr.sucursal_id = v_suc or pr.sucursal_id is null)
                            and pr.vigente_desde <= current_date
                            and (pr.vigente_hasta is null or pr.vigente_hasta >= current_date)
                        ), '[]'::jsonb),

    'costo_promedio', case when v_ve then coalesce(v_prom, 0) end,
    'ultimo_costo',   case when v_ve then coalesce(v_ult, 0) end,
    'margen',         case when v_ve and v_precio > 0 and coalesce(v_prom, 0) > 0
                           then round((v_precio - v_prom) / v_precio * 100, 1) end,
    'valor_inventario', case when v_ve then round(v_total * coalesce(v_prom, 0), 2) end,

    'existencia',       v_total,
    'apartado',         v_apart,
    'disponible',       greatest(v_total - v_apart, 0),
    'stock_minimo',     p.stock_minimo,
    'stock_maximo',     p.stock_maximo,
    'stock_bajo',       v_total <= p.stock_minimo,

    -- CAMBIO: tipo y codigo, para que la pantalla distinga bodega de piso
    -- sin adivinar por el nombre.
    'ubicaciones', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ubicacion_id', x.ubicacion_id, 'nombre', x.ubicacion,
               'predeterminada', x.es_predeterminada, 'cantidad', x.cantidad,
               'tipo', u.tipo, 'codigo', u.codigo, 'activa', u.activa)
               order by x.orden, x.ubicacion)
      from fn_existencia_por_ubicacion(p.id, v_suc) x
      join ubicaciones u on u.id = x.ubicacion_id), '[]'::jsonb),

    'lotes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'lote_id', l.id, 'codigo', l.codigo,
               'vence', l.fecha_vencimiento,
               'dias', case when l.fecha_vencimiento is not null
                            then l.fecha_vencimiento - current_date end,
               'cantidad', e.cantidad)
               order by l.fecha_vencimiento nulls last, l.creado_en)
      from existencias e
      join lotes l on l.id = e.lote_id
      where e.producto_id = p.id and e.sucursal_id = v_suc and e.cantidad > 0),
      '[]'::jsonb),

    'sin_lote', coalesce((select sum(e.cantidad) from existencias e
                           where e.producto_id = p.id and e.sucursal_id = v_suc
                             and e.lote_id is null), 0),

    'otras_sucursales', coalesce((
      select jsonb_agg(jsonb_build_object('sucursal', s.nombre, 'cantidad', t.c)
                       order by s.nombre)
      from sucursales s
      join lateral (select coalesce(sum(e.cantidad), 0) as c from existencias e
                     where e.producto_id = p.id and e.sucursal_id = s.id) t on true
      where s.organizacion_id = p.organizacion_id and s.activa and s.id <> v_suc
        and (app.es_admin() or s.id in (select app.sucursales_permitidas()))
        and t.c <> 0), '[]'::jsonb),

    'ultima_compra', (
      select jsonb_build_object('fecha', k.ocurrido_en,
                                'cantidad', k.cantidad,
                                'costo', case when v_ve then k.costo_unitario end)
      from kardex k
      where k.producto_id = p.id and k.sucursal_id = v_suc
        and k.tipo = 'compra'
      order by k.ocurrido_en desc limit 1),

    'ultima_venta', (
      select max(v.creada_en) from ventas v
      join venta_detalle d on d.venta_id = v.id
      where d.producto_id = p.id and v.sucursal_id = v_suc
        and v.estado = 'completada'),

    'vendido_30d', coalesce((
      select sum(d.cantidad) from ventas v
      join venta_detalle d on d.venta_id = v.id
      where d.producto_id = p.id and v.sucursal_id = v_suc
        and v.estado = 'completada'
        and v.creada_en >= now() - interval '30 days'), 0),

    'conteo_abierto', (
      select jsonb_build_object('conteo_id', c.id, 'numero', c.numero,
                                'alcance', c.alcance)
      from conteos c
      where c.sucursal_id = v_suc and c.estado = 'abierto' limit 1),

    'ajustes_pendientes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ajuste_id', a.id, 'numero', a.numero,
               'ubicacion', ub.nombre, 'ubicacion_id', a.ubicacion_id,
               'lote_id', a.lote_id,
               'lote', (select codigo from lotes where id = a.lote_id),
               'sistema', a.cantidad_sistema, 'contado', a.cantidad_contada,
               'diferencia', a.cantidad_contada - a.cantidad_sistema,
               'motivo', a.motivo,
               'solicitado_por', (select nombre from perfiles where id = a.solicitado_por),
               'solicitado_en', a.solicitado_en)
               order by a.solicitado_en)
      from ajustes_inventario a
      join ubicaciones ub on ub.id = a.ubicacion_id
      where a.producto_id = p.id and a.sucursal_id = v_suc
        and a.estado = 'pendiente'), '[]'::jsonb),

    'puede_aprobar', app.es_admin() or app.tiene_nivel('gerente'),
    'puede_ver_costos', v_ve
  ) into r;

  return r;
end $fn$;

revoke execute on function fn_consultar_producto(uuid, uuid) from public, anon;
grant execute on function fn_consultar_producto(uuid, uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 2. No se mueve mercaderia de un lugar que se esta contando
--
-- Mismo cuerpo de la 019 mas el seguro de la auditoria abierta, en los DOS
-- extremos: si el origen se esta contando, el auditor ya vio esa caja; si el
-- destino se esta contando, la caja llega despues de que paso por ahi.
-- ---------------------------------------------------------------------------
create or replace function fn_mover_entre_ubicaciones(
  p_producto_id uuid,
  p_hacia       uuid,
  p_cantidad    numeric,
  p_desde       uuid default null,   -- null = la predeterminada
  p_lote_id     uuid default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org     uuid;
  h         record;
  d         record;
  v_total   numeric;
  v_asig    numeric;
  v_disp    numeric;
  v_aud     text;
begin
  if p_cantidad is null or p_cantidad <= 0 then
    raise exception 'La cantidad a mover debe ser mayor a cero';
  end if;

  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para mover mercaderia';
  end if;

  select * into h from ubicaciones
   where id = p_hacia and (organizacion_id = v_org or app.es_admin());
  if h.id is null then raise exception 'Esa ubicacion de destino no es de su negocio'; end if;
  if not h.activa then raise exception 'La ubicacion % esta inactiva', h.nombre; end if;

  if p_desde is null then
    select * into d from ubicaciones
     where sucursal_id = h.sucursal_id and es_predeterminada;
  else
    select * into d from ubicaciones
     where id = p_desde and (organizacion_id = v_org or app.es_admin());
  end if;
  if d.id is null then raise exception 'Esa ubicacion de origen no existe'; end if;
  if d.id = h.id then raise exception 'El origen y el destino son la misma ubicacion'; end if;
  if d.sucursal_id <> h.sucursal_id then
    raise exception 'Las dos ubicaciones tienen que ser de la misma sucursal. Para pasar mercaderia entre sucursales se usa un traslado';
  end if;

  if not app.es_admin()
     and h.sucursal_id not in (select app.sucursales_permitidas()) then
    raise exception 'No tiene acceso a esa sucursal';
  end if;

  -- SEGURO NUEVO: mover mercaderia mientras se cuenta el lugar deja el conteo
  -- mintiendo. Se espera a que cierren la auditoria.
  select u.nombre into v_aud
  from auditorias a
  join ubicaciones u on u.id = a.ubicacion_id
  where a.estado = 'abierta' and a.ubicacion_id in (d.id, h.id)
  limit 1;
  if v_aud is not null then
    raise exception 'Hay una auditoria abierta en %. Termine de contar ese lugar antes de mover mercaderia de ahi o hacia ahi', v_aud;
  end if;

  perform 1 from productos
   where id = p_producto_id and organizacion_id = h.organizacion_id
     and activo and tipo <> 'servicio';
  if not found then raise exception 'Ese producto no es de este negocio'; end if;

  if p_lote_id is not null then
    perform 1 from lotes
     where id = p_lote_id and producto_id = p_producto_id
       and sucursal_id = h.sucursal_id;
    if not found then raise exception 'Ese lote no corresponde al producto en esta sucursal'; end if;
  end if;

  select coalesce(sum(e.cantidad), 0) into v_total
  from existencias e
  where e.producto_id = p_producto_id
    and e.sucursal_id = h.sucursal_id
    and e.lote_id is not distinct from p_lote_id;

  select coalesce(sum(eu.cantidad), 0) into v_asig
  from existencias_ubicacion eu
  where eu.producto_id = p_producto_id
    and eu.sucursal_id = h.sucursal_id
    and eu.lote_id is not distinct from p_lote_id;

  if d.es_predeterminada then
    v_disp := greatest(v_total - v_asig, 0);
  else
    select coalesce(cantidad, 0) into v_disp
    from existencias_ubicacion
    where producto_id = p_producto_id and sucursal_id = h.sucursal_id
      and ubicacion_id = d.id and lote_id is not distinct from p_lote_id;
    v_disp := coalesce(v_disp, 0);
  end if;

  if v_disp < p_cantidad then
    raise exception 'En % solo hay % para mover', d.nombre, v_disp;
  end if;

  if not d.es_predeterminada then
    update existencias_ubicacion
       set cantidad = cantidad - p_cantidad, actualizado_en = now()
     where producto_id = p_producto_id and sucursal_id = h.sucursal_id
       and ubicacion_id = d.id and lote_id is not distinct from p_lote_id;
  end if;

  if not h.es_predeterminada then
    insert into existencias_ubicacion (organizacion_id, sucursal_id, producto_id,
                                       lote_id, ubicacion_id, cantidad)
    values (h.organizacion_id, h.sucursal_id, p_producto_id, p_lote_id, h.id, p_cantidad)
    on conflict (producto_id, sucursal_id, ubicacion_id, lote_id) do update
      set cantidad = existencias_ubicacion.cantidad + excluded.cantidad,
          actualizado_en = now();
  end if;

  return jsonb_build_object(
    'producto', (select nombre from productos where id = p_producto_id),
    'desde', d.nombre, 'desde_id', d.id, 'desde_tipo', d.tipo,
    'hacia', h.nombre, 'hacia_id', h.id, 'hacia_tipo', h.tipo,
    'cantidad', p_cantidad);
end $fn$;

revoke execute on function fn_mover_entre_ubicaciones(uuid, uuid, numeric, uuid, uuid)
  from public, anon;
grant execute on function fn_mover_entre_ubicaciones(uuid, uuid, numeric, uuid, uuid)
  to authenticated;
