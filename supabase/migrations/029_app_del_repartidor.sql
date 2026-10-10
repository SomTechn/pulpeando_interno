-- ===========================================================================
-- 029 · App del repartidor
--
-- Lo que necesita el repartidor en el telefono, y dos huecos del flujo de
-- pedidos que salieron al disenarla:
--
--   1. UN PEDIDO NO SALE NI SE ENTREGA SIN COBRARSE.
--      Hasta ahora el tablero dejaba mandar a ruta un pedido sin pasar por
--      "Cobrar y despachar", y un pedido entregado ya no ofrece cobrar. Ese
--      pedido nunca se volvia venta: la mercaderia salio y el kardex no se
--      entero. Ahora en_ruta y entregado exigen que el pedido tenga venta.
--
--      Y al reves: un pedido cobrado no se cancela sin anular antes su
--      venta, o la mercaderia regresa pero el kardex la da por vendida.
--
--   2. NO SE PUDO ENTREGAR.
--      La casa cerrada, el cliente no contesta, la direccion no existe. El
--      repartidor lo reporta con un motivo; el pedido vuelve a "listo" en el
--      tablero con el motivo a la vista, y la tienda decide (otro intento,
--      cancelar, llamar al cliente).
--
-- Y para el repartidor:
--   · fn_mis_entregas con lo que le faltaba: tienda, envio, la incidencia
--   · fn_mi_jornada: lo entregado hoy y cuanto EFECTIVO trae encima. Es la
--     cifra que tiene que entregar en la tienda al volver.
-- ===========================================================================

alter table pedidos add column if not exists incidencia    text;
alter table pedidos add column if not exists incidencia_en timestamptz;


-- ---------------------------------------------------------------------------
-- 1. Cambiar estado: ruta y entrega solo con el pedido cobrado
-- ---------------------------------------------------------------------------
create or replace function fn_cambiar_estado_pedido(
  p_pedido_id uuid,
  p_estado    estado_pedido,
  p_nota      text default null
) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  p record;
  d record;
begin
  select * into p from pedidos where id = p_pedido_id for update;
  if p.id is null then raise exception 'Pedido inexistente'; end if;

  if app.es_repartidor() then
    if p.repartidor_id is distinct from auth.uid() then
      raise exception 'Ese pedido no está asignado a usted';
    end if;
    if p_estado not in ('en_ruta', 'entregado') then
      raise exception 'Un repartidor solo marca en ruta o entregado';
    end if;
  elsif not (app.tiene_nivel('auxiliar') and p.organizacion_id = app.org_id())
        and not app.es_admin() then
    raise exception 'No tiene permiso sobre este pedido';
  end if;

  if p.estado in ('entregado', 'cancelado') then
    raise exception 'El pedido ya está %', p.estado;
  end if;

  if p_estado = 'cancelado' and not (app.tiene_nivel('supervisor') or app.es_admin()) then
    raise exception 'Solo un supervisor puede cancelar un pedido';
  end if;

  -- NUEVO: un pedido cobrado no se cancela sin anular su venta. Si no, la
  -- mercaderia vuelve a la tienda pero el kardex la sigue dando por vendida.
  if p_estado = 'cancelado' and p.venta_id is not null
     and exists (select 1 from ventas v where v.id = p.venta_id and v.estado = 'completada') then
    raise exception 'El pedido % ya se cobró. Anule la venta en Ventas (la mercadería regresa al inventario) y después cancélelo', p.numero;
  end if;

  -- NUEVO: sin venta la mercaderia saldria sin descargarse del inventario
  if p_estado in ('en_ruta', 'entregado') and p.venta_id is null then
    raise exception 'El pedido % todavía no está cobrado. Cóbrelo en «Cobrar y despachar» antes de que salga', p.numero;
  end if;

  if p_estado = 'en_ruta' and p.tipo_entrega = 'domicilio' and p.repartidor_id is null then
    raise exception 'Asigne un repartidor antes de mandarlo a entregar';
  end if;

  if p_estado = 'confirmado' and p.estado = 'nuevo' then
    for d in
      select producto_id, coalesce(cantidad_surtida, cantidad) as cant
      from pedido_detalle where pedido_id = p_pedido_id
    loop
      insert into pedido_reservas (organizacion_id, sucursal_id, pedido_id, producto_id, cantidad)
      values (p.organizacion_id, p.sucursal_id, p_pedido_id, d.producto_id, d.cant);
    end loop;
  end if;

  if p_estado in ('cancelado', 'entregado') then
    update pedido_reservas set liberada_en = now()
     where pedido_id = p_pedido_id and liberada_en is null;
  end if;

  update pedidos
     set estado = p_estado,
         entregado_en = case when p_estado = 'entregado' then now() else entregado_en end,
         motivo_cancelacion = case when p_estado = 'cancelado' then p_nota else motivo_cancelacion end,
         -- un nuevo intento o la entrega borran la incidencia anterior
         incidencia    = case when p_estado in ('en_ruta', 'entregado', 'cancelado') then null else incidencia end,
         incidencia_en = case when p_estado in ('en_ruta', 'entregado', 'cancelado') then null else incidencia_en end
   where id = p_pedido_id;

  insert into pedido_eventos (organizacion_id, pedido_id, estado, usuario_id, nota)
  values (p.organizacion_id, p_pedido_id, p_estado, auth.uid(), p_nota);
end $$;

revoke execute on function fn_cambiar_estado_pedido(uuid, estado_pedido, text) from public, anon;
grant  execute on function fn_cambiar_estado_pedido(uuid, estado_pedido, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 2. No se pudo entregar
-- ---------------------------------------------------------------------------
create or replace function fn_entrega_fallida(p_pedido_id uuid, p_motivo text)
returns void
language plpgsql security definer set search_path = public, app as $$
declare
  p record;
  v_motivo text := nullif(btrim(coalesce(p_motivo, '')), '');
begin
  select * into p from pedidos where id = p_pedido_id for update;
  if p.id is null then raise exception 'Pedido inexistente'; end if;

  if app.es_repartidor() then
    if p.repartidor_id is distinct from auth.uid() then
      raise exception 'Ese pedido no está asignado a usted';
    end if;
  elsif not (app.tiene_nivel('auxiliar') and p.organizacion_id = app.org_id())
        and not app.es_admin() then
    raise exception 'No tiene permiso sobre este pedido';
  end if;

  if p.estado not in ('listo', 'en_ruta') then
    raise exception 'El pedido está %, no en camino', p.estado;
  end if;
  if v_motivo is null then raise exception 'Diga por qué no se pudo entregar'; end if;

  update pedidos
     set estado = 'listo', incidencia = v_motivo, incidencia_en = now()
   where id = p_pedido_id;

  insert into pedido_eventos (organizacion_id, pedido_id, estado, usuario_id, nota)
  values (p.organizacion_id, p_pedido_id, 'listo', auth.uid(), 'No se pudo entregar: ' || v_motivo);
end $$;

revoke execute on function fn_entrega_fallida(uuid, text) from public, anon;
grant  execute on function fn_entrega_fallida(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 3. Mis entregas, con lo que faltaba
-- ---------------------------------------------------------------------------
drop function if exists fn_mis_entregas();

create function fn_mis_entregas()
returns table (
  pedido_id    uuid,
  numero       text,
  estado       estado_pedido,
  tienda       text,
  tienda_dir   text,
  tienda_tel   text,
  cliente      text,
  telefono     text,
  direccion    text,
  referencia   text,
  latitud      numeric,
  longitud     numeric,
  total        numeric,
  costo_envio  numeric,
  metodo_pago  metodo_pago,
  paga_con     numeric,
  cobrado      boolean,
  notas        text,
  productos    int,
  incidencia   text,
  programado_para timestamptz,
  creado_en    timestamptz
)
language sql stable security definer set search_path = public, app as $$
  select
    p.id, p.numero, p.estado,
    s.nombre, s.direccion, s.telefono,
    coalesce(cl.nombre, p.nombre_contacto, 'Cliente'),
    coalesce(cl.telefono, p.telefono_contacto),
    coalesce(p.direccion_texto, dc.direccion),
    coalesce(dc.referencia, p.referencia),
    dc.latitud, dc.longitud,
    p.total, p.costo_envio, p.metodo_pago, p.paga_con,
    p.venta_id is not null,
    p.notas,
    (select count(*)::int from pedido_detalle d where d.pedido_id = p.id
       and coalesce(d.cantidad_surtida, d.cantidad) > 0),
    p.incidencia,
    p.programado_para,
    p.creado_en
  from pedidos p
  join sucursales s                on s.id = p.sucursal_id
  left join clientes cl            on cl.id = p.cliente_id
  left join direcciones_cliente dc on dc.id = p.direccion_id
  where p.repartidor_id = auth.uid()
    and p.estado in ('listo', 'en_ruta')
  order by case p.estado when 'en_ruta' then 0 else 1 end,
           coalesce(p.programado_para, p.creado_en)
$$;

revoke execute on function fn_mis_entregas() from public, anon;
grant  execute on function fn_mis_entregas() to authenticated;


-- ---------------------------------------------------------------------------
-- 4. Mi jornada: lo entregado hoy y el efectivo que traigo
-- ---------------------------------------------------------------------------
create or replace function fn_mi_jornada()
returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_yo   record;
  v_tz   text;
  v_ini  timestamptz;
  r      jsonb;
begin
  select pf.id, pf.nombre, pf.rol::text as rol, pf.organizacion_id, o.nombre as negocio, o.moneda
    into v_yo
  from perfiles pf join organizaciones o on o.id = pf.organizacion_id
  where pf.id = auth.uid() and pf.activo;
  if v_yo.id is null then raise exception 'Usuario sin perfil activo'; end if;

  v_tz  := app.zona(v_yo.organizacion_id);
  v_ini := (now() at time zone v_tz)::date::timestamp at time zone v_tz;

  select jsonb_build_object(
    'nombre',  v_yo.nombre,
    'rol',     v_yo.rol,
    'negocio', v_yo.negocio,
    'moneda',  v_yo.moneda,
    'entregados', (select count(*) from pedidos p
                    where p.repartidor_id = v_yo.id and p.estado = 'entregado'
                      and p.entregado_en >= v_ini),
    'efectivo',   (select coalesce(sum(p.total), 0) from pedidos p
                    where p.repartidor_id = v_yo.id and p.estado = 'entregado'
                      and p.entregado_en >= v_ini and p.metodo_pago = 'efectivo'),
    'envios',     (select coalesce(sum(p.costo_envio), 0) from pedidos p
                    where p.repartidor_id = v_yo.id and p.estado = 'entregado'
                      and p.entregado_en >= v_ini),
    'hoy', coalesce((
      select jsonb_agg(jsonb_build_object(
               'numero', p.numero,
               'cliente', coalesce(cl.nombre, p.nombre_contacto, 'Cliente'),
               'total', p.total,
               'metodo_pago', p.metodo_pago,
               'entregado_en', p.entregado_en) order by p.entregado_en desc)
      from pedidos p left join clientes cl on cl.id = p.cliente_id
      where p.repartidor_id = v_yo.id and p.estado = 'entregado'
        and p.entregado_en >= v_ini), '[]'::jsonb)
  ) into r;
  return r;
end $$;

revoke execute on function fn_mi_jornada() from public, anon;
grant  execute on function fn_mi_jornada() to authenticated;


-- ---------------------------------------------------------------------------
-- 5. El tablero muestra la incidencia (columna nueva al final de la vista)
-- ---------------------------------------------------------------------------
create or replace view v_pedidos_tablero as
select
  p.id,
  p.organizacion_id,
  p.sucursal_id,
  p.numero,
  p.origen,
  p.estado,
  p.tipo_entrega,
  p.creado_en,
  p.programado_para,
  p.entregado_en,
  p.total,
  p.costo_envio,
  p.metodo_pago,
  p.paga_con,
  p.notas,
  p.venta_id,
  p.motivo_cancelacion,
  p.cliente_id,
  coalesce(cl.nombre, p.nombre_contacto, 'Cliente de mostrador') as cliente,
  coalesce(cl.telefono, p.telefono_contacto)                     as telefono,
  coalesce(p.direccion_texto, dc.direccion)                      as direccion,
  coalesce(dc.referencia, p.referencia)                          as referencia,
  dc.latitud, dc.longitud,
  p.repartidor_id,
  rp.nombre                                                      as repartidor,
  (select count(*) from pedido_detalle d where d.pedido_id = p.id)          as lineas,
  (select coalesce(sum(d.cantidad), 0) from pedido_detalle d where d.pedido_id = p.id) as unidades,
  floor(extract(epoch from (now() - p.creado_en)) / 60)::int      as minutos,
  exists (
    select 1
    from pedido_detalle d
    join (select producto_id, sucursal_id, sum(cantidad) as hay
          from existencias group by producto_id, sucursal_id) e
      on e.producto_id = d.producto_id and e.sucursal_id = p.sucursal_id
    where d.pedido_id = p.id
      and e.hay < coalesce(d.cantidad_surtida, d.cantidad)
  ) as tiene_faltantes,
  p.incidencia,
  p.incidencia_en
from pedidos p
left join clientes cl            on cl.id = p.cliente_id
left join direcciones_cliente dc on dc.id = p.direccion_id
left join perfiles rp            on rp.id = p.repartidor_id;

alter view v_pedidos_tablero set (security_invoker = on);
grant select on v_pedidos_tablero to authenticated;

notify pgrst, 'reload schema';
