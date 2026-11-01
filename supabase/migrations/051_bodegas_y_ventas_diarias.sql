-- ============================================================================
--  051 · Bodegas como módulo y ventas diarias del producto
--
--  · fn_ventas_producto_dias: las ventas del producto día por día (últimos
--    30), para el historial de Consultar que se cambia deslizando entre
--    semanas y días.
--  · fn_crear_bodega: una bodega nueva en un paso (fn_guardar_ubicacion crea
--    de tipo piso y había que cambiarle el tipo aparte). Supervisor.
--  · fn_bodega_productos: lo que hay en una bodega, producto por producto,
--    con el vencimiento más próximo. Es lo que se ve al entrar a una bodega
--    antes de auditarla.
-- ============================================================================

create or replace function fn_ventas_producto_dias(
  p_producto_id uuid,
  p_dias        int  default 30,
  p_sucursal_id uuid default null
)
returns table (dia date, unidades numeric, importe numeric)
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org uuid;
  v_suc uuid;
  v_tz  text;
  v_n   int;
  v_hoy date;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para ver ventas';
  end if;
  perform 1 from productos where id = p_producto_id and (organizacion_id = v_org or app.es_admin());
  if not found then raise exception 'Ese producto no es de su negocio'; end if;

  v_suc := coalesce(p_sucursal_id, (select s.id from sucursales s
                                     where s.organizacion_id = v_org and s.activa
                                     order by s.es_principal desc limit 1));
  if v_suc not in (select app.sucursales_permitidas()) and not app.es_admin() then
    raise exception 'No tiene acceso a esa sucursal';
  end if;
  v_tz  := app.zona(v_org);
  v_n   := least(greatest(coalesce(p_dias, 30), 1), 90);
  v_hoy := (now() at time zone v_tz)::date;

  return query
  with dias as (
    select (v_hoy - i)::date as d from generate_series(0, v_n - 1) as i
  ),
  movidas as (
    select (v.creada_en at time zone v_tz)::date as dia, d.cantidad, d.total
      from ventas v join venta_detalle d on d.venta_id = v.id
     where d.producto_id = p_producto_id and v.sucursal_id = v_suc and v.estado = 'completada'
       and v.creada_en >= ((v_hoy - (v_n - 1))::timestamp at time zone v_tz)
  )
  select x.d, coalesce(sum(m.cantidad), 0), round(coalesce(sum(m.total), 0), 2)
    from dias x left join movidas m on m.dia = x.d
   group by x.d
   order by x.d;
end $fn$;

revoke execute on function fn_ventas_producto_dias(uuid, int, uuid) from public, anon;
grant execute on function fn_ventas_producto_dias(uuid, int, uuid) to authenticated;


create or replace function fn_crear_bodega(p_nombre text, p_sucursal_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  v_suc uuid;
  v_id  uuid;
begin
  if v_org is null or not app.tiene_nivel('supervisor') then
    raise exception 'Solo un supervisor puede crear bodegas';
  end if;
  if p_nombre is null or btrim(p_nombre) = '' then raise exception 'La bodega necesita un nombre'; end if;
  v_suc := coalesce(p_sucursal_id, (select s.id from sucursales s
                                     where s.organizacion_id = v_org and s.activa
                                     order by s.es_principal desc limit 1));
  perform 1 from sucursales where id = v_suc and organizacion_id = v_org;
  if not found then raise exception 'Esa sucursal no es de su negocio'; end if;
  if v_suc not in (select app.sucursales_permitidas()) then raise exception 'No tiene acceso a esa sucursal'; end if;
  if exists (select 1 from ubicaciones where sucursal_id = v_suc and lower(nombre) = lower(btrim(p_nombre))) then
    raise exception 'Ya hay un lugar con ese nombre en esta sucursal';
  end if;

  insert into ubicaciones (organizacion_id, sucursal_id, nombre, orden, activa, tipo, codigo)
  values (v_org, v_suc, btrim(p_nombre), 100, true, 'bodega', app.codigo_ubicacion(v_suc, 'bodega'))
  returning id into v_id;

  return jsonb_build_object('ubicacion_id', v_id, 'nombre', btrim(p_nombre),
                            'codigo', (select codigo from ubicaciones where id = v_id));
end $fn$;

revoke execute on function fn_crear_bodega(text, uuid) from public, anon;
grant execute on function fn_crear_bodega(text, uuid) to authenticated;


create or replace function fn_bodega_productos(p_ubicacion_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  u     record;
begin
  if v_org is null or not app.tiene_nivel('auxiliar') then raise exception 'Sin permiso'; end if;
  select * into u from ubicaciones where id = p_ubicacion_id and organizacion_id = v_org;
  if u.id is null then raise exception 'Esa ubicación no es de su negocio'; end if;
  if u.sucursal_id not in (select app.sucursales_permitidas()) then raise exception 'No tiene acceso a esa sucursal'; end if;

  return jsonb_build_object(
    'ubicacion_id', u.id, 'nombre', u.nombre, 'codigo', u.codigo, 'tipo', u.tipo, 'activa', u.activa,
    'auditada_en', (select max(a.cerrada_en) from auditorias a where a.ubicacion_id = u.id and a.estado = 'aplicada'),
    'abierta', (select jsonb_build_object('auditoria_id', a.id, 'numero', a.numero) from auditorias a
                 where a.ubicacion_id = u.id and a.estado = 'abierta' limit 1),
    'productos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'producto_id', p.id, 'nombre', p.nombre, 'sku', p.sku, 'unidad', p.unidad_base,
               'cantidad', x.cantidad, 'empaque', p.unidades_empaque, 'vence', x.vence) order by p.nombre)
        from (select eu.producto_id, sum(eu.cantidad) as cantidad,
                     min(l.fecha_vencimiento) filter (where eu.cantidad > 0) as vence
                from existencias_ubicacion eu
                left join lotes l on l.id = eu.lote_id
               where eu.ubicacion_id = u.id
               group by eu.producto_id
              having sum(eu.cantidad) > 0) x
        join productos p on p.id = x.producto_id), '[]'::jsonb));
end $fn$;

revoke execute on function fn_bodega_productos(uuid) from public, anon;
grant execute on function fn_bodega_productos(uuid) to authenticated;
