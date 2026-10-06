// Licence self-service: reset devices, look up an order, resend keys.
(function () {
  'use strict';
  var C = window.Cirrus, t = C.t;
  function $(id) { return document.getElementById(id); }

  function say(el, text, ok) {
    el.textContent = text;
    el.className = 'result ' + (ok ? 'ok' : 'error');
    el.hidden = false;
  }

  function bind(id, fn) {
    var form = $(id);
    if (!form) return;
    form.addEventListener('submit', async function (e) {
      e.preventDefault();
      var btn = form.querySelector('button[type=submit]');
      btn.disabled = true;
      try { await fn(new FormData(form)); } finally { btn.disabled = false; }
    });
  }

  bind('reset-form', async function (fd) {
    var out = $('reset-result');
    try {
      var r = await C.api('POST', '/api/v1/reset', { license_key: fd.get('license_key'), email: fd.get('email') });
      if (r.ok) say(out, t('reset_ok'), true); else say(out, C.errText(r.data), false);
    } catch (e) { say(out, t('err_network'), false); }
  });

  bind('lookup-form', async function (fd) {
    var box = $('lookup-result'), st = $('lookup-status');
    $('lookup-keyline').hidden = true;
    try {
      var no = String(fd.get('order_no')).trim(), tok = String(fd.get('token')).trim();
      var r = await C.api('GET', '/api/v1/orders/' + encodeURIComponent(no) + '?token=' + encodeURIComponent(tok));
      box.hidden = false;
      box.className = 'result ' + (r.ok ? 'ok' : 'error');
      if (!r.ok) { st.textContent = C.errText(r.data); return; }
      st.textContent = no + ' · ¥' + r.data.amount + ' · ' + t(r.data.status);
      if (r.data.status === 'paid' && r.data.license_key) {
        $('lookup-key').textContent = r.data.license_key;
        $('lookup-keyline').hidden = false;
      }
    } catch (e) { box.hidden = false; box.className = 'result error'; st.textContent = t('err_network'); }
  });

  bind('resend-form', async function (fd) {
    var out = $('resend-result');
    try {
      var r = await C.api('POST', '/api/v1/resend', { email: fd.get('email') });
      if (r.ok) say(out, t('resend_ok'), true); else say(out, C.errText(r.data), false);
    } catch (e) { say(out, t('err_network'), false); }
  });
})();
