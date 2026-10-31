\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- Sobre la semilla de t_pedidos: org 1 = La Esquina, org 2 = Dona Chus.
-- Auxiliar 1 (22222) es la cajera; Gerente 2 es de la otra pulpería.
insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa) values
 ('aaaa0000-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-000000000001',
  'bbbbbbbb-0000-0000-0000-000000000001','C1','Caja 1', true),
 ('aaaa0000-0000-0000-0000-0000000000c2','aaaaaaaa-0000-0000-0000-000000000001',
  'bbbbbbbb-0000-0000-0000-000000000001','C2','Caja 2', true),
 ('aaaa0000-0000-0000-0000-0000000000c9','aaaaaaaa-0000-0000-0000-000000000002',
  'bbbbbbbb-0000-0000-0000-000000000002','C1','Caja de Chus', true);

\echo '=== T1: cada negocio tiene su código de tienda, distinto y de 3 dígitos ==='
select count(distinct codigo_tienda) = count(*) as distintos,
       bool_and(codigo_tienda ~ '^[1-9][0-9]{2}$') as tres_digitos
  from organizaciones;
\echo '--- esperado: t | t ---'

\echo ''
\echo '=== T2: números de cajero y de caja, por negocio ==='
select nombre, numero_cajero from perfiles order by organizacion_id, numero_cajero;
select nombre, numero from cajas order by organizacion_id, numero;
\echo '--- esperado: Gerente 1 = 1, Auxiliar 1 = 2, Gerente 2 = 1; Caja 1 = 1, Caja 2 = 2, Caja de Chus = 1 ---'

\echo ''
\echo '=== T3: una venta en la Caja 2 lleva su código ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000c2','22222222-2222-2222-2222-222222222222','22222', 0) as t \gset
select fn_desbloquear_caja(:'t'::uuid,'22222') as d \gset
select (fn_registrar_venta(:'d'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  '[{"metodo":"efectivo","monto":60.00,"recibido":100.00}]'::jsonb)->>'venta_id') as vid \gset
reset role;
select v.codigo_barras ~ '^[0-9]{16}$' as dieciseis,
       substr(v.codigo_barras, 1, 3) = o.codigo_tienda as tienda,
       substr(v.codigo_barras, 4, 3) = '002' as cajero,
       substr(v.codigo_barras, 7, 2) = '02' as caja
  from ventas v join organizaciones o on o.id = v.organizacion_id where v.id = :'vid'::uuid;
\echo '--- esperado: t | t | t | t ---'
select codigo_barras as cod from ventas where id = :'vid'::uuid \gset

\echo ''
\echo '=== T4: la cajera escanea el ticket (con guiones también) ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select (fn_buscar_ticket(:'cod')->>'venta_id') = :'vid' as encontro;
select (fn_buscar_ticket(substr(:'cod',1,3)||'-'||substr(:'cod',4,3)||'-'||substr(:'cod',7,2)||'-'||substr(:'cod',9))->>'ok') as con_guiones;
select fn_buscar_ticket('12345')->>'mensaje' as corto;
select fn_buscar_ticket(left(:'cod', 8) || '00000000')->>'mensaje' as inexistente;
\echo '--- esperado: t | true | Eso no es un código de ticket | No hay ninguna venta con ese ticket ---'

\echo ''
\echo '=== T5: la venta completa trae el código, la tienda y el logo ==='
reset role;
update organizaciones set config = config || '{"logo_path":"aaaaaaaa-0000-0000-0000-000000000001/logo-1.png"}'
 where id = 'aaaaaaaa-0000-0000-0000-000000000001';
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_venta_completa(:'vid'::uuid)->'venta'->>'codigo_barras' = :'cod' as codigo,
       fn_venta_completa(:'vid'::uuid)->'negocio'->>'codigo_tienda' = left(:'cod', 3) as tienda,
       fn_venta_completa(:'vid'::uuid)->'negocio'->>'logo_path' as logo;
\echo '--- esperado: t | t | aaaaaaaa-.../logo-1.png ---'

\echo ''
\echo '=== T6: el gerente de la OTRA pulpería escanea ese ticket ==='
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select fn_buscar_ticket(:'cod')->>'mensaje' as otra;
\echo '--- esperado: Ese ticket es de otra tienda ---'

\echo ''
\echo '=== T7: y si falsifica el prefijo con SU tienda, tampoco ve la venta ==='
select o.codigo_tienda || substr(:'cod', 4) as falso from organizaciones o
 where o.id = 'aaaaaaaa-0000-0000-0000-000000000002' \gset
select fn_buscar_ticket(:'falso')->>'mensaje' as falso;
\echo '--- esperado: No hay ninguna venta con ese ticket ---'

\echo ''
\echo '=== T8: nadie cambia los números desde la app ==='
\set ON_ERROR_STOP off
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
update organizaciones set codigo_tienda = '555' where id = 'aaaaaaaa-0000-0000-0000-000000000001';
\echo '--- esperado: ERROR El código de tienda lo asigna Pulpeando ---'
update cajas set numero = 7 where id = 'aaaa0000-0000-0000-0000-0000000000c1';
\echo '--- esperado: ERROR El número de caja lo asigna el sistema ---'
update perfiles set numero_cajero = 50 where id = '22222222-2222-2222-2222-222222222222';
\echo '--- esperado: ERROR El número de cajero lo asigna el sistema ---'
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
update perfiles set numero_cajero = 9 where id = '22222222-2222-2222-2222-222222222222';
\echo '--- esperado: ERROR El número de cajero (su propio perfil tampoco) ---'
\echo ''
\echo '=== T9: pero el gerente sí edita su caja y su negocio como siempre ==='
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
update cajas set nombre = 'Caja 1 (entrada)' where id = 'aaaa0000-0000-0000-0000-0000000000c1';
update organizaciones set nombre = 'La Esquina' where id = 'aaaaaaaa-0000-0000-0000-000000000001';
\echo '--- esperado: UPDATE 1 | UPDATE 1 ---'

\echo ''
\echo '=== T10: anon y las funciones internas ==='
set role anon;
select fn_buscar_ticket(:'cod');
\echo '--- esperado: ERROR permission denied ---'
set role authenticated;
select app.codigo_de_venta('aaaaaaaa-0000-0000-0000-000000000001', null, null);
\echo '--- esperado: ERROR permission denied ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== T11: una caja nueva toma el siguiente número; una venta sin caja ni cajero va con ceros ==='
reset role;
insert into cajas (organizacion_id, sucursal_id, codigo, nombre)
values ('aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','C3','Caja 3')
returning numero;
select app.codigo_de_venta('aaaaaaaa-0000-0000-0000-000000000001', null, null) ~ '^[1-9][0-9]{2}00000[0-9]{8}$' as ceros;
\echo '--- esperado: 3 | t ---'

