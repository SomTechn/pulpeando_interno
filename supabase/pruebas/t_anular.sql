\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- Sobre la semilla de t_pedidos: org 1 = La Esquina, org 2 = Dona Chus.
insert into auth.users (id, email) values
  ('bbbb0000-0000-0000-0000-000000000001','sup1@t.hn'),
  ('bbbb0000-0000-0000-0000-000000000002','sup2@t.hn');

insert into perfiles (id, organizacion_id, nombre, email, rol, pin_pos, activo) values
 ('bbbb0000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
  'Supervisor Propio','sup1@t.hn','supervisor', crypt('77777', gen_salt('bf')), true),
 ('bbbb0000-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000002',
  'Supervisor Rival','sup2@t.hn','supervisor', crypt('88888', gen_salt('bf')), true);
insert into usuario_sucursales (perfil_id, sucursal_id) values
 ('bbbb0000-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001'),
 ('bbbb0000-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000002');

insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa)
values ('aaaa0000-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000001','C1','Caja 1', true);

insert into clientes (id, organizacion_id, codigo, nombre, limite_credito, saldo, activo)
values ('aaaa0000-0000-0000-0000-0000000000f1','aaaaaaaa-0000-0000-0000-000000000001',
        'CF','Dona Fia', 500, 0, true);

\echo '=== Venta MIXTA: L60 efectivo + L120 fiado (3 arroces a L60) ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000c1','22222222-2222-2222-2222-222222222222','22222', 0) as t \gset
select fn_desbloquear_caja(:'t'::uuid,'22222') as d \gset
select (fn_registrar_venta(:'d'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":3}]'::jsonb,
  '[{"metodo":"efectivo","monto":60.00,"recibido":60.00},
    {"metodo":"credito","monto":120.00}]'::jsonb,
  'aaaa0000-0000-0000-0000-0000000000f1')) as venta \gset
select (:'venta'::jsonb->>'venta_id') as vid \gset

reset role;
select v.numero, v.total, c.saldo as debe_despues_de_la_venta
from ventas v join clientes c on c.id = v.cliente_id where v.id = :'vid'::uuid;
select 'existencia tras la venta' as que, cantidad from existencias
 where producto_id='eeeeeeee-0000-0000-0000-000000000001'
   and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001';

\echo ''
\echo '=== A1: el supervisor del OTRO negocio intenta anularla ==='
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000002';
\set ON_ERROR_STOP off
select fn_anular_venta(:'vid'::uuid, 'curioseando');
\set ON_ERROR_STOP on
reset role;
select numero, estado from ventas where id = :'vid'::uuid;

\echo ''
\echo '=== A2: una AUXILIAR del propio negocio tampoco puede ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
select fn_anular_venta(:'vid'::uuid, 'me equivoque');
\set ON_ERROR_STOP on

\echo ''
\echo '=== A3: el supervisor PROPIO si la anula ==='
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_anular_venta(:'vid'::uuid, 'cobro equivocado') as resultado;
reset role;
select numero, estado, motivo_anulacion from ventas where id = :'vid'::uuid;

\echo ''
\echo '--- El saldo de la clienta. Fio L120, asi que debe quedar en 0 ---'
select nombre, saldo as debe_ahora from clientes where id='aaaa0000-0000-0000-0000-0000000000f1';
select 'existencia tras anular (debe volver a 50)' as que, cantidad from existencias
 where producto_id='eeeeeeee-0000-0000-0000-000000000001'
   and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001';

\echo ''
\echo '=== A4: anular dos veces ==='
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
\set ON_ERROR_STOP off
select fn_anular_venta(:'vid'::uuid, 'otra vez');
\set ON_ERROR_STOP on
reset role;
\echo '### FIN ANULAR'

\echo ''
\echo '=== A5: EL MONTO. La clienta ya debia L300 de antes ==='
set role postgres;
update clientes set saldo = 300 where id='aaaa0000-0000-0000-0000-0000000000f1';
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_desbloquear_caja(:'t'::uuid,'22222') as d2 \gset
select (fn_registrar_venta(:'d2'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":3}]'::jsonb,
  '[{"metodo":"efectivo","monto":60.00,"recibido":60.00},
    {"metodo":"credito","monto":120.00}]'::jsonb,
  'aaaa0000-0000-0000-0000-0000000000f1')) as v2 \gset
select (:'v2'::jsonb->>'venta_id') as vid2 \gset
reset role;
select 'debe tras la venta (300 + 120 fiado = 420)' as paso, saldo
from clientes where id='aaaa0000-0000-0000-0000-0000000000f1';

set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_anular_venta(:'vid2'::uuid, 'se equivoco de cliente');
reset role;
select 'debe tras anular (debe volver a 300, no a 240)' as paso, saldo
from clientes where id='aaaa0000-0000-0000-0000-0000000000f1';

\echo ''
\echo '=== A6: anular sin motivo ==='
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_desbloquear_caja(:'t'::uuid,'22222') as d3 \gset
\set ON_ERROR_STOP off
select fn_anular_venta(:'vid2'::uuid, '   ');
\set ON_ERROR_STOP on

\echo ''
\echo '=== A7: el HISTORIAL ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\echo '-- lo que ve la AUXILIAR (sin costo ni ganancia):'
select numero, cliente, total, costo, ganancia, estado, metodos, lineas
from fn_historial_ventas() order by numero;

\echo ''
\echo '-- lo que ve el SUPERVISOR (con costo y ganancia):'
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select numero, cliente, total, costo, ganancia, estado, motivo
from fn_historial_ventas() order by numero;

\echo ''
\echo '-- solo las anuladas:'
select numero, estado, anulada_por, motivo from fn_historial_ventas(null,null,null,null,'anulada');
\echo '-- buscando por nombre de cliente:'
select numero, cliente from fn_historial_ventas(null,null,null,'Fia');
\echo '-- buscando un numero que no existe:'
select count(*) as nada from fn_historial_ventas(null,null,null,'ZZZZ');
\echo '-- de manana en adelante (no deberia haber nada):'
select count(*) as futuro from fn_historial_ventas((current_date+1), null);

\echo ''
\echo '=== A8: el RESUMEN del periodo ==='
select jsonb_pretty(fn_ventas_resumen());
\echo '-- como auxiliar, la ganancia va nula:'
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_ventas_resumen()->'ganancia' as ganancia_para_auxiliar;

\echo ''
\echo '=== A9: el TICKET completo ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select jsonb_pretty(fn_venta_completa(:'vid2'::uuid));

\echo ''
\echo '=== A10: el negocio RIVAL no ve nada de esto ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000002';
select count(*) as ventas_que_ve from fn_historial_ventas();
select fn_ventas_resumen()->'ventas' as ventas_en_su_resumen;
\set ON_ERROR_STOP off
select fn_venta_completa(:'vid2'::uuid);
\set ON_ERROR_STOP on

\echo ''
\echo '=== A11: anon no alcanza nada ==='
reset role;
set role anon;
reset request.jwt.claim.sub;
\set ON_ERROR_STOP off
select count(*) from fn_historial_ventas();
select fn_ventas_resumen();
select fn_venta_completa(:'vid2'::uuid);
select fn_anular_venta(:'vid2'::uuid, 'x');
\set ON_ERROR_STOP on
reset role;
\echo '### FIN HISTORIAL'
