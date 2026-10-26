\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- Sobre la semilla de t_pedidos (org 1 = La Esquina, sucursal bbbb...001).
insert into auth.users (id, email) values
  ('bbbb0000-0000-0000-0000-000000000001','sup1@t.hn');
insert into perfiles (id, organizacion_id, nombre, email, rol, pin_pos, activo)
values ('bbbb0000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
        'Supervisor','sup1@t.hn','supervisor', crypt('77777', gen_salt('bf')), true);
insert into usuario_sucursales (perfil_id, sucursal_id)
values ('bbbb0000-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001');

insert into cajas (id, organizacion_id, sucursal_id, codigo, nombre, activa)
values ('aaaa0000-0000-0000-0000-0000000000c1','aaaaaaaa-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000001','C1','Caja 1', true);

-- Un segundo producto, y uno con lote y vencimiento
insert into productos (id, organizacion_id, sku, nombre, categoria_id, tipo,
                       unidad_base, activo, se_vende, controla_lote, controla_vencimiento)
values
 ('eeeeeeee-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001',
  'P2','Azucar 2lb','dddddddd-0000-0000-0000-000000000001','unidad','unidad',true,true,false,false),
 ('eeeeeeee-0000-0000-0000-00000000000b','aaaaaaaa-0000-0000-0000-000000000001',
  'P3','Leche litro','dddddddd-0000-0000-0000-000000000001','unidad','unidad',true,true,true,true),
 ('eeeeeeee-0000-0000-0000-00000000000c','aaaaaaaa-0000-0000-0000-000000000001',
  'P4','Jabon','dddddddd-0000-0000-0000-000000000001','unidad','unidad',true,true,false,false);

insert into precios (organizacion_id, producto_id, sucursal_id, nivel, cantidad_minima, precio, vigente_desde)
values
 ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-00000000000a','bbbbbbbb-0000-0000-0000-000000000001','detalle',1,25, now()-interval '1 day'),
 ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001','detalle',1,38, now()-interval '1 day'),
 ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-00000000000c','bbbbbbbb-0000-0000-0000-000000000001','detalle',1,18, now()-interval '1 day');

-- Dos lotes de leche
insert into lotes (id, organizacion_id, producto_id, sucursal_id, codigo,
                   fecha_vencimiento, costo_ingreso)
values ('11110000-0000-0000-0000-00000000000a','aaaaaaaa-0000-0000-0000-000000000001',
        'eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001',
        'L-ENE', current_date + 10, 25),
       ('11110000-0000-0000-0000-00000000000b','aaaaaaaa-0000-0000-0000-000000000001',
        'eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001',
        'L-FEB', current_date + 40, 25);

insert into existencias (organizacion_id, producto_id, sucursal_id, lote_id, cantidad) values
 ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-00000000000a','bbbbbbbb-0000-0000-0000-000000000001', null, 20),
 ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001','11110000-0000-0000-0000-00000000000a', 6),
 ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001','11110000-0000-0000-0000-00000000000b', 12);
-- Jabon: el sistema cree que hay CERO (ni fila de existencias)

insert into producto_costos (organizacion_id, producto_id, sucursal_id, cantidad, valor, costo_promedio, ultimo_costo) values
 ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-00000000000a','bbbbbbbb-0000-0000-0000-000000000001',20,300,15,15),
 ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-00000000000b','bbbbbbbb-0000-0000-0000-000000000001',18,450,25,25),
 ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-00000000000c','bbbbbbbb-0000-0000-0000-000000000001',0,0,12,12);

\echo '### Arroz 50 · Azucar 20 · Leche 6+12 en dos lotes · Jabon 0 (sin fila)'

-- ===================================================================
\echo ''
\echo '=== C1: la AUXILIAR no puede abrir un conteo ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
select fn_abrir_conteo();
\set ON_ERROR_STOP on

\echo ''
\echo '=== C2: el SUPERVISOR lo abre ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_abrir_conteo('bbbbbbbb-0000-0000-0000-000000000001','general',null,null,
                       'Conteo del lunes') as abierto \gset
\echo :abierto
select (:'abierto'::jsonb->>'conteo_id') as cid \gset

\echo ''
\echo '-- las lineas precargadas: una por producto y lote, incluido el jabon en cero'
select producto, lote, vence, contada, sistema from fn_conteo_lineas(:'cid'::uuid)
order by producto, lote nulls first;

\echo ''
\echo '=== C3: no se puede abrir un segundo conteo en la misma sucursal ==='
\set ON_ERROR_STOP off
select fn_abrir_conteo('bbbbbbbb-0000-0000-0000-000000000001');
\set ON_ERROR_STOP on

\echo ''
\echo '=== C4: la AUXILIAR cuenta, y es CIEGO: no ve el sistema ni la diferencia ==='
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_contar(:'cid'::uuid,'eeeeeeee-0000-0000-0000-000000000001', 48) as arroz;
\echo '-- y en la lista tampoco ve sistema ni diferencia:'
select producto, contada, sistema, diferencia from fn_conteo_lineas(:'cid'::uuid)
where contada is not null;

\echo ''
\echo '=== C5: el SUPERVISOR si ve la diferencia ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select producto, contada, sistema, diferencia, valor_dif
from fn_conteo_lineas(:'cid'::uuid) where contada is not null;

\echo ''
\echo '=== C6: se cuenta el resto. Azucar 23 (sobran 3), leche por lote, jabon 4 ==='
select fn_contar(:'cid'::uuid,'eeeeeeee-0000-0000-0000-00000000000a', 23) as azucar;
select fn_contar(:'cid'::uuid,'eeeeeeee-0000-0000-0000-00000000000b', 5,
                 '11110000-0000-0000-0000-00000000000a') as leche_ene;
select fn_contar(:'cid'::uuid,'eeeeeeee-0000-0000-0000-00000000000b', 12,
                 '11110000-0000-0000-0000-00000000000b') as leche_feb;
select fn_contar(:'cid'::uuid,'eeeeeeee-0000-0000-0000-00000000000c', 4,
                 null, 'estaban en la bodega') as jabon;

\echo ''
\echo '-- como va:'
select jsonb_pretty(fn_conteo_resumen(:'cid'::uuid));

\echo ''
\echo '=== C7: EL CASO QUE IMPORTA. Se vende DESPUES de contar y ANTES de aplicar ==='
\echo '-- se contaron 48 arroces; ahora se venden 2 mas. El sistema queda en 48.'
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select fn_abrir_turno('aaaa0000-0000-0000-0000-0000000000c1','22222222-2222-2222-2222-222222222222','22222',0) as tt \gset
select fn_desbloquear_caja(:'tt'::uuid,'22222') as dd \gset
select (fn_registrar_venta(:'dd'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":2}]'::jsonb,
  '[{"metodo":"efectivo","monto":120.00,"recibido":120.00}]'::jsonb))->>'numero' as venta;
reset role;
select 'existencia de arroz tras la venta' as que, cantidad from existencias
 where producto_id='eeeeeeee-0000-0000-0000-000000000001' and lote_id is null
   and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001';

\echo ''
\echo '=== C8: el SUPERVISOR no puede aplicar; es del gerente ==='
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
\set ON_ERROR_STOP off
select fn_aplicar_conteo(:'cid'::uuid);
\set ON_ERROR_STOP on

\echo ''
\echo '=== C9: el GERENTE lo aplica ==='
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select jsonb_pretty(fn_aplicar_conteo(:'cid'::uuid));

\echo ''
\echo '--- EXISTENCIAS DESPUES DE APLICAR ---'
\echo '    arroz: sistema decia 50, se contaron 48 (faltaban 2), despues se'
\echo '    vendieron 2. Debe quedar en 46, NO en 48: la venta no se borra.'
reset role;
select pr.nombre, lo.codigo as lote, e.cantidad
from existencias e join productos pr on pr.id = e.producto_id
left join lotes lo on lo.id = e.lote_id
where e.sucursal_id='bbbbbbbb-0000-0000-0000-000000000001'
order by pr.nombre, lo.codigo nulls first;

\echo ''
\echo '--- el kardex del ajuste ---'
select pr.nombre, k.tipo, k.cantidad, k.costo_unitario, k.notas
from kardex k join productos pr on pr.id = k.producto_id
where k.documento_tipo = 'conteo' order by pr.nombre;

\echo ''
\echo '=== C10: un conteo aplicado ya no se toca ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\set ON_ERROR_STOP off
select fn_aplicar_conteo(:'cid'::uuid);
select fn_contar(:'cid'::uuid,'eeeeeeee-0000-0000-0000-000000000001', 99);
select fn_cancelar_conteo(:'cid'::uuid, 'ya no');
\set ON_ERROR_STOP on

\echo ''
\echo '=== C11: ahora si se puede abrir otro ==='
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select (fn_abrir_conteo('bbbbbbbb-0000-0000-0000-000000000001','categoria',
        'dddddddd-0000-0000-0000-000000000001')) as c2 \gset
select (:'c2'::jsonb->>'conteo_id') as cid2 \gset
\echo :c2

\echo ''
\echo '-- aplicar sin haber contado nada:'
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\set ON_ERROR_STOP off
select fn_aplicar_conteo(:'cid2'::uuid);
\echo '-- cancelar sin motivo:'
select fn_cancelar_conteo(:'cid2'::uuid, '  ');
\set ON_ERROR_STOP on
\echo '-- cancelar con motivo:'
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select fn_cancelar_conteo(:'cid2'::uuid, 'me equivoque de alcance') as cancelado;
reset role;
select numero, estado, motivo_cancelacion from conteos order by abierto_en;

\echo ''
\echo '=== C12: cantidad negativa, y producto de otro negocio ==='
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select (fn_abrir_conteo('bbbbbbbb-0000-0000-0000-000000000001')) as c3 \gset
select (:'c3'::jsonb->>'conteo_id') as cid3 \gset
\set ON_ERROR_STOP off
select fn_contar(:'cid3'::uuid,'eeeeeeee-0000-0000-0000-000000000001', -5);
\echo '-- producto de la pulperia rival:'
select fn_contar(:'cid3'::uuid,'eeeeeeee-0000-0000-0000-000000000002', 10);
\set ON_ERROR_STOP on

\echo ''
\echo '=== C13: el negocio RIVAL no ve ni toca este conteo ==='
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
\set ON_ERROR_STOP off
select count(*) as conteos_que_ve from fn_conteos();
select count(*) as lineas_que_ve from fn_conteo_lineas(:'cid3'::uuid);
select fn_conteo_resumen(:'cid3'::uuid);
select fn_contar(:'cid3'::uuid,'eeeeeeee-0000-0000-0000-000000000001', 1);
select fn_aplicar_conteo(:'cid3'::uuid);
select fn_cancelar_conteo(:'cid3'::uuid, 'ajeno');
\set ON_ERROR_STOP on

\echo ''
\echo '=== C14: anon no alcanza nada ==='
reset role;
set role anon;
reset request.jwt.claim.sub;
\set ON_ERROR_STOP off
select fn_abrir_conteo();
select count(*) from fn_conteos();
select count(*) from conteos;
\set ON_ERROR_STOP on
reset role;
\echo '### FIN CONTEO'

\echo ''
\echo '=== C15: se vende casi todo entre contar y aplicar ==='
set role postgres;
-- conteo nuevo sobre el arroz, que quedo en 46
delete from conteos where estado = 'abierto';
set role authenticated;
set request.jwt.claim.sub = 'bbbb0000-0000-0000-0000-000000000001';
select (fn_abrir_conteo('bbbbbbbb-0000-0000-0000-000000000001')) as c4 \gset
select (:'c4'::jsonb->>'conteo_id') as cid4 \gset
\echo '-- se cuentan 40 (faltan 6)'
select (fn_contar(:'cid4'::uuid,'eeeeeeee-0000-0000-0000-000000000001', 40))->>'diferencia' as dif;
\echo '-- y despues se venden 44, dejando 2 en existencia'
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
-- el turno de C7 sigue abierto; se reusa
select id as t5 from turnos_caja where estado='abierto'
  and caja_id='aaaa0000-0000-0000-0000-0000000000c1' \gset
select fn_desbloquear_caja(:'t5'::uuid,'22222') as d5 \gset
select (fn_registrar_venta(:'d5'::uuid,
  '[{"producto_id":"eeeeeeee-0000-0000-0000-000000000001","cantidad":44}]'::jsonb,
  '[{"metodo":"efectivo","monto":2640.00,"recibido":2640.00}]'::jsonb))->>'numero' as venta;
reset role;
select 'existencia de arroz' as que, cantidad from existencias
 where producto_id='eeeeeeee-0000-0000-0000-000000000001' and lote_id is null
   and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001';
\echo '-- aplicar deberia explicar que hacer, no decir "stock insuficiente":'
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\set ON_ERROR_STOP off
select fn_aplicar_conteo(:'cid4'::uuid);
\set ON_ERROR_STOP on
reset role;
select 'el conteo sigue abierto' as que, estado from conteos where id = :'cid4'::uuid;
select 'y la existencia no se movio' as que, cantidad from existencias
 where producto_id='eeeeeeee-0000-0000-0000-000000000001' and lote_id is null
   and sucursal_id='bbbbbbbb-0000-0000-0000-000000000001';
\echo '### FIN C15'
