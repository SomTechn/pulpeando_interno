\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- ===================================================================
-- DOS pulperias, cada una con su envio y su minimo, y un comprador
-- que no es cliente de ninguna todavia.
-- ===================================================================
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','gerente1@t.hn'),
  ('22222222-2222-2222-2222-222222222222','auxiliar1@t.hn'),
  ('99999999-9999-9999-9999-999999999999','gerente2@t.hn'),
  ('cccc0000-0000-0000-0000-00000000000a','dona.luz@correo.hn'),
  ('cccc0000-0000-0000-0000-00000000000b','otro.cliente@correo.hn');

insert into organizaciones (id, nombre, pais, moneda) values
  ('aaaaaaaa-0000-0000-0000-000000000001','Pulperia La Esquina','HN','HNL'),
  ('aaaaaaaa-0000-0000-0000-000000000002','Pulperia Dona Chus','HN','HNL');

insert into sucursales (id, organizacion_id, codigo, nombre, direccion,
                        es_principal, activa, acepta_domicilio, costo_envio, pedido_minimo) values
  ('bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
   '001','La Esquina','Col. Las Flores', true, true, true, 25.00, 100.00),
  ('bbbbbbbb-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000002',
   '001','Dona Chus','Col. El Centro', true, true, true, 15.00, 0),
  ('bbbbbbbb-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000002',
   '002','Dona Chus 2','Col. Satelite', true, true, false, 0, 0);

insert into perfiles (id, organizacion_id, nombre, email, rol, pin_pos, activo) values
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001','Gerente 1','gerente1@t.hn','gerente', crypt('11111', gen_salt('bf')), true),
  ('22222222-2222-2222-2222-222222222222','aaaaaaaa-0000-0000-0000-000000000001','Auxiliar 1','auxiliar1@t.hn','auxiliar', crypt('22222', gen_salt('bf')), true),
  ('99999999-9999-9999-9999-999999999999','aaaaaaaa-0000-0000-0000-000000000002','Gerente 2','gerente2@t.hn','gerente', crypt('99999', gen_salt('bf')), true);

insert into usuario_sucursales (perfil_id, sucursal_id) values
  ('11111111-1111-1111-1111-111111111111','bbbbbbbb-0000-0000-0000-000000000001'),
  ('22222222-2222-2222-2222-222222222222','bbbbbbbb-0000-0000-0000-000000000001'),
  ('99999999-9999-9999-9999-999999999999','bbbbbbbb-0000-0000-0000-000000000002');

insert into categorias (id, organizacion_id, nombre) values
  ('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Abarrotes'),
  ('dddddddd-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000002','Abarrotes');

-- Producto de cada tienda
insert into productos (id, organizacion_id, sku, nombre, categoria_id, tipo, unidad_base, activo, se_vende) values
  ('eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','P1','Arroz 5lb','dddddddd-0000-0000-0000-000000000001','unidad','unidad',true,true),
  ('eeeeeeee-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000002','P1','Frijol 1lb','dddddddd-0000-0000-0000-000000000002','unidad','unidad',true,true);

insert into precios (organizacion_id, producto_id, sucursal_id, nivel, cantidad_minima, precio, vigente_desde) values
  ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','detalle',1, 60.00, now()-interval '1 day'),
  ('aaaaaaaa-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000002','detalle',1, 30.00, now()-interval '1 day');

insert into precios (organizacion_id, producto_id, sucursal_id, nivel, cantidad_minima, precio, vigente_desde) values
  ('aaaaaaaa-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000003','detalle',1, 30.00, now()-interval '1 day');

insert into existencias (organizacion_id, producto_id, sucursal_id, cantidad) values
  ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001', 50),
  ('aaaaaaaa-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000002', 50);

insert into producto_costos (organizacion_id, producto_id, sucursal_id, cantidad, valor, costo_promedio, ultimo_costo) values
  ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',50,2000,40,40),
  ('aaaaaaaa-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000002',50,1000,20,20);

\echo '### SEMBRADO: 2 pulperias, un comprador sin ficha en ninguna'

-- ===================================================================
set role authenticated;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-00000000000a';

\echo ''
\echo '=== D1: un usuario NUEVO ve las tiendas disponibles ==='
select negocio, sucursal, costo_envio, pedido_minimo, acepta_domicilio,
       productos, ya_soy_cliente
from fn_tiendas_disponibles() order by negocio, sucursal;

\echo ''
\echo '=== D2: y NO ve ninguna en "mis tiendas", porque no ha pedido ==='
select count(*) as mis_tiendas from fn_tiendas_cliente();

\echo ''
\echo '=== D3: puede ver el catalogo de una tienda sin ser cliente ==='
select nombre, precio, disponible from fn_catalogo_cliente('bbbbbbbb-0000-0000-0000-000000000001');

\echo ''
\echo '=== D4: pedido por debajo del minimo de L100 (debe FALLAR) ==='
\set ON_ERROR_STOP off
select fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001', null, 'app_cliente', 'domicilio',
  null, 'Col. Las Flores casa 3', 'Dona Luz', '9999-1111');
\set ON_ERROR_STOP on

\echo ''
\echo '=== D5: pedido de L120 con envio L25 => total 145 (debe PASAR) ==='
select jsonb_pretty(fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":2}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001', null, 'app_cliente', 'domicilio',
  null, 'Col. Las Flores casa 3', 'Dona Luz', '9999-1111'));

\echo ''
\echo '=== D6: se le creo su ficha de cliente en esa tienda, sin fiado ==='
reset role;
select o.nombre as negocio, c.nombre, c.telefono, c.limite_credito, c.saldo
from clientes c join organizaciones o on o.id = c.organizacion_id
where c.usuario_id = 'cccc0000-0000-0000-0000-00000000000a';

\echo ''
\echo '=== D7: EL HUECO DEL ENVIO. Mandar envio 0 y negativo ==='
set role authenticated;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-00000000000a';
\echo '-- envio 0: la tienda igual cobra sus L25'
select (fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":2}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001', null, 'app_cliente', 'domicilio',
  null, 'Col. Las Flores casa 3', 'Dona Luz', '9999-1111',
  'efectivo', null, 0, null))->'envio' as envio_cobrado;
\echo '-- envio -500: igual L25, el total no baja'
select (fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":2}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001', null, 'app_cliente', 'domicilio',
  null, 'Col. Las Flores casa 3', 'Dona Luz', '9999-1111',
  'efectivo', null, -500, null)) as pedido_con_envio_negativo;

\echo ''
\echo '=== D8: EL HUECO DE LA TIENDA EQUIVOCADA ==='
\echo '-- ahora pide a la OTRA pulperia; debe ir a Dona Chus, no a La Esquina'
select (fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000002","cantidad":2}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000002', null, 'app_cliente', 'domicilio',
  null, 'Col. El Centro casa 9', 'Dona Luz', '9999-1111')) as pedido_otra_tienda;

reset role;
select o.nombre as negocio, p.numero, p.total, p.costo_envio, s.nombre as sucursal
from pedidos p
join organizaciones o on o.id = p.organizacion_id
join sucursales s on s.id = p.sucursal_id
order by p.creado_en;

\echo ''
\echo '=== D9: pedir producto de OTRA tienda a esta sucursal (debe FALLAR) ==='
set role authenticated;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-00000000000a';
\set ON_ERROR_STOP off
select fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000002","cantidad":1}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001', null, 'app_cliente', 'domicilio',
  null, 'x', 'Dona Luz', '9999-1111');
\set ON_ERROR_STOP on

\echo ''
\echo '=== D10: sucursal que no lleva a domicilio (debe FALLAR) ==='
\set ON_ERROR_STOP off
select fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000002","cantidad":1}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000003', null, 'app_cliente', 'domicilio',
  null, 'x', 'Dona Luz', '9999-1111');
\echo '-- pero si puede recoger en tienda:'
select (fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000002","cantidad":1}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000003', null, 'app_cliente', 'recoge_en_tienda'))->'envio' as envio_recoge;
\set ON_ERROR_STOP on

\echo ''
\echo '=== D11: sin sucursal elegida (debe FALLAR) ==='
\set ON_ERROR_STOP off
select fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":2}]'::jsonb,
  null, null, 'app_cliente', 'domicilio', null, 'x', 'Dona Luz', '9999-1111');
\echo '-- domicilio sin direccion (debe FALLAR):'
select fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":2}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001', null, 'app_cliente', 'domicilio',
  null, '   ', 'Dona Luz', '9999-1111');
\set ON_ERROR_STOP on

\echo ''
\echo '=== D12: mis pedidos, de las dos tiendas ==='
select negocio, numero, total, costo_envio, estado from fn_mis_pedidos();

\echo ''
\echo '=== D13: OTRO cliente no ve los pedidos de Dona Luz ==='
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-00000000000b';
select count(*) as pedidos_que_ve from fn_mis_pedidos();
\echo '-- ni puede cancelarselos:'
reset role;
select id from pedidos order by creado_en limit 1 \gset
set role authenticated;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-00000000000b';
\set ON_ERROR_STOP off
select fn_cancelar_mi_pedido(:'id'::uuid, 'curioseando');
\set ON_ERROR_STOP on

\echo ''
\echo '=== D14: Dona Luz si cancela el suyo ==='
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-00000000000a';
select fn_cancelar_mi_pedido(:'id'::uuid, 'ya no lo necesito') as cancelado;
reset role;
select numero, estado, motivo_cancelacion from pedidos where id = :'id'::uuid;

\echo ''
\echo '=== D15: PERSONAL. La auxiliar no puede usar sucursal ajena ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
select fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000002', null, 'mostrador', 'recoge_en_tienda');
\echo '-- ni cliente ajeno:'
reset role;
select id from clientes where organizacion_id='aaaaaaaa-0000-0000-0000-000000000002' limit 1 \gset aj_
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001', :'aj_id'::uuid, 'mostrador', 'recoge_en_tienda');
\set ON_ERROR_STOP on

\echo ''
\echo '=== D16: la auxiliar si puede perdonar el envio, pero no ponerlo negativo ==='
select (fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001', null, 'mostrador', 'domicilio',
  null, 'Col. Las Flores', 'Vecino', '9999-2222', 'efectivo', null, 0, null))->'envio' as perdonado;
select (fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001', null, 'mostrador', 'domicilio',
  null, 'Col. Las Flores', 'Vecino', '9999-2222', 'efectivo', null, -300, null))->'envio' as negativo_a_cero;
\echo '-- si NO indica envio, se cobra el de la sucursal (L25), no cero:'
select (fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001', null, 'mostrador', 'domicilio',
  null, 'Col. Las Flores', 'Vecino', '9999-2222'))->'envio' as envio_por_omision;
\echo '-- y el minimo no aplica al personal (pedido de mostrador chico):'
select (fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001', null, 'mostrador', 'recoge_en_tienda'))->'total' as total_chico;

\echo ''
\echo '=== D17: anon no alcanza nada de esto ==='
reset role;
set role anon;
reset request.jwt.claim.sub;
\set ON_ERROR_STOP off
select count(*) from fn_tiendas_disponibles();
select count(*) from fn_catalogo_cliente('bbbbbbbb-0000-0000-0000-000000000001');
select fn_crear_pedido('[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001');
\set ON_ERROR_STOP on

reset role;
\echo ''
\echo '### FIN PEDIDOS'
