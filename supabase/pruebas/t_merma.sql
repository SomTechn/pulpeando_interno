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

-- Arroz 50 al costo 40. Bodega 30, piso 20.
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_mover_entre_ubicaciones('eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega'), 30) is not null as ok;

\echo '### Arroz 50 al costo 40 · piso 20 · bodega 30'


-- ===================================================================
\echo ''
\echo '=== M1: cada negocio nacio con su catalogo de causas ==='
select nombre, clase, orden from fn_causas_merma();
\echo '--- esperado: siete de daño y una desconocida ---'

\echo ''
\echo '=== M1b: y la otra pulperia tiene las suyas, no las de aqui ==='
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select count(*) as causas_de_dona_chus from fn_causas_merma();
set role postgres;
select count(distinct organizacion_id) as negocios_con_causas from causas_merma;
set role authenticated;


-- ===================================================================
\echo ''
\echo '=== M2: la AUXILIAR registra una merma por vencimiento ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_registrar_merma('eeeeeeee-0000-0000-0000-000000000001', 3,
  (select causa_id from fn_causas_merma() where nombre = 'Vencimiento'),
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega'),
  null, 'Tres bolsas rotas en el fondo');

\echo ''
\echo '=== M2b: el inventario NO se movio ==='
select (select coalesce(sum(cantidad),0) from existencias
         where producto_id='eeeeeeee-0000-0000-0000-000000000001'
           and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001') as total;
\echo '--- esperado: 50 ---'

\echo ''
\echo '=== M2c: la auxiliar no ve cuanto vale ==='
select numero, estado, clase, causa, producto, cantidad, valor, solicitado_por
from fn_mermas('pendiente');

\echo ''
\echo '=== M2d: el supervisor si ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select numero, clase, causa, cantidad, valor from fn_mermas('pendiente');
\echo '--- esperado: 3 al costo 40 = 120 ---'


-- ===================================================================
\echo ''
\echo '=== M3: ni la auxiliar ni el supervisor la aprueban ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
set role postgres;
select id as me1 from mermas where estado='pendiente' \gset
set role authenticated;
\set ON_ERROR_STOP off
select fn_resolver_merma(:'me1', true);
\echo '--- esperado: solo el gerente ---'
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_resolver_merma(:'me1', true);
\echo '--- esperado: solo el gerente ---'
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select fn_resolver_merma(:'me1', true);
\echo '--- esperado: solo el gerente de ESTE negocio ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== M4: el GERENTE la aprueba ==='
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_resolver_merma(:'me1', true);

\echo ''
\echo '=== M4b: bajo del total Y de la bodega, el piso intacto ==='
select (select coalesce(sum(cantidad),0) from existencias
         where producto_id='eeeeeeee-0000-0000-0000-000000000001'
           and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001') as total;
select ubicacion, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');
\echo '--- esperado: total 47 · piso 20 · bodega 27 ---'

\echo ''
\echo '=== M4c: quedo en el kardex con la causa ==='
set role postgres;
select tipo, cantidad, documento_tipo, notas from kardex
 where producto_id='eeeeeeee-0000-0000-0000-000000000001' and documento_tipo='merma';
set role authenticated;

\echo ''
\echo '=== M4d: y no se puede volver a resolver ==='
\set ON_ERROR_STOP off
select fn_resolver_merma(:'me1', true);
\echo '--- esperado: ya se habia aprobado ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== M5: no se puede mermar mas de lo que hay en el lugar ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
select fn_registrar_merma('eeeeeeee-0000-0000-0000-000000000001', 99,
  (select causa_id from fn_causas_merma() where nombre = 'Vencimiento'),
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega'));
\echo '--- esperado: en Bodega el sistema solo tiene 27 ---'

\echo ''
\echo '=== M5b: ni cantidad cero o negativa ==='
select fn_registrar_merma('eeeeeeee-0000-0000-0000-000000000001', 0,
  (select causa_id from fn_causas_merma() where nombre = 'Vencimiento'));
select fn_registrar_merma('eeeeeeee-0000-0000-0000-000000000001', -2,
  (select causa_id from fn_causas_merma() where nombre = 'Vencimiento'));
\echo '--- esperado: mayor a cero, las dos veces ---'

\echo ''
\echo '=== M5c: ni con una causa de otro negocio ==='
set role postgres;
select id as causa_ajena from causas_merma
 where organizacion_id='aaaaaaaa-0000-0000-0000-000000000002' limit 1 \gset
set role authenticated;
select fn_registrar_merma('eeeeeeee-0000-0000-0000-000000000001', 1, :'causa_ajena');
\echo '--- esperado: esa causa no es de su negocio ---'

\echo ''
\echo '=== M5d: ni el repartidor ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000009';
select fn_registrar_merma('eeeeeeee-0000-0000-0000-000000000001', 1,
  (select causa_id from fn_causas_merma() limit 1));
\echo '--- esperado: no tiene permiso ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== M6: rechazar exige motivo y no mueve nada ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_registrar_merma('eeeeeeee-0000-0000-0000-000000000001', 5,
  (select causa_id from fn_causas_merma() where nombre = 'Quiebra o derrame'),
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Piso de ventas'))
  ->> 'numero' as pedida;
set role postgres;
select id as me2 from mermas where estado='pendiente' \gset
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\set ON_ERROR_STOP off
select fn_resolver_merma(:'me2', false);
\echo '--- esperado: exige decir por que ---'
\set ON_ERROR_STOP on
select fn_resolver_merma(:'me2', false, 'Eso no se quebro, lo vi completo');
select (select coalesce(sum(cantidad),0) from existencias
         where producto_id='eeeeeeee-0000-0000-0000-000000000001'
           and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001') as total;
\echo '--- esperado: sigue en 47 ---'


-- ===================================================================
\echo ''
\echo '=== M7: la merma "no se sabe" cae en el otro balde ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_registrar_merma('eeeeeeee-0000-0000-0000-000000000001', 2,
  (select causa_id from fn_causas_merma() where clase = 'desconocida'),
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Piso de ventas'),
  null, 'Faltan dos y nadie sabe') -> 'clase' as clase;
set role postgres;
select id as me3 from mermas where estado='pendiente' \gset
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_resolver_merma(:'me3', true) ->> 'numero' as aprobada;


-- ===================================================================
\echo ''
\echo '=== M8: y un conteo aplicado a la baja tambien ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_solicitar_ajuste('eeeeeeee-0000-0000-0000-000000000001',
  (select id from ubicaciones where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega'),
  23, null, 'Conte la bodega') ->> 'numero' as conteo;
set role postgres;
select id as aj1 from ajustes_inventario where estado='pendiente' \gset
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_resolver_ajuste(:'aj1', true) ->> 'diferencia' as dif;
\echo '--- bodega de 27 a 23: -4 que nadie explico ---'

\echo ''
\echo '=== M8b: un conteo de PISO a la alza es sobrante ==='
\echo '--- para contar el piso hay que auditar la bodega primero ---'
set role postgres;
select id as bod from ubicaciones
 where sucursal_id='bbbbbbbb-0000-0000-0000-000000000001' and nombre='Bodega' \gset
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_auditoria(:'bod') ->> 'numero' as auditoria;
set role postgres;
select id as audx from auditorias where ubicacion_id = :'bod' and estado='abierta' \gset
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_auditar_producto(:'audx', 'eeeeeeee-0000-0000-0000-000000000001', 23)
  -> 'total' as escaneado;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_completar_auditoria(:'audx') ->> 'numero' as completada;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_solicitar_conteo_piso('eeeeeeee-0000-0000-0000-000000000001',
  (select coalesce(sum(cantidad),0) + 1 from fn_existencia_por_ubicacion(
     'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001')
   where es_predeterminada or ubicacion = 'Piso de ventas'),
  null, 'Habia una mas') ->> 'numero' as conteo2;
set role postgres;
select id as aj2 from ajustes_inventario where estado='pendiente' \gset
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_resolver_ajuste(:'aj2', true) ->> 'diferencia' as dif2;


-- ===================================================================
\echo ''
\echo '=== M9: EL RESUMEN. Las dos mermas por separado ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select jsonb_pretty(fn_merma_resumen()) as resumen;
\echo ''
\echo '--- cuentas esperadas, todo al costo 40 ---'
\echo '---   daño:        3 de vencimiento = L 120'
\echo '---   desconocida: 2 "no se sabe" + 4 del conteo = 6 = L 240'
\echo '---   sobrante:    1 del conteo a la alza = L 40'
\echo '---   neta:        240 - 40 = L 200'
\echo '---   total:       120 + 200 = L 320'

\echo ''
\echo '=== M9b: la AUXILIAR no ve el resumen ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
select fn_merma_resumen();
\echo '--- esperado: es para supervisor en adelante ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== M9c: la otra pulperia ve su propio resumen, vacio ==='
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select (fn_merma_resumen() ->> 'total')::numeric as total_ajeno,
       (fn_merma_resumen() -> 'desconocida' ->> 'valor')::numeric as desc_ajeno;
\echo '--- esperado: 0 y 0 ---'


-- ===================================================================
\echo ''
\echo '=== M10: el catalogo solo lo toca el gerente ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
\set ON_ERROR_STOP off
select fn_guardar_causa_merma('Robo en sala', 'desconocida');
\echo '--- esperado: solo el gerente ---'
\set ON_ERROR_STOP on
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_guardar_causa_merma('Robo en sala', 'desconocida') ->> 'nombre' as creada;

\echo ''
\echo '=== M10b: la clase NO se cambia despues ==='
set role postgres;
select id as c_robo from causas_merma where nombre='Robo en sala' \gset
set role authenticated;
select fn_guardar_causa_merma('Robo en sala', 'dano', :'c_robo') is not null as guardada;
set role postgres;
select nombre, clase from causas_merma where id = :'c_robo';
\echo '--- esperado: sigue siendo desconocida ---'
set role authenticated;

\echo ''
\echo '=== M10c: el gerente de la otra pulperia no toca estas causas ==='
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
\set ON_ERROR_STOP off
select fn_guardar_causa_merma('Mia ahora', 'dano', :'c_robo');
\echo '--- esperado: esa causa no es de su negocio ---'
\set ON_ERROR_STOP on


-- ===================================================================
\echo ''
\echo '=== M11: nadie escribe las tablas a mano ==='
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\set ON_ERROR_STOP off
update mermas set estado = 'aprobado';
\echo '--- esperado: permiso denegado ---'
update causas_merma set clase = 'dano';
\echo '--- esperado: permiso denegado ---'
insert into mermas (organizacion_id, sucursal_id, numero, producto_id, causa_id,
                    clase, cantidad)
values ('aaaaaaaa-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',
        'A-MANO','eeeeeeee-0000-0000-0000-000000000001',
        (select id from causas_merma limit 1),'dano',999);
\echo '--- esperado: permiso denegado ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== M12: el desglose sigue cuadrando despues de todo ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select
 (select coalesce(sum(cantidad),0) from existencias
   where producto_id='eeeeeeee-0000-0000-0000-000000000001'
     and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001') as total,
 (select coalesce(sum(cantidad),0) from fn_existencia_por_ubicacion(
    'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001')) as desglose;
select ubicacion, cantidad from fn_existencia_por_ubicacion(
  'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');

\echo ''
\echo '### FIN'
