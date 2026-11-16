// Guides, blog, calculator and 404: a theme switch (same choice as the home page, kept in this browser
// only) and a copy button on every code block. Nothing is sent anywhere.
(function () {
  var root = document.documentElement;
  var current = function () {
    return root.getAttribute('data-theme') || (matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark');
  };

  // theme switch in the top navigation
  var links = document.querySelector('nav.top .links');
  if (links && !links.querySelector('.theme')) {
    var btn = document.createElement('button');
    btn.className = 'theme';
    btn.type = 'button';
    btn.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="4.5"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>';
    var label = function () { btn.setAttribute('aria-label', current() === 'light' ? 'Switch to dark mode' : 'Switch to light mode'); };
    label();
    matchMedia('(prefers-color-scheme: light)').addEventListener('change', label);
    btn.addEventListener('click', function () {
      var next = current() === 'light' ? 'dark' : 'light';
      root.setAttribute('data-theme', next);
      try { localStorage.setItem('theme', next); } catch (e) { /* private window: the choice lasts for this page */ }
      label();
    });
    links.appendChild(btn);
  }

  // copy button on code blocks
  if (!navigator.clipboard) return;
  document.querySelectorAll('article pre').forEach(function (pre) {
    var b = document.createElement('button');
    b.className = 'copy';
    b.type = 'button';
    b.textContent = 'Copy';
    b.setAttribute('aria-label', 'Copy this code');
    b.addEventListener('click', function () {
      var code = pre.querySelector('code') || pre;
      navigator.clipboard.writeText(code.textContent.replace(/\n$/, '')).then(function () {
        b.textContent = 'Copied';
      }, function () {
        b.textContent = 'Copy failed';
      }).then(function () {
        setTimeout(function () { b.textContent = 'Copy'; }, 1800);
      });
    });
    pre.style.position = 'relative';
    pre.appendChild(b);
  });
})();

// Search on the guides, blog and 404 pages: the index the docs search reads (/docs/search-index.json),
// which also lists the guides and the blog. Loaded on first use; nothing is sent anywhere.
(function () {
  var q = document.querySelector('input[data-site-search]'), list = document.getElementById('site-results');
  if (!q || !list) return;
  q.closest('.site-search').hidden = false;   // shown only when this script runs
  var index = null, loading = null;
  function load() {
    if (!loading) {
      loading = fetch('/docs/search-index.json').then(function (r) { return r.json(); }).then(function (d) {
        index = d.map(function (e) { return { e: e, k: (e.p + ' ' + e.h + ' ' + e.t).toLowerCase(), p: e.p.toLowerCase() }; });
      }).catch(function () { index = []; });
    }
    return loading;
  }
  function esc(s) { return s.replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function render() {
    var terms = q.value.toLowerCase().split(/\s+/).filter(Boolean), found = [];
    if (!terms.length || !index) { list.hidden = true; list.innerHTML = ''; return; }
    index.forEach(function (x) {
      var score = 0;
      for (var i = 0; i < terms.length; i++) {
        if (x.k.indexOf(terms[i]) < 0) return;
        score += x.p.indexOf(terms[i]) >= 0 ? 5 : 1;
      }
      found.push({ e: x.e, s: score + (x.e.h ? 0 : 2) });
    });
    found.sort(function (a, b) { return b.s - a.s; });
    found = found.slice(0, 8);
    list.innerHTML = found.length ? found.map(function (r) {
      var title = r.e.h ? r.e.p + ' › ' + r.e.h : r.e.p;
      return '<li><a href="' + esc(r.e.u) + '">' + esc(title) + '</a><small>' + esc(r.e.t.slice(0, 120)) + '</small></li>';
    }).join('') : '<li class="empty">No results for \u201c' + esc(q.value.trim()) + '\u201d</li>';
    list.hidden = false;
  }
  q.addEventListener('focus', load);
  q.addEventListener('input', function () { load().then(render); });
  q.addEventListener('keydown', function (e) { if (e.key === 'Escape') { q.value = ''; render(); } });
})();
