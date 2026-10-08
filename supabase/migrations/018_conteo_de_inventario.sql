-- ============================================================================
--  018 · Conteo fisico de inventario
--
--  Sin esto el kardex y el estante se separan y nadie lo nota. Se vende algo
--  sin marcarlo, se cae una botella, se la lleva alguien, y el sistema sigue
--  diciendo que hay 12 cuando hay 9. A los dos meses el inventario del sistema
--  es ficcion y las sugerencias de compra que salgan de ahi tambien.
--
--  COMO FUNCIONA, Y POR QUE ASI
--
--  Un conteo se abre, se cuenta producto por producto, y al final se aplica.
--  Las tres decisiones que importan:
--
--  1) EL AJUSTE ES UNA DIFERENCIA, NO UN "DEJALO EN ESTE NUMERO".
--
--     Cuando se cuenta un producto se guarda cuanto decia el sistema EN ESE
--     MOMENTO, y el ajuste que se aplica al final es (contado - sistema de ese
--     momento). Si se contara a las 9 de la mañana y se aplicara a las 3 de la
--     tarde, un "dejalo en 10" borraria todo lo vendido en el dia. Con la
--     diferencia, lo vendido entre contar y aplicar se respeta.
--
--  2) LO QUE NO SE CONTO NO SE TOCA.
--
--     En un conteo general siempre quedan productos sin contar. Tratarlos como
--     cero vaciaria el inventario de medio negocio. Solo se ajustan las lineas
--     que alguien conto de verdad.
--
--  3) SE CUENTA POR PRODUCTO Y LOTE.
--
--     Los perecederos llevan lote y vencimiento, y es justo lo que mas hay que
--     contar. Si se contara solo por producto, el ajuste caeria en un monton
--     sin lote y el FEFO -lo que vence primero sale primero- dejaria de saber
--     que tiene.
--
--  QUIEN HACE QUE
--
--     auxiliar     cuenta
--     supervisor   abre el conteo, ve las diferencias, lo cancela
--     gerente      lo aplica
--
--  El conteo es ciego para quien cuenta: la cantidad del sistema y la
--  diferencia solo salen de supervisor para arriba. Si la cajera ve que el
--  sistema dice 12, escribe 12. Contar sirve cuando no se sabe la respuesta.
--  Y aplicar un ajuste a la baja es la forma mas comoda de tapar un faltante,
--  por eso lo aplica el dueño y no quien conto.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Las tablas
-- ---------------------------------------------------------------------------

create table if not exists conteos (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  sucursal_id      uuid not null references sucursales(id),
  numero           text not null,
  alcance          text not null default 'general'
                   check (alcance in ('general','categoria','proveedor')),
  categoria_id     uuid references categorias(id),
  proveedor_id     uuid references proveedores(id),
  estado           text not null default 'abierto'
                   check (estado in ('abierto','aplicado','cancelado')),
  notas            text,
  motivo_cancelacion text,
  abierto_por      uuid references perfiles(id),
  abierto_en       timestamptz not null default now(),
  cerrado_por      uuid references perfiles(id),
  cerrado_en       timestamptz,
  diferencia_valor numeric(16,4),
  unique (organizacion_id, numero)
);

create table if not exists conteo_detalle (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  conteo_id        uuid not null references conteos(id) on delete cascade,
  producto_id      uuid not null references productos(id),
  lote_id          uuid references lotes(id),
  -- Lo que decia el sistema cuando se conto esta linea. Null mientras nadie
  -- la haya contado.
  cantidad_sistema numeric(16,3),
  cantidad_contada numeric(16,3),
  contado_por      uuid references perfiles(id),
  contado_en       timestamptz,
  nota             text
);

-- nulls not distinct: sin esto, un producto sin lote podria entrar dos veces
-- en el mismo conteo, porque Postgres considera distintos a dos nulos.
create unique index if not exists ux_conteo_detalle
  on conteo_detalle (conteo_id, producto_id, lote_id) nulls not distinct;

create index if not exists ix_conteo_detalle_conteo on conteo_detalle (conteo_id);
create index if not exists ix_conteos_sucursal on conteos (sucursal_id, estado);

alter table conteos         enable row level security;
alter table conteo_detalle  enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where tablename='conteos' and policyname='conteos_sel') then
    create policy conteos_sel on conteos for select
      using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))
             or app.es_admin());
  end if;
  if not exists (select 1 from pg_policies where tablename='conteo_detalle' and policyname='conteo_det_sel') then
    create policy conteo_det_sel on conteo_detalle for select
      using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))
             or app.es_admin());
  end if;
end $$;

-- Solo se escriben por funcion: un conteo que se pueda editar a mano no sirve
-- como control de nada.
revoke insert, update, delete on conteos        from authenticated;
revoke insert, update, delete on conteo_detalle from authenticated;
grant select on conteos        to authenticated;
grant select on conteo_detalle to authenticated;


-- ---------------------------------------------------------------------------
-- 2. Abrir un conteo
--
--    Se precargan las lineas de una vez: cada producto del alcance con cada
--    uno de sus lotes, mas los productos que el sistema cree en cero. Esos
--    ultimos importan: "el sistema dice 0 pero hay 3 en la bodega" es
--    exactamente el hallazgo que se busca.
-- ---------------------------------------------------------------------------

create or replace function fn_abrir_conteo(
  p_sucursal_id  uuid default null,
  p_alcance      text default 'general',
  p_categoria_id uuid default null,
  p_proveedor_id uuid default null,
  p_notas        text default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org   uuid;
  v_suc   uuid;
  v_id    uuid;
  v_num   text;
  v_n     int;
begin
  v_org := app.org_id();
  if v_org is null or not app.tiene_nivel('supervisor') then
    raise exception 'Solo un supervisor puede abrir un conteo';
  end if;

  v_suc := coalesce(p_sucursal_id,
                    (select id from sucursales
                      where organizacion_id = v_org and activa
                      order by es_principal desc limit 1));

  perform 1 from sucursales
   where id = v_suc and organizacion_id = v_org and activa;
  if not found then raise exception 'Esa sucursal no es de su negocio'; end if;

  if p_alcance not in ('general','categoria','proveedor') then
    raise exception 'Alcance invalido';
  end if;
  if p_alcance = 'categoria' and p_categoria_id is null then
    raise exception 'Indique la categoria a contar';
  end if;
  if p_alcance = 'proveedor' and p_proveedor_id is null then
    raise exception 'Indique el proveedor a contar';
  end if;

  -- Un solo conteo abierto por sucursal. Con dos, dos personas ajustan lo
  -- mismo y el segundo ajuste pisa al primero.
  if exists (select 1 from conteos
              where sucursal_id = v_suc and estado = 'abierto') then
    raise exception 'Ya hay un conteo abierto en esta sucursal. Terminelo o cancelelo primero';
  end if;

  v_num := app.numero_documento(v_org, v_suc, 'conteo', 'C', 6);

  insert into conteos (organizacion_id, sucursal_id, numero, alcance,
                       categoria_id, proveedor_id, notas, abierto_por)
  values (v_org, v_suc, v_num, p_alcance,
          case when p_alcance = 'categoria' then p_categoria_id end,
          case when p_alcance = 'proveedor' then p_proveedor_id end,
          nullif(btrim(coalesce(p_notas,'')), ''), auth.uid())
  returning id into v_id;

  -- Una linea por producto y lote. Los productos sin existencia entran con
  -- una sola linea sin lote.
  with alcance as (
    select p.id
    from productos p
    where p.organizacion_id = v_org
      and p.activo and p.tipo <> 'servicio'
      and (p_alcance <> 'categoria' or p.categoria_id = p_categoria_id)
      and (p_alcance <> 'proveedor' or p.proveedor_id = p_proveedor_id)
  ),
  con_lote as (
    select e.producto_id, e.lote_id
    from existencias e
    join alcance a on a.id = e.producto_id
    where e.sucursal_id = v_suc
      and (e.cantidad <> 0 or e.lote_id is null)
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
    raise exception 'No hay productos que contar con ese alcance';
  end if;

  return jsonb_build_object(
    'conteo_id', v_id, 'numero', v_num, 'lineas', v_n,
    'sucursal', (select nombre from sucursales where id = v_suc));
end $fn$;

revoke execute on function fn_abrir_conteo(uuid, text, uuid, uuid, text) from public, anon;
grant execute on function fn_abrir_conteo(uuid, text, uuid, uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 3. Contar una linea
--
--    Aqui se congela la cantidad del sistema. Es el dato que despues decide
--    la diferencia, y tiene que ser la de este instante, no la de cuando se
--    abrio el conteo ni la de cuando se aplique.
-- ---------------------------------------------------------------------------

create or replace function fn_contar(
  p_conteo_id  uuid,
  p_producto_id uuid,
  p_cantidad   numeric,
  p_lote_id    uuid default null,
  p_nota       text default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  c       record;
  v_sis   numeric;
  v_det   uuid;
begin
  if p_cantidad is null or p_cantidad < 0 then
    raise exception 'La cantidad contada no puede ser negativa';
  end if;

  select * into c from conteos where id = p_conteo_id;
  if c.id is null then raise exception 'Conteo inexistente'; end if;
  if c.estado <> 'abierto' then
    raise exception 'Ese conteo ya se cerro';
  end if;
  if not (app.es_admin()
          or (c.organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para contar en este negocio';
  end if;

  select coalesce(sum(e.cantidad), 0) into v_sis
  from existencias e
  where e.producto_id = p_producto_id
    and e.sucursal_id = c.sucursal_id
    and e.lote_id is not distinct from p_lote_id;

  update conteo_detalle
     set cantidad_contada = p_cantidad,
         cantidad_sistema = v_sis,
         contado_por = auth.uid(),
         contado_en  = now(),
         nota = nullif(btrim(coalesce(p_nota,'')), '')
   where conteo_id = p_conteo_id
     and producto_id = p_producto_id
     and lote_id is not distinct from p_lote_id
  returning id into v_det;

  -- Un producto que no estaba en el alcance pero que aparecio en la bodega
  -- se agrega: encontrarlo es justamente para lo que sirve contar.
  if v_det is null then
    perform 1 from productos
     where id = p_producto_id and organizacion_id = c.organizacion_id
       and activo and tipo <> 'servicio';
    if not found then raise exception 'Ese producto no es de este negocio'; end if;

    insert into conteo_detalle (organizacion_id, conteo_id, producto_id, lote_id,
                                cantidad_sistema, cantidad_contada,
                                contado_por, contado_en, nota)
    values (c.organizacion_id, p_conteo_id, p_producto_id, p_lote_id,
            v_sis, p_cantidad, auth.uid(), now(),
            nullif(btrim(coalesce(p_nota,'')), ''))
    returning id into v_det;
  end if;

  return jsonb_build_object(
    'linea_id', v_det,
    'contado',  p_cantidad,
    -- La diferencia solo se devuelve a quien puede verla.
    'sistema',    case when app.tiene_nivel('supervisor') then v_sis end,
    'diferencia', case when app.tiene_nivel('supervisor') then p_cantidad - v_sis end);
end $fn$;

revoke execute on function fn_contar(uuid, uuid, numeric, uuid, text) from public, anon;
grant execute on function fn_contar(uuid, uuid, numeric, uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. Las lineas del conteo
-- ---------------------------------------------------------------------------

create or replace function fn_conteo_lineas(
  p_conteo_id      uuid,
  p_buscar         text default null,
  p_solo_pendientes boolean default false,
  p_solo_diferencias boolean default false,
  p_limite         int default 500
)
returns table (
  linea_id    uuid,
  producto_id uuid,
  producto    text,
  sku         text,
  categoria   text,
  lote_id     uuid,
  lote        text,
  vence       date,
  unidad      text,
  contada     numeric,
  sistema     numeric,
  diferencia  numeric,
  valor_dif   numeric,
  contado_por text,
  contado_en  timestamptz,
  nota        text
)
language sql stable security definer set search_path = public, app as $fn$
  with c as (
    select * from conteos
    where id = p_conteo_id
      and (organizacion_id = app.org_id() or app.es_admin())
  ),
  ve as (select app.tiene_nivel('supervisor') as costos)
  select
    d.id, d.producto_id, pr.nombre, pr.sku,
    coalesce(cat.nombre, 'Sin categoria'),
    d.lote_id, lo.codigo, lo.fecha_vencimiento, pr.unidad_base,
    d.cantidad_contada,
    case when ve.costos then d.cantidad_sistema end,
    case when ve.costos and d.cantidad_contada is not null
         then d.cantidad_contada - d.cantidad_sistema end,
    case when ve.costos and d.cantidad_contada is not null
         then round((d.cantidad_contada - d.cantidad_sistema)
                    * coalesce(pc.costo_promedio, 0), 2) end,
    pe.nombre, d.contado_en, d.nota
  from conteo_detalle d
  join c on c.id = d.conteo_id
  cross join ve
  join productos pr      on pr.id = d.producto_id
  left join categorias cat on cat.id = pr.categoria_id
  left join lotes lo     on lo.id = d.lote_id
  left join perfiles pe  on pe.id = d.contado_por
  left join producto_costos pc on pc.producto_id = d.producto_id
                              and pc.sucursal_id = c.sucursal_id
  where app.tiene_nivel('auxiliar')
    and (not p_solo_pendientes or d.cantidad_contada is null)
    and (not p_solo_diferencias
         or (d.cantidad_contada is not null
             and d.cantidad_contada <> d.cantidad_sistema))
    and (p_buscar is null or btrim(p_buscar) = ''
         or pr.nombre ilike '%' || btrim(p_buscar) || '%'
         or pr.sku    ilike '%' || btrim(p_buscar) || '%'
         or exists (select 1 from producto_codigos pc2
                     where pc2.producto_id = pr.id
                       and pc2.codigo = btrim(p_buscar)))
  order by cat.nombre nulls last, pr.nombre, lo.fecha_vencimiento nulls first
  limit greatest(coalesce(p_limite, 500), 1)
$fn$;

revoke execute on function fn_conteo_lineas(uuid, text, boolean, boolean, int)
  from public, anon;
grant execute on function fn_conteo_lineas(uuid, text, boolean, boolean, int)
  to authenticated;


-- ---------------------------------------------------------------------------
-- 5. Como va el conteo
-- ---------------------------------------------------------------------------

create or replace function fn_conteo_resumen(p_conteo_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  c    record;
  v_ve boolean;
  r    jsonb;
begin
  select * into c from conteos where id = p_conteo_id;
  if c.id is null then raise exception 'Conteo inexistente'; end if;
  if not (app.es_admin()
          or (c.organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))) then
    raise exception 'Ese conteo no es de este negocio';
  end if;

  v_ve := app.tiene_nivel('supervisor') or app.es_admin();

  select jsonb_build_object(
    'conteo_id', c.id, 'numero', c.numero, 'estado', c.estado,
    'alcance', c.alcance, 'notas', c.notas,
    'sucursal', (select nombre from sucursales where id = c.sucursal_id),
    'categoria', (select nombre from categorias where id = c.categoria_id),
    'proveedor', (select nombre from proveedores where id = c.proveedor_id),
    'abierto_por', (select nombre from perfiles where id = c.abierto_por),
    'abierto_en', c.abierto_en,
    'cerrado_por', (select nombre from perfiles where id = c.cerrado_por),
    'cerrado_en', c.cerrado_en,
    'motivo_cancelacion', c.motivo_cancelacion,
    'lineas',     (select count(*) from conteo_detalle d where d.conteo_id = c.id),
    'contadas',   (select count(*) from conteo_detalle d
                    where d.conteo_id = c.id and d.cantidad_contada is not null),
    'pendientes', (select count(*) from conteo_detalle d
                    where d.conteo_id = c.id and d.cantidad_contada is null),
    'con_diferencia', case when v_ve then (
       select count(*) from conteo_detalle d
        where d.conteo_id = c.id and d.cantidad_contada is not null
          and d.cantidad_contada <> d.cantidad_sistema) end,
    'sobrantes', case when v_ve then (
       select count(*) from conteo_detalle d
        where d.conteo_id = c.id and d.cantidad_contada > d.cantidad_sistema) end,
    'faltantes', case when v_ve then (
       select count(*) from conteo_detalle d
        where d.conteo_id = c.id and d.cantidad_contada < d.cantidad_sistema) end,
    -- Lo que la diferencia vale en plata, al costo promedio.
    'valor_diferencia', case when v_ve then coalesce((
       select round(sum((d.cantidad_contada - d.cantidad_sistema)
                        * coalesce(pc.costo_promedio, 0)), 2)
       from conteo_detalle d
       left join producto_costos pc on pc.producto_id = d.producto_id
                                   and pc.sucursal_id = c.sucursal_id
       where d.conteo_id = c.id and d.cantidad_contada is not null), 0) end,
    'valor_aplicado', case when v_ve then c.diferencia_valor end
  ) into r;

  return r;
end $fn$;

revoke execute on function fn_conteo_resumen(uuid) from public, anon;
grant execute on function fn_conteo_resumen(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 6. Aplicar el conteo
--
--    Aqui se mueve el inventario de verdad. Lo aplica el gerente, no quien
--    conto: un ajuste a la baja es la forma mas comoda de tapar un faltante.
-- ---------------------------------------------------------------------------

create or replace function fn_aplicar_conteo(p_conteo_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  c        record;
  l        record;
  v_dif    numeric;
  v_costo  numeric;
  v_mas    int := 0;
  v_menos  int := 0;
  v_igual  int := 0;
  v_valor  numeric := 0;
begin
  select * into c from conteos where id = p_conteo_id for update;
  if c.id is null then raise exception 'Conteo inexistente'; end if;
  if c.estado <> 'abierto' then raise exception 'Ese conteo ya se cerro'; end if;

  if not (app.es_admin()
          or (c.organizacion_id = app.org_id() and app.tiene_nivel('gerente'))) then
    -- "de este negocio": el gerente de otra pulperia tambien es gerente, y el
    -- mensaje sin esa parte lo deja pensando que le falta rango.
    raise exception 'Solo el gerente de este negocio puede aplicar un conteo';
  end if;

  if not exists (select 1 from conteo_detalle
                  where conteo_id = p_conteo_id and cantidad_contada is not null) then
    raise exception 'Todavia no se ha contado nada';
  end if;

  -- Solo las lineas contadas. Lo que nadie conto se queda como esta.
  for l in
    select d.*, pr.nombre as producto
    from conteo_detalle d
    join productos pr on pr.id = d.producto_id
    where d.conteo_id = p_conteo_id and d.cantidad_contada is not null
    order by pr.nombre
  loop
    v_dif := l.cantidad_contada - coalesce(l.cantidad_sistema, 0);

    if v_dif = 0 then
      v_igual := v_igual + 1;
      continue;
    end if;

    select coalesce(costo_promedio, 0) into v_costo
    from producto_costos
    where producto_id = l.producto_id and sucursal_id = c.sucursal_id;

    if v_dif > 0 then
      -- Sobrante: entra al costo promedio vigente. No se compro nada, se
      -- reconoce lo que ya estaba.
      perform fn_kardex_registrar(c.sucursal_id, l.producto_id, 'ajuste_positivo',
                                  v_dif, coalesce(v_costo, 0), l.lote_id,
                                  'conteo', c.id,
                                  'Conteo ' || c.numero, auth.uid());
      v_mas := v_mas + 1;
    else
      -- Si entre contar y aplicar se vendio casi todo, el kardex rechaza la
      -- salida por falta de existencia y el gerente se queda con un "stock
      -- insuficiente" que no le dice que hacer. Se traduce a algo accionable:
      -- ese producto hay que volverlo a contar.
      begin
        perform fn_kardex_registrar(c.sucursal_id, l.producto_id, 'ajuste_negativo',
                                    abs(v_dif), null, l.lote_id,
                                    'conteo', c.id,
                                    'Conteo ' || c.numero, auth.uid());
      exception when others then
        if sqlerrm like '%insuficiente%' then
          raise exception 'Ya no hay suficiente % para aplicar el ajuste: se vendio despues de contarlo. Vuelva a contar ese producto y aplique de nuevo', l.producto;
        else
          raise;
        end if;
      end;
      v_menos := v_menos + 1;
    end if;

    v_valor := v_valor + (v_dif * coalesce(v_costo, 0));
  end loop;

  update conteos
     set estado = 'aplicado', cerrado_por = auth.uid(), cerrado_en = now(),
         diferencia_valor = round(v_valor, 4)
   where id = p_conteo_id;

  return jsonb_build_object(
    'numero', c.numero,
    'sobrantes', v_mas, 'faltantes', v_menos, 'sin_cambio', v_igual,
    'sin_contar', (select count(*) from conteo_detalle
                    where conteo_id = p_conteo_id and cantidad_contada is null),
    'valor_diferencia', round(v_valor, 2));
end $fn$;

revoke execute on function fn_aplicar_conteo(uuid) from public, anon;
grant execute on function fn_aplicar_conteo(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 7. Cancelar
-- ---------------------------------------------------------------------------

create or replace function fn_cancelar_conteo(p_conteo_id uuid, p_motivo text)
returns void
language plpgsql security definer set search_path = public, app as $fn$
declare c record;
begin
  if p_motivo is null or btrim(p_motivo) = '' then
    raise exception 'Cancelar un conteo exige un motivo';
  end if;

  select * into c from conteos where id = p_conteo_id for update;
  if c.id is null then raise exception 'Conteo inexistente'; end if;
  if c.estado <> 'abierto' then raise exception 'Ese conteo ya se cerro'; end if;

  if not (app.es_admin()
          or (c.organizacion_id = app.org_id() and app.tiene_nivel('supervisor'))) then
    raise exception 'Solo un supervisor de este negocio puede cancelar un conteo';
  end if;

  update conteos
     set estado = 'cancelado', cerrado_por = auth.uid(), cerrado_en = now(),
         motivo_cancelacion = btrim(p_motivo)
   where id = p_conteo_id;
end $fn$;

revoke execute on function fn_cancelar_conteo(uuid, text) from public, anon;
grant execute on function fn_cancelar_conteo(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 8. La lista de conteos
-- ---------------------------------------------------------------------------

create or replace function fn_conteos(p_limite int default 30)
returns table (
  conteo_id   uuid,
  numero      text,
  estado      text,
  alcance     text,
  detalle     text,
  sucursal    text,
  abierto_por text,
  abierto_en  timestamptz,
  cerrado_en  timestamptz,
  lineas      int,
  contadas    int,
  valor       numeric
)
language sql stable security definer set search_path = public, app as $fn$
  select
    c.id, c.numero, c.estado, c.alcance,
    coalesce(cat.nombre, pv.nombre, 'Todo el inventario'),
    s.nombre, pe.nombre, c.abierto_en, c.cerrado_en,
    (select count(*)::int from conteo_detalle d where d.conteo_id = c.id),
    (select count(*)::int from conteo_detalle d
      where d.conteo_id = c.id and d.cantidad_contada is not null),
    case when app.tiene_nivel('supervisor') then c.diferencia_valor end
  from conteos c
  join sucursales s        on s.id = c.sucursal_id
  left join categorias cat on cat.id = c.categoria_id
  left join proveedores pv on pv.id = c.proveedor_id
  left join perfiles pe    on pe.id = c.abierto_por
  where app.tiene_nivel('auxiliar')
    and c.organizacion_id = app.org_id()
    and c.sucursal_id in (select app.sucursales_permitidas())
  order by c.abierto_en desc
  limit greatest(coalesce(p_limite, 30), 1)
$fn$;

revoke execute on function fn_conteos(int) from public, anon;
grant execute on function fn_conteos(int) to authenticated;
