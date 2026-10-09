-- ============================================================================
--  019 · Ubicaciones dentro de la sucursal, consulta de producto y conteo
--        por seleccion
--
--  LO QUE SE PIDIO
--
--  Una pantalla "Consultar" donde se escanea o se escribe un codigo o un
--  nombre y sale todo del producto: lo que hay en el piso de ventas, lo que
--  hay en bodega, la existencia total, las ventas de las ultimas semanas, los
--  vencimientos, y poder mandar ese producto a un conteo sin tener que contar
--  la categoria entera.
--
--  POR QUE EL DESGLOSE VA APARTE Y NO DENTRO DE existencias
--
--  La tabla existencias es por (producto, sucursal, lote) y de ella cuelgan
--  seis vistas y seis funciones, incluido el descuento FEFO de cada venta.
--  Partirla en piso y bodega seria abrir el centro del sistema: justo donde
--  esta la plata. Asi que no se toca.
--
--  existencias sigue siendo EL TOTAL. Aparte se guarda cuanto de ese total
--  esta en cada ubicacion con nombre, y lo que nadie asigno a ninguna se lee
--  como que esta en la ubicacion predeterminada. Es decir:
--
--      predeterminada  =  total  -  suma de las demas ubicaciones
--
--  De ahi salen tres cosas gratis:
--
--    · El desglose SIEMPRE cuadra con el total. No hay dos verdades.
--    · Un negocio que nunca use ubicaciones ve todo en una sola y nada
--      cambia para el.
--    · Ventas, FEFO, catalogo, pedidos y compras siguen exactamente igual.
--
--  MOVER DEL PISO A LA BODEGA NO ES UN MOVIMIENTO DE INVENTARIO
--
--  Nada entra ni sale del negocio cuando alguien baja cajas de la bodega al
--  estante. No lleva kardex, no toca el costo promedio y no cambia el total.
--  Meterlo al kardex llenaria el historial de ruido y haria ver como
--  "ajustes" lo que es acomodar mercaderia.
--
--  CUANDO LA VENTA SE COME MAS DE LO QUE DECIA EL PISO
--
--  El cajero no marca de donde saca. Si el piso decia 2 y se vendieron 5, el
--  desglose quedaria pidiendo 8 en bodega de un total de 5: imposible. Un
--  disparador recorta el desglose empezando por lo mas cerca de la venta, y
--  nunca deja que la suma de las ubicaciones pase del total. La pantalla de
--  consulta hace visible ese descuadre, que es lo que empuja a la gente a
--  registrar los traslados.
--
--  QUIEN HACE QUE
--
--      auxiliar     consulta, mueve entre ubicaciones, agrega a un conteo
--                   que ya este abierto
--      supervisor   crea y renombra ubicaciones, abre un conteo por seleccion,
--                   ve costos y margen
--      gerente      cambia cual ubicacion es la predeterminada
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 0. La zona horaria del negocio
--
--    El servidor esta en UTC y Honduras en UTC-6. Una venta de las 7 de la
--    noche cae en el dia siguiente si se agrupa por la hora del servidor, y
--    la grafica semanal saldria corrida. Se lee de la configuracion del
--    negocio por si algun dia hay clientes en otro pais.
-- ---------------------------------------------------------------------------

create or replace function app.zona(p_org uuid default null)
returns text
language sql stable security definer set search_path = public, app as $fn$
  select coalesce(
    nullif(btrim((select o.config->>'zona' from organizaciones o
                   where o.id = coalesce(p_org, app.org_id()))), ''),
    'America/Tegucigalpa')
$fn$;

revoke execute on function app.zona(uuid) from public, anon;
grant execute on function app.zona(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 1. Las ubicaciones
--
--    Cada negocio les pone el nombre que use: piso de ventas, bodega,
--    refrigerador, exhibidor, gondola 3. El "orden" es que tan cerca esta de
--    la venta, y sirve para dos cosas: ordenar la pantalla y decidir de donde
--    se recorta cuando la venta se pasa (lo mas cerca cede primero).
-- ---------------------------------------------------------------------------

create table if not exists ubicaciones (
  id                uuid primary key default gen_random_uuid(),
  organizacion_id   uuid not null references organizaciones(id) on delete cascade,
  sucursal_id       uuid not null references sucursales(id) on delete cascade,
  nombre            text not null,
  -- Donde vive lo que nadie asigno. Una sola por sucursal.
  es_predeterminada boolean not null default false,
  orden             int not null default 100,
  activa            boolean not null default true,
  creado_en         timestamptz not null default now()
);

create unique index if not exists ux_ubicaciones_nombre
  on ubicaciones (sucursal_id, lower(btrim(nombre)));

create unique index if not exists ux_ubicaciones_pred
  on ubicaciones (sucursal_id) where es_predeterminada;

create index if not exists ix_ubicaciones_suc on ubicaciones (sucursal_id, activa);


-- El desglose. Solo guarda las ubicaciones que NO son la predeterminada:
-- lo de la predeterminada se calcula como el resto, y asi no hay forma de
-- que las dos cuentas se contradigan.
create table if not exists existencias_ubicacion (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  sucursal_id      uuid not null references sucursales(id) on delete cascade,
  producto_id      uuid not null references productos(id) on delete cascade,
  lote_id          uuid references lotes(id) on delete cascade,
  ubicacion_id     uuid not null references ubicaciones(id) on delete cascade,
  cantidad         numeric(16,3) not null default 0 check (cantidad >= 0),
  actualizado_en   timestamptz not null default now()
);

-- nulls not distinct: sin esto un producto sin lote entraria dos veces en la
-- misma ubicacion, porque Postgres considera distintos a dos nulos.
create unique index if not exists ux_existencias_ubicacion
  on existencias_ubicacion (producto_id, sucursal_id, ubicacion_id, lote_id)
  nulls not distinct;

create index if not exists ix_eu_producto
  on existencias_ubicacion (producto_id, sucursal_id);

alter table ubicaciones            enable row level security;
alter table existencias_ubicacion  enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies
                  where tablename='ubicaciones' and policyname='ubicaciones_sel') then
    create policy ubicaciones_sel on ubicaciones for select
      using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))
             or app.es_admin());
  end if;
  if not exists (select 1 from pg_policies
                  where tablename='existencias_ubicacion' and policyname='eu_sel') then
    create policy eu_sel on existencias_ubicacion for select
      using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))
             or app.es_admin());
  end if;
end $$;

-- Igual que el resto del inventario: se escribe por funcion. Un desglose
-- editable a mano desde la consola del navegador no controla nada.
revoke insert, update, delete on ubicaciones           from authenticated;
revoke insert, update, delete on existencias_ubicacion from authenticated;
grant select on ubicaciones           to authenticated;
grant select on existencias_ubicacion to authenticated;


-- ---------------------------------------------------------------------------
-- 2. Toda sucursal nace con sus dos ubicaciones
--
--    Sin esto una sucursal nueva no tendria donde poner el resto y el
--    desglose apareceria vacio con existencia en el total.
-- ---------------------------------------------------------------------------

create or replace function app.tg_sucursal_ubicaciones()
returns trigger
language plpgsql security definer set search_path = public, app as $fn$
begin
  insert into ubicaciones (organizacion_id, sucursal_id, nombre, es_predeterminada, orden)
  values (new.organizacion_id, new.id, 'Piso de ventas', true,  10),
         (new.organizacion_id, new.id, 'Bodega',         false, 200)
  on conflict do nothing;
  return new;
end $fn$;

do $$ begin
  if not exists (select 1 from pg_trigger
                  where tgname = 'tg_sucursal_ubicaciones'
                    and tgrelid = 'sucursales'::regclass) then
    create trigger tg_sucursal_ubicaciones
      after insert on sucursales
      for each row execute function app.tg_sucursal_ubicaciones();
  end if;
end $$;

-- Las que ya existen
insert into ubicaciones (organizacion_id, sucursal_id, nombre, es_predeterminada, orden)
select s.organizacion_id, s.id, 'Piso de ventas', true, 10
from sucursales s
where not exists (select 1 from ubicaciones u
                   where u.sucursal_id = s.id and u.es_predeterminada);

insert into ubicaciones (organizacion_id, sucursal_id, nombre, es_predeterminada, orden)
select s.organizacion_id, s.id, 'Bodega', false, 200
from sucursales s
where not exists (select 1 from ubicaciones u
                   where u.sucursal_id = s.id
                     and lower(btrim(u.nombre)) = 'bodega');


-- ---------------------------------------------------------------------------
-- 3. El disparador que mantiene el desglose dentro del total
--
--    Es la unica garantia de que la suma de las ubicaciones nunca pase de la
--    existencia real. Se dispara con cada venta, compra, merma y ajuste, sin
--    que ninguna de esas funciones sepa que las ubicaciones existen.
-- ---------------------------------------------------------------------------

create or replace function app.tg_cuadrar_ubicaciones()
returns trigger
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_asignado numeric;
  v_exceso   numeric;
  v_quita    numeric;
  r          record;
begin
  select coalesce(sum(eu.cantidad), 0) into v_asignado
  from existencias_ubicacion eu
  where eu.producto_id = new.producto_id
    and eu.sucursal_id = new.sucursal_id
    and eu.lote_id is not distinct from new.lote_id;

  if v_asignado = 0 then return null; end if;

  v_exceso := v_asignado - greatest(coalesce(new.cantidad, 0), 0);
  if v_exceso <= 0 then return null; end if;

  -- Se saco mas de lo que el desglose decia que habia disponible fuera de
  -- las ubicaciones nombradas. Se recorta empezando por lo mas cerca de la
  -- caja: si hay exhibidor y bodega, cede primero el exhibidor.
  for r in
    select eu.id, eu.cantidad
    from existencias_ubicacion eu
    join ubicaciones u on u.id = eu.ubicacion_id
    where eu.producto_id = new.producto_id
      and eu.sucursal_id = new.sucursal_id
      and eu.lote_id is not distinct from new.lote_id
      and eu.cantidad > 0
    order by u.orden, u.nombre
  loop
    exit when v_exceso <= 0;
    v_quita := least(r.cantidad, v_exceso);
    update existencias_ubicacion
       set cantidad = cantidad - v_quita, actualizado_en = now()
     where id = r.id;
    v_exceso := v_exceso - v_quita;
  end loop;

  return null;
end $fn$;

do $$ begin
  if not exists (select 1 from pg_trigger
                  where tgname = 'tg_cuadrar_ubicaciones'
                    and tgrelid = 'existencias'::regclass) then
    create trigger tg_cuadrar_ubicaciones
      after insert or update of cantidad on existencias
      for each row execute function app.tg_cuadrar_ubicaciones();
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 4. Ver y mantener las ubicaciones
-- ---------------------------------------------------------------------------

create or replace function fn_ubicaciones(p_sucursal_id uuid default null)
returns table (
  ubicacion_id      uuid,
  nombre            text,
  es_predeterminada boolean,
  orden             int,
  activa            boolean
)
language sql stable security definer set search_path = public, app as $fn$
  select u.id, u.nombre, u.es_predeterminada, u.orden, u.activa
  from ubicaciones u
  where app.tiene_nivel('auxiliar')
    and (u.organizacion_id = app.org_id() or app.es_admin())
    and u.sucursal_id = coalesce(
          p_sucursal_id,
          (select s.id from sucursales s
            where s.organizacion_id = app.org_id() and s.activa
            order by s.es_principal desc limit 1))
  order by u.orden, u.nombre
$fn$;

revoke execute on function fn_ubicaciones(uuid) from public, anon;
grant execute on function fn_ubicaciones(uuid) to authenticated;


create or replace function fn_guardar_ubicacion(
  p_nombre      text,
  p_id          uuid default null,
  p_sucursal_id uuid default null,
  p_orden       int  default null,
  p_activa      boolean default true
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid;
  v_suc uuid;
  v_id  uuid;
  v_pred boolean;
begin
  v_org := app.org_id();
  if v_org is null or not app.tiene_nivel('supervisor') then
    raise exception 'Solo un supervisor puede crear o cambiar ubicaciones';
  end if;
  if p_nombre is null or btrim(p_nombre) = '' then
    raise exception 'La ubicacion necesita un nombre';
  end if;

  if p_id is not null then
    -- Que sea del mismo negocio: tiene_nivel mira el rango de quien llama,
    -- no de quien es la fila.
    select id, sucursal_id, es_predeterminada into v_id, v_suc, v_pred
    from ubicaciones where id = p_id and organizacion_id = v_org;
    if v_id is null then raise exception 'Esa ubicacion no es de su negocio'; end if;

    -- La predeterminada no se puede desactivar: es donde vive el resto.
    if v_pred and p_activa is false then
      raise exception 'No se puede desactivar la ubicacion predeterminada. Fije otra como predeterminada primero';
    end if;

    update ubicaciones
       set nombre = btrim(p_nombre),
           orden  = coalesce(p_orden, orden),
           activa = coalesce(p_activa, activa)
     where id = v_id;
  else
    v_suc := coalesce(p_sucursal_id,
                      (select s.id from sucursales s
                        where s.organizacion_id = v_org and s.activa
                        order by s.es_principal desc limit 1));
    perform 1 from sucursales where id = v_suc and organizacion_id = v_org;
    if not found then raise exception 'Esa sucursal no es de su negocio'; end if;

    insert into ubicaciones (organizacion_id, sucursal_id, nombre, orden, activa)
    values (v_org, v_suc, btrim(p_nombre), coalesce(p_orden, 100),
            coalesce(p_activa, true))
    returning id into v_id;
  end if;

  return jsonb_build_object('ubicacion_id', v_id, 'nombre', btrim(p_nombre));
end $fn$;

revoke execute on function fn_guardar_ubicacion(text, uuid, uuid, int, boolean)
  from public, anon;
grant execute on function fn_guardar_ubicacion(text, uuid, uuid, int, boolean)
  to authenticated;


-- Cambiar cual es la predeterminada mueve el piso bajo todo el desglose, por
-- eso lo hace el gerente. Y hay que convertir: lo que la vieja
-- predeterminada tenia calculado se escribe como fila propia antes de que
-- deje de serlo, o se perderia.
create or replace function fn_fijar_ubicacion_predeterminada(p_ubicacion_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org   uuid;
  u       record;
  v_vieja uuid;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('gerente'))) then
    raise exception 'Solo el gerente puede cambiar la ubicacion predeterminada';
  end if;

  select * into u from ubicaciones
   where id = p_ubicacion_id
     and (organizacion_id = v_org or app.es_admin());
  if u.id is null then raise exception 'Esa ubicacion no es de su negocio'; end if;
  if not u.activa then raise exception 'Una ubicacion inactiva no puede ser la predeterminada'; end if;
  if u.es_predeterminada then
    return jsonb_build_object('ubicacion_id', u.id, 'nombre', u.nombre, 'cambio', false);
  end if;

  select id into v_vieja from ubicaciones
   where sucursal_id = u.sucursal_id and es_predeterminada;

  -- El resto que la vieja tenia calculado pasa a ser una fila explicita.
  if v_vieja is not null then
    insert into existencias_ubicacion (organizacion_id, sucursal_id, producto_id,
                                       lote_id, ubicacion_id, cantidad)
    select e.organizacion_id, e.sucursal_id, e.producto_id, e.lote_id, v_vieja,
           greatest(e.cantidad - coalesce((
             select sum(eu.cantidad) from existencias_ubicacion eu
             where eu.producto_id = e.producto_id
               and eu.sucursal_id = e.sucursal_id
               and eu.lote_id is not distinct from e.lote_id), 0), 0)
    from existencias e
    where e.sucursal_id = u.sucursal_id and e.cantidad > 0
    on conflict (producto_id, sucursal_id, ubicacion_id, lote_id) do update
      set cantidad = existencias_ubicacion.cantidad + excluded.cantidad,
          actualizado_en = now();

    update ubicaciones set es_predeterminada = false where id = v_vieja;
  end if;

  -- Y la nueva deja de tener cantidad propia: ahora ella es el resto. Se
  -- dejan las filas en cero en vez de borrarlas, porque si algun dia vuelve
  -- a ser una ubicacion normal el historial de cuando se toco sigue ahi.
  update existencias_ubicacion
     set cantidad = 0, actualizado_en = now()
   where ubicacion_id = u.id and cantidad <> 0;

  update ubicaciones set es_predeterminada = true where id = u.id;

  return jsonb_build_object('ubicacion_id', u.id, 'nombre', u.nombre, 'cambio', true);
end $fn$;

revoke execute on function fn_fijar_ubicacion_predeterminada(uuid) from public, anon;
grant execute on function fn_fijar_ubicacion_predeterminada(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. Mover entre ubicaciones
--
--    No es un movimiento de inventario: nada entra ni sale del negocio. No
--    toca kardex, ni costo promedio, ni el total.
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
    'desde', d.nombre, 'hacia', h.nombre, 'cantidad', p_cantidad);
end $fn$;

revoke execute on function fn_mover_entre_ubicaciones(uuid, uuid, numeric, uuid, uuid)
  from public, anon;
grant execute on function fn_mover_entre_ubicaciones(uuid, uuid, numeric, uuid, uuid)
  to authenticated;


-- ---------------------------------------------------------------------------
-- 6. El desglose de un producto
--
--    La predeterminada sale de la resta, asi que la suma de esta lista es
--    siempre la existencia total. No hay forma de que no cuadre.
-- ---------------------------------------------------------------------------

create or replace function fn_existencia_por_ubicacion(
  p_producto_id uuid,
  p_sucursal_id uuid default null
)
returns table (
  ubicacion_id      uuid,
  ubicacion         text,
  es_predeterminada boolean,
  orden             int,
  cantidad          numeric
)
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org uuid;
  v_suc uuid;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para ver el inventario';
  end if;

  v_suc := coalesce(p_sucursal_id,
                    (select s.id from sucursales s
                      where s.organizacion_id = v_org and s.activa
                      order by s.es_principal desc limit 1));

  perform 1 from sucursales where id = v_suc and (organizacion_id = v_org or app.es_admin());
  if not found then raise exception 'Esa sucursal no es de su negocio'; end if;

  return query
  with total as (
    select coalesce(sum(e.cantidad), 0) as t
    from existencias e
    where e.producto_id = p_producto_id and e.sucursal_id = v_suc
  ),
  asignado as (
    select eu.ubicacion_id as uid, sum(eu.cantidad) as c
    from existencias_ubicacion eu
    where eu.producto_id = p_producto_id and eu.sucursal_id = v_suc
    group by eu.ubicacion_id
  )
  select u.id, u.nombre, u.es_predeterminada, u.orden,
         case when u.es_predeterminada
              then greatest((select t from total)
                            - coalesce((select sum(c) from asignado), 0), 0)
              else coalesce(a.c, 0) end
  from ubicaciones u
  left join asignado a on a.uid = u.id
  where u.sucursal_id = v_suc
    and (u.activa or coalesce(a.c, 0) <> 0)
  order by u.orden, u.nombre;
end $fn$;

revoke execute on function fn_existencia_por_ubicacion(uuid, uuid) from public, anon;
grant execute on function fn_existencia_por_ubicacion(uuid, uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 7. Buscar para consultar
--
--    Un codigo escaneado tiene que caer directo en el producto, sin lista
--    intermedia: en caja eso es la diferencia entre agil y lento. Por eso
--    sale primero lo exacto.
-- ---------------------------------------------------------------------------

create or replace function fn_buscar_para_consulta(
  p_busqueda    text,
  p_sucursal_id uuid default null,
  p_limite      int  default 20
)
returns table (
  producto_id uuid,
  nombre      text,
  sku         text,
  codigo      text,
  categoria   text,
  unidad      text,
  precio      numeric,
  existencia  numeric,
  exacto      boolean
)
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org uuid;
  v_suc uuid;
  v_q   text;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para consultar productos';
  end if;

  v_q := btrim(coalesce(p_busqueda, ''));
  if v_q = '' then return; end if;

  v_suc := coalesce(p_sucursal_id,
                    (select s.id from sucursales s
                      where s.organizacion_id = v_org and s.activa
                      order by s.es_principal desc limit 1));

  return query
  with cand as (
    select p.id,
           -- 0 codigo de barras exacto · 1 SKU exacto · 2 empieza con ·
           -- 3 contiene
           min(case
                 when exists (select 1 from producto_codigos pc
                               where pc.producto_id = p.id and pc.codigo = v_q) then 0
                 when lower(p.sku) = lower(v_q) then 1
                 when p.nombre ilike v_q || '%' then 2
                 else 3
               end) as rango
    from productos p
    where p.organizacion_id = v_org
      and p.tipo <> 'servicio'
      and (p.nombre ilike '%' || v_q || '%'
           or p.sku ilike '%' || v_q || '%'
           or exists (select 1 from producto_codigos pc
                       where pc.producto_id = p.id and pc.codigo = v_q))
    group by p.id
  )
  select p.id, p.nombre, p.sku,
         (select pc.codigo from producto_codigos pc
           where pc.producto_id = p.id
           order by pc.es_principal desc limit 1),
         coalesce(cat.nombre, 'Sin categoria'),
         p.unidad_base,
         fn_precio_vigente(p.id, v_suc, 1),
         coalesce((select sum(e.cantidad) from existencias e
                    where e.producto_id = p.id and e.sucursal_id = v_suc), 0),
         c.rango = 0
  from cand c
  join productos p on p.id = c.id
  left join categorias cat on cat.id = p.categoria_id
  order by c.rango, p.activo desc, p.nombre
  limit greatest(coalesce(p_limite, 20), 1);
end $fn$;

revoke execute on function fn_buscar_para_consulta(text, uuid, int) from public, anon;
grant execute on function fn_buscar_para_consulta(text, uuid, int) to authenticated;


-- ---------------------------------------------------------------------------
-- 8. El perfil completo del producto
--
--    Todo lo que alguien pregunta parado frente al estante, en una sola
--    llamada. Los costos y el margen solo para supervisor y arriba: el
--    auxiliar ve precio y existencia, no cuanto gana el negocio.
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
    -- Cuantos dias antes se considera "por vencer". La leche no avisa con el
    -- mismo plazo que una lata, asi que manda el producto y el negocio
    -- solo pone el valor de fondo.
    'dias_alerta', coalesce(p.dias_alerta_vencim,
                            (select o.dias_alerta_vencimiento from organizaciones o
                              where o.id = p.organizacion_id), 30),

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

    -- Plata: solo de supervisor para arriba
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

    'ubicaciones', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ubicacion_id', x.ubicacion_id, 'nombre', x.ubicacion,
               'predeterminada', x.es_predeterminada, 'cantidad', x.cantidad)
               order by x.orden, x.ubicacion)
      from fn_existencia_por_ubicacion(p.id, v_suc) x), '[]'::jsonb),

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

    -- Si hay un conteo abierto en la sucursal, la pantalla sabe que
    -- "agregar a conteo" suma a ese y no abre otro.
    'conteo_abierto', (
      select jsonb_build_object('conteo_id', c.id, 'numero', c.numero,
                                'alcance', c.alcance)
      from conteos c
      where c.sucursal_id = v_suc and c.estado = 'abierto' limit 1),

    'puede_ver_costos', v_ve
  ) into r;

  return r;
end $fn$;

revoke execute on function fn_consultar_producto(uuid, uuid) from public, anon;
grant execute on function fn_consultar_producto(uuid, uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 9. Las ventas por semana
--
--    Las semanas vacias tambien salen, con cero. Una grafica que se salta
--    las semanas sin venta miente: las dos semanas que no se vendio nada son
--    justo el dato.
-- ---------------------------------------------------------------------------

create or replace function fn_ventas_producto_semanas(
  p_producto_id uuid,
  p_semanas     int  default 5,
  p_sucursal_id uuid default null
)
returns table (
  semana_inicio date,
  semana_fin    date,
  unidades      numeric,
  importe       numeric
)
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org uuid;
  v_suc uuid;
  v_tz  text;
  v_n   int;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para ver ventas';
  end if;

  perform 1 from productos
   where id = p_producto_id and (organizacion_id = v_org or app.es_admin());
  if not found then raise exception 'Ese producto no es de su negocio'; end if;

  v_suc := coalesce(p_sucursal_id,
                    (select s.id from sucursales s
                      where s.organizacion_id = v_org and s.activa
                      order by s.es_principal desc limit 1));
  v_tz  := app.zona(v_org);
  v_n   := least(greatest(coalesce(p_semanas, 5), 1), 26);

  return query
  with hoy as (
    select (now() at time zone v_tz)::date as d
  ),
  semanas as (
    select (date_trunc('week', (select d from hoy)::timestamp)
            - (i || ' weeks')::interval)::date as ini
    from generate_series(0, v_n - 1) as i
  ),
  movidas as (
    select (v.creada_en at time zone v_tz)::date as dia,
           d.cantidad,
           d.total
    from ventas v
    join venta_detalle d on d.venta_id = v.id
    where d.producto_id = p_producto_id
      and v.sucursal_id = v_suc
      and v.estado = 'completada'
      and v.creada_en >= ((select min(ini) from semanas)::timestamp
                          at time zone v_tz)
  )
  select s.ini, (s.ini + 6)::date,
         coalesce(sum(m.cantidad), 0),
         round(coalesce(sum(m.total), 0), 2)
  from semanas s
  left join movidas m on m.dia between s.ini and (s.ini + 6)
  group by s.ini
  order by s.ini;
end $fn$;

revoke execute on function fn_ventas_producto_semanas(uuid, int, uuid) from public, anon;
grant execute on function fn_ventas_producto_semanas(uuid, int, uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 10. Conteo por seleccion
--
--     Contar la categoria entera para revisar tres productos es lo que hace
--     que nadie cuente nunca. Un conteo por seleccion arranca vacio y se le
--     van agregando los productos desde su perfil.
-- ---------------------------------------------------------------------------

alter table conteos drop constraint if exists conteos_alcance_check;
alter table conteos add constraint conteos_alcance_check
  check (alcance in ('general','categoria','proveedor','seleccion'));


create or replace function fn_abrir_conteo(
  p_sucursal_id  uuid default null,
  p_alcance      text default 'general',
  p_categoria_id uuid default null,
  p_proveedor_id uuid default null,
  p_notas        text default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org   uuid;
  v_suc   uuid;
  v_id    uuid;
  v_num   text;
  v_n     int;
begin
  v_org := app.org_id();
  if v_org is null or not app.tiene_nivel('supervisor') then
    raise exception 'Solo un supervisor puede abrir un conteo';
  end if;

  v_suc := coalesce(p_sucursal_id,
                    (select id from sucursales
                      where organizacion_id = v_org and activa
                      order by es_principal desc limit 1));

  perform 1 from sucursales
   where id = v_suc and organizacion_id = v_org and activa;
  if not found then raise exception 'Esa sucursal no es de su negocio'; end if;

  if p_alcance not in ('general','categoria','proveedor','seleccion') then
    raise exception 'Alcance invalido';
  end if;
  if p_alcance = 'categoria' and p_categoria_id is null then
    raise exception 'Indique la categoria a contar';
  end if;
  if p_alcance = 'proveedor' and p_proveedor_id is null then
    raise exception 'Indique el proveedor a contar';
  end if;

  -- Un solo conteo abierto por sucursal. Con dos, dos personas ajustan lo
  -- mismo y el segundo ajuste pisa al primero.
  if exists (select 1 from conteos
              where sucursal_id = v_suc and estado = 'abierto') then
    raise exception 'Ya hay un conteo abierto en esta sucursal. Terminelo o cancelelo primero';
  end if;

  v_num := app.numero_documento(v_org, v_suc, 'conteo', 'C', 6);

  insert into conteos (organizacion_id, sucursal_id, numero, alcance,
                       categoria_id, proveedor_id, notas, abierto_por)
  values (v_org, v_suc, v_num, p_alcance,
          case when p_alcance = 'categoria' then p_categoria_id end,
          case when p_alcance = 'proveedor' then p_proveedor_id end,
          nullif(btrim(coalesce(p_notas,'')), ''), auth.uid())
  returning id into v_id;

  -- El conteo por seleccion arranca vacio a proposito: lo que se cuenta es
  -- lo que alguien manda desde el perfil del producto.
  if p_alcance <> 'seleccion' then
    with alcance as (
      select p.id
      from productos p
      where p.organizacion_id = v_org
        and p.activo and p.tipo <> 'servicio'
        and (p_alcance <> 'categoria' or p.categoria_id = p_categoria_id)
        and (p_alcance <> 'proveedor' or p.proveedor_id = p_proveedor_id)
    ),
    con_lote as (
      select e.producto_id, e.lote_id
      from existencias e
      join alcance a on a.id = e.producto_id
      where e.sucursal_id = v_suc
        and (e.cantidad <> 0 or e.lote_id is null)
    ),
    todas as (
      select producto_id, lote_id from con_lote
      union
      select a.id, null::uuid from alcance a
      where not exists (select 1 from con_lote c where c.producto_id = a.id)
    )
    insert into conteo_detalle (organizacion_id, conteo_id, producto_id, lote_id)
    select v_org, v_id, t.producto_id, t.lote_id from todas t
    on conflict do nothing;
  end if;

  select count(*) into v_n from conteo_detalle where conteo_id = v_id;

  if v_n = 0 and p_alcance <> 'seleccion' then
    raise exception 'No hay productos que contar con ese alcance';
  end if;

  return jsonb_build_object(
    'conteo_id', v_id, 'numero', v_num, 'lineas', v_n,
    'alcance', p_alcance,
    'sucursal', (select nombre from sucursales where id = v_suc));
end $fn$;

revoke execute on function fn_abrir_conteo(uuid, text, uuid, uuid, text) from public, anon;
grant execute on function fn_abrir_conteo(uuid, text, uuid, uuid, text) to authenticated;


-- Agregar un producto al conteo desde su perfil.
--
-- Si ya hay un conteo abierto en la sucursal, se suma a ese: con dos conteos
-- abiertos el segundo ajuste pisaria al primero. Si no hay ninguno, abrir uno
-- es cosa de supervisor, igual que siempre.
create or replace function fn_agregar_a_conteo(
  p_producto_id uuid,
  p_conteo_id   uuid default null,
  p_sucursal_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org    uuid;
  v_suc    uuid;
  c        record;
  v_nuevo  boolean := false;
  v_antes  int;
  v_desp   int;
  v_abre   jsonb;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para contar en este negocio';
  end if;

  if p_conteo_id is not null then
    select * into c from conteos
     where id = p_conteo_id and (organizacion_id = v_org or app.es_admin());
    if c.id is null then raise exception 'Ese conteo no es de su negocio'; end if;
    if c.estado <> 'abierto' then raise exception 'Ese conteo ya se cerro'; end if;
    v_suc := c.sucursal_id;
  else
    v_suc := coalesce(p_sucursal_id,
                      (select s.id from sucursales s
                        where s.organizacion_id = v_org and s.activa
                        order by s.es_principal desc limit 1));
    perform 1 from sucursales where id = v_suc and (organizacion_id = v_org or app.es_admin());
    if not found then raise exception 'Esa sucursal no es de su negocio'; end if;

    select * into c from conteos
     where sucursal_id = v_suc and estado = 'abierto' limit 1;

    if c.id is null then
      -- Abrir exige supervisor; fn_abrir_conteo lo verifica por su cuenta.
      v_abre := fn_abrir_conteo(v_suc, 'seleccion', null, null,
                                'Productos elegidos desde la consulta');
      select * into c from conteos where id = (v_abre->>'conteo_id')::uuid;
      v_nuevo := true;
    end if;
  end if;

  perform 1 from productos
   where id = p_producto_id and organizacion_id = c.organizacion_id
     and activo and tipo <> 'servicio';
  if not found then raise exception 'Ese producto no es de este negocio'; end if;

  select count(*) into v_antes from conteo_detalle
   where conteo_id = c.id and producto_id = p_producto_id;

  -- Una linea por lote con existencia, y una sin lote siempre: "el sistema
  -- dice 0 pero hay 3 en la bodega" es justo el hallazgo que se busca.
  insert into conteo_detalle (organizacion_id, conteo_id, producto_id, lote_id)
  select c.organizacion_id, c.id, p_producto_id, x.lote_id
  from (
    select e.lote_id
    from existencias e
    where e.producto_id = p_producto_id
      and e.sucursal_id = c.sucursal_id
      and e.cantidad <> 0
    union
    select null::uuid
  ) x
  on conflict do nothing;

  select count(*) into v_desp from conteo_detalle
   where conteo_id = c.id and producto_id = p_producto_id;

  return jsonb_build_object(
    'conteo_id', c.id, 'numero', c.numero, 'alcance', c.alcance,
    'conteo_nuevo', v_nuevo,
    'agregadas', v_desp - v_antes,
    'ya_estaba', v_antes > 0,
    'lineas_producto', v_desp,
    'producto', (select nombre from productos where id = p_producto_id));
end $fn$;

revoke execute on function fn_agregar_a_conteo(uuid, uuid, uuid) from public, anon;
grant execute on function fn_agregar_a_conteo(uuid, uuid, uuid) to authenticated;


-- La lista de conteos tenia que decir "Todo el inventario" cuando no habia
-- categoria ni proveedor. Con el alcance nuevo eso seria mentira.
create or replace function fn_conteos(p_limite int default 30)
returns table (
  conteo_id   uuid,
  numero      text,
  estado      text,
  alcance     text,
  detalle     text,
  sucursal    text,
  abierto_por text,
  abierto_en  timestamptz,
  cerrado_en  timestamptz,
  lineas      int,
  contadas    int,
  valor       numeric
)
language sql stable security definer set search_path = public, app as $fn$
  select
    c.id, c.numero, c.estado, c.alcance,
    case c.alcance
      when 'categoria' then coalesce(cat.nombre, 'Categoria')
      when 'proveedor' then coalesce(pv.nombre, 'Proveedor')
      when 'seleccion' then 'Productos elegidos'
      else 'Todo el inventario'
    end,
    s.nombre, pe.nombre, c.abierto_en, c.cerrado_en,
    (select count(*)::int from conteo_detalle d where d.conteo_id = c.id),
    (select count(*)::int from conteo_detalle d
      where d.conteo_id = c.id and d.cantidad_contada is not null),
    case when app.tiene_nivel('supervisor') then c.diferencia_valor end
  from conteos c
  join sucursales s        on s.id = c.sucursal_id
  left join categorias cat on cat.id = c.categoria_id
  left join proveedores pv on pv.id = c.proveedor_id
  left join perfiles pe    on pe.id = c.abierto_por
  where app.tiene_nivel('auxiliar')
    and c.organizacion_id = app.org_id()
    and c.sucursal_id in (select app.sucursales_permitidas())
  order by c.abierto_en desc
  limit greatest(coalesce(p_limite, 30), 1)
$fn$;

revoke execute on function fn_conteos(int) from public, anon;
grant execute on function fn_conteos(int) to authenticated;
