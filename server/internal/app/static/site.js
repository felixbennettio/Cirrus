// Shared helpers: translated strings, JSON API calls and copy buttons.
(function () {
  'use strict';
  var I = {};
  var el = document.getElementById('i18n');
  try { if (el) I = JSON.parse(el.textContent) || {}; } catch (e) { I = {}; }

  function t(key, vars) {
    var s = I[key] || { copied: '✓' }[key] || key;
    if (vars) Object.keys(vars).forEach(function (k) { s = s.split('{' + k + '}').join(vars[k]); });
    return s;
  }

  // The API's Chinese "message" is used on the Chinese page; the English
  // page translates known error codes.
  function errText(data) {
    var code = data && data.error;
    if (code && I['err_' + code]) return t('err_' + code, { n: data.retry_after_days });
    if (data && data.message) return data.message;
    return t('err_generic');
  }

  async function api(method, path, body) {
    var opts = { method: method, headers: { Accept: 'application/json' }, cache: 'no-store' };
    if (body) {
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(body);
    }
    var res = await fetch(path, opts);
    var data = {};
    try { data = await res.json(); } catch (e) { data = {}; }
    return { ok: res.ok, status: res.status, data: data || {} };
  }

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.className = 'offscreen';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); } finally { document.body.removeChild(ta); }
    return Promise.resolve();
  }

  document.addEventListener('click', function (e) {
    var b = e.target.closest('[data-copy]');
    if (!b) return;
    var src = document.getElementById(b.getAttribute('data-copy'));
    if (!src) return;
    var label = b.textContent;
    copyText(src.textContent.trim()).then(function () {
      b.textContent = t('copied');
      setTimeout(function () { b.textContent = label; }, 1500);
    });
  });

  window.Cirrus = { t: t, api: api, errText: errText };
})();
