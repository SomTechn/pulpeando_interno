\pset pager off
set role postgres;
insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa) values
 ('aaaa0000-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','C1','Caja 1', true);
update organizaciones set permite_stock_negativo = true where id = 'aaaaaaaa-0000-0000-0000-000000000001';

\echo '=== D1: un turno de ayer se cierra solo a medianoche ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000c1','11111111-1111-1111-1111-111111111111','11111', 50) as t \gset
select fn_desbloquear_caja(:'t'::uuid,'11111') as d \gset
select (fn_registrar_venta(:'d'::uuid, '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":3}]'::jsonb,
  '[{"metodo":"efectivo","monto":180,"recibido":200}]'::jsonb))->>'venta_id' as v \gset
reset role;
select app.cerrar_turnos_vencidos() as hoy_no_cierra_nada;
-- Se abrió ayer a las 3 pm hora del negocio
update turnos_caja set abierto_en = (((now() at time zone 'America/Tegucigalpa')::date - 1 + time '15:00')::timestamp at time zone 'America/Tegucigalpa') where id = :'t'::uuid;
select app.cerrar_turnos_vencidos() as cerrados;
select estado, cerrado_auto, monto_esperado, monto_declarado is null sin_conteo,
       (cerrado_en at time zone 'America/Tegucigalpa') = (now() at time zone 'America/Tegucigalpa')::date::timestamp a_medianoche,
       notas from turnos_caja where id = :'t'::uuid;
select count(*) filter (where consumido_en is null) desbloqueos_vivos from caja_desbloqueos where turno_id = :'t'::uuid;
select app.cerrar_turnos_vencidos() as segunda_vez;
\echo '--- esperado: 0 ; 1 ; cerrado t 230 t t "Cerrado automáticamente a medianoche" ; 0 ; 0 ---'

\echo ''
\echo '=== D2: la caja ya no vende en ese turno ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_desbloquear_caja(:'t'::uuid,'11111');
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000c1','11111111-1111-1111-1111-111111111111','11111', 0) is not null as abre_otro;
reset role;
\echo '--- esperado: error no está abierto ; t ---'

\echo ''
\echo '=== D3: lista de cierres ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_cierres_caja(current_date - 1, current_date);
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select x->>'cajero' cajero, x->>'caja' caja, (x->>'automatico')::boolean auto, (x->>'ventas')::int ventas,
       (x->>'total')::numeric total, x->'metodos' metodos, (x->>'esperado')::numeric esperado, x->>'declarado' declarado
  from jsonb_array_elements(fn_cierres_caja(current_date - 1, current_date)->'cierres') x;
select (fn_cierres_caja(current_date - 1, current_date)->>'abiertos')::int abiertos;
select fn_cierres_caja(current_date, current_date - 1);
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select jsonb_array_length(fn_cierres_caja(current_date - 1, current_date)->'cierres') otro_negocio;
reset role;
select has_function_privilege('anon','fn_cierres_caja(date,date,uuid)','execute') a1,
       has_function_privilege('authenticated','app.cerrar_turnos_vencidos()','execute') a2;
\echo '--- esperado: error supervisor ; 1 fila auto t 1 venta 180 {"efectivo":180} 230 nulo ; 1 ; error fechas ; 0 ; f f ---'
