\set ON_ERROR_STOP on
\pset pager off
set role postgres;

-- Tres ventas puestas a mano con horas elegidas a proposito.
-- El servidor esta en UTC y Honduras en UTC-6:
--   2026-10-05 03:00 UTC  =  domingo  4 de octubre, 9 de la noche  -> semana Sep28-Oct4
--   2026-10-05 07:00 UTC  =  lunes    5 de octubre, 1 de la manana -> semana Oct5-Oct11
insert into ventas (id, organizacion_id, sucursal_id, numero, subtotal, total,
                    estado, creada_en) values
 ('faaa0000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
  'bbbbbbbb-0000-0000-0000-000000000001','T-A', 120, 120, 'completada',
  '2026-10-05 03:00:00+00'),
 ('faaa0000-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001',
  'bbbbbbbb-0000-0000-0000-000000000001','T-B', 60, 60, 'completada',
  '2026-10-05 07:00:00+00'),
 ('faaa0000-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000001',
  'bbbbbbbb-0000-0000-0000-000000000001','T-C', 60, 60, 'anulada',
  '2026-10-06 18:00:00+00');

insert into venta_detalle (organizacion_id, venta_id, producto_id, cantidad,
                           precio_unitario, total) values
 ('aaaaaaaa-0000-0000-0000-000000000001','faaa0000-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000001', 2, 60, 120),
 ('aaaaaaaa-0000-0000-0000-000000000001','faaa0000-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000001', 1, 60, 60),
 ('aaaaaaaa-0000-0000-0000-000000000001','faaa0000-0000-0000-0000-000000000003','eeeeeeee-0000-0000-0000-000000000001', 1, 60, 60);

\echo '=== S1: la venta de las 9 de la noche del domingo NO se pasa a la semana siguiente ==='
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select semana_inicio, semana_fin, unidades, importe
from fn_ventas_producto_semanas('eeeeeeee-0000-0000-0000-000000000001', 5);
\echo '--- esperado: 2 unidades/120 en la semana del 28 sep, 1/60 en la del 5 oct ---'
\echo '--- y la ANULADA no cuenta en ninguna ---'

\echo ''
\echo '=== S2: con la hora del servidor saldria corrida (lo que se evito) ==='
set role postgres;
select date_trunc('week', creada_en)::date as semana_utc,
       date_trunc('week', (creada_en at time zone 'America/Tegucigalpa'))::date as semana_hn,
       numero
from ventas where numero in ('T-A','T-B') order by numero;
