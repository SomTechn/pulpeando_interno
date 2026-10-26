\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- Sobre la semilla de t_pedidos:
--   org 1 "La Esquina"  sucursal bbbb...001  Arroz 50
--   org 2 "Dona Chus"   sucursal bbbb...002  Frijol 50
--   gerente1 1111..  auxiliar1 2222..  gerente2 9999..

insert into auth.users (id, email) values
  ('bbbb0000-0000-0000-0000-000000000001','sup1@t.hn'),
  ('bbbb0000-0000-0000-0000-000000000009','repa1@t.hn');
insert into perfiles (id, organizacion_id, nombre, email, rol, activo) values
 ('bbbb0000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Supervisor','sup1@t.hn','supervisor',true),
 ('bbbb0000-0000-0000-0000-000000000009','aaaaaaaa-0000-0000-0000-000000000001','Repartidor','repa1@t.hn','repartidor',true);
insert into usuario_sucursales (perfil_id, sucursal_id) values
 ('bbbb0000-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001'),
 ('bbbb0000-0000-0000-0000-000000000009','bbbbbbbb-0000-0000-0000-000000000001');

-- Leche con dos lotes, y un codigo de barras en el arroz
insert into productos (id, organizacion_id, sku, nombre, categoria_id, tipo,
                       unidad_base, activo, se_vende, controla_lote, controla_vencimiento)
values ('eeeeeeee-0000-0000-0000-00000000000b','aaaaaaaa-0000-0000-0000-000000000001',
        'P3','Leche litro','dddddddd-0000-0000-0000-000000000001','unidad','unidad',true,true,true,true);

insert into producto_codigos (organizacion_id, producto_id, codigo, es_principal) values
 ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','7501234567890', true),
 ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-00000000000b','7509999999999', true);

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

\echo '### Arroz 50 (sin lote) · Leche 6 + 12 en dos lotes'


-- ===================================================================
\echo ''
\echo '=== U1: toda sucursal nacio con sus dos ubicaciones ==='
select s.nombre as sucursal, u.nombre, u.es_predeterminada, u.orden
from ubicaciones u join sucursales s on s.id = u.sucursal_id
order by s.nombre, u.orden;

\echo ''
\echo '=== U1b: una sucursal NUEVA tambien (el disparador) ==='
insert into sucursales (id, organizacion_id, codigo, nombre, es_principal, activa)
values ('bbbbbbbb-0000-0000-0000-00000000000f','aaaaaaaa-0000-0000-0000-000000000001',
        '009','Sucursal Nueva', false, true);
select count(*) as ubicaciones_de_la_nueva from ubicaciones
 where sucursal_id = 'bbbbbbbb-0000-0000-0000-00000000000f';


-- ===================================================================
\echo ''
\echo '=== U2: sin desglose, TODO se lee en la predeterminada ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select ubicacion, es_predeterminada, cantidad
from fn_existencia_por_ubicacion('eeeeeeee-0000-0000-0000-000000000001',
                                 'bbbbbbbb-0000-0000-0000-000000000001');
\echo '--- esperado: Piso 50, Bodega 0 (suma 50 = el total) ---'


-- ===================================================================
\echo ''
\echo '=== U3: la auxiliar baja 30 de arroz del piso a la bodega ==='
select fn_mover_entre_ubicaciones(
  'eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega'),
  30);
select ubicacion, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');
\echo '--- esperado: Piso 20, Bodega 30 ---'

\echo ''
\echo '=== U3b: y la SUMA sigue siendo el total ==='
select
 (select coalesce(sum(cantidad),0) from existencias
   where producto_id='eeeeeeee-0000-0000-0000-000000000001'
     and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001') as total,
 (select coalesce(sum(cantidad),0) from fn_existencia_por_ubicacion(
    'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001')) as desglose;


-- ===================================================================
\echo ''
\echo '=== U4: no se puede mover mas de lo que hay en el origen ==='
\set ON_ERROR_STOP off
select fn_mover_entre_ubicaciones(
  'eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega'),
  25);
\echo '--- esperado: en Piso de ventas solo hay 20 ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== U5: se venden 40 (el piso solo tenia 20). El desglose se recorta ==='
set role postgres;
select fn_kardex_registrar('bbbbbbbb-0000-0000-0000-000000000001',
  'eeeeeeee-0000-0000-0000-000000000001','venta', 40, null, null,
  'venta', null, 'prueba', '11111111-1111-1111-1111-111111111111') is not null as ok;
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select ubicacion, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');
select
 (select coalesce(sum(cantidad),0) from existencias
   where producto_id='eeeeeeee-0000-0000-0000-000000000001'
     and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001') as total,
 (select coalesce(sum(cantidad),0) from fn_existencia_por_ubicacion(
    'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001')) as desglose;
\echo '--- esperado: total 10, desglose 10, nada negativo ---'


-- ===================================================================
\echo ''
\echo '=== U6: el gerente de la OTRA pulperia no puede mover nada de aqui ==='
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
\set ON_ERROR_STOP off
select fn_mover_entre_ubicaciones(
  'eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega'),
  5);
\echo '--- esperado: esa ubicacion de destino no es de su negocio ---'

\echo ''
\echo '=== U6b: ni consultar el producto ajeno ==='
select fn_consultar_producto('eeeeeeee-0000-0000-0000-000000000001');
\echo '--- esperado: ese producto no es de su negocio ---'

\echo ''
\echo '=== U6c: ni ver su desglose ==='
select * from fn_existencia_por_ubicacion('eeeeeeee-0000-0000-0000-000000000001',
                                          'bbbbbbbb-0000-0000-0000-000000000001');
\echo '--- esperado: esa sucursal no es de su negocio ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== U7: no se mueve entre ubicaciones de DISTINTA sucursal ==='
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\set ON_ERROR_STOP off
select fn_mover_entre_ubicaciones(
  'eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-00000000000f' and nombre='Bodega'),
  2,
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Piso de ventas'));
\echo '--- esperado: tienen que ser de la misma sucursal / traslado ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== U8: por lote. 4 de L-ENE al refrigerador ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_guardar_ubicacion('Refrigerador', null,
       'bbbbbbbb-0000-0000-0000-000000000001', 20, true);
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_mover_entre_ubicaciones(
  'eeeeeeee-0000-0000-0000-00000000000b',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Refrigerador'),
  4, null, '11110000-0000-0000-0000-00000000000a');
select ubicacion, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001');
\echo '--- esperado: Piso 14, Refrigerador 4, Bodega 0 · suma 18 ---'

\echo ''
\echo '=== U8b: no se puede mover 5 del lote L-ENE (solo quedan 2 en el piso) ==='
\set ON_ERROR_STOP off
select fn_mover_entre_ubicaciones(
  'eeeeeeee-0000-0000-0000-00000000000b',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Refrigerador'),
  5, null, '11110000-0000-0000-0000-00000000000a');
\echo '--- esperado: en Piso de ventas solo hay 2 ---'

\echo ''
\echo '=== U8c: ni un lote que no es de este producto ==='
select fn_mover_entre_ubicaciones(
  'eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Refrigerador'),
  1, null, '11110000-0000-0000-0000-00000000000a');
\echo '--- esperado: ese lote no corresponde al producto ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== U9: la AUXILIAR no ve costo ni margen ==='
select
  r->>'nombre'           as producto,
  r->>'existencia'       as existencia,
  r->>'precio'           as precio,
  r->>'costo_promedio'   as costo,
  r->>'margen'           as margen,
  r->>'valor_inventario' as valor,
  r->>'puede_ver_costos' as ve_costos
from (select fn_consultar_producto('eeeeeeee-0000-0000-0000-00000000000b') as r) q;
\echo '--- esperado: costo/margen/valor en blanco, ve_costos false ---'

\echo ''
\echo '=== U9b: el SUPERVISOR si ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select
  r->>'costo_promedio'   as costo,
  r->>'margen'           as margen,
  r->>'valor_inventario' as valor,
  r->>'puede_ver_costos' as ve_costos
from (select fn_consultar_producto('eeeeeeee-0000-0000-0000-00000000000b') as r) q;

\echo ''
\echo '=== U9c: los lotes con su vencimiento, y el desglose, dentro del perfil ==='
select jsonb_pretty(
  (fn_consultar_producto('eeeeeeee-0000-0000-0000-00000000000b')
    - 'precios' - 'codigos' - 'ultima_compra' - 'descripcion' - 'imagen_url')
  -> 'lotes') as lotes;
select jsonb_pretty(fn_consultar_producto('eeeeeeee-0000-0000-0000-00000000000b')
  -> 'ubicaciones') as ubicaciones;


-- ===================================================================
\echo ''
\echo '=== U10: escanear un codigo exacto cae directo en el producto ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select nombre, sku, codigo, existencia, exacto
from fn_buscar_para_consulta('7509999999999');

\echo ''
\echo '=== U10b: buscar por nombre parcial ==='
select nombre, exacto from fn_buscar_para_consulta('le');

\echo ''
\echo '=== U10c: la busqueda NO cruza negocios ==='
select count(*) as frijoles_visibles from fn_buscar_para_consulta('Frijol');
\echo '--- esperado: 0 ---'


-- ===================================================================
\echo ''
\echo '=== U11: cinco semanas, incluidas las vacias ==='
select semana_inicio, semana_fin, unidades, importe
from fn_ventas_producto_semanas('eeeeeeee-0000-0000-0000-000000000001', 5);
\echo '--- esperado: 5 filas, las vacias en 0 ---'


-- ===================================================================
\echo ''
\echo '=== U12: la AUXILIAR no puede abrir un conteo por su cuenta ==='
\set ON_ERROR_STOP off
select fn_agregar_a_conteo('eeeeeeee-0000-0000-0000-00000000000b');
\echo '--- esperado: solo un supervisor puede abrir un conteo ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== U12b: el SUPERVISOR agrega la leche y se abre un conteo por seleccion ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_agregar_a_conteo('eeeeeeee-0000-0000-0000-00000000000b');

\echo ''
\echo '=== U12c: el conteo trae SOLO la leche (no la categoria entera) ==='
select producto, lote, vence, contada, sistema
from fn_conteo_lineas((select id from conteos where estado='abierto'
                        and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001'));
\echo '--- esperado: 3 lineas de Leche (L-ENE, L-FEB, sin lote). Ningun arroz ---'

\echo ''
\echo '=== U12d: la auxiliar SI puede agregar a uno ya abierto ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_agregar_a_conteo('eeeeeeee-0000-0000-0000-000000000001');
select count(*) as lineas from conteo_detalle
 where conteo_id = (select id from conteos where estado='abierto'
                     and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001');

\echo ''
\echo '=== U12e: agregar dos veces no duplica ==='
select fn_agregar_a_conteo('eeeeeeee-0000-0000-0000-000000000001');

\echo ''
\echo '=== U12f: en la lista de conteos el alcance se lee ==='
select numero, alcance, detalle, lineas from fn_conteos(5);
\echo '--- esperado: "Productos elegidos", NO "Todo el inventario" ---'


-- ===================================================================
\echo ''
\echo '=== U13: contar una linea del conteo por seleccion ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_contar(
  (select id from conteos where estado='abierto' and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001'),
  'eeeeeeee-0000-0000-0000-00000000000b', 5, '11110000-0000-0000-0000-00000000000a');


-- ===================================================================
\echo ''
\echo '=== U14: aplicar el conteo ajusta SOLO lo contado ==='
select ubicacion, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001');
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_aplicar_conteo(
  (select id from conteos where estado='abierto' and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001'));
\echo '--- L-ENE pasa de 6 a 5. El arroz (no contado) no se toca ---'
select l.codigo, e.cantidad from existencias e
 left join lotes l on l.id = e.lote_id
 where e.producto_id='eeeeeeee-0000-0000-0000-00000000000b'
   and e.sucursal_id='bbbbbbbb-0000-0000-0000-000000000001'
 order by l.codigo nulls last;
select cantidad as arroz from existencias
 where producto_id='eeeeeeee-0000-0000-0000-000000000001'
   and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001';

\echo ''
\echo '=== U14b: y el desglose siguio cuadrando tras el ajuste ==='
select
 (select coalesce(sum(cantidad),0) from existencias
   where producto_id='eeeeeeee-0000-0000-0000-00000000000b'
     and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001') as total,
 (select coalesce(sum(cantidad),0) from fn_existencia_por_ubicacion(
    'eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001')) as desglose;
select ubicacion, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001');


-- ===================================================================
\echo ''
\echo '=== U15: cambiar la predeterminada no pierde nada ==='
\echo '--- antes ---'
select ubicacion, es_predeterminada, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001');
\set ON_ERROR_STOP off
select fn_fijar_ubicacion_predeterminada(
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega'));
\echo '--- esperado: una bodega NO puede ser la predeterminada ---'
\set ON_ERROR_STOP on
select fn_fijar_ubicacion_predeterminada(
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Refrigerador'));
\echo '--- despues: las mismas cantidades, el refrigerador es la predeterminada ---'
select ubicacion, es_predeterminada, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001');
select
 (select coalesce(sum(cantidad),0) from existencias
   where producto_id='eeeeeeee-0000-0000-0000-00000000000b'
     and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001') as total,
 (select coalesce(sum(cantidad),0) from fn_existencia_por_ubicacion(
    'eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001')) as desglose;

\echo ''
\echo '=== U15b: la auxiliar no puede cambiar la predeterminada ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
select fn_fijar_ubicacion_predeterminada(
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Piso de ventas'));
\echo '--- esperado: solo el gerente ---'

\echo ''
\echo '=== U15c: ni crear ubicaciones ==='
select fn_guardar_ubicacion('Mi bodega secreta');
\echo '--- esperado: solo un supervisor ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== U16: el REPARTIDOR no consulta inventario ni precios ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000009';
\set ON_ERROR_STOP off
select fn_consultar_producto('eeeeeeee-0000-0000-0000-000000000001');
\echo '--- esperado: no tiene permiso ---'
select * from fn_buscar_para_consulta('Arroz');
\echo '--- esperado: no tiene permiso ---'
select * from fn_existencia_por_ubicacion('eeeeeeee-0000-0000-0000-000000000001');
\echo '--- esperado: no tiene permiso ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== U17: nadie escribe el desglose a mano ==='
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\set ON_ERROR_STOP off
update existencias_ubicacion set cantidad = 9999;
\echo '--- esperado: permiso denegado ---'
insert into ubicaciones (organizacion_id, sucursal_id, nombre)
values ('aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','A mano');
\echo '--- esperado: permiso denegado ---'
\set ON_ERROR_STOP on

\echo ''
\echo '### FIN'

-- ===================================================================
\echo ''
\echo '=== U18: una sucursal a la que no tiene acceso ==='
set role postgres;
select app.nivel_rol('gerente') as nivel_gerente;
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select count(*) as sucursales_de_la_auxiliar from app.sucursales_permitidas();
\set ON_ERROR_STOP off
select fn_mover_entre_ubicaciones(
  'eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-00000000000f' and nombre='Bodega'),
  1,
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-00000000000f' and nombre='Piso de ventas'));
\echo '--- esperado: no tiene acceso a esa sucursal ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== U19: el supervisor de aqui no renombra la ubicacion de la otra pulperia ==='
-- El id se saca como postgres: desde la sesion del supervisor la RLS lo
-- esconderia y la prueba no probaria nada.
set role postgres;
select id as ajena from ubicaciones
 where sucursal_id='bbbbbbbb-0000-0000-0000-000000000002' and nombre='Bodega' \gset
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
\set ON_ERROR_STOP off
select fn_guardar_ubicacion('Mia ahora', :'ajena');
\echo '--- esperado: esa ubicacion no es de su negocio ---'

\echo ''
\echo '=== U19b: ni la pone como predeterminada, ni mueve nada ahi ==='
select fn_fijar_ubicacion_predeterminada(:'ajena');
\echo '--- esperado: esa ubicacion no es de su negocio ---'
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-000000000002', :'ajena', 1);
\echo '--- esperado: esa ubicacion de destino no es de su negocio ---'
select fn_consultar_producto('eeeeeeee-0000-0000-0000-000000000002');
\echo '--- esperado: ese producto no es de su negocio ---'
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';

\echo ''
\echo '=== U20: dos ubicaciones con el mismo nombre en una sucursal ==='
select fn_guardar_ubicacion('bodega  ', null, 'bbbbbbbb-0000-0000-0000-000000000001');
\echo '--- esperado: llave duplicada ---'

\echo ''
\echo '=== U21: mover cero o negativo ==='
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-00000000000b',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Refrigerador'), 0);
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-00000000000b',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Refrigerador'), -5);
\echo '--- esperado: la cantidad debe ser mayor a cero (las dos veces) ---'

\echo ''
\echo '=== U22: no se desactiva la predeterminada ==='
select fn_guardar_ubicacion('Bodega',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and es_predeterminada),
  null, null, false);
\echo '--- esperado: fije otra como predeterminada primero ---'
\set ON_ERROR_STOP on

\echo ''
\echo '### FIN 2'

-- ===================================================================
\echo ''
\echo '=== U23: el GERENTE de aqui tampoco toca lo de la otra pulperia ==='
set role postgres;
select id as ajena2 from ubicaciones
 where sucursal_id='bbbbbbbb-0000-0000-0000-000000000002' and nombre='Bodega' \gset
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\set ON_ERROR_STOP off
select fn_fijar_ubicacion_predeterminada(:'ajena2');
select fn_guardar_ubicacion('Secuestrada', :'ajena2');
select fn_ventas_producto_semanas('eeeeeeee-0000-0000-0000-000000000002');
select fn_agregar_a_conteo('eeeeeeee-0000-0000-0000-000000000002');
\echo '--- esperado: los cuatro rechazados por negocio ajeno ---'
\set ON_ERROR_STOP on
select count(*) as ubicaciones_ajenas_visibles
from fn_ubicaciones('bbbbbbbb-0000-0000-0000-000000000002');
\echo '--- esperado: 0 ---'
