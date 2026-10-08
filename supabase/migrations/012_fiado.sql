-- ============================================================================
--  Migración 012 · Fiado (cuentas por cobrar de clientes)
--
--  El cuaderno de fiados es el dolor mas grande de una pulperia: plata que
--  se pierde, pleitos con el cliente, y nadie sabe cuanto le deben en total.
--
--  Tres cosas que esta migracion resuelve y que el sistema no tenia:
--
--  1) NADIE VERIFICABA EL LIMITE DE CREDITO. fn_registrar_venta aceptaba
--     'credito' y sumaba al saldo sin mirar limite_credito. Se podia fiar
--     sin tope.
--
--  2) NO HABIA DONDE REGISTRAR UN ABONO. El saldo solo subia.
--
--  3) UN ABONO EN EFECTIVO DESCUADRA LA CAJA. Si el cliente llega y paga
--     L100 de lo que debe, entran L100 a la gaveta que el arqueo no conoce.
--     Por eso el abono en efectivo se liga al turno y se suma al esperado.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Abonos
-- ---------------------------------------------------------------------------

create table if not exists abonos_cliente (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  sucursal_id      uuid references sucursales(id),
  cliente_id       uuid not null references clientes(id) on delete cascade,
  turno_id         uuid references turnos_caja(id),
  monto            numeric(16,4) not null check (monto > 0),
  metodo           metodo_pago not null default 'efectivo',
  referencia       text,
  notas            text,
  saldo_anterior   numeric(16,4) not null,
  saldo_nuevo      numeric(16,4) not null,
  registrado_por   uuid references perfiles(id),
  anulado          boolean not null default false,
  anulado_por      uuid references perfiles(id),
  anulado_en       timestamptz,
  creado_en        timestamptz not null default now()
);

create index if not exists ix_abonos_cliente on abonos_cliente (cliente_id, creado_en desc);
create index if not exists ix_abonos_turno   on abonos_cliente (turno_id) where not anulado;

alter table abonos_cliente enable row level security;

create policy abonos_sel on abonos_cliente for select
  using ((organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))
         or cliente_id in (select id from clientes where usuario_id = auth.uid())
         or app.es_admin());

-- Solo se escriben por funcion, para que el saldo nunca quede desalineado
revoke insert, update, delete on abonos_cliente from authenticated;
grant select on abonos_cliente to authenticated;


-- ---------------------------------------------------------------------------
-- 2. Registrar un abono
-- ---------------------------------------------------------------------------

create or replace function fn_registrar_abono(
  p_cliente_id uuid,
  p_monto      numeric,
  p_metodo     metodo_pago default 'efectivo',
  p_turno_id   uuid default null,
  p_referencia text default null,
  p_notas      text default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  c        record;
  v_sal    numeric;
  v_nuevo  numeric;
  v_suc    uuid;
  v_id     uuid;
begin
  if p_monto is null or p_monto <= 0 then
    raise exception 'El abono debe ser mayor a cero';
  end if;

  select * into c from clientes where id = p_cliente_id for update;
  if c.id is null then raise exception 'Cliente inexistente'; end if;

  -- Sin "auth.uid() is not null and". Si no hay identidad no hay permiso:
  -- un authenticated sin sub registraba abonos contra cualquier cliente.
  if not (current_user = 'service_role'
          or app.es_admin()
          or (c.organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))) then
    raise exception 'No tiene permiso para registrar abonos';
  end if;

  v_sal := coalesce(c.saldo, 0);
  if v_sal <= 0 then
    raise exception 'Este cliente no debe nada';
  end if;
  if round(p_monto, 2) > round(v_sal, 2) then
    raise exception 'El abono (%) es mayor que la deuda (%)', p_monto, v_sal;
  end if;

  -- Un abono en efectivo tiene que entrar al arqueo del turno
  if p_metodo = 'efectivo' and p_turno_id is null then
    raise exception 'Un abono en efectivo necesita un turno de caja abierto';
  end if;

  -- El turno TIENE que ser del mismo negocio que el cliente. Sin este filtro
  -- un abono de una pulperia entraba al arqueo de otra y le aparecia un
  -- faltante al cajero ajeno.
  if p_turno_id is not null then
    select sucursal_id into v_suc from turnos_caja
     where id = p_turno_id and estado = 'abierto'
       and organizacion_id = c.organizacion_id;
    if v_suc is null then
      raise exception 'El turno de caja no esta abierto o no es de este negocio';
    end if;
  end if;

  v_nuevo := round(v_sal - p_monto, 4);

  insert into abonos_cliente (organizacion_id, sucursal_id, cliente_id, turno_id,
                              monto, metodo, referencia, notas,
                              saldo_anterior, saldo_nuevo, registrado_por)
  values (c.organizacion_id, v_suc, p_cliente_id, p_turno_id,
          round(p_monto, 4), p_metodo, p_referencia, p_notas,
          v_sal, v_nuevo, auth.uid())
  returning id into v_id;

  update clientes set saldo = v_nuevo, actualizado_en = now()
   where id = p_cliente_id;

  return jsonb_build_object(
    'abono_id', v_id,
    'cliente', c.nombre,
    'abonado', round(p_monto, 2),
    'saldo_anterior', round(v_sal, 2),
    'saldo_nuevo', round(v_nuevo, 2),
    'queda_libre', v_nuevo <= 0
  );
end $fn$;

revoke execute on function fn_registrar_abono(uuid, numeric, metodo_pago, uuid, text, text)
  from public, anon;
grant execute on function fn_registrar_abono(uuid, numeric, metodo_pago, uuid, text, text)
  to authenticated;


-- Anular un abono mal registrado. Devuelve el saldo al cliente.
create or replace function fn_anular_abono(p_abono_id uuid, p_motivo text)
returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  a       record;
  v_nuevo numeric;
  v_nom   text;
begin
  if p_motivo is null or btrim(p_motivo) = '' then
    raise exception 'Anular un abono exige un motivo';
  end if;

  select * into a from abonos_cliente where id = p_abono_id for update;
  if a.id is null then raise exception 'Abono inexistente'; end if;
  if a.anulado then raise exception 'El abono ya esta anulado'; end if;

  if not (app.es_admin()
          or (a.organizacion_id = app.org_id() and app.tiene_nivel('supervisor'))) then
    raise exception 'Solo un supervisor puede anular un abono';
  end if;

  update abonos_cliente
     set anulado = true, anulado_por = auth.uid(), anulado_en = now(),
         notas = coalesce(notas || ' | ', '') || 'Anulado: ' || btrim(p_motivo)
   where id = p_abono_id;

  update clientes set saldo = saldo + a.monto, actualizado_en = now()
   where id = a.cliente_id
  returning nombre, saldo into v_nom, v_nuevo;

  return jsonb_build_object(
    'abono_id',   p_abono_id,
    'cliente',    v_nom,
    'devuelto',   round(a.monto, 2),
    'saldo_nuevo', round(v_nuevo, 2),
    -- Si el abono era en efectivo de un turno ya cerrado, el arqueo de ese
    -- turno quedo congelado con ese dinero adentro. La gaveta no cambia.
    'arqueo_congelado', a.metodo = 'efectivo'
      and exists (select 1 from turnos_caja t
                   where t.id = a.turno_id and t.estado = 'cerrado')
  );
end $fn$;

revoke execute on function fn_anular_abono(uuid, text) from public, anon;
grant execute on function fn_anular_abono(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 3. El limite de credito ahora si se respeta
--
--    Regla: limite_credito en 0 significa que a ese cliente NO se le fia.
--    Para habilitarle fiado hay que ponerle un limite explicito. Es mas
--    seguro que asumir credito ilimitado por omision.
-- ---------------------------------------------------------------------------

create or replace function fn_registrar_venta(
  p_desbloqueo_id uuid,
  p_items         jsonb,
  p_pagos         jsonb,
  p_cliente_id    uuid default null,
  p_fiscal        boolean default false
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

  -- El cliente tiene que ser de este negocio. Sin esto una caja podia
  -- etiquetar la venta -y cargarle el fiado- a un cliente de otra pulperia.
  if p_cliente_id is not null then
    select * into cl from clientes
     where id = p_cliente_id and organizacion_id = t.organizacion_id;
    if cl.id is null then
      raise exception 'Cliente inexistente en este negocio';
    end if;
  end if;

  v_numero := 'T-' || lpad(fn_siguiente_numero(t.organizacion_id, t.sucursal_id, 'ticket')::text, 8, '0');

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

  for it in select * from jsonb_array_elements(p_items) loop
    select p.*, coalesce(i.tasa, 0) as tasa, coalesce(i.incluido_en_precio, true) as incluido
      into v_prod
    from productos p
    left join impuestos i on i.id = p.impuesto_id
    where p.id = (it->>'producto_id')::uuid;

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

    v_desc  := coalesce((it->>'descuento')::numeric, 0);
    v_tasa  := v_prod.tasa;
    v_linea := (v_precio * v_cant) - v_desc;

    if v_prod.tipo = 'servicio' then
      v_costo := 0;
    else
      v_costo := fn_descontar_fefo(t.sucursal_id, v_prod.id, v_cant,
                                   'venta', v_venta_id, d.cajero_id);
    end if;

    insert into venta_detalle (organizacion_id, venta_id, producto_id, cantidad,
                               precio_unitario, descuento, tasa_impuesto,
                               impuesto_incluido, costo_unitario, total)
    values (t.organizacion_id, v_venta_id, v_prod.id, v_cant,
            v_precio, v_desc, v_tasa, v_prod.incluido,
            case when v_cant > 0 then v_costo / v_cant else 0 end, v_linea);

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

  -- ---- control de fiado ----
  if v_credito > 0 then
    if p_cliente_id is null then
      raise exception 'Una venta al credito requiere cliente';
    end if;

    -- Se relee con for update: entre la validacion de arriba y aqui otra caja
    -- pudo haberle fiado al mismo cliente. El candado evita el doble fiado.
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
    'pagado', round(v_pagado, 2), 'fiado', round(v_credito, 2),
    'cambio', v_cambio, 'caja_bloqueada', true
  );
end $fn$;

revoke execute on function fn_registrar_venta(uuid, jsonb, jsonb, uuid, boolean) from public, anon;
grant execute on function fn_registrar_venta(uuid, jsonb, jsonb, uuid, boolean) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. El arqueo incluye los abonos en efectivo
-- ---------------------------------------------------------------------------

create or replace function fn_cerrar_turno(
  p_turno_id uuid,
  p_monto_declarado numeric,
  p_notas text default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  t          record;
  v_ventas   numeric;
  v_abonos   numeric;
  v_esperado numeric;
begin
  select * into t from turnos_caja where id = p_turno_id for update;
  if t.id is null or t.estado <> 'abierto' then
    raise exception 'El turno no esta abierto';
  end if;

  select coalesce(sum(pv.monto), 0) into v_ventas
  from pagos_venta pv
  join ventas ve on ve.id = pv.venta_id
  where ve.turno_id = p_turno_id
    and ve.estado = 'completada'
    and pv.metodo = 'efectivo';

  -- Lo que el cliente pago de su fiado tambien esta en la gaveta
  select coalesce(sum(ab.monto), 0) into v_abonos
  from abonos_cliente ab
  where ab.turno_id = p_turno_id
    and not ab.anulado
    and ab.metodo = 'efectivo';

  v_esperado := t.monto_inicial + v_ventas + v_abonos;

  update turnos_caja
     set estado = 'cerrado', cerrado_en = now(), cerrado_por = auth.uid(),
         monto_declarado = p_monto_declarado,
         monto_esperado  = v_esperado,
         diferencia      = p_monto_declarado - v_esperado,
         notas           = p_notas
   where id = p_turno_id;

  update caja_desbloqueos set consumido_en = now()
   where turno_id = p_turno_id and consumido_en is null;

  return jsonb_build_object(
    'monto_inicial',   t.monto_inicial,
    'efectivo_ventas', v_ventas,
    'abonos_fiado',    v_abonos,
    'esperado',        v_esperado,
    'declarado',       p_monto_declarado,
    'diferencia',      p_monto_declarado - v_esperado
  );
end $fn$;

revoke execute on function fn_cerrar_turno(uuid, numeric, text) from public, anon;
grant execute on function fn_cerrar_turno(uuid, numeric, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. Quien me debe
--
--    La antiguedad se calcula por orden de compra (lo mas viejo se paga
--    primero): se acumulan las ventas al credito de la mas antigua a la mas
--    nueva y se compara contra lo abonado. La primera que todavia no queda
--    cubierta es la deuda mas vieja que sigue viva.
-- ---------------------------------------------------------------------------

create or replace view v_fiado as
-- OJO: la antiguedad se calcula sobre la parte FIADA de cada venta, no sobre
-- el total. En una venta mixta (parte efectivo, parte fiado) el total no es
-- lo que el cliente quedo debiendo.
with credito as (
  select v.cliente_id, v.id, v.creada_en, cr.monto,
         sum(cr.monto) over (partition by v.cliente_id order by v.creada_en, v.id) as acumulado
  from ventas v
  cross join lateral (
    select coalesce(sum(pv.monto), 0) as monto
    from pagos_venta pv
    where pv.venta_id = v.id and pv.metodo = 'credito'
  ) cr
  where v.es_credito and v.estado = 'completada' and v.cliente_id is not null
),
pagado as (
  select cliente_id, sum(monto) as total
  from abonos_cliente where not anulado
  group by cliente_id
),
vieja as (
  select c.cliente_id, min(c.creada_en) as desde
  from credito c
  left join pagado p on p.cliente_id = c.cliente_id
  where c.acumulado > coalesce(p.total, 0)
  group by c.cliente_id
)
select
  cl.organizacion_id,
  cl.id                                   as cliente_id,
  cl.nombre                               as cliente,
  cl.telefono,
  cl.saldo                                as debe,
  cl.limite_credito                       as limite,
  greatest(cl.limite_credito - cl.saldo, 0) as disponible,
  cl.saldo >= cl.limite_credito           as tope_alcanzado,
  vieja.desde                             as deuda_desde,
  case when vieja.desde is null then null
       else (current_date - vieja.desde::date) end as dias,
  (select max(a.creado_en) from abonos_cliente a
    where a.cliente_id = cl.id and not a.anulado) as ultimo_abono,
  (select count(*) from ventas v
    where v.cliente_id = cl.id and v.es_credito and v.estado = 'completada') as compras_credito
from clientes cl
left join vieja on vieja.cliente_id = cl.id
where cl.saldo > 0;

alter view v_fiado set (security_invoker = on);
grant select on v_fiado to authenticated;


-- Estado de cuenta de un cliente: sus compras al credito y sus abonos
create or replace function fn_estado_cuenta(p_cliente_id uuid)
returns table (
  fecha      timestamptz,
  tipo       text,
  documento  text,
  detalle    text,
  cargo      numeric,
  abono      numeric
)
language sql stable security definer set search_path = public, app as $fn$
  -- El cargo es lo que quedo FIADO, no el total de la venta. Si la dona pago
  -- L50 en efectivo y fio L100, su estado de cuenta carga L100.
  select v.creada_en, 'compra', v.numero,
         (select count(*)::text from venta_detalle d where d.venta_id = v.id) || ' productos',
         cr.monto, null::numeric
  from ventas v
  join clientes c on c.id = v.cliente_id
  cross join lateral (
    select coalesce(sum(pv.monto), 0) as monto
    from pagos_venta pv
    where pv.venta_id = v.id and pv.metodo = 'credito'
  ) cr
  where v.cliente_id = p_cliente_id
    and v.es_credito and v.estado = 'completada'
    and cr.monto > 0
    and (app.es_admin()
         or (c.organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))
         or c.usuario_id = auth.uid())

  union all

  select a.creado_en, 'abono',
         coalesce(a.referencia, '—'),
         a.metodo::text || coalesce(' · ' || a.notas, ''),
         null::numeric, a.monto
  from abonos_cliente a
  join clientes c on c.id = a.cliente_id
  where a.cliente_id = p_cliente_id
    and not a.anulado
    and (app.es_admin()
         or (c.organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))
         or c.usuario_id = auth.uid())

  order by 1
$fn$;

revoke execute on function fn_estado_cuenta(uuid) from public, anon;
grant execute on function fn_estado_cuenta(uuid) to authenticated;


-- Resumen para la pantalla de fiado
create or replace function fn_fiado_resumen()
returns jsonb
language sql stable security definer set search_path = public, app as $fn$
  select jsonb_build_object(
    'clientes',      count(*),
    'total',         coalesce(sum(debe), 0),
    'al_tope',       count(*) filter (where tope_alcanzado),
    'mas_30_dias',   count(*) filter (where dias > 30),
    'monto_mas_30',  coalesce(sum(debe) filter (where dias > 30), 0),
    'mas_viejo',     coalesce(max(dias), 0)
  )
  from v_fiado
  where organizacion_id = app.org_id()
$fn$;

revoke execute on function fn_fiado_resumen() from public, anon;
grant execute on function fn_fiado_resumen() to authenticated;
