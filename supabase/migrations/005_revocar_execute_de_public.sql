-- ============================================================================
--  Migración 005 · Cerrar el permiso que llegaba por PUBLIC
--
--  Postgres concede EXECUTE a PUBLIC en cada función nueva, y `anon` hereda
--  de PUBLIC. Revocar solo a `anon` no bastaba: había que quitarlo de PUBLIC.
--  Después se vuelve a conceder, una por una, solo lo que la app necesita.
-- ============================================================================

revoke execute on all functions in schema public from public;
revoke execute on all functions in schema app    from public;

alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema app    revoke execute on functions from public;

grant execute on all functions in schema public to service_role;
grant execute on all functions in schema app    to service_role;

-- Funciones de contexto que usan las políticas RLS
grant execute on all functions in schema app to authenticated;

grant execute on function fn_pos_contexto()                                    to authenticated;
grant execute on function fn_registrar_venta(uuid, jsonb, jsonb, uuid, boolean) to authenticated;
grant execute on function fn_desbloquear_caja(uuid, text)                       to authenticated;
grant execute on function fn_abrir_turno(uuid, uuid, text, numeric)             to authenticated;
grant execute on function fn_cerrar_turno(uuid, numeric, text)                  to authenticated;
grant execute on function fn_establecer_pin(uuid, text)                         to authenticated;
grant execute on function fn_anular_venta(uuid, text)                           to authenticated;
grant execute on function fn_confirmar_factura_compra(uuid)                     to authenticated;
grant execute on function fn_precio_vigente(uuid, uuid, numeric, nivel_precio)  to authenticated;
grant execute on function fn_lotes_fefo(uuid, uuid)                             to authenticated;
grant execute on function fn_cambiar_estado_pedido(uuid, estado_pedido, text)   to authenticated;
grant execute on function fn_asignar_repartidor(uuid, uuid)                     to authenticated;
grant execute on function fn_facturar_pedido(uuid, uuid, boolean)               to authenticated;
grant execute on function fn_crear_pedido(jsonb, uuid, uuid, origen_pedido, tipo_entrega, uuid, text, text, text, metodo_pago, numeric, numeric, text) to authenticated;

revoke execute on function fn_descontar_fefo(uuid, uuid, numeric, text, uuid, uuid) from public, anon, authenticated;
revoke execute on function fn_siguiente_numero(uuid, uuid, text)                    from public, anon, authenticated;
revoke execute on function fn_kardex_registrar(uuid, uuid, tipo_movimiento, numeric, numeric, uuid, text, uuid, text, uuid) from public, anon, authenticated;
