-- ============================================================================
--  Migración 042 · Lo que pide una abarrotería grande
--
--    1. AUTORIZACIÓN DEL SUPERVISOR EN LA CAJA
--       Quitar productos ya marcados, cancelar la venta y borrar ventas en
--       espera pueden pedir código y PIN de un supervisor. Cada negocio
--       escoge cuáles (organizaciones.config.caja_autoriza). El permiso es
--       una autorización de un solo uso que el servidor emite; el evento de
--       caja la consume y así queda quién autorizó.
--
--    2. VENCIMIENTOS: fn_vencimientos, para la pantalla del mismo nombre.
--
--    3. IMPORTAR EL CATÁLOGO desde Excel (fn_importar_productos) y CAMBIAR
--       PRECIOS EN LOTE (fn_cambiar_precios), con vista previa.
--
--    4. PROMOCIONES: lleva N paga M (2x1, 3x2), N por L X (3 por L 100) y
--       descuento %, por producto, categoría o marca, con fechas y días de
--       la semana. El descuento lo calcula SIEMPRE el servidor al cobrar
--       (app.descuentos_promo): el descuento que mande la caja se ignora.
--       La caja hace la misma cuenta (promos.js) para enseñarla antes de
--       cobrar; las dos trabajan en centavos enteros para que den igual.
-- ============================================================================


-- ===========================================================================
-- 1. Autorización del supervisor
-- ===========================================================================
create table if not exists autorizaciones_caja (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references organizaciones(id) on delete cascade,
  autorizo        uuid not null references perfiles(id),
  pidio           uuid not null references perfiles(id),
  accion          text not null check (accion in ('quitar', 'cancelar', 'descartar')),
  creada_en       timestamptz not null default now(),
  usada_en        timestamptz
);
alter table autorizaciones_caja enable row level security;
revoke all on autorizaciones_caja from anon, authenticated;

alter table eventos_caja add column if not exists autorizo uuid references perfiles(id);

-- Pide código y PIN de un supervisor. Como app.quien_autoriza, NO lanza con
-- credencial mala: devuelve {ok:false}, para que el intento fallido cuente.
create or replace function fn_autorizar_caja(p_codigo text, p_pin text, p_accion text)
returns jsonb
language plpgsql security definer set search_path = public, app, extensions as $fn$
declare
  aut  jsonb;
  v_id uuid;
begin
  if app.org_id() is null or not app.tiene_nivel('auxiliar') then
    raise exception 'Sin permiso para la caja';
  end if;
  if p_accion not in ('quitar', 'cancelar', 'descartar') then
    raise exception 'Acción no válida';
  end if;
  aut := app.quien_autoriza(p_codigo, p_pin, 'supervisor');
  if not (aut->>'ok')::boolean then return aut; end if;

  insert into autorizaciones_caja (organizacion_id, autorizo, pidio, accion)
  values (app.org_id(), (aut->>'perfil_id')::uuid, auth.uid(), p_accion)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'autorizacion_id', v_id,
                            'nombre', aut->>'nombre', 'perfil_id', aut->>'perfil_id');
end $fn$;

-- Los eventos ahora pueden traer la autorización que los permitió.
create or replace function fn_eventos_caja(p_eventos jsonb) returns int
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  ev    jsonb;
  cj    record;
  v_aut uuid;
  v_n   int := 0;
begin
  if v_org is null or not app.tiene_nivel('auxiliar') then
    raise exception 'Sin permiso para la caja';
  end if;
  if jsonb_typeof(p_eventos) <> 'array' then raise exception 'Se esperaba una lista'; end if;
  if jsonb_array_length(p_eventos) > 200 then raise exception 'Demasiados eventos de una vez'; end if;

  for ev in select * from jsonb_array_elements(p_eventos) loop
    select * into cj from cajas where id = (ev->>'caja_id')::uuid and organizacion_id = v_org;
    if cj.id is null then continue; end if;
    if (ev->>'tipo') not in ('abortada', 'suspendida', 'retomada', 'descartada', 'linea_quitada') then
      continue;
    end if;

    -- La autorización vale una vez, solo en este negocio y solo para quien la pidió.
    v_aut := null;
    if (ev->>'autorizacion_id') is not null then
      update autorizaciones_caja set usada_en = now()
       where id = (ev->>'autorizacion_id')::uuid and organizacion_id = v_org
         and pidio = auth.uid() and usada_en is null
         and creada_en > now() - interval '1 day'
      returning autorizo into v_aut;
    end if;

    insert into eventos_caja (id, organizacion_id, sucursal_id, caja_id, turno_id, cajero_id,
                              tipo, lineas, unidades, monto, detalle, motivo, ocurrido_en, autorizo)
    values ((ev->>'id')::uuid, v_org, cj.sucursal_id, cj.id,
            (select id from turnos_caja where id = (ev->>'turno_id')::uuid
                                          and caja_id = cj.id and organizacion_id = v_org),
            auth.uid(), ev->>'tipo',
            coalesce((ev->>'lineas')::int, 0),
            coalesce((ev->>'unidades')::numeric, 0),
            round(coalesce((ev->>'monto')::numeric, 0), 2),
            ev->'detalle',
            left(nullif(btrim(ev->>'motivo'), ''), 200),
            least(coalesce((ev->>'ocurrido_en')::timestamptz, now()), now()),
            v_aut)
    on conflict (id) do nothing;
    if found then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end $fn$;

-- Lo que este negocio pide autorizar. Por omisión: cancelar y borrar en
-- espera sí, quitar una línea no (en una pulpería chica sería un estorbo).
create or replace function app.caja_autoriza(p_config jsonb) returns jsonb
language sql immutable as $fn$
  select jsonb_build_object(
    'quitar',    coalesce((p_config -> 'caja_autoriza' ->> 'quitar')::boolean, false),
    'cancelar',  coalesce((p_config -> 'caja_autoriza' ->> 'cancelar')::boolean, true),
    'descartar', coalesce((p_config -> 'caja_autoriza' ->> 'descartar')::boolean, true))
$fn$;


-- ===========================================================================
-- 2. Vencimientos
-- ===========================================================================
create or replace function fn_vencimientos(p_sucursal_id uuid default null, p_dias int default 60)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org  uuid := app.org_id();
  v_hoy  date;
  v_sucs uuid[];
  v_ve   boolean := app.tiene_nivel('supervisor');
begin
  if v_org is null or not app.tiene_nivel('auxiliar') then
    raise exception 'Sin permiso para ver vencimientos';
  end if;
  v_hoy := (now() at time zone app.zona(v_org))::date;
  if p_sucursal_id is not null then
    if p_sucursal_id not in (select app.sucursales_permitidas()) then
      raise exception 'No tiene acceso a esa sucursal';
    end if;
    v_sucs := array[p_sucursal_id];
  else
    v_sucs := array(select app.sucursales_permitidas());
  end if;

  return jsonb_build_object(
    'hoy', v_hoy,
    'puede_ver_costos', v_ve,
    'puede_ofertar', app.tiene_nivel('gerente'),
    'lotes', coalesce((select jsonb_agg(jsonb_build_object(
        'lote_id', l.id, 'lote', l.codigo, 'vence', l.fecha_vencimiento,
        'dias', l.fecha_vencimiento - v_hoy,
        'producto_id', p.id, 'nombre', p.nombre, 'sku', p.sku, 'unidad', p.unidad_base,
        'categoria', c.nombre, 'proveedor', pv.nombre,
        'sucursal_id', e.sucursal_id, 'sucursal', s.nombre,
        'cantidad', e.cantidad,
        'alerta', coalesce(p.dias_alerta_vencim, o.dias_alerta_vencimiento, 30),
        'costo', case when v_ve then round(coalesce(pc.costo_promedio, l.costo_ingreso, 0), 2) end,
        'valor', case when v_ve then round(e.cantidad * coalesce(pc.costo_promedio, l.costo_ingreso, 0), 2) end,
        'precio', fn_precio_vigente(p.id, e.sucursal_id, 1),
        'en_oferta', exists (select 1 from precios pr where pr.producto_id = p.id and pr.es_oferta
                               and pr.vigente_desde <= v_hoy and pr.vigente_hasta >= v_hoy
                               and (pr.sucursal_id is null or pr.sucursal_id = e.sucursal_id)),
        'merma_pendiente', exists (select 1 from mermas m where m.lote_id = l.id and m.estado = 'pendiente'))
        order by l.fecha_vencimiento, p.nombre)
      from existencias e
      join lotes l on l.id = e.lote_id
      join productos p on p.id = e.producto_id
      join organizaciones o on o.id = p.organizacion_id
      join sucursales s on s.id = e.sucursal_id
      left join categorias c on c.id = p.categoria_id
      left join proveedores pv on pv.id = coalesce(l.proveedor_id, p.proveedor_id)
      left join producto_costos pc on pc.producto_id = p.id and pc.sucursal_id = e.sucursal_id
     where e.organizacion_id = v_org and e.sucursal_id = any(v_sucs)
       and e.cantidad > 0 and l.fecha_vencimiento is not null
       and l.fecha_vencimiento <= v_hoy + greatest(coalesce(p_dias, 60), 0)), '[]'::jsonb));
end $fn$;


-- ===========================================================================
-- 3. Importar el catálogo y cambiar precios en lote
-- ===========================================================================

-- El precio de siempre de un producto (el de toda la organización, sin fin).
create or replace function app.fijar_precio_base(p_org uuid, p_producto uuid, p_precio numeric)
returns void
language plpgsql security definer set search_path = public, app as $fn$
declare v_id uuid;
begin
  select id into v_id from precios
   where producto_id = p_producto and nivel = 'detalle' and sucursal_id is null
     and vigente_hasta is null and not es_oferta and cantidad_minima <= 1
   order by cantidad_minima limit 1;
  if v_id is not null then
    update precios set precio = round(p_precio, 2), actualizado_en = now() where id = v_id;
  else
    insert into precios (organizacion_id, producto_id, nivel, cantidad_minima, precio)
    values (p_org, p_producto, 'detalle', 1, round(p_precio, 2));
  end if;
  -- Si alguna sucursal tenía su propio precio de siempre, también cambia:
  -- si no, la lista de precios que se subió no se vería en esa caja.
  update precios set precio = round(p_precio, 2), actualizado_en = now()
   where producto_id = p_producto and nivel = 'detalle' and sucursal_id is not null
     and vigente_hasta is null and not es_oferta and cantidad_minima <= 1;
end $fn$;
revoke execute on function app.fijar_precio_base(uuid, uuid, numeric) from public, anon, authenticated;

/* Cada fila es un objeto con lo que traiga el Excel:
     sku, nombre, codigo (varios separados por ; o ,), categoria, marca,
     proveedor, unidad, tipo, precio, costo, existencia, minimo, maximo,
     impuesto (15, 18 o 0), empaque, vence (sí/no)
   Se busca el producto por sku y, si no, por código de barras. Lo que no
   existe se crea; lo que existe se actualiza solo si p_actualizar. Cada
   fila va en su propia sub-transacción: una mala no tumba las demás.
   La existencia inicial solo entra si ese producto todavía no tiene
   existencia en esa sucursal: lo que ya está contado se corrige con un
   conteo, no con un Excel. */
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


/* Cambiar precios en lote. Con p_aplicar = false solo dice cómo quedarían.
     modo 'porcentaje'  sube o baja el precio actual en p_valor %
     modo 'margen'      precio para ganar p_valor % sobre el precio sin ISV
     modo 'markup'      precio = costo + p_valor % del costo (más ISV)
   p_redondeo: a cuánto se redondea hacia arriba (0.25, 0.50, 1, 5; 0 = no) */
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
       and (not (p_filtro ? 'categoria_id') or p.categoria_id = (p_filtro->>'categoria_id')::uuid)
       and (not (p_filtro ? 'marca_id')     or p.marca_id     = (p_filtro->>'marca_id')::uuid)
       and (not (p_filtro ? 'proveedor_id') or p.proveedor_id = (p_filtro->>'proveedor_id')::uuid)
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


-- ===========================================================================
-- 4. Promociones
-- ===========================================================================
create table if not exists promociones (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references organizaciones(id) on delete cascade,
  sucursal_id     uuid references sucursales(id),
  nombre          text not null,
  tipo            text not null check (tipo in ('nxm', 'paquete', 'porcentaje')),
  lleva           int  check (lleva between 2 and 99),
  paga            int  check (paga >= 0),
  precio_paquete  numeric(14,2) check (precio_paquete > 0),
  porcentaje      numeric(6,2)  check (porcentaje > 0 and porcentaje < 100),
  alcance         text not null check (alcance in ('productos', 'categoria', 'marca')),
  producto_ids    uuid[],
  categoria_id    uuid references categorias(id),
  marca_id        uuid references marcas(id),
  vigente_desde   date not null default current_date,
  vigente_hasta   date,
  dias_semana     int[],
  activa          boolean not null default true,
  prioridad       int not null default 100,
  creada_por      uuid references perfiles(id),
  creada_en       timestamptz not null default now(),
  check (tipo <> 'nxm' or (lleva is not null and paga is not null and paga < lleva)),
  check (tipo <> 'paquete' or (lleva is not null and precio_paquete is not null)),
  check (tipo <> 'porcentaje' or porcentaje is not null),
  check (alcance <> 'productos' or cardinality(producto_ids) > 0),
  check (alcance <> 'categoria' or categoria_id is not null),
  check (alcance <> 'marca' or marca_id is not null)
);
create index if not exists ix_promos_org on promociones (organizacion_id, activa);
alter table promociones enable row level security;
do $pol$
begin
  if not exists (select 1 from pg_policies where tablename = 'promociones' and policyname = 'promos_ver') then
    execute $c$create policy promos_ver on promociones for select to authenticated
      using (organizacion_id = app.org_id())$c$;
  end if;
end $pol$;
revoke all on promociones from anon;
revoke insert, update, delete on promociones from authenticated;
grant select on promociones to authenticated;

alter table venta_detalle add column if not exists promociones jsonb;

-- ¿Esta promoción vale hoy en esta sucursal?
create or replace function app.promo_vigente(pr promociones, p_suc uuid, p_hoy date) returns boolean
language sql immutable as $fn$
  select pr.activa
     and (pr.sucursal_id is null or pr.sucursal_id = p_suc)
     and pr.vigente_desde <= p_hoy
     and (pr.vigente_hasta is null or pr.vigente_hasta >= p_hoy)
     and (pr.dias_semana is null or cardinality(pr.dias_semana) = 0
          or extract(dow from p_hoy)::int = any(pr.dias_semana))
$fn$;

/* LA CUENTA DE LAS PROMOCIONES. promos.js hace exactamente lo mismo.
   Todo en centavos y milésimas enteras, para que el servidor y la caja den
   el mismo centavo.

   Entra: [{producto_id, cantidad, precio}] en el orden del ticket.
   Sale:  {descuentos:[centavos por línea], aplicadas:[{id, nombre, descuento}]}

   Las promociones van por prioridad y fecha de creación. Cada unidad entra
   en una sola promoción.
     nxm         en cada grupo de "lleva" unidades (de la más cara a la más
                 barata) las "lleva - paga" más baratas salen gratis
     paquete     cada grupo de "lleva" unidades cuesta "precio_paquete"; el
                 descuento se reparte entre las unidades según su precio
     porcentaje  rebaja el % a toda la cantidad que quede (también a la que
                 se vende por peso)
   nxm y paquete solo cuentan unidades enteras. */
create or replace function app.descuentos_promo(p_org uuid, p_suc uuid, p_items jsonb)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  n      int := coalesce(jsonb_array_length(p_items), 0);
  ids    uuid[] := '{}';
  cats   uuid[] := '{}';
  mars   uuid[] := '{}';
  prc    bigint[] := '{}';   -- precio en centavos
  rest   bigint[] := '{}';   -- cantidad que queda, en milésimas
  dsc    bigint[] := '{}';   -- descuento en centavos
  quien  text[] := '{}';     -- qué promociones tocaron cada línea
  pr     promociones;
  hoy    date;
  i int; k int; g int; grupos int; sel int[];
  u      int[];
  tot bigint; d bigint; repartido bigint; dprom bigint;
  aplic  jsonb := '[]'::jsonb;
  pid uuid;
begin
  if n = 0 then return jsonb_build_object('descuentos', '[]'::jsonb, 'aplicadas', '[]'::jsonb); end if;
  hoy := (now() at time zone app.zona(p_org))::date;

  for i in 1..n loop
    pid := (p_items -> (i - 1) ->> 'producto_id')::uuid;
    ids  := ids  || pid;
    cats := cats || (select categoria_id from productos where id = pid);
    mars := mars || (select marca_id from productos where id = pid);
    prc  := prc  || round(coalesce((p_items -> (i - 1) ->> 'precio')::numeric, 0) * 100)::bigint;
    rest := rest || round(coalesce((p_items -> (i - 1) ->> 'cantidad')::numeric, 0) * 1000)::bigint;
    dsc  := dsc  || 0::bigint;
    quien := quien || ''::text;
  end loop;

  for pr in select * from promociones
             where organizacion_id = p_org and app.promo_vigente(promociones, p_suc, hoy)
             order by prioridad, creada_en, id
  loop
    sel := '{}';
    for i in 1..n loop
      if rest[i] > 0 and prc[i] > 0 and (
           (pr.alcance = 'productos' and ids[i] = any(pr.producto_ids))
        or (pr.alcance = 'categoria' and cats[i] = pr.categoria_id)
        or (pr.alcance = 'marca' and mars[i] = pr.marca_id)) then
        sel := sel || i;
      end if;
    end loop;
    if cardinality(sel) = 0 then continue; end if;
    dprom := 0;

    if pr.tipo = 'porcentaje' then
      foreach i in array sel loop
        -- rest (milésimas) × precio (centavos) × % (centésimas) / 10^7, redondeado a la mitad
        d := (rest[i] * prc[i] * round(pr.porcentaje * 100)::bigint * 2 + 10000000) / 20000000;
        dsc[i] := dsc[i] + d; dprom := dprom + d;
        if d > 0 and strpos(quien[i], pr.id::text) = 0 then quien[i] := quien[i] || pr.id::text || ','; end if;
        rest[i] := 0;
      end loop;
    else
      -- las unidades enteras, de la más cara a la más barata (empate: la línea de arriba)
      u := array(select x.i from (
                   select s.i, prc[s.i] as p, gs
                     from unnest(sel) s(i), generate_series(1, (rest[s.i] / 1000)::int) gs) x
                 order by x.p desc, x.i, x.gs);
      grupos := coalesce(cardinality(u), 0) / pr.lleva;
      for g in 0..grupos - 1 loop
        if pr.tipo = 'nxm' then
          for k in (pr.paga + 1)..pr.lleva loop
            i := u[g * pr.lleva + k];
            dsc[i] := dsc[i] + prc[i]; dprom := dprom + prc[i];
            if strpos(quien[i], pr.id::text) = 0 then quien[i] := quien[i] || pr.id::text || ','; end if;
          end loop;
        else
          tot := 0;
          for k in 1..pr.lleva loop tot := tot + prc[u[g * pr.lleva + k]]; end loop;
          d := tot - round(pr.precio_paquete * 100)::bigint;
          if d > 0 then
            repartido := 0;
            for k in 1..pr.lleva loop
              i := u[g * pr.lleva + k];
              if k < pr.lleva then
                dsc[i] := dsc[i] + (d * prc[i]) / tot;
                repartido := repartido + (d * prc[i]) / tot;
              else
                dsc[i] := dsc[i] + (d - repartido);
              end if;
              if strpos(quien[i], pr.id::text) = 0 then quien[i] := quien[i] || pr.id::text || ','; end if;
            end loop;
            dprom := dprom + d;
          end if;
        end if;
        for k in 1..pr.lleva loop
          i := u[g * pr.lleva + k];
          rest[i] := rest[i] - 1000;
        end loop;
      end loop;
    end if;

    if dprom > 0 then
      aplic := aplic || jsonb_build_object('id', pr.id, 'nombre', pr.nombre, 'descuento', round(dprom / 100.0, 2));
    end if;
  end loop;

  return jsonb_build_object(
    'descuentos', (select jsonb_agg(round(x / 100.0, 2) order by o) from unnest(dsc) with ordinality t(x, o)),
    'promos_linea', (select jsonb_agg(to_jsonb(coalesce(string_to_array(rtrim(q, ','), ','), '{}'::text[])) order by o)
                       from unnest(quien) with ordinality t(q, o)),
    'aplicadas', aplic);
end $fn$;
revoke execute on function app.descuentos_promo(uuid, uuid, jsonb) from public, anon, authenticated;


-- Para la caja: las de hoy, con la lista de productos a los que aplica.
create or replace function fn_promociones_activas(p_sucursal_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  v_suc uuid;
  hoy   date;
begin
  if v_org is null or not app.tiene_nivel('auxiliar') then raise exception 'Sin permiso'; end if;
  v_suc := coalesce(p_sucursal_id, (select id from sucursales where organizacion_id = v_org and activa
                                      order by es_principal desc limit 1));
  hoy := (now() at time zone app.zona(v_org))::date;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', pr.id, 'nombre', pr.nombre, 'tipo', pr.tipo, 'lleva', pr.lleva, 'paga', pr.paga,
      'precio_paquete', pr.precio_paquete, 'porcentaje', pr.porcentaje,
      'producto_ids', case pr.alcance
         when 'productos' then to_jsonb(pr.producto_ids)
         when 'categoria' then (select coalesce(jsonb_agg(p.id), '[]'::jsonb) from productos p
                                 where p.organizacion_id = v_org and p.categoria_id = pr.categoria_id)
         else (select coalesce(jsonb_agg(p.id), '[]'::jsonb) from productos p
                where p.organizacion_id = v_org and p.marca_id = pr.marca_id) end)
      order by pr.prioridad, pr.creada_en, pr.id)
    from promociones pr
   where pr.organizacion_id = v_org and app.promo_vigente(pr, v_suc, hoy)), '[]'::jsonb);
end $fn$;

-- Para la pantalla de promociones: todas, con su estado.
create or replace function fn_promociones() returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare v_org uuid := app.org_id(); hoy date;
begin
  if v_org is null or not app.tiene_nivel('supervisor') then raise exception 'Sin permiso'; end if;
  hoy := (now() at time zone app.zona(v_org))::date;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', pr.id, 'nombre', pr.nombre, 'tipo', pr.tipo, 'lleva', pr.lleva, 'paga', pr.paga,
      'precio_paquete', pr.precio_paquete, 'porcentaje', pr.porcentaje, 'alcance', pr.alcance,
      'producto_ids', pr.producto_ids, 'categoria_id', pr.categoria_id, 'marca_id', pr.marca_id,
      'categoria', (select nombre from categorias where id = pr.categoria_id),
      'marca', (select nombre from marcas where id = pr.marca_id),
      'productos', (select jsonb_agg(jsonb_build_object('id', p.id, 'nombre', p.nombre) order by p.nombre)
                      from productos p where p.id = any(pr.producto_ids)),
      'sucursal_id', pr.sucursal_id, 'sucursal', (select nombre from sucursales where id = pr.sucursal_id),
      'vigente_desde', pr.vigente_desde, 'vigente_hasta', pr.vigente_hasta,
      'dias_semana', pr.dias_semana, 'activa', pr.activa,
      'estado', case when not pr.activa then 'apagada'
                     when pr.vigente_hasta is not null and pr.vigente_hasta < hoy then 'terminada'
                     when pr.vigente_desde > hoy then 'programada'
                     else 'vigente' end,
      'usos_30d', (select count(distinct vd.venta_id) from venta_detalle vd
                    join ventas v on v.id = vd.venta_id
                   where v.organizacion_id = v_org and v.estado = 'completada'
                     and v.creada_en > now() - interval '30 days'
                     and vd.promociones @> jsonb_build_array(jsonb_build_object('id', pr.id))),
      'descuento_30d', (select coalesce(sum((x ->> 'descuento')::numeric), 0)
                          from venta_detalle vd join ventas v on v.id = vd.venta_id,
                               jsonb_array_elements(coalesce(vd.promociones, '[]'::jsonb)) x
                         where v.organizacion_id = v_org and v.estado = 'completada'
                           and v.creada_en > now() - interval '30 days'
                           and x ->> 'id' = pr.id::text))
      order by (pr.activa and (pr.vigente_hasta is null or pr.vigente_hasta >= hoy)) desc,
               pr.vigente_desde desc, pr.creada_en desc)
    from promociones pr where pr.organizacion_id = v_org), '[]'::jsonb);
end $fn$;

create or replace function fn_guardar_promocion(p jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  v_id  uuid := nullif(p->>'id', '')::uuid;
  v_ids uuid[];
begin
  if v_org is null or not app.tiene_nivel('gerente') then
    raise exception 'Las promociones las pone el gerente';
  end if;
  if coalesce(btrim(p->>'nombre'), '') = '' then raise exception 'Póngale un nombre a la promoción'; end if;
  if v_id is not null and not exists (select 1 from promociones where id = v_id and organizacion_id = v_org) then
    raise exception 'Esa promoción no es de su negocio';
  end if;
  if (p->>'categoria_id') is not null and not exists
       (select 1 from categorias where id = (p->>'categoria_id')::uuid and organizacion_id = v_org) then
    raise exception 'Esa categoría no es de su negocio';
  end if;
  if (p->>'marca_id') is not null and not exists
       (select 1 from marcas where id = (p->>'marca_id')::uuid and organizacion_id = v_org) then
    raise exception 'Esa marca no es de su negocio';
  end if;
  if (p->>'sucursal_id') is not null and not exists
       (select 1 from sucursales where id = (p->>'sucursal_id')::uuid and organizacion_id = v_org) then
    raise exception 'Esa sucursal no es de su negocio';
  end if;
  if p ? 'producto_ids' and jsonb_typeof(p->'producto_ids') = 'array' then
    v_ids := array(select x::uuid from jsonb_array_elements_text(p->'producto_ids') x);
    if exists (select 1 from unnest(v_ids) x
                where not exists (select 1 from productos where id = x and organizacion_id = v_org)) then
      raise exception 'Hay productos que no son de su negocio';
    end if;
  end if;
  if (p->>'vigente_hasta') is not null and (p->>'vigente_hasta')::date < coalesce((p->>'vigente_desde')::date, current_date) then
    raise exception 'La promoción termina antes de empezar';
  end if;

  if v_id is null then
    insert into promociones (organizacion_id, sucursal_id, nombre, tipo, lleva, paga, precio_paquete,
                             porcentaje, alcance, producto_ids, categoria_id, marca_id,
                             vigente_desde, vigente_hasta, dias_semana, activa, creada_por)
    values (v_org, (p->>'sucursal_id')::uuid, btrim(p->>'nombre'), p->>'tipo',
            (p->>'lleva')::int, (p->>'paga')::int, (p->>'precio_paquete')::numeric,
            (p->>'porcentaje')::numeric, p->>'alcance',
            case when p->>'alcance' = 'productos' then v_ids end,
            case when p->>'alcance' = 'categoria' then (p->>'categoria_id')::uuid end,
            case when p->>'alcance' = 'marca' then (p->>'marca_id')::uuid end,
            coalesce((p->>'vigente_desde')::date, (now() at time zone app.zona(v_org))::date),
            (p->>'vigente_hasta')::date,
            case when jsonb_typeof(p->'dias_semana') = 'array' and jsonb_array_length(p->'dias_semana') between 1 and 6
                 then array(select x::int from jsonb_array_elements_text(p->'dias_semana') x) end,
            coalesce((p->>'activa')::boolean, true), auth.uid())
    returning id into v_id;
  else
    update promociones set
      sucursal_id = (p->>'sucursal_id')::uuid, nombre = btrim(p->>'nombre'), tipo = p->>'tipo',
      lleva = (p->>'lleva')::int, paga = (p->>'paga')::int,
      precio_paquete = (p->>'precio_paquete')::numeric, porcentaje = (p->>'porcentaje')::numeric,
      alcance = p->>'alcance',
      producto_ids = case when p->>'alcance' = 'productos' then v_ids end,
      categoria_id = case when p->>'alcance' = 'categoria' then (p->>'categoria_id')::uuid end,
      marca_id = case when p->>'alcance' = 'marca' then (p->>'marca_id')::uuid end,
      vigente_desde = coalesce((p->>'vigente_desde')::date, vigente_desde),
      vigente_hasta = (p->>'vigente_hasta')::date,
      dias_semana = case when jsonb_typeof(p->'dias_semana') = 'array' and jsonb_array_length(p->'dias_semana') between 1 and 6
                         then array(select x::int from jsonb_array_elements_text(p->'dias_semana') x) end,
      activa = coalesce((p->>'activa')::boolean, activa)
     where id = v_id;
  end if;
  return v_id;
end $fn$;

-- Ver cómo quedaría un ticket (pantalla de promociones y pruebas).
create or replace function fn_calcular_promos(p_items jsonb, p_sucursal_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare v_org uuid := app.org_id(); v_suc uuid; v jsonb := '[]'::jsonb; it jsonb;
begin
  if v_org is null or not app.tiene_nivel('auxiliar') then raise exception 'Sin permiso'; end if;
  v_suc := coalesce(p_sucursal_id, (select id from sucursales where organizacion_id = v_org and activa
                                      order by es_principal desc limit 1));
  for it in select * from jsonb_array_elements(p_items) loop
    if not exists (select 1 from productos where id = (it->>'producto_id')::uuid and organizacion_id = v_org) then
      raise exception 'Producto de otro negocio';
    end if;
    v := v || jsonb_build_object('producto_id', it->>'producto_id', 'cantidad', (it->>'cantidad')::numeric,
              'precio', coalesce((it->>'precio')::numeric,
                                 fn_precio_vigente((it->>'producto_id')::uuid, v_suc, (it->>'cantidad')::numeric)));
  end loop;
  return app.descuentos_promo(v_org, v_suc, v);
end $fn$;


-- ---------------------------------------------------------------------------
-- fn_registrar_venta: igual que antes, con dos cambios.
--   · el descuento de cada línea lo pone el servidor con las promociones
--     del día; el que mande la caja ya no se toma en cuenta
--   · la línea guarda qué promociones se le aplicaron
-- La firma no cambia.
-- ---------------------------------------------------------------------------
create or replace function fn_registrar_venta(
  p_desbloqueo_id uuid, p_items jsonb, p_pagos jsonb,
  p_cliente_id uuid default null, p_fiscal boolean default false
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  d           record;
  t           record;
  o           record;
  cl          record;
  it          jsonb;
  pg          jsonb;
  v_venta_id  uuid;
  v_numero    text;
  v_prod      record;
  v_cant      numeric;
  v_precio    numeric;
  v_desc      numeric;
  v_tasa      numeric;
  v_linea     numeric;
  v_costo     numeric;
  v_sub       numeric := 0;
  v_imp       numeric := 0;
  v_desctot   numeric := 0;
  v_costotot  numeric := 0;
  v_total     numeric := 0;
  v_pagado    numeric := 0;
  v_cambio    numeric := 0;
  v_recibido  numeric := 0;
  v_credito   numeric := 0;
  v_tipo      tipo_documento_fiscal := 'ticket';
  v_numfiscal text;
  v_cai       text;
  s           record;
  v_lineas    jsonb := '[]'::jsonb;
  v_promo     jsonb;
  v_ix        int := 0;
  v_suyas     jsonb;
begin
  select * into d from caja_desbloqueos where id = p_desbloqueo_id for update;
  if d.id is null then
    raise exception 'Caja bloqueada: digite el PIN para iniciar la venta';
  end if;
  if d.consumido_en is not null then
    raise exception 'Este desbloqueo ya se uso. Digite el PIN de nuevo';
  end if;
  if d.expira_en < now() then
    raise exception 'El desbloqueo expiro. Digite el PIN de nuevo';
  end if;

  select * into t from turnos_caja where id = d.turno_id;
  if t.estado <> 'abierto' then raise exception 'El turno de caja esta cerrado'; end if;

  select * into o from organizaciones where id = t.organizacion_id;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'La venta no tiene productos';
  end if;

  if p_cliente_id is not null then
    select * into cl from clientes
     where id = p_cliente_id and organizacion_id = t.organizacion_id;
    if cl.id is null then
      raise exception 'Cliente inexistente en este negocio';
    end if;
  end if;

  -- Primero los precios de cada línea: las promociones se calculan sobre ellos.
  for it in select * from jsonb_array_elements(p_items) loop
    select p.*, coalesce(i.tasa, 0) as tasa, coalesce(i.incluido_en_precio, true) as incluido
      into v_prod
    from productos p
    left join impuestos i on i.id = p.impuesto_id
    where p.id = (it->>'producto_id')::uuid and p.organizacion_id = t.organizacion_id;

    if v_prod.id is null then
      raise exception 'Producto % inexistente', it->>'producto_id';
    end if;

    v_cant := (it->>'cantidad')::numeric;
    if v_cant is null or v_cant <= 0 then
      raise exception 'Cantidad invalida en %', v_prod.nombre;
    end if;

    if v_prod.tipo = 'servicio' and (it ? 'precio') then
      v_precio := (it->>'precio')::numeric;
      if v_precio is null or v_precio < 0 then
        raise exception 'Precio invalido para %', v_prod.nombre;
      end if;
    else
      v_precio := coalesce(
        fn_precio_vigente(v_prod.id, t.sucursal_id, v_cant,
                          coalesce((it->>'nivel')::nivel_precio, 'detalle')), 0);
      if v_precio = 0 then
        raise exception 'El producto % no tiene precio asignado', v_prod.nombre;
      end if;
    end if;
    v_lineas := v_lineas || jsonb_build_object('producto_id', v_prod.id, 'cantidad', v_cant,
                                               'precio', v_precio,
                                               'servicio', v_prod.tipo = 'servicio');
  end loop;

  -- Las promociones no tocan servicios: se les manda precio 0.
  v_promo := app.descuentos_promo(t.organizacion_id, t.sucursal_id,
               (select jsonb_agg(case when (x->>'servicio')::boolean
                                      then x || '{"precio":0}'::jsonb else x end order by e.pos)
                  from jsonb_array_elements(v_lineas) with ordinality e(x, pos)));

  v_numero := app.numero_documento(t.organizacion_id, t.sucursal_id, 'ticket', 'T', 8);

  if p_fiscal and o.facturacion_fiscal_activa then
    select * into s from series_fiscales
     where sucursal_id = t.sucursal_id and tipo_documento = 'factura' and activa
       and correlativo_actual <= correlativo_final
       and (fecha_limite_emision is null or fecha_limite_emision >= current_date)
     order by creada_en limit 1
     for update;

    if s.id is null then
      raise exception 'No hay rango de facturacion autorizado disponible';
    end if;

    v_tipo      := 'factura';
    v_numfiscal := s.prefijo || '-' || lpad(s.correlativo_actual::text, 8, '0');
    v_cai       := s.cai;
    update series_fiscales set correlativo_actual = correlativo_actual + 1 where id = s.id;
  end if;

  insert into ventas (organizacion_id, sucursal_id, caja_id, turno_id, cajero_id,
                      cliente_id, numero, tipo_documento, numero_fiscal, cai)
  values (t.organizacion_id, t.sucursal_id, t.caja_id, t.id, d.cajero_id,
          p_cliente_id, v_numero, v_tipo, v_numfiscal, v_cai)
  returning id into v_venta_id;

  for it in select * from jsonb_array_elements(v_lineas) loop
    v_ix := v_ix + 1;
    select p.*, coalesce(i.tasa, 0) as tasa, coalesce(i.incluido_en_precio, true) as incluido
      into v_prod
    from productos p
    left join impuestos i on i.id = p.impuesto_id
    where p.id = (it->>'producto_id')::uuid;

    v_cant   := (it->>'cantidad')::numeric;
    v_precio := (it->>'precio')::numeric;
    v_desc   := least(coalesce((v_promo -> 'descuentos' ->> (v_ix - 1))::numeric, 0), v_precio * v_cant);
    v_tasa   := v_prod.tasa;
    v_linea  := (v_precio * v_cant) - v_desc;

    -- qué promociones tocaron esta línea (para Finanzas y el ticket)
    v_suyas := case when v_desc > 0 then (
      select jsonb_agg(jsonb_build_object('id', a->>'id', 'nombre', a->>'nombre',
                                          'descuento', round(v_desc, 2)))
        from jsonb_array_elements(v_promo -> 'aplicadas') a
       where (v_promo -> 'promos_linea' -> (v_ix - 1)) ? (a->>'id')) end;

    if v_prod.tipo = 'servicio' then
      v_costo := 0;
    else
      v_costo := fn_descontar_fefo(t.sucursal_id, v_prod.id, v_cant,
                                   'venta', v_venta_id, d.cajero_id);
    end if;

    insert into venta_detalle (organizacion_id, venta_id, producto_id, cantidad,
                               precio_unitario, descuento, tasa_impuesto,
                               impuesto_incluido, costo_unitario, total, promociones)
    values (t.organizacion_id, v_venta_id, v_prod.id, v_cant,
            v_precio, v_desc, v_tasa, v_prod.incluido,
            case when v_cant > 0 then v_costo / v_cant else 0 end, v_linea, v_suyas);

    if v_prod.incluido then
      v_sub := v_sub + (v_linea / (1 + v_tasa));
      v_imp := v_imp + (v_linea - (v_linea / (1 + v_tasa)));
    else
      v_sub := v_sub + v_linea;
      v_imp := v_imp + (v_linea * v_tasa);
    end if;

    v_desctot  := v_desctot + v_desc;
    v_costotot := v_costotot + v_costo;
  end loop;

  v_total := round(v_sub + v_imp, 2);

  for pg in select * from jsonb_array_elements(coalesce(p_pagos, '[]'::jsonb)) loop
    if (pg->>'metodo') = 'credito' then
      v_credito := v_credito + (pg->>'monto')::numeric;
    end if;
    v_pagado   := v_pagado + (pg->>'monto')::numeric;
    v_recibido := v_recibido + coalesce((pg->>'recibido')::numeric, (pg->>'monto')::numeric);

    insert into pagos_venta (organizacion_id, venta_id, metodo, monto, recibido, referencia)
    values (t.organizacion_id, v_venta_id, (pg->>'metodo')::metodo_pago,
            (pg->>'monto')::numeric, (pg->>'recibido')::numeric, pg->>'referencia');
  end loop;

  if v_credito > 0 then
    if p_cliente_id is null then
      raise exception 'Una venta al credito requiere cliente';
    end if;

    select * into cl from clientes
     where id = p_cliente_id and organizacion_id = t.organizacion_id for update;
    if cl.id is null then raise exception 'Cliente inexistente en este negocio'; end if;
    if not cl.activo then raise exception 'El cliente % esta inactivo', cl.nombre; end if;

    if coalesce(cl.limite_credito, 0) <= 0 then
      raise exception 'A % no se le fia. Asignele un limite de credito primero', cl.nombre;
    end if;

    if round(coalesce(cl.saldo, 0) + v_credito, 2) > round(cl.limite_credito, 2) then
      raise exception 'Pasa del limite de %: debe % y su limite es %',
        cl.nombre, round(coalesce(cl.saldo, 0), 2), round(cl.limite_credito, 2);
    end if;
  end if;

  if round(v_pagado, 2) < v_total then
    raise exception 'Pago insuficiente: total %, recibido %', v_total, v_pagado;
  end if;
  v_cambio := greatest(round(v_recibido - v_total, 2), 0);

  update pagos_venta set cambio = v_cambio
   where venta_id = v_venta_id and metodo = 'efectivo'
     and id = (select pv.id from pagos_venta pv where pv.venta_id = v_venta_id
               and pv.metodo = 'efectivo' order by pv.creado_en desc limit 1);

  update ventas
     set subtotal = round(v_sub, 2), impuesto = round(v_imp, 2),
         descuento = round(v_desctot, 2), total = v_total,
         costo_total = round(v_costotot, 2), es_credito = v_credito > 0
   where id = v_venta_id;

  if v_credito > 0 then
    update clientes set saldo = saldo + v_credito, actualizado_en = now()
     where id = p_cliente_id;
  end if;

  update caja_desbloqueos
     set consumido_en = now(), venta_id = v_venta_id
   where id = p_desbloqueo_id;

  return jsonb_build_object(
    'venta_id', v_venta_id, 'numero', v_numero, 'documento', v_tipo,
    'numero_fiscal', v_numfiscal,
    'subtotal', round(v_sub, 2), 'impuesto', round(v_imp, 2), 'total', v_total,
    'descuento', round(v_desctot, 2), 'promociones', v_promo -> 'aplicadas',
    'pagado', round(v_pagado, 2), 'fiado', round(v_credito, 2),
    'cambio', v_cambio, 'caja_bloqueada', true
  );
end $fn$;


-- ---------------------------------------------------------------------------
-- El contexto trae también qué pide autorizar la caja.
-- ---------------------------------------------------------------------------
create or replace function fn_pos_contexto() returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_perfil record;
  v_org    record;
  v_res    jsonb;
begin
  select * into v_perfil from perfiles where id = auth.uid() and activo;
  if v_perfil.id is null then
    raise exception 'Usuario sin perfil activo';
  end if;

  select * into v_org from organizaciones where id = v_perfil.organizacion_id;

  select jsonb_build_object(
    'usuario', jsonb_build_object(
      'id', v_perfil.id,
      'nombre', v_perfil.nombre,
      'rol', v_perfil.rol,
      'nivel', app.nivel_rol(v_perfil.rol),
      'tiene_pin', v_perfil.pin_pos is not null
    ),
    'organizacion', jsonb_build_object(
      'id', v_org.id,
      'nombre', v_org.nombre,
      'moneda', v_org.moneda,
      'factura_fiscal', v_org.facturacion_fiscal_activa,
      'color', case when coalesce(v_org.config ->> 'color_marca', '') ~ '^#[0-9A-Fa-f]{6}$'
                    then v_org.config ->> 'color_marca' end,
      'logo_path', v_org.config ->> 'logo_path',
      'caja_autoriza', app.caja_autoriza(coalesce(v_org.config, '{}'::jsonb))
    ),
    'sucursales', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'nombre', s.nombre, 'codigo', s.codigo)
             order by s.es_principal desc, s.nombre)
      from sucursales s where s.id in (select app.sucursales_permitidas())
    ), '[]'::jsonb),
    'cajas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'caja_id', ec.caja_id, 'caja', ec.caja,
               'sucursal_id', ec.sucursal_id,
               'turno_id', ec.turno_id, 'cajero', ec.cajero,
               'cajero_id', ec.cajero_id,
               'desbloqueada', ec.desbloqueada,
               'ventas_turno', ec.ventas_turno,
               'total_turno', ec.total_turno))
      from v_estado_cajas ec
      where ec.sucursal_id in (select app.sucursales_permitidas())
    ), '[]'::jsonb),
    'impuesto_default', coalesce((
      select tasa from impuestos
      where organizacion_id = v_perfil.organizacion_id and es_predeterminado and activo
      limit 1), 0),
    'sin_sucursal', not exists (select 1 from app.sucursales_permitidas())
  ) into v_res;

  return v_res;
end $fn$;


-- permisos
revoke execute on function fn_autorizar_caja(text, text, text) from public, anon;
revoke execute on function fn_eventos_caja(jsonb) from public, anon;
revoke execute on function fn_vencimientos(uuid, int) from public, anon;
revoke execute on function fn_importar_productos(jsonb, uuid, boolean) from public, anon;
revoke execute on function fn_cambiar_precios(jsonb, text, numeric, numeric, boolean) from public, anon;
revoke execute on function fn_promociones_activas(uuid) from public, anon;
revoke execute on function fn_promociones() from public, anon;
revoke execute on function fn_guardar_promocion(jsonb) from public, anon;
revoke execute on function fn_calcular_promos(jsonb, uuid) from public, anon;
grant execute on function fn_autorizar_caja(text, text, text) to authenticated;
grant execute on function fn_eventos_caja(jsonb) to authenticated;
grant execute on function fn_vencimientos(uuid, int) to authenticated;
grant execute on function fn_importar_productos(jsonb, uuid, boolean) to authenticated;
grant execute on function fn_cambiar_precios(jsonb, text, numeric, numeric, boolean) to authenticated;
grant execute on function fn_promociones_activas(uuid) to authenticated;
grant execute on function fn_promociones() to authenticated;
grant execute on function fn_guardar_promocion(jsonb) to authenticated;
grant execute on function fn_calcular_promos(jsonb, uuid) to authenticated;
grant execute on function fn_registrar_venta(uuid, jsonb, jsonb, uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
