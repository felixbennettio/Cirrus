// Hands the Cloudflare authorization response to the Cirrus app
// (templates/oauth.html). The query string is passed on unchanged.
(function () {
  var query = window.location.search;
  var params = new URLSearchParams(query);
  var open = document.getElementById('oauth-open');
  if (!params.get('state') || !(params.get('code') || params.get('error'))) {
    open.hidden = true;
    document.getElementById('oauth-hint').hidden = true;
    document.getElementById('oauth-missing').hidden = false;
    return;
  }
  var target = 'io.felixbennett.cirrus:/oauth/callback' + query;
  var lang = document.querySelector('a.lang');
  if (lang) {
    var u = new URL(lang.getAttribute('href'), window.location.href);
    params.forEach(function (v, k) { if (k !== 'lang') u.searchParams.set(k, v); });
    lang.setAttribute('href', u.pathname + u.search);
  }
  open.setAttribute('href', target);
  if (params.get('error')) {
    var err = document.getElementById('oauth-error');
    err.textContent = params.get('error_description') || params.get('error');
    err.hidden = false;
  }
  // Keep the code out of the address bar and history.
  if (window.history && window.history.replaceState) {
    window.history.replaceState(null, '', window.location.pathname);
  }
  window.location.href = target;
})();
