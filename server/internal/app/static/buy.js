// The purchase flow: create the order, show how to pay, poll every 3 s and
// show the licence key once paid. The order number and token are kept in
// localStorage so a reload (or the return from Alipay) resumes the order.
(function () {
  'use strict';
  var C = window.Cirrus, t = C.t;
  var LS = 'cirrus.order';
  function $(id) { return document.getElementById(id); }
  var form = $('order-form'), payPanel = $('pay-panel'), done = $('done-panel'), expired = $('expired-panel');
  var panels = [form, payPanel, done, expired];
  var current = null, timer = null, shownType = null;

  function load() { try { return JSON.parse(localStorage.getItem(LS)); } catch (e) { return null; } }
  function save(o) { try { localStorage.setItem(LS, JSON.stringify(o)); } catch (e) { /* private mode */ } }
  function clear() { try { localStorage.removeItem(LS); } catch (e) { /* ignore */ } }

  function show(p) { panels.forEach(function (x) { x.hidden = x !== p; }); }
  function stop() { if (timer) clearTimeout(timer); timer = null; }
  function setSrc(img, url) { if (url && img.getAttribute('src') !== url) img.src = url; }
  function status(s) { $('p-status').textContent = s; }

  function renderPay(o, data) {
    var pay = data.pay || {};
    var method = t(data.method || o.method);
    $('p-order').textContent = o.order_no;
    $('p-token').textContent = o.token;
    $('p-amount').textContent = pay.amount || data.amount || '';
    $('p-static').hidden = pay.type !== 'static_qr';
    $('p-dynamic').hidden = pay.type !== 'qr';
    $('p-redirect').hidden = pay.type !== 'redirect';
    if (pay.type === 'redirect' && pay.url) $('p-go').href = pay.url; // fresh signed URL on every poll
    if (shownType !== pay.type) {
      shownType = pay.type;
      if (pay.type === 'static_qr') {
        setSrc($('p-static-img'), pay.qr_image);
        var ol = $('p-steps');
        ol.textContent = '';
        [t('step_scan', { m: method }), t('step_amount', { a: pay.amount }), t('step_note', { o: o.order_no }), t('step_wait')]
          .forEach(function (s) { var li = document.createElement('li'); li.textContent = s; ol.appendChild(li); });
        $('p-save').textContent = t('save_hint', { m: method });
        status(t('waiting_man'));
      } else if (pay.type === 'qr') {
        setSrc($('p-qr'), pay.qr_image);
        // WeChat Native codes can only be scanned, not opened as a link.
        var wx = (data.method || o.method) === 'wechat';
        $('p-scan').textContent = t('scan_dynamic', { m: method }) + (wx ? ' ' + t('scan_wechat_phone') : '');
        $('p-open-row').hidden = wx;
        if (!wx) {
          $('p-open').href = pay.qr_text;
          $('p-open').textContent = t('open_app');
        }
        status(t('waiting'));
      } else {
        status(t('waiting'));
      }
    }
    show(payPanel);
  }

  function handle(o, data) {
    if (data.status === 'paid') {
      stop();
      $('d-key').textContent = data.license_key || '';
      show(done);
    } else if (data.status === 'expired') {
      stop();
      $('e-order').textContent = o.order_no;
      show(expired);
    } else {
      renderPay(o, data);
    }
  }

  async function poll() {
    timer = null;
    if (!current) return;
    var keepGoing = true;
    if (!document.hidden) {
      try {
        var r = await C.api('GET', '/api/v1/orders/' + encodeURIComponent(current.order_no) +
          '?token=' + encodeURIComponent(current.token));
        if (r.status === 404) {
          clear(); current = null; keepGoing = false; show(form);
        } else if (r.ok) {
          handle(current, r.data);
          keepGoing = r.data.status === 'pending';
        }
      } catch (e) { /* network hiccup: try again */ }
    }
    if (keepGoing && current) timer = setTimeout(poll, 3000);
  }

  function reset() {
    stop(); clear(); current = null; shownType = null;
    $('form-error').hidden = true;
    show(form);
  }
  ['p-new', 'd-new', 'e-new'].forEach(function (id) { $(id).addEventListener('click', reset); });

  form.addEventListener('submit', async function (e) {
    e.preventDefault();
    var err = $('form-error'), btn = $('submit');
    err.hidden = true;
    var fd = new FormData(form);
    btn.disabled = true;
    var label = btn.textContent;
    btn.textContent = t('creating');
    try {
      var r = await C.api('POST', '/api/v1/orders', {
        product: fd.get('product'), email: String(fd.get('email') || '').trim(), method: fd.get('method')
      });
      if (r.status === 201) {
        current = { order_no: r.data.order_no, token: r.data.token, method: r.data.method };
        save(current);
        shownType = null;
        handle(current, r.data);
        var pay = r.data.pay || {};
        if (pay.type === 'redirect' && pay.url) {
          status(t('redirecting'));
          window.location.href = pay.url;
        }
        stop();
        timer = setTimeout(poll, 3000);
      } else {
        err.textContent = C.errText(r.data);
        err.hidden = false;
      }
    } catch (ex) {
      err.textContent = t('err_network');
      err.hidden = false;
    } finally {
      btn.disabled = false;
      btn.textContent = label;
    }
  });

  // Resume an order kept in this browser.
  current = load();
  var ret = $('return-note').getAttribute('data-order');
  if (current && current.order_no && current.token) {
    poll();
  } else if (ret) {
    $('return-note').textContent = t('no_order');
    $('return-note').hidden = false;
  }
})();
