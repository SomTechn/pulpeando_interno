\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- Una cajera con código y PIN, un repartidor (que no atiende caja) y una
-- cajera dada de baja.
insert into auth.users (id, email) values
  ('cccc0000-0000-0000-0000-000000000001','cajera@t.hn'),
  ('cccc0000-0000-0000-0000-000000000002','repa@t.hn'),
  ('cccc0000-0000-0000-0000-000000000003','exempleada@t.hn'),
  ('cccc0000-0000-0000-0000-000000000009','cajera.chus@t.hn');

insert into perfiles (id, organizacion_id, nombre, email, rol, codigo, pin_pos, activo) values
 ('cccc0000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
  'Cajera Mari','cajera@t.hn','auxiliar','C7', crypt('45678', gen_salt('bf')), true),
 ('cccc0000-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001',
  'Repartidor Tono','repa@t.hn','repartidor','R1', crypt('45678', gen_salt('bf')), true),
 ('cccc0000-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000001',
  'Ex Empleada','exempleada@t.hn','auxiliar','X9', crypt('45678', gen_salt('bf')), false),
 -- Misma letra y número que la cajera de La Esquina, en la otra pulpería.
 ('cccc0000-0000-0000-0000-000000000009','aaaaaaaa-0000-0000-0000-000000000002',
  'Cajera Chus','cajera.chus@t.hn','auxiliar','C7', crypt('45678', gen_salt('bf')), true);

insert into usuario_sucursales (perfil_id, sucursal_id) values
 ('cccc0000-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001'),
 ('cccc0000-0000-0000-0000-000000000009','bbbbbbbb-0000-0000-0000-000000000002');

insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa) values
 ('aaaa0000-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001',
  'bbbbbbbb-0000-0000-0000-000000000001','C1','Caja 1', true),
 ('aaaa0000-0000-0000-0000-0000000000e9','aaaaaaaa-0000-0000-0000-000000000002',
  'bbbbbbbb-0000-0000-0000-000000000002','C1','Caja de Chus', true);

\echo '### La Esquina: cajera C7 con PIN 45678. Dona Chus tambien tiene una C7.'


-- ===================================================================
\echo ''
\echo '=== E1: el gerente parea la tablet de la caja 1 ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select r ->> 'llave' as llave, r ->> 'aparato_id' as aparato
  from fn_parear_aparato('bbbbbbbb-0000-0000-0000-000000000001',
                         'aaaa0000-0000-0000-0000-0000000000e1',
                         'Tablet caja 1') r \gset

select length(:'llave') as largo_llave, :'aparato' is not null as tiene_id;
\echo '--- esperado: largo 48 y tiene_id = t ---'

set role postgres;
select count(*) as llave_en_claro_en_la_tabla
  from aparatos_caja where id = :'aparato' and llave_pos = :'llave';
\echo '--- esperado: 0. La llave se guarda hasheada, nunca en claro ---'
set role authenticated;


-- ===================================================================
\echo ''
\echo '=== E2: el gerente de Dona Chus no parea en La Esquina ==='
\set ON_ERROR_STOP off
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select fn_parear_aparato('bbbbbbbb-0000-0000-0000-000000000001', null, 'Robada');
\echo '--- esperado: esa sucursal no es de su negocio ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== E3: el auxiliar no parea aparatos ==='
\set ON_ERROR_STOP off
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_parear_aparato('bbbbbbbb-0000-0000-0000-000000000001', null, 'Mia');
\echo '--- esperado: solo un gerente ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== E4: una caja de otra sucursal no se parea aqui ==='
\set ON_ERROR_STOP off
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_parear_aparato('bbbbbbbb-0000-0000-0000-000000000001',
                         'aaaa0000-0000-0000-0000-0000000000e9', 'Mezclada');
\echo '--- esperado: esa caja no es de esa sucursal ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== E5: la cajera entra con su codigo y su PIN ==='
set role service_role;
select jsonb_pretty(app.entrada_de_caja(:'aparato', :'llave', 'c7', '45678')) as entrada;
\echo '--- esperado: ok true, Cajera Mari, su correo, la sucursal y la caja ---'
\echo '--- (el codigo va en minuscula a proposito: no debe importar) ---'

\echo ''
\echo '=== E5c: un perfil sin correo en perfiles igual entra, con el de su cuenta ==='
set role postgres;
update perfiles set email = null where id = 'cccc0000-0000-0000-0000-000000000001';
set role service_role;
select fn_entrar_caja(:'aparato', :'llave', 'C7', '45678') ->> 'email' as correo;
\echo '--- esperado: cajera@t.hn, sacado de auth.users ---'
set role postgres;
update perfiles set email = 'cajera@t.hn' where id = 'cccc0000-0000-0000-0000-000000000001';
set role service_role;

\echo ''
\echo '=== E5b: lo mismo por la envoltura publica, que es por donde entra ==='
\echo '--- la funcion de borde (PostgREST no publica el esquema app) ---'
select fn_entrar_caja(:'aparato', :'llave', 'C7', '45678') ->> 'nombre' as por_la_envoltura;
\echo '--- esperado: Cajera Mari ---'


-- ===================================================================
\echo ''
\echo '=== E6: la llave equivocada no abre ==='
select app.entrada_de_caja(:'aparato', 'ffffffff', 'C7', '45678') ->> 'error' as llave_mala;
select app.entrada_de_caja('aaaa0000-0000-0000-0000-00000000dead', 'loquesea',
                           'C7', '45678') ->> 'error' as aparato_inventado;
\echo '--- esperado: "aparato" las dos veces, el mismo mensaje para los dos ---'


-- ===================================================================
\echo ''
\echo '=== E7: el codigo de la otra pulperia no entra por este aparato ==='
\echo '--- (Dona Chus tambien tiene una C7 con el mismo PIN) ---'
select app.entrada_de_caja(:'aparato', :'llave', 'C7', '45678') ->> 'nombre' as quien_entro;
\echo '--- esperado: Cajera Mari, NUNCA Cajera Chus ---'


-- ===================================================================
\echo ''
\echo '=== E8: el repartidor no atiende caja, y la dada de baja tampoco ==='
select app.entrada_de_caja(:'aparato', :'llave', 'R1', '45678') ->> 'mensaje' as repartidor;
\echo '--- esperado: Repartidor Tono no atiende caja ---'
select app.entrada_de_caja(:'aparato', :'llave', 'X9', '45678') ->> 'mensaje' as de_baja;
\echo '--- esperado: "Codigo o PIN incorrecto". Un inactivo ni existe ---'


-- ===================================================================
\echo ''
\echo '=== E9: el PIN malo suma intento, y a los cinco bloquea el perfil ==='
select app.entrada_de_caja(:'aparato', :'llave', 'C7', '00000') ->> 'mensaje' as i1;
select app.entrada_de_caja(:'aparato', :'llave', 'C7', '00001') ->> 'mensaje' as i2;
select app.entrada_de_caja(:'aparato', :'llave', 'C7', '00002') ->> 'mensaje' as i3;
select app.entrada_de_caja(:'aparato', :'llave', 'C7', '00003') ->> 'mensaje' as i4;
select app.entrada_de_caja(:'aparato', :'llave', 'C7', '00004') ->> 'mensaje' as i5;
set role postgres;
select codigo, pin_intentos_fallidos,
       pin_bloqueado_hasta > now() as esta_frio
  from perfiles where id = 'cccc0000-0000-0000-0000-000000000001';
\echo '--- esperado: 5 intentos y esta_frio = t. El contador tiene que SOBREVIVIR ---'

set role service_role;
select app.entrada_de_caja(:'aparato', :'llave', 'C7', '45678') ->> 'mensaje' as con_el_pin_bueno;
\echo '--- esperado: "Codigo o PIN incorrecto" aunque el PIN sea el bueno ---'


-- ===================================================================
\echo ''
\echo '=== E10: a los diez intentos se bloquea el APARATO entero ==='
\echo '--- (quien se robe la tablet no va a ir probando codigo por codigo) ---'
-- El aparato viene cargado con los fallos de E8 y E9. Se pone en cero para
-- que esta prueba cuente diez y no "los que queden".
set role postgres;
update aparatos_caja set intentos_fallidos = 0, bloqueado_hasta = null;
set role service_role;
-- Un codigo que no existe: asi el que se cuenta es el del aparato, sin tocar
-- el contador de ningun perfil.
select string_agg(
         app.entrada_de_caja(:'aparato', :'llave', 'ZZ', '00000') ->> 'error',
         ' ') as diez_intentos
  from generate_series(1, 10);
\echo '--- esperado: "credencial" las diez veces ---'
select app.entrada_de_caja(:'aparato', :'llave', 'ZZ', '00000') ->> 'error' as el_onceavo;
\echo '--- esperado: aparato_bloqueado ---'
select app.entrada_de_caja(:'aparato', :'llave', 'C7', '45678') ->> 'error' as con_todo_bueno;
\echo '--- esperado: aparato_bloqueado. Ni con la credencial buena ---'

set role postgres;
update perfiles set pin_intentos_fallidos = 0, pin_bloqueado_hasta = null
 where id = 'cccc0000-0000-0000-0000-000000000001';
update aparatos_caja set intentos_fallidos = 0, bloqueado_hasta = null;


-- ===================================================================
\echo ''
\echo '=== E11: el aparato revocado queda muerto ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_revocar_aparato(:'aparato') ->> 'nombre' as revocado;
set role service_role;
select app.entrada_de_caja(:'aparato', :'llave', 'C7', '45678') ->> 'error' as ya_no;
\echo '--- esperado: revoca "Tablet caja 1" y despues error "aparato" ---'


-- ===================================================================
\echo ''
\echo '=== E12: el gerente de Dona Chus no revoca aparatos de La Esquina ==='
\set ON_ERROR_STOP off
set role authenticated;
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select fn_revocar_aparato(:'aparato');
\echo '--- esperado: ese aparato no es de su negocio ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== E13: cada quien ve solo los aparatos de su negocio ==='
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select nombre, sucursal, caja, activo from fn_aparatos_caja();
\echo '--- esperado: la Tablet caja 1 de La Esquina, ya inactiva ---'
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select count(*) as los_de_chus from fn_aparatos_caja();
\echo '--- esperado: 0 ---'

\echo ''
\echo '=== E13b: el auxiliar no ve la lista de aparatos ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select count(*) as los_del_auxiliar from fn_aparatos_caja();
\echo '--- esperado: 0 ---'
\set ON_ERROR_STOP off
select count(*) as por_la_tabla from aparatos_caja;
\echo '--- esperado: permiso denegado. La tabla no se lee de frente, ni el ---'
\echo '--- gerente la lee: la llave hasheada no tiene por que salir nunca ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== E14: nadie suelto alcanza la puerta de la caja ==='
\set ON_ERROR_STOP off
set role authenticated;
select app.entrada_de_caja('aaaa0000-0000-0000-0000-00000000dead','x','C7','45678');
\echo '--- esperado: permiso denegado. Con sesion no se usa esta puerta ---'
select fn_entrar_caja('aaaa0000-0000-0000-0000-00000000dead','x','C7','45678');
\echo '--- esperado: permiso denegado. La envoltura publica tampoco se regala ---'
set role anon;
select app.entrada_de_caja('aaaa0000-0000-0000-0000-00000000dead','x','C7','45678');
\echo '--- esperado: permiso denegado ---'
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
insert into aparatos_caja (organizacion_id, sucursal_id, nombre, llave_pos)
values ('aaaaaaaa-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000001','Mia','x');
\echo '--- esperado: permiso denegado. A la tabla no se escribe a mano ---'
\set ON_ERROR_STOP on
