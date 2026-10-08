-- ============================================================================
--  017 · Historial de ventas, y dos agujeros en la anulacion
--
--  La caja no tenia historial: no habia forma de ver lo vendido, reimprimir un
--  ticket, ni corregir un cobro equivocado. fn_anular_venta existia desde la
--  002b pero sin pantalla, y al ir a dársela aparecieron dos defectos.
--
--  1) CUALQUIER SUPERVISOR PODIA ANULAR LA VENTA DE CUALQUIER NEGOCIO
--
--     El unico permiso era:
--
--         if not (app.tiene_nivel('supervisor') or app.es_admin()) then
--
--     y app.tiene_nivel solo mira el nivel del rol de quien llama; no mira a
--     que negocio pertenece la venta. Probado: el supervisor de la pulperia
--     rival anulo una venta ajena pasando su uuid. Eso devuelve mercaderia al
--     inventario de otro, le borra la deuda a su clienta y le mueve los
--     numeros del dia. Es el mismo descuido que ya se cerro en compras (006) y
--     en el fiado (012); aqui seguia abierto.
--
--  2) AL ANULAR SE LE RESTABA AL CLIENTE EL TOTAL, NO LO FIADO
--
--         update clientes set saldo = greatest(saldo - v.total, 0)
--
--     En una venta mixta -L60 en efectivo y L120 fiados- el total es L180 pero
--     el cliente solo quedo debiendo L120. Anularla le bajaba la deuda L180:
--     L60 de regalo, y el greatest(...,0) lo tapaba cuando el saldo era chico.
--     Mismo error que ya se corrigio en el estado de cuenta y en v_fiado.
--
--  La anulacion de una factura fiscal se deja pasar como hasta ahora. Lo
--  correcto seria una nota de credito, pero eso no existe todavia y bloquearla
--  dejaria al negocio sin forma de arreglar un error. Queda anotado quien
--  anulo, cuando y por que, y el correlativo fiscal no se reusa.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Anular una venta, ahora dentro de su negocio y por el monto correcto
-- ---------------------------------------------------------------------------

create or replace function fn_anular_venta(p_venta_id uuid, p_motivo text)
returns void
language plpgsql security definer set search_path = public, app as $fn$
declare
  v        record;
  l        record;
  v_fiado  numeric;
begin
  if p_motivo is null or btrim(p_motivo) = '' then
    raise exception 'Anular una venta exige un motivo';
  end if;

  select * into v from ventas where id = p_venta_id for update;
  if v.id is null then raise exception 'Venta inexistente'; end if;
  if v.estado = 'anulada' then raise exception 'La venta ya esta anulada'; end if;

  -- La venta tiene que ser de SU negocio. Sin esto el supervisor de cualquier
  -- pulperia anulaba las ventas de las demas.
  if not (app.es_admin()
          or (v.organizacion_id = app.org_id() and app.tiene_nivel('supervisor'))) then
    raise exception 'Solo un supervisor de este negocio puede anular ventas';
  end if;

  for l in select * from venta_detalle where venta_id = p_venta_id loop
    -- Los servicios -el envio- no tienen existencia que devolver.
    if exists (select 1 from productos p
                where p.id = l.producto_id and p.tipo <> 'servicio') then
      perform fn_kardex_registrar(v.sucursal_id, l.producto_id, 'devolucion_venta',
                                  l.cantidad, l.costo_unitario, l.lote_id,
                                  'anulacion_venta', v.id,
                                  'Anulacion ' || v.numero, auth.uid());
    end if;
  end loop;

  -- Se le devuelve lo que QUEDO FIADO, no el total de la venta.
  if v.cliente_id is not null then
    select coalesce(sum(pv.monto), 0) into v_fiado
    from pagos_venta pv
    where pv.venta_id = p_venta_id and pv.metodo = 'credito';

    if v_fiado > 0 then
      update clientes
         set saldo = greatest(saldo - v_fiado, 0), actualizado_en = now()
       where id = v.cliente_id;
    end if;
  end if;

  update ventas
     set estado = 'anulada', anulada_por = auth.uid(),
         anulada_en = now(), motivo_anulacion = btrim(p_motivo)
   where id = p_venta_id;
end $fn$;

revoke execute on function fn_anular_venta(uuid, text) from public, anon;
grant execute on function fn_anular_venta(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 2. El historial
--
--    El costo y la ganancia solo salen para supervisor en adelante: una
--    auxiliar ve lo que vendio, no a como lo compro el dueño. Es la misma
--    linea que ya se trazo en compras.
-- ---------------------------------------------------------------------------

create or replace function fn_historial_ventas(
  p_desde       date default null,
  p_hasta       date default null,
  p_sucursal_id uuid default null,
  p_buscar      text default null,
  p_estado      text default null,     -- completada · anulada · null = todas
  p_limite      int  default 100
)
returns table (
  venta_id     uuid,
  numero       text,
  numero_fiscal text,
  documento    text,
  creada_en    timestamptz,
  sucursal     text,
  caja         text,
  cajero       text,
  cliente      text,
  total        numeric,
  costo        numeric,
  ganancia     numeric,
  es_credito   boolean,
  estado       text,
  metodos      text,
  lineas       int,
  anulada_por  text,
  motivo       text
)
language sql stable security definer set search_path = public, app as $fn$
  with permiso as (
    select app.tiene_nivel('supervisor') as ve_costos,
           app.tiene_nivel('auxiliar')   as entra
  )
  select
    v.id, v.numero, v.numero_fiscal, v.tipo_documento::text, v.creada_en,
    s.nombre, cj.nombre, pf.nombre, cl.nombre,
    v.total,
    case when p.ve_costos then v.costo_total end,
    case when p.ve_costos then round(v.total - v.impuesto - v.costo_total, 2) end,
    v.es_credito, v.estado::text,
    (select string_agg(distinct pv.metodo::text, ', ') from pagos_venta pv
      where pv.venta_id = v.id),
    (select count(*)::int from venta_detalle d where d.venta_id = v.id),
    ap.nombre, v.motivo_anulacion
  from ventas v
  cross join permiso p
  join sucursales s       on s.id = v.sucursal_id
  left join cajas cj      on cj.id = v.caja_id
  left join perfiles pf   on pf.id = v.cajero_id
  left join clientes cl   on cl.id = v.cliente_id
  left join perfiles ap   on ap.id = v.anulada_por
  where p.entra
    and v.organizacion_id = app.org_id()
    and v.sucursal_id in (select app.sucursales_permitidas())
    and (p_sucursal_id is null or v.sucursal_id = p_sucursal_id)
    and (p_desde is null or v.creada_en >= p_desde::timestamptz)
    and (p_hasta is null or v.creada_en < (p_hasta + 1)::timestamptz)
    and (p_estado is null or v.estado::text = p_estado)
    and (p_buscar is null or btrim(p_buscar) = ''
         or v.numero ilike '%' || btrim(p_buscar) || '%'
         or coalesce(v.numero_fiscal,'') ilike '%' || btrim(p_buscar) || '%'
         or coalesce(cl.nombre,'') ilike '%' || btrim(p_buscar) || '%')
  order by v.creada_en desc
  limit greatest(coalesce(p_limite, 100), 1)
$fn$;

revoke execute on function fn_historial_ventas(date, date, uuid, text, text, int)
  from public, anon;
grant execute on function fn_historial_ventas(date, date, uuid, text, text, int)
  to authenticated;


-- ---------------------------------------------------------------------------
-- 3. Una venta completa, para reimprimir el ticket
-- ---------------------------------------------------------------------------

create or replace function fn_venta_completa(p_venta_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v    record;
  o    record;
  v_ve_costos boolean;
  v_res jsonb;
begin
  select * into v from ventas where id = p_venta_id;
  if v.id is null then raise exception 'Venta inexistente'; end if;

  if not (app.es_admin()
          or (v.organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))) then
    raise exception 'Esa venta no es de este negocio';
  end if;

  select * into o from organizaciones where id = v.organizacion_id;
  v_ve_costos := app.tiene_nivel('supervisor') or app.es_admin();

  select jsonb_build_object(
    'venta', jsonb_build_object(
      'id', v.id, 'numero', v.numero, 'numero_fiscal', v.numero_fiscal,
      'cai', v.cai, 'documento', v.tipo_documento, 'creada_en', v.creada_en,
      'subtotal', v.subtotal, 'impuesto', v.impuesto, 'descuento', v.descuento,
      'total', v.total, 'es_credito', v.es_credito, 'estado', v.estado,
      'motivo_anulacion', v.motivo_anulacion, 'anulada_en', v.anulada_en,
      'costo', case when v_ve_costos then v.costo_total end,
      'anulada_por', (select nombre from perfiles where id = v.anulada_por)
    ),
    'negocio', jsonb_build_object(
      'nombre', o.nombre, 'rtn', o.identificacion_fiscal, 'moneda', o.moneda),
    'sucursal', (select jsonb_build_object('nombre', s.nombre, 'direccion', s.direccion,
                        'telefono', s.telefono)
                   from sucursales s where s.id = v.sucursal_id),
    'caja',    (select nombre from cajas where id = v.caja_id),
    'cajero',  (select nombre from perfiles where id = v.cajero_id),
    'cliente', (select jsonb_build_object('nombre', c.nombre, 'telefono', c.telefono,
                       'rtn', c.identificacion_fiscal)
                  from clientes c where c.id = v.cliente_id),
    'lineas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'producto', pr.nombre,
               'cantidad', d.cantidad,
               'precio',   d.precio_unitario,
               'descuento', d.descuento,
               'total',    d.total,
               'costo',    case when v_ve_costos then d.costo_unitario end)
             order by pr.nombre)
      from venta_detalle d join productos pr on pr.id = d.producto_id
      where d.venta_id = v.id), '[]'::jsonb),
    'pagos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'metodo', pv.metodo, 'monto', pv.monto,
               'recibido', pv.recibido, 'cambio', pv.cambio,
               'referencia', pv.referencia) order by pv.creado_en)
      from pagos_venta pv where pv.venta_id = v.id), '[]'::jsonb)
  ) into v_res;

  return v_res;
end $fn$;

revoke execute on function fn_venta_completa(uuid) from public, anon;
grant execute on function fn_venta_completa(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. El resumen del periodo que se esta viendo
-- ---------------------------------------------------------------------------

create or replace function fn_ventas_resumen(
  p_desde       date default null,
  p_hasta       date default null,
  p_sucursal_id uuid default null
) returns jsonb
language sql stable security definer set search_path = public, app as $fn$
  with alcance as (
    select ve.id, ve.total, ve.impuesto, ve.costo_total, ve.es_credito, ve.estado
    from ventas ve
    where app.tiene_nivel('auxiliar')
      and ve.organizacion_id = app.org_id()
      and ve.sucursal_id in (select app.sucursales_permitidas())
      and (p_sucursal_id is null or ve.sucursal_id = p_sucursal_id)
      and (p_desde is null or ve.creada_en >= p_desde::timestamptz)
      and (p_hasta is null or ve.creada_en < (p_hasta + 1)::timestamptz)
  ),
  -- El efectivo se suma de los pagos, no de los totales: una venta mixta
  -- aporta solo su parte en efectivo.
  efectivo as (
    select coalesce(sum(pv.monto), 0) as monto
    from pagos_venta pv
    join alcance a on a.id = pv.venta_id and a.estado = 'completada'
    where pv.metodo = 'efectivo'
  ),
  fiado as (
    select coalesce(sum(pv.monto), 0) as monto
    from pagos_venta pv
    join alcance a on a.id = pv.venta_id and a.estado = 'completada'
    where pv.metodo = 'credito'
  )
  select jsonb_build_object(
    'ventas',        count(*) filter (where a.estado = 'completada'),
    'total',         coalesce(sum(a.total) filter (where a.estado = 'completada'), 0),
    'efectivo',      (select monto from efectivo),
    'fiado',         (select monto from fiado),
    'anuladas',      count(*) filter (where a.estado = 'anulada'),
    'monto_anulado', coalesce(sum(a.total) filter (where a.estado = 'anulada'), 0),
    'ganancia',      case when app.tiene_nivel('supervisor')
                          then coalesce(sum(a.total - a.impuesto - a.costo_total)
                                        filter (where a.estado = 'completada'), 0) end
  )
  from alcance a
$fn$;

revoke execute on function fn_ventas_resumen(date, date, uuid) from public, anon;
grant execute on function fn_ventas_resumen(date, date, uuid) to authenticated;
