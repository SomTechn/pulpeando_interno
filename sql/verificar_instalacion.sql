-- ============================================================================
--  VERIFICACIÓN DE INSTALACIÓN · sistema de abarrotes
--
--  Pegue todo esto en el SQL Editor de Supabase y ejecute.
--  Devuelve una sola tabla. Cópiela y péguemela tal cual.
--  No modifica nada: solo lee el catálogo de la base.
-- ============================================================================

with
esperadas as (
  select unnest(array[
    'organizaciones','sucursales','perfiles','usuario_sucursales','categorias','marcas',
    'proveedores','impuestos','productos','presentaciones','producto_codigos','precios',
    'series_fiscales','lotes','existencias','producto_costos','kardex','ordenes_compra',
    'orden_compra_detalle','facturas_compra','factura_compra_detalle','pagos_compra',
    'cajas','turnos_caja','caja_desbloqueos','intentos_pin','clientes','secuencias',
    'ventas','venta_detalle','pagos_venta','pedidos','pedido_detalle','pedido_eventos',
    'direcciones_cliente'
  ]) as t
),
funciones as (
  select unnest(array[
    'fn_kardex_registrar','fn_confirmar_factura_compra','fn_lotes_fefo',
    'fn_establecer_pin','fn_abrir_turno','fn_desbloquear_caja','fn_registrar_venta',
    'fn_cerrar_turno','fn_anular_venta','fn_precio_vigente','fn_siguiente_numero',
    'fn_crear_pedido','fn_cambiar_estado_pedido','fn_asignar_repartidor',
    'fn_facturar_pedido','fn_pos_contexto','fn_descontar_fefo'
  ]) as f
),
vistas as (
  select unnest(array[
    'v_existencias','v_vencimientos','v_stock_bajo',
    'v_estado_cajas','v_margen_productos','v_pos_catalogo'
  ]) as v
),
criticas as (
  select unnest(array[
    'kardex','existencias','producto_costos','ventas','venta_detalle',
    'pagos_venta','turnos_caja','caja_desbloqueos'
  ]) as c
),
-- cuenta filas sin romperse si la tabla todavía no existe
conteos as (
  select nom,
         case when to_regclass('public.' || nom) is null then null
              else (xpath('/row/c/text()',
                     query_to_xml(format('select count(*) c from public.%I', nom),
                                  false, true, '')))[1]::text::bigint
         end as n
  from unnest(array['organizaciones','sucursales','productos','cajas']) as nom
),
con_pin as (
  select case when to_regclass('public.perfiles') is null then null
              else (xpath('/row/c/text()',
                     query_to_xml('select count(*) c from public.perfiles where pin_pos is not null',
                                  false, true, '')))[1]::text::bigint
         end as n
)

-- 1. Migración 001 y 002
select '1. Tablas del esquema' as revision,
       case when count(*) filter (where existe) = count(*) then 'BIEN' else 'FALTA' end as estado,
       count(*) filter (where existe) || ' de ' || count(*) ||
       coalesce(' · faltan: ' || nullif(string_agg(t, ', ') filter (where not existe), ''), '') as detalle
from (select t, exists (select 1 from pg_tables p
                        where p.schemaname='public' and p.tablename = e.t) as existe
      from esperadas e) x

union all
select '2. Funciones',
       case when count(*) filter (where existe) = count(*) then 'BIEN' else 'FALTA' end,
       count(*) filter (where existe) || ' de ' || count(*) ||
       coalesce(' · faltan: ' || nullif(string_agg(f, ', ') filter (where not existe), ''), '')
from (select f, exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                        where n.nspname='public' and p.proname = fu.f) as existe
      from funciones fu) y

-- 2. El fallo de seguridad más importante
union all
select '3. Vistas sin fuga entre negocios',
       case when count(*) filter (where existe) = 0 then 'FALTA'
            when count(*) filter (where existe and not seguro) > 0 then 'RIESGO'
            else 'BIEN' end,
       case when count(*) filter (where existe) = 0
              then 'las vistas todavía no existen'
            when count(*) filter (where existe and not seguro) > 0
              then 'ABIERTAS: ' ||
                   string_agg(v, ', ' order by v) filter (where existe and not seguro) ||
                   ' · falta correr la migración 003'
            else 'las ' || count(*) filter (where existe) || ' vistas usan security_invoker' end
from (select v, c.oid is not null as existe,
             coalesce(array_to_string(c.reloptions, ','), '') like '%security_invoker=on%' as seguro
      from vistas
      left join pg_class c on c.relname = vistas.v and c.relkind = 'v') z

-- 3. El permiso sin el cual la app no lee nada
union all
select '4. Acceso al esquema app',
       case when has_schema_privilege('authenticated','app','usage') then 'BIEN' else 'FALTA' end,
       case when has_schema_privilege('authenticated','app','usage')
            then 'authenticated puede usar las funciones de RLS'
            else 'sin esto la aplicación no puede leer ninguna tabla' end
where exists (select 1 from pg_namespace where nspname='app')

union all
select '4. Acceso al esquema app', 'FALTA', 'el esquema app no existe: no se corrió la migración 001'
where not exists (select 1 from pg_namespace where nspname='app')

-- 4. RLS
union all
select '5. RLS activo',
       case when total = 0 then '—' when sin = 0 then 'BIEN' else 'RIESGO' end,
       case when total = 0 then 'todavía no hay tablas del sistema'
            when sin = 0 then 'las ' || total || ' tablas del sistema tienen RLS'
            else 'sin RLS: ' || lista end
from (select count(*) as total,
             count(*) filter (where not p.rowsecurity) as sin,
             string_agg(p.tablename, ', ' order by p.tablename) filter (where not p.rowsecurity) as lista
      from pg_tables p
      where p.schemaname='public' and p.tablename in (select t from esperadas)) r5

-- 5. Escritura directa donde no debe haberla
union all
select '6. Tablas de solo-lectura para la app',
       case when total = 0 then '—' when malas = 0 then 'BIEN' else 'RIESGO' end,
       case when total = 0 then 'todavía no hay tablas que revisar'
            when malas = 0 then 'inventario y ventas solo cambian por función'
            else 'se pueden escribir directo: ' || lista end
from (select count(*) as total,
             count(*) filter (where puede) as malas,
             string_agg(c, ', ' order by c) filter (where puede) as lista
      from (select cr.c, has_table_privilege('authenticated', k.oid, 'insert') as puede
            from criticas cr
            join pg_class k on k.relname = cr.c and k.relkind = 'r'
            join pg_namespace ns on ns.oid = k.relnamespace and ns.nspname = 'public') w) r6

-- 6. La llave anónima no debe ver nada del negocio
union all
select '7. Llave anónima sin acceso',
       case when total = 0 then '—' when malas = 0 then 'BIEN' else 'RIESGO' end,
       case when total = 0 then 'todavía no hay tablas que revisar'
            when malas = 0 then 'anon no lee datos de ningún negocio'
            else malas || ' tablas legibles con la llave pública: ' || lista end
from (select count(*) as total,
             count(*) filter (where puede) as malas,
             string_agg(t, ', ' order by t) filter (where puede) as lista
      from (select e.t, has_table_privilege('anon', k.oid, 'select') as puede
            from esperadas e
            join pg_class k on k.relname = e.t and k.relkind = 'r'
            join pg_namespace ns on ns.oid = k.relnamespace and ns.nspname = 'public') v2) r7

-- 7. Datos cargados
union all
select '8. Datos', 'INFO',
       coalesce((select n::text from conteos where nom='organizaciones'), '—') || ' organizaciones · ' ||
       coalesce((select n::text from conteos where nom='sucursales'), '—') || ' sucursales · ' ||
       coalesce((select n::text from conteos where nom='productos'), '—') || ' productos · ' ||
       coalesce((select n::text from conteos where nom='cajas'), '—') || ' cajas · ' ||
       coalesce((select n::text from con_pin), '—') || ' usuarios con PIN'

union all
select '9. Postgres', 'INFO', version()

order by 1;
