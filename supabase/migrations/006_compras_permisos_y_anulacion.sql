-- ============================================================================
--  Migración 006 · Compras: permisos, anulación y catálogo de entrada
--
--  fn_confirmar_factura_compra es SECURITY DEFINER y no verificaba quién la
--  llamaba: bastaba conocer el UUID de una factura para meter mercadería al
--  inventario de otro negocio. Se le agrega la validación.
-- ============================================================================

alter table facturas_compra
  add column if not exists anulada_en       timestamptz,
  add column if not exists anulada_por      uuid references perfiles(id),
  add column if not exists motivo_anulacion text;

create or replace function fn_confirmar_factura_compra(p_factura_id uuid)
returns void
language plpgsql security definer set search_path = public, app as $$
declare
  f            record;
  d            record;
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

  -- auth.uid() nulo = ejecución del lado del servidor (SQL Editor, service_role)
  if auth.uid() is not null
     and not (app.es_admin()
              or (f.organizacion_id = app.org_id() and app.tiene_nivel('supervisor'))) then
    raise exception 'No tiene permiso para confirmar esta compra';
  end if;

  if f.estado <> 'borrador' then
    raise exception 'Solo se confirman facturas en borrador (estado actual: %)', f.estado;
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


-- Anular una compra ya confirmada: devuelve todo con un movimiento contrario.
-- Si la mercadería ya se vendió, fn_kardex_registrar lo impide y la anulación
-- falla. Eso es correcto: primero hay que resolver las ventas.
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

  if not (app.es_admin()
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


-- ============================================================================
--  Catálogo para la pantalla de entrada de mercadería
-- ============================================================================

create view v_catalogo_compra as
select
  p.organizacion_id,
  s.id                              as sucursal_id,
  p.id                              as producto_id,
  p.sku,
  p.nombre,
  p.unidad_base,
  p.controla_lote,
  p.controla_vencimiento,
  coalesce(i.tasa, 0)               as tasa_impuesto,
  coalesce(c.nombre, 'Sin categoría') as categoria,
  prov.nombre                       as proveedor,
  fn_precio_vigente(p.id, s.id, 1)  as precio_venta,
  coalesce(pc.ultimo_costo, 0)      as ultimo_costo,
  coalesce(pc.costo_promedio, 0)    as costo_promedio,
  coalesce(ex.cantidad, 0)          as existencia,
  array(select codigo from producto_codigos pk where pk.producto_id = p.id) as codigos,
  coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', pr.id, 'nombre', pr.nombre,
             'factor', pr.factor, 'es_compra', pr.es_compra)
           order by pr.factor)
    from presentaciones pr
    where pr.producto_id = p.id and pr.activa
  ), '[]'::jsonb)                   as presentaciones
from productos p
cross join sucursales s
left join categorias c   on c.id = p.categoria_id
left join impuestos i    on i.id = p.impuesto_id
left join proveedores prov on prov.id = p.proveedor_id
left join producto_costos pc on pc.producto_id = p.id and pc.sucursal_id = s.id
left join (
  select producto_id, sucursal_id, sum(cantidad) as cantidad
  from existencias group by producto_id, sucursal_id
) ex on ex.producto_id = p.id and ex.sucursal_id = s.id
where p.activo and p.se_compra
  and s.organizacion_id = p.organizacion_id
  and s.activa;

alter view v_catalogo_compra set (security_invoker = on);
grant select on v_catalogo_compra to authenticated;


-- Historial de compras con el nombre del proveedor ya resuelto
create view v_compras as
select
  f.organizacion_id, f.sucursal_id, f.id, f.numero, f.fecha, f.fecha_vencimiento,
  pr.nombre as proveedor, f.proveedor_id, f.estado,
  f.subtotal, f.impuesto, f.total, f.saldo,
  f.creada_en, f.confirmada_en, f.motivo_anulacion,
  pe.nombre as creada_por_nombre,
  (select count(*) from factura_compra_detalle d where d.factura_compra_id = f.id) as lineas,
  (select coalesce(sum(pg.monto), 0) from pagos_compra pg where pg.factura_compra_id = f.id) as pagado
from facturas_compra f
join proveedores pr on pr.id = f.proveedor_id
left join perfiles pe on pe.id = f.creada_por;

alter view v_compras set (security_invoker = on);
grant select on v_compras to authenticated;
