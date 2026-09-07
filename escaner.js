/* ==========================================================================
   Escáner de códigos de barras y QR con la cámara.
   Compartido por la caja y por la entrada de mercadería.

   Usa BarcodeDetector, que viene en el navegador de Android y en Chrome de
   escritorio. Donde no existe (iPhone, Firefox) carga ZXing por detrás.
   El usuario no nota la diferencia.

   Uso:
     import { escanear } from './escaner.js';

     // una sola lectura
     const codigo = await escanear();

     // modo continuo: se queda abierto y va avisando cada lectura
     await escanear({
       continuo: true,
       titulo: 'Escanear productos',
       alLeer: async (codigo) => ({ ok:true, texto:'Leche entera', cuenta:'x2' })
     });

   REQUIERE HTTPS. Los navegadores no dan la cámara por http://.
   ========================================================================== */

let detectorCache = null;

/* -------------------------------------------------------------------------
   Detector: primero el del navegador, si no ZXing
   ------------------------------------------------------------------------- */
async function crearDetector(){
  if (detectorCache) return detectorCache;

  if ('BarcodeDetector' in window){
    try{
      const soportados = await window.BarcodeDetector.getSupportedFormats();
      const deseados = ['ean_13','ean_8','upc_a','upc_e','code_128','code_39',
                        'itf','codabar','qr_code'];
      const formats = deseados.filter(f => soportados.includes(f));
      if (formats.length){
        const bd = new window.BarcodeDetector({ formats });
        detectorCache = {
          motor: 'navegador',
          async leer(video){
            const r = await bd.detect(video);
            return r.length ? String(r[0].rawValue || '').trim() : null;
          }
        };
        return detectorCache;
      }
    }catch(e){ /* sigue al plan B */ }
  }

  const mod = await import('https://esm.sh/@zxing/library@0.21.3');
  const lector = new mod.BrowserMultiFormatReader();
  const lienzo = document.createElement('canvas');
  const ctx = lienzo.getContext('2d', { willReadFrequently: true });

  detectorCache = {
    motor: 'zxing',
    async leer(video){
      if (!video.videoWidth) return null;
      // se analiza a la mitad de resolución: suficiente y bastante más rápido
      const escala = video.videoWidth > 1280 ? 0.5 : 1;
      lienzo.width  = Math.round(video.videoWidth  * escala);
      lienzo.height = Math.round(video.videoHeight * escala);
      ctx.drawImage(video, 0, 0, lienzo.width, lienzo.height);
      try{
        return String(lector.decodeFromCanvas(lienzo).getText() || '').trim();
      }catch(e){
        return null;   // no encontró código en este cuadro, es lo normal
      }
    }
  };
  return detectorCache;
}

/* -------------------------------------------------------------------------
   Avisos: pitido corto y vibración
   ------------------------------------------------------------------------- */
let audio = null;
function pitar(agudo = true){
  try{
    audio = audio || new (window.AudioContext || window.webkitAudioContext)();
    if (audio.state === 'suspended') audio.resume();
    const osc = audio.createOscillator();
    const vol = audio.createGain();
    osc.type = 'sine';
    osc.frequency.value = agudo ? 1180 : 380;
    vol.gain.setValueAtTime(0.0001, audio.currentTime);
    vol.gain.exponentialRampToValueAtTime(0.18, audio.currentTime + 0.01);
    vol.gain.exponentialRampToValueAtTime(0.0001, audio.currentTime + 0.13);
    osc.connect(vol); vol.connect(audio.destination);
    osc.start(); osc.stop(audio.currentTime + 0.14);
  }catch(e){}
  try{ navigator.vibrate?.(agudo ? 40 : [50,40,50]); }catch(e){}
}

/* -------------------------------------------------------------------------
   Escáner
   ------------------------------------------------------------------------- */
export async function escanear(opciones = {}){
  const {
    continuo = false,
    titulo = continuo ? 'Escanear productos' : 'Escanear código',
    pista = 'Acerque el código de barras al recuadro',
    alLeer = null
  } = opciones;

  return new Promise(async (resolver) => {
    const capa = document.createElement('div');
    capa.className = 'escaner';
    capa.innerHTML = `
      <video playsinline muted autoplay></video>
      <div class="escaner-capa">
        <div class="escaner-arriba">
          <b>${titulo}</b>
          <button class="escaner-btn" data-a="linterna" title="Linterna" hidden>🔦</button>
          <button class="escaner-btn" data-a="camara" title="Cambiar cámara" hidden>⟳</button>
          <button class="escaner-btn" data-a="cerrar" title="Cerrar">✕</button>
        </div>
        <div class="escaner-medio">
          <div class="mira"><i></i><i></i><i></i><i></i><span class="raya"></span></div>
        </div>
        <div class="escaner-abajo">
          <div class="escaner-pista">${pista}</div>
          <div class="escaner-leidos"></div>
          <div class="escaner-acciones">
            <button class="escaner-manual" data-a="manual">Digitar código</button>
            ${continuo ? '<button class="btn principal-b" data-a="listo">Listo</button>' : ''}
          </div>
        </div>
      </div>`;
    document.body.appendChild(capa);

    const video    = capa.querySelector('video');
    const mira     = capa.querySelector('.mira');
    const pistaEl  = capa.querySelector('.escaner-pista');
    const leidosEl = capa.querySelector('.escaner-leidos');
    const btnLuz   = capa.querySelector('[data-a="linterna"]');
    const btnCam   = capa.querySelector('[data-a="camara"]');

    let flujo = null, pista_ = null, corriendo = true, timer = null;
    let camaras = [], iCamara = 0, luz = false;
    let ultimo = '', ultimoEn = 0;

    function terminar(valor){
      corriendo = false;
      clearTimeout(timer);
      try{ flujo?.getTracks().forEach(t => t.stop()); }catch(e){}
      capa.remove();
      resolver(valor);
    }

    function fallo(titulo_, texto){
      const aviso = document.createElement('div');
      aviso.className = 'escaner-aviso';
      aviso.innerHTML = `
        <div>
          <h3>${titulo_}</h3>
          <p>${texto}</p>
          <button class="btn principal-b" style="width:100%;margin-bottom:10px" data-f="manual">
            Digitar el código a mano</button>
          <button class="btn secundario" style="width:100%" data-f="cerrar">Cerrar</button>
        </div>`;
      capa.appendChild(aviso);
      aviso.querySelector('[data-f="cerrar"]').onclick = () => terminar(null);
      aviso.querySelector('[data-f="manual"]').onclick = pedirManual;
    }

    function pedirManual(){
      const codigo = prompt('Escriba el código del producto:');
      if (codigo && codigo.trim()) procesar(codigo.trim(), true);
      else if (!continuo) terminar(null);
    }

    function anotar(texto, ok){
      const fila = document.createElement('div');
      fila.className = 'leido' + (ok ? '' : ' error');
      fila.innerHTML = `<span>${ok ? '✓' : '!'}</span><b></b>` +
                       (ok && texto.cuenta ? `<span class="cuenta">${texto.cuenta}</span>` : '');
      fila.querySelector('b').textContent = texto.texto || texto;
      leidosEl.prepend(fila);
      while (leidosEl.children.length > 6) leidosEl.lastChild.remove();
    }

    async function procesar(codigo, manual){
      const ahora = Date.now();
      // el mismo código seguido se ignora: la cámara lo ve muchas veces
      if (!manual && codigo === ultimo && ahora - ultimoEn < 1600) return;
      ultimo = codigo; ultimoEn = ahora;

      mira.classList.add('acierto');
      setTimeout(() => mira.classList.remove('acierto'), 320);

      if (!continuo){ pitar(true); terminar(codigo); return; }

      let r = { ok:true, texto:codigo };
      if (alLeer){
        try{ r = await alLeer(codigo) || r; }
        catch(e){ r = { ok:false, texto:'Error: ' + (e.message || e) }; }
      }
      pitar(r.ok);
      anotar(r, r.ok);
    }

    async function ciclo(){
      if (!corriendo) return;
      try{
        const codigo = await detector.leer(video);
        if (codigo) await procesar(codigo, false);
      }catch(e){ /* un cuadro malo no debe tumbar el ciclo */ }
      if (corriendo) timer = setTimeout(ciclo, detector.motor === 'navegador' ? 110 : 180);
    }

    async function encender(idCamara){
      try{ flujo?.getTracks().forEach(t => t.stop()); }catch(e){}
      flujo = await navigator.mediaDevices.getUserMedia({
        video: idCamara
          ? { deviceId:{ exact:idCamara }, width:{ ideal:1280 }, height:{ ideal:720 } }
          : { facingMode:{ ideal:'environment' }, width:{ ideal:1280 }, height:{ ideal:720 } },
        audio: false
      });
      video.srcObject = flujo;
      await video.play().catch(()=>{});
      pista_ = flujo.getVideoTracks()[0];

      // linterna, solo si el aparato la ofrece
      const cap = pista_.getCapabilities ? pista_.getCapabilities() : {};
      btnLuz.hidden = !cap.torch;
      luz = false; btnLuz.classList.remove('on');
    }

    // ---- arranque ----
    if (!navigator.mediaDevices?.getUserMedia){
      fallo('Este navegador no da acceso a la cámara',
            'Puede pasar si la página no se abrió por HTTPS. Igual puede digitar el código.');
      return;
    }

    let detector;
    try{
      await encender(null);
      detector = await crearDetector();
      pistaEl.textContent = pista;
      ciclo();
    }catch(e){
      const n = e?.name || '';
      if (n === 'NotAllowedError')
        fallo('Falta el permiso de la cámara',
              'Toque el candado junto a la dirección, permita la cámara y vuelva a intentar.');
      else if (n === 'NotFoundError')
        fallo('No se encontró ninguna cámara', 'Este aparato no tiene cámara disponible.');
      else
        fallo('No se pudo abrir la cámara', e?.message || 'Intente de nuevo.');
      return;
    }

    // varias cámaras: se ofrece cambiar
    try{
      const disp = await navigator.mediaDevices.enumerateDevices();
      camaras = disp.filter(d => d.kind === 'videoinput');
      btnCam.hidden = camaras.length < 2;
    }catch(e){}

    // ---- botones ----
    capa.addEventListener('click', async e => {
      const b = e.target.closest('[data-a]'); if (!b) return;
      const a = b.dataset.a;

      if (a === 'cerrar' || a === 'listo') terminar(null);

      if (a === 'manual') pedirManual();

      if (a === 'linterna'){
        try{
          luz = !luz;
          await pista_.applyConstraints({ advanced:[{ torch: luz }] });
          btnLuz.classList.toggle('on', luz);
        }catch(err){ btnLuz.hidden = true; }
      }

      if (a === 'camara'){
        iCamara = (iCamara + 1) % camaras.length;
        try{ await encender(camaras[iCamara].deviceId); }
        catch(err){ pistaEl.textContent = 'No se pudo cambiar de cámara'; }
      }
    });

    // cerrar con Escape
    const salir = ev => { if (ev.key === 'Escape'){ document.removeEventListener('keydown', salir); terminar(null); } };
    document.addEventListener('keydown', salir);

    // al ocultar la pestaña se suelta la cámara
    document.addEventListener('visibilitychange', function ocultar(){
      if (document.hidden && corriendo){
        document.removeEventListener('visibilitychange', ocultar);
        terminar(null);
      }
    });
  });
}

/* Para decidir si vale la pena mostrar el botón de cámara */
export function hayCamara(){
  return !!(navigator.mediaDevices?.getUserMedia) &&
         (window.isSecureContext !== false);
}
