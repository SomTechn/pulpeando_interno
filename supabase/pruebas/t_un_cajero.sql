\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- Dos cajas en La Esquina; la Auxiliar 1 (2222, PIN 22222) es la cajera.
insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa) values
 ('aaaa0000-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-000000000001',
  'bbbbbbbb-0000-0000-0000-000000000001','K1','Caja 1', true),
 ('aaaa0000-0000-0000-0000-0000000000a2','aaaaaaaa-0000-0000-0000-000000000001',
  'bbbbbbbb-0000-0000-0000-000000000001','K2','Caja 2', true),
 ('aaaa0000-0000-0000-0000-0000000000a9','aaaaaaaa-0000-0000-0000-000000000002',
  'bbbbbbbb-0000-0000-0000-000000000002','K9','Caja de Chus', true);

update perfiles set codigo = 'A1' where id = '22222222-2222-2222-2222-222222222222';

\echo '### Caja 1 y Caja 2 en La Esquina. Auxiliar 1: codigo A1, PIN 22222'


-- ===================================================================
\echo ''
\echo '=== U1: la cajera abre turno en la Caja 1 ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000a1',
                      '22222222-2222-2222-2222-222222222222','22222', 500) is not null as abrio;
\echo '--- esperado: t ---'


-- ===================================================================
\echo ''
\echo '=== U2: con ese turno abierto NO abre otro en la Caja 2 ==='
\set ON_ERROR_STOP off
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000a2',
                      '22222222-2222-2222-2222-222222222222','22222', 0);
\echo '--- esperado: Auxiliar 1 ya tiene el turno abierto en Caja 1 ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== U2b: y aunque se salte la funcion, el indice tampoco lo deja ==='
set role postgres;
\set ON_ERROR_STOP off
insert into turnos_caja (organizacion_id, sucursal_id, caja_id, cajero_id, monto_inicial)
values ('aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',
        'aaaa0000-0000-0000-0000-0000000000a2','22222222-2222-2222-2222-222222222222', 0);
\echo '--- esperado: duplicate key ... ux_cajero_un_turno ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== U3: el PIN malo cuenta el intento y NO se deshace ==='
set role postgres;
update turnos_caja set estado = 'cerrado', cerrado_en = now()
 where cajero_id = '22222222-2222-2222-2222-222222222222';
update perfiles set pin_intentos_fallidos = 0, pin_bloqueado_hasta = null
 where id = '22222222-2222-2222-2222-222222222222';
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000a2',
                      '22222222-2222-2222-2222-222222222222','00000', 0) as pin_malo;
\echo '--- esperado: vacio (null). Ya no lanza ---'
set role postgres;
select pin_intentos_fallidos from perfiles where id = '22222222-2222-2222-2222-222222222222';
\echo '--- esperado: 1. Antes quedaba en 0: la excepcion deshacia el conteo ---'
select count(*) as turnos_abiertos from turnos_caja
 where cajero_id = '22222222-2222-2222-2222-222222222222' and estado = 'abierto';
\echo '--- esperado: 0 ---'


-- ===================================================================
\echo ''
\echo '=== U4: no se abre turno en la caja de otro negocio ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000a9',
                      '22222222-2222-2222-2222-222222222222','22222', 0);
\echo '--- esperado: esa caja no es de su negocio ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== U5: un auxiliar no abre turno a nombre de otro ==='
\set ON_ERROR_STOP off
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000a2',
                      '11111111-1111-1111-1111-111111111111','11111', 0);
\echo '--- esperado: cada cajero abre su propio turno ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== U6: la tablet de la Caja 2 no le abre sesion si su turno esta en la 1 ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select r ->> 'llave' as llave1, r ->> 'aparato_id' as ap1
  from fn_parear_aparato('bbbbbbbb-0000-0000-0000-000000000001',
                         'aaaa0000-0000-0000-0000-0000000000a1','Tablet 1') r \gset
select r ->> 'llave' as llave2, r ->> 'aparato_id' as ap2
  from fn_parear_aparato('bbbbbbbb-0000-0000-0000-000000000001',
                         'aaaa0000-0000-0000-0000-0000000000a2','Tablet 2') r \gset

set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000a1',
                      '22222222-2222-2222-2222-222222222222','22222', 0) is not null as abrio_en_1;

set role service_role;
select fn_entrar_caja(:'ap2', :'llave2', 'A1', '22222') ->> 'mensaje' as en_la_tablet_2;
\echo '--- esperado: Auxiliar 1 tiene el turno abierto en Caja 1. Cierrelo alla primero ---'
select fn_entrar_caja(:'ap1', :'llave1', 'A1', '22222') ->> 'ok' as en_la_tablet_1;
\echo '--- esperado: true. En su propia caja si entra ---'
