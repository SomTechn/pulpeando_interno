-- ============================================================================
--  020 · Editar la existencia desde la consulta, con aprobacion
--
--  LO QUE SE PIDIO
--
--  Que desde la pantalla de consulta se pueda corregir lo que hay en el piso
--  de ventas -o en cualquier otra ubicacion-, y que al darle actualizar eso
--  se vaya a aprobacion en vez de cambiar el inventario de una vez.
--
--  POR QUE PASA POR APROBACION Y NO SE APLICA SOLO
--
--  Bajar una existencia es la forma mas comoda de tapar un faltante. Si la
--  misma persona que atiende la caja puede dejar el sistema en el numero que
--  le convenga, el inventario deja de ser un control y pasa a ser un reflejo
--  de lo que alguien quiso escribir. Por eso se pide y otro aprueba, igual
--  que el conteo: el auxiliar cuenta, el gerente aplica.
--
--  LAS TRES DECISIONES QUE IMPORTAN
--
--  1) SE GUARDA LA DIFERENCIA, NO EL NUMERO.
--
--     Al pedir se congela cuanto decia el sistema EN ESE MOMENTO. Lo que se
--     aplica al aprobar es (contado - ese numero). Si se pide a las 9 de la
--     mañana y se aprueba a las 3 de la tarde, "dejalo en 14" borraria todo
--     lo vendido en el dia; la diferencia lo respeta.
--
--  2) CORREGIR UNA UBICACION CAMBIA EL TOTAL DEL NEGOCIO.
--
--     Si el piso decia 18 y hay 14, faltan 4 de verdad: es merma, robo o una
--     venta sin marcar. No es mover mercaderia. Para lo otro -los 4 estan en
--     la bodega y nadie lo apunto- ya existe "Mover de lugar", que no toca
--     ni el total ni el kardex. La pantalla lo dice con todas sus letras,
--     porque confundir las dos cosas es lo que arruina un inventario.
--
--  3) EL AJUSTE CAE EN LA UBICACION QUE SE CONTO.
--
--     El kardex mueve el total. Si la ubicacion contada no es la
--     predeterminada hay que bajarle tambien su parte del desglose, o la
--     perdida se la comeria el piso y la bodega seguiria diciendo lo mismo.
--
--  QUIEN HACE QUE
--
--      auxiliar     pide el ajuste
--      gerente      lo aprueba o lo rechaza
--
--  Un ajuste pendiente no cambia nada: el inventario sigue como estaba hasta
--  que alguien con rango lo aprueba.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. La tabla
-- ---------------------------------------------------------------------------

create table if not exists ajustes_inventario (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  sucursal_id      uuid not null references sucursales(id),
  numero           text not null,
  producto_id      uuid not null references productos(id),
  lote_id          uuid references lotes(id),
  ubicacion_id     uuid not null references ubicaciones(id),

  -- Lo que decia el sistema cuando se pidio. Congelado a proposito.
  cantidad_sistema numeric(16,3) not null,
  cantidad_contada numeric(16,3) not null check (cantidad_contada >= 0),

  motivo           text,
  estado           text not null default 'pendiente'
                   check (estado in ('pendiente','aprobado','rechazado')),

  solicitado_por   uuid references perfiles(id),
  solicitado_en    timestamptz not null default now(),
  resuelto_por     uuid references perfiles(id),
  resuelto_en      timestamptz,
  nota_resolucion  text,

  -- Lo que de verdad se movio al aprobar, que puede no ser la diferencia
  -- pedida si entre pedir y aprobar cambio algo.
  aplicado         numeric(16,3),
  valor_aplicado   numeric(16,4),

  unique (organizacion_id, numero)
);

-- Un solo pendiente por producto, lote y ubicacion: con dos, el segundo que
-- se apruebe parte de una cantidad de sistema que ya no existe.
create unique index if not exists ux_ajuste_pendiente
  on ajustes_inventario (producto_id, ubicacion_id, lote_id)
  nulls not distinct
  where estado = 'pendiente';

create index if not exists ix_ajustes_sucursal
  on ajustes_inventario (sucursal_id, estado, solicitado_en desc);

alter table ajustes_inventario enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies
                  where tablename='ajustes_inventario' and policyname='ajustes_sel') then
    create policy ajustes_sel on ajustes_inventario for select
      using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))
             or app.es_admin());
  end if;
end $$;

revoke insert, update, delete on ajustes_inventario from authenticated;
grant select on ajustes_inventario to authenticated;


-- ---------------------------------------------------------------------------
-- 2. Cuanto dice el sistema que hay en una ubicacion
--
--    La predeterminada no guarda filas: es el resto. Esta cuenta aparece en
--    tres lugares distintos, asi que vive en un solo sitio.
-- ---------------------------------------------------------------------------

create or replace function app.existencia_en_ubicacion(
  p_producto_id uuid, p_ubicacion_id uuid, p_lote_id uuid
) returns numeric
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  u      record;
  v_tot  numeric;
  v_asig numeric;
  v_n    numeric;
begin
  select * into u from ubicaciones where id = p_ubicacion_id;
  if u.id is null then return null; end if;

  if u.es_predeterminada then
    select coalesce(sum(e.cantidad), 0) into v_tot
    from existencias e
    where e.producto_id = p_producto_id and e.sucursal_id = u.sucursal_id
      and e.lote_id is not distinct from p_lote_id;

    select coalesce(sum(eu.cantidad), 0) into v_asig
    from existencias_ubicacion eu
    where eu.producto_id = p_producto_id and eu.sucursal_id = u.sucursal_id
      and eu.lote_id is not distinct from p_lote_id;

    return greatest(v_tot - v_asig, 0);
  end if;

  select coalesce(cantidad, 0) into v_n
  from existencias_ubicacion
  where producto_id = p_producto_id and sucursal_id = u.sucursal_id
    and ubicacion_id = u.id and lote_id is not distinct from p_lote_id;

  return coalesce(v_n, 0);
end $fn$;

revoke execute on function app.existencia_en_ubicacion(uuid, uuid, uuid) from public, anon;
grant execute on function app.existencia_en_ubicacion(uuid, uuid, uuid) to authenticated;


-- El desglose de UN lote por ubicacion. fn_existencia_por_ubicacion suma
-- todos los lotes juntos, que es lo que sirve para mirar; para corregir hay
-- que ver lote por lote, porque el ajuste cae en un lote concreto.
create or replace function fn_existencia_ubicacion_lote(
  p_producto_id uuid,
  p_lote_id     uuid default null,
  p_sucursal_id uuid default null
)
returns table (
  ubicacion_id      uuid,
  ubicacion         text,
  es_predeterminada boolean,
  orden             int,
  cantidad          numeric
)
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org uuid;
  v_suc uuid;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para ver el inventario';
  end if;

  v_suc := coalesce(p_sucursal_id,
                    (select s.id from sucursales s
                      where s.organizacion_id = v_org and s.activa
                      order by s.es_principal desc limit 1));

  perform 1 from sucursales where id = v_suc and (organizacion_id = v_org or app.es_admin());
  if not found then raise exception 'Esa sucursal no es de su negocio'; end if;

  return query
  select u.id, u.nombre, u.es_predeterminada, u.orden,
         app.existencia_en_ubicacion(p_producto_id, u.id, p_lote_id)
  from ubicaciones u
  where u.sucursal_id = v_suc and u.activa
  order by u.orden, u.nombre;
end $fn$;

revoke execute on function fn_existencia_ubicacion_lote(uuid, uuid, uuid) from public, anon;
grant execute on function fn_existencia_ubicacion_lote(uuid, uuid, uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 3. Pedir el ajuste
-- ---------------------------------------------------------------------------

create or replace function fn_solicitar_ajuste(
  p_producto_id  uuid,
  p_ubicacion_id uuid,
  p_cantidad     numeric,
  p_lote_id      uuid default null,
  p_motivo       text default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org  uuid;
  u      record;
  v_sis  numeric;
  v_num  text;
  v_id   uuid;
begin
  if p_cantidad is null or p_cantidad < 0 then
    raise exception 'La cantidad contada no puede ser negativa';
  end if;

  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para pedir ajustes de inventario';
  end if;

  select * into u from ubicaciones
   where id = p_ubicacion_id and (organizacion_id = v_org or app.es_admin());
  if u.id is null then raise exception 'Esa ubicacion no es de su negocio'; end if;
  if not u.activa then raise exception 'La ubicacion % esta inactiva', u.nombre; end if;

  if not app.es_admin()
     and u.sucursal_id not in (select app.sucursales_permitidas()) then
    raise exception 'No tiene acceso a esa sucursal';
  end if;

  perform 1 from productos
   where id = p_producto_id and organizacion_id = u.organizacion_id
     and activo and tipo <> 'servicio';
  if not found then raise exception 'Ese producto no es de este negocio'; end if;

  if p_lote_id is not null then
    perform 1 from lotes
     where id = p_lote_id and producto_id = p_producto_id
       and sucursal_id = u.sucursal_id;
    if not found then raise exception 'Ese lote no corresponde al producto en esta sucursal'; end if;
  end if;

  if exists (select 1 from ajustes_inventario
              where producto_id = p_producto_id and ubicacion_id = p_ubicacion_id
                and lote_id is not distinct from p_lote_id and estado = 'pendiente') then
    raise exception 'Ya hay un ajuste pendiente de aprobacion para % en %',
      (select nombre from productos where id = p_producto_id), u.nombre;
  end if;

  v_sis := app.existencia_en_ubicacion(p_producto_id, p_ubicacion_id, p_lote_id);

  if v_sis = p_cantidad then
    raise exception 'En % el sistema ya dice %. No hay nada que ajustar', u.nombre, v_sis;
  end if;

  v_num := app.numero_documento(u.organizacion_id, u.sucursal_id, 'ajuste', 'AJ', 6);

  insert into ajustes_inventario (
    organizacion_id, sucursal_id, numero, producto_id, lote_id, ubicacion_id,
    cantidad_sistema, cantidad_contada, motivo, solicitado_por)
  values (u.organizacion_id, u.sucursal_id, v_num, p_producto_id, p_lote_id, u.id,
          v_sis, p_cantidad, nullif(btrim(coalesce(p_motivo,'')), ''), auth.uid())
  returning id into v_id;

  return jsonb_build_object(
    'ajuste_id', v_id, 'numero', v_num,
    'ubicacion', u.nombre,
    'producto',  (select nombre from productos where id = p_producto_id),
    'sistema',   v_sis,
    'contado',   p_cantidad,
    'diferencia', p_cantidad - v_sis,
    -- Para que la pantalla sepa si ofrecer el boton de aprobar.
    'puede_aprobar', app.es_admin() or app.tiene_nivel('gerente'));
end $fn$;

revoke execute on function fn_solicitar_ajuste(uuid, uuid, numeric, uuid, text)
  from public, anon;
grant execute on function fn_solicitar_ajuste(uuid, uuid, numeric, uuid, text)
  to authenticated;


-- ---------------------------------------------------------------------------
-- 4. La lista de ajustes
-- ---------------------------------------------------------------------------

create or replace function fn_ajustes(
  p_estado      text default 'pendiente',
  p_sucursal_id uuid default null,
  p_producto_id uuid default null,
  p_limite      int  default 50
)
returns table (
  ajuste_id      uuid,
  numero         text,
  estado         text,
  producto_id    uuid,
  producto       text,
  sku            text,
  unidad         text,
  lote           text,
  vence          date,
  ubicacion      text,
  sucursal       text,
  sistema        numeric,
  contado        numeric,
  diferencia     numeric,
  valor          numeric,
  motivo         text,
  solicitado_por text,
  solicitado_en  timestamptz,
  resuelto_por   text,
  resuelto_en    timestamptz,
  nota           text,
  aplicado       numeric
)
language sql stable security definer set search_path = public, app as $fn$
  select
    a.id, a.numero, a.estado,
    a.producto_id, pr.nombre, pr.sku, pr.unidad_base,
    lo.codigo, lo.fecha_vencimiento,
    ub.nombre, s.nombre,
    a.cantidad_sistema, a.cantidad_contada,
    a.cantidad_contada - a.cantidad_sistema,
    -- Lo que la diferencia vale en plata solo de supervisor para arriba.
    case when app.tiene_nivel('supervisor')
         then round((a.cantidad_contada - a.cantidad_sistema)
                    * coalesce(pc.costo_promedio, 0), 2) end,
    a.motivo,
    pe.nombre, a.solicitado_en,
    pr2.nombre, a.resuelto_en, a.nota_resolucion,
    a.aplicado
  from ajustes_inventario a
  join productos pr      on pr.id = a.producto_id
  join ubicaciones ub    on ub.id = a.ubicacion_id
  join sucursales s      on s.id = a.sucursal_id
  left join lotes lo     on lo.id = a.lote_id
  left join perfiles pe  on pe.id = a.solicitado_por
  left join perfiles pr2 on pr2.id = a.resuelto_por
  left join producto_costos pc on pc.producto_id = a.producto_id
                              and pc.sucursal_id = a.sucursal_id
  where app.tiene_nivel('auxiliar')
    and a.organizacion_id = app.org_id()
    and a.sucursal_id in (select app.sucursales_permitidas())
    and (p_estado is null or p_estado = 'todos' or a.estado = p_estado)
    and (p_sucursal_id is null or a.sucursal_id = p_sucursal_id)
    and (p_producto_id is null or a.producto_id = p_producto_id)
  order by (a.estado = 'pendiente') desc, a.solicitado_en desc
  limit greatest(coalesce(p_limite, 50), 1)
$fn$;

revoke execute on function fn_ajustes(text, uuid, uuid, int) from public, anon;
grant execute on function fn_ajustes(text, uuid, uuid, int) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. Aprobar o rechazar
--
--    Aqui se mueve el inventario de verdad.
-- ---------------------------------------------------------------------------

create or replace function fn_resolver_ajuste(
  p_ajuste_id uuid,
  p_aprobar   boolean,
  p_nota      text default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  a        record;
  u        record;
  v_sis    numeric;
  v_dif    numeric;
  v_costo  numeric;
  v_tipo   tipo_movimiento;
begin
  select * into a from ajustes_inventario where id = p_ajuste_id for update;
  if a.id is null then raise exception 'Ese ajuste no existe'; end if;
  if a.estado <> 'pendiente' then
    raise exception 'Ese ajuste ya se habia %', a.estado;
  end if;

  -- "de este negocio": el gerente de otra pulperia tambien es gerente, y
  -- tiene_nivel mira el rango de quien llama, no de quien es la fila.
  if not (app.es_admin()
          or (a.organizacion_id = app.org_id() and app.tiene_nivel('gerente'))) then
    raise exception 'Solo el gerente de este negocio puede aprobar un ajuste de inventario';
  end if;

  if not p_aprobar then
    if p_nota is null or btrim(p_nota) = '' then
      raise exception 'Rechazar un ajuste exige decir por que';
    end if;
    update ajustes_inventario
       set estado = 'rechazado', resuelto_por = auth.uid(), resuelto_en = now(),
           nota_resolucion = btrim(p_nota)
     where id = a.id;
    return jsonb_build_object('numero', a.numero, 'estado', 'rechazado');
  end if;

  select * into u from ubicaciones where id = a.ubicacion_id;

  -- La diferencia se mide contra lo congelado al pedir, no contra lo de
  -- ahora: lo que se vendio entre pedir y aprobar es venta, no faltante.
  v_dif := a.cantidad_contada - a.cantidad_sistema;

  select coalesce(costo_promedio, 0) into v_costo
  from producto_costos
  where producto_id = a.producto_id and sucursal_id = a.sucursal_id;

  v_tipo := case when v_dif > 0 then 'ajuste_positivo' else 'ajuste_negativo' end;

  -- ORDEN: primero el desglose, despues el kardex.
  --
  -- Si la ubicacion contada no es la predeterminada hay que bajarle o subirle
  -- su parte, o la perdida se la comeria el piso y la bodega seguiria
  -- diciendo lo mismo. Pero tiene que ir ANTES del kardex: al bajar el total,
  -- el disparador que cuadra las ubicaciones ve un desglose que ya no cabe y
  -- lo recorta por su cuenta; si despues se restara otra vez, la ubicacion
  -- quedaria con menos de lo que se conto. Pasó: bajar la bodega de 30 a 25
  -- la dejaba en 24.
  if not u.es_predeterminada then
    insert into existencias_ubicacion (organizacion_id, sucursal_id, producto_id,
                                       lote_id, ubicacion_id, cantidad)
    values (a.organizacion_id, a.sucursal_id, a.producto_id, a.lote_id, u.id,
            greatest(v_dif, 0))
    on conflict (producto_id, sucursal_id, ubicacion_id, lote_id) do update
      set cantidad = greatest(existencias_ubicacion.cantidad + v_dif, 0),
          actualizado_en = now();
  end if;

  begin
    perform fn_kardex_registrar(
      a.sucursal_id, a.producto_id, v_tipo, abs(v_dif),
      case when v_dif > 0 then coalesce(v_costo, 0) end,
      a.lote_id, 'ajuste', a.id,
      'Ajuste ' || a.numero || ' · ' || u.nombre, auth.uid());
  exception when others then
    if sqlerrm like '%insuficiente%' then
      raise exception 'Ya no hay suficiente % para aplicar el ajuste: se vendio despues de contarlo. Vuelva a contar y pida el ajuste de nuevo',
        (select nombre from productos where id = a.producto_id);
    else
      raise;
    end if;
  end;

  update ajustes_inventario
     set estado = 'aprobado', resuelto_por = auth.uid(), resuelto_en = now(),
         nota_resolucion = nullif(btrim(coalesce(p_nota,'')), ''),
         aplicado = v_dif,
         valor_aplicado = round(v_dif * coalesce(v_costo, 0), 4)
   where id = a.id;

  select app.existencia_en_ubicacion(a.producto_id, a.ubicacion_id, a.lote_id)
    into v_sis;

  return jsonb_build_object(
    'numero', a.numero, 'estado', 'aprobado',
    'ubicacion', u.nombre,
    'producto', (select nombre from productos where id = a.producto_id),
    'diferencia', v_dif,
    'queda_en', v_sis,
    'existencia_total', (select coalesce(sum(e.cantidad), 0) from existencias e
                          where e.producto_id = a.producto_id
                            and e.sucursal_id = a.sucursal_id),
    'valor', case when app.tiene_nivel('supervisor')
                  then round(v_dif * coalesce(v_costo, 0), 2) end);
end $fn$;

revoke execute on function fn_resolver_ajuste(uuid, boolean, text) from public, anon;
grant execute on function fn_resolver_ajuste(uuid, boolean, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 6. El perfil del producto avisa si tiene un ajuste esperando
--
--    Sin esto, dos personas piden el mismo ajuste y la segunda solo se entera
--    por un error.
-- ---------------------------------------------------------------------------

create or replace function fn_consultar_producto(
  p_producto_id uuid,
  p_sucursal_id uuid default null
) returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org   uuid;
  v_suc   uuid;
  v_ve    boolean;
  p       record;
  v_total numeric;
  v_apart numeric;
  v_prom  numeric;
  v_ult   numeric;
  v_precio numeric;
  r       jsonb;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para consultar productos';
  end if;

  v_suc := coalesce(p_sucursal_id,
                    (select s.id from sucursales s
                      where s.organizacion_id = v_org and s.activa
                      order by s.es_principal desc limit 1));

  select * into p from productos
   where id = p_producto_id and (organizacion_id = v_org or app.es_admin());
  if p.id is null then raise exception 'Ese producto no es de su negocio'; end if;

  perform 1 from sucursales where id = v_suc and (organizacion_id = v_org or app.es_admin());
  if not found then raise exception 'Esa sucursal no es de su negocio'; end if;

  v_ve := app.tiene_nivel('supervisor') or app.es_admin();

  select coalesce(sum(cantidad), 0) into v_total
  from existencias where producto_id = p.id and sucursal_id = v_suc;

  select coalesce(sum(cantidad), 0) into v_apart
  from pedido_reservas
  where producto_id = p.id and sucursal_id = v_suc and liberada_en is null;

  select costo_promedio, ultimo_costo into v_prom, v_ult
  from producto_costos where producto_id = p.id and sucursal_id = v_suc;

  v_precio := fn_precio_vigente(p.id, v_suc, 1);

  select jsonb_build_object(
    'producto_id', p.id,
    'nombre',      p.nombre,
    'sku',         p.sku,
    'descripcion', p.descripcion,
    'imagen_url',  p.imagen_url,
    'unidad',      p.unidad_base,
    'tipo',        p.tipo,
    'activo',      p.activo,
    'se_vende',    p.se_vende,
    'categoria',   (select nombre from categorias  where id = p.categoria_id),
    'marca',       (select nombre from marcas      where id = p.marca_id),
    'proveedor',   (select nombre from proveedores where id = p.proveedor_id),
    'tasa_impuesto', coalesce((select tasa from impuestos where id = p.impuesto_id), 0),
    'controla_lote', p.controla_lote,
    'controla_vencimiento', p.controla_vencimiento,
    'dias_alerta', coalesce(p.dias_alerta_vencim,
                            (select o.dias_alerta_vencimiento from organizaciones o
                              where o.id = p.organizacion_id), 30),

    'sucursal_id', v_suc,
    'sucursal',    (select nombre from sucursales where id = v_suc),

    'codigos', coalesce((select jsonb_agg(pc.codigo order by pc.es_principal desc, pc.codigo)
                          from producto_codigos pc where pc.producto_id = p.id), '[]'::jsonb),

    'precio', v_precio,
    'precios', coalesce((select jsonb_agg(jsonb_build_object(
                            'nivel', pr.nivel, 'desde', pr.cantidad_minima, 'precio', pr.precio)
                            order by pr.nivel, pr.cantidad_minima)
                          from precios pr
                          where pr.producto_id = p.id
                            and (pr.sucursal_id = v_suc or pr.sucursal_id is null)
                            and pr.vigente_desde <= current_date
                            and (pr.vigente_hasta is null or pr.vigente_hasta >= current_date)
                        ), '[]'::jsonb),

    'costo_promedio', case when v_ve then coalesce(v_prom, 0) end,
    'ultimo_costo',   case when v_ve then coalesce(v_ult, 0) end,
    'margen',         case when v_ve and v_precio > 0 and coalesce(v_prom, 0) > 0
                           then round((v_precio - v_prom) / v_precio * 100, 1) end,
    'valor_inventario', case when v_ve then round(v_total * coalesce(v_prom, 0), 2) end,

    'existencia',       v_total,
    'apartado',         v_apart,
    'disponible',       greatest(v_total - v_apart, 0),
    'stock_minimo',     p.stock_minimo,
    'stock_maximo',     p.stock_maximo,
    'stock_bajo',       v_total <= p.stock_minimo,

    'ubicaciones', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ubicacion_id', x.ubicacion_id, 'nombre', x.ubicacion,
               'predeterminada', x.es_predeterminada, 'cantidad', x.cantidad)
               order by x.orden, x.ubicacion)
      from fn_existencia_por_ubicacion(p.id, v_suc) x), '[]'::jsonb),

    'lotes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'lote_id', l.id, 'codigo', l.codigo,
               'vence', l.fecha_vencimiento,
               'dias', case when l.fecha_vencimiento is not null
                            then l.fecha_vencimiento - current_date end,
               'cantidad', e.cantidad)
               order by l.fecha_vencimiento nulls last, l.creado_en)
      from existencias e
      join lotes l on l.id = e.lote_id
      where e.producto_id = p.id and e.sucursal_id = v_suc and e.cantidad > 0),
      '[]'::jsonb),

    'sin_lote', coalesce((select sum(e.cantidad) from existencias e
                           where e.producto_id = p.id and e.sucursal_id = v_suc
                             and e.lote_id is null), 0),

    'otras_sucursales', coalesce((
      select jsonb_agg(jsonb_build_object('sucursal', s.nombre, 'cantidad', t.c)
                       order by s.nombre)
      from sucursales s
      join lateral (select coalesce(sum(e.cantidad), 0) as c from existencias e
                     where e.producto_id = p.id and e.sucursal_id = s.id) t on true
      where s.organizacion_id = p.organizacion_id and s.activa and s.id <> v_suc
        and (app.es_admin() or s.id in (select app.sucursales_permitidas()))
        and t.c <> 0), '[]'::jsonb),

    'ultima_compra', (
      select jsonb_build_object('fecha', k.ocurrido_en,
                                'cantidad', k.cantidad,
                                'costo', case when v_ve then k.costo_unitario end)
      from kardex k
      where k.producto_id = p.id and k.sucursal_id = v_suc
        and k.tipo = 'compra'
      order by k.ocurrido_en desc limit 1),

    'ultima_venta', (
      select max(v.creada_en) from ventas v
      join venta_detalle d on d.venta_id = v.id
      where d.producto_id = p.id and v.sucursal_id = v_suc
        and v.estado = 'completada'),

    'vendido_30d', coalesce((
      select sum(d.cantidad) from ventas v
      join venta_detalle d on d.venta_id = v.id
      where d.producto_id = p.id and v.sucursal_id = v_suc
        and v.estado = 'completada'
        and v.creada_en >= now() - interval '30 days'), 0),

    'conteo_abierto', (
      select jsonb_build_object('conteo_id', c.id, 'numero', c.numero,
                                'alcance', c.alcance)
      from conteos c
      where c.sucursal_id = v_suc and c.estado = 'abierto' limit 1),

    -- Los ajustes de este producto que estan esperando aprobacion.
    'ajustes_pendientes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ajuste_id', a.id, 'numero', a.numero,
               'ubicacion', ub.nombre, 'ubicacion_id', a.ubicacion_id,
               'lote_id', a.lote_id,
               'lote', (select codigo from lotes where id = a.lote_id),
               'sistema', a.cantidad_sistema, 'contado', a.cantidad_contada,
               'diferencia', a.cantidad_contada - a.cantidad_sistema,
               'motivo', a.motivo,
               'solicitado_por', (select nombre from perfiles where id = a.solicitado_por),
               'solicitado_en', a.solicitado_en)
               order by a.solicitado_en)
      from ajustes_inventario a
      join ubicaciones ub on ub.id = a.ubicacion_id
      where a.producto_id = p.id and a.sucursal_id = v_suc
        and a.estado = 'pendiente'), '[]'::jsonb),

    'puede_aprobar', app.es_admin() or app.tiene_nivel('gerente'),
    'puede_ver_costos', v_ve
  ) into r;

  return r;
end $fn$;

revoke execute on function fn_consultar_producto(uuid, uuid) from public, anon;
grant execute on function fn_consultar_producto(uuid, uuid) to authenticated;
