\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- Semilla de t_pedidos. Gerente 1 = 1111, Auxiliar 1 = 2222 (PIN 22222),
-- Gerente 2 de otro negocio = 9999. Arroz a L 60, costo L 45.
insert into producto_costos (organizacion_id, producto_id, sucursal_id, cantidad, valor, costo_promedio, ultimo_costo)
values ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000001', 50, 2250, 45, 45)
on conflict do nothing;
update producto_costos set cantidad = 50, valor = 2250, costo_promedio = 45, ultimo_costo = 45
 where producto_id = 'eeeeeeee-0000-0000-0000-000000000001'
   and sucursal_id = 'bbbbbbbb-0000-0000-0000-000000000001';
insert into auth.users (id, email) values ('bbbb0000-0000-0000-0000-000000000001','sup1@t.hn');
insert into perfiles (id, organizacion_id, nombre, email, rol, pin_pos, activo) values
 ('bbbb0000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
  'Supervisor','sup1@t.hn','supervisor', crypt('77777', gen_salt('bf')), true);
insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa)
values ('aaaa0000-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000001','C1','Caja 1', true);

\echo '=== Turno con fondo L 500 y dos ventas en efectivo (L 120 y L 60) ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000c1','22222222-2222-2222-2222-222222222222','22222', 500) as t \gset
select fn_desbloquear_caja(:'t'::uuid,'22222') as d \gset
select fn_registrar_venta(:'d'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":2}]'::jsonb,
  '[{"metodo":"efectivo","monto":120,"recibido":120}]'::jsonb, null) is not null as v1;
select fn_desbloquear_caja(:'t'::uuid,'22222') as d \gset
select fn_registrar_venta(:'d'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  '[{"metodo":"efectivo","monto":60,"recibido":60}]'::jsonb, null) is not null as v2;

\echo ''
\echo '=== F1: la cajera manda sus eventos (abortada, suspendida, linea quitada) ==='
select fn_eventos_caja(jsonb_build_array(
  jsonb_build_object('id','f0000000-0000-0000-0000-000000000001','caja_id','aaaa0000-0000-0000-0000-0000000000c1',
    'turno_id', :'t', 'tipo','abortada','lineas',3,'unidades',4,'monto',230.5,
    'detalle', '[{"nombre":"Arroz","cantidad":2}]'::jsonb, 'ocurrido_en', now()),
  jsonb_build_object('id','f0000000-0000-0000-0000-000000000002','caja_id','aaaa0000-0000-0000-0000-0000000000c1',
    'turno_id', :'t', 'tipo','suspendida','lineas',1,'monto',60, 'ocurrido_en', now()),
  jsonb_build_object('id','f0000000-0000-0000-0000-000000000003','caja_id','aaaa0000-0000-0000-0000-0000000000c1',
    'turno_id', :'t', 'tipo','linea_quitada','lineas',1,'unidades',1,'monto',60, 'ocurrido_en', now()),
  jsonb_build_object('id','f0000000-0000-0000-0000-000000000004','caja_id','aaaa0000-0000-0000-0000-0000000000c1',
    'tipo','inventado','monto',1, 'ocurrido_en', now())
)) as recibidos;
\echo '--- esperado: 3 (el tipo inventado se ignora) ---'
select fn_eventos_caja(jsonb_build_array(
  jsonb_build_object('id','f0000000-0000-0000-0000-000000000001','caja_id','aaaa0000-0000-0000-0000-0000000000c1',
    'tipo','abortada','monto',230.5, 'ocurrido_en', now()))) as repetido;
\echo '--- esperado: 0. El reintento sin internet no lo duplica ---'

\echo ''
\echo '=== F2: el gerente de otro negocio no puede meter eventos en esta caja ==='
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select fn_eventos_caja(jsonb_build_array(
  jsonb_build_object('id','f0000000-0000-0000-0000-000000000009','caja_id','aaaa0000-0000-0000-0000-0000000000c1',
    'tipo','abortada','monto',1, 'ocurrido_en', now()))) as metidos;
\echo '--- esperado: 0 ---'

\echo ''
\echo '=== F3: la auxiliar no registra egresos ni ve Finanzas ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
select fn_categorias_egreso();
select fn_finanzas_resumen();
\echo '--- esperado: dos errores de permiso ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== F4: el gerente registra luz (oficina) y un pago desde la gaveta ==='
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select jsonb_array_length(fn_categorias_egreso()) as categorias;
\echo '--- esperado: 16 categorias de arranque ---'
select (fn_registrar_egreso(
   (select id from categorias_egreso where nombre = 'Energía eléctrica'), 1500, 'Factura ENEE octubre',
   null, 'transferencia', 'banco') ->> 'ok') as luz;
select (fn_registrar_egreso(
   (select id from categorias_egreso where nombre = 'Transporte y combustible'), 100, 'Flete de agua',
   null, 'efectivo', 'caja', null, 'Don Chepe', null, :'t') ->> 'movimiento_id') is not null as de_la_gaveta;
select app.efectivo_esperado(:'t'::uuid) as en_gaveta;
\echo '--- esperado: t, t, y en gaveta 500 + 180 - 100 = 580 ---'
\set ON_ERROR_STOP off
select fn_registrar_egreso((select id from categorias_egreso where nombre = 'Agua'),
   99999, 'Más de lo que hay', null, 'efectivo', 'caja', null, null, null, :'t');
\echo '--- esperado: En esa gaveta el sistema solo cuenta con 580.00 ---'
select fn_registrar_egreso((select id from categorias_egreso where nombre = 'Agua'),
   10, 'Del futuro', current_date + 3);
\echo '--- esperado: La fecha no puede ser futura ---'
\set ON_ERROR_STOP on
select (fn_registrar_egreso((select id from categorias_egreso where nombre = 'Retiro del dueño'),
   300, 'Para la casa') ->> 'ok') as retiro;

\echo ''
\echo '=== F5: el estado de resultados ==='
select r -> 'resultados' ->> 'venta_bruta' as bruta,
       r -> 'resultados' ->> 'costo_ventas' as costo,
       r -> 'resultados' ->> 'utilidad_bruta' as ub,
       r -> 'resultados' ->> 'gastos' as gastos,
       r -> 'resultados' ->> 'utilidad_neta' as neta,
       r -> 'resultados' ->> 'retiros_dueno' as retiros
  from fn_finanzas_resumen() r;
\echo '--- esperado: 180 | 135 | 45 (sin ISV) | 1600 | 45 - 1600 = -1555 | 300 (el retiro NO es gasto) ---'
select r -> 'indicadores' ->> 'markup' as markup, r -> 'indicadores' ->> 'margen_bruto' as margen,
       r -> 'indicadores' ->> 'punto_equilibrio' as equilibrio
  from fn_finanzas_resumen() r;
\echo '--- esperado: markup 33.3, margen 25.0, equilibrio 1600 / 0.25 = 6400 ---'
select r -> 'caja' ->> 'abortadas' as abortadas, r -> 'caja' ->> 'monto_abortado' as m_ab,
       r -> 'caja' ->> 'suspendidas' as susp, r -> 'caja' ->> 'lineas_quitadas' as quitadas
  from fn_finanzas_resumen() r;
\echo '--- esperado: 1 | 230.50 | 1 | 1 ---'

\echo ''
\echo '=== F6: el supervisor ve Finanzas pero no la utilidad ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select r -> 'resultados' is null or r -> 'resultados' = 'null'::jsonb as sin_resultados,
       r -> 'indicadores' ->> 'markup' as markup, r -> 'caja' ->> 'abortadas' as abortadas
  from fn_finanzas_resumen() r;
\echo '--- esperado: t | (null) | 1 ---'
\set ON_ERROR_STOP off
select fn_anular_egreso((select id from egresos where concepto = 'Flete de agua'), 'no');
\echo '--- esperado: Solo el gerente anula egresos ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== F7: listas ==='
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select jsonb_array_length(fn_finanzas_lista('egresos')) as egresos,
       jsonb_array_length(fn_finanzas_lista('abortadas')) as abortadas,
       jsonb_array_length(fn_finanzas_lista('suspendidas')) as suspendidas,
       jsonb_array_length(fn_finanzas_lista('quitadas')) as quitadas;
\echo '--- esperado: 3 | 1 | 1 | 1 ---'

\echo ''
\echo '=== F8: anular el egreso de la gaveta devuelve el dinero ==='
select fn_anular_egreso((select id from egresos where concepto = 'Flete de agua'), 'Lo pagó el proveedor');
select app.efectivo_esperado(:'t'::uuid) as en_gaveta;
\echo '--- esperado: t y 680 ---'

\echo ''
\echo '=== F9: cierre con faltante y arqueos ==='
set role postgres;
update turnos_caja set estado = 'cerrado', cerrado_en = now(), cerrado_por = '11111111-1111-1111-1111-111111111111',
       monto_esperado = 680, monto_declarado = 650, diferencia = -30 where id = :'t'::uuid;
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select x ->> 'tipo' as tipo, x ->> 'cajero' as cajero, x ->> 'diferencia' as dif
  from jsonb_array_elements(fn_finanzas_lista('arqueos')) x;
select x ->> 'cajero' as cajero, x ->> 'turnos' as turnos, x ->> 'faltante' as faltante
  from jsonb_array_elements(fn_finanzas_lista('cuadre')) x;
\echo '--- esperado: cierre | Auxiliar 1 | -30.00 ; Auxiliar 1 | 1 | -30.00 ---'
\set ON_ERROR_STOP off
select fn_anular_egreso((select id from egresos where concepto = 'Factura ENEE octubre' ), '');
\echo '--- esperado: Escriba por qué se anula ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== F10: el otro negocio no ve nada de esto ==='
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select jsonb_array_length(fn_finanzas_lista('egresos')) as egresos,
       fn_finanzas_resumen() -> 'caja' ->> 'abortadas' as abortadas;
\echo '--- esperado: 0 | 0 ---'
select count(*) as filas_visibles from egresos;
\echo '--- esperado: 0 ---'

\echo ''
\echo '=== F11: el contexto trae el color de la marca ==='
set role postgres;
update organizaciones set config = coalesce(config, '{}'::jsonb) || '{"color_marca":"#7C3AED"}'
 where id = 'aaaaaaaa-0000-0000-0000-000000000001';
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_pos_contexto() -> 'organizacion' ->> 'color' as color;
set role postgres;
update organizaciones set config = config || '{"color_marca":"red; background:url(x)"}'
 where id = 'aaaaaaaa-0000-0000-0000-000000000001';
set role authenticated;
select fn_pos_contexto() -> 'organizacion' ->> 'color' as color_raro;
\echo '--- esperado: #7C3AED y luego (null): un color mal escrito no pasa ---'
