// Screenshot gallery on the home page (templates/index.html). Without
// scripts every group is listed and a thumbnail links to the full picture;
// this turns the groups into tabs and opens pictures in a lightbox.
(function () {
  'use strict';
  var root = document.getElementById('screenshots');
  if (!root) return;
  var groups = Array.prototype.slice.call(root.querySelectorAll('.shot-group'));
  if (!groups.length) return;

  // Tabs.
  var tabs = document.createElement('div');
  tabs.className = 'shot-tabs';
  tabs.setAttribute('role', 'tablist');
  var buttons = groups.map(function (g, i) {
    var b = document.createElement('button');
    b.type = 'button';
    b.id = 'tab-' + g.id;
    b.textContent = g.querySelector('h3').textContent;
    b.setAttribute('role', 'tab');
    b.setAttribute('aria-controls', g.id);
    g.setAttribute('role', 'tabpanel');
    g.setAttribute('aria-labelledby', b.id);
    b.addEventListener('click', function () { select(i); });
    tabs.appendChild(b);
    return b;
  });
  function select(i, focus) {
    groups.forEach(function (g, j) {
      g.hidden = j !== i;
      buttons[j].setAttribute('aria-selected', j === i ? 'true' : 'false');
      buttons[j].tabIndex = j === i ? 0 : -1;
    });
    if (focus) buttons[i].focus();
  }
  tabs.addEventListener('keydown', function (e) {
    var i = buttons.indexOf(document.activeElement);
    if (i < 0) return;
    var n = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: buttons.length - 1 }[e.key];
    if (n === undefined) return;
    e.preventDefault();
    select((n + buttons.length) % buttons.length, true);
  });
  groups[0].parentNode.insertBefore(tabs, groups[0]);
  root.classList.add('tabbed');
  select(0);

  // Lightbox.
  if (typeof HTMLDialogElement !== 'function') return;
  var dlg = document.createElement('dialog');
  dlg.className = 'lightbox';
  dlg.innerHTML = '<figure><img alt=""><figcaption></figcaption></figure>' +
    '<button type="button" class="lb-close"></button>' +
    '<button type="button" class="lb-prev"></button><button type="button" class="lb-next"></button>';
  var img = dlg.querySelector('img'), cap = dlg.querySelector('figcaption');
  [['.lb-close', 'close', '×'], ['.lb-prev', 'prev', '‹'], ['.lb-next', 'next', '›']].forEach(function (b) {
    var el = dlg.querySelector(b[0]);
    el.setAttribute('aria-label', root.dataset[b[1]] || b[1]);
    el.textContent = b[2];
  });
  document.body.appendChild(dlg);

  var links = [], at = 0;
  // The picture fades in once loaded, so the previous one never shows
  // under the next caption; the neighbours are fetched ahead.
  img.addEventListener('load', function () { img.classList.add('ready'); });
  function show(i) {
    at = (i + links.length) % links.length;
    var a = links[at];
    img.classList.remove('ready');
    img.removeAttribute('src');
    img.width = +a.dataset.w;
    img.height = +a.dataset.h;
    img.alt = cap.textContent = a.querySelector('.cap').textContent;
    img.src = a.getAttribute('href');
    dlg.classList.toggle('single', links.length < 2);
    [at - 1, at + 1].forEach(function (j) {
      new Image().src = links[(j + links.length) % links.length].getAttribute('href');
    });
  }
  root.addEventListener('click', function (e) {
    var a = e.target.closest('.shots a');
    if (!a || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey) return;
    e.preventDefault();
    links = Array.prototype.slice.call(a.closest('.shots').querySelectorAll('a'));
    show(links.indexOf(a));
    dlg.showModal();
  });
  dlg.querySelector('.lb-close').addEventListener('click', function () { dlg.close(); });
  dlg.querySelector('.lb-prev').addEventListener('click', function () { show(at - 1); });
  dlg.querySelector('.lb-next').addEventListener('click', function () { show(at + 1); });
  dlg.addEventListener('click', function (e) { if (e.target === dlg) dlg.close(); });
  dlg.addEventListener('keydown', function (e) {
    if (e.key === 'ArrowLeft') show(at - 1);
    else if (e.key === 'ArrowRight') show(at + 1);
  });
  dlg.addEventListener('close', function () { img.removeAttribute('src'); });
})();
