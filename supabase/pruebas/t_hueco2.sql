\set ON_ERROR_STOP on
\pset pager off

\echo '=== AUXILIAR: lo que ya NO puede hacer ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
\echo '-- subirse el limite:'
update clientes set limite_credito = 999999 where codigo = 'C001';
\echo '-- borrar la deuda:'
update clientes set saldo = 0 where codigo = 'C001';
\echo '-- regalarse puntos:'
update clientes set puntos = 9999 where codigo = 'C001';
\echo '-- adoptar al cliente:'
update clientes set usuario_id = '22222222-2222-2222-2222-222222222222' where codigo = 'C001';
\echo '-- borrar al cliente (y con el, la deuda):'
delete from clientes where codigo = 'C001';
\echo '-- fijar el limite por funcion (necesita supervisor):'
select fn_fijar_limite_credito('f0000000-0000-0000-0000-00000000000a', 5000);
\set ON_ERROR_STOP on

\echo ''
\echo '=== AUXILIAR: lo que SI debe poder ==='
update clientes set telefono = '9999-7777', actualizado_en = now() where codigo = 'C001';
\echo '-- dar de alta un cliente nuevo:'
insert into clientes (organizacion_id, codigo, nombre, telefono, activo)
values ('aaaaaaaa-0000-0000-0000-000000000001','C009','Cliente Nuevo','9999-0009', true);
\echo '-- el nuevo arranca sin fiado:'
select nombre, saldo, limite_credito from clientes where codigo = 'C009';
\echo '-- desactivar a uno:'
update clientes set activo = false where codigo = 'C009';
\echo '-- y el saldo sigue intacto:'
select nombre, saldo, limite_credito from clientes where codigo = 'C001';

\echo ''
\echo '=== Un cliente nuevo con limite de contrabando en el insert (debe FALLAR) ==='
\set ON_ERROR_STOP off
insert into clientes (organizacion_id, codigo, nombre, limite_credito, saldo, activo)
values ('aaaaaaaa-0000-0000-0000-000000000001','C010','Tramposo', 50000, -5000, true);
\set ON_ERROR_STOP on

\echo ''
\echo '=== SUPERVISOR fija el limite (debe PASAR) ==='
set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select jsonb_pretty(fn_fijar_limite_credito('f0000000-0000-0000-0000-00000000000a', 400));
select nombre, saldo, limite_credito, limite_fijado_por is not null as quedo_firmado
from clientes where codigo = 'C001';

\echo ''
\echo '-- limite negativo (debe FALLAR):'
\set ON_ERROR_STOP off
select fn_fijar_limite_credito('f0000000-0000-0000-0000-00000000000a', -1);
\set ON_ERROR_STOP on

\echo ''
\echo '-- bajar el limite por debajo de la deuda: pasa pero lo avisa'
select jsonb_pretty(fn_fijar_limite_credito('f0000000-0000-0000-0000-00000000000a', 50));

\echo ''
\echo '=== El fiado sigue funcionando con el limite nuevo ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_turno('cccccccc-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','22222', 0) as tt \gset
select fn_desbloquear_caja(:'tt'::uuid, '22222') as dd \gset
\set ON_ERROR_STOP off
\echo '-- fiar con el limite por debajo del saldo (debe FALLAR):'
select fn_registrar_venta(:'dd'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  '[{"metodo":"credito","monto":50.00}]'::jsonb,
  'f0000000-0000-0000-0000-00000000000a');
\set ON_ERROR_STOP on

\echo ''
\echo '=== El REPARTIDOR no ve nada de esto ==='
reset role;
insert into auth.users (id, email) values ('44444444-4444-4444-4444-444444444444','repa@t.hn');
insert into perfiles (id, organizacion_id, nombre, email, rol, activo)
values ('44444444-4444-4444-4444-444444444444','aaaaaaaa-0000-0000-0000-000000000001','Repa','repa@t.hn','repartidor', true);
set role authenticated;
set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
\set ON_ERROR_STOP off
select count(*) as clientes_que_ve from clientes;
select count(*) as fiado_que_ve from v_fiado;
select fn_fijar_limite_credito('f0000000-0000-0000-0000-00000000000a', 9999);
select fn_registrar_abono('f0000000-0000-0000-0000-00000000000a', 10, 'transferencia', null);
\set ON_ERROR_STOP on
reset role;
\echo '### FIN'
