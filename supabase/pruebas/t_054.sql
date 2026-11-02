\pset pager off
set role postgres;
insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa) values
 ('aaaa0000-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','C1','Caja 1', true);
update organizaciones set permite_stock_negativo = true where id = 'aaaaaaaa-0000-0000-0000-000000000001';
insert into precios (organizacion_id, producto_id, sucursal_id, nivel, cantidad_minima, precio, vigente_desde, vigente_hasta, es_oferta) values
 ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','detalle',1, 50.00, current_date - 1, current_date + 6, true);

\echo '=== P1: el catálogo de la caja trae el precio de siempre y la oferta ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select precio, precio_normal, oferta_hasta = current_date + 6 as hasta
  from fn_ofertas_caja('bbbbbbbb-0000-0000-0000-000000000001') where producto_id = 'eeeeeeee-0000-0000-0000-000000000001';
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select count(*) as otro_negocio from fn_ofertas_caja('bbbbbbbb-0000-0000-0000-000000000001');
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
reset role;
\echo '--- esperado: 50 | 60 | t ; 0 ---'

\echo ''
\echo '=== P2: anotar las rebajas de una venta y verlas al imprimir ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000c1','11111111-1111-1111-1111-111111111111','11111', 0) as t \gset
select fn_desbloquear_caja(:'t'::uuid,'11111') as d \gset
select (fn_registrar_venta(:'d'::uuid, '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":2}]'::jsonb,
  '[{"metodo":"efectivo","monto":100,"recibido":100}]'::jsonb))->>'venta_id' as v \gset
select fn_anotar_rebajas(:'v'::uuid, '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","nombre":"x","cantidad":1,"precio":50},{"producto_id":null,"nombre":"Pan suelto","cantidad":2,"precio":3}]'::jsonb) as anotadas;
select fn_anotar_rebajas(:'v'::uuid, '[{"producto_id":null,"nombre":"Otra","cantidad":1,"precio":3}]'::jsonb) as segunda_vez;
select jsonb_array_length(r->'rebajas') n, r->'rebajas'->0->>'producto' p1, (r->'rebajas'->0->>'total')::numeric t1,
       r->'rebajas'->1->>'producto' p2
  from (select fn_venta_completa(:'v'::uuid) r) x;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_anotar_rebajas(:'v'::uuid, '[{"nombre":"x","cantidad":1}]'::jsonb);
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select fn_anotar_rebajas(:'v'::uuid, '[{"nombre":"x","cantidad":1}]'::jsonb);
reset role;
select has_table_privilege('authenticated','venta_rebajas','select') a1,
       has_function_privilege('anon','fn_anotar_rebajas(uuid,jsonb)','execute') a2,
       has_function_privilege('anon','fn_ofertas_caja(uuid)','execute') a3;
\echo '--- esperado: 2 ; 0 ; 2 | Arroz 5lb (el nombre del producto) | 50 | Pan suelto ; error solo quien cobró ; error otro negocio ; f f f ---'
