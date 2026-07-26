-- ============================================================================
--  Migración 004 · Endurecimiento de permisos
--
--  Supabase concede EXECUTE sobre toda función nueva de `public` a los roles
--  anon y authenticated. Eso dejaba dos huecos:
--
--  1) `anon` (sin iniciar sesión, solo con la llave pública) podía llamar
--     fn_abrir_turno y fn_desbloquear_caja, que no verifican quién llama
--     sino el PIN. Era una puerta para adivinar PINes desde internet.
--  2) `authenticated` podía llamar helpers internos como fn_descontar_fefo,
--     que descarga inventario sin pasar por una venta.
-- ============================================================================

revoke execute on all functions in schema public from anon;
revoke execute on all functions in schema app    from anon;
revoke usage   on schema app                     from anon;

alter default privileges in schema public revoke execute on functions from anon;
alter default privileges in schema app    revoke execute on functions from anon;

revoke execute on function fn_descontar_fefo(uuid, uuid, numeric, text, uuid, uuid)
  from public, anon, authenticated;
revoke execute on function fn_siguiente_numero(uuid, uuid, text)
  from public, anon, authenticated;

grant execute on function fn_pos_contexto()                                     to authenticated;
grant execute on function fn_registrar_venta(uuid, jsonb, jsonb, uuid, boolean)  to authenticated;
grant execute on function fn_desbloquear_caja(uuid, text)                        to authenticated;
grant execute on function fn_abrir_turno(uuid, uuid, text, numeric)              to authenticated;
grant execute on function fn_cerrar_turno(uuid, numeric, text)                   to authenticated;
grant execute on function fn_establecer_pin(uuid, text)                          to authenticated;
grant execute on function fn_anular_venta(uuid, text)                            to authenticated;
grant execute on function fn_confirmar_factura_compra(uuid)                      to authenticated;
grant execute on function fn_precio_vigente(uuid, uuid, numeric, nivel_precio)   to authenticated;
grant execute on function fn_lotes_fefo(uuid, uuid)                              to authenticated;
grant execute on function fn_cambiar_estado_pedido(uuid, estado_pedido, text)    to authenticated;
grant execute on function fn_asignar_repartidor(uuid, uuid)                      to authenticated;
grant execute on function fn_facturar_pedido(uuid, uuid, boolean)                to authenticated;
grant execute on function fn_crear_pedido(jsonb, uuid, uuid, origen_pedido, tipo_entrega, uuid, text, text, text, metodo_pago, numeric, numeric, text) to authenticated;

-- search_path fijo: un search_path mutable permite que otro esquema
-- suplante a una tabla dentro de la función.
alter function app.set_actualizado_en()                             set search_path = public, app;
alter function app.es_entrada(tipo_movimiento)                      set search_path = public, app;
alter function app.nivel_rol(rol_usuario)                           set search_path = public, app;
alter function app.kardex_inmutable()                               set search_path = public, app;
alter function app.aplicar_pago_compra()                            set search_path = public, app;
alter function fn_lotes_fefo(uuid, uuid)                            set search_path = public, app;
alter function fn_precio_vigente(uuid, uuid, numeric, nivel_precio) set search_path = public, app;
