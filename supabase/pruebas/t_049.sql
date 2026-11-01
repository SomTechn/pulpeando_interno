\pset pager off
set role postgres;
-- Semilla de t_pedidos: La Esquina, Gerente 1 (PIN 11111), Auxiliar 1, arroz eeee…01.
insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa) values
 ('aaaa0000-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','C1','Caja 1', true);
update organizaciones set permite_stock_negativo = true where id = 'aaaaaaaa-0000-0000-0000-000000000001';

set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select (fn_crear_pedido('[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":2}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001', null, 'mostrador', 'domicilio',
  null, 'Col. Kennedy', 'Don Pedro', '9999-2222', 'efectivo') ->> 'pedido_id') as p1 \gset
select fn_cambiar_estado_pedido(:'p1'::uuid, 'confirmado', null);
select fn_cambiar_estado_pedido(:'p1'::uuid, 'listo', null);
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000c1','11111111-1111-1111-1111-111111111111','11111', 0) as t \gset
select fn_desbloquear_caja(:'t'::uuid,'11111') as d \gset
select fn_facturar_pedido(:'p1'::uuid, :'d'::uuid) ->> 'venta_id' is not null as cobrado;
reset role;
select venta_id as v1 from pedidos where id = :'p1' \gset
select sum(cantidad) as exist_antes from existencias where producto_id = 'eeeeeeee-0000-0000-0000-000000000001' and sucursal_id = 'bbbbbbbb-0000-0000-0000-000000000001' \gset

\echo '=== E1: el pedido cobrado y listo (el que se quedaba pegado) ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_cambiar_estado_pedido(:'p1'::uuid, 'cancelado', 'por el camino viejo');
select fn_cambiar_estado_pedido(:'p1'::uuid, 'en_ruta', null);
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_cancelar_pedido(:'p1'::uuid, 'no lo quiere');
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_cancelar_pedido(:'p1'::uuid, '  ');
reset role;
\echo '--- esperado: error «Use Cancelar pedido» ; error asigne repartidor ; error solo supervisor ; error diga por qué ---'

\echo ''
\echo '=== E2: el supervisor cancela: se anula la venta y vuelve la mercadería ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select r ->> 'venta_anulada' as anulo, r ->> 'turno_cerrado' as cerrado, (r ->> 'efectivo')::numeric > 0 as efectivo
  from (select fn_cancelar_pedido(:'p1'::uuid, 'El cliente ya no lo quiere') r) x;
select fn_cancelar_pedido(:'p1'::uuid, 'otra vez');
reset role;
select p.estado, p.motivo_cancelacion, v.estado as venta, v.motivo_anulacion,
       (select sum(cantidad) from existencias where producto_id = 'eeeeeeee-0000-0000-0000-000000000001' and sucursal_id = 'bbbbbbbb-0000-0000-0000-000000000001') - :'exist_antes' as volvio,
       (select count(*) from pedido_reservas where pedido_id = p.id and liberada_en is null) as reservas_vivas,
       (select nota from pedido_eventos where pedido_id = p.id order by ocurrido_en desc, id desc limit 1) as evento
  from pedidos p join ventas v on v.id = p.venta_id where p.id = :'p1';
\echo '--- esperado: true | false | t ; error ya cancelado ; cancelado | El cliente ya no lo quiere | anulada | Pedido P-… cancelado: … | 2 | 0 | … (se anuló la venta …) ---'

\echo ''
\echo '=== E3: un pedido nuevo, sin cobrar, se cancela sin tocar ventas ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select (fn_crear_pedido('[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001', null, 'mostrador', 'recoge_en_tienda',
  null, null, 'Doña Ana', '9999-3333', 'efectivo') ->> 'pedido_id') as p2 \gset
select r ->> 'venta_anulada' as anulo from (select fn_cancelar_pedido(:'p2'::uuid, 'Pedido duplicado') r) x;
reset role;
select estado from pedidos where id = :'p2';
\echo '--- esperado: false ; cancelado ---'

\echo ''
\echo '=== E4: cobrado en un turno ya cerrado: se cancela y avisa ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select (fn_crear_pedido('[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  'bbbbbbbb-0000-0000-0000-000000000001', null, 'mostrador', 'domicilio',
  null, 'Col. Kennedy', 'Don Pedro', '9999-2222', 'efectivo') ->> 'pedido_id') as p3 \gset
select fn_cambiar_estado_pedido(:'p3'::uuid, 'confirmado', null);
select fn_cambiar_estado_pedido(:'p3'::uuid, 'listo', null);
select fn_desbloquear_caja(:'t'::uuid,'11111') as d \gset
select fn_facturar_pedido(:'p3'::uuid, :'d'::uuid) ->> 'venta_id' is not null as cobrado;
reset role;
update turnos_caja set estado = 'cerrado', cerrado_en = now() where id = :'t';
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select r ->> 'venta_anulada' as anulo, r ->> 'turno_cerrado' as cerrado from (select fn_cancelar_pedido(:'p3'::uuid, 'Se cobró dos veces') r) x;
reset role;
\echo '--- esperado: true | true ---'

\echo ''
\echo '=== E5: otro negocio no cancela, y lo de la 029 existe ==='
set role authenticated;
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select fn_cancelar_pedido(:'p2'::uuid, 'ajeno');
reset role;
select has_function_privilege('anon', 'fn_cancelar_pedido(uuid,text)', 'execute') as anon,
       has_function_privilege('authenticated', 'fn_mis_entregas_v2()', 'execute') as v2,
       has_function_privilege('authenticated', 'fn_entrega_fallida(uuid,text)', 'execute') as fallida,
       (select count(*) from information_schema.columns where table_name = 'v_pedidos_tablero' and column_name = 'incidencia') as vista;
\echo '--- esperado: error (permiso: ya cancelado o ajeno) ; f | t | t | 1 ---'
