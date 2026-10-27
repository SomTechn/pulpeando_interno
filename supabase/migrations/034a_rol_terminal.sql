-- ============================================================================
--  Migración 034a · Rol terminal
--
--  Va aislada, igual que la 002a: ALTER TYPE ... ADD VALUE no admite usarse
--  en la misma transacción en que se agrega el valor.
--
--  Una terminal es la TABLET de una caja, no una persona. Entra al sistema
--  con su propia cuenta para que la cajera no tenga que escribir correo ni
--  contraseña en el mostrador, y queda en nivel 0: por sí sola no alcanza
--  ninguna función del sistema. Quien manda es la cajera que marca su
--  código y su PIN encima.
-- ============================================================================

alter type rol_usuario add value if not exists 'terminal';
