-- ============================================================================
--  056 · Cajeros: tiempo por venta e indicadores
--
--  · La caja anota cuándo empezó cada venta (el primer producto escaneado);
--    con la hora del cobro sale cuánto duró.
--  · fn_cajeros_indicadores: por cajero y período, ventas, artículos por
--    hora, tiempo promedio por venta, horas en turno, anulaciones,
--    cancelaciones y descuadres. Supervisor en adelante.
-- ============================================================================

create table if not exists venta_tiempos (
  venta_id        uuid primary key references ventas(id) on delete cascade,
  organizacion_id uuid not null references organizaciones(id) on delete cascade,
  cajero_id       uuid,
  inicio          timestamptz not null,
  segundos        int not null check (segundos >= 0),
  creado_en       timestamptz not null default now()
);
create index if not exists ix_venta_tiempos_org on venta_tiempos (organizacion_id, cajero_id);
alter table venta_tiempos enable row level security;
revoke all on venta_tiempos from public, anon, authenticated;

create or replace function fn_anotar_tiempo_venta(p_venta_id uuid, p_inicio timestamptz)
returns int
language plpgsql security definer set search_path = public, app as $fn$
declare v record; n int;
begin
  if not app.tiene_nivel('auxiliar') then raise exception 'Sin permiso'; end if;
  select * into v from ventas where id = p_venta_id and organizacion_id = app.org_id();
  if v.id is null then raise exception 'Esa venta no es de su negocio'; end if;
  if v.cajero_id is distinct from auth.uid() and not app.tiene_nivel('supervisor') then
    raise exception 'Solo quien cobró la venta anota su tiempo';
  end if;
  if p_inicio is null then return null; end if;
  if exists (select 1 from venta_tiempos where venta_id = v.id) then return null; end if;
  -- Más de dos horas no es una venta, es una caja olvidada abierta: no cuenta.
  n := greatest(0, extract(epoch from (v.creada_en - p_inicio))::int);
  if n > 7200 then return null; end if;
  insert into venta_tiempos (venta_id, organizacion_id, cajero_id, inicio, segundos)
  values (v.id, v.organizacion_id, v.cajero_id, least(p_inicio, v.creada_en), n)
  on conflict (venta_id) do nothing;
  return n;
end $fn$;
revoke execute on function fn_anotar_tiempo_venta(uuid, timestamptz) from public, anon;
grant execute on function fn_anotar_tiempo_venta(uuid, timestamptz) to authenticated;

create or replace function fn_cajeros_indicadores(p_desde date, p_hasta date, p_sucursal_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  v_tz  text;
  v_ini timestamptz; v_fin timestamptz;
begin
  if v_org is null or not app.tiene_nivel('supervisor') then
    raise exception 'Solo supervisor o gerente ven los indicadores de cajeros';
  end if;
  if p_hasta < p_desde then raise exception 'La fecha final va después de la inicial'; end if;
  if p_hasta - p_desde > 370 then raise exception 'Escoja un período de un año como mucho'; end if;
  v_tz  := app.zona(v_org);
  v_ini := (p_desde::timestamp) at time zone v_tz;
  v_fin := ((p_hasta + 1)::timestamp) at time zone v_tz;

  return jsonb_build_object(
    'desde', p_desde, 'hasta', p_hasta,
    'cajeros', coalesce((
      with gente as (
        select p.id, p.nombre, p.rol, p.activo, p.numero_cajero, p.codigo
          from perfiles p
         where p.organizacion_id = v_org and p.rol in ('auxiliar','supervisor','gerente')
      ), vt as (
        select v.cajero_id, count(*) as ventas, sum(v.total) as total
          from ventas v
         where v.organizacion_id = v_org and v.estado = 'completada'
           and v.creada_en >= v_ini and v.creada_en < v_fin and v.caja_id is not null
           and (p_sucursal_id is null or v.sucursal_id = p_sucursal_id)
         group by v.cajero_id
      ), ha as (
        -- Horas con ventas: un turno que se queda abierto días no cuenta como trabajo
        select v.cajero_id, count(distinct date_trunc('hour', v.creada_en at time zone v_tz)) as horas
          from ventas v
         where v.organizacion_id = v_org and v.estado = 'completada'
           and v.creada_en >= v_ini and v.creada_en < v_fin and v.caja_id is not null
           and (p_sucursal_id is null or v.sucursal_id = p_sucursal_id)
         group by v.cajero_id
      ), un as (
        select v.cajero_id, sum(d.cantidad) as unidades, count(*) as lineas
          from ventas v join venta_detalle d on d.venta_id = v.id
         where v.organizacion_id = v_org and v.estado = 'completada'
           and v.creada_en >= v_ini and v.creada_en < v_fin and v.caja_id is not null
           and (p_sucursal_id is null or v.sucursal_id = p_sucursal_id)
         group by v.cajero_id
      ), an as (
        select v.cajero_id, count(*) as anuladas
          from ventas v
         where v.organizacion_id = v_org and v.estado = 'anulada'
           and v.creada_en >= v_ini and v.creada_en < v_fin
           and (p_sucursal_id is null or v.sucursal_id = p_sucursal_id)
         group by v.cajero_id
      ), ti as (
        select t.cajero_id, avg(t.segundos) as segundos, count(*) as medidas
          from venta_tiempos t join ventas v on v.id = t.venta_id
         where t.organizacion_id = v_org and v.estado = 'completada'
           and v.creada_en >= v_ini and v.creada_en < v_fin
           and (p_sucursal_id is null or v.sucursal_id = p_sucursal_id)
         group by t.cajero_id
      ), tu as (
        select t.cajero_id,
               sum(greatest(0, extract(epoch from (least(coalesce(t.cerrado_en, now()), v_fin, t.abierto_en + interval '14 hours')
                                              - greatest(t.abierto_en, v_ini))) / 3600.0)) as horas,
               count(*) as turnos,
               sum(coalesce(t.diferencia, 0)) filter (where t.cerrado_en is not null) as descuadre,
               bool_or(t.estado = 'abierto') as en_turno,
               max(t.abierto_en) as ultimo_turno
          from turnos_caja t
         where t.organizacion_id = v_org
           and t.abierto_en < v_fin and coalesce(t.cerrado_en, now()) > v_ini
           and (p_sucursal_id is null or t.sucursal_id = p_sucursal_id)
         group by t.cajero_id
      ), ev as (
        select e.cajero_id,
               count(*) filter (where e.tipo = 'linea_quitada') as quitadas,
               count(*) filter (where e.tipo = 'abortada') as canceladas
          from eventos_caja e
         where e.organizacion_id = v_org and e.ocurrido_en >= v_ini and e.ocurrido_en < v_fin
           and (p_sucursal_id is null or e.sucursal_id = p_sucursal_id)
         group by e.cajero_id
      )
      select jsonb_agg(jsonb_build_object(
               'id', g.id, 'nombre', g.nombre, 'rol', g.rol, 'activo', g.activo,
               'numero', g.numero_cajero, 'codigo', g.codigo,
               'ventas', coalesce(vt.ventas, 0), 'total', round(coalesce(vt.total, 0), 2),
               'ticket_promedio', case when coalesce(vt.ventas, 0) > 0 then round(vt.total / vt.ventas, 2) end,
               'unidades', round(coalesce(un.unidades, 0), 3), 'lineas', coalesce(un.lineas, 0),
               'horas', round(coalesce(tu.horas, 0)::numeric, 2), 'turnos', coalesce(tu.turnos, 0),
               'horas_activas', coalesce(ha.horas, 0),
               'articulos_hora', case when coalesce(ha.horas, 0) > 0 then round((coalesce(un.lineas, 0)::numeric / ha.horas), 1) end,
               'ventas_hora', case when coalesce(ha.horas, 0) > 0 then round((coalesce(vt.ventas, 0)::numeric / ha.horas), 1) end,
               'segundos_venta', case when ti.medidas > 0 then round(ti.segundos)::int end,
               'ventas_medidas', coalesce(ti.medidas, 0),
               'anuladas', coalesce(an.anuladas, 0),
               'quitadas', coalesce(ev.quitadas, 0), 'canceladas', coalesce(ev.canceladas, 0),
               'descuadre', round(coalesce(tu.descuadre, 0), 2),
               'en_turno', coalesce(tu.en_turno, false), 'ultimo_turno', tu.ultimo_turno)
             order by coalesce(vt.ventas, 0) desc, g.nombre)
        from gente g
        left join vt on vt.cajero_id = g.id
        left join un on un.cajero_id = g.id
        left join ha on ha.cajero_id = g.id
        left join an on an.cajero_id = g.id
        left join ti on ti.cajero_id = g.id
        left join tu on tu.cajero_id = g.id
        left join ev on ev.cajero_id = g.id
       where g.activo or vt.ventas is not null or tu.turnos is not null), '[]'::jsonb));
end $fn$;
revoke execute on function fn_cajeros_indicadores(date, date, uuid) from public, anon;
grant execute on function fn_cajeros_indicadores(date, date, uuid) to authenticated;

notify pgrst, 'reload schema';
