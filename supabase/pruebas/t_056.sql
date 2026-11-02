\pset pager off
set role postgres;
insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa) values
 ('aaaa0000-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','C1','Caja 1', true);
update organizaciones set permite_stock_negativo = true where id = 'aaaaaaaa-0000-0000-0000-000000000001';

\echo '=== C1: tiempo de una venta ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000c1','11111111-1111-1111-1111-111111111111','11111', 0) as t \gset
select fn_desbloquear_caja(:'t'::uuid,'11111') as d \gset
select (fn_registrar_venta(:'d'::uuid, '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":3}]'::jsonb,
  '[{"metodo":"efectivo","monto":180,"recibido":200}]'::jsonb))->>'venta_id' as v \gset
select fn_anotar_tiempo_venta(:'v'::uuid, now() - interval '95 seconds') as segundos;
select fn_anotar_tiempo_venta(:'v'::uuid, now() - interval '10 seconds') as segunda_vez_no_cambia;
reset role;
select segundos from venta_tiempos where venta_id = :'v'::uuid;
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_anotar_tiempo_venta(:'v'::uuid, now());
reset role;
\echo '--- esperado: 95 ; (nulo) ; 95 ; error solo quien cobró ---'

\echo ''
\echo '=== C2: indicadores ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_cajeros_indicadores(current_date, current_date);
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select x->>'nombre' nombre, (x->>'ventas')::int ventas, (x->>'total')::numeric total, (x->>'lineas')::int lineas,
       (x->>'segundos_venta')::int seg, (x->>'en_turno')::boolean en_turno, (x->>'horas')::numeric >= 0 horas
  from jsonb_array_elements(fn_cajeros_indicadores(current_date, current_date)->'cajeros') x
 order by 1;
select fn_cajeros_indicadores(current_date, current_date - 1);
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select jsonb_array_length(fn_cajeros_indicadores(current_date, current_date)->'cajeros') otro_negocio_solo_los_suyos;
reset role;
select has_function_privilege('anon','fn_cajeros_indicadores(date,date,uuid)','execute') a1,
       has_table_privilege('authenticated','venta_tiempos','select') a2;
\echo '--- esperado: error supervisor ; Auxiliar 1 0 · Gerente 1 con 1 venta 180 1 línea 95 s en turno ; error fechas ; 1 ; f f ---'
