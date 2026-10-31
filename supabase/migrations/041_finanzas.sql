-- ============================================================================
--  Migración 041 · Finanzas
--
--  Lo que le faltaba al dueño para llevar la contabilidad sin otro sistema:
--
--    1. EGRESOS. Alquiler, planilla, luz, combustible: todo lo que sale y no
--       es mercadería. Con categoría, forma de pago y de dónde salió. Si salió
--       de la gaveta de una caja con turno abierto, se registra además como
--       retiro de esa gaveta, para que el arqueo cuadre solo.
--
--    2. EVENTOS DE CAJA. Lo que pasa en la caja y no termina en venta:
--         abortada       la cajera canceló una venta con productos ya marcados
--         suspendida     dejó la venta en espera (F7)
--         retomada       la retomó (F8)
--         descartada     borró ventas que estaban en espera
--         linea_quitada  quitó un producto ya marcado (F4)
--       Es donde se esconde la plata que se pierde en el mostrador: marcar,
--       cobrar, y cancelar antes de imprimir. La caja los manda en lote y
--       con su propio id, así que llegan una sola vez aunque se reintente
--       sin internet.
--
--    3. REPORTES. fn_finanzas_resumen (estado de resultados e indicadores)
--       y fn_finanzas_lista (el detalle de cada sección).
--
--  Ver: supervisor en adelante. Anular egresos y ver la utilidad: gerente.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Egresos
-- ---------------------------------------------------------------------------
create table if not exists categorias_egreso (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references organizaciones(id) on delete cascade,
  nombre          text not null,
  -- operativo: gasto del negocio. financiero: intereses, comisiones.
  -- impuesto: municipalidad, SAR. retiro_dueno: no es gasto, es reparto.
  clase           text not null default 'operativo'
                  check (clase in ('operativo', 'financiero', 'impuesto', 'retiro_dueno')),
  orden           int not null default 100,
  activa          boolean not null default true,
  creada_en       timestamptz not null default now(),
  unique (organizacion_id, nombre)
);

create table if not exists egresos (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references organizaciones(id) on delete cascade,
  sucursal_id     uuid not null references sucursales(id),
  categoria_id    uuid not null references categorias_egreso(id),
  fecha           date not null,
  concepto        text not null,
  beneficiario    text,
  monto           numeric(16,2) not null check (monto > 0),
  metodo          text not null default 'efectivo'
                  check (metodo in ('efectivo', 'transferencia', 'tarjeta', 'cheque')),
  -- de dónde salió el dinero
  origen          text not null default 'oficina'
                  check (origen in ('caja', 'banco', 'oficina')),
  referencia      text,
  turno_id        uuid references turnos_caja(id),
  movimiento_id   uuid references movimientos_caja(id),
  registrado_por  uuid not null references perfiles(id),
  creado_en       timestamptz not null default now(),
  anulado_en      timestamptz,
  anulado_por     uuid references perfiles(id),
  motivo_anulacion text
);
create index if not exists ix_egresos_fecha on egresos (organizacion_id, fecha);

create table if not exists eventos_caja (
  id              uuid primary key,             -- lo pone la caja: no se duplica
  organizacion_id uuid not null references organizaciones(id) on delete cascade,
  sucursal_id     uuid not null references sucursales(id),
  caja_id         uuid not null references cajas(id),
  turno_id        uuid references turnos_caja(id),
  cajero_id       uuid not null references perfiles(id),
  tipo            text not null
                  check (tipo in ('abortada', 'suspendida', 'retomada', 'descartada', 'linea_quitada')),
  lineas          int not null default 0,
  unidades        numeric(14,3) not null default 0,
  monto           numeric(16,2) not null default 0,
  detalle         jsonb,
  motivo          text,
  ocurrido_en     timestamptz not null,
  recibido_en     timestamptz not null default now()
);
create index if not exists ix_eventos_caja on eventos_caja (organizacion_id, ocurrido_en);

alter table categorias_egreso enable row level security;
alter table egresos           enable row level security;
alter table eventos_caja      enable row level security;

-- Se lee por las funciones; directo, solo lo del propio negocio y desde supervisor.
do $pol$
begin
  if not exists (select 1 from pg_policies where tablename = 'categorias_egreso' and policyname = 'cat_egreso_ver') then
    execute $c$create policy cat_egreso_ver on categorias_egreso for select to authenticated
      using (organizacion_id = app.org_id())$c$;
  end if;
  if not exists (select 1 from pg_policies where tablename = 'egresos' and policyname = 'egresos_ver') then
    execute $c$create policy egresos_ver on egresos for select to authenticated
      using (organizacion_id = app.org_id() and app.tiene_nivel('supervisor'))$c$;
  end if;
  if not exists (select 1 from pg_policies where tablename = 'eventos_caja' and policyname = 'eventos_caja_ver') then
    execute $c$create policy eventos_caja_ver on eventos_caja for select to authenticated
      using (organizacion_id = app.org_id() and app.tiene_nivel('supervisor'))$c$;
  end if;
end
$pol$;

revoke all on categorias_egreso, egresos, eventos_caja from anon;
revoke insert, update, delete on categorias_egreso, egresos, eventos_caja from authenticated;
grant select on categorias_egreso, egresos, eventos_caja to authenticated;


-- Las categorías de siempre, la primera vez que el negocio las pide.
create or replace function fn_categorias_egreso() returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare v_org uuid := app.org_id();
begin
  if v_org is null or not app.tiene_nivel('supervisor') then
    raise exception 'Los egresos son para supervisor en adelante';
  end if;
  if not exists (select 1 from categorias_egreso where organizacion_id = v_org) then
    insert into categorias_egreso (organizacion_id, nombre, clase, orden)
    select v_org, n, c, o from (values
      ('Alquiler', 'operativo', 10), ('Planilla y sueldos', 'operativo', 20),
      ('Energía eléctrica', 'operativo', 30), ('Agua', 'operativo', 40),
      ('Internet y teléfono', 'operativo', 50), ('Transporte y combustible', 'operativo', 60),
      ('Mantenimiento y reparaciones', 'operativo', 70), ('Publicidad', 'operativo', 80),
      ('Bolsas, empaques y papelería', 'operativo', 90), ('Limpieza', 'operativo', 100),
      ('Seguridad', 'operativo', 110), ('Otros gastos', 'operativo', 190),
      ('Comisiones bancarias y POS', 'financiero', 200), ('Intereses de préstamos', 'financiero', 210),
      ('Impuestos y municipalidad', 'impuesto', 300),
      ('Retiro del dueño', 'retiro_dueno', 400)) x(n, c, o)
    on conflict do nothing;
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nombre', nombre, 'clase', clase)
                                    order by orden, nombre)
                     from categorias_egreso where organizacion_id = v_org and activa), '[]'::jsonb);
end $fn$;

-- Una categoría nueva (gerente).
create or replace function fn_crear_categoria_egreso(p_nombre text, p_clase text default 'operativo')
returns uuid
language plpgsql security definer set search_path = public, app as $fn$
declare v_org uuid := app.org_id(); v_id uuid;
begin
  if v_org is null or not app.tiene_nivel('gerente') then
    raise exception 'Las categorías las crea el gerente';
  end if;
  if coalesce(btrim(p_nombre), '') = '' then raise exception 'Falta el nombre'; end if;
  insert into categorias_egreso (organizacion_id, nombre, clase)
  values (v_org, btrim(p_nombre), coalesce(p_clase, 'operativo'))
  on conflict (organizacion_id, nombre) do update set activa = true
  returning id into v_id;
  return v_id;
end $fn$;


create or replace function fn_registrar_egreso(
  p_categoria_id uuid,
  p_monto        numeric,
  p_concepto     text,
  p_fecha        date default null,
  p_metodo       text default 'efectivo',
  p_origen       text default 'oficina',
  p_sucursal_id  uuid default null,
  p_beneficiario text default null,
  p_referencia   text default null,
  p_turno_id     uuid default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org  uuid := app.org_id();
  v_suc  uuid;
  c      record;
  t      record;
  v_mov  uuid;
  v_id   uuid;
  v_hay  numeric;
  v_turno uuid;
begin
  if v_org is null or not app.tiene_nivel('supervisor') then
    raise exception 'Los egresos los registra un supervisor en adelante';
  end if;

  select * into c from categorias_egreso where id = p_categoria_id and organizacion_id = v_org;
  if c.id is null then raise exception 'Esa categoría no es de su negocio'; end if;
  if p_monto is null or p_monto <= 0 then raise exception 'El monto tiene que ser mayor a cero'; end if;
  if coalesce(btrim(p_concepto), '') = '' then raise exception 'Escriba en qué se gastó'; end if;
  if p_origen not in ('caja', 'banco', 'oficina') then raise exception 'Origen no válido'; end if;
  if p_metodo not in ('efectivo', 'transferencia', 'tarjeta', 'cheque') then
    raise exception 'Forma de pago no válida';
  end if;
  if coalesce(p_fecha, current_date) > (now() at time zone app.zona(v_org))::date then
    raise exception 'La fecha no puede ser futura';
  end if;

  if p_origen = 'caja' then
    -- Sale de una gaveta: tiene que haber turno abierto, y es efectivo.
    select * into t from turnos_caja where id = p_turno_id and organizacion_id = v_org;
    if t.id is null then raise exception 'Elija la caja de donde sale el dinero'; end if;
    if t.estado <> 'abierto' then raise exception 'Ese turno ya se cerró'; end if;
    v_hay := app.efectivo_esperado(t.id);
    if p_monto > v_hay then
      raise exception 'En esa gaveta el sistema solo cuenta con %', round(v_hay, 2);
    end if;
    v_suc := t.sucursal_id;
    v_turno := t.id;
    insert into movimientos_caja (organizacion_id, sucursal_id, caja_id, turno_id, tipo,
                                  monto, motivo, autorizo)
    values (v_org, t.sucursal_id, t.caja_id, t.id, 'retiro', round(p_monto, 2),
            'Egreso: ' || btrim(p_concepto), auth.uid())
    returning id into v_mov;
  else
    v_suc := coalesce(p_sucursal_id,
                      (select id from sucursales where organizacion_id = v_org and activa
                        order by es_principal desc limit 1));
    if not exists (select 1 from sucursales where id = v_suc and organizacion_id = v_org) then
      raise exception 'Esa sucursal no es de su negocio';
    end if;
  end if;

  insert into egresos (organizacion_id, sucursal_id, categoria_id, fecha, concepto, beneficiario,
                       monto, metodo, origen, referencia, turno_id, movimiento_id, registrado_por)
  values (v_org, v_suc, c.id, coalesce(p_fecha, (now() at time zone app.zona(v_org))::date),
          btrim(p_concepto), nullif(btrim(p_beneficiario), ''), round(p_monto, 2),
          case when p_origen = 'caja' then 'efectivo' else p_metodo end,
          p_origen, nullif(btrim(p_referencia), ''),
          v_turno, v_mov, auth.uid())
  returning id into v_id;

  return jsonb_build_object('ok', true, 'egreso_id', v_id, 'movimiento_id', v_mov);
end $fn$;


-- Anular un egreso (gerente). Si salió de una gaveta con el turno todavía
-- abierto, el dinero se devuelve a esa gaveta como fondo; con el turno ya
-- cerrado no se puede, porque ese arqueo ya se firmó.
create or replace function fn_anular_egreso(p_egreso_id uuid, p_motivo text) returns boolean
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  e     record;
  t     record;
begin
  if v_org is null or not app.tiene_nivel('gerente') then
    raise exception 'Solo el gerente anula egresos';
  end if;
  select * into e from egresos where id = p_egreso_id and organizacion_id = v_org;
  if e.id is null then raise exception 'Ese egreso no es de su negocio'; end if;
  if e.anulado_en is not null then raise exception 'Ese egreso ya estaba anulado'; end if;
  if coalesce(btrim(p_motivo), '') = '' then raise exception 'Escriba por qué se anula'; end if;

  if e.movimiento_id is not null then
    select * into t from turnos_caja where id = e.turno_id;
    if t.estado <> 'abierto' then
      raise exception 'Ese egreso salió de un turno que ya se cerró: el arqueo ya está firmado';
    end if;
    insert into movimientos_caja (organizacion_id, sucursal_id, caja_id, turno_id, tipo,
                                  monto, motivo, autorizo)
    values (v_org, t.sucursal_id, t.caja_id, t.id, 'fondo', e.monto,
            'Anulación de egreso: ' || e.concepto, auth.uid());
  end if;

  update egresos set anulado_en = now(), anulado_por = auth.uid(),
                     motivo_anulacion = btrim(p_motivo)
   where id = e.id;
  return true;
end $fn$;


-- ---------------------------------------------------------------------------
-- 2. Eventos de caja, en lote
-- ---------------------------------------------------------------------------
create or replace function fn_eventos_caja(p_eventos jsonb) returns int
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  ev    jsonb;
  cj    record;
  v_n   int := 0;
begin
  if v_org is null or not app.tiene_nivel('auxiliar') then
    raise exception 'Sin permiso para la caja';
  end if;
  if jsonb_typeof(p_eventos) <> 'array' then raise exception 'Se esperaba una lista'; end if;
  if jsonb_array_length(p_eventos) > 200 then raise exception 'Demasiados eventos de una vez'; end if;

  for ev in select * from jsonb_array_elements(p_eventos) loop
    select * into cj from cajas where id = (ev->>'caja_id')::uuid and organizacion_id = v_org;
    if cj.id is null then continue; end if;          -- de otro negocio: se ignora
    if (ev->>'tipo') not in ('abortada', 'suspendida', 'retomada', 'descartada', 'linea_quitada') then
      continue;
    end if;
    insert into eventos_caja (id, organizacion_id, sucursal_id, caja_id, turno_id, cajero_id,
                              tipo, lineas, unidades, monto, detalle, motivo, ocurrido_en)
    values ((ev->>'id')::uuid, v_org, cj.sucursal_id, cj.id,
            -- el turno solo si es de esa caja y de este negocio
            (select id from turnos_caja where id = (ev->>'turno_id')::uuid
                                          and caja_id = cj.id and organizacion_id = v_org),
            auth.uid(),                                -- el cajero es quien manda, no lo que diga el lote
            ev->>'tipo',
            coalesce((ev->>'lineas')::int, 0),
            coalesce((ev->>'unidades')::numeric, 0),
            round(coalesce((ev->>'monto')::numeric, 0), 2),
            ev->'detalle',
            left(nullif(btrim(ev->>'motivo'), ''), 200),
            least(coalesce((ev->>'ocurrido_en')::timestamptz, now()), now()))
    on conflict (id) do nothing;
    if found then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end $fn$;


-- ---------------------------------------------------------------------------
-- 3. Reportes
-- ---------------------------------------------------------------------------

-- Lo común: período en horas de Honduras y sucursales que se pueden ver.
create or replace function app.finanzas_alcance(
  p_desde date, p_hasta date, p_sucursal_id uuid,
  out v_org uuid, out v_d date, out v_h date, out v_ini timestamptz, out v_fin timestamptz,
  out v_sucs uuid[], out v_hoy date
)
language plpgsql stable security definer set search_path = public, app as $fn$
declare v_tz text;
begin
  v_org := app.org_id();
  if v_org is null or not app.tiene_nivel('supervisor') then
    raise exception 'Finanzas es para supervisor en adelante';
  end if;
  v_tz  := app.zona(v_org);
  v_hoy := (now() at time zone v_tz)::date;
  v_h   := least(coalesce(p_hasta, v_hoy), v_hoy);
  v_d   := coalesce(p_desde, date_trunc('month', v_h)::date);
  if v_d > v_h then raise exception 'La fecha de inicio es después de la final'; end if;
  if v_h - v_d > 366 then raise exception 'Hasta un año a la vez'; end if;
  v_ini := v_d::timestamp at time zone v_tz;
  v_fin := (v_h + 1)::timestamp at time zone v_tz;
  if p_sucursal_id is not null then
    if p_sucursal_id not in (select app.sucursales_permitidas()) then
      raise exception 'No tiene acceso a esa sucursal';
    end if;
    v_sucs := array[p_sucursal_id];
  else
    v_sucs := array(select app.sucursales_permitidas());
  end if;
end $fn$;
revoke execute on function app.finanzas_alcance(date, date, uuid) from public, anon;
grant execute on function app.finanzas_alcance(date, date, uuid) to authenticated;


create or replace function fn_finanzas_resumen(
  p_desde date default null, p_hasta date default null, p_sucursal_id uuid default null
) returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  a        record;
  v_dias   int;
  t        jsonb;
  v_merma  numeric;
  v_egr    numeric;
  v_gasto  numeric;
  v_retiro numeric;
  v_inv    numeric;
  v_fiado  numeric;
  v_cred   numeric;
  v_ve     boolean := app.tiene_nivel('gerente');
  r        jsonb;
begin
  select * into a from app.finanzas_alcance(p_desde, p_hasta, p_sucursal_id);
  v_dias := a.v_h - a.v_d + 1;
  t := app.tablero_totales(a.v_org, a.v_sucs, a.v_ini, a.v_fin);

  v_merma := coalesce((fn_merma_resumen(a.v_d, a.v_h, p_sucursal_id) ->> 'total')::numeric, 0);

  select coalesce(sum(e.monto) filter (where c.clase <> 'retiro_dueno'), 0),
         coalesce(sum(e.monto) filter (where c.clase in ('operativo', 'financiero', 'impuesto')), 0),
         coalesce(sum(e.monto) filter (where c.clase = 'retiro_dueno'), 0)
    into v_egr, v_gasto, v_retiro
    from egresos e join categorias_egreso c on c.id = e.categoria_id
   where e.organizacion_id = a.v_org and e.sucursal_id = any(a.v_sucs)
     and e.anulado_en is null and e.fecha between a.v_d and a.v_h;

  select coalesce(sum(valor), 0) into v_inv
    from producto_costos where organizacion_id = a.v_org and sucursal_id = any(a.v_sucs);
  select coalesce(sum(debe), 0) into v_fiado from v_fiado where organizacion_id = a.v_org and debe > 0;
  select coalesce(sum(pv.monto), 0) into v_cred
    from pagos_venta pv join ventas v on v.id = pv.venta_id
   where v.organizacion_id = a.v_org and v.sucursal_id = any(a.v_sucs)
     and v.estado = 'completada' and pv.metodo = 'credito'
     and v.creada_en >= a.v_ini and v.creada_en < a.v_fin;

  with
  vv as (select v.id, v.total, v.impuesto from ventas v
          where v.organizacion_id = a.v_org and v.sucursal_id = any(a.v_sucs)
            and v.estado = 'completada' and v.creada_en >= a.v_ini and v.creada_en < a.v_fin),
  ev as (select * from eventos_caja e
          where e.organizacion_id = a.v_org and e.sucursal_id = any(a.v_sucs)
            and e.ocurrido_en >= a.v_ini and e.ocurrido_en < a.v_fin),
  tc as (select * from turnos_caja x
          where x.organizacion_id = a.v_org and x.sucursal_id = any(a.v_sucs)
            and x.estado = 'cerrado' and x.cerrado_en >= a.v_ini and x.cerrado_en < a.v_fin),
  dv as (select * from devoluciones_venta d
          where d.organizacion_id = a.v_org and d.sucursal_id = any(a.v_sucs)
            and d.creada_en >= a.v_ini and d.creada_en < a.v_fin)
  select jsonb_build_object(
    'desde', a.v_d, 'hasta', a.v_h, 'dias', v_dias, 'hoy', a.v_hoy,
    'puede_ver_utilidad', v_ve,

    -- estado de resultados
    'resultados', case when v_ve then jsonb_build_object(
       'venta_bruta',     round((select coalesce(sum(total), 0) from vv), 2),
       'isv',             round((select coalesce(sum(impuesto), 0) from vv), 2),
       'devoluciones',    t -> 'devuelto',
       'venta_neta',      t -> 'venta_sin_isv',
       'costo_ventas',    t -> 'costo',
       'utilidad_bruta',  t -> 'utilidad',
       'merma',           round(v_merma, 2),
       'gastos',          round(v_gasto, 2),
       'gastos_por_clase', coalesce((select jsonb_object_agg(clase, m) from (
           select c.clase, round(sum(e.monto), 2) as m from egresos e
             join categorias_egreso c on c.id = e.categoria_id
            where e.organizacion_id = a.v_org and e.sucursal_id = any(a.v_sucs)
              and e.anulado_en is null and e.fecha between a.v_d and a.v_h
            group by c.clase) x), '{}'::jsonb),
       'utilidad_neta',   round((t ->> 'utilidad')::numeric - v_merma - v_gasto, 2),
       'retiros_dueno',   round(v_retiro, 2)) end,

    'gastos_por_categoria', coalesce((select jsonb_agg(jsonb_build_object(
         'categoria', c.nombre, 'clase', c.clase, 'monto', round(x.m, 2), 'veces', x.n)
         order by x.m desc)
       from (select categoria_id, sum(monto) as m, count(*) as n from egresos
              where organizacion_id = a.v_org and sucursal_id = any(a.v_sucs)
                and anulado_en is null and fecha between a.v_d and a.v_h
              group by categoria_id) x
       join categorias_egreso c on c.id = x.categoria_id), '[]'::jsonb),

    -- indicadores
    'indicadores', jsonb_build_object(
       'margen_bruto',  case when v_ve then t -> 'margen' end,
       -- markup: cuánto se le sube al costo. 25% de margen = 33% de markup.
       'markup',        case when v_ve and (t ->> 'costo')::numeric > 0
                             then round((t ->> 'utilidad')::numeric / (t ->> 'costo')::numeric * 100, 1) end,
       'margen_neto',   case when v_ve and (t ->> 'venta_sin_isv')::numeric > 0
                             then round(((t ->> 'utilidad')::numeric - v_merma - v_gasto)
                                        / (t ->> 'venta_sin_isv')::numeric * 100, 1) end,
       'gasto_sobre_venta', case when (t ->> 'venta_sin_isv')::numeric > 0
                             then round(v_gasto / (t ->> 'venta_sin_isv')::numeric * 100, 1) end,
       -- punto de equilibrio: la venta (sin ISV) que cubre los gastos del período
       'punto_equilibrio', case when v_ve and coalesce((t ->> 'margen')::numeric, 0) > 0
                             then round((v_gasto + v_merma) / ((t ->> 'margen')::numeric / 100), 2) end,
       'venta_diaria',  round((t ->> 'venta')::numeric / v_dias, 2),
       'ticket_promedio', t -> 'ticket_promedio',
       'inventario',    case when v_ve then round(v_inv, 2) end,
       -- rotación anualizada: cuántas veces al año se vende el inventario
       'rotacion',      case when v_ve and v_inv > 0
                             then round((t ->> 'costo')::numeric / v_inv * 365 / v_dias, 1) end,
       'dias_inventario', case when v_ve and (t ->> 'costo')::numeric > 0
                             then round(v_inv / ((t ->> 'costo')::numeric / v_dias), 0) end,
       'fiado',         round(v_fiado, 2),
       -- días de cobro: cuántos días de venta al crédito hay en la calle
       'dias_cobro',    case when v_cred > 0 then round(v_fiado / (v_cred / v_dias), 0) end,
       'merma_sobre_venta', case when (t ->> 'venta')::numeric > 0
                             then round(v_merma / (t ->> 'venta')::numeric * 100, 2) end),

    -- la caja
    'caja', jsonb_build_object(
       'turnos',         (select count(*) from tc),
       'cuadrados',      (select count(*) from tc where abs(coalesce(diferencia, 0)) < 1),
       'faltante',       round((select coalesce(sum(least(diferencia, 0)), 0) from tc), 2),
       'sobrante',       round((select coalesce(sum(greatest(diferencia, 0)), 0) from tc), 2),
       'arqueos',        (select count(*) from movimientos_caja m
                           where m.organizacion_id = a.v_org and m.sucursal_id = any(a.v_sucs)
                             and m.tipo = 'arqueo'
                             and m.creado_en >= a.v_ini and m.creado_en < a.v_fin),
       'anuladas',       t -> 'anuladas',
       'monto_anulado',  t -> 'monto_anulado',
       'devoluciones',   (select count(*) from dv),
       'monto_devuelto', round((select coalesce(sum(total), 0) from dv), 2),
       'abortadas',      (select count(*) from ev where tipo = 'abortada'),
       'monto_abortado', round((select coalesce(sum(monto), 0) from ev where tipo = 'abortada'), 2),
       'suspendidas',    (select count(*) from ev where tipo = 'suspendida'),
       'monto_suspendido', round((select coalesce(sum(monto), 0) from ev where tipo = 'suspendida'), 2),
       'retomadas',      (select count(*) from ev where tipo = 'retomada'),
       'descartadas',    (select count(*) from ev where tipo = 'descartada'),
       'lineas_quitadas', (select count(*) from ev where tipo = 'linea_quitada'),
       'monto_quitado',  round((select coalesce(sum(monto), 0) from ev where tipo = 'linea_quitada'), 2)),

    -- dinero que entró y salió, por forma
    'flujo', jsonb_build_object(
       'cobros', coalesce((select jsonb_object_agg(metodo, m) from (
           select pv.metodo, round(sum(pv.monto), 2) as m from pagos_venta pv
             join vv on vv.id = pv.venta_id group by pv.metodo) x), '{}'::jsonb),
       'egresos', round(v_egr + v_retiro, 2),
       'egresos_por_origen', coalesce((select jsonb_object_agg(origen, m) from (
           select origen, round(sum(monto), 2) as m from egresos
            where organizacion_id = a.v_org and sucursal_id = any(a.v_sucs)
              and anulado_en is null and fecha between a.v_d and a.v_h group by origen) x), '{}'::jsonb),
       'compras', round(coalesce((select sum(total) from facturas_compra f
            where f.organizacion_id = a.v_org and f.sucursal_id = any(a.v_sucs)
              and f.estado = 'confirmado' and f.fecha between a.v_d and a.v_h), 0), 2))
  ) into r;

  return r;
end $fn$;


-- El detalle de cada sección.
create or replace function fn_finanzas_lista(
  p_seccion text, p_desde date default null, p_hasta date default null,
  p_sucursal_id uuid default null, p_limite int default 300
) returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  a   record;
  lim int := least(greatest(coalesce(p_limite, 300), 1), 1000);
begin
  select * into a from app.finanzas_alcance(p_desde, p_hasta, p_sucursal_id);

  if p_seccion = 'arqueos' then
    -- arqueos sorpresa y cierres de turno, juntos y en orden
    return coalesce((select jsonb_agg(x order by x->>'cuando' desc) from (
     select x from (
      select jsonb_build_object(
        'tipo', 'arqueo', 'id', m.id, 'cuando', m.creado_en,
        'caja', cj.nombre, 'cajero', pc.nombre, 'autorizo', pa.nombre,
        'esperado', round(m.esperado, 2), 'contado', round(m.monto, 2),
        'diferencia', round(m.diferencia, 2), 'motivo', m.motivo) as x
        from movimientos_caja m
        join cajas cj on cj.id = m.caja_id
        join turnos_caja tc on tc.id = m.turno_id
        join perfiles pc on pc.id = tc.cajero_id
        join perfiles pa on pa.id = m.autorizo
       where m.organizacion_id = a.v_org and m.sucursal_id = any(a.v_sucs) and m.tipo = 'arqueo'
         and m.creado_en >= a.v_ini and m.creado_en < a.v_fin
      union all
      select jsonb_build_object(
        'tipo', 'cierre', 'id', tc.id, 'cuando', tc.cerrado_en, 'abierto_en', tc.abierto_en,
        'caja', cj.nombre, 'cajero', pc.nombre, 'autorizo', pa.nombre,
        'esperado', round(tc.monto_esperado, 2), 'contado', round(tc.monto_declarado, 2),
        'diferencia', round(tc.diferencia, 2), 'motivo', tc.notas)
        from turnos_caja tc
        join cajas cj on cj.id = tc.caja_id
        join perfiles pc on pc.id = tc.cajero_id
        left join perfiles pa on pa.id = tc.cerrado_por
       where tc.organizacion_id = a.v_org and tc.sucursal_id = any(a.v_sucs) and tc.estado = 'cerrado'
         and tc.cerrado_en >= a.v_ini and tc.cerrado_en < a.v_fin
     ) u(x) order by x->>'cuando' desc limit lim) s), '[]'::jsonb);

  elsif p_seccion = 'cuadre' then
    -- por cajero: cuántos turnos, cuántos cuadrados, faltante y sobrante
    return coalesce((select jsonb_agg(jsonb_build_object(
        'cajero', p.nombre, 'codigo', p.codigo, 'turnos', x.n, 'cuadrados', x.ok,
        'faltante', round(x.falt, 2), 'sobrante', round(x.sobr, 2), 'neto', round(x.neto, 2),
        'peor', round(x.peor, 2), 'vendido', round(coalesce(v.total, 0), 2),
        'faltante_pct', case when coalesce(v.total, 0) > 0 then round(-x.falt / v.total * 100, 2) end)
        order by x.falt)
      from (select cajero_id, count(*) as n,
                   count(*) filter (where abs(coalesce(diferencia, 0)) < 1) as ok,
                   coalesce(sum(least(diferencia, 0)), 0) as falt,
                   coalesce(sum(greatest(diferencia, 0)), 0) as sobr,
                   coalesce(sum(diferencia), 0) as neto,
                   coalesce(min(diferencia), 0) as peor
              from turnos_caja
             where organizacion_id = a.v_org and sucursal_id = any(a.v_sucs) and estado = 'cerrado'
               and cerrado_en >= a.v_ini and cerrado_en < a.v_fin
             group by cajero_id) x
      join perfiles p on p.id = x.cajero_id
      left join (select cajero_id, sum(total) as total from ventas
                  where organizacion_id = a.v_org and sucursal_id = any(a.v_sucs)
                    and estado = 'completada' and creada_en >= a.v_ini and creada_en < a.v_fin
                  group by cajero_id) v on v.cajero_id = x.cajero_id), '[]'::jsonb);

  elsif p_seccion = 'anulaciones' then
    return coalesce((select jsonb_agg(jsonb_build_object(
        'id', v.id, 'numero', v.numero, 'creada_en', v.creada_en, 'anulada_en', v.anulada_en,
        'total', round(v.total, 2), 'cajero', pc.nombre, 'anulo', pa.nombre,
        'motivo', v.motivo_anulacion, 'caja', cj.nombre,
        'minutos', round(extract(epoch from (v.anulada_en - v.creada_en)) / 60))
        order by v.anulada_en desc)
      from (select * from ventas
             where organizacion_id = a.v_org and sucursal_id = any(a.v_sucs) and estado = 'anulada'
               and anulada_en >= a.v_ini and anulada_en < a.v_fin
             order by anulada_en desc limit lim) v
      left join perfiles pc on pc.id = v.cajero_id
      left join perfiles pa on pa.id = v.anulada_por
      left join cajas cj on cj.id = v.caja_id), '[]'::jsonb);

  elsif p_seccion = 'devoluciones' then
    return coalesce((select jsonb_agg(jsonb_build_object(
        'id', d.id, 'numero', d.numero, 'creada_en', d.creada_en, 'venta', v.numero,
        'total', round(d.total, 2), 'reembolso', round(d.reembolso, 2),
        'metodo', d.reembolso_metodo, 'rebaja_fiado', round(d.rebaja_fiado, 2),
        'motivo', d.motivo, 'hizo', p.nombre)
        order by d.creada_en desc)
      from (select * from devoluciones_venta
             where organizacion_id = a.v_org and sucursal_id = any(a.v_sucs)
               and creada_en >= a.v_ini and creada_en < a.v_fin
             order by creada_en desc limit lim) d
      left join ventas v on v.id = d.venta_id
      left join perfiles p on p.id = d.creada_por), '[]'::jsonb);

  elsif p_seccion in ('abortadas', 'suspendidas', 'quitadas') then
    return coalesce((select jsonb_agg(jsonb_build_object(
        'id', e.id, 'tipo', e.tipo, 'cuando', e.ocurrido_en, 'caja', cj.nombre,
        'cajero', p.nombre, 'lineas', e.lineas, 'unidades', e.unidades, 'monto', e.monto,
        'detalle', e.detalle, 'motivo', e.motivo)
        order by e.ocurrido_en desc)
      from (select * from eventos_caja
             where organizacion_id = a.v_org and sucursal_id = any(a.v_sucs)
               and ocurrido_en >= a.v_ini and ocurrido_en < a.v_fin
               and tipo = any(case p_seccion
                                when 'abortadas' then array['abortada']
                                when 'suspendidas' then array['suspendida', 'retomada', 'descartada']
                                else array['linea_quitada'] end)
             order by ocurrido_en desc limit lim) e
      join cajas cj on cj.id = e.caja_id
      join perfiles p on p.id = e.cajero_id), '[]'::jsonb);

  elsif p_seccion = 'egresos' then
    return coalesce((select jsonb_agg(jsonb_build_object(
        'id', e.id, 'fecha', e.fecha, 'categoria', c.nombre, 'clase', c.clase,
        'concepto', e.concepto, 'beneficiario', e.beneficiario, 'monto', e.monto,
        'metodo', e.metodo, 'origen', e.origen, 'referencia', e.referencia,
        'caja', cj.nombre, 'registro', p.nombre, 'creado_en', e.creado_en,
        'anulado', e.anulado_en is not null, 'motivo_anulacion', e.motivo_anulacion,
        'sucursal', s.nombre)
        order by e.fecha desc, e.creado_en desc)
      from (select * from egresos
             where organizacion_id = a.v_org and sucursal_id = any(a.v_sucs)
               and fecha between a.v_d and a.v_h
             order by fecha desc, creado_en desc limit lim) e
      join categorias_egreso c on c.id = e.categoria_id
      join perfiles p on p.id = e.registrado_por
      join sucursales s on s.id = e.sucursal_id
      left join turnos_caja tc on tc.id = e.turno_id
      left join cajas cj on cj.id = tc.caja_id), '[]'::jsonb);

  else
    raise exception 'Sección desconocida: %', p_seccion;
  end if;
end $fn$;


-- Las cajas con turno abierto, para pagar un egreso desde una gaveta.
create or replace function fn_cajas_abiertas() returns jsonb
language sql stable security definer set search_path = public, app as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'turno_id', tc.id, 'caja', cj.nombre, 'cajero', p.nombre,
           'sucursal', s.nombre, 'en_gaveta', round(app.efectivo_esperado(tc.id), 2))
           order by s.nombre, cj.nombre), '[]'::jsonb)
    from turnos_caja tc
    join cajas cj on cj.id = tc.caja_id
    join perfiles p on p.id = tc.cajero_id
    join sucursales s on s.id = tc.sucursal_id
   where tc.organizacion_id = app.org_id() and tc.estado = 'abierto'
     and app.tiene_nivel('supervisor')
     and tc.sucursal_id in (select app.sucursales_permitidas())
$fn$;


revoke execute on function fn_categorias_egreso() from public, anon;
revoke execute on function fn_crear_categoria_egreso(text, text) from public, anon;
revoke execute on function fn_registrar_egreso(uuid, numeric, text, date, text, text, uuid, text, text, uuid) from public, anon;
revoke execute on function fn_anular_egreso(uuid, text) from public, anon;
revoke execute on function fn_eventos_caja(jsonb) from public, anon;
revoke execute on function fn_finanzas_resumen(date, date, uuid) from public, anon;
revoke execute on function fn_finanzas_lista(text, date, date, uuid, int) from public, anon;
revoke execute on function fn_cajas_abiertas() from public, anon;
grant execute on function fn_categorias_egreso() to authenticated;
grant execute on function fn_crear_categoria_egreso(text, text) to authenticated;
grant execute on function fn_registrar_egreso(uuid, numeric, text, date, text, text, uuid, text, text, uuid) to authenticated;
grant execute on function fn_anular_egreso(uuid, text) to authenticated;
grant execute on function fn_eventos_caja(jsonb) to authenticated;
grant execute on function fn_finanzas_resumen(date, date, uuid) to authenticated;
grant execute on function fn_finanzas_lista(text, date, date, uuid, int) to authenticated;
grant execute on function fn_cajas_abiertas() to authenticated;


-- ---------------------------------------------------------------------------
-- 4. El color y el logo del negocio llegan con el contexto, para que cada
--    pantalla se pinte con la marca desde el primer momento.
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
      'logo_path', v_org.config ->> 'logo_path'
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

notify pgrst, 'reload schema';
