// ============================================================================
//  entrar-caja
//
//  La puerta del mostrador. La cajera marca su codigo y su PIN en la tablet y
//  esta funcion le devuelve una sesion.
//
//  SE DESPLIEGA SIN VERIFICAR JWT:
//
//      supabase functions deploy entrar-caja --no-verify-jwt
//
//  y es la unica del sistema que va asi, por una razon sencilla: quien llama
//  todavia no tiene sesion, justamente esta pidiendo una. Eso la deja de cara
//  a internet, asi que los candados estan en otra parte:
//
//    1. EL APARATO. Hay que mandar el id y la llave de una tablet que un
//       gerente pareo. La llave son 24 bytes al azar; sin ella no se puede ni
//       intentar. Si se pierde la tablet, el gerente la revoca.
//    2. EL CONTEO. La base cuenta los intentos fallidos contra el perfil (5 y
//       se enfria) y contra el aparato (10 y se enfria). Por eso fn_entrar_caja
//       responde {ok:false} en vez de lanzar: al lanzar, Postgres deshace el
//       contador y el bloqueo no se cumple nunca.
//    3. LO QUE NO SE DICE. Codigo inexistente y PIN malo dan el mismo mensaje.
//
//  REGLA DE ORO, igual que en crear-usuario: aqui dentro corre la llave
//  service_role, que se salta RLS por completo. Nada de lo que decide esta
//  funcion sale del cuerpo de la peticion. El negocio, la sucursal y la caja
//  salen del APARATO, que la base verifico; el rol sale del PERFIL. Si el
//  negocio viniera en el cuerpo, cualquiera con una tablet pareada abriria
//  caja en la pulperia de la competencia.
//
//  Las decisiones puras estan en reglas.ts, que se prueba aparte.
// ============================================================================

import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import { cuerpoDeSesion, respuestaDeVeredicto, validarEntrada } from './reglas.ts';

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

/** Lo que no es un veredicto de credencial: peticion mal hecha o avería. */
const fallo = (mensaje: string, estado = 400, error = 'peticion') =>
  responder({ ok: false, error, mensaje }, estado);

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return fallo('Use POST', 405);

  const url = Deno.env.get('SUPABASE_URL');
  const servicio = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const publica = Deno.env.get('SUPABASE_ANON_KEY');
  if (!url || !servicio || !publica)
    return fallo('La funcion no esta configurada', 500, 'config');

  let cuerpo: unknown;
  try {
    cuerpo = await req.json();
  } catch {
    return fallo('El cuerpo no es JSON');
  }

  const veredicto = validarEntrada(cuerpo);
  if (!veredicto.ok) return fallo(veredicto.error, veredicto.estado, 'credencial');
  const { aparato, llave, codigo, pin } = veredicto.datos;

  const sb = createClient(url, servicio, { auth: { persistSession: false } });

  // ---- 1. que la base diga si la credencial sirve ----
  const { data: dicho, error: eRpc } = await sb.rpc('fn_entrar_caja', {
    p_aparato: aparato,
    p_llave: llave,
    p_codigo: codigo,
    p_pin: pin,
  });

  if (eRpc) {
    console.error('fn_entrar_caja fallo:', eRpc.message);
    return fallo('No se pudo verificar la credencial', 500, 'base');
  }

  const r = respuestaDeVeredicto(dicho as Record<string, unknown>);
  if (r.cuerpo.ok !== true) return responder(r.cuerpo, r.estado);
  const v = r.cuerpo as Record<string, unknown>;

  // ---- 2. acuñar la sesion ----
  //
  // No se usa la contraseña de la empleada: esta funcion no la sabe, y
  // guardarla en algun lado para poder usarla seria peor que el problema que
  // resuelve. En vez de eso se genera un enlace de un solo uso y se canjea
  // aqui mismo. El enlace NO se envia por correo: generateLink solo lo crea.
  const { data: enlace, error: eEnlace } = await sb.auth.admin.generateLink({
    type: 'magiclink',
    email: String(v.email ?? ''),
  });

  const ficha = enlace?.properties?.hashed_token;
  if (eEnlace || !ficha) {
    console.error('generateLink fallo:', eEnlace?.message ?? 'sin ficha');
    return fallo('No se pudo abrir la sesion de caja', 500, 'sesion');
  }

  // El canje va con la llave publica, no con la de servicio: lo que se quiere
  // de vuelta es una sesion de usuario normal, con el rol que le toca.
  const publico = createClient(url, publica, { auth: { persistSession: false } });
  const { data: canje, error: eCanje } = await publico.auth.verifyOtp({
    token_hash: ficha,
    type: 'magiclink',
  });

  if (eCanje || !canje?.session) {
    console.error('verifyOtp fallo:', eCanje?.message ?? 'sin sesion');
    return fallo('No se pudo abrir la sesion de caja', 500, 'sesion');
  }

  return responder(cuerpoDeSesion(v, canje.session));
});
