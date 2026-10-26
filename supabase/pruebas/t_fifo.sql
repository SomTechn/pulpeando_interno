\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- Estado limpio de antiguedad: dos ventas fiadas de L100,
-- una hace 45 dias y otra hace 10 dias. Sin abonos.
update ventas set creada_en = now() - interval '45 days' where numero = 'T-00000001';
update ventas set creada_en = now() - interval '10 days' where numero = 'T-00000002';
update abonos_cliente set anulado = true;
update clientes set saldo = 200 where id = 'f0000000-0000-0000-0000-00000000000a';

create or replace function _ver() returns table(caso text, debe numeric, dias integer)
language sql security definer set search_path = public, app as $$
  select 'v_fiado'::text, f.debe, f.dias from v_fiado f
  where f.cliente_id = 'f0000000-0000-0000-0000-00000000000a'
$$;

\echo '=== F1: sin abonos. La deuda viva arranca hace 45 dias ==='
select * from _ver();

\echo ''
\echo '=== F2: abono de L99. T-1 sigue parcialmente viva => 45 dias ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_registrar_abono('f0000000-0000-0000-0000-00000000000a', 99, 'transferencia', null, 'A1') as r \gset
set role postgres;
select * from _ver();

\echo ''
\echo '=== F3: abono de L1 mas (total 100). T-1 queda liquidada => 10 dias ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_registrar_abono('f0000000-0000-0000-0000-00000000000a', 1, 'transferencia', null, 'A2') as r \gset
set role postgres;
select * from _ver();

\echo ''
\echo '=== F4: abono de los L100 restantes. Ya no debe nada => fuera de v_fiado ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_registrar_abono('f0000000-0000-0000-0000-00000000000a', 100, 'transferencia', null, 'A3') as r \gset
\echo 'resultado:' :r
set role postgres;
select coalesce((select count(*) from _ver()), 0) as filas_en_v_fiado;
select nombre, saldo from clientes where id = 'f0000000-0000-0000-0000-00000000000a';

\echo ''
\echo '=== F5: ya libre, otro abono debe FALLAR ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
select fn_registrar_abono('f0000000-0000-0000-0000-00000000000a', 1, 'transferencia', null);
\set ON_ERROR_STOP on

\echo ''
\echo '=== F6: y ahora si puede volver a fiar los L200 completos ==='
select fn_abrir_turno('cccccccc-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','22222', 0) as t2 \gset
select fn_desbloquear_caja(:'t2'::uuid, '22222') as dq \gset
select fn_registrar_venta(:'dq'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":4}]'::jsonb,
  '[{"metodo":"credito","monto":200.00}]'::jsonb,
  'f0000000-0000-0000-0000-00000000000a') as v \gset
\echo 'venta:' :v
set role postgres;
select * from _ver();

drop function _ver();
reset role;
\echo '### FIN FIFO'
