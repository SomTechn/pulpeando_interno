\set ON_ERROR_STOP on
\pset pager off

\echo '=== El AUXILIAR intenta subirse el limite de credito de un cliente ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select nombre, saldo, limite_credito from clientes where codigo='C001';

\set ON_ERROR_STOP off
update clientes set limite_credito = 999999 where codigo = 'C001';
\echo '-- y borrarse la deuda:'
update clientes set saldo = 0 where codigo = 'C001';
\echo '-- y habilitarle fiado a quien no se le fia:'
update clientes set limite_credito = 5000 where codigo = 'C002';
\set ON_ERROR_STOP on

\echo ''
\echo '=== Como quedaron ==='
select nombre, saldo, limite_credito from clientes where codigo in ('C001','C002') order by codigo;

\echo ''
\echo '=== Y ahora puede fiar sin tope ==='
select fn_abrir_turno('cccccccc-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','22222', 0) as tt \gset
select fn_desbloquear_caja(:'tt'::uuid, '22222') as dd \gset
\set ON_ERROR_STOP off
select fn_registrar_venta(:'dd'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":40}]'::jsonb,
  '[{"metodo":"credito","monto":2000.00}]'::jsonb,
  'f0000000-0000-0000-0000-00000000000a');
\set ON_ERROR_STOP on
select nombre, saldo, limite_credito from clientes where codigo='C001';
reset role;
\echo '### FIN HUECO'
