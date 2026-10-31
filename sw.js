self.addEventListener("push", function (e) {
  var d = {};
  try { d = e.data.json(); } catch (x) { d = { body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "Pengingat angsuran", {
    body: d.body || "", tag: d.tag, data: { url: d.url || "./" }
  }));
});
self.addEventListener("notificationclick", function (e) {
  e.notification.close();
  e.waitUntil(clients.matchAll({ type: "window", includeUncontrolled: true }).then(function (l) {
    for (var i = 0; i < l.length; i++) if ("focus" in l[i]) return l[i].focus();
    return clients.openWindow(e.notification.data.url);
  }));
});
