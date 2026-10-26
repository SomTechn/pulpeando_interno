\set ON_ERROR_STOP on
\pset pager off
\timing off

-- =====================================================================
-- SEMBRADO
-- =====================================================================
set role postgres;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','gerente@t.hn'),
  ('22222222-2222-2222-2222-222222222222','auxiliar@t.hn'),
  ('33333333-3333-3333-3333-333333333333','supervisor@t.hn');

insert into organizaciones (id, nombre, pais, moneda)
values ('aaaaaaaa-0000-0000-0000-000000000001','Pulperia Test','HN','HNL');

insert into sucursales (id, organizacion_id, codigo, nombre, es_principal, activa)
values ('bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','001','Principal',true,true);

insert into perfiles (id, organizacion_id, nombre, email, rol, pin_pos, activo)
values
 ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001','Gerente','gerente@t.hn','gerente', crypt('11111', gen_salt('bf')), true),
 ('22222222-2222-2222-2222-222222222222','aaaaaaaa-0000-0000-0000-000000000001','Auxiliar','auxiliar@t.hn','auxiliar', crypt('22222', gen_salt('bf')), true),
 ('33333333-3333-3333-3333-333333333333','aaaaaaaa-0000-0000-0000-000000000001','Supervisor','supervisor@t.hn','supervisor', crypt('33333', gen_salt('bf')), true);

insert into usuario_sucursales (perfil_id, sucursal_id) values
 ('11111111-1111-1111-1111-111111111111','bbbbbbbb-0000-0000-0000-000000000001'),
 ('22222222-2222-2222-2222-222222222222','bbbbbbbb-0000-0000-0000-000000000001'),
 ('33333333-3333-3333-3333-333333333333','bbbbbbbb-0000-0000-0000-000000000001');

insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa)
values ('cccccccc-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','C1','Caja 1', true);

insert into categorias (id, organizacion_id, nombre)
values ('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Abarrotes');

insert into productos (id, organizacion_id, sku, nombre, categoria_id, tipo, unidad_base, activo, se_vende)
values ('eeeeeeee-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','P001','Arroz 5lb','dddddddd-0000-0000-0000-000000000001','unidad','unidad', true, true);

insert into precios (organizacion_id, producto_id, sucursal_id, nivel, cantidad_minima, precio, vigente_desde)
values ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','detalle',1, 50.00, now() - interval '1 day');

insert into existencias (organizacion_id, producto_id, sucursal_id, cantidad)
values ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001', 100);

insert into producto_costos (organizacion_id, producto_id, sucursal_id, cantidad, valor, costo_promedio, ultimo_costo)
values ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001', 100, 3000, 30.00, 30.00);

insert into clientes (id, organizacion_id, codigo, nombre, telefono, limite_credito, saldo, activo) values
 ('f0000000-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001','C001','Dona Marta','9999-0001', 200.00, 0, true),
 ('f0000000-0000-0000-0000-00000000000b','aaaaaaaa-0000-0000-0000-000000000001','C002','Don Pedro','9999-0002',   0.00, 0, true),
 ('f0000000-0000-0000-0000-00000000000c','aaaaaaaa-0000-0000-0000-000000000001','C003','Cliente Baja','9999-0003',500.00, 0, false);

\echo '### SEMBRADO LISTO'

set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';

select fn_abrir_turno('cccccccc-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','22222', 500) as tid \gset
\echo 'turno:' :tid

\echo ''
\echo '=== P1: venta a credito L100, limite L200 (debe PASAR) ==='
select fn_desbloquear_caja(:'tid'::uuid, '22222') as dq \gset
select fn_registrar_venta(
  :'dq'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":2}]'::jsonb,
  '[{"metodo":"credito","monto":100.00}]'::jsonb,
  'f0000000-0000-0000-0000-00000000000a'
) as v1 \gset
\echo 'resultado:' :v1
select nombre, saldo, limite_credito from clientes where id='f0000000-0000-0000-0000-00000000000a';

\echo ''
\echo '=== P2: venta a credito L150 mas (100+150 > 200) debe FALLAR ==='
select fn_desbloquear_caja(:'tid'::uuid, '22222') as dq2 \gset
\set ON_ERROR_STOP off
select fn_registrar_venta(:'dq2'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":3}]'::jsonb,
  '[{"metodo":"credito","monto":150.00}]'::jsonb,
  'f0000000-0000-0000-0000-00000000000a');
\set ON_ERROR_STOP on
select nombre, saldo from clientes where id='f0000000-0000-0000-0000-00000000000a';
select 'kardex tras el fallo (debe seguir en 100):' as nota, cantidad from existencias where producto_id='eeeeeeee-0000-0000-0000-000000000001';

\echo ''
\echo '=== P3: cliente con limite 0 (debe FALLAR) ==='
select fn_desbloquear_caja(:'tid'::uuid, '22222') as dq3 \gset
\set ON_ERROR_STOP off
select fn_registrar_venta(:'dq3'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  '[{"metodo":"credito","monto":50.00}]'::jsonb,
  'f0000000-0000-0000-0000-00000000000b');
\set ON_ERROR_STOP on

\echo ''
\echo '=== P4: credito sin cliente (debe FALLAR) ==='
select fn_desbloquear_caja(:'tid'::uuid, '22222') as dq4 \gset
\set ON_ERROR_STOP off
select fn_registrar_venta(:'dq4'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  '[{"metodo":"credito","monto":50.00}]'::jsonb);
\set ON_ERROR_STOP on

\echo ''
\echo '=== P5: cliente inactivo (debe FALLAR) ==='
select fn_desbloquear_caja(:'tid'::uuid, '22222') as dq5 \gset
\set ON_ERROR_STOP off
select fn_registrar_venta(:'dq5'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":1}]'::jsonb,
  '[{"metodo":"credito","monto":50.00}]'::jsonb,
  'f0000000-0000-0000-0000-00000000000c');
\set ON_ERROR_STOP on

\echo ''
\echo '=== P6: mixta L50 efectivo + L100 credito = tope exacto (debe PASAR) ==='
select fn_desbloquear_caja(:'tid'::uuid, '22222') as dq6 \gset
select fn_registrar_venta(:'dq6'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":3}]'::jsonb,
  '[{"metodo":"efectivo","monto":50.00,"recibido":50.00},{"metodo":"credito","monto":100.00}]'::jsonb,
  'f0000000-0000-0000-0000-00000000000a') as v6 \gset
\echo 'resultado:' :v6
select nombre, saldo, limite_credito from clientes where id='f0000000-0000-0000-0000-00000000000a';

\echo ''
\echo '=== P7: abono L80 efectivo con turno abierto ==='
select fn_registrar_abono('f0000000-0000-0000-0000-00000000000a', 80.00, 'efectivo', :'tid'::uuid) as ab1 \gset
\echo 'resultado:' :ab1
select nombre, saldo from clientes where id='f0000000-0000-0000-0000-00000000000a';

\echo ''
\echo '=== P8: abonos invalidos ==='
\set ON_ERROR_STOP off
\echo '-- mayor a la deuda:'
select fn_registrar_abono('f0000000-0000-0000-0000-00000000000a', 5000.00, 'efectivo', :'tid'::uuid);
\echo '-- monto cero:'
select fn_registrar_abono('f0000000-0000-0000-0000-00000000000a', 0, 'efectivo', :'tid'::uuid);
\echo '-- efectivo sin turno:'
select fn_registrar_abono('f0000000-0000-0000-0000-00000000000a', 10.00, 'efectivo', null);
\set ON_ERROR_STOP on

\echo ''
\echo '=== P9: abono L20 por transferencia sin turno (debe PASAR) ==='
select fn_registrar_abono('f0000000-0000-0000-0000-00000000000a', 20.00, 'transferencia', null, 'REF-998') as ab2 \gset
\echo 'resultado:' :ab2
select nombre, saldo from clientes where id='f0000000-0000-0000-0000-00000000000a';

\echo ''
\echo '=== P10: arqueo. inicial 500 + efectivo 50 + abono efectivo 80 = 630 ==='
select fn_cerrar_turno(:'tid'::uuid, 630.00) as cierre \gset
\echo 'resultado:' :cierre

\echo ''
\echo '=== P11: v_fiado ==='
select cliente, debe, limite, disponible, tope_alcanzado, dias, compras_credito from v_fiado order by debe desc;

\echo ''
\echo '=== P12: fn_fiado_resumen ==='
select jsonb_pretty(fn_fiado_resumen());

\echo ''
\echo '=== P13: fn_estado_cuenta ==='
select * from fn_estado_cuenta('f0000000-0000-0000-0000-00000000000a');

\echo ''
\echo '=== P14: auxiliar anula abono (debe FALLAR) ==='
select (:'ab2'::jsonb->>'abono_id') as abid \gset
\set ON_ERROR_STOP off
select fn_anular_abono(:'abid'::uuid, 'prueba');
\set ON_ERROR_STOP on

\echo ''
\echo '=== P15: supervisor anula el abono (debe PASAR) ==='
set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select fn_anular_abono(:'abid'::uuid, 'cheque rebotado') as an \gset
\echo 'resultado:' :an
select nombre, saldo from clientes where id='f0000000-0000-0000-0000-00000000000a';

\echo ''
\echo '=== P16: anular dos veces (debe FALLAR) ==='
\set ON_ERROR_STOP off
select fn_anular_abono(:'abid'::uuid, 'otra vez');
\set ON_ERROR_STOP on

\echo ''
\echo '=== P17: anon no puede nada ==='
reset role;
set role anon;
reset request.jwt.claim.sub;
\set ON_ERROR_STOP off
select fn_registrar_abono('f0000000-0000-0000-0000-00000000000a', 1, 'efectivo', null);
select count(*) as abonos_visibles_anon from abonos_cliente;
select count(*) as fiado_visible_anon from v_fiado;
\set ON_ERROR_STOP on

reset role;
\echo ''
\echo '### FIN'
