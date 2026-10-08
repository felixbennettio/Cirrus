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

  // API errors come with a "message" in the page language (api() sends it
  // as Accept-Language); a few codes have page strings of their own.
  function errText(data) {
    var code = data && data.error;
    if (code && I['err_' + code]) return t('err_' + code, { n: data.retry_after_days });
    if (data && data.message) return data.message;
    return t('err_generic');
  }

  async function api(method, path, body) {
    var lang = document.documentElement.lang || 'en';
    var opts = { method: method, headers: { Accept: 'application/json', 'Accept-Language': lang }, cache: 'no-store' };
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

  // Language menu (templates/layout.html): a <details> that works without
  // scripts; this closes it on Escape or a click elsewhere and lets the arrow
  // keys move between the languages.
  var menu = document.querySelector('details.langs');
  if (menu) {
    var items = function () { return Array.prototype.slice.call(menu.querySelectorAll('.lang-list a')); };
    document.addEventListener('click', function (e) {
      if (menu.open && !menu.contains(e.target)) menu.open = false;
    });
    menu.addEventListener('toggle', function () {
      if (!menu.open) return;
      var cur = menu.querySelector('.lang-list a[aria-current]') || items()[0];
      if (cur) cur.focus();
    });
    menu.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && menu.open) {
        menu.open = false;
        menu.querySelector('summary').focus();
        return;
      }
      if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp' && e.key !== 'Home' && e.key !== 'End') return;
      var list = items(), i = list.indexOf(document.activeElement);
      if (!menu.open || !list.length) return;
      e.preventDefault();
      if (e.key === 'Home') i = 0;
      else if (e.key === 'End') i = list.length - 1;
      else i = (i + (e.key === 'ArrowDown' ? 1 : -1) + list.length) % list.length;
      list[i].focus();
    });
  }

  window.Cirrus = { t: t, api: api, errText: errText };
})();
