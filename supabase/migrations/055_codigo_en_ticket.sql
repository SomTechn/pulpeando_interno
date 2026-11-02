-- ============================================================================
--  055 · El código de barras de cada línea en el ticket impreso
--
--  fn_venta_completa trae en cada línea el código de barras del producto (el
--  principal, o el primero) para imprimirlo debajo del nombre. Sin código,
--  el ticket pone el item (sku). Se parcha la definición viva, como en la 054.
-- ============================================================================
do $do$
declare d text;
begin
  d := pg_get_functiondef('fn_venta_completa(uuid)'::regprocedure);
  if position('''codigo'', (select pc.codigo' in d) > 0 then return; end if;
  d := replace(d,
$a$'sku', pr.sku,$a$,
$b$'sku', pr.sku,
               'codigo', (select pc.codigo from producto_codigos pc
                           where pc.producto_id = pr.id
                           order by pc.es_principal desc, pc.codigo limit 1),$b$);
  if position('''codigo'', (select pc.codigo' in d) = 0 then
    raise exception 'No se encontró dónde agregar el código a fn_venta_completa';
  end if;
  execute d;
end $do$;

notify pgrst, 'reload schema';
