/* Las vistas: lo que antes flotaba ahora es una pantalla dentro de .principal */
import { JSDOM } from 'jsdom';

let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); } else { mal++; console.log('  MAL  ' + n); } };
const esperar = (ms = 20) => new Promise(r => setTimeout(r, ms));

const dom = new JSDOM(`<!doctype html><body>
  <div class="armazon"><aside id="menu"></aside><div class="principal"><header class="barra">x</header></div></div>
  <div class="form-velo oculto" id="form-velo"><div class="cajon"><div class="cajon-enc"><h2>Producto</h2>
    <button class="cerrar-x" id="form-cerrar">✕</button></div><div class="cajon-cuerpo"></div></div></div>
  <div class="velo oculto" id="velo"><div class="hoja" id="hoja"></div></div>
</body>`, { url:'https://x.test/catalogo.html', pretendToBeVisual:true });
const w = dom.window, d = w.document;
w.__conVistas = true;
globalThis.window = w; globalThis.document = d;
const { activarVistas, esMensaje } = await import('./vistas.js');
activarVistas(d);
const $ = s => d.querySelector(s);
const ver = (id, si = true) => $(id).classList.toggle('oculto', !si);

console.log('\n=== DÓNDE QUEDAN ===');
chk('el panel y la hoja viven dentro de .principal',
    $('#velo').parentElement.classList.contains('principal') && $('#form-velo').parentElement.classList.contains('principal'));
chk('marcados como vistas', $('#velo').classList.contains('vista') && $('#form-velo').classList.contains('vista'));
chk('la hoja trae su «← Volver»', /Volver/.test($('#velo .vista-barra').textContent));

console.log('\n=== UN FORMULARIO ES UNA PANTALLA ===');
let cancelo = 0;
$('#hoja').innerHTML = `<h2>Caja nueva</h2><input id="n"><button id="no">Cancelar</button><button id="si">Guardar</button>`;
$('#no').onclick = () => { cancelo++; ver('#velo', false); };
ver('#velo');
await esperar();
chk('se queda abierto como vista', !$('#velo').classList.contains('oculto'));
chk('sin aviso flotante', !$('.aviso-flotante'));
$('.vista-volver').click();
await esperar();
chk('Volver usa su propio Cancelar', cancelo === 1 && $('#velo').classList.contains('oculto'));

console.log('\n=== UN MENSAJE CORTO ES UN AVISO ===');
let entendido = 0;
$('#hoja').innerHTML = `<h2>Guardado</h2><p>Los próximos tickets salen con estos datos.</p><button id="ok">Entendido</button>`;
$('#ok').onclick = () => { entendido++; ver('#velo', false); };
chk('se reconoce como mensaje', esMensaje($('#hoja')));
ver('#velo');
await esperar();
const af = $('.aviso-flotante');
chk('no abre la pantalla', $('#velo').classList.contains('oculto'));
chk('sale el aviso con su texto', af && /Guardado/.test(af.textContent) && /próximos tickets/.test(af.textContent));
chk('sin repetir «Entendido» como botón', af && !af.querySelector('.af-accion'));
af.querySelector('.af-x').click();
await esperar();
chk('al cerrarlo se aprieta su «Entendido» por debajo', entendido === 1);

console.log('\n=== CON OTRA ACCIÓN, ESPERA ===');
let reintento = 0;
$('#hoja').innerHTML = `<h2>No se pudo guardar</h2><p>Sin conexión</p><button id="r">Reintentar</button>`;
$('#r').onclick = () => { reintento++; };
ver('#velo');
await esperar();
const af2 = $('.aviso-flotante:not(.saliendo)');
chk('el de error sale en rojo', af2?.classList.contains('malo'));
chk('trae su botón de acción', af2?.querySelector('.af-accion')?.textContent === 'Reintentar');
af2.querySelector('.af-accion').click();
await esperar();
chk('la acción corre al tocarla', reintento === 1);

console.log('\n=== CARGANDO NO ES UN MENSAJE ===');
$('#hoja').innerHTML = `<span class="girando"></span>`;
ver('#velo');
await esperar();
chk('un «cargando» deja la pantalla abierta', !$('#velo').classList.contains('oculto'));
$('#hoja').innerHTML = `<h2>Elija</h2><select></select><button>Cancelar</button><button>Listo</button>`;
await esperar();
chk('y cuando llega el contenido sigue ahí', !$('#velo').classList.contains('oculto'));
ver('#velo', false);

console.log('\n=== EL PANEL LATERAL ===');
let cerro = 0;
$('#form-cerrar').addEventListener('click', () => { cerro++; ver('#form-velo', false); });
ver('#form-velo');
await esperar();
d.dispatchEvent(new w.KeyboardEvent('keydown', { key:'Escape' }));
await esperar();
chk('Esc lo cierra con su propio botón', cerro === 1 && $('#form-velo').classList.contains('oculto'));
chk('su ✕ se anuncia como Volver', $('#form-cerrar').getAttribute('aria-label') === 'Volver');

console.log('\n' + ok + ' bien, ' + mal + ' mal');
process.exit(mal ? 1 : 0);
