-- ============================================================================
--  SEMILLA INICIAL
--  Deja el negocio listo para el primer inicio de sesión en el POS.
--
--  ANTES DE EJECUTAR:
--   1. Supabase → Authentication → Users → Add user
--      · correo y contraseña del gerente (usted)
--      · marque "Auto Confirm User"
--   2. Copie el UUID que aparece en la lista de usuarios
--   3. Péguelo abajo, en v_usuario_id
--   4. Cambie el PIN por uno que no sea 12345 ni cinco dígitos iguales
--
--  Se puede ejecutar más de una vez sin duplicar nada.
-- ============================================================================

do $$
declare
  -- >>>>>>>>>>>>>>>>>>>>  EDITE ESTO  <<<<<<<<<<<<<<<<<<<<
  v_usuario_id   uuid := '00000000-0000-0000-0000-000000000000';  -- UUID de Authentication → Users
  v_nombre       text := 'Nombre del gerente';
  v_negocio      text := 'Pulpería Pulpeando';
  v_rtn          text := null;
  v_pin          text := '48317';                                  -- 5 dígitos
  v_sucursal_nom text := 'Sucursal Central';
  -- >>>>>>>>>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<<<<<<<<<<<<<<

  v_org      uuid;
  v_suc      uuid;
  v_imp      uuid;
  v_caja     uuid;
  v_cat_bas  uuid;
  v_cat_beb  uuid;
  v_cat_lac  uuid;
begin
  if v_usuario_id = '00000000-0000-0000-0000-000000000000' then
    raise exception 'Falta pegar el UUID del usuario creado en Authentication → Users';
  end if;
  if not exists (select 1 from auth.users where id = v_usuario_id) then
    raise exception 'No existe ese usuario en Authentication. Revise el UUID.';
  end if;
  if v_pin !~ '^[0-9]{5}$' then
    raise exception 'El PIN debe tener 5 dígitos';
  end if;

  -- ---------- organización ----------
  select id into v_org from organizaciones where nombre = v_negocio;
  if v_org is null then
    insert into organizaciones (nombre, identificacion_fiscal, pais, moneda,
                                facturacion_fiscal_activa, dias_alerta_vencimiento)
    values (v_negocio, v_rtn, 'HN', 'HNL', false, 30)
    returning id into v_org;
  end if;

  -- ---------- sucursal ----------
  select id into v_suc from sucursales where organizacion_id = v_org and codigo = 'S01';
  if v_suc is null then
    insert into sucursales (organizacion_id, codigo, nombre, es_principal)
    values (v_org, 'S01', v_sucursal_nom, true)
    returning id into v_suc;
  end if;

  -- ---------- perfil del gerente ----------
  insert into perfiles (id, organizacion_id, nombre, rol, activo)
  values (v_usuario_id, v_org, v_nombre, 'gerente', true)
  on conflict (id) do update
    set organizacion_id = excluded.organizacion_id,
        nombre = excluded.nombre,
        rol = excluded.rol,
        activo = true;

  -- PIN de caja. Se escribe directo porque fn_establecer_pin exige una
  -- sesión iniciada y aquí todavía no hay ninguna.
  update perfiles
     set pin_pos = extensions.crypt(v_pin, extensions.gen_salt('bf')),
         pin_intentos_fallidos = 0,
         pin_bloqueado_hasta = null,
         pin_actualizado_en = now()
   where id = v_usuario_id;

  -- ---------- impuesto ----------
  select id into v_imp from impuestos where organizacion_id = v_org and nombre = 'ISV 15%';
  if v_imp is null then
    insert into impuestos (organizacion_id, nombre, tasa, incluido_en_precio,
                           es_predeterminado, activo)
    values (v_org, 'ISV 15%', 0.15, true, true, true)
    returning id into v_imp;

    insert into impuestos (organizacion_id, nombre, tasa, incluido_en_precio, activo)
    values (v_org, 'Exento', 0, true, true);
  end if;

  -- ---------- caja ----------
  select id into v_caja from cajas where sucursal_id = v_suc and codigo = 'C1';
  if v_caja is null then
    insert into cajas (organizacion_id, sucursal_id, codigo, nombre)
    values (v_org, v_suc, 'C1', 'Caja 1')
    returning id into v_caja;
  end if;

  -- ---------- categorías ----------
  select id into v_cat_bas from categorias where organizacion_id = v_org and nombre = 'Básicos';
  if v_cat_bas is null then
    insert into categorias (organizacion_id, nombre, orden) values (v_org, 'Básicos', 1)
      returning id into v_cat_bas;
    insert into categorias (organizacion_id, nombre, orden) values (v_org, 'Bebidas', 2)
      returning id into v_cat_beb;
    insert into categorias (organizacion_id, nombre, orden) values (v_org, 'Lácteos', 3)
      returning id into v_cat_lac;
    insert into categorias (organizacion_id, nombre, orden) values
      (v_org, 'Aseo', 4), (v_org, 'Snacks', 5), (v_org, 'Granos básicos', 6);
  end if;

  raise notice 'Negocio: %', v_negocio;
  raise notice 'Organización: %', v_org;
  raise notice 'Sucursal: %', v_suc;
  raise notice 'Caja: %', v_caja;
  raise notice 'Ya puede entrar al POS con su correo y contraseña, y abrir turno con el PIN.';
end $$;


-- ============================================================================
--  PRODUCTOS DE EJEMPLO (opcional)
--  Bórrelos cuando cargue su catálogo real.
--  Sin existencia todavía: eso entra con una factura de compra.
-- ============================================================================

do $$
declare
  v_org  uuid;
  v_suc  uuid;
  v_imp  uuid;
  v_cat  uuid;
  v_prod uuid;
  r      record;
begin
  select id into v_org from organizaciones order by creada_en limit 1;
  if v_org is null then return; end if;

  select id into v_suc from sucursales where organizacion_id = v_org order by es_principal desc limit 1;
  select id into v_imp from impuestos where organizacion_id = v_org and es_predeterminado limit 1;

  for r in
    select * from (values
      ('FRIJ400', 'Frijoles rojos molidos 400g', 'Básicos',  38.50, false),
      ('ACE500',  'Aceite vegetal 500ml',        'Básicos',  42.00, false),
      ('ARR5LB',  'Arroz de primera 5 lb',       'Básicos',  98.00, false),
      ('AZU5LB',  'Azúcar refinada 5 lb',        'Básicos',  62.00, false),
      ('CAF400',  'Café molido 400g',            'Bebidas', 115.00, false),
      ('GAS25',   'Gaseosa 2.5 L',               'Bebidas',  45.00, false),
      ('AGU1L',   'Agua purificada 1 L',         'Bebidas',  15.00, false),
      ('LEC1L',   'Leche entera 1 L',            'Lácteos',  28.00, true),
      ('QUE1LB',  'Queso fresco por libra',      'Lácteos',  78.00, true),
      ('CRE400',  'Crema 400ml',                 'Lácteos',  46.00, true)
    ) as t(sku, nombre, categoria, precio, vence)
  loop
    if exists (select 1 from productos where organizacion_id = v_org and sku = r.sku) then
      continue;
    end if;

    select id into v_cat from categorias
     where organizacion_id = v_org and nombre = r.categoria limit 1;

    insert into productos (organizacion_id, sku, nombre, categoria_id, impuesto_id,
                           tipo, unidad_base, controla_vencimiento, stock_minimo, dias_cobertura)
    values (v_org, r.sku, r.nombre, v_cat, v_imp, 'unidad', 'UND', r.vence, 10, 15)
    returning id into v_prod;

    insert into precios (organizacion_id, producto_id, precio, nivel)
    values (v_org, v_prod, r.precio, 'detalle');
  end loop;

  raise notice 'Productos de ejemplo cargados. Aparecen en el POS con existencia 0 hasta que registre una compra.';
end $$;
