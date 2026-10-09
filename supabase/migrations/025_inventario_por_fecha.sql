-- ===========================================================================
-- 025 · Inventario por fecha
--
-- Contesta dos preguntas que el dueño hace seguido y que hasta ahora solo se
-- podian contestar leyendo el kardex a mano:
--
--   1. ¿Que paso con el inventario entre tal y tal fecha?
--      Por producto: con cuanto empezo, cuanto entro, cuanto salio y con
--      cuanto termino. Y en total, por tipo de movimiento: cuanto fue compra,
--      cuanto venta, cuanto merma, cuanto ajuste.
--
--   2. ¿Cuanto habia de cada cosa tal dia?
--      Es la misma funcion con una sola fecha: el saldo final de ese dia.
--
-- Mas el kardex de un producto en un rango, movimiento por movimiento, con su
-- documento (ticket, factura, conteo, merma) y quien lo hizo.
--
-- No se guarda nada nuevo. El kardex ya trae el saldo despues de cada
-- movimiento (saldo_cantidad, saldo_valor), asi que el saldo a cualquier hora
-- es el del ultimo movimiento antes de esa hora. No hay que sumar la historia
-- entera ni tener fotos diarias del inventario.
--
-- Permisos, igual que el kardex:
--   · supervisor en adelante ve cantidades
--   · gerente en adelante ve ademas los valores en lempiras (README: costos
--     y margenes son de gerente). El kardex como tabla se deja leer desde
--     supervisor; estas funciones son mas estrictas que eso, no menos.
--
-- Las fechas se cortan en la hora del negocio (app.zona), no la del
-- servidor: una venta de las 8 de la noche del dia 9 es del dia 9.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 0. Indice para los totales por rango de una sucursal
--
--    ix_kardex_prod sirve para "el ultimo movimiento de este producto antes
--    de tal hora". Para "todo lo que paso en esta sucursal en octubre" hace
--    falta uno por sucursal y fecha.
-- ---------------------------------------------------------------------------
create index if not exists ix_kardex_suc_fecha
  on kardex (sucursal_id, ocurrido_en);


-- ---------------------------------------------------------------------------
-- 1. Utilidades
-- ---------------------------------------------------------------------------

-- Nombre corto de cada tipo de movimiento, para que la pantalla y el CSV
-- digan lo mismo.
create or replace function app.nombre_movimiento(t tipo_movimiento)
returns text immutable language sql as $fn$
  select case t
    when 'inventario_inicial' then 'Inventario inicial'
    when 'compra'             then 'Compra'
    when 'devolucion_compra'  then 'Devolución a proveedor'
    when 'venta'              then 'Venta'
    when 'devolucion_venta'   then 'Devolución de venta'
    when 'ajuste_positivo'    then 'Ajuste (sobrante)'
    when 'ajuste_negativo'    then 'Ajuste (faltante)'
    when 'merma'              then 'Merma'
    when 'traslado_entrada'   then 'Traslado recibido'
    when 'traslado_salida'    then 'Traslado enviado'
  end
$fn$;

-- El numero del documento que causo el movimiento. El kardex solo guarda el
-- tipo y el id; el numero vive en cada tabla.
create or replace function app.numero_de_documento(p_tipo text, p_id uuid)
returns text stable language sql security definer set search_path = public, app as $fn$
  select case
    when p_id is null then null
    when p_tipo in ('venta', 'anulacion_venta')
      then (select numero from ventas where id = p_id)
    when p_tipo in ('factura_compra', 'anulacion_compra')
      then (select numero from facturas_compra where id = p_id)
    when p_tipo = 'conteo'
      then (select numero::text from conteos where id = p_id)
    when p_tipo = 'ajuste'
      then (select numero::text from ajustes_inventario where id = p_id)
    when p_tipo = 'merma'
      then (select numero::text from mermas where id = p_id)
    when p_tipo = 'pedido'
      then (select numero from pedidos where id = p_id)
  end
$fn$;

-- La sucursal que se va a leer: la pedida si el usuario tiene acceso, o la
-- principal de las que tiene.
create or replace function app.sucursal_para_reporte(p_sucursal_id uuid)
returns uuid stable language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  v_suc uuid;
begin
  if p_sucursal_id is null then
    select s.id into v_suc
    from sucursales s
    where s.organizacion_id = v_org
      and (app.es_admin() or s.id in (select app.sucursales_permitidas()))
    order by s.es_principal desc, s.nombre
    limit 1;
    if v_suc is null then raise exception 'No tiene ninguna sucursal asignada'; end if;
    return v_suc;
  end if;

  perform 1 from sucursales
   where id = p_sucursal_id and (organizacion_id = v_org or app.es_admin());
  if not found then raise exception 'Esa sucursal no es de su negocio'; end if;

  if not app.es_admin()
     and p_sucursal_id not in (select app.sucursales_permitidas()) then
    raise exception 'No tiene acceso a esa sucursal';
  end if;

  return p_sucursal_id;
end $fn$;

revoke execute on function app.nombre_movimiento(tipo_movimiento) from public, anon;
revoke execute on function app.numero_de_documento(text, uuid)    from public, anon;
revoke execute on function app.sucursal_para_reporte(uuid)        from public, anon;
grant  execute on function app.nombre_movimiento(tipo_movimiento) to authenticated;
grant  execute on function app.numero_de_documento(text, uuid)    to authenticated;
grant  execute on function app.sucursal_para_reporte(uuid)        to authenticated;


-- ---------------------------------------------------------------------------
-- 2. El inventario de un periodo, producto por producto
--
--    inicial  = saldo del ultimo movimiento ANTES de que empiece p_desde
--    entradas = todo lo que sumo dentro del periodo
--    salidas  = todo lo que resto dentro del periodo
--    final    = saldo del ultimo movimiento ANTES de que termine p_hasta
--
--    inicial + entradas - salidas = final, siempre: los saldos del kardex son
--    corridos. Si alguna vez no cuadra, alguien escribio el kardex por fuera
--    de fn_kardex_registrar, y la pantalla lo marca.
--
--    Con p_desde = p_hasta se lee como "el inventario de ese dia".
-- ---------------------------------------------------------------------------
create or replace function fn_inventario_por_fecha(
  p_desde        date,
  p_hasta        date,
  p_sucursal_id  uuid    default null,
  p_buscar       text    default null,
  p_categoria_id uuid    default null,
  p_solo_movidos boolean default false,
  p_limite       int     default 500
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
  r        jsonb;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('supervisor'))) then
    raise exception 'El inventario por fecha es para supervisor en adelante';
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
  v_lim := least(greatest(coalesce(p_limite, 500), 1), 2000);

  -- Medianoche del negocio, no del servidor
  v_ini := p_desde::timestamp at time zone v_tz;
  v_fin := (p_hasta + 1)::timestamp at time zone v_tz;

  v_buscar := nullif(btrim(coalesce(p_buscar, '')), '');

  with inv (producto_id, nombre, sku, unidad, categoria,
                inicial, valor_inicial, entradas, valor_entradas,
                salidas, valor_salidas, final, valor_final,
                movimientos, ultimo) as materialized (
  select p.id, p.nombre, p.sku, p.unidad_base,
         (select c.nombre from categorias c where c.id = p.categoria_id),
         coalesce(ki.saldo_cantidad, 0), coalesce(ki.saldo_valor, 0),
         coalesce(mv.entradas, 0), coalesce(mv.valor_entradas, 0),
         coalesce(mv.salidas, 0),  coalesce(mv.valor_salidas, 0),
         coalesce(kf.saldo_cantidad, 0), coalesce(kf.saldo_valor, 0),
         coalesce(mv.n, 0), kf.ocurrido_en
  from productos p
  -- El ultimo movimiento antes del cierre. Si no hay ninguno, el producto
  -- no existia en esta sucursal todavia y no tiene nada que decir.
  join lateral (
    select k.saldo_cantidad, k.saldo_valor, k.ocurrido_en
    from kardex k
    where k.producto_id = p.id and k.sucursal_id = v_suc
      and k.ocurrido_en < v_fin
    order by k.ocurrido_en desc, k.id desc
    limit 1) kf on true
  left join lateral (
    select k.saldo_cantidad, k.saldo_valor
    from kardex k
    where k.producto_id = p.id and k.sucursal_id = v_suc
      and k.ocurrido_en < v_ini
    order by k.ocurrido_en desc, k.id desc
    limit 1) ki on true
  left join lateral (
    select sum(k.cantidad)          filter (where k.cantidad > 0) as entradas,
           sum(k.costo_total)       filter (where k.cantidad > 0) as valor_entradas,
           sum(abs(k.cantidad))     filter (where k.cantidad < 0) as salidas,
           sum(k.costo_total)       filter (where k.cantidad < 0) as valor_salidas,
           count(*)::int                                          as n
    from kardex k
    where k.producto_id = p.id and k.sucursal_id = v_suc
      and k.ocurrido_en >= v_ini and k.ocurrido_en < v_fin) mv on true
  where p.organizacion_id = v_org
    and p.tipo <> 'servicio'
    and (p_categoria_id is null or p.categoria_id = p_categoria_id)
    and (v_buscar is null
         or p.nombre ilike '%' || v_buscar || '%'
         or p.sku ilike v_buscar || '%'
         or exists (select 1 from producto_codigos pc
                     where pc.producto_id = p.id and pc.codigo = v_buscar))
    and (not coalesce(p_solo_movidos, false) or coalesce(mv.n, 0) > 0)
  )
  select jsonb_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    'sucursal_id', v_suc,
    'sucursal', (select nombre from sucursales where id = v_suc),
    'puede_ver_costos', v_ve,

    'totales', jsonb_build_object(
      'productos',       (select count(*) from inv),
      'con_movimiento',  (select count(*) from inv where movimientos > 0),
      'movimientos',     (select coalesce(sum(movimientos), 0) from inv),
      'no_cuadran',      (select count(*) from inv
                           where inicial + entradas - salidas <> final),
      'valor_inicial',   case when v_ve then (select round(coalesce(sum(valor_inicial), 0), 2) from inv) end,
      'valor_entradas',  case when v_ve then (select round(coalesce(sum(valor_entradas), 0), 2) from inv) end,
      'valor_salidas',   case when v_ve then (select round(coalesce(sum(valor_salidas), 0), 2) from inv) end,
      'valor_final',     case when v_ve then (select round(coalesce(sum(valor_final), 0), 2) from inv) end),

    -- Por tipo de movimiento, de toda la sucursal (respeta los mismos
    -- filtros de producto que la lista).
    'por_tipo', coalesce((
      select jsonb_agg(jsonb_build_object(
               'tipo', x.tipo,
               'nombre', app.nombre_movimiento(x.tipo),
               'entrada', app.es_entrada(x.tipo),
               'movimientos', x.n,
               'unidades', x.u,
               'valor', case when v_ve then round(x.v, 2) end)
               order by app.es_entrada(x.tipo) desc, x.u desc)
      from (
        select k.tipo, count(*)::int as n, sum(abs(k.cantidad)) as u,
               sum(k.costo_total) as v
        from kardex k
        where k.sucursal_id = v_suc
          and k.ocurrido_en >= v_ini and k.ocurrido_en < v_fin
          and k.producto_id in (select producto_id from inv)
        group by k.tipo) x), '[]'::jsonb),

    'productos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'producto_id', f.producto_id,
               'nombre',      f.nombre,
               'sku',         f.sku,
               'unidad',      f.unidad,
               'categoria',   f.categoria,
               'inicial',     f.inicial,
               'entradas',    f.entradas,
               'salidas',     f.salidas,
               'final',       f.final,
               'movimientos', f.movimientos,
               'ultimo',      f.ultimo,
               'cuadra',      f.inicial + f.entradas - f.salidas = f.final,
               'valor_inicial',  case when v_ve then round(f.valor_inicial, 2) end,
               'valor_entradas', case when v_ve then round(f.valor_entradas, 2) end,
               'valor_salidas',  case when v_ve then round(f.valor_salidas, 2) end,
               'valor_final',    case when v_ve then round(f.valor_final, 2) end)
               order by f.nombre)
      from (select * from inv order by nombre limit v_lim) f), '[]'::jsonb),

    'truncado', (select count(*) from inv) > v_lim,
    'limite', v_lim
  ) into r;

  return r;
end $fn$;

revoke execute on function fn_inventario_por_fecha(date, date, uuid, text, uuid, boolean, int)
  from public, anon;
grant execute on function fn_inventario_por_fecha(date, date, uuid, text, uuid, boolean, int)
  to authenticated;


-- ---------------------------------------------------------------------------
-- 3. El kardex de un producto en un periodo
--
--    Cada movimiento con su saldo despues, el documento que lo causo y quien
--    lo hizo. Si hay mas de p_limite, vienen los ULTIMOS (lo reciente es lo
--    que se revisa) y se avisa; los saldos siguen siendo exactos porque son
--    los del kardex, no una suma hecha aqui.
-- ---------------------------------------------------------------------------
create or replace function fn_kardex_producto(
  p_producto_id uuid,
  p_desde       date,
  p_hasta       date,
  p_sucursal_id uuid default null,
  p_limite      int  default 300
) returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org   uuid;
  v_tz    text;
  v_suc   uuid;
  v_ve    boolean;
  v_ini   timestamptz;
  v_fin   timestamptz;
  v_lim   int;
  v_n     int;
  p       record;
  ki      record;
  kf      record;
  r       jsonb;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('supervisor'))) then
    raise exception 'El kardex es para supervisor en adelante';
  end if;

  if p_desde is null or p_hasta is null then
    raise exception 'Indique las dos fechas del periodo';
  end if;
  if p_desde > p_hasta then
    raise exception 'La fecha inicial es posterior a la final';
  end if;

  select * into p from productos
   where id = p_producto_id and (organizacion_id = v_org or app.es_admin());
  if p.id is null then raise exception 'Ese producto no es de su negocio'; end if;

  v_suc := app.sucursal_para_reporte(p_sucursal_id);
  v_tz  := app.zona(v_org);
  v_ve  := app.es_admin() or app.tiene_nivel('gerente');
  v_lim := least(greatest(coalesce(p_limite, 300), 1), 1000);

  v_ini := p_desde::timestamp at time zone v_tz;
  v_fin := (p_hasta + 1)::timestamp at time zone v_tz;

  select k.saldo_cantidad, k.saldo_valor into ki
  from kardex k
  where k.producto_id = p.id and k.sucursal_id = v_suc and k.ocurrido_en < v_ini
  order by k.ocurrido_en desc, k.id desc limit 1;

  select k.saldo_cantidad, k.saldo_valor into kf
  from kardex k
  where k.producto_id = p.id and k.sucursal_id = v_suc and k.ocurrido_en < v_fin
  order by k.ocurrido_en desc, k.id desc limit 1;

  select count(*) into v_n
  from kardex k
  where k.producto_id = p.id and k.sucursal_id = v_suc
    and k.ocurrido_en >= v_ini and k.ocurrido_en < v_fin;

  select jsonb_build_object(
    'producto_id', p.id,
    'nombre',      p.nombre,
    'sku',         p.sku,
    'unidad',      p.unidad_base,
    'sucursal_id', v_suc,
    'sucursal',    (select nombre from sucursales where id = v_suc),
    'desde',       p_desde,
    'hasta',       p_hasta,
    'puede_ver_costos', v_ve,

    'inicial',       coalesce(ki.saldo_cantidad, 0),
    'final',         coalesce(kf.saldo_cantidad, 0),
    'valor_inicial', case when v_ve then round(coalesce(ki.saldo_valor, 0), 2) end,
    'valor_final',   case when v_ve then round(coalesce(kf.saldo_valor, 0), 2) end,
    'entradas', coalesce((select sum(k.cantidad) from kardex k
                           where k.producto_id = p.id and k.sucursal_id = v_suc
                             and k.cantidad > 0
                             and k.ocurrido_en >= v_ini and k.ocurrido_en < v_fin), 0),
    'salidas',  coalesce((select sum(abs(k.cantidad)) from kardex k
                           where k.producto_id = p.id and k.sucursal_id = v_suc
                             and k.cantidad < 0
                             and k.ocurrido_en >= v_ini and k.ocurrido_en < v_fin), 0),
    'total_movimientos', v_n,
    'truncado', v_n > v_lim,

    'movimientos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',          m.id,
               'fecha',       m.ocurrido_en,
               'tipo',        m.tipo,
               'nombre_tipo', app.nombre_movimiento(m.tipo),
               'cantidad',    m.cantidad,
               'saldo',       m.saldo_cantidad,
               'lote',        (select l.codigo from lotes l where l.id = m.lote_id),
               'documento_tipo', m.documento_tipo,
               'documento',   app.numero_de_documento(m.documento_tipo, m.documento_id),
               'usuario',     (select pf.nombre from perfiles pf where pf.id = m.usuario_id),
               'notas',       m.notas,
               'costo_unitario',  case when v_ve then round(m.costo_unitario, 4) end,
               'costo_total',     case when v_ve then round(m.costo_total, 2) end,
               'costo_promedio',  case when v_ve then round(m.costo_promedio_resultante, 4) end,
               'saldo_valor',     case when v_ve then round(m.saldo_valor, 2) end)
               order by m.ocurrido_en, m.id)
      from (
        select k.* from kardex k
        where k.producto_id = p.id and k.sucursal_id = v_suc
          and k.ocurrido_en >= v_ini and k.ocurrido_en < v_fin
        order by k.ocurrido_en desc, k.id desc
        limit v_lim) m), '[]'::jsonb)
  ) into r;

  return r;
end $fn$;

revoke execute on function fn_kardex_producto(uuid, date, date, uuid, int) from public, anon;
grant execute on function fn_kardex_producto(uuid, date, date, uuid, int) to authenticated;
