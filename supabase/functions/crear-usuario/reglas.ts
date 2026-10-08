// ============================================================================
//  Reglas de quien puede dar de alta a quien.
//
//  Vive aparte del servidor a proposito: son decisiones puras, sin red ni base
//  de datos, y por eso se pueden probar una por una. El index.ts solo hace de
//  cartero. La llave service_role se salta RLS, asi que aqui dentro no hay red
//  de seguridad de la base: estas funciones SON la red.
// ============================================================================

// repartidor 0 · auxiliar 1 · supervisor 2 · gerente 3 · admin 4
export const NIVEL: Record<string, number> = {
  repartidor: 0, auxiliar: 1, supervisor: 2, gerente: 3, admin: 4,
};

export const ROLES_VALIDOS = Object.keys(NIVEL);

export function nivelDe(rol: unknown): number {
  if (typeof rol !== 'string') return -1;
  const n = NIVEL[rol];
  return n === undefined ? -1 : n;
}

export type Solicitante = {
  id: string;
  organizacion_id: string;
  rol: string;
  activo: boolean;
};

export type Alta = {
  nombre: string;
  email: string;
  password: string;
  rol: string;
  telefono: string | null;
  sucursales: string[];
};

export type Veredicto =
  | { ok: true; datos: Alta }
  | { ok: false; error: string; estado: number };

const no = (error: string, estado = 400): Veredicto => ({ ok: false, error, estado });

/** Si quien pide puede dar de alta a alguien, sin mirar todavia a quien. */
export function puedeDarDeAlta(s: Solicitante | null | undefined): Veredicto | null {
  if (!s || !s.activo)
    return no('Su usuario no tiene perfil activo en ningun negocio', 403);
  if (nivelDe(s.rol) < NIVEL.gerente)
    return no('Solo un gerente puede dar de alta usuarios', 403);
  return null;
}

/**
 * Revisa el alta completa. Devuelve los datos ya limpios para que index.ts no
 * vuelva a tocar el cuerpo de la peticion: lo que entra aqui sucio sale
 * normalizado o no sale.
 */
export function validarAlta(s: Solicitante, cuerpo: Record<string, unknown>): Veredicto {
  const puerta = puedeDarDeAlta(s);
  if (puerta) return puerta;

  const nombre = String(cuerpo.nombre ?? '').trim();
  const email = String(cuerpo.email ?? '').trim().toLowerCase();
  const password = String(cuerpo.password ?? '');
  const rol = String(cuerpo.rol ?? '').trim();
  const telefono = cuerpo.telefono ? String(cuerpo.telefono).trim() || null : null;

  if (!nombre) return no('Falta el nombre');
  if (nombre.length > 120) return no('El nombre es demasiado largo');
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return no('El correo no es valido');
  if (email.length > 254) return no('El correo es demasiado largo');
  if (password.length < 8) return no('La contrasena necesita al menos 8 caracteres');
  if (password.length > 72) return no('La contrasena es demasiado larga');

  const nivelNuevo = nivelDe(rol);
  if (nivelNuevo < 0) return no('Ese rol no existe');

  // Nadie crea a alguien con mas poder que el suyo.
  if (nivelNuevo > nivelDe(s.rol))
    return no('No puede crear un usuario con mas permisos que usted', 403);

  // admin es el dueño de la plataforma, no el del local: un gerente que
  // pudiera crear un admin se quedaria con todas las pulperias. Hoy a eso ya
  // lo detiene el chequeo de nivel de arriba, porque admin es el unico rol en
  // nivel 4, y por eso esta linea no se alcanza nunca. Se queda igual: el dia
  // que se agregue otro rol en nivel 4 -un soporte, un auditor- el chequeo de
  // nivel dejaria de alcanzar y esta seria la unica que evita que ese rol
  // reparta cuentas de admin.
  if (rol === 'admin' && s.rol !== 'admin')
    return no('El rol admin no se asigna desde aqui', 403);

  // Las sucursales llegan como ids; que sean del negocio correcto lo confirma
  // index.ts contra la base. Aqui solo se limpia la lista.
  const crudas = Array.isArray(cuerpo.sucursales) ? cuerpo.sucursales : [];
  const sucursales = [...new Set(
    crudas.map((x) => String(x ?? '').trim()).filter(Boolean),
  )];
  if (sucursales.length > 50) return no('Demasiadas sucursales');

  return { ok: true, datos: { nombre, email, password, rol, telefono, sucursales } };
}

/**
 * Las sucursales pedidas tienen que estar TODAS entre las que la base dice que
 * son del negocio de quien pide. Si falta una, se rechaza el alta completa en
 * vez de asignar las que si eran: un alta a medias es peor que ninguna.
 */
export function sucursalesCoinciden(pedidas: string[], halladas: string[]): boolean {
  if (pedidas.length !== halladas.length) return false;
  const set = new Set(halladas);
  return pedidas.every((p) => set.has(p));
}

/** Si el rol recien creado necesita PIN para operar caja. */
export function necesitaPin(rol: string): boolean {
  return nivelDe(rol) >= NIVEL.auxiliar;
}
