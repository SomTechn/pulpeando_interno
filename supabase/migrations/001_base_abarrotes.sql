-- ============================================================================
--  ABARROTES SaaS · Migración 001 · Fases 1 y 2
--  Fase 1: multi-tenant, roles, RLS, catálogo, precios
--  Fase 2: lotes, vencimientos, existencias, kardex, compras
--
--  Decisiones aplicadas:
--   1) Costeo: PROMEDIO PONDERADO por (producto, sucursal) + trazabilidad de lote
--   2) Facturación fiscal: interruptor por organización (ticket <-> factura fiscal)
--   3) Multi-sucursal desde el inicio
--   4) Hardware: códigos de barras múltiples, presentaciones, peso variable (balanza)
-- ============================================================================

create extension if not exists pgcrypto;

create schema if not exists app;   -- funciones auxiliares de seguridad

-- ============================================================================
-- 1. TIPOS
-- ============================================================================

create type rol_usuario as enum ('auxiliar', 'supervisor', 'gerente', 'admin');

create type tipo_producto as enum ('unidad', 'peso', 'granel', 'servicio');

create type nivel_precio as enum ('detalle', 'mayoreo', 'especial');

create type tipo_movimiento as enum (
  'inventario_inicial',
  'compra',
  'devolucion_compra',
  'venta',
  'devolucion_venta',
  'ajuste_positivo',
  'ajuste_negativo',
  'merma',
  'traslado_entrada',
  'traslado_salida'
);

create type estado_documento as enum ('borrador', 'confirmado', 'anulado');

create type estado_orden_compra as enum ('borrador', 'enviada', 'parcial', 'recibida', 'anulada');

create type tipo_documento_fiscal as enum ('factura', 'nota_credito', 'nota_debito', 'ticket');


-- ============================================================================
-- 2. UTILIDADES
-- ============================================================================

create or replace function app.set_actualizado_en()
returns trigger language plpgsql as $$
begin
  new.actualizado_en := now();
  return new;
end $$;

-- Movimientos que suman inventario
create or replace function app.es_entrada(t tipo_movimiento)
returns boolean immutable language sql as $$
  select t in ('inventario_inicial', 'compra', 'devolucion_venta',
               'ajuste_positivo', 'traslado_entrada')
$$;

create or replace function app.nivel_rol(r rol_usuario)
returns int immutable language sql as $$
  select case r
    when 'auxiliar'   then 1
    when 'supervisor' then 2
    when 'gerente'    then 3
    when 'admin'      then 4
  end
$$;


-- ============================================================================
-- 3. ORGANIZACIONES, SUCURSALES Y USUARIOS
-- ============================================================================

create table organizaciones (
  id                        uuid primary key default gen_random_uuid(),
  nombre                    text not null,
  identificacion_fiscal     text,                       -- RTN / NIT / RFC
  pais                      char(2) not null default 'HN',
  moneda                    char(3) not null default 'HNL',
  -- Decisión 2: si está en false el POS emite solo ticket interno
  facturacion_fiscal_activa boolean not null default false,
  permite_stock_negativo    boolean not null default false,
  dias_alerta_vencimiento   int not null default 30,
  plan                      text not null default 'basico',
  activa                    boolean not null default true,
  config                    jsonb not null default '{}'::jsonb,
  creada_en                 timestamptz not null default now(),
  actualizado_en            timestamptz not null default now()
);

create table sucursales (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  codigo           text not null,
  nombre           text not null,
  direccion        text,
  telefono         text,
  es_principal     boolean not null default false,
  activa           boolean not null default true,
  creada_en        timestamptz not null default now(),
  actualizado_en   timestamptz not null default now(),
  unique (organizacion_id, codigo)
);

-- Perfil de usuario: 1 a 1 con auth.users de Supabase
create table perfiles (
  id               uuid primary key references auth.users(id) on delete cascade,
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  nombre           text not null,
  email            text,
  telefono         text,
  rol              rol_usuario not null default 'auxiliar',
  pin_pos          text,                                -- hash del PIN de caja
  activo           boolean not null default true,
  creado_en        timestamptz not null default now(),
  actualizado_en   timestamptz not null default now()
);

-- Auxiliares y supervisores se asignan a sucursales concretas.
-- Gerente y admin ven todas las de su organización.
create table usuario_sucursales (
  perfil_id    uuid not null references perfiles(id) on delete cascade,
  sucursal_id  uuid not null references sucursales(id) on delete cascade,
  primary key (perfil_id, sucursal_id)
);


-- ---------------------------------------------------------------------------
-- Funciones de contexto (SECURITY DEFINER para no recursar sobre RLS)
-- ---------------------------------------------------------------------------

create or replace function app.org_id()
returns uuid stable language sql security definer set search_path = public, app as $$
  select organizacion_id from perfiles where id = auth.uid() and activo
$$;

create or replace function app.rol()
returns rol_usuario stable language sql security definer set search_path = public, app as $$
  select rol from perfiles where id = auth.uid() and activo
$$;

create or replace function app.es_admin()
returns boolean stable language sql security definer set search_path = public, app as $$
  select coalesce((select rol = 'admin' from perfiles where id = auth.uid() and activo), false)
$$;

-- ¿El usuario actual tiene al menos este rol?
create or replace function app.tiene_nivel(minimo rol_usuario)
returns boolean stable language sql security definer set search_path = public, app as $$
  select coalesce(
    (select app.nivel_rol(rol) >= app.nivel_rol(minimo)
       from perfiles where id = auth.uid() and activo),
    false)
$$;

-- Sucursales a las que el usuario actual tiene acceso
create or replace function app.sucursales_permitidas()
returns setof uuid stable language sql security definer set search_path = public, app as $$
  select s.id
  from sucursales s
  join perfiles p on p.id = auth.uid() and p.activo
  where s.organizacion_id = p.organizacion_id
    and (
      app.nivel_rol(p.rol) >= app.nivel_rol('gerente')
      or exists (select 1 from usuario_sucursales us
                 where us.perfil_id = p.id and us.sucursal_id = s.id)
    )
$$;


-- ============================================================================
-- 4. CATÁLOGO
-- ============================================================================

create table categorias (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  padre_id         uuid references categorias(id) on delete set null,
  nombre           text not null,
  color            text,
  icono            text,
  orden            int not null default 0,
  activa           boolean not null default true,
  creada_en        timestamptz not null default now(),
  actualizado_en   timestamptz not null default now(),
  unique (organizacion_id, padre_id, nombre)
);

create table marcas (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  nombre           text not null,
  activa           boolean not null default true,
  actualizado_en   timestamptz not null default now(),
  unique (organizacion_id, nombre)
);

create table proveedores (
  id                    uuid primary key default gen_random_uuid(),
  organizacion_id       uuid not null references organizaciones(id) on delete cascade,
  codigo                text,
  nombre                text not null,
  identificacion_fiscal text,
  contacto              text,
  telefono              text,
  email                 text,
  direccion             text,
  dias_credito          int not null default 0,
  dias_entrega          int not null default 3,   -- lead time -> sugerencias de compra
  dia_visita            int[],                    -- 1=lunes ... 7=domingo
  notas                 text,
  activo                boolean not null default true,
  creado_en             timestamptz not null default now(),
  actualizado_en        timestamptz not null default now(),
  unique (organizacion_id, nombre)
);

create table impuestos (
  id                 uuid primary key default gen_random_uuid(),
  organizacion_id    uuid not null references organizaciones(id) on delete cascade,
  nombre             text not null,           -- ISV 15%, Exento, ...
  tasa               numeric(6,4) not null default 0,
  incluido_en_precio boolean not null default true,
  es_predeterminado  boolean not null default false,
  activo             boolean not null default true,
  actualizado_en     timestamptz not null default now(),
  unique (organizacion_id, nombre)
);

create table productos (
  id                    uuid primary key default gen_random_uuid(),
  organizacion_id       uuid not null references organizaciones(id) on delete cascade,
  sku                   text not null,
  nombre                text not null,
  descripcion           text,
  categoria_id          uuid references categorias(id) on delete set null,
  marca_id              uuid references marcas(id) on delete set null,
  proveedor_id          uuid references proveedores(id) on delete set null,
  impuesto_id           uuid references impuestos(id) on delete set null,
  tipo                  tipo_producto not null default 'unidad',
  unidad_base           text not null default 'UND',      -- UND, LB, KG, LT
  -- Decisión 1: trazabilidad de lote independiente del costeo promedio
  controla_lote         boolean not null default false,
  controla_vencimiento  boolean not null default false,
  dias_alerta_vencim    int,                              -- override por producto
  stock_minimo          numeric(14,3) not null default 0,
  stock_maximo          numeric(14,3),
  dias_cobertura        int not null default 15,          -- para sugerencias de compra
  imagen_url            text,
  se_vende              boolean not null default true,
  se_compra             boolean not null default true,
  activo                boolean not null default true,
  creado_en             timestamptz not null default now(),
  actualizado_en        timestamptz not null default now(),
  unique (organizacion_id, sku)
);

-- Fardo, caja, blíster, unidad... factor = cuántas unidades base contiene
create table presentaciones (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  producto_id      uuid not null references productos(id) on delete cascade,
  nombre           text not null,
  factor           numeric(14,4) not null default 1 check (factor > 0),
  es_base          boolean not null default false,
  es_compra        boolean not null default false,   -- presentación típica de compra
  activa           boolean not null default true,
  unique (producto_id, nombre)
);

-- Un producto puede tener varios códigos de barras (por presentación)
create table producto_codigos (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  producto_id      uuid not null references productos(id) on delete cascade,
  presentacion_id  uuid references presentaciones(id) on delete set null,
  codigo           text not null,
  es_principal     boolean not null default false,
  unique (organizacion_id, codigo)
);

-- sucursal_id null = precio válido para toda la organización
create table precios (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  producto_id      uuid not null references productos(id) on delete cascade,
  presentacion_id  uuid references presentaciones(id) on delete cascade,
  sucursal_id      uuid references sucursales(id) on delete cascade,
  nivel            nivel_precio not null default 'detalle',
  cantidad_minima  numeric(14,3) not null default 1,
  precio           numeric(14,4) not null check (precio >= 0),
  vigente_desde    date not null default current_date,
  vigente_hasta    date,
  actualizado_en   timestamptz not null default now()
);


-- ============================================================================
-- 5. FACTURACIÓN FISCAL (interruptor + correlativos autorizados)
-- ============================================================================

create table series_fiscales (
  id                     uuid primary key default gen_random_uuid(),
  organizacion_id        uuid not null references organizaciones(id) on delete cascade,
  sucursal_id            uuid not null references sucursales(id) on delete cascade,
  tipo_documento         tipo_documento_fiscal not null default 'factura',
  cai                    text,                       -- clave de autorización
  prefijo                text not null,              -- 000-001-01
  correlativo_inicial    bigint not null,
  correlativo_final      bigint not null,
  correlativo_actual     bigint not null,
  fecha_limite_emision   date,
  activa                 boolean not null default true,
  creada_en              timestamptz not null default now(),
  check (correlativo_actual between correlativo_inicial and correlativo_final + 1)
);


-- ============================================================================
-- 6. INVENTARIO: LOTES, EXISTENCIAS Y COSTOS
-- ============================================================================

create table lotes (
  id                 uuid primary key default gen_random_uuid(),
  organizacion_id    uuid not null references organizaciones(id) on delete cascade,
  producto_id        uuid not null references productos(id) on delete cascade,
  sucursal_id        uuid not null references sucursales(id) on delete cascade,
  codigo             text,
  fecha_vencimiento  date,
  costo_ingreso      numeric(14,4) not null default 0,
  proveedor_id       uuid references proveedores(id) on delete set null,
  documento_origen   text,
  creado_en          timestamptz not null default now(),
  unique (producto_id, sucursal_id, codigo, fecha_vencimiento)
);

-- Saldo físico. lote_id null = producto sin control de lote.
create table existencias (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  producto_id      uuid not null references productos(id) on delete cascade,
  sucursal_id      uuid not null references sucursales(id) on delete cascade,
  lote_id          uuid references lotes(id) on delete cascade,
  cantidad         numeric(14,3) not null default 0,
  actualizado_en   timestamptz not null default now()
);

create unique index ux_existencias
  on existencias (producto_id, sucursal_id,
                  coalesce(lote_id, '00000000-0000-0000-0000-000000000000'::uuid));

-- Costo promedio ponderado por producto y sucursal (decisión 1)
create table producto_costos (
  id                uuid primary key default gen_random_uuid(),
  organizacion_id   uuid not null references organizaciones(id) on delete cascade,
  producto_id       uuid not null references productos(id) on delete cascade,
  sucursal_id       uuid not null references sucursales(id) on delete cascade,
  cantidad          numeric(14,3) not null default 0,   -- saldo total
  valor             numeric(16,4) not null default 0,   -- valor total del saldo
  costo_promedio    numeric(14,4) not null default 0,
  ultimo_costo      numeric(14,4) not null default 0,
  actualizado_en    timestamptz not null default now(),
  unique (producto_id, sucursal_id)
);


-- ============================================================================
-- 7. KARDEX (libro inmutable · fuente de verdad del inventario)
-- ============================================================================

create table kardex (
  id                        bigserial primary key,
  organizacion_id           uuid not null references organizaciones(id) on delete cascade,
  sucursal_id               uuid not null references sucursales(id),
  producto_id               uuid not null references productos(id),
  lote_id                   uuid references lotes(id),
  tipo                      tipo_movimiento not null,
  cantidad                  numeric(14,3) not null,      -- con signo (+ entra / - sale)
  costo_unitario            numeric(14,4) not null default 0,
  costo_total               numeric(16,4) not null default 0,
  costo_promedio_resultante numeric(14,4) not null default 0,
  saldo_cantidad            numeric(14,3) not null default 0,
  saldo_valor               numeric(16,4) not null default 0,
  documento_tipo            text,
  documento_id              uuid,
  usuario_id                uuid references perfiles(id),
  notas                     text,
  ocurrido_en               timestamptz not null default now()
);

create index ix_kardex_prod on kardex (producto_id, sucursal_id, ocurrido_en desc);
create index ix_kardex_doc  on kardex (documento_tipo, documento_id);
create index ix_kardex_org  on kardex (organizacion_id, ocurrido_en desc);

-- El kardex no se edita ni se borra: se corrige con un movimiento contrario.
create or replace function app.kardex_inmutable()
returns trigger language plpgsql as $$
begin
  raise exception 'El kardex es inmutable. Registre un movimiento de corrección.';
end $$;

create trigger tg_kardex_inmutable
  before update or delete on kardex
  for each row execute function app.kardex_inmutable();


-- ---------------------------------------------------------------------------
-- Motor de movimientos: única puerta de entrada al inventario
-- ---------------------------------------------------------------------------
create or replace function fn_kardex_registrar(
  p_sucursal_id     uuid,
  p_producto_id     uuid,
  p_tipo            tipo_movimiento,
  p_cantidad        numeric,                 -- siempre positiva
  p_costo_unitario  numeric default null,    -- obligatorio en entradas
  p_lote_id         uuid    default null,
  p_documento_tipo  text    default null,
  p_documento_id    uuid    default null,
  p_notas           text    default null,
  p_usuario_id      uuid    default null
) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_org        uuid;
  v_negativo   boolean;
  v_entrada    boolean;
  v_signo      int;
  v_cant       numeric;
  v_valor      numeric;
  v_prom       numeric;
  v_costo_mov  numeric;
  v_disp       numeric;
  v_id         bigint;
begin
  if p_cantidad is null or p_cantidad <= 0 then
    raise exception 'La cantidad del movimiento debe ser mayor a cero';
  end if;

  select s.organizacion_id, o.permite_stock_negativo
    into v_org, v_negativo
  from sucursales s
  join organizaciones o on o.id = s.organizacion_id
  where s.id = p_sucursal_id;

  if v_org is null then
    raise exception 'Sucursal % inexistente', p_sucursal_id;
  end if;

  v_entrada := app.es_entrada(p_tipo);
  v_signo   := case when v_entrada then 1 else -1 end;

  -- Fila de costo (se crea si no existe) y se bloquea para evitar carreras
  insert into producto_costos (organizacion_id, producto_id, sucursal_id)
  values (v_org, p_producto_id, p_sucursal_id)
  on conflict (producto_id, sucursal_id) do nothing;

  select cantidad, valor, costo_promedio
    into v_cant, v_valor, v_prom
  from producto_costos
  where producto_id = p_producto_id and sucursal_id = p_sucursal_id
  for update;

  if v_entrada then
    if p_costo_unitario is null or p_costo_unitario < 0 then
      raise exception 'Toda entrada de inventario requiere costo unitario';
    end if;
    v_costo_mov := p_costo_unitario;
    v_cant      := v_cant + p_cantidad;
    v_valor     := v_valor + (p_cantidad * v_costo_mov);
    v_prom      := case when v_cant > 0 then v_valor / v_cant else v_costo_mov end;
  else
    -- Promedio ponderado: toda salida se valora al costo promedio vigente
    v_costo_mov := v_prom;

    if not v_negativo then
      select coalesce(sum(cantidad), 0) into v_disp
      from existencias
      where producto_id = p_producto_id
        and sucursal_id = p_sucursal_id
        and (p_lote_id is null or lote_id = p_lote_id);

      if v_disp < p_cantidad then
        raise exception 'Stock insuficiente: disponible %, solicitado %', v_disp, p_cantidad;
      end if;
    end if;

    v_cant  := v_cant - p_cantidad;
    v_valor := greatest(v_valor - (p_cantidad * v_costo_mov), 0);
    if v_cant > 0 then
      v_prom := v_valor / v_cant;
    end if;   -- si el saldo llega a 0 se conserva el último promedio
  end if;

  -- Saldo físico por lote
  update existencias
     set cantidad = cantidad + (v_signo * p_cantidad),
         actualizado_en = now()
   where producto_id = p_producto_id
     and sucursal_id = p_sucursal_id
     and lote_id is not distinct from p_lote_id;

  if not found then
    insert into existencias (organizacion_id, producto_id, sucursal_id, lote_id, cantidad)
    values (v_org, p_producto_id, p_sucursal_id, p_lote_id, v_signo * p_cantidad);
  end if;

  update producto_costos
     set cantidad = v_cant,
         valor    = v_valor,
         costo_promedio = v_prom,
         ultimo_costo   = case when v_entrada then v_costo_mov else ultimo_costo end,
         actualizado_en = now()
   where producto_id = p_producto_id and sucursal_id = p_sucursal_id;

  insert into kardex (
    organizacion_id, sucursal_id, producto_id, lote_id, tipo,
    cantidad, costo_unitario, costo_total, costo_promedio_resultante,
    saldo_cantidad, saldo_valor, documento_tipo, documento_id, usuario_id, notas
  ) values (
    v_org, p_sucursal_id, p_producto_id, p_lote_id, p_tipo,
    v_signo * p_cantidad, v_costo_mov, p_cantidad * v_costo_mov, v_prom,
    v_cant, v_valor, p_documento_tipo, p_documento_id,
    coalesce(p_usuario_id, auth.uid()), p_notas
  ) returning id into v_id;

  return v_id;
end $$;


-- FEFO: primero el lote que vence antes
create or replace function fn_lotes_fefo(p_producto_id uuid, p_sucursal_id uuid)
returns table (lote_id uuid, codigo text, fecha_vencimiento date, cantidad numeric)
language sql stable as $$
  select l.id, l.codigo, l.fecha_vencimiento, e.cantidad
  from existencias e
  join lotes l on l.id = e.lote_id
  where e.producto_id = p_producto_id
    and e.sucursal_id = p_sucursal_id
    and e.cantidad > 0
  order by l.fecha_vencimiento nulls last, l.creado_en
$$;


-- ============================================================================
-- 8. COMPRAS
-- ============================================================================

create table ordenes_compra (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  sucursal_id      uuid not null references sucursales(id),
  proveedor_id     uuid not null references proveedores(id),
  numero           text not null,
  estado           estado_orden_compra not null default 'borrador',
  fecha            date not null default current_date,
  fecha_esperada   date,
  subtotal         numeric(16,4) not null default 0,
  impuesto         numeric(16,4) not null default 0,
  total            numeric(16,4) not null default 0,
  notas            text,
  creada_por       uuid references perfiles(id),
  creada_en        timestamptz not null default now(),
  actualizado_en   timestamptz not null default now(),
  unique (organizacion_id, numero)
);

create table orden_compra_detalle (
  id                uuid primary key default gen_random_uuid(),
  organizacion_id   uuid not null references organizaciones(id) on delete cascade,
  orden_compra_id   uuid not null references ordenes_compra(id) on delete cascade,
  producto_id       uuid not null references productos(id),
  presentacion_id   uuid references presentaciones(id),
  cantidad          numeric(14,3) not null check (cantidad > 0),
  cantidad_recibida numeric(14,3) not null default 0,
  costo_unitario    numeric(14,4) not null default 0
);

create table facturas_compra (
  id                uuid primary key default gen_random_uuid(),
  organizacion_id   uuid not null references organizaciones(id) on delete cascade,
  sucursal_id       uuid not null references sucursales(id),
  proveedor_id      uuid not null references proveedores(id),
  orden_compra_id   uuid references ordenes_compra(id) on delete set null,
  numero            text not null,                 -- número del documento del proveedor
  cai_proveedor     text,
  fecha             date not null default current_date,
  fecha_vencimiento date,                          -- vencimiento del crédito
  subtotal          numeric(16,4) not null default 0,
  descuento         numeric(16,4) not null default 0,
  impuesto          numeric(16,4) not null default 0,
  total             numeric(16,4) not null default 0,
  saldo             numeric(16,4) not null default 0,
  estado            estado_documento not null default 'borrador',
  archivo_url       text,                          -- PDF/foto en Storage
  notas             text,
  creada_por        uuid references perfiles(id),
  confirmada_en     timestamptz,
  creada_en         timestamptz not null default now(),
  actualizado_en    timestamptz not null default now(),
  unique (organizacion_id, proveedor_id, numero)
);

create table factura_compra_detalle (
  id                 uuid primary key default gen_random_uuid(),
  organizacion_id    uuid not null references organizaciones(id) on delete cascade,
  factura_compra_id  uuid not null references facturas_compra(id) on delete cascade,
  producto_id        uuid not null references productos(id),
  presentacion_id    uuid references presentaciones(id),
  cantidad           numeric(14,3) not null check (cantidad > 0),
  costo_unitario     numeric(14,4) not null check (costo_unitario >= 0),  -- por presentación
  descuento          numeric(14,4) not null default 0,
  tasa_impuesto      numeric(6,4) not null default 0,
  lote_codigo        text,
  fecha_vencimiento  date
);

create table pagos_compra (
  id                 uuid primary key default gen_random_uuid(),
  organizacion_id    uuid not null references organizaciones(id) on delete cascade,
  factura_compra_id  uuid not null references facturas_compra(id) on delete cascade,
  fecha              date not null default current_date,
  monto              numeric(16,4) not null check (monto > 0),
  metodo             text not null default 'efectivo',
  referencia         text,
  registrado_por     uuid references perfiles(id),
  creado_en          timestamptz not null default now()
);


-- ---------------------------------------------------------------------------
-- Confirmar factura de compra: crea lotes, mueve kardex y deja la CxP
-- ---------------------------------------------------------------------------
create or replace function fn_confirmar_factura_compra(p_factura_id uuid)
returns void
language plpgsql security definer set search_path = public, app as $$
declare
  f          record;
  d          record;
  v_factor   numeric;
  v_cant_base numeric;
  v_costo_base numeric;
  v_lote     uuid;
  v_sub      numeric := 0;
  v_imp      numeric := 0;
begin
  select * into f from facturas_compra where id = p_factura_id for update;

  if f.id is null then
    raise exception 'Factura de compra inexistente';
  end if;
  if f.estado <> 'borrador' then
    raise exception 'Solo se confirman facturas en borrador (estado actual: %)', f.estado;
  end if;

  for d in
    select fcd.*, p.controla_lote, p.controla_vencimiento
    from factura_compra_detalle fcd
    join productos p on p.id = fcd.producto_id
    where fcd.factura_compra_id = p_factura_id
  loop
    v_factor := coalesce((select factor from presentaciones where id = d.presentacion_id), 1);

    -- Todo se guarda en unidad base: compras por fardo, vendes por unidad
    v_cant_base  := d.cantidad * v_factor;
    v_costo_base := (d.costo_unitario - d.descuento) / nullif(v_factor, 0);

    v_lote := null;
    if d.controla_lote or d.controla_vencimiento
       or d.lote_codigo is not null or d.fecha_vencimiento is not null then
      insert into lotes (organizacion_id, producto_id, sucursal_id, codigo,
                         fecha_vencimiento, costo_ingreso, proveedor_id, documento_origen)
      values (f.organizacion_id, d.producto_id, f.sucursal_id,
              coalesce(d.lote_codigo, f.numero), d.fecha_vencimiento,
              v_costo_base, f.proveedor_id, 'FC-' || f.numero)
      on conflict (producto_id, sucursal_id, codigo, fecha_vencimiento)
        do update set costo_ingreso = excluded.costo_ingreso
      returning id into v_lote;
    end if;

    perform fn_kardex_registrar(
      f.sucursal_id, d.producto_id, 'compra',
      v_cant_base, v_costo_base, v_lote,
      'factura_compra', f.id,
      'Compra ' || f.numero, f.creada_por
    );

    v_sub := v_sub + (v_cant_base * v_costo_base);
    v_imp := v_imp + (v_cant_base * v_costo_base * d.tasa_impuesto);
  end loop;

  update facturas_compra
     set subtotal = round(v_sub, 4),
         impuesto = round(v_imp, 4),
         total    = round(v_sub + v_imp, 4),
         saldo    = round(v_sub + v_imp, 4),
         estado   = 'confirmado',
         confirmada_en = now(),
         actualizado_en = now()
   where id = p_factura_id;

  if f.orden_compra_id is not null then
    update ordenes_compra set estado = 'recibida', actualizado_en = now()
     where id = f.orden_compra_id;
  end if;
end $$;


-- Saldo de la cuenta por pagar al registrar un pago
create or replace function app.aplicar_pago_compra()
returns trigger language plpgsql as $$
begin
  update facturas_compra
     set saldo = greatest(saldo - new.monto, 0),
         actualizado_en = now()
   where id = new.factura_compra_id;
  return new;
end $$;

create trigger tg_pago_compra
  after insert on pagos_compra
  for each row execute function app.aplicar_pago_compra();


-- ============================================================================
-- 9. VISTAS DE OPERACIÓN
-- ============================================================================

-- Existencias consolidadas por producto y sucursal
create view v_existencias as
select
  e.organizacion_id,
  e.sucursal_id,
  s.nombre                          as sucursal,
  e.producto_id,
  p.sku,
  p.nombre                          as producto,
  c.nombre                          as categoria,
  sum(e.cantidad)                   as cantidad,
  p.stock_minimo,
  p.stock_maximo,
  coalesce(pc.costo_promedio, 0)    as costo_promedio,
  round(sum(e.cantidad) * coalesce(pc.costo_promedio, 0), 2) as valor_inventario
from existencias e
join productos  p on p.id = e.producto_id
join sucursales s on s.id = e.sucursal_id
left join categorias c on c.id = p.categoria_id
left join producto_costos pc
       on pc.producto_id = e.producto_id and pc.sucursal_id = e.sucursal_id
group by e.organizacion_id, e.sucursal_id, s.nombre, e.producto_id,
         p.sku, p.nombre, c.nombre, p.stock_minimo, p.stock_maximo, pc.costo_promedio;

-- Semáforo de vencimientos
create view v_vencimientos as
select
  l.organizacion_id,
  l.sucursal_id,
  l.producto_id,
  p.sku,
  p.nombre                                as producto,
  l.id                                    as lote_id,
  l.codigo                                as lote,
  l.fecha_vencimiento,
  (l.fecha_vencimiento - current_date)    as dias_restantes,
  e.cantidad,
  round(e.cantidad * l.costo_ingreso, 2)  as valor_en_riesgo,
  case
    when l.fecha_vencimiento < current_date then 'vencido'
    when l.fecha_vencimiento <= current_date
         + greatest(coalesce(p.dias_alerta_vencim, o.dias_alerta_vencimiento) / 3, 3) then 'critico'
    when l.fecha_vencimiento <= current_date
         + coalesce(p.dias_alerta_vencim, o.dias_alerta_vencimiento) then 'proximo'
    else 'ok'
  end as semaforo
from lotes l
join existencias e on e.lote_id = l.id and e.cantidad > 0
join productos p on p.id = l.producto_id
join organizaciones o on o.id = l.organizacion_id
where l.fecha_vencimiento is not null;

-- Productos bajo mínimo
create view v_stock_bajo as
select *
from v_existencias
where cantidad <= stock_minimo;


-- ============================================================================
-- 10. TRIGGERS DE actualizado_en
-- ============================================================================

do $$
declare t text;
begin
  foreach t in array array[
    'organizaciones','sucursales','perfiles','categorias','marcas','proveedores',
    'impuestos','productos','precios','ordenes_compra','facturas_compra'
  ] loop
    execute format(
      'create trigger tg_%1$s_upd before update on %1$I
       for each row execute function app.set_actualizado_en()', t);
  end loop;
end $$;


-- ============================================================================
-- 11. RLS · AISLAMIENTO POR ORGANIZACIÓN Y PERMISOS POR ROL
-- ============================================================================

alter table organizaciones     enable row level security;
alter table perfiles           enable row level security;
alter table usuario_sucursales enable row level security;

-- Organización: cada quien ve la suya; el admin de plataforma las ve todas
create policy org_select on organizaciones for select
  using (id = app.org_id() or app.es_admin());
create policy org_update on organizaciones for update
  using ((id = app.org_id() and app.tiene_nivel('gerente')) or app.es_admin());
create policy org_admin_all on organizaciones for all
  using (app.es_admin()) with check (app.es_admin());

-- Perfiles: todos ven a su equipo; solo gerente+ los administra
create policy perfil_select on perfiles for select
  using (organizacion_id = app.org_id() or app.es_admin());
create policy perfil_update_propio on perfiles for update
  using (id = auth.uid()) with check (id = auth.uid() and rol = app.rol());
create policy perfil_gestion on perfiles for all
  using ((organizacion_id = app.org_id() and app.tiene_nivel('gerente')) or app.es_admin())
  with check ((organizacion_id = app.org_id() and app.tiene_nivel('gerente')) or app.es_admin());

create policy us_select on usuario_sucursales for select
  using (exists (select 1 from perfiles p
                 where p.id = usuario_sucursales.perfil_id
                   and (p.organizacion_id = app.org_id() or app.es_admin())));
create policy us_gestion on usuario_sucursales for all
  using (app.tiene_nivel('gerente')) with check (app.tiene_nivel('gerente'));

-- ---------------------------------------------------------------------------
-- Patrón general: lectura para toda la organización, escritura por nivel
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
  -- Solo gerente+ escribe (catálogo, precios, estructura)
  tablas_gerente text[] := array[
    'sucursales','categorias','marcas','proveedores','impuestos',
    'productos','presentaciones','producto_codigos','precios','series_fiscales'
  ];
  -- Supervisor+ escribe (operación de compras e inventario)
  tablas_supervisor text[] := array[
    'ordenes_compra','orden_compra_detalle','facturas_compra',
    'factura_compra_detalle','pagos_compra','lotes'
  ];
begin
  foreach t in array (tablas_gerente || tablas_supervisor) loop
    execute format('alter table %I enable row level security', t);
    execute format(
      'create policy %I on %I for select
         using (organizacion_id = app.org_id() or app.es_admin())',
      t || '_sel', t);
  end loop;

  foreach t in array tablas_gerente loop
    execute format(
      'create policy %I on %I for all
         using ((organizacion_id = app.org_id() and app.tiene_nivel(''gerente'')) or app.es_admin())
         with check ((organizacion_id = app.org_id() and app.tiene_nivel(''gerente'')) or app.es_admin())',
      t || '_esc', t);
  end loop;

  foreach t in array tablas_supervisor loop
    execute format(
      'create policy %I on %I for all
         using ((organizacion_id = app.org_id() and app.tiene_nivel(''supervisor'')) or app.es_admin())
         with check ((organizacion_id = app.org_id() and app.tiene_nivel(''supervisor'')) or app.es_admin())',
      t || '_esc', t);
  end loop;
end $$;

-- Existencias: las ve todo el personal (cantidades, sin costos).
-- Se escriben únicamente a través de fn_kardex_registrar.
alter table existencias enable row level security;
create policy existencias_sel on existencias for select
  using (organizacion_id = app.org_id() or app.es_admin());

-- Kardex: supervisor+ (contiene costos por movimiento)
alter table kardex enable row level security;
create policy kardex_sel on kardex for select
  using ((organizacion_id = app.org_id() and app.tiene_nivel('supervisor')) or app.es_admin());

-- Costos y márgenes: gerente+ (según la matriz de permisos)
alter table producto_costos enable row level security;
create policy costos_sel on producto_costos for select
  using ((organizacion_id = app.org_id() and app.tiene_nivel('gerente')) or app.es_admin());


-- ============================================================================
-- 12. ÍNDICES DE APOYO
-- ============================================================================

create index ix_productos_org      on productos (organizacion_id, activo);
create index ix_productos_cat      on productos (categoria_id);
create index ix_productos_prov     on productos (proveedor_id);
create index ix_productos_busqueda on productos using gin (to_tsvector('spanish', nombre));
create index ix_codigos_codigo     on producto_codigos (codigo);
create index ix_existencias_suc    on existencias (sucursal_id, producto_id);
create index ix_lotes_venc         on lotes (sucursal_id, fecha_vencimiento)
                                   where fecha_vencimiento is not null;
create index ix_fc_estado          on facturas_compra (organizacion_id, estado, fecha desc);
create index ix_fc_saldo           on facturas_compra (proveedor_id) where saldo > 0;
create index ix_precios_lookup     on precios (producto_id, sucursal_id, nivel, cantidad_minima);
