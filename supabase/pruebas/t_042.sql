\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- Semilla de t_pedidos: Arroz 5lb (P1) a L 60 en La Esquina, 50 en existencia.
-- Gerente 1 = 1111 (PIN 11111), Auxiliar 1 = 2222 (PIN 22222), Gerente 2 = 9999.
update perfiles set codigo = 'G1' where id = '11111111-1111-1111-1111-111111111111';
update perfiles set codigo = 'A1' where id = '22222222-2222-2222-2222-222222222222';
insert into impuestos (organizacion_id, nombre, tasa, incluido_en_precio, es_predeterminado, activo)
values ('aaaaaaaa-0000-0000-0000-000000000001', 'ISV 15%', 0.15, true, true, true);
insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa)
values ('aaaa0000-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000001','C1','Caja 1', true);

\echo '=================== 1. AUTORIZACIÓN DEL SUPERVISOR ==================='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_autorizar_caja('G1', '00000', 'cancelar') ->> 'ok' as pin_malo;
\echo '--- esperado: false ---'
select fn_autorizar_caja('A1', '22222', 'cancelar') ->> 'ok' as auxiliar_no;
\echo '--- esperado: false (la auxiliar no es supervisor) ---'
select fn_autorizar_caja('G1', '11111', 'cancelar') ->> 'autorizacion_id' as aut \gset
select :'aut' <> '' as dio_permiso;
select fn_eventos_caja(jsonb_build_array(jsonb_build_object(
  'id','f1000000-0000-0000-0000-000000000001','caja_id','aaaa0000-0000-0000-0000-0000000000c1',
  'tipo','abortada','monto',100,'autorizacion_id', :'aut','ocurrido_en', now()))) as uno;
select fn_eventos_caja(jsonb_build_array(jsonb_build_object(
  'id','f1000000-0000-0000-0000-000000000002','caja_id','aaaa0000-0000-0000-0000-0000000000c1',
  'tipo','abortada','monto',100,'autorizacion_id', :'aut','ocurrido_en', now()))) as dos;
set role postgres;
select e.id::text like '%1' as primero, p.nombre as autorizo
  from eventos_caja e left join perfiles p on p.id = e.autorizo order by e.id;
\echo '--- esperado: el primero lo autorizó Gerente 1; el segundo (misma autorización) queda sin autorizar ---'

\echo ''
\echo '=================== 2. VENCIMIENTOS ==================='
insert into lotes (id, organizacion_id, producto_id, sucursal_id, codigo, fecha_vencimiento, costo_ingreso) values
 ('10700000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
  'bbbbbbbb-0000-0000-0000-000000000001','L-VIEJO', current_date - 3, 40),
 ('10700000-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
  'bbbbbbbb-0000-0000-0000-000000000001','L-PRONTO', current_date + 5, 40),
 ('10700000-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
  'bbbbbbbb-0000-0000-0000-000000000001','L-LEJOS', current_date + 200, 40);
insert into existencias (organizacion_id, producto_id, sucursal_id, lote_id, cantidad) values
 ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','10700000-0000-0000-0000-000000000001', 4),
 ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','10700000-0000-0000-0000-000000000002', 6),
 ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','10700000-0000-0000-0000-000000000003', 9);
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select x ->> 'lote' as lote, x ->> 'dias' as dias, x ->> 'cantidad' as cant, x ->> 'valor' as valor
  from jsonb_array_elements(fn_vencimientos() -> 'lotes') x;
\echo '--- esperado: L-VIEJO -3 y L-PRONTO 5; L-LEJOS no (pasa de 60 días); la auxiliar no ve el valor ---'
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select jsonb_array_length(fn_vencimientos() -> 'lotes') as del_otro;
\echo '--- esperado: 0 ---'

\echo ''
\echo '=================== 3. IMPORTAR Y CAMBIAR PRECIOS ==================='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
select fn_importar_productos('[{"nombre":"x"}]');
\echo '--- esperado: Solo el gerente importa el catálogo ---'
\set ON_ERROR_STOP on
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select r ->> 'creados' as creados, r ->> 'actualizados' as act, r ->> 'existencias' as exis,
       jsonb_array_length(r -> 'errores') as errores, r -> 'errores' -> 0 ->> 'mensaje' as error1,
       jsonb_array_length(r -> 'avisos') as avisos
  from fn_importar_productos($j$[
    {"sku":"COC3","nombre":"Coca-Cola 3 L","codigo":"7401000000011","categoria":"Bebidas","marca":"Coca-Cola",
     "proveedor":"Distribuidora del Norte","precio":"75","costo":"58","existencia":"24","impuesto":"15"},
    {"sku":"PEP3","nombre":"Pepsi 3 L","codigo":"7401000000028;7401000000035","categoria":"bebidas","marca":"Pepsi",
     "precio":"70","costo":"52","existencia":"12"},
    {"sku":"MAL","nombre":"Malo","precio":"-4"},
    {"sku":"P1","precio":"62","existencia":"10","costo":"40"},
    {"nombre":"Sin sku ni nada","precio":"10"}
  ]$j$) r;
\echo '--- esperado: 3 creados, 1 actualizado (P1), 2 existencias, 1 error (precio negativo), 1 aviso (P1 ya tenía) ---'
select p.sku, c.nombre as cat, m.nombre as marca, fn_precio_vigente(p.id, 'bbbbbbbb-0000-0000-0000-000000000001', 1) as precio,
       (select sum(cantidad) from existencias e where e.producto_id = p.id) as exis,
       (select count(*) from producto_codigos pc where pc.producto_id = p.id) as codigos
  from productos p left join categorias c on c.id = p.categoria_id left join marcas m on m.id = p.marca_id
 where p.organizacion_id = 'aaaaaaaa-0000-0000-0000-000000000001' order by p.sku;
\echo '--- esperado: una sola categoría Bebidas (no Bebidas y bebidas), P1 a 62, COC3 24 u, PEP3 2 códigos ---'
select count(*) as categorias_bebidas from categorias where lower(nombre) = 'bebidas';
\echo '--- esperado: 1 ---'
select fn_importar_productos('[{"sku":"COC3","precio":"80"}]', null, false) ->> 'omitidos' as sin_actualizar;
\echo '--- esperado: 1 (con actualizar=false no toca lo que ya existe) ---'

select r ->> 'productos' as n, r -> 'lista' -> 0 ->> 'nombre' as prod, r -> 'lista' -> 0 ->> 'actual' as antes,
       r -> 'lista' -> 0 ->> 'nuevo' as nuevo
  from fn_cambiar_precios(jsonb_build_object('categoria_id', (select id from categorias where nombre = 'Bebidas')),
                          'porcentaje', 10, 0.5, false) r;
\echo '--- esperado: 2 productos; Coca 75 -> 82.50; no aplicado ---'
select fn_precio_vigente((select id from productos where sku = 'COC3'), 'bbbbbbbb-0000-0000-0000-000000000001', 1) as sigue;
\echo '--- esperado: 75 (era solo la vista previa) ---'
select (fn_cambiar_precios(jsonb_build_object('categoria_id', (select id from categorias where nombre = 'Bebidas')),
                           'margen', 25, 1, true)) -> 'lista' -> 0 ->> 'nuevo' as con_margen;
\echo '--- esperado: Coca: costo 58 / 0.75 = 77.33 x 1.15 = 88.93 -> redondeado arriba a 89 ---'
\set ON_ERROR_STOP off
select fn_cambiar_precios('{}', 'porcentaje', 10, 0, true);
\echo '--- esperado: Escoja a qué productos ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=================== 4. PROMOCIONES ==================='
-- precios simples para que las cuentas se vean
set role postgres;
update precios set precio = 50 where producto_id = (select id from productos where sku = 'COC3') and not es_oferta;
update precios set precio = 40 where producto_id = (select id from productos where sku = 'PEP3') and not es_oferta;
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
select fn_guardar_promocion('{"nombre":"x","tipo":"nxm","lleva":2,"paga":1,"alcance":"marca"}');
\echo '--- esperado: Las promociones las pone el gerente ---'
\set ON_ERROR_STOP on
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

select fn_guardar_promocion(jsonb_build_object('nombre','2x1 Coca','tipo','nxm','lleva',2,'paga',1,
  'alcance','productos','producto_ids', jsonb_build_array((select id from productos where sku='COC3')))) is not null as p1;
select r -> 'descuentos' as desc, r -> 'aplicadas' -> 0 ->> 'descuento' as total
  from fn_calcular_promos(jsonb_build_array(
    jsonb_build_object('producto_id', (select id from productos where sku='COC3'), 'cantidad', 5))) r;
\echo '--- esperado: [100.0] (5 cocas: 2 grupos de 2 -> 2 gratis) ---'

set role postgres; update promociones set activa = false; set role authenticated;
select fn_guardar_promocion(jsonb_build_object('nombre','3 refrescos por 120','tipo','paquete','lleva',3,'precio_paquete',120,
  'alcance','categoria','categoria_id', (select id from categorias where nombre='Bebidas'))) is not null as p2;
select r -> 'descuentos' as desc
  from fn_calcular_promos(jsonb_build_array(
    jsonb_build_object('producto_id', (select id from productos where sku='COC3'), 'cantidad', 2),
    jsonb_build_object('producto_id', (select id from productos where sku='PEP3'), 'cantidad', 2))) r;
\echo '--- esperado: grupo = 50,50,40 = 140 -> 20 de descuento: coca 7.14+7.14, pepsi 5.72; la 2a pepsi sin promo ---'

set role postgres; update promociones set activa = false; set role authenticated;
select fn_guardar_promocion(jsonb_build_object('nombre','Pepsi -12.5%','tipo','porcentaje','porcentaje',12.5,
  'alcance','marca','marca_id', (select id from marcas where nombre='Pepsi'))) is not null as p3;
select r -> 'descuentos' as desc
  from fn_calcular_promos(jsonb_build_array(
    jsonb_build_object('producto_id', (select id from productos where sku='PEP3'), 'cantidad', 1.5))) r;
\echo '--- esperado: [7.5] (1.5 x 40 x 12.5%) ---'

\echo ''
\echo '--- Una venta de verdad con la promo: el servidor pone el descuento, no la caja ---'
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000c1','22222222-2222-2222-2222-222222222222','22222', 0) as t \gset
select fn_desbloquear_caja(:'t'::uuid,'22222') as d \gset
select r ->> 'total' as total, r ->> 'descuento' as descuento, r -> 'promociones' -> 0 ->> 'nombre' as promo
  from fn_registrar_venta(:'d'::uuid,
    jsonb_build_array(jsonb_build_object('producto_id', (select id from productos where sku='PEP3'),
                                         'cantidad', 2, 'descuento', 999)),
    '[{"metodo":"efectivo","monto":70,"recibido":70}]'::jsonb, null) r;
\echo '--- esperado: total 70.00 (80 - 10), descuento 10.00, Pepsi -12.5%. El 999 de la caja no se tomó ---'
set role postgres;
select descuento, total, promociones -> 0 ->> 'nombre' as promo from venta_detalle
 where producto_id = (select id from productos where sku='PEP3');
\echo '--- esperado: 10.0000 | 70 | Pepsi -12.5% ---'

\echo ''
\echo '--- La de los martes no vale otro día ---'
update promociones set activa = false;
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_guardar_promocion(jsonb_build_object('nombre','Solo hoy no','tipo','porcentaje','porcentaje',50,
  'alcance','marca','marca_id', (select id from marcas where nombre='Pepsi'),
  'dias_semana', jsonb_build_array(((extract(dow from current_date)::int + 1) % 7)))) is not null as p4;
select jsonb_array_length(fn_promociones_activas()) as activas_hoy;
\echo '--- esperado: 0 ---'
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select jsonb_array_length(fn_promociones()) as del_otro;
\echo '--- esperado: 0 ---'
