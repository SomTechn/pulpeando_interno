-- ============================================================================
--  ABARROTES SaaS · Migración 003 · Pedidos, permisos y RPCs del POS
--
--  · Un pedido se crea desde el panel del negocio (mostrador, teléfono,
--    WhatsApp) o desde la app del cliente. Misma función, misma validación
--    de precios, distinto camino de autorización.
--  · Corrige un permiso que faltaba: sin USAGE sobre el esquema `app`,
--    todas las políticas RLS fallaban para el rol authenticated.
--  · RPCs que la PWA del POS necesita para arrancar en una sola llamada.
-- ============================================================================

-- ============================================================================
-- 0. PERMISOS DE ESQUEMA  ← sin esto, la app no puede leer NADA
-- ============================================================================

grant usage on schema app to authenticated, anon, service_role;
grant execute on all functions in schema app to authenticated, anon, service_role;
alter default privileges in schema app
  grant execute on functions to authenticated, anon, service_role;

-- Las funciones de caja y venta las llama la PWA con el usuario autenticado
grant execute on function fn_registrar_venta(uuid, jsonb, jsonb, uuid, boolean) to authenticated;
grant execute on function fn_desbloquear_caja(uuid, text)                       to authenticated;
grant execute on function fn_abrir_turno(uuid, uuid, text, numeric)             to authenticated;
grant execute on function fn_cerrar_turno(uuid, numeric, text)                  to authenticated;
grant execute on function fn_establecer_pin(uuid, text)                         to authenticated;
grant execute on function fn_anular_venta(uuid, text)                           to authenticated;
grant execute on function fn_confirmar_factura_compra(uuid)                     to authenticated;
grant execute on function fn_precio_vigente(uuid, uuid, numeric, nivel_precio)  to authenticated;
grant execute on function fn_lotes_fefo(uuid, uuid)                             to authenticated;

-- fn_kardex_registrar NO se expone: el inventario solo se mueve por documento
revoke execute on function fn_kardex_registrar(uuid, uuid, tipo_movimiento, numeric, numeric, uuid, text, uuid, text, uuid) from public, anon, authenticated;


-- ============================================================================
-- 1. ACCESO A SUCURSALES
--    Un auxiliar sin asignación se quedaba sin nada que ver. Si la
--    organización tiene una sola sucursal no hay nada que aislar, así que
--    todo su personal la ve. Con dos o más, la asignación vuelve a ser
--    obligatoria.
-- ============================================================================

create or replace function app.sucursales_permitidas()
returns setof uuid stable language sql security definer set search_path = public, app as $$
  select s.id
  from sucursales s
  join perfiles p on p.id = auth.uid() and p.activo
  where s.organizacion_id = p.organizacion_id
    and s.activa
    and app.nivel_rol(p.rol) >= 1
    and (
      app.nivel_rol(p.rol) >= app.nivel_rol('gerente')
      or exists (select 1 from usuario_sucursales us
                 where us.perfil_id = p.id and us.sucursal_id = s.id)
      or (select count(*) from sucursales s2
           where s2.organizacion_id = p.organizacion_id and s2.activa) = 1
    )
$$;


-- ============================================================================
-- 2. TIPOS
-- ============================================================================

create type origen_pedido as enum ('mostrador', 'telefono', 'whatsapp', 'app_cliente');

create type estado_pedido as enum (
  'nuevo', 'confirmado', 'preparando', 'listo', 'en_ruta', 'entregado', 'cancelado'
);

create type tipo_entrega as enum ('domicilio', 'recoge_en_tienda');


-- ============================================================================
-- 2. DIRECCIONES DEL CLIENTE
-- ============================================================================

create table direcciones_cliente (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  cliente_id       uuid not null references clientes(id) on delete cascade,
  etiqueta         text not null default 'Casa',
  direccion        text not null,
  referencia       text,
  telefono         text,
  latitud          numeric(10,7),
  longitud         numeric(10,7),
  es_principal     boolean not null default false,
  activa           boolean not null default true,
  creada_en        timestamptz not null default now()
);

create index ix_dir_cliente on direcciones_cliente (cliente_id) where activa;


-- ============================================================================
-- 3. PEDIDOS
-- ============================================================================

create table pedidos (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  sucursal_id      uuid not null references sucursales(id),
  numero           text not null,
  origen           origen_pedido not null,
  tipo_entrega     tipo_entrega not null default 'domicilio',
  estado           estado_pedido not null default 'nuevo',

  cliente_id       uuid references clientes(id),
  nombre_contacto  text,                      -- pedidos de mostrador sin ficha
  telefono_contacto text,
  direccion_id     uuid references direcciones_cliente(id),
  direccion_texto  text,
  referencia       text,

  repartidor_id    uuid references perfiles(id),
  creado_por       uuid references perfiles(id),   -- null si lo hizo el cliente

  subtotal         numeric(16,4) not null default 0,
  impuesto         numeric(16,4) not null default 0,
  costo_envio      numeric(16,4) not null default 0,
  descuento        numeric(16,4) not null default 0,
  total            numeric(16,4) not null default 0,
  metodo_pago      metodo_pago not null default 'efectivo',
  paga_con         numeric(16,4),              -- para llevar el cambio

  venta_id         uuid references ventas(id),  -- se llena al facturar
  notas            text,
  motivo_cancelacion text,

  programado_para  timestamptz,
  creado_en        timestamptz not null default now(),
  actualizado_en   timestamptz not null default now(),
  entregado_en     timestamptz,
  unique (organizacion_id, numero)
);

create table pedido_detalle (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  pedido_id        uuid not null references pedidos(id) on delete cascade,
  producto_id      uuid not null references productos(id),
  cantidad         numeric(14,3) not null check (cantidad > 0),
  cantidad_surtida numeric(14,3),              -- lo que realmente se pudo surtir
  precio_unitario  numeric(14,4) not null,
  tasa_impuesto    numeric(6,4) not null default 0,
  impuesto_incluido boolean not null default true,
  total            numeric(16,4) not null default 0,
  nota             text
);

create table pedido_eventos (
  id               bigserial primary key,
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  pedido_id        uuid not null references pedidos(id) on delete cascade,
  estado           estado_pedido not null,
  usuario_id       uuid references perfiles(id),
  nota             text,
  ocurrido_en      timestamptz not null default now()
);

create index ix_pedidos_tablero on pedidos (organizacion_id, sucursal_id, estado, creado_en desc);
create index ix_pedidos_repartidor on pedidos (repartidor_id, estado);
create index ix_pedidos_cliente on pedidos (cliente_id, creado_en desc);
create index ix_pd_pedido on pedido_detalle (pedido_id);

create trigger tg_pedidos_upd before update on pedidos
  for each row execute function app.set_actualizado_en();


-- ---------------------------------------------------------------------------
--  Crear pedido. Un solo camino para los dos orígenes.
--
--  Desde el panel del negocio: el auxiliar manda cliente_id (o solo nombre
--  y teléfono si es alguien de paso) y elige el origen.
--  Desde la app del cliente:   no manda organizacion ni cliente; se deducen
--  de su sesión y el origen se fuerza a 'app_cliente'.
--
--  Los precios SIEMPRE se resuelven en el servidor. El cliente nunca
--  decide cuánto cuesta lo que pide.
-- ---------------------------------------------------------------------------
create or replace function fn_crear_pedido(
  p_items            jsonb,
  p_sucursal_id      uuid    default null,
  p_cliente_id       uuid    default null,
  p_origen           origen_pedido default 'app_cliente',
  p_tipo_entrega     tipo_entrega  default 'domicilio',
  p_direccion_id     uuid    default null,
  p_direccion_texto  text    default null,
  p_nombre_contacto  text    default null,
  p_telefono_contacto text   default null,
  p_metodo_pago      metodo_pago default 'efectivo',
  p_paga_con         numeric default null,
  p_costo_envio      numeric default 0,
  p_notas            text    default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_es_staff   boolean;
  v_org        uuid;
  v_sucursal   uuid;
  v_cliente    uuid;
  v_origen     origen_pedido;
  v_creado_por uuid;
  v_pedido     uuid;
  v_numero     text;
  it           jsonb;
  v_prod       record;
  v_cant       numeric;
  v_precio     numeric;
  v_linea      numeric;
  v_sub        numeric := 0;
  v_imp        numeric := 0;
  v_total      numeric := 0;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'El pedido no tiene productos';
  end if;

  v_es_staff := app.org_id() is not null and app.tiene_nivel('auxiliar');

  if v_es_staff then
    -- ---- pedido levantado en el panel del negocio ----
    v_org        := app.org_id();
    v_cliente    := p_cliente_id;
    v_origen     := coalesce(p_origen, 'mostrador');
    v_creado_por := auth.uid();
    v_sucursal   := coalesce(p_sucursal_id,
                             (select id from sucursales
                               where organizacion_id = v_org and activa
                               order by es_principal desc limit 1));
    if v_origen = 'app_cliente' then
      v_origen := 'mostrador';   -- el origen debe reflejar la realidad
    end if;
  else
    -- ---- pedido hecho por el cliente desde su app ----
    select id, organizacion_id into v_cliente, v_org
    from clientes where usuario_id = auth.uid() and activo
    limit 1;

    if v_cliente is null then
      raise exception 'Debe iniciar sesión como cliente para hacer un pedido';
    end if;

    v_origen     := 'app_cliente';
    v_creado_por := null;
    v_sucursal   := coalesce(p_sucursal_id,
                             (select id from sucursales
                               where organizacion_id = v_org and activa
                               order by es_principal desc limit 1));

    if p_tipo_entrega = 'domicilio' and p_direccion_id is null and p_direccion_texto is null then
      raise exception 'Indique la dirección de entrega';
    end if;
  end if;

  if v_sucursal is null then
    raise exception 'No hay sucursal disponible para tomar el pedido';
  end if;

  v_numero := 'P-' || lpad(fn_siguiente_numero(v_org, v_sucursal, 'pedido')::text, 6, '0');

  insert into pedidos (
    organizacion_id, sucursal_id, numero, origen, tipo_entrega,
    cliente_id, nombre_contacto, telefono_contacto,
    direccion_id, direccion_texto, creado_por,
    metodo_pago, paga_con, costo_envio, notas
  ) values (
    v_org, v_sucursal, v_numero, v_origen, p_tipo_entrega,
    v_cliente, p_nombre_contacto, p_telefono_contacto,
    p_direccion_id,
    coalesce(p_direccion_texto, (select direccion from direcciones_cliente where id = p_direccion_id)),
    v_creado_por, p_metodo_pago, p_paga_con, coalesce(p_costo_envio, 0), p_notas
  ) returning id into v_pedido;

  for it in select * from jsonb_array_elements(p_items) loop
    select p.*, coalesce(i.tasa, 0) as tasa, coalesce(i.incluido_en_precio, true) as incluido
      into v_prod
    from productos p
    left join impuestos i on i.id = p.impuesto_id
    where p.id = (it->>'producto_id')::uuid
      and p.organizacion_id = v_org
      and p.activo and p.se_vende;

    if v_prod.id is null then
      raise exception 'Producto no disponible';
    end if;

    v_cant := (it->>'cantidad')::numeric;
    if v_cant is null or v_cant <= 0 then
      raise exception 'Cantidad inválida en %', v_prod.nombre;
    end if;

    v_precio := coalesce(fn_precio_vigente(v_prod.id, v_sucursal, v_cant), 0);
    if v_precio = 0 then
      raise exception 'El producto % no tiene precio asignado', v_prod.nombre;
    end if;

    v_linea := v_precio * v_cant;

    insert into pedido_detalle (organizacion_id, pedido_id, producto_id, cantidad,
                                precio_unitario, tasa_impuesto, impuesto_incluido, total,
                                nota)
    values (v_org, v_pedido, v_prod.id, v_cant, v_precio, v_prod.tasa,
            v_prod.incluido, v_linea, it->>'nota');

    if v_prod.incluido then
      v_sub := v_sub + (v_linea / (1 + v_prod.tasa));
      v_imp := v_imp + (v_linea - v_linea / (1 + v_prod.tasa));
    else
      v_sub := v_sub + v_linea;
      v_imp := v_imp + (v_linea * v_prod.tasa);
    end if;
  end loop;

  v_total := round(v_sub + v_imp + coalesce(p_costo_envio, 0), 2);

  update pedidos
     set subtotal = round(v_sub, 2), impuesto = round(v_imp, 2), total = v_total
   where id = v_pedido;

  insert into pedido_eventos (organizacion_id, pedido_id, estado, usuario_id, nota)
  values (v_org, v_pedido, 'nuevo', v_creado_por, 'Pedido creado desde ' || v_origen);

  return jsonb_build_object(
    'pedido_id', v_pedido,
    'numero', v_numero,
    'origen', v_origen,
    'subtotal', round(v_sub, 2),
    'impuesto', round(v_imp, 2),
    'envio', coalesce(p_costo_envio, 0),
    'total', v_total
  );
end $$;


-- Cambiar estado. El repartidor solo puede mover los suyos y solo hacia adelante.
create or replace function fn_cambiar_estado_pedido(
  p_pedido_id uuid,
  p_estado    estado_pedido,
  p_nota      text default null
) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  p record;
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
  elsif not (app.tiene_nivel('auxiliar') and p.organizacion_id = app.org_id()) and not app.es_admin() then
    raise exception 'No tiene permiso sobre este pedido';
  end if;

  if p.estado in ('entregado', 'cancelado') then
    raise exception 'El pedido ya está %', p.estado;
  end if;

  if p_estado = 'cancelado' and not (app.tiene_nivel('supervisor') or app.es_admin()) then
    raise exception 'Solo un supervisor puede cancelar un pedido';
  end if;

  update pedidos
     set estado = p_estado,
         entregado_en = case when p_estado = 'entregado' then now() else entregado_en end,
         motivo_cancelacion = case when p_estado = 'cancelado' then p_nota else motivo_cancelacion end
   where id = p_pedido_id;

  insert into pedido_eventos (organizacion_id, pedido_id, estado, usuario_id, nota)
  values (p.organizacion_id, p_pedido_id, p_estado, auth.uid(), p_nota);
end $$;


create or replace function fn_asignar_repartidor(p_pedido_id uuid, p_repartidor_id uuid)
returns void
language plpgsql security definer set search_path = public, app as $$
declare p record; r record;
begin
  select * into p from pedidos where id = p_pedido_id;
  if p.id is null then raise exception 'Pedido inexistente'; end if;

  if not ((app.tiene_nivel('auxiliar') and p.organizacion_id = app.org_id()) or app.es_admin()) then
    raise exception 'No tiene permiso para asignar repartidores';
  end if;

  select * into r from perfiles where id = p_repartidor_id and activo;
  if r.id is null or r.organizacion_id <> p.organizacion_id then
    raise exception 'Repartidor inexistente';
  end if;
  if r.rol::text <> 'repartidor' then
    raise exception 'Ese usuario no es repartidor';
  end if;

  update pedidos set repartidor_id = p_repartidor_id where id = p_pedido_id;

  insert into pedido_eventos (organizacion_id, pedido_id, estado, usuario_id, nota)
  values (p.organizacion_id, p_pedido_id, p.estado, auth.uid(), 'Asignado a ' || r.nombre);
end $$;


-- Convertir el pedido en venta: descarga inventario y cobra.
-- Necesita la caja desbloqueada, igual que cualquier venta.
create or replace function fn_facturar_pedido(
  p_pedido_id     uuid,
  p_desbloqueo_id uuid,
  p_fiscal        boolean default false
) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p        record;
  v_items  jsonb;
  v_pagos  jsonb;
  v_res    jsonb;
begin
  select * into p from pedidos where id = p_pedido_id for update;
  if p.id is null then raise exception 'Pedido inexistente'; end if;
  if p.venta_id is not null then raise exception 'El pedido ya fue facturado'; end if;
  if p.estado = 'cancelado' then raise exception 'El pedido está cancelado'; end if;

  select jsonb_agg(jsonb_build_object(
           'producto_id', producto_id,
           'cantidad', coalesce(cantidad_surtida, cantidad)))
    into v_items
  from pedido_detalle where pedido_id = p_pedido_id
    and coalesce(cantidad_surtida, cantidad) > 0;

  if v_items is null then raise exception 'El pedido no tiene nada que surtir'; end if;

  v_pagos := jsonb_build_array(jsonb_build_object(
    'metodo', p.metodo_pago::text,
    'monto',  p.total,
    'recibido', coalesce(p.paga_con, p.total)));

  v_res := fn_registrar_venta(p_desbloqueo_id, v_items, v_pagos, p.cliente_id, p_fiscal);

  update pedidos set venta_id = (v_res->>'venta_id')::uuid where id = p_pedido_id;

  return v_res || jsonb_build_object('pedido', p.numero);
end $$;


-- ============================================================================
-- 4. RLS DE PEDIDOS
-- ============================================================================

alter table pedidos             enable row level security;
alter table pedido_detalle      enable row level security;
alter table pedido_eventos      enable row level security;
alter table direcciones_cliente enable row level security;

-- Personal de tienda: los de su organización.
-- Repartidor: solo los asignados a él.
-- Cliente: solo los suyos.
create policy pedidos_sel on pedidos for select
  using (
    app.es_admin()
    or (organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))
    or (repartidor_id = auth.uid())
    or (cliente_id in (select id from clientes where usuario_id = auth.uid()))
  );

create policy pedidos_upd on pedidos for update
  using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar')) or app.es_admin())
  with check ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar')) or app.es_admin());

create policy pd_sel on pedido_detalle for select
  using (pedido_id in (select id from pedidos));

create policy pe_sel on pedido_eventos for select
  using (pedido_id in (select id from pedidos));

create policy dir_sel on direcciones_cliente for select
  using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))
         or cliente_id in (select id from clientes where usuario_id = auth.uid())
         or app.es_admin());

create policy dir_cliente_esc on direcciones_cliente for all
  using (cliente_id in (select id from clientes where usuario_id = auth.uid()))
  with check (cliente_id in (select id from clientes where usuario_id = auth.uid()));

create policy dir_staff_esc on direcciones_cliente for all
  using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar')) or app.es_admin())
  with check ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar')) or app.es_admin());

grant execute on function fn_crear_pedido(jsonb, uuid, uuid, origen_pedido, tipo_entrega, uuid, text, text, text, metodo_pago, numeric, numeric, text) to authenticated;
grant execute on function fn_cambiar_estado_pedido(uuid, estado_pedido, text) to authenticated;
grant execute on function fn_asignar_repartidor(uuid, uuid) to authenticated;
grant execute on function fn_facturar_pedido(uuid, uuid, boolean) to authenticated;

-- Realtime para el tablero de pedidos y la app del cliente
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    execute 'alter publication supabase_realtime add table pedidos';
  end if;
end $$;


-- ============================================================================
-- 5. LO QUE EL POS NECESITA PARA ARRANCAR
-- ============================================================================

-- Catálogo listo para la cuadrícula: precio, existencia y alertas en una fila
create view v_pos_catalogo as
select
  p.organizacion_id,
  s.id                              as sucursal_id,
  p.id                              as producto_id,
  p.sku,
  p.nombre,
  p.imagen_url,
  p.tipo,
  p.unidad_base,
  c.id                              as categoria_id,
  coalesce(c.nombre, 'Sin categoría') as categoria,
  coalesce(i.tasa, 0)               as tasa_impuesto,
  fn_precio_vigente(p.id, s.id, 1)  as precio,
  coalesce(ex.cantidad, 0)          as existencia,
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
where p.activo and p.se_vende
  and s.organizacion_id = p.organizacion_id
  and s.activa;

-- Todo lo que la PWA necesita saber al abrir: quién soy, dónde estoy,
-- qué caja me toca y si hay turno abierto.
create or replace function fn_pos_contexto()
returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_perfil record;
  v_org    record;
  v_res    jsonb;
begin
  select * into v_perfil from perfiles where id = auth.uid() and activo;
  if v_perfil.id is null then
    raise exception 'Usuario sin perfil activo';
  end if;

  select * into v_org from organizaciones where id = v_perfil.organizacion_id;

  select jsonb_build_object(
    'usuario', jsonb_build_object(
      'id', v_perfil.id,
      'nombre', v_perfil.nombre,
      'rol', v_perfil.rol,
      'nivel', app.nivel_rol(v_perfil.rol),
      'tiene_pin', v_perfil.pin_pos is not null
    ),
    'organizacion', jsonb_build_object(
      'id', v_org.id,
      'nombre', v_org.nombre,
      'moneda', v_org.moneda,
      'factura_fiscal', v_org.facturacion_fiscal_activa
    ),
    'sucursales', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'nombre', s.nombre, 'codigo', s.codigo)
             order by s.es_principal desc, s.nombre)
      from sucursales s where s.id in (select app.sucursales_permitidas())
    ), '[]'::jsonb),
    'cajas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'caja_id', ec.caja_id, 'caja', ec.caja,
               'sucursal_id', ec.sucursal_id,
               'turno_id', ec.turno_id, 'cajero', ec.cajero,
               'cajero_id', ec.cajero_id,
               'desbloqueada', ec.desbloqueada,
               'ventas_turno', ec.ventas_turno,
               'total_turno', ec.total_turno))
      from v_estado_cajas ec
      where ec.sucursal_id in (select app.sucursales_permitidas())
    ), '[]'::jsonb),
    'impuesto_default', coalesce((
      select tasa from impuestos
      where organizacion_id = v_perfil.organizacion_id and es_predeterminado and activo
      limit 1), 0),
    'sin_sucursal', not exists (select 1 from app.sucursales_permitidas())
  ) into v_res;

  return v_res;
end $$;

grant execute on function fn_pos_contexto() to authenticated;
grant select on v_pos_catalogo to authenticated;
grant select on v_existencias, v_vencimientos, v_stock_bajo, v_estado_cajas to authenticated;
grant select on v_margen_productos to authenticated;


-- ============================================================================
-- 6. PERMISOS DE TABLA
--    Supabase concede por defecto lectura y escritura sobre todo lo nuevo
--    en `public`, dejando a RLS como única barrera. Aquí se cierra de forma
--    explícita: lo que solo debe cambiar por documento no se puede escribir
--    directamente ni con la llave anónima ni con la del usuario.
-- ============================================================================

-- La llave anónima no ve datos de ningún negocio
revoke all on all tables in schema public from anon;

do $$
declare
  t text;
  -- lectura para el usuario autenticado (RLS decide qué filas)
  lectura text[] := array[
    'organizaciones','sucursales','perfiles','usuario_sucursales','categorias','marcas',
    'proveedores','impuestos','productos','presentaciones','producto_codigos','precios',
    'series_fiscales','lotes','existencias','producto_costos','kardex','ordenes_compra',
    'orden_compra_detalle','facturas_compra','factura_compra_detalle','pagos_compra',
    'cajas','turnos_caja','caja_desbloqueos','intentos_pin','clientes','secuencias',
    'ventas','venta_detalle','pagos_venta','pedidos','pedido_detalle','pedido_eventos',
    'direcciones_cliente'
  ];
  -- escritura directa permitida (siempre filtrada por RLS)
  escritura text[] := array[
    'sucursales','categorias','marcas','proveedores','impuestos','productos',
    'presentaciones','producto_codigos','precios','series_fiscales','lotes',
    'ordenes_compra','orden_compra_detalle','facturas_compra','factura_compra_detalle',
    'pagos_compra','cajas','clientes','direcciones_cliente','perfiles','usuario_sucursales'
  ];
  -- solo cambian a través de funciones: kardex, existencias, costos, ventas,
  -- turnos, desbloqueos, secuencias y el contenido de los pedidos
  solo_funciones text[] := array[
    'kardex','existencias','producto_costos','ventas','venta_detalle','pagos_venta',
    'turnos_caja','caja_desbloqueos','intentos_pin','secuencias','pedido_detalle',
    'pedido_eventos'
  ];
begin
  foreach t in array lectura loop
    execute format('grant select on %I to authenticated', t);
  end loop;

  foreach t in array escritura loop
    execute format('grant insert, update, delete on %I to authenticated', t);
  end loop;

  foreach t in array solo_funciones loop
    execute format('revoke insert, update, delete on %I from authenticated', t);
  end loop;

  -- las organizaciones se editan, no se crean ni borran desde la app
  execute 'grant update on organizaciones to authenticated';
  execute 'revoke insert, delete on organizaciones from authenticated';
  -- los pedidos se crean por función; el tablero solo cambia su estado
  execute 'grant update on pedidos to authenticated';
  execute 'revoke insert, delete on pedidos from authenticated';
end $$;


-- ============================================================================
-- 7. VISTAS CON SEGURIDAD DEL INVOCADOR
--    Por omisión una vista de Postgres corre con los permisos de quien la
--    creó, así que se salta el RLS de las tablas que consulta. Sin esto,
--    cualquier usuario autenticado veía el catálogo, las existencias y los
--    márgenes de TODOS los negocios de la plataforma.
-- ============================================================================

alter view v_existencias      set (security_invoker = on);
alter view v_vencimientos     set (security_invoker = on);
alter view v_stock_bajo       set (security_invoker = on);
alter view v_estado_cajas     set (security_invoker = on);
alter view v_margen_productos set (security_invoker = on);
alter view v_pos_catalogo     set (security_invoker = on);
