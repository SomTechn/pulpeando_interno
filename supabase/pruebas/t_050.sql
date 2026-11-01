\pset pager off
set role postgres;
-- Semilla de t_pedidos. Arroz exento (L 60); se agrega Coca 15% incluido (L 30).
insert into impuestos (id, organizacion_id, nombre, tasa, incluido_en_precio, es_predeterminado, activo)
values ('11110000-0000-0000-0000-000000000015','aaaaaaaa-0000-0000-0000-000000000001','ISV 15%',0.15,true,true,true);
insert into productos (id, organizacion_id, sku, nombre, categoria_id, tipo, unidad_base, activo, se_vende, impuesto_id) values
 ('eeeeeeee-0000-0000-0000-0000000000c0','aaaaaaaa-0000-0000-0000-000000000001','C1','Coca 600','dddddddd-0000-0000-0000-000000000001','unidad','unidad',true,true,'11110000-0000-0000-0000-000000000015');
insert into precios (organizacion_id, producto_id, sucursal_id, nivel, cantidad_minima, precio, vigente_desde)
values ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-0000000000c0','bbbbbbbb-0000-0000-0000-000000000001','detalle',1,30, now() - interval '1 day');
insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa) values
 ('aaaa0000-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','C1','Caja 1', true);
update organizaciones set permite_stock_negativo = true where id = 'aaaaaaaa-0000-0000-0000-000000000001';
insert into proveedores (id, organizacion_id, nombre, identificacion_fiscal) values
 ('fafa0000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Distribuidora Norte','08011999123456');
insert into clientes (organizacion_id, nombre, telefono, limite_credito) values ('aaaaaaaa-0000-0000-0000-000000000001', 'Doña Fía', '9000-0001', 1000);
select id as fia from clientes where nombre = 'Doña Fía' \gset

-- Ventas: v1 = 2 arroz + 2 coca en efectivo; v2 = 1 coca fiada; v3 = 1 arroz anulada
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000c1','11111111-1111-1111-1111-111111111111','11111', 0) as t \gset
select fn_desbloquear_caja(:'t'::uuid,'11111') as d \gset
select (fn_registrar_venta(:'d'::uuid, '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":2},{"producto_id":"eeeeeeee-0000-0000-0000-0000000000c0","cantidad":2}]'::jsonb,
  '[{"metodo":"efectivo","monto":180,"recibido":200}]'::jsonb) ->> 'venta_id') as v1 \gset
select fn_desbloquear_caja(:'t'::uuid,'11111') as d \gset
select (fn_registrar_venta(:'d'::uuid, '[{"producto_id":"eeeeeeee-0000-0000-0000-0000000000c0","cantidad":1}]'::jsonb,
  '[{"metodo":"credito","monto":30}]'::jsonb, :'fia'::uuid) ->> 'venta_id') as v2 \gset
select fn_desbloquear_caja(:'t'::uuid,'11111') as d \gset
select (fn_registrar_venta(:'d'::uuid, '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  '[{"metodo":"efectivo","monto":60,"recibido":60}]'::jsonb) ->> 'venta_id') as v3 \gset
select fn_anular_venta(:'v3'::uuid, 'prueba');
reset role;

-- Compra confirmada: 24 coca a L 20 (15%) y 10 arroz a L 45 (exento), vence hace 10 días
insert into facturas_compra (id, organizacion_id, sucursal_id, proveedor_id, numero, fecha, fecha_vencimiento, estado, creada_por)
values ('fcfc0000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',
        'fafa0000-0000-0000-0000-000000000001','000-001-01-00000123', current_date, current_date - 10, 'borrador',
        '11111111-1111-1111-1111-111111111111');
insert into factura_compra_detalle (organizacion_id, factura_compra_id, producto_id, cantidad, costo_unitario, descuento, tasa_impuesto) values
 ('aaaaaaaa-0000-0000-0000-000000000001','fcfc0000-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-0000000000c0',24,20,0,0.15),
 ('aaaaaaaa-0000-0000-0000-000000000001','fcfc0000-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',10,45,0,0);
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_confirmar_factura_compra('fcfc0000-0000-0000-0000-000000000001');
reset role;

\echo '=== F1: el ISV del período ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select c -> 'isv' -> 'ventas' -> '15' ->> 'base' as base15, c -> 'isv' -> 'ventas' -> '15' ->> 'isv' as isv15,
       c -> 'isv' -> 'ventas' -> '0' ->> 'base' as exento, c -> 'isv' -> 'compras' -> '15' ->> 'isv' as isv_compras,
       c -> 'isv' ->> 'debito' as debito, c -> 'isv' ->> 'credito' as credito,
       c -> 'isv' ->> 'a_pagar' as a_pagar, c -> 'isv' ->> 'a_favor' as a_favor
  from (select fn_contabilidad() c) x;
reset role;
select round(sum(impuesto), 2) as isv_en_ventas from ventas where organizacion_id = 'aaaaaaaa-0000-0000-0000-000000000001' and estado = 'completada';
select round(impuesto, 2) as isv_en_factura from facturas_compra where id = 'fcfc0000-0000-0000-0000-000000000001';
\echo '--- esperado: 78.26 | 11.74 | 120.00 | 72.00 | 11.74 | 72.00 | 0.00 | 60.26 ; el ISV de las ventas = 11.74 (la anulada no cuenta) ; 72.00 ---'

\echo ''
\echo '=== F2: cuentas por cobrar y por pagar ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select c -> 'cxc' ->> 'total' as cxc, c -> 'cxc' ->> 'clientes' as clientes, c -> 'cxc' -> 'mayores' -> 0 ->> 'cliente' as mayor,
       c -> 'cxp' ->> 'total' as cxp, c -> 'cxp' ->> 'v1_30' as vencido_1_30, c -> 'cxp' ->> 'por_vencer' as por_vencer,
       c -> 'cxp' -> 'proveedores' -> 0 ->> 'proveedor' as proveedor
  from (select fn_contabilidad() c) x;
reset role;
\echo '--- esperado: 30.00 | 1 | Doña Fía | 1002.00 | 1002.00 | 0.00 | Distribuidora Norte ---'

\echo ''
\echo '=== F3: seis meses de resultados, el último con la venta de hoy ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select jsonb_array_length(c -> 'meses') as meses, c -> 'meses' -> 5 ->> 'mes' = to_char(current_date, 'YYYY-MM') as ultimo_es_este,
       (c -> 'meses' -> 5 ->> 'venta_neta')::numeric as venta_neta
  from (select fn_contabilidad() c) x;
reset role;
\echo '--- esperado: 6 | t | 198.26 (78.26 + 120 sin ISV) ---'

\echo ''
\echo '=== F4: los libros ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select jsonb_array_length(l) as ventas, (select count(*) from jsonb_array_elements(l) e where e ->> 'estado' = 'anulada') as anuladas,
       (select e ->> 'cliente' from jsonb_array_elements(l) e where (e ->> 'total')::numeric = 30) as fiado_a
  from (select fn_libro_ventas() l) x;
select e ->> 'proveedor' as proveedor, e ->> 'rtn' as rtn, e ->> 'base_15' as base15, e ->> 'isv_15' as isv15, e ->> 'exento' as exento, e ->> 'total' as total
  from jsonb_array_elements(fn_libro_compras()) e;
reset role;
\echo '--- esperado: 3 | 1 | Doña Fía ; Distribuidora Norte | 08011999123456 | 480.00 | 72.00 | 450.00 | 1002.00 ---'

\echo ''
\echo '=== F5: solo el gerente ==='
insert into auth.users (id, email) values ('bbbb0000-0000-0000-0000-000000000001','sup1@t.hn');
insert into perfiles (id, organizacion_id, nombre, email, rol, activo) values
 ('bbbb0000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Supervisor','sup1@t.hn','supervisor', true);
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_contabilidad();
select fn_libro_ventas();
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select (fn_contabilidad() -> 'isv' ->> 'debito')::numeric as otro_negocio;
reset role;
select has_function_privilege('anon', 'fn_contabilidad(date,date,uuid)', 'execute') as anon;
\echo '--- esperado: 2 errores (gerente) ; 0 (no ve lo de La Esquina) ; f ---'
