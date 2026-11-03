\pset pager off
set role postgres;
insert into auth.users (id, email) values ('bbbb0000-0000-0000-0000-000000000001','sup1@t.hn');
insert into perfiles (id, organizacion_id, nombre, email, rol, activo) values
 ('bbbb0000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Supervisor','sup1@t.hn','supervisor',true);
insert into usuario_sucursales (perfil_id, sucursal_id) values
 ('bbbb0000-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');
select id as bod1 from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and tipo='bodega' limit 1 \gset
\echo '### Arroz 50, todo en el piso, bodega sin auditar nunca'

\echo '=== E1: sin nada en bodega se cuenta el piso sin auditar ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select (fn_estado_bodega('bbbbbbbb-0000-0000-0000-000000000001', 24)->>'al_dia') bodega_al_dia;
select fn_conteo_pide_bodega('eeeeeeee-0000-0000-0000-000000000001');
select (fn_solicitar_conteo_piso('eeeeeeee-0000-0000-0000-000000000001', 48)->>'diferencia')::numeric dif;
reset role;
update ajustes_inventario set estado = 'rechazado' where estado = 'pendiente';
\echo '--- esperado: false ; pide false bodega 0 piso 50 ; -2 ---'

\echo ''
\echo '=== E2: el piso dice más de lo que cabe en el estante ==='
update productos set capacidad_estante = 40 where id = 'eeeeeeee-0000-0000-0000-000000000001';
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_conteo_pide_bodega('eeeeeeee-0000-0000-0000-000000000001');
select fn_solicitar_conteo_piso('eeeeeeee-0000-0000-0000-000000000001', 48);
reset role;
update productos set capacidad_estante = 60 where id = 'eeeeeeee-0000-0000-0000-000000000001';
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select (fn_conteo_pide_bodega('eeeeeeee-0000-0000-0000-000000000001')->>'pide') con_60_cabe;
reset role;
\echo '--- esperado: pide true razon capacidad ; error primero hay que auditar ; false ---'

\echo ''
\echo '=== E3: con mercadería en bodega sí se pide ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-000000000001', :'bod1', 30) is not null movido;
select fn_conteo_pide_bodega('eeeeeeee-0000-0000-0000-000000000001');
select fn_solicitar_conteo_piso('eeeeeeee-0000-0000-0000-000000000001', 18);
\echo '--- esperado: t ; pide true bodega 30 piso 20 razon bodega ; error auditar ---'

\echo ''
\echo '=== E4: permisos ==='
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select fn_conteo_pide_bodega('eeeeeeee-0000-0000-0000-000000000001');
reset role;
select has_function_privilege('anon','fn_conteo_pide_bodega(uuid,uuid)','execute') a1,
       has_function_privilege('authenticated','app.conteo_pide_bodega(uuid,uuid)','execute') a2,
       position('conteo_pide_bodega' in pg_get_functiondef('fn_solicitar_conteo_piso(uuid,numeric,uuid,text,uuid)'::regprocedure)) > 0 parchada;
\echo '--- esperado: error otro negocio ; f f t ---'
