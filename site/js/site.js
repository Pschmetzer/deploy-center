// Guides, blog, calculator and 404: a theme switch (same choice as the home page, kept in this browser
// only) and a copy button on every code block. Nothing is sent anywhere.
(function () {
  var root = document.documentElement;
  var current = function () {
    return root.getAttribute('data-theme') || (matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark');
  };

  // The browser bar follows a manual choice too: once the visitor picks a theme, one meta tag without a media query replaces the two.
  var COLORS = { dark: '#0b0d12', light: '#fbfbfd' };
  var paintBar = function (theme) {
    var metas = document.querySelectorAll('meta[name="theme-color"]');
    if (!metas.length || !COLORS[theme]) return;
    for (var i = 1; i < metas.length; i++) metas[i].remove();
    metas[0].removeAttribute('media');
    metas[0].setAttribute('content', COLORS[theme]);
  };
  // another tab changed the theme: follow it without a reload
  window.addEventListener('storage', function (e) {
    if (e.key !== 'theme' || (e.newValue !== 'light' && e.newValue !== 'dark')) return;
    root.setAttribute('data-theme', e.newValue);
    paintBar(e.newValue);
    var b = document.querySelector('nav.top .theme');
    if (b) b.setAttribute('aria-label', e.newValue === 'light' ? 'Switch to dark mode' : 'Switch to light mode');
  });

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
      paintBar(next);
      try { localStorage.setItem('theme', next); } catch (e) { /* private window: the choice lasts for this page */ }
      label();
    });
    var dl = links.querySelector('a.dl');
    if (dl) links.insertBefore(btn, dl); else links.appendChild(btn);   // before "Download", as on the home page
  }

  // copy button on code blocks; a fallback for browsers without the clipboard API, and a message for screen readers
  var live = document.createElement('div');
  live.className = 'sr'; live.setAttribute('role', 'status'); live.setAttribute('aria-live', 'polite');
  document.body.appendChild(live);
  var say = function (msg) { live.textContent = ''; setTimeout(function () { live.textContent = msg; }, 60); };
  var fallback = function (text) {
    var ta = document.createElement('textarea');
    ta.value = text; ta.setAttribute('readonly', ''); ta.style.position = 'fixed'; ta.style.opacity = '0';
    document.body.appendChild(ta); ta.select();
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) { /* no copy command here */ }
    ta.remove();
    return ok;
  };
  document.querySelectorAll('article pre').forEach(function (pre) {
    var b = document.createElement('button'), timer;
    b.className = 'copy';
    b.type = 'button';
    b.textContent = 'Copy';
    b.setAttribute('aria-label', 'Copy this code');
    b.addEventListener('click', function () {
      var code = pre.querySelector('code') || pre;
      var text = code.textContent.replace(/\n$/, '');
      var done = function (ok) {
        b.textContent = ok ? 'Copied' : 'Copy failed';
        say(ok ? 'Copied to the clipboard' : 'Copying failed');
        clearTimeout(timer);
        timer = setTimeout(function () { b.textContent = 'Copy'; }, 1800);
      };
      if (navigator.clipboard) navigator.clipboard.writeText(text).then(function () { done(true); }, function () { done(fallback(text)); });
      else done(fallback(text));
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
  var st = document.createElement('div');
  st.className = 'sr'; st.setAttribute('role', 'status'); st.setAttribute('aria-live', 'polite');
  list.parentNode.insertBefore(st, list);
  q.closest('.site-search').hidden = false;   // shown only when this script runs
  var index = null, loading = null, offline = false;
  // "auto-deploy" and "autodeploy" are one word here (as in the docs search)
  function norm(s) { return s.toLowerCase().replace(/[-_`<>]/g, ''); }
  function load() {
    if (!loading) {
      loading = fetch('/docs/search-index.json').then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); }).then(function (d) {
        offline = false;
        index = d.map(function (e) { return { e: e, k: norm(e.p + ' ' + e.h + ' ' + e.t), p: norm(e.p) }; });
      }).catch(function () {
        // a failure is not kept: the next focus asks again (offline, a changed network)
        index = null; loading = null; offline = true;
      });
    }
    return loading;
  }
  function esc(s) { return s.replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function render() {
    var terms = norm(q.value).split(/\s+/).filter(Boolean), found = [];
    if (terms.length && offline) {
      list.innerHTML = '<li class="empty">Search is not available offline. Try again when you are back online.</li>';
      list.hidden = false; st.textContent = 'Search is not available offline'; return;
    }
    if (!terms.length || !index) { list.hidden = true; list.innerHTML = ''; st.textContent = ''; return; }
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
    st.textContent = found.length ? found.length + (found.length === 1 ? ' result' : ' results') : 'No results';
  }
  q.addEventListener('focus', load);
  q.addEventListener('input', function () { load().then(render); });
  // a plain list of links, as in the docs search: the arrow keys move through them, Enter opens the first,
  // Esc closes the list (a second Esc clears the field)
  function close() { list.hidden = true; st.textContent = ''; }
  function move(d) {
    var items = Array.prototype.slice.call(list.querySelectorAll('a'));
    if (!items.length) return;
    var at = items.indexOf(document.activeElement);
    if (at < 0) { items[d > 0 ? 0 : items.length - 1].focus(); return; }
    var next = at + d;
    if (next < 0) q.focus(); else if (next < items.length) items[next].focus();
  }
  q.addEventListener('keydown', function (e) {
    if (e.key === 'ArrowDown') { e.preventDefault(); move(1); }
    else if (e.key === 'Enter') {
      var a = list.hidden ? null : list.querySelector('a');
      if (a) { e.preventDefault(); location.href = a.getAttribute('href'); }
    } else if (e.key === 'Escape') {
      if (!list.hidden) close(); else q.value = '';
    }
  });
  list.addEventListener('keydown', function (e) {
    if (e.key === 'ArrowDown') { e.preventDefault(); move(1); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); move(-1); }
    else if (e.key === 'Escape') { close(); q.focus(); }
  });
})();
