// Coldwater's service worker.
//
// Caches the shell so the page opens instantly on a home network and still
// renders when the appliance is briefly unreachable. It deliberately never
// caches an API response: a bank statement audit is not something to leave
// sitting in a browser cache, and a stale one would be worse than none.

const SHELL = 'coldwater-shell-v1';
const ASSETS = [
  '/',
  '/static/css/app.css',
  '/static/js/app.js',
  '/static/icon.svg',
  '/manifest.webmanifest',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(SHELL).then((cache) => cache.addAll(ASSETS)).then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== SHELL).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // Never touch the API, and never interfere with an upload.
  if (url.pathname.startsWith('/api/') || event.request.method !== 'GET') return;

  event.respondWith(
    caches.match(event.request).then(
      (hit) =>
        hit ??
        fetch(event.request).catch(
          () => caches.match('/') ?? Response.error(),
        ),
    ),
  );
});
