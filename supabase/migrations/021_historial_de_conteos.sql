-- ============================================================================
--  021 · El historial de conteos de un producto
--
--  En el equipo de mano de un supermercado, la pantalla del articulo dice en
--  que quedo el ultimo conteo. Sin eso nadie sabe si lo que esta viendo se
--  reviso ayer o hace tres meses, y se vuelve a contar lo mismo.
--
--  El problema es que en este sistema un producto se cuenta por DOS caminos:
--
--    · la hoja de conteo (018) cuenta muchos productos de una vez
--    · el conteo por lugar (020) corrige un solo producto en un solo lugar
--
--  Para quien esta parado frente al estante los dos son "el conteo". Asi que
--  esta funcion los junta en una sola lista ordenada por fecha. Que la
--  diferencia venga de una hoja o de una correccion suelta es cosa del
--  sistema, no de la persona.
-- ============================================================================

create or replace function fn_conteos_del_producto(
  p_producto_id uuid,
  p_sucursal_id uuid default null,
  p_limite      int  default 5
)
returns table (
  origen      text,       -- 'lugar' · 'hoja'
  referencia  text,       -- el numero del conteo o del ajuste
  estado      text,       -- pendiente · aprobado · rechazado · contado · aplicado...
  ubicacion   text,       -- null cuando viene de una hoja: la hoja cuenta la sucursal
  lote        text,
  sistema     numeric,
  contado     numeric,
  diferencia  numeric,
  quien       text,
  cuando      timestamptz,
  nota        text
)
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org uuid;
  v_suc uuid;
  v_ve  boolean;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para ver los conteos';
  end if;

  perform 1 from productos
   where id = p_producto_id and (organizacion_id = v_org or app.es_admin());
  if not found then raise exception 'Ese producto no es de su negocio'; end if;

  v_suc := coalesce(p_sucursal_id,
                    (select s.id from sucursales s
                      where s.organizacion_id = v_org and s.activa
                      order by s.es_principal desc limit 1));

  -- La cantidad del sistema y la diferencia son datos de control: el conteo
  -- es ciego para quien cuenta. De supervisor para arriba se ven.
  v_ve := app.tiene_nivel('supervisor') or app.es_admin();

  return query
  select * from (
    -- Conteos de un lugar concreto
    select 'lugar'::text, a.numero, a.estado,
           ub.nombre, (select codigo from lotes where id = a.lote_id),
           case when v_ve or a.estado = 'pendiente' then a.cantidad_sistema end,
           a.cantidad_contada,
           case when v_ve or a.estado = 'pendiente'
                then a.cantidad_contada - a.cantidad_sistema end,
           coalesce(pe.nombre, '—'), a.solicitado_en,
           coalesce(a.nota_resolucion, a.motivo)
    from ajustes_inventario a
    join ubicaciones ub   on ub.id = a.ubicacion_id
    left join perfiles pe on pe.id = a.solicitado_por
    where a.producto_id = p_producto_id
      and a.sucursal_id = v_suc
      and a.organizacion_id = v_org

    union all

    -- Lineas de hoja de conteo que alguien conto de verdad
    select 'hoja'::text, c.numero,
           case when c.estado = 'abierto' then 'contado' else c.estado end,
           null, (select codigo from lotes where id = d.lote_id),
           case when v_ve then d.cantidad_sistema end,
           d.cantidad_contada,
           case when v_ve then d.cantidad_contada - d.cantidad_sistema end,
           coalesce(pe.nombre, '—'), d.contado_en, d.nota
    from conteo_detalle d
    join conteos c        on c.id = d.conteo_id
    left join perfiles pe on pe.id = d.contado_por
    where d.producto_id = p_producto_id
      and c.sucursal_id = v_suc
      and c.organizacion_id = v_org
      and d.cantidad_contada is not null
  ) t
  order by t.solicitado_en desc nulls last
  limit greatest(coalesce(p_limite, 5), 1);
end $fn$;

revoke execute on function fn_conteos_del_producto(uuid, uuid, int) from public, anon;
grant execute on function fn_conteos_del_producto(uuid, uuid, int) to authenticated;
