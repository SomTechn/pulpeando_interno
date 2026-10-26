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

-- El arroz trae 12 por caja
update productos set unidades_empaque = 12
 where id = 'eeeeeeee-0000-0000-0000-000000000001';

\echo '### Arroz 50, caja de 12'


-- ===================================================================
\echo ''
\echo '=== B1: las ubicaciones nacieron con tipo y codigo ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select codigo, nombre, tipo, es_predeterminada
from fn_ubicaciones_detalle('bbbbbbbb-0000-0000-0000-000000000001');

\echo ''
\echo '=== B1b: un exhibidor de piso y una bodega 2 ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_guardar_ubicacion('Exhibidor de la entrada', null,
       'bbbbbbbb-0000-0000-0000-000000000001', 20) ->> 'codigo' as exhibidor;
select fn_guardar_ubicacion('Bodega de arriba', null,
       'bbbbbbbb-0000-0000-0000-000000000001', 210) ->> 'codigo' as bodega2_antes;
set role postgres;
select id as b2 from ubicaciones where nombre='Bodega de arriba' \gset
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_fijar_tipo_ubicacion(:'b2', 'bodega') ->> 'codigo' as bodega2_despues;
\echo '--- esperado: al volverse bodega cambia de P a B ---'

\echo ''
\echo '=== B1c: la predeterminada no puede ser bodega ==='
set role postgres;
select id as pred from ubicaciones
 where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and es_predeterminada \gset
select id as bod1 from ubicaciones
 where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega' \gset
select id as exh from ubicaciones where nombre='Exhibidor de la entrada' \gset
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
\set ON_ERROR_STOP off
select fn_fijar_tipo_ubicacion(:'pred', 'bodega');
\echo '--- esperado: la predeterminada tiene que ser del piso ---'
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_fijar_ubicacion_predeterminada(:'bod1');
\echo '--- esperado: solo una del piso puede ser predeterminada ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== B2: escanear el QR de la ubicacion ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_ubicacion_por_codigo('001-B01') ->> 'nombre' as por_codigo;
select fn_ubicacion_por_codigo('  001-b01 ') ->> 'nombre' as en_minuscula;
select fn_ubicacion_por_codigo('PULP-U:001-B01') ->> 'nombre' as con_prefijo;
\set ON_ERROR_STOP off
select fn_ubicacion_por_codigo('XX-B99');
\echo '--- esperado: no hay ninguna ubicacion con ese codigo ---'
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select fn_ubicacion_por_codigo('001-B01');
\echo '--- esperado: la otra pulperia lee SU 001-B01, no el de aqui ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== B3: acomodar el arroz: 30 a bodega, 5 al exhibidor ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-000000000001',
  :'bod1', 30) is not null as a_bodega;
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-000000000001',
  :'exh', 5) is not null as al_exhibidor;
select ubicacion, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');
\echo '--- esperado: piso 15, exhibidor 5, bodega 30, bodega de arriba 0 ---'


-- ===================================================================
\echo ''
\echo '=== B4: CONTAR EL PISO SIN AUDITAR LA BODEGA ==='
\set ON_ERROR_STOP off
select fn_solicitar_conteo_piso('eeeeeeee-0000-0000-0000-000000000001', 18);
\echo '--- esperado: primero hay que auditar la bodega, y que diga cuales ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== B4b: y el estado lo dice ==='
select jsonb_pretty(fn_estado_bodega()) as estado;


-- ===================================================================
\echo ''
\echo '=== B5: la auxiliar abre la auditoria de la bodega ==='
select fn_abrir_auditoria(:'bod1') as abierta;
set role postgres;
select id as au1 from auditorias where estado='abierta' and ubicacion_id = :'bod1' \gset
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';

\echo ''
\echo '=== B5b: abrirla otra vez devuelve la misma, no crea otra ==='
select fn_abrir_auditoria(:'bod1') -> 'ya_estaba' as ya_estaba;


-- ===================================================================
\echo ''
\echo '=== B6: ESCANEAR SUMA. Primera caja de 12 ==='
select fn_auditar_producto(:'au1', 'eeeeeeee-0000-0000-0000-000000000001', 12);
\echo ''
\echo '=== B6b: segunda caja. Debe decir cuanto llevaba ==='
select fn_auditar_producto(:'au1', 'eeeeeeee-0000-0000-0000-000000000001', 12);
\echo '--- esperado: llevaba 12, agregado 12, total 24, escaneos 2 ---'

\echo ''
\echo '=== B6c: media caja suelta ==='
select fn_auditar_producto(:'au1', 'eeeeeeee-0000-0000-0000-000000000001', 3)
  -> 'total' as total;

\echo ''
\echo '=== B6d: corregir: reemplaza, no suma ==='
select fn_auditar_producto(:'au1', 'eeeeeeee-0000-0000-0000-000000000001', 24, null, true);
\echo '--- esperado: total 24, los escaneos no suben ---'

\echo ''
\echo '=== B6e: como va ==='
select escaneado, producto, contado, sistema, escaneos from fn_auditoria_lineas(:'au1');
select jsonb_pretty(fn_auditoria_resumen(:'au1')) as resumen;


-- ===================================================================
\echo ''
\echo '=== B7: la AUXILIAR no completa ==='
\set ON_ERROR_STOP off
select fn_completar_auditoria(:'au1');
\echo '--- esperado: solo un supervisor ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== B7b: el SUPERVISOR si ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_completar_auditoria(:'au1');

\echo ''
\echo '=== B7c: reescribio la bodega y NO toco el total ==='
select (select coalesce(sum(cantidad),0) from existencias
         where producto_id='eeeeeeee-0000-0000-0000-000000000001'
           and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001') as total;
select ubicacion, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');
\echo '--- esperado: total 50 · bodega 24 · exhibidor 5 · piso 21 (el resto) ---'

\echo ''
\echo '=== B7d: no se vuelve a completar ==='
\set ON_ERROR_STOP off
select fn_completar_auditoria(:'au1');
\echo '--- esperado: ya se cerro ---'

\echo ''
\echo '=== B7e: la predeterminada ni se abre a auditoria ==='
\set ON_ERROR_STOP off
select fn_abrir_auditoria(:'pred');
\echo '--- esperado: su cantidad es el resto, se avisa AL ABRIR ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== B7f: y el piso ya no se cuenta lugar por lugar ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
select fn_solicitar_ajuste('eeeeeeee-0000-0000-0000-000000000001', :'exh', 2);
\echo '--- esperado: el piso se cuenta completo, desde Consultar ---'
select fn_solicitar_ajuste('eeeeeeee-0000-0000-0000-000000000001', :'pred', 2);
\echo '--- esperado: lo mismo ---'
\set ON_ERROR_STOP on
\echo '--- pero una bodega SI se corrige lugar por lugar ---'
select fn_solicitar_ajuste('eeeeeeee-0000-0000-0000-000000000001', :'bod1', 23,
  null, 'Falta una bolsa') ->> 'numero' as ajuste_bodega;
set role postgres;
select id as ajb from ajustes_inventario where estado='pendiente' \gset
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_resolver_ajuste(:'ajb', false, 'Era prueba') ->> 'estado' as rechazado;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';


-- ===================================================================
\echo ''
\echo '=== B8: la bodega de arriba, con algo adentro que nadie escanea ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-000000000001',
  :'b2', 4, :'bod1') is not null as movido;
select ubicacion, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');
\echo '--- bodega 20, bodega de arriba 4 ---'

select fn_abrir_auditoria(:'b2') ->> 'numero' as au2;
set role postgres;
select id as au2 from auditorias where ubicacion_id = :'b2' and estado='abierta' \gset
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
\echo '--- se completa SIN escanear nada, vaciando lo no escaneado ---'
select fn_completar_auditoria(:'au2', true);
select ubicacion, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');
\echo '--- esperado: bodega de arriba 0, y esos 4 pasaron al piso (25) ---'
select (select coalesce(sum(cantidad),0) from existencias
         where producto_id='eeeeeeee-0000-0000-0000-000000000001'
           and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001') as total;
\echo '--- y el total sigue en 50 ---'


-- ===================================================================
\echo ''
\echo '=== B9: el recorte. Escanear mas de lo que hay en toda la sucursal ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_auditoria(:'bod1') ->> 'numero' as au3;
set role postgres;
select id as au3 from auditorias where ubicacion_id = :'bod1' and estado='abierta' \gset
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_auditar_producto(:'au3', 'eeeeeeee-0000-0000-0000-000000000001', 300)
  -> 'total' as escaneado;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_completar_auditoria(:'au3');
\echo '--- esperado: recortados 1 ---'
select ubicacion, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');
\echo '--- esperado: bodega 45 (50 menos los 5 del exhibidor), piso 0 ---'


-- ===================================================================
\echo ''
\echo '=== B10: ahora la bodega esta al dia ==='
select (fn_estado_bodega() ->> 'al_dia')::boolean as al_dia;

\echo ''
\echo '=== B10b: y SI se puede contar el piso ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select ubicacion, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');
\echo '--- el piso son el exhibidor (5) + la predeterminada (0) = 5 ---'
select fn_solicitar_conteo_piso('eeeeeeee-0000-0000-0000-000000000001', 3,
  null, 'Conte la gondola y la punta');

\echo ''
\echo '=== B10c: dos conteos del mismo producto no se encolan ==='
\set ON_ERROR_STOP off
select fn_solicitar_conteo_piso('eeeeeeee-0000-0000-0000-000000000001', 2);
\echo '--- esperado: ya hay un conteo esperando ---'

\echo ''
\echo '=== B10d: ni contar lo que ya dice ==='
set role postgres;
select id as aj1 from ajustes_inventario where estado='pendiente' \gset
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_resolver_ajuste(:'aj1', true);
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_solicitar_conteo_piso('eeeeeeee-0000-0000-0000-000000000001', 3);
\echo '--- esperado: el sistema ya dice 3 en el piso ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== B10e: el ajuste bajo el total y el desglose cuadra ==='
select (select coalesce(sum(cantidad),0) from existencias
         where producto_id='eeeeeeee-0000-0000-0000-000000000001'
           and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001') as total,
       (select coalesce(sum(cantidad),0) from fn_existencia_por_ubicacion(
          'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001')) as desglose;
select ubicacion, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');
\echo '--- esperado: total 48 (50 menos 2), bodega 45, exhibidor 3, piso 0 ---'


-- ===================================================================
\echo ''
\echo '=== B11: cuando la auditoria envejece, se vuelve a cerrar la puerta ==='
set role postgres;
update auditorias set cerrada_en = now() - interval '30 hours' where estado='aplicada';
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select (fn_estado_bodega() ->> 'al_dia')::boolean as al_dia_con_30h;
\set ON_ERROR_STOP off
select fn_solicitar_conteo_piso('eeeeeeee-0000-0000-0000-000000000001', 1);
\echo '--- esperado: vuelve a pedir auditar ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== B12: nada de esto cruza negocios ==='
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
\set ON_ERROR_STOP off
select fn_abrir_auditoria(:'bod1');
\echo '--- esperado: esa ubicacion no es de su negocio ---'
select fn_auditar_producto(:'au3', 'eeeeeeee-0000-0000-0000-000000000001', 5);
\echo '--- esperado: ya se cerro / no es de este negocio ---'
select fn_auditoria_lineas(:'au3');
\echo '--- esperado: no es de este negocio ---'
select fn_solicitar_conteo_piso('eeeeeeee-0000-0000-0000-000000000001', 5);
\echo '--- esperado: ese producto no es de este negocio ---'
select fn_fijar_tipo_ubicacion(:'exh', 'bodega');
\echo '--- esperado: esa ubicacion no es de su negocio ---'
\set ON_ERROR_STOP on
select count(*) as auditorias_ajenas from fn_auditorias();
\echo '--- esperado: 0 ---'

\echo ''
\echo '=== B13: el repartidor no audita ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000009';
\set ON_ERROR_STOP off
select fn_abrir_auditoria(:'bod1');
\echo '--- esperado: no tiene permiso ---'
select fn_ubicacion_por_codigo('001-B01');
\echo '--- esperado: no tiene permiso ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== B14: nadie escribe las tablas a mano ==='
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\set ON_ERROR_STOP off
update auditorias set estado = 'aplicada';
\echo '--- esperado: permiso denegado ---'
update auditoria_detalle set cantidad = 9999;
\echo '--- esperado: permiso denegado ---'
update ubicaciones set tipo = 'piso';
\echo '--- esperado: permiso denegado ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== B15: el historial de auditorias ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select numero, estado, ubicacion, codigo, tipo, escaneados, unidades, abierta_por
from fn_auditorias();

\echo ''
\echo '### FIN'
