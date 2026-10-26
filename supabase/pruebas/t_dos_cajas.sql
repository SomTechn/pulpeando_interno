\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- Un negocio con DOS sucursales, cada una con su caja y su cajera.
-- Antes de la 015 la segunda caja no podia vender: su T-00000001 choca con
-- el de la primera por el indice unique (organizacion_id, numero).

insert into auth.users (id, email) values
  ('aaaa1111-0000-0000-0000-000000000001','caja1@t.hn'),
  ('aaaa1111-0000-0000-0000-000000000002','caja2@t.hn');

insert into organizaciones (id, nombre, pais, moneda)
values ('0f000000-0000-0000-0000-000000000001','Pulperia Dos Ramas','HN','HNL');

insert into sucursales (id, organizacion_id, codigo, nombre, es_principal, activa) values
  ('0f000000-0000-0000-0000-0000000000a1','0f000000-0000-0000-0000-000000000001','001','Rama Uno', true, true),
  ('0f000000-0000-0000-0000-0000000000a2','0f000000-0000-0000-0000-000000000001','002','Rama Dos', false, true);

insert into perfiles (id, organizacion_id, nombre, email, rol, pin_pos, activo) values
  ('aaaa1111-0000-0000-0000-000000000001','0f000000-0000-0000-0000-000000000001','Cajera Uno','caja1@t.hn','auxiliar', crypt('11111', gen_salt('bf')), true),
  ('aaaa1111-0000-0000-0000-000000000002','0f000000-0000-0000-0000-000000000001','Cajera Dos','caja2@t.hn','auxiliar', crypt('22222', gen_salt('bf')), true);

insert into usuario_sucursales (perfil_id, sucursal_id) values
  ('aaaa1111-0000-0000-0000-000000000001','0f000000-0000-0000-0000-0000000000a1'),
  ('aaaa1111-0000-0000-0000-000000000002','0f000000-0000-0000-0000-0000000000a2');

insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa) values
  ('0f000000-0000-0000-0000-0000000000c1','0f000000-0000-0000-0000-000000000001','0f000000-0000-0000-0000-0000000000a1','C1','Caja Rama Uno', true),
  ('0f000000-0000-0000-0000-0000000000c2','0f000000-0000-0000-0000-000000000001','0f000000-0000-0000-0000-0000000000a2','C1','Caja Rama Dos', true);

insert into categorias (id, organizacion_id, nombre)
values ('0f000000-0000-0000-0000-0000000000d1','0f000000-0000-0000-0000-000000000001','Abarrotes');

insert into productos (id, organizacion_id, sku, nombre, categoria_id, tipo, unidad_base, activo, se_vende)
values ('0f000000-0000-0000-0000-0000000000e1','0f000000-0000-0000-0000-000000000001','P1','Azucar 2lb','0f000000-0000-0000-0000-0000000000d1','unidad','unidad',true,true);

-- precio, existencia y costo en LAS DOS sucursales
insert into precios (organizacion_id, producto_id, sucursal_id, nivel, cantidad_minima, precio, vigente_desde) values
  ('0f000000-0000-0000-0000-000000000001','0f000000-0000-0000-0000-0000000000e1','0f000000-0000-0000-0000-0000000000a1','detalle',1,40.00, now()-interval '1 day'),
  ('0f000000-0000-0000-0000-000000000001','0f000000-0000-0000-0000-0000000000e1','0f000000-0000-0000-0000-0000000000a2','detalle',1,40.00, now()-interval '1 day');
insert into existencias (organizacion_id, producto_id, sucursal_id, cantidad) values
  ('0f000000-0000-0000-0000-000000000001','0f000000-0000-0000-0000-0000000000e1','0f000000-0000-0000-0000-0000000000a1', 30),
  ('0f000000-0000-0000-0000-000000000001','0f000000-0000-0000-0000-0000000000e1','0f000000-0000-0000-0000-0000000000a2', 30);
insert into producto_costos (organizacion_id, producto_id, sucursal_id, cantidad, valor, costo_promedio, ultimo_costo) values
  ('0f000000-0000-0000-0000-000000000001','0f000000-0000-0000-0000-0000000000e1','0f000000-0000-0000-0000-0000000000a1',30,750,25,25),
  ('0f000000-0000-0000-0000-000000000001','0f000000-0000-0000-0000-0000000000e1','0f000000-0000-0000-0000-0000000000a2',30,750,25,25);

\echo '### Un negocio, dos sucursales, dos cajas'

\echo ''
\echo '=== M1: la Rama Uno vende ==='
set role authenticated;
set request.jwt.claim.sub = 'aaaa1111-0000-0000-0000-000000000001';
select fn_abrir_turno('0f000000-0000-0000-0000-0000000000c1','aaaa1111-0000-0000-0000-000000000001','11111', 0) as t1 \gset
select fn_desbloquear_caja(:'t1'::uuid,'11111') as d1 \gset
select (fn_registrar_venta(:'d1'::uuid,
  '[{"producto_id":"0f000000-0000-0000-0000-0000000000e1","cantidad":1}]'::jsonb,
  '[{"metodo":"efectivo","monto":40.00,"recibido":40.00}]'::jsonb))->>'numero' as venta_rama_uno;

\echo ''
\echo '=== M2: la Rama Dos vende. ANTES de la 015 esto reventaba ==='
set request.jwt.claim.sub = 'aaaa1111-0000-0000-0000-000000000002';
select fn_abrir_turno('0f000000-0000-0000-0000-0000000000c2','aaaa1111-0000-0000-0000-000000000002','22222', 0) as t2 \gset
select fn_desbloquear_caja(:'t2'::uuid,'22222') as d2 \gset
select (fn_registrar_venta(:'d2'::uuid,
  '[{"producto_id":"0f000000-0000-0000-0000-0000000000e1","cantidad":1}]'::jsonb,
  '[{"metodo":"efectivo","monto":40.00,"recibido":40.00}]'::jsonb))->>'numero' as venta_rama_dos;

\echo ''
\echo '=== M3: cada rama sigue su propia corrida ==='
set request.jwt.claim.sub = 'aaaa1111-0000-0000-0000-000000000001';
select fn_desbloquear_caja(:'t1'::uuid,'11111') as d3 \gset
select (fn_registrar_venta(:'d3'::uuid,
  '[{"producto_id":"0f000000-0000-0000-0000-0000000000e1","cantidad":1}]'::jsonb,
  '[{"metodo":"efectivo","monto":40.00,"recibido":40.00}]'::jsonb))->>'numero' as rama_uno_otra_vez;
set request.jwt.claim.sub = 'aaaa1111-0000-0000-0000-000000000002';
select fn_desbloquear_caja(:'t2'::uuid,'22222') as d4 \gset
select (fn_registrar_venta(:'d4'::uuid,
  '[{"producto_id":"0f000000-0000-0000-0000-0000000000e1","cantidad":1}]'::jsonb,
  '[{"metodo":"efectivo","monto":40.00,"recibido":40.00}]'::jsonb))->>'numero' as rama_dos_otra_vez;

\echo ''
\echo '=== M4: los cuatro numeros, todos distintos ==='
reset role;
select s.nombre as sucursal, v.numero, v.total
from ventas v join sucursales s on s.id = v.sucursal_id
where v.organizacion_id = '0f000000-0000-0000-0000-000000000001'
order by s.codigo, v.numero;

select count(*) as ventas, count(distinct numero) as numeros_distintos
from ventas where organizacion_id = '0f000000-0000-0000-0000-000000000001';

\echo ''
\echo '=== M5: y los pedidos igual, una sucursal cada uno ==='
insert into auth.users (id, email) values ('cccc2222-0000-0000-0000-000000000001','compra@t.hn');
set role authenticated;
set request.jwt.claim.sub = 'cccc2222-0000-0000-0000-000000000001';
select (fn_crear_pedido(
  '[{"producto_id":"0f000000-0000-0000-0000-0000000000e1","cantidad":1}]'::jsonb,
  '0f000000-0000-0000-0000-0000000000a1', null, 'app_cliente', 'recoge_en_tienda'))->>'numero' as pedido_rama_uno;
select (fn_crear_pedido(
  '[{"producto_id":"0f000000-0000-0000-0000-0000000000e1","cantidad":1}]'::jsonb,
  '0f000000-0000-0000-0000-0000000000a2', null, 'app_cliente', 'recoge_en_tienda'))->>'numero' as pedido_rama_dos;
reset role;
select count(*) as pedidos, count(distinct numero) as numeros_distintos
from pedidos where organizacion_id = '0f000000-0000-0000-0000-000000000001';

\echo ''
\echo '### FIN DOS CAJAS'
