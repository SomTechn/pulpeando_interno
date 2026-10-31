-- ============================================================================
--  Migración 045 · Elegir varios, y el producto con color, tamaño y foto
--
--  1. VARIOS EN LOS FILTROS
--     Somar pidió que en todo filtro o selector se pueda escoger más de uno.
--     Las funciones que reciben jsonb aceptan ahora un valor o una lista en
--     el mismo campo, así lo que ya mandaba un valor solo sigue igual:
--
--       fn_buscar_ventas   caja_id, cajero_id, sucursal_id, metodo, estado
--                          (+ solo_credito: las fiadas)
--       fn_cambiar_precios categoria_id, marca_id, proveedor_id
--                          (un departamento trae sus categorías hijas)
--
--     fn_abrir_conteo recibe una sola categoría o proveedor y su firma no se
--     puede cambiar sin un drop. Para contar varias está fn_abrir_conteo_varios:
--     con una sola llama a la de siempre; con varias abre una hoja «por
--     selección» y le pone los productos de todas.
--
--  2. EL PRODUCTO: color y tamaño (texto libre: "Rojo", "Grande", "2.5 L").
--     La foto va al bucket «marca» que ya existe (038), en la carpeta del
--     negocio: marca/<org>/productos/... Las políticas de la 038 ya dejan
--     subir ahí al gerente de ese negocio. La URL pública queda en imagen_url,
--     que la caja ya pinta.
--
--  Sin drops.
-- ============================================================================

-- Un valor o una lista, como arreglo. Nulo si no viene nada.
create or replace function app.uuids(p jsonb)
returns uuid[] language sql immutable as $fn$
  select case
    when p is null or p = 'null'::jsonb then null
    when jsonb_typeof(p) = 'array' then
      nullif(array(select x::uuid from jsonb_array_elements_text(p) x where x <> ''), '{}')
    when p #>> '{}' = '' then null
    else array[(p #>> '{}')::uuid] end
$fn$;

create or replace function app.textos(p jsonb)
returns text[] language sql immutable as $fn$
  select case
    when p is null or p = 'null'::jsonb then null
    when jsonb_typeof(p) = 'array' then
      nullif(array(select x from jsonb_array_elements_text(p) x where x <> ''), '{}')
    when p #>> '{}' = '' then null
    else array[p #>> '{}'] end
$fn$;

revoke execute on function app.uuids(jsonb) from public, anon;
grant execute on function app.uuids(jsonb) to authenticated;
revoke execute on function app.textos(jsonb) from public, anon;
grant execute on function app.textos(jsonb) to authenticated;


-- ---------------------------------------------------------------------------
-- El producto: color y tamaño
-- ---------------------------------------------------------------------------
alter table productos add column if not exists color  text;
alter table productos add column if not exists tamano text;


-- ---------------------------------------------------------------------------
-- Buscar ventas: varios a la vez (igual que la 044 en todo lo demás)
-- ---------------------------------------------------------------------------
create or replace function fn_buscar_ventas(p_filtros jsonb default '{}'::jsonb)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  f        jsonb := coalesce(p_filtros, '{}'::jsonb);
  v_org    uuid := app.org_id();
  v_tz     text;
  v_costos boolean := app.tiene_nivel('supervisor');
  v_lim    int := least(greatest(coalesce((f->>'limite')::int, 300), 1), 1000);
  v_desde  date := nullif(f->>'desde', '')::date;
  v_hasta  date := nullif(f->>'hasta', '')::date;
  v_hd     time := nullif(f->>'hora_desde', '')::time;
  v_hh     time := nullif(f->>'hora_hasta', '')::time;
  v_bus    text := nullif(btrim(f->>'buscar'), '');
  v_cli    text := nullif(btrim(f->>'cliente'), '');
  v_pro    text := nullif(btrim(f->>'producto'), '');
  v_cajas   uuid[] := app.uuids(f->'caja_id');
  v_cajeros uuid[] := app.uuids(f->'cajero_id');
  v_sucs    uuid[] := app.uuids(f->'sucursal_id');
  v_mets    text[] := app.textos(f->'metodo');
  v_estados text[] := app.textos(f->'estado');
  v_res    jsonb;
begin
  if v_org is null or not app.tiene_nivel('auxiliar') then
    raise exception 'Sin permiso';
  end if;
  v_tz := app.zona(v_org);

  with base as (
    select v.*,
           (select coalesce(sum(coalesce(pv.recibido, pv.monto)), 0) from pagos_venta pv
             where pv.venta_id = v.id and pv.metodo = 'efectivo') as ef_recibido,
           (select coalesce(sum(pv.monto), 0) from pagos_venta pv
             where pv.venta_id = v.id and pv.metodo = 'efectivo') as ef_monto,
           (select coalesce(sum(pv.cambio), 0) from pagos_venta pv where pv.venta_id = v.id) as cambio_t,
           (select string_agg(distinct pv.metodo::text, ', ') from pagos_venta pv
             where pv.venta_id = v.id) as metodos,
           (select coalesce(sum(dv.total), 0) from devoluciones_venta dv where dv.venta_id = v.id) as devuelto
      from ventas v
     where v.organizacion_id = v_org
       and v.sucursal_id in (select app.sucursales_permitidas())
       and (v_sucs    is null or v.sucursal_id = any(v_sucs))
       and (v_cajas   is null or v.caja_id     = any(v_cajas))
       and (v_cajeros is null or v.cajero_id   = any(v_cajeros))
       and (v_desde is null or v.creada_en >= (v_desde::timestamp at time zone v_tz))
       and (v_hasta is null or v.creada_en <  ((v_hasta + 1)::timestamp at time zone v_tz))
       and (v_estados is null or v.estado::text = any(v_estados))
       and (not coalesce((f->>'solo_credito')::boolean, false) or v.es_credito)
       and (f->>'monto_min' is null or v.total >= (f->>'monto_min')::numeric)
       and (f->>'monto_max' is null or v.total <= (f->>'monto_max')::numeric)
       and (v_hd is null or v_hh is null
            or case when v_hd <= v_hh
                    then (v.creada_en at time zone v_tz)::time between v_hd and v_hh
                    else (v.creada_en at time zone v_tz)::time >= v_hd
                      or (v.creada_en at time zone v_tz)::time <= v_hh end)
       and (v_hd is null or v_hh is not null or (v.creada_en at time zone v_tz)::time >= v_hd)
       and (v_hh is null or v_hd is not null or (v.creada_en at time zone v_tz)::time <= v_hh)
       and (v_mets is null or exists (select 1 from pagos_venta pv
                                       where pv.venta_id = v.id and pv.metodo::text = any(v_mets)))
       and (v_bus is null
            or v.numero ilike '%' || v_bus || '%'
            or coalesce(v.numero_fiscal, '') ilike '%' || v_bus || '%'
            or coalesce(v.codigo_barras, '') = regexp_replace(v_bus, '[^0-9]', '', 'g')
            or exists (select 1 from clientes c where c.id = v.cliente_id
                        and c.nombre ilike '%' || v_bus || '%'))
       and (v_cli is null or exists (
             select 1 from clientes c where c.id = v.cliente_id
                and (c.nombre ilike '%' || v_cli || '%'
                     or coalesce(c.telefono, '') ilike '%' || v_cli || '%'
                     or coalesce(c.numero::text, '') = v_cli)))
       and (v_pro is null or exists (
             select 1 from venta_detalle d join productos p on p.id = d.producto_id
              where d.venta_id = v.id
                and (p.nombre ilike '%' || v_pro || '%' or p.sku = v_pro
                     or exists (select 1 from producto_codigos pc
                                 where pc.producto_id = p.id and pc.codigo = v_pro))))
  ),
  filtrada as (
    select * from base b
     where (f->>'efectivo_min' is null or (b.ef_monto > 0 and b.ef_recibido >= (f->>'efectivo_min')::numeric))
       and (f->>'efectivo_max' is null or (b.ef_monto > 0 and b.ef_recibido <= (f->>'efectivo_max')::numeric))
       and (f->>'cambio_min'   is null or b.cambio_t >= (f->>'cambio_min')::numeric)
       and (f->>'cambio_max'   is null or b.cambio_t <= (f->>'cambio_max')::numeric)
  )
  select jsonb_build_object(
    'resumen', (select jsonb_build_object(
        'ventas',      count(*) filter (where estado = 'completada'),
        'total',       coalesce(sum(total) filter (where estado = 'completada'), 0),
        'efectivo',    coalesce(sum(ef_monto) filter (where estado = 'completada'), 0),
        'recibido',    coalesce(sum(ef_recibido) filter (where estado = 'completada'), 0),
        'cambio',      coalesce(sum(cambio_t) filter (where estado = 'completada'), 0),
        'devuelto',    coalesce(sum(devuelto) filter (where estado = 'completada'), 0),
        'anuladas',    count(*) filter (where estado = 'anulada'),
        'monto_anulado', coalesce(sum(total) filter (where estado = 'anulada'), 0),
        'ganancia',    case when v_costos then coalesce(sum(total - impuesto - costo_total)
                                                 filter (where estado = 'completada'), 0) end,
        'filas',       count(*))
      from filtrada),
    'filas', coalesce((
      select jsonb_agg(x order by x->>'creada_en' desc) from (
        select jsonb_build_object(
          'venta_id', b.id, 'numero', b.numero, 'numero_fiscal', b.numero_fiscal,
          'documento', b.tipo_documento, 'creada_en', b.creada_en,
          'codigo_barras', b.codigo_barras,
          'sucursal', (select nombre from sucursales where id = b.sucursal_id),
          'caja', (select nombre from cajas where id = b.caja_id),
          'cajero', (select nombre from perfiles where id = b.cajero_id),
          'cliente', (select nombre from clientes where id = b.cliente_id),
          'total', b.total,
          'costo', case when v_costos then b.costo_total end,
          'ganancia', case when v_costos then round(b.total - b.impuesto - b.costo_total, 2) end,
          'es_credito', b.es_credito, 'estado', b.estado,
          'metodos', b.metodos,
          'efectivo_recibido', b.ef_recibido, 'cambio', b.cambio_t,
          'lineas', (select count(*) from venta_detalle d where d.venta_id = b.id),
          'devuelto', b.devuelto) as x
        from filtrada b
        order by b.creada_en desc
        limit v_lim) t), '[]'::jsonb)
  ) into v_res;

  return v_res;
end $fn$;

revoke execute on function fn_buscar_ventas(jsonb) from public, anon;
grant execute on function fn_buscar_ventas(jsonb) to authenticated;


-- ---------------------------------------------------------------------------
-- Cambiar precios en lote: varias categorías, marcas o proveedores
-- ---------------------------------------------------------------------------
create or replace function fn_cambiar_precios(
  p_filtro jsonb, p_modo text, p_valor numeric,
  p_redondeo numeric default 0, p_aplicar boolean default false
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  v_suc uuid;
  r     record;
  lista jsonb := '[]'::jsonb;
  v_nuevo numeric;
  v_base numeric;
  n int := 0; v_sin_costo int := 0;
begin
  if v_org is null or not app.tiene_nivel('gerente') then
    raise exception 'Solo el gerente cambia precios';
  end if;
  if p_modo not in ('porcentaje', 'margen', 'markup') then raise exception 'Modo no válido'; end if;
  if p_valor is null then raise exception 'Falta el porcentaje'; end if;
  if p_modo = 'margen' and (p_valor <= 0 or p_valor >= 95) then
    raise exception 'El margen tiene que estar entre 0 y 95%%';
  end if;
  if p_modo = 'porcentaje' and p_valor <= -90 then raise exception 'No se puede bajar tanto'; end if;
  if coalesce(p_filtro, '{}'::jsonb) = '{}'::jsonb
     or not (p_filtro ?| array['categoria_id', 'marca_id', 'proveedor_id', 'producto_ids', 'todos']) then
    raise exception 'Escoja a qué productos se les cambia el precio';
  end if;

  v_suc := (select id from sucursales where organizacion_id = v_org and activa order by es_principal desc limit 1);

  for r in
    select p.id, p.nombre, p.sku,
           fn_precio_vigente(p.id, v_suc, 1) as actual,
           (select pr.precio from precios pr where pr.producto_id = p.id and pr.nivel = 'detalle'
              and pr.sucursal_id is null and pr.vigente_hasta is null and not pr.es_oferta
            order by pr.cantidad_minima limit 1) as base,
           coalesce((select pc.costo_promedio from producto_costos pc
                      where pc.producto_id = p.id and pc.costo_promedio > 0
                      order by (pc.sucursal_id = v_suc) desc limit 1), 0) as costo,
           coalesce(i.tasa, 0) as tasa, coalesce(i.incluido_en_precio, true) as incluido
      from productos p
      left join impuestos i on i.id = p.impuesto_id
     where p.organizacion_id = v_org and p.activo and p.se_vende and p.tipo <> 'servicio'
       and (not (p_filtro ? 'categoria_id') or p.categoria_id = any(app.uuids(p_filtro->'categoria_id'))
            -- una categoría que es departamento trae también sus hijas
            or p.categoria_id in (select c.id from categorias c
                                   where c.padre_id = any(app.uuids(p_filtro->'categoria_id'))))
       and (not (p_filtro ? 'marca_id')     or p.marca_id     = any(app.uuids(p_filtro->'marca_id')))
       and (not (p_filtro ? 'proveedor_id') or p.proveedor_id = any(app.uuids(p_filtro->'proveedor_id')))
       and (not (p_filtro ? 'producto_ids') or p.id in
              (select x::uuid from jsonb_array_elements_text(p_filtro->'producto_ids') x))
     order by p.nombre
     limit 2000
  loop
    v_base := coalesce(r.base, r.actual);
    if p_modo = 'porcentaje' then
      if v_base is null then continue; end if;
      v_nuevo := v_base * (1 + p_valor / 100);
    else
      if r.costo <= 0 then v_sin_costo := v_sin_costo + 1; continue; end if;
      v_nuevo := case p_modo
                   when 'margen' then r.costo / (1 - p_valor / 100)
                   else r.costo * (1 + p_valor / 100) end;
      if r.incluido then v_nuevo := v_nuevo * (1 + r.tasa); end if;
    end if;
    if coalesce(p_redondeo, 0) > 0 then
      v_nuevo := ceil(round(v_nuevo, 4) / p_redondeo) * p_redondeo;
    end if;
    v_nuevo := round(v_nuevo, 2);
    if v_nuevo <= 0 then continue; end if;

    n := n + 1;
    lista := lista || jsonb_build_object('producto_id', r.id, 'nombre', r.nombre, 'sku', r.sku,
               'actual', round(coalesce(v_base, 0), 2), 'nuevo', v_nuevo, 'costo', round(r.costo, 2),
               'margen', case when v_nuevo > 0 and r.costo > 0
                              then round(((v_nuevo / (1 + case when r.incluido then r.tasa else 0 end)) - r.costo)
                                         / (v_nuevo / (1 + case when r.incluido then r.tasa else 0 end)) * 100, 1) end);
    if p_aplicar and v_nuevo <> coalesce(v_base, -1) then
      perform app.fijar_precio_base(v_org, r.id, v_nuevo);
    end if;
  end loop;

  return jsonb_build_object('productos', n, 'sin_costo', v_sin_costo, 'aplicado', p_aplicar,
                            'lista', lista);
end $fn$;

revoke execute on function fn_cambiar_precios(jsonb, text, numeric, numeric, boolean) from public, anon;
grant execute on function fn_cambiar_precios(jsonb, text, numeric, numeric, boolean) to authenticated;


-- ---------------------------------------------------------------------------
-- Contar varias categorías (o varios proveedores) en una sola hoja
-- ---------------------------------------------------------------------------
create or replace function fn_abrir_conteo_varios(
  p_sucursal_id uuid,
  p_alcance     text,
  p_ids         uuid[],
  p_notas       text default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org   uuid := app.org_id();
  v_ids   uuid[];
  v_res   jsonb;
  v_id    uuid;
  v_suc   uuid;
  v_n     int;
  v_nombres text;
begin
  if v_org is null or not app.tiene_nivel('supervisor') then
    raise exception 'Solo un supervisor puede abrir un conteo';
  end if;
  if p_alcance not in ('categoria', 'proveedor') then
    raise exception 'Alcance invalido';
  end if;

  -- Solo los de este negocio, sin repetir
  if p_alcance = 'categoria' then
    select array_agg(distinct id), string_agg(distinct nombre, ', ') into v_ids, v_nombres
      from categorias where organizacion_id = v_org and id = any(coalesce(p_ids, '{}'));
  else
    select array_agg(distinct id), string_agg(distinct nombre, ', ') into v_ids, v_nombres
      from proveedores where organizacion_id = v_org and id = any(coalesce(p_ids, '{}'));
  end if;
  if coalesce(array_length(v_ids, 1), 0) = 0 then
    raise exception 'Escoja al menos una %', case when p_alcance = 'categoria' then 'categoría' else 'proveedor' end;
  end if;

  -- Uno solo: el conteo de siempre
  if array_length(v_ids, 1) = 1 then
    return fn_abrir_conteo(p_sucursal_id, p_alcance,
                           case when p_alcance = 'categoria' then v_ids[1] end,
                           case when p_alcance = 'proveedor' then v_ids[1] end, p_notas);
  end if;

  -- Varios: una hoja por selección con los productos de todos
  v_res := fn_abrir_conteo(p_sucursal_id, 'seleccion', null, null,
             concat_ws(' · ', nullif(btrim(coalesce(p_notas, '')), ''),
                       case when p_alcance = 'categoria' then 'Categorías: ' else 'Proveedores: ' end || v_nombres));
  v_id := (v_res ->> 'conteo_id')::uuid;
  select sucursal_id into v_suc from conteos where id = v_id;

  with alcance as (
    select p.id from productos p
     where p.organizacion_id = v_org and p.activo and p.tipo <> 'servicio'
       and ((p_alcance = 'categoria' and (p.categoria_id = any(v_ids)
              or p.categoria_id in (select c.id from categorias c where c.padre_id = any(v_ids))))
         or (p_alcance = 'proveedor' and p.proveedor_id = any(v_ids)))
  ),
  con_lote as (
    select e.producto_id, e.lote_id from existencias e
      join alcance a on a.id = e.producto_id
     where e.sucursal_id = v_suc and (e.cantidad <> 0 or e.lote_id is null)
  ),
  todas as (
    select producto_id, lote_id from con_lote
    union
    select a.id, null::uuid from alcance a
     where not exists (select 1 from con_lote c where c.producto_id = a.id)
  )
  insert into conteo_detalle (organizacion_id, conteo_id, producto_id, lote_id)
  select v_org, v_id, t.producto_id, t.lote_id from todas t
  on conflict do nothing;

  select count(*) into v_n from conteo_detalle where conteo_id = v_id;
  if v_n = 0 then
    raise exception 'No hay productos que contar en esas %',
      case when p_alcance = 'categoria' then 'categorías' else 'proveedores' end;
  end if;

  return v_res || jsonb_build_object('lineas', v_n, 'varios', array_length(v_ids, 1));
end $fn$;

revoke execute on function fn_abrir_conteo_varios(uuid, text, uuid[], text) from public, anon;
grant execute on function fn_abrir_conteo_varios(uuid, text, uuid[], text) to authenticated;

notify pgrst, 'reload schema';
