-- ============================================================================
--  022 · Merma: por daño y desconocida
--
--  Un negocio pierde mercaderia de dos maneras muy distintas, y confundirlas
--  es lo que impide arreglar cualquiera de las dos:
--
--  MERMA POR DAÑO (conocida). Alguien sabe que paso y lo dice: se vencio, se
--  quebro, se corto la cadena de frio, llego golpeado. Tiene causa, tiene
--  responsable y tiene arreglo -comprar menos, rotar mejor, revisar el
--  refrigerador-. Se registra en el momento, con el producto en la mano.
--
--  MERMA DESCONOCIDA. Falta y nadie sabe por que. No se registra: SALE DE LA
--  RESTA. Es lo que el conteo encuentra de menos y nadie pudo explicar. Por
--  eso la unica forma de medirla es contando, y por eso un negocio que no
--  cuenta no sabe cuanto se le pierde.
--
--  COMO SE MIDEN POR SEPARADO
--
--    merma por daño      = las mermas aprobadas con una causa de daño
--    merma desconocida   = las diferencias negativas de conteo que se
--                          aplicaron, mas las mermas que alguien marco
--                          "no se sabe"
--    sobrante            = las diferencias positivas de conteo
--    merma desconocida neta = desconocida - sobrante
--
--  La ultima linea es la que importa: un sobrante casi nunca es mercaderia
--  que aparecio, es un error de conteo o un producto que se vendio como otro.
--  Restarlo evita inflar el robo con errores de digitacion.
--
--  QUIEN HACE QUE
--
--      auxiliar     registra la merma con el producto en la mano
--      gerente      la aprueba, y hasta entonces no sale del inventario
--
--  Que la apruebe otro no es burocracia: "se me cayo" es la tapadera mas
--  barata que existe. El que la registra y el que la autoriza no pueden ser
--  la misma persona si se quiere que el numero signifique algo.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. El catalogo de causas
--
--    Cada negocio pone las suyas. La CLASE -daño o desconocida- es lo que
--    decide en que balde cae, y por eso no la elige quien registra: la trae
--    la causa.
-- ---------------------------------------------------------------------------

create table if not exists causas_merma (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references organizaciones(id) on delete cascade,
  nombre          text not null,
  clase           text not null check (clase in ('dano','desconocida')),
  activa          boolean not null default true,
  orden           int not null default 100,
  creado_en       timestamptz not null default now()
);

create unique index if not exists ux_causas_merma
  on causas_merma (organizacion_id, lower(btrim(nombre)));

alter table causas_merma enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies
                  where tablename='causas_merma' and policyname='causas_merma_sel') then
    create policy causas_merma_sel on causas_merma for select
      using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))
             or app.es_admin());
  end if;
end $$;

revoke insert, update, delete on causas_merma from authenticated;
grant select on causas_merma to authenticated;


-- Las causas de arranque. Cubren lo que de verdad se pierde en una pulperia;
-- el negocio agrega las suyas despues.
create or replace function app.sembrar_causas_merma(p_org uuid)
returns void
language plpgsql security definer set search_path = public, app as $fn$
begin
  insert into causas_merma (organizacion_id, nombre, clase, orden)
  values
    (p_org, 'Vencimiento',                'dano', 10),
    (p_org, 'Daño en manipulación',       'dano', 20),
    (p_org, 'Mala calidad o mal estado',  'dano', 30),
    (p_org, 'Cadena de frío o temperatura','dano', 40),
    (p_org, 'Quiebra o derrame',          'dano', 50),
    (p_org, 'Plaga o contaminación',      'dano', 60),
    (p_org, 'Empaque dañado',             'dano', 70),
    (p_org, 'No se sabe, desapareció',    'desconocida', 900)
  on conflict do nothing;
end $fn$;

create or replace function app.tg_organizacion_causas()
returns trigger
language plpgsql security definer set search_path = public, app as $fn$
begin
  perform app.sembrar_causas_merma(new.id);
  return new;
end $fn$;

do $$ begin
  if not exists (select 1 from pg_trigger
                  where tgname = 'tg_organizacion_causas'
                    and tgrelid = 'organizaciones'::regclass) then
    create trigger tg_organizacion_causas
      after insert on organizaciones
      for each row execute function app.tg_organizacion_causas();
  end if;
end $$;

do $$
declare o record;
begin
  for o in select id from organizaciones loop
    perform app.sembrar_causas_merma(o.id);
  end loop;
end $$;


-- ---------------------------------------------------------------------------
-- 2. Las mermas
-- ---------------------------------------------------------------------------

create table if not exists mermas (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  sucursal_id      uuid not null references sucursales(id),
  numero           text not null,
  producto_id      uuid not null references productos(id),
  lote_id          uuid references lotes(id),
  ubicacion_id     uuid references ubicaciones(id),
  causa_id         uuid not null references causas_merma(id),

  -- La clase se copia al registrar. Si manana alguien cambia la causa de
  -- balde en el catalogo, el historial no se puede mover: lo que se midio
  -- el mes pasado se midio asi.
  clase            text not null check (clase in ('dano','desconocida')),

  cantidad         numeric(16,3) not null check (cantidad > 0),
  -- El costo del momento, para que el valor del periodo no cambie cuando
  -- cambie el costo promedio.
  costo_unitario   numeric(14,4),

  estado           text not null default 'pendiente'
                   check (estado in ('pendiente','aprobado','rechazado')),
  notas            text,

  solicitado_por   uuid references perfiles(id),
  solicitado_en    timestamptz not null default now(),
  resuelto_por     uuid references perfiles(id),
  resuelto_en      timestamptz,
  nota_resolucion  text,
  valor_aplicado   numeric(16,4),

  unique (organizacion_id, numero)
);

create index if not exists ix_mermas_sucursal
  on mermas (sucursal_id, estado, solicitado_en desc);
create index if not exists ix_mermas_producto on mermas (producto_id);

alter table mermas enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies
                  where tablename='mermas' and policyname='mermas_sel') then
    create policy mermas_sel on mermas for select
      using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))
             or app.es_admin());
  end if;
end $$;

revoke insert, update, delete on mermas from authenticated;
grant select on mermas to authenticated;


-- ---------------------------------------------------------------------------
-- 3. Mantener el catalogo
-- ---------------------------------------------------------------------------

create or replace function fn_causas_merma(p_solo_activas boolean default true)
returns table (
  causa_id uuid,
  nombre   text,
  clase    text,
  activa   boolean,
  orden    int
)
language sql stable security definer set search_path = public, app as $fn$
  select c.id, c.nombre, c.clase, c.activa, c.orden
  from causas_merma c
  where app.tiene_nivel('auxiliar')
    and (c.organizacion_id = app.org_id() or app.es_admin())
    and (not p_solo_activas or c.activa)
  order by c.clase, c.orden, c.nombre
$fn$;

revoke execute on function fn_causas_merma(boolean) from public, anon;
grant execute on function fn_causas_merma(boolean) to authenticated;


create or replace function fn_guardar_causa_merma(
  p_nombre text,
  p_clase  text default 'dano',
  p_id     uuid default null,
  p_activa boolean default true,
  p_orden  int default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid;
  v_id  uuid;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('gerente'))) then
    raise exception 'Solo el gerente puede cambiar las causas de merma';
  end if;
  if p_nombre is null or btrim(p_nombre) = '' then
    raise exception 'La causa necesita un nombre';
  end if;
  if p_clase not in ('dano','desconocida') then
    raise exception 'La causa tiene que ser de daño o desconocida';
  end if;

  if p_id is not null then
    select id into v_id from causas_merma
     where id = p_id and organizacion_id = v_org;
    if v_id is null then raise exception 'Esa causa no es de su negocio'; end if;

    -- La clase no se cambia: las mermas ya registradas se contaron con la
    -- clase que tenian, y moverla aqui haria que el reporte del mes pasado
    -- diga otra cosa manana.
    update causas_merma
       set nombre = btrim(p_nombre),
           activa = coalesce(p_activa, activa),
           orden  = coalesce(p_orden, orden)
     where id = v_id;
  else
    insert into causas_merma (organizacion_id, nombre, clase, activa, orden)
    values (v_org, btrim(p_nombre), p_clase, coalesce(p_activa, true),
            coalesce(p_orden, 100))
    returning id into v_id;
  end if;

  return jsonb_build_object('causa_id', v_id, 'nombre', btrim(p_nombre));
end $fn$;

revoke execute on function fn_guardar_causa_merma(text, text, uuid, boolean, int)
  from public, anon;
grant execute on function fn_guardar_causa_merma(text, text, uuid, boolean, int)
  to authenticated;


-- ---------------------------------------------------------------------------
-- 4. Registrar una merma
-- ---------------------------------------------------------------------------

create or replace function fn_registrar_merma(
  p_producto_id  uuid,
  p_cantidad     numeric,
  p_causa_id     uuid,
  p_ubicacion_id uuid default null,
  p_lote_id      uuid default null,
  p_notas        text default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org   uuid;
  v_suc   uuid;
  c       record;
  u       record;
  v_hay   numeric;
  v_costo numeric;
  v_num   text;
  v_id    uuid;
begin
  if p_cantidad is null or p_cantidad <= 0 then
    raise exception 'La cantidad de la merma tiene que ser mayor a cero';
  end if;

  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para registrar mermas';
  end if;

  select * into c from causas_merma
   where id = p_causa_id and (organizacion_id = v_org or app.es_admin());
  if c.id is null then raise exception 'Esa causa no es de su negocio'; end if;
  if not c.activa then raise exception 'La causa "%" ya no se usa', c.nombre; end if;

  if p_ubicacion_id is not null then
    select * into u from ubicaciones
     where id = p_ubicacion_id and (organizacion_id = v_org or app.es_admin());
    if u.id is null then raise exception 'Esa ubicacion no es de su negocio'; end if;
    v_suc := u.sucursal_id;
  else
    v_suc := (select s.id from sucursales s
               where s.organizacion_id = v_org and s.activa
               order by s.es_principal desc limit 1);
    select * into u from ubicaciones
     where sucursal_id = v_suc and es_predeterminada;
  end if;

  if not app.es_admin()
     and v_suc not in (select app.sucursales_permitidas()) then
    raise exception 'No tiene acceso a esa sucursal';
  end if;

  perform 1 from productos
   where id = p_producto_id and organizacion_id = c.organizacion_id
     and activo and tipo <> 'servicio';
  if not found then raise exception 'Ese producto no es de este negocio'; end if;

  if p_lote_id is not null then
    perform 1 from lotes
     where id = p_lote_id and producto_id = p_producto_id and sucursal_id = v_suc;
    if not found then raise exception 'Ese lote no corresponde al producto en esta sucursal'; end if;
  end if;

  -- Avisar aqui y no al aprobar: quien registra tiene el producto en la mano
  -- y puede corregir el numero; el gerente que aprueba tres horas despues, no.
  if u.id is not null then
    v_hay := app.existencia_en_ubicacion(p_producto_id, u.id, p_lote_id);
    if v_hay < p_cantidad then
      raise exception 'En % el sistema solo tiene %. Revise el lugar o el lote',
        u.nombre, v_hay;
    end if;
  end if;

  select coalesce(costo_promedio, 0) into v_costo
  from producto_costos
  where producto_id = p_producto_id and sucursal_id = v_suc;

  v_num := app.numero_documento(c.organizacion_id, v_suc, 'merma', 'ME', 6);

  insert into mermas (organizacion_id, sucursal_id, numero, producto_id, lote_id,
                      ubicacion_id, causa_id, clase, cantidad, costo_unitario,
                      notas, solicitado_por)
  values (c.organizacion_id, v_suc, v_num, p_producto_id, p_lote_id,
          u.id, c.id, c.clase, p_cantidad, coalesce(v_costo, 0),
          nullif(btrim(coalesce(p_notas,'')), ''), auth.uid())
  returning id into v_id;

  return jsonb_build_object(
    'merma_id', v_id, 'numero', v_num,
    'producto', (select nombre from productos where id = p_producto_id),
    'causa', c.nombre, 'clase', c.clase,
    'ubicacion', u.nombre,
    'cantidad', p_cantidad,
    'valor', case when app.tiene_nivel('supervisor')
                  then round(p_cantidad * coalesce(v_costo, 0), 2) end,
    'puede_aprobar', app.es_admin() or app.tiene_nivel('gerente'));
end $fn$;

revoke execute on function fn_registrar_merma(uuid, numeric, uuid, uuid, uuid, text)
  from public, anon;
grant execute on function fn_registrar_merma(uuid, numeric, uuid, uuid, uuid, text)
  to authenticated;


-- ---------------------------------------------------------------------------
-- 5. Aprobar o rechazar
-- ---------------------------------------------------------------------------

create or replace function fn_resolver_merma(
  p_merma_id uuid,
  p_aprobar  boolean,
  p_nota     text default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  m       record;
  u       record;
  v_costo numeric;
begin
  select * into m from mermas where id = p_merma_id for update;
  if m.id is null then raise exception 'Esa merma no existe'; end if;
  if m.estado <> 'pendiente' then
    raise exception 'Esa merma ya se habia %', m.estado;
  end if;

  if not (app.es_admin()
          or (m.organizacion_id = app.org_id() and app.tiene_nivel('gerente'))) then
    raise exception 'Solo el gerente de este negocio puede aprobar una merma';
  end if;

  if not p_aprobar then
    if p_nota is null or btrim(p_nota) = '' then
      raise exception 'Rechazar una merma exige decir por que';
    end if;
    update mermas
       set estado = 'rechazado', resuelto_por = auth.uid(), resuelto_en = now(),
           nota_resolucion = btrim(p_nota)
     where id = m.id;
    return jsonb_build_object('numero', m.numero, 'estado', 'rechazado');
  end if;

  select * into u from ubicaciones where id = m.ubicacion_id;

  -- Igual que en el conteo: primero el desglose, despues el kardex. Al bajar
  -- el total el disparador recorta las ubicaciones por su cuenta, y restar
  -- despues dejaria el lugar con menos de lo que de verdad salio.
  if u.id is not null and not u.es_predeterminada then
    update existencias_ubicacion
       set cantidad = greatest(cantidad - m.cantidad, 0), actualizado_en = now()
     where producto_id = m.producto_id and sucursal_id = m.sucursal_id
       and ubicacion_id = u.id and lote_id is not distinct from m.lote_id;
  end if;

  begin
    perform fn_kardex_registrar(
      m.sucursal_id, m.producto_id, 'merma', m.cantidad, null, m.lote_id,
      'merma', m.id,
      'Merma ' || m.numero || ' · ' || (select nombre from causas_merma where id = m.causa_id),
      auth.uid());
  exception when others then
    if sqlerrm like '%insuficiente%' then
      raise exception 'Ya no hay suficiente % para dar de baja: se vendio o se ajusto despues de registrarla. Vuelva a registrarla con la cantidad que haya',
        (select nombre from productos where id = m.producto_id);
    else
      raise;
    end if;
  end;

  -- El valor se congela al costo que tenia cuando se registro.
  v_costo := coalesce(m.costo_unitario, 0);

  update mermas
     set estado = 'aprobado', resuelto_por = auth.uid(), resuelto_en = now(),
         nota_resolucion = nullif(btrim(coalesce(p_nota,'')), ''),
         valor_aplicado = round(m.cantidad * v_costo, 4)
   where id = m.id;

  return jsonb_build_object(
    'numero', m.numero, 'estado', 'aprobado',
    'producto', (select nombre from productos where id = m.producto_id),
    'cantidad', m.cantidad,
    'existencia_total', (select coalesce(sum(e.cantidad), 0) from existencias e
                          where e.producto_id = m.producto_id
                            and e.sucursal_id = m.sucursal_id),
    'valor', case when app.tiene_nivel('supervisor')
                  then round(m.cantidad * v_costo, 2) end);
end $fn$;

revoke execute on function fn_resolver_merma(uuid, boolean, text) from public, anon;
grant execute on function fn_resolver_merma(uuid, boolean, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 6. La lista
-- ---------------------------------------------------------------------------

create or replace function fn_mermas(
  p_estado      text default 'pendiente',
  p_desde       date default null,
  p_hasta       date default null,
  p_sucursal_id uuid default null,
  p_producto_id uuid default null,
  p_limite      int  default 100
)
returns table (
  merma_id       uuid,
  numero         text,
  estado         text,
  clase          text,
  causa          text,
  producto_id    uuid,
  producto       text,
  sku            text,
  unidad         text,
  lote           text,
  vence          date,
  ubicacion      text,
  sucursal       text,
  cantidad       numeric,
  valor          numeric,
  notas          text,
  solicitado_por text,
  solicitado_en  timestamptz,
  resuelto_por   text,
  resuelto_en    timestamptz,
  nota           text
)
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_tz text;
begin
  if not app.tiene_nivel('auxiliar') then
    raise exception 'No tiene permiso para ver las mermas';
  end if;
  v_tz := app.zona();

  return query
  select
    m.id, m.numero, m.estado, m.clase, ca.nombre,
    m.producto_id, pr.nombre, pr.sku, pr.unidad_base,
    lo.codigo, lo.fecha_vencimiento,
    ub.nombre, s.nombre,
    m.cantidad,
    case when app.tiene_nivel('supervisor')
         then round(m.cantidad * coalesce(m.costo_unitario, 0), 2) end,
    m.notas,
    pe.nombre, m.solicitado_en,
    pe2.nombre, m.resuelto_en, m.nota_resolucion
  from mermas m
  join causas_merma ca   on ca.id = m.causa_id
  join productos pr      on pr.id = m.producto_id
  join sucursales s      on s.id = m.sucursal_id
  left join ubicaciones ub on ub.id = m.ubicacion_id
  left join lotes lo     on lo.id = m.lote_id
  left join perfiles pe  on pe.id = m.solicitado_por
  left join perfiles pe2 on pe2.id = m.resuelto_por
  where m.organizacion_id = app.org_id()
    and m.sucursal_id in (select app.sucursales_permitidas())
    and (p_estado is null or p_estado = 'todos' or m.estado = p_estado)
    and (p_sucursal_id is null or m.sucursal_id = p_sucursal_id)
    and (p_producto_id is null or m.producto_id = p_producto_id)
    and (p_desde is null or (m.solicitado_en at time zone v_tz)::date >= p_desde)
    and (p_hasta is null or (m.solicitado_en at time zone v_tz)::date <= p_hasta)
  order by (m.estado = 'pendiente') desc, m.solicitado_en desc
  limit greatest(coalesce(p_limite, 100), 1);
end $fn$;

revoke execute on function fn_mermas(text, date, date, uuid, uuid, int) from public, anon;
grant execute on function fn_mermas(text, date, date, uuid, uuid, int) to authenticated;


-- ---------------------------------------------------------------------------
-- 7. El resumen: las dos mermas, por separado
--
--    Esta es la funcion que contesta la pregunta del dueño: cuanto se perdio,
--    cuanto de eso se sabe por que, y cuanto no.
-- ---------------------------------------------------------------------------

create or replace function fn_merma_resumen(
  p_desde       date default null,
  p_hasta       date default null,
  p_sucursal_id uuid default null
) returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org   uuid;
  v_tz    text;
  v_d     date;
  v_h     date;
  v_sucs  uuid[];
  v_ve    boolean;
  r       jsonb;
  v_dano_u  numeric; v_dano_v  numeric;
  v_desc_u  numeric; v_desc_v  numeric;
  v_sobr_u  numeric; v_sobr_v  numeric;
  v_venta   numeric;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('supervisor'))) then
    raise exception 'El resumen de merma es para supervisor en adelante';
  end if;

  v_tz := app.zona(v_org);
  v_h  := coalesce(p_hasta, (now() at time zone v_tz)::date);
  v_d  := coalesce(p_desde, v_h - 29);
  v_ve := true;

  v_sucs := case when p_sucursal_id is not null then array[p_sucursal_id]
                 else array(select app.sucursales_permitidas()) end;

  -- 1. Merma por daño: lo que alguien explico
  select coalesce(sum(m.cantidad), 0),
         coalesce(sum(m.cantidad * coalesce(m.costo_unitario, 0)), 0)
    into v_dano_u, v_dano_v
  from mermas m
  where m.organizacion_id = v_org and m.estado = 'aprobado'
    and m.clase = 'dano'
    and m.sucursal_id = any(v_sucs)
    and (m.resuelto_en at time zone v_tz)::date between v_d and v_h;

  -- 2. Merma desconocida: lo que nadie pudo explicar.
  --    Dos origenes: la merma que alguien marco "no se sabe", y -sobre todo-
  --    las diferencias negativas que dejo un conteo aplicado.
  select coalesce(sum(m.cantidad), 0),
         coalesce(sum(m.cantidad * coalesce(m.costo_unitario, 0)), 0)
    into v_desc_u, v_desc_v
  from mermas m
  where m.organizacion_id = v_org and m.estado = 'aprobado'
    and m.clase = 'desconocida'
    and m.sucursal_id = any(v_sucs)
    and (m.resuelto_en at time zone v_tz)::date between v_d and v_h;

  select v_desc_u + coalesce(sum(abs(k.cantidad)), 0),
         v_desc_v + coalesce(sum(k.costo_total), 0)
    into v_desc_u, v_desc_v
  from kardex k
  where k.organizacion_id = v_org
    and k.tipo = 'ajuste_negativo'
    and k.documento_tipo in ('ajuste','conteo')
    and k.sucursal_id = any(v_sucs)
    and (k.ocurrido_en at time zone v_tz)::date between v_d and v_h;

  -- 3. Sobrante: las diferencias positivas. Casi nunca es mercaderia que
  --    aparecio; es error de conteo o un producto que se vendio como otro.
  select coalesce(sum(abs(k.cantidad)), 0), coalesce(sum(k.costo_total), 0)
    into v_sobr_u, v_sobr_v
  from kardex k
  where k.organizacion_id = v_org
    and k.tipo = 'ajuste_positivo'
    and k.documento_tipo in ('ajuste','conteo')
    and k.sucursal_id = any(v_sucs)
    and (k.ocurrido_en at time zone v_tz)::date between v_d and v_h;

  -- 4. La venta del periodo, para sacar el porcentaje. Es la forma en que el
  --    retail mide la merma: sola, en lempiras, no dice si es mucha o poca.
  select coalesce(sum(v.total), 0) into v_venta
  from ventas v
  where v.organizacion_id = v_org and v.estado = 'completada'
    and v.sucursal_id = any(v_sucs)
    and (v.creada_en at time zone v_tz)::date between v_d and v_h;

  select jsonb_build_object(
    'desde', v_d, 'hasta', v_h,
    'dano', jsonb_build_object(
      'unidades', v_dano_u, 'valor', round(v_dano_v, 2),
      'por_causa', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'causa', x.causa, 'unidades', x.u, 'valor', round(x.v, 2))
                 order by x.v desc)
        from (
          select ca.nombre as causa, sum(m.cantidad) as u,
                 sum(m.cantidad * coalesce(m.costo_unitario, 0)) as v
          from mermas m join causas_merma ca on ca.id = m.causa_id
          where m.organizacion_id = v_org and m.estado = 'aprobado'
            and m.clase = 'dano' and m.sucursal_id = any(v_sucs)
            and (m.resuelto_en at time zone v_tz)::date between v_d and v_h
          group by ca.nombre) x), '[]'::jsonb)),
    'desconocida', jsonb_build_object(
      'unidades', v_desc_u, 'valor', round(v_desc_v, 2)),
    'sobrante', jsonb_build_object(
      'unidades', v_sobr_u, 'valor', round(v_sobr_v, 2)),
    'desconocida_neta', round(greatest(v_desc_v - v_sobr_v, 0), 2),
    'total', round(v_dano_v + greatest(v_desc_v - v_sobr_v, 0), 2),
    'venta', round(v_venta, 2),
    'porcentaje', case when v_venta > 0
      then round((v_dano_v + greatest(v_desc_v - v_sobr_v, 0)) / v_venta * 100, 2) end,
    'pendientes', (select count(*) from mermas m
                    where m.organizacion_id = v_org and m.estado = 'pendiente'
                      and m.sucursal_id = any(v_sucs)),
    'top', coalesce((
      select jsonb_agg(jsonb_build_object(
               'producto', x.nombre, 'unidades', x.u, 'valor', round(x.v, 2),
               'clase', x.clase) order by x.v desc)
      from (
        select pr.nombre, m.clase, sum(m.cantidad) as u,
               sum(m.cantidad * coalesce(m.costo_unitario, 0)) as v
        from mermas m join productos pr on pr.id = m.producto_id
        where m.organizacion_id = v_org and m.estado = 'aprobado'
          and m.sucursal_id = any(v_sucs)
          and (m.resuelto_en at time zone v_tz)::date between v_d and v_h
        group by pr.nombre, m.clase
        order by v desc limit 8) x), '[]'::jsonb)
  ) into r;

  return r;
end $fn$;

revoke execute on function fn_merma_resumen(date, date, uuid) from public, anon;
grant execute on function fn_merma_resumen(date, date, uuid) to authenticated;
