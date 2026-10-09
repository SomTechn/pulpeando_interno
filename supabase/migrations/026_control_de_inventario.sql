-- ===========================================================================
-- 026 · Control de inventario por producto y dia
--
-- La tabla con la que se persigue una diferencia de inventario. Por cada
-- producto y cada dia (o por todo el periodo):
--
--   inicial    lo que habia al abrir
--   compras    compras menos devoluciones a proveedor
--   ventas     ventas menos devoluciones de clientes (anulaciones)
--   merma      merma POR DAÑO: la que alguien registro con una causa
--   otros      carga inicial y traslados, si los hay
--   teorico    inicial + compras - ventas - merma + otros
--              = lo que DEBERIA haber si solo hubiera pasado lo explicado
--   ajustes    lo que movieron los conteos y los ajustes aprobados
--   final      lo que dice el sistema al cerrar
--   diferencia final - teorico = la MERMA DESCONOCIDA del item
--              (los ajustes de conteo mas la merma marcada "no se sabe")
--
-- Si diferencia = 0 todo lo que salio tiene explicacion. Si no, ahi esta el
-- problema, y con la fecha se sabe cuando aparecio.
--
-- Filtros: un producto (nombre, SKU o codigo de barras escaneado), una
-- categoria o un departamento. Departamento = categoria padre: al elegirlo
-- entran todas sus subcategorias.
--
-- Permisos: supervisor en adelante. Costo y valores en lempiras solo
-- gerente. El precio de venta lo ve cualquiera que pueda entrar (es el mismo
-- que se ve en la caja).
-- ===========================================================================

create or replace function fn_control_inventario(
  p_desde        date,
  p_hasta        date,
  p_sucursal_id  uuid    default null,
  p_buscar       text    default null,
  p_categoria_id uuid    default null,
  p_por_dia      boolean default true,
  p_limite       int     default 1500
) returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org    uuid;
  v_tz     text;
  v_suc    uuid;
  v_ve     boolean;
  v_ini    timestamptz;
  v_fin    timestamptz;
  v_lim    int;
  v_buscar text;
  v_cats   uuid[];
  r        jsonb;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('supervisor'))) then
    raise exception 'El control de inventario es para supervisor en adelante';
  end if;

  if p_desde is null or p_hasta is null then
    raise exception 'Indique las dos fechas del periodo';
  end if;
  if p_desde > p_hasta then
    raise exception 'La fecha inicial es posterior a la final';
  end if;
  if p_hasta - p_desde > 366 then
    raise exception 'El periodo puede ser de un año como máximo';
  end if;

  v_suc := app.sucursal_para_reporte(p_sucursal_id);
  v_tz  := app.zona(v_org);
  v_ve  := app.es_admin() or app.tiene_nivel('gerente');
  v_lim := least(greatest(coalesce(p_limite, 1500), 1), 5000);
  v_ini := p_desde::timestamp at time zone v_tz;
  v_fin := (p_hasta + 1)::timestamp at time zone v_tz;
  v_buscar := nullif(btrim(coalesce(p_buscar, '')), '');

  -- La categoria y todo lo que cuelga de ella (departamento → subcategorias)
  if p_categoria_id is not null then
    perform 1 from categorias where id = p_categoria_id and organizacion_id = v_org;
    if not found then raise exception 'Esa categoría no es de su negocio'; end if;

    with recursive arbol as (
      select id from categorias where id = p_categoria_id
      union
      select c.id from categorias c join arbol a on c.padre_id = a.id
    )
    select array_agg(id) into v_cats from arbol;
  end if;

  with
  prods as materialized (
    select p.id, p.nombre, p.sku, p.unidad_base, p.categoria_id,
           (select pc.codigo from producto_codigos pc
             where pc.producto_id = p.id
             order by pc.es_principal desc, pc.codigo limit 1) as barras,
           c.nombre as categoria,
           cp.nombre as departamento
    from productos p
    left join categorias c  on c.id  = p.categoria_id
    left join categorias cp on cp.id = c.padre_id
    where p.organizacion_id = v_org
      and p.tipo <> 'servicio'
      and (v_cats is null or p.categoria_id = any(v_cats))
      and (v_buscar is null
           or p.nombre ilike '%' || v_buscar || '%'
           or p.sku ilike v_buscar || '%'
           or exists (select 1 from producto_codigos pc
                       where pc.producto_id = p.id and pc.codigo = v_buscar))
  ),
  -- Cada movimiento del periodo, ya con su dia en hora del negocio y, si es
  -- merma, de que clase fue.
  mov as materialized (
    select k.id, k.producto_id, k.tipo, k.cantidad, k.costo_total,
           k.saldo_cantidad, k.costo_promedio_resultante, k.ocurrido_en,
           (k.ocurrido_en at time zone v_tz)::date as dia,
           case when k.tipo = 'merma'
                then coalesce((select m.clase from mermas m
                                where k.documento_tipo = 'merma' and m.id = k.documento_id),
                              'dano') end as clase
    from kardex k
    where k.sucursal_id = v_suc
      and k.ocurrido_en >= v_ini and k.ocurrido_en < v_fin
      and k.producto_id in (select id from prods)
  ),
  -- Agregado por producto y dia (o por producto, si no es por dia)
  agg as (
    select m.producto_id,
           case when p_por_dia then m.dia end as dia,
           sum(case when m.tipo in ('compra','devolucion_compra') then m.cantidad else 0 end) as compras,
           sum(case when m.tipo in ('venta','devolucion_venta') then -m.cantidad else 0 end) as ventas,
           sum(case when m.tipo = 'merma' and m.clase = 'dano' then -m.cantidad else 0 end) as merma_dano,
           sum(case when m.tipo = 'merma' and m.clase = 'desconocida' then -m.cantidad else 0 end) as merma_desc,
           sum(case when m.tipo in ('ajuste_positivo','ajuste_negativo') then m.cantidad else 0 end) as ajustes,
           sum(case when m.tipo in ('inventario_inicial','traslado_entrada','traslado_salida')
                    then m.cantidad else 0 end) as otros,
           sum(m.cantidad) as neto,
           -- valores al costo del propio movimiento (el del kardex)
           sum(case when m.tipo = 'merma' and m.clase = 'dano' then m.costo_total else 0 end) as v_merma_dano,
           sum(case when m.tipo = 'ajuste_positivo' then m.costo_total
                    when m.tipo = 'ajuste_negativo' then -m.costo_total else 0 end) as v_ajustes,
           sum(case when m.tipo = 'merma' and m.clase = 'desconocida' then m.costo_total else 0 end) as v_merma_desc,
           sum(case when m.tipo in ('venta','devolucion_venta')
                    then case when m.cantidad < 0 then m.costo_total else -m.costo_total end
                    else 0 end) as v_ventas,
           (array_agg(m.saldo_cantidad order by m.ocurrido_en desc, m.id desc))[1] as final_dia,
           (array_agg(m.costo_promedio_resultante order by m.ocurrido_en desc, m.id desc))[1] as costo_dia,
           count(*)::int as n
    from mov m
    group by m.producto_id, case when p_por_dia then m.dia end
  ),
  filas as (
    -- POR DIA: solo los dias en que el producto se movio. El inicial del dia
    -- sale del saldo corrido: lo que quedo menos lo que se movio ese dia.
    select pr.*, a.dia,
           a.final_dia - a.neto as inicial,
           a.compras, a.ventas, a.merma_dano, a.merma_desc, a.ajustes, a.otros,
           a.final_dia as final,
           a.costo_dia as costo,
           a.v_merma_dano, a.v_ajustes, a.v_merma_desc, a.v_ventas, a.n
    from agg a join prods pr on pr.id = a.producto_id
    where p_por_dia

    union all

    -- PERIODO: una fila por producto con historia en la sucursal, aunque no
    -- se haya movido (un producto quieto que deberia venderse tambien dice
    -- algo).
    select pr.*, null::date,
           coalesce(ki.saldo_cantidad, 0),
           coalesce(a.compras, 0), coalesce(a.ventas, 0),
           coalesce(a.merma_dano, 0), coalesce(a.merma_desc, 0),
           coalesce(a.ajustes, 0), coalesce(a.otros, 0),
           kf.saldo_cantidad,
           kf.costo_promedio_resultante,
           coalesce(a.v_merma_dano, 0), coalesce(a.v_ajustes, 0),
           coalesce(a.v_merma_desc, 0), coalesce(a.v_ventas, 0), coalesce(a.n, 0)
    from prods pr
    join lateral (
      select k.saldo_cantidad, k.costo_promedio_resultante
      from kardex k
      where k.producto_id = pr.id and k.sucursal_id = v_suc and k.ocurrido_en < v_fin
      order by k.ocurrido_en desc, k.id desc limit 1) kf on true
    left join lateral (
      select k.saldo_cantidad
      from kardex k
      where k.producto_id = pr.id and k.sucursal_id = v_suc and k.ocurrido_en < v_ini
      order by k.ocurrido_en desc, k.id desc limit 1) ki on true
    left join agg a on a.producto_id = pr.id
    where not p_por_dia
  ),
  calc as materialized (
    select f.*,
           f.inicial + f.compras - f.ventas - f.merma_dano + f.otros as teorico,
           f.final - (f.inicial + f.compras - f.ventas - f.merma_dano + f.otros) as diferencia,
           f.v_ajustes - f.v_merma_desc as v_diferencia,
           -- precio de venta vigente ESE dia (o al cierre del periodo)
           (select pr.precio from precios pr
             where pr.producto_id = f.id
               and (pr.sucursal_id = v_suc or pr.sucursal_id is null)
               and pr.nivel = 'detalle' and pr.cantidad_minima <= 1
               and pr.vigente_desde <= coalesce(f.dia, p_hasta)
               and (pr.vigente_hasta is null or pr.vigente_hasta >= coalesce(f.dia, p_hasta))
             order by pr.sucursal_id nulls last, pr.cantidad_minima desc
             limit 1) as precio
    from filas f
  )
  select jsonb_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    'por_dia', coalesce(p_por_dia, true),
    'sucursal_id', v_suc,
    'sucursal', (select nombre from sucursales where id = v_suc),
    'puede_ver_costos', v_ve,

    'totales', jsonb_build_object(
      'filas',          (select count(*) from calc),
      'productos',      (select count(distinct id) from calc),
      'con_diferencia', (select count(*) from calc where diferencia <> 0),
      'compras',        (select coalesce(sum(compras), 0) from calc),
      'ventas',         (select coalesce(sum(ventas), 0) from calc),
      'merma_dano',     (select coalesce(sum(merma_dano), 0) from calc),
      'ajustes',        (select coalesce(sum(ajustes), 0) from calc),
      'diferencia',     (select coalesce(sum(diferencia), 0) from calc),
      'valor_merma_dano', case when v_ve then (select round(coalesce(sum(v_merma_dano), 0), 2) from calc) end,
      'valor_ajustes',    case when v_ve then (select round(coalesce(sum(v_ajustes), 0), 2) from calc) end,
      'valor_diferencia', case when v_ve then (select round(coalesce(sum(v_diferencia), 0), 2) from calc) end,
      'valor_ventas_costo', case when v_ve then (select round(coalesce(sum(v_ventas), 0), 2) from calc) end),

    -- Los ajustes y la merma desconocida, dia por dia: cuando aparecio la
    -- diferencia. Solo los dias que tuvieron algo.
    'por_fecha', coalesce((
      select jsonb_agg(jsonb_build_object(
               'dia', x.dia,
               'productos', x.np,
               'ajustes', x.aj,
               'merma_desconocida', x.md,
               'merma_dano', x.dn,
               'valor_ajustes', case when v_ve then round(x.vaj, 2) end,
               'valor_diferencia', case when v_ve then round(x.vdf, 2) end,
               'valor_merma_dano', case when v_ve then round(x.vdn, 2) end)
               order by x.dia)
      from (
        select m.dia,
               count(distinct m.producto_id) filter (where m.tipo in ('ajuste_positivo','ajuste_negativo')
                                                        or (m.tipo = 'merma')) as np,
               sum(case when m.tipo in ('ajuste_positivo','ajuste_negativo') then m.cantidad else 0 end) as aj,
               sum(case when m.tipo = 'merma' and m.clase = 'desconocida' then -m.cantidad else 0 end) as md,
               sum(case when m.tipo = 'merma' and m.clase = 'dano' then -m.cantidad else 0 end) as dn,
               sum(case when m.tipo = 'ajuste_positivo' then m.costo_total
                        when m.tipo = 'ajuste_negativo' then -m.costo_total else 0 end) as vaj,
               sum(case when m.tipo = 'ajuste_positivo' then m.costo_total
                        when m.tipo = 'ajuste_negativo' then -m.costo_total
                        when m.tipo = 'merma' and m.clase = 'desconocida' then -m.costo_total
                        else 0 end) as vdf,
               sum(case when m.tipo = 'merma' and m.clase = 'dano' then m.costo_total else 0 end) as vdn
        from mov m
        group by m.dia) x
      where x.aj <> 0 or x.md <> 0 or x.dn <> 0), '[]'::jsonb),

    'filas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'producto_id',  c.id,
               'dia',          c.dia,
               'sku',          c.sku,
               'barras',       c.barras,
               'nombre',       c.nombre,
               'unidad',       c.unidad_base,
               'categoria',    c.categoria,
               'departamento', c.departamento,
               'costo',        case when v_ve then round(c.costo, 4) end,
               'precio',       c.precio,
               'inicial',      c.inicial,
               'compras',      c.compras,
               'ventas',       c.ventas,
               'merma_dano',   c.merma_dano,
               'otros',        c.otros,
               'teorico',      c.teorico,
               'ajustes',      c.ajustes,
               'merma_desconocida_registrada', c.merma_desc,
               'final',        c.final,
               'diferencia',   c.diferencia,
               'movimientos',  c.n,
               'valor_diferencia', case when v_ve then round(c.v_diferencia, 2) end,
               'valor_merma_dano', case when v_ve then round(c.v_merma_dano, 2) end)
               order by c.nombre, c.dia)
      from (select * from calc order by nombre, dia limit v_lim) c), '[]'::jsonb),

    'hay_otros', (select coalesce(bool_or(otros <> 0), false) from calc),
    'truncado', (select count(*) from calc) > v_lim,
    'limite', v_lim
  ) into r;

  return r;
end $fn$;

revoke execute on function fn_control_inventario(date, date, uuid, text, uuid, boolean, int)
  from public, anon;
grant execute on function fn_control_inventario(date, date, uuid, text, uuid, boolean, int)
  to authenticated;


-- ---------------------------------------------------------------------------
-- Categorias para el filtro, con su departamento. Las lee supervisor en
-- adelante (las mismas personas que ven el control).
-- ---------------------------------------------------------------------------
create or replace function fn_categorias_arbol()
returns jsonb
language sql stable security definer set search_path = public, app as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'nombre', c.nombre, 'padre_id', c.padre_id,
           'es_departamento', exists (select 1 from categorias h where h.padre_id = c.id))
           order by coalesce(cp.nombre, c.nombre), c.padre_id nulls first, c.nombre), '[]'::jsonb)
  from categorias c
  left join categorias cp on cp.id = c.padre_id
  where c.organizacion_id = app.org_id() and c.activa
$fn$;

revoke execute on function fn_categorias_arbol() from public, anon;
grant execute on function fn_categorias_arbol() to authenticated;

notify pgrst, 'reload schema';
