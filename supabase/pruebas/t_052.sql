\pset pager off
set role postgres;
insert into clientes (id, organizacion_id, codigo, nombre, telefono, limite_credito, saldo, activo) values
 ('c5200000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','K1','Juan Pérez','9999-0001', 500, 0, true),
 ('c5200000-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000001','K3','Otro Juan','9999-0003', 0, 0, true),
 ('c5200000-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000002','K2','Juancho','9999-0002', 500, 300, true);
insert into auth.users (id, email) values ('ad520000-0000-0000-0000-000000000001','admin@t.hn');
insert into perfiles (id, organizacion_id, nombre, email, rol, activo) values
 ('ad520000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Admin','admin@t.hn','admin', true);

\echo '=== R1: verificar con DNI y permiso ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_riesgo_verificar('c5200000-0000-0000-0000-000000000001', '0801-1990-12345', false);
select fn_riesgo_verificar('c5200000-0000-0000-0000-000000000001', '0801-19-12345', true);
select fn_riesgo_verificar('c5200000-0000-0000-0000-000000000001', '9901-1990-12345', true);
select r->>'verificado' v, r->>'dni_final' fin, r->>'senal' senal, r->>'texto' texto
  from (select fn_riesgo_verificar('c5200000-0000-0000-0000-000000000001', '0801 1990 12345', true) r) x;
select fn_riesgo_verificar('c5200000-0000-0000-0000-000000000003', '0801199012345', true);
select fn_riesgo_verificar('c5200000-0000-0000-0000-000000000002', '0801199012345', true);
reset role;
\echo '--- esperado: error permiso ; error 13 ; error no valido ; true | 2345 | verde | Sin historial ; error ya esta con Juan Pérez ; error otro negocio ---'

\echo ''
\echo '=== R2: el DNI no queda guardado en ningún lado ==='
select count(*) as con_dni from clientes where coalesce(dni_final,'') = '0801199012345'
   or coalesce(identificacion_fiscal,'') like '%0801199012345%';
select count(*) as personas, min(length(huella)) as largo from riesgo_personas;
\echo '--- esperado: 0 ; 1 | 64 ---'

\echo ''
\echo '=== R3: la señal desde cada negocio ==='
set role authenticated;
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select r->>'senal' senal, r->>'texto' texto from (select fn_riesgo_verificar('c5200000-0000-0000-0000-000000000002', '0801-1990-12345', true) r) x;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select r->>'senal' senal, r->>'texto' texto, r->>'con_deuda' deuda, r ? 'debe' as trae_monto
  from (select fn_riesgo_cliente('c5200000-0000-0000-0000-000000000001') r) x;
reset role;
\echo '--- esperado: verde | Al día en el otro negocio ; amarillo | Debe en otro negocio, al día | 1 | f ---'

\echo ''
\echo '=== R4: debe en tres negocios: rojo ==='
insert into organizaciones (id, nombre, pais, moneda) values
  ('aaaaaaaa-0000-0000-0000-000000000003','Pulpería Tres','HN','HNL'),
  ('aaaaaaaa-0000-0000-0000-000000000004','Pulpería Cuatro','HN','HNL');
insert into clientes (organizacion_id, codigo, nombre, limite_credito, saldo, activo, riesgo_persona_id, riesgo_consentido_en)
select o, 'K', 'Juan', 500, 100, true, (select riesgo_persona_id from clientes where id = 'c5200000-0000-0000-0000-000000000001'), now()
  from unnest(array['aaaaaaaa-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000004']::uuid[]) o;
-- uno sin permiso no cuenta
insert into organizaciones (id, nombre, pais, moneda) values ('aaaaaaaa-0000-0000-0000-000000000005','Pulpería Cinco','HN','HNL');
insert into clientes (organizacion_id, codigo, nombre, limite_credito, saldo, activo, riesgo_persona_id)
values ('aaaaaaaa-0000-0000-0000-000000000005','K','Juan', 500, 900, true, (select riesgo_persona_id from clientes where id = 'c5200000-0000-0000-0000-000000000001'));
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select r->>'senal' senal, r->>'texto' texto, r->>'negocios' negocios from (select fn_riesgo_cliente('c5200000-0000-0000-0000-000000000001') r) x;
select count(*) as en_lista, min(senal) as senal from fn_riesgo_clientes();
reset role;
\echo '--- esperado: rojo | Debe en 3 negocios, al día | 3 ; 1 | rojo ---'

\echo ''
\echo '=== R5: la persona ve su reporte y reclama ==='
update clientes set usuario_id = 'cccc0000-0000-0000-0000-00000000000a' where id = 'c5200000-0000-0000-0000-000000000001';
set role authenticated;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-00000000000a';
select r->>'verificado' v, r->>'senal' senal, jsonb_array_length(r->'negocios_detalle') negocios,
       (select sum((x->>'debe')::numeric) from jsonb_array_elements(r->'negocios_detalle') x) debe
  from (select fn_mi_central() r) x;
select fn_reclamar_central('corto');
select fn_reclamar_central('Ya le pagué a Pulpería Tres el lunes, tengo el recibo');
select jsonb_array_length(fn_mi_central()->'reclamos') reclamos;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-00000000000b';
select fn_mi_central()->>'verificado' otro;
select fn_admin_reclamos_central();
reset role;
select id as rec from riesgo_reclamos limit 1 \gset
set role authenticated;
set request.jwt.claim.sub = 'ad520000-0000-0000-0000-000000000001';
select jsonb_array_length(fn_admin_reclamos_central()) as reclamos_admin;
select fn_admin_resolver_reclamo(:'rec'::uuid, 'resuelto', '');
select fn_admin_resolver_reclamo(:'rec'::uuid, 'resuelto', 'Pulpería Tres confirmó el pago');
reset role;
select estado, respuesta from riesgo_reclamos;
\echo '--- esperado: true | rojo | 4 | 500 ; error corto ; (ok) ; 1 ; false ; error solo plataforma ; 1 ; error respuesta ; (ok) ; resuelto | Pulpería Tres confirmó ---'

\echo ''
\echo '=== R6: quitar de la central y la bitácora ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_riesgo_quitar('c5200000-0000-0000-0000-000000000001');
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_riesgo_quitar('c5200000-0000-0000-0000-000000000001');
select fn_riesgo_cliente('c5200000-0000-0000-0000-000000000001')->>'verificado' verificado;
select * from riesgo_bitacora;
update clientes set riesgo_persona_id = null where id = 'c5200000-0000-0000-0000-000000000003';
reset role;
select accion, count(*) from riesgo_bitacora group by accion order by accion;
select has_function_privilege('anon', 'fn_riesgo_verificar(uuid,text,boolean)', 'execute') a1,
       has_function_privilege('authenticated', 'app.dni_huella(text)', 'execute') a2,
       has_function_privilege('authenticated', 'app.riesgo_resumen(uuid,uuid)', 'execute') a3,
       has_table_privilege('authenticated', 'riesgo_personas', 'select') a4,
       has_table_privilege('authenticated', 'app.riesgo_llave', 'select') a5;
\echo '--- esperado: error supervisor ; (ok) ; false ; error tabla ; error columna ; consultar 2 | quitar 1 | verificar 2 ; f f f f f ---'
