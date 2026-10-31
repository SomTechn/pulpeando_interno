\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- Semilla de t_pedidos: Arroz 5lb a L 60 en La Esquina, 50 en existencia.
-- Se le pone costo L 45 para que haya utilidad que medir.
insert into producto_costos (organizacion_id, producto_id, sucursal_id, cantidad, valor, costo_promedio, ultimo_costo)
values ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000001', 50, 2250, 45, 45)
on conflict do nothing;
update producto_costos set cantidad = 50, valor = 2250, costo_promedio = 45, ultimo_costo = 45
 where producto_id = 'eeeeeeee-0000-0000-0000-000000000001'
   and sucursal_id = 'bbbbbbbb-0000-0000-0000-000000000001';

insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa)
values ('aaaa0000-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000001','C1','Caja 1', true);
update perfiles set codigo = 'A1' where id = '22222222-2222-2222-2222-222222222222';

\echo '=== Tres ventas de la Auxiliar: 2, 1 y 1 arroces; la ultima se anula ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000c1','22222222-2222-2222-2222-222222222222','22222', 100) as t \gset
select fn_desbloquear_caja(:'t'::uuid,'22222') as d \gset
select fn_registrar_venta(:'d'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":2}]'::jsonb,
  '[{"metodo":"efectivo","monto":120,"recibido":120}]'::jsonb, null) is not null as v1;
select fn_desbloquear_caja(:'t'::uuid,'22222') as d \gset
select fn_registrar_venta(:'d'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  '[{"metodo":"tarjeta","monto":60}]'::jsonb, null) is not null as v2;
select fn_desbloquear_caja(:'t'::uuid,'22222') as d \gset
select (fn_registrar_venta(:'d'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  '[{"metodo":"efectivo","monto":60,"recibido":60}]'::jsonb, null) ->> 'venta_id') as v3 \gset
set role postgres;
update ventas set estado = 'anulada', anulada_en = now() where id = :'v3'::uuid;
-- el turno cerro con L 10 menos de lo esperado
update turnos_caja set estado = 'cerrado', cerrado_en = now(),
       monto_esperado = 220, monto_declarado = 210, diferencia = -10
 where id = :'t'::uuid;

\echo ''
\echo '=== T1: la auxiliar no ve el tablero ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
select fn_tablero();
\echo '--- esperado: El tablero es para el gerente o el dueño ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== T2: el gerente ve sus cifras ==='
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select t -> 'periodo' ->> 'tickets' as tickets,
       t -> 'periodo' ->> 'venta' as venta,
       t -> 'periodo' ->> 'unidades' as unidades,
       t -> 'periodo' ->> 'anuladas' as anuladas,
       t -> 'periodo' ->> 'monto_anulado' as anulado,
       t -> 'periodo' ->> 'ticket_promedio' as ticket,
       t -> 'hoy_ventas' ->> 'venta' as hoy
  from fn_tablero() t;
\echo '--- esperado: 2 | 180.00 | 3 | 1 | 60.00 | 90.00 | 180.00 ---'
select (t -> 'periodo' ->> 'costo')::numeric as costo,
       (t -> 'periodo' ->> 'utilidad')::numeric > 0 as gana,
       t -> 'periodo' ->> 'margen' is not null as hay_margen
  from fn_tablero() t;
\echo '--- esperado: costo = 3 x costo de la venta; gana t; hay_margen t ---'
select jsonb_array_length(t -> 'por_dia') as dias,
       (select sum((x ->> 'venta')::numeric) from jsonb_array_elements(t -> 'por_dia') x) as suma_dias,
       t -> 'top_productos' -> 0 ->> 'nombre' as top,
       t -> 'top_productos' -> 0 ->> 'unidades' as top_u
  from fn_tablero() t;
\echo '--- esperado: 30 | 180.00 | Arroz 5lb | 3 ---'
select (select jsonb_object_agg(x ->> 'metodo', x ->> 'monto') from jsonb_array_elements(t -> 'por_metodo') x) as metodos
  from fn_tablero() t;
\echo '--- esperado: efectivo 120, tarjeta 60 (la anulada no cuenta) ---'
select c ->> 'cajero' as cajero, c ->> 'codigo' as cod, c ->> 'venta' as venta,
       c ->> 'anuladas' as anuladas, c ->> 'faltante' as faltante
  from fn_tablero() t, jsonb_array_elements(t -> 'por_cajero') c;
\echo '--- esperado: Auxiliar 1 | A1 | 180.00 | 1 | -10.00 ---'
select t -> 'caja' ->> 'turnos' as turnos, t -> 'caja' ->> 'faltante' as faltante,
       t -> 'caja' ->> 'con_diferencia' as con_dif
  from fn_tablero() t;
\echo '--- esperado: 1 | -10.00 | 1 ---'
select t -> 'inventario' ->> 'valor_costo' as valor, t -> 'inventario' ->> 'dias_inventario' as dias,
       t -> 'inventario' ->> 'productos' as productos
  from fn_tablero() t;
\echo '--- esperado: valor > 0, dias calculados, 1 producto ---'

\echo ''
\echo '=== T3: el periodo anterior no tiene ventas ==='
select t -> 'anterior' ->> 'venta' as antes from fn_tablero() t;
\echo '--- esperado: 0 ---'

\echo ''
\echo '=== T4: el gerente del otro negocio no ve estas ventas ==='
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select t -> 'periodo' ->> 'venta' as venta, jsonb_array_length(t -> 'por_cajero') as cajeros
  from fn_tablero() t;
\echo '--- esperado: 0 | 0 ---'
\set ON_ERROR_STOP off
select fn_tablero(null, null, 'bbbbbbbb-0000-0000-0000-000000000001');
\echo '--- esperado: Esa sucursal no es de su negocio ---'

\echo ''
\echo '=== T5: fechas al reves y rango de mas de un ano ==='
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_tablero(current_date, current_date - 5);
\echo '--- esperado: La fecha de inicio es despues de la final ---'
select fn_tablero(current_date - 400, current_date);
\echo '--- esperado: hasta un ano ---'
\set ON_ERROR_STOP on
select t ->> 'dias' as dias from fn_tablero(current_date - 6, current_date) t;
\echo '--- esperado: 7 ---'
