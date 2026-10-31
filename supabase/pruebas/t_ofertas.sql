\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- Semilla de t_pedidos: Arroz 5lb (P1) a L 60 en La Esquina (sucursal ...001).
-- Gerente 1 = 1111, Auxiliar 1 = 2222, Gerente 2 (otro negocio) = 9999.
insert into producto_codigos (organizacion_id, producto_id, codigo, es_principal)
values ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        '7401234567896', true);
-- mayoreo: desde 6, a L 52
insert into precios (organizacion_id, producto_id, sucursal_id, nivel, cantidad_minima, precio, vigente_desde)
values ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000001','detalle', 6, 52, now()-interval '1 day');

\echo '=== O1: sin oferta, el precio es el de siempre ==='
select fn_precio_vigente('eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',1) as uno,
       fn_precio_vigente('eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',6) as seis;
\echo '--- esperado: 60 y 52 ---'

\echo ''
\echo '=== O2: el auxiliar no pone ofertas ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\set ON_ERROR_STOP off
select fn_fijar_oferta('eeeeeeee-0000-0000-0000-000000000001', 49, current_date + 7);
\echo '--- esperado: Solo el gerente pone ofertas ---'

\echo ''
\echo '=== O3: el gerente de otro negocio tampoco ==='
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select fn_fijar_oferta('eeeeeeee-0000-0000-0000-000000000001', 49, current_date + 7);
\echo '--- esperado: Ese producto no es de su negocio ---'

\echo ''
\echo '=== O4: fechas y precio malos ==='
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_fijar_oferta('eeeeeeee-0000-0000-0000-000000000001', 0, current_date + 7);
\echo '--- esperado: mayor que cero ---'
select fn_fijar_oferta('eeeeeeee-0000-0000-0000-000000000001', 49, current_date - 1);
\echo '--- esperado: ya pasó (o termina antes de empezar) ---'
set role postgres;
\set ON_ERROR_STOP off
insert into precios (organizacion_id, producto_id, precio, es_oferta)
values ('aaaaaaaa-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001', 10, true);
\echo '--- esperado: viola ck_precio_oferta_con_fin ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== O5: el gerente pone L 49 por una semana ==='
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_fijar_oferta('eeeeeeee-0000-0000-0000-000000000001', 49, current_date + 7) is not null as puso;
select fn_precio_vigente('eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',1) as uno,
       fn_precio_vigente('eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',6) as seis,
       fn_precio_vigente('eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',1,'mayoreo') as nivel_mayoreo;
\echo '--- esperado: 49, 49, 49 (la oferta es mas barata que todo) ---'

\echo ''
\echo '=== O6: la caja lo ve en su catalogo ==='
select precio from v_pos_catalogo
 where producto_id = 'eeeeeeee-0000-0000-0000-000000000001'
   and sucursal_id = 'bbbbbbbb-0000-0000-0000-000000000001';
\echo '--- esperado: 49 ---'

\echo ''
\echo '=== O7: la etiqueta trae antes y ahora ==='
select e ->> 'precio' as precio, e ->> 'precio_regular' as antes,
       e -> 'oferta' ->> 'precio' as oferta, (e -> 'oferta' ->> 'hasta')::date - current_date as dias,
       e ->> 'codigo' as codigo, e ->> 'sku' as item, jsonb_array_length(e -> 'ofertas') as n,
       e ->> 'puede_ofertar' as puede
  from fn_etiqueta_producto('eeeeeeee-0000-0000-0000-000000000001') e;
\echo '--- esperado: 49 | 60 | 49 | 7 | 7401234567896 | P1 | 1 | true ---'

\echo ''
\echo '=== O8: una oferta MAS CARA no sube el precio ==='
select fn_fijar_oferta('eeeeeeee-0000-0000-0000-000000000001', 55, current_date + 3) is not null as puso;
select fn_precio_vigente('eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',1) as uno,
       fn_precio_vigente('eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',6) as seis;
\echo '--- esperado: 55 y 52. La nueva reemplazo a la de 49; a 6 sigue el mayoreo ---'
set role postgres;
select count(*) filter (where vigente_hasta >= current_date) as vivas,
       count(*) as total
  from precios where producto_id = 'eeeeeeee-0000-0000-0000-000000000001' and es_oferta;
\echo '--- esperado: 1 viva de 2. La de 49 termino ayer ---'

\echo ''
\echo '=== O9: el auxiliar ve la etiqueta pero no puede ofertar ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select e ->> 'precio' as precio, e -> 'oferta' ->> 'precio' as oferta, e ->> 'puede_ofertar' as puede
  from fn_etiqueta_producto('eeeeeeee-0000-0000-0000-000000000001') e;
\echo '--- esperado: 55 | 55 | false ---'
\set ON_ERROR_STOP off
select fn_quitar_oferta((select id from precios where es_oferta and vigente_hasta >= current_date limit 1));
\echo '--- esperado: Solo el gerente quita ofertas ---'

\echo ''
\echo '=== O10: el otro negocio no ve la etiqueta ==='
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
select fn_etiqueta_producto('eeeeeeee-0000-0000-0000-000000000001');
\echo '--- esperado: Ese producto no es de su negocio ---'
\set ON_ERROR_STOP on

\echo ''
\echo '=== O11: el gerente la quita y vuelve el precio de siempre ==='
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select fn_quitar_oferta((e -> 'oferta' ->> 'id')::uuid) as quito
  from fn_etiqueta_producto('eeeeeeee-0000-0000-0000-000000000001') e;
select e ->> 'precio' as precio, e -> 'oferta' as oferta, jsonb_array_length(e -> 'ofertas') as n
  from fn_etiqueta_producto('eeeeeeee-0000-0000-0000-000000000001') e;
\echo '--- esperado: t, luego 60 | (null) | 0 ---'

\echo ''
\echo '=== O12: una oferta que empieza manana no cuenta hoy, pero se lista ==='
select fn_fijar_oferta('eeeeeeee-0000-0000-0000-000000000001', 45, current_date + 5, current_date + 1) is not null as puso;
select e ->> 'precio' as precio, e -> 'oferta' as oferta, jsonb_array_length(e -> 'ofertas') as n
  from fn_etiqueta_producto('eeeeeeee-0000-0000-0000-000000000001') e;
\echo '--- esperado: 60 | (null) | 1 ---'
