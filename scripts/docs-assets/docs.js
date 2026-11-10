// Deploy Center docs: folding menus, copy buttons, the current section, search. No dependencies.
(function () {
  'use strict';

  // Sidebar and "On this page" stay open where there is room and fold on small screens.
  var side = document.getElementById('sidenav'), toc = document.getElementById('toc');
  var narrow = matchMedia('(max-width: 899px)'), medium = matchMedia('(max-width: 1159px)');
  function fold() {
    if (side) side.open = !narrow.matches;
    if (toc) toc.open = !medium.matches;
  }
  fold();
  [narrow, medium].forEach(function (m) { (m.addEventListener ? m.addEventListener('change', fold) : m.addListener(fold)); });

  // Copy buttons on code blocks.
  document.querySelectorAll('.code').forEach(function (block) {
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'copy';
    b.textContent = 'Copy';
    b.setAttribute('aria-label', 'Copy code');
    b.addEventListener('click', function () {
      var text = block.querySelector('code').textContent;
      var done = function () {
        b.textContent = 'Copied'; b.classList.add('done');
        setTimeout(function () { b.textContent = 'Copy'; b.classList.remove('done'); }, 1500);
      };
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(done, function () { fallback(text); done(); });
      } else { fallback(text); done(); }
    });
    block.appendChild(b);
  });
  function fallback(text) {
    var t = document.createElement('textarea');
    t.value = text; t.setAttribute('readonly', ''); t.style.position = 'fixed'; t.style.opacity = '0';
    document.body.appendChild(t); t.select();
    try { document.execCommand('copy'); } catch (e) {}
    t.remove();
  }

  // Mark the section being read in "On this page".
  var links = toc ? Array.prototype.slice.call(toc.querySelectorAll('a[href^="#"]')) : [];
  if (links.length && 'IntersectionObserver' in window) {
    var byId = {};
    links.forEach(function (a) { byId[decodeURIComponent(a.getAttribute('href').slice(1))] = a; });
    var heads = Object.keys(byId).map(function (id) { return document.getElementById(id); }).filter(Boolean);
    var current = null;
    var io = new IntersectionObserver(function () {
      var top = null;
      heads.forEach(function (h) { if (h.getBoundingClientRect().top < 140) top = h; });
      top = top || heads[0];
      if (top !== current) {
        if (current) byId[current.id].classList.remove('active');
        byId[top.id].classList.add('active');
        current = top;
      }
    }, { rootMargin: '0px 0px -60% 0px', threshold: [0, 1] });
    heads.forEach(function (h) { io.observe(h); });
  }

  // Search: /docs/search-index.json, loaded on first use.
  var q = document.getElementById('q'), list = document.getElementById('results');
  if (!q || !list) return;
  var index = null, loading = null, sel = -1, shown = [];
  function load() {
    if (!loading) {
      loading = fetch('/docs/search-index.json').then(function (r) { return r.json(); }).then(function (d) {
        index = d.map(function (e) { return { e: e, p: e.p.toLowerCase(), h: e.h.toLowerCase(), t: e.t.toLowerCase() }; });
      }).catch(function () { index = []; });
    }
    return loading;
  }
  function esc(s) { return s.replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function mark(s, terms) {
    var out = esc(s);
    terms.forEach(function (t) {
      out = out.replace(new RegExp('(' + esc(t).replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ')', 'gi'), '<mark>$1</mark>');
    });
    return out;
  }
  function snippet(text, terms) {
    var low = text.toLowerCase(), at = -1;
    terms.some(function (t) { at = low.indexOf(t); return at >= 0; });
    var from = Math.max(0, at - 50);
    var s = text.slice(from, from + 150);
    return (from > 0 ? '…' : '') + s + (from + 150 < text.length ? '…' : '');
  }
  function search(value) {
    var terms = value.toLowerCase().split(/\s+/).filter(function (t) { return t.length > 1 || /\w/.test(t); });
    if (!terms.length || !index) return [];
    var res = [];
    index.forEach(function (x) {
      var score = 0;
      for (var i = 0; i < terms.length; i++) {
        var t = terms[i], s = 0;
        if (x.h.indexOf(t) >= 0) s += 10;
        if (x.p.indexOf(t) >= 0) s += x.h ? 3 : 8;
        if (x.t.indexOf(t) >= 0) s += 1 + Math.min(3, x.t.split(t).length - 2);
        if (!s) return;          // every word must match somewhere
        score += s;
      }
      if (x.h.indexOf(value.toLowerCase().trim()) >= 0) score += 15;
      res.push({ x: x, s: score });
    });
    res.sort(function (a, b) { return b.s - a.s; });
    return res.slice(0, 10).map(function (r) { return { e: r.x.e, terms: terms }; });
  }
  function render() {
    var v = q.value.trim();
    if (!v) { close(); return; }
    shown = search(v);
    sel = -1;
    list.innerHTML = shown.length ? shown.map(function (r, i) {
      var title = r.e.h ? r.e.p + ' › ' + r.e.h : r.e.p;
      return '<li role="option" id="r' + i + '"><a href="' + esc(r.e.u) + '">' + mark(title, r.terms) +
        '<small>' + mark(snippet(r.e.t, r.terms), r.terms) + '</small></a></li>';
    }).join('') : '<li class="empty">No results for “' + esc(v) + '”</li>';
    list.hidden = false;
    q.setAttribute('aria-expanded', 'true');
  }
  function close() { list.hidden = true; q.setAttribute('aria-expanded', 'false'); q.removeAttribute('aria-activedescendant'); }
  function move(d) {
    if (!shown.length) return;
    var items = list.querySelectorAll('li[role=option]');
    if (sel >= 0) items[sel].removeAttribute('aria-selected');
    sel = (sel + d + items.length) % items.length;
    items[sel].setAttribute('aria-selected', 'true');
    items[sel].scrollIntoView({ block: 'nearest' });
    q.setAttribute('aria-activedescendant', 'r' + sel);
  }
  q.addEventListener('focus', load);
  q.addEventListener('input', function () { load().then(render); });
  q.addEventListener('keydown', function (e) {
    if (e.key === 'ArrowDown') { e.preventDefault(); move(1); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); move(-1); }
    else if (e.key === 'Enter') {
      var r = shown[sel >= 0 ? sel : 0];
      if (r) { e.preventDefault(); close(); location.href = r.e.u; }
    } else if (e.key === 'Escape') { close(); q.blur(); }
  });
  list.addEventListener('click', function (e) { if (e.target.closest('a')) close(); });
  document.addEventListener('click', function (e) { if (!e.target.closest('.search')) close(); });
  document.addEventListener('keydown', function (e) {
    var tag = (e.target.tagName || '').toLowerCase();
    if (e.key === '/' && tag !== 'input' && tag !== 'textarea' && !e.metaKey && !e.ctrlKey) { e.preventDefault(); q.focus(); }
  });
})();
