-- ============================================================================
--  052 · Central de riesgo de fiado (Central Pulpeando)
--
--  La idea: el que debe en tres pulperías y no le paga a ninguna llega a la
--  cuarta como cliente nuevo. Con esto, la cuarta lo sabe antes de fiarle.
--
--  Cómo se cuida a la persona:
--    · El DNI NO se guarda. Se guarda una huella (HMAC-SHA256 con una llave
--      que solo conoce la base) y los últimos 4 dígitos, para que la cajera
--      confirme que es el mismo papel. Con la huella se cruza entre negocios
--      sin que el número quede legible en ningún lado.
--    · Solo entra quien aceptó en la caja: la cajera lo marca y queda quién y
--      cuándo. Sin ese permiso, ni se guarda ni se consulta.
--    · Una pulpería ve SOLO una señal (verde, amarillo, rojo) y en cuántos
--      otros negocios debe y si va atrasado. Ni montos ni nombres de negocios.
--    · La persona ve su propio reporte completo en la app del cliente y puede
--      reclamar; los reclamos los atiende la plataforma.
--    · Cada verificación queda anotada (quién, cuándo) y cada negocio tiene un
--      tope diario, para que nadie se ponga a consultar DNIs ajenos.
-- ============================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- 1. La llave de la huella. Nadie la lee: ni la app, ni el gerente.
-- ---------------------------------------------------------------------------
create table if not exists app.riesgo_llave (
  id    int primary key default 1 check (id = 1),
  llave text not null
);
insert into app.riesgo_llave (llave)
select encode(gen_random_bytes(32), 'hex')
 where not exists (select 1 from app.riesgo_llave);
revoke all on app.riesgo_llave from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Las personas (solo la huella) y el enlace con cada ficha de cliente
-- ---------------------------------------------------------------------------
create table if not exists riesgo_personas (
  id        uuid primary key default gen_random_uuid(),
  huella    text not null unique,
  creada_en timestamptz not null default now()
);
alter table riesgo_personas enable row level security;
revoke all on riesgo_personas from public, anon, authenticated;

alter table clientes add column if not exists riesgo_persona_id     uuid references riesgo_personas(id);
alter table clientes add column if not exists dni_final             text;
alter table clientes add column if not exists riesgo_consentido_en  timestamptz;
alter table clientes add column if not exists riesgo_consentido_por uuid references perfiles(id);
-- Una persona, una ficha por negocio: si ya está con otro nombre, se avisa.
create unique index if not exists ux_clientes_persona_org
  on clientes (organizacion_id, riesgo_persona_id) where riesgo_persona_id is not null;
create index if not exists ix_clientes_persona on clientes (riesgo_persona_id)
  where riesgo_persona_id is not null;

-- Lo que hizo cada negocio con la central: para ver abusos y para el tope.
create table if not exists riesgo_bitacora (
  id              bigint generated always as identity primary key,
  organizacion_id uuid not null references organizaciones(id) on delete cascade,
  cliente_id      uuid references clientes(id) on delete set null,
  persona_id      uuid references riesgo_personas(id) on delete set null,
  accion          text not null check (accion in ('verificar','consultar','quitar')),
  por             uuid,
  creada_en       timestamptz not null default now()
);
create index if not exists ix_riesgo_bitacora_org on riesgo_bitacora (organizacion_id, creada_en desc);
alter table riesgo_bitacora enable row level security;
revoke all on riesgo_bitacora from public, anon, authenticated;

create table if not exists riesgo_reclamos (
  id           uuid primary key default gen_random_uuid(),
  persona_id   uuid not null references riesgo_personas(id) on delete cascade,
  usuario_id   uuid,
  texto        text not null check (char_length(btrim(texto)) between 10 and 1000),
  estado       text not null default 'abierto' check (estado in ('abierto','resuelto','rechazado')),
  respuesta    text,
  creado_en    timestamptz not null default now(),
  resuelto_en  timestamptz,
  resuelto_por uuid
);
alter table riesgo_reclamos enable row level security;
revoke all on riesgo_reclamos from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. El DNI hondureño: 13 dígitos. Departamento 01–18, año de nacimiento.
-- ---------------------------------------------------------------------------
create or replace function app.dni_normal(p_dni text)
returns text
language plpgsql immutable set search_path = public, app as $fn$
declare
  v text := regexp_replace(coalesce(p_dni, ''), '[^0-9]', '', 'g');
  v_dep int; v_anio int;
begin
  if length(v) <> 13 then
    raise exception 'El DNI tiene 13 números (por ejemplo 0801-1990-12345)';
  end if;
  v_dep := substr(v, 1, 2)::int;
  v_anio := substr(v, 5, 4)::int;
  if v_dep < 1 or v_dep > 18 or v_anio < 1900 or v_anio > extract(year from now())::int then
    raise exception 'Ese DNI no parece válido. Revise los números';
  end if;
  return v;
end $fn$;

create or replace function app.dni_huella(p_dni text)
returns text
language sql stable security definer set search_path = public, app, extensions as $fn$
  select encode(hmac(app.dni_normal(p_dni), (select llave from app.riesgo_llave), 'sha256'), 'hex')
$fn$;
revoke execute on function app.dni_huella(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. La señal: lo que la persona debe en OTROS negocios (que tengan su permiso)
--      rojo      atrasado en alguno, o debe en 3 o más
--      amarillo  debe en 1 o 2, al día
--      verde     no debe en ningún otro
-- ---------------------------------------------------------------------------
create or replace function app.riesgo_resumen(p_persona uuid, p_excluir_org uuid)
returns jsonb
language sql stable security definer set search_path = public, app as $fn$
  with otros as (
    select c.organizacion_id,
           coalesce(f.debe, 0) as debe,
           coalesce(f.debe, 0) > 0 and (coalesce(f.atrasado, false) or coalesce(f.dias, 0) > 45) as atrasado
      from clientes c
      left join v_fiado f on f.cliente_id = c.id
     where c.riesgo_persona_id = p_persona
       and c.riesgo_consentido_en is not null
       and (p_excluir_org is null or c.organizacion_id <> p_excluir_org)
  ), r as (
    select count(distinct organizacion_id)                                  as negocios,
           count(distinct organizacion_id) filter (where debe > 0)          as con_deuda,
           coalesce(bool_or(atrasado), false)                               as atrasado
      from otros
  )
  select jsonb_build_object(
    'negocios', r.negocios, 'con_deuda', r.con_deuda, 'atrasado', r.atrasado,
    'senal', case when r.atrasado or r.con_deuda >= 3 then 'rojo'
                  when r.con_deuda >= 1 then 'amarillo' else 'verde' end,
    'texto', case
      when r.atrasado then 'Va atrasado en ' || case when r.con_deuda = 1 then 'otro negocio' else r.con_deuda || ' negocios' end
      when r.con_deuda >= 1 then 'Debe en ' || case when r.con_deuda = 1 then 'otro negocio' else r.con_deuda || ' negocios' end || ', al día'
      when r.negocios >= 1 then 'Al día en ' || case when r.negocios = 1 then 'el otro negocio' else 'los ' || r.negocios || ' negocios' end || ' donde compra'
      else 'Sin historial en otros negocios' end)
  from r
$fn$;
revoke execute on function app.riesgo_resumen(uuid, uuid) from public, anon, authenticated;

-- La ficha de un cliente de MI negocio, con o sin central.
create or replace function app.riesgo_de_cliente(p_cliente_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare c record;
begin
  select * into c from clientes where id = p_cliente_id;
  if c.riesgo_persona_id is null or c.riesgo_consentido_en is null then
    return jsonb_build_object('verificado', false);
  end if;
  return jsonb_build_object('verificado', true, 'dni_final', c.dni_final,
           'desde', c.riesgo_consentido_en)
         || app.riesgo_resumen(c.riesgo_persona_id, c.organizacion_id);
end $fn$;
revoke execute on function app.riesgo_de_cliente(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Verificar a un cliente con su DNI (cajera en adelante, con permiso)
-- ---------------------------------------------------------------------------
create or replace function fn_riesgo_verificar(p_cliente_id uuid, p_dni text, p_acepto boolean)
returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  c record; v_huella text; v_persona uuid; v_otro text; v_hoy int;
begin
  if v_org is null or not app.tiene_nivel('auxiliar') then raise exception 'Sin permiso'; end if;
  select * into c from clientes where id = p_cliente_id and organizacion_id = v_org;
  if c.id is null then raise exception 'Ese cliente no es de su negocio'; end if;
  if not coalesce(p_acepto, false) then
    raise exception 'Primero el cliente tiene que aceptar que su fiado se consulte en la Central';
  end if;

  select count(*) into v_hoy from riesgo_bitacora
   where organizacion_id = v_org and accion = 'verificar' and creada_en > now() - interval '1 day';
  if v_hoy >= 40 then
    raise exception 'Llegó al tope de verificaciones de hoy. Siga mañana';
  end if;

  v_huella := app.dni_huella(p_dni);
  insert into riesgo_personas (huella) values (v_huella)
    on conflict (huella) do nothing;
  select id into v_persona from riesgo_personas where huella = v_huella;

  select nombre into v_otro from clientes
   where organizacion_id = v_org and riesgo_persona_id = v_persona and id <> c.id limit 1;
  if v_otro is not null then
    raise exception 'Ese DNI ya está con el cliente %', v_otro;
  end if;

  update clientes set riesgo_persona_id = v_persona,
                      dni_final = right(app.dni_normal(p_dni), 4),
                      riesgo_consentido_en = now(),
                      riesgo_consentido_por = auth.uid()
   where id = c.id;
  insert into riesgo_bitacora (organizacion_id, cliente_id, persona_id, accion, por)
  values (v_org, c.id, v_persona, 'verificar', auth.uid());

  return app.riesgo_de_cliente(c.id);
end $fn$;
revoke execute on function fn_riesgo_verificar(uuid, text, boolean) from public, anon;
grant execute on function fn_riesgo_verificar(uuid, text, boolean) to authenticated;

-- La señal de un cliente ya verificado.
create or replace function fn_riesgo_cliente(p_cliente_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare v_org uuid := app.org_id(); c record;
begin
  if v_org is null or not app.tiene_nivel('auxiliar') then raise exception 'Sin permiso'; end if;
  select * into c from clientes where id = p_cliente_id and organizacion_id = v_org;
  if c.id is null then raise exception 'Ese cliente no es de su negocio'; end if;
  if c.riesgo_persona_id is not null then
    insert into riesgo_bitacora (organizacion_id, cliente_id, persona_id, accion, por)
    values (v_org, c.id, c.riesgo_persona_id, 'consultar', auth.uid());
  end if;
  return app.riesgo_de_cliente(c.id);
end $fn$;
revoke execute on function fn_riesgo_cliente(uuid) from public, anon;
grant execute on function fn_riesgo_cliente(uuid) to authenticated;

-- Quitar a un cliente de la central (lo pide él, o se equivocaron de DNI).
create or replace function fn_riesgo_quitar(p_cliente_id uuid)
returns void
language plpgsql security definer set search_path = public, app as $fn$
declare v_org uuid := app.org_id(); c record;
begin
  if v_org is null or not app.tiene_nivel('supervisor') then
    raise exception 'Solo un supervisor puede quitar a un cliente de la Central';
  end if;
  select * into c from clientes where id = p_cliente_id and organizacion_id = v_org;
  if c.id is null then raise exception 'Ese cliente no es de su negocio'; end if;
  insert into riesgo_bitacora (organizacion_id, cliente_id, persona_id, accion, por)
  values (v_org, c.id, c.riesgo_persona_id, 'quitar', auth.uid());
  update clientes set riesgo_persona_id = null, dni_final = null,
                      riesgo_consentido_en = null, riesgo_consentido_por = null
   where id = c.id;
end $fn$;
revoke execute on function fn_riesgo_quitar(uuid) from public, anon;
grant execute on function fn_riesgo_quitar(uuid) to authenticated;

-- Las señales de varios clientes a la vez (la lista de Fiado). Sin bitácora:
-- es la misma información que ya se ve uno por uno.
create or replace function fn_riesgo_clientes()
returns table (cliente_id uuid, senal text, texto text)
language sql stable security definer set search_path = public, app as $fn$
  select c.id, r->>'senal', r->>'texto'
    from clientes c
    cross join lateral app.riesgo_resumen(c.riesgo_persona_id, c.organizacion_id) r
   where c.organizacion_id = app.org_id() and app.tiene_nivel('auxiliar')
     and c.riesgo_persona_id is not null and c.riesgo_consentido_en is not null
$fn$;
revoke execute on function fn_riesgo_clientes() from public, anon;
grant execute on function fn_riesgo_clientes() to authenticated;

-- ---------------------------------------------------------------------------
-- 6. La persona: su reporte completo y su reclamo (app del cliente)
-- ---------------------------------------------------------------------------
create or replace function fn_mi_central()
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare v_persona uuid;
begin
  if auth.uid() is null then raise exception 'Inicie sesión'; end if;
  select riesgo_persona_id into v_persona from clientes
   where usuario_id = auth.uid() and riesgo_persona_id is not null
     and riesgo_consentido_en is not null
   order by riesgo_consentido_en desc limit 1;
  if v_persona is null then return jsonb_build_object('verificado', false); end if;

  -- La señal es la misma que ven las pulperías, pero el texto le habla a él
  -- (contando todas, no «otros negocios»).
  return jsonb_build_object('verificado', true)
    || (select r || jsonb_build_object('texto', case
          when (r->>'atrasado')::boolean then 'Va atrasado en ' || case when (r->>'con_deuda')::int = 1 then 'una pulpería' else (r->>'con_deuda') || ' pulperías' end
          when (r->>'con_deuda')::int >= 1 then 'Debe en ' || case when (r->>'con_deuda')::int = 1 then 'una pulpería' else (r->>'con_deuda') || ' pulperías' end || ', al día'
          else 'Al día en todas las pulperías' end)
          from app.riesgo_resumen(v_persona, null) r)
    || jsonb_build_object(
      'negocios_detalle', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'negocio', o.nombre, 'debe', coalesce(f.debe, 0),
                 'atrasado', coalesce(f.debe, 0) > 0 and (coalesce(f.atrasado, false) or coalesce(f.dias, 0) > 45),
                 'desde', c.riesgo_consentido_en) order by o.nombre)
          from clientes c
          join organizaciones o on o.id = c.organizacion_id
          left join v_fiado f on f.cliente_id = c.id
         where c.riesgo_persona_id = v_persona and c.riesgo_consentido_en is not null), '[]'::jsonb),
      'reclamos', coalesce((
        select jsonb_agg(jsonb_build_object('texto', r.texto, 'estado', r.estado,
                 'respuesta', r.respuesta, 'creado_en', r.creado_en) order by r.creado_en desc)
          from riesgo_reclamos r where r.persona_id = v_persona), '[]'::jsonb));
end $fn$;
revoke execute on function fn_mi_central() from public, anon;
grant execute on function fn_mi_central() to authenticated;

create or replace function fn_reclamar_central(p_texto text)
returns void
language plpgsql security definer set search_path = public, app as $fn$
declare v_persona uuid;
begin
  if auth.uid() is null then raise exception 'Inicie sesión'; end if;
  select riesgo_persona_id into v_persona from clientes
   where usuario_id = auth.uid() and riesgo_persona_id is not null
   order by riesgo_consentido_en desc nulls last limit 1;
  if v_persona is null then raise exception 'Usted no está en la Central'; end if;
  if char_length(btrim(coalesce(p_texto, ''))) < 10 then
    raise exception 'Cuente qué está mal (al menos 10 letras)';
  end if;
  if (select count(*) from riesgo_reclamos where persona_id = v_persona and estado = 'abierto') >= 3 then
    raise exception 'Ya tiene reclamos abiertos. Espere la respuesta';
  end if;
  insert into riesgo_reclamos (persona_id, usuario_id, texto) values (v_persona, auth.uid(), btrim(p_texto));
end $fn$;
revoke execute on function fn_reclamar_central(text) from public, anon;
grant execute on function fn_reclamar_central(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. La plataforma atiende los reclamos (admin.html)
-- ---------------------------------------------------------------------------
create or replace function fn_admin_reclamos_central()
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
begin
  if not app.es_admin() then raise exception 'Solo la plataforma'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'texto', r.texto, 'estado', r.estado, 'respuesta', r.respuesta,
             'creado_en', r.creado_en, 'resuelto_en', r.resuelto_en,
             'negocios', (select jsonb_agg(jsonb_build_object('negocio', o.nombre,
                             'cliente', c.nombre, 'telefono', c.telefono,
                             'debe', coalesce(c.saldo, 0)))
                            from clientes c join organizaciones o on o.id = c.organizacion_id
                           where c.riesgo_persona_id = r.persona_id))
           order by (r.estado = 'abierto') desc, r.creado_en desc)
      from riesgo_reclamos r), '[]'::jsonb);
end $fn$;
revoke execute on function fn_admin_reclamos_central() from public, anon;
grant execute on function fn_admin_reclamos_central() to authenticated;

create or replace function fn_admin_resolver_reclamo(p_id uuid, p_estado text, p_respuesta text)
returns void
language plpgsql security definer set search_path = public, app as $fn$
begin
  if not app.es_admin() then raise exception 'Solo la plataforma'; end if;
  if p_estado not in ('resuelto', 'rechazado') then raise exception 'Estado no válido'; end if;
  if p_respuesta is null or btrim(p_respuesta) = '' then raise exception 'Escriba la respuesta para la persona'; end if;
  update riesgo_reclamos set estado = p_estado, respuesta = btrim(p_respuesta),
                             resuelto_en = now(), resuelto_por = auth.uid()
   where id = p_id;
  if not found then raise exception 'No existe ese reclamo'; end if;
end $fn$;
revoke execute on function fn_admin_resolver_reclamo(uuid, text, text) from public, anon;
grant execute on function fn_admin_resolver_reclamo(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
