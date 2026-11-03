/* Prueba de instalar.js: el botón de instalar la app en cada caso. */
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';

const CODIGO = fs.readFileSync(fileURLToPath(new URL('./instalar.js', import.meta.url)), 'utf8');
let ok = 0, mal = 0;
const chk = (n, c) => { if (c){ ok++; console.log('  ok   ' + n); } else { mal++; console.log('  MAL  ' + n); } };
const esperar = (ms = 20) => new Promise(r => setTimeout(r, ms));

function montar({ ua = 'Mozilla/5.0 (Linux; Android 14) Chrome/130', standalone = false } = {}){
  const dom = new JSDOM('<!doctype html><html><head></head><body><div id="z"></div></body></html>',
    { runScripts:'outside-only', url:'https://x.test/' });
  const w = dom.window;
  Object.defineProperty(w.navigator, 'userAgent', { value:ua, configurable:true });
  w.matchMedia = q => ({ matches: standalone && /standalone/.test(q), addEventListener(){}, removeEventListener(){} });
  w.eval(CODIGO);
  return { w, d:w.document };
}
function evento(w){
  const e = new w.Event('beforeinstallprompt', { cancelable:true });
  e.llamado = false;
  e.prompt = () => { e.llamado = true; };
  e.userChoice = Promise.resolve({ outcome:'accepted' });
  w.dispatchEvent(e);
  return e;
}

console.log('\n=== INSTALAR LA APP ===');
{
  const { w, d } = montar();
  const PI = w.PulpeandoInstalar;
  PI.montar(d.querySelector('#z'), { texto:'Instalar Pulpeando' });
  chk('sin aviso del navegador, explica cómo hacerlo desde el menú', PI.modo() === 'manual');
  d.querySelector('.pi-btn').click();
  await esperar();
  chk('al tocar el botón enseña los pasos', /Instalar app/.test(d.querySelector('.pi-ayuda').textContent)
      && !d.querySelector('.pi-ayuda').classList.contains('oculto'));
  const e = evento(w);
  chk('guarda el aviso de Chrome y no deja que salga solo', e.defaultPrevented && PI.modo() === 'directo');
  d.querySelector('.pi-btn').click();
  await esperar();
  chk('con el aviso, el botón abre el cuadro de instalar', e.llamado);
  chk('aceptado, el botón desaparece', PI.modo() === 'instalada' && d.querySelector('#z').classList.contains('oculto'));
}
{
  const { w, d } = montar({ ua:'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Safari/604.1' });
  const PI = w.PulpeandoInstalar;
  PI.montar(d.querySelector('#z'));
  chk('en iPhone dice cómo con Compartir', PI.modo() === 'ios' && /Compartir/.test(PI.pasos()) && /Agregar a inicio/.test(PI.pasos()));
}
{
  const { w, d } = montar({ standalone:true });
  w.PulpeandoInstalar.montar(d.querySelector('#z'));
  chk('abierta como app no enseña nada', d.querySelector('#z').classList.contains('oculto'));
}
{
  const { w } = montar();
  let visto = null;
  w.PulpeandoInstalar.alCambiar(m => { visto = m; });
  evento(w);
  w.dispatchEvent(new w.Event('appinstalled'));
  chk('avisa cuando se instala desde el menú del navegador', visto === 'instalada');
}

console.log(`\n${ok} bien · ${mal} mal`);
process.exit(mal ? 1 : 0);
