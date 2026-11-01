-- ============================================================================
--  050 · Contabilidad básica para el dueño
--
--  Lo que una pulpería necesita para cumplir y para saber cómo va, sin
--  catálogo de cuentas ni asientos (eso queda para los negocios grandes):
--
--   · ISV del período: el que se cobró en las ventas (menos devoluciones)
--     contra el que se pagó en las compras. Separado por tasa (15%, 18%) y
--     lo exento, como lo pide la declaración.
--   · Cuentas por cobrar: el fiado por antigüedad.
--   · Cuentas por pagar: lo que se les debe a los proveedores, vencido o no.
--   · Estado de resultados de los últimos 6 meses, para comparar.
--   · Libro de ventas y libro de compras del período, para el contador.
--
--  Todo lo ve el gerente (la utilidad y lo que se debe no es para el
--  supervisor). Período y sucursal como el resto de Finanzas
--  (app.finanzas_alcance).
--
--  Cómo se parte el ISV de una línea de venta:
--    impuesto incluido   base = total / (1 + tasa)   isv = total − base
--    sin incluir         base = total                isv = total × tasa
--  Compras: base = cantidad × (costo − descuento), isv = base × tasa (igual
--  que fn_confirmar_factura_compra).
-- ============================================================================

create or replace function app.partir_isv(p_total numeric, p_tasa numeric, p_incluido boolean,
                                          out base numeric, out isv numeric)
language sql immutable as $fn$
  select case when coalesce(p_incluido, true) then p_total / (1 + coalesce(p_tasa, 0)) else p_total end,
         case when coalesce(p_incluido, true) then p_total - p_total / (1 + coalesce(p_tasa, 0))
              else p_total * coalesce(p_tasa, 0) end
$fn$;
revoke execute on function app.partir_isv(numeric, numeric, boolean) from public, anon;
grant execute on function app.partir_isv(numeric, numeric, boolean) to authenticated;

-- La tasa como etiqueta: '0', '15', '18'
create or replace function app.tasa_txt(p_tasa numeric) returns text
language sql immutable as $fn$ select (round(coalesce(p_tasa, 0) * 100))::int::text $fn$;
revoke execute on function app.tasa_txt(numeric) from public, anon;
grant execute on function app.tasa_txt(numeric) to authenticated;


-- ---------------------------------------------------------------------------
-- 1. El resumen contable
-- ---------------------------------------------------------------------------
create or replace function fn_contabilidad(
  p_desde date default null, p_hasta date default null, p_sucursal_id uuid default null
) returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  a      record;
  v_tz   text;
  v_v    jsonb;   -- ventas por tasa
  v_d    jsonb;   -- devoluciones por tasa
  v_c    jsonb;   -- compras por tasa
  v_deb  numeric;
  v_cre  numeric;
  v_meses jsonb := '[]'::jsonb;
  m_ini  date;
  m_fin  date;
  t      jsonb;
  g      numeric;
  mer    numeric;
  i      int;
begin
  select * into a from app.finanzas_alcance(p_desde, p_hasta, p_sucursal_id);
  if not app.tiene_nivel('gerente') then raise exception 'La contabilidad es del gerente'; end if;
  v_tz := app.zona(a.v_org);

  -- ventas completadas del período, por tasa
  select coalesce(jsonb_object_agg(tasa, jsonb_build_object('base', round(base, 2), 'isv', round(isv, 2))), '{}'::jsonb)
    into v_v
    from (select app.tasa_txt(d.tasa_impuesto) as tasa,
                 sum((app.partir_isv(d.total, d.tasa_impuesto, d.impuesto_incluido)).base) as base,
                 sum((app.partir_isv(d.total, d.tasa_impuesto, d.impuesto_incluido)).isv) as isv
            from venta_detalle d join ventas v on v.id = d.venta_id
           where v.organizacion_id = a.v_org and v.sucursal_id = any(a.v_sucs) and v.estado = 'completada'
             and v.creada_en >= a.v_ini and v.creada_en < a.v_fin
           group by 1) x;

  -- devoluciones del período (restan, el día que se devolvió)
  select coalesce(jsonb_object_agg(tasa, jsonb_build_object('base', round(base, 2), 'isv', round(isv, 2))), '{}'::jsonb)
    into v_d
    from (select app.tasa_txt(d.tasa_impuesto) as tasa,
                 sum((app.partir_isv(d.total, d.tasa_impuesto, d.impuesto_incluido)).base) as base,
                 sum((app.partir_isv(d.total, d.tasa_impuesto, d.impuesto_incluido)).isv) as isv
            from devolucion_detalle d join devoluciones_venta dv on dv.id = d.devolucion_id
           where dv.organizacion_id = a.v_org and dv.sucursal_id = any(a.v_sucs)
             and dv.creada_en >= a.v_ini and dv.creada_en < a.v_fin
           group by 1) x;

  -- compras confirmadas con fecha de factura en el período
  select coalesce(jsonb_object_agg(tasa, jsonb_build_object('base', round(base, 2), 'isv', round(isv, 2))), '{}'::jsonb)
    into v_c
    from (select app.tasa_txt(d.tasa_impuesto) as tasa,
                 sum(d.cantidad * (d.costo_unitario - coalesce(d.descuento, 0))) as base,
                 sum(d.cantidad * (d.costo_unitario - coalesce(d.descuento, 0)) * d.tasa_impuesto) as isv
            from factura_compra_detalle d join facturas_compra f on f.id = d.factura_compra_id
           where f.organizacion_id = a.v_org and f.sucursal_id = any(a.v_sucs) and f.estado = 'confirmado'
             and f.fecha between a.v_d and a.v_h
           group by 1) x;

  select coalesce(sum((value ->> 'isv')::numeric), 0) into v_deb from jsonb_each(v_v);
  v_deb := v_deb - coalesce((select sum((value ->> 'isv')::numeric) from jsonb_each(v_d)), 0);
  select coalesce(sum((value ->> 'isv')::numeric), 0) into v_cre from jsonb_each(v_c);

  -- los últimos 6 meses (el del final del período y los 5 de antes)
  for i in reverse 5..0 loop
    m_ini := (date_trunc('month', a.v_h) - make_interval(months => i))::date;
    m_fin := least((m_ini + interval '1 month')::date - 1, a.v_hoy);
    t := app.tablero_totales(a.v_org, a.v_sucs, m_ini::timestamp at time zone v_tz, (m_fin + 1)::timestamp at time zone v_tz);
    select coalesce(sum(e.monto), 0) into g
      from egresos e join categorias_egreso c on c.id = e.categoria_id
     where e.organizacion_id = a.v_org and e.sucursal_id = any(a.v_sucs) and e.anulado_en is null
       and c.clase in ('operativo', 'financiero', 'impuesto') and e.fecha between m_ini and m_fin;
    mer := coalesce((fn_merma_resumen(m_ini, m_fin, p_sucursal_id) ->> 'total')::numeric, 0);
    v_meses := v_meses || jsonb_build_object(
      'mes', to_char(m_ini, 'YYYY-MM'),
      'venta_neta', round(coalesce((t ->> 'venta_sin_isv')::numeric, 0), 2),
      'costo', round(coalesce((t ->> 'costo')::numeric, 0), 2),
      'utilidad_bruta', round(coalesce((t ->> 'utilidad')::numeric, 0), 2),
      'merma', round(mer, 2),
      'gastos', round(g, 2),
      'utilidad_neta', round(coalesce((t ->> 'utilidad')::numeric, 0) - mer - g, 2));
  end loop;

  return jsonb_build_object(
    'desde', a.v_d, 'hasta', a.v_h,
    'isv', jsonb_build_object(
      'ventas', v_v, 'devoluciones', v_d, 'compras', v_c,
      'debito', round(v_deb, 2), 'credito', round(v_cre, 2),
      'a_pagar', round(greatest(v_deb - v_cre, 0), 2),
      'a_favor', round(greatest(v_cre - v_deb, 0), 2)),
    'cxc', (select jsonb_build_object(
        'total', round(coalesce(sum(debe), 0), 2),
        'clientes', count(*),
        'corriente', round(coalesce(sum(debe) filter (where coalesce(dias, 0) <= 30), 0), 2),
        'd31_60', round(coalesce(sum(debe) filter (where dias between 31 and 60), 0), 2),
        'd61_90', round(coalesce(sum(debe) filter (where dias between 61 and 90), 0), 2),
        'mas_90', round(coalesce(sum(debe) filter (where dias > 90), 0), 2),
        'atrasados', count(*) filter (where atrasado),
        'mayores', coalesce((select jsonb_agg(jsonb_build_object('cliente', cliente, 'debe', round(debe, 2), 'dias', dias, 'atrasado', atrasado) order by debe desc)
                               from (select * from v_fiado where organizacion_id = a.v_org and debe > 0 order by debe desc limit 8) y), '[]'::jsonb))
      from v_fiado where organizacion_id = a.v_org and debe > 0),
    'cxp', (select jsonb_build_object(
        'total', round(coalesce(sum(f.saldo), 0), 2),
        'facturas', count(*),
        'por_vencer', round(coalesce(sum(f.saldo) filter (where coalesce(f.fecha_vencimiento, f.fecha) >= a.v_hoy), 0), 2),
        'v1_30', round(coalesce(sum(f.saldo) filter (where a.v_hoy - coalesce(f.fecha_vencimiento, f.fecha) between 1 and 30), 0), 2),
        'v31_60', round(coalesce(sum(f.saldo) filter (where a.v_hoy - coalesce(f.fecha_vencimiento, f.fecha) between 31 and 60), 0), 2),
        'mas_60', round(coalesce(sum(f.saldo) filter (where a.v_hoy - coalesce(f.fecha_vencimiento, f.fecha) > 60), 0), 2),
        'proveedores', coalesce((select jsonb_agg(jsonb_build_object('proveedor', p.nombre, 'debe', round(x.debe, 2),
                                  'facturas', x.n, 'vencido', round(x.vencido, 2), 'proxima', x.proxima) order by x.debe desc)
            from (select f2.proveedor_id, sum(f2.saldo) as debe, count(*) as n,
                         sum(f2.saldo) filter (where coalesce(f2.fecha_vencimiento, f2.fecha) < a.v_hoy) as vencido,
                         min(coalesce(f2.fecha_vencimiento, f2.fecha)) filter (where coalesce(f2.fecha_vencimiento, f2.fecha) >= a.v_hoy) as proxima
                    from facturas_compra f2
                   where f2.organizacion_id = a.v_org and f2.sucursal_id = any(a.v_sucs)
                     and f2.estado = 'confirmado' and f2.saldo > 0
                   group by f2.proveedor_id) x
            left join proveedores p on p.id = x.proveedor_id), '[]'::jsonb))
      from facturas_compra f
     where f.organizacion_id = a.v_org and f.sucursal_id = any(a.v_sucs)
       and f.estado = 'confirmado' and f.saldo > 0),
    'meses', v_meses);
end $fn$;


-- ---------------------------------------------------------------------------
-- 2. Libro de ventas y libro de compras (para el contador)
-- ---------------------------------------------------------------------------
create or replace function fn_libro_ventas(
  p_desde date default null, p_hasta date default null, p_sucursal_id uuid default null
) returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare a record;
begin
  select * into a from app.finanzas_alcance(p_desde, p_hasta, p_sucursal_id);
  if not app.tiene_nivel('gerente') then raise exception 'La contabilidad es del gerente'; end if;
  return coalesce((
    select jsonb_agg(r order by r ->> 'fecha', r ->> 'numero')
    from (
      select jsonb_build_object(
        'fecha', (v.creada_en at time zone app.zona(a.v_org))::date,
        'numero', v.numero, 'documento', v.tipo_documento, 'numero_fiscal', v.numero_fiscal, 'cai', v.cai,
        'cliente', coalesce(c.nombre, 'Consumidor final'), 'rtn', c.identificacion_fiscal,
        'estado', v.estado,
        'exento',  round(coalesce(sum(p.base) filter (where p.tasa = '0'), 0), 2),
        'base_15', round(coalesce(sum(p.base) filter (where p.tasa = '15'), 0), 2),
        'isv_15',  round(coalesce(sum(p.isv)  filter (where p.tasa = '15'), 0), 2),
        'base_18', round(coalesce(sum(p.base) filter (where p.tasa = '18'), 0), 2),
        'isv_18',  round(coalesce(sum(p.isv)  filter (where p.tasa = '18'), 0), 2),
        'total', round(v.total, 2)) as r
      from ventas v
      left join clientes c on c.id = v.cliente_id
      left join lateral (select app.tasa_txt(d.tasa_impuesto) as tasa,
                                (app.partir_isv(d.total, d.tasa_impuesto, d.impuesto_incluido)).base as base,
                                (app.partir_isv(d.total, d.tasa_impuesto, d.impuesto_incluido)).isv as isv
                           from venta_detalle d where d.venta_id = v.id) p on true
      where v.organizacion_id = a.v_org and v.sucursal_id = any(a.v_sucs)
        and v.creada_en >= a.v_ini and v.creada_en < a.v_fin
      group by v.id, c.id
      limit 20000
    ) x), '[]'::jsonb);
end $fn$;

create or replace function fn_libro_compras(
  p_desde date default null, p_hasta date default null, p_sucursal_id uuid default null
) returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare a record;
begin
  select * into a from app.finanzas_alcance(p_desde, p_hasta, p_sucursal_id);
  if not app.tiene_nivel('gerente') then raise exception 'La contabilidad es del gerente'; end if;
  return coalesce((
    select jsonb_agg(r order by r ->> 'fecha', r ->> 'numero')
    from (
      select jsonb_build_object(
        'fecha', f.fecha, 'numero', f.numero, 'cai', f.cai_proveedor,
        'proveedor', pr.nombre, 'rtn', pr.identificacion_fiscal, 'estado', f.estado,
        'exento',  round(coalesce(sum(b.base) filter (where b.tasa = '0'), 0), 2),
        'base_15', round(coalesce(sum(b.base) filter (where b.tasa = '15'), 0), 2),
        'isv_15',  round(coalesce(sum(b.base * 0.15) filter (where b.tasa = '15'), 0), 2),
        'base_18', round(coalesce(sum(b.base) filter (where b.tasa = '18'), 0), 2),
        'isv_18',  round(coalesce(sum(b.base * 0.18) filter (where b.tasa = '18'), 0), 2),
        'total', round(f.total, 2), 'saldo', round(f.saldo, 2), 'vence', f.fecha_vencimiento) as r
      from facturas_compra f
      left join proveedores pr on pr.id = f.proveedor_id
      left join lateral (select app.tasa_txt(d.tasa_impuesto) as tasa,
                                d.cantidad * (d.costo_unitario - coalesce(d.descuento, 0)) as base
                           from factura_compra_detalle d where d.factura_compra_id = f.id) b on true
      where f.organizacion_id = a.v_org and f.sucursal_id = any(a.v_sucs)
        and f.estado in ('confirmado', 'anulado') and f.fecha between a.v_d and a.v_h
      group by f.id, pr.id
    ) x), '[]'::jsonb);
end $fn$;

revoke execute on function fn_contabilidad(date, date, uuid) from public, anon;
revoke execute on function fn_libro_ventas(date, date, uuid) from public, anon;
revoke execute on function fn_libro_compras(date, date, uuid) from public, anon;
grant execute on function fn_contabilidad(date, date, uuid) to authenticated;
grant execute on function fn_libro_ventas(date, date, uuid) to authenticated;
grant execute on function fn_libro_compras(date, date, uuid) to authenticated;
