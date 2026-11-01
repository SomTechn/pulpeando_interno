/* Pruebas de las reglas del registro de negocios. */
import { validarRegistro, pinValido, limpiarTelefono, correoValido, ipDe, mensajeDeLaBase }
  from './reglas.ts';

let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };

const base = { negocio:'Pulpería La Bendición', nombre:'Rosa Martínez', telefono:'9999-1234',
               email:'Rosa@Correo.hn', password:'tienda2026', pin:'40719' };
const con = (extra) => validarRegistro({ ...base, ...extra });

console.log('\n=== Un registro bueno ===');
const b = validarRegistro(base);
chk('pasa', b.ok === true);
chk('correo en minúsculas', b.ok && b.datos.email === 'rosa@correo.hn');
chk('teléfono 9999-1234', b.ok && b.datos.telefono === '9999-1234');
chk('sin muestra si no la pide', b.ok && b.datos.muestra === false);
chk('sucursal null si viene vacía', b.ok && b.datos.sucursal === null);
chk('muestra solo con true de verdad', con({ muestra:'true' }).datos?.muestra === false && con({ muestra:true }).datos?.muestra === true);
chk('espacios de más se limpian', con({ negocio:'  La   Bendición  ' }).datos?.negocio === 'La Bendición');
chk('nombre larguísimo se corta a 80', con({ negocio:'x'.repeat(300) }).datos?.negocio.length === 80);

console.log('\n=== Lo que se rechaza ===');
chk('sin cuerpo', validarRegistro(null).ok === false);
chk('negocio corto', con({ negocio:'AB' }).ok === false);
chk('nombre corto', con({ nombre:'R' }).ok === false);
chk('negocio no texto', con({ negocio:{ a:1 } }).ok === false);
chk('teléfono de 7 dígitos', con({ telefono:'999123' }).ok === false);
chk('correo sin arroba', con({ email:'rosa.correo.hn' }).ok === false);
chk('contraseña de 7', con({ password:'abc1234' }).ok === false);
chk('contraseña 12345678', con({ password:'12345678' }).ok === false);
chk('contraseña repetida', con({ password:'aaaaaaaa' }).ok === false);
chk('contraseña igual al correo', con({ password:'rosa@correo.hn' }).ok === false);
chk('contraseña de 100', con({ password:'x1'.repeat(50) }).ok === false);
chk('PIN 11111', con({ pin:'11111' }).ok === false);
chk('PIN 12345', con({ pin:'12345' }).ok === false);
chk('PIN de 4', con({ pin:'4071' }).ok === false);
chk('PIN con letra', con({ pin:'4a719' }).ok === false);
chk('PIN numérico se acepta como texto', con({ pin:40719 }).ok === true);

console.log('\n=== Campo trampa ===');
const robot = con({ sitio_web:'http://spam.example' });
chk('se rechaza', robot.ok === false);
chk('marcado como robot', robot.ok === false && robot.robot === true);
chk('vacío no molesta', con({ sitio_web:'' }).ok === true);

console.log('\n=== Ayudantes ===');
chk('pin bueno', pinValido('40719') === null);
chk('pin 98765 fácil', pinValido('98765') !== null);
chk('tel con 504', limpiarTelefono('+504 9999 1234') === '9999-1234');
chk('tel fijo 2', limpiarTelefono('22345678') === '2234-5678');
chk('tel que empieza en 1 no', limpiarTelefono('12345678') === null);
chk('tel null', limpiarTelefono(null) === null);
chk('correo bueno', correoValido('a@b.hn'));
chk('correo sin dominio', !correoValido('a@b'));
const h = (o) => ({ get:(n) => o[n] ?? null });
chk('ip del primer x-forwarded-for', ipDe(h({ 'x-forwarded-for':'1.2.3.4, 10.0.0.1' })) === '1.2.3.4');
chk('ip de cf', ipDe(h({ 'cf-connecting-ip':'5.6.7.8' })) === '5.6.7.8');
chk('sin ip', ipDe(h({})) === '?');
chk('mensaje propio pasa', mensajeDeLaBase('Ese PIN es muy fácil de adivinar. Escoja otro').includes('PIN'));
chk('error técnico se tapa', mensajeDeLaBase('duplicate key value violates unique constraint').startsWith('No se pudo'));
chk('null se tapa', mensajeDeLaBase(null).startsWith('No se pudo'));

console.log(`\n${ok} bien, ${mal} mal`);
if (mal) process.exit(1);
