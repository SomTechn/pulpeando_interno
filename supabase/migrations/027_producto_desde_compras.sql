-- ===========================================================================
-- 027 · Dar de alta un producto desde Compras
--
-- Cuando llega mercaderia nueva, quien recibe no tiene por que dejar la
-- factura a medias, ir a Catalogos y volver. Esta funcion crea el producto,
-- su codigo de barras y su precio en un solo paso, y Compras lo agrega a la
-- entrada de una vez.
--
-- Permisos, respetando la matriz del README:
--   · supervisor en adelante puede crear el producto (recibir mercaderia es
--     de supervisor)
--   · el PRECIO de venta solo lo pone el gerente. Si lo crea un supervisor,
--     el producto queda sin precio: entra al inventario pero no aparece en la
--     caja hasta que el gerente le ponga precio en Catalogos. La funcion lo
--     devuelve en 'precio_pendiente' para que la pantalla lo diga.
--
-- Validaciones que en Catalogos hace la base por las restricciones, aqui con
-- mensajes claros: codigo interno repetido y codigo de barras que ya es de
-- otro producto (el error tipico de escanear la caja en vez de la unidad).
-- ===========================================================================

create or replace function fn_crear_producto_compra(
  p_nombre               text,
  p_codigo_barras        text    default null,
  p_sku                  text    default null,
  p_categoria_id         uuid    default null,
  p_impuesto_id          uuid    default null,
  p_precio               numeric default null,
  p_unidad               text    default 'UND',
  p_controla_vencimiento boolean default false,
  p_unidades_empaque     numeric default null,
  p_proveedor_id         uuid    default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org     uuid;
  v_gerente boolean;
  v_nombre  text;
  v_barras  text;
  v_sku     text;
  v_imp     uuid;
  v_otro    text;
  v_id      uuid;
  v_n       int;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('supervisor'))) then
    raise exception 'Crear productos es de supervisor en adelante';
  end if;
  v_gerente := app.es_admin() or app.tiene_nivel('gerente');

  v_nombre := nullif(btrim(regexp_replace(coalesce(p_nombre, ''), '\s+', ' ', 'g')), '');
  if v_nombre is null then raise exception 'Escriba el nombre del producto'; end if;
  if length(v_nombre) > 120 then raise exception 'El nombre es demasiado largo'; end if;

  v_barras := nullif(btrim(coalesce(p_codigo_barras, '')), '');
  v_sku    := nullif(upper(btrim(coalesce(p_sku, ''))), '');

  -- Ningun otro producto del negocio con el mismo nombre exacto: casi
  -- siempre es que ya existia y no lo encontraron.
  select sku into v_otro from productos
   where organizacion_id = v_org and lower(nombre) = lower(v_nombre) limit 1;
  if v_otro is not null then
    raise exception 'Ya existe un producto con ese nombre (código %). Búsquelo en vez de crearlo otra vez', v_otro;
  end if;

  if v_barras is not null then
    select p.nombre into v_otro
    from producto_codigos pc join productos p on p.id = pc.producto_id
    where pc.organizacion_id = v_org and pc.codigo = v_barras limit 1;
    if v_otro is not null then
      raise exception 'Ese código de barras ya es de «%»', v_otro;
    end if;
  end if;

  if v_sku is not null then
    perform 1 from productos where organizacion_id = v_org and sku = v_sku;
    if found then raise exception 'El código interno % ya lo tiene otro producto', v_sku; end if;
  else
    -- Sin codigo interno: se usa el de barras si no choca; si no, N0001,
    -- N0002… (N de "nuevo", para que se vea que se creo al vuelo).
    if v_barras is not null and not exists
         (select 1 from productos where organizacion_id = v_org and sku = upper(v_barras)) then
      v_sku := upper(v_barras);
    else
      select count(*) + 1 into v_n from productos where organizacion_id = v_org;
      loop
        v_sku := 'N' || lpad(v_n::text, 4, '0');
        exit when not exists (select 1 from productos where organizacion_id = v_org and sku = v_sku);
        v_n := v_n + 1;
      end loop;
    end if;
  end if;

  if p_categoria_id is not null then
    perform 1 from categorias where id = p_categoria_id and organizacion_id = v_org;
    if not found then raise exception 'Esa categoría no es de su negocio'; end if;
  end if;

  if p_proveedor_id is not null then
    perform 1 from proveedores where id = p_proveedor_id and organizacion_id = v_org;
    if not found then raise exception 'Ese proveedor no es de su negocio'; end if;
  end if;

  -- El impuesto: el elegido, o el predeterminado del negocio
  if p_impuesto_id is not null then
    select id into v_imp from impuestos where id = p_impuesto_id and organizacion_id = v_org;
    if v_imp is null then raise exception 'Ese impuesto no es de su negocio'; end if;
  else
    select id into v_imp from impuestos
     where organizacion_id = v_org and es_predeterminado and activo limit 1;
  end if;

  if p_precio is not null and p_precio < 0 then
    raise exception 'El precio no puede ser negativo';
  end if;
  if p_unidades_empaque is not null and p_unidades_empaque <= 0 then
    raise exception 'Las unidades por caja deben ser mayores a cero';
  end if;

  insert into productos (organizacion_id, sku, nombre, categoria_id, impuesto_id,
                         proveedor_id, unidad_base, controla_vencimiento,
                         unidades_empaque, tipo, se_vende, se_compra, activo)
  values (v_org, v_sku, v_nombre, p_categoria_id, v_imp, p_proveedor_id,
          coalesce(nullif(upper(btrim(p_unidad)), ''), 'UND'),
          coalesce(p_controla_vencimiento, false), p_unidades_empaque,
          'unidad', true, true, true)
  returning id into v_id;

  if v_barras is not null then
    insert into producto_codigos (organizacion_id, producto_id, codigo, es_principal)
    values (v_org, v_id, v_barras, true);
  end if;

  -- Precio: solo si lo pone el gerente
  if v_gerente and coalesce(p_precio, 0) > 0 then
    insert into precios (organizacion_id, producto_id, precio, nivel, cantidad_minima)
    values (v_org, v_id, p_precio, 'detalle', 1);
  end if;

  return jsonb_build_object(
    'producto_id', v_id,
    'sku', v_sku,
    'nombre', v_nombre,
    'codigo_barras', v_barras,
    'precio', case when v_gerente and coalesce(p_precio, 0) > 0 then p_precio end,
    'precio_pendiente', not (v_gerente and coalesce(p_precio, 0) > 0),
    'precio_ignorado', not v_gerente and coalesce(p_precio, 0) > 0);
end $fn$;

revoke execute on function fn_crear_producto_compra(text, text, text, uuid, uuid, numeric, text, boolean, numeric, uuid)
  from public, anon;
grant execute on function fn_crear_producto_compra(text, text, text, uuid, uuid, numeric, text, boolean, numeric, uuid)
  to authenticated;

notify pgrst, 'reload schema';
