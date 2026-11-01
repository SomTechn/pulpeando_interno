-- ============================================================================
--  046 · Registro por cuenta propia, prueba gratis y cobro del plan
--
--  Un negocio nuevo se registra solo desde registro.html (la función de borde
--  registrar-negocio crea el usuario y llama a fn_crear_negocio con la llave
--  service_role). Queda con N días de prueba. Pulpeando registra los pagos
--  desde admin.html y eso corre la fecha de pagado_hasta.
--
--  Reglas de la cuenta:
--   · vence = la más tardía entre prueba_hasta y pagado_hasta
--   · las dos en blanco = sin límite (los negocios de antes de 046 y cortesías)
--   · pasado el vencimiento hay unos días de gracia con aviso; después ya no se
--     abre turno de caja. Lo demás se puede consultar, para que el dueño vea
--     sus datos y pague.
--   · activa = false bloquea igual, sin gracia.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La cuenta en la organización
-- ---------------------------------------------------------------------------
alter table organizaciones add column if not exists prueba_hasta date;
alter table organizaciones add column if not exists pagado_hasta date;
alter table organizaciones add column if not exists telefono_contacto text;
alter table organizaciones add column if not exists origen text not null default 'manual';
alter table organizaciones add column if not exists notas_plataforma text;

-- El plan, las fechas y las notas internas solo los toca Pulpeando
create or replace function app.organizaciones_candado()
returns trigger language plpgsql set search_path = public, app as $fn$
begin
  if not app.es_admin() then
    if new.plan is distinct from old.plan or new.activa is distinct from old.activa
       or new.prueba_hasta is distinct from old.prueba_hasta
       or new.pagado_hasta is distinct from old.pagado_hasta
       or new.origen is distinct from old.origen
       or new.notas_plataforma is distinct from old.notas_plataforma then
      raise exception 'El plan y el estado de la cuenta los cambia Pulpeando';
    end if;
    if new.id <> old.id then
      raise exception 'No se puede cambiar el identificador del negocio';
    end if;
  end if;
  new.identificacion_fiscal := nullif(regexp_replace(coalesce(new.identificacion_fiscal, ''), '[^0-9]', '', 'g'), '');
  if new.identificacion_fiscal is not null and length(new.identificacion_fiscal) <> 14 then
    raise exception 'El RTN tiene 14 dígitos';
  end if;
  return new;
end $fn$;


-- ---------------------------------------------------------------------------
-- 2. Configuración de la plataforma (una sola fila) y pagos
-- ---------------------------------------------------------------------------
create table if not exists plataforma_config (
  id             boolean primary key default true check (id),
  datos          jsonb not null default '{}'::jsonb,
  actualizado_en timestamptz not null default now()
);
alter table plataforma_config enable row level security;
revoke all on plataforma_config from public, anon, authenticated;

insert into plataforma_config (id, datos) values (true, jsonb_build_object(
  'registro_abierto', true,
  'dias_prueba', 14,
  'dias_gracia', 3,
  'planes', jsonb_build_array(
    jsonb_build_object('id', 'basico',  'nombre', 'Básico',  'precio', 450,
                       'detalle', 'Una sucursal, cajas y usuarios sin límite'),
    jsonb_build_object('id', 'negocio', 'nombre', 'Negocio', 'precio', 850,
                       'detalle', 'Varias sucursales, bodega y reportes completos')),
  'pago_instrucciones', 'Deposite o transfiera el monto del plan y mande el comprobante por WhatsApp. Le activamos el mes el mismo día.',
  'whatsapp', ''
)) on conflict (id) do nothing;

create or replace function app.config_plataforma()
returns jsonb stable language sql security definer set search_path = public, app as $$
  select coalesce((select datos from plataforma_config where id), '{}'::jsonb)
$$;

create table if not exists pagos_suscripcion (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  plan             text not null,
  meses            int  not null check (meses between 1 and 24),
  monto            numeric(12,2) not null check (monto >= 0),
  metodo           text,
  referencia       text,
  desde            date not null,
  hasta            date not null,
  registrado_por   uuid references perfiles(id),
  creado_en        timestamptz not null default now()
);
create index if not exists pagos_suscripcion_org on pagos_suscripcion (organizacion_id, creado_en desc);
alter table pagos_suscripcion enable row level security;
revoke all on pagos_suscripcion from public, anon, authenticated;

-- Intentos de registro, para no dejar que un robot cree mil negocios
create table if not exists registro_intentos (
  id        bigserial primary key,
  ip        text not null,
  correo    text,
  creado_en timestamptz not null default now()
);
create index if not exists registro_intentos_ip on registro_intentos (ip, creado_en desc);
alter table registro_intentos enable row level security;
revoke all on registro_intentos from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- 3. El estado de la cuenta
-- ---------------------------------------------------------------------------
create or replace function app.estado_cuenta(p_org uuid)
returns jsonb stable language plpgsql security definer set search_path = public, app as $fn$
declare
  o       record;
  v_vence date;
  v_gracia int := coalesce((app.config_plataforma() ->> 'dias_gracia')::int, 3);
  v_dias  int;
begin
  select plan, activa, prueba_hasta, pagado_hasta into o from organizaciones where id = p_org;
  if not found then return null; end if;
  v_vence := greatest(o.prueba_hasta, o.pagado_hasta);   -- greatest ignora los null
  v_dias  := v_vence - current_date;
  return jsonb_build_object(
    'plan', o.plan,
    'activa', o.activa,
    'prueba_hasta', o.prueba_hasta,
    'pagado_hasta', o.pagado_hasta,
    'vence', v_vence,
    'sin_limite', v_vence is null,
    'en_prueba', o.prueba_hasta is not null and o.prueba_hasta >= current_date
                 and (o.pagado_hasta is null or o.pagado_hasta < current_date),
    'dias_restantes', v_dias,
    'dias_gracia', v_gracia,
    'en_gracia', v_dias is not null and v_dias < 0 and v_dias >= -v_gracia,
    'vencida', not o.activa or (v_dias is not null and v_dias < -v_gracia)
  );
end $fn$;

create or replace function app.cuenta_bloqueada(p_org uuid)
returns boolean stable language sql security definer set search_path = public, app as $$
  select coalesce((app.estado_cuenta(p_org) ->> 'vencida')::boolean, false)
$$;

-- Con la cuenta vencida no se abre turno (ni desde la caja ni desde el panel)
create or replace function app.turnos_cuenta_al_dia()
returns trigger language plpgsql security definer set search_path = public, app as $fn$
begin
  if app.cuenta_bloqueada(new.organizacion_id) then
    raise exception 'La cuenta de este negocio está vencida. El gerente puede pagar el plan en Configuración → Plan y pago';
  end if;
  return new;
end $fn$;

create or replace trigger tg_turnos_cuenta_al_dia
  before insert on turnos_caja
  for each row execute function app.turnos_cuenta_al_dia();

revoke execute on function app.config_plataforma() from public, anon;
revoke execute on function app.estado_cuenta(uuid) from public, anon;
revoke execute on function app.cuenta_bloqueada(uuid) from public, anon;
grant execute on function app.config_plataforma() to authenticated, service_role;
grant execute on function app.estado_cuenta(uuid) to authenticated, service_role;
grant execute on function app.cuenta_bloqueada(uuid) to authenticated, service_role;


-- ---------------------------------------------------------------------------
-- 4. El alta del negocio (solo la llama la función de borde, con service_role)
-- ---------------------------------------------------------------------------

-- ¿Puede esta IP registrar otro negocio? Anota el intento de una vez.
create or replace function fn_registro_intento(p_ip text, p_correo text default null)
returns boolean language plpgsql security definer set search_path = public, app as $fn$
declare n int;
begin
  delete from registro_intentos where creado_en < now() - interval '2 days';
  select count(*) into n from registro_intentos
   where ip = coalesce(p_ip, '?') and creado_en > now() - interval '1 hour';
  insert into registro_intentos (ip, correo) values (coalesce(p_ip, '?'), lower(p_correo));
  return n < 5;
end $fn$;

-- Lo que la página de registro puede saber antes de tener cuenta
create or replace function fn_registro_info()
returns jsonb stable language sql security definer set search_path = public, app as $$
  select jsonb_build_object(
    'registro_abierto', coalesce((c ->> 'registro_abierto')::boolean, true),
    'dias_prueba', coalesce((c ->> 'dias_prueba')::int, 14),
    'planes', coalesce(c -> 'planes', '[]'::jsonb),
    'whatsapp', coalesce(c ->> 'whatsapp', ''))
  from (select app.config_plataforma() c) x
$$;

create or replace function fn_crear_negocio(p_usuario uuid, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path = public, app, extensions as $fn$
declare
  cfg      jsonb := app.config_plataforma();
  v_neg    text := btrim(coalesce(p_datos ->> 'negocio', ''));
  v_nom    text := btrim(coalesce(p_datos ->> 'nombre', ''));
  v_tel    text := nullif(btrim(coalesce(p_datos ->> 'telefono', '')), '');
  v_suc_n  text := coalesce(nullif(btrim(coalesce(p_datos ->> 'sucursal', '')), ''), 'Sucursal principal');
  v_dir    text := nullif(btrim(coalesce(p_datos ->> 'direccion', '')), '');
  v_pin    text := coalesce(p_datos ->> 'pin', '');
  v_email  text;
  v_dias   int  := coalesce((cfg ->> 'dias_prueba')::int, 14);
  v_org    uuid;
  v_suc    uuid;
begin
  if not coalesce((cfg ->> 'registro_abierto')::boolean, true) then
    raise exception 'El registro de negocios nuevos está cerrado por el momento';
  end if;
  if length(v_neg) < 3 or length(v_neg) > 80 then raise exception 'El nombre del negocio va de 3 a 80 letras'; end if;
  if length(v_nom) < 3 or length(v_nom) > 80 then raise exception 'Su nombre va de 3 a 80 letras'; end if;
  if v_pin !~ '^[0-9]{5}$' then raise exception 'El PIN de caja tiene 5 dígitos'; end if;
  if v_pin ~ '^(.)\1{4}$' or v_pin in ('12345', '54321', '01234', '98765') then
    raise exception 'Ese PIN es muy fácil de adivinar. Escoja otro';
  end if;

  select email into v_email from auth.users where id = p_usuario;
  if not found then raise exception 'El usuario no existe'; end if;
  if exists (select 1 from perfiles where id = p_usuario) then
    raise exception 'Ese usuario ya pertenece a un negocio';
  end if;

  insert into organizaciones (nombre, pais, moneda, facturacion_fiscal_activa, dias_alerta_vencimiento,
                              plan, prueba_hasta, telefono_contacto, origen)
  values (v_neg, 'HN', 'HNL', false, 30, 'prueba', current_date + v_dias, v_tel, 'registro')
  returning id into v_org;

  insert into sucursales (organizacion_id, codigo, nombre, direccion, telefono, es_principal)
  values (v_org, 'S01', v_suc_n, v_dir, v_tel, true)
  returning id into v_suc;

  insert into perfiles (id, organizacion_id, nombre, email, telefono, rol, activo,
                        pin_pos, pin_intentos_fallidos, pin_actualizado_en)
  values (p_usuario, v_org, v_nom, v_email, v_tel, 'gerente', true,
          crypt(v_pin, gen_salt('bf')), 0, now());

  insert into impuestos (organizacion_id, nombre, tasa, incluido_en_precio, es_predeterminado, activo)
  values (v_org, 'ISV 15%', 0.15, true, true, true),
         (v_org, 'Exento', 0, true, false, true);

  insert into cajas (organizacion_id, sucursal_id, codigo, nombre)
  values (v_org, v_suc, 'C1', 'Caja 1');

  insert into categorias (organizacion_id, nombre, orden) values
    (v_org, 'Básicos', 1), (v_org, 'Bebidas', 2), (v_org, 'Lácteos', 3),
    (v_org, 'Aseo', 4), (v_org, 'Snacks', 5), (v_org, 'Granos básicos', 6);

  return jsonb_build_object(
    'organizacion_id', v_org,
    'codigo_tienda', (select codigo_tienda from organizaciones where id = v_org),
    'prueba_hasta', current_date + v_dias);
end $fn$;

revoke execute on function fn_registro_intento(text, text) from public, anon, authenticated;
revoke execute on function fn_registro_info() from public, anon, authenticated;
revoke execute on function fn_crear_negocio(uuid, jsonb) from public, anon, authenticated;
grant execute on function fn_registro_intento(text, text) to service_role;
grant execute on function fn_registro_info() to service_role;
grant execute on function fn_crear_negocio(uuid, jsonb) to service_role;


-- ---------------------------------------------------------------------------
-- 5. El contexto del POS ahora trae la cuenta
-- ---------------------------------------------------------------------------
create or replace function fn_pos_contexto() returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
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
      'factura_fiscal', v_org.facturacion_fiscal_activa,
      'color', case when coalesce(v_org.config ->> 'color_marca', '') ~ '^#[0-9A-Fa-f]{6}$'
                    then v_org.config ->> 'color_marca' end,
      'logo_path', v_org.config ->> 'logo_path',
      'caja_autoriza', app.caja_autoriza(coalesce(v_org.config, '{}'::jsonb)),
      'cuenta', app.estado_cuenta(v_org.id)
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
end $fn$;


-- ---------------------------------------------------------------------------
-- 6. El gerente: su plan, sus pagos y los primeros pasos
-- ---------------------------------------------------------------------------
create or replace function fn_mi_cuenta()
returns jsonb stable language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  cfg   jsonb := app.config_plataforma();
begin
  if v_org is null or not app.tiene_nivel('gerente') then
    raise exception 'Solo el gerente ve el plan del negocio';
  end if;
  return jsonb_build_object(
    'cuenta', app.estado_cuenta(v_org),
    'codigo_tienda', (select codigo_tienda from organizaciones where id = v_org),
    'planes', coalesce(cfg -> 'planes', '[]'::jsonb),
    'pago_instrucciones', coalesce(cfg ->> 'pago_instrucciones', ''),
    'whatsapp', coalesce(cfg ->> 'whatsapp', ''),
    'pagos', coalesce((
      select jsonb_agg(jsonb_build_object('fecha', p.creado_en, 'plan', p.plan, 'meses', p.meses,
               'monto', p.monto, 'metodo', p.metodo, 'referencia', p.referencia,
               'desde', p.desde, 'hasta', p.hasta) order by p.creado_en desc)
      from pagos_suscripcion p where p.organizacion_id = v_org), '[]'::jsonb));
end $fn$;

create or replace function fn_primeros_pasos()
returns jsonb stable language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  o     record;
begin
  if v_org is null or not app.tiene_nivel('gerente') then return null; end if;
  select * into o from organizaciones where id = v_org;
  return jsonb_build_object(
    'oculto', coalesce((o.config ->> 'primeros_pasos_ocultos')::boolean, false),
    'cuenta', app.estado_cuenta(v_org),
    'muestra', (select count(*) from productos p where p.organizacion_id = v_org and p.activo
                  and exists (select 1 from producto_codigos c where c.producto_id = p.id and c.codigo like '2110000______')),
    'pasos', jsonb_build_array(
      jsonb_build_object('id', 'productos', 'hecho',
        exists (select 1 from productos where organizacion_id = v_org and activo)),
      jsonb_build_object('id', 'negocio', 'hecho',
        o.identificacion_fiscal is not null or coalesce(o.config ->> 'logo_path', '') <> ''),
      jsonb_build_object('id', 'usuarios', 'hecho',
        (select count(*) from perfiles where organizacion_id = v_org and activo) > 1),
      jsonb_build_object('id', 'venta', 'hecho',
        exists (select 1 from ventas where organizacion_id = v_org)),
      jsonb_build_object('id', 'compra', 'hecho',
        exists (select 1 from facturas_compra where organizacion_id = v_org))));
end $fn$;

create or replace function fn_ocultar_primeros_pasos(p_oculto boolean default true)
returns void language plpgsql security definer set search_path = public, app as $fn$
declare v_org uuid := app.org_id();
begin
  if v_org is null or not app.tiene_nivel('gerente') then
    raise exception 'Solo el gerente';
  end if;
  update organizaciones
     set config = coalesce(config, '{}'::jsonb) || jsonb_build_object('primeros_pasos_ocultos', coalesce(p_oculto, true))
   where id = v_org;
end $fn$;

revoke execute on function fn_mi_cuenta() from public, anon;
revoke execute on function fn_primeros_pasos() from public, anon;
revoke execute on function fn_ocultar_primeros_pasos(boolean) from public, anon;
grant execute on function fn_mi_cuenta() to authenticated;
grant execute on function fn_primeros_pasos() to authenticated;
grant execute on function fn_ocultar_primeros_pasos(boolean) to authenticated;


-- ---------------------------------------------------------------------------
-- 7. Pulpeando (rol admin): todos los negocios, pagos y configuración
-- ---------------------------------------------------------------------------
create or replace function fn_admin_negocios()
returns jsonb stable language plpgsql security definer set search_path = public, app as $fn$
begin
  if not app.es_admin() then raise exception 'Solo Pulpeando'; end if;
  return coalesce((
    select jsonb_agg(x order by x ->> 'creada_en' desc)
    from (
      select jsonb_build_object(
        'id', o.id, 'nombre', o.nombre, 'codigo_tienda', o.codigo_tienda,
        'creada_en', o.creada_en, 'origen', o.origen, 'telefono', o.telefono_contacto,
        'notas', o.notas_plataforma,
        'cuenta', app.estado_cuenta(o.id),
        'dueno', (select jsonb_build_object('nombre', p.nombre, 'email', p.email, 'telefono', p.telefono)
                    from perfiles p where p.organizacion_id = o.id and p.rol in ('gerente', 'admin')
                   order by p.creado_en limit 1),
        'usuarios', (select count(*) from perfiles p where p.organizacion_id = o.id and p.activo),
        'productos', (select count(*) from productos p where p.organizacion_id = o.id and p.activo),
        'ventas_30d', (select count(*) from ventas v where v.organizacion_id = o.id
                         and v.creada_en > now() - interval '30 days'),
        'ultima_venta', (select max(v.creada_en) from ventas v where v.organizacion_id = o.id),
        'pagado_total', (select coalesce(sum(monto), 0) from pagos_suscripcion s where s.organizacion_id = o.id)
      ) x
      from organizaciones o
    ) t), '[]'::jsonb);
end $fn$;

create or replace function fn_admin_registrar_pago(
  p_org uuid, p_meses int, p_monto numeric, p_plan text default null,
  p_metodo text default null, p_referencia text default null
) returns jsonb language plpgsql security definer set search_path = public, app as $fn$
declare
  o       record;
  v_desde date;
  v_hasta date;
  v_plan  text;
begin
  if not app.es_admin() then raise exception 'Solo Pulpeando'; end if;
  if p_meses is null or p_meses < 1 or p_meses > 24 then raise exception 'De 1 a 24 meses'; end if;
  if p_monto is null or p_monto < 0 then raise exception 'Monto inválido'; end if;
  select * into o from organizaciones where id = p_org for update;
  if not found then raise exception 'Negocio inexistente'; end if;
  v_plan := coalesce(nullif(btrim(p_plan), ''), nullif(o.plan, 'prueba'), 'basico');
  -- El mes pagado arranca cuando se acaba lo que ya tenía (prueba o pago), o hoy
  v_desde := greatest(current_date, o.prueba_hasta + 1, o.pagado_hasta + 1);
  v_hasta := (v_desde + make_interval(months => p_meses))::date - 1;

  insert into pagos_suscripcion (organizacion_id, plan, meses, monto, metodo, referencia, desde, hasta, registrado_por)
  values (p_org, v_plan, p_meses, p_monto, nullif(btrim(p_metodo), ''), nullif(btrim(p_referencia), ''),
          v_desde, v_hasta, auth.uid());
  update organizaciones set pagado_hasta = v_hasta, plan = v_plan, activa = true where id = p_org;
  return app.estado_cuenta(p_org);
end $fn$;

create or replace function fn_admin_actualizar_cuenta(p_org uuid, p_cambios jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $fn$
begin
  if not app.es_admin() then raise exception 'Solo Pulpeando'; end if;
  if not exists (select 1 from organizaciones where id = p_org) then raise exception 'Negocio inexistente'; end if;
  update organizaciones set
    plan             = case when p_cambios ? 'plan' then coalesce(nullif(p_cambios ->> 'plan', ''), plan) else plan end,
    activa           = case when p_cambios ? 'activa' then coalesce((p_cambios ->> 'activa')::boolean, activa) else activa end,
    prueba_hasta     = case when p_cambios ? 'prueba_hasta' then nullif(p_cambios ->> 'prueba_hasta', '')::date else prueba_hasta end,
    pagado_hasta     = case when p_cambios ? 'pagado_hasta' then nullif(p_cambios ->> 'pagado_hasta', '')::date else pagado_hasta end,
    notas_plataforma = case when p_cambios ? 'notas' then nullif(p_cambios ->> 'notas', '') else notas_plataforma end
  where id = p_org;
  return app.estado_cuenta(p_org);
end $fn$;

create or replace function fn_admin_config()
returns jsonb stable language plpgsql security definer set search_path = public, app as $fn$
begin
  if not app.es_admin() then raise exception 'Solo Pulpeando'; end if;
  return app.config_plataforma();
end $fn$;

create or replace function fn_admin_guardar_config(p_datos jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $fn$
declare
  v jsonb := app.config_plataforma();
  p jsonb;
begin
  if not app.es_admin() then raise exception 'Solo Pulpeando'; end if;
  if jsonb_typeof(p_datos) <> 'object' then raise exception 'Se esperaba un objeto'; end if;
  if p_datos ? 'dias_prueba' and coalesce((p_datos ->> 'dias_prueba')::int, -1) not between 0 and 90 then
    raise exception 'La prueba va de 0 a 90 días';
  end if;
  if p_datos ? 'dias_gracia' and coalesce((p_datos ->> 'dias_gracia')::int, -1) not between 0 and 30 then
    raise exception 'La gracia va de 0 a 30 días';
  end if;
  if p_datos ? 'planes' then
    if jsonb_typeof(p_datos -> 'planes') <> 'array' or jsonb_array_length(p_datos -> 'planes') = 0 then
      raise exception 'Hace falta al menos un plan';
    end if;
    for p in select * from jsonb_array_elements(p_datos -> 'planes') loop
      if coalesce(p ->> 'id', '') !~ '^[a-z0-9_]{2,20}$' or coalesce(p ->> 'nombre', '') = ''
         or coalesce((p ->> 'precio')::numeric, -1) < 0 then
        raise exception 'Cada plan lleva id (minúsculas), nombre y precio';
      end if;
    end loop;
  end if;
  v := v || (p_datos - array(select k from jsonb_object_keys(p_datos) k
                              where k not in ('registro_abierto', 'dias_prueba', 'dias_gracia', 'planes',
                                              'pago_instrucciones', 'whatsapp')));
  update plataforma_config set datos = v, actualizado_en = now() where id;
  return v;
end $fn$;

revoke execute on function fn_admin_negocios() from public, anon;
revoke execute on function fn_admin_registrar_pago(uuid, int, numeric, text, text, text) from public, anon;
revoke execute on function fn_admin_actualizar_cuenta(uuid, jsonb) from public, anon;
revoke execute on function fn_admin_config() from public, anon;
revoke execute on function fn_admin_guardar_config(jsonb) from public, anon;
grant execute on function fn_admin_negocios() to authenticated;
grant execute on function fn_admin_registrar_pago(uuid, int, numeric, text, text, text) to authenticated;
grant execute on function fn_admin_actualizar_cuenta(uuid, jsonb) to authenticated;
grant execute on function fn_admin_config() to authenticated;
grant execute on function fn_admin_guardar_config(jsonb) to authenticated;


-- ---------------------------------------------------------------------------
-- 8. Catálogo de muestra (los mismos 100 productos de sql/demo_catalogo.sql)
--    Para que el negocio recién registrado pruebe la caja de una vez. Va por
--    fn_importar_productos, así que solo el gerente lo carga y no duplica.
-- ---------------------------------------------------------------------------
create or replace function fn_cargar_catalogo_muestra()
returns jsonb language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  v_res jsonb;
  v_filas jsonb;
  v_cats jsonb;
  v_provs jsonb;
begin
  if v_org is null or not app.tiene_nivel('gerente') then
    raise exception 'Solo el gerente carga el catálogo de muestra';
  end if;
  -- Filas cortas: [nombre, #categoría, #proveedor, precio, costo, existencia,
  -- mínimo, impuesto, código, marca, empaque, unidad (UND si falta)]
  v_cats := '["Aseo", "Bebidas", "Básicos", "Cuidado personal", "Dulces y galletas", "Embutidos y huevos", "Enlatados y salsas", "Granos básicos", "Lácteos", "Panadería", "Snacks"]'::jsonb;
  v_provs := '["Abarrotera Central Sula", "Avícola y Embutidos El Rancho", "Bebidas y Refrescos del Norte", "Distribuidora Granos del Valle", "Higiene y Hogar Distribuciones", "Lácteos La Campiña", "Panificadora San Pedro", "Snacks y Golosinas Choloma"]'::jsonb;
  select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'nombre', f ->> 0, 'categoria', v_cats ->> (f ->> 1)::int, 'proveedor', v_provs ->> (f ->> 2)::int,
           'precio', f ->> 3, 'costo', f ->> 4, 'existencia', f ->> 5, 'minimo', f ->> 6,
           'impuesto', f ->> 7, 'codigo', f ->> 8, 'marca', nullif(f ->> 9, ''), 'empaque', f ->> 10,
           'unidad', coalesce(f ->> 11, 'UND'))) order by n)
    into v_filas
    from jsonb_array_elements($demo$[
["Arroz blanco 1 lb",7,3,"14","11.2","60","15","0","2110000000073","","25"],
["Arroz blanco 5 lb",7,3,"68","54.4","24","6","0","2110000000141","","10"],
["Frijol rojo 1 lb",7,3,"22","17.6","50","12","0","2110000000219","","25"],
["Frijol negro 1 lb",7,3,"24","19.2","30","7","0","2110000000288","","25"],
["Maíz blanco 1 lb",7,3,"8","6.4","40","10","0","2110000000356","","25"],
["Harina de maíz Maseca 1 kg",7,3,"32","25.6","30","7","0","2110000000424","Maseca","10"],
["Harina de trigo 1 lb",7,3,"14","11.2","30","7","0","2110000000493","","25"],
["Lentejas 1 lb",7,3,"30","24.0","15","3","0","2110000000561","","25"],
["Avena en hojuelas Quaker 400 g",7,3,"38","26.43","18","4","15","2110000000639","Quaker","12"],
["Azúcar blanca 1 lb",2,0,"13","10.4","60","15","0","2110000000707","","25"],
["Azúcar blanca 5 lb",2,0,"62","49.6","20","5","0","2110000000776","","10"],
["Sal yodada 1 lb",2,0,"6","4.8","40","10","0","2110000000844","","25"],
["Aceite vegetal 750 ml",2,0,"58","46.4","24","6","0","2110000000912","","12"],
["Aceite vegetal 1.5 L",2,0,"105","84.0","12","3","0","2110000000981","","12"],
["Manteca vegetal 1 lb",2,0,"30","24.0","24","6","0","2110000001056","","24"],
["Café molido Maya 200 g",2,0,"48","38.4","24","6","0","2110000001124","Café Maya","24"],
["Café instantáneo Nescafé Clásico 50 g",2,0,"62","43.13","18","4","15","2110000001193","Nescafé","24"],
["Spaghetti 200 g",2,0,"12","8.35","40","10","15","2110000001261","","20"],
["Coditos 200 g",2,0,"12","8.35","30","7","15","2110000001339","","20"],
["Sopa instantánea Maruchan pollo 64 g",2,0,"18","12.52","48","12","15","2110000001407","Maruchan","24"],
["Consomé de pollo Maggi 8 cubos",2,0,"15","10.43","36","9","15","2110000001476","Maggi","24"],
["Sopa de pollo con fideos Knorr 60 g",2,0,"16","11.13","30","7","15","2110000001544","Knorr","24"],
["Corn Flakes Kellogg's 300 g",2,0,"72","50.09","10","2","15","2110000001612","Kellogg's","12"],
["Vinagre blanco 500 ml",2,0,"18","12.52","12","3","15","2110000001681","","12"],
["Frijoles rojos molidos Ducal 400 g",6,0,"26","18.09","36","9","15","2110000001759","Ducal","24"],
["Frijoles negros enteros Ducal 400 g",6,0,"26","18.09","24","6","15","2110000001827","Ducal","24"],
["Salsa de tomate Naturas 400 g",6,0,"38","26.43","24","6","15","2110000001896","Naturas","24"],
["Mayonesa Naturas 400 g",6,0,"52","36.17","18","4","15","2110000001964","Naturas","24"],
["Pasta de tomate 106 g",6,0,"12","8.35","36","9","15","2110000002039","","48"],
["Sardinas en salsa de tomate 155 g",6,0,"28","19.48","30","7","15","2110000002107","","48"],
["Atún en agua 140 g",6,0,"36","25.04","30","7","15","2110000002176","","48"],
["Maíz dulce Del Monte 240 g",6,0,"32","22.26","12","3","15","2110000002244","Del Monte","24"],
["Mostaza 200 g",6,0,"28","19.48","12","3","15","2110000002312","","24"],
["Chile jalapeño en rajas 200 g",6,0,"25","17.39","12","3","15","2110000002381","","24"],
["Salsa inglesa 150 ml",6,0,"30","20.87","10","2","15","2110000002459","","24"],
["Coca-Cola 3 L",1,2,"68","47.3","24","6","15","2110000002527","Coca-Cola","6"],
["Coca-Cola 1.5 L",1,2,"40","27.83","24","6","15","2110000002596","Coca-Cola","8"],
["Coca-Cola 600 ml",1,2,"25","17.39","48","12","15","2110000002664","Coca-Cola","24"],
["Coca-Cola lata 355 ml",1,2,"22","15.3","24","6","15","2110000002732","Coca-Cola","24"],
["Sprite 3 L",1,2,"62","43.13","12","3","15","2110000002800","Sprite","6"],
["Fanta naranja 3 L",1,2,"62","43.13","12","3","15","2110000002879","Fanta","6"],
["Pepsi 3 L",1,2,"60","41.74","12","3","15","2110000002947","Pepsi","6"],
["Tropical uva 3 L",1,2,"55","38.26","12","3","15","2110000003012","Tropical","6"],
["Tropical naranja 600 ml",1,2,"18","12.52","24","6","15","2110000003081","Tropical","24"],
["Agua Azul 600 ml",1,2,"12","8.35","48","12","15","2110000003159","Agua Azul","24"],
["Agua Azul galón 3.78 L",1,2,"38","26.43","12","3","15","2110000003227","Agua Azul","4"],
["Jugo de naranja Del Valle 1 L",1,2,"42","29.22","12","3","15","2110000003296","Del Valle","12"],
["Jugo de manzana 250 ml",1,2,"14","9.74","24","6","15","2110000003364","","24"],
["Té frío Lipton limón 500 ml",1,2,"22","15.3","12","3","15","2110000003432","Lipton","12"],
["Gatorade naranja 600 ml",1,2,"32","22.26","24","6","15","2110000003500","Gatorade","24"],
["Monster Energy 473 ml",1,2,"55","38.26","12","3","15","2110000003579","Monster","24"],
["Leche entera Sula 1 L",8,5,"34","29.24","36","9","0","2110000003647","Sula","12"],
["Leche semidescremada Sula 1 L",8,5,"35","30.1","12","3","0","2110000003715","Sula","12"],
["Leche entera Dos Pinos 1 L",8,5,"36","30.96","12","3","0","2110000003784","Dos Pinos","12"],
["Leche en polvo Nido 360 g",8,5,"165","141.9","8","2","0","2110000003852","Nido","12"],
["Mantequilla crema Sula 400 ml",8,5,"48","41.28","12","3","0","2110000003920","Sula","12"],
["Quesillo 1 lb",8,5,"75","64.5","10","2","0","2110000003999","",null,"LB"],
["Queso seco 1 lb",8,5,"70","60.2","8","2","0","2110000004064","",null,"LB"],
["Yogur de fresa Sula 1 L",8,5,"58","43.37","8","2","15","2110000004132","Sula","12"],
["Leche con chocolate 200 ml",8,5,"14","10.47","24","6","15","2110000004200","","24"],
["Margarina 450 g",8,5,"38","28.42","12","3","15","2110000004279","","24"],
["Huevos cartón de 30",5,1,"165","141.9","10","2","0","2110000004347","","12"],
["Huevos 15 unidades",5,1,"85","73.1","10","2","0","2110000004415","","12"],
["Mortadela Delicia 1 lb",5,1,"55","41.13","10","2","15","2110000004484","Delicia",null],
["Salchichas Delicia 1 lb",5,1,"62","46.37","10","2","15","2110000004552","Delicia",null],
["Jamón de pavo 1 lb",5,1,"85","63.57","6","2","15","2110000004620","",null],
["Chorizo 1 lb",5,1,"70","52.35","6","2","15","2110000004699","",null],
["Pan blanco de molde Bimbo grande",9,6,"58","49.88","10","2","0","2110000004767","Bimbo",null],
["Pan integral de molde Bimbo",9,6,"64","55.04","6","2","0","2110000004835","Bimbo",null],
["Pan para hot dog Bimbo 8 u",9,6,"40","34.4","6","2","0","2110000004903","Bimbo",null],
["Semita de yema",9,6,"12","10.32","20","5","0","2110000004972","",null],
["Tortillas de maíz 10 u",9,6,"15","12.9","20","5","0","2110000005047","",null],
["Zambos chile limón 30 g",10,7,"12","8.35","36","9","15","2110000005115","Zambos","24"],
["Ranchitas nacho 45 g",10,7,"14","9.74","24","6","15","2110000005184","Yummies","24"],
["Taqueritos 40 g",10,7,"12","8.35","24","6","15","2110000005252","Yummies","24"],
["Doritos nacho 45 g",10,7,"20","13.91","24","6","15","2110000005320","Doritos","24"],
["Lay's clásicas 42 g",10,7,"20","13.91","24","6","15","2110000005399","Lay's","24"],
["Tortrix limón 40 g",10,7,"12","8.35","24","6","15","2110000005467","Tortrix","24"],
["Platanitos con sal 60 g",10,7,"15","10.43","24","6","15","2110000005535","","24"],
["Maní salado 60 g",10,7,"12","8.35","24","6","15","2110000005603","","24"],
["Galletas María Gamesa 200 g",4,7,"22","15.3","24","6","15","2110000005672","Gamesa","24"],
["Galletas Oreo 108 g",4,7,"28","19.48","18","4","15","2110000005740","Oreo","12"],
["Galletas Chiky 6 u",4,7,"25","17.39","18","4","15","2110000005818","Pozuelo","12"],
["Galletas Club Social 6 u",4,7,"30","20.87","12","3","15","2110000005887","Club Social","12"],
["Chocolate Snickers 52 g",4,7,"28","19.48","24","6","15","2110000005955","Snickers","24"],
["Chicles Trident menta 5 u",4,7,"12","8.35","24","6","15","2110000006020","Trident","24"],
["Caramelos surtidos bolsa 100 u",4,7,"45","31.3","6","2","15","2110000006099","","12"],
["Detergente en polvo Xtra 1 kg",0,4,"55","38.26","12","3","15","2110000006167","Xtra","12"],
["Detergente en polvo Ariel 1 kg",0,4,"85","59.13","8","2","15","2110000006235","Ariel","12"],
["Cloro Clorox 1 L",0,4,"28","19.48","12","3","15","2110000006303","Clorox","12"],
["Lavaplatos en crema Axion 425 g",0,4,"35","24.35","12","3","15","2110000006372","Axion","24"],
["Suavizante Suavitel 850 ml",0,4,"48","33.39","8","2","15","2110000006440","Suavitel","12"],
["Papel higiénico Scott 4 rollos",0,4,"52","36.17","12","3","15","2110000006518","Scott","12"],
["Papel higiénico Scott 12 rollos",0,4,"145","100.87","6","2","15","2110000006587","Scott","4"],
["Pasta dental Colgate 100 ml",3,4,"42","29.22","12","3","15","2110000006655","Colgate","24"],
["Jabón de baño Protex 110 g",3,4,"28","19.48","18","4","15","2110000006723","Protex","24"],
["Champú Sedal 340 ml",3,4,"85","59.13","6","2","15","2110000006792","Sedal","12"],
["Toallas sanitarias Kotex 10 u",3,4,"48","33.39","8","2","15","2110000006860","Kotex","24"],
["Desodorante Rexona 50 ml",3,4,"55","38.26","8","2","15","2110000006938","Rexona","12"],
["Pañales Huggies etapa 3, 20 u",3,4,"230","160.0","6","2","15","2110000007003","Huggies","6"]
]$demo$::jsonb) with ordinality as t(f, n);
  v_res := fn_importar_productos(v_filas, null, true);
  update proveedores set dias_credito = 8, dias_entrega = 2, dia_visita = array[1, 4]::int[], contacto = 'Marvin Castillo', notas = 'Proveedor de muestra' where organizacion_id = v_org and nombre = 'Distribuidora Granos del Valle';
  update proveedores set dias_credito = 15, dias_entrega = 3, dia_visita = array[2]::int[], contacto = 'Lesly Fajardo', notas = 'Proveedor de muestra' where organizacion_id = v_org and nombre = 'Abarrotera Central Sula';
  update proveedores set dias_credito = 7, dias_entrega = 1, dia_visita = array[1, 3, 5]::int[], contacto = 'Óscar Mejía', notas = 'Proveedor de muestra' where organizacion_id = v_org and nombre = 'Bebidas y Refrescos del Norte';
  update proveedores set dias_credito = 0, dias_entrega = 1, dia_visita = array[1, 2, 3, 4, 5, 6]::int[], contacto = 'Karla Rivera', notas = 'Proveedor de muestra' where organizacion_id = v_org and nombre = 'Lácteos La Campiña';
  update proveedores set dias_credito = 7, dias_entrega = 1, dia_visita = array[2, 5]::int[], contacto = 'José Ramírez', notas = 'Proveedor de muestra' where organizacion_id = v_org and nombre = 'Avícola y Embutidos El Rancho';
  update proveedores set dias_credito = 0, dias_entrega = 1, dia_visita = array[1, 2, 3, 4, 5, 6]::int[], contacto = 'Doña Marta Zelaya', notas = 'Proveedor de muestra' where organizacion_id = v_org and nombre = 'Panificadora San Pedro';
  update proveedores set dias_credito = 15, dias_entrega = 3, dia_visita = array[3]::int[], contacto = 'Ricardo Paz', notas = 'Proveedor de muestra' where organizacion_id = v_org and nombre = 'Snacks y Golosinas Choloma';
  update proveedores set dias_credito = 30, dias_entrega = 4, dia_visita = array[4]::int[], contacto = 'Andrea Banegas', notas = 'Proveedor de muestra' where organizacion_id = v_org and nombre = 'Higiene y Hogar Distribuciones';
  return v_res;
end $fn$;

-- Quitar la muestra cuando ya va a meter sus productos de verdad: se apagan
-- (no se borran, porque pueden tener ventas o kardex) los productos que solo
-- tienen códigos del rango interno de la muestra y los proveedores de muestra.
create or replace function fn_quitar_catalogo_muestra()
returns jsonb language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  n_prod int; n_prov int;
begin
  if v_org is null or not app.tiene_nivel('gerente') then
    raise exception 'Solo el gerente quita el catálogo de muestra';
  end if;
  update productos p set activo = false
   where p.organizacion_id = v_org and p.activo
     and exists (select 1 from producto_codigos c where c.producto_id = p.id and c.codigo like '2110000______')
     and not exists (select 1 from producto_codigos c where c.producto_id = p.id and c.codigo not like '2110000______');
  get diagnostics n_prod = row_count;
  update proveedores set activo = false
   where organizacion_id = v_org and activo and notas = 'Proveedor de muestra';
  get diagnostics n_prov = row_count;
  return jsonb_build_object('productos', n_prod, 'proveedores', n_prov);
end $fn$;

revoke execute on function fn_cargar_catalogo_muestra() from public, anon;
revoke execute on function fn_quitar_catalogo_muestra() from public, anon;
grant execute on function fn_cargar_catalogo_muestra() to authenticated;
grant execute on function fn_quitar_catalogo_muestra() to authenticated;
