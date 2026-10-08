// ============================================================================
//  crear-usuario
//
//  Da de alta a un empleado: crea su cuenta de acceso y su perfil en el
//  negocio de quien lo pide. Esto no se podia hacer desde el navegador porque
//  crear una cuenta exige la llave service_role, que no puede viajar al
//  cliente. Por eso vive aqui.
//
//  REGLA DE ORO DE ESTE ARCHIVO
//
//  La llave service_role se salta RLS por completo: aqui dentro no hay red de
//  seguridad de la base de datos. Entonces la identidad, el negocio y el rol
//  del solicitante NUNCA salen del cuerpo de la peticion. Salen del JWT:
//
//    1. Supabase valida la firma del JWT (verify_jwt)
//    2. getUser() dice quien es
//    3. su perfil en la base dice de que negocio es y con que rol
//
//  Si el negocio viniera en el cuerpo, un gerente podria meter usuarios en la
//  pulperia de la competencia. Si el rol del solicitante viniera en el cuerpo,
//  una auxiliar diria que es admin y se crearia una cuenta de dueño de la
//  plataforma.
//
//  Las decisiones de permiso estan en reglas.ts, que se prueba aparte.
// ============================================================================

import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import { necesitaPin, sucursalesCoinciden, validarAlta } from './reglas.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const responder = (cuerpo: unknown, estado = 200) =>
  new Response(JSON.stringify(cuerpo), {
    status: estado,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });

const fallo = (mensaje: string, estado = 400) => responder({ error: mensaje }, estado);

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return fallo('Use POST', 405);

  const url = Deno.env.get('SUPABASE_URL');
  const servicio = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !servicio) return fallo('La funcion no esta configurada', 500);

  const sb = createClient(url, servicio, { auth: { persistSession: false } });

  // ---- 1. quien pide ----
  const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim();
  if (!jwt) return fallo('Falta la sesion', 401);

  const { data: quien, error: eAuth } = await sb.auth.getUser(jwt);
  if (eAuth || !quien?.user) return fallo('La sesion no es valida', 401);

  // ---- 2. su perfil manda, no el cuerpo ----
  const { data: solicitante, error: ePerfil } = await sb
    .from('perfiles')
    .select('id, organizacion_id, rol, activo')
    .eq('id', quien.user.id)
    .maybeSingle();

  if (ePerfil) return fallo('No se pudo leer su perfil', 500);

  // ---- 3. las reglas ----
  let cuerpo: Record<string, unknown>;
  try {
    cuerpo = await req.json();
  } catch {
    return fallo('El cuerpo no es JSON');
  }

  const veredicto = validarAlta(solicitante as never, cuerpo);
  if (!veredicto.ok) return fallo(veredicto.error, veredicto.estado);
  const alta = veredicto.datos;

  // ---- 4. las sucursales son de SU negocio ----
  if (alta.sucursales.length) {
    const { data: suyas, error: eSuc } = await sb
      .from('sucursales')
      .select('id')
      .eq('organizacion_id', solicitante!.organizacion_id)
      .in('id', alta.sucursales);
    if (eSuc) return fallo('No se pudieron verificar las sucursales', 500);
    const halladas = (suyas ?? []).map((s: { id: string }) => s.id);
    if (!sucursalesCoinciden(alta.sucursales, halladas))
      return fallo('Alguna sucursal no es de su negocio', 403);
  }

  // ---- 5. el correo no puede estar tomado ----
  // Si ya hay cuenta con ese correo puede ser un cliente de la app que ahora
  // entra a trabajar. No lo convertimos en empleado por las calladas.
  const { data: yaHay } = await sb
    .from('perfiles')
    .select('id, organizacion_id')
    .eq('email', alta.email)
    .maybeSingle();

  if (yaHay) {
    return fallo(
      yaHay.organizacion_id === solicitante!.organizacion_id
        ? 'Ya hay un usuario con ese correo en su negocio'
        : 'Ese correo ya esta en uso',
    );
  }

  // ---- 6. crear la cuenta ----
  const { data: creado, error: eCrear } = await sb.auth.admin.createUser({
    email: alta.email,
    password: alta.password,
    email_confirm: true,
    user_metadata: { nombre: alta.nombre },
  });

  if (eCrear || !creado?.user) {
    const m = (eCrear?.message || '').toLowerCase();
    if (m.includes('already') || m.includes('registered') || m.includes('exists'))
      return fallo('Ese correo ya tiene cuenta');
    return fallo('No se pudo crear la cuenta: ' + (eCrear?.message ?? 'error'), 500);
  }

  const nuevoId = creado.user.id;

  // ---- 7. el perfil ----
  // Si esto falla hay que borrar la cuenta: una cuenta de auth sin perfil no
  // entra a ninguna pantalla y nadie la ve para limpiarla.
  const { error: eInsert } = await sb.from('perfiles').insert({
    id: nuevoId,
    organizacion_id: solicitante!.organizacion_id,
    nombre: alta.nombre,
    email: alta.email,
    telefono: alta.telefono,
    rol: alta.rol,
    activo: true,
  });

  if (eInsert) {
    await sb.auth.admin.deleteUser(nuevoId);
    return fallo('No se pudo crear el perfil: ' + eInsert.message, 500);
  }

  // ---- 8. sus sucursales ----
  if (alta.sucursales.length) {
    const { error: eUS } = await sb.from('usuario_sucursales').insert(
      alta.sucursales.map((sucursal_id) => ({ perfil_id: nuevoId, sucursal_id })),
    );
    if (eUS) {
      await sb.from('perfiles').delete().eq('id', nuevoId);
      await sb.auth.admin.deleteUser(nuevoId);
      return fallo('No se pudieron asignar las sucursales: ' + eUS.message, 500);
    }
  }

  // El PIN no se pone aqui. Lo pone el navegador con fn_establecer_pin, que ya
  // tiene las reglas (5 digitos, no repetidos, no 12345) y verifica permiso con
  // la sesion del gerente. Una sola copia de esa logica.
  return responder({
    perfil_id: nuevoId,
    nombre: alta.nombre,
    email: alta.email,
    rol: alta.rol,
    sucursales: alta.sucursales.length,
    falta_pin: necesitaPin(alta.rol),
  }, 201);
});
