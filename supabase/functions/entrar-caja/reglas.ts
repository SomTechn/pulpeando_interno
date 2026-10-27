// ============================================================================
//  Reglas de la entrada a caja.
//
//  Vive aparte del servidor a proposito: son decisiones puras, sin red ni base
//  de datos, y por eso se pueden probar una por una.
//
//  Esta es la UNICA puerta del sistema que atiende sin sesion, porque la
//  cajera todavia no tiene ninguna: justamente esta pidiendo una. Entonces
//  aqui no hay JWT que diga quien llama, y todo lo que llega es sospechoso
//  hasta que la base lo confirme. Lo que estas funciones hacen es tirar a la
//  basura lo que ni vale la pena preguntarle a la base.
// ============================================================================

export type Entrada = {
  aparato: string;
  llave: string;
  codigo: string;
  pin: string;
};

export type Veredicto =
  | { ok: true; datos: Entrada }
  | { ok: false; error: string; estado: number };

const no = (error: string, estado = 400): Veredicto => ({ ok: false, error, estado });

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// 24 bytes en hexadecimal, que es lo que reparte fn_parear_aparato.
const LLAVE = /^[0-9a-f]{48}$/i;

// Igual que fn_fijar_codigo_perfil: corto y sin signos raros.
const CODIGO = /^[A-Za-z0-9]{1,8}$/;

// fn_establecer_pin pide cinco digitos. Se acepta un rango por si eso cambia,
// pero nada que no sean digitos.
const PIN = /^[0-9]{4,8}$/;

const texto = (v: unknown): string => (typeof v === 'string' ? v.trim() : '');

/**
 * Revisa la peticion y devuelve los datos ya limpios, para que index.ts no
 * vuelva a tocar el cuerpo.
 *
 * El mensaje de error NO dice cual de los cuatro campos venia mal cuando se
 * trata de la credencial: al que esta probando no se le regalan pistas. Si
 * viene mal el aparato si se dice, porque eso es un problema de la tablet y
 * la cajera necesita saber que hay que parearla.
 */
export function validarEntrada(cuerpo: unknown): Veredicto {
  if (!cuerpo || typeof cuerpo !== 'object' || Array.isArray(cuerpo))
    return no('El cuerpo no es un objeto');

  const c = cuerpo as Record<string, unknown>;
  const aparato = texto(c.aparato);
  const llave = texto(c.llave);
  const codigo = texto(c.codigo);
  const pin = texto(c.pin);

  if (!UUID.test(aparato) || !LLAVE.test(llave))
    return no('Este aparato no esta pareado con ninguna caja', 400);

  if (!CODIGO.test(codigo) || !PIN.test(pin))
    return no('Codigo o PIN incorrecto', 400);

  return { ok: true, datos: { aparato, llave, codigo, pin } };
}

/**
 * Como se le contesta al navegador segun lo que dijo la base.
 *
 * Una credencial mala se contesta con 200 y ok:false, no con 401. Dos razones:
 *
 *   1. el navegador tiene que LEER el mensaje para enseñarlo, y un no-2xx
 *      llega al cliente de Supabase como excepcion con el cuerpo escondido
 *   2. es la misma forma que ya usan fn_movimiento_caja y quien_autoriza:
 *      {ok:false, error}. Una sola convencion en todo el sistema.
 *
 * El 401 queda para cuando NO hubo veredicto, que es otra cosa.
 */
export function respuestaDeVeredicto(
  v: Record<string, unknown> | null | undefined,
): { estado: number; cuerpo: Record<string, unknown> } {
  if (!v || typeof v !== 'object')
    return { estado: 500, cuerpo: { ok: false, error: 'sin_respuesta',
             mensaje: 'No se pudo verificar la credencial' } };

  if (v.ok === true) return { estado: 200, cuerpo: v };

  return {
    estado: 200,
    cuerpo: {
      ok: false,
      error: typeof v.error === 'string' ? v.error : 'credencial',
      mensaje: typeof v.mensaje === 'string' ? v.mensaje : 'Codigo o PIN incorrecto',
    },
  };
}

/**
 * Lo que sale de vuelta cuando la credencial era buena.
 *
 * Se arma a mano y no se reenvia lo que vino de la base: asi un dia que
 * alguien le agregue una columna a perfiles, esa columna no se asoma sola al
 * navegador.
 */
export function cuerpoDeSesion(
  v: Record<string, unknown>,
  sesion: { access_token: string; refresh_token: string; expires_in?: number },
) {
  return {
    ok: true,
    sesion: {
      access_token: sesion.access_token,
      refresh_token: sesion.refresh_token,
      expires_in: sesion.expires_in ?? null,
    },
    cajera: {
      perfil_id: v.perfil_id,
      nombre: v.nombre,
      rol: v.rol,
    },
    caja: {
      organizacion_id: v.organizacion_id,
      sucursal_id: v.sucursal_id,
      caja_id: v.caja_id,
    },
  };
}
