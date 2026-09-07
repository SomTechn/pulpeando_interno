-- ============================================================================
--  Migración 010 · Arqueo de caja y cobro del envío
--
--  Dos errores encontrados al probar el ciclo completo de un pedido a
--  domicilio. Los dos mueven dinero real:
--
--  1) ARQUEO MAL CALCULADO (afecta a TODAS las ventas en efectivo).
--     fn_cerrar_turno sumaba `monto - cambio`. Eso era correcto cuando el
--     cambio se calculaba sobre lo aplicado, pero en la migración 002 se
--     corrigió para calcularlo sobre lo que entrega el cliente, y el cierre
--     de turno no se revisó.
--     Venta de L50 pagando con L100: monto 50, cambio 50 → el arqueo decía
--     que entraron L0 a la gaveta. Lo que de verdad entra es `monto`, que
--     por definición es recibido − cambio.
--
--  2) EL ENVÍO NO SE COBRABA EN LA VENTA.
--     El pedido cobraba L263 (L238 de producto + L25 de envío) pero la venta
--     solo registraba los L238 del producto. El cambio salía sobre el total
--     equivocado: la caja devolvía L262 en vez de L237, regalando el envío
--     completo en cada pedido. Y la gaveta quedaba descuadrada por L25.
--
--     Se resuelve tratando el envío como lo que es: un servicio vendido.
--     Entra como una línea más de la venta, sin tocar inventario.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Arqueo
-- ---------------------------------------------------------------------------

create or replace function fn_cerrar_turno(
  p_turno_id uuid,
  p_monto_declarado numeric,
  p_notas text default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  t          record;
  v_efectivo numeric;
  v_esperado numeric;
begin
  select * into t from turnos_caja where id = p_turno_id for update;
  if t.id is null or t.estado <> 'abierto' then
    raise exception 'El turno no está abierto';
  end if;

  -- `monto` es lo que quedó en la gaveta por esa venta: el cliente entregó
  -- `recibido` y se le devolvió `cambio`.
  select coalesce(sum(pv.monto), 0) into v_efectivo
  from pagos_venta pv
  join ventas ve on ve.id = pv.venta_id
  where ve.turno_id = p_turno_id
    and ve.estado = 'completada'
    and pv.metodo = 'efectivo';

  v_esperado := t.monto_inicial + v_efectivo;

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
    'efectivo_ventas', v_efectivo,
    'esperado',        v_esperado,
    'declarado',       p_monto_declarado,
    'diferencia',      p_monto_declarado - v_esperado
  );
end $$;

revoke execute on function fn_cerrar_turno(uuid, numeric, text) from public, anon;
grant  execute on function fn_cerrar_turno(uuid, numeric, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 2. Servicios en la venta (envío, y lo que venga después)
--
--    Un producto de tipo `servicio` no tiene existencia ni lote: no se
--    descarga del inventario. Y su precio va en la línea, porque el envío
--    cambia según la distancia.
-- ---------------------------------------------------------------------------

create or replace function fn_registrar_venta(
  p_desbloqueo_id uuid,
  p_items         jsonb,
  p_pagos         jsonb,
  p_cliente_id    uuid default null,
  p_fiscal        boolean default false
) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d           record;
  t           record;
  o           record;
  it          jsonb;
  pg          jsonb;
  v_venta_id  uuid;
  v_numero    text;
  v_prod      record;
  v_cant      numeric;
  v_precio    numeric;
  v_desc      numeric;
  v_tasa      numeric;
  v_linea     numeric;
  v_costo     numeric;
  v_sub       numeric := 0;
  v_imp       numeric := 0;
  v_desctot   numeric := 0;
  v_costotot  numeric := 0;
  v_total     numeric := 0;
  v_pagado    numeric := 0;
  v_cambio    numeric := 0;
  v_recibido  numeric := 0;
  v_credito   boolean := false;
  v_tipo      tipo_documento_fiscal := 'ticket';
  v_numfiscal text;
  v_cai       text;
  s           record;
begin
  select * into d from caja_desbloqueos where id = p_desbloqueo_id for update;
  if d.id is null then
    raise exception 'Caja bloqueada: digite el PIN para iniciar la venta';
  end if;
  if d.consumido_en is not null then
    raise exception 'Este desbloqueo ya se usó. Digite el PIN de nuevo';
  end if;
  if d.expira_en < now() then
    raise exception 'El desbloqueo expiró. Digite el PIN de nuevo';
  end if;

  select * into t from turnos_caja where id = d.turno_id;
  if t.estado <> 'abierto' then raise exception 'El turno de caja está cerrado'; end if;

  select * into o from organizaciones where id = t.organizacion_id;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'La venta no tiene productos';
  end if;

  v_numero := 'T-' || lpad(fn_siguiente_numero(t.organizacion_id, t.sucursal_id, 'ticket')::text, 8, '0');

  if p_fiscal and o.facturacion_fiscal_activa then
    select * into s from series_fiscales
     where sucursal_id = t.sucursal_id and tipo_documento = 'factura' and activa
       and correlativo_actual <= correlativo_final
       and (fecha_limite_emision is null or fecha_limite_emision >= current_date)
     order by creada_en limit 1
     for update;

    if s.id is null then
      raise exception 'No hay rango de facturación autorizado disponible';
    end if;

    v_tipo      := 'factura';
    v_numfiscal := s.prefijo || '-' || lpad(s.correlativo_actual::text, 8, '0');
    v_cai       := s.cai;
    update series_fiscales set correlativo_actual = correlativo_actual + 1 where id = s.id;
  end if;

  insert into ventas (organizacion_id, sucursal_id, caja_id, turno_id, cajero_id,
                      cliente_id, numero, tipo_documento, numero_fiscal, cai)
  values (t.organizacion_id, t.sucursal_id, t.caja_id, t.id, d.cajero_id,
          p_cliente_id, v_numero, v_tipo, v_numfiscal, v_cai)
  returning id into v_venta_id;

  for it in select * from jsonb_array_elements(p_items) loop
    select p.*, coalesce(i.tasa, 0) as tasa, coalesce(i.incluido_en_precio, true) as incluido
      into v_prod
    from productos p
    left join impuestos i on i.id = p.impuesto_id
    where p.id = (it->>'producto_id')::uuid;

    if v_prod.id is null then
      raise exception 'Producto % inexistente', it->>'producto_id';
    end if;

    v_cant := (it->>'cantidad')::numeric;
    if v_cant is null or v_cant <= 0 then
      raise exception 'Cantidad inválida en %', v_prod.nombre;
    end if;

    -- Un servicio lleva su precio en la línea (el envío varía por distancia).
    -- Todo lo demás lo pone el servidor, nunca el cliente.
    if v_prod.tipo = 'servicio' and (it ? 'precio') then
      v_precio := (it->>'precio')::numeric;
      if v_precio is null or v_precio < 0 then
        raise exception 'Precio inválido para %', v_prod.nombre;
      end if;
    else
      v_precio := coalesce(
        fn_precio_vigente(v_prod.id, t.sucursal_id, v_cant,
                          coalesce((it->>'nivel')::nivel_precio, 'detalle')), 0);
      if v_precio = 0 then
        raise exception 'El producto % no tiene precio asignado', v_prod.nombre;
      end if;
    end if;

    v_desc  := coalesce((it->>'descuento')::numeric, 0);
    v_tasa  := v_prod.tasa;
    v_linea := (v_precio * v_cant) - v_desc;

    -- Un servicio no sale del inventario
    if v_prod.tipo = 'servicio' then
      v_costo := 0;
    else
      v_costo := fn_descontar_fefo(t.sucursal_id, v_prod.id, v_cant,
                                   'venta', v_venta_id, d.cajero_id);
    end if;

    insert into venta_detalle (organizacion_id, venta_id, producto_id, cantidad,
                               precio_unitario, descuento, tasa_impuesto,
                               impuesto_incluido, costo_unitario, total)
    values (t.organizacion_id, v_venta_id, v_prod.id, v_cant,
            v_precio, v_desc, v_tasa, v_prod.incluido,
            case when v_cant > 0 then v_costo / v_cant else 0 end, v_linea);

    if v_prod.incluido then
      v_sub := v_sub + (v_linea / (1 + v_tasa));
      v_imp := v_imp + (v_linea - (v_linea / (1 + v_tasa)));
    else
      v_sub := v_sub + v_linea;
      v_imp := v_imp + (v_linea * v_tasa);
    end if;

    v_desctot  := v_desctot + v_desc;
    v_costotot := v_costotot + v_costo;
  end loop;

  v_total := round(v_sub + v_imp, 2);

  for pg in select * from jsonb_array_elements(coalesce(p_pagos, '[]'::jsonb)) loop
    if (pg->>'metodo') = 'credito' then
      v_credito := true;
      if p_cliente_id is null then
        raise exception 'Una venta al crédito requiere cliente';
      end if;
    end if;
    v_pagado   := v_pagado + (pg->>'monto')::numeric;
    v_recibido := v_recibido + coalesce((pg->>'recibido')::numeric, (pg->>'monto')::numeric);

    insert into pagos_venta (organizacion_id, venta_id, metodo, monto, recibido, referencia)
    values (t.organizacion_id, v_venta_id, (pg->>'metodo')::metodo_pago,
            (pg->>'monto')::numeric, (pg->>'recibido')::numeric, pg->>'referencia');
  end loop;

  if round(v_pagado, 2) < v_total then
    raise exception 'Pago insuficiente: total %, recibido %', v_total, v_pagado;
  end if;
  v_cambio := greatest(round(v_recibido - v_total, 2), 0);

  update pagos_venta set cambio = v_cambio
   where venta_id = v_venta_id and metodo = 'efectivo'
     and id = (select pv.id from pagos_venta pv where pv.venta_id = v_venta_id
               and pv.metodo = 'efectivo' order by pv.creado_en desc limit 1);

  update ventas
     set subtotal = round(v_sub, 2), impuesto = round(v_imp, 2),
         descuento = round(v_desctot, 2), total = v_total,
         costo_total = round(v_costotot, 2), es_credito = v_credito
   where id = v_venta_id;

  if v_credito then
    update clientes set saldo = saldo + v_total, actualizado_en = now()
     where id = p_cliente_id;
  end if;

  update caja_desbloqueos
     set consumido_en = now(), venta_id = v_venta_id
   where id = p_desbloqueo_id;

  return jsonb_build_object(
    'venta_id', v_venta_id, 'numero', v_numero, 'documento', v_tipo,
    'numero_fiscal', v_numfiscal,
    'subtotal', round(v_sub, 2), 'impuesto', round(v_imp, 2), 'total', v_total,
    'pagado', round(v_pagado, 2), 'cambio', v_cambio, 'caja_bloqueada', true
  );
end $$;

revoke execute on function fn_registrar_venta(uuid, jsonb, jsonb, uuid, boolean) from public, anon;
grant  execute on function fn_registrar_venta(uuid, jsonb, jsonb, uuid, boolean) to authenticated;


-- ---------------------------------------------------------------------------
-- 3. Producto de servicio para el envío
--    Se crea uno por organización, la primera vez que se factura un pedido
--    con costo de envío. Queda fuera del catálogo del POS y del cliente
--    (se_vende = false) para que nadie lo agregue a mano por error.
-- ---------------------------------------------------------------------------

create or replace function app.producto_envio(p_org uuid)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id  uuid;
  v_imp uuid;
begin
  select id into v_id from productos
   where organizacion_id = p_org and sku = 'SERV-ENVIO';
  if v_id is not null then return v_id; end if;

  select id into v_imp from impuestos
   where organizacion_id = p_org and es_predeterminado and activo limit 1;

  insert into productos (organizacion_id, sku, nombre, descripcion, impuesto_id,
                         tipo, unidad_base, se_vende, se_compra, activo)
  values (p_org, 'SERV-ENVIO', 'Envío a domicilio',
          'Servicio de entrega. Se agrega solo al facturar un pedido.',
          v_imp, 'servicio', 'SERV', false, false, true)
  returning id into v_id;

  return v_id;
end $$;


-- ---------------------------------------------------------------------------
-- 4. Facturar el pedido cobrando el envío
-- ---------------------------------------------------------------------------

create or replace function fn_facturar_pedido(
  p_pedido_id     uuid,
  p_desbloqueo_id uuid,
  p_fiscal        boolean default false
) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p       record;
  v_items jsonb;
  v_pagos jsonb;
  v_res   jsonb;
  v_envio uuid;
begin
  select * into p from pedidos where id = p_pedido_id for update;
  if p.id is null then raise exception 'Pedido inexistente'; end if;
  if p.venta_id is not null then raise exception 'El pedido ya fue facturado'; end if;
  if p.estado = 'cancelado' then raise exception 'El pedido está cancelado'; end if;

  select jsonb_agg(jsonb_build_object(
           'producto_id', producto_id,
           'cantidad', coalesce(cantidad_surtida, cantidad)))
    into v_items
  from pedido_detalle
  where pedido_id = p_pedido_id and coalesce(cantidad_surtida, cantidad) > 0;

  if v_items is null then raise exception 'El pedido no tiene nada que surtir'; end if;

  -- El envío entra como una línea de servicio, así el total de la venta
  -- coincide con lo que se le cobra al cliente y el cambio sale correcto.
  if coalesce(p.costo_envio, 0) > 0 then
    v_envio := app.producto_envio(p.organizacion_id);
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'producto_id', v_envio,
      'cantidad', 1,
      'precio', p.costo_envio));
  end if;

  v_pagos := jsonb_build_array(jsonb_build_object(
    'metodo',   p.metodo_pago::text,
    'monto',    p.total,
    'recibido', coalesce(p.paga_con, p.total)));

  update pedido_reservas set liberada_en = now()
   where pedido_id = p_pedido_id and liberada_en is null;

  v_res := fn_registrar_venta(p_desbloqueo_id, v_items, v_pagos, p.cliente_id, p_fiscal);

  update pedidos set venta_id = (v_res->>'venta_id')::uuid where id = p_pedido_id;

  insert into pedido_eventos (organizacion_id, pedido_id, estado, usuario_id, nota)
  values (p.organizacion_id, p_pedido_id, p.estado, auth.uid(),
          'Facturado: ' || coalesce(v_res->>'numero_fiscal', v_res->>'numero'));

  return v_res || jsonb_build_object('pedido', p.numero);
end $$;

revoke execute on function fn_facturar_pedido(uuid, uuid, boolean) from public, anon;
grant  execute on function fn_facturar_pedido(uuid, uuid, boolean) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. El margen no debe contar el envío como ganancia de producto
-- ---------------------------------------------------------------------------

drop view if exists v_margen_productos;

create view v_margen_productos as
select
  vd.organizacion_id,
  v.sucursal_id,
  vd.producto_id,
  p.nombre                       as producto,
  date_trunc('day', v.creada_en) as dia,
  sum(vd.cantidad)               as unidades,
  round(sum(case when vd.impuesto_incluido
                 then vd.total / (1 + vd.tasa_impuesto)
                 else vd.total end), 2)            as venta_neta,
  round(sum(vd.costo_unitario * vd.cantidad), 2)   as costo,
  round(sum(case when vd.impuesto_incluido
                 then vd.total / (1 + vd.tasa_impuesto)
                 else vd.total end)
        - sum(vd.costo_unitario * vd.cantidad), 2) as margen
from venta_detalle vd
join ventas v    on v.id = vd.venta_id and v.estado = 'completada'
join productos p on p.id = vd.producto_id
where p.tipo <> 'servicio'
group by vd.organizacion_id, v.sucursal_id, vd.producto_id, p.nombre,
         date_trunc('day', v.creada_en);

alter view v_margen_productos set (security_invoker = on);
grant select on v_margen_productos to authenticated;
