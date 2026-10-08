/* Service worker de la app del cliente.

   La cascara se cachea para que la app abra sin internet y se pueda instalar.
   Lo que NUNCA se cachea son las llamadas a Supabase: un catalogo viejo le
   muestra al cliente precios que ya no son, o productos que se acabaron, y
   eso termina en un pedido que la pulperia no puede surtir. Mejor la pantalla
   diciendo que no hay conexion. */
const CACHE = 'pulpeando-cliente-v1';
const CONCHA = [
  './',
  './index.html',
  './manifest.webmanifest',
  '../config.js',
  '../icono-192.png',
  '../icono-512.png'
];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE)
      // addAll falla entero si un archivo falla; asi cada uno va por su cuenta
      .then(c => Promise.allSettled(CONCHA.map(u => c.add(u))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);

  // Nada de la API, la autenticacion ni las funciones se guarda
  if (url.pathname.startsWith('/rest/') ||
      url.pathname.startsWith('/auth/') ||
      url.pathname.startsWith('/realtime/') ||
      url.pathname.startsWith('/functions/')) return;

  if (e.request.method !== 'GET') return;

  // Primero la red; si falla, lo que haya guardado
  e.respondWith(
    fetch(e.request)
      .then(r => {
        if (r.ok && (url.origin === location.origin || url.host.includes('fonts.'))){
          const copia = r.clone();
          caches.open(CACHE).then(c => c.put(e.request, copia));
        }
        return r;
      })
      .catch(() => caches.match(e.request).then(r => r || caches.match('./index.html')))
  );
});
