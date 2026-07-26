-- ============================================================================
--  Migración 008 · Correcciones de compras
--
--  1) fn_confirmar_factura_compra aceptaba confirmar una factura sin
--     renglones: quedaba una compra "confirmada" por L 0.00 en el historial
--     y en la cuenta por pagar del proveedor.
--
--  2) El costo estaba reservado al gerente, pero quien recibe la mercadería
--     es el supervisor y es él quien digita los costos de la factura del
--     proveedor. Ocultarle el último costo no protegía nada y le quitaba la
--     referencia para detectar un alza del proveedor. El análisis de
--     rentabilidad (v_margen_productos) sigue siendo cosa de gerencia.
-- ============================================================================

-- ---------- 1. No se confirma una factura vacía ----------
create or replace function fn_confirmar_factura_compra(p_factura_id uuid)
returns void
language plpgsql security definer set search_path = public, app as $$
declare
  f            record;
  d            record;
  v_lineas     int;
  v_factor     numeric;
  v_cant_base  numeric;
  v_costo_base numeric;
  v_lote       uuid;
  v_sub        numeric := 0;
  v_imp        numeric := 0;
begin
  select * into f from facturas_compra where id = p_factura_id for update;

  if f.id is null then
    raise exception 'Factura de compra inexistente';
  end if;

  if auth.uid() is not null
     and not (app.es_admin()
              or (f.organizacion_id = app.org_id() and app.tiene_nivel('supervisor'))) then
    raise exception 'No tiene permiso para confirmar esta compra';
  end if;

  if f.estado <> 'borrador' then
    raise exception 'Solo se confirman facturas en borrador (estado actual: %)', f.estado;
  end if;

  select count(*) into v_lineas
  from factura_compra_detalle where factura_compra_id = p_factura_id;

  if v_lineas = 0 then
    raise exception 'La factura no tiene productos: no hay nada que ingresar';
  end if;

  for d in
    select fcd.*, p.controla_lote, p.controla_vencimiento
    from factura_compra_detalle fcd
    join productos p on p.id = fcd.producto_id
    where fcd.factura_compra_id = p_factura_id
  loop
    v_factor := coalesce((select factor from presentaciones where id = d.presentacion_id), 1);

    v_cant_base  := d.cantidad * v_factor;
    v_costo_base := (d.costo_unitario - d.descuento) / nullif(v_factor, 0);

    v_lote := null;
    if d.controla_lote or d.controla_vencimiento
       or d.lote_codigo is not null or d.fecha_vencimiento is not null then
      insert into lotes (organizacion_id, producto_id, sucursal_id, codigo,
                         fecha_vencimiento, costo_ingreso, proveedor_id, documento_origen)
      values (f.organizacion_id, d.producto_id, f.sucursal_id,
              coalesce(d.lote_codigo, f.numero), d.fecha_vencimiento,
              v_costo_base, f.proveedor_id, 'FC-' || f.numero)
      on conflict (producto_id, sucursal_id, codigo, fecha_vencimiento)
        do update set costo_ingreso = excluded.costo_ingreso
      returning id into v_lote;
    end if;

    perform fn_kardex_registrar(
      f.sucursal_id, d.producto_id, 'compra',
      v_cant_base, v_costo_base, v_lote,
      'factura_compra', f.id,
      'Compra ' || f.numero, f.creada_por
    );

    v_sub := v_sub + (v_cant_base * v_costo_base);
    v_imp := v_imp + (v_cant_base * v_costo_base * d.tasa_impuesto);
  end loop;

  update facturas_compra
     set subtotal = round(v_sub, 4),
         impuesto = round(v_imp, 4),
         total    = round(v_sub + v_imp, 4),
         saldo    = round(v_sub + v_imp, 4),
         estado   = 'confirmado',
         confirmada_en = now(),
         actualizado_en = now()
   where id = p_factura_id;

  if f.orden_compra_id is not null then
    update ordenes_compra set estado = 'recibida', actualizado_en = now()
     where id = f.orden_compra_id;
  end if;
end $$;


-- ---------- 2. El supervisor ve los costos de compra ----------
drop policy if exists costos_sel on producto_costos;

create policy costos_sel on producto_costos for select
  using ((organizacion_id = app.org_id() and app.tiene_nivel('supervisor'))
         or app.es_admin());


-- ============================================================================
--  3. La devolución a proveedor sale al costo al que entró
--
--  Toda salida se valoraba al promedio vigente. Para una venta eso es
--  correcto, pero al devolver mercadería al proveedor se devuelve lo que se
--  compró, al precio que se pagó. Valorarla al promedio dejaba el costo
--  desviado después de anular una compra: en la prueba, anular una entrada
--  dejaba el promedio en 27.7428 en vez de volver a los 27.30 originales.
-- ============================================================================

create or replace function fn_kardex_registrar(
  p_sucursal_id     uuid,
  p_producto_id     uuid,
  p_tipo            tipo_movimiento,
  p_cantidad        numeric,
  p_costo_unitario  numeric default null,
  p_lote_id         uuid    default null,
  p_documento_tipo  text    default null,
  p_documento_id    uuid    default null,
  p_notas           text    default null,
  p_usuario_id      uuid    default null
) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_org        uuid;
  v_negativo   boolean;
  v_entrada    boolean;
  v_signo      int;
  v_cant       numeric;
  v_valor      numeric;
  v_prom       numeric;
  v_costo_mov  numeric;
  v_disp       numeric;
  v_id         bigint;
begin
  if p_cantidad is null or p_cantidad <= 0 then
    raise exception 'La cantidad del movimiento debe ser mayor a cero';
  end if;

  select s.organizacion_id, o.permite_stock_negativo
    into v_org, v_negativo
  from sucursales s
  join organizaciones o on o.id = s.organizacion_id
  where s.id = p_sucursal_id;

  if v_org is null then
    raise exception 'Sucursal % inexistente', p_sucursal_id;
  end if;

  v_entrada := app.es_entrada(p_tipo);
  v_signo   := case when v_entrada then 1 else -1 end;

  insert into producto_costos (organizacion_id, producto_id, sucursal_id)
  values (v_org, p_producto_id, p_sucursal_id)
  on conflict (producto_id, sucursal_id) do nothing;

  select cantidad, valor, costo_promedio
    into v_cant, v_valor, v_prom
  from producto_costos
  where producto_id = p_producto_id and sucursal_id = p_sucursal_id
  for update;

  if v_entrada then
    if p_costo_unitario is null or p_costo_unitario < 0 then
      raise exception 'Toda entrada de inventario requiere costo unitario';
    end if;
    v_costo_mov := p_costo_unitario;
    v_cant      := v_cant + p_cantidad;
    v_valor     := v_valor + (p_cantidad * v_costo_mov);
    v_prom      := case when v_cant > 0 then v_valor / v_cant else v_costo_mov end;
  else
    -- Devolución al proveedor: sale al costo al que entró.
    -- Cualquier otra salida (venta, merma, ajuste): al promedio vigente.
    if p_tipo = 'devolucion_compra' and p_costo_unitario is not null then
      v_costo_mov := p_costo_unitario;
    else
      v_costo_mov := v_prom;
    end if;

    if not v_negativo then
      select coalesce(sum(cantidad), 0) into v_disp
      from existencias
      where producto_id = p_producto_id
        and sucursal_id = p_sucursal_id
        and (p_lote_id is null or lote_id = p_lote_id);

      if v_disp < p_cantidad then
        raise exception 'Stock insuficiente: disponible %, solicitado %', v_disp, p_cantidad;
      end if;
    end if;

    v_cant  := v_cant - p_cantidad;
    v_valor := greatest(v_valor - (p_cantidad * v_costo_mov), 0);
    if v_cant > 0 then
      v_prom := v_valor / v_cant;
    end if;
  end if;

  update existencias
     set cantidad = cantidad + (v_signo * p_cantidad),
         actualizado_en = now()
   where producto_id = p_producto_id
     and sucursal_id = p_sucursal_id
     and lote_id is not distinct from p_lote_id;

  if not found then
    insert into existencias (organizacion_id, producto_id, sucursal_id, lote_id, cantidad)
    values (v_org, p_producto_id, p_sucursal_id, p_lote_id, v_signo * p_cantidad);
  end if;

  update producto_costos
     set cantidad = v_cant,
         valor    = v_valor,
         costo_promedio = v_prom,
         ultimo_costo   = case when v_entrada then v_costo_mov else ultimo_costo end,
         actualizado_en = now()
   where producto_id = p_producto_id and sucursal_id = p_sucursal_id;

  insert into kardex (
    organizacion_id, sucursal_id, producto_id, lote_id, tipo,
    cantidad, costo_unitario, costo_total, costo_promedio_resultante,
    saldo_cantidad, saldo_valor, documento_tipo, documento_id, usuario_id, notas
  ) values (
    v_org, p_sucursal_id, p_producto_id, p_lote_id, p_tipo,
    v_signo * p_cantidad, v_costo_mov, p_cantidad * v_costo_mov, v_prom,
    v_cant, v_valor, p_documento_tipo, p_documento_id,
    coalesce(p_usuario_id, auth.uid()), p_notas
  ) returning id into v_id;

  return v_id;
end $$;

revoke execute on function fn_kardex_registrar(uuid, uuid, tipo_movimiento, numeric, numeric, uuid, text, uuid, text, uuid) from public, anon, authenticated;


-- ============================================================================
--  4. Coherencia en la anulación de compras
--
--  fn_confirmar_factura_compra permite ejecutarse del lado del servidor
--  (SQL Editor, service_role, tareas programadas), donde auth.uid() es nulo.
--  fn_anular_factura_compra no lo permitía, así que una corrección desde el
--  SQL Editor fallaba con "Solo un supervisor puede anular". Se igualan.
--  `anon` no puede llamarla, así que un uid nulo solo ocurre del lado servidor.
-- ============================================================================

create or replace function fn_anular_factura_compra(p_factura_id uuid, p_motivo text)
returns void
language plpgsql security definer set search_path = public, app as $$
declare
  f            record;
  d            record;
  v_factor     numeric;
  v_cant_base  numeric;
  v_costo_base numeric;
  v_lote       uuid;
begin
  select * into f from facturas_compra where id = p_factura_id for update;
  if f.id is null then raise exception 'Factura inexistente'; end if;

  if auth.uid() is not null
     and not (app.es_admin()
              or (f.organizacion_id = app.org_id() and app.tiene_nivel('supervisor'))) then
    raise exception 'Solo un supervisor puede anular una compra';
  end if;

  if f.estado = 'anulado' then raise exception 'La factura ya está anulada'; end if;

  if f.estado = 'confirmado' then
    for d in
      select * from factura_compra_detalle where factura_compra_id = p_factura_id
    loop
      v_factor     := coalesce((select factor from presentaciones where id = d.presentacion_id), 1);
      v_cant_base  := d.cantidad * v_factor;
      v_costo_base := (d.costo_unitario - d.descuento) / nullif(v_factor, 0);

      select id into v_lote from lotes
       where producto_id = d.producto_id and sucursal_id = f.sucursal_id
         and codigo = coalesce(d.lote_codigo, f.numero)
         and fecha_vencimiento is not distinct from d.fecha_vencimiento;

      perform fn_kardex_registrar(
        f.sucursal_id, d.producto_id, 'devolucion_compra',
        v_cant_base, v_costo_base, v_lote,
        'anulacion_compra', f.id,
        'Anulación ' || f.numero || ': ' || coalesce(p_motivo, ''), auth.uid()
      );
    end loop;
  end if;

  update facturas_compra
     set estado = 'anulado', saldo = 0,
         anulada_en = now(), anulada_por = auth.uid(),
         motivo_anulacion = p_motivo, actualizado_en = now()
   where id = p_factura_id;
end $$;

revoke execute on function fn_anular_factura_compra(uuid, text) from public, anon;
grant  execute on function fn_anular_factura_compra(uuid, text) to authenticated;
