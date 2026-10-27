-- ============================================================================
--  Migración 034 · La cajera entra con su código y su PIN
--
--  Hasta aquí, para abrir una pantalla había que escribir correo y contraseña.
--  En el mostrador eso no sirve: la cajera entra, sale, la releva otra, y
--  nadie va a teclear "maria.hernandez@..." con la fila esperando.
--
--  Entonces la caja tiene su propia puerta: código corto y PIN. Pero esa
--  puerta da a internet, y un PIN de cinco dígitos de cara al mundo son cien
--  mil combinaciones: un programa las prueba todas en un rato.
--
--  EL APARATO ES EL SEGUNDO CANDADO
--
--  El gerente parea una vez la tablet con una sucursal y una caja. La tablet
--  guarda una llave larga, al azar, que no se parece a nada que se adivine.
--  Esa llave NO es una sesión y NO lee nada: lo único que da es el derecho a
--  intentar un PIN en esa tienda. Quien no tenga una tablet pareada no puede
--  ni tocar la puerta.
--
--  Lo que eso compra:
--    · la tablet no queda conectada: la cajera marca su PIN cada vez
--    · si se pierde la tablet, el gerente le revoca la llave y queda muerta
--    · el PIN sigue siendo corto, que es lo que lo hace usable
--
--  POR QUÉ ESTA FUNCIÓN RESPONDE EN VEZ DE LANZAR
--
--  Igual que app.quien_autoriza en la 033: al lanzar una excepción, Postgres
--  deshace todo lo que la función escribió, el contador de intentos fallidos
--  incluido, y el bloqueo a los cinco intentos no se cumple nunca. Para que
--  el contador sobreviva, la función tiene que TERMINAR BIEN.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Los aparatos pareados
--
-- La llave se guarda hasheada, como una contraseña. Se enseña UNA sola vez,
-- al parear; después ni el gerente puede volver a verla. Si se pierde, se
-- revoca el aparato y se parea de nuevo.
-- ---------------------------------------------------------------------------
create table if not exists aparatos_caja (
  id                 uuid primary key default gen_random_uuid(),
  organizacion_id    uuid not null references organizaciones(id) on delete cascade,
  sucursal_id        uuid not null references sucursales(id) on delete cascade,
  caja_id            uuid references cajas(id) on delete set null,
  nombre             text not null,
  llave_pos          text not null,
  activo             boolean not null default true,
  -- Contra quien se robe la tablet y se ponga a probar códigos: el aparato
  -- entero se bloquea, no solo el perfil que se intentó.
  intentos_fallidos  int not null default 0,
  bloqueado_hasta    timestamptz,
  ultimo_uso         timestamptz,
  creado_por         uuid references perfiles(id) on delete set null,
  creado_en          timestamptz not null default now()
);

create index if not exists ix_aparatos_org
  on aparatos_caja (organizacion_id, activo);

alter table aparatos_caja enable row level security;

-- Solo de lectura, y solo para quien manda en el negocio. La columna de la
-- llave no se lee nunca desde el navegador: para eso está la vista de abajo.
drop policy if exists aparatos_sel on aparatos_caja;
create policy aparatos_sel on aparatos_caja for select
  to authenticated
  using (organizacion_id = app.org_id() and app.tiene_nivel('gerente'));

-- Nadie escribe a mano: todo pasa por las funciones de abajo.
revoke insert, update, delete on aparatos_caja from authenticated;


-- ---------------------------------------------------------------------------
-- 2. Parear un aparato
--
-- Devuelve la llave en claro UNA vez. De ahí en adelante solo vive en la
-- tablet.
-- ---------------------------------------------------------------------------
create or replace function fn_parear_aparato(
  p_sucursal_id uuid,
  p_caja_id     uuid default null,
  p_nombre      text default null
) returns jsonb
language plpgsql security definer set search_path = public, app, extensions as $fn$
declare
  v_org    uuid := app.org_id();
  v_llave  text;
  v_id     uuid;
  v_nombre text;
begin
  if v_org is null then raise exception 'Sesion sin negocio'; end if;
  if not app.tiene_nivel('gerente') then
    raise exception 'Solo un gerente puede parear un aparato';
  end if;

  -- tiene_nivel solo dice de qué rango es quien llama, no de qué negocio es
  -- la sucursal que mandó. Sin esta línea, un gerente parea una tablet en la
  -- pulpería de la competencia.
  if not exists (select 1 from sucursales
                  where id = p_sucursal_id and organizacion_id = v_org) then
    raise exception 'Esa sucursal no es de su negocio';
  end if;

  if p_caja_id is not null
     and not exists (select 1 from cajas
                      where id = p_caja_id
                        and organizacion_id = v_org
                        and sucursal_id = p_sucursal_id) then
    raise exception 'Esa caja no es de esa sucursal';
  end if;

  v_nombre := nullif(btrim(coalesce(p_nombre, '')), '');
  if v_nombre is null then v_nombre := 'Aparato de caja'; end if;
  if length(v_nombre) > 60 then
    raise exception 'El nombre del aparato es muy largo';
  end if;

  -- 24 bytes al azar: no se adivina ni probando.
  v_llave := encode(gen_random_bytes(24), 'hex');

  insert into aparatos_caja (organizacion_id, sucursal_id, caja_id, nombre,
                             llave_pos, creado_por)
  values (v_org, p_sucursal_id, p_caja_id, v_nombre,
          crypt(v_llave, gen_salt('bf')), auth.uid())
  returning id into v_id;

  return jsonb_build_object('aparato_id', v_id, 'nombre', v_nombre,
                            'llave', v_llave);
end $fn$;

revoke execute on function fn_parear_aparato(uuid, uuid, text) from public, anon;
grant  execute on function fn_parear_aparato(uuid, uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 3. Ver y revocar
-- ---------------------------------------------------------------------------
create or replace function fn_aparatos_caja()
returns table (
  aparato_id      uuid,
  nombre          text,
  sucursal        text,
  caja            text,
  activo          boolean,
  bloqueado_hasta timestamptz,
  ultimo_uso      timestamptz,
  creado_en       timestamptz
)
language sql stable security definer set search_path = public, app as $fn$
  select a.id, a.nombre, s.nombre, c.nombre, a.activo,
         a.bloqueado_hasta, a.ultimo_uso, a.creado_en
    from aparatos_caja a
    join sucursales s on s.id = a.sucursal_id
    left join cajas c on c.id = a.caja_id
   where a.organizacion_id = app.org_id()
     and app.tiene_nivel('gerente')
   order by a.activo desc, a.creado_en desc;
$fn$;

revoke execute on function fn_aparatos_caja() from public, anon;
grant  execute on function fn_aparatos_caja() to authenticated;


create or replace function fn_revocar_aparato(p_aparato_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  v_org uuid := app.org_id();
  v_nom text;
begin
  if v_org is null then raise exception 'Sesion sin negocio'; end if;
  if not app.tiene_nivel('gerente') then
    raise exception 'Solo un gerente puede revocar un aparato';
  end if;

  -- Otra vez: el rango no dice de qué negocio es el aparato.
  update aparatos_caja set activo = false
   where id = p_aparato_id and organizacion_id = v_org
  returning nombre into v_nom;

  if v_nom is null then raise exception 'Ese aparato no es de su negocio'; end if;
  return jsonb_build_object('aparato_id', p_aparato_id, 'nombre', v_nom);
end $fn$;

revoke execute on function fn_revocar_aparato(uuid) from public, anon;
grant  execute on function fn_revocar_aparato(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. La entrada
--
-- Esta es la única función del sistema que trabaja SIN sesión: la cajera
-- todavía no tiene ninguna, justamente está pidiendo una. Por eso:
--
--   · no llama a app.org_id(): el negocio sale del aparato, no de quien pide
--   · solo service_role puede ejecutarla, o sea solo la función de borde
--   · responde {ok:false, error} y nunca lanza, para no deshacer el contador
--
-- Lo que devuelve no es una sesión: es el permiso para que la función de
-- borde acuñe una. Ahí vive la llave de servicio, no aquí.
-- ---------------------------------------------------------------------------
create or replace function app.entrada_de_caja(
  p_aparato uuid,
  p_llave   text,
  p_codigo  text,
  p_pin     text
) returns jsonb
language plpgsql security definer set search_path = public, app, extensions as $fn$
declare
  ap aparatos_caja;
  p  perfiles;
begin
  if p_aparato is null or coalesce(btrim(p_llave), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'aparato',
      'mensaje', 'Este aparato no esta pareado con ninguna caja');
  end if;

  select * into ap from aparatos_caja where id = p_aparato;

  -- Aparato desconocido y llave mala dan la misma respuesta: distinguirlos
  -- le diría al que prueba cuáles identificadores existen.
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

  -- Mismo mensaje si el código no existe o si el PIN está mal.
  if p.id is null
     or (p.pin_bloqueado_hasta is not null and p.pin_bloqueado_hasta > now())
     or p.pin_pos is null
     or p.pin_pos <> crypt(p_pin, p.pin_pos) then

    -- El intento falla contra el aparato siempre: así, quien se robe la
    -- tablet y vaya probando código por código se queda sin aparato antes
    -- de dejar a todo el personal bloqueado.
    update aparatos_caja
       set intentos_fallidos = intentos_fallidos + 1,
           bloqueado_hasta = case when intentos_fallidos + 1 >= 10
                                  then now() + interval '10 minutes' end
     where id = ap.id;

    -- Y contra el perfil solo si el código existe, que es lo que ya hacía
    -- quien_autoriza.
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

  -- Un repartidor no atiende caja. El nivel se revisa después de dar por
  -- buena la credencial: aquí ya se sabe quién es.
  if app.nivel_rol(p.rol) < app.nivel_rol('auxiliar') then
    return jsonb_build_object('ok', false, 'error', 'permiso',
      'mensaje', p.nombre || ' no atiende caja');
  end if;

  if p.email is null then
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
    'email', p.email,
    'nombre', p.nombre,
    'rol', p.rol,
    'organizacion_id', ap.organizacion_id,
    'sucursal_id', ap.sucursal_id,
    'caja_id', ap.caja_id);
end $fn$;

-- authenticated tampoco: quien ya tiene sesión no necesita esta puerta, y
-- dejarla abierta le regalaría un oráculo para probar PINes ajenos.
revoke execute on function app.entrada_de_caja(uuid, text, text, text)
  from public, anon, authenticated;
grant  execute on function app.entrada_de_caja(uuid, text, text, text)
  to service_role;


-- ---------------------------------------------------------------------------
-- 5. La misma puerta, alcanzable
--
-- PostgREST solo publica el esquema public, así que la función de borde no
-- puede llamar app.entrada_de_caja directamente. Esta envoltura no decide
-- nada: solo la hace alcanzable, y con los mismos permisos.
-- ---------------------------------------------------------------------------
create or replace function fn_entrar_caja(
  p_aparato uuid,
  p_llave   text,
  p_codigo  text,
  p_pin     text
) returns jsonb
language sql security definer set search_path = public, app as $fn$
  select app.entrada_de_caja(p_aparato, p_llave, p_codigo, p_pin)
$fn$;

revoke execute on function fn_entrar_caja(uuid, text, text, text)
  from public, anon, authenticated;
grant  execute on function fn_entrar_caja(uuid, text, text, text)
  to service_role;
