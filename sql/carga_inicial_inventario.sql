-- ============================================================================
--  CARGA INICIAL DE MERCADERÍA
--
--  El POS muestra todo AGOTADO porque nunca ha entrado inventario. Este
--  script registra una factura de compra de prueba y la confirma, que es
--  la forma correcta de que entre mercadería: crea lotes, mueve el kardex
--  y calcula el costo promedio.
--
--  OJO: el kardex es inmutable a propósito. Estos movimientos quedan en el
--  historial para siempre. Está bien para un negocio de prueba; si esta
--  organización va a ser la real, mejor cargue sus compras de verdad.
--
--  Los costos van al 65% del precio de venta, un margen típico de pulpería.
-- ============================================================================

do $$
declare
  v_org      uuid;
  v_suc      uuid;
  v_prov     uuid;
  v_factura  uuid;
  r          record;
  v_costo    numeric;
  v_cant     numeric;
begin
  select id into v_org from organizaciones order by creada_en limit 1;
  if v_org is null then
    raise exception 'No hay ninguna organización. Ejecute antes semilla_inicial.sql';
  end if;

  select id into v_suc from sucursales
   where organizacion_id = v_org and activa
   order by es_principal desc limit 1;

  -- ---------- proveedor ----------
  select id into v_prov from proveedores
   where organizacion_id = v_org and nombre = 'Distribuidora de prueba';
  if v_prov is null then
    insert into proveedores (organizacion_id, nombre, contacto, telefono,
                             dias_credito, dias_entrega)
    values (v_org, 'Distribuidora de prueba', 'Ventas', '2200-0000', 15, 4)
    returning id into v_prov;
  end if;

  -- ---------- factura de compra ----------
  if exists (select 1 from facturas_compra
              where organizacion_id = v_org and numero = 'CARGA-INICIAL') then
    raise notice 'La carga inicial ya se hizo antes. No se repite.';
    return;
  end if;

  insert into facturas_compra (organizacion_id, sucursal_id, proveedor_id,
                               numero, fecha, fecha_vencimiento, notas)
  values (v_org, v_suc, v_prov, 'CARGA-INICIAL', current_date,
          current_date + 15, 'Carga inicial de inventario para pruebas')
  returning id into v_factura;

  -- ---------- renglones ----------
  for r in
    select p.id, p.sku, p.nombre, p.controla_vencimiento,
           coalesce(fn_precio_vigente(p.id, v_suc, 1), 0) as precio
    from productos p
    where p.organizacion_id = v_org and p.activo and p.se_compra
    order by p.nombre
  loop
    if r.precio = 0 then
      raise notice 'Se omite % porque no tiene precio', r.nombre;
      continue;
    end if;

    v_costo := round(r.precio * 0.65, 2);

    -- más unidades de lo barato, menos de lo caro
    v_cant := case
      when r.precio < 30  then 60
      when r.precio < 60  then 40
      when r.precio < 100 then 24
      else 12
    end;

    insert into factura_compra_detalle (
      organizacion_id, factura_compra_id, producto_id, cantidad,
      costo_unitario, tasa_impuesto, lote_codigo, fecha_vencimiento
    ) values (
      v_org, v_factura, r.id, v_cant, v_costo, 0.15,
      case when r.controla_vencimiento then 'L-' || to_char(current_date, 'YYMMDD') end,
      -- lo perecedero vence pronto, para que se vea el semáforo del POS
      case when r.controla_vencimiento then current_date + 12 end
    );
  end loop;

  -- ---------- confirmar: aquí es donde entra al inventario ----------
  perform fn_confirmar_factura_compra(v_factura);

  raise notice 'Mercadería cargada con la factura CARGA-INICIAL.';
  raise notice 'Recargue el POS y ya podrá vender.';
end $$;


-- Cómo quedó el inventario
select
  producto,
  cantidad                        as existencia,
  costo_promedio,
  round(valor_inventario, 2)      as valor
from v_existencias
order by producto;
