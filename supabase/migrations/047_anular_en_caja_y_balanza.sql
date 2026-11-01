-- ============================================================================
--  047 · Anular una venta desde la caja con PIN de supervisor, y balanza
--
--  ANULAR EN LA CAJA
--  Hasta aquí una venta cobrada solo la anulaba un supervisor con su propia
--  sesión, desde Ventas. En la caja la cajera tiene la sesión puesta: el
--  supervisor llega, marca su código y PIN (fn_autorizar_caja con la acción
--  'anular') y la caja anula con esa autorización.
--   · Siempre pide supervisor: no es un permiso que se pueda apagar.
--   · Solo ventas de un turno que sigue abierto. Si el turno ya se cerró,
--     el arqueo ya contó esa plata y la anulación descuadraría un cierre
--     firmado; esa va por Ventas, como siempre.
--   · La autorización vale una vez, 15 minutos, para quien la pidió, y queda
--     amarrada a la venta (autorizaciones_caja.venta_id).
--   · anulada_por es el supervisor, no la cajera.
--
--  BALANZA
--  Las etiquetas de balanza son EAN-13 que empiezan con 2: prefijo (2
--  dígitos), PLU, peso o precio, y dígito de control. La caja las lee con
--  balanza.js; aquí solo se guarda la forma (organizaciones.config.balanza)
--  y se manda en fn_pos_contexto junto con el código de tienda (para que la
--  caja reconozca un ticket propio escaneado en el buscador).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La acción 'anular' y a qué venta se amarró
-- ---------------------------------------------------------------------------
alter table autorizaciones_caja add column if not exists venta_id uuid references ventas(id);
alter table autorizaciones_caja drop constraint if exists autorizaciones_caja_accion_check;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'autorizaciones_caja_accion_valida') then
    alter table autorizaciones_caja add constraint autorizaciones_caja_accion_valida
      check (accion in ('quitar', 'cancelar', 'descartar', 'anular'));
  end if;
end $$;

create or replace function fn_autorizar_caja(p_codigo text, p_pin text, p_accion text)
returns jsonb
language plpgsql security definer set search_path = public, app, extensions as $fn$
declare
  aut  jsonb;
  v_id uuid;
begin
  if app.org_id() is null or not app.tiene_nivel('auxiliar') then
    raise exception 'Sin permiso para la caja';
  end if;
  if p_accion not in ('quitar', 'cancelar', 'descartar', 'anular') then
    raise exception 'Acción no válida';
  end if;
  aut := app.quien_autoriza(p_codigo, p_pin, 'supervisor');
  if not (aut->>'ok')::boolean then return aut; end if;

  insert into autorizaciones_caja (organizacion_id, autorizo, pidio, accion)
  values (app.org_id(), (aut->>'perfil_id')::uuid, auth.uid(), p_accion)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'autorizacion_id', v_id,
                            'nombre', aut->>'nombre', 'perfil_id', aut->>'perfil_id');
end $fn$;


-- ---------------------------------------------------------------------------
-- 2. El corazón de la anulación, una sola copia
--    fn_anular_venta (Ventas, sesión del supervisor) y fn_anular_venta_caja
--    (caja, autorización) llaman aquí con quién anula.
-- ---------------------------------------------------------------------------
create or replace function app.anular_venta(p_venta_id uuid, p_motivo text, p_por uuid)
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

  if exists (select 1 from devoluciones_venta where venta_id = p_venta_id) then
    raise exception 'Esta venta ya tiene devoluciones: no se anula entera. Devuelva lo que falte';
  end if;

  for l in select * from venta_detalle where venta_id = p_venta_id loop
    if exists (select 1 from productos p
                where p.id = l.producto_id and p.tipo <> 'servicio') then
      perform fn_kardex_registrar(v.sucursal_id, l.producto_id, 'devolucion_venta',
                                  l.cantidad, l.costo_unitario, l.lote_id,
                                  'anulacion_venta', v.id,
                                  'Anulacion ' || v.numero, p_por);
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
     set estado = 'anulada', anulada_por = p_por,
         anulada_en = now(), motivo_anulacion = btrim(p_motivo)
   where id = p_venta_id;
end $fn$;

revoke execute on function app.anular_venta(uuid, text, uuid) from public, anon, authenticated;

create or replace function fn_anular_venta(p_venta_id uuid, p_motivo text)
returns void
language plpgsql security definer set search_path = public, app as $fn$
declare v_org uuid;
begin
  select organizacion_id into v_org from ventas where id = p_venta_id;
  if v_org is null then raise exception 'Venta inexistente'; end if;
  if not (app.es_admin() or (v_org = app.org_id() and app.tiene_nivel('supervisor'))) then
    raise exception 'Solo un supervisor de este negocio puede anular ventas';
  end if;
  perform app.anular_venta(p_venta_id, p_motivo, auth.uid());
end $fn$;

revoke execute on function fn_anular_venta(uuid, text) from public, anon;
grant execute on function fn_anular_venta(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 3. Desde la caja
-- ---------------------------------------------------------------------------
create or replace function fn_anular_venta_caja(p_venta_id uuid, p_motivo text, p_autorizacion_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org   uuid := app.org_id();
  v       record;
  v_aut   uuid;
begin
  if v_org is null or not app.tiene_nivel('auxiliar') then
    raise exception 'Sin permiso para la caja';
  end if;
  select ve.*, t.estado as turno_estado into v
    from ventas ve left join turnos_caja t on t.id = ve.turno_id
   where ve.id = p_venta_id;
  if v.id is null or v.organizacion_id <> v_org then raise exception 'Venta inexistente'; end if;
  if v.estado = 'anulada' then raise exception 'La venta ya esta anulada'; end if;
  if v.turno_id is null or v.turno_estado is distinct from 'abierto' then
    raise exception 'Esa venta es de un turno ya cerrado. La anula un supervisor desde Ventas';
  end if;

  -- La autorización: de este negocio, para quien la pidió, para anular, sin usar y reciente
  update autorizaciones_caja set usada_en = now(), venta_id = p_venta_id
   where id = p_autorizacion_id and organizacion_id = v_org and pidio = auth.uid()
     and accion = 'anular' and usada_en is null and creada_en > now() - interval '15 minutes'
  returning autorizo into v_aut;
  if v_aut is null then
    raise exception 'La autorización del supervisor no vale o ya se usó. Pídala otra vez';
  end if;

  perform app.anular_venta(p_venta_id, p_motivo, v_aut);

  return jsonb_build_object(
    'ok', true,
    'numero', v.numero,
    'total', v.total,
    'autorizo', (select nombre from perfiles where id = v_aut),
    'efectivo', coalesce((select sum(monto) from pagos_venta where venta_id = p_venta_id and metodo = 'efectivo'), 0),
    'credito',  coalesce((select sum(monto) from pagos_venta where venta_id = p_venta_id and metodo = 'credito'), 0),
    'otros',    coalesce((select sum(monto) from pagos_venta where venta_id = p_venta_id and metodo not in ('efectivo', 'credito')), 0));
end $fn$;

-- Las ventas del turno, para escoger cuál anular sin tener el ticket en la mano
create or replace function fn_ventas_turno_caja(p_turno_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare v_org uuid := app.org_id();
begin
  if v_org is null or not app.tiene_nivel('auxiliar') then
    raise exception 'Sin permiso para la caja';
  end if;
  if not exists (select 1 from turnos_caja where id = p_turno_id and organizacion_id = v_org) then
    raise exception 'Turno inexistente';
  end if;
  return coalesce((
    select jsonb_agg(x order by x ->> 'creada_en' desc)
    from (
      select jsonb_build_object(
        'id', ve.id, 'numero', ve.numero, 'creada_en', ve.creada_en, 'total', ve.total,
        'estado', ve.estado, 'codigo_barras', ve.codigo_barras,
        'cliente', (select nombre from clientes c where c.id = ve.cliente_id),
        'lineas', (select count(*) from venta_detalle d where d.venta_id = ve.id),
        'metodos', (select string_agg(distinct pv.metodo::text, ',') from pagos_venta pv where pv.venta_id = ve.id)) x
      from ventas ve
      where ve.turno_id = p_turno_id
      order by ve.creada_en desc
      limit 60
    ) t), '[]'::jsonb);
end $fn$;

revoke execute on function fn_autorizar_caja(text, text, text) from public, anon;
revoke execute on function fn_anular_venta_caja(uuid, text, uuid) from public, anon;
revoke execute on function fn_ventas_turno_caja(uuid) from public, anon;
grant execute on function fn_autorizar_caja(text, text, text) to authenticated;
grant execute on function fn_anular_venta_caja(uuid, text, uuid) to authenticated;
grant execute on function fn_ventas_turno_caja(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. La forma de la balanza, limpia, con sus valores por defecto
-- ---------------------------------------------------------------------------
create or replace function app.balanza(p_config jsonb) returns jsonb
language sql immutable as $fn$
  select jsonb_build_object(
    'activa',    coalesce((p_config -> 'balanza' ->> 'activa')::boolean, false),
    'prefijos',  coalesce(nullif(p_config -> 'balanza' ->> 'prefijos', ''), '20-29'),
    'largo_plu', least(greatest(coalesce((p_config -> 'balanza' ->> 'largo_plu')::int, 5), 4), 6),
    'tipo',      case when p_config -> 'balanza' ->> 'tipo' = 'precio' then 'precio' else 'peso' end,
    'decimales', least(greatest(coalesce((p_config -> 'balanza' ->> 'decimales')::int, 3), 0), 3))
$fn$;


-- ---------------------------------------------------------------------------
-- 5. El contexto del POS trae el código de tienda y la balanza
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
      'codigo_tienda', v_org.codigo_tienda,
      'factura_fiscal', v_org.facturacion_fiscal_activa,
      'color', case when coalesce(v_org.config ->> 'color_marca', '') ~ '^#[0-9A-Fa-f]{6}$'
                    then v_org.config ->> 'color_marca' end,
      'logo_path', v_org.config ->> 'logo_path',
      'caja_autoriza', app.caja_autoriza(coalesce(v_org.config, '{}'::jsonb)),
      'balanza', app.balanza(coalesce(v_org.config, '{}'::jsonb)),
      'cuenta', app.estado_cuenta(v_org.id)
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
