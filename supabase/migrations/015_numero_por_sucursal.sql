-- ============================================================================
--  015 · El numero de venta tambien choca entre sucursales
--
--  Mismo defecto que se arreglo en pedidos (migracion 014), y aqui es peor:
--
--    secuencias  cuenta por (organizacion_id, sucursal_id, tipo)
--    ventas      exige UNIQUE (organizacion_id, numero)
--
--  En un negocio con dos sucursales, la caja de la primera emite T-00000001.
--  Cuando la caja de la segunda intenta su primera venta genera otra vez
--  T-00000001 y el insert revienta con llave duplicada. Esa caja NO PUEDE
--  VENDER hasta que los contadores se separen por su cuenta. Y el multisucursal
--  es parte del producto desde el primer dia.
--
--  Mis pruebas de venta nunca lo vieron porque todas usaban una sola sucursal.
--  Salio al probar los pedidos del cliente con dos sucursales de un negocio.
--
--  En vivo no ha pasado porque el unico negocio tiene una sola sucursal. Los
--  tres tickets ya emitidos (T-00000001 a T-00000003) se quedan como estan y
--  siguen siendo unicos; los nuevos llevan el codigo de la sucursal:
--  T-001-00000004.
--
--  Lo unico que cambia del cuerpo de fn_registrar_venta es la linea que arma
--  v_numero. Se reescribe completa porque en Postgres no se parcha un cuerpo.
-- ============================================================================


create or replace function fn_registrar_venta(
  p_desbloqueo_id uuid,
  p_items         jsonb,
  p_pagos         jsonb,
  p_cliente_id    uuid default null,
  p_fiscal        boolean default false
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  d           record;
  t           record;
  o           record;
  cl          record;
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
  v_credito   numeric := 0;
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
    raise exception 'Este desbloqueo ya se uso. Digite el PIN de nuevo';
  end if;
  if d.expira_en < now() then
    raise exception 'El desbloqueo expiro. Digite el PIN de nuevo';
  end if;

  select * into t from turnos_caja where id = d.turno_id;
  if t.estado <> 'abierto' then raise exception 'El turno de caja esta cerrado'; end if;

  select * into o from organizaciones where id = t.organizacion_id;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'La venta no tiene productos';
  end if;

  -- El cliente tiene que ser de este negocio. Sin esto una caja podia
  -- etiquetar la venta -y cargarle el fiado- a un cliente de otra pulperia.
  if p_cliente_id is not null then
    select * into cl from clientes
     where id = p_cliente_id and organizacion_id = t.organizacion_id;
    if cl.id is null then
      raise exception 'Cliente inexistente en este negocio';
    end if;
  end if;

  v_numero := app.numero_documento(t.organizacion_id, t.sucursal_id, 'ticket', 'T', 8);

  if p_fiscal and o.facturacion_fiscal_activa then
    select * into s from series_fiscales
     where sucursal_id = t.sucursal_id and tipo_documento = 'factura' and activa
       and correlativo_actual <= correlativo_final
       and (fecha_limite_emision is null or fecha_limite_emision >= current_date)
     order by creada_en limit 1
     for update;

    if s.id is null then
      raise exception 'No hay rango de facturacion autorizado disponible';
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
      raise exception 'Cantidad invalida en %', v_prod.nombre;
    end if;

    if v_prod.tipo = 'servicio' and (it ? 'precio') then
      v_precio := (it->>'precio')::numeric;
      if v_precio is null or v_precio < 0 then
        raise exception 'Precio invalido para %', v_prod.nombre;
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
      v_credito := v_credito + (pg->>'monto')::numeric;
    end if;
    v_pagado   := v_pagado + (pg->>'monto')::numeric;
    v_recibido := v_recibido + coalesce((pg->>'recibido')::numeric, (pg->>'monto')::numeric);

    insert into pagos_venta (organizacion_id, venta_id, metodo, monto, recibido, referencia)
    values (t.organizacion_id, v_venta_id, (pg->>'metodo')::metodo_pago,
            (pg->>'monto')::numeric, (pg->>'recibido')::numeric, pg->>'referencia');
  end loop;

  -- ---- control de fiado ----
  if v_credito > 0 then
    if p_cliente_id is null then
      raise exception 'Una venta al credito requiere cliente';
    end if;

    -- Se relee con for update: entre la validacion de arriba y aqui otra caja
    -- pudo haberle fiado al mismo cliente. El candado evita el doble fiado.
    select * into cl from clientes
     where id = p_cliente_id and organizacion_id = t.organizacion_id for update;
    if cl.id is null then raise exception 'Cliente inexistente en este negocio'; end if;
    if not cl.activo then raise exception 'El cliente % esta inactivo', cl.nombre; end if;

    if coalesce(cl.limite_credito, 0) <= 0 then
      raise exception 'A % no se le fia. Asignele un limite de credito primero', cl.nombre;
    end if;

    if round(coalesce(cl.saldo, 0) + v_credito, 2) > round(cl.limite_credito, 2) then
      raise exception 'Pasa del limite de %: debe % y su limite es %',
        cl.nombre, round(coalesce(cl.saldo, 0), 2), round(cl.limite_credito, 2);
    end if;
  end if;

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
         costo_total = round(v_costotot, 2), es_credito = v_credito > 0
   where id = v_venta_id;

  if v_credito > 0 then
    update clientes set saldo = saldo + v_credito, actualizado_en = now()
     where id = p_cliente_id;
  end if;

  update caja_desbloqueos
     set consumido_en = now(), venta_id = v_venta_id
   where id = p_desbloqueo_id;

  return jsonb_build_object(
    'venta_id', v_venta_id, 'numero', v_numero, 'documento', v_tipo,
    'numero_fiscal', v_numfiscal,
    'subtotal', round(v_sub, 2), 'impuesto', round(v_imp, 2), 'total', v_total,
    'pagado', round(v_pagado, 2), 'fiado', round(v_credito, 2),
    'cambio', v_cambio, 'caja_bloqueada', true
  );
end $fn$;

revoke execute on function fn_registrar_venta(uuid, jsonb, jsonb, uuid, boolean) from public, anon;
grant execute on function fn_registrar_venta(uuid, jsonb, jsonb, uuid, boolean) to authenticated;
