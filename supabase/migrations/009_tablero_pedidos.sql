-- ============================================================================
--  Migración 009 · Tablero de pedidos
--
--  Lo que necesita la tienda para atender pedidos que entran solos:
--   · Realtime bien configurado (replica identity, si no los UPDATE llegan
--     sin los datos viejos y el tablero no sabe de qué columna venía el cambio)
--   · Una vista con todo lo que la tarjeta del pedido muestra, para no hacer
--     seis consultas por pedido
--   · Surtido: marcar qué se pudo despachar de cada línea antes de facturar
--   · Reserva de existencia: un pedido aceptado aparta la mercadería para que
--     la caja no la venda mientras tanto
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Realtime
-- ---------------------------------------------------------------------------

-- Sin esto, un UPDATE llega sin los valores anteriores y el tablero no puede
-- saber si el cambio fue de estado, de repartidor o de otra cosa.
alter table pedidos replica identity full;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'pedidos'
    ) then
      execute 'alter publication supabase_realtime add table pedidos';
    end if;
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 2. Reserva de existencia
--    Un pedido aceptado aparta la mercadería. Sin esto, la caja vende lo que
--    el cliente ya pidió y a la hora de despachar no hay.
--    La reserva NO mueve el kardex: no ha salido nada todavía.
-- ---------------------------------------------------------------------------

create table if not exists pedido_reservas (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  sucursal_id      uuid not null references sucursales(id),
  pedido_id        uuid not null references pedidos(id) on delete cascade,
  producto_id      uuid not null references productos(id),
  cantidad         numeric(14,3) not null check (cantidad > 0),
  liberada_en      timestamptz,
  creada_en        timestamptz not null default now()
);

create index if not exists ix_reservas_vivas on pedido_reservas (producto_id, sucursal_id)
  where liberada_en is null;
create index if not exists ix_reservas_pedido on pedido_reservas (pedido_id);

alter table pedido_reservas enable row level security;

drop policy if exists reservas_sel on pedido_reservas;
create policy reservas_sel on pedido_reservas for select
  using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar')) or app.es_admin());

revoke insert, update, delete on pedido_reservas from authenticated;
grant select on pedido_reservas to authenticated;


-- ---------------------------------------------------------------------------
-- 3. Estado del pedido, con reservas
-- ---------------------------------------------------------------------------

create or replace function fn_cambiar_estado_pedido(
  p_pedido_id uuid,
  p_estado    estado_pedido,
  p_nota      text default null
) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  p record;
  d record;
begin
  select * into p from pedidos where id = p_pedido_id for update;
  if p.id is null then raise exception 'Pedido inexistente'; end if;

  if app.es_repartidor() then
    if p.repartidor_id is distinct from auth.uid() then
      raise exception 'Ese pedido no está asignado a usted';
    end if;
    if p_estado not in ('en_ruta', 'entregado') then
      raise exception 'Un repartidor solo marca en ruta o entregado';
    end if;
  elsif not (app.tiene_nivel('auxiliar') and p.organizacion_id = app.org_id())
        and not app.es_admin() then
    raise exception 'No tiene permiso sobre este pedido';
  end if;

  if p.estado in ('entregado', 'cancelado') then
    raise exception 'El pedido ya está %', p.estado;
  end if;

  if p_estado = 'cancelado' and not (app.tiene_nivel('supervisor') or app.es_admin()) then
    raise exception 'Solo un supervisor puede cancelar un pedido';
  end if;

  -- Al confirmar se aparta la mercadería
  if p_estado = 'confirmado' and p.estado = 'nuevo' then
    for d in
      select producto_id, coalesce(cantidad_surtida, cantidad) as cant
      from pedido_detalle where pedido_id = p_pedido_id
    loop
      insert into pedido_reservas (organizacion_id, sucursal_id, pedido_id, producto_id, cantidad)
      values (p.organizacion_id, p.sucursal_id, p_pedido_id, d.producto_id, d.cant);
    end loop;
  end if;

  -- Al cancelar o entregar se libera lo que quedara apartado
  -- (al facturar, fn_facturar_pedido ya la liberó y movió el kardex)
  if p_estado in ('cancelado', 'entregado') then
    update pedido_reservas set liberada_en = now()
     where pedido_id = p_pedido_id and liberada_en is null;
  end if;

  update pedidos
     set estado = p_estado,
         entregado_en = case when p_estado = 'entregado' then now() else entregado_en end,
         motivo_cancelacion = case when p_estado = 'cancelado' then p_nota else motivo_cancelacion end
   where id = p_pedido_id;

  insert into pedido_eventos (organizacion_id, pedido_id, estado, usuario_id, nota)
  values (p.organizacion_id, p_pedido_id, p_estado, auth.uid(), p_nota);
end $$;

revoke execute on function fn_cambiar_estado_pedido(uuid, estado_pedido, text) from public, anon;
grant  execute on function fn_cambiar_estado_pedido(uuid, estado_pedido, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. Surtir el pedido
--    En una pulpería es normal que falte algo. Se marca cuánto se pudo
--    despachar de cada línea y se recalculan los totales.
-- ---------------------------------------------------------------------------

create or replace function fn_surtir_pedido(p_pedido_id uuid, p_lineas jsonb)
returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p        record;
  it       jsonb;
  lin      record;
  v_sub    numeric := 0;
  v_imp    numeric := 0;
  v_total  numeric := 0;
  v_faltan int := 0;
begin
  select * into p from pedidos where id = p_pedido_id for update;
  if p.id is null then raise exception 'Pedido inexistente'; end if;

  if not ((app.tiene_nivel('auxiliar') and p.organizacion_id = app.org_id()) or app.es_admin()) then
    raise exception 'No tiene permiso sobre este pedido';
  end if;
  if p.venta_id is not null then raise exception 'El pedido ya fue facturado'; end if;
  if p.estado in ('entregado', 'cancelado') then
    raise exception 'El pedido ya está %', p.estado;
  end if;

  -- p_lineas: [{"detalle_id":"...","cantidad_surtida":2}]
  for it in select * from jsonb_array_elements(p_lineas) loop
    update pedido_detalle
       set cantidad_surtida = greatest((it->>'cantidad_surtida')::numeric, 0)
     where id = (it->>'detalle_id')::uuid
       and pedido_id = p_pedido_id;
  end loop;

  for lin in select * from pedido_detalle where pedido_id = p_pedido_id loop
    declare
      v_cant  numeric := coalesce(lin.cantidad_surtida, lin.cantidad);
      v_linea numeric;
    begin
      if v_cant < lin.cantidad then v_faltan := v_faltan + 1; end if;
      v_linea := lin.precio_unitario * v_cant;

      update pedido_detalle set total = v_linea where id = lin.id;

      if lin.impuesto_incluido then
        v_sub := v_sub + (v_linea / (1 + lin.tasa_impuesto));
        v_imp := v_imp + (v_linea - v_linea / (1 + lin.tasa_impuesto));
      else
        v_sub := v_sub + v_linea;
        v_imp := v_imp + (v_linea * lin.tasa_impuesto);
      end if;
    end;
  end loop;

  v_total := round(v_sub + v_imp + coalesce(p.costo_envio, 0), 2);

  update pedidos
     set subtotal = round(v_sub, 2), impuesto = round(v_imp, 2), total = v_total
   where id = p_pedido_id;

  -- Las reservas siguen a lo que realmente se va a despachar.
  -- El alias va con nombre propio: `d` chocaría con la variable del bucle
  -- de arriba y Postgres no sabría a cuál se refiere.
  update pedido_reservas r
     set cantidad = surtido.cant
  from (select pd.producto_id as prod, coalesce(pd.cantidad_surtida, pd.cantidad) as cant
        from pedido_detalle pd where pd.pedido_id = p_pedido_id) as surtido
   where r.pedido_id = p_pedido_id
     and r.producto_id = surtido.prod
     and r.liberada_en is null
     and surtido.cant > 0;

  update pedido_reservas r
     set liberada_en = now()
  from (select pd.producto_id as prod, coalesce(pd.cantidad_surtida, pd.cantidad) as cant
        from pedido_detalle pd where pd.pedido_id = p_pedido_id) as surtido
   where r.pedido_id = p_pedido_id
     and r.producto_id = surtido.prod
     and r.liberada_en is null
     and surtido.cant <= 0;

  insert into pedido_eventos (organizacion_id, pedido_id, estado, usuario_id, nota)
  values (p.organizacion_id, p_pedido_id, p.estado, auth.uid(),
          case when v_faltan > 0
               then 'Surtido con ' || v_faltan || ' faltante(s)'
               else 'Surtido completo' end);

  return jsonb_build_object(
    'subtotal', round(v_sub, 2),
    'impuesto', round(v_imp, 2),
    'envio', coalesce(p.costo_envio, 0),
    'total', v_total,
    'faltantes', v_faltan
  );
end $$;

revoke execute on function fn_surtir_pedido(uuid, jsonb) from public, anon;
grant  execute on function fn_surtir_pedido(uuid, jsonb) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. Facturar el pedido, liberando la reserva
-- ---------------------------------------------------------------------------

create or replace function fn_facturar_pedido(
  p_pedido_id     uuid,
  p_desbloqueo_id uuid,
  p_fiscal        boolean default false
) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p       record;
  v_items jsonb;
  v_pagos jsonb;
  v_res   jsonb;
begin
  select * into p from pedidos where id = p_pedido_id for update;
  if p.id is null then raise exception 'Pedido inexistente'; end if;
  if p.venta_id is not null then raise exception 'El pedido ya fue facturado'; end if;
  if p.estado = 'cancelado' then raise exception 'El pedido está cancelado'; end if;

  select jsonb_agg(jsonb_build_object(
           'producto_id', producto_id,
           'cantidad', coalesce(cantidad_surtida, cantidad)))
    into v_items
  from pedido_detalle
  where pedido_id = p_pedido_id and coalesce(cantidad_surtida, cantidad) > 0;

  if v_items is null then raise exception 'El pedido no tiene nada que surtir'; end if;

  v_pagos := jsonb_build_array(jsonb_build_object(
    'metodo',   p.metodo_pago::text,
    'monto',    p.total,
    'recibido', coalesce(p.paga_con, p.total)));

  -- La reserva se libera ANTES de descargar: si no, el propio pedido se
  -- estorbaría a sí mismo al comprobar la existencia disponible.
  update pedido_reservas set liberada_en = now()
   where pedido_id = p_pedido_id and liberada_en is null;

  v_res := fn_registrar_venta(p_desbloqueo_id, v_items, v_pagos, p.cliente_id, p_fiscal);

  update pedidos set venta_id = (v_res->>'venta_id')::uuid where id = p_pedido_id;

  insert into pedido_eventos (organizacion_id, pedido_id, estado, usuario_id, nota)
  values (p.organizacion_id, p_pedido_id, p.estado, auth.uid(),
          'Facturado: ' || coalesce(v_res->>'numero_fiscal', v_res->>'numero'));

  return v_res || jsonb_build_object('pedido', p.numero);
end $$;

revoke execute on function fn_facturar_pedido(uuid, uuid, boolean) from public, anon;
grant  execute on function fn_facturar_pedido(uuid, uuid, boolean) to authenticated;


-- ---------------------------------------------------------------------------
-- 6. Existencia disponible = física − apartada
-- ---------------------------------------------------------------------------

-- Se recrea porque cambian columnas; CREATE OR REPLACE no permite
-- reordenar ni renombrar columnas de una vista existente.
drop view if exists v_pos_catalogo;

create view v_pos_catalogo as
select
  p.organizacion_id,
  s.id                                as sucursal_id,
  p.id                                as producto_id,
  p.sku,
  p.nombre,
  p.imagen_url,
  p.tipo,
  p.unidad_base,
  c.id                                as categoria_id,
  coalesce(c.nombre, 'Sin categoría') as categoria,
  coalesce(i.tasa, 0)                 as tasa_impuesto,
  fn_precio_vigente(p.id, s.id, 1)    as precio,
  coalesce(ex.cantidad, 0)            as existencia_fisica,
  coalesce(rv.cantidad, 0)            as apartado,
  greatest(coalesce(ex.cantidad, 0) - coalesce(rv.cantidad, 0), 0) as existencia,
  p.stock_minimo,
  coalesce(ex.cantidad, 0) <= p.stock_minimo as stock_bajo,
  (select min(l.fecha_vencimiento)
     from lotes l join existencias e2 on e2.lote_id = l.id and e2.cantidad > 0
    where l.producto_id = p.id and l.sucursal_id = s.id) as vence_el,
  array(select codigo from producto_codigos pc where pc.producto_id = p.id) as codigos
from productos p
cross join sucursales s
left join categorias c on c.id = p.categoria_id
left join impuestos i on i.id = p.impuesto_id
left join (
  select producto_id, sucursal_id, sum(cantidad) as cantidad
  from existencias group by producto_id, sucursal_id
) ex on ex.producto_id = p.id and ex.sucursal_id = s.id
left join (
  select producto_id, sucursal_id, sum(cantidad) as cantidad
  from pedido_reservas where liberada_en is null
  group by producto_id, sucursal_id
) rv on rv.producto_id = p.id and rv.sucursal_id = s.id
where p.activo and p.se_vende
  and s.organizacion_id = p.organizacion_id
  and s.activa;

alter view v_pos_catalogo set (security_invoker = on);
grant select on v_pos_catalogo to authenticated;


-- ---------------------------------------------------------------------------
-- 7. El tablero
--    Todo lo que muestra la tarjeta de un pedido, en una sola fila.
-- ---------------------------------------------------------------------------

drop view if exists v_pedidos_tablero;
create view v_pedidos_tablero as
select
  p.id,
  p.organizacion_id,
  p.sucursal_id,
  p.numero,
  p.origen,
  p.estado,
  p.tipo_entrega,
  p.creado_en,
  p.programado_para,
  p.entregado_en,
  p.total,
  p.costo_envio,
  p.metodo_pago,
  p.paga_con,
  p.notas,
  p.venta_id,
  p.motivo_cancelacion,
  p.cliente_id,
  coalesce(cl.nombre, p.nombre_contacto, 'Cliente de mostrador') as cliente,
  coalesce(cl.telefono, p.telefono_contacto)                     as telefono,
  coalesce(p.direccion_texto, dc.direccion)                      as direccion,
  coalesce(dc.referencia, p.referencia)                          as referencia,
  dc.latitud, dc.longitud,
  p.repartidor_id,
  rp.nombre                                                      as repartidor,
  (select count(*) from pedido_detalle d where d.pedido_id = p.id)          as lineas,
  (select coalesce(sum(d.cantidad), 0) from pedido_detalle d where d.pedido_id = p.id) as unidades,
  -- minutos desde que entró, para poner en rojo lo que lleva mucho esperando
  floor(extract(epoch from (now() - p.creado_en)) / 60)::int      as minutos,
  -- ¿algún producto sin existencia suficiente para despacharlo?
  exists (
    select 1
    from pedido_detalle d
    join (select producto_id, sucursal_id, sum(cantidad) as hay
          from existencias group by producto_id, sucursal_id) e
      on e.producto_id = d.producto_id and e.sucursal_id = p.sucursal_id
    where d.pedido_id = p.id
      and e.hay < coalesce(d.cantidad_surtida, d.cantidad)
  ) as tiene_faltantes
from pedidos p
left join clientes cl            on cl.id = p.cliente_id
left join direcciones_cliente dc on dc.id = p.direccion_id
left join perfiles rp            on rp.id = p.repartidor_id;

alter view v_pedidos_tablero set (security_invoker = on);
grant select on v_pedidos_tablero to authenticated;


-- Las líneas de un pedido, con existencia al momento
create or replace function fn_pedido_lineas(p_pedido_id uuid)
returns table (
  detalle_id       uuid,
  producto_id      uuid,
  producto         text,
  sku              text,
  unidad           text,
  cantidad         numeric,
  cantidad_surtida numeric,
  precio_unitario  numeric,
  total            numeric,
  nota             text,
  existencia       numeric
)
language sql stable security definer set search_path = public, app as $$
  select
    d.id, d.producto_id, pr.nombre, pr.sku, pr.unidad_base,
    d.cantidad, d.cantidad_surtida, d.precio_unitario, d.total, d.nota,
    coalesce((select sum(e.cantidad) from existencias e
              where e.producto_id = d.producto_id and e.sucursal_id = p.sucursal_id), 0)
  from pedido_detalle d
  join pedidos p   on p.id = d.pedido_id
  join productos pr on pr.id = d.producto_id
  where d.pedido_id = p_pedido_id
    and (
      app.es_admin()
      or (p.organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))
      or p.repartidor_id = auth.uid()
      or p.cliente_id in (select id from clientes where usuario_id = auth.uid())
    )
  order by pr.nombre
$$;

revoke execute on function fn_pedido_lineas(uuid) from public, anon;
grant  execute on function fn_pedido_lineas(uuid) to authenticated;


-- Repartidores disponibles, para el selector del tablero
create or replace function fn_repartidores()
returns table (id uuid, nombre text, activos int)
language sql stable security definer set search_path = public, app as $$
  select pf.id, pf.nombre,
         (select count(*)::int from pedidos pd
           where pd.repartidor_id = pf.id
             and pd.estado in ('listo', 'en_ruta'))
  from perfiles pf
  where pf.organizacion_id = app.org_id()
    and pf.activo
    and pf.rol::text = 'repartidor'
    and (app.tiene_nivel('auxiliar') or app.es_admin())
  order by pf.nombre
$$;

revoke execute on function fn_repartidores() from public, anon;
grant  execute on function fn_repartidores() to authenticated;


-- ---------------------------------------------------------------------------
-- 8. Resumen del día, para la barra del tablero
-- ---------------------------------------------------------------------------

create or replace function fn_pedidos_resumen(p_sucursal_id uuid default null)
returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'nuevos',     count(*) filter (where estado = 'nuevo'),
    'en_proceso', count(*) filter (where estado in ('confirmado','preparando','listo')),
    'en_ruta',    count(*) filter (where estado = 'en_ruta'),
    'entregados', count(*) filter (where estado = 'entregado'
                                     and entregado_en >= date_trunc('day', now())),
    'vendido_hoy', coalesce(sum(total) filter (where estado = 'entregado'
                                     and entregado_en >= date_trunc('day', now())), 0),
    'espera_max', coalesce(max(floor(extract(epoch from (now() - creado_en)) / 60))
                    filter (where estado in ('nuevo','confirmado','preparando')), 0)
  )
  from pedidos
  where organizacion_id = app.org_id()
    and (p_sucursal_id is null or sucursal_id = p_sucursal_id)
    and (estado <> 'entregado' or entregado_en >= date_trunc('day', now()))
    and (estado <> 'cancelado' or creado_en >= date_trunc('day', now()))
$$;

revoke execute on function fn_pedidos_resumen(uuid) from public, anon;
grant  execute on function fn_pedidos_resumen(uuid) to authenticated;


-- ============================================================================
--  9. CATÁLOGO PARA LA APP DEL CLIENTE
--
--  Al probar el flujo salió que un cliente autenticado veía CERO productos:
--  las políticas de `productos`, `precios` y `categorias` exigen pertenecer
--  a la organización (app.org_id()), y un cliente no tiene perfil de personal.
--  La app del cliente no habría podido mostrar nada.
--
--  No se relaja la RLS de esas tablas: se expone una función que devuelve
--  solo lo que un comprador debe ver —nombre, precio, si hay o no— y nunca
--  costos, márgenes ni existencias exactas.
-- ============================================================================

-- Qué tiendas puede ver este cliente
create or replace function fn_tiendas_cliente()
returns table (
  organizacion_id uuid,
  negocio         text,
  sucursal_id     uuid,
  sucursal        text,
  direccion       text,
  telefono        text,
  moneda          text
)
language sql stable security definer set search_path = public, app as $$
  select o.id, o.nombre, s.id, s.nombre, s.direccion, s.telefono, o.moneda
  from clientes c
  join organizaciones o on o.id = c.organizacion_id and o.activa
  join sucursales s     on s.organizacion_id = o.id and s.activa
  where c.usuario_id = auth.uid() and c.activo
  order by s.es_principal desc, s.nombre
$$;

-- Catálogo que ve el comprador.
-- `disponible` es booleano a propósito: al cliente no le incumbe cuántas
-- unidades hay, y publicar el inventario exacto de un negocio sería un
-- descuido con la información de la tienda.
create or replace function fn_catalogo_cliente(
  p_sucursal_id uuid default null,
  p_busqueda    text default null
)
returns table (
  producto_id   uuid,
  nombre        text,
  imagen_url    text,
  categoria_id  uuid,
  categoria     text,
  precio        numeric,
  unidad        text,
  disponible    boolean,
  sucursal_id   uuid
)
language sql stable security definer set search_path = public, app as $$
  with mias as (
    select c.organizacion_id
    from clientes c
    where c.usuario_id = auth.uid() and c.activo
  ),
  suc as (
    select s.id, s.organizacion_id
    from sucursales s
    join mias m on m.organizacion_id = s.organizacion_id
    where s.activa
      and (p_sucursal_id is null or s.id = p_sucursal_id)
  )
  select
    p.id,
    p.nombre,
    p.imagen_url,
    p.categoria_id,
    coalesce(c.nombre, 'Sin categoría'),
    fn_precio_vigente(p.id, suc.id, 1),
    p.unidad_base,
    greatest(coalesce(ex.cantidad, 0) - coalesce(rv.cantidad, 0), 0) > 0,
    suc.id
  from suc
  join productos p on p.organizacion_id = suc.organizacion_id
                   and p.activo and p.se_vende
  left join categorias c on c.id = p.categoria_id
  left join (
    select producto_id, sucursal_id, sum(cantidad) as cantidad
    from existencias group by producto_id, sucursal_id
  ) ex on ex.producto_id = p.id and ex.sucursal_id = suc.id
  left join (
    select producto_id, sucursal_id, sum(cantidad) as cantidad
    from pedido_reservas where liberada_en is null
    group by producto_id, sucursal_id
  ) rv on rv.producto_id = p.id and rv.sucursal_id = suc.id
  where fn_precio_vigente(p.id, suc.id, 1) is not null
    and (p_busqueda is null or p_busqueda = ''
         or p.nombre ilike '%' || p_busqueda || '%')
  order by c.nombre nulls last, p.nombre
$$;

-- Los pedidos del cliente, para la pantalla de seguimiento
create or replace function fn_mis_pedidos(p_limite int default 20)
returns table (
  pedido_id    uuid,
  numero       text,
  estado       estado_pedido,
  creado_en    timestamptz,
  entregado_en timestamptz,
  total        numeric,
  costo_envio  numeric,
  tipo_entrega tipo_entrega,
  direccion    text,
  repartidor   text,
  lineas       int,
  negocio      text
)
language sql stable security definer set search_path = public, app as $$
  select
    p.id, p.numero, p.estado, p.creado_en, p.entregado_en,
    p.total, p.costo_envio, p.tipo_entrega,
    coalesce(p.direccion_texto, dc.direccion),
    rp.nombre,
    (select count(*)::int from pedido_detalle d where d.pedido_id = p.id),
    o.nombre
  from pedidos p
  join organizaciones o            on o.id = p.organizacion_id
  left join direcciones_cliente dc on dc.id = p.direccion_id
  left join perfiles rp            on rp.id = p.repartidor_id
  where p.cliente_id in (select id from clientes where usuario_id = auth.uid())
  order by p.creado_en desc
  limit greatest(coalesce(p_limite, 20), 1)
$$;

-- Cancelar el propio pedido, solo mientras la tienda no lo haya aceptado
create or replace function fn_cancelar_mi_pedido(p_pedido_id uuid, p_motivo text default null)
returns void
language plpgsql security definer set search_path = public, app as $$
declare p record;
begin
  select * into p from pedidos where id = p_pedido_id for update;
  if p.id is null then raise exception 'Pedido inexistente'; end if;

  if p.cliente_id not in (select id from clientes where usuario_id = auth.uid()) then
    raise exception 'Ese pedido no es suyo';
  end if;

  if p.estado <> 'nuevo' then
    raise exception 'La tienda ya empezó a prepararlo. Llame para cancelarlo.';
  end if;

  update pedido_reservas set liberada_en = now()
   where pedido_id = p_pedido_id and liberada_en is null;

  update pedidos
     set estado = 'cancelado',
         motivo_cancelacion = coalesce(p_motivo, 'Cancelado por el cliente')
   where id = p_pedido_id;

  insert into pedido_eventos (organizacion_id, pedido_id, estado, usuario_id, nota)
  values (p.organizacion_id, p_pedido_id, 'cancelado', null,
          coalesce(p_motivo, 'Cancelado por el cliente'));
end $$;

revoke execute on function fn_tiendas_cliente()                 from public, anon;
revoke execute on function fn_catalogo_cliente(uuid, text)      from public, anon;
revoke execute on function fn_mis_pedidos(int)                  from public, anon;
revoke execute on function fn_cancelar_mi_pedido(uuid, text)    from public, anon;

grant execute on function fn_tiendas_cliente()              to authenticated;
grant execute on function fn_catalogo_cliente(uuid, text)   to authenticated;
grant execute on function fn_mis_pedidos(int)               to authenticated;
grant execute on function fn_cancelar_mi_pedido(uuid, text) to authenticated;
