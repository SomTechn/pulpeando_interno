\pset pager off
set role postgres;
insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa) values
 ('aaaa0000-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','C1','Caja 1', true);
update organizaciones set permite_stock_negativo = true where id = 'aaaaaaaa-0000-0000-0000-000000000001';
insert into auth.users (id, email) values ('bbbb0000-0000-0000-0000-000000000001','sup1@t.hn');
insert into perfiles (id, organizacion_id, nombre, email, rol, activo) values
 ('bbbb0000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Supervisor','sup1@t.hn','supervisor', true);

\echo '=== G1: ventas por día ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000c1','11111111-1111-1111-1111-111111111111','11111', 0) as t \gset
select fn_desbloquear_caja(:'t'::uuid,'11111') as d \gset
select fn_registrar_venta(:'d'::uuid, '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":3}]'::jsonb,
  '[{"metodo":"efectivo","monto":180,"recibido":200}]'::jsonb) is not null as vendio;
select count(*) as dias, sum(unidades) as unidades, max(dia) = (now() at time zone 'America/Tegucigalpa')::date as hoy_al_final,
       (select unidades from fn_ventas_producto_dias('eeeeeeee-0000-0000-0000-000000000001') order by dia desc limit 1) as hoy
  from fn_ventas_producto_dias('eeeeeeee-0000-0000-0000-000000000001');
select count(*) as siete from fn_ventas_producto_dias('eeeeeeee-0000-0000-0000-000000000001', 7);
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select * from fn_ventas_producto_dias('eeeeeeee-0000-0000-0000-000000000001');
reset role;
\echo '--- esperado: t ; 30 | 3 | t | 3 ; 7 ; error de otro negocio ---'

\echo ''
\echo '=== G2: crear bodega ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_crear_bodega('Bodega trasera');
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select r ->> 'nombre' as nombre, r ->> 'codigo' ~ '-B[0-9]+$' as codigo_bodega from (select fn_crear_bodega('Bodega trasera') r) x;
select fn_crear_bodega('bodega TRASERA');
select fn_crear_bodega('  ');
reset role;
select tipo, activa from ubicaciones where nombre = 'Bodega trasera';
\echo '--- esperado: error auxiliar ; Bodega trasera | t ; error repetida ; error sin nombre ; bodega | t ---'

\echo ''
\echo '=== G3: lo que hay en una bodega ==='
select id as bod from ubicaciones where nombre = 'Bodega trasera' \gset
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-000000000001', :'bod'::uuid, 12) is not null as movio;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select r ->> 'nombre' as nombre, jsonb_array_length(r -> 'productos') as productos,
       r -> 'productos' -> 0 ->> 'nombre' as producto, (r -> 'productos' -> 0 ->> 'cantidad')::numeric as cantidad, r ->> 'auditada_en' as auditada
  from (select fn_bodega_productos(:'bod'::uuid) r) x;
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select fn_bodega_productos(:'bod'::uuid);
reset role;
select has_function_privilege('anon', 'fn_crear_bodega(text,uuid)', 'execute') as anon1,
       has_function_privilege('anon', 'fn_bodega_productos(uuid)', 'execute') as anon2,
       has_function_privilege('anon', 'fn_ventas_producto_dias(uuid,int,uuid)', 'execute') as anon3;
\echo '--- esperado: t ; Bodega trasera | 1 | Arroz 5lb | 12 | (nulo) ; error otro negocio ; f | f | f ---'
