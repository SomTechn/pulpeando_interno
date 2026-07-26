-- ============================================================================
--  ABARROTES SaaS · Migración 002 · Caja y Ventas
--
--  · Rol repartidor (app de delivery)
--  · PIN de 5 dígitos por cajero (hash bcrypt, con bloqueo por intentos)
--  · La caja se bloquea al cerrar cada transacción: para vender hay que
--    desbloquear con PIN y ese desbloqueo sirve para UNA sola venta.
--    La regla se impone en la base de datos, no solo en la interfaz.
--  · Ventas, pagos, ticket o factura fiscal según el interruptor de la org
-- ============================================================================

create type metodo_pago as enum ('efectivo', 'tarjeta', 'transferencia', 'credito', 'otro');
create type estado_turno as enum ('abierto', 'cerrado');
create type estado_venta as enum ('completada', 'anulada');


-- ============================================================================
-- 1. JERARQUÍA DE ROLES (actualizada)
--    repartidor = 0: no entra al inventario ni a la caja, solo a sus pedidos
-- ============================================================================

create or replace function app.nivel_rol(r rol_usuario)
returns int immutable language sql as $$
  select case r::text
    when 'repartidor' then 0
    when 'auxiliar'   then 1
    when 'supervisor' then 2
    when 'gerente'    then 3
    when 'admin'      then 4
    else 0
  end
$$;

create or replace function app.es_repartidor()
returns boolean stable language sql security definer set search_path = public, app as $$
  select coalesce((select rol::text = 'repartidor' from perfiles
                   where id = auth.uid() and activo), false)
$$;


-- ============================================================================
-- 2. PIN DEL CAJERO
-- ============================================================================

alter table perfiles
  add column pin_intentos_fallidos int not null default 0,
  add column pin_bloqueado_hasta   timestamptz,
  add column pin_actualizado_en    timestamptz;

-- Establecer o cambiar el PIN. Cada quien puede cambiar el suyo;
-- gerente y admin pueden asignarlo a cualquiera de su organización.
create or replace function fn_establecer_pin(p_perfil_id uuid, p_pin text)
returns void
language plpgsql security definer set search_path = public, app, extensions as $$
declare
  v_org_destino uuid;
begin
  if p_pin !~ '^[0-9]{5}$' then
    raise exception 'El PIN debe tener exactamente 5 dígitos';
  end if;
  if p_pin ~ '^(.)\1{4}$' then
    raise exception 'El PIN no puede ser el mismo dígito cinco veces';
  end if;
  if p_pin in ('12345', '54321', '01234', '98765') then
    raise exception 'Ese PIN es demasiado fácil de adivinar';
  end if;

  select organizacion_id into v_org_destino from perfiles where id = p_perfil_id;
  if v_org_destino is null then
    raise exception 'Usuario inexistente';
  end if;

  if not (
    p_perfil_id = auth.uid()
    or app.es_admin()
    or (v_org_destino = app.org_id() and app.tiene_nivel('gerente'))
  ) then
    raise exception 'No tiene permiso para cambiar este PIN';
  end if;

  update perfiles
     set pin_pos = crypt(p_pin, gen_salt('bf')),
         pin_intentos_fallidos = 0,
         pin_bloqueado_hasta = null,
         pin_actualizado_en = now()
   where id = p_perfil_id;
end $$;


-- ============================================================================
-- 3. CAJAS Y TURNOS
-- ============================================================================

create table cajas (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  sucursal_id      uuid not null references sucursales(id) on delete cascade,
  codigo           text not null,
  nombre           text not null,
  activa           boolean not null default true,
  creada_en        timestamptz not null default now(),
  unique (sucursal_id, codigo)
);

create table turnos_caja (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  sucursal_id      uuid not null references sucursales(id),
  caja_id          uuid not null references cajas(id),
  cajero_id        uuid not null references perfiles(id),
  estado           estado_turno not null default 'abierto',
  monto_inicial    numeric(16,4) not null default 0,
  abierto_en       timestamptz not null default now(),
  cerrado_en       timestamptz,
  monto_declarado  numeric(16,4),      -- lo que el cajero contó
  monto_esperado   numeric(16,4),      -- lo que el sistema calculó
  diferencia       numeric(16,4),
  cerrado_por      uuid references perfiles(id),
  notas            text
);

-- Una caja no puede tener dos turnos abiertos a la vez
create unique index ux_turno_abierto on turnos_caja (caja_id) where estado = 'abierto';

create index ix_turnos_cajero on turnos_caja (cajero_id, abierto_en desc);


-- ============================================================================
-- 4. BLOQUEO DE CAJA
--    Un desbloqueo = una venta. Al registrarse la venta se consume.
-- ============================================================================

create table caja_desbloqueos (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  turno_id         uuid not null references turnos_caja(id) on delete cascade,
  cajero_id        uuid not null references perfiles(id),
  creado_en        timestamptz not null default now(),
  expira_en        timestamptz not null default now() + interval '15 minutes',
  consumido_en     timestamptz,
  venta_id         uuid
);

create index ix_desbloqueo_activo on caja_desbloqueos (turno_id)
  where consumido_en is null;

-- Registro de intentos, para auditoría de quién intentó abrir la caja
create table intentos_pin (
  id               bigserial primary key,
  organizacion_id  uuid references organizaciones(id) on delete cascade,
  perfil_id        uuid references perfiles(id) on delete set null,
  turno_id         uuid,
  exitoso          boolean not null,
  ocurrido_en      timestamptz not null default now()
);


-- Abrir turno: valida el PIN del cajero y deja la caja lista
create or replace function fn_abrir_turno(
  p_caja_id       uuid,
  p_cajero_id     uuid,
  p_pin           text,
  p_monto_inicial numeric default 0
) returns uuid
language plpgsql security definer set search_path = public, app, extensions as $$
declare
  c      record;
  p      record;
  v_id   uuid;
begin
  select * into c from cajas where id = p_caja_id and activa;
  if c.id is null then
    raise exception 'Caja inexistente o desactivada';
  end if;

  select * into p from perfiles where id = p_cajero_id and activo;
  if p.id is null or p.organizacion_id <> c.organizacion_id then
    raise exception 'Cajero inexistente';
  end if;
  if app.nivel_rol(p.rol) < 1 then
    raise exception 'Este usuario no tiene permiso para operar caja';
  end if;
  if p.pin_pos is null then
    raise exception 'El cajero no tiene PIN asignado';
  end if;
  if p.pin_bloqueado_hasta is not null and p.pin_bloqueado_hasta > now() then
    raise exception 'PIN bloqueado por intentos fallidos. Intente de nuevo más tarde';
  end if;
  if p.pin_pos <> crypt(p_pin, p.pin_pos) then
    update perfiles
       set pin_intentos_fallidos = pin_intentos_fallidos + 1,
           pin_bloqueado_hasta = case when pin_intentos_fallidos + 1 >= 5
                                      then now() + interval '5 minutes' end
     where id = p_cajero_id;
    insert into intentos_pin (organizacion_id, perfil_id, exitoso)
    values (c.organizacion_id, p_cajero_id, false);
    raise exception 'PIN incorrecto';
  end if;

  update perfiles set pin_intentos_fallidos = 0, pin_bloqueado_hasta = null
   where id = p_cajero_id;

  insert into turnos_caja (organizacion_id, sucursal_id, caja_id, cajero_id, monto_inicial)
  values (c.organizacion_id, c.sucursal_id, c.id, p_cajero_id, coalesce(p_monto_inicial, 0))
  returning id into v_id;

  insert into intentos_pin (organizacion_id, perfil_id, turno_id, exitoso)
  values (c.organizacion_id, p_cajero_id, v_id, true);

  return v_id;
end $$;


-- Desbloquear la caja para UNA venta
create or replace function fn_desbloquear_caja(p_turno_id uuid, p_pin text)
returns uuid
language plpgsql security definer set search_path = public, app, extensions as $$
declare
  t      record;
  p      record;
  v_id   uuid;
begin
  select * into t from turnos_caja where id = p_turno_id;
  if t.id is null or t.estado <> 'abierto' then
    raise exception 'El turno de caja no está abierto';
  end if;

  select * into p from perfiles where id = t.cajero_id and activo;
  if p.pin_bloqueado_hasta is not null and p.pin_bloqueado_hasta > now() then
    raise exception 'PIN bloqueado por intentos fallidos. Llame al supervisor';
  end if;

  if p.pin_pos is null or p.pin_pos <> crypt(p_pin, p.pin_pos) then
    update perfiles
       set pin_intentos_fallidos = pin_intentos_fallidos + 1,
           pin_bloqueado_hasta = case when pin_intentos_fallidos + 1 >= 5
                                      then now() + interval '5 minutes' end
     where id = p.id;
    insert into intentos_pin (organizacion_id, perfil_id, turno_id, exitoso)
    values (t.organizacion_id, p.id, p_turno_id, false);
    raise exception 'PIN incorrecto';
  end if;

  update perfiles set pin_intentos_fallidos = 0, pin_bloqueado_hasta = null
   where id = p.id;

  -- Un solo desbloqueo vivo por turno
  update caja_desbloqueos set consumido_en = now()
   where turno_id = p_turno_id and consumido_en is null;

  insert into caja_desbloqueos (organizacion_id, turno_id, cajero_id)
  values (t.organizacion_id, p_turno_id, p.id)
  returning id into v_id;

  insert into intentos_pin (organizacion_id, perfil_id, turno_id, exitoso)
  values (t.organizacion_id, p.id, p_turno_id, true);

  return v_id;
end $$;


-- ============================================================================
-- 5. CLIENTES (base para crédito y para la app del cliente)
-- ============================================================================

create table clientes (
  id                    uuid primary key default gen_random_uuid(),
  organizacion_id       uuid not null references organizaciones(id) on delete cascade,
  usuario_id            uuid references auth.users(id) on delete set null,  -- app del cliente
  codigo                text,
  nombre                text not null,
  identificacion_fiscal text,
  telefono              text,
  email                 text,
  direccion             text,
  limite_credito        numeric(16,4) not null default 0,
  saldo                 numeric(16,4) not null default 0,
  puntos                int not null default 0,
  activo                boolean not null default true,
  creado_en             timestamptz not null default now(),
  actualizado_en        timestamptz not null default now(),
  unique (organizacion_id, telefono)
);

create index ix_clientes_usuario on clientes (usuario_id);


-- ============================================================================
-- 6. SECUENCIAS DE DOCUMENTOS
-- ============================================================================

create table secuencias (
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  sucursal_id      uuid not null references sucursales(id) on delete cascade,
  tipo             text not null,          -- 'ticket', 'pedido', ...
  valor            bigint not null default 0,
  primary key (organizacion_id, sucursal_id, tipo)
);

create or replace function fn_siguiente_numero(
  p_org uuid, p_sucursal uuid, p_tipo text
) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare v bigint;
begin
  insert into secuencias (organizacion_id, sucursal_id, tipo, valor)
  values (p_org, p_sucursal, p_tipo, 0)
  on conflict (organizacion_id, sucursal_id, tipo) do nothing;

  update secuencias set valor = valor + 1
   where organizacion_id = p_org and sucursal_id = p_sucursal and tipo = p_tipo
  returning valor into v;

  return v;
end $$;


-- ============================================================================
-- 7. VENTAS
-- ============================================================================

create table ventas (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  sucursal_id      uuid not null references sucursales(id),
  caja_id          uuid references cajas(id),
  turno_id         uuid references turnos_caja(id),
  cajero_id        uuid references perfiles(id),
  cliente_id       uuid references clientes(id),
  numero           text not null,                       -- ticket interno
  tipo_documento   tipo_documento_fiscal not null default 'ticket',
  numero_fiscal    text,                                -- si la org factura
  cai              text,
  subtotal         numeric(16,4) not null default 0,
  descuento        numeric(16,4) not null default 0,
  impuesto         numeric(16,4) not null default 0,
  total            numeric(16,4) not null default 0,
  costo_total      numeric(16,4) not null default 0,     -- para margen
  es_credito       boolean not null default false,
  estado           estado_venta not null default 'completada',
  anulada_por      uuid references perfiles(id),
  anulada_en       timestamptz,
  motivo_anulacion text,
  creada_en        timestamptz not null default now(),
  unique (organizacion_id, numero)
);

create table venta_detalle (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  venta_id         uuid not null references ventas(id) on delete cascade,
  producto_id      uuid not null references productos(id),
  presentacion_id  uuid references presentaciones(id),
  lote_id          uuid references lotes(id),
  cantidad         numeric(14,3) not null check (cantidad > 0),
  precio_unitario  numeric(14,4) not null,
  descuento        numeric(14,4) not null default 0,
  tasa_impuesto    numeric(6,4) not null default 0,
  impuesto_incluido boolean not null default true,
  costo_unitario   numeric(14,4) not null default 0,
  total            numeric(16,4) not null default 0
);

create table pagos_venta (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  venta_id         uuid not null references ventas(id) on delete cascade,
  metodo           metodo_pago not null,
  monto            numeric(16,4) not null check (monto > 0),
  recibido         numeric(16,4),
  cambio           numeric(16,4) not null default 0,
  referencia       text,
  creado_en        timestamptz not null default now()
);

create index ix_ventas_fecha on ventas (organizacion_id, sucursal_id, creada_en desc);
create index ix_ventas_turno on ventas (turno_id);
create index ix_vd_producto  on venta_detalle (producto_id);

alter table caja_desbloqueos
  add constraint fk_desbloqueo_venta foreign key (venta_id) references ventas(id) on delete set null;


-- Precio vigente según sucursal, nivel y cantidad
create or replace function fn_precio_vigente(
  p_producto_id uuid,
  p_sucursal_id uuid,
  p_cantidad    numeric default 1,
  p_nivel       nivel_precio default 'detalle'
) returns numeric
language sql stable as $$
  select pr.precio
  from precios pr
  where pr.producto_id = p_producto_id
    and (pr.sucursal_id = p_sucursal_id or pr.sucursal_id is null)
    and pr.nivel = p_nivel
    and pr.cantidad_minima <= p_cantidad
    and pr.vigente_desde <= current_date
    and (pr.vigente_hasta is null or pr.vigente_hasta >= current_date)
  order by pr.sucursal_id nulls last, pr.cantidad_minima desc
  limit 1
$$;


-- Descuento de inventario por FEFO: primero lo que vence antes.
-- Devuelve el costo total de la salida.
create or replace function fn_descontar_fefo(
  p_sucursal_id uuid,
  p_producto_id uuid,
  p_cantidad    numeric,
  p_doc_tipo    text,
  p_doc_id      uuid,
  p_usuario_id  uuid
) returns numeric
language plpgsql security definer set search_path = public, app as $$
declare
  v_pendiente numeric := p_cantidad;
  v_toma      numeric;
  v_costo     numeric := 0;
  v_kid       bigint;
  l           record;
  v_controla  boolean;
begin
  select controla_lote or controla_vencimiento into v_controla
  from productos where id = p_producto_id;

  if not coalesce(v_controla, false) then
    v_kid := fn_kardex_registrar(p_sucursal_id, p_producto_id, 'venta',
                                 p_cantidad, null, null, p_doc_tipo, p_doc_id, null, p_usuario_id);
    select abs(costo_total) into v_costo from kardex where id = v_kid;
    return v_costo;
  end if;

  for l in select * from fn_lotes_fefo(p_producto_id, p_sucursal_id) loop
    exit when v_pendiente <= 0;
    v_toma := least(v_pendiente, l.cantidad);
    v_kid := fn_kardex_registrar(p_sucursal_id, p_producto_id, 'venta',
                                 v_toma, null, l.lote_id, p_doc_tipo, p_doc_id, null, p_usuario_id);
    select v_costo + abs(costo_total) into v_costo from kardex where id = v_kid;
    v_pendiente := v_pendiente - v_toma;
  end loop;

  if v_pendiente > 0 then
    -- Sin lotes suficientes: fn_kardex_registrar decide si lo permite
    v_kid := fn_kardex_registrar(p_sucursal_id, p_producto_id, 'venta',
                                 v_pendiente, null, null, p_doc_tipo, p_doc_id,
                                 'Salida sin lote asignado', p_usuario_id);
    select v_costo + abs(costo_total) into v_costo from kardex where id = v_kid;
  end if;

  return v_costo;
end $$;


-- ---------------------------------------------------------------------------
--  Registrar venta.
--  Exige un desbloqueo de caja válido y lo consume: al terminar,
--  la caja queda bloqueada otra vez.
--
--  p_items:  [{"producto_id":"...","cantidad":2,"descuento":0,"nivel":"detalle"}]
--  p_pagos:  [{"metodo":"efectivo","monto":100,"recibido":200}]
-- ---------------------------------------------------------------------------
create or replace function fn_registrar_venta(
  p_desbloqueo_id uuid,
  p_items         jsonb,
  p_pagos         jsonb,
  p_cliente_id    uuid default null,
  p_fiscal        boolean default false
) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d            record;
  t            record;
  o            record;
  it           jsonb;
  pg           jsonb;
  v_venta_id   uuid;
  v_numero     text;
  v_prod       record;
  v_cant       numeric;
  v_precio     numeric;
  v_desc       numeric;
  v_tasa       numeric;
  v_linea      numeric;
  v_costo      numeric;
  v_sub        numeric := 0;
  v_imp        numeric := 0;
  v_desctot    numeric := 0;
  v_costotot   numeric := 0;
  v_total      numeric := 0;
  v_pagado     numeric := 0;
  v_cambio     numeric := 0;
  v_recibido   numeric := 0;
  v_credito    boolean := false;
  v_tipo       tipo_documento_fiscal := 'ticket';
  v_numfiscal  text;
  v_cai        text;
  s            record;
begin
  -- 1. La caja tiene que estar desbloqueada
  select * into d from caja_desbloqueos where id = p_desbloqueo_id for update;
  if d.id is null then
    raise exception 'Caja bloqueada: digite el PIN para iniciar la venta';
  end if;
  if d.consumido_en is not null then
    raise exception 'Este desbloqueo ya se usó. Digite el PIN de nuevo';
  end if;
  if d.expira_en < now() then
    raise exception 'El desbloqueo expiró. Digite el PIN de nuevo';
  end if;

  select * into t from turnos_caja where id = d.turno_id;
  if t.estado <> 'abierto' then
    raise exception 'El turno de caja está cerrado';
  end if;

  select * into o from organizaciones where id = t.organizacion_id;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'La venta no tiene productos';
  end if;

  -- 2. Documento
  v_numero := 'T-' || lpad(fn_siguiente_numero(t.organizacion_id, t.sucursal_id, 'ticket')::text, 8, '0');

  if p_fiscal and o.facturacion_fiscal_activa then
    select * into s from series_fiscales
     where sucursal_id = t.sucursal_id and tipo_documento = 'factura' and activa
       and correlativo_actual <= correlativo_final
       and (fecha_limite_emision is null or fecha_limite_emision >= current_date)
     order by creada_en limit 1
     for update;

    if s.id is null then
      raise exception 'No hay rango de facturación autorizado disponible';
    end if;

    v_tipo      := 'factura';
    v_numfiscal := s.prefijo || '-' || lpad(s.correlativo_actual::text, 8, '0');
    v_cai       := s.cai;

    update series_fiscales set correlativo_actual = correlativo_actual + 1 where id = s.id;
  end if;

  insert into ventas (organizacion_id, sucursal_id, caja_id, turno_id, cajero_id,
                      cliente_id, numero, tipo_documento, numero_fiscal, cai)
  values (t.organizacion_id, t.sucursal_id, t.caja_id, t.id, d.cajero_id,
          p_cliente_id, v_numero, v_tipo, v_numfiscal, v_cai)
  returning id into v_venta_id;

  -- 3. Líneas
  for it in select * from jsonb_array_elements(p_items) loop
    select p.*, coalesce(i.tasa, 0) as tasa, coalesce(i.incluido_en_precio, true) as incluido
      into v_prod
    from productos p
    left join impuestos i on i.id = p.impuesto_id
    where p.id = (it->>'producto_id')::uuid;

    if v_prod.id is null then
      raise exception 'Producto % inexistente', it->>'producto_id';
    end if;

    v_cant := (it->>'cantidad')::numeric;
    if v_cant is null or v_cant <= 0 then
      raise exception 'Cantidad inválida en %', v_prod.nombre;
    end if;

    v_precio := coalesce(
      fn_precio_vigente(v_prod.id, t.sucursal_id, v_cant,
                        coalesce((it->>'nivel')::nivel_precio, 'detalle')),
      0);
    if v_precio = 0 then
      raise exception 'El producto % no tiene precio asignado', v_prod.nombre;
    end if;

    v_desc  := coalesce((it->>'descuento')::numeric, 0);
    v_tasa  := v_prod.tasa;
    v_linea := (v_precio * v_cant) - v_desc;

    v_costo := fn_descontar_fefo(t.sucursal_id, v_prod.id, v_cant,
                                 'venta', v_venta_id, d.cajero_id);

    insert into venta_detalle (organizacion_id, venta_id, producto_id, cantidad,
                               precio_unitario, descuento, tasa_impuesto,
                               impuesto_incluido, costo_unitario, total)
    values (t.organizacion_id, v_venta_id, v_prod.id, v_cant,
            v_precio, v_desc, v_tasa, v_prod.incluido,
            case when v_cant > 0 then v_costo / v_cant else 0 end, v_linea);

    -- Precio con impuesto incluido: se desagrega para el reporte fiscal
    if v_prod.incluido then
      v_sub := v_sub + (v_linea / (1 + v_tasa));
      v_imp := v_imp + (v_linea - (v_linea / (1 + v_tasa)));
    else
      v_sub := v_sub + v_linea;
      v_imp := v_imp + (v_linea * v_tasa);
    end if;

    v_desctot  := v_desctot + v_desc;
    v_costotot := v_costotot + v_costo;
  end loop;

  v_total := round(v_sub + v_imp, 2);

  -- 4. Pagos
  for pg in select * from jsonb_array_elements(coalesce(p_pagos, '[]'::jsonb)) loop
    if (pg->>'metodo') = 'credito' then
      v_credito := true;
      if p_cliente_id is null then
        raise exception 'Una venta al crédito requiere cliente';
      end if;
    end if;
    v_pagado   := v_pagado + (pg->>'monto')::numeric;
    v_recibido := v_recibido + coalesce((pg->>'recibido')::numeric, (pg->>'monto')::numeric);

    insert into pagos_venta (organizacion_id, venta_id, metodo, monto, recibido, referencia)
    values (t.organizacion_id, v_venta_id, (pg->>'metodo')::metodo_pago,
            (pg->>'monto')::numeric, (pg->>'recibido')::numeric, pg->>'referencia');
  end loop;

  if round(v_pagado, 2) < v_total then
    raise exception 'Pago insuficiente: total %, recibido %', v_total, v_pagado;
  end if;
  v_cambio := greatest(round(v_recibido - v_total, 2), 0);

  update pagos_venta set cambio = v_cambio
   where venta_id = v_venta_id and metodo = 'efectivo'
     and id = (select id from pagos_venta where venta_id = v_venta_id
               and metodo = 'efectivo' order by creado_en desc limit 1);

  update ventas
     set subtotal = round(v_sub, 2), impuesto = round(v_imp, 2),
         descuento = round(v_desctot, 2), total = v_total,
         costo_total = round(v_costotot, 2), es_credito = v_credito
   where id = v_venta_id;

  if v_credito then
    update clientes set saldo = saldo + v_total, actualizado_en = now()
     where id = p_cliente_id;
  end if;

  -- 5. Consumir el desbloqueo: la caja vuelve a bloquearse
  update caja_desbloqueos
     set consumido_en = now(), venta_id = v_venta_id
   where id = p_desbloqueo_id;

  return jsonb_build_object(
    'venta_id', v_venta_id,
    'numero', v_numero,
    'documento', v_tipo,
    'numero_fiscal', v_numfiscal,
    'subtotal', round(v_sub, 2),
    'impuesto', round(v_imp, 2),
    'total', v_total,
    'pagado', round(v_pagado, 2),
    'cambio', v_cambio,
    'caja_bloqueada', true
  );
end $$;


-- Anular venta: devuelve todo al inventario. Supervisor o superior.
create or replace function fn_anular_venta(p_venta_id uuid, p_motivo text)
returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v record;
  l record;
begin
  if not (app.tiene_nivel('supervisor') or app.es_admin()) then
    raise exception 'Solo un supervisor puede anular ventas';
  end if;

  select * into v from ventas where id = p_venta_id for update;
  if v.id is null then raise exception 'Venta inexistente'; end if;
  if v.estado = 'anulada' then raise exception 'La venta ya está anulada'; end if;

  for l in select * from venta_detalle where venta_id = p_venta_id loop
    perform fn_kardex_registrar(v.sucursal_id, l.producto_id, 'devolucion_venta',
                                l.cantidad, l.costo_unitario, l.lote_id,
                                'anulacion_venta', v.id,
                                'Anulación ' || v.numero, auth.uid());
  end loop;

  if v.es_credito and v.cliente_id is not null then
    update clientes set saldo = greatest(saldo - v.total, 0) where id = v.cliente_id;
  end if;

  update ventas
     set estado = 'anulada', anulada_por = auth.uid(),
         anulada_en = now(), motivo_anulacion = p_motivo
   where id = p_venta_id;
end $$;


-- Cerrar turno con arqueo
create or replace function fn_cerrar_turno(p_turno_id uuid, p_monto_declarado numeric, p_notas text default null)
returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  t          record;
  v_efectivo numeric;
  v_esperado numeric;
begin
  select * into t from turnos_caja where id = p_turno_id for update;
  if t.id is null or t.estado <> 'abierto' then
    raise exception 'El turno no está abierto';
  end if;

  select coalesce(sum(pv.monto - pv.cambio), 0) into v_efectivo
  from pagos_venta pv
  join ventas ve on ve.id = pv.venta_id
  where ve.turno_id = p_turno_id and ve.estado = 'completada' and pv.metodo = 'efectivo';

  v_esperado := t.monto_inicial + v_efectivo;

  update turnos_caja
     set estado = 'cerrado', cerrado_en = now(), cerrado_por = auth.uid(),
         monto_declarado = p_monto_declarado,
         monto_esperado = v_esperado,
         diferencia = p_monto_declarado - v_esperado,
         notas = p_notas
   where id = p_turno_id;

  update caja_desbloqueos set consumido_en = now()
   where turno_id = p_turno_id and consumido_en is null;

  return jsonb_build_object(
    'monto_inicial', t.monto_inicial,
    'efectivo_ventas', v_efectivo,
    'esperado', v_esperado,
    'declarado', p_monto_declarado,
    'diferencia', p_monto_declarado - v_esperado
  );
end $$;


-- ============================================================================
-- 8. VISTAS DE CAJA Y VENTAS
-- ============================================================================

-- Estado en vivo de cada caja: la pantalla que ve el cajero al entrar
create view v_estado_cajas as
select
  c.organizacion_id,
  c.sucursal_id,
  c.id                as caja_id,
  c.nombre            as caja,
  t.id                as turno_id,
  t.estado            as estado_turno,
  p.id                as cajero_id,
  p.nombre            as cajero,
  t.abierto_en,
  exists (select 1 from caja_desbloqueos cd
          where cd.turno_id = t.id and cd.consumido_en is null and cd.expira_en > now())
                      as desbloqueada,
  (select count(*) from ventas v where v.turno_id = t.id and v.estado = 'completada') as ventas_turno,
  (select coalesce(sum(v.total), 0) from ventas v where v.turno_id = t.id and v.estado = 'completada') as total_turno
from cajas c
left join turnos_caja t on t.caja_id = c.id and t.estado = 'abierto'
left join perfiles p on p.id = t.cajero_id
where c.activa;

-- Márgenes por producto (gerencia)
create view v_margen_productos as
select
  vd.organizacion_id,
  v.sucursal_id,
  vd.producto_id,
  p.nombre                                   as producto,
  date_trunc('day', v.creada_en)             as dia,
  sum(vd.cantidad)                           as unidades,
  round(sum(case when vd.impuesto_incluido
                 then vd.total / (1 + vd.tasa_impuesto)
                 else vd.total end), 2)        as venta_neta,
  round(sum(vd.costo_unitario * vd.cantidad), 2) as costo,
  round(sum(case when vd.impuesto_incluido
                 then vd.total / (1 + vd.tasa_impuesto)
                 else vd.total end)
        - sum(vd.costo_unitario * vd.cantidad), 2) as margen
from venta_detalle vd
join ventas v on v.id = vd.venta_id and v.estado = 'completada'
join productos p on p.id = vd.producto_id
group by vd.organizacion_id, v.sucursal_id, vd.producto_id, p.nombre, date_trunc('day', v.creada_en);


-- ============================================================================
-- 9. RLS
-- ============================================================================

alter table cajas             enable row level security;
alter table turnos_caja       enable row level security;
alter table caja_desbloqueos  enable row level security;
alter table intentos_pin      enable row level security;
alter table clientes          enable row level security;
alter table secuencias        enable row level security;
alter table ventas            enable row level security;
alter table venta_detalle     enable row level security;
alter table pagos_venta       enable row level security;

-- Personal de tienda (auxiliar en adelante). El repartidor queda fuera.
create policy cajas_sel on cajas for select
  using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar')) or app.es_admin());
create policy cajas_esc on cajas for all
  using ((organizacion_id = app.org_id() and app.tiene_nivel('gerente')) or app.es_admin())
  with check ((organizacion_id = app.org_id() and app.tiene_nivel('gerente')) or app.es_admin());

create policy turnos_sel on turnos_caja for select
  using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar')) or app.es_admin());

create policy desbloqueos_sel on caja_desbloqueos for select
  using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar')) or app.es_admin());

create policy intentos_sel on intentos_pin for select
  using ((organizacion_id = app.org_id() and app.tiene_nivel('supervisor')) or app.es_admin());

create policy secuencias_sel on secuencias for select
  using (organizacion_id = app.org_id() or app.es_admin());

-- Clientes: el personal ve los de su organización.
-- Además, un cliente autenticado en su propia app ve solo su ficha.
create policy clientes_sel on clientes for select
  using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))
         or usuario_id = auth.uid()
         or app.es_admin());
create policy clientes_esc on clientes for all
  using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar')) or app.es_admin())
  with check ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar')) or app.es_admin());
create policy clientes_propio_upd on clientes for update
  using (usuario_id = auth.uid())
  with check (usuario_id = auth.uid());

-- Ventas: el auxiliar ve las suyas del turno; supervisor en adelante ve todas.
-- El cliente ve las ventas asociadas a su ficha.
create policy ventas_sel on ventas for select
  using (
    app.es_admin()
    or (organizacion_id = app.org_id() and app.tiene_nivel('supervisor'))
    or (organizacion_id = app.org_id() and app.tiene_nivel('auxiliar') and cajero_id = auth.uid())
    or cliente_id in (select id from clientes where usuario_id = auth.uid())
  );

create policy venta_detalle_sel on venta_detalle for select
  using (venta_id in (select id from ventas));

create policy pagos_venta_sel on pagos_venta for select
  using (venta_id in (select id from ventas));

-- Nota: las ventas NO se insertan directamente. Solo fn_registrar_venta
-- (SECURITY DEFINER) puede crearlas, y exige un desbloqueo de caja válido.


-- ============================================================================
-- 10. PERMISOS DE EJECUCIÓN
-- ============================================================================

revoke execute on function fn_registrar_venta(uuid, jsonb, jsonb, uuid, boolean) from public;
revoke execute on function fn_desbloquear_caja(uuid, text) from public;
revoke execute on function fn_abrir_turno(uuid, uuid, text, numeric) from public;
revoke execute on function fn_establecer_pin(uuid, text) from public;
