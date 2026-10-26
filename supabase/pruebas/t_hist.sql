\set ON_ERROR_STOP on
\pset pager off
\i /tmp/pulptest/t_ajustes.sql
\echo ''
\echo '=== H1: el historial de conteos del arroz ==='
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select origen, referencia, estado, ubicacion, sistema, contado, diferencia, quien
from fn_conteos_del_producto('eeeeeeee-0000-0000-0000-000000000001', null, 5);

\echo ''
\echo '=== H2: ahora una hoja de conteo sobre el mismo producto ==='
select fn_abrir_conteo('bbbbbbbb-0000-0000-0000-000000000001','seleccion',null,null,'Hoja de prueba') ->> 'numero' as hoja;
select fn_agregar_a_conteo('eeeeeeee-0000-0000-0000-000000000001') ->> 'numero' as agregado;
select fn_contar((select id from conteos where estado='abierto'),
                 'eeeeeeee-0000-0000-0000-000000000001', 7) ->> 'contado' as contado;
select origen, referencia, estado, ubicacion, sistema, contado, diferencia, quien
from fn_conteos_del_producto('eeeeeeee-0000-0000-0000-000000000001', null, 5);
\echo '--- esperado: la hoja arriba (es la mas reciente) y los de lugar debajo ---'

\echo ''
\echo '=== H3: la AUXILIAR no ve sistema ni diferencia de lo ya resuelto ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select origen, referencia, estado, sistema, contado, diferencia
from fn_conteos_del_producto('eeeeeeee-0000-0000-0000-000000000001', null, 6);
\echo '--- pero si el suyo pendiente, que ella misma escribio ---'

\echo ''
\echo '=== H4: no cruza negocios ==='
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
\set ON_ERROR_STOP off
select * from fn_conteos_del_producto('eeeeeeee-0000-0000-0000-000000000001');
\echo '--- esperado: ese producto no es de su negocio ---'
\set ON_ERROR_STOP on
