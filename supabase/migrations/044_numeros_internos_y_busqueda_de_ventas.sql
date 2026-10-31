-- ============================================================================
--  Migración 044 · Números internos y búsqueda de ventas
--
--  1. EL ITEM DEL PRODUCTO: 5 DÍGITOS AL AZAR (51089)
--     Lo pone el sistema al crear el producto, venga de Catálogos, de
--     Compras («producto nuevo desde la factura») o del Excel. Va en
--     productos.sku, que es lo que la caja, las etiquetas y las búsquedas ya
--     usan como código interno.
--
--     Si el producto llegó con un código que no es de 5 dígitos (el del
--     Excel, "ARR5LB"), ese código NO se pierde: queda como un código más
--     del producto (producto_codigos), así se sigue encontrando escaneando o
--     buscando por él, y volver a importar el mismo Excel lo reconoce.
--     Los que el propio sistema inventaba de relleno (P00012 del Excel,
--     N0003 de Compras) no se guardan: no los conoce nadie.
--
--     El servicio de envío (SERV-ENVIO) se queda como está: el sistema lo
--     busca por ese nombre.
--
--  2. NÚMEROS DE CATEGORÍA, PROVEEDOR Y CLIENTE
--       categoría  01 – 99 (y hasta 999 si hicieran falta)
--       proveedor  1001 – 99999
--       cliente    1001 – 99999
--     El siguiente libre del negocio. Nadie los cambia desde la app.
--
--  3. fn_buscar_ventas: el historial con todos los filtros (monto, hora,
--     producto, caja, cajero, cliente, forma de pago, efectivo recibido y
--     cambio). Recibe y devuelve jsonb para que agregar un filtro mañana no
--     obligue a cambiar la firma (y cambiar la firma exige un drop que la
--     herramienta de Supabase no deja).
--
--  Sin drops: se aplica completa desde la herramienta de Supabase.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. El item del producto
-- ---------------------------------------------------------------------------
create or replace function app.nuevo_item(p_org uuid)
returns text language plpgsql volatile set search_path = public, app as $fn$
declare v text; i int := 0;
begin
  loop
    v := (10000 + floor(random() * 90000))::int::text;
    exit when not exists (select 1 from productos where organizacion_id = p_org and sku = v);
    i := i + 1;
    if i > 200 then raise exception 'No se encontró un item libre de 5 dígitos'; end if;
  end loop;
  return v;
end $fn$;

-- ¿Es uno de los códigos de relleno que el propio sistema inventaba?
create or replace function app.es_sku_de_relleno(p text)
returns boolean language sql immutable as $fn$
  select coalesce(p, '') = '' or p ~ '^P\d{5}$' or p ~ '^N\d{4}$'
$fn$;

create or replace function app.productos_item()
returns trigger language plpgsql set search_path = public, app as $fn$
declare v_orig text;
begin
  if tg_op = 'UPDATE' then
    if old.sku ~ '^\d{5}$' and new.sku is distinct from old.sku and not app.es_admin() then
      raise exception 'El item lo asigna el sistema y no cambia';
    end if;
    return new;
  end if;

  v_orig := btrim(coalesce(new.sku, ''));
  if v_orig like 'SERV-%' then return new; end if;
  if v_orig ~ '^\d{5}$' and not exists (select 1 from productos
                                         where organizacion_id = new.organizacion_id and sku = v_orig) then
    new.sku := v_orig;
    return new;
  end if;

  new.sku := app.nuevo_item(new.organizacion_id);
  -- El código con que llegó se guarda después del insert, cuando el
  -- producto ya existe (producto_codigos lo referencia).
  if not app.es_sku_de_relleno(v_orig) then
    perform set_config('app.sku_original_' || replace(new.id::text, '-', ''), v_orig, true);
  end if;
  return new;
end $fn$;

create or replace function app.productos_item_alias()
returns trigger language plpgsql set search_path = public, app as $fn$
declare v_orig text;
begin
  v_orig := nullif(current_setting('app.sku_original_' || replace(new.id::text, '-', ''), true), '');
  if v_orig is not null then
    insert into producto_codigos (organizacion_id, producto_id, codigo, es_principal)
    values (new.organizacion_id, new.id, v_orig, false)
    on conflict (organizacion_id, codigo) do nothing;
    perform set_config('app.sku_original_' || replace(new.id::text, '-', ''), '', true);
  end if;
  return null;
end $fn$;

create or replace trigger tg_productos_item
  before insert or update on productos
  for each row execute function app.productos_item();

create or replace trigger tg_productos_item_alias
  after insert on productos
  for each row execute function app.productos_item_alias();

-- Los productos que ya existen: el código viejo queda como código del
-- producto y el item pasa a ser de 5 dígitos.
do $$
declare r record;
begin
  for r in select id, organizacion_id, sku from productos
            where sku !~ '^\d{5}$' and sku not like 'SERV-%' order by creado_en loop
    if not app.es_sku_de_relleno(r.sku) then
      insert into producto_codigos (organizacion_id, producto_id, codigo, es_principal)
      values (r.organizacion_id, r.id, r.sku, false)
      on conflict (organizacion_id, codigo) do nothing;
    end if;
    update productos set sku = app.nuevo_item(r.organizacion_id) where id = r.id;
  end loop;
end $$;


-- ---------------------------------------------------------------------------
-- 2. Números de categoría, proveedor y cliente
--    Un solo disparador para las tres: el rango viene en sus argumentos.
-- ---------------------------------------------------------------------------
alter table categorias  add column if not exists numero int;
alter table proveedores add column if not exists numero int;
alter table clientes    add column if not exists numero int;

create or replace function app.asignar_numero()
returns trigger language plpgsql set search_path = public, app as $fn$
declare
  v_desde int := tg_argv[0]::int;
  v_hasta int := tg_argv[1]::int;
  v_viejo int;
  v_nuevo int;
  v int;
begin
  v_nuevo := (to_jsonb(new) ->> 'numero')::int;
  if tg_op = 'UPDATE' then
    v_viejo := (to_jsonb(old) ->> 'numero')::int;
    if v_viejo is not null and v_nuevo is distinct from v_viejo and not app.es_admin() then
      raise exception 'Ese número lo asigna el sistema y no cambia';
    end if;
    return new;
  end if;
  if v_nuevo is not null then return new; end if;

  perform pg_advisory_xact_lock(hashtext(tg_table_name || ':' || new.organizacion_id::text));
  execute format('select coalesce(max(numero), $2 - 1) + 1 from %I where organizacion_id = $1',
                 tg_table_name)
     into v using new.organizacion_id, v_desde;
  if v > v_hasta then
    -- se acabó el rango: el primer hueco
    execute format('select n from generate_series($2, $3) n
                     where not exists (select 1 from %I t where t.organizacion_id = $1 and t.numero = n)
                     order by n limit 1', tg_table_name)
       into v using new.organizacion_id, v_desde, v_hasta;
    if v is null then raise exception 'Se acabaron los números de %', tg_table_name; end if;
  end if;
  new := jsonb_populate_record(new, jsonb_build_object('numero', v));
  return new;
end $fn$;

create or replace trigger tg_categorias_numero
  before insert or update on categorias
  for each row execute function app.asignar_numero('1', '999');
create or replace trigger tg_proveedores_numero
  before insert or update on proveedores
  for each row execute function app.asignar_numero('1001', '99999');
create or replace trigger tg_clientes_numero
  before insert or update on clientes
  for each row execute function app.asignar_numero('1001', '99999');

-- Los que ya existen, en el orden en que se crearon. Las categorías no
-- tienen fecha de creación confiable entre sí: van por nombre.
with r as (select id, row_number() over (partition by organizacion_id order by orden, nombre, id) as n
             from categorias where numero is null)
update categorias c set numero = r.n from r where c.id = r.id;
with r as (select id, 1000 + row_number() over (partition by organizacion_id order by creado_en, id) as n
             from proveedores where numero is null)
update proveedores p set numero = r.n from r where p.id = r.id;
with r as (select id, 1000 + row_number() over (partition by organizacion_id order by creado_en, id) as n
             from clientes where numero is null)
update clientes c set numero = r.n from r where c.id = r.id;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'categorias_numero_key') then
    alter table categorias add constraint categorias_numero_key unique (organizacion_id, numero);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'proveedores_numero_key') then
    alter table proveedores add constraint proveedores_numero_key unique (organizacion_id, numero);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'clientes_numero_key') then
    alter table clientes add constraint clientes_numero_key unique (organizacion_id, numero);
  end if;
end $$;

-- El disparador de productos corre con los permisos de quien inserta (el
-- gerente desde Catálogos), así que estas dos tienen que poder llamarse.
-- Solo devuelven un número libre y si un texto es de relleno.
revoke execute on function app.nuevo_item(uuid) from public, anon;
grant execute on function app.nuevo_item(uuid) to authenticated;
revoke execute on function app.es_sku_de_relleno(text) from public, anon;
grant execute on function app.es_sku_de_relleno(text) to authenticated;
revoke execute on function app.productos_item() from public, anon, authenticated;
revoke execute on function app.productos_item_alias() from public, anon, authenticated;
revoke execute on function app.asignar_numero() from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- 3. Buscar ventas con todos los filtros
--
--    p_filtros (todo opcional):
--      desde, hasta            fechas (días de Honduras)
--      hora_desde, hora_hasta  'HH:MM' hora local; si desde > hasta cruza la
--                              medianoche (22:00 a 02:00)
--      sucursal_id, caja_id, cajero_id
--      buscar                  número de ticket, factura, código del ticket o cliente
--      cliente                 nombre, teléfono o número del cliente
--      producto                nombre, item o código de barras
--      metodo                  efectivo · tarjeta · transferencia · credito · otro
--      monto_min, monto_max    total de la venta
--      efectivo_min, efectivo_max   lo que el cliente entregó en efectivo
--      cambio_min, cambio_max       el cambio que se le dio
--      estado                  completada · anulada
--      limite                  filas a devolver (el resumen cuenta todas)
--
--    Para los descuadres: "efectivo recibido de 500" y "cambio mayor de 100"
--    encuentran el billete que se contó como de 500 y era de 100.
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
  v_met    text := nullif(f->>'metodo', '');
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
       and (f->>'sucursal_id' is null or v.sucursal_id = (f->>'sucursal_id')::uuid)
       and (f->>'caja_id'     is null or v.caja_id     = (f->>'caja_id')::uuid)
       and (f->>'cajero_id'   is null or v.cajero_id   = (f->>'cajero_id')::uuid)
       and (v_desde is null or v.creada_en >= (v_desde::timestamp at time zone v_tz))
       and (v_hasta is null or v.creada_en <  ((v_hasta + 1)::timestamp at time zone v_tz))
       and (f->>'estado' is null or v.estado::text = f->>'estado')
       and (f->>'monto_min' is null or v.total >= (f->>'monto_min')::numeric)
       and (f->>'monto_max' is null or v.total <= (f->>'monto_max')::numeric)
       and (v_hd is null or v_hh is null
            or case when v_hd <= v_hh
                    then (v.creada_en at time zone v_tz)::time between v_hd and v_hh
                    else (v.creada_en at time zone v_tz)::time >= v_hd
                      or (v.creada_en at time zone v_tz)::time <= v_hh end)
       and (v_hd is null or v_hh is not null or (v.creada_en at time zone v_tz)::time >= v_hd)
       and (v_hh is null or v_hd is not null or (v.creada_en at time zone v_tz)::time <= v_hh)
       and (v_met is null or exists (select 1 from pagos_venta pv
                                      where pv.venta_id = v.id and pv.metodo::text = v_met))
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
-- 4. Importar desde Excel: el sku del Excel también se busca entre los
--    códigos del producto. Solo cambia esa búsqueda; el resto es la 042.
-- ---------------------------------------------------------------------------
create or replace function fn_importar_productos(
  p_filas jsonb, p_sucursal_id uuid default null, p_actualizar boolean default true
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org   uuid := app.org_id();
  v_suc   uuid;
  f       jsonb;
  n       int := 0;
  v_creados int := 0; v_act int := 0; v_exis int := 0; v_omit int := 0;
  errores jsonb := '[]'::jsonb;
  avisos  jsonb := '[]'::jsonb;
  v_pid   uuid;
  v_nuevo boolean;
  v_cat uuid; v_mar uuid; v_prov uuid; v_imp uuid;
  v_sku text; v_nom text; v_cod text;
  v_precio numeric; v_costo numeric; v_exist numeric;
  v_tipo tipo_producto;
  v_hay numeric;
  v_tasa numeric;
  txt text;
begin
  if v_org is null or not app.tiene_nivel('gerente') then
    raise exception 'Solo el gerente importa el catálogo';
  end if;
  if jsonb_typeof(p_filas) <> 'array' then raise exception 'Se esperaba una lista de filas'; end if;
  if jsonb_array_length(p_filas) > 500 then raise exception 'Mande de 500 filas a la vez como mucho'; end if;

  v_suc := coalesce(p_sucursal_id, (select id from sucursales where organizacion_id = v_org and activa
                                      order by es_principal desc limit 1));
  if not exists (select 1 from sucursales where id = v_suc and organizacion_id = v_org) then
    raise exception 'Esa sucursal no es de su negocio';
  end if;

  for f in select * from jsonb_array_elements(p_filas) loop
    n := n + 1;
    begin
      v_sku := nullif(btrim(f->>'sku'), '');
      v_nom := nullif(btrim(f->>'nombre'), '');
      v_cod := nullif(btrim(f->>'codigo'), '');
      v_precio := nullif(f->>'precio', '')::numeric;
      v_costo  := nullif(f->>'costo', '')::numeric;
      v_exist  := nullif(f->>'existencia', '')::numeric;

      if v_precio is not null and v_precio < 0 then raise exception 'El precio no puede ser negativo'; end if;
      if v_costo is not null and v_costo < 0 then raise exception 'El costo no puede ser negativo'; end if;
      if v_exist is not null and v_exist < 0 then raise exception 'La existencia no puede ser negativa'; end if;

      -- ¿ya existe?
      v_pid := null;
      if v_sku is not null then
        select id into v_pid from productos where organizacion_id = v_org and upper(sku) = upper(v_sku);
        -- Desde la 044 el item es de 5 dígitos y el código viejo quedó como
        -- código del producto: el mismo Excel de antes lo sigue encontrando.
        if v_pid is null then
          select producto_id into v_pid from producto_codigos
           where organizacion_id = v_org and upper(codigo) = upper(v_sku) limit 1;
        end if;
      end if;
      if v_pid is null and v_cod is not null then
        select producto_id into v_pid from producto_codigos
         where organizacion_id = v_org
           and codigo = btrim(split_part(replace(v_cod, ',', ';'), ';', 1));
      end if;
      v_nuevo := v_pid is null;

      if v_nuevo and v_nom is null then raise exception 'Falta el nombre'; end if;
      if not v_nuevo and not p_actualizar then
        v_omit := v_omit + 1;
        continue;
      end if;

      -- categoría, marca y proveedor por nombre; si no existen se crean
      v_cat := null; v_mar := null; v_prov := null; v_imp := null;
      txt := nullif(btrim(f->>'categoria'), '');
      if txt is not null then
        select id into v_cat from categorias where organizacion_id = v_org and lower(nombre) = lower(txt) limit 1;
        if v_cat is null then
          insert into categorias (organizacion_id, nombre) values (v_org, txt) returning id into v_cat;
        end if;
      end if;
      txt := nullif(btrim(f->>'marca'), '');
      if txt is not null then
        select id into v_mar from marcas where organizacion_id = v_org and lower(nombre) = lower(txt) limit 1;
        if v_mar is null then
          insert into marcas (organizacion_id, nombre) values (v_org, txt) returning id into v_mar;
        end if;
      end if;
      txt := nullif(btrim(f->>'proveedor'), '');
      if txt is not null then
        select id into v_prov from proveedores where organizacion_id = v_org and lower(nombre) = lower(txt) limit 1;
        if v_prov is null then
          insert into proveedores (organizacion_id, nombre) values (v_org, txt) returning id into v_prov;
        end if;
      end if;
      txt := nullif(btrim(lower(f->>'impuesto')), '');
      if txt is not null then
        v_tasa := case when txt in ('exento', 'no', 'e') then 0
                       else replace(replace(txt, '%', ''), ',', '.')::numeric end;
        if v_tasa > 1 then v_tasa := v_tasa / 100; end if;
        select id into v_imp from impuestos where organizacion_id = v_org and activo
           and abs(tasa - v_tasa) < 0.0001 order by es_predeterminado desc limit 1;
        if v_imp is null then raise exception 'No hay un impuesto de %%% en Configuración', round(v_tasa * 100, 2); end if;
      end if;
      v_tipo := case lower(coalesce(nullif(btrim(f->>'tipo'), ''), ''))
                  when 'peso' then 'peso' when 'granel' then 'granel' when 'servicio' then 'servicio'
                  when 'unidad' then 'unidad' else null end;

      if v_nuevo then
        insert into productos (organizacion_id, sku, nombre, categoria_id, marca_id, proveedor_id,
                               impuesto_id, tipo, unidad_base, stock_minimo, stock_maximo,
                               unidades_empaque, controla_lote, controla_vencimiento)
        values (v_org,
                coalesce(v_sku, 'P' || lpad((select count(*) + 1 from productos where organizacion_id = v_org)::text, 5, '0')),
                v_nom, v_cat, v_mar, v_prov,
                coalesce(v_imp, (select id from impuestos where organizacion_id = v_org and es_predeterminado and activo limit 1)),
                coalesce(v_tipo, 'unidad'),
                coalesce(nullif(btrim(f->>'unidad'), ''), 'UND'),
                coalesce(nullif(f->>'minimo', '')::numeric, 0),
                nullif(f->>'maximo', '')::numeric,
                nullif(f->>'empaque', '')::numeric,
                coalesce(lower(f->>'vence') in ('si', 'sí', 's', 'x', 'true', '1'), false),
                coalesce(lower(f->>'vence') in ('si', 'sí', 's', 'x', 'true', '1'), false))
        returning id into v_pid;
        v_creados := v_creados + 1;
      else
        update productos set
          nombre       = coalesce(v_nom, nombre),
          categoria_id = coalesce(v_cat, categoria_id),
          marca_id     = coalesce(v_mar, marca_id),
          proveedor_id = coalesce(v_prov, proveedor_id),
          impuesto_id  = coalesce(v_imp, impuesto_id),
          tipo         = coalesce(v_tipo, tipo),
          unidad_base  = coalesce(nullif(btrim(f->>'unidad'), ''), unidad_base),
          stock_minimo = coalesce(nullif(f->>'minimo', '')::numeric, stock_minimo),
          stock_maximo = coalesce(nullif(f->>'maximo', '')::numeric, stock_maximo),
          unidades_empaque = coalesce(nullif(f->>'empaque', '')::numeric, unidades_empaque),
          actualizado_en = now()
         where id = v_pid;
        v_act := v_act + 1;
      end if;

      -- códigos de barras: se agregan los que falten
      if v_cod is not null then
        insert into producto_codigos (organizacion_id, producto_id, codigo, es_principal)
        select v_org, v_pid, c, not exists (select 1 from producto_codigos where producto_id = v_pid)
          from (select distinct btrim(x) as c
                  from unnest(string_to_array(replace(v_cod, ',', ';'), ';')) x) cs
         where c <> ''
        on conflict (organizacion_id, codigo) do nothing;
        if exists (select 1 from unnest(string_to_array(replace(v_cod, ',', ';'), ';')) x
                    join producto_codigos pc on pc.organizacion_id = v_org and pc.codigo = btrim(x)
                   where pc.producto_id <> v_pid) then
          avisos := avisos || jsonb_build_object('fila', n,
                      'mensaje', 'Un código ya era de otro producto y no se cambió');
        end if;
      end if;

      if v_precio is not null and v_precio > 0 then
        perform app.fijar_precio_base(v_org, v_pid, v_precio);
      end if;

      -- existencia inicial, con su costo
      if v_exist is not null and v_exist > 0 then
        select coalesce(sum(cantidad), 0) into v_hay from existencias
         where producto_id = v_pid and sucursal_id = v_suc;
        if v_hay <> 0 then
          avisos := avisos || jsonb_build_object('fila', n,
                      'mensaje', 'Ya tenía existencia: no se cambió. Corríjala con un conteo');
        elsif v_costo is null then
          avisos := avisos || jsonb_build_object('fila', n,
                      'mensaje', 'Sin costo no se carga la existencia');
        else
          perform fn_kardex_registrar(v_suc, v_pid, 'inventario_inicial', v_exist, v_costo,
                                      null, 'importacion', null, 'Importado desde Excel', auth.uid());
          v_exis := v_exis + 1;
        end if;
      end if;

    exception when others then
      errores := errores || jsonb_build_object('fila', n, 'sku', v_sku, 'nombre', v_nom,
                                               'mensaje', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('filas', n, 'creados', v_creados, 'actualizados', v_act,
                            'omitidos', v_omit, 'existencias', v_exis,
                            'errores', errores, 'avisos', avisos);
end $fn$;

revoke execute on function fn_importar_productos(jsonb, uuid, boolean) from public, anon;
grant execute on function fn_importar_productos(jsonb, uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
