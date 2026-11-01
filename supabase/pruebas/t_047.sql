\pset pager off
set role postgres;

-- Semilla de t_pedidos: Arroz 5lb a L 60 en La Esquina. Gerente 1 = G1 (PIN 11111),
-- Auxiliar 1 = A1 (PIN 22222). Supervisor S1 (PIN 77777) se agrega aquí.
update perfiles set codigo = 'G1' where id = '11111111-1111-1111-1111-111111111111';
update perfiles set codigo = 'A1' where id = '22222222-2222-2222-2222-222222222222';
update perfiles set codigo = 'G2' where id = '99999999-9999-9999-9999-999999999999';
insert into auth.users (id, email) values ('bbbb0000-0000-0000-0000-000000000001','sup1@t.hn');
insert into perfiles (id, organizacion_id, nombre, email, rol, pin_pos, activo, codigo) values
 ('bbbb0000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
  'Supervisor Propio','sup1@t.hn','supervisor', crypt('77777', gen_salt('bf')), true, 'S1');
insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa) values
 ('aaaa0000-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','C1','Caja 1', true);
update organizaciones set permite_stock_negativo = true where id = 'aaaaaaaa-0000-0000-0000-000000000001';
select id as arroz from productos where nombre = 'Arroz 5lb' \gset
insert into clientes (organizacion_id, nombre, telefono, limite_credito) values ('aaaaaaaa-0000-0000-0000-000000000001', 'Doña Fía', '9000-0001', 1000);
select id as fia from clientes where nombre = 'Doña Fía' \gset

-- La auxiliar abre turno y vende: v1 efectivo (2 arroz), v2 fiado (1 arroz)
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000c1','22222222-2222-2222-2222-222222222222','22222', 0) as t \gset
select fn_desbloquear_caja(:'t'::uuid,'22222') as d \gset
select (fn_registrar_venta(:'d'::uuid, jsonb_build_array(jsonb_build_object('producto_id', :'arroz', 'cantidad', 2)),
  '[{"metodo":"efectivo","monto":120,"recibido":200}]'::jsonb) ->> 'venta_id') as v1 \gset
select fn_desbloquear_caja(:'t'::uuid,'22222') as d \gset
select (fn_registrar_venta(:'d'::uuid, jsonb_build_array(jsonb_build_object('producto_id', :'arroz', 'cantidad', 1)),
  '[{"metodo":"credito","monto":60}]'::jsonb, :'fia'::uuid) ->> 'venta_id') as v2 \gset
reset role;
select cantidad as exist_antes from existencias where producto_id = :'arroz' \gset
select saldo as saldo_antes from clientes where id = :'fia' \gset

\echo '=== B1: las ventas del turno ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select jsonb_array_length(fn_ventas_turno_caja(:'t'::uuid)) as ventas,
       fn_ventas_turno_caja(:'t'::uuid) -> 0 ->> 'metodos' as metodos_ultima,
       (fn_ventas_turno_caja(:'t'::uuid) -> 0 ->> 'codigo_barras') ~ '^[0-9]{16}$' as con_codigo;
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select fn_ventas_turno_caja(:'t'::uuid);
reset role;
\echo '--- esperado: 2 | credito | t ; error «Turno inexistente» para el gerente de otro negocio ---'

\echo ''
\echo '=== B2: sin autorización, o con una que no sirve, no se anula ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_anular_venta(:'v1'::uuid, 'error');
select fn_anular_venta_caja(:'v1'::uuid, 'error', gen_random_uuid());
select fn_autorizar_caja('A1', '22222', 'anular') ->> 'ok' as auxiliar_no_autoriza;
select fn_autorizar_caja('S1', '00000', 'anular') ->> 'ok' as pin_malo;
select fn_autorizar_caja('S1', '77777', 'cancelar') ->> 'autorizacion_id' as aut_cancelar \gset
select fn_anular_venta_caja(:'v1'::uuid, 'error', :'aut_cancelar'::uuid);
select fn_autorizar_caja('S1', '77777', 'regalar');
reset role;
select estado from ventas where id = :'v1';
\echo '--- esperado: 3 errores (no supervisor, autorización falsa, autorización de cancelar), false, false, error acción, completada ---'

\echo ''
\echo '=== B3: el supervisor autoriza y se anula la venta en efectivo ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_autorizar_caja('S1', '77777', 'anular') ->> 'autorizacion_id' as aut \gset
select fn_anular_venta_caja(:'v1'::uuid, '', :'aut'::uuid);
select r ->> 'ok' as ok, r ->> 'total' as total, r ->> 'efectivo' as efectivo, r ->> 'autorizo' as autorizo
  from (select fn_anular_venta_caja(:'v1'::uuid, 'Cobró de más', :'aut'::uuid) r) x;
select fn_anular_venta_caja(:'v1'::uuid, 'otra vez', :'aut'::uuid);
reset role;
select v.estado, p.nombre as anulada_por, v.motivo_anulacion,
       (select cantidad from existencias where producto_id = :'arroz') - :'exist_antes' as volvio,
       (select venta_id = v.id and usada_en is not null from autorizaciones_caja where id = :'aut') as amarrada
  from ventas v join perfiles p on p.id = v.anulada_por where v.id = :'v1';
\echo '--- esperado: error motivo (sin gastar la autorización) ; true | 120 | 120 | Supervisor Propio ; error ya anulada ; anulada | Supervisor Propio | Cobró de más | 2 | t ---'

\echo ''
\echo '=== B4: la autorización vale una vez y solo para quien la pidió ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_anular_venta_caja(:'v2'::uuid, 'otra', :'aut'::uuid);
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
reset role;
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_autorizar_caja('S1', '77777', 'anular') ->> 'autorizacion_id' as aut2 \gset
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_anular_venta_caja(:'v2'::uuid, 'de otro', :'aut2'::uuid);
reset role;
\echo '--- esperado: 2 errores (ya usada; pedida por otra persona) ---'

\echo ''
\echo '=== B5: la fiada anulada le baja el saldo a la clienta ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select r ->> 'credito' as credito from (select fn_anular_venta_caja(:'v2'::uuid, 'Se equivocó de cliente', :'aut2'::uuid) r) x;
reset role;
select :'saldo_antes'::numeric - saldo as bajo from clientes where id = :'fia';
\echo '--- esperado: 60 ; 60 ---'

\echo ''
\echo '=== B6: autorización vieja no sirve ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_desbloquear_caja(:'t'::uuid,'22222') as d \gset
select (fn_registrar_venta(:'d'::uuid, jsonb_build_array(jsonb_build_object('producto_id', :'arroz', 'cantidad', 1)),
  '[{"metodo":"efectivo","monto":60,"recibido":60}]'::jsonb) ->> 'venta_id') as v3 \gset
select fn_autorizar_caja('S1', '77777', 'anular') ->> 'autorizacion_id' as aut3 \gset
reset role;
update autorizaciones_caja set creada_en = now() - interval '20 minutes' where id = :'aut3';
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_anular_venta_caja(:'v3'::uuid, 'tarde', :'aut3'::uuid);
reset role;
\echo '--- esperado: error (más de 15 minutos) ---'

\echo ''
\echo '=== B7: turno cerrado: va por Ventas ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_autorizar_caja('S1', '77777', 'anular') ->> 'autorizacion_id' as aut4 \gset
reset role;
update turnos_caja set estado = 'cerrado', cerrado_en = now() where id = :'t';
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_anular_venta_caja(:'v3'::uuid, 'cerrado', :'aut4'::uuid);
reset role;
select usada_en is null as no_se_gasto from autorizaciones_caja where id = :'aut4';
-- y desde Ventas el supervisor con su sesión sí puede (fn_anular_venta sigue igual)
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_anular_venta(:'v3'::uuid, 'Desde Ventas');
reset role;
select v.estado, p.nombre from ventas v join perfiles p on p.id = v.anulada_por where v.id = :'v3';
\echo '--- esperado: error turno cerrado ; t ; anulada | Supervisor Propio ---'

\echo ''
\echo '=== B8: la balanza y el código de tienda en el contexto ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_pos_contexto() -> 'organizacion' -> 'balanza' as balanza_defecto,
       (fn_pos_contexto() -> 'organizacion' ->> 'codigo_tienda') ~ '^[0-9]{3}$' as tienda;
reset role;
update organizaciones set config = config || '{"balanza":{"activa":true,"tipo":"precio","largo_plu":9,"decimales":2,"prefijos":"23"}}' where id = 'aaaaaaaa-0000-0000-0000-000000000001';
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_pos_contexto() -> 'organizacion' -> 'balanza' as balanza;
reset role;
\echo '--- esperado: {activa:false, prefijos:20-29, largo_plu:5, tipo:peso, decimales:3} | t ; {activa:true, prefijos:23, largo_plu:6 (tope), tipo:precio, decimales:2} ---'

\echo ''
\echo '=== B9: permisos ==='
select has_function_privilege('anon', 'fn_anular_venta_caja(uuid,text,uuid)', 'execute') as anon_anular,
       has_function_privilege('anon', 'fn_ventas_turno_caja(uuid)', 'execute') as anon_lista,
       has_function_privilege('authenticated', 'app.anular_venta(uuid,text,uuid)', 'execute') as auth_corazon;
\echo '--- esperado: f | f | f ---'
