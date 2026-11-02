\pset pager off
set role postgres;

\echo '=== A1: registrar accesos con IP y país ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
set request.headers = '{"x-forwarded-for":"190.53.10.4, 10.0.0.1","cf-ipcountry":"HN"}';
select fn_registrar_acceso('Chrome en Android');
select fn_registrar_acceso('Chrome en Android');
set request.headers = '{"cf-connecting-ip":"8.8.8.8","cf-ipcountry":"US"}';
select fn_registrar_acceso('Firefox', 'caja');
set request.headers = '';
select fn_registrar_acceso(null);
reset role;
select ip, pais, aparato, donde from accesos order by id;
\echo '--- esperado: HN fuera f ; (igual) ; US fuera t ; pais nulo ; 190.53.10.4 HN · 8.8.8.8 US caja (3 filas: la repetida no se anota, la sin IP sí porque cambió) ---'

\echo ''
\echo '=== A2: el gerente los ve; la auxiliar no ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_accesos();
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select r->>'fuera_7d' fuera, jsonb_array_length(r->'filas') filas, r->'filas'->0->>'nombre' nombre
  from (select fn_accesos() r) x;
select jsonb_array_length(fn_accesos(30, true)->'filas') solo_fuera;
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select jsonb_array_length(fn_accesos()->'filas') otro_negocio;
reset role;
\echo '--- esperado: error ; 1 | 3 | Auxiliar 1 ; 1 ; 0 ---'

\echo ''
\echo '=== H1: horario válido y abierta ahora ==='
select app.horario_valido('{"1":{"abre":"07:00","cierra":"21:00"},"0":null}') ok1,
       app.horario_valido('{"7":{"abre":"07:00","cierra":"21:00"}}') mal_dia,
       app.horario_valido('{"1":{"abre":"7:00","cierra":"21:00"}}') mal_hora,
       app.horario_valido('{"1":{"abre":"08:00","cierra":"08:00"}}') igual;
update sucursales set horario = '{"1":{"abre":"25:00","cierra":"21:00"}}' where id = 'bbbbbbbb-0000-0000-0000-000000000001';
-- todos los días de 00:00 a 23:59: abierta salvo el último minuto
select app.abierta_ahora('{"0":{"abre":"00:00","cierra":"23:59"},"1":{"abre":"00:00","cierra":"23:59"},"2":{"abre":"00:00","cierra":"23:59"},"3":{"abre":"00:00","cierra":"23:59"},"4":{"abre":"00:00","cierra":"23:59"},"5":{"abre":"00:00","cierra":"23:59"},"6":{"abre":"00:00","cierra":"23:59"}}', 'America/Tegucigalpa') siempre,
       app.abierta_ahora('{"0":null,"1":null,"2":null,"3":null,"4":null,"5":null,"6":null}', 'America/Tegucigalpa') nunca,
       app.abierta_ahora(null, 'America/Tegucigalpa') sin_horario;
-- abre de noche y cierra de madrugada: a esta hora, ¿cae dentro? (se compara con el cálculo a mano)
with h as (select (now() at time zone 'America/Tegucigalpa') t)
select app.abierta_ahora(jsonb_build_object(extract(dow from t)::int::text,
         jsonb_build_object('abre', to_char(t - interval '1 hour', 'HH24:MI'), 'cierra', to_char(t - interval '2 hours', 'HH24:MI'))),
         'America/Tegucigalpa') noche_abierta
  from h;
\echo '--- esperado: t f f f ; error check ; t | f | (nulo) ; t ---'

\echo ''
\echo '=== H2: el cliente ve las tiendas con su horario ==='
update sucursales set horario = '{"0":{"abre":"00:00","cierra":"23:59"},"1":{"abre":"00:00","cierra":"23:59"},"2":{"abre":"00:00","cierra":"23:59"},"3":{"abre":"00:00","cierra":"23:59"},"4":{"abre":"00:00","cierra":"23:59"},"5":{"abre":"00:00","cierra":"23:59"},"6":{"abre":"00:00","cierra":"23:59"}}'
 where id = 'bbbbbbbb-0000-0000-0000-000000000002';
set role authenticated;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-00000000000b';
select x->>'sucursal' sucursal, x->>'abierta' abierta, x ? 'horario' trae_horario
  from jsonb_array_elements(fn_tiendas_cerca()) x;
-- el gerente puede guardar el horario (permiso de columna)
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
update sucursales set horario = '{"1":{"abre":"06:30","cierra":"20:00"}}' where id = 'bbbbbbbb-0000-0000-0000-000000000001';
reset role;
select horario from sucursales where id = 'bbbbbbbb-0000-0000-0000-000000000001';
\echo '--- esperado: Dona Chus primero con abierta true ; las demás nulo ; horario guardado ---'

\echo ''
\echo '=== F1: mi fiado ==='
insert into clientes (id, organizacion_id, codigo, nombre, limite_credito, saldo, activo, usuario_id) values
 ('c5300000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','F1','Doña Luz', 800, 250, true, 'cccc0000-0000-0000-0000-00000000000a');
insert into abonos_cliente (organizacion_id, cliente_id, monto, saldo_anterior, saldo_nuevo)
values ('aaaaaaaa-0000-0000-0000-000000000001','c5300000-0000-0000-0000-000000000001', 50, 300, 250);
set role authenticated;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-00000000000a';
select x->>'negocio' negocio, (x->>'debe')::numeric debe, (x->>'disponible')::numeric disponible,
       jsonb_array_length(x->'movimientos') movs, x->'movimientos'->0->>'tipo' ultimo
  from jsonb_array_elements(fn_mi_fiado()) x;
set request.jwt.claim.sub = 'cccc0000-0000-0000-0000-00000000000b';
select jsonb_array_length(fn_mi_fiado()) otro;
reset role;
select has_function_privilege('anon','fn_mi_fiado()','execute') a1,
       has_function_privilege('anon','fn_registrar_acceso(text,text)','execute') a2,
       has_table_privilege('authenticated','accesos','select') a3;
\echo '--- esperado: Pulperia La Esquina | 250 | 550 | 1 | abono ; 0 ; f f f ---'
