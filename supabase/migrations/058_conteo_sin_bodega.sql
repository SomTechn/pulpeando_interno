-- ===========================================================================
-- 058 · Contar el piso sin auditar la bodega cuando la bodega no importa
--
-- La regla de las 24 horas existe porque el piso se calcula restando la
-- bodega: con una bodega vieja, la cifra del piso no vale. Pero si el producto
-- no tiene nada en ninguna bodega, la resta es cero y la auditoría no cambia
-- nada. Pedido de Somar: en ese caso no se pide, salvo que el piso diga más de
-- lo que cabe en el estante (capacidad_estante): eso huele a mercadería que
-- está en bodega sin registrar, y ahí sí hay que auditar.
-- ===========================================================================

create or replace function app.conteo_pide_bodega(p_producto_id uuid, p_sucursal_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_total numeric;
  v_bod   numeric;
  v_cap   numeric;
  v_piso  numeric;
begin
  select coalesce(sum(e.cantidad), 0) into v_total
    from existencias e
   where e.producto_id = p_producto_id and e.sucursal_id = p_sucursal_id;

  select coalesce(sum(greatest(eu.cantidad, 0)), 0) into v_bod
    from existencias_ubicacion eu
    join ubicaciones u on u.id = eu.ubicacion_id
   where eu.producto_id = p_producto_id and eu.sucursal_id = p_sucursal_id
     and u.tipo = 'bodega' and u.activa;

  select nullif(capacidad_estante, 0) into v_cap from productos where id = p_producto_id;
  v_piso := greatest(v_total - v_bod, 0);

  return jsonb_build_object(
    'pide', v_bod > 0 or (v_cap is not null and v_piso > v_cap),
    'bodega', v_bod, 'piso', v_piso, 'capacidad', v_cap,
    'razon', case when v_bod > 0 then 'bodega'
                  when v_cap is not null and v_piso > v_cap then 'capacidad'
                  else null end);
end $fn$;

revoke execute on function app.conteo_pide_bodega(uuid, uuid) from public, anon, authenticated;

-- Para la pantalla: lo mismo, con el candado de siempre.
create or replace function fn_conteo_pide_bodega(p_producto_id uuid, p_sucursal_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  v_suc uuid;
begin
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('auxiliar'))) then
    raise exception 'Sin permiso';
  end if;
  perform 1 from productos where id = p_producto_id and organizacion_id = v_org;
  if not found then raise exception 'Ese producto no es de este negocio'; end if;
  v_suc := coalesce(p_sucursal_id,
                    (select s.id from sucursales s
                      where s.organizacion_id = v_org and s.activa
                      order by s.es_principal desc limit 1));
  if not app.es_admin() and v_suc not in (select app.sucursales_permitidas()) then
    raise exception 'No tiene acceso a esa sucursal';
  end if;
  return app.conteo_pide_bodega(p_producto_id, v_suc);
end $fn$;

revoke execute on function fn_conteo_pide_bodega(uuid, uuid) from public, anon;
grant execute on function fn_conteo_pide_bodega(uuid, uuid) to authenticated;

-- La puerta de fn_solicitar_conteo_piso: se parcha sobre la definición viva
-- (producción y migraciones no siempre coinciden letra por letra).
do $do$
declare
  d text := pg_get_functiondef('fn_solicitar_conteo_piso(uuid,numeric,uuid,text,uuid)'::regprocedure);
  a text := 'if not (v_est->>''al_dia'')::boolean then';
  b text := 'if not (v_est->>''al_dia'')::boolean and (app.conteo_pide_bodega(p_producto_id, v_suc)->>''pide'')::boolean then';
begin
  if position('conteo_pide_bodega' in d) > 0 then return; end if;
  if position(a in d) = 0 then raise exception 'No encontré la puerta de la bodega en fn_solicitar_conteo_piso'; end if;
  execute replace(d, a, b);
end $do$;
