\pset pager off
set role postgres;

-- Sobre la semilla de t_pedidos. Usuario nuevo que se registra y un admin de Pulpeando.
insert into auth.users (id, email) values
 ('cccc0000-0000-0000-0000-000000000001','nueva@t.hn'),
 ('cccc0000-0000-0000-0000-000000000002','otra@t.hn'),
 ('adad0000-0000-0000-0000-000000000001','admin@pulpeando.hn');
insert into perfiles (id, organizacion_id, nombre, email, rol, activo) values
 ('adad0000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Pulpeando','admin@pulpeando.hn','admin', true);

\echo '=== A1: el alta completa con service_role ==='
set role service_role;
select (fn_crear_negocio('cccc0000-0000-0000-0000-000000000001',
  '{"negocio":"Pulpería La Bendición","nombre":"Rosa Martínez","telefono":"9999-1234","pin":"40719","sucursal":"Colonia Kennedy"}') ->> 'organizacion_id') as org \gset
reset role;
select o.nombre, o.plan, o.origen, o.prueba_hasta = current_date + 14 as prueba_14, o.codigo_tienda ~ '^[1-9][0-9]{2}$' as cod_ok,
       o.telefono_contacto,
       (select count(*) from sucursales where organizacion_id = o.id) as suc,
       (select count(*) from ubicaciones where organizacion_id = o.id) as ubic,
       (select count(*) from impuestos where organizacion_id = o.id) as imp,
       (select count(*) from cajas where organizacion_id = o.id) as cajas,
       (select count(*) from categorias where organizacion_id = o.id) as cats,
       (select rol || ' ' || nombre || ' pin:' || (pin_pos = crypt('40719', pin_pos)) from perfiles where id = 'cccc0000-0000-0000-0000-000000000001') as dueno
  from organizaciones o where o.id = :'org';
\echo '--- esperado: La Bendición | prueba | registro | t | t | 9999-1234 | 1 | 2 | 2 | 1 | 6 | gerente Rosa Martínez pin:true ---'

\echo ''
\echo '=== A2: nadie más puede llamar al alta ni a sus ayudantes ==='
select has_function_privilege('anon', 'fn_crear_negocio(uuid,jsonb)', 'execute') as anon_alta,
       has_function_privilege('authenticated', 'fn_crear_negocio(uuid,jsonb)', 'execute') as auth_alta,
       has_function_privilege('authenticated', 'fn_registro_intento(text,text)', 'execute') as auth_intento,
       has_function_privilege('anon', 'fn_registro_info()', 'execute') as anon_info,
       has_function_privilege('service_role', 'fn_crear_negocio(uuid,jsonb)', 'execute') as srv_alta,
       has_function_privilege('anon', 'fn_mi_cuenta()', 'execute') as anon_cuenta,
       has_function_privilege('anon', 'fn_admin_negocios()', 'execute') as anon_admin;
\echo '--- esperado: f | f | f | f | t | f | f ---'

\echo ''
\echo '=== A3: lo que el alta rechaza ==='
set role service_role;
select fn_crear_negocio('cccc0000-0000-0000-0000-000000000002', '{"negocio":"Tienda X","nombre":"Pedro P","pin":"11111"}');
select fn_crear_negocio('cccc0000-0000-0000-0000-000000000002', '{"negocio":"Tienda X","nombre":"Pedro P","pin":"12345"}');
select fn_crear_negocio('cccc0000-0000-0000-0000-000000000002', '{"negocio":"Tienda X","nombre":"Pedro P","pin":"12a45"}');
select fn_crear_negocio('cccc0000-0000-0000-0000-000000000002', '{"negocio":"X","nombre":"Pedro P","pin":"40719"}');
select fn_crear_negocio('cccc0000-0000-0000-0000-000000000001', '{"negocio":"Otra más","nombre":"Rosa M","pin":"40719"}');
select fn_crear_negocio('dddd0000-0000-0000-0000-000000000009', '{"negocio":"Fantasma","nombre":"Nadie N","pin":"40719"}');
reset role;
update plataforma_config set datos = datos || '{"registro_abierto":false}' where id;
set role service_role;
select fn_crear_negocio('cccc0000-0000-0000-0000-000000000002', '{"negocio":"Tienda X","nombre":"Pedro P","pin":"40719"}');
select fn_registro_info() ->> 'registro_abierto' as abierto;
reset role;
update plataforma_config set datos = datos || '{"registro_abierto":true}' where id;
select count(*) as negocios_de_pedro from perfiles where id = 'cccc0000-0000-0000-0000-000000000002';
\echo '--- esperado: 7 errores (fácil, fácil, 5 dígitos, nombre corto, ya pertenece, no existe, cerrado), abierto=false, 0 ---'

\echo ''
\echo '=== A4: límite de intentos por IP ==='
set role service_role;
select fn_registro_intento('1.2.3.4', 'a@b.c') as i1, fn_registro_intento('1.2.3.4') as i2, fn_registro_intento('1.2.3.4') as i3,
       fn_registro_intento('1.2.3.4') as i4, fn_registro_intento('1.2.3.4') as i5, fn_registro_intento('1.2.3.4') as i6,
       fn_registro_intento('5.6.7.8') as otra_ip;
reset role;
\echo '--- esperado: t t t t t f t ---'

\echo ''
\echo '=== A5: el dueño entra: su cuenta, primeros pasos y catálogo de muestra ==='
set role authenticated;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-000000000001';
select c -> 'organizacion' -> 'cuenta' ->> 'en_prueba' as en_prueba,
       c -> 'organizacion' -> 'cuenta' ->> 'dias_restantes' as dias,
       c -> 'organizacion' -> 'cuenta' ->> 'vencida' as vencida,
       c -> 'usuario' ->> 'rol' as rol,
       jsonb_array_length(c -> 'cajas') as cajas
  from (select fn_pos_contexto() c) x;
select jsonb_array_length(m -> 'planes') as planes, m ->> 'codigo_tienda' ~ '^[0-9]{3}$' as cod,
       jsonb_array_length(m -> 'pagos') as pagos
  from (select fn_mi_cuenta() m) x;
select p ->> 'oculto' as oculto, (select string_agg((e ->> 'id') || '=' || (e ->> 'hecho'), ' ') from jsonb_array_elements(p -> 'pasos') e) as pasos
  from (select fn_primeros_pasos() p) x;
select r ->> 'creados' as creados from (select fn_cargar_catalogo_muestra() r) x;
select r ->> 'creados' as creados_2da, r ->> 'actualizados' as act_2da from (select fn_cargar_catalogo_muestra() r) x;
select fn_ocultar_primeros_pasos();
select p ->> 'oculto' as oculto, (select e ->> 'hecho' from jsonb_array_elements(p -> 'pasos') e where e ->> 'id' = 'productos') as productos
  from (select fn_primeros_pasos() p) x;
reset role;
select (select count(*) from productos where organizacion_id = :'org' and activo) as prod,
       (select count(*) from proveedores where organizacion_id = :'org' and dia_visita is not null) as prov_con_visita,
       (select count(*) from productos where organizacion_id = 'aaaaaaaa-0000-0000-0000-000000000001' and nombre like 'Arroz blanco 1 lb') as fuga_org1;
\echo '--- esperado: true | 14 | false | gerente | 1 ; 2 | t | 0 ; false | productos=false negocio=false usuarios=false venta=false compra=false ; 100 ; 0 | 100 ; true | true ; 100 | 8 | 0 ---'

\echo ''
\echo '=== A6: el gerente no se alarga la prueba ni ve lo de Pulpeando ==='
set role authenticated;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-000000000001';
update organizaciones set prueba_hasta = current_date + 365 where id = :'org';
update organizaciones set plan = 'negocio' where id = :'org';
select fn_admin_negocios();
select fn_admin_registrar_pago(:'org', 1, 450);
select fn_admin_guardar_config('{"dias_prueba":90}');
update organizaciones set nombre = 'Pulpería La Bendición 2' where id = :'org';
select nombre from organizaciones where id = :'org';
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_mi_cuenta();
select fn_cargar_catalogo_muestra();
reset role;
select prueba_hasta = current_date + 14 as prueba_igual, plan from organizaciones where id = :'org';
\echo '--- esperado: 7 errores (prueba, plan, 3 admin, auxiliar cuenta, auxiliar catálogo), el nombre sí cambia, t | prueba ---'

\echo ''
\echo '=== A7: abrir turno según la cuenta ==='
select id as caja from cajas where organizacion_id = :'org' \gset
set role authenticated;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-000000000001';
select fn_abrir_turno(:'caja'::uuid, 'cccc0000-0000-0000-0000-000000000001', '40719', 0) is not null as abre_en_prueba;
reset role;
delete from caja_desbloqueos where turno_id in (select id from turnos_caja where caja_id = :'caja');
delete from movimientos_caja where turno_id in (select id from turnos_caja where caja_id = :'caja');
delete from eventos_caja where turno_id in (select id from turnos_caja where caja_id = :'caja');
delete from turnos_caja where caja_id = :'caja';
-- en gracia: venció hace 2 días, la gracia es de 3
set role postgres;
alter table organizaciones disable trigger tg_organizaciones_candado;
update organizaciones set prueba_hasta = current_date - 2 where id = :'org';
set role authenticated;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-000000000001';
select c ->> 'en_gracia' as en_gracia, c ->> 'vencida' as vencida, c ->> 'dias_restantes' as dias
  from (select fn_pos_contexto() -> 'organizacion' -> 'cuenta' c) x;
select fn_abrir_turno(:'caja'::uuid, 'cccc0000-0000-0000-0000-000000000001', '40719', 0) is not null as abre_en_gracia;
reset role;
delete from caja_desbloqueos where turno_id in (select id from turnos_caja where caja_id = :'caja');
delete from movimientos_caja where turno_id in (select id from turnos_caja where caja_id = :'caja');
delete from eventos_caja where turno_id in (select id from turnos_caja where caja_id = :'caja');
delete from turnos_caja where caja_id = :'caja';
update organizaciones set prueba_hasta = current_date - 10 where id = :'org';
set role authenticated;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-000000000001';
select fn_pos_contexto() -> 'organizacion' -> 'cuenta' ->> 'vencida' as vencida;
select fn_abrir_turno(:'caja'::uuid, 'cccc0000-0000-0000-0000-000000000001', '40719', 0);
reset role;
\echo '--- esperado: t ; true | false | -2 ; t ; true ; error «cuenta vencida» ---'

\echo ''
\echo '=== A8: Pulpeando registra el pago ==='
set role authenticated;
set request.jwt.claim.sub = 'adad0000-0000-0000-0000-000000000001';
select jsonb_array_length(fn_admin_negocios()) as negocios;
select n ->> 'nombre' as nombre, n -> 'dueno' ->> 'email' as email, n ->> 'productos' as prod, n -> 'cuenta' ->> 'vencida' as vencida
  from jsonb_array_elements(fn_admin_negocios()) n where n ->> 'id' = :'org';
select e ->> 'vencida' as vencida, e ->> 'pagado_hasta' = ((current_date + interval '1 month')::date - 1)::text as hasta_ok, e ->> 'plan' as plan
  from (select fn_admin_registrar_pago(:'org', 1, 450, null, 'transferencia', 'BAC 123') e) x;
-- segundo pago: arranca al día siguiente del primero
select e ->> 'pagado_hasta' = ((current_date + interval '1 month' + interval '3 months')::date - 1)::text as hasta_ok2
  from (select fn_admin_registrar_pago(:'org', 3, 1350, 'negocio') e) x;
select fn_admin_actualizar_cuenta(:'org', '{"notas":"Llamó el 1 de nov"}') ->> 'plan' as plan;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-000000000001';
select jsonb_array_length(fn_mi_cuenta() -> 'pagos') as pagos_que_ve_el_gerente;
select fn_abrir_turno(:'caja'::uuid, 'cccc0000-0000-0000-0000-000000000001', '40719', 0) is not null as abre_ya_pagado;
reset role;
select notas_plataforma from organizaciones where id = :'org';
\echo '--- esperado: 3 ; La Bendición 2 | nueva@t.hn | 100 | true ; false | t | basico ; t ; negocio ; 2 ; t ; Llamó el 1 de nov ---'

\echo ''
\echo '=== A9: pago durante la prueba arranca cuando acaba la prueba; desactivar bloquea ==='
update organizaciones set prueba_hasta = current_date + 5, pagado_hasta = null where id = 'aaaaaaaa-0000-0000-0000-000000000002';
set role authenticated;
set request.jwt.claim.sub = 'adad0000-0000-0000-0000-000000000001';
select fn_admin_registrar_pago('aaaaaaaa-0000-0000-0000-000000000002', 1, 450) is not null as pago;
reset role;
select desde = current_date + 6 as desde_ok from pagos_suscripcion where organizacion_id = 'aaaaaaaa-0000-0000-0000-000000000002';
set role authenticated;
set request.jwt.claim.sub = 'adad0000-0000-0000-0000-000000000001';
select fn_admin_actualizar_cuenta('aaaaaaaa-0000-0000-0000-000000000002', '{"activa":false}') ->> 'vencida' as vencida_si_inactiva;
select fn_admin_guardar_config('{"dias_prueba":200}');
select fn_admin_guardar_config('{"planes":[{"id":"Mal Id","nombre":"x","precio":1}]}');
select c ->> 'dias_prueba' as dias, c ? 'raro' as guardo_raro, c ->> 'whatsapp' as wa
  from (select fn_admin_guardar_config('{"dias_prueba":30,"raro":1,"whatsapp":"50499990000"}') c) x;
reset role;
alter table organizaciones enable trigger tg_organizaciones_candado;
\echo '--- esperado: t ; t ; true ; 2 errores (prueba 0-90, plan) ; 30 | f | 50499990000 ---'

\echo ''
\echo '=== A10: los negocios de antes no tienen límite ==='
select app.estado_cuenta('aaaaaaaa-0000-0000-0000-000000000001') ->> 'sin_limite' as sin_limite,
       app.cuenta_bloqueada('aaaaaaaa-0000-0000-0000-000000000001') as bloqueada;
\echo '--- esperado: true | f ---'

\echo ''
\echo '=== A11: quitar la muestra ==='
set role authenticated;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-000000000001';
select fn_quitar_catalogo_muestra();
reset role;
select count(*) filter (where activo) as activos from productos where organizacion_id = :'org';
\echo '--- esperado: {"productos": 100, "proveedores": 8} | 0 ---'

\echo ''
\echo '=== A12: el catálogo compacto queda igual que sql/demo_catalogo.sql ==='
select count(*) filter (where p.unidades_empaque is not null) as con_empaque, count(m.id) as con_marca, count(*) as total,
       sum(p.stock_minimo) as minimos from productos p left join marcas m on m.id = p.marca_id where p.organizacion_id = :'org';
\echo '--- esperado: 89 | 64 | 100 | 497 ---'
