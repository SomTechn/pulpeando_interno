-- ============================================================================
--  Migración 037 · Un cajero, una caja
--
--  Ya existía "una caja, un turno abierto" (ux_turno_abierto). Faltaba lo
--  inverso: un cajero con turno abierto en la Caja 1 podía abrir otro en la
--  Caja 2, y entonces el efectivo de los dos turnos era de la misma persona
--  en dos gavetas. Ningún arqueo cuadra así.
--
--  Tres cosas:
--
--    1. el índice que lo hace imposible, no solo improbable
--    2. fn_abrir_turno con mensajes que se entienden, y con dos huecos
--       tapados (ver abajo)
--    3. la entrada a /caja rechaza al cajero que tiene turno en OTRA caja:
--       la tablet de la Caja 2 no le abre sesión si su turno está en la 1
-- ============================================================================

create unique index if not exists ux_cajero_un_turno
  on turnos_caja (cajero_id) where estado = 'abierto';


-- ---------------------------------------------------------------------------
-- fn_abrir_turno
--
-- Dos huecos que tenía desde la 002b:
--
--   · No revisaba que la caja fuera del negocio de quien llama. Es el
--     problema de siempre: el PIN dice quién es el cajero, pero no de qué
--     negocio es la caja que mandó.
--   · El PIN malo sumaba el intento fallido y enseguida lanzaba el error, y
--     Postgres deshace todo lo que la función escribió: el contador volvía a
--     cero y los cinco intentos no se cumplían nunca.
--
-- Para no deshacer el contador, el PIN malo ya no lanza: devuelve null. La
-- pantalla lo lee como "PIN incorrecto". El tipo de retorno no cambia (sigue
-- siendo uuid), así que no hace falta soltar la función.
-- ---------------------------------------------------------------------------
create or replace function fn_abrir_turno(
  p_caja_id uuid, p_cajero_id uuid, p_pin text, p_monto_inicial numeric default 0
) returns uuid
language plpgsql security definer set search_path = public, app, extensions as $fn$
declare
  c    record;
  p    record;
  t    record;
  v_id uuid;
begin
  select * into c from cajas where id = p_caja_id and activa;
  if c.id is null then
    raise exception 'Caja inexistente o desactivada';
  end if;
  if c.organizacion_id <> app.org_id() and not app.es_admin() then
    raise exception 'Esa caja no es de su negocio';
  end if;

  -- Cada quien abre su propio turno. Un supervisor puede abrirlo a nombre
  -- de otro, que es lo que pasa cuando la cajera llega y el supervisor ya
  -- está en la caja.
  if p_cajero_id <> auth.uid() and not app.tiene_nivel('supervisor') then
    raise exception 'Cada cajero abre su propio turno';
  end if;

  select * into p from perfiles where id = p_cajero_id and activo;
  if p.id is null or p.organizacion_id <> c.organizacion_id then
    raise exception 'Cajero inexistente';
  end if;
  if app.nivel_rol(p.rol) < 1 then
    raise exception 'Este usuario no tiene permiso para operar caja';
  end if;
  if p.pin_pos is null then
    raise exception 'El cajero no tiene PIN asignado';
  end if;

  select tc.id, cj.nombre as caja into t
    from turnos_caja tc join cajas cj on cj.id = tc.caja_id
   where tc.cajero_id = p.id and tc.estado = 'abierto';
  if t.id is not null then
    raise exception '% ya tiene el turno abierto en %. Ciérrelo allá primero', p.nombre, t.caja;
  end if;

  if exists (select 1 from turnos_caja where caja_id = c.id and estado = 'abierto') then
    raise exception '% ya tiene un turno abierto', c.nombre;
  end if;

  if p.pin_bloqueado_hasta is not null and p.pin_bloqueado_hasta > now() then
    raise exception 'PIN bloqueado por intentos fallidos. Intente de nuevo más tarde';
  end if;

  if p.pin_pos <> crypt(p_pin, p.pin_pos) then
    update perfiles
       set pin_intentos_fallidos = pin_intentos_fallidos + 1,
           pin_bloqueado_hasta = case when pin_intentos_fallidos + 1 >= 5
                                      then now() + interval '5 minutes' end
     where id = p_cajero_id;
    insert into intentos_pin (organizacion_id, perfil_id, exitoso)
    values (c.organizacion_id, p_cajero_id, false);
    return null;   -- PIN incorrecto. Se devuelve para que el contador quede.
  end if;

  update perfiles set pin_intentos_fallidos = 0, pin_bloqueado_hasta = null
   where id = p_cajero_id;

  insert into turnos_caja (organizacion_id, sucursal_id, caja_id, cajero_id, monto_inicial)
  values (c.organizacion_id, c.sucursal_id, c.id, p_cajero_id, coalesce(p_monto_inicial, 0))
  returning id into v_id;

  insert into intentos_pin (organizacion_id, perfil_id, turno_id, exitoso)
  values (c.organizacion_id, p_cajero_id, v_id, true);

  return v_id;
end $fn$;

revoke execute on function fn_abrir_turno(uuid, uuid, text, numeric) from public, anon;
grant  execute on function fn_abrir_turno(uuid, uuid, text, numeric) to authenticated;


-- ---------------------------------------------------------------------------
-- La entrada a /caja: si el cajero ya tiene turno en otra caja, esta tablet
-- no le abre sesión. Se revisa DESPUÉS de dar por buena la credencial: aquí
-- ya se sabe quién es, y decirle dónde está su turno no regala nada.
-- ---------------------------------------------------------------------------
create or replace function app.entrada_de_caja(
  p_aparato uuid,
  p_llave   text,
  p_codigo  text,
  p_pin     text
) returns jsonb
language plpgsql security definer set search_path = public, app, extensions as $fn$
declare
  ap      aparatos_caja;
  p       perfiles;
  v_email text;
  v_otra  text;
begin
  if p_aparato is null or coalesce(btrim(p_llave), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'aparato',
      'mensaje', 'Este aparato no esta pareado con ninguna caja');
  end if;

  select * into ap from aparatos_caja where id = p_aparato;

  if ap.id is null or not ap.activo
     or ap.llave_pos is null or ap.llave_pos <> crypt(p_llave, ap.llave_pos) then
    return jsonb_build_object('ok', false, 'error', 'aparato',
      'mensaje', 'Este aparato ya no tiene permiso para abrir caja');
  end if;

  if ap.bloqueado_hasta is not null and ap.bloqueado_hasta > now() then
    return jsonb_build_object('ok', false, 'error', 'aparato_bloqueado',
      'mensaje', 'Demasiados intentos en este aparato. Espere unos minutos');
  end if;

  if coalesce(btrim(p_codigo), '') = '' or coalesce(btrim(p_pin), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'credencial',
      'mensaje', 'Hace falta el codigo y el PIN');
  end if;

  select * into p from perfiles
   where organizacion_id = ap.organizacion_id
     and codigo is not null
     and upper(codigo) = upper(btrim(p_codigo))
     and activo;

  if p.id is null
     or (p.pin_bloqueado_hasta is not null and p.pin_bloqueado_hasta > now())
     or p.pin_pos is null
     or p.pin_pos <> crypt(p_pin, p.pin_pos) then

    update aparatos_caja
       set intentos_fallidos = intentos_fallidos + 1,
           bloqueado_hasta = case when intentos_fallidos + 1 >= 10
                                  then now() + interval '10 minutes' end
     where id = ap.id;

    if p.id is not null then
      update perfiles
         set pin_intentos_fallidos = pin_intentos_fallidos + 1,
             pin_bloqueado_hasta = case when pin_intentos_fallidos + 1 >= 5
                                        then now() + interval '5 minutes' end
       where id = p.id;
      insert into intentos_pin (organizacion_id, perfil_id, exitoso)
      values (ap.organizacion_id, p.id, false);
    end if;

    return jsonb_build_object('ok', false, 'error', 'credencial',
      'mensaje', 'Codigo o PIN incorrecto');
  end if;

  if app.nivel_rol(p.rol) < app.nivel_rol('auxiliar') then
    return jsonb_build_object('ok', false, 'error', 'permiso',
      'mensaje', p.nombre || ' no atiende caja');
  end if;

  -- Un cajero, una caja.
  if ap.caja_id is not null then
    select cj.nombre into v_otra
      from turnos_caja tc join cajas cj on cj.id = tc.caja_id
     where tc.cajero_id = p.id and tc.estado = 'abierto' and tc.caja_id <> ap.caja_id;
    if v_otra is not null then
      return jsonb_build_object('ok', false, 'error', 'otra_caja',
        'mensaje', p.nombre || ' tiene el turno abierto en ' || v_otra
                   || '. Cierrelo alla primero');
    end if;
  end if;

  -- El correo sale de la cuenta de acceso: perfiles.email puede estar vacio
  -- en un perfil hecho a mano aunque la cuenta tenga correo.
  select u.email into v_email from auth.users u where u.id = p.id;
  if v_email is null then
    return jsonb_build_object('ok', false, 'error', 'sin_correo',
      'mensaje', p.nombre || ' no tiene correo y no puede abrir sesion');
  end if;

  update aparatos_caja
     set intentos_fallidos = 0, bloqueado_hasta = null, ultimo_uso = now()
   where id = ap.id;
  update perfiles set pin_intentos_fallidos = 0, pin_bloqueado_hasta = null
   where id = p.id;
  insert into intentos_pin (organizacion_id, perfil_id, exitoso)
  values (ap.organizacion_id, p.id, true);

  return jsonb_build_object(
    'ok', true,
    'perfil_id', p.id,
    'email', v_email,
    'nombre', p.nombre,
    'rol', p.rol,
    'organizacion_id', ap.organizacion_id,
    'sucursal_id', ap.sucursal_id,
    'caja_id', ap.caja_id);
end $fn$;

revoke execute on function app.entrada_de_caja(uuid, text, text, text)
  from public, anon, authenticated;
grant  execute on function app.entrada_de_caja(uuid, text, text, text)
  to service_role;

notify pgrst, 'reload schema';
