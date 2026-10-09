-- ============================================================================
--  023 · Auditoria de bodega y conteo de piso
--
--  EL PROCESO, Y POR QUE ESE ORDEN
--
--  1) Se audita la bodega, ubicacion por ubicacion: se escanea el QR del
--     lugar y despues cada producto que hay adentro.
--  2) Solo entonces se puede contar un producto, y se cuenta UNICAMENTE en
--     el piso de ventas.
--
--  El orden no es capricho. En este sistema el piso de ventas no se guarda:
--  SE CALCULA como el resto -el total menos lo que esta asignado a bodega-.
--  Si la cifra de bodega esta vieja, la del piso es basura, y contar el piso
--  contra una cifra basura produce un ajuste basura. Por eso: bodega
--  auditada hace menos de 24 horas, o no se deja contar.
--
--  LA AUDITORIA NO CAMBIA EL TOTAL DEL NEGOCIO
--
--  Solo dice DONDE esta la mercaderia. Lo que la auditoria encuentra de menos
--  en la bodega no desaparece: pasa a ser parte del resto, o sea del piso, y
--  ahi lo encuentra -o no- el conteo del piso, que si va a aprobacion y si
--  cambia el total. Cada cosa en su lugar: la auditoria acomoda, el conteo
--  ajusta.
--
--  ESCANEAR SUMA
--
--  En una ubicacion puede haber tres cajas del mismo producto. Escanear la
--  segunda no reemplaza lo de la primera: lo suma. La pantalla muestra
--  cuanto llevaba y propone la caja completa como cantidad, por si no quiere
--  contar unidad por unidad.
--
--  QUIEN HACE QUE
--
--      auxiliar     abre la auditoria y escanea
--      supervisor   la completa, que es lo que reescribe la ubicacion
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Las ubicaciones ahora tienen tipo y codigo
--
--    tipo   · 'piso' o 'bodega'. Decide que se audita y que se cuenta.
--    codigo · lo que lleva el QR pegado en el estante.
-- ---------------------------------------------------------------------------

alter table ubicaciones add column if not exists tipo text not null default 'piso';
alter table ubicaciones add column if not exists codigo text;

do $$ begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'ubicaciones'::regclass and conname = 'ubicaciones_tipo_check') then
    alter table ubicaciones add constraint ubicaciones_tipo_check
      check (tipo in ('piso','bodega'));
  end if;
end $$;

-- Lo que ya existe: la bodega es bodega, el resto piso.
update ubicaciones set tipo = 'bodega'
 where tipo <> 'bodega' and lower(btrim(nombre)) like '%bodega%';

-- El codigo lleva el de la sucursal adelante para que no choquen dos
-- sucursales del mismo negocio, y para que al leerlo se sepa de donde es.
create or replace function app.codigo_ubicacion(p_sucursal uuid, p_tipo text)
returns text
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_suc text;
  v_pre text;
  v_n   int;
begin
  select nullif(btrim(coalesce(codigo,'')), '') into v_suc from sucursales where id = p_sucursal;
  v_suc := coalesce(v_suc, left(replace(p_sucursal::text, '-', ''), 4));
  v_pre := case when p_tipo = 'bodega' then 'B' else 'P' end;

  select coalesce(max(substring(u.codigo from '[0-9]+$')::int), 0) + 1 into v_n
  from ubicaciones u
  where u.sucursal_id = p_sucursal
    and u.codigo like v_suc || '-' || v_pre || '%';

  return v_suc || '-' || v_pre || lpad(v_n::text, 2, '0');
end $fn$;

revoke execute on function app.codigo_ubicacion(uuid, text) from public, anon;

-- Ponerle codigo a las que ya existen, una por una para no repetir numero.
do $$
declare u record;
begin
  for u in select id, sucursal_id, tipo from ubicaciones
            where codigo is null order by sucursal_id, orden, nombre loop
    update ubicaciones set codigo = app.codigo_ubicacion(u.sucursal_id, u.tipo)
     where id = u.id;
  end loop;
end $$;

create unique index if not exists ux_ubicaciones_codigo
  on ubicaciones (organizacion_id, codigo);

create index if not exists ix_ubicaciones_tipo on ubicaciones (sucursal_id, tipo, activa);

-- Las nuevas tambien
create or replace function app.tg_sucursal_ubicaciones()
returns trigger
language plpgsql security definer set search_path = public, app as $fn$
begin
  insert into ubicaciones (organizacion_id, sucursal_id, nombre, es_predeterminada,
                           orden, tipo, codigo)
  values (new.organizacion_id, new.id, 'Piso de ventas', true,  10, 'piso',
          app.codigo_ubicacion(new.id, 'piso'))
  on conflict do nothing;
  insert into ubicaciones (organizacion_id, sucursal_id, nombre, es_predeterminada,
                           orden, tipo, codigo)
  values (new.organizacion_id, new.id, 'Bodega', false, 200, 'bodega',
          app.codigo_ubicacion(new.id, 'bodega'))
  on conflict do nothing;
  return new;
end $fn$;


-- ---------------------------------------------------------------------------
-- 2. Cuantas unidades trae una caja
--
--    Sin esto el boton de "caja completa" no tiene que proponer. Es el mismo
--    dato que el equipo de un supermercado llama "Empaque".
-- ---------------------------------------------------------------------------

alter table productos add column if not exists unidades_empaque numeric(14,3);


-- ---------------------------------------------------------------------------
-- 3. La predeterminada tiene que ser del piso
--
--    La predeterminada es donde cae el resto. Si fuera una bodega, el resto
--    -o sea lo que no esta asignado- se leeria como bodega y el piso siempre
--    saldria en cero. Todo el modelo se apoya en esto.
-- ---------------------------------------------------------------------------

create or replace function fn_guardar_ubicacion(
  p_nombre      text,
  p_id          uuid default null,
  p_sucursal_id uuid default null,
  p_orden       int  default null,
  p_activa      boolean default true
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid; v_suc uuid; v_id uuid; v_pred boolean;
begin
  v_org := app.org_id();
  if v_org is null or not app.tiene_nivel('supervisor') then
    raise exception 'Solo un supervisor puede crear o cambiar ubicaciones';
  end if;
  if p_nombre is null or btrim(p_nombre) = '' then
    raise exception 'La ubicacion necesita un nombre';
  end if;

  if p_id is not null then
    select id, sucursal_id, es_predeterminada into v_id, v_suc, v_pred
    from ubicaciones where id = p_id and organizacion_id = v_org;
    if v_id is null then raise exception 'Esa ubicacion no es de su negocio'; end if;

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

    insert into ubicaciones (organizacion_id, sucursal_id, nombre, orden, activa,
                             tipo, codigo)
    values (v_org, v_suc, btrim(p_nombre), coalesce(p_orden, 100),
            coalesce(p_activa, true), 'piso', app.codigo_ubicacion(v_suc, 'piso'))
    returning id into v_id;
  end if;

  return jsonb_build_object('ubicacion_id', v_id, 'nombre', btrim(p_nombre),
                            'codigo', (select codigo from ubicaciones where id = v_id));
end $fn$;

revoke execute on function fn_guardar_ubicacion(text, uuid, uuid, int, boolean)
  from public, anon;
grant execute on function fn_guardar_ubicacion(text, uuid, uuid, int, boolean)
  to authenticated;


-- Si es de piso o de bodega va aparte: cambiarlo mueve que se audita y que
-- se cuenta, no es renombrar un estante.
create or replace function fn_fijar_tipo_ubicacion(p_ubicacion_id uuid, p_tipo text)
returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare v_org uuid; u record;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('supervisor'))) then
    raise exception 'Solo un supervisor puede cambiar el tipo de una ubicacion';
  end if;
  if p_tipo not in ('piso','bodega') then
    raise exception 'La ubicacion es de piso o de bodega';
  end if;

  select * into u from ubicaciones
   where id = p_ubicacion_id and (organizacion_id = v_org or app.es_admin());
  if u.id is null then raise exception 'Esa ubicacion no es de su negocio'; end if;

  if u.es_predeterminada and p_tipo <> 'piso' then
    raise exception 'La ubicacion predeterminada tiene que ser del piso de ventas: ahi cae todo lo que no se asigna a un lugar';
  end if;
  if exists (select 1 from auditorias where ubicacion_id = u.id and estado = 'abierta') then
    raise exception 'Hay una auditoria abierta en %. Terminela o cancelela antes de cambiarle el tipo', u.nombre;
  end if;

  if u.tipo <> p_tipo then
    update ubicaciones
       set tipo = p_tipo, codigo = app.codigo_ubicacion(u.sucursal_id, p_tipo)
     where id = u.id;
  end if;

  return jsonb_build_object('ubicacion_id', u.id, 'nombre', u.nombre, 'tipo', p_tipo,
                            'codigo', (select codigo from ubicaciones where id = u.id));
end $fn$;

revoke execute on function fn_fijar_tipo_ubicacion(uuid, text) from public, anon;
grant execute on function fn_fijar_tipo_ubicacion(uuid, text) to authenticated;


create or replace function fn_fijar_ubicacion_predeterminada(p_ubicacion_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare v_org uuid; u record; v_vieja uuid;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('gerente'))) then
    raise exception 'Solo el gerente puede cambiar la ubicacion predeterminada';
  end if;

  select * into u from ubicaciones
   where id = p_ubicacion_id and (organizacion_id = v_org or app.es_admin());
  if u.id is null then raise exception 'Esa ubicacion no es de su negocio'; end if;
  if not u.activa then raise exception 'Una ubicacion inactiva no puede ser la predeterminada'; end if;
  if u.tipo <> 'piso' then
    raise exception 'Solo una ubicacion del piso de ventas puede ser la predeterminada: ahi cae todo lo que no se asigna a un lugar';
  end if;
  if u.es_predeterminada then
    return jsonb_build_object('ubicacion_id', u.id, 'nombre', u.nombre, 'cambio', false);
  end if;

  select id into v_vieja from ubicaciones
   where sucursal_id = u.sucursal_id and es_predeterminada;

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

  update existencias_ubicacion
     set cantidad = 0, actualizado_en = now()
   where ubicacion_id = u.id and cantidad <> 0;

  update ubicaciones set es_predeterminada = true where id = u.id;

  return jsonb_build_object('ubicacion_id', u.id, 'nombre', u.nombre, 'cambio', true);
end $fn$;

revoke execute on function fn_fijar_ubicacion_predeterminada(uuid) from public, anon;
grant execute on function fn_fijar_ubicacion_predeterminada(uuid) to authenticated;


-- Resolver el QR que se escaneo
create or replace function fn_ubicacion_por_codigo(p_codigo text)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare u record; v_org uuid; v_cod text;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para ver las ubicaciones';
  end if;

  -- El QR puede traer el codigo pelado o con un prefijo; se limpia.
  v_cod := upper(btrim(coalesce(p_codigo, '')));
  v_cod := regexp_replace(v_cod, '^(PULP[-:]?U[-:]?|UBI[-:]?)', '');

  select * into u from ubicaciones
   where organizacion_id = v_org and upper(codigo) = v_cod;
  if u.id is null then
    raise exception 'No hay ninguna ubicacion con el codigo %', v_cod;
  end if;
  if not u.activa then raise exception 'La ubicacion % esta inactiva', u.nombre; end if;
  if not app.es_admin() and u.sucursal_id not in (select app.sucursales_permitidas()) then
    raise exception 'Esa ubicacion es de otra sucursal';
  end if;

  return jsonb_build_object(
    'ubicacion_id', u.id, 'nombre', u.nombre, 'codigo', u.codigo,
    'tipo', u.tipo, 'predeterminada', u.es_predeterminada,
    'sucursal_id', u.sucursal_id,
    'sucursal', (select nombre from sucursales where id = u.sucursal_id));
end $fn$;

revoke execute on function fn_ubicacion_por_codigo(text) from public, anon;
grant execute on function fn_ubicacion_por_codigo(text) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. Las auditorias
-- ---------------------------------------------------------------------------

create table if not exists auditorias (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references organizaciones(id) on delete cascade,
  sucursal_id     uuid not null references sucursales(id),
  ubicacion_id    uuid not null references ubicaciones(id),
  numero          text not null,
  estado          text not null default 'abierta'
                  check (estado in ('abierta','aplicada','cancelada')),
  -- Si al completar se vacia lo que nadie escaneo, o se deja como estaba.
  vacio_no_escaneados boolean,
  notas           text,
  motivo_cancelacion text,
  abierta_por     uuid references perfiles(id),
  abierta_en      timestamptz not null default now(),
  cerrada_por     uuid references perfiles(id),
  cerrada_en      timestamptz,
  unique (organizacion_id, numero)
);

create unique index if not exists ux_auditoria_abierta
  on auditorias (ubicacion_id) where estado = 'abierta';
create index if not exists ix_auditorias_ubic
  on auditorias (ubicacion_id, estado, cerrada_en desc);

create table if not exists auditoria_detalle (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references organizaciones(id) on delete cascade,
  auditoria_id    uuid not null references auditorias(id) on delete cascade,
  producto_id     uuid not null references productos(id),
  lote_id         uuid references lotes(id),
  cantidad        numeric(16,3) not null default 0 check (cantidad >= 0),
  -- Cuantas veces se escaneo: tres cajas del mismo producto son tres
  -- escaneos, y verlo ayuda a saber si alguien conto dos veces lo mismo.
  escaneos        int not null default 0,
  contado_por     uuid references perfiles(id),
  actualizado_en  timestamptz not null default now()
);

create unique index if not exists ux_auditoria_detalle
  on auditoria_detalle (auditoria_id, producto_id, lote_id) nulls not distinct;
create index if not exists ix_auditoria_detalle on auditoria_detalle (auditoria_id);

alter table auditorias        enable row level security;
alter table auditoria_detalle enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies
                  where tablename='auditorias' and policyname='auditorias_sel') then
    create policy auditorias_sel on auditorias for select
      using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))
             or app.es_admin());
  end if;
  if not exists (select 1 from pg_policies
                  where tablename='auditoria_detalle' and policyname='aud_det_sel') then
    create policy aud_det_sel on auditoria_detalle for select
      using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))
             or app.es_admin());
  end if;
end $$;

revoke insert, update, delete on auditorias        from authenticated;
revoke insert, update, delete on auditoria_detalle from authenticated;
grant select on auditorias        to authenticated;
grant select on auditoria_detalle to authenticated;



-- La lista rica va con OTRO NOMBRE: fn_ubicaciones ya existe con menos
-- columnas y cambiarle la forma exige soltarla, cosa que el tunel de
-- migraciones no permite.
create or replace function fn_ubicaciones_detalle(p_sucursal_id uuid default null)
returns table (
  ubicacion_id      uuid,
  nombre            text,
  es_predeterminada boolean,
  orden             int,
  activa            boolean,
  tipo              text,
  codigo            text,
  auditada_en       timestamptz,
  productos         int,
  unidades          numeric
)
language sql stable security definer set search_path = public, app as $fn$
  select u.id, u.nombre, u.es_predeterminada, u.orden, u.activa, u.tipo, u.codigo,
         (select max(a.cerrada_en) from auditorias a
           where a.ubicacion_id = u.id and a.estado = 'aplicada'),
         (select count(*)::int from existencias_ubicacion eu
           where eu.ubicacion_id = u.id and eu.cantidad > 0),
         (select coalesce(sum(eu.cantidad), 0) from existencias_ubicacion eu
           where eu.ubicacion_id = u.id)
  from ubicaciones u
  where app.tiene_nivel('auxiliar')
    and (u.organizacion_id = app.org_id() or app.es_admin())
    and u.sucursal_id = coalesce(
          p_sucursal_id,
          (select s.id from sucursales s
            where s.organizacion_id = app.org_id() and s.activa
            order by s.es_principal desc limit 1))
  order by u.tipo desc, u.orden, u.nombre
$fn$;

revoke execute on function fn_ubicaciones_detalle(uuid) from public, anon;
grant execute on function fn_ubicaciones_detalle(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. Abrir
-- ---------------------------------------------------------------------------

create or replace function fn_abrir_auditoria(p_ubicacion_id uuid, p_notas text default null)
returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid; u record; v_id uuid; v_num text; v_ab record;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para auditar';
  end if;

  select * into u from ubicaciones
   where id = p_ubicacion_id and (organizacion_id = v_org or app.es_admin());
  if u.id is null then raise exception 'Esa ubicacion no es de su negocio'; end if;
  if not u.activa then raise exception 'La ubicacion % esta inactiva', u.nombre; end if;
  if not app.es_admin() and u.sucursal_id not in (select app.sucursales_permitidas()) then
    raise exception 'No tiene acceso a esa sucursal';
  end if;
  -- Se avisa al abrir y no al completar: enterarse despues de escanear un
  -- estante entero es la peor forma de enterarse.
  if u.es_predeterminada then
    raise exception 'La ubicacion % no se audita: su cantidad es el resto de todo lo demas. Audite las bodegas y cuente el piso desde Consultar', u.nombre;
  end if;

  -- Si ya hay una abierta se sigue esa. Dos personas auditando el mismo
  -- estante y guardando por separado es la forma de perder lo contado.
  select * into v_ab from auditorias
   where ubicacion_id = u.id and estado = 'abierta';
  if v_ab.id is not null then
    return jsonb_build_object(
      'auditoria_id', v_ab.id, 'numero', v_ab.numero, 'ubicacion', u.nombre,
      'codigo', u.codigo, 'tipo', u.tipo, 'ya_estaba', true,
      'abierta_por', (select nombre from perfiles where id = v_ab.abierta_por),
      'abierta_en', v_ab.abierta_en);
  end if;

  v_num := app.numero_documento(u.organizacion_id, u.sucursal_id, 'auditoria', 'AU', 6);

  insert into auditorias (organizacion_id, sucursal_id, ubicacion_id, numero,
                          notas, abierta_por)
  values (u.organizacion_id, u.sucursal_id, u.id, v_num,
          nullif(btrim(coalesce(p_notas,'')), ''), auth.uid())
  returning id into v_id;

  return jsonb_build_object(
    'auditoria_id', v_id, 'numero', v_num, 'ubicacion', u.nombre,
    'codigo', u.codigo, 'tipo', u.tipo, 'ya_estaba', false,
    'abierta_en', now());
end $fn$;

revoke execute on function fn_abrir_auditoria(uuid, text) from public, anon;
grant execute on function fn_abrir_auditoria(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 6. Escanear un producto: SUMA
--
--    En un estante puede haber tres cajas del mismo producto. La segunda no
--    reemplaza a la primera.
-- ---------------------------------------------------------------------------

create or replace function fn_auditar_producto(
  p_auditoria_id uuid,
  p_producto_id  uuid,
  p_cantidad     numeric,
  p_lote_id      uuid default null,
  p_reemplazar   boolean default false   -- true: corregir, no sumar
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  a        record;
  pr       record;
  v_antes  numeric := 0;
  v_total  numeric;
  v_esc    int;
begin
  if p_cantidad is null or p_cantidad < 0 then
    raise exception 'La cantidad no puede ser negativa';
  end if;

  select * into a from auditorias where id = p_auditoria_id;
  if a.id is null then raise exception 'Esa auditoria no existe'; end if;
  if a.estado <> 'abierta' then raise exception 'Esa auditoria ya se cerro'; end if;
  if not (app.es_admin()
          or (a.organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para auditar en este negocio';
  end if;

  select * into pr from productos
   where id = p_producto_id and organizacion_id = a.organizacion_id
     and activo and tipo <> 'servicio';
  if pr.id is null then raise exception 'Ese producto no es de este negocio'; end if;

  if p_lote_id is not null then
    perform 1 from lotes
     where id = p_lote_id and producto_id = p_producto_id and sucursal_id = a.sucursal_id;
    if not found then raise exception 'Ese lote no corresponde al producto en esta sucursal'; end if;
  end if;

  select cantidad, escaneos into v_antes, v_esc
  from auditoria_detalle
  where auditoria_id = a.id and producto_id = p_producto_id
    and lote_id is not distinct from p_lote_id;

  v_antes := coalesce(v_antes, 0);
  v_total := case when p_reemplazar then p_cantidad else v_antes + p_cantidad end;

  insert into auditoria_detalle (organizacion_id, auditoria_id, producto_id, lote_id,
                                 cantidad, escaneos, contado_por)
  values (a.organizacion_id, a.id, p_producto_id, p_lote_id, v_total, 1, auth.uid())
  on conflict (auditoria_id, producto_id, lote_id) do update
    set cantidad = v_total,
        escaneos = case when p_reemplazar then auditoria_detalle.escaneos
                        else auditoria_detalle.escaneos + 1 end,
        contado_por = auth.uid(),
        actualizado_en = now();

  return jsonb_build_object(
    'producto_id', pr.id, 'producto', pr.nombre, 'sku', pr.sku,
    'unidad', pr.unidad_base,
    'empaque', pr.unidades_empaque,
    'llevaba', v_antes,
    'agregado', case when p_reemplazar then null else p_cantidad end,
    'total', v_total,
    'escaneos', coalesce(v_esc, 0) + case when p_reemplazar then 0 else 1 end);
end $fn$;

revoke execute on function fn_auditar_producto(uuid, uuid, numeric, uuid, boolean)
  from public, anon;
grant execute on function fn_auditar_producto(uuid, uuid, numeric, uuid, boolean)
  to authenticated;


-- ---------------------------------------------------------------------------
-- 7. Como va la auditoria
--
--    Dos listas: lo que ya se escaneo, y lo que el sistema creia que estaba
--    aqui y todavia nadie toco. La segunda es la que evita completar a medias.
-- ---------------------------------------------------------------------------

create or replace function fn_auditoria_lineas(p_auditoria_id uuid)
returns table (
  escaneado   boolean,
  producto_id uuid,
  producto    text,
  sku         text,
  unidad      text,
  empaque     numeric,
  lote_id     uuid,
  lote        text,
  vence       date,
  contado     numeric,
  sistema     numeric,
  escaneos    int,
  quien       text,
  actualizado timestamptz
)
language plpgsql stable security definer set search_path = public, app as $fn$
declare a record;
begin
  select * into a from auditorias where id = p_auditoria_id;
  if a.id is null then raise exception 'Esa auditoria no existe'; end if;
  if not (app.es_admin()
          or (a.organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))) then
    raise exception 'Esa auditoria no es de este negocio';
  end if;

  return query
  select true, d.producto_id, pr.nombre, pr.sku, pr.unidad_base, pr.unidades_empaque,
         d.lote_id, lo.codigo, lo.fecha_vencimiento,
         d.cantidad,
         coalesce((select eu.cantidad from existencias_ubicacion eu
                    where eu.producto_id = d.producto_id
                      and eu.sucursal_id = a.sucursal_id
                      and eu.ubicacion_id = a.ubicacion_id
                      and eu.lote_id is not distinct from d.lote_id), 0),
         d.escaneos, pe.nombre, d.actualizado_en
  from auditoria_detalle d
  join productos pr     on pr.id = d.producto_id
  left join lotes lo    on lo.id = d.lote_id
  left join perfiles pe on pe.id = d.contado_por
  where d.auditoria_id = a.id

  union all

  -- Lo que el sistema dice que esta aqui y nadie ha escaneado
  select false, eu.producto_id, pr.nombre, pr.sku, pr.unidad_base, pr.unidades_empaque,
         eu.lote_id, lo.codigo, lo.fecha_vencimiento,
         null::numeric, eu.cantidad, 0, null::text, null::timestamptz
  from existencias_ubicacion eu
  join productos pr  on pr.id = eu.producto_id
  left join lotes lo on lo.id = eu.lote_id
  where eu.ubicacion_id = a.ubicacion_id
    and eu.cantidad > 0
    and not exists (select 1 from auditoria_detalle d
                     where d.auditoria_id = a.id
                       and d.producto_id = eu.producto_id
                       and d.lote_id is not distinct from eu.lote_id)

  order by 1 desc, 13 desc nulls last, 3;
end $fn$;

revoke execute on function fn_auditoria_lineas(uuid) from public, anon;
grant execute on function fn_auditoria_lineas(uuid) to authenticated;


create or replace function fn_auditoria_resumen(p_auditoria_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare a record; u record;
begin
  select * into a from auditorias where id = p_auditoria_id;
  if a.id is null then raise exception 'Esa auditoria no existe'; end if;
  if not (app.es_admin()
          or (a.organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))) then
    raise exception 'Esa auditoria no es de este negocio';
  end if;
  select * into u from ubicaciones where id = a.ubicacion_id;

  return jsonb_build_object(
    'auditoria_id', a.id, 'numero', a.numero, 'estado', a.estado,
    'ubicacion', u.nombre, 'codigo', u.codigo, 'tipo', u.tipo,
    'ubicacion_id', u.id,
    'sucursal', (select nombre from sucursales where id = a.sucursal_id),
    'notas', a.notas, 'motivo_cancelacion', a.motivo_cancelacion,
    'abierta_por', (select nombre from perfiles where id = a.abierta_por),
    'abierta_en', a.abierta_en,
    'cerrada_por', (select nombre from perfiles where id = a.cerrada_por),
    'cerrada_en', a.cerrada_en,
    'escaneados', (select count(*) from auditoria_detalle d where d.auditoria_id = a.id),
    'unidades', (select coalesce(sum(d.cantidad), 0) from auditoria_detalle d
                  where d.auditoria_id = a.id),
    'sin_escanear', (select count(*) from existencias_ubicacion eu
                      where eu.ubicacion_id = a.ubicacion_id and eu.cantidad > 0
                        and not exists (select 1 from auditoria_detalle d
                                         where d.auditoria_id = a.id
                                           and d.producto_id = eu.producto_id
                                           and d.lote_id is not distinct from eu.lote_id)),
    'puede_completar', app.es_admin() or app.tiene_nivel('supervisor'));
end $fn$;

revoke execute on function fn_auditoria_resumen(uuid) from public, anon;
grant execute on function fn_auditoria_resumen(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 8. Completar
--
--    Aqui se reescribe la ubicacion. NO cambia el total del negocio: lo que
--    deja de estar en la bodega pasa al resto, que es el piso, y ahi lo
--    encuentra el conteo del piso.
-- ---------------------------------------------------------------------------

create or replace function fn_completar_auditoria(
  p_auditoria_id uuid,
  p_vaciar_no_escaneados boolean default true
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  a        record;
  u        record;
  ln       record;
  v_tope   numeric;
  v_otros  numeric;
  v_puesto numeric;
  v_n      int := 0;
  v_vac    int := 0;
  v_rec    int := 0;
begin
  select * into a from auditorias where id = p_auditoria_id for update;
  if a.id is null then raise exception 'Esa auditoria no existe'; end if;
  if a.estado <> 'abierta' then raise exception 'Esa auditoria ya se cerro'; end if;

  if not (app.es_admin()
          or (a.organizacion_id = app.org_id() and app.tiene_nivel('supervisor'))) then
    raise exception 'Solo un supervisor de este negocio puede completar una auditoria';
  end if;

  select * into u from ubicaciones where id = a.ubicacion_id;
  if u.es_predeterminada then
    raise exception 'La ubicacion predeterminada no se audita: su cantidad es el resto de todo lo demas';
  end if;

  -- 1. Lo escaneado manda. Pero una ubicacion no puede tener mas de lo que
  --    hay en toda la sucursal: si alguien escanea 50 y en el sistema hay 30
  --    en total, lo que sobra no es de esta ubicacion, es un faltante en
  --    otra parte. Se pone lo que cabe y se avisa.
  for ln in select * from auditoria_detalle where auditoria_id = a.id loop
    select coalesce(sum(e.cantidad), 0) into v_tope
    from existencias e
    where e.producto_id = ln.producto_id and e.sucursal_id = a.sucursal_id
      and e.lote_id is not distinct from ln.lote_id;

    select coalesce(sum(eu.cantidad), 0) into v_otros
    from existencias_ubicacion eu
    where eu.producto_id = ln.producto_id and eu.sucursal_id = a.sucursal_id
      and eu.lote_id is not distinct from ln.lote_id
      and eu.ubicacion_id <> u.id;

    v_puesto := least(ln.cantidad, greatest(v_tope - v_otros, 0));
    if v_puesto < ln.cantidad then v_rec := v_rec + 1; end if;

    insert into existencias_ubicacion (organizacion_id, sucursal_id, producto_id,
                                       lote_id, ubicacion_id, cantidad)
    values (a.organizacion_id, a.sucursal_id, ln.producto_id, ln.lote_id, u.id, v_puesto)
    on conflict (producto_id, sucursal_id, ubicacion_id, lote_id) do update
      set cantidad = v_puesto, actualizado_en = now();

    v_n := v_n + 1;
  end loop;

  -- 2. Lo que nadie escaneo. Auditar un lugar es certificar lo que tiene;
  --    si no se escaneo, no esta aqui, y esas unidades pasan al resto. Pero
  --    el que completa decide, porque a veces se audito a medias.
  if p_vaciar_no_escaneados then
    update existencias_ubicacion eu
       set cantidad = 0, actualizado_en = now()
     where eu.ubicacion_id = u.id
       and eu.cantidad > 0
       and not exists (select 1 from auditoria_detalle d
                        where d.auditoria_id = a.id
                          and d.producto_id = eu.producto_id
                          and d.lote_id is not distinct from eu.lote_id);
    get diagnostics v_vac = row_count;
  end if;

  update auditorias
     set estado = 'aplicada', cerrada_por = auth.uid(), cerrada_en = now(),
         vacio_no_escaneados = p_vaciar_no_escaneados
   where id = a.id;

  return jsonb_build_object(
    'numero', a.numero, 'ubicacion', u.nombre, 'codigo', u.codigo,
    'actualizados', v_n, 'vaciados', v_vac, 'recortados', v_rec,
    'unidades', (select coalesce(sum(cantidad), 0) from auditoria_detalle
                  where auditoria_id = a.id));
end $fn$;

revoke execute on function fn_completar_auditoria(uuid, boolean) from public, anon;
grant execute on function fn_completar_auditoria(uuid, boolean) to authenticated;


create or replace function fn_cancelar_auditoria(p_auditoria_id uuid, p_motivo text)
returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare a record;
begin
  if p_motivo is null or btrim(p_motivo) = '' then
    raise exception 'Cancelar una auditoria exige un motivo';
  end if;
  select * into a from auditorias where id = p_auditoria_id for update;
  if a.id is null then raise exception 'Esa auditoria no existe'; end if;
  if a.estado <> 'abierta' then raise exception 'Esa auditoria ya se cerro'; end if;
  if not (app.es_admin()
          or (a.organizacion_id = app.org_id() and app.tiene_nivel('supervisor'))) then
    raise exception 'Solo un supervisor de este negocio puede cancelar una auditoria';
  end if;

  update auditorias
     set estado = 'cancelada', cerrada_por = auth.uid(), cerrada_en = now(),
         motivo_cancelacion = btrim(p_motivo)
   where id = a.id;

  return jsonb_build_object('numero', a.numero, 'estado', 'cancelada');
end $fn$;

revoke execute on function fn_cancelar_auditoria(uuid, text) from public, anon;
grant execute on function fn_cancelar_auditoria(uuid, text) to authenticated;


create or replace function fn_auditorias(
  p_sucursal_id uuid default null,
  p_limite      int  default 30
)
returns table (
  auditoria_id uuid,
  numero       text,
  estado       text,
  ubicacion    text,
  codigo       text,
  tipo         text,
  abierta_por  text,
  abierta_en   timestamptz,
  cerrada_en   timestamptz,
  escaneados   int,
  unidades     numeric
)
language sql stable security definer set search_path = public, app as $fn$
  select a.id, a.numero, a.estado, u.nombre, u.codigo, u.tipo,
         pe.nombre, a.abierta_en, a.cerrada_en,
         (select count(*)::int from auditoria_detalle d where d.auditoria_id = a.id),
         (select coalesce(sum(d.cantidad), 0) from auditoria_detalle d
           where d.auditoria_id = a.id)
  from auditorias a
  join ubicaciones u    on u.id = a.ubicacion_id
  left join perfiles pe on pe.id = a.abierta_por
  where app.tiene_nivel('auxiliar')
    and a.organizacion_id = app.org_id()
    and a.sucursal_id in (select app.sucursales_permitidas())
    and (p_sucursal_id is null or a.sucursal_id = p_sucursal_id)
  order by (a.estado = 'abierta') desc, a.abierta_en desc
  limit greatest(coalesce(p_limite, 30), 1)
$fn$;

revoke execute on function fn_auditorias(uuid, int) from public, anon;
grant execute on function fn_auditorias(uuid, int) to authenticated;


-- ---------------------------------------------------------------------------
-- 9. Como esta la bodega
--
--    Lo que contesta "¿puedo contar el piso?". Cada ubicacion de bodega con
--    cuando se audito por ultima vez y si todavia vale.
-- ---------------------------------------------------------------------------

create or replace function fn_estado_bodega(
  p_sucursal_id uuid default null,
  p_horas       int  default 24
) returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org uuid; v_suc uuid; v_h int; r jsonb;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para ver el inventario';
  end if;

  v_suc := coalesce(p_sucursal_id,
                    (select s.id from sucursales s
                      where s.organizacion_id = v_org and s.activa
                      order by s.es_principal desc limit 1));
  v_h := greatest(coalesce(p_horas, 24), 1);

  select jsonb_build_object(
    'horas', v_h,
    'ubicaciones', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ubicacion_id', x.id, 'nombre', x.nombre, 'codigo', x.codigo,
               'auditada_en', x.cerrada_en,
               'al_dia', x.cerrada_en is not null
                         and x.cerrada_en > now() - make_interval(hours => v_h))
               order by x.orden, x.nombre)
      from (
        select u.id, u.nombre, u.codigo, u.orden,
               (select max(a.cerrada_en) from auditorias a
                 where a.ubicacion_id = u.id and a.estado = 'aplicada') as cerrada_en
        from ubicaciones u
        where u.sucursal_id = v_suc and u.activa and u.tipo = 'bodega') x), '[]'::jsonb),
    'bodegas', (select count(*) from ubicaciones u
                 where u.sucursal_id = v_suc and u.activa and u.tipo = 'bodega'),
    'al_dia', not exists (
      select 1 from ubicaciones u
      where u.sucursal_id = v_suc and u.activa and u.tipo = 'bodega'
        and not exists (select 1 from auditorias a
                         where a.ubicacion_id = u.id and a.estado = 'aplicada'
                           and a.cerrada_en > now() - make_interval(hours => v_h)))
  ) into r;

  return r;
end $fn$;

revoke execute on function fn_estado_bodega(uuid, int) from public, anon;
grant execute on function fn_estado_bodega(uuid, int) to authenticated;


-- ---------------------------------------------------------------------------
-- 10. El conteo del piso
--
--     Se cuenta el piso COMPLETO, sumando lo que haya en cada punto de venta
--     -la gondola, la punta, la caja-, y se manda un solo numero. El sistema
--     lo compara contra el piso que el calcula, y la diferencia va a
--     aprobacion como cualquier conteo.
--
--     Exige la bodega auditada: el piso es el resto, y un resto calculado
--     sobre una bodega vieja no se puede contrastar con nada.
-- ---------------------------------------------------------------------------

create or replace function fn_solicitar_conteo_piso(
  p_producto_id uuid,
  p_cantidad    numeric,
  p_lote_id     uuid default null,
  p_motivo      text default null,
  p_sucursal_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org   uuid;
  v_suc   uuid;
  v_pred  record;
  v_sis   numeric := 0;
  v_est   jsonb;
  v_falta text;
  v_num   text;
  v_id    uuid;
  u       record;
begin
  if p_cantidad is null or p_cantidad < 0 then
    raise exception 'La cantidad contada no puede ser negativa';
  end if;

  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para contar';
  end if;

  v_suc := coalesce(p_sucursal_id,
                    (select s.id from sucursales s
                      where s.organizacion_id = v_org and s.activa
                      order by s.es_principal desc limit 1));

  if not app.es_admin() and v_suc not in (select app.sucursales_permitidas()) then
    raise exception 'No tiene acceso a esa sucursal';
  end if;

  perform 1 from productos
   where id = p_producto_id and organizacion_id = v_org
     and activo and tipo <> 'servicio';
  if not found then raise exception 'Ese producto no es de este negocio'; end if;

  if p_lote_id is not null then
    perform 1 from lotes
     where id = p_lote_id and producto_id = p_producto_id and sucursal_id = v_suc;
    if not found then raise exception 'Ese lote no corresponde al producto en esta sucursal'; end if;
  end if;

  -- La puerta: la bodega al dia.
  v_est := fn_estado_bodega(v_suc, 24);
  if not (v_est->>'al_dia')::boolean then
    select string_agg(x->>'nombre', ', ')
      into v_falta
    from jsonb_array_elements(v_est->'ubicaciones') x
    where not (x->>'al_dia')::boolean;
    raise exception 'Primero hay que auditar la bodega. Falta: %. El piso de ventas se calcula restando la bodega, asi que con la bodega vieja el conteo no sirve', coalesce(v_falta, 'la bodega');
  end if;

  -- El resto cae en la predeterminada, que por regla es del piso.
  select * into v_pred from ubicaciones
   where sucursal_id = v_suc and es_predeterminada;
  if v_pred.id is null then
    raise exception 'Esta sucursal no tiene ubicacion predeterminada';
  end if;

  if exists (select 1 from ajustes_inventario
              where producto_id = p_producto_id and ubicacion_id = v_pred.id
                and lote_id is not distinct from p_lote_id and estado = 'pendiente') then
    raise exception 'Ya hay un conteo de este producto esperando aprobacion';
  end if;

  -- Lo que el sistema dice que hay en TODO el piso.
  for u in select * from ubicaciones
            where sucursal_id = v_suc and activa and tipo = 'piso' loop
    v_sis := v_sis + coalesce(app.existencia_en_ubicacion(p_producto_id, u.id, p_lote_id), 0);
  end loop;

  if v_sis = p_cantidad then
    raise exception 'El sistema ya dice % en el piso de ventas. No hay nada que ajustar', v_sis;
  end if;

  v_num := app.numero_documento(v_org, v_suc, 'ajuste', 'AJ', 6);

  insert into ajustes_inventario (
    organizacion_id, sucursal_id, numero, producto_id, lote_id, ubicacion_id,
    cantidad_sistema, cantidad_contada, motivo, solicitado_por)
  values (v_org, v_suc, v_num, p_producto_id, p_lote_id, v_pred.id,
          v_sis, p_cantidad, nullif(btrim(coalesce(p_motivo,'')), ''), auth.uid())
  returning id into v_id;

  return jsonb_build_object(
    'ajuste_id', v_id, 'numero', v_num,
    'ubicacion', 'Piso de ventas',
    'producto', (select nombre from productos where id = p_producto_id),
    'sistema', v_sis, 'contado', p_cantidad,
    'diferencia', p_cantidad - v_sis,
    'puede_aprobar', app.es_admin() or app.tiene_nivel('gerente'));
end $fn$;

revoke execute on function fn_solicitar_conteo_piso(uuid, numeric, uuid, text, uuid)
  from public, anon;
grant execute on function fn_solicitar_conteo_piso(uuid, numeric, uuid, text, uuid)
  to authenticated;


-- ---------------------------------------------------------------------------
-- 11. Una sola puerta al conteo del piso
--
--     fn_solicitar_ajuste sigue sirviendo para corregir una ubicacion
--     concreta -una bodega-, pero ya no para el piso: el piso se cuenta
--     entero, de una vez, y con la bodega auditada. Dos caminos con reglas
--     distintas hacia el mismo numero es una regla que no existe: quien
--     quiera saltarse la auditoria solo tendria que usar el otro.
-- ---------------------------------------------------------------------------

create or replace function fn_solicitar_ajuste(
  p_producto_id  uuid,
  p_ubicacion_id uuid,
  p_cantidad     numeric,
  p_lote_id      uuid default null,
  p_motivo       text default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org  uuid;
  u      record;
  v_sis  numeric;
  v_num  text;
  v_id   uuid;
begin
  if p_cantidad is null or p_cantidad < 0 then
    raise exception 'La cantidad contada no puede ser negativa';
  end if;

  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para pedir ajustes de inventario';
  end if;

  select * into u from ubicaciones
   where id = p_ubicacion_id and (organizacion_id = v_org or app.es_admin());
  if u.id is null then raise exception 'Esa ubicacion no es de su negocio'; end if;
  if not u.activa then raise exception 'La ubicacion % esta inactiva', u.nombre; end if;

  if u.tipo = 'piso' then
    raise exception 'El piso de ventas se cuenta completo, no lugar por lugar. Use el conteo de piso desde Consultar';
  end if;

  if not app.es_admin()
     and u.sucursal_id not in (select app.sucursales_permitidas()) then
    raise exception 'No tiene acceso a esa sucursal';
  end if;

  perform 1 from productos
   where id = p_producto_id and organizacion_id = u.organizacion_id
     and activo and tipo <> 'servicio';
  if not found then raise exception 'Ese producto no es de este negocio'; end if;

  if p_lote_id is not null then
    perform 1 from lotes
     where id = p_lote_id and producto_id = p_producto_id
       and sucursal_id = u.sucursal_id;
    if not found then raise exception 'Ese lote no corresponde al producto en esta sucursal'; end if;
  end if;

  if exists (select 1 from ajustes_inventario
              where producto_id = p_producto_id and ubicacion_id = p_ubicacion_id
                and lote_id is not distinct from p_lote_id and estado = 'pendiente') then
    raise exception 'Ya hay un ajuste pendiente de aprobacion para % en %',
      (select nombre from productos where id = p_producto_id), u.nombre;
  end if;

  v_sis := app.existencia_en_ubicacion(p_producto_id, p_ubicacion_id, p_lote_id);

  if v_sis = p_cantidad then
    raise exception 'En % el sistema ya dice %. No hay nada que ajustar', u.nombre, v_sis;
  end if;

  v_num := app.numero_documento(u.organizacion_id, u.sucursal_id, 'ajuste', 'AJ', 6);

  insert into ajustes_inventario (
    organizacion_id, sucursal_id, numero, producto_id, lote_id, ubicacion_id,
    cantidad_sistema, cantidad_contada, motivo, solicitado_por)
  values (u.organizacion_id, u.sucursal_id, v_num, p_producto_id, p_lote_id, u.id,
          v_sis, p_cantidad, nullif(btrim(coalesce(p_motivo,'')), ''), auth.uid())
  returning id into v_id;

  return jsonb_build_object(
    'ajuste_id', v_id, 'numero', v_num,
    'ubicacion', u.nombre,
    'producto',  (select nombre from productos where id = p_producto_id),
    'sistema',   v_sis,
    'contado',   p_cantidad,
    'diferencia', p_cantidad - v_sis,
    'puede_aprobar', app.es_admin() or app.tiene_nivel('gerente'));
end $fn$;

revoke execute on function fn_solicitar_ajuste(uuid, uuid, numeric, uuid, text)
  from public, anon;
grant execute on function fn_solicitar_ajuste(uuid, uuid, numeric, uuid, text)
  to authenticated;
