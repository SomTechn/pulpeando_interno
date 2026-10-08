-- ============================================================================
--  014 · El camino del cliente: descubrir una pulperia y pedirle a domicilio
--
--  Esta migracion arregla el flujo que es la razon de ser de Pulpeando. La base
--  de pedidos estaba completa pero asumia que el cliente YA pertenecia a un
--  negocio, y el costo del envio lo decidia quien llamaba a la funcion. Cinco
--  problemas, encontrados al ir a construir la app del cliente:
--
--  1) UN USUARIO NUEVO NO VEIA NINGUNA TIENDA. fn_tiendas_cliente solo lista
--     negocios donde ya existe su ficha de cliente, y fn_catalogo_cliente solo
--     muestra catalogo de esos mismos. Alguien que se acaba de bajar la app
--     veia la pantalla vacia y no tenia por donde hacer su primer pedido.
--
--  2) EL CLIENTE DE DOS PULPERIAS PEDIA A LA EQUIVOCADA. fn_crear_pedido
--     resolvia el negocio con "select ... from clientes where usuario_id =
--     auth.uid() limit 1", sin mirar la sucursal elegida. Quien fuera cliente
--     de dos tiendas mandaba su pedido a cualquiera de las dos. Justo el caso
--     normal, porque la idea es elegir entre varias.
--
--  3) EL COSTO DEL ENVIO LO PONIA EL CLIENTE. p_costo_envio entraba al total
--     tal como llegaba. Desde la consola del navegador: mandar 0 y el envio
--     sale gratis; mandar un negativo y el total baja por debajo del valor de
--     la mercaderia, o sea la pulperia entrega el mandado y queda debiendo.
--
--  4) LA SUCURSAL Y EL CLIENTE NO SE VERIFICABAN. p_sucursal_id se usaba sin
--     comprobar que fuera del negocio resuelto, y en el camino del personal
--     p_cliente_id se aceptaba sin comprobar que el cliente fuera de su
--     negocio. El mismo hueco que ya se cerro en las ventas.
--
--  5) NO HABIA DONDE CONFIGURAR EL ENVIO. Ninguna columna guardaba cuanto
--     cobra cada pulperia por llevarlo ni desde cuanto lo lleva.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Cada sucursal decide si lleva a domicilio, cuanto cobra y desde cuanto
-- ---------------------------------------------------------------------------

alter table sucursales add column if not exists acepta_domicilio boolean not null default true;
alter table sucursales add column if not exists costo_envio   numeric(12,4) not null default 0;
alter table sucursales add column if not exists pedido_minimo numeric(12,4) not null default 0;

do $$ begin
  if not exists (select 1 from pg_constraint
                  where conname = 'sucursales_envio_no_negativo'
                    and conrelid = 'sucursales'::regclass) then
    alter table sucursales add constraint sucursales_envio_no_negativo
      check (costo_envio >= 0 and pedido_minimo >= 0);
  end if;
end $$;

-- El personal edita esto desde Catalogos; el cliente solo lo lee por funcion.
revoke update on sucursales from authenticated;
grant update (codigo, nombre, direccion, telefono, es_principal, activa,
              acepta_domicilio, costo_envio, pedido_minimo, actualizado_en)
  on sucursales to authenticated;


-- ---------------------------------------------------------------------------
-- 1b. El numero de documento lleva el codigo de la sucursal
--
--     Hallado al probar esto con dos sucursales: el correlativo es por
--     (negocio, sucursal) pero el indice unico de pedidos es por (negocio,
--     numero). O sea que la segunda sucursal volvia a generar P-000001 y el
--     insert reventaba con llave duplicada: esa sucursal no podia tomar un
--     solo pedido hasta que los contadores se separaran por si solos.
--
--     Se mete el codigo de la sucursal en el numero: P-002-000001. Queda
--     unico por negocio -el codigo es obligatorio y unico por negocio-, cada
--     sucursal conserva su propia corrida de numeros, y el numero dice de que
--     sucursal salio. Nada lee el formato del numero, solo se muestra.
--
--     La misma colision existe en ventas; se arregla en la 015.
-- ---------------------------------------------------------------------------

create or replace function app.numero_documento(
  p_org      uuid,
  p_sucursal uuid,
  p_tipo     text,
  p_prefijo  text,
  p_ancho    int
) returns text
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_cod text;
  v_n   bigint;
begin
  select nullif(btrim(coalesce(codigo, '')), '') into v_cod
  from sucursales where id = p_sucursal;

  -- El codigo es obligatorio, pero podria quedar en blanco. Antes que generar
  -- un numero repetido -que impide vender- se usa un trozo del id.
  v_cod := coalesce(v_cod, left(replace(p_sucursal::text, '-', ''), 4));

  v_n := fn_siguiente_numero(p_org, p_sucursal, p_tipo);
  return p_prefijo || '-' || v_cod || '-' || lpad(v_n::text, p_ancho, '0');
end $fn$;

-- Solo la usan otras funciones, que corren como dueñas. Nadie la llama suelta.
revoke execute on function app.numero_documento(uuid, uuid, text, text, int)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- 2. Descubrir tiendas sin ser cliente de ninguna
--
--    Cualquiera con sesion puede ver que pulperias hay y cuanto cobran de
--    envio. Es un mercado: la lista de negocios es justamente lo que se
--    ofrece. Lo que NO sale de aqui es nada interno del negocio: ni
--    existencias, ni costos, ni cuanto vende.
-- ---------------------------------------------------------------------------

create or replace function fn_tiendas_disponibles(p_busqueda text default null)
returns table (
  organizacion_id  uuid,
  negocio          text,
  sucursal_id      uuid,
  sucursal         text,
  direccion        text,
  telefono         text,
  moneda           text,
  acepta_domicilio boolean,
  costo_envio      numeric,
  pedido_minimo    numeric,
  productos        integer,
  ya_soy_cliente   boolean
)
language sql stable security definer set search_path = public, app as $fn$
  select
    o.id, o.nombre, s.id, s.nombre, s.direccion, s.telefono, o.moneda,
    s.acepta_domicilio, s.costo_envio, s.pedido_minimo,
    (select count(*)::int from productos p
      where p.organizacion_id = o.id and p.activo and p.se_vende
        and p.tipo <> 'servicio'),
    exists (select 1 from clientes c
             where c.organizacion_id = o.id and c.usuario_id = auth.uid() and c.activo)
  from organizaciones o
  join sucursales s on s.organizacion_id = o.id and s.activa
  where o.activa
    and auth.uid() is not null
    and (p_busqueda is null or btrim(p_busqueda) = ''
         or o.nombre ilike '%' || btrim(p_busqueda) || '%'
         or s.nombre ilike '%' || btrim(p_busqueda) || '%'
         or coalesce(s.direccion, '') ilike '%' || btrim(p_busqueda) || '%')
  order by o.nombre, s.es_principal desc, s.nombre
$fn$;

revoke execute on function fn_tiendas_disponibles(text) from public, anon;
grant execute on function fn_tiendas_disponibles(text) to authenticated;


-- ---------------------------------------------------------------------------
-- 3. El catalogo de una tienda, sin exigir ser cliente de ella
--
--    Se mantiene la firma y el tipo de retorno de antes para no romper nada.
--    Lo que cambia es la puerta: ya no se pide ficha de cliente previa. Lo que
--    NO cambia es que 'disponible' sigue siendo un si/no: el cliente nunca ve
--    cuantas unidades hay ni a que costo las compro la tienda.
-- ---------------------------------------------------------------------------

create or replace function fn_catalogo_cliente(
  p_sucursal_id uuid default null,
  p_busqueda    text default null
)
returns table (
  producto_id uuid,
  nombre      text,
  imagen_url  text,
  categoria_id uuid,
  categoria   text,
  precio      numeric,
  unidad      text,
  disponible  boolean,
  sucursal_id uuid
)
language sql stable security definer set search_path = public, app as $fn$
  with suc as (
    select s.id, s.organizacion_id
    from sucursales s
    join organizaciones o on o.id = s.organizacion_id and o.activa
    where s.activa
      and auth.uid() is not null
      and (
        -- una tienda concreta, sea cliente de ella o no
        (p_sucursal_id is not null and s.id = p_sucursal_id)
        -- sin tienda indicada: las tiendas donde ya es cliente, como antes
        or (p_sucursal_id is null and exists (
              select 1 from clientes c
               where c.organizacion_id = s.organizacion_id
                 and c.usuario_id = auth.uid() and c.activo))
      )
  )
  select
    p.id,
    p.nombre,
    p.imagen_url,
    p.categoria_id,
    coalesce(c.nombre, 'Sin categoria'),
    fn_precio_vigente(p.id, suc.id, 1),
    p.unidad_base,
    greatest(coalesce(ex.cantidad, 0) - coalesce(rv.cantidad, 0), 0) > 0,
    suc.id
  from suc
  join productos p on p.organizacion_id = suc.organizacion_id
                   and p.activo and p.se_vende and p.tipo <> 'servicio'
  left join categorias c on c.id = p.categoria_id
  left join (
    select producto_id, sucursal_id, sum(cantidad) as cantidad
    from existencias group by producto_id, sucursal_id
  ) ex on ex.producto_id = p.id and ex.sucursal_id = suc.id
  left join (
    select producto_id, sucursal_id, sum(cantidad) as cantidad
    from pedido_reservas where liberada_en is null
    group by producto_id, sucursal_id
  ) rv on rv.producto_id = p.id and rv.sucursal_id = suc.id
  where fn_precio_vigente(p.id, suc.id, 1) is not null
    and (p_busqueda is null or btrim(p_busqueda) = ''
         or p.nombre ilike '%' || btrim(p_busqueda) || '%')
  order by c.nombre nulls last, p.nombre
$fn$;

revoke execute on function fn_catalogo_cliente(uuid, text) from public, anon;
grant execute on function fn_catalogo_cliente(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. Crear el pedido
--
--    Reescrita. Los cambios de fondo:
--
--    · El negocio sale de la SUCURSAL ELEGIDA, no de una ficha de cliente al
--      azar. Asi el cliente de dos pulperias le pide a la que escogio.
--    · Si es su primer pedido en esa tienda, se le crea la ficha de cliente
--      ahi mismo, con limite de fiado en 0: pedir a domicilio no es fiar.
--    · El costo del envio sale de la sucursal. Para el personal se respeta lo
--      que indique -una cajera puede perdonar el envio- pero nunca negativo.
--    · Se respeta el pedido minimo de la tienda.
-- ---------------------------------------------------------------------------

create or replace function fn_crear_pedido(
  p_items            jsonb,
  p_sucursal_id      uuid default null,
  p_cliente_id       uuid default null,
  p_origen           origen_pedido default 'app_cliente',
  p_tipo_entrega     tipo_entrega default 'domicilio',
  p_direccion_id     uuid default null,
  p_direccion_texto  text default null,
  p_nombre_contacto  text default null,
  p_telefono_contacto text default null,
  p_metodo_pago      metodo_pago default 'efectivo',
  p_paga_con         numeric default null,
  -- Ojo con este default: tiene que ser null, no 0. Con 0 "no indique nada"
  -- significaba "envio gratis", y una cajera que tomara un pedido por
  -- telefono sin tocar el campo regalaba el envio. Con null, no indicar nada
  -- significa "lo que cobra la sucursal", y un 0 explicito es perdonarlo.
  p_costo_envio      numeric default null,
  p_notas            text default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_es_staff   boolean;
  v_org        uuid;
  v_suc        record;
  v_cliente    uuid;
  v_origen     origen_pedido;
  v_creado_por uuid;
  v_pedido     uuid;
  v_numero     text;
  v_envio      numeric := 0;
  it           jsonb;
  v_prod       record;
  v_cant       numeric;
  v_precio     numeric;
  v_linea      numeric;
  v_sub        numeric := 0;
  v_imp        numeric := 0;
  v_total      numeric := 0;
  v_dir        text;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'El pedido no tiene productos';
  end if;
  if auth.uid() is null then
    raise exception 'Inicie sesion para hacer un pedido';
  end if;

  v_es_staff := app.org_id() is not null and app.tiene_nivel('auxiliar');

  if v_es_staff then
    v_org := app.org_id();

    -- La sucursal tiene que ser de su negocio.
    select s.* into v_suc from sucursales s
     where s.id = coalesce(p_sucursal_id,
                           (select id from sucursales
                             where organizacion_id = v_org and activa
                             order by es_principal desc limit 1))
       and s.organizacion_id = v_org and s.activa;
    if v_suc.id is null then
      raise exception 'Esa sucursal no es de su negocio';
    end if;

    -- Y el cliente tambien, si viene uno.
    if p_cliente_id is not null then
      select c.id into v_cliente from clientes c
       where c.id = p_cliente_id and c.organizacion_id = v_org and c.activo;
      if v_cliente is null then
        raise exception 'Ese cliente no es de su negocio';
      end if;
    end if;

    v_origen     := coalesce(p_origen, 'mostrador');
    if v_origen = 'app_cliente' then v_origen := 'mostrador'; end if;
    v_creado_por := auth.uid();

    -- El personal si puede fijar el envio (perdonarlo, cobrar distinto), pero
    -- no ponerlo negativo -eso restaria del total- y si el cliente lo pasa a
    -- traer no se cobra envio aunque se indique: no hubo reparto.
    v_envio := case when p_tipo_entrega = 'domicilio'
                    then greatest(coalesce(p_costo_envio, v_suc.costo_envio), 0)
                    else 0 end;

  else
    -- ---- camino del cliente de la app ----
    if p_sucursal_id is null then
      raise exception 'Elija de que pulperia quiere pedir';
    end if;

    select s.* into v_suc from sucursales s
     join organizaciones o on o.id = s.organizacion_id and o.activa
     where s.id = p_sucursal_id and s.activa;
    if v_suc.id is null then
      raise exception 'Esa pulperia no esta disponible';
    end if;
    v_org := v_suc.organizacion_id;

    if p_tipo_entrega = 'domicilio' and not v_suc.acepta_domicilio then
      raise exception 'Esta pulperia no hace entregas a domicilio por ahora';
    end if;
    if p_tipo_entrega = 'domicilio'
       and p_direccion_id is null and btrim(coalesce(p_direccion_texto,'')) = '' then
      raise exception 'Indique la direccion de entrega';
    end if;

    -- Su ficha de cliente EN ESTA TIENDA. Si es su primer pedido aqui, se
    -- crea: sin esto el pedido no tiene a quien pertenecer y el cliente no
    -- podria verlo ni cancelarlo despues.
    select c.id into v_cliente from clientes c
     where c.organizacion_id = v_org and c.usuario_id = auth.uid() and c.activo
     limit 1;

    if v_cliente is null then
      insert into clientes (organizacion_id, usuario_id, nombre, telefono,
                            limite_credito, saldo, activo)
      values (v_org, auth.uid(),
              coalesce(nullif(btrim(coalesce(p_nombre_contacto,'')), ''), 'Cliente de la app'),
              nullif(btrim(coalesce(p_telefono_contacto,'')), ''),
              0, 0, true)
      returning id into v_cliente;
    end if;

    -- Una direccion guardada tiene que ser suya.
    if p_direccion_id is not null then
      perform 1 from direcciones_cliente d
       where d.id = p_direccion_id and d.cliente_id = v_cliente and d.activa;
      if not found then
        raise exception 'Esa direccion no es suya';
      end if;
    end if;

    v_origen     := 'app_cliente';
    v_creado_por := null;

    -- El cliente NO decide el envio. Lo pone la tienda.
    v_envio := case when p_tipo_entrega = 'domicilio' then v_suc.costo_envio else 0 end;
  end if;

  v_numero := app.numero_documento(v_org, v_suc.id, 'pedido', 'P', 6);

  v_dir := coalesce(nullif(btrim(coalesce(p_direccion_texto,'')), ''),
                    (select direccion from direcciones_cliente where id = p_direccion_id));

  insert into pedidos (
    organizacion_id, sucursal_id, numero, origen, tipo_entrega,
    cliente_id, nombre_contacto, telefono_contacto,
    direccion_id, direccion_texto, creado_por,
    metodo_pago, paga_con, costo_envio, notas
  ) values (
    v_org, v_suc.id, v_numero, v_origen, p_tipo_entrega,
    v_cliente, p_nombre_contacto, p_telefono_contacto,
    p_direccion_id, v_dir, v_creado_por,
    p_metodo_pago, p_paga_con, v_envio, p_notas
  ) returning id into v_pedido;

  for it in select * from jsonb_array_elements(p_items) loop
    select p.*, coalesce(i.tasa, 0) as tasa, coalesce(i.incluido_en_precio, true) as incluido
      into v_prod
    from productos p
    left join impuestos i on i.id = p.impuesto_id
    where p.id = (it->>'producto_id')::uuid
      and p.organizacion_id = v_org
      and p.activo and p.se_vende and p.tipo <> 'servicio';

    if v_prod.id is null then
      raise exception 'Producto no disponible';
    end if;

    v_cant := (it->>'cantidad')::numeric;
    if v_cant is null or v_cant <= 0 then
      raise exception 'Cantidad invalida en %', v_prod.nombre;
    end if;

    -- El precio lo pone la tienda, nunca el que pide.
    v_precio := coalesce(fn_precio_vigente(v_prod.id, v_suc.id, v_cant), 0);
    if v_precio = 0 then
      raise exception 'El producto % no tiene precio asignado', v_prod.nombre;
    end if;

    v_linea := v_precio * v_cant;

    insert into pedido_detalle (organizacion_id, pedido_id, producto_id, cantidad,
                                precio_unitario, tasa_impuesto, impuesto_incluido,
                                total, nota)
    values (v_org, v_pedido, v_prod.id, v_cant, v_precio, v_prod.tasa,
            v_prod.incluido, v_linea, it->>'nota');

    if v_prod.incluido then
      v_sub := v_sub + (v_linea / (1 + v_prod.tasa));
      v_imp := v_imp + (v_linea - v_linea / (1 + v_prod.tasa));
    else
      v_sub := v_sub + v_linea;
      v_imp := v_imp + (v_linea * v_prod.tasa);
    end if;
  end loop;

  -- El minimo se mide sobre la mercaderia, sin contar el envio: si no, el
  -- propio envio ayudaria a alcanzar el minimo.
  if not v_es_staff and v_suc.pedido_minimo > 0
     and round(v_sub + v_imp, 2) < round(v_suc.pedido_minimo, 2) then
    raise exception 'Esta pulperia lleva a domicilio desde %. Su pedido va en %',
      round(v_suc.pedido_minimo, 2), round(v_sub + v_imp, 2);
  end if;

  v_total := round(v_sub + v_imp + v_envio, 2);

  update pedidos
     set subtotal = round(v_sub, 2), impuesto = round(v_imp, 2), total = v_total
   where id = v_pedido;

  insert into pedido_eventos (organizacion_id, pedido_id, estado, usuario_id, nota)
  values (v_org, v_pedido, 'nuevo', v_creado_por, 'Pedido creado desde ' || v_origen);

  return jsonb_build_object(
    'pedido_id', v_pedido,
    'numero',    v_numero,
    'origen',    v_origen,
    'negocio',   (select nombre from organizaciones where id = v_org),
    'subtotal',  round(v_sub, 2),
    'impuesto',  round(v_imp, 2),
    'envio',     round(v_envio, 2),
    'total',     v_total
  );
end $fn$;

revoke execute on function fn_crear_pedido(jsonb, uuid, uuid, origen_pedido, tipo_entrega,
  uuid, text, text, text, metodo_pago, numeric, numeric, text) from public, anon;
grant execute on function fn_crear_pedido(jsonb, uuid, uuid, origen_pedido, tipo_entrega,
  uuid, text, text, text, metodo_pago, numeric, numeric, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. Mis tiendas: donde ya pedi antes. Sigue sirviendo para el inicio de la
--    app, ahora con el costo de envio para no tener que adivinarlo.
-- ---------------------------------------------------------------------------

create or replace function fn_tiendas_cliente()
returns table (
  organizacion_id uuid,
  negocio         text,
  sucursal_id     uuid,
  sucursal        text,
  direccion       text,
  telefono        text,
  moneda          text
)
language sql stable security definer set search_path = public, app as $fn$
  select o.id, o.nombre, s.id, s.nombre, s.direccion, s.telefono, o.moneda
  from clientes c
  join organizaciones o on o.id = c.organizacion_id and o.activa
  join sucursales s     on s.organizacion_id = o.id and s.activa
  where c.usuario_id = auth.uid() and c.activo
  order by o.nombre, s.es_principal desc, s.nombre
$fn$;

revoke execute on function fn_tiendas_cliente() from public, anon;
grant execute on function fn_tiendas_cliente() to authenticated;


-- ---------------------------------------------------------------------------
-- 6. Las direcciones del cliente: suyas y de nadie mas
--
--    La app necesita guardarlas y reusarlas. Sin politica propia un cliente
--    podria leer las direcciones de otro, que es saber donde vive.
-- ---------------------------------------------------------------------------

do $$ begin
  if not exists (select 1 from pg_policies
                  where tablename='direcciones_cliente' and policyname='dir_cliente_propio') then
    create policy dir_cliente_propio on direcciones_cliente for all
      using (cliente_id in (select id from clientes where usuario_id = auth.uid()))
      with check (cliente_id in (select id from clientes where usuario_id = auth.uid()));
  end if;
end $$;
