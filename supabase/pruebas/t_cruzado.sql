\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- Segunda organizacion: la pulperia rival
insert into auth.users (id, email) values ('99999999-9999-9999-9999-999999999999','rival@t.hn');

insert into organizaciones (id, nombre, pais, moneda)
values ('aaaaaaaa-0000-0000-0000-000000000002','Pulperia Rival','HN','HNL');

insert into sucursales (id, organizacion_id, codigo, nombre, es_principal, activa)
values ('bbbbbbbb-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000002','001','Rival',true,true);

insert into perfiles (id, organizacion_id, nombre, email, rol, pin_pos, activo)
values ('99999999-9999-9999-9999-999999999999','aaaaaaaa-0000-0000-0000-000000000002','Rival','rival@t.hn','gerente', crypt('99999', gen_salt('bf')), true);

insert into usuario_sucursales (perfil_id, sucursal_id)
values ('99999999-9999-9999-9999-999999999999','bbbbbbbb-0000-0000-0000-000000000002');

insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa)
values ('cccccccc-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000002','C1','Caja Rival', true);

\echo ''
\echo '=== El rival abre su turno ==='
set role authenticated;
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select fn_abrir_turno('cccccccc-0000-0000-0000-000000000002','99999999-9999-9999-9999-999999999999','99999', 0) as rtid \gset
\echo 'turno rival:' :rtid

\echo ''
\echo '=== El AUXILIAR de la org 1 registra un abono de SU cliente contra el turno del RIVAL ==='
\echo '    (si pasa, el efectivo del abono entra al arqueo del rival)'
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
select fn_registrar_abono('f0000000-0000-0000-0000-00000000000a', 10.00, 'efectivo', :'rtid'::uuid);
\set ON_ERROR_STOP on

\echo ''
\echo '=== Que ve el arqueo del rival ==='
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select fn_cerrar_turno(:'rtid'::uuid, 0) as cierre_rival \gset
\echo :cierre_rival

\echo ''
\echo '=== Y los abonos quedaron apuntados a que sucursal ==='
reset role;
select a.monto, a.organizacion_id, a.sucursal_id, s.nombre as sucursal_nombre
from abonos_cliente a left join sucursales s on s.id = a.sucursal_id;

\echo ''
\echo '=== Un abono con auth.uid() nulo (rol authenticated sin sub) ==='
set role authenticated;
reset request.jwt.claim.sub;
\set ON_ERROR_STOP off
select fn_registrar_abono('f0000000-0000-0000-0000-00000000000a', 5.00, 'transferencia', null, 'SIN-SUB');
\set ON_ERROR_STOP on
reset role;
select nombre, saldo from clientes where id='f0000000-0000-0000-0000-00000000000a';
\echo '### FIN CRUZADO'

\echo ''
\echo '=== El rival vende FIADO a un cliente de la org 1 (debe FALLAR) ==='
set role authenticated;
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select fn_abrir_turno('cccccccc-0000-0000-0000-000000000002','99999999-9999-9999-9999-999999999999','99999', 0) as rt2 \gset
select fn_desbloquear_caja(:'rt2'::uuid, '99999') as rdq \gset
\set ON_ERROR_STOP off
select fn_registrar_venta(:'rdq'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  '[{"metodo":"credito","monto":50.00}]'::jsonb,
  'f0000000-0000-0000-0000-00000000000a');
\set ON_ERROR_STOP on
reset role;
select nombre, saldo from clientes where id='f0000000-0000-0000-0000-00000000000a';
