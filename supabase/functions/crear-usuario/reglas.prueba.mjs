/* Pruebas de quien puede dar de alta a quien. */
import { NIVEL, nivelDe, puedeDarDeAlta, validarAlta, sucursalesCoinciden, necesitaPin }
  from './reglas.ts';

let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };

const perfil = (rol, extra = {}) => ({
  id:'u1', organizacion_id:'org-1', rol, activo:true, ...extra });

const base = { nombre:'Ana Lopez', email:'ana@tienda.hn', password:'clave1234',
               rol:'auxiliar' };

console.log('\n=== Niveles ===');
chk('repartidor 0', nivelDe('repartidor') === 0);
chk('auxiliar 1', nivelDe('auxiliar') === 1);
chk('supervisor 2', nivelDe('supervisor') === 2);
chk('gerente 3', nivelDe('gerente') === 3);
chk('admin 4', nivelDe('admin') === 4);
chk('un rol inventado no tiene nivel', nivelDe('jefe') === -1);
chk('null no tiene nivel', nivelDe(null) === -1);
chk('un numero no tiene nivel', nivelDe(4) === -1);
chk('objeto no tiene nivel', nivelDe({ rol:'admin' }) === -1);

console.log('\n=== Quien puede dar de alta ===');
for (const [rol, puede] of [['repartidor',false], ['auxiliar',false],
                            ['supervisor',false], ['gerente',true], ['admin',true]]){
  const v = puedeDarDeAlta(perfil(rol));
  chk(rol + (puede ? ' sí puede' : ' no puede'), puede ? v === null : v?.ok === false);
  if (!puede && v) chk('  ...y responde 403', v.estado === 403);
}
chk('sin perfil no puede', puedeDarDeAlta(null)?.ok === false);
chk('perfil inactivo no puede',
    puedeDarDeAlta(perfil('gerente', { activo:false }))?.ok === false);
chk('inactivo responde 403',
    puedeDarDeAlta(perfil('gerente', { activo:false }))?.estado === 403);

console.log('\n=== Escalada de privilegios ===');
{
  const g = perfil('gerente');
  chk('gerente crea auxiliar', validarAlta(g, { ...base, rol:'auxiliar' }).ok);
  chk('gerente crea supervisor', validarAlta(g, { ...base, rol:'supervisor' }).ok);
  chk('gerente crea repartidor', validarAlta(g, { ...base, rol:'repartidor' }).ok);
  chk('gerente crea otro gerente', validarAlta(g, { ...base, rol:'gerente' }).ok);

  const a = validarAlta(g, { ...base, rol:'admin' });
  chk('gerente NO crea admin', a.ok === false);
  // Lo detiene el chequeo de nivel (admin es 4, gerente 3), no la rama
  // especifica de admin, que hoy es inalcanzable. Cualquiera de los dos
  // mensajes es correcto; lo que importa es que no pase.
  chk('y explica por qué', /mas permisos que usted|admin no se asigna/i.test(a.error || ''));
  chk('con 403', a.estado === 403);

  // Si alguien agrega un rol en nivel 4 que no sea admin, el chequeo de nivel
  // deja de alcanzar y la segunda guarda pasa a ser la que protege.
  const otroNivel4 = { id:'u9', organizacion_id:'org-1', rol:'auditor', activo:true };
  const falso = { ...NIVEL };
  chk('hoy admin es el único en nivel 4',
      Object.entries(falso).filter(([k,v]) => v >= 4 && k !== 'admin').length === 0);

  const inv = validarAlta(g, { ...base, rol:'superadmin' });
  chk('un rol inventado se rechaza', inv.ok === false);
  chk('dice que no existe', /no existe/i.test(inv.error || ''));

  chk('admin sí crea admin',
      validarAlta(perfil('admin'), { ...base, rol:'admin' }).ok);
  chk('admin crea gerente',
      validarAlta(perfil('admin'), { ...base, rol:'gerente' }).ok);

  // la puerta de rol se revisa aunque el cuerpo venga perfecto
  chk('auxiliar con cuerpo válido sigue sin poder',
      validarAlta(perfil('auxiliar'), base).ok === false);
  chk('supervisor con cuerpo válido sigue sin poder',
      validarAlta(perfil('supervisor'), base).ok === false);
}

console.log('\n=== El cuerpo no decide quién es el solicitante ===');
{
  const g = perfil('auxiliar');
  // un atacante manda su propio rol y organizacion en el cuerpo
  const v = validarAlta(g, { ...base, rol:'gerente',
    solicitante_rol:'admin', rol_solicitante:'admin',
    organizacion_id:'org-ajena', activo:true, nivel:4 });
  chk('mandar rol de admin en el cuerpo no sirve', v.ok === false);
  chk('sigue siendo un auxiliar sin permiso',
      /Solo un gerente/i.test(v.error || ''));

  // y un gerente no puede cambiar su organizacion por el cuerpo
  const v2 = validarAlta(perfil('gerente'), { ...base, organizacion_id:'org-ajena' });
  chk('el alta no lleva organizacion dentro', v2.ok && !('organizacion_id' in v2.datos));
  chk('los datos limpios solo traen lo esperado',
      v2.ok && Object.keys(v2.datos).sort().join(',') ===
      'email,nombre,password,rol,sucursales,telefono');
}

console.log('\n=== Validación de campos ===');
{
  const g = perfil('gerente');
  const malo = (c, texto) => {
    const v = validarAlta(g, { ...base, ...c });
    return v.ok === false && (!texto || new RegExp(texto, 'i').test(v.error));
  };
  chk('nombre vacío', malo({ nombre:'' }, 'nombre'));
  chk('nombre de solo espacios', malo({ nombre:'   ' }, 'nombre'));
  chk('nombre larguísimo', malo({ nombre:'x'.repeat(121) }, 'largo'));
  chk('correo sin arroba', malo({ email:'ana.tienda.hn' }, 'correo'));
  chk('correo sin dominio', malo({ email:'ana@' }, 'correo'));
  chk('correo sin punto', malo({ email:'ana@tienda' }, 'correo'));
  chk('correo con espacio', malo({ email:'an a@tienda.hn' }, 'correo'));
  chk('correo vacío', malo({ email:'' }, 'correo'));
  chk('contraseña de 7', malo({ password:'1234567' }, 'contrasena'));
  chk('contraseña vacía', malo({ password:'' }, 'contrasena'));
  chk('contraseña de 73', malo({ password:'x'.repeat(73) }, 'larga'));
  chk('rol vacío', malo({ rol:'' }, 'rol'));

  chk('contraseña de 8 justos pasa',
      validarAlta(g, { ...base, password:'12345678' }).ok);
  chk('contraseña de 72 justos pasa',
      validarAlta(g, { ...base, password:'x'.repeat(72) }).ok);
}

console.log('\n=== Normalización ===');
{
  const g = perfil('gerente');
  const v = validarAlta(g, { nombre:'  Ana Lopez  ', email:'  ANA@Tienda.HN ',
                             password:'clave1234', rol:'auxiliar',
                             telefono:'  9999-1234  ' });
  chk('el nombre se recorta', v.ok && v.datos.nombre === 'Ana Lopez');
  chk('el correo baja a minúsculas', v.ok && v.datos.email === 'ana@tienda.hn');
  chk('el teléfono se recorta', v.ok && v.datos.telefono === '9999-1234');

  const sinTel = validarAlta(g, base);
  chk('sin teléfono queda en null', sinTel.ok && sinTel.datos.telefono === null);
  const telVacio = validarAlta(g, { ...base, telefono:'   ' });
  chk('teléfono de espacios queda en null',
      telVacio.ok && telVacio.datos.telefono === null);
}

console.log('\n=== Sucursales ===');
{
  const g = perfil('gerente');
  const v = validarAlta(g, { ...base, sucursales:['s1','s2','s1','  s3  ','',null] });
  chk('se quitan repetidas y vacías', v.ok && v.datos.sucursales.length === 3);
  chk('se recortan los ids', v.ok && v.datos.sucursales.includes('s3'));
  chk('sin sucursales queda lista vacía',
      validarAlta(g, base).datos.sucursales.length === 0);
  chk('sucursales que no son lista se ignoran',
      validarAlta(g, { ...base, sucursales:'s1' }).datos.sucursales.length === 0);
  chk('demasiadas sucursales se rechaza',
      validarAlta(g, { ...base,
        sucursales:Array.from({length:51}, (_,i) => 's'+i) }).ok === false);

  chk('todas presentes coincide', sucursalesCoinciden(['a','b'], ['b','a']));
  chk('falta una no coincide', sucursalesCoinciden(['a','b'], ['a']) === false);
  chk('sobra una no coincide', sucursalesCoinciden(['a'], ['a','b']) === false);
  chk('vacías coinciden', sucursalesCoinciden([], []));
  chk('pedida ajena no coincide', sucursalesCoinciden(['ajena'], []) === false);
}

console.log('\n=== Quién necesita PIN ===');
chk('auxiliar necesita PIN', necesitaPin('auxiliar'));
chk('supervisor necesita PIN', necesitaPin('supervisor'));
chk('gerente necesita PIN', necesitaPin('gerente'));
chk('repartidor no necesita PIN', necesitaPin('repartidor') === false);

console.log('\n' + ok + ' bien, ' + mal + ' mal');
process.exit(mal ? 1 : 0);
