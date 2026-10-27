/* Pruebas de la puerta de caja. Corre con:  node reglas.prueba.mjs */
import { validarEntrada, respuestaDeVeredicto, cuerpoDeSesion } from './reglas.ts';

let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); }
                        else { mal++; console.log('  MAL  ' + n); } };

const APARATO = 'aaaa0000-1111-4222-8333-444455556666';
const LLAVE   = 'a'.repeat(48);
const bueno   = { aparato:APARATO, llave:LLAVE, codigo:'C7', pin:'45678' };
const con     = (extra) => validarEntrada({ ...bueno, ...extra });

console.log('\n=== Lo que pasa ===');
{
  const v = con({});
  chk('la entrada completa pasa', v.ok === true);
  chk('devuelve los cuatro campos',
      v.ok && v.datos.aparato === APARATO && v.datos.llave === LLAVE &&
      v.datos.codigo === 'C7' && v.datos.pin === '45678');
}
chk('el codigo en minuscula pasa tal cual (la base compara en mayuscula)',
    con({ codigo:'c7' }).datos?.codigo === 'c7');
chk('los espacios de sobra se recortan',
    con({ codigo:'  C7 ', pin:' 45678 ' }).datos?.codigo === 'C7');
chk('la llave en mayuscula pasa', con({ llave:'A'.repeat(48) }).ok === true);
chk('un PIN de cuatro pasa', con({ pin:'4567' }).ok === true);
chk('un PIN de ocho pasa', con({ pin:'45678901' }).ok === true);
chk('un codigo de ocho pasa', con({ codigo:'ABCD1234' }).ok === true);

console.log('\n=== El aparato ===');
chk('sin aparato no se intenta', con({ aparato:'' }).ok === false);
chk('un aparato que no es uuid no se intenta', con({ aparato:'C7' }).ok === false);
chk('un uuid a medias no pasa',
    con({ aparato:'aaaa0000-1111-4222-8333-4444' }).ok === false);
chk('sin llave no se intenta', con({ llave:'' }).ok === false);
chk('una llave corta no pasa', con({ llave:'a'.repeat(47) }).ok === false);
chk('una llave larga no pasa', con({ llave:'a'.repeat(49) }).ok === false);
chk('una llave con signos no pasa', con({ llave:'z'.repeat(48) }).ok === false);
chk('el error del aparato dice que hay que parear',
    /pareado/i.test(con({ aparato:'x' }).error));

console.log('\n=== La credencial ===');
chk('sin codigo no pasa', con({ codigo:'' }).ok === false);
chk('sin PIN no pasa', con({ pin:'' }).ok === false);
chk('un codigo de nueve no pasa', con({ codigo:'ABCDEFGHI' }).ok === false);
chk('un codigo con signos no pasa', con({ codigo:'C-7' }).ok === false);
chk('un codigo con espacio adentro no pasa', con({ codigo:'C 7' }).ok === false);
chk('un PIN con letras no pasa', con({ pin:'4567a' }).ok === false);
chk('un PIN de tres no pasa', con({ pin:'456' }).ok === false);
chk('un PIN de nueve no pasa', con({ pin:'456789012' }).ok === false);

/* Al que esta probando no se le dice cual de los dos venia mal. */
chk('el codigo malo y el PIN malo dan el MISMO mensaje',
    con({ codigo:'' }).error === con({ pin:'' }).error);
chk('y ese mensaje no nombra ni el codigo ni el PIN por separado',
    con({ pin:'' }).error === 'Codigo o PIN incorrecto');

console.log('\n=== Cuerpos raros ===');
for (const [nombre, c] of [['null', null], ['texto', 'C7'], ['numero', 7],
                           ['arreglo', [bueno]], ['vacio', {}]])
  chk('un cuerpo ' + nombre + ' no pasa', validarEntrada(c).ok === false);
chk('un campo que no es texto no pasa', con({ pin: 45678 }).ok === false);
chk('un campo objeto no pasa', con({ codigo: { toString: () => 'C7' } }).ok === false);

console.log('\n=== Como se contesta ===');
{
  const r = respuestaDeVeredicto({ ok:false, error:'credencial',
                                   mensaje:'Codigo o PIN incorrecto' });
  chk('la credencial mala va con 200, no con 401', r.estado === 200);
  chk('...y el navegador puede leer el mensaje',
      r.cuerpo.mensaje === 'Codigo o PIN incorrecto');
  chk('...y viene marcada como fallida', r.cuerpo.ok === false);
}
{
  const r = respuestaDeVeredicto({ ok:false, error:'aparato_bloqueado',
                                   mensaje:'Demasiados intentos' });
  chk('el aparato bloqueado conserva su tipo de error',
      r.cuerpo.error === 'aparato_bloqueado');
}
chk('sin respuesta de la base es 500', respuestaDeVeredicto(null).estado === 500);
chk('una respuesta que no es objeto es 500',
    respuestaDeVeredicto('ok').estado === 500);
{
  const r = respuestaDeVeredicto({ ok:false });
  chk('un {ok:false} pelado igual trae mensaje',
      typeof r.cuerpo.mensaje === 'string' && r.cuerpo.mensaje.length > 0);
}

console.log('\n=== Lo que sale de vuelta ===');
{
  const v = { ok:true, perfil_id:'p1', nombre:'Cajera Mari', rol:'auxiliar',
              email:'cajera@t.hn', organizacion_id:'o1', sucursal_id:'s1',
              caja_id:'c1', pin_pos:'$2a$NO_DEBE_SALIR' };
  const c = cuerpoDeSesion(v, { access_token:'at', refresh_token:'rt', expires_in:3600 });

  chk('va la sesion', c.sesion.access_token === 'at' && c.sesion.refresh_token === 'rt');
  chk('va quien es', c.cajera.nombre === 'Cajera Mari' && c.cajera.rol === 'auxiliar');
  chk('va donde esta', c.caja.sucursal_id === 's1' && c.caja.caja_id === 'c1');

  /* Se arma a mano justamente para esto: lo que la base devuelva de mas no
     se asoma solo al navegador. */
  const plano = JSON.stringify(c);
  chk('NO sale el hash del PIN', !plano.includes('NO_DEBE_SALIR'));
  chk('NO sale el correo de la empleada', !plano.includes('cajera@t.hn'));
  chk('no quedan campos sueltos del veredicto',
      Object.keys(c).sort().join(',') === 'caja,cajera,ok,sesion');
}
{
  const c = cuerpoDeSesion({}, { access_token:'at', refresh_token:'rt' });
  chk('sin expires_in queda en null', c.sesion.expires_in === null);
}

console.log(`\n${ok} bien · ${mal} mal`);
process.exit(mal ? 1 : 0);
