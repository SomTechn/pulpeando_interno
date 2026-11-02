-- ============================================================================
--  053 · Registro de accesos y horario de cada sucursal
--
--  · Cada vez que alguien entra (panel o caja) queda anotado con su IP y el
--    país, si el proveedor lo manda en los encabezados (cf-ipcountry). Si
--    alguien entra desde fuera de Honduras, el gerente lo ve en Inicio.
--  · Cada sucursal puede guardar su horario por día. La app del cliente lo
--    enseña y dice si la pulpería está abierta ahora mismo.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Los accesos
-- ---------------------------------------------------------------------------
create table if not exists accesos (
  id              bigint generated always as identity primary key,
  organizacion_id uuid references organizaciones(id) on delete cascade,
  usuario_id      uuid not null,
  ip              text,
  pais            text,
  aparato         text,
  donde           text not null default 'panel' check (donde in ('panel','caja')),
  creado_en       timestamptz not null default now()
);
create index if not exists ix_accesos_org on accesos (organizacion_id, creado_en desc);
create index if not exists ix_accesos_usuario on accesos (usuario_id, creado_en desc);
alter table accesos enable row level security;
revoke all on accesos from public, anon, authenticated;

create or replace function fn_registrar_acceso(p_aparato text default null, p_donde text default 'panel')
returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  h jsonb; v_ip text; v_pais text; v_ult record;
begin
  if auth.uid() is null then return null; end if;
  begin
    h := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then h := null;
  end;
  v_ip := btrim(split_part(coalesce(h->>'cf-connecting-ip', h->>'x-real-ip', h->>'x-forwarded-for', ''), ',', 1));
  v_pais := upper(nullif(btrim(coalesce(h->>'cf-ipcountry', h->>'x-country-code', h->>'x-vercel-ip-country', '')), ''));
  if v_pais in ('XX', 'T1') then v_pais := null; end if;   -- desconocido / Tor

  -- La misma persona desde la misma IP en la última media hora: ya está.
  select * into v_ult from accesos
   where usuario_id = auth.uid() and creado_en > now() - interval '30 minutes'
   order by creado_en desc limit 1;
  if v_ult.id is null or v_ult.ip is distinct from nullif(v_ip, '') then
    insert into accesos (organizacion_id, usuario_id, ip, pais, aparato, donde)
    values (app.org_id(), auth.uid(), nullif(v_ip, ''), v_pais, left(p_aparato, 160),
            case when p_donde = 'caja' then 'caja' else 'panel' end);
  end if;
  return jsonb_build_object('pais', v_pais, 'fuera', v_pais is not null and v_pais <> 'HN');
end $fn$;
revoke execute on function fn_registrar_acceso(text, text) from public, anon;
grant execute on function fn_registrar_acceso(text, text) to authenticated;

-- Los accesos del negocio (gerente). p_fuera = solo los de fuera de Honduras.
create or replace function fn_accesos(p_dias int default 30, p_fuera boolean default false)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare v_org uuid := app.org_id();
begin
  if v_org is null or not app.tiene_nivel('gerente') then raise exception 'Solo el gerente ve los accesos'; end if;
  return jsonb_build_object(
    'fuera_7d', (select count(*) from accesos a where a.organizacion_id = v_org
                   and a.pais is not null and a.pais <> 'HN' and a.creado_en > now() - interval '7 days'),
    'filas', coalesce((
      select jsonb_agg(x order by x->>'creado_en' desc) from (
        select jsonb_build_object('nombre', coalesce(p.nombre, '—'), 'rol', p.rol, 'ip', a.ip,
                 'pais', a.pais, 'fuera', a.pais is not null and a.pais <> 'HN',
                 'aparato', a.aparato, 'donde', a.donde, 'creado_en', a.creado_en) x
          from accesos a left join perfiles p on p.id = a.usuario_id
         where a.organizacion_id = v_org
           and a.creado_en > now() - make_interval(days => least(greatest(coalesce(p_dias, 30), 1), 90))
           and (not coalesce(p_fuera, false) or (a.pais is not null and a.pais <> 'HN'))
         order by a.creado_en desc limit 300) t), '[]'::jsonb));
end $fn$;
revoke execute on function fn_accesos(int, boolean) from public, anon;
grant execute on function fn_accesos(int, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. El horario: {"0":null,"1":{"abre":"07:00","cierra":"21:00"}, ...}
--    0 = domingo. Si cierra es menor que abre, cierra pasada la medianoche.
-- ---------------------------------------------------------------------------
create or replace function app.horario_valido(h jsonb)
returns boolean
language sql immutable as $fn$
  select h is null or (jsonb_typeof(h) = 'object' and not exists (
    select 1 from jsonb_each(h) e
     where e.key !~ '^[0-6]$'
        or (jsonb_typeof(e.value) <> 'null' and not (
              jsonb_typeof(e.value) = 'object'
              and coalesce(e.value->>'abre', '') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
              and coalesce(e.value->>'cierra', '') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
              and e.value->>'abre' <> e.value->>'cierra'))))
$fn$;

alter table sucursales add column if not exists horario jsonb;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'sucursales_horario_valido') then
    alter table sucursales add constraint sucursales_horario_valido check (app.horario_valido(horario));
  end if;
end $$;
grant update (horario) on sucursales to authenticated;

create or replace function app.abierta_ahora(p_horario jsonb, p_tz text)
returns boolean
language plpgsql stable as $fn$
declare
  v_ahora timestamp := now() at time zone p_tz;
  v_hoy jsonb; v_ayer jsonb; t time := v_ahora::time;
begin
  if p_horario is null then return null; end if;
  v_hoy  := p_horario -> extract(dow from v_ahora)::int::text;
  v_ayer := p_horario -> ((extract(dow from v_ahora)::int + 6) % 7)::text;
  -- lo que abrió ayer y cierra pasada la medianoche
  if jsonb_typeof(v_ayer) = 'object' and (v_ayer->>'cierra')::time < (v_ayer->>'abre')::time
     and t < (v_ayer->>'cierra')::time then return true; end if;
  if jsonb_typeof(v_hoy) <> 'object' then return false; end if;
  if (v_hoy->>'cierra')::time > (v_hoy->>'abre')::time then
    return t >= (v_hoy->>'abre')::time and t < (v_hoy->>'cierra')::time;
  end if;
  return t >= (v_hoy->>'abre')::time;
end $fn$;

-- Las tiendas para la app del cliente, con horario y si está abierta. Es la
-- misma lista de fn_tiendas_disponibles (su tipo de retorno no se puede
-- cambiar sin drop) más esas dos cosas.
create or replace function fn_tiendas_cerca(p_busqueda text default null)
returns jsonb
language sql stable security definer set search_path = public, app as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'organizacion_id', t.organizacion_id, 'negocio', t.negocio,
           'sucursal_id', t.sucursal_id, 'sucursal', t.sucursal, 'direccion', t.direccion,
           'telefono', t.telefono, 'moneda', t.moneda, 'acepta_domicilio', t.acepta_domicilio,
           'costo_envio', t.costo_envio, 'pedido_minimo', t.pedido_minimo,
           'productos', t.productos, 'ya_soy_cliente', t.ya_soy_cliente,
           'horario', s.horario,
           'abierta', app.abierta_ahora(s.horario, app.zona(t.organizacion_id)))
         order by app.abierta_ahora(s.horario, app.zona(t.organizacion_id)) desc nulls last,
                  t.ya_soy_cliente desc, t.negocio), '[]'::jsonb)
    from fn_tiendas_disponibles(p_busqueda) t
    join sucursales s on s.id = t.sucursal_id
$fn$;
revoke execute on function fn_tiendas_cerca(text) from public, anon;
grant execute on function fn_tiendas_cerca(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Mi fiado (app del cliente): en cada tienda, cuánto debe, cuánto le
--    queda y sus últimos movimientos. Es su propia cuenta.
-- ---------------------------------------------------------------------------
create or replace function fn_mi_fiado()
returns jsonb
language sql stable security definer set search_path = public, app as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'negocio', o.nombre, 'moneda', o.moneda,
           'debe', coalesce(c.saldo, 0), 'limite', coalesce(c.limite_credito, 0),
           'disponible', greatest(coalesce(c.limite_credito, 0) - coalesce(c.saldo, 0), 0),
           'movimientos', coalesce((
             select jsonb_agg(jsonb_build_object('fecha', mm.fecha, 'tipo', mm.tipo,
                      'monto', mm.monto, 'numero', mm.numero) order by mm.fecha desc)
               from ((select v.creada_en as fecha, 'compra'::text as tipo,
                             (select coalesce(sum(pv.monto), 0) from pagos_venta pv
                               where pv.venta_id = v.id and pv.metodo = 'credito') as monto,
                             coalesce(v.numero_fiscal, v.numero) as numero
                        from ventas v
                       where v.cliente_id = c.id and v.es_credito and v.estado = 'completada')
                     union all
                     (select a.creado_en, 'abono', a.monto, null::text
                        from abonos_cliente a where a.cliente_id = c.id and not a.anulado)
                     order by 1 desc limit 15) mm), '[]'::jsonb))
         order by c.saldo desc, o.nombre), '[]'::jsonb)
    from clientes c join organizaciones o on o.id = c.organizacion_id
   where auth.uid() is not null and c.usuario_id = auth.uid() and c.activo
     and (coalesce(c.saldo, 0) > 0 or coalesce(c.limite_credito, 0) > 0)
$fn$;
revoke execute on function fn_mi_fiado() from public, anon;
grant execute on function fn_mi_fiado() to authenticated;

notify pgrst, 'reload schema';
