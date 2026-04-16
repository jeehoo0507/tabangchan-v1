// 타방찬 Push Service Worker
// 주의: scope는 /push-scope/ — Flutter SW(/flutter_service_worker.js)와 충돌 방지
// install/activate/fetch 없음 → Flutter SW의 캐싱 로직 그대로 유지

self.addEventListener('push', function(event) {
  let data = { title: '타방찬', body: '새 알림이 있습니다.' };
  try { if (event.data) data = event.data.json(); } catch (_) {}

  event.waitUntil(
    self.registration.showNotification(data.title, {
      body: data.body,
      icon: '/icons/Icon-192.png',
      badge: '/icons/Icon-192.png',
      tag: data.tag || 'tabangchan',
      renotify: true,
    })
  );
});

self.addEventListener('notificationclick', function(event) {
  event.notification.close();
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
      for (const c of list) {
        if (c.url.includes(self.location.origin)) { c.focus(); return; }
      }
      clients.openWindow('/');
    })
  );
});
