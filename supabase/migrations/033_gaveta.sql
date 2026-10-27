-- ===========================================================================
-- 033 · La gaveta: arqueo sorpresivo, fondo, retiro y cierre
--
-- Hasta hoy el turno solo tenía monto_inicial al abrir y monto_declarado al
-- cerrar. En el mostrador pasan más cosas:
--
--   fondo    entra cambio (sencillo) a media mañana porque se acabó
--   retiro   el gerente saca el grueso del efectivo y lo guarda
--   arqueo   el supervisor llega sin avisar y cuenta la gaveta
--
-- Las tres las hace un supervisor o un gerente, y las autoriza con su CÓDIGO
-- y su PIN parado frente a la caja: no se va a su computadora a firmar algo.
-- Por eso el código de perfil nace aquí, aunque también lo va a usar la
-- cajera para entrar cuando la caja sea su propio link.
--
-- UNA SOLA FÓRMULA para el efectivo esperado, en app.efectivo_esperado(). El
-- arqueo y el cierre tienen que dar lo mismo; con dos cuentas escritas aparte
-- se separan en silencio y nadie sabe cuál creer.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Código de perfil
--
-- Corto, para teclearlo en el mostrador sin mirar. Único dentro del negocio,
-- no en todo el sistema: dos pulperías pueden tener su "01".
-- ---------------------------------------------------------------------------
alter table perfiles add column if not exists codigo text;

create unique index if not exists ux_perfil_codigo
  on perfiles (organizacion_id, upper(codigo)) where codigo is not null;

-- ---------------------------------------------------------------------------
-- 2. Quién autoriza
--
-- Se exige código Y pin. Solo con el PIN, cinco dígitos contra todos los
-- perfiles del negocio es un candado que se abre probando.
--
-- RESPONDE, no lanza. Y es a propósito:
--
--   El bloqueo por intentos fallidos NUNCA funcionó en este sistema. La
--   función sumaba el intento y enseguida lanzaba el error; en Postgres eso
--   deshace todo lo que la función escribió, contador incluido. Volvía a
--   cero cada vez y los cinco intentos no se cumplían nunca. Está así en
--   fn_desbloquear_caja desde la 002b.
--
--   Para que el contador sobreviva, la función tiene que TERMINAR BIEN. Por
--   eso devuelve {ok:false, error} en vez de lanzar, y quien la llama corta
--   ahí antes de escribir nada.
-- ---------------------------------------------------------------------------
create or replace function app.quien_autoriza(
  p_codigo text,
  p_pin    text,
  p_minimo rol_usuario default 'supervisor'
) returns jsonb
language plpgsql security definer set search_path = public, app, extensions as $fn$
declare
  v_org uuid;
  p     perfiles;
begin
  v_org := app.org_id();
  if v_org is null then raise exception 'Sesion sin negocio'; end if;

  if coalesce(btrim(p_codigo), '') = '' or coalesce(btrim(p_pin), '') = '' then
    return jsonb_build_object('ok', false,
      'error', 'Hace falta el codigo y el PIN de quien autoriza');
  end if;

  select * into p from perfiles
   where organizacion_id = v_org
     and codigo is not null
     and upper(codigo) = upper(btrim(p_codigo))
     and activo;

  -- Mismo mensaje si el código no existe o si el PIN está mal: decir cuál de
  -- los dos falló regala la mitad del candado.
  if p.id is null then
    return jsonb_build_object('ok', false, 'error', 'Codigo o PIN incorrecto');
  end if;

  if p.pin_bloqueado_hasta is not null and p.pin_bloqueado_hasta > now() then
    return jsonb_build_object('ok', false,
      'error', 'Ese PIN esta bloqueado por intentos fallidos. Espere unos minutos');
  end if;

  if p.pin_pos is null or p.pin_pos <> crypt(p_pin, p.pin_pos) then
    update perfiles
       set pin_intentos_fallidos = pin_intentos_fallidos + 1,
           pin_bloqueado_hasta = case when pin_intentos_fallidos + 1 >= 5
                                      then now() + interval '5 minutes' end
     where id = p.id;
    insert into intentos_pin (organizacion_id, perfil_id, exitoso)
    values (v_org, p.id, false);
    return jsonb_build_object('ok', false, 'error', 'Codigo o PIN incorrecto');
  end if;

  update perfiles set pin_intentos_fallidos = 0, pin_bloqueado_hasta = null
   where id = p.id;
  insert into intentos_pin (organizacion_id, perfil_id, exitoso)
  values (v_org, p.id, true);

  -- El nivel se revisa DESPUÉS de dar por buena la credencial: aquí ya se sabe
  -- quién es, así que decir su nombre no regala nada.
  if app.nivel_rol(p.rol) < app.nivel_rol(p_minimo) then
    return jsonb_build_object('ok', false,
      'error', p.nombre || ' no tiene permiso para autorizar esto');
  end if;

  return jsonb_build_object('ok', true, 'perfil_id', p.id, 'nombre', p.nombre,
                            'rol', p.rol);
end $fn$;

revoke execute on function app.quien_autoriza(text, text, rol_usuario) from public, anon;

-- ---------------------------------------------------------------------------
-- 3. Movimientos de gaveta
-- ---------------------------------------------------------------------------
do $$ begin
  if not exists (select 1 from pg_type where typname = 'tipo_movimiento_caja') then
    create type tipo_movimiento_caja as enum ('fondo', 'retiro', 'arqueo');
  end if;
end $$;

create table if not exists movimientos_caja (
  id               uuid primary key default gen_random_uuid(),
  organizacion_id  uuid not null references organizaciones(id) on delete cascade,
  sucursal_id      uuid not null references sucursales(id),
  caja_id          uuid not null references cajas(id),
  turno_id         uuid not null references turnos_caja(id) on delete cascade,
  tipo             tipo_movimiento_caja not null,
  -- fondo y retiro: lo que entra o sale. arqueo: lo que se contó.
  monto            numeric(16,4) not null check (monto > 0),
  -- solo arqueo, y se congela: lo que el sistema decía en ese momento
  esperado         numeric(16,4),
  diferencia       numeric(16,4),
  motivo           text,
  autorizo         uuid not null references perfiles(id),
  creado_en        timestamptz not null default now()
);

create index if not exists ix_mov_caja_turno on movimientos_caja (turno_id, creado_en);

alter table movimientos_caja enable row level security;

-- La politica se crea solo si falta, en vez de soltarla y rehacerla. Queda
-- igual de idempotente y deja de ser una sentencia destructiva, que es lo que
-- frena la herramienta de Supabase al aplicar migraciones.
do $pol$ begin
  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'movimientos_caja'
                    and policyname = 'mov_caja_ver') then
    execute $crea$create policy mov_caja_ver on movimientos_caja for select
      using (organizacion_id = app.org_id() and app.tiene_nivel('auxiliar'))$crea$;
  end if;
end $pol$;

revoke insert, update, delete on movimientos_caja from authenticated;
-- anon no lee, aunque RLS ya lo tape: Supabase concede el select por defecto.
revoke select on movimientos_caja from anon;

-- ---------------------------------------------------------------------------
-- 4. El efectivo esperado, en un solo lugar
--
--   lo que se puso al abrir
--   + lo que entró en efectivo (ventas y abonos de fiado)
--   + los fondos que metieron después
--   − lo que se devolvió en efectivo a clientes
--   − los retiros
--
-- El arqueo NO suma ni resta: solo deja constancia de lo que se contó.
-- ---------------------------------------------------------------------------
create or replace function app.efectivo_esperado(p_turno_id uuid)
returns numeric
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  t         record;
  v_ventas  numeric;
  v_abonos  numeric;
  v_devol   numeric;
  v_fondo   numeric;
  v_retiro  numeric;
begin
  select * into t from turnos_caja where id = p_turno_id;
  if t.id is null then raise exception 'Ese turno no existe'; end if;

  select coalesce(sum(pv.monto), 0) into v_ventas
  from pagos_venta pv
  join ventas ve on ve.id = pv.venta_id
  where ve.turno_id = p_turno_id and ve.estado = 'completada'
    and pv.metodo = 'efectivo';

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

  return round(t.monto_inicial + v_ventas + v_abonos + v_fondo - v_devol - v_retiro, 2);
end $fn$;

revoke execute on function app.efectivo_esperado(uuid) from public, anon;

-- ---------------------------------------------------------------------------
-- 5. Meter fondo o sacar un retiro
-- ---------------------------------------------------------------------------
create or replace function fn_movimiento_caja(
  p_turno_id uuid,
  p_tipo     text,
  p_monto    numeric,
  p_codigo   text,
  p_pin      text,
  p_motivo   text default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  t        record;
  aut      jsonb;
  v_antes  numeric;
  v_id     uuid;
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

  -- Si la credencial falla se SALE devolviendo, no lanzando: así el intento
  -- fallido queda contado (ver app.quien_autoriza).
  aut := app.quien_autoriza(p_codigo, p_pin, 'supervisor');
  if not (aut->>'ok')::boolean then return aut; end if;

  if not app.es_admin() and t.sucursal_id not in (select app.sucursales_permitidas()) then
    raise exception 'No tiene acceso a esa sucursal';
  end if;

  v_antes := app.efectivo_esperado(p_turno_id);

  -- No se puede sacar lo que no hay en la gaveta.
  if p_tipo = 'retiro' and p_monto > v_antes then
    raise exception 'En la gaveta el sistema solo cuenta con %, no se pueden retirar %',
      round(v_antes, 2), round(p_monto, 2);
  end if;

  insert into movimientos_caja (organizacion_id, sucursal_id, caja_id, turno_id,
                                tipo, monto, motivo, autorizo)
  values (t.organizacion_id, t.sucursal_id, t.caja_id, p_turno_id,
          p_tipo::tipo_movimiento_caja, round(p_monto, 2),
          nullif(btrim(p_motivo), ''), (aut->>'perfil_id')::uuid)
  returning id into v_id;

  return jsonb_build_object(
    'ok',            true,
    'movimiento_id', v_id,
    'tipo',          p_tipo,
    'monto',         round(p_monto, 2),
    'autorizo',      aut->>'nombre',
    'en_gaveta',     app.efectivo_esperado(p_turno_id));
end $fn$;

revoke execute on function fn_movimiento_caja(uuid, text, numeric, text, text, text)
  from public, anon;
grant execute on function fn_movimiento_caja(uuid, text, numeric, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Arqueo sorpresivo
--
-- Se manda lo CONTADO y la función responde la diferencia. A propósito no hay
-- forma de preguntar antes cuánto debería haber: un arqueo en el que el que
-- cuenta ya vio la respuesta no sirve de nada. Es la misma regla del conteo
-- de inventario.
--
-- El turno sigue abierto: esto no cierra nada ni corrige la gaveta.
-- ---------------------------------------------------------------------------
create or replace function fn_arqueo_caja(
  p_turno_id uuid,
  p_contado  numeric,
  p_codigo   text,
  p_pin      text,
  p_motivo   text default null
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  t         record;
  aut       jsonb;
  v_esperado numeric;
  v_dif     numeric;
  v_id      uuid;
begin
  if p_contado is null or p_contado < 0 then
    raise exception 'Ponga cuanto se conto en la gaveta';
  end if;

  select * into t from turnos_caja
   where id = p_turno_id and organizacion_id = app.org_id();
  if t.id is null then raise exception 'Ese turno no es de su negocio'; end if;
  if t.estado <> 'abierto' then raise exception 'Ese turno ya se cerro'; end if;

  aut := app.quien_autoriza(p_codigo, p_pin, 'supervisor');
  if not (aut->>'ok')::boolean then return aut; end if;

  if not app.es_admin() and t.sucursal_id not in (select app.sucursales_permitidas()) then
    raise exception 'No tiene acceso a esa sucursal';
  end if;

  v_esperado := app.efectivo_esperado(p_turno_id);
  v_dif := round(p_contado - v_esperado, 2);

  insert into movimientos_caja (organizacion_id, sucursal_id, caja_id, turno_id,
                                tipo, monto, esperado, diferencia, motivo, autorizo)
  values (t.organizacion_id, t.sucursal_id, t.caja_id, p_turno_id,
          'arqueo', round(p_contado, 2), v_esperado, v_dif,
          nullif(btrim(p_motivo), ''), (aut->>'perfil_id')::uuid)
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

revoke execute on function fn_arqueo_caja(uuid, numeric, text, text, text) from public, anon;
grant execute on function fn_arqueo_caja(uuid, numeric, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Lo que pasó en esta gaveta
--
-- El esperado NO va aquí: esta lista la puede abrir la cajera, y si le enseña
-- cuánto debería haber, el arqueo deja de ser sorpresa.
-- ---------------------------------------------------------------------------
create or replace function fn_movimientos_turno(p_turno_id uuid)
returns table (
  movimiento_id uuid,
  tipo          text,
  monto         numeric,
  diferencia    numeric,
  motivo        text,
  autorizo      text,
  cuando        timestamptz
)
language plpgsql stable security definer set search_path = public, app as $fn$
declare
  v_ve_dif boolean;
begin
  if not (app.es_admin() or app.tiene_nivel('auxiliar')) then
    raise exception 'No tiene permiso para ver la gaveta';
  end if;

  perform 1 from turnos_caja
   where id = p_turno_id and organizacion_id = app.org_id();
  if not found then raise exception 'Ese turno no es de su negocio'; end if;

  v_ve_dif := app.es_admin() or app.tiene_nivel('supervisor');

  return query
  select m.id, m.tipo::text, m.monto,
         case when v_ve_dif then m.diferencia end,
         m.motivo,
         (select pe.nombre from perfiles pe where pe.id = m.autorizo),
         m.creado_en
  from movimientos_caja m
  where m.turno_id = p_turno_id
  order by m.creado_en;
end $fn$;

revoke execute on function fn_movimientos_turno(uuid) from public, anon;
grant execute on function fn_movimientos_turno(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Cerrar el turno
--
-- Mismo contrato de antes más tres cosas: usa la fórmula compartida, cuenta
-- los fondos y retiros, y lo cierra un supervisor con su código y PIN. La
-- cajera cuenta y declara; quien cierra es otro.
--
-- Se crea con otro nombre porque cambiarle los parámetros a fn_cerrar_turno
-- dejaría dos versiones compitiendo. La vieja sigue viva para no romper lo
-- que ya la llama; esta es la que usa la caja nueva.
-- ---------------------------------------------------------------------------
create or replace function fn_cerrar_turno_con_arqueo(
  p_turno_id        uuid,
  p_monto_declarado numeric,
  p_codigo          text,
  p_pin             text,
  p_notas           text default null
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
begin
  if p_monto_declarado is null or p_monto_declarado < 0 then
    raise exception 'Ponga cuanto se conto en la gaveta';
  end if;

  select * into t from turnos_caja
   where id = p_turno_id and organizacion_id = app.org_id() for update;
  if t.id is null then raise exception 'Ese turno no es de su negocio'; end if;
  if t.estado <> 'abierto' then raise exception 'Ese turno ya se cerro'; end if;

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
         notas           = nullif(btrim(p_notas), '')
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

revoke execute on function fn_cerrar_turno_con_arqueo(uuid, numeric, text, text, text)
  from public, anon;
grant execute on function fn_cerrar_turno_con_arqueo(uuid, numeric, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 9. El viejo fn_cerrar_turno también cuenta fondos y retiros
--
-- Si no, cerrar por el camino de antes daría una diferencia inventada en
-- cuanto alguien meta fondo. Misma fórmula compartida.
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
  v_devol    numeric;
  v_fondo    numeric;
  v_retiro   numeric;
  v_esperado numeric;
begin
  select * into t from turnos_caja where id = p_turno_id for update;
  if t.id is null or t.estado <> 'abierto' then
    raise exception 'El turno no esta abierto';
  end if;

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

  v_esperado := round(t.monto_inicial + v_ventas + v_abonos + v_fondo - v_devol - v_retiro, 2);

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
    'fondos',          v_fondo,
    'retiros',         v_retiro,
    'devoluciones',    v_devol,
    'esperado',        v_esperado,
    'declarado',       p_monto_declarado,
    'diferencia',      p_monto_declarado - v_esperado);
end $fn$;

revoke execute on function fn_cerrar_turno(uuid, numeric, text) from public, anon;
grant execute on function fn_cerrar_turno(uuid, numeric, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 10. Poner el código a un perfil
--
-- Lo hace un gerente desde Catálogos. El código es del negocio, no global.
-- ---------------------------------------------------------------------------
create or replace function fn_fijar_codigo_perfil(p_perfil_id uuid, p_codigo text)
returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid;
  v_cod text;
  p     record;
begin
  v_org := app.org_id();
  if not (app.es_admin() or (v_org is not null and app.tiene_nivel('gerente'))) then
    raise exception 'Solo un gerente puede asignar el codigo';
  end if;

  select * into p from perfiles
   where id = p_perfil_id and (organizacion_id = v_org or app.es_admin());
  if p.id is null then raise exception 'Ese usuario no es de su negocio'; end if;

  v_cod := nullif(upper(btrim(p_codigo)), '');
  if v_cod is not null and length(v_cod) > 8 then
    raise exception 'El codigo es para teclearlo rapido: 8 caracteres como mucho';
  end if;
  if v_cod is not null and v_cod !~ '^[A-Z0-9]+$' then
    raise exception 'El codigo solo lleva letras y numeros';
  end if;

  if v_cod is not null and exists (
    select 1 from perfiles o
     where o.organizacion_id = p.organizacion_id
       and o.id <> p.id and upper(o.codigo) = v_cod) then
    raise exception 'Ya hay alguien con el codigo % en este negocio', v_cod;
  end if;

  update perfiles set codigo = v_cod, actualizado_en = now() where id = p.id;

  return jsonb_build_object('perfil_id', p.id, 'nombre', p.nombre, 'codigo', v_cod);
end $fn$;

revoke execute on function fn_fijar_codigo_perfil(uuid, text) from public, anon;
grant execute on function fn_fijar_codigo_perfil(uuid, text) to authenticated;
