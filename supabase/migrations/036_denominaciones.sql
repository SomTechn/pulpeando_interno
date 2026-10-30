-- ============================================================================
--  Migración 036 · El conteo por denominación
--
--  Hasta aquí, un arqueo era un número: "hay 4,380". Eso dice que no cuadra
--  pero no ayuda a encontrar dónde: si faltan 120, saber que había tres de
--  cien y no cuatro es la mitad del camino. Ahora el arqueo, el fondo, el
--  retiro y el cierre llevan cuántos billetes de cada clase se contaron.
--
--  LA LISTA DE DENOMINACIONES ES DEL NEGOCIO, NO DEL CÓDIGO
--
--  Va en organizaciones.config->'denominaciones'. Dos razones:
--
--    1. Un billete se deja de emitir o aparece uno nuevo, y eso no debería
--       exigir una migración ni esperar a que alguien programe.
--    2. Esto es multi-inquilino: el día que haya un negocio fuera de
--       Honduras, cambia la lista y ya.
--
--  Sin lista configurada se usan las de Honduras, que es lo que hay hoy.
--
--  EL DESGLOSE TIENE QUE CUADRAR CON EL MONTO
--
--  Si la suma del desglose no da el monto, no se guarda ninguno de los dos.
--  Un desglose que no suma el total es peor que no tener desglose: se ve
--  igual de oficial y manda a buscar la diferencia al lugar equivocado.
--
--  POR QUÉ HAY QUE SOLTAR LAS FUNCIONES PRIMERO
--
--  Agregarle un parámetro con default a una función existente NO la
--  reemplaza: crea una segunda, y entonces la llamada de seis argumentos
--  calza con las dos y Postgres responde "function is not unique". Por eso
--  van los drop de arriba. Es lo mismo que ya pasó con fn_ubicaciones_detalle
--  y con fn_fijar_tipo_ubicacion.
-- ============================================================================

drop function if exists fn_movimiento_caja(uuid, text, numeric, text, text, text);
drop function if exists fn_arqueo_caja(uuid, numeric, text, text, text);
drop function if exists fn_cerrar_turno_con_arqueo(uuid, numeric, text, text, text);


-- ---------------------------------------------------------------------------
-- 1. Dónde se guarda el desglose
-- ---------------------------------------------------------------------------
alter table movimientos_caja add column if not exists detalle jsonb;
alter table turnos_caja     add column if not exists detalle_cierre jsonb;


-- ---------------------------------------------------------------------------
-- 2. Las denominaciones del negocio
--
-- Honduras: billetes de 500, 200, 100, 50, 20, 10, 5, 2 y 1 lempira, y
-- monedas de 50, 20, 10 y 5 centavos. La pantalla separa billetes de monedas
-- por el valor (1 o más es billete), así no hace falta configurarlo aparte.
-- ---------------------------------------------------------------------------
create or replace function app.denominaciones(p_org uuid default null)
returns numeric[]
stable language sql security definer set search_path = public, app as $fn$
  select coalesce(
    (select array_agg(x::numeric order by x::numeric desc)
       from organizaciones o,
            lateral jsonb_array_elements_text(o.config->'denominaciones') x
      where o.id = coalesce(p_org, app.org_id())
        and jsonb_typeof(o.config->'denominaciones') = 'array'
        and x::numeric > 0),
    array[500, 200, 100, 50, 20, 10, 5, 2, 1, 0.5, 0.2, 0.1, 0.05]::numeric[])
$fn$;

revoke execute on function app.denominaciones(uuid) from public, anon;
grant  execute on function app.denominaciones(uuid) to authenticated;


create or replace function fn_fijar_denominaciones(p_lista jsonb)
returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  v_n   int;
begin
  if v_org is null then raise exception 'Sesion sin negocio'; end if;
  if not app.tiene_nivel('gerente') then
    raise exception 'Solo un gerente cambia las denominaciones';
  end if;

  -- null vuelve a las de por defecto, que es la salida cuando alguien se
  -- equivoca y no quiere pensar cuál era la lista buena.
  if p_lista is null or jsonb_typeof(p_lista) = 'null' then
    update organizaciones set config = config - 'denominaciones', actualizado_en = now()
     where id = v_org;
    return jsonb_build_object('denominaciones', to_jsonb(app.denominaciones(v_org)),
                              'por_defecto', true);
  end if;

  if jsonb_typeof(p_lista) <> 'array' then
    raise exception 'Las denominaciones van en una lista';
  end if;

  select count(*) into v_n from jsonb_array_elements(p_lista) x
   where jsonb_typeof(x) = 'number' and (x::text)::numeric > 0;

  if v_n <> jsonb_array_length(p_lista) then
    raise exception 'Cada denominacion es un numero mayor a cero';
  end if;
  if v_n < 1 or v_n > 24 then
    raise exception 'Ponga entre 1 y 24 denominaciones';
  end if;

  update organizaciones
     set config = jsonb_set(config, '{denominaciones}', p_lista), actualizado_en = now()
   where id = v_org;

  return jsonb_build_object('denominaciones', to_jsonb(app.denominaciones(v_org)),
                            'por_defecto', false);
end $fn$;

revoke execute on function fn_fijar_denominaciones(jsonb) from public, anon;
grant  execute on function fn_fijar_denominaciones(jsonb) to authenticated;


-- ---------------------------------------------------------------------------
-- 3. Revisar y sumar un desglose
--
--   {"500": 3, "100": 12, "0.5": 20}
--
-- La llave es la denominación y el valor cuántas hay. Se exige que la llave
-- sea una denominación del negocio: si no, un "0.03" se cuela y el total
-- cuadra con algo que no existe.
-- ---------------------------------------------------------------------------
create or replace function app.detalle_suma(d jsonb)
returns numeric
immutable language sql set search_path = public, app as $fn$
  select coalesce(sum((k)::numeric * (v#>>'{}')::numeric), 0)
    from jsonb_each(coalesce(d, '{}'::jsonb)) as e(k, v)
$fn$;

revoke execute on function app.detalle_suma(jsonb) from public, anon;
grant  execute on function app.detalle_suma(jsonb) to authenticated;


-- Devuelve null si está bien, o el reclamo si no.
create or replace function app.detalle_reclamo(d jsonb, p_monto numeric, p_org uuid)
returns text
stable language plpgsql set search_path = public, app as $fn$
declare
  k    text;
  v    jsonb;
  den  numeric[] := app.denominaciones(p_org);
  v_n  numeric;
begin
  if d is null or jsonb_typeof(d) = 'null' then return null; end if;
  if jsonb_typeof(d) <> 'object' then
    return 'El desglose por denominacion no tiene la forma esperada';
  end if;

  for k, v in select * from jsonb_each(d) loop
    begin
      v_n := k::numeric;
    exception when others then
      return 'Hay una denominacion que no es un numero: ' || k;
    end;

    if not (v_n = any(den)) then
      return 'La denominacion ' || k || ' no es de las que usa este negocio';
    end if;

    if jsonb_typeof(v) <> 'number' then
      return 'La cantidad de ' || k || ' tiene que ser un numero';
    end if;

    v_n := (v#>>'{}')::numeric;
    if v_n < 0 or v_n <> trunc(v_n) then
      return 'La cantidad de ' || k || ' tiene que ser entera y no negativa';
    end if;
  end loop;

  -- Lo que mas importa: que el desglose y el monto digan lo mismo.
  if round(app.detalle_suma(d), 2) <> round(p_monto, 2) then
    return 'El desglose suma ' || round(app.detalle_suma(d), 2)
           || ' y el monto dice ' || round(p_monto, 2);
  end if;

  return null;
end $fn$;

revoke execute on function app.detalle_reclamo(jsonb, numeric, uuid) from public, anon;
grant  execute on function app.detalle_reclamo(jsonb, numeric, uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. Fondo y retiro, ahora con desglose
-- ---------------------------------------------------------------------------
create or replace function fn_movimiento_caja(
  p_turno_id uuid,
  p_tipo     text,
  p_monto    numeric,
  p_codigo   text,
  p_pin      text,
  p_motivo   text default null,
  p_detalle  jsonb default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  t        record;
  aut      jsonb;
  v_antes  numeric;
  v_id     uuid;
  v_mal    text;
begin
  if p_tipo not in ('fondo', 'retiro') then
    raise exception 'El tipo tiene que ser fondo o retiro';
  end if;
  if p_monto is null or p_monto <= 0 then
    raise exception 'El monto tiene que ser mayor a cero';
  end if;

  select * into t from turnos_caja
   where id = p_turno_id and organizacion_id = app.org_id();
  if t.id is null then raise exception 'Ese turno no es de su negocio'; end if;
  if t.estado <> 'abierto' then raise exception 'Ese turno ya se cerro'; end if;

  -- El desglose se revisa ANTES de cobrar el intento de PIN: un desglose mal
  -- armado es un error de la pantalla, no un intento de entrar con mala
  -- credencial, y no tiene por qué gastarle intentos a nadie.
  v_mal := app.detalle_reclamo(p_detalle, p_monto, t.organizacion_id);
  if v_mal is not null then raise exception '%', v_mal; end if;

  aut := app.quien_autoriza(p_codigo, p_pin, 'supervisor');
  if not (aut->>'ok')::boolean then return aut; end if;

  if not app.es_admin() and t.sucursal_id not in (select app.sucursales_permitidas()) then
    raise exception 'No tiene acceso a esa sucursal';
  end if;

  v_antes := app.efectivo_esperado(p_turno_id);

  if p_tipo = 'retiro' and p_monto > v_antes then
    raise exception 'En la gaveta el sistema solo cuenta con %, no se pueden retirar %',
      round(v_antes, 2), round(p_monto, 2);
  end if;

  insert into movimientos_caja (organizacion_id, sucursal_id, caja_id, turno_id,
                                tipo, monto, motivo, autorizo, detalle)
  values (t.organizacion_id, t.sucursal_id, t.caja_id, p_turno_id,
          p_tipo::tipo_movimiento_caja, round(p_monto, 2),
          nullif(btrim(p_motivo), ''), (aut->>'perfil_id')::uuid, p_detalle)
  returning id into v_id;

  return jsonb_build_object(
    'ok',            true,
    'movimiento_id', v_id,
    'tipo',          p_tipo,
    'monto',         round(p_monto, 2),
    'autorizo',      aut->>'nombre',
    'en_gaveta',     app.efectivo_esperado(p_turno_id));
end $fn$;

revoke execute on function fn_movimiento_caja(uuid, text, numeric, text, text, text, jsonb)
  from public, anon;
grant execute on function fn_movimiento_caja(uuid, text, numeric, text, text, text, jsonb)
  to authenticated;


-- ---------------------------------------------------------------------------
-- 5. Arqueo con desglose
--
-- Sigue siendo a ciegas: se manda lo contado y la función responde la
-- diferencia. El desglose no cambia eso, solo deja por escrito de qué estaba
-- hecho ese contado.
-- ---------------------------------------------------------------------------
create or replace function fn_arqueo_caja(
  p_turno_id uuid,
  p_contado  numeric,
  p_codigo   text,
  p_pin      text,
  p_motivo   text default null,
  p_detalle  jsonb default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  t         record;
  aut       jsonb;
  v_esperado numeric;
  v_dif     numeric;
  v_id      uuid;
  v_mal     text;
begin
  if p_contado is null or p_contado < 0 then
    raise exception 'Ponga cuanto se conto en la gaveta';
  end if;

  select * into t from turnos_caja
   where id = p_turno_id and organizacion_id = app.org_id();
  if t.id is null then raise exception 'Ese turno no es de su negocio'; end if;
  if t.estado <> 'abierto' then raise exception 'Ese turno ya se cerro'; end if;

  v_mal := app.detalle_reclamo(p_detalle, p_contado, t.organizacion_id);
  if v_mal is not null then raise exception '%', v_mal; end if;

  aut := app.quien_autoriza(p_codigo, p_pin, 'supervisor');
  if not (aut->>'ok')::boolean then return aut; end if;

  if not app.es_admin() and t.sucursal_id not in (select app.sucursales_permitidas()) then
    raise exception 'No tiene acceso a esa sucursal';
  end if;

  v_esperado := app.efectivo_esperado(p_turno_id);
  v_dif := round(p_contado - v_esperado, 2);

  insert into movimientos_caja (organizacion_id, sucursal_id, caja_id, turno_id,
                                tipo, monto, esperado, diferencia, motivo, autorizo,
                                detalle)
  values (t.organizacion_id, t.sucursal_id, t.caja_id, p_turno_id,
          'arqueo', round(p_contado, 2), v_esperado, v_dif,
          nullif(btrim(p_motivo), ''), (aut->>'perfil_id')::uuid, p_detalle)
  returning id into v_id;

  return jsonb_build_object(
    'ok',         true,
    'arqueo_id',  v_id,
    'contado',    round(p_contado, 2),
    'esperado',   v_esperado,
    'diferencia', v_dif,
    'autorizo',   aut->>'nombre',
    'cuando',     now());
end $fn$;

revoke execute on function fn_arqueo_caja(uuid, numeric, text, text, text, jsonb)
  from public, anon;
grant execute on function fn_arqueo_caja(uuid, numeric, text, text, text, jsonb)
  to authenticated;


-- ---------------------------------------------------------------------------
-- 6. Cierre con desglose
-- ---------------------------------------------------------------------------
create or replace function fn_cerrar_turno_con_arqueo(
  p_turno_id        uuid,
  p_monto_declarado numeric,
  p_codigo          text,
  p_pin             text,
  p_notas           text default null,
  p_detalle         jsonb default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  t          record;
  aut        jsonb;
  v_esperado numeric;
  v_ventas   numeric;
  v_abonos   numeric;
  v_devol    numeric;
  v_fondo    numeric;
  v_retiro   numeric;
  v_mal      text;
begin
  if p_monto_declarado is null or p_monto_declarado < 0 then
    raise exception 'Ponga cuanto se conto en la gaveta';
  end if;

  select * into t from turnos_caja
   where id = p_turno_id and organizacion_id = app.org_id() for update;
  if t.id is null then raise exception 'Ese turno no es de su negocio'; end if;
  if t.estado <> 'abierto' then raise exception 'Ese turno ya se cerro'; end if;

  v_mal := app.detalle_reclamo(p_detalle, p_monto_declarado, t.organizacion_id);
  if v_mal is not null then raise exception '%', v_mal; end if;

  aut := app.quien_autoriza(p_codigo, p_pin, 'supervisor');
  if not (aut->>'ok')::boolean then return aut; end if;

  if not app.es_admin() and t.sucursal_id not in (select app.sucursales_permitidas()) then
    raise exception 'No tiene acceso a esa sucursal';
  end if;

  v_esperado := app.efectivo_esperado(p_turno_id);

  select coalesce(sum(pv.monto), 0) into v_ventas
  from pagos_venta pv join ventas ve on ve.id = pv.venta_id
  where ve.turno_id = p_turno_id and ve.estado = 'completada' and pv.metodo = 'efectivo';

  select coalesce(sum(ab.monto), 0) into v_abonos
  from abonos_cliente ab
  where ab.turno_id = p_turno_id and not ab.anulado and ab.metodo = 'efectivo';

  select coalesce(sum(dv.reembolso), 0) into v_devol
  from devoluciones_venta dv
  where dv.turno_id = p_turno_id and dv.reembolso_metodo = 'efectivo';

  select coalesce(sum(m.monto) filter (where m.tipo = 'fondo'), 0),
         coalesce(sum(m.monto) filter (where m.tipo = 'retiro'), 0)
    into v_fondo, v_retiro
  from movimientos_caja m where m.turno_id = p_turno_id;

  update turnos_caja
     set estado = 'cerrado', cerrado_en = now(), cerrado_por = (aut->>'perfil_id')::uuid,
         monto_declarado = round(p_monto_declarado, 2),
         monto_esperado  = v_esperado,
         diferencia      = round(p_monto_declarado - v_esperado, 2),
         notas           = nullif(btrim(p_notas), ''),
         detalle_cierre  = p_detalle
   where id = p_turno_id;

  update caja_desbloqueos set consumido_en = now()
   where turno_id = p_turno_id and consumido_en is null;

  return jsonb_build_object(
    'ok',              true,
    'monto_inicial',   t.monto_inicial,
    'efectivo_ventas', v_ventas,
    'abonos_fiado',    v_abonos,
    'fondos',          v_fondo,
    'retiros',         v_retiro,
    'devoluciones',    v_devol,
    'esperado',        v_esperado,
    'declarado',       round(p_monto_declarado, 2),
    'diferencia',      round(p_monto_declarado - v_esperado, 2),
    'cerro',           aut->>'nombre');
end $fn$;

revoke execute on function fn_cerrar_turno_con_arqueo(uuid, numeric, text, text, text, jsonb)
  from public, anon;
grant execute on function fn_cerrar_turno_con_arqueo(uuid, numeric, text, text, text, jsonb)
  to authenticated;


-- ---------------------------------------------------------------------------
-- 7. Ver el desglose de un movimiento
--
-- Aparte y no dentro de fn_movimientos_turno a propósito: agregarle una
-- columna a esa función cambiaría su tipo de retorno, y eso en Postgres exige
-- soltarla. Una función nueva no rompe nada y se pide solo cuando alguien
-- abre un movimiento a mirarlo.
--
-- Lleva el mismo candado que fn_movimientos_turno: la diferencia solo la ve
-- un supervisor, o el arqueo deja de ser sorpresa para la cajera.
-- ---------------------------------------------------------------------------
create or replace function fn_detalle_movimiento(p_movimiento_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  m record;
begin
  select * into m from movimientos_caja where id = p_movimiento_id;
  if m.id is null then raise exception 'Ese movimiento no existe'; end if;
  if not (app.es_admin()
          or (m.organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))) then
    raise exception 'Ese movimiento no es de su negocio';
  end if;

  return jsonb_build_object(
    'movimiento_id', m.id,
    'tipo',          m.tipo,
    'monto',         m.monto,
    'detalle',       m.detalle,
    'diferencia',    case when app.es_admin() or app.tiene_nivel('supervisor')
                          then m.diferencia end);
end $fn$;

revoke execute on function fn_detalle_movimiento(uuid) from public, anon;
grant  execute on function fn_detalle_movimiento(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 8. Las denominaciones, alcanzables desde el navegador
--
-- PostgREST solo publica el esquema public. Dice tambien si son las de por
-- defecto, para que Configuracion pueda enseñar "sin configurar" en vez de
-- hacer creer que alguien eligio esa lista.
-- ---------------------------------------------------------------------------
create or replace function fn_denominaciones()
returns jsonb
language sql stable security definer set search_path = public, app as $fn$
  select jsonb_build_object(
    'denominaciones', to_jsonb(app.denominaciones()),
    'por_defecto', not exists (
      select 1 from organizaciones o
       where o.id = app.org_id()
         and jsonb_typeof(o.config->'denominaciones') = 'array'))
   where app.tiene_nivel('auxiliar') or app.es_admin()
$fn$;

revoke execute on function fn_denominaciones() from public, anon;
grant  execute on function fn_denominaciones() to authenticated;

notify pgrst, 'reload schema';
