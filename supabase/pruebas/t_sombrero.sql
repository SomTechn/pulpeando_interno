\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- La gerente de La Esquina quiere pedirle a Dona Chus, y tambien a su propia
-- tienda. Y la auxiliar sigue tomando pedidos de mostrador como siempre.

\echo '=== S1: el PERSONAL pide desde la app del cliente a OTRA pulperia ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select (fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000002","cantidad":1}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000002', null, 'app_cliente', 'domicilio',
  null, 'Col. El Centro', 'Gerente Uno', '9999-0001')) as pedido;

\echo ''
\echo '=== S2: y ESE pedido si le aparece en sus pedidos ==='
select negocio, numero, total, estado from fn_mis_pedidos();

\echo ''
\echo '=== S3: se le creo su ficha de cliente en Dona Chus, sin fiado ==='
reset role;
select o.nombre as negocio, c.nombre, c.limite_credito
from clientes c join organizaciones o on o.id = c.organizacion_id
where c.usuario_id = '11111111-1111-1111-1111-111111111111';

\echo ''
\echo '=== S4: el personal tambien puede pedirle a SU PROPIA tienda como cliente ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select (fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":2}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001', null, 'app_cliente', 'domicilio',
  null, 'Col. Las Flores', 'Gerente Uno', '9999-0001')) as pedido_propio;
\echo '-- y le cobra el envio de su propia tienda (L25), no cero:'
reset role;
select p.numero, p.origen, p.costo_envio, p.cliente_id is not null as con_dueno
from pedidos p order by p.creado_en desc limit 1;

\echo ''
\echo '=== S5: el MOSTRADOR sigue funcionando igual ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select (fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001', null, 'mostrador', 'recoge_en_tienda')) as mostrador;
reset role;
select numero, origen, cliente_id is not null as con_dueno, creado_por is not null as con_creador
from pedidos order by creado_en desc limit 1;

\echo ''
\echo '=== S6: si el panel OLVIDA el origen, cae en mostrador (lado seguro) ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select (fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001')) as sin_origen;
reset role;
select numero, origen from pedidos order by creado_en desc limit 1;

\echo ''
\echo '=== S7: un cliente comun que no manda origen igual es cliente ==='
set role authenticated;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-00000000000b';
select (fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000002","cantidad":1}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000002', null, null, 'recoge_en_tienda')) as cliente_sin_origen;
reset role;
select numero, origen, cliente_id is not null as con_dueno
from pedidos order by creado_en desc limit 1;

\echo ''
\echo '=== S8: pedir como cliente NO da permisos de mostrador ==='
\echo '-- la gerente no puede meter un cliente ajeno viniendo como cliente:'
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
reset role;
insert into clientes (organizacion_id, codigo, nombre, limite_credito, saldo, activo)
values ('aaaaaaaa-0000-0000-0000-000000000001','CX','Vecino Ajeno', 0, 0, true)
on conflict do nothing;
select id from clientes where organizacion_id='aaaaaaaa-0000-0000-0000-000000000001'
  and usuario_id is null limit 1 \gset otro_
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select (fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":2}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001', :'otro_id'::uuid, 'app_cliente', 'domicilio',
  null, 'x', 'Gerente Uno', '9999-0001')) as con_cliente_ajeno;
\echo '-- el p_cliente_id se ignora: el pedido es de ELLA, no del otro cliente'
reset role;
select p.numero, c.nombre as dueno_del_pedido
from pedidos p join clientes c on c.id = p.cliente_id
order by p.creado_en desc limit 1;

\echo ''
\echo '=== S9: y como cliente SI respeta el minimo de la tienda ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\set ON_ERROR_STOP off
select fn_crear_pedido(
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001', null, 'app_cliente', 'domicilio',
  null, 'x', 'Gerente Uno', '9999-0001');
\set ON_ERROR_STOP on
reset role;
\echo '### FIN SOMBRERO'
