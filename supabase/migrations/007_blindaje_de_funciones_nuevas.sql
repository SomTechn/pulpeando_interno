-- ============================================================================
--  Migración 007 · Red de seguridad para funciones nuevas
--
--  Postgres concede EXECUTE a PUBLIC en cada función nueva y `anon` hereda
--  de ahí. Ya pasó dos veces pese a ajustar los privilegios por defecto.
--  En vez de recordar el REVOKE en cada migración, un disparador de eventos
--  lo hace solo. Alcance limitado a los esquemas public y app.
--  Para exponer una función hay que concederla a mano, que es como debe ser.
-- ============================================================================

create or replace function app.blindar_funciones_nuevas()
returns event_trigger
language plpgsql
security definer
as $$
declare
  r record;
begin
  for r in
    select object_identity, schema_name
    from pg_event_trigger_ddl_commands()
    where command_tag = 'CREATE FUNCTION'
      and schema_name in ('public', 'app')
  loop
    begin
      execute format('revoke execute on function %s from public', r.object_identity);
      execute format('revoke execute on function %s from anon',   r.object_identity);
    exception when others then
      raise notice 'No se pudo blindar %: %', r.object_identity, sqlerrm;
    end;
  end loop;
end $$;

revoke execute on function app.blindar_funciones_nuevas() from public, anon;

drop event trigger if exists tg_blindar_funciones;

create event trigger tg_blindar_funciones
  on ddl_command_end
  when tag in ('CREATE FUNCTION')
  execute function app.blindar_funciones_nuevas();
