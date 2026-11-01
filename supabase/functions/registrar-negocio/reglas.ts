// ============================================================================
//  Reglas del registro de un negocio nuevo.
//
//  Decisiones puras, sin red ni base, para probarlas una por una. La base
//  vuelve a revisar lo importante en fn_crear_negocio (PIN, largo de nombres,
//  registro abierto); aquí se limpia lo que llega del navegador y se corta
//  temprano lo que no tiene sentido mandar.
// ============================================================================

export type Registro = {
  negocio: string;
  sucursal: string | null;
  direccion: string | null;
  nombre: string;
  telefono: string;
  email: string;
  password: string;
  pin: string;
  muestra: boolean;
};

export type Veredicto =
  | { ok: true; datos: Registro }
  | { ok: false; error: string; estado: number; robot?: boolean };

const no = (error: string, estado = 400): Veredicto => ({ ok: false, error, estado });

const texto = (v: unknown, max: number): string =>
  typeof v === 'string' ? v.replace(/\s+/g, ' ').trim().slice(0, max) : '';

export const PIN_FACILES = new Set(['12345', '54321', '01234', '98765']);

export function pinValido(pin: string): string | null {
  if (!/^[0-9]{5}$/.test(pin)) return 'El PIN de caja tiene 5 dígitos';
  if (/^(.)\1{4}$/.test(pin) || PIN_FACILES.has(pin)) return 'Ese PIN es muy fácil de adivinar. Escoja otro';
  return null;
}

/** Teléfono hondureño: 8 dígitos, o con 504 delante. Se guarda como 9999-9999. */
export function limpiarTelefono(v: unknown): string | null {
  const d = String(v ?? '').replace(/\D/g, '').replace(/^504(?=\d{8}$)/, '');
  if (!/^[2-9]\d{7}$/.test(d)) return null;
  return d.slice(0, 4) + '-' + d.slice(4);
}

export function correoValido(v: string): boolean {
  return v.length <= 120 && /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(v);
}

export function validarRegistro(cuerpo: Record<string, unknown> | null | undefined): Veredicto {
  if (!cuerpo || typeof cuerpo !== 'object') return no('Faltan los datos');

  // Campo trampa: el formulario lo esconde, una persona no lo llena.
  if (texto(cuerpo.sitio_web, 200) !== '') return { ok: false, error: 'No se pudo registrar', estado: 400, robot: true };

  const negocio = texto(cuerpo.negocio, 80);
  const nombre = texto(cuerpo.nombre, 80);
  const email = texto(cuerpo.email, 120).toLowerCase();
  const password = typeof cuerpo.password === 'string' ? cuerpo.password : '';
  const pin = typeof cuerpo.pin === 'string' ? cuerpo.pin.trim() : String(cuerpo.pin ?? '');

  if (negocio.length < 3) return no('Escriba el nombre del negocio (3 letras o más)');
  if (nombre.length < 3) return no('Escriba su nombre (3 letras o más)');
  const telefono = limpiarTelefono(cuerpo.telefono);
  if (!telefono) return no('El teléfono tiene 8 dígitos');
  if (!correoValido(email)) return no('Revise el correo');
  if (password.length < 8) return no('La contraseña lleva 8 caracteres o más');
  if (password.length > 72) return no('La contraseña es demasiado larga');
  if (password.toLowerCase() === email || /^(.)\1+$/.test(password) || /^(12345678|password|contraseña)/i.test(password))
    return no('Esa contraseña es muy fácil. Escoja otra');
  const malPin = pinValido(pin);
  if (malPin) return no(malPin);

  return {
    ok: true,
    datos: {
      negocio,
      sucursal: texto(cuerpo.sucursal, 60) || null,
      direccion: texto(cuerpo.direccion, 160) || null,
      nombre,
      telefono,
      email,
      password,
      pin,
      muestra: cuerpo.muestra === true,
    },
  };
}

/** La IP de quien pide, detrás del proxy de Supabase. */
export function ipDe(h: { get(n: string): string | null }): string {
  const xff = h.get('x-forwarded-for');
  if (xff) return xff.split(',')[0].trim() || '?';
  return h.get('cf-connecting-ip') || h.get('x-real-ip') || '?';
}

/** Traduce lo que devuelve la base a algo que el dueño entienda. */
export function mensajeDeLaBase(m: string | undefined | null): string {
  const t = String(m ?? '');
  // Los raise exception propios ya vienen en español y para el usuario
  if (/PIN|nombre|registro|negocio|usuario|letras/i.test(t) && !/violates|duplicate|syntax/i.test(t)) return t;
  return 'No se pudo crear el negocio. Intente de nuevo en un momento';
}
