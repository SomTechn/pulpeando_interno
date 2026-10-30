\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- Mismo armado que t_gaveta: una caja, un turno abierto y un supervisor con
-- codigo y PIN que es quien autoriza.
insert into auth.users (id, email) values
  ('bbbb0000-0000-0000-0000-000000000001','sup1@t.hn');
insert into perfiles (id, organizacion_id, nombre, email, rol, activo) values
 ('bbbb0000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
  'Supervisor Beto','sup1@t.hn','supervisor',true);
insert into usuario_sucursales (perfil_id, sucursal_id) values
 ('bbbb0000-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');

insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa)
values ('aaaa0000-0000-0000-0000-0000000000d1','aaaaaaaa-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000001','D1','Caja 1', true);

select fn_establecer_pin('bbbb0000-0000-0000-0000-000000000001','77341');
select fn_establecer_pin('11111111-1111-1111-1111-111111111111','19283');

set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_fijar_codigo_perfil('bbbb0000-0000-0000-0000-000000000001','S1') ->> 'codigo' as beto;

set role postgres;
insert into turnos_caja (id, organizacion_id, sucursal_id, caja_id, cajero_id,
                         estado, monto_inicial, abierto_en)
values ('aaaa0000-0000-0000-0000-00000000d1a1','aaaaaaaa-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000001','aaaa0000-0000-0000-0000-0000000000d1',
        '22222222-2222-2222-2222-222222222222','abierto', 500, now());

\echo '### Turno abierto con 500 de fondo. Supervisor S1 / PIN 77341'


-- ===================================================================
\echo ''
\echo '=== D1: las denominaciones de Honduras salen sin configurar nada ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select app.denominaciones() as por_defecto;
\echo '--- esperado: 500,200,100,50,20,10,5,2,1,0.5,0.2,0.1,0.05 de mayor a menor ---'

\echo ''
\echo '=== D1b: y la pantalla las pide por la envoltura publica ==='
select fn_denominaciones() as para_el_navegador;
\echo '--- esperado: la misma lista y por_defecto true ---'


-- ===================================================================
\echo ''
\echo '=== D2: el gerente cambia la lista y vuelve atras ==='
select fn_fijar_denominaciones('[1000,500,100]'::jsonb) -> 'denominaciones' as puestas;
\echo '--- esperado: [1000, 500, 100] ---'
select fn_fijar_denominaciones(null) ->> 'por_defecto' as volvio;
\echo '--- esperado: true ---'
select app.denominaciones() as otra_vez;
\echo '--- esperado: la lista de Honduras de nuevo ---'

\echo ''
\echo '=== D2b: lo que no es lista de numeros positivos se rechaza ==='
\set ON_ERROR_STOP off
select fn_fijar_denominaciones('{"500":1}'::jsonb);
\echo '--- esperado: van en una lista ---'
select fn_fijar_denominaciones('[100,"cien"]'::jsonb);
\echo '--- esperado: cada denominacion es un numero mayor a cero ---'
select fn_fijar_denominaciones('[100,0]'::jsonb);
\echo '--- esperado: lo mismo ---'
select fn_fijar_denominaciones('[]'::jsonb);
\echo '--- esperado: entre 1 y 24 ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== D2c: el auxiliar no cambia las denominaciones ==='
\set ON_ERROR_STOP off
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_fijar_denominaciones('[100]'::jsonb);
\echo '--- esperado: solo un gerente ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== D3: la suma del desglose ==='
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select app.detalle_suma('{"500":3,"100":2,"0.5":4}'::jsonb) as suma;
\echo '--- esperado: 1702.00 (1500 + 200 + 2) ---'
select app.detalle_suma(null) as nada;
\echo '--- esperado: 0 ---'


-- ===================================================================
\echo ''
\echo '=== D4: un fondo con su desglose ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_movimiento_caja('aaaa0000-0000-0000-0000-00000000d1a1','fondo', 700,
         'S1','77341','Del fondo de la tienda',
         '{"500":1,"100":2}'::jsonb) -> 'monto' as fondo;
\echo '--- esperado: 700.00 ---'

set role postgres;
select tipo, monto, detalle from movimientos_caja
 where turno_id = 'aaaa0000-0000-0000-0000-00000000d1a1';
\echo '--- esperado: fondo 700 con el desglose {"100": 2, "500": 1} guardado ---'
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';


-- ===================================================================
\echo ''
\echo '=== D5: si el desglose no suma el monto, NO se guarda nada ==='
\echo '--- (un desglose que no cuadra manda a buscar al lugar equivocado) ---'
\set ON_ERROR_STOP off
select fn_movimiento_caja('aaaa0000-0000-0000-0000-00000000d1a1','fondo', 700,
         'S1','77341', null, '{"500":1}'::jsonb);
\echo '--- esperado: el desglose suma 500.00 y el monto dice 700.00 ---'
\set ON_ERROR_STOP on

set role postgres;
select count(*) as movimientos from movimientos_caja
 where turno_id = 'aaaa0000-0000-0000-0000-00000000d1a1';
\echo '--- esperado: 1. El de D4 y nada mas: el rechazado no entro ---'
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';


-- ===================================================================
\echo ''
\echo '=== D6: denominaciones y cantidades que no valen ==='
\set ON_ERROR_STOP off
select fn_movimiento_caja('aaaa0000-0000-0000-0000-00000000d1a1','fondo', 3,
         'S1','77341', null, '{"3":1}'::jsonb);
\echo '--- esperado: la denominacion 3 no es de las que usa este negocio ---'
select fn_movimiento_caja('aaaa0000-0000-0000-0000-00000000d1a1','fondo', 100,
         'S1','77341', null, '{"100":1.5}'::jsonb);
\echo '--- esperado: la cantidad de 100 tiene que ser entera ---'
select fn_movimiento_caja('aaaa0000-0000-0000-0000-00000000d1a1','fondo', 100,
         'S1','77341', null, '{"100":"uno"}'::jsonb);
\echo '--- esperado: la cantidad de 100 tiene que ser un numero ---'
select fn_movimiento_caja('aaaa0000-0000-0000-0000-00000000d1a1','fondo', 100,
         'S1','77341', null, '[100]'::jsonb);
\echo '--- esperado: el desglose no tiene la forma esperada ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== D7: el desglose malo NO le gasta intentos de PIN a nadie ==='
\echo '--- (es un error de la pantalla, no una credencial equivocada) ---'
set role postgres;
select pin_intentos_fallidos as antes from perfiles
 where id = 'bbbb0000-0000-0000-0000-000000000001';
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
select fn_movimiento_caja('aaaa0000-0000-0000-0000-00000000d1a1','fondo', 700,
         'S1','77341', null, '{"500":1}'::jsonb);
\set ON_ERROR_STOP on
set role postgres;
select pin_intentos_fallidos as despues from perfiles
 where id = 'bbbb0000-0000-0000-0000-000000000001';
\echo '--- esperado: 0 las dos veces ---'
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';


-- ===================================================================
\echo ''
\echo '=== D8: sin desglose se sigue pudiendo, como antes ==='
select fn_movimiento_caja('aaaa0000-0000-0000-0000-00000000d1a1','retiro', 200,
         'S1','77341','Al banco') -> 'monto' as sin_desglose;
\echo '--- esperado: 200.00. El desglose es opcional ---'


-- ===================================================================
\echo ''
\echo '=== D9: arqueo con desglose ==='
\echo '--- en la gaveta hay 500 + 700 - 200 = 1000; se cuentan 980 ---'
\set ON_ERROR_STOP off
-- El id sale de la respuesta: la cajera NO puede leer movimientos_caja de
-- frente, solo por fn_movimientos_turno, y asi debe ser.
select fn_arqueo_caja('aaaa0000-0000-0000-0000-00000000d1a1', 980,
         'S1','77341','Arqueo de media tarde',
         '{"500":1,"100":4,"50":1,"20":1,"10":1}'::jsonb) ->> 'arqueo_id' as arq \gset

select jsonb_pretty(fn_detalle_movimiento(:'arq')) as detalle_visto;
\echo '--- esperado: contado 980, el desglose, y diferencia en blanco por ser auxiliar ---'

select count(*) as lo_lee_de_frente from movimientos_caja;
\echo '--- esperado: permiso denegado. A la tabla no se entra directo ---'

set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_detalle_movimiento(:'arq') -> 'diferencia' as la_ve_el_gerente;
\echo '--- esperado: -20.00 ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== D10: el cierre guarda su desglose en el turno ==='
select fn_cerrar_turno_con_arqueo('aaaa0000-0000-0000-0000-00000000d1a1', 1000,
         'S1','77341','Cierre del dia',
         '{"500":1,"100":5}'::jsonb) -> 'diferencia' as cierre;
\echo '--- esperado: 0.00 ---'

set role postgres;
select estado, monto_declarado, detalle_cierre from turnos_caja
 where id = 'aaaa0000-0000-0000-0000-00000000d1a1';
\echo '--- esperado: cerrado, 1000.00 y el desglose guardado ---'


-- ===================================================================
\echo ''
\echo '=== D11: la otra pulperia no ve este desglose ==='
set role authenticated;
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
\set ON_ERROR_STOP off
select fn_detalle_movimiento(:'arq');
\echo '--- esperado: ese movimiento no es de su negocio ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== D12: nadie suelto alcanza estas funciones ==='
\set ON_ERROR_STOP off
set role anon;
select app.denominaciones();
\echo '--- esperado: permiso denegado ---'
select fn_fijar_denominaciones('[100]'::jsonb);
\echo '--- esperado: permiso denegado ---'
select fn_detalle_movimiento('aaaa0000-0000-0000-0000-00000000dead');
\echo '--- esperado: permiso denegado ---'
\set ON_ERROR_STOP on
