\set ON_ERROR_STOP on
\pset pager off
set role postgres;

insert into auth.users (id, email) values
  ('bbbb0000-0000-0000-0000-000000000001','sup1@t.hn');
insert into perfiles (id, organizacion_id, nombre, email, rol, activo) values
 ('bbbb0000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
  'Supervisor Beto','sup1@t.hn','supervisor',true);
insert into usuario_sucursales (perfil_id, sucursal_id) values
 ('bbbb0000-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');

insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa)
values ('aaaa0000-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000001','C1','Caja 1', true);

-- PIN para el supervisor y para el gerente
select fn_establecer_pin('bbbb0000-0000-0000-0000-000000000001','77341');
select fn_establecer_pin('11111111-1111-1111-1111-111111111111','19283');

\echo '### Caja c1, auxiliar 2222 con PIN 22222, supervisor Beto con PIN 77341'

-- ===================================================================
\echo ''
\echo '=== G1: el gerente reparte los codigos ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_fijar_codigo_perfil('bbbb0000-0000-0000-0000-000000000001','S1') ->> 'codigo' as beto;
select fn_fijar_codigo_perfil('22222222-2222-2222-2222-222222222222','C1') ->> 'codigo' as cajera;
select fn_fijar_codigo_perfil('11111111-1111-1111-1111-111111111111','G1') ->> 'codigo' as gerente;
\echo '--- esperado: S1, C1, G1 ---'

\echo ''
\echo '=== G1b: el codigo se guarda en mayuscula y no se repite ==='
\set ON_ERROR_STOP off
select fn_fijar_codigo_perfil('22222222-2222-2222-2222-222222222222','s1');
\echo '--- esperado: ya hay alguien con el codigo S1 ---'
select fn_fijar_codigo_perfil('22222222-2222-2222-2222-222222222222','ABCDEFGHI');
\echo '--- esperado: 8 caracteres como mucho ---'
select fn_fijar_codigo_perfil('22222222-2222-2222-2222-222222222222','C 1!');
\echo '--- esperado: solo letras y numeros ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== G1c: el auxiliar no reparte codigos ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
select fn_fijar_codigo_perfil('22222222-2222-2222-2222-222222222222','XX');
\echo '--- esperado: solo un gerente ---'
\set ON_ERROR_STOP on

-- ===================================================================
\echo ''
\echo '=== G2: se abre turno con 200 de fondo y se vende 120 en efectivo ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000c1',
       '22222222-2222-2222-2222-222222222222','22222', 200) as tg \gset
select fn_desbloquear_caja(:'tg'::uuid,'22222') as dg \gset
select (fn_registrar_venta(:'dg'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":2}]'::jsonb,
  '[{"metodo":"efectivo","monto":120.00,"recibido":200.00}]'::jsonb))->>'numero' as venta;
set role postgres;
select app.efectivo_esperado(:'tg'::uuid) as en_gaveta;
set role authenticated;
\echo '--- esperado: 320 (200 de fondo + 120 de la venta) ---'

-- ===================================================================
\echo ''
\echo '=== G3: la CAJERA no mueve la gaveta, ni con su propio codigo ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_movimiento_caja(:'tg'::uuid, 'fondo', 100, 'C1', '22222') ->> 'error' as con_fondo;
select fn_arqueo_caja(:'tg'::uuid, 320, 'C1', '22222') ->> 'error' as con_arqueo;
\echo '--- esperado: "Auxiliar 1 no tiene permiso para autorizar esto" las dos veces ---'

\echo ''
\echo '=== G3b: codigo que no existe y PIN equivocado dicen LO MISMO ==='
select fn_movimiento_caja(:'tg'::uuid, 'fondo', 100, 'ZZ', '77341') ->> 'error' as codigo_malo;
select fn_movimiento_caja(:'tg'::uuid, 'fondo', 100, 'S1', '00000') ->> 'error' as pin_malo;
\echo '--- esperado: "Codigo o PIN incorrecto" las dos veces, palabra por palabra ---'
select fn_movimiento_caja(:'tg'::uuid, 'fondo', 100, 'ZZ', '77341') ->> 'ok' as responde_no_lanza;
\echo '--- esperado: false (si lanzara, el contador de intentos se perderia) ---'
-- se limpia el contador que dejaron estos intentos
set role postgres;
update perfiles set pin_intentos_fallidos = 0, pin_bloqueado_hasta = null
 where codigo = 'S1';
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';

-- ===================================================================
\echo ''
\echo '=== G4: el supervisor mete 150 de cambio ==='
select fn_movimiento_caja(:'tg'::uuid, 'fondo', 150, 'S1', '77341', 'se acabo el sencillo') as fondo;
\echo '--- esperado: en_gaveta 470, autorizo Supervisor Beto ---'

\echo ''
\echo '=== G5: no se puede retirar mas de lo que hay ==='
\set ON_ERROR_STOP off
select fn_movimiento_caja(:'tg'::uuid, 'retiro', 1000, 'S1', '77341');
\echo '--- esperado: el sistema solo cuenta con 470 ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== G6: retiro parcial de 300 ==='
select fn_movimiento_caja(:'tg'::uuid, 'retiro', 300, 'S1', '77341', 'a la caja fuerte') as retiro;
\echo '--- esperado: en_gaveta 170 ---'

\echo ''
\echo '=== G6b: un tipo que no existe se rechaza ==='
\set ON_ERROR_STOP off
select fn_movimiento_caja(:'tg'::uuid, 'prestamo', 50, 'S1', '77341');
\echo '--- esperado: tiene que ser fondo o retiro ---'
select fn_movimiento_caja(:'tg'::uuid, 'fondo', -5, 'S1', '77341');
\echo '--- esperado: mayor a cero ---'
\set ON_ERROR_STOP on

-- ===================================================================
\echo ''
\echo '=== G7: arqueo sorpresivo. Hay 170 y se cuentan 165 ==='
select fn_arqueo_caja(:'tg'::uuid, 165, 'S1', '77341', 'arqueo de media tarde') as arqueo;
\echo '--- esperado: esperado 170, contado 165, diferencia -5 ---'

\echo ''
\echo '=== G7b: el arqueo NO toca la gaveta: sigue en 170 ==='
set role postgres;
select app.efectivo_esperado(:'tg'::uuid) as sigue_igual;
set role authenticated;
\echo '--- esperado: 170 ---'

-- ===================================================================
\echo ''
\echo '=== G8: la cajera ve los movimientos pero NO la diferencia ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select tipo, monto, diferencia, autorizo from fn_movimientos_turno(:'tg'::uuid) order by cuando;
\echo '--- esperado: tres filas, diferencia en blanco (si la viera, el arqueo deja de ser sorpresa) ---'

\echo ''
\echo '=== G8b: el supervisor si la ve ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select tipo, monto, diferencia from fn_movimientos_turno(:'tg'::uuid) order by cuando;
\echo '--- esperado: el arqueo con -5 ---'

-- ===================================================================
\echo ''
\echo '=== G9: cerrar el turno. La cajera declara 170 ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select jsonb_pretty(fn_cerrar_turno_con_arqueo(:'tg'::uuid, 170, 'S1', '77341', 'turno normal'));
\echo '--- esperado: inicial 200, ventas 120, fondos 150, retiros 300, esperado 170, diferencia 0 ---'

\echo ''
\echo '=== G9b: un turno cerrado ya no se mueve ==='
\set ON_ERROR_STOP off
select fn_movimiento_caja(:'tg'::uuid, 'fondo', 10, 'S1', '77341');
select fn_arqueo_caja(:'tg'::uuid, 10, 'S1', '77341');
select fn_cerrar_turno_con_arqueo(:'tg'::uuid, 10, 'S1', '77341');
\echo '--- esperado: ya se cerro, las tres veces ---'
\set ON_ERROR_STOP on

-- ===================================================================
\echo ''
\echo '=== G10: el fn_cerrar_turno viejo tambien cuenta fondos y retiros ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000c1',
       '22222222-2222-2222-2222-222222222222','22222', 100) as t2 \gset
select fn_movimiento_caja(:'t2'::uuid, 'fondo', 50, 'S1', '77341') ->> 'en_gaveta' as con_fondo;
select (fn_cerrar_turno(:'t2'::uuid, 150))->>'diferencia' as dif_vieja;
\echo '--- esperado: en_gaveta 150 y diferencia 0 (sin contar el fondo daria 50) ---'

-- ===================================================================
\echo ''
\echo '=== G11: la otra pulperia no toca este turno ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000c1',
       '22222222-2222-2222-2222-222222222222','22222', 0) as t3 \gset
set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
\set ON_ERROR_STOP off
select fn_movimiento_caja(:'t3'::uuid, 'fondo', 10, 'S1', '77341');
\echo '--- esperado: ese turno no es de su negocio ---'
select * from fn_movimientos_turno(:'t3'::uuid);
\echo '--- esperado: lo mismo ---'
\set ON_ERROR_STOP on

-- ===================================================================
\echo ''
\echo '=== G12: cinco PIN malos y el codigo queda frio ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_movimiento_caja(:'t3'::uuid, 'fondo', 10, 'S1', '00001') ->> 'ok' as i1;
select fn_movimiento_caja(:'t3'::uuid, 'fondo', 10, 'S1', '00002') ->> 'ok' as i2;
select fn_movimiento_caja(:'t3'::uuid, 'fondo', 10, 'S1', '00003') ->> 'ok' as i3;
select fn_movimiento_caja(:'t3'::uuid, 'fondo', 10, 'S1', '00004') ->> 'ok' as i4;
select fn_movimiento_caja(:'t3'::uuid, 'fondo', 10, 'S1', '00005') ->> 'ok' as i5;
\echo '--- esperado: false cinco veces ---'
set role postgres;
select codigo, pin_intentos_fallidos,
       (pin_bloqueado_hasta > now()) as esta_frio
  from perfiles where codigo = 'S1';
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\echo '--- esperado: 5 intentos y esta_frio = t. ESTO es lo que nunca funciono ---'
select fn_movimiento_caja(:'t3'::uuid, 'fondo', 10, 'S1', '77341') ->> 'error' as con_el_pin_bueno;
\echo '--- esperado: bloqueado por intentos fallidos, aunque el PIN sea el bueno ---'

\echo ''
\echo '=== G13: nadie suelto alcanza estas funciones ==='
set role anon;
\set ON_ERROR_STOP off
select fn_movimiento_caja(:'t3'::uuid, 'fondo', 10, 'S1', '77341');
select fn_arqueo_caja(:'t3'::uuid, 10, 'S1', '77341');
select * from fn_movimientos_turno(:'t3'::uuid);
\echo '--- esperado: permiso denegado las tres veces ---'
\set ON_ERROR_STOP on
reset role;

\echo ''
\echo '### FIN'
