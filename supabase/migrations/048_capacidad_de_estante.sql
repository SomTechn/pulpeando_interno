-- ============================================================================
--  048 · Capacidad de estante y lista para reponer el piso de ventas
--
--  Cada producto puede decir cuánto cabe en su espacio del piso de ventas
--  (productos.capacidad_estante). Con eso, fn_reponer_piso arma la lista de
--  lo que hay que bajar de la bodega: lo que está por debajo de su
--  capacidad en el piso y tiene existencia en alguna bodega.
--
--  El piso es la ubicación predeterminada (el residuo: total − lo que está en
--  las demás). Se sugiere sacar de la bodega que más tiene de ese producto,
--  hasta llenar el espacio o hasta lo que haya. Pasarlo es el
--  fn_mover_entre_ubicaciones de siempre (no es kardex: el total no cambia).
-- ============================================================================

alter table productos add column if not exists capacidad_estante numeric(14,3);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'productos_capacidad_estante_positiva') then
    alter table productos add constraint productos_capacidad_estante_positiva
      check (capacidad_estante is null or capacidad_estante > 0);
  end if;
end $$;

create or replace function fn_reponer_piso(p_sucursal_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org  uuid := app.org_id();
  v_piso record;
begin
  if v_org is null or not app.tiene_nivel('auxiliar') then
    raise exception 'Sin permiso';
  end if;
  if not exists (select 1 from sucursales where id = p_sucursal_id and organizacion_id = v_org)
     or p_sucursal_id not in (select app.sucursales_permitidas()) then
    raise exception 'No tiene acceso a esa sucursal';
  end if;
  select id, nombre into v_piso from ubicaciones where sucursal_id = p_sucursal_id and es_predeterminada;

  return jsonb_build_object(
    'piso_id', v_piso.id,
    'piso', v_piso.nombre,
    'sin_capacidad', (select count(*) from productos where organizacion_id = v_org and activo
                        and tipo <> 'servicio' and capacidad_estante is null),
    'filas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'producto_id', x.id, 'sku', x.sku, 'nombre', x.nombre, 'unidad', x.unidad_base,
               'capacidad', x.capacidad_estante, 'piso', x.piso, 'bodega', x.bodega,
               'falta', x.capacidad_estante - x.piso,
               'lleno', round(greatest(x.piso, 0) / x.capacidad_estante * 100),
               'desde_id', x.desde_id, 'desde', x.desde,
               'sugerido', case when x.desde_id is null then 0
                                when x.tipo = 'unidad' then floor(least(x.capacidad_estante - x.piso, x.en_desde))
                                else least(x.capacidad_estante - x.piso, x.en_desde) end)
             order by greatest(x.piso, 0) / x.capacidad_estante, x.nombre)
      from (
        select p.id, p.sku, p.nombre, p.unidad_base, p.tipo, p.capacidad_estante,
               coalesce(t.total, 0) - coalesce(o.otros, 0) as piso,
               coalesce(o.otros, 0) as bodega,
               b.ubicacion_id as desde_id, b.nombre as desde, b.cantidad as en_desde
        from productos p
        left join lateral (select sum(e.cantidad) as total from existencias e
                            where e.producto_id = p.id and e.sucursal_id = p_sucursal_id) t on true
        left join lateral (select sum(eu.cantidad) as otros from existencias_ubicacion eu
                            where eu.producto_id = p.id and eu.sucursal_id = p_sucursal_id) o on true
        left join lateral (select eu.ubicacion_id, u.nombre, sum(eu.cantidad) as cantidad
                             from existencias_ubicacion eu join ubicaciones u on u.id = eu.ubicacion_id
                            where eu.producto_id = p.id and eu.sucursal_id = p_sucursal_id and u.activa
                            group by eu.ubicacion_id, u.nombre
                           having sum(eu.cantidad) > 0
                            order by sum(eu.cantidad) desc limit 1) b on true
        where p.organizacion_id = v_org and p.activo and p.tipo <> 'servicio'
          and p.capacidad_estante is not null
      ) x
      where x.piso < x.capacidad_estante
    ), '[]'::jsonb));
end $fn$;

revoke execute on function fn_reponer_piso(uuid) from public, anon;
grant execute on function fn_reponer_piso(uuid) to authenticated;
