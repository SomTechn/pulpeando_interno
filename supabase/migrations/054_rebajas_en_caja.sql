-- ============================================================================
--  054 · Rebajas en caja y el precio de siempre en el catálogo de la caja
--
--  · La cajera solo cambia la cantidad del ÚLTIMO producto que escaneó. Si el
--    cliente devuelve algo de antes, se escanea otra vez en modo «Rebajar»:
--    queda anotado y sale en el ticket como «anulado en caja».
--  · fn_ofertas_caja: el precio de siempre y hasta cuándo dura cada oferta,
--    para que la caja enseñe el ahorro de cada producto.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Las ofertas vigentes de la sucursal con su precio de siempre. Es una
--    función aparte y no columnas nuevas en v_pos_catalogo: en producción esa
--    vista tiene las columnas en otro orden que en las migraciones, y
--    recrearla sin drop no se puede.
-- ---------------------------------------------------------------------------
create or replace function fn_ofertas_caja(p_sucursal_id uuid)
returns table (producto_id uuid, precio numeric, precio_normal numeric, oferta_hasta date)
language sql stable security definer set search_path = public, app as $fn$
  select o.producto_id, o.precio, n.precio, o.vigente_hasta
    from (select distinct on (pr.producto_id) pr.producto_id, pr.precio, pr.vigente_hasta
            from precios pr join productos p on p.id = pr.producto_id
           where p.organizacion_id = app.org_id() and app.tiene_nivel('auxiliar')
             and (pr.sucursal_id = p_sucursal_id or pr.sucursal_id is null)
             and pr.es_oferta and pr.cantidad_minima <= 1
             and pr.vigente_desde <= current_date and pr.vigente_hasta >= current_date
           order by pr.producto_id, pr.sucursal_id nulls last, pr.precio) o
    cross join lateral (
      select pr.precio from precios pr
       where pr.producto_id = o.producto_id
         and (pr.sucursal_id = p_sucursal_id or pr.sucursal_id is null)
         and pr.nivel = 'detalle' and not pr.es_oferta and pr.cantidad_minima <= 1
         and pr.vigente_desde <= current_date
         and (pr.vigente_hasta is null or pr.vigente_hasta >= current_date)
       order by pr.sucursal_id nulls last, pr.cantidad_minima desc, pr.vigente_desde desc
       limit 1) n
   where o.precio < n.precio
$fn$;
revoke execute on function fn_ofertas_caja(uuid) from public, anon;
grant execute on function fn_ofertas_caja(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Lo que se rebajó del ticket antes de cobrar
-- ---------------------------------------------------------------------------
create table if not exists venta_rebajas (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references organizaciones(id) on delete cascade,
  venta_id        uuid not null references ventas(id) on delete cascade,
  producto_id     uuid references productos(id),
  nombre          text not null,
  cantidad        numeric(14,3) not null check (cantidad > 0),
  precio          numeric(16,4) not null default 0,
  autorizacion_id uuid,
  por             uuid,
  ocurrida_en     timestamptz not null default now(),
  creada_en       timestamptz not null default now()
);
create index if not exists ix_venta_rebajas on venta_rebajas (venta_id);
alter table venta_rebajas enable row level security;
revoke all on venta_rebajas from public, anon, authenticated;

-- La caja manda las rebajas justo después de cobrar (o al subir las ventas
-- guardadas sin internet). Una sola vez por venta, por quien la cobró.
create or replace function fn_anotar_rebajas(p_venta_id uuid, p_rebajas jsonb)
returns int
language plpgsql security definer set search_path = public, app as $fn$
declare v record; n int;
begin
  if not app.tiene_nivel('auxiliar') then raise exception 'Sin permiso'; end if;
  select * into v from ventas where id = p_venta_id and organizacion_id = app.org_id();
  if v.id is null then raise exception 'Esa venta no es de su negocio'; end if;
  if v.cajero_id is distinct from auth.uid() and not app.tiene_nivel('supervisor') then
    raise exception 'Solo quien cobró la venta anota sus rebajas';
  end if;
  if v.creada_en < now() - interval '3 days' then raise exception 'Esa venta ya es vieja'; end if;
  if exists (select 1 from venta_rebajas where venta_id = v.id) then return 0; end if;
  if jsonb_typeof(p_rebajas) <> 'array' or jsonb_array_length(p_rebajas) = 0 then return 0; end if;
  if jsonb_array_length(p_rebajas) > 200 then raise exception 'Demasiadas rebajas'; end if;

  insert into venta_rebajas (organizacion_id, venta_id, producto_id, nombre, cantidad, precio,
                             autorizacion_id, por, ocurrida_en)
  select v.organizacion_id, v.id, p.id,
         coalesce(p.nombre, left(btrim(r->>'nombre'), 120), 'Producto'),
         round((r->>'cantidad')::numeric, 3),
         coalesce(nullif(r->>'precio', '')::numeric, 0),
         nullif(r->>'autorizacion_id', '')::uuid,
         auth.uid(),
         coalesce(nullif(r->>'ocurrida_en', '')::timestamptz, now())
    from jsonb_array_elements(p_rebajas) r
    left join productos p on p.id = nullif(r->>'producto_id', '')::uuid
                         and p.organizacion_id = v.organizacion_id
   where coalesce(nullif(r->>'cantidad', '')::numeric, 0) > 0;
  get diagnostics n = row_count;
  return n;
end $fn$;
revoke execute on function fn_anotar_rebajas(uuid, jsonb) from public, anon;
grant execute on function fn_anotar_rebajas(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. La venta completa (para imprimir) trae las rebajas.
--    Se le agrega la clave a la definición que ESTÉ en la base (la de
--    producción ya no es idéntica a la de las migraciones): se lee, se le
--    pega 'rebajas' antes del cierre y se vuelve a crear. Si no encuentra
--    dónde pegarla, se detiene en vez de dejarla a medias.
-- ---------------------------------------------------------------------------
do $do$
declare d text;
begin
  d := pg_get_functiondef('fn_venta_completa(uuid)'::regprocedure);
  if position('''rebajas''' in d) > 0 then return; end if;
  d := replace(d,
$a$      from devoluciones_venta dv where dv.venta_id = v.id), '[]'::jsonb)
  ) into v_res;$a$,
$b$      from devoluciones_venta dv where dv.venta_id = v.id), '[]'::jsonb),
    'rebajas', coalesce((
      select jsonb_agg(jsonb_build_object('producto', r.nombre, 'cantidad', r.cantidad,
               'precio', r.precio, 'total', round(r.cantidad * r.precio, 2),
               'ocurrida_en', r.ocurrida_en) order by r.ocurrida_en)
      from venta_rebajas r where r.venta_id = v.id), '[]'::jsonb)
  ) into v_res;$b$);
  if position('''rebajas''' in d) = 0 then
    raise exception 'No se encontró dónde agregar las rebajas a fn_venta_completa';
  end if;
  execute d;
end $do$;

notify pgrst, 'reload schema';
