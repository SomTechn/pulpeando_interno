\pset pager off
set role postgres;
-- Semilla de t_pedidos: Arroz 5lb con 50 en La Esquina (sucursal bbbb…01).
select id as arroz from productos where nombre = 'Arroz 5lb' \gset
select id as bodega from ubicaciones where sucursal_id = 'bbbbbbbb-0000-0000-0000-000000000001' and tipo = 'bodega' limit 1 \gset
select id as piso from ubicaciones where sucursal_id = 'bbbbbbbb-0000-0000-0000-000000000001' and es_predeterminada \gset
select (select sum(cantidad) from existencias where producto_id = :'arroz') as total_arroz;

\echo '=== C1: el gerente pone la capacidad; cero no vale ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
update productos set capacidad_estante = 0 where id = :'arroz';
update productos set capacidad_estante = 20 where id = :'arroz';
select fn_mover_entre_ubicaciones(:'arroz'::uuid, :'bodega'::uuid, 40) is not null as a_bodega;
reset role;
select capacidad_estante from productos where id = :'arroz';
\echo '--- esperado: error (>0) ; t ; 20 ---'

\echo ''
\echo '=== C2: la lista de reponer ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select r ->> 'piso_id' = :'piso' as piso_ok, f ->> 'nombre' as nombre, f ->> 'piso' as en_piso, f ->> 'bodega' as en_bodega,
       f ->> 'falta' as falta, f ->> 'sugerido' as sugerido, f ->> 'lleno' as lleno, f ->> 'desde_id' = :'bodega' as desde_bodega
  from (select fn_reponer_piso('bbbbbbbb-0000-0000-0000-000000000001') r) x, jsonb_array_elements(r -> 'filas') f;
\echo '--- esperado: t | Arroz 5lb | 10 | 40 | 10 | 10 | 50 | t ---'

\echo ''
\echo '=== C3: otro negocio no ve la lista ==='
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select fn_reponer_piso('bbbbbbbb-0000-0000-0000-000000000001');
\echo '--- esperado: error de acceso ---'

\echo ''
\echo '=== C4: se pasa lo sugerido y sale de la lista ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_mover_entre_ubicaciones(:'arroz'::uuid, :'piso'::uuid, 10, :'bodega'::uuid) is not null as pasado;
select jsonb_array_length(fn_reponer_piso('bbbbbbbb-0000-0000-0000-000000000001') -> 'filas') as filas;
reset role;
select (select sum(cantidad) from existencias where producto_id = :'arroz') as total_igual;
\echo '--- esperado: t ; 0 ; el mismo total del principio (mover no es kardex) ---'

\echo ''
\echo '=== C5: sin bodega sugiere 0 (hay que comprar) ==='
update existencias set cantidad = 5 where producto_id = :'arroz';
update existencias_ubicacion set cantidad = 0 where producto_id = :'arroz';
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select f ->> 'piso' as piso, f ->> 'sugerido' as sugerido, f ->> 'desde' as desde
  from jsonb_array_elements(fn_reponer_piso('bbbbbbbb-0000-0000-0000-000000000001') -> 'filas') f;
reset role;
select has_function_privilege('anon', 'fn_reponer_piso(uuid)', 'execute') as anon;
\echo '--- esperado: 5 | 0 | (nulo) ; f ---'
