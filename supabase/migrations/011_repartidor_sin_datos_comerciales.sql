-- ============================================================================
--  Migración 011 · El repartidor no ve la información comercial
--
--  Al probar el tablero salió que un usuario con rol repartidor podía leer:
--    · las facturas de compra CON SU DETALLE (10 líneas con costo unitario)
--    · los proveedores del negocio
--    · los precios de venta de todo el catálogo
--    · las existencias y los lotes
--
--  La causa: las políticas de lectura de la migración 001 solo comprobaban
--  `organizacion_id = app.org_id()`. Un repartidor SÍ tiene perfil en la
--  organización, así que pasaba el filtro. Cuando se creó ese esquema el rol
--  repartidor todavía no existía (llegó en la 002a) y las políticas nunca se
--  revisaron.
--
--  Un repartidor puede llevar pedidos de dos tiendas del mismo barrio. Ver a
--  qué costo compra la competencia no es un detalle menor.
--
--  Se exige nivel de auxiliar (1) para leer. El repartidor sigue viendo lo
--  suyo: sus pedidos asignados y, por fn_pedido_lineas, qué debe entregar.
-- ============================================================================

do $$
declare
  t text;
  -- Todo lo que es información del negocio, no de la entrega
  comerciales text[] := array[
    'sucursales','categorias','marcas','proveedores','impuestos',
    'productos','presentaciones','producto_codigos','precios','series_fiscales',
    'lotes','existencias',
    'ordenes_compra','orden_compra_detalle',
    'facturas_compra','factura_compra_detalle','pagos_compra'
  ];
begin
  foreach t in array comerciales loop
    -- se reemplaza la política de lectura por una con nivel mínimo
    execute format('drop policy if exists %I on %I', t || '_sel', t);
    execute format(
      'create policy %I on %I for select
         using ((organizacion_id = app.org_id() and app.tiene_nivel(''auxiliar''))
                or app.es_admin())',
      t || '_sel', t);
  end loop;
end $$;


-- ---------------------------------------------------------------------------
--  Lo que el repartidor SÍ necesita: los datos de entrega de sus pedidos.
--  Va por función para no abrirle ninguna tabla.
-- ---------------------------------------------------------------------------

create or replace function fn_mis_entregas()
returns table (
  pedido_id    uuid,
  numero       text,
  estado       estado_pedido,
  cliente      text,
  telefono     text,
  direccion    text,
  referencia   text,
  latitud      numeric,
  longitud     numeric,
  total        numeric,
  metodo_pago  metodo_pago,
  paga_con     numeric,
  cobrado      boolean,
  notas        text,
  productos    int,
  creado_en    timestamptz
)
language sql stable security definer set search_path = public, app as $$
  select
    p.id, p.numero, p.estado,
    coalesce(cl.nombre, p.nombre_contacto, 'Cliente'),
    coalesce(cl.telefono, p.telefono_contacto),
    coalesce(p.direccion_texto, dc.direccion),
    coalesce(dc.referencia, p.referencia),
    dc.latitud, dc.longitud,
    p.total, p.metodo_pago, p.paga_con,
    p.venta_id is not null,
    p.notas,
    (select count(*)::int from pedido_detalle d where d.pedido_id = p.id),
    p.creado_en
  from pedidos p
  left join clientes cl            on cl.id = p.cliente_id
  left join direcciones_cliente dc on dc.id = p.direccion_id
  where p.repartidor_id = auth.uid()
    and p.estado in ('listo', 'en_ruta')
  order by p.creado_en
$$;

revoke execute on function fn_mis_entregas() from public, anon;
grant  execute on function fn_mis_entregas() to authenticated;
