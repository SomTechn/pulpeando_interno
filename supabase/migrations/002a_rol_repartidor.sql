-- ============================================================================
--  Migración 002a · Rol repartidor
--  Va aislada: ALTER TYPE ... ADD VALUE no admite usarse en la misma
--  transacción en que se agrega el valor.
-- ============================================================================

alter type rol_usuario add value if not exists 'repartidor';
