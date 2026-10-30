-- ============================================================================
--  Migración 038 · El logo y las promociones, como imágenes del negocio
--
--  El dueño sube su logo y las imágenes de sus promociones desde
--  Configuración, y la caja bloqueada las enseña.
--
--  UN BUCKET, UNA CARPETA POR NEGOCIO
--
--    marca/<organizacion_id>/logo-....png
--    marca/<organizacion_id>/promo-....jpg
--
--  Las políticas miran la primera carpeta de la ruta: solo un gerente sube,
--  cambia o borra, y solo dentro de la carpeta de SU negocio. Es el mismo
--  cuidado de siempre: el rango dice quién es, la carpeta dice de quién es.
--
--  El bucket es público de lectura a propósito. Un logo y un anuncio de
--  "2 x L 50 en refrescos" están hechos para que los vea cualquiera, y así
--  la caja los pinta con una URL directa, sin firmar nada.
--
--  Tamaño y tipo los limita el propio bucket: 2 MB, PNG, JPG o WEBP. Una
--  foto de 12 MB del celular en una tablet de caja es una caja lenta.
--
--  Todo va dentro de un "si existe storage": en el Postgres local de las
--  pruebas no hay esquema storage, y la migración tiene que poder correr
--  igual allá.
-- ============================================================================

do $migra$
begin
  if not exists (select 1 from pg_namespace where nspname = 'storage') then
    raise notice 'Sin esquema storage (base de pruebas): se salta la 038';
    return;
  end if;

  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('marca', 'marca', true, 2097152,
          array['image/png', 'image/jpeg', 'image/webp'])
  on conflict (id) do update
    set public = true,
        file_size_limit = excluded.file_size_limit,
        allowed_mime_types = excluded.allowed_mime_types;

  if not exists (select 1 from pg_policies where schemaname = 'storage'
                  and tablename = 'objects' and policyname = 'marca_subir') then
    execute $p$
      create policy marca_subir on storage.objects for insert to authenticated
        with check (bucket_id = 'marca'
                    and (storage.foldername(name))[1] = app.org_id()::text
                    and app.tiene_nivel('gerente'))$p$;
  end if;

  if not exists (select 1 from pg_policies where schemaname = 'storage'
                  and tablename = 'objects' and policyname = 'marca_cambiar') then
    execute $p$
      create policy marca_cambiar on storage.objects for update to authenticated
        using (bucket_id = 'marca'
               and (storage.foldername(name))[1] = app.org_id()::text
               and app.tiene_nivel('gerente'))$p$;
  end if;

  if not exists (select 1 from pg_policies where schemaname = 'storage'
                  and tablename = 'objects' and policyname = 'marca_borrar') then
    execute $p$
      create policy marca_borrar on storage.objects for delete to authenticated
        using (bucket_id = 'marca'
               and (storage.foldername(name))[1] = app.org_id()::text
               and app.tiene_nivel('gerente'))$p$;
  end if;

  -- Para borrar o reemplazar, Storage necesita poder VER la fila del objeto.
  -- Solo la del propio negocio: ver la carpeta de la competencia no.
  if not exists (select 1 from pg_policies where schemaname = 'storage'
                  and tablename = 'objects' and policyname = 'marca_ver') then
    execute $p$
      create policy marca_ver on storage.objects for select to authenticated
        using (bucket_id = 'marca'
               and (storage.foldername(name))[1] = app.org_id()::text)$p$;
  end if;
end
$migra$;
