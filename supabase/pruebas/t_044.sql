\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- Sobre la semilla de t_pedidos: org 1 = La Esquina (Gerente 1, Auxiliar 1),
-- org 2 = Dona Chus (Gerente 2). Productos: Arroz 5lb y Frijol 1lb.
insert into auth.users (id, email) values ('bbbb0000-0000-0000-0000-000000000001','sup1@t.hn');
insert into perfiles (id, organizacion_id, nombre, email, rol, pin_pos, activo) values
 ('bbbb0000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
  'Supervisor Propio','sup1@t.hn','supervisor', crypt('77777', gen_salt('bf')), true);
insert into usuario_sucursales (perfil_id, sucursal_id) values
 ('bbbb0000-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');
insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa) values
 ('aaaa0000-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-000000000001',
  'bbbbbbbb-0000-0000-0000-000000000001','C1','Caja 1', true),
 ('aaaa0000-0000-0000-0000-0000000000c2','aaaaaaaa-0000-0000-0000-000000000001',
  'bbbbbbbb-0000-0000-0000-000000000001','C2','Caja 2', true);

\echo '=== I1: los productos de la semilla ya tienen item de 5 dígitos y su código viejo ==='
select count(*) filter (where sku ~ '^[0-9]{5}$') = count(*) as todos_5,
       (select count(*) from producto_codigos where codigo in ('P1','P2')) as viejos_guardados
  from productos;
\echo '--- esperado: t | 2 o más ---'

\echo ''
\echo '=== I2: el gerente crea productos desde Catálogos ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
insert into productos (organizacion_id, sku, nombre) values
 ('aaaaaaaa-0000-0000-0000-000000000001', '', 'Sin item'),
 ('aaaaaaaa-0000-0000-0000-000000000001', 'MANT1LB', 'Con código propio'),
 ('aaaaaaaa-0000-0000-0000-000000000001', '51089', 'Con item de 5 ya pensado'),
 ('aaaaaaaa-0000-0000-0000-000000000001', 'P00077', 'Con relleno del Excel');
reset role;
select nombre, sku ~ '^[0-9]{5}$' as item5,
       (select string_agg(codigo, ',') from producto_codigos c where c.producto_id = p.id) as codigos
  from productos p where nombre like 'Sin item' or nombre like 'Con %' order by nombre;
select sku from productos where nombre = 'Con item de 5 ya pensado';
\echo '--- esperado: los cuatro con item; MANT1LB guardado como código; P00077 no; el de 51089 lo conserva ---'

\echo ''
\echo '=== I3: el item no se cambia desde la app ==='
\set ON_ERROR_STOP off
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
update productos set sku = '99999' where nombre = 'Sin item';
\echo '--- esperado: ERROR El item lo asigna el sistema ---'
update productos set nombre = 'Sin item (editado)' where nombre = 'Sin item';
\echo '--- esperado: UPDATE 1 (lo demás sí se edita) ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== I4: números de categoría, proveedor y cliente ==='
insert into categorias (organizacion_id, nombre) values ('aaaaaaaa-0000-0000-0000-000000000001', 'Bebidas'), ('aaaaaaaa-0000-0000-0000-000000000001', 'Lácteos');
insert into proveedores (organizacion_id, nombre) values ('aaaaaaaa-0000-0000-0000-000000000001', 'Distribuidora Uno'), ('aaaaaaaa-0000-0000-0000-000000000001', 'Distribuidora Dos');
insert into clientes (organizacion_id, nombre, telefono) values ('aaaaaaaa-0000-0000-0000-000000000001', 'Doña Marta', '9876-5432');
reset role;
select 'categoria' as que, nombre, numero from categorias where organizacion_id = 'aaaaaaaa-0000-0000-0000-000000000001'
union all select 'proveedor', nombre, numero from proveedores where organizacion_id = 'aaaaaaaa-0000-0000-0000-000000000001'
union all select 'cliente', nombre, numero from clientes where organizacion_id = 'aaaaaaaa-0000-0000-0000-000000000001'
order by 1, 3;
select numero from clientes where organizacion_id = 'aaaaaaaa-0000-0000-0000-000000000002';
\echo '--- esperado: categorías 1,2,3; proveedores 1001,1002; clientes 1001,1002; el de la otra pulpería empieza en 1001 ---'

\echo ''
\echo '=== I5: nadie cambia esos números ==='
\set ON_ERROR_STOP off
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
update categorias set numero = 50 where nombre = 'Bebidas';
\echo '--- esperado: ERROR Ese número lo asigna el sistema ---'
update proveedores set numero = 5000 where nombre = 'Distribuidora Uno';
\echo '--- esperado: ERROR Ese número lo asigna el sistema ---'
update proveedores set telefono = '2550-0000' where nombre = 'Distribuidora Uno';
\echo '--- esperado: UPDATE 1 ---'
\set ON_ERROR_STOP on


-- ===================================================================
--  Ventas para buscar. Cada una con su forma de pago y su efectivo.
-- ===================================================================
reset role;
select id as arroz from productos where nombre = 'Arroz 5lb' and organizacion_id = 'aaaaaaaa-0000-0000-0000-000000000001' \gset
update organizaciones set permite_stock_negativo = true where id = 'aaaaaaaa-0000-0000-0000-000000000001';
insert into productos (organizacion_id, sku, nombre, se_vende) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '', 'Frijol rojo 1lb', true);
select id as frijol from productos where nombre = 'Frijol rojo 1lb' \gset
insert into precios (organizacion_id, producto_id, nivel, cantidad_minima, precio, vigente_desde)
values ('aaaaaaaa-0000-0000-0000-000000000001', :'frijol', 'detalle', 1, 30, now() - interval '1 day');
select id as marta from clientes where nombre = 'Doña Marta' \gset
update clientes set limite_credito = 1000 where id = :'marta';

set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000c2','22222222-2222-2222-2222-222222222222','22222', 0) as t \gset

-- V1: 1 arroz, paga con 100 en efectivo
select fn_desbloquear_caja(:'t'::uuid,'22222') as d \gset
select (fn_registrar_venta(:'d'::uuid, jsonb_build_array(jsonb_build_object('producto_id', :'arroz', 'cantidad', 1)),
  jsonb_build_array(jsonb_build_object('metodo','efectivo','monto', fn_precio_vigente(:'arroz'::uuid, 'bbbbbbbb-0000-0000-0000-000000000001', 1), 'recibido', 100)))->>'venta_id') as v1 \gset
-- V2: 3 arroces, paga con 500 en efectivo
select fn_desbloquear_caja(:'t'::uuid,'22222') as d \gset
select (fn_registrar_venta(:'d'::uuid, jsonb_build_array(jsonb_build_object('producto_id', :'arroz', 'cantidad', 3)),
  jsonb_build_array(jsonb_build_object('metodo','efectivo','monto', 3 * fn_precio_vigente(:'arroz'::uuid, 'bbbbbbbb-0000-0000-0000-000000000001', 1), 'recibido', 500)))->>'venta_id') as v2 \gset
-- V3: 2 frijoles con tarjeta, a Doña Marta
select fn_desbloquear_caja(:'t'::uuid,'22222') as d \gset
select (fn_registrar_venta(:'d'::uuid, jsonb_build_array(jsonb_build_object('producto_id', :'frijol', 'cantidad', 2)),
  jsonb_build_array(jsonb_build_object('metodo','tarjeta','monto', 2 * fn_precio_vigente(:'frijol'::uuid, 'bbbbbbbb-0000-0000-0000-000000000001', 1))),
  :'marta')->>'venta_id') as v3 \gset
reset role;
select v.numero, v.total, (select string_agg(metodo || ' ' || coalesce(recibido::text,'-') || ' cambio ' || cambio, '; ') from pagos_venta where venta_id = v.id) pagos
  from ventas v where v.id in (:'v1', :'v2', :'v3') order by v.creada_en;
-- La V2 se hizo de noche (21:30 en Honduras) para probar las horas
update ventas set creada_en = ((current_date::timestamp + time '21:30') at time zone 'America/Tegucigalpa') where id = :'v2';
update ventas set creada_en = ((current_date::timestamp + time '09:15') at time zone 'America/Tegucigalpa') where id in (:'v1', :'v3');

\echo ''
\echo '=== B1: sin filtros, las tres; la auxiliar no ve la ganancia ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select r->'resumen'->>'ventas' as ventas, r->'resumen'->>'ganancia' as ganancia,
       r->'filas'->0 ? 'efectivo_recibido' as trae_efectivo
  from fn_buscar_ventas('{}') r;
\echo '--- esperado: 3 | (nulo) | t ---'

\echo ''
\echo '=== B2: el supervisor sí ve la ganancia ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select (fn_buscar_ventas('{}')->'resumen'->>'ganancia') is not null as ve_ganancia;
\echo '--- esperado: t ---'

\echo ''
\echo '=== B3: los filtros, uno por uno ==='
select
  (select jsonb_array_length(fn_buscar_ventas('{"metodo":"tarjeta"}')->'filas')) as tarjeta,
  (select jsonb_array_length(fn_buscar_ventas('{"metodo":"efectivo"}')->'filas')) as efectivo,
  (select jsonb_array_length(fn_buscar_ventas('{"efectivo_min":500,"efectivo_max":500}')->'filas')) as con_500,
  (select fn_buscar_ventas('{"efectivo_min":500}')->'filas'->0->>'venta_id' = :'v2') as es_v2,
  (select jsonb_array_length(fn_buscar_ventas('{"cambio_min":100}')->'filas')) as cambio_100,
  (select jsonb_array_length(fn_buscar_ventas('{"producto":"frijol"}')->'filas')) as frijol,
  (select jsonb_array_length(fn_buscar_ventas(jsonb_build_object('producto', 'P1'))->'filas')) as por_codigo_viejo,
  (select jsonb_array_length(fn_buscar_ventas('{"cliente":"marta"}')->'filas')) as marta,
  (select jsonb_array_length(fn_buscar_ventas('{"cliente":"1002"}')->'filas')) as cliente_1002;
\echo '--- esperado: 1 | 2 | 1 | t | 1 (la de 500) | 1 | 2 | 1 | 1 ---'

select
  (select jsonb_array_length(fn_buscar_ventas('{"hora_desde":"20:00","hora_hasta":"23:00"}')->'filas')) as de_noche,
  (select jsonb_array_length(fn_buscar_ventas('{"hora_desde":"20:00","hora_hasta":"10:00"}')->'filas')) as cruza_medianoche,
  (select jsonb_array_length(fn_buscar_ventas('{"hora_desde":"09:00"}')->'filas')) as desde_las_9,
  (select jsonb_array_length(fn_buscar_ventas(jsonb_build_object('monto_min', 100))->'filas')) as monto_100,
  (select jsonb_array_length(fn_buscar_ventas(jsonb_build_object('caja_id','aaaa0000-0000-0000-0000-0000000000c2'))->'filas')) as caja2,
  (select jsonb_array_length(fn_buscar_ventas(jsonb_build_object('caja_id','aaaa0000-0000-0000-0000-0000000000c1'))->'filas')) as caja1,
  (select jsonb_array_length(fn_buscar_ventas(jsonb_build_object('cajero_id','22222222-2222-2222-2222-222222222222'))->'filas')) as cajera,
  (select jsonb_array_length(fn_buscar_ventas(jsonb_build_object('desde', current_date - 3, 'hasta', current_date - 1))->'filas')) as otros_dias;
\echo '--- esperado: 1 | 3 | 3 | 1 o 2 según el precio | 3 | 0 | 3 | 0 ---'

\echo ''
\echo '=== B4: el resumen cuenta el efectivo recibido y el cambio ==='
select r->'resumen'->>'recibido' as recibido, r->'resumen'->>'cambio' as cambio
  from fn_buscar_ventas('{"metodo":"efectivo"}') r;
\echo '--- esperado: recibido 600 y el cambio que corresponda ---'

\echo ''
\echo '=== B5: el gerente de la OTRA pulpería no ve ninguna ==='
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select fn_buscar_ventas('{}')->'resumen'->>'filas' as ve;
\echo '--- esperado: 0 ---'

\echo ''
\echo '=== B6: anon no entra ==='
\set ON_ERROR_STOP off
set role anon;
select fn_buscar_ventas('{}');
\echo '--- esperado: ERROR permission denied ---'
set role authenticated;
select app.asignar_numero();
\echo '--- esperado: ERROR (las funciones de disparador no se llaman sueltas) ---'
\set ON_ERROR_STOP on
