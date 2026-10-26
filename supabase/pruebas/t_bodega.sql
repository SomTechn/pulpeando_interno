\set ON_ERROR_STOP on
\pset pager off
set role postgres;

insert into auth.users (id, email) values
  ('bbbb0000-0000-0000-0000-000000000001','sup1@t.hn'),
  ('bbbb0000-0000-0000-0000-000000000009','repa1@t.hn');
insert into perfiles (id, organizacion_id, nombre, email, rol, activo) values
 ('bbbb0000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Supervisor','sup1@t.hn','supervisor',true),
 ('bbbb0000-0000-0000-0000-000000000009','aaaaaaaa-0000-0000-0000-000000000001','Repartidor','repa1@t.hn','repartidor',true);
insert into usuario_sucursales (perfil_id, sucursal_id) values
 ('bbbb0000-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001'),
 ('bbbb0000-0000-0000-0000-000000000009','bbbbbbbb-0000-0000-0000-000000000001');

\echo '### Arroz 50 en la sucursal 1'

-- ===================================================================
\echo ''
\echo '=== D1: la consulta ya dice de que tipo es cada lugar ==='
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select u->>'nombre' as lugar, u->>'tipo' as tipo, u->>'codigo' as codigo,
       (u->>'predeterminada')::boolean as pred, u->>'cantidad' as cantidad
from jsonb_array_elements(
       fn_consultar_producto('eeeeeeee-0000-0000-0000-000000000001')->'ubicaciones') u;
\echo '--- esperado: Piso de ventas piso/predeterminada, Bodega bodega ---'

-- ===================================================================
\echo ''
\echo '=== D2: cargar a bodega lo que acaba de llegar ==='
set role postgres;
select id as bod from ubicaciones
 where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega' \gset
select id as piso from ubicaciones
 where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and es_predeterminada \gset
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-000000000001',
       :'bod'::uuid, 30, :'piso'::uuid) as cargado;
\echo '--- esperado: 30 del piso a la Bodega, con desde_tipo piso y hacia_tipo bodega ---'

select u->>'nombre' as lugar, u->>'tipo' as tipo, u->>'cantidad' as cantidad
from jsonb_array_elements(
       fn_consultar_producto('eeeeeeee-0000-0000-0000-000000000001')->'ubicaciones') u;
\echo '--- esperado: Piso 20, Bodega 30 ---'

-- ===================================================================
\echo ''
\echo '=== D3: bajar al piso lo que se escriba ==='
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-000000000001',
       :'piso'::uuid, 7, :'bod'::uuid) as bajado;
select u->>'nombre' as lugar, u->>'cantidad' as cantidad
from jsonb_array_elements(
       fn_consultar_producto('eeeeeeee-0000-0000-0000-000000000001')->'ubicaciones') u;
\echo '--- esperado: Piso 27, Bodega 23 ---'

\echo ''
\echo '=== D3b: el total NO cambia: mover no es movimiento de kardex ==='
select coalesce(sum(cantidad),0) as total_existencias
from existencias where producto_id='eeeeeeee-0000-0000-0000-000000000001'
  and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001';
select count(*) as movimientos_de_kardex_por_mover
from kardex where producto_id='eeeeeeee-0000-0000-0000-000000000001'
  and documento_tipo = 'movimiento';
\echo '--- esperado: 50 y 0 ---'

-- ===================================================================
\echo ''
\echo '=== D4: no se baja mas de lo que hay en ese lugar ==='
\set ON_ERROR_STOP off
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-000000000001',
       :'piso'::uuid, 999, :'bod'::uuid);
\echo '--- esperado: en Bodega solo hay 23 ---'
\set ON_ERROR_STOP on

-- ===================================================================
\echo ''
\echo '=== D5: con auditoria abierta en la bodega NO se mueve nada ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_auditoria(:'bod'::uuid) ->> 'numero' as auditoria;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
\set ON_ERROR_STOP off
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-000000000001',
       :'piso'::uuid, 1, :'bod'::uuid);
\echo '--- esperado: hay una auditoria abierta en Bodega (sacar de ahi) ---'
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-000000000001',
       :'bod'::uuid, 1, :'piso'::uuid);
\echo '--- esperado: lo mismo al reves (meter ahi) ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== D5b: mientras tanto, otro lugar si se puede mover ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_guardar_ubicacion('Refrigerador', null,
       'bbbbbbbb-0000-0000-0000-000000000001', 30) ->> 'nombre' as creado;
set role postgres;
select id as refri from ubicaciones where nombre='Refrigerador'
  and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' \gset
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-000000000001',
       :'refri'::uuid, 5, :'piso'::uuid) ->> 'hacia' as movido;
\echo '--- esperado: Refrigerador ---'

\echo ''
\echo '=== D5c: cerrada la auditoria, vuelve a moverse ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
set role postgres;
select id as audi from auditorias where estado='abierta' \gset
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_cancelar_auditoria(:'audi'::uuid, 'era prueba') ->> 'estado' as cerrada;
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-000000000001',
       :'piso'::uuid, 1, :'bod'::uuid) ->> 'cantidad' as ya_se_puede;
\echo '--- esperado: cancelada y 1 ---'

-- ===================================================================
\echo ''
\echo '=== D6: el repartidor no mueve ni consulta ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000009';
\set ON_ERROR_STOP off
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-000000000001',
       :'piso'::uuid, 1, :'bod'::uuid);
select fn_consultar_producto('eeeeeeee-0000-0000-0000-000000000001');
\echo '--- esperado: sin permiso las dos veces ---'
\set ON_ERROR_STOP on

-- ===================================================================
\echo ''
\echo '=== D7: la otra pulperia no se toca ==='
set role postgres;
select id as ajena from ubicaciones
 where sucursal_id='bbbbbbbb-0000-0000-0000-000000000002' and nombre='Bodega' \gset
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\set ON_ERROR_STOP off
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-000000000001',
       :'ajena'::uuid, 1, :'piso'::uuid);
\echo '--- esperado: esa ubicacion de destino no es de su negocio ---'
\set ON_ERROR_STOP on

\echo ''
\echo '### FIN'
