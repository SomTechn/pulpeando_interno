-- ============================================================================
--  016 · El personal tambien puede pedir como cliente
--
--  QUE PASO
--
--  El dueño entro a la app del cliente con su propia cuenta -la de gerente- e
--  hizo un pedido. El pedido llego al tablero del negocio, pero nunca aparecio
--  en "sus pedidos" dentro de la app.
--
--  La causa: fn_crear_pedido decidia el camino mirando si quien pide tiene
--  perfil en algun negocio. Como el dueño lo tiene, tomo el camino del
--  mostrador, y en ese camino el cliente es el que venga en p_cliente_id. La
--  app del cliente no manda ese dato -no tiene por que saberlo- asi que el
--  pedido quedo con cliente_id nulo. Y fn_mis_pedidos busca por cliente:
--
--      where p.cliente_id in (select id from clientes where usuario_id = auth.uid())
--
--  Un pedido sin cliente no le pertenece a nadie. Invisible para quien lo hizo
--  y sin forma de cancelarlo desde la app.
--
--  No es un caso raro de prueba: le pasa a cualquiera que trabaje en una
--  pulperia y quiera pedirle a otra. En un pueblo donde todos se conocen, eso
--  es lo normal.
--
--  COMO SE ARREGLA
--
--  Que el ORIGEN declare la intencion, en vez de adivinarla por quien es la
--  persona. p_origen = 'app_cliente' significa "vengo como cliente" y se usa
--  el camino del cliente aunque la persona sea personal de un negocio: se le
--  busca o se le crea su ficha en la tienda elegida, paga el envio de esa
--  tienda y respeta su minimo, igual que cualquiera.
--
--  Se aprovecha para cambiar el valor por omision de p_origen de 'app_cliente'
--  a 'mostrador'. Asi el descuido apunta al lado seguro: una pantalla del
--  panel que olvide indicar el origen cae en el camino del mostrador, que es
--  lo que esa pantalla queria. Y un cliente comun que no mande nada igual cae
--  al camino del cliente, porque el del mostrador exige nivel de auxiliar.
--
--  No se agrega un parametro nuevo a proposito: eso dejaria la version vieja
--  de la funcion conviviendo con la nueva, y la vieja conserva el defecto.
--
--  El pedido que quedo huerfano se queda como esta: es un pedido real que la
--  tienda atendio. Se cancela desde el tablero si hace falta.
-- ============================================================================


create or replace function fn_crear_pedido(
  p_items            jsonb,
  p_sucursal_id      uuid default null,
  p_cliente_id       uuid default null,
  -- Por omision 'mostrador': el descuido apunta al lado seguro. La app del
  -- cliente manda 'app_cliente' a proposito.
  p_origen           origen_pedido default 'mostrador',
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

  -- El origen declara la intencion. Sin esto, cualquiera con perfil en un
  -- negocio que usara la app del cliente generaba un pedido sin cliente,
  -- invisible para el mismo.
  v_es_staff := coalesce(p_origen, 'mostrador') <> 'app_cliente'
                and app.org_id() is not null and app.tiene_nivel('auxiliar');

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
