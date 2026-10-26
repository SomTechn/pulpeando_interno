\set ON_ERROR_STOP on
\pset pager off
set role postgres;
select id as ajena from ubicaciones
 where sucursal_id='bbbbbbbb-0000-0000-0000-000000000002' and nombre='Bodega' \gset
\echo '=== U23: el GERENTE de aqui tampoco toca la ubicacion de la otra pulperia ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\set ON_ERROR_STOP off
select fn_fijar_ubicacion_predeterminada(:'ajena');
\echo '--- esperado: esa ubicacion no es de su negocio ---'
select fn_guardar_ubicacion('Secuestrada', :'ajena');
\echo '--- esperado: esa ubicacion no es de su negocio ---'
select fn_ubicaciones('bbbbbbbb-0000-0000-0000-000000000002');
\echo '--- esperado: 0 filas (no es su sucursal) ---'
select fn_ventas_producto_semanas('eeeeeeee-0000-0000-0000-000000000002');
\echo '--- esperado: ese producto no es de su negocio ---'
select fn_agregar_a_conteo('eeeeeeee-0000-0000-0000-000000000002');
\echo '--- esperado: ese producto no es de este negocio ---'
