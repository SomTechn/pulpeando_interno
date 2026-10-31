-- ============================================================================
--  Migración 039 · Precio de oferta
--
--  Hasta ahora un producto tenía un precio y punto. Para poner una oferta
--  había que cambiar el precio y acordarse de regresarlo, y la etiqueta del
--  estante no tenía cómo decir "antes L 45, ahora L 39".
--
--  UNA OFERTA ES UN PRECIO MÁS, MARCADO Y CON FECHA DE FIN
--
--    precios.es_oferta = true, y vigente_hasta obligatorio. Una oferta sin
--    fin es un precio nuevo, no una oferta.
--
--  CÓMO SE COBRA
--
--    fn_precio_vigente busca el precio de siempre (como antes, sin mirar
--    las ofertas) y aparte la oferta vigente, y cobra el MENOR de los dos.
--    Así una oferta nunca sube un precio: si el cliente de mayoreo ya paga
--    menos que la oferta, sigue pagando lo suyo. La caja, los pedidos y la
--    consulta usan fn_precio_vigente, así que la oferta llega a todos sin
--    tocarlos.
--
--  QUIÉN LA PONE
--
--    fn_fijar_oferta y fn_quitar_oferta, solo gerente y solo de su negocio.
--    Quitar no borra: le pone fin ayer, y queda de historia.
--
--  LA ETIQUETA
--
--    fn_etiqueta_producto devuelve lo que se imprime en el estante: nombre,
--    item, código de barras, precio, y si hay oferta, el precio de antes y
--    hasta cuándo dura.
-- ============================================================================

alter table precios add column if not exists es_oferta boolean not null default false;

do $c$
begin
  if not exists (select 1 from pg_constraint where conname = 'ck_precio_oferta_con_fin') then
    alter table precios add constraint ck_precio_oferta_con_fin
      check (not es_oferta or vigente_hasta is not null);
  end if;
end
$c$;


-- ---------------------------------------------------------------------------
-- fn_precio_vigente: el de siempre, o la oferta si es menor.
-- La firma no cambia (la usa v_pos_catalogo).
-- ---------------------------------------------------------------------------
create or replace function fn_precio_vigente(
  p_producto_id uuid, p_sucursal_id uuid,
  p_cantidad numeric default 1, p_nivel nivel_precio default 'detalle'
) returns numeric
language sql stable set search_path = public, app as $fn$
  select least(
    -- el precio de siempre: igual que antes, sin las ofertas
    (select pr.precio from precios pr
      where pr.producto_id = p_producto_id
        and (pr.sucursal_id = p_sucursal_id or pr.sucursal_id is null)
        and pr.nivel = p_nivel
        and not pr.es_oferta
        and pr.cantidad_minima <= p_cantidad
        and pr.vigente_desde <= current_date
        and (pr.vigente_hasta is null or pr.vigente_hasta >= current_date)
      order by pr.sucursal_id nulls last, pr.cantidad_minima desc, pr.vigente_desde desc
      limit 1),
    -- la oferta vigente, de cualquier nivel: es para todos
    (select pr.precio from precios pr
      where pr.producto_id = p_producto_id
        and (pr.sucursal_id = p_sucursal_id or pr.sucursal_id is null)
        and pr.es_oferta
        and pr.cantidad_minima <= p_cantidad
        and pr.vigente_desde <= current_date
        and pr.vigente_hasta >= current_date
      order by pr.sucursal_id nulls last, pr.precio
      limit 1))
  -- least() ignora los null: sin oferta queda el de siempre, y al reves
$fn$;

revoke execute on function fn_precio_vigente(uuid, uuid, numeric, nivel_precio) from public, anon;
grant  execute on function fn_precio_vigente(uuid, uuid, numeric, nivel_precio) to authenticated;


-- ---------------------------------------------------------------------------
-- Poner una oferta. Si ya había una para ese producto y esa sucursal que se
-- cruza con las fechas nuevas, la anterior termina el día antes de que
-- empiece esta: dos ofertas a la vez solo confunden al que lee la etiqueta.
-- ---------------------------------------------------------------------------
create or replace function fn_fijar_oferta(
  p_producto_id uuid,
  p_precio      numeric,
  p_hasta       date,
  p_desde       date default null,
  p_sucursal_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org   uuid := app.org_id();
  v_desde date := coalesce(p_desde, current_date);
  p       record;
  v_id    uuid;
begin
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('gerente'))) then
    raise exception 'Solo el gerente pone ofertas';
  end if;

  select * into p from productos where id = p_producto_id;
  if p.id is null or (p.organizacion_id <> v_org and not app.es_admin()) then
    raise exception 'Ese producto no es de su negocio';
  end if;

  if p_sucursal_id is not null and not exists (
       select 1 from sucursales where id = p_sucursal_id
          and organizacion_id = p.organizacion_id) then
    raise exception 'Esa sucursal no es de su negocio';
  end if;

  if p_precio is null or p_precio <= 0 then
    raise exception 'El precio de oferta tiene que ser mayor que cero';
  end if;
  if p_hasta is null then
    raise exception 'La oferta necesita fecha de fin';
  end if;
  if p_hasta < v_desde then
    raise exception 'La oferta termina antes de empezar';
  end if;
  if p_hasta < current_date then
    raise exception 'Esa fecha de fin ya pasó';
  end if;

  update precios
     set vigente_hasta = v_desde - 1, actualizado_en = now()
   where producto_id = p.id and es_oferta
     and sucursal_id is not distinct from p_sucursal_id
     and vigente_hasta >= v_desde
     and vigente_desde <= p_hasta;

  insert into precios (organizacion_id, producto_id, sucursal_id, nivel, cantidad_minima,
                       precio, vigente_desde, vigente_hasta, es_oferta)
  values (p.organizacion_id, p.id, p_sucursal_id, 'detalle', 1,
          round(p_precio, 2), v_desde, p_hasta, true)
  returning id into v_id;

  return v_id;
end $fn$;

revoke execute on function fn_fijar_oferta(uuid, numeric, date, date, uuid) from public, anon;
grant  execute on function fn_fijar_oferta(uuid, numeric, date, date, uuid) to authenticated;


-- Quitar una oferta: termina ayer. No se borra, queda de historia.
create or replace function fn_quitar_oferta(p_precio_id uuid) returns boolean
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  r     record;
begin
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('gerente'))) then
    raise exception 'Solo el gerente quita ofertas';
  end if;

  select * into r from precios where id = p_precio_id and es_oferta;
  if r.id is null or (r.organizacion_id <> v_org and not app.es_admin()) then
    raise exception 'Esa oferta no es de su negocio';
  end if;

  update precios
     set vigente_hasta = least(vigente_hasta, current_date - 1),
         vigente_desde = least(vigente_desde, current_date - 1),
         actualizado_en = now()
   where id = r.id;
  return true;
end $fn$;

revoke execute on function fn_quitar_oferta(uuid) from public, anon;
grant  execute on function fn_quitar_oferta(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- Lo que lleva la etiqueta del estante.
-- ---------------------------------------------------------------------------
create or replace function fn_etiqueta_producto(
  p_producto_id uuid, p_sucursal_id uuid default null
) returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org     uuid := app.org_id();
  v_suc     uuid;
  p         record;
  v_precio  numeric;
  v_regular numeric;
  o         record;
begin
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para imprimir etiquetas';
  end if;

  select * into p from productos where id = p_producto_id;
  if p.id is null or (p.organizacion_id <> v_org and not app.es_admin()) then
    raise exception 'Ese producto no es de su negocio';
  end if;

  v_suc := coalesce(p_sucursal_id,
                    (select s.id from sucursales s
                      where s.organizacion_id = p.organizacion_id and s.activa
                      order by s.es_principal desc limit 1));
  if v_suc is not null and not exists (
       select 1 from sucursales where id = v_suc and organizacion_id = p.organizacion_id) then
    raise exception 'Esa sucursal no es de su negocio';
  end if;

  v_precio := fn_precio_vigente(p.id, v_suc, 1);

  select pr.precio into v_regular from precios pr
   where pr.producto_id = p.id
     and (pr.sucursal_id = v_suc or pr.sucursal_id is null)
     and pr.nivel = 'detalle' and not pr.es_oferta
     and pr.cantidad_minima <= 1
     and pr.vigente_desde <= current_date
     and (pr.vigente_hasta is null or pr.vigente_hasta >= current_date)
   order by pr.sucursal_id nulls last, pr.cantidad_minima desc, pr.vigente_desde desc
   limit 1;

  -- la oferta que se está cobrando (si es la que manda)
  select pr.id, pr.precio, pr.vigente_desde, pr.vigente_hasta into o from precios pr
   where pr.producto_id = p.id
     and (pr.sucursal_id = v_suc or pr.sucursal_id is null)
     and pr.es_oferta and pr.cantidad_minima <= 1
     and pr.vigente_desde <= current_date and pr.vigente_hasta >= current_date
   order by pr.sucursal_id nulls last, pr.precio
   limit 1;

  return jsonb_build_object(
    'producto_id', p.id,
    'nombre',      p.nombre,
    'sku',         p.sku,
    'unidad',      p.unidad_base,
    'marca',       (select nombre from marcas where id = p.marca_id),
    'codigo',      (select pc.codigo from producto_codigos pc where pc.producto_id = p.id
                     order by pc.es_principal desc, pc.codigo limit 1),
    'negocio',     (select nombre from organizaciones where id = p.organizacion_id),
    'sucursal_id', v_suc,
    'precio',      v_precio,
    'precio_regular', v_regular,
    'oferta', case when o.id is not null and v_regular is not null and o.precio < v_regular
                   then jsonb_build_object('id', o.id, 'precio', o.precio,
                                           'desde', o.vigente_desde, 'hasta', o.vigente_hasta)
              end,
    -- las de hoy en adelante, para que el gerente vea y quite
    'ofertas', coalesce((select jsonb_agg(jsonb_build_object(
                  'id', pr.id, 'precio', pr.precio, 'desde', pr.vigente_desde,
                  'hasta', pr.vigente_hasta,
                  'sucursal', (select nombre from sucursales where id = pr.sucursal_id))
                  order by pr.vigente_desde)
                from precios pr
               where pr.producto_id = p.id and pr.es_oferta
                 and pr.vigente_hasta >= current_date
                 and (pr.sucursal_id = v_suc or pr.sucursal_id is null)), '[]'::jsonb),
    'puede_ofertar', app.es_admin() or app.tiene_nivel('gerente'),
    'hoy', current_date
  );
end $fn$;

revoke execute on function fn_etiqueta_producto(uuid, uuid) from public, anon;
grant  execute on function fn_etiqueta_producto(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
