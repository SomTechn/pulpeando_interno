-- ============================================================================
--  Migración 043 · El código del ticket, para escanearlo en una devolución
--
--  El ticket lleva al pie un código de barras. Con la pistola (o la cámara)
--  en Ventas, el ticket abre la venta directo, sin buscarla por fecha.
--
--  EL CÓDIGO: 16 DÍGITOS
--
--      823   014   02   58301947
--      │     │     │    └─ ticket: 8 dígitos al azar, únicos en el negocio
--      │     │     └────── número de caja (01–99, por negocio)
--      │     └──────────── número de cajero (001–999, por negocio)
--      └────────────────── código de tienda: 3 dígitos al azar (100–999)
--
--  Por qué así:
--   - Todo dígitos y en número par: Code 128 los empaca de dos en dos
--     (juego C) y el código sale corto, cabe a lo ancho en papel de 58 mm.
--   - Ancho fijo: cualquiera puede leerlo de vuelta sin separadores.
--   - El número del ticket es al azar y no correlativo: con un ticket en la
--     mano no se adivina el de la venta de al lado.
--   - El código de tienda es único en toda la plataforma. Escanear en
--     Pulpería A el ticket de Pulpería B responde "es de otra tienda" en vez
--     de "no existe", que confunde. Son 900 códigos: alcanza para 900
--     negocios. Antes de llegar ahí hay que pasar a 4 dígitos.
--
--  El número de cajero y el de caja son NUEVOS, numéricos y fijos. No se usa
--  el código de cajera (perfiles.codigo) porque lleva letras, es opcional y
--  el gerente lo cambia; ni cajas.codigo, que es texto libre y se repite
--  entre sucursales. Ninguno de los dos números se puede cambiar desde la app.
--
--  El código se arma en un disparador de ventas, no en fn_registrar_venta:
--  así lo llevan TODAS las ventas (caja, pedidos, fiado) sin reescribir
--  ninguna de esas funciones. Lo que el ticket dice queda congelado en la
--  venta: si mañana la cajera cambia de número, el ticket viejo sigue leyendo.
--
--  Sin drops: se aplica completa desde la herramienta de Supabase.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. El código de tienda
-- ---------------------------------------------------------------------------
alter table organizaciones add column if not exists codigo_tienda text;

create or replace function app.nuevo_codigo_tienda()
returns text language plpgsql volatile set search_path = public, app as $fn$
declare v text;
begin
  select lpad(n::text, 3, '0') into v
    from generate_series(100, 999) n
   where not exists (select 1 from organizaciones o where o.codigo_tienda = n::text)
   order by random() limit 1;
  if v is null then
    raise exception 'Se acabaron los códigos de tienda de 3 dígitos';
  end if;
  return v;
end $fn$;

create or replace function app.organizaciones_codigo_tienda()
returns trigger language plpgsql set search_path = public, app as $fn$
begin
  if tg_op = 'INSERT' then
    if new.codigo_tienda is null then new.codigo_tienda := app.nuevo_codigo_tienda(); end if;
  elsif old.codigo_tienda is not null
       and new.codigo_tienda is distinct from old.codigo_tienda and not app.es_admin() then
    raise exception 'El código de tienda lo asigna Pulpeando y no cambia';
  end if;
  return new;
end $fn$;

create or replace trigger tg_organizaciones_codigo_tienda
  before insert or update on organizaciones
  for each row execute function app.organizaciones_codigo_tienda();

-- Los negocios que ya existen. Uno por uno: cada código mira los anteriores.
do $$
declare r record;
begin
  for r in select id from organizaciones where codigo_tienda is null order by creada_en loop
    update organizaciones set codigo_tienda = app.nuevo_codigo_tienda() where id = r.id;
  end loop;
end $$;

alter table organizaciones alter column codigo_tienda set not null;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'organizaciones_codigo_tienda_key') then
    alter table organizaciones add constraint organizaciones_codigo_tienda_key unique (codigo_tienda);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'organizaciones_codigo_tienda_formato') then
    alter table organizaciones add constraint organizaciones_codigo_tienda_formato
      check (codigo_tienda ~ '^[1-9][0-9]{2}$');
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 2. El número de cajero (por negocio, 1–999) y el de caja (por negocio, 1–99)
--    El siguiente libre, con un candado por negocio para que dos altas al
--    mismo tiempo no saquen el mismo número.
-- ---------------------------------------------------------------------------
alter table perfiles add column if not exists numero_cajero smallint;
alter table cajas    add column if not exists numero smallint;

create or replace function app.perfiles_numero_cajero()
returns trigger language plpgsql set search_path = public, app as $fn$
begin
  if tg_op = 'UPDATE' then
    if old.numero_cajero is not null
       and new.numero_cajero is distinct from old.numero_cajero and not app.es_admin() then
      raise exception 'El número de cajero lo asigna el sistema y no cambia';
    end if;
    return new;
  end if;
  if new.numero_cajero is null and new.organizacion_id is not null then
    perform pg_advisory_xact_lock(hashtext('numero_cajero:' || new.organizacion_id::text));
    select n into new.numero_cajero from generate_series(1, 999) n
     where not exists (select 1 from perfiles p
                        where p.organizacion_id = new.organizacion_id and p.numero_cajero = n)
     order by n limit 1;
    if new.numero_cajero is null then
      raise exception 'Este negocio ya usó los 999 números de cajero';
    end if;
  end if;
  return new;
end $fn$;

create or replace trigger tg_perfiles_numero_cajero
  before insert or update on perfiles
  for each row execute function app.perfiles_numero_cajero();

create or replace function app.cajas_numero()
returns trigger language plpgsql set search_path = public, app as $fn$
begin
  if tg_op = 'UPDATE' then
    if old.numero is not null
       and new.numero is distinct from old.numero and not app.es_admin() then
      raise exception 'El número de caja lo asigna el sistema y no cambia';
    end if;
    return new;
  end if;
  if new.numero is null then
    perform pg_advisory_xact_lock(hashtext('numero_caja:' || new.organizacion_id::text));
    select n into new.numero from generate_series(1, 99) n
     where not exists (select 1 from cajas c
                        where c.organizacion_id = new.organizacion_id and c.numero = n)
     order by n limit 1;
    if new.numero is null then
      raise exception 'Este negocio ya usó los 99 números de caja';
    end if;
  end if;
  return new;
end $fn$;

create or replace trigger tg_cajas_numero
  before insert or update on cajas
  for each row execute function app.cajas_numero();

-- Los que ya existen, en el orden en que se crearon
with r as (
  select id, row_number() over (partition by organizacion_id order by creado_en, id) as n
    from perfiles where organizacion_id is not null and numero_cajero is null)
update perfiles p set numero_cajero = r.n from r where p.id = r.id;

with r as (
  select id, row_number() over (partition by organizacion_id order by creada_en, id) as n
    from cajas where numero is null)
update cajas c set numero = r.n from r where c.id = r.id;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'perfiles_numero_cajero_key') then
    alter table perfiles add constraint perfiles_numero_cajero_key unique (organizacion_id, numero_cajero);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'perfiles_numero_cajero_rango') then
    alter table perfiles add constraint perfiles_numero_cajero_rango check (numero_cajero between 1 and 999);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'cajas_numero_key') then
    alter table cajas add constraint cajas_numero_key unique (organizacion_id, numero);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'cajas_numero_rango') then
    alter table cajas add constraint cajas_numero_rango check (numero between 1 and 99);
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 3. El código de la venta
-- ---------------------------------------------------------------------------
alter table ventas add column if not exists codigo_barras text;

-- Arma el código para una venta. El azar se repite hasta dar con uno libre
-- en el negocio; con 100 millones de números eso es casi siempre al primero.
create or replace function app.codigo_de_venta(p_org uuid, p_cajero uuid, p_caja uuid)
returns text language plpgsql volatile set search_path = public, app as $fn$
declare
  v_pre text;
  v_cod text;
  i     int := 0;
begin
  select o.codigo_tienda
         || lpad(coalesce((select numero_cajero from perfiles where id = p_cajero), 0)::text, 3, '0')
         || lpad(coalesce((select numero from cajas where id = p_caja), 0)::text, 2, '0')
    into v_pre
    from organizaciones o where o.id = p_org;
  loop
    v_cod := v_pre || lpad(floor(random() * 100000000)::bigint::text, 8, '0');
    exit when not exists (select 1 from ventas
                           where organizacion_id = p_org and right(codigo_barras, 8) = right(v_cod, 8));
    i := i + 1;
    if i > 50 then raise exception 'No se pudo generar el código del ticket'; end if;
  end loop;
  return v_cod;
end $fn$;

create or replace function app.ventas_codigo_barras()
returns trigger language plpgsql set search_path = public, app as $fn$
begin
  if new.codigo_barras is null then
    new.codigo_barras := app.codigo_de_venta(new.organizacion_id, new.cajero_id, new.caja_id);
  end if;
  return new;
end $fn$;

create or replace trigger tg_ventas_codigo_barras
  before insert on ventas
  for each row execute function app.ventas_codigo_barras();

-- Las ventas que ya existen también lo llevan: se pueden reimprimir y devolver.
do $$
declare r record;
begin
  for r in select id, organizacion_id, cajero_id, caja_id from ventas
            where codigo_barras is null order by creada_en loop
    update ventas set codigo_barras = app.codigo_de_venta(r.organizacion_id, r.cajero_id, r.caja_id)
     where id = r.id;
  end loop;
end $$;

-- El número del ticket (los últimos 8) no se repite dentro del negocio
create unique index if not exists ventas_ticket_aleatorio_key
  on ventas (organizacion_id, right(codigo_barras, 8));
create unique index if not exists ventas_codigo_barras_key
  on ventas (organizacion_id, codigo_barras);

-- Las funciones auxiliares no las llama nadie desde fuera
revoke execute on function app.nuevo_codigo_tienda() from public, anon, authenticated;
revoke execute on function app.codigo_de_venta(uuid, uuid, uuid) from public, anon, authenticated;
revoke execute on function app.organizaciones_codigo_tienda() from public, anon, authenticated;
revoke execute on function app.perfiles_numero_cajero() from public, anon, authenticated;
revoke execute on function app.cajas_numero() from public, anon, authenticated;
revoke execute on function app.ventas_codigo_barras() from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- 4. Escanear un ticket: del código a la venta
--    Responde {ok:false, mensaje} en vez de lanzar, para que la pantalla
--    diga algo útil al cajero sin parsear errores.
-- ---------------------------------------------------------------------------
create or replace function fn_buscar_ticket(p_codigo text)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  v_cod text := regexp_replace(coalesce(p_codigo, ''), '[^0-9]', '', 'g');
  v_tienda text;
  v_id uuid;
begin
  if v_org is null or not app.tiene_nivel('auxiliar') then
    raise exception 'Sin permiso';
  end if;
  if length(v_cod) <> 16 then
    return jsonb_build_object('ok', false, 'mensaje', 'Eso no es un código de ticket');
  end if;
  select codigo_tienda into v_tienda from organizaciones where id = v_org;
  if left(v_cod, 3) <> v_tienda then
    return jsonb_build_object('ok', false, 'mensaje', 'Ese ticket es de otra tienda');
  end if;
  select id into v_id from ventas
   where organizacion_id = v_org and codigo_barras = v_cod;
  if v_id is null then
    return jsonb_build_object('ok', false, 'mensaje', 'No hay ninguna venta con ese ticket');
  end if;
  return jsonb_build_object('ok', true, 'venta_id', v_id);
end $fn$;

revoke execute on function fn_buscar_ticket(text) from public, anon;
grant execute on function fn_buscar_ticket(text) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. La venta completa y la devolución completa llevan ahora el código, el
--    código de tienda, los números de cajero y caja, y el logo.
--    Mismo tipo de retorno (jsonb): create or replace basta.
-- ---------------------------------------------------------------------------
create or replace function fn_venta_completa(p_venta_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v    record;
  o    record;
  s    record;
  v_rango jsonb;
  v_ve_costos boolean;
  v_res jsonb;
begin
  select * into v from ventas where id = p_venta_id;
  if v.id is null then raise exception 'Venta inexistente'; end if;

  if not (app.es_admin()
          or (v.organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))) then
    raise exception 'Esa venta no es de este negocio';
  end if;

  select * into o from organizaciones where id = v.organizacion_id;
  v_ve_costos := app.tiene_nivel('supervisor') or app.es_admin();

  if v.numero_fiscal is not null then
    select * into s from series_fiscales sf
     where sf.organizacion_id = v.organizacion_id
       and sf.cai is not distinct from v.cai
       and v.numero_fiscal like sf.prefijo || '-%'
     order by sf.creada_en desc limit 1;
    -- (s queda sin asignar si no hay numero fiscal: no se lee fuera de este if)
    if found then
      v_rango := jsonb_build_object(
        'desde', s.prefijo || '-' || lpad(s.correlativo_inicial::text, 8, '0'),
        'hasta', s.prefijo || '-' || lpad(s.correlativo_final::text, 8, '0'),
        'fecha_limite', s.fecha_limite_emision);
    end if;
  end if;

  select jsonb_build_object(
    'venta', jsonb_build_object(
      'id', v.id, 'numero', v.numero, 'numero_fiscal', v.numero_fiscal,
      'cai', v.cai, 'documento', v.tipo_documento, 'creada_en', v.creada_en,
      'subtotal', v.subtotal, 'impuesto', v.impuesto, 'descuento', v.descuento,
      'total', v.total, 'es_credito', v.es_credito, 'estado', v.estado,
      'motivo_anulacion', v.motivo_anulacion, 'anulada_en', v.anulada_en,
      'costo', case when v_ve_costos then v.costo_total end,
      'anulada_por', (select nombre from perfiles where id = v.anulada_por),
      'devuelto', (select coalesce(sum(total), 0) from devoluciones_venta where venta_id = v.id),
      'sucursal_id', v.sucursal_id,
      'codigo_barras', v.codigo_barras
    ),
    'rango', v_rango,
    'negocio', jsonb_build_object(
      'nombre', o.nombre, 'rtn', o.identificacion_fiscal, 'moneda', o.moneda,
      'razon_social', o.config->>'razon_social',
      'direccion', o.config->>'direccion_fiscal',
      'telefono', o.config->>'telefono',
      'correo', o.config->>'correo',
      'mensaje_ticket', o.config->>'mensaje_ticket',
      'ancho_ticket', coalesce((o.config->>'ancho_ticket')::int, 80),
      'codigo_tienda', o.codigo_tienda,
      'logo_path', o.config->>'logo_path'),
    'sucursal', (select jsonb_build_object('nombre', su.nombre, 'direccion', su.direccion,
                        'telefono', su.telefono)
                   from sucursales su where su.id = v.sucursal_id),
    'caja',    (select nombre from cajas where id = v.caja_id),
    'cajero',  (select nombre from perfiles where id = v.cajero_id),
    'cliente', (select jsonb_build_object('nombre', c.nombre, 'telefono', c.telefono,
                       'rtn', c.identificacion_fiscal)
                  from clientes c where c.id = v.cliente_id),
    'desglose', (
      select jsonb_build_object(
        'exento',    round(coalesce(sum(d.total) filter (where d.tasa_impuesto = 0), 0), 2),
        'gravado15', round(coalesce(sum(case when d.impuesto_incluido then d.total / (1 + d.tasa_impuesto) else d.total end)
                                    filter (where d.tasa_impuesto between 0.149 and 0.151), 0), 2),
        'isv15',     round(coalesce(sum(case when d.impuesto_incluido then d.total - d.total / (1 + d.tasa_impuesto) else d.total * d.tasa_impuesto end)
                                    filter (where d.tasa_impuesto between 0.149 and 0.151), 0), 2),
        'gravado18', round(coalesce(sum(case when d.impuesto_incluido then d.total / (1 + d.tasa_impuesto) else d.total end)
                                    filter (where d.tasa_impuesto between 0.179 and 0.181), 0), 2),
        'isv18',     round(coalesce(sum(case when d.impuesto_incluido then d.total - d.total / (1 + d.tasa_impuesto) else d.total * d.tasa_impuesto end)
                                    filter (where d.tasa_impuesto between 0.179 and 0.181), 0), 2))
      from venta_detalle d where d.venta_id = v.id),
    'lineas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'detalle_id', d.id,
               'producto', pr.nombre,
               'sku', pr.sku,
               'cantidad', d.cantidad,
               'devuelto', (select coalesce(sum(dd.cantidad), 0) from devolucion_detalle dd
                             where dd.venta_detalle_id = d.id),
               'precio',   d.precio_unitario,
               'descuento', d.descuento,
               'total',    d.total,
               'tasa',     d.tasa_impuesto,
               'exento',   d.tasa_impuesto = 0,
               'costo',    case when v_ve_costos then d.costo_unitario end)
             order by pr.nombre)
      from venta_detalle d join productos pr on pr.id = d.producto_id
      where d.venta_id = v.id), '[]'::jsonb),
    'pagos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'metodo', pv.metodo, 'monto', pv.monto,
               'recibido', pv.recibido, 'cambio', pv.cambio,
               'referencia', pv.referencia) order by pv.creado_en)
      from pagos_venta pv where pv.venta_id = v.id), '[]'::jsonb),
    'devoluciones', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', dv.id, 'numero', dv.numero, 'numero_fiscal', dv.numero_fiscal,
               'documento', dv.tipo_documento, 'total', dv.total, 'motivo', dv.motivo,
               'rebaja_fiado', dv.rebaja_fiado, 'reembolso', dv.reembolso,
               'metodo', dv.reembolso_metodo, 'creada_en', dv.creada_en,
               'por', (select nombre from perfiles where id = dv.creada_por))
             order by dv.creada_en)
      from devoluciones_venta dv where dv.venta_id = v.id), '[]'::jsonb)
  ) into v_res;

  return v_res;
end $fn$;

revoke execute on function fn_venta_completa(uuid) from public, anon;
grant execute on function fn_venta_completa(uuid) to authenticated;


-- Lo que se imprime de una devolucion: el mismo formato del ticket
create or replace function fn_devolucion_completa(p_devolucion_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  dv  record;
  v   record;
  o   record;
  s   record;
  v_rango jsonb;
begin
  select * into dv from devoluciones_venta where id = p_devolucion_id;
  if dv.id is null then raise exception 'Devolución inexistente'; end if;
  if not (app.es_admin() or (dv.organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))) then
    raise exception 'Esa devolución no es de este negocio';
  end if;
  select * into v from ventas where id = dv.venta_id;
  select * into o from organizaciones where id = dv.organizacion_id;
  if dv.numero_fiscal is not null then
    select * into s from series_fiscales sf
     where sf.organizacion_id = dv.organizacion_id and sf.cai is not distinct from dv.cai
       and dv.numero_fiscal like sf.prefijo || '-%'
     order by sf.creada_en desc limit 1;
    -- (s queda sin asignar si no hay numero fiscal: no se lee fuera de este if)
    if found then
      v_rango := jsonb_build_object(
        'desde', s.prefijo || '-' || lpad(s.correlativo_inicial::text, 8, '0'),
        'hasta', s.prefijo || '-' || lpad(s.correlativo_final::text, 8, '0'),
        'fecha_limite', s.fecha_limite_emision);
    end if;
  end if;

  return jsonb_build_object(
    'devolucion', jsonb_build_object('motivo', dv.motivo,
      'referencia', coalesce(v.numero_fiscal, v.numero),
      'rebaja_fiado', dv.rebaja_fiado, 'reembolso', dv.reembolso, 'metodo', dv.reembolso_metodo),
    'venta', jsonb_build_object(
      'id', dv.id, 'numero', dv.numero, 'numero_fiscal', dv.numero_fiscal, 'cai', dv.cai,
      'documento', case when dv.tipo_documento = 'nota_credito' then 'nota_credito' else 'devolucion' end,
      'creada_en', dv.creada_en, 'subtotal', dv.subtotal, 'impuesto', dv.impuesto,
      'descuento', 0, 'total', dv.total, 'estado', 'completada'),
    'rango', v_rango,
    'negocio', jsonb_build_object(
      'nombre', o.nombre, 'rtn', o.identificacion_fiscal, 'moneda', o.moneda,
      'razon_social', o.config->>'razon_social', 'direccion', o.config->>'direccion_fiscal',
      'telefono', o.config->>'telefono', 'correo', o.config->>'correo',
      'mensaje_ticket', o.config->>'mensaje_ticket',
      'ancho_ticket', coalesce((o.config->>'ancho_ticket')::int, 80),
      'codigo_tienda', o.codigo_tienda,
      'logo_path', o.config->>'logo_path'),
    'sucursal', (select jsonb_build_object('nombre', su.nombre, 'direccion', su.direccion, 'telefono', su.telefono)
                   from sucursales su where su.id = dv.sucursal_id),
    'cajero', (select nombre from perfiles where id = dv.creada_por),
    'cliente', (select jsonb_build_object('nombre', c.nombre, 'rtn', c.identificacion_fiscal)
                  from clientes c where c.id = v.cliente_id),
    'desglose', (
      select jsonb_build_object(
        'exento',    round(coalesce(sum(d.total) filter (where d.tasa_impuesto = 0), 0), 2),
        'gravado15', round(coalesce(sum(case when d.impuesto_incluido then d.total / (1 + d.tasa_impuesto) else d.total end)
                                    filter (where d.tasa_impuesto between 0.149 and 0.151), 0), 2),
        'isv15',     round(coalesce(sum(case when d.impuesto_incluido then d.total - d.total / (1 + d.tasa_impuesto) else d.total * d.tasa_impuesto end)
                                    filter (where d.tasa_impuesto between 0.149 and 0.151), 0), 2),
        'gravado18', round(coalesce(sum(case when d.impuesto_incluido then d.total / (1 + d.tasa_impuesto) else d.total end)
                                    filter (where d.tasa_impuesto between 0.179 and 0.181), 0), 2),
        'isv18',     round(coalesce(sum(case when d.impuesto_incluido then d.total - d.total / (1 + d.tasa_impuesto) else d.total * d.tasa_impuesto end)
                                    filter (where d.tasa_impuesto between 0.179 and 0.181), 0), 2))
      from devolucion_detalle d where d.devolucion_id = dv.id),
    'lineas', coalesce((
      select jsonb_agg(jsonb_build_object('producto', pr.nombre, 'cantidad', d.cantidad,
               'precio', d.precio_unitario, 'total', d.total, 'exento', d.tasa_impuesto = 0)
             order by pr.nombre)
      from devolucion_detalle d join productos pr on pr.id = d.producto_id
      where d.devolucion_id = dv.id), '[]'::jsonb),
    'pagos', case when dv.reembolso > 0
                  then jsonb_build_array(jsonb_build_object('metodo', dv.reembolso_metodo, 'monto', dv.reembolso))
                  else '[]'::jsonb end);
end $fn$;

revoke execute on function fn_devolucion_completa(uuid) from public, anon;
grant execute on function fn_devolucion_completa(uuid) to authenticated;
