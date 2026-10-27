-- ===========================================================================
-- 032 · Devolucion parcial de una venta
--
-- Hasta ahora solo se podia anular la venta entera. En el mostrador lo comun
-- es otra cosa: "la leche vino vencida", "me cobro dos y era una". Se
-- devuelven ALGUNAS lineas, o parte de una.
--
-- Una devolucion:
--   · regresa la mercaderia al kardex (devolucion_venta) al MISMO costo al
--     que salio, para que el costo promedio no se mueva por la devolucion
--   · si la venta fue fiada, primero se le rebaja la deuda al cliente (hasta
--     lo que quedo fiado de esa venta); lo demas se le devuelve
--   · lo que se devuelve en efectivo sale de un turno de caja abierto y el
--     arqueo lo descuenta: si no, la caja apareceria con sobrante
--   · si la venta fue factura, la devolucion lleva NOTA DE CREDITO con su
--     propio rango autorizado (tipo 03). Sin rango vigente se registra igual
--     y avisa: el gerente debe registrar el rango de notas de credito.
--   · no se puede devolver mas de lo vendido, contando devoluciones previas
--   · una venta con devoluciones ya no se anula entera (se devolveria dos
--     veces lo mismo): se devuelve lo que quede
--
-- Permiso: supervisor en adelante, igual que anular.
-- ===========================================================================

create table if not exists devoluciones_venta (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  sucursal_id      uuid not null references sucursales(id),
  venta_id         uuid not null references ventas(id),
  turno_id         uuid references turnos_caja(id),
  numero           text not null,
  tipo_documento   tipo_documento_fiscal not null default 'ticket',
  numero_fiscal    text,
  cai              text,
  motivo           text not null,
  subtotal         numeric(16,4) not null default 0,
  impuesto         numeric(16,4) not null default 0,
  total            numeric(16,4) not null default 0,
  rebaja_fiado     numeric(16,4) not null default 0,
  reembolso        numeric(16,4) not null default 0,
  reembolso_metodo metodo_pago,
  creada_por       uuid references perfiles(id),
  creada_en        timestamptz not null default now(),
  unique (organizacion_id, numero)
);

create table if not exists devolucion_detalle (
  id                uuid primary key default gen_random_uuid(),
  organizacion_id   uuid not null references organizaciones(id) on delete cascade,
  devolucion_id     uuid not null references devoluciones_venta(id) on delete cascade,
  venta_detalle_id  uuid not null references venta_detalle(id),
  producto_id       uuid not null references productos(id),
  cantidad          numeric(14,3) not null check (cantidad > 0),
  precio_unitario   numeric(14,4) not null,
  tasa_impuesto     numeric(6,4) not null default 0,
  impuesto_incluido boolean not null default true,
  costo_unitario    numeric(14,4) not null default 0,
  total             numeric(16,4) not null
);

create index if not exists ix_devoluciones_venta on devoluciones_venta (venta_id);
create index if not exists ix_devoluciones_turno on devoluciones_venta (turno_id);
create index if not exists ix_devdet_linea on devolucion_detalle (venta_detalle_id);

alter table devoluciones_venta enable row level security;
alter table devolucion_detalle enable row level security;

-- La politica se crea solo si falta, en vez de soltarla y rehacerla. Queda
-- igual de idempotente y deja de ser una sentencia destructiva, que es lo que
-- frena la herramienta de Supabase al aplicar migraciones.
do $pol$ begin
  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'devoluciones_venta'
                    and policyname = 'devoluciones_sel') then
    execute $crea$create policy devoluciones_sel on devoluciones_venta for select
      using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar')) or app.es_admin())$crea$;
  end if;
end $pol$;
do $pol$ begin
  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'devolucion_detalle'
                    and policyname = 'devdet_sel') then
    execute $crea$create policy devdet_sel on devolucion_detalle for select
      using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar')) or app.es_admin())$crea$;
  end if;
end $pol$;

-- Solo se escriben por fn_devolver_venta
revoke insert, update, delete on devoluciones_venta, devolucion_detalle from authenticated, anon;
-- anon no lee ni aunque RLS lo tape: es la regla de todas las tablas de dinero
-- de este sistema, y Supabase concede el select por defecto si no se revoca.
revoke select on devoluciones_venta, devolucion_detalle from anon;
grant select on devoluciones_venta, devolucion_detalle to authenticated;


-- ---------------------------------------------------------------------------
-- Notas de credito tambien llevan CAI: el candado de los rangos lo exige a
-- todo lo que no sea ticket interno (antes solo a facturas).
-- ---------------------------------------------------------------------------
create or replace function app.series_fiscales_candado()
returns trigger language plpgsql set search_path = public, app as $fn$
declare
  v_usado boolean;
begin
  if tg_op = 'DELETE' then
    if old.correlativo_actual > old.correlativo_inicial then
      raise exception 'Ese rango ya se usó en % documento(s): no se borra. Desactívelo', old.correlativo_actual - old.correlativo_inicial;
    end if;
    return old;
  end if;

  new.cai     := nullif(upper(btrim(coalesce(new.cai, ''))), '');
  new.prefijo := btrim(new.prefijo);

  if new.prefijo !~ '^[0-9]{3}-[0-9]{3}-[0-9]{2}$' then
    raise exception 'El prefijo debe tener la forma 000-001-01 (establecimiento-punto de emisión-tipo de documento)';
  end if;
  if new.tipo_documento <> 'ticket' and new.cai is null then
    raise exception 'Un rango autorizado necesita su CAI';
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
      raise exception 'El correlativo no puede retroceder: repetiría números ya emitidos';
    end if;
    if v_usado and (new.cai is distinct from old.cai
                    or new.prefijo is distinct from old.prefijo
                    or new.correlativo_inicial <> old.correlativo_inicial
                    or new.tipo_documento <> old.tipo_documento
                    or new.sucursal_id <> old.sucursal_id) then
      raise exception 'Ese rango ya se usó: no se le cambia el CAI, el prefijo, el inicio ni la sucursal. Cree un rango nuevo';
    end if;
    if new.correlativo_final < old.correlativo_actual - 1 then
      raise exception 'El final no puede quedar antes del último número emitido (%)', old.correlativo_actual - 1;
    end if;
    if new.correlativo_actual <> old.correlativo_actual
       and new.correlativo_actual <> old.correlativo_actual + 1 then
      raise exception 'El correlativo avanza solo al emitir';
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


-- ---------------------------------------------------------------------------
-- Devolver
--   p_lineas: [{"detalle_id":"…","cantidad":1}]
--   p_metodo: como se devuelve lo que no se rebaja del fiado
-- ---------------------------------------------------------------------------
create or replace function fn_devolver_venta(
  p_venta_id  uuid,
  p_lineas    jsonb,
  p_motivo    text,
  p_turno_id  uuid default null,
  p_metodo    metodo_pago default 'efectivo'
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v         record;
  o         record;
  it        jsonb;
  d         record;
  s         record;
  v_dev     uuid;
  v_cant    numeric;
  v_ya      numeric;
  v_unit    numeric;
  v_linea   numeric;
  v_sub     numeric := 0;
  v_imp     numeric := 0;
  v_total   numeric := 0;
  v_fiado   numeric;
  v_rebajado numeric;
  v_rebaja  numeric := 0;
  v_reemb   numeric := 0;
  v_saldo   numeric;
  v_numero  text;
  v_tipo    tipo_documento_fiscal := 'ticket';
  v_nf      text;
  v_cai     text;
  v_falta_nc boolean := false;
  v_n       int := 0;
begin
  if p_motivo is null or btrim(p_motivo) = '' then
    raise exception 'Una devolución exige un motivo';
  end if;
  if p_lineas is null or jsonb_typeof(p_lineas) <> 'array' or jsonb_array_length(p_lineas) = 0 then
    raise exception 'Diga qué productos se devuelven';
  end if;

  select * into v from ventas where id = p_venta_id for update;
  if v.id is null then raise exception 'Venta inexistente'; end if;
  if not (app.es_admin() or (v.organizacion_id = app.org_id() and app.tiene_nivel('supervisor'))) then
    raise exception 'Solo un supervisor de este negocio puede registrar devoluciones';
  end if;
  if v.estado <> 'completada' then raise exception 'La venta está %', v.estado; end if;
  if p_metodo = 'credito' then
    raise exception 'Lo que se devuelve no se le fía: elija efectivo, tarjeta o transferencia';
  end if;

  select * into o from organizaciones where id = v.organizacion_id;

  v_numero := app.numero_documento(v.organizacion_id, v.sucursal_id, 'devolucion', 'DV', 8);
  insert into devoluciones_venta (organizacion_id, sucursal_id, venta_id, numero, motivo, creada_por)
  values (v.organizacion_id, v.sucursal_id, v.id, v_numero, btrim(p_motivo), auth.uid())
  returning id into v_dev;

  for it in select * from jsonb_array_elements(p_lineas) loop
    v_cant := round(coalesce((it->>'cantidad')::numeric, 0), 3);
    continue when v_cant <= 0;

    select * into d from venta_detalle
     where id = (it->>'detalle_id')::uuid and venta_id = v.id;
    if d.id is null then raise exception 'Esa línea no es de esta venta'; end if;

    select coalesce(sum(dd.cantidad), 0) into v_ya
    from devolucion_detalle dd where dd.venta_detalle_id = d.id;

    if v_cant > d.cantidad - v_ya + 0.0005 then
      raise exception 'De «%» se vendieron % y ya se devolvieron %: no se pueden devolver %',
        (select nombre from productos where id = d.producto_id),
        round(d.cantidad, 3), round(v_ya, 3), v_cant;
    end if;

    -- Lo que se cobro por unidad, ya con su descuento
    v_unit  := d.total / d.cantidad;
    v_linea := round(v_unit * v_cant, 4);

    insert into devolucion_detalle (organizacion_id, devolucion_id, venta_detalle_id, producto_id,
                                    cantidad, precio_unitario, tasa_impuesto, impuesto_incluido,
                                    costo_unitario, total)
    values (v.organizacion_id, v_dev, d.id, d.producto_id, v_cant, v_unit, d.tasa_impuesto,
            d.impuesto_incluido, d.costo_unitario, v_linea);

    if exists (select 1 from productos p where p.id = d.producto_id and p.tipo <> 'servicio') then
      perform fn_kardex_registrar(v.sucursal_id, d.producto_id, 'devolucion_venta',
                                  v_cant, d.costo_unitario, d.lote_id,
                                  'devolucion', v_dev, 'Devolución ' || v_numero, auth.uid());
    end if;

    if d.impuesto_incluido then
      v_sub := v_sub + v_linea / (1 + d.tasa_impuesto);
      v_imp := v_imp + v_linea - v_linea / (1 + d.tasa_impuesto);
    else
      v_sub := v_sub + v_linea;
      v_imp := v_imp + v_linea * d.tasa_impuesto;
    end if;
    v_n := v_n + 1;
  end loop;

  if v_n = 0 then raise exception 'Diga cuántas unidades se devuelven'; end if;
  v_total := round(v_sub + v_imp, 2);

  -- Primero se rebaja el fiado de ESTA venta que siga vivo en la cuenta
  if v.cliente_id is not null then
    select coalesce(sum(pv.monto), 0) into v_fiado
    from pagos_venta pv where pv.venta_id = v.id and pv.metodo = 'credito';
    select coalesce(sum(rebaja_fiado), 0) into v_rebajado
    from devoluciones_venta where venta_id = v.id and id <> v_dev;
    select saldo into v_saldo from clientes where id = v.cliente_id for update;

    v_rebaja := round(greatest(least(v_total, v_fiado - v_rebajado, coalesce(v_saldo, 0)), 0), 2);
    if v_rebaja > 0 then
      update clientes set saldo = round(saldo - v_rebaja, 4), actualizado_en = now()
       where id = v.cliente_id;
    end if;
  end if;

  v_reemb := round(v_total - v_rebaja, 2);

  -- El efectivo que se devuelve sale de una gaveta abierta de esta sucursal
  if v_reemb > 0 and p_metodo = 'efectivo' then
    if p_turno_id is null then
      raise exception 'Para devolver efectivo hace falta una caja abierta';
    end if;
    perform 1 from turnos_caja
     where id = p_turno_id and estado = 'abierto' and sucursal_id = v.sucursal_id;
    if not found then
      raise exception 'Esa caja no está abierta en esta sucursal';
    end if;
  end if;

  -- Factura → nota de credito con su propio rango
  if v.tipo_documento = 'factura' and o.facturacion_fiscal_activa then
    select * into s from series_fiscales
     where sucursal_id = v.sucursal_id and tipo_documento = 'nota_credito' and activa
       and correlativo_actual <= correlativo_final
       and (fecha_limite_emision is null or fecha_limite_emision >= (now() at time zone app.zona(v.organizacion_id))::date)
     order by creada_en limit 1
     for update;
    if s.id is null then
      v_falta_nc := true;
    else
      v_tipo := 'nota_credito';
      v_nf   := s.prefijo || '-' || lpad(s.correlativo_actual::text, 8, '0');
      v_cai  := s.cai;
      update series_fiscales set correlativo_actual = correlativo_actual + 1 where id = s.id;
    end if;
  end if;

  update devoluciones_venta
     set subtotal = round(v_sub, 4), impuesto = round(v_imp, 4), total = v_total,
         rebaja_fiado = v_rebaja, reembolso = v_reemb,
         reembolso_metodo = case when v_reemb > 0 then p_metodo end,
         turno_id = case when v_reemb > 0 and p_metodo = 'efectivo' then p_turno_id end,
         tipo_documento = v_tipo, numero_fiscal = v_nf, cai = v_cai
   where id = v_dev;

  return jsonb_build_object(
    'devolucion_id', v_dev,
    'numero', v_numero,
    'documento', v_tipo,
    'numero_fiscal', v_nf,
    'total', v_total,
    'rebaja_fiado', v_rebaja,
    'reembolso', v_reemb,
    'metodo', case when v_reemb > 0 then p_metodo end,
    'falta_nota_credito', v_falta_nc,
    'saldo_cliente', case when v.cliente_id is not null
                          then (select round(saldo, 2) from clientes where id = v.cliente_id) end);
end $fn$;

revoke execute on function fn_devolver_venta(uuid, jsonb, text, uuid, metodo_pago) from public, anon;
grant execute on function fn_devolver_venta(uuid, jsonb, text, uuid, metodo_pago) to authenticated;


-- ---------------------------------------------------------------------------
-- Anular entera no se puede si ya hubo devoluciones
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

  if not (app.es_admin()
          or (v.organizacion_id = app.org_id() and app.tiene_nivel('supervisor'))) then
    raise exception 'Solo un supervisor de este negocio puede anular ventas';
  end if;

  if exists (select 1 from devoluciones_venta where venta_id = p_venta_id) then
    raise exception 'Esta venta ya tiene devoluciones: no se anula entera. Devuelva lo que falte';
  end if;

  for l in select * from venta_detalle where venta_id = p_venta_id loop
    if exists (select 1 from productos p
                where p.id = l.producto_id and p.tipo <> 'servicio') then
      perform fn_kardex_registrar(v.sucursal_id, l.producto_id, 'devolucion_venta',
                                  l.cantidad, l.costo_unitario, l.lote_id,
                                  'anulacion_venta', v.id,
                                  'Anulacion ' || v.numero, auth.uid());
    end if;
  end loop;

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
-- El arqueo descuenta el efectivo devuelto en el turno
-- ---------------------------------------------------------------------------
create or replace function fn_cerrar_turno(
  p_turno_id uuid,
  p_monto_declarado numeric,
  p_notas text default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  t          record;
  v_ventas   numeric;
  v_abonos   numeric;
  v_devol    numeric;
  v_esperado numeric;
begin
  select * into t from turnos_caja where id = p_turno_id for update;
  if t.id is null or t.estado <> 'abierto' then
    raise exception 'El turno no esta abierto';
  end if;

  select coalesce(sum(pv.monto), 0) into v_ventas
  from pagos_venta pv
  join ventas ve on ve.id = pv.venta_id
  where ve.turno_id = p_turno_id
    and ve.estado = 'completada'
    and pv.metodo = 'efectivo';

  select coalesce(sum(ab.monto), 0) into v_abonos
  from abonos_cliente ab
  where ab.turno_id = p_turno_id
    and not ab.anulado
    and ab.metodo = 'efectivo';

  -- Lo que se le devolvio en efectivo a un cliente salio de esta gaveta
  select coalesce(sum(dv.reembolso), 0) into v_devol
  from devoluciones_venta dv
  where dv.turno_id = p_turno_id and dv.reembolso_metodo = 'efectivo';

  v_esperado := t.monto_inicial + v_ventas + v_abonos - v_devol;

  update turnos_caja
     set estado = 'cerrado', cerrado_en = now(), cerrado_por = auth.uid(),
         monto_declarado = p_monto_declarado,
         monto_esperado  = v_esperado,
         diferencia      = p_monto_declarado - v_esperado,
         notas           = p_notas
   where id = p_turno_id;

  update caja_desbloqueos set consumido_en = now()
   where turno_id = p_turno_id and consumido_en is null;

  return jsonb_build_object(
    'monto_inicial',   t.monto_inicial,
    'efectivo_ventas', v_ventas,
    'abonos_fiado',    v_abonos,
    'devoluciones',    v_devol,
    'esperado',        v_esperado,
    'declarado',       p_monto_declarado,
    'diferencia',      p_monto_declarado - v_esperado
  );
end $fn$;


-- ---------------------------------------------------------------------------
-- La venta completa: cada linea dice cuanto ya se devolvio, y la venta trae
-- sus devoluciones. Una devolucion se imprime con fn_devolucion_completa.
-- ---------------------------------------------------------------------------
create or replace function fn_venta_completa(p_venta_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v    record;
  o    record;
  s    record;
  v_rango jsonb;
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

  if v.numero_fiscal is not null then
    select * into s from series_fiscales sf
     where sf.organizacion_id = v.organizacion_id
       and sf.cai is not distinct from v.cai
       and v.numero_fiscal like sf.prefijo || '-%'
     order by sf.creada_en desc limit 1;
    -- (s queda sin asignar si no hay numero fiscal: no se lee fuera de este if)
    if found then
      v_rango := jsonb_build_object(
        'desde', s.prefijo || '-' || lpad(s.correlativo_inicial::text, 8, '0'),
        'hasta', s.prefijo || '-' || lpad(s.correlativo_final::text, 8, '0'),
        'fecha_limite', s.fecha_limite_emision);
    end if;
  end if;

  select jsonb_build_object(
    'venta', jsonb_build_object(
      'id', v.id, 'numero', v.numero, 'numero_fiscal', v.numero_fiscal,
      'cai', v.cai, 'documento', v.tipo_documento, 'creada_en', v.creada_en,
      'subtotal', v.subtotal, 'impuesto', v.impuesto, 'descuento', v.descuento,
      'total', v.total, 'es_credito', v.es_credito, 'estado', v.estado,
      'motivo_anulacion', v.motivo_anulacion, 'anulada_en', v.anulada_en,
      'costo', case when v_ve_costos then v.costo_total end,
      'anulada_por', (select nombre from perfiles where id = v.anulada_por),
      'devuelto', (select coalesce(sum(total), 0) from devoluciones_venta where venta_id = v.id),
      'sucursal_id', v.sucursal_id
    ),
    'rango', v_rango,
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
               'detalle_id', d.id,
               'producto', pr.nombre,
               'sku', pr.sku,
               'cantidad', d.cantidad,
               'devuelto', (select coalesce(sum(dd.cantidad), 0) from devolucion_detalle dd
                             where dd.venta_detalle_id = d.id),
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
      from pagos_venta pv where pv.venta_id = v.id), '[]'::jsonb),
    'devoluciones', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', dv.id, 'numero', dv.numero, 'numero_fiscal', dv.numero_fiscal,
               'documento', dv.tipo_documento, 'total', dv.total, 'motivo', dv.motivo,
               'rebaja_fiado', dv.rebaja_fiado, 'reembolso', dv.reembolso,
               'metodo', dv.reembolso_metodo, 'creada_en', dv.creada_en,
               'por', (select nombre from perfiles where id = dv.creada_por))
             order by dv.creada_en)
      from devoluciones_venta dv where dv.venta_id = v.id), '[]'::jsonb)
  ) into v_res;

  return v_res;
end $fn$;

revoke execute on function fn_venta_completa(uuid) from public, anon;
grant execute on function fn_venta_completa(uuid) to authenticated;


-- Lo que se imprime de una devolucion: el mismo formato del ticket
create or replace function fn_devolucion_completa(p_devolucion_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  dv  record;
  v   record;
  o   record;
  s   record;
  v_rango jsonb;
begin
  select * into dv from devoluciones_venta where id = p_devolucion_id;
  if dv.id is null then raise exception 'Devolución inexistente'; end if;
  if not (app.es_admin() or (dv.organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))) then
    raise exception 'Esa devolución no es de este negocio';
  end if;
  select * into v from ventas where id = dv.venta_id;
  select * into o from organizaciones where id = dv.organizacion_id;
  if dv.numero_fiscal is not null then
    select * into s from series_fiscales sf
     where sf.organizacion_id = dv.organizacion_id and sf.cai is not distinct from dv.cai
       and dv.numero_fiscal like sf.prefijo || '-%'
     order by sf.creada_en desc limit 1;
    -- (s queda sin asignar si no hay numero fiscal: no se lee fuera de este if)
    if found then
      v_rango := jsonb_build_object(
        'desde', s.prefijo || '-' || lpad(s.correlativo_inicial::text, 8, '0'),
        'hasta', s.prefijo || '-' || lpad(s.correlativo_final::text, 8, '0'),
        'fecha_limite', s.fecha_limite_emision);
    end if;
  end if;

  return jsonb_build_object(
    'devolucion', jsonb_build_object('motivo', dv.motivo,
      'referencia', coalesce(v.numero_fiscal, v.numero),
      'rebaja_fiado', dv.rebaja_fiado, 'reembolso', dv.reembolso, 'metodo', dv.reembolso_metodo),
    'venta', jsonb_build_object(
      'id', dv.id, 'numero', dv.numero, 'numero_fiscal', dv.numero_fiscal, 'cai', dv.cai,
      'documento', case when dv.tipo_documento = 'nota_credito' then 'nota_credito' else 'devolucion' end,
      'creada_en', dv.creada_en, 'subtotal', dv.subtotal, 'impuesto', dv.impuesto,
      'descuento', 0, 'total', dv.total, 'estado', 'completada'),
    'rango', v_rango,
    'negocio', jsonb_build_object(
      'nombre', o.nombre, 'rtn', o.identificacion_fiscal, 'moneda', o.moneda,
      'razon_social', o.config->>'razon_social', 'direccion', o.config->>'direccion_fiscal',
      'telefono', o.config->>'telefono', 'correo', o.config->>'correo',
      'mensaje_ticket', o.config->>'mensaje_ticket',
      'ancho_ticket', coalesce((o.config->>'ancho_ticket')::int, 80)),
    'sucursal', (select jsonb_build_object('nombre', su.nombre, 'direccion', su.direccion, 'telefono', su.telefono)
                   from sucursales su where su.id = dv.sucursal_id),
    'cajero', (select nombre from perfiles where id = dv.creada_por),
    'cliente', (select jsonb_build_object('nombre', c.nombre, 'rtn', c.identificacion_fiscal)
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
      from devolucion_detalle d where d.devolucion_id = dv.id),
    'lineas', coalesce((
      select jsonb_agg(jsonb_build_object('producto', pr.nombre, 'cantidad', d.cantidad,
               'precio', d.precio_unitario, 'total', d.total, 'exento', d.tasa_impuesto = 0)
             order by pr.nombre)
      from devolucion_detalle d join productos pr on pr.id = d.producto_id
      where d.devolucion_id = dv.id), '[]'::jsonb),
    'pagos', case when dv.reembolso > 0
                  then jsonb_build_array(jsonb_build_object('metodo', dv.reembolso_metodo, 'monto', dv.reembolso))
                  else '[]'::jsonb end);
end $fn$;

revoke execute on function fn_devolucion_completa(uuid) from public, anon;
grant execute on function fn_devolucion_completa(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- Historial y resumen: lo devuelto se resta, y los dias son los de Honduras.
-- Antes "hoy" iba de medianoche a medianoche en UTC: de 6 de la tarde a 6 de
-- la tarde en la pulperia. Lo vendido de noche caia en el dia siguiente.
-- ---------------------------------------------------------------------------
create or replace function app.inicio_dia(p_dia date)
returns timestamptz stable language sql set search_path = public, app as $fn$
  select p_dia::timestamp at time zone app.zona(app.org_id())
$fn$;

drop function if exists fn_historial_ventas(date, date, uuid, text, text, int);
create function fn_historial_ventas(
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
  motivo       text,
  devuelto     numeric
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
    ap.nombre, v.motivo_anulacion,
    (select coalesce(sum(dv.total), 0) from devoluciones_venta dv where dv.venta_id = v.id)
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
    and (p_desde is null or v.creada_en >= app.inicio_dia(p_desde))
    and (p_hasta is null or v.creada_en < app.inicio_dia(p_hasta + 1))
    and (p_estado is null or v.estado::text = p_estado)
    and (p_buscar is null or btrim(p_buscar) = ''
         or v.numero ilike '%' || btrim(p_buscar) || '%'
         or coalesce(v.numero_fiscal,'') ilike '%' || btrim(p_buscar) || '%'
         or coalesce(cl.nombre,'') ilike '%' || btrim(p_buscar) || '%')
  order by v.creada_en desc
  limit greatest(coalesce(p_limite, 100), 1)
$fn$;

revoke execute on function fn_historial_ventas(date, date, uuid, text, text, int) from public, anon;
grant execute on function fn_historial_ventas(date, date, uuid, text, text, int) to authenticated;


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
      and (p_desde is null or ve.creada_en >= app.inicio_dia(p_desde))
      and (p_hasta is null or ve.creada_en < app.inicio_dia(p_hasta + 1))
  ),
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
  ),
  -- Las devoluciones cuentan el dia que se hicieron, no el de la venta
  devol as (
    select coalesce(sum(dv.total), 0) as total,
           count(*) as cuantas,
           coalesce(sum(dv.reembolso) filter (where dv.reembolso_metodo = 'efectivo'), 0) as efectivo,
           coalesce(sum(dv.rebaja_fiado), 0) as fiado,
           coalesce(sum(dv.subtotal - (select coalesce(sum(dd.cantidad * dd.costo_unitario), 0)
                                         from devolucion_detalle dd where dd.devolucion_id = dv.id)), 0) as margen
    from devoluciones_venta dv
    where app.tiene_nivel('auxiliar')
      and dv.organizacion_id = app.org_id()
      and dv.sucursal_id in (select app.sucursales_permitidas())
      and (p_sucursal_id is null or dv.sucursal_id = p_sucursal_id)
      and (p_desde is null or dv.creada_en >= app.inicio_dia(p_desde))
      and (p_hasta is null or dv.creada_en < app.inicio_dia(p_hasta + 1))
  )
  select jsonb_build_object(
    'ventas',        count(*) filter (where a.estado = 'completada'),
    'total',         coalesce(sum(a.total) filter (where a.estado = 'completada'), 0) - (select total from devol),
    'bruto',         coalesce(sum(a.total) filter (where a.estado = 'completada'), 0),
    'devuelto',      (select total from devol),
    'devoluciones',  (select cuantas from devol),
    'efectivo',      (select monto from efectivo) - (select efectivo from devol),
    'fiado',         (select monto from fiado) - (select fiado from devol),
    'anuladas',      count(*) filter (where a.estado = 'anulada'),
    'monto_anulado', coalesce(sum(a.total) filter (where a.estado = 'anulada'), 0),
    'ganancia',      case when app.tiene_nivel('supervisor')
                          then coalesce(sum(a.total - a.impuesto - a.costo_total)
                                        filter (where a.estado = 'completada'), 0)
                               - (select margen from devol) end
  )
  from alcance a
$fn$;

revoke execute on function fn_ventas_resumen(date, date, uuid) from public, anon;
grant execute on function fn_ventas_resumen(date, date, uuid) to authenticated;

notify pgrst, 'reload schema';
