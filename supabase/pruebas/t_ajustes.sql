\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- Sobre la semilla de t_pedidos:
--   org 1 "La Esquina"  sucursal bbbb...001  Arroz 50 (sin lote)
--   org 2 "Dona Chus"   sucursal bbbb...002  Frijol 50
insert into auth.users (id, email) values
  ('bbbb0000-0000-0000-0000-000000000001','sup1@t.hn'),
  ('bbbb0000-0000-0000-0000-000000000009','repa1@t.hn');
insert into perfiles (id, organizacion_id, nombre, email, rol, activo) values
 ('bbbb0000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Supervisor','sup1@t.hn','supervisor',true),
 ('bbbb0000-0000-0000-0000-000000000009','aaaaaaaa-0000-0000-0000-000000000001','Repartidor','repa1@t.hn','repartidor',true);
insert into usuario_sucursales (perfil_id, sucursal_id) values
 ('bbbb0000-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001'),
 ('bbbb0000-0000-0000-0000-000000000009','bbbbbbbb-0000-0000-0000-000000000001');

insert into productos (id, organizacion_id, sku, nombre, categoria_id, tipo,
                       unidad_base, activo, se_vende, controla_lote, controla_vencimiento)
values ('eeeeeeee-0000-0000-0000-00000000000b','aaaaaaaa-0000-0000-0000-000000000001',
        'P3','Leche litro','dddddddd-0000-0000-0000-000000000001','unidad','unidad',true,true,true,true);

insert into precios (organizacion_id, producto_id, sucursal_id, nivel, cantidad_minima, precio, vigente_desde)
values ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001','detalle',1,38, now()-interval '1 day');

insert into lotes (id, organizacion_id, producto_id, sucursal_id, codigo,
                   fecha_vencimiento, costo_ingreso)
values ('11110000-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001',
        'eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001',
        'L-ENE', current_date + 10, 25),
       ('11110000-0000-0000-0000-00000000000b','aaaaaaaa-0000-0000-0000-000000000001',
        'eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001',
        'L-FEB', current_date + 40, 25);

insert into existencias (organizacion_id, producto_id, sucursal_id, lote_id, cantidad) values
 ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001','11110000-0000-0000-0000-00000000000a', 6),
 ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001','11110000-0000-0000-0000-00000000000b', 12);

insert into producto_costos (organizacion_id, producto_id, sucursal_id, cantidad, valor, costo_promedio, ultimo_costo) values
 ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001',18,450,25,25);

-- Una segunda bodega, porque fn_solicitar_ajuste ya solo corrige bodegas:
-- el piso se cuenta completo con fn_solicitar_conteo_piso.
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_guardar_ubicacion('Bodega B', null,
       'bbbbbbbb-0000-0000-0000-000000000001', 220) is not null as creada_b;
set role postgres;
select id as bodb from ubicaciones where nombre='Bodega B' \gset
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_fijar_tipo_ubicacion(:'bodb', 'bodega') is not null as es_bodega;

-- El arroz: 30 a la bodega y 20 a la bodega B
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega'), 30) is not null as movido;
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-000000000001',
  :'bodb', 20) is not null as movido_b;

-- Un refrigerador con 4 litros del lote L-ENE. Es de bodega para poder
-- corregirlo lugar por lugar.
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_guardar_ubicacion('Refrigerador', null, 'bbbbbbbb-0000-0000-0000-000000000001', 20, true) is not null as creada;
set role postgres;
select id as refri from ubicaciones where nombre='Refrigerador' \gset
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_fijar_tipo_ubicacion(:'refri', 'bodega') is not null as refri_bodega;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-00000000000b',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Refrigerador'),
  4, null, '11110000-0000-0000-0000-00000000000a') is not null as movido2;

\echo '### Arroz: bodega B 20 · bodega 30 (total 50) · piso 0'
\echo '### Leche: L-ENE 6 (4 en refrigerador, 2 en piso) · L-FEB 12 en piso'


-- ===================================================================
\echo ''
\echo '=== A1: la AUXILIAR pide bajar la bodega B de arroz de 20 a 14 ==='
select fn_solicitar_ajuste('eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega B'),
  14, null, 'Conte el estante');

\echo ''
\echo '=== A1b: el inventario NO se movio todavia ==='
select (select coalesce(sum(cantidad),0) from existencias
         where producto_id='eeeeeeee-0000-0000-0000-000000000001'
           and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001') as total_arroz;
select ubicacion, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');
\echo '--- esperado: total 50, bodega B 20, bodega 30 ---'

\echo ''
\echo '=== A1c: y el perfil del producto lo avisa ==='
select jsonb_pretty(fn_consultar_producto('eeeeeeee-0000-0000-0000-000000000001')
  -> 'ajustes_pendientes') as pendientes;


-- ===================================================================
\echo ''
\echo '=== A2: la AUXILIAR no puede aprobarlo ==='
\set ON_ERROR_STOP off
select fn_resolver_ajuste((select id from ajustes_inventario where estado='pendiente'), true);
\echo '--- esperado: solo el gerente de este negocio ---'

\echo ''
\echo '=== A2b: ni el SUPERVISOR ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_resolver_ajuste((select id from ajustes_inventario where estado='pendiente'), true);
\echo '--- esperado: solo el gerente ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== A3: el gerente de la OTRA pulperia tampoco ==='
set role postgres;
select id as aj1 from ajustes_inventario where estado='pendiente' \gset
set role authenticated;
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
\set ON_ERROR_STOP off
select fn_resolver_ajuste(:'aj1', true);
\echo '--- esperado: solo el gerente de ESTE negocio ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== A4: dos pedidos iguales no se encolan ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
select fn_solicitar_ajuste('eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega B'),
  11);
\echo '--- esperado: ya hay un ajuste pendiente ---'

\echo ''
\echo '=== A5: pedir el mismo numero que ya dice el sistema no es ajuste ==='
select fn_solicitar_ajuste('eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega'),
  30);
\echo '--- esperado: el sistema ya dice 30 ---'

\echo ''
\echo '=== A5b: ni una cantidad negativa ==='
select fn_solicitar_ajuste('eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega'),
  -3);
\echo '--- esperado: no puede ser negativa ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== A6: la lista. La auxiliar no ve cuanto vale la diferencia ==='
select numero, producto, ubicacion, sistema, contado, diferencia, valor, solicitado_por
from fn_ajustes('pendiente');

\echo ''
\echo '=== A6b: el supervisor si ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select numero, ubicacion, diferencia, valor from fn_ajustes('pendiente');
\echo '--- esperado: -6 al costo 40 = -240 ---'

\echo ''
\echo '=== A6c: la otra pulperia no ve nada de esto ==='
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select count(*) as ajustes_ajenos_visibles from fn_ajustes('todos');
\echo '--- esperado: 0 ---'


-- ===================================================================
\echo ''
\echo '=== A7: el GERENTE lo aprueba ==='
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_resolver_ajuste(:'aj1', true);

\echo ''
\echo '=== A7b: bajo el total y quedo en la BODEGA B, la otra intacta ==='
select (select coalesce(sum(cantidad),0) from existencias
         where producto_id='eeeeeeee-0000-0000-0000-000000000001'
           and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001') as total_arroz;
select ubicacion, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');
\echo '--- esperado: total 44, bodega B 14, bodega 30 ---'

\echo ''
\echo '=== A7c: quedo en el kardex como ajuste negativo ==='
select tipo, cantidad, documento_tipo, notas from kardex
 where producto_id='eeeeeeee-0000-0000-0000-000000000001' and documento_tipo='ajuste';

\echo ''
\echo '=== A7d: y ya no se puede volver a resolver ==='
\set ON_ERROR_STOP off
select fn_resolver_ajuste(:'aj1', true);
\echo '--- esperado: ya se habia aprobado ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== A8: ajustar una ubicacion que NO es la predeterminada ==='
\echo '--- el refrigerador dice 4 del lote L-ENE y solo hay 2 ---'
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_solicitar_ajuste('eeeeeeee-0000-0000-0000-00000000000b',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Refrigerador'),
  2, '11110000-0000-0000-0000-00000000000a', 'Se me cayeron dos');

set role postgres;
select id as aj2 from ajustes_inventario where estado='pendiente' \gset
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_resolver_ajuste(:'aj2', true);

\echo ''
\echo '=== A8b: bajo el refrigerador, NO el piso ==='
select ubicacion, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001');
select (select coalesce(sum(cantidad),0) from existencias
         where producto_id='eeeeeeee-0000-0000-0000-00000000000b'
           and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001') as total_leche;
\echo '--- esperado: total 16 · refrigerador 2 · el resto en el piso ---'

\echo ''
\echo '=== A8c: y bajo del LOTE correcto ==='
select l.codigo, e.cantidad from existencias e join lotes l on l.id = e.lote_id
 where e.producto_id='eeeeeeee-0000-0000-0000-00000000000b'
   and e.sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' order by l.codigo;
\echo '--- esperado: L-ENE 4, L-FEB 12 ---'


-- ===================================================================
\echo ''
\echo '=== A9: entre pedir y aprobar se vende. La venta se respeta ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_solicitar_ajuste('eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega'),
  25, null, 'Falta una bolsa');
\echo '--- pedido: bodega de 30 a 25 (dif -5) ---'

set role postgres;
select id as aj3 from ajustes_inventario where estado='pendiente' \gset
\echo '--- ahora se venden 10 (total 44 -> 34) ---'
select fn_kardex_registrar('bbbbbbbb-0000-0000-0000-000000000001',
  'eeeeeeee-0000-0000-0000-000000000001','venta', 10, null, null,
  'venta', null, 'prueba', '11111111-1111-1111-1111-111111111111') is not null as vendido;

set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_resolver_ajuste(:'aj3', true);
\echo ''
select (select coalesce(sum(cantidad),0) from existencias
         where producto_id='eeeeeeee-0000-0000-0000-000000000001'
           and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001') as total_arroz;
select ubicacion, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');
\echo '--- esperado: total 29 (34 menos los 5 del ajuste), NO 25 ---'
\echo '--- bodega 25, piso 4 ---'


-- ===================================================================
\echo ''
\echo '=== A10: un sobrante entra al costo promedio ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_solicitar_ajuste('eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega B'),
  9, null, 'Aparecieron cinco');
set role postgres;
select id as aj4 from ajustes_inventario where estado='pendiente' \gset
select costo_promedio as costo_antes from producto_costos
 where producto_id='eeeeeeee-0000-0000-0000-000000000001'
   and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001';
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_resolver_ajuste(:'aj4', true);
set role postgres;
select costo_promedio as costo_despues from producto_costos
 where producto_id='eeeeeeee-0000-0000-0000-000000000001'
   and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001';
\echo '--- esperado: el costo promedio no se movio ---'


-- ===================================================================
\echo ''
\echo '=== A11: rechazar exige motivo y no mueve nada ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_solicitar_ajuste('eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega'),
  0, null, 'Creo que no hay nada');
set role postgres;
select id as aj5 from ajustes_inventario where estado='pendiente' \gset
select (select coalesce(sum(cantidad),0) from existencias
         where producto_id='eeeeeeee-0000-0000-0000-000000000001'
           and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001') as total_antes;
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\set ON_ERROR_STOP off
select fn_resolver_ajuste(:'aj5', false);
\echo '--- esperado: rechazar exige decir por que ---'
\set ON_ERROR_STOP on
select fn_resolver_ajuste(:'aj5', false, 'La bodega no se ha contado');
select (select coalesce(sum(cantidad),0) from existencias
         where producto_id='eeeeeeee-0000-0000-0000-000000000001'
           and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001') as total_despues;
\echo '--- esperado: el total no cambio ---'

\echo ''
\echo '=== A11b: y despues de rechazado se puede volver a pedir ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_solicitar_ajuste('eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega'),
  20, null, 'Ya conte bien') ->> 'numero' as nuevo;


-- ===================================================================
\echo ''
\echo '=== A12: si entre pedir y aprobar se vendio casi todo ==='
set role postgres;
select id as aj6 from ajustes_inventario where estado='pendiente' \gset
select fn_kardex_registrar('bbbbbbbb-0000-0000-0000-000000000001',
  'eeeeeeee-0000-0000-0000-000000000001','venta', 22, null, null,
  'venta', null, 'se vendio casi todo', '11111111-1111-1111-1111-111111111111') is not null as vendido;
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\set ON_ERROR_STOP off
select fn_resolver_ajuste(:'aj6', true);
\echo '--- esperado: un mensaje que diga que hay que volver a contar ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== A13: el REPARTIDOR no pide ajustes ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000009';
\set ON_ERROR_STOP off
select fn_solicitar_ajuste('eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega'), 5);
\echo '--- esperado: no tiene permiso ---'
select count(*) from fn_ajustes('todos');
\echo '--- esperado: 0 filas o rechazo ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== A14: pedir sobre una ubicacion de la OTRA pulperia ==='
set role postgres;
select id as ajena from ubicaciones
 where sucursal_id='bbbbbbbb-0000-0000-0000-000000000002' and nombre='Bodega' \gset
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
select fn_solicitar_ajuste('eeeeeeee-0000-0000-0000-000000000001', :'ajena', 5);
\echo '--- esperado: esa ubicacion no es de su negocio ---'

\echo ''
\echo '=== A14b: ni sobre un producto ajeno en una ubicacion propia ==='
select fn_solicitar_ajuste('eeeeeeee-0000-0000-0000-000000000002',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega'), 5);
\echo '--- esperado: ese producto no es de este negocio ---'

\echo ''
\echo '=== A14c: ni con un lote que no es del producto ==='
select fn_solicitar_ajuste('eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega'),
  5, '11110000-0000-0000-0000-00000000000a');
\echo '--- esperado: ese lote no corresponde ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== A15: nadie escribe la tabla a mano ==='
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\set ON_ERROR_STOP off
update ajustes_inventario set estado = 'aprobado';
\echo '--- esperado: permiso denegado ---'
insert into ajustes_inventario (organizacion_id, sucursal_id, numero, producto_id,
  ubicacion_id, cantidad_sistema, cantidad_contada)
values ('aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',
  'A-MANO','eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega'), 0, 999);
\echo '--- esperado: permiso denegado ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== A16: el historial completo ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select numero, estado, producto, ubicacion, sistema, contado, diferencia,
       aplicado, solicitado_por, resuelto_por, nota
from fn_ajustes('todos');

\echo ''
\echo '=== A16b: y el desglose sigue cuadrando ==='
select
 (select coalesce(sum(cantidad),0) from existencias
   where producto_id='eeeeeeee-0000-0000-0000-000000000001'
     and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001') as total,
 (select coalesce(sum(cantidad),0) from fn_existencia_por_ubicacion(
    'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001')) as desglose;
select
 (select coalesce(sum(cantidad),0) from existencias
   where producto_id='eeeeeeee-0000-0000-0000-00000000000b'
     and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001') as total_leche,
 (select coalesce(sum(cantidad),0) from fn_existencia_por_ubicacion(
    'eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001')) as desglose_leche;

\echo ''
\echo '### FIN'

-- ===================================================================
\echo ''
\echo '=== A17: el desglose de UN lote por ubicacion ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\echo '--- L-ENE: 4 en el piso, 2 en el refrigerador ---'
select ubicacion, cantidad from fn_existencia_ubicacion_lote(
  'eeeeeeee-0000-0000-0000-00000000000b','11110000-0000-0000-0000-00000000000a');
\echo '--- L-FEB: 12 en el piso, 0 en el refrigerador ---'
select ubicacion, cantidad from fn_existencia_ubicacion_lote(
  'eeeeeeee-0000-0000-0000-00000000000b','11110000-0000-0000-0000-00000000000b');
\echo '--- sin lote (el arroz) ---'
select ubicacion, cantidad from fn_existencia_ubicacion_lote(
  'eeeeeeee-0000-0000-0000-000000000001');

\echo ''
\echo '=== A17b: y el repartidor no lo ve ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000009';
\set ON_ERROR_STOP off
select * from fn_existencia_ubicacion_lote('eeeeeeee-0000-0000-0000-000000000001');
\echo '--- esperado: no tiene permiso ---'
\set ON_ERROR_STOP on
