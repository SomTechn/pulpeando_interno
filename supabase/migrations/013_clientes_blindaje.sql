-- ============================================================================
--  013 · El saldo y el limite de fiado dejan de ser editables desde el navegador
--
--  QUE ESTABA MAL
--
--  La politica clientes_esc es ALL para auxiliar en adelante, y con razon: la
--  cajera tiene que poder dar de alta a un cliente nuevo en el mostrador. Pero
--  ALL sobre la tabla es ALL sobre TODAS sus columnas, y en clientes viven dos
--  columnas de dinero:
--
--      saldo           lo que el cliente debe
--      limite_credito  hasta cuanto se le fia
--
--  Con la llave publishable y la sesion de una auxiliar, esto funcionaba:
--
--      update clientes set saldo = 0 where codigo = 'C001';
--      update clientes set limite_credito = 999999 where codigo = 'C001';
--
--  Probado: una deuda de L120 quedo en cero y el limite en L999,999, y despues
--  la misma caja fio L2,000 sin que fn_registrar_venta tuviera nada que objetar.
--  Todo el control de fiado de la migracion 012 se saltaba desde la consola del
--  navegador. Tambien se podia habilitarle fiado a un cliente al que el dueño
--  decidio no fiarle.
--
--  COMO SE CIERRA
--
--  Los permisos por columna de Postgres. La politica RLS sigue igual (la cajera
--  da de alta clientes), pero authenticated solo recibe insert/update sobre las
--  columnas descriptivas. saldo, limite_credito, puntos y usuario_id quedan
--  fuera: a saldo solo lo mueven fn_registrar_venta, fn_registrar_abono y
--  fn_anular_abono, que corren como dueñas de la funcion y por eso no las topa
--  el permiso por columna; al limite lo mueve fn_fijar_limite_credito, que pide
--  supervisor y deja constancia de quien lo fijo.
--
--  Tambien se quita el delete: borrar un cliente borraba su deuda. Para sacar a
--  alguien de la lista esta activo = false, que conserva el historial.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Quien fijo el limite. Cuando falta plata, esta es la primera pregunta.
-- ---------------------------------------------------------------------------

alter table clientes add column if not exists limite_fijado_por uuid references perfiles(id);
alter table clientes add column if not exists limite_fijado_en  timestamptz;


-- ---------------------------------------------------------------------------
-- 2. Permisos por columna
-- ---------------------------------------------------------------------------

revoke insert, update, delete on clientes from authenticated;

-- Lo que la cajera si puede escribir de un cliente
grant insert (organizacion_id, codigo, nombre, identificacion_fiscal,
              telefono, email, direccion, activo)
  on clientes to authenticated;

grant update (codigo, nombre, identificacion_fiscal,
              telefono, email, direccion, activo, actualizado_en)
  on clientes to authenticated;

-- El cliente de la app puede corregir sus propios datos de contacto.
-- La politica clientes_propio_upd ya lo limita a su propia fila; los permisos
-- por columna de arriba le impiden tocarse el limite o el saldo.


-- ---------------------------------------------------------------------------
-- 3. Fijar el limite de fiado: decision de supervisor, no de caja
-- ---------------------------------------------------------------------------

create or replace function fn_fijar_limite_credito(
  p_cliente_id uuid,
  p_limite     numeric
) returns jsonb
language plpgsql security definer set search_path = public, app as $fn$
declare
  c       record;
  v_lim   numeric;
begin
  if p_limite is null or p_limite < 0 then
    raise exception 'El limite no puede ser negativo';
  end if;

  select * into c from clientes where id = p_cliente_id for update;
  if c.id is null then raise exception 'Cliente inexistente'; end if;

  if not (app.es_admin()
          or (c.organizacion_id = app.org_id() and app.tiene_nivel('supervisor'))) then
    raise exception 'Solo un supervisor puede fijar el limite de fiado';
  end if;

  v_lim := round(p_limite, 4);

  update clientes
     set limite_credito    = v_lim,
         limite_fijado_por = auth.uid(),
         limite_fijado_en  = now(),
         actualizado_en    = now()
   where id = p_cliente_id;

  return jsonb_build_object(
    'cliente',      c.nombre,
    'limite',       round(v_lim, 2),
    'debe',         round(coalesce(c.saldo, 0), 2),
    'disponible',   round(greatest(v_lim - coalesce(c.saldo, 0), 0), 2),
    -- Bajar el limite por debajo de lo que ya debe es legitimo ("ya no le
    -- fio mas"), pero conviene decirlo en pantalla para que no sorprenda.
    'debajo_del_saldo', v_lim < coalesce(c.saldo, 0)
  );
end $fn$;

revoke execute on function fn_fijar_limite_credito(uuid, numeric) from public, anon;
grant execute on function fn_fijar_limite_credito(uuid, numeric) to authenticated;
