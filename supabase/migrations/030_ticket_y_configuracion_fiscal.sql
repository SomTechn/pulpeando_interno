-- ===========================================================================
-- 030 · Ticket impreso y configuracion fiscal
--
-- 1. fn_venta_completa trae todo lo que la factura de la SAR exige impreso:
--    rango autorizado y fecha limite de emision del CAI, el desglose de
--    importe exento / gravado 15% / gravado 18% con su ISV, el RTN del
--    emisor y del cliente, y los datos del pie del ticket.
--
-- 2. Los rangos de facturacion (CAI) no se pueden manipular:
--    · el correlativo solo avanza; nunca retrocede (dos facturas con el
--      mismo numero son un problema con la SAR)
--    · un rango ya usado no cambia de CAI, prefijo ni limites, y no se borra
--    · al crear un rango el correlativo arranca en el inicial
--    · formatos: prefijo 000-001-01, CAI XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XX
--    · dos rangos del mismo negocio con el mismo prefijo no se enciman
--
-- 3. El gerente edita los datos de SU negocio, pero no el plan ni si la
--    cuenta esta activa: eso es del dueño del SaaS (admin). Hasta ahora la
--    politica de UPDATE se lo permitia.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. Candados de los rangos de facturacion
-- ---------------------------------------------------------------------------
create or replace function app.series_fiscales_candado()
returns trigger language plpgsql set search_path = public, app as $fn$
declare
  v_usado boolean;
begin
  if tg_op = 'DELETE' then
    if old.correlativo_actual > old.correlativo_inicial then
      raise exception 'Ese rango ya se usó en % factura(s): no se borra. Desactívelo', old.correlativo_actual - old.correlativo_inicial;
    end if;
    return old;
  end if;

  new.cai     := nullif(upper(btrim(coalesce(new.cai, ''))), '');
  new.prefijo := btrim(new.prefijo);

  if new.prefijo !~ '^[0-9]{3}-[0-9]{3}-[0-9]{2}$' then
    raise exception 'El prefijo debe tener la forma 000-001-01 (establecimiento-punto de emisión-tipo de documento)';
  end if;
  if new.tipo_documento = 'factura' and new.cai is null then
    raise exception 'Un rango de facturas necesita su CAI';
  end if;
  if new.cai is not null and new.cai !~ '^[0-9A-F]{6}(-[0-9A-F]{6}){4}-[0-9A-F]{2}$' then
    raise exception 'El CAI debe tener la forma XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XX (letras A-F y números)';
  end if;
  if new.correlativo_inicial < 1 or new.correlativo_final < new.correlativo_inicial then
    raise exception 'El rango está al revés: el número final debe ser mayor o igual al inicial';
  end if;
  if new.correlativo_final > 99999999 then
    raise exception 'El correlativo tiene 8 dígitos: el final no puede pasar de 99999999';
  end if;

  if tg_op = 'INSERT' then
    new.correlativo_actual := new.correlativo_inicial;
  else
    v_usado := old.correlativo_actual > old.correlativo_inicial;

    if new.correlativo_actual < old.correlativo_actual then
      raise exception 'El correlativo no puede retroceder: repetiría números de factura ya emitidos';
    end if;
    if v_usado and (new.cai is distinct from old.cai
                    or new.prefijo is distinct from old.prefijo
                    or new.correlativo_inicial <> old.correlativo_inicial
                    or new.tipo_documento <> old.tipo_documento
                    or new.sucursal_id <> old.sucursal_id) then
      raise exception 'Ese rango ya se usó: no se le cambia el CAI, el prefijo, el inicio ni la sucursal. Cree un rango nuevo';
    end if;
    if new.correlativo_final < old.correlativo_actual - 1 then
      raise exception 'El final no puede quedar antes de la última factura emitida (%)', old.correlativo_actual - 1;
    end if;
    -- Solo la venta mueve el correlativo, y de uno en uno
    if new.correlativo_actual <> old.correlativo_actual
       and new.correlativo_actual <> old.correlativo_actual + 1 then
      raise exception 'El correlativo avanza solo al facturar';
    end if;
  end if;

  if exists (select 1 from series_fiscales s
              where s.organizacion_id = new.organizacion_id
                and s.prefijo = new.prefijo
                and s.id <> new.id
                and int8range(s.correlativo_inicial, s.correlativo_final, '[]')
                    && int8range(new.correlativo_inicial, new.correlativo_final, '[]')) then
    raise exception 'Ese rango se encima con otro del mismo prefijo';
  end if;

  return new;
end $fn$;

drop trigger if exists tg_series_fiscales_candado on series_fiscales;
create trigger tg_series_fiscales_candado
  before insert or update or delete on series_fiscales
  for each row execute function app.series_fiscales_candado();


-- ---------------------------------------------------------------------------
-- 2. El plan y la cuenta activa son del admin
-- ---------------------------------------------------------------------------
create or replace function app.organizaciones_candado()
returns trigger language plpgsql set search_path = public, app as $fn$
begin
  if not app.es_admin() then
    if new.plan is distinct from old.plan or new.activa is distinct from old.activa then
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

drop trigger if exists tg_organizaciones_candado on organizaciones;
create trigger tg_organizaciones_candado
  before update on organizaciones
  for each row execute function app.organizaciones_candado();


-- ---------------------------------------------------------------------------
-- 3. La venta completa, con lo que pide la factura
-- ---------------------------------------------------------------------------
create or replace function fn_venta_completa(p_venta_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v    record;
  o    record;
  s    record;
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

  -- El rango del que salio la factura: mismo CAI y mismo prefijo
  if v.numero_fiscal is not null then
    select * into s from series_fiscales sf
     where sf.organizacion_id = v.organizacion_id
       and sf.cai is not distinct from v.cai
       and v.numero_fiscal like sf.prefijo || '-%'
     order by sf.creada_en desc limit 1;
  end if;

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
    'rango', case when s.id is not null then jsonb_build_object(
      'desde', s.prefijo || '-' || lpad(s.correlativo_inicial::text, 8, '0'),
      'hasta', s.prefijo || '-' || lpad(s.correlativo_final::text, 8, '0'),
      'fecha_limite', s.fecha_limite_emision) end,
    'negocio', jsonb_build_object(
      'nombre', o.nombre, 'rtn', o.identificacion_fiscal, 'moneda', o.moneda,
      'razon_social', o.config->>'razon_social',
      'direccion', o.config->>'direccion_fiscal',
      'telefono', o.config->>'telefono',
      'correo', o.config->>'correo',
      'mensaje_ticket', o.config->>'mensaje_ticket',
      'ancho_ticket', coalesce((o.config->>'ancho_ticket')::int, 80)),
    'sucursal', (select jsonb_build_object('nombre', su.nombre, 'direccion', su.direccion,
                        'telefono', su.telefono)
                   from sucursales su where su.id = v.sucursal_id),
    'caja',    (select nombre from cajas where id = v.caja_id),
    'cajero',  (select nombre from perfiles where id = v.cajero_id),
    'cliente', (select jsonb_build_object('nombre', c.nombre, 'telefono', c.telefono,
                       'rtn', c.identificacion_fiscal)
                  from clientes c where c.id = v.cliente_id),
    'desglose', (
      select jsonb_build_object(
        'exento',    round(coalesce(sum(d.total) filter (where d.tasa_impuesto = 0), 0), 2),
        'gravado15', round(coalesce(sum(case when d.impuesto_incluido then d.total / (1 + d.tasa_impuesto) else d.total end)
                                    filter (where d.tasa_impuesto between 0.149 and 0.151), 0), 2),
        'isv15',     round(coalesce(sum(case when d.impuesto_incluido then d.total - d.total / (1 + d.tasa_impuesto) else d.total * d.tasa_impuesto end)
                                    filter (where d.tasa_impuesto between 0.149 and 0.151), 0), 2),
        'gravado18', round(coalesce(sum(case when d.impuesto_incluido then d.total / (1 + d.tasa_impuesto) else d.total end)
                                    filter (where d.tasa_impuesto between 0.179 and 0.181), 0), 2),
        'isv18',     round(coalesce(sum(case when d.impuesto_incluido then d.total - d.total / (1 + d.tasa_impuesto) else d.total * d.tasa_impuesto end)
                                    filter (where d.tasa_impuesto between 0.179 and 0.181), 0), 2))
      from venta_detalle d where d.venta_id = v.id),
    'lineas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'producto', pr.nombre,
               'sku', pr.sku,
               'cantidad', d.cantidad,
               'precio',   d.precio_unitario,
               'descuento', d.descuento,
               'total',    d.total,
               'tasa',     d.tasa_impuesto,
               'exento',   d.tasa_impuesto = 0,
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
-- 4. Estado de la facturacion: lo que queda de cada rango
--    La caja lo usa para avisar antes de que se acabe o venza el CAI.
-- ---------------------------------------------------------------------------
create or replace function fn_estado_facturacion(p_sucursal_id uuid default null)
returns jsonb
language sql stable security definer set search_path = public, app as $fn$
  select jsonb_build_object(
    'activa', (select facturacion_fiscal_activa from organizaciones where id = app.org_id()),
    'rangos', coalesce(jsonb_agg(jsonb_build_object(
       'id', s.id, 'sucursal_id', s.sucursal_id,
       'sucursal', (select nombre from sucursales where id = s.sucursal_id),
       'tipo', s.tipo_documento, 'cai', s.cai, 'prefijo', s.prefijo,
       'inicial', s.correlativo_inicial, 'final', s.correlativo_final,
       'siguiente', s.correlativo_actual,
       'usadas', s.correlativo_actual - s.correlativo_inicial,
       'quedan', greatest(s.correlativo_final - s.correlativo_actual + 1, 0),
       'fecha_limite', s.fecha_limite_emision,
       'dias', case when s.fecha_limite_emision is not null
                    then s.fecha_limite_emision - (now() at time zone app.zona())::date end,
       'activa', s.activa,
       'vigente', s.activa and s.correlativo_actual <= s.correlativo_final
                  and (s.fecha_limite_emision is null
                       or s.fecha_limite_emision >= (now() at time zone app.zona())::date))
       order by s.sucursal_id, s.creada_en), '[]'::jsonb))
  from series_fiscales s
  where s.organizacion_id = app.org_id()
    and (app.tiene_nivel('auxiliar') or app.es_admin())
    and (p_sucursal_id is null or s.sucursal_id = p_sucursal_id)
$fn$;

revoke execute on function fn_estado_facturacion(uuid) from public, anon;
grant execute on function fn_estado_facturacion(uuid) to authenticated;

notify pgrst, 'reload schema';
