-- ===========================================================================
-- 057 · Cierres de caja y cierre automático a medianoche
--
-- 1. Ningún turno pasa de un día a otro: a las 12 de la noche (hora del
--    negocio) se cierra solo. Queda con lo que el sistema esperaba en la
--    gaveta, sin conteo, y marcado como automático para que se note.
-- 2. fn_cierres_caja: la lista de turnos cerrados con su cuadre y lo cobrado
--    por cada forma de pago, para la pantalla de cierres.
-- ===========================================================================

alter table turnos_caja add column if not exists cerrado_auto boolean not null default false;

-- ---------------------------------------------------------------------------
-- 1. Cerrar los turnos que vienen de un día anterior
--
-- Cada negocio con su zona: la medianoche de Tegucigalpa no es la de Madrid.
-- Se cierra a la medianoche que siguió al día en que se abrió, no a la hora
-- en que corre el trabajo, para que el corte quede exacto aunque corra tarde.
-- ---------------------------------------------------------------------------
create or replace function app.cerrar_turnos_vencidos()
returns int
language plpgsql security definer set search_path = public, app as $fn$
declare
  t      record;
  v_tz   text;
  v_corte timestamptz;
  n      int := 0;
begin
  for t in
    select tc.* from turnos_caja tc
     where tc.estado = 'abierto'
       and (tc.abierto_en at time zone app.zona(tc.organizacion_id))::date
           < (now() at time zone app.zona(tc.organizacion_id))::date
     for update skip locked
  loop
    v_tz    := app.zona(t.organizacion_id);
    v_corte := (((t.abierto_en at time zone v_tz)::date + 1)::timestamp) at time zone v_tz;

    update turnos_caja
       set estado         = 'cerrado',
           cerrado_en     = v_corte,
           cerrado_auto   = true,
           monto_esperado = app.efectivo_esperado(t.id),
           notas          = concat_ws(' · ', nullif(btrim(t.notas), ''), 'Cerrado automáticamente a medianoche')
     where id = t.id;

    update caja_desbloqueos set consumido_en = now()
     where turno_id = t.id and consumido_en is null;

    n := n + 1;
  end loop;
  return n;
end $fn$;

revoke execute on function app.cerrar_turnos_vencidos() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. La lista de cierres
-- ---------------------------------------------------------------------------
create or replace function fn_cierres_caja(p_desde date, p_hasta date, p_sucursal_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  v_tz  text;
  v_ini timestamptz; v_fin timestamptz;
begin
  if v_org is null or not app.tiene_nivel('supervisor') then
    raise exception 'Solo supervisor o gerente ven los cierres de caja';
  end if;
  if p_hasta < p_desde then raise exception 'La fecha final va después de la inicial'; end if;
  if p_hasta - p_desde > 370 then raise exception 'Escoja un período de un año como mucho'; end if;
  v_tz  := app.zona(v_org);
  v_ini := (p_desde::timestamp) at time zone v_tz;
  v_fin := ((p_hasta + 1)::timestamp) at time zone v_tz;

  return jsonb_build_object(
    'desde', p_desde, 'hasta', p_hasta,
    'cierres', coalesce((
      select jsonb_agg(x order by x.cerrado_en desc) from (
        select t.id as turno_id,
               s.nombre as sucursal,
               c.nombre as caja,
               pc.nombre as cajero,
               pc.numero_cajero,
               t.abierto_en, t.cerrado_en,
               t.cerrado_auto as automatico,
               t.monto_inicial,
               t.monto_esperado as esperado,
               t.monto_declarado as declarado,
               t.diferencia,
               pr.nombre as cerro,
               t.notas,
               coalesce(v.ventas, 0)  as ventas,
               coalesce(v.total, 0)   as total,
               coalesce(pg.metodos, '{}'::jsonb) as metodos,
               coalesce(ab.abonos, 0) as abonos,
               coalesce(dv.devol, 0)  as devoluciones,
               coalesce(mv.fondos, 0) as fondos,
               coalesce(mv.retiros, 0) as retiros
          from turnos_caja t
          join sucursales s on s.id = t.sucursal_id
          join cajas c      on c.id = t.caja_id
          join perfiles pc  on pc.id = t.cajero_id
          left join perfiles pr on pr.id = t.cerrado_por
          left join lateral (
            select count(*) as ventas, sum(ve.total) as total
              from ventas ve where ve.turno_id = t.id and ve.estado = 'completada') v on true
          left join lateral (
            select jsonb_object_agg(m.metodo, m.monto) as metodos from (
              select pv.metodo::text as metodo, round(sum(pv.monto), 2) as monto
                from pagos_venta pv join ventas ve on ve.id = pv.venta_id
               where ve.turno_id = t.id and ve.estado = 'completada'
               group by pv.metodo) m) pg on true
          left join lateral (
            select sum(a.monto) as abonos from abonos_cliente a
             where a.turno_id = t.id and not a.anulado and a.metodo = 'efectivo') ab on true
          left join lateral (
            select sum(d.reembolso) as devol from devoluciones_venta d
             where d.turno_id = t.id and d.reembolso_metodo = 'efectivo') dv on true
          left join lateral (
            select sum(m.monto) filter (where m.tipo = 'fondo') as fondos,
                   sum(m.monto) filter (where m.tipo = 'retiro') as retiros
              from movimientos_caja m where m.turno_id = t.id) mv on true
         where t.organizacion_id = v_org
           and t.estado = 'cerrado'
           and t.cerrado_en >= v_ini and t.cerrado_en < v_fin
           and (p_sucursal_id is null or t.sucursal_id = p_sucursal_id)
           and (app.es_admin() or t.sucursal_id in (select app.sucursales_permitidas()))
      ) x), '[]'::jsonb),
    'abiertos', (select count(*) from turnos_caja t
                  where t.organizacion_id = v_org and t.estado = 'abierto'
                    and (p_sucursal_id is null or t.sucursal_id = p_sucursal_id)));
end $fn$;

revoke execute on function fn_cierres_caja(date, date, uuid) from public, anon;
grant execute on function fn_cierres_caja(date, date, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. El reloj: cada 5 minutos revisa. Si pg_cron no está (pruebas locales),
--    la migración sigue igual.
-- ---------------------------------------------------------------------------
do $do$
begin
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'pg_cron no disponible: %', sqlerrm;
    return;
  end;
  perform cron.unschedule(jobid) from cron.job where jobname = 'cerrar-turnos-medianoche';
  perform cron.schedule('cerrar-turnos-medianoche', '*/5 * * * *',
                        'select app.cerrar_turnos_vencidos()');
end $do$;
