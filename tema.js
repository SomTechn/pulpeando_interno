/* ==========================================================================
   El color de la marca.

   Cada negocio elige su color principal en Configuración. De ese solo color
   salen todos los tonos que usa el sistema:

     --marca          el color tal cual: botones principales, lo activo
     --marca-oscuro   al pasar el mouse o al apretar
     --marca-suave    fondos de lo seleccionado (casi blanco, teñido)
     --marca-borde    bordes de lo seleccionado
     --marca-tinta    el color para TEXTO sobre blanco. Si el dueño elige un
                      amarillo, el texto en amarillo no se lee: aquí se
                      oscurece hasta que tenga contraste 4.5:1
     --marca-sobre    la letra que va encima de un botón de la marca:
                      blanca, o tinta oscura si el color es claro

   Este archivo se carga normal (no como módulo) en el <head> de cada
   pantalla, ANTES de pintar: así la pantalla aparece ya con el color del
   negocio, sin un destello del verde de fábrica. El color se recuerda en
   el navegador y se confirma con el que trae fn_pos_contexto.
   ========================================================================== */
(function(){
  var FABRICA = '#12805C';
  var LLAVE = 'pulpeando.color';

  function hexValido(h){ return typeof h === 'string' && /^#[0-9a-fA-F]{6}$/.test(h); }
  function aRgb(h){ return [1, 3, 5].map(function(i){ return parseInt(h.substr(i, 2), 16); }); }
  function aHex(rgb){
    return '#' + rgb.map(function(v){
      v = Math.max(0, Math.min(255, Math.round(v)));
      return (v < 16 ? '0' : '') + v.toString(16);
    }).join('');
  }
  function mezclar(h, con, t){
    var a = aRgb(h), b = aRgb(con);
    return aHex(a.map(function(v, i){ return v + (b[i] - v) * t; }));
  }
  function luminancia(h){
    var c = aRgb(h).map(function(v){
      v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  }
  function contraste(a, b){
    var x = luminancia(a), y = luminancia(b);
    return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
  }

  function tonos(color){
    var m = hexValido(color) ? color.toUpperCase() : FABRICA;
    var tinta = m, n = 0;
    while (contraste(tinta, '#FFFFFF') < 4.5 && n++ < 20) tinta = mezclar(tinta, '#000000', 0.08);
    var oscuro = mezclar(m, '#000000', 0.14);
    var sobre = contraste(m, '#FFFFFF') >= contraste(m, '#0F1729') ? '#FFFFFF' : '#0F1729';
    return {
      '--marca': m,
      '--marca-oscuro': oscuro,
      '--marca-suave': mezclar(m, '#FFFFFF', 0.9),
      '--marca-borde': mezclar(m, '#FFFFFF', 0.7),
      '--marca-tinta': tinta,
      '--marca-sobre': sobre,
      '--marca-sombra': 'rgba(' + aRgb(m).join(',') + ',.45)'
    };
  }

  function aplicar(color, recordar){
    var t = tonos(color), raiz = document.documentElement;
    for (var k in t) raiz.style.setProperty(k, t[k]);
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute('content', t['--marca']);
    if (recordar !== false){
      try { if (hexValido(color)) localStorage.setItem(LLAVE, color); else localStorage.removeItem(LLAVE); }
      catch(e){}
    }
    return t;
  }

  // Lo primero: el color que este navegador ya conoce.
  var guardado = null;
  try { guardado = localStorage.getItem(LLAVE); } catch(e){}
  aplicar(hexValido(guardado) ? guardado : FABRICA, false);

  window.PulpeandoTema = {
    aplicar: aplicar, tonos: tonos, contraste: contraste, valido: hexValido, FABRICA: FABRICA,
    // Colores sugeridos: probados contra blanco y con letra legible encima.
    SUGERIDOS: [
      ['#12805C', 'Pino'], ['#0F766E', 'Turquesa'], ['#1D4ED8', 'Azul rey'],
      ['#0369A1', 'Océano'], ['#4338CA', 'Índigo'], ['#7C3AED', 'Violeta'],
      ['#BE123C', 'Carmesí'], ['#C2410C', 'Naranja'], ['#B45309', 'Ámbar'],
      ['#334155', 'Grafito']
    ]
  };
})();
