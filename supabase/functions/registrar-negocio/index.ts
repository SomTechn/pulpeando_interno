// ============================================================================
//  registrar-negocio
//
//  La puerta de entrada de un negocio nuevo, sin que Pulpeando intervenga:
//
//    GET   → lo que la página de registro muestra (días de prueba, planes,
//            si el registro está abierto)
//    POST  → crea la cuenta del dueño y su negocio con N días de prueba
//
//  Se despliega con verify_jwt = false porque quien se registra todavía no
//  tiene sesión. Por eso mismo aquí no se confía en nada del cuerpo más allá
//  de los datos del formulario: el negocio se crea siempre nuevo, el rol es
//  siempre gerente de ESE negocio y nunca se toca uno existente.
//
//  Defensas contra robots: campo trampa, 5 intentos por IP por hora
//  (fn_registro_intento) y la base revisa todo otra vez en fn_crear_negocio.
// ============================================================================

import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import { ipDe, mensajeDeLaBase, validarRegistro } from './reglas.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};

const responder = (cuerpo: unknown, estado = 200) =>
  new Response(JSON.stringify(cuerpo), {
    status: estado,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });

const fallo = (mensaje: string, estado = 400) => responder({ ok: false, error: mensaje }, estado);

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const url = Deno.env.get('SUPABASE_URL');
  const servicio = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !servicio) return fallo('La función no está configurada', 500);
  const sb = createClient(url, servicio, { auth: { persistSession: false } });

  if (req.method === 'GET') {
    const { data, error } = await sb.rpc('fn_registro_info');
    if (error) return fallo('No se pudo leer la información', 500);
    return responder({ ok: true, ...data });
  }
  if (req.method !== 'POST') return fallo('Use POST', 405);

  let cuerpo: Record<string, unknown>;
  try {
    cuerpo = await req.json();
  } catch {
    return fallo('El cuerpo no es JSON');
  }

  const v = validarRegistro(cuerpo);
  if (!v.ok) return fallo(v.error, v.estado);
  const r = v.datos;

  // ---- límite por IP (anota el intento aunque luego falle) ----
  const { data: permitido, error: eInt } = await sb.rpc('fn_registro_intento', {
    p_ip: ipDe(req.headers),
    p_correo: r.email,
  });
  if (eInt) return fallo('No se pudo registrar. Intente de nuevo', 500);
  if (permitido === false) return fallo('Demasiados intentos desde esta conexión. Espere una hora', 429);

  // ---- la cuenta del dueño ----
  const { data: creado, error: eCrear } = await sb.auth.admin.createUser({
    email: r.email,
    password: r.password,
    email_confirm: true,
    user_metadata: { nombre: r.nombre, origen: 'registro' },
  });
  if (eCrear || !creado?.user) {
    const m = (eCrear?.message || '').toLowerCase();
    if (m.includes('already') || m.includes('registered') || m.includes('exists'))
      return fallo('Ese correo ya tiene cuenta. Entre con él o use otro', 409);
    if (m.includes('password')) return fallo('Esa contraseña no la acepta el sistema. Escoja otra más larga');
    return fallo('No se pudo crear la cuenta. Intente de nuevo', 500);
  }
  const usuario = creado.user.id;

  // ---- el negocio ----
  const { data: negocio, error: eNeg } = await sb.rpc('fn_crear_negocio', {
    p_usuario: usuario,
    p_datos: {
      negocio: r.negocio,
      nombre: r.nombre,
      telefono: r.telefono,
      sucursal: r.sucursal,
      direccion: r.direccion,
      pin: r.pin,
    },
  });
  if (eNeg || !negocio) {
    // Sin negocio la cuenta no sirve para nada y bloquearía el correo
    await sb.auth.admin.deleteUser(usuario);
    return fallo(mensajeDeLaBase(eNeg?.message), 400);
  }

  return responder({
    ok: true,
    email: r.email,
    negocio: r.negocio,
    codigo_tienda: negocio.codigo_tienda,
    prueba_hasta: negocio.prueba_hasta,
    muestra: r.muestra,
  }, 201);
});
