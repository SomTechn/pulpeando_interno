/* Service worker del POS.
   La app se cachea para que abra sin internet. Las llamadas a Supabase
   NUNCA se cachean: los datos viejos en una caja hacen más daño que la
   pantalla vacía, y las ventas offline ya viajan en su propia cola. */
const CACHE = 'pos-abarrotes-v3';
const CONCHA = [
  './',
  './index.html',
  './compras.html',
  './config.js',
  './manifest.webmanifest',
  './icono-192.png',
  './icono-512.png'
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(CONCHA)).then(() => self.skipWaiting()));
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

  // Nada de la API ni de la autenticación se guarda en caché
  if (url.pathname.startsWith('/rest/') ||
      url.pathname.startsWith('/auth/') ||
      url.pathname.startsWith('/realtime/')) return;

  if (e.request.method !== 'GET') return;

  // Primero la red; si falla, lo que haya guardado
  e.respondWith(
    fetch(e.request)
      .then(r => {
        if (r.ok && (url.origin === location.origin || url.host.includes('fonts.'))) {
          const copia = r.clone();
          caches.open(CACHE).then(c => c.put(e.request, copia));
        }
        return r;
      })
      .catch(() => caches.match(e.request).then(r => r || caches.match('./index.html')))
  );
});
