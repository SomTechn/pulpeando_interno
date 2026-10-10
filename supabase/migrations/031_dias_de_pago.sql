-- ===========================================================================
-- 031 · Dias de pago del cliente de fiado
--
-- En la pulperia el fiado se cobra cuando el cliente cobra: el viernes, la
-- quincena, el 30. Se guarda en clientes.dias_pago:
--
--   {"tipo":"semana","dias":[5]}        los viernes (1 = lunes … 7 = domingo)
--   {"tipo":"mes","dias":[15,30]}       la quincena y fin de mes
--                                       (30 o 31 en febrero = ultimo dia)
--
-- Con eso:
--   · proximo_pago   el siguiente dia que le toca
--   · le_toca_hoy    hoy es su dia de pago y debe
--   · atrasado       paso un dia de pago con deuda de antes de ese dia y no
--                    abono nada desde entonces
--
-- Lo fija un supervisor, como el limite: son las condiciones del credito.
-- ===========================================================================

alter table clientes add column if not exists dias_pago jsonb;

-- Que siempre tenga una forma que las funciones entiendan
create or replace function app.dias_pago_valido(d jsonb)
returns boolean immutable language sql as $fn$
  select d is null or (
    jsonb_typeof(d) = 'object'
    and d->>'tipo' in ('semana', 'mes')
    and jsonb_typeof(d->'dias') = 'array'
    and jsonb_array_length(d->'dias') between 1 and 7
    and not exists (
      select 1 from jsonb_array_elements(d->'dias') x
      where jsonb_typeof(x) <> 'number'
         or (d->>'tipo' = 'semana' and (x::int < 1 or x::int > 7))
         or (d->>'tipo' = 'mes'    and (x::int < 1 or x::int > 31))))
$fn$;

alter table clientes drop constraint if exists clientes_dias_pago_valido;
alter table clientes add constraint clientes_dias_pago_valido check (app.dias_pago_valido(dias_pago));


-- Las fechas de pago entre dos dias, segun la regla del cliente
create or replace function app.fechas_pago(d jsonb, p_desde date, p_hasta date)
returns setof date stable language sql as $fn$
  select g::date
  from generate_series(p_desde, p_hasta, interval '1 day') g
  where d is not null and (
    (d->>'tipo' = 'semana'
      and extract(isodow from g)::int in (select x::int from jsonb_array_elements_text(d->'dias') x))
    or
    (d->>'tipo' = 'mes'
      and exists (select 1 from jsonb_array_elements_text(d->'dias') x
                  where extract(day from g)::int =
                        least(x::int, extract(day from (date_trunc('month', g) + interval '1 month - 1 day'))::int))))
$fn$;

create or replace function app.proximo_pago(d jsonb, p_hoy date)
returns date stable language sql as $fn$
  select min(f) from app.fechas_pago(d, p_hoy, p_hoy + 62) f
$fn$;

create or replace function app.ultimo_pago(d jsonb, p_hoy date)
returns date stable language sql as $fn$
  select max(f) from app.fechas_pago(d, p_hoy - 62, p_hoy) f
$fn$;

-- Texto para la pantalla: "los viernes", "los 15 y 30"
create or replace function app.dias_pago_texto(d jsonb)
returns text immutable language sql as $fn$
  select case
    when d is null then null
    when d->>'tipo' = 'semana' then 'los ' || regexp_replace((
      select string_agg((array['lunes','martes','miércoles','jueves','viernes','sábados','domingos'])[x::int], ', ' order by x::int)
      from jsonb_array_elements_text(d->'dias') x), ', ([^,]*)$', ' y \1')
    else 'los ' || (
      select string_agg(x, ' y ' order by x::int) from jsonb_array_elements_text(d->'dias') x)
      || ' de cada mes'
  end
$fn$;


-- ---------------------------------------------------------------------------
-- Fijarlos (supervisor en adelante)
-- ---------------------------------------------------------------------------
create or replace function fn_fijar_dias_pago(p_cliente_id uuid, p_dias_pago jsonb)
returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  c record;
  v_tz text;
begin
  select * into c from clientes where id = p_cliente_id for update;
  if c.id is null then raise exception 'Cliente inexistente'; end if;

  if not (app.es_admin()
          or (c.organizacion_id = app.org_id() and app.tiene_nivel('supervisor'))) then
    raise exception 'Solo un supervisor fija los días de pago';
  end if;

  if p_dias_pago is not null and jsonb_typeof(p_dias_pago) = 'null' then p_dias_pago := null; end if;
  if not app.dias_pago_valido(p_dias_pago) then
    raise exception 'Días de pago no válidos';
  end if;

  update clientes set dias_pago = p_dias_pago, actualizado_en = now() where id = p_cliente_id;

  v_tz := app.zona(c.organizacion_id);
  return jsonb_build_object(
    'cliente', c.nombre,
    'dias_pago', p_dias_pago,
    'texto', app.dias_pago_texto(p_dias_pago),
    'proximo_pago', app.proximo_pago(p_dias_pago, (now() at time zone v_tz)::date));
end $fn$;

revoke execute on function fn_fijar_dias_pago(uuid, jsonb) from public, anon;
grant execute on function fn_fijar_dias_pago(uuid, jsonb) to authenticated;


-- ---------------------------------------------------------------------------
-- La situacion de pago de un cliente, para la caja
-- ---------------------------------------------------------------------------
create or replace function fn_situacion_cliente(p_cliente_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  c       record;
  v_hoy   date;
  v_ult   date;
  v_desde timestamptz;
  v_abono timestamptz;
begin
  select * into c from clientes where id = p_cliente_id;
  if c.id is null then raise exception 'Cliente inexistente'; end if;
  if not (app.es_admin() or (c.organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))) then
    raise exception 'Ese cliente no es de su negocio';
  end if;

  v_hoy := (now() at time zone app.zona(c.organizacion_id))::date;
  v_ult := app.ultimo_pago(c.dias_pago, v_hoy);
  select deuda_desde, ultimo_abono into v_desde, v_abono from v_fiado where cliente_id = c.id;

  return jsonb_build_object(
    'debe', round(coalesce(c.saldo, 0), 2),
    'limite', round(coalesce(c.limite_credito, 0), 2),
    'disponible', round(greatest(coalesce(c.limite_credito, 0) - coalesce(c.saldo, 0), 0), 2),
    'dias_pago', c.dias_pago,
    'dias_pago_texto', app.dias_pago_texto(c.dias_pago),
    'proximo_pago', app.proximo_pago(c.dias_pago, v_hoy),
    'le_toca_hoy', coalesce(c.saldo, 0) > 0 and v_ult = v_hoy,
    'atrasado', coalesce(c.saldo, 0) > 0 and v_ult is not null and v_ult < v_hoy
                and v_desde is not null and v_desde::date < v_ult
                and (v_abono is null or (v_abono at time zone app.zona(c.organizacion_id))::date < v_ult),
    'deuda_desde', v_desde,
    'ultimo_abono', v_abono);
end $fn$;

revoke execute on function fn_situacion_cliente(uuid) from public, anon;
grant execute on function fn_situacion_cliente(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- v_fiado con los dias de pago (columnas nuevas al final)
-- ---------------------------------------------------------------------------
create or replace view v_fiado as
with credito as (
  select v.cliente_id, v.id, v.creada_en, cr.monto,
         sum(cr.monto) over (partition by v.cliente_id order by v.creada_en, v.id) as acumulado
  from ventas v
  cross join lateral (
    select coalesce(sum(pv.monto), 0) as monto
    from pagos_venta pv
    where pv.venta_id = v.id and pv.metodo = 'credito'
  ) cr
  where v.es_credito and v.estado = 'completada' and v.cliente_id is not null
),
pagado as (
  select cliente_id, sum(monto) as total
  from abonos_cliente where not anulado
  group by cliente_id
),
vieja as (
  select c.cliente_id, min(c.creada_en) as desde
  from credito c
  left join pagado p on p.cliente_id = c.cliente_id
  where c.acumulado > coalesce(p.total, 0)
  group by c.cliente_id
),
base as (
  select
    cl.organizacion_id,
    cl.id                                   as cliente_id,
    cl.nombre                               as cliente,
    cl.telefono,
    cl.saldo                                as debe,
    cl.limite_credito                       as limite,
    greatest(cl.limite_credito - cl.saldo, 0) as disponible,
    cl.saldo >= cl.limite_credito           as tope_alcanzado,
    vieja.desde                             as deuda_desde,
    case when vieja.desde is null then null
         else (current_date - vieja.desde::date) end as dias,
    (select max(a.creado_en) from abonos_cliente a
      where a.cliente_id = cl.id and not a.anulado) as ultimo_abono,
    (select count(*) from ventas v
      where v.cliente_id = cl.id and v.es_credito and v.estado = 'completada') as compras_credito,
    cl.dias_pago,
    (now() at time zone app.zona(cl.organizacion_id))::date as hoy
  from clientes cl
  left join vieja on vieja.cliente_id = cl.id
  where cl.saldo > 0
)
select
  b.organizacion_id, b.cliente_id, b.cliente, b.telefono, b.debe, b.limite, b.disponible,
  b.tope_alcanzado, b.deuda_desde, b.dias, b.ultimo_abono, b.compras_credito,
  b.dias_pago,
  app.dias_pago_texto(b.dias_pago)        as dias_pago_texto,
  app.proximo_pago(b.dias_pago, b.hoy)    as proximo_pago,
  app.ultimo_pago(b.dias_pago, b.hoy) = b.hoy as le_toca_hoy,
  coalesce(
    app.ultimo_pago(b.dias_pago, b.hoy) < b.hoy
    and b.deuda_desde::date < app.ultimo_pago(b.dias_pago, b.hoy)
    and (b.ultimo_abono is null
         or (b.ultimo_abono at time zone app.zona(b.organizacion_id))::date < app.ultimo_pago(b.dias_pago, b.hoy)),
    false)                                as atrasado
from base b;

alter view v_fiado set (security_invoker = on);
grant select on v_fiado to authenticated;

create or replace function fn_fiado_resumen()
returns jsonb
language sql stable security definer set search_path = public, app as $fn$
  select jsonb_build_object(
    'clientes',      count(*),
    'total',         coalesce(sum(debe), 0),
    'al_tope',       count(*) filter (where tope_alcanzado),
    'mas_30_dias',   count(*) filter (where dias > 30),
    'monto_mas_30',  coalesce(sum(debe) filter (where dias > 30), 0),
    'mas_viejo',     coalesce(max(dias), 0),
    'les_toca_hoy',  count(*) filter (where le_toca_hoy),
    'monto_hoy',     coalesce(sum(debe) filter (where le_toca_hoy), 0),
    'atrasados',     count(*) filter (where atrasado),
    'monto_atrasado', coalesce(sum(debe) filter (where atrasado), 0)
  )
  from v_fiado
  where organizacion_id = app.org_id()
$fn$;

revoke execute on function fn_fiado_resumen() from public, anon;
grant execute on function fn_fiado_resumen() to authenticated;

-- La caja lee dias_pago al elegir cliente (lectura, no escritura)
grant select (dias_pago) on clientes to authenticated;

notify pgrst, 'reload schema';
