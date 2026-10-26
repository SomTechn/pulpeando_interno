\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- Envejecer las dos ventas a credito de Dona Marta:
--   T-00000001 (L100 fiado)  -> hace 45 dias
--   T-00000002 (L100 fiado)  -> hace 10 dias
-- Abonos existentes: 80 efectivo + 20 transferencia = 100 pagados.
-- FIFO: los 100 pagados liquidan T-00000001 completa.
-- Entonces la deuda viva arranca en T-00000002 => 10 dias, no 45.
update ventas set creada_en = now() - interval '45 days' where numero = 'T-00000001';
update ventas set creada_en = now() - interval '10 days' where numero = 'T-00000002';

set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';

\echo '=== A1: antiguedad FIFO. Debe decir 10 dias (no 45) ==='
select cliente, debe, deuda_desde::date, dias from v_fiado;

\echo ''
\echo '=== A2: si borramos los abonos, la deuda viva arranca en la venta vieja => 45 dias ==='
set role postgres;
update abonos_cliente set anulado = true;
update clientes set saldo = 200 where id='f0000000-0000-0000-0000-00000000000a';
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select cliente, debe, deuda_desde::date, dias, tope_alcanzado from v_fiado;

\echo ''
\echo '=== A3: resumen debe contar 1 cliente con mas de 30 dias, L200 ==='
select jsonb_pretty(fn_fiado_resumen());

\echo ''
\echo '=== A4: aislamiento. El rival NO debe ver a Dona Marta ==='
set role postgres;
insert into auth.users (id, email) values ('99999999-9999-9999-9999-999999999999','rival@t.hn');
insert into organizaciones (id, nombre, pais, moneda)
values ('aaaaaaaa-0000-0000-0000-000000000002','Pulperia Rival','HN','HNL');
insert into sucursales (id, organizacion_id, codigo, nombre, es_principal, activa)
values ('bbbbbbbb-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000002','001','Rival',true,true);
insert into perfiles (id, organizacion_id, nombre, email, rol, pin_pos, activo)
values ('99999999-9999-9999-9999-999999999999','aaaaaaaa-0000-0000-0000-000000000002','Rival','rival@t.hn','gerente', crypt('99999', gen_salt('bf')), true);
insert into clientes (id, organizacion_id, codigo, nombre, limite_credito, saldo, activo)
values ('f0000000-0000-0000-0000-00000000000d','aaaaaaaa-0000-0000-0000-000000000002','R001','Cliente Rival', 300, 77, true);

set role authenticated;
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
\echo '-- lo que ve el rival en v_fiado:'
select cliente, debe from v_fiado;
\echo '-- su resumen:'
select jsonb_pretty(fn_fiado_resumen());
\echo '-- intenta leer el estado de cuenta de Dona Marta (debe venir VACIO):'
select count(*) as filas from fn_estado_cuenta('f0000000-0000-0000-0000-00000000000a');
\echo '-- intenta abonarle a Dona Marta (debe FALLAR):'
\set ON_ERROR_STOP off
select fn_registrar_abono('f0000000-0000-0000-0000-00000000000a', 10, 'transferencia', null);
\set ON_ERROR_STOP on

\echo ''
\echo '=== A5: anular abono exige motivo ==='
set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select id from abonos_cliente limit 1 \gset
\set ON_ERROR_STOP off
select fn_anular_abono(:'id'::uuid, '   ');
\set ON_ERROR_STOP on

reset role;
\echo '### FIN ANTIGUEDAD'
