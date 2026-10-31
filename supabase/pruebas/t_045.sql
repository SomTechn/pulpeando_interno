\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- Sobre la semilla de t_pedidos. Org 1 = La Esquina (Gerente 1, Auxiliar 1).
insert into auth.users (id, email) values ('bbbb0000-0000-0000-0000-000000000001','sup1@t.hn');
insert into perfiles (id, organizacion_id, nombre, email, rol, pin_pos, activo) values
 ('bbbb0000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
  'Supervisor Propio','sup1@t.hn','supervisor', crypt('77777', gen_salt('bf')), true);
insert into usuario_sucursales (perfil_id, sucursal_id) values
 ('bbbb0000-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');
insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa) values
 ('aaaa0000-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','C1','Caja 1', true),
 ('aaaa0000-0000-0000-0000-0000000000c2','aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','C2','Caja 2', true),
 ('aaaa0000-0000-0000-0000-0000000000c3','aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','C3','Caja 3', true);
update organizaciones set permite_stock_negativo = true where id = 'aaaaaaaa-0000-0000-0000-000000000001';

\echo '=== A1: un valor o una lista ==='
select app.uuids('"aaaa0000-0000-0000-0000-0000000000c1"') as uno,
       array_length(app.uuids('["aaaa0000-0000-0000-0000-0000000000c1","aaaa0000-0000-0000-0000-0000000000c2"]'), 1) as dos,
       app.uuids('[]') is null as vacia, app.uuids(null) is null as nula, app.uuids('""') is null as texto_vacio,
       app.textos('["efectivo","tarjeta"]') as textos;
\echo '--- esperado: {c1} | 2 | t | t | t | {efectivo,tarjeta} ---'

\echo ''
\echo '=== A2: color y tamaño del producto ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
update productos set color = 'Rojo', tamano = '2.5 L' where nombre = 'Arroz 5lb';
reset role;
select nombre, color, tamano from productos where nombre = 'Arroz 5lb';
\echo '--- esperado: Rojo | 2.5 L (el gerente lo guarda desde Catálogos) ---'

-- Una venta en cada caja: C1 efectivo, C2 tarjeta, C3 fiado
select id as arroz from productos where nombre = 'Arroz 5lb' \gset
insert into clientes (organizacion_id, nombre, telefono, limite_credito) values ('aaaaaaaa-0000-0000-0000-000000000001', 'Doña Fía', '9000-0001', 1000);
select id as fia from clientes where nombre = 'Doña Fía' \gset
\set ON_ERROR_STOP on
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000c1','22222222-2222-2222-2222-222222222222','22222', 0) as t \gset
select fn_desbloquear_caja(:'t'::uuid,'22222') as d \gset
select (fn_registrar_venta(:'d'::uuid, jsonb_build_array(jsonb_build_object('producto_id', :'arroz', 'cantidad', 1)),
  '[{"metodo":"efectivo","monto":60,"recibido":100}]'::jsonb)->>'venta_id') as v1 \gset
reset role;
update turnos_caja set caja_id = 'aaaa0000-0000-0000-0000-0000000000c2' where id = :'t';
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_desbloquear_caja(:'t'::uuid,'22222') as d \gset
select (fn_registrar_venta(:'d'::uuid, jsonb_build_array(jsonb_build_object('producto_id', :'arroz', 'cantidad', 1)),
  '[{"metodo":"tarjeta","monto":60}]'::jsonb)->>'venta_id') as v2 \gset
reset role;
update turnos_caja set caja_id = 'aaaa0000-0000-0000-0000-0000000000c3' where id = :'t';
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_desbloquear_caja(:'t'::uuid,'22222') as d \gset
select (fn_registrar_venta(:'d'::uuid, jsonb_build_array(jsonb_build_object('producto_id', :'arroz', 'cantidad', 1)),
  '[{"metodo":"credito","monto":60}]'::jsonb, :'fia')->>'venta_id') as v3 \gset
reset role;
select v.caja_id = 'aaaa0000-0000-0000-0000-0000000000c3' as v3_en_caja3 from ventas v where v.id = :'v3';
\echo '--- esperado: t (tres ventas, una por caja) ---'

\echo ''
\echo '=== B1: ventas con varios a la vez ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select
  (select jsonb_array_length(fn_buscar_ventas('{"caja_id":["aaaa0000-0000-0000-0000-0000000000c1","aaaa0000-0000-0000-0000-0000000000c2"]}')->'filas')) as cajas_1_y_2,
  (select jsonb_array_length(fn_buscar_ventas('{"caja_id":"aaaa0000-0000-0000-0000-0000000000c3"}')->'filas')) as solo_caja_3,
  (select jsonb_array_length(fn_buscar_ventas('{"metodo":["tarjeta","credito"]}')->'filas')) as tarjeta_o_fiado,
  (select jsonb_array_length(fn_buscar_ventas('{"metodo":"efectivo"}')->'filas')) as efectivo,
  (select jsonb_array_length(fn_buscar_ventas('{"estado":["completada","anulada"]}')->'filas')) as dos_estados,
  (select jsonb_array_length(fn_buscar_ventas('{"solo_credito":true}')->'filas')) as fiadas,
  (select jsonb_array_length(fn_buscar_ventas('{"caja_id":[]}')->'filas')) as lista_vacia_es_todas;
\echo '--- esperado: 2 | 1 | 2 | 1 | 3 | 1 | 3 ---'

\echo ''
\echo '=== C1: cambiar precios a varias categorías ==='
reset role;
insert into categorias (id, organizacion_id, nombre) values
  ('dddddddd-0000-0000-0000-0000000000b1','aaaaaaaa-0000-0000-0000-000000000001','Bebidas'),
  ('dddddddd-0000-0000-0000-0000000000b2','aaaaaaaa-0000-0000-0000-000000000001','Gaseosas');
update categorias set padre_id = 'dddddddd-0000-0000-0000-0000000000b1' where id = 'dddddddd-0000-0000-0000-0000000000b2';
insert into productos (organizacion_id, sku, nombre, categoria_id, se_vende) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '', 'Coca 3 L', 'dddddddd-0000-0000-0000-0000000000b2', true);
insert into precios (organizacion_id, producto_id, nivel, cantidad_minima, precio, vigente_desde)
select 'aaaaaaaa-0000-0000-0000-000000000001', id, 'detalle', 1, 68, now() - interval '1 day' from productos where nombre = 'Coca 3 L';
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select (fn_cambiar_precios('{"categoria_id":["dddddddd-0000-0000-0000-000000000001","dddddddd-0000-0000-0000-0000000000b2"]}', 'porcentaje', 10, 0, false)->>'productos')::int as dos_categorias,
       (fn_cambiar_precios('{"categoria_id":"dddddddd-0000-0000-0000-0000000000b1"}', 'porcentaje', 10, 0, false)->>'productos')::int as el_departamento_trae_sus_hijas,
       (fn_cambiar_precios('{"categoria_id":"dddddddd-0000-0000-0000-000000000001"}', 'porcentaje', 10, 0, false)->>'productos')::int as una_como_antes;
\echo '--- esperado: 2 | 1 | 1 ---'

\echo ''
\echo '=== D1: contar dos categorías en una sola hoja ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select r->>'alcance' as alcance, (r->>'lineas')::int as lineas, (r->>'varios')::int as varios
  from fn_abrir_conteo_varios(null, 'categoria',
        array['dddddddd-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-0000000000b1']::uuid[], 'del sábado') r;
reset role;
select alcance, notas from conteos order by abierto_en desc limit 1;
\echo '--- esperado: seleccion | 2 | 2 ; notas con las dos categorías ---'

\echo ''
\echo '=== D2: con una sola, es el conteo de siempre ==='
update conteos set estado = 'cancelado';
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select r->>'alcance' as alcance from fn_abrir_conteo_varios(null, 'categoria', array['dddddddd-0000-0000-0000-000000000001']::uuid[]) r;
\echo '--- esperado: categoria ---'

\echo ''
\echo '=== D3: la auxiliar no abre conteos; la otra pulpería no cuela sus categorías ==='
reset role;
update conteos set estado = 'cancelado';
\set ON_ERROR_STOP off
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_conteo_varios(null, 'categoria', array['dddddddd-0000-0000-0000-000000000001']::uuid[]);
\echo '--- esperado: ERROR Solo un supervisor ---'
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_abrir_conteo_varios(null, 'categoria', array['dddddddd-0000-0000-0000-000000000002']::uuid[]);
\echo '--- esperado: ERROR Escoja al menos una categoría (la de la otra pulpería no cuenta) ---'
set role anon;
select fn_abrir_conteo_varios(null, 'categoria', array['dddddddd-0000-0000-0000-000000000001']::uuid[]);
\echo '--- esperado: ERROR permission denied ---'
\set ON_ERROR_STOP on
