// Deploy Center docs: folding menus, copy buttons, theme switch, the current section, search. No dependencies.
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

  // Theme switch: the system's choice until you pick one; the pick stays in this browser only (as on the other pages).
  var root = document.documentElement, themeBtn = document.querySelector('button.theme');
  if (themeBtn) {
    var current = function () { return root.getAttribute('data-theme') || (matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark'); };
    var label = function () { themeBtn.setAttribute('aria-label', current() === 'light' ? 'Switch to dark mode' : 'Switch to light mode'); };
    themeBtn.hidden = false;
    label();
    matchMedia('(prefers-color-scheme: light)').addEventListener && matchMedia('(prefers-color-scheme: light)').addEventListener('change', label);
    themeBtn.addEventListener('click', function () {
      var next = current() === 'light' ? 'dark' : 'light';
      root.setAttribute('data-theme', next);
      try { localStorage.setItem('theme', next); } catch (e) { /* private window: the choice lasts for this page */ }
      label();
    });
  }

  // A status line for screen readers ("Copied"), as on the guides.
  var status = document.createElement('div');
  status.className = 'sr'; status.setAttribute('role', 'status'); status.setAttribute('aria-live', 'polite');
  document.body.appendChild(status);
  function say(text) { status.textContent = ''; setTimeout(function () { status.textContent = text; }, 60); }

  // Copy buttons on code blocks. "Copied" only when it was; otherwise the code is selected and the key is named.
  var plat = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || '';
  var copyKey = /mac|iphone|ipad|ipod/i.test(plat) ? 'Cmd-C' : 'Ctrl-C';
  document.querySelectorAll('.code').forEach(function (block) {
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'copy';
    b.textContent = 'Copy';
    b.setAttribute('aria-label', 'Copy code');
    b.addEventListener('click', function () {
      var code = block.querySelector('code');
      var text = code.textContent;
      var reset = function () { setTimeout(function () { b.textContent = 'Copy'; b.classList.remove('done'); }, 1500); };
      var done = function () { b.textContent = 'Copied'; b.classList.add('done'); say('Copied to the clipboard'); reset(); };
      var failed = function () {
        var r = document.createRange(); r.selectNodeContents(code);
        var s = getSelection(); s.removeAllRanges(); s.addRange(r);
        b.textContent = 'Press ' + copyKey; say('Copying failed; the code is selected, press ' + copyKey); reset();
      };
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(done, function () { fallback(text) ? done() : failed(); });
      } else if (fallback(text)) { done(); } else { failed(); }
    });
    block.appendChild(b);
  });
  function fallback(text) {
    var t = document.createElement('textarea'), ok = false;
    t.value = text; t.setAttribute('readonly', ''); t.style.position = 'fixed'; t.style.opacity = '0';
    document.body.appendChild(t); t.select();
    try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    t.remove();
    return ok;
  }

  // Mark the section being read in "On this page" (and say so to screen readers: aria-current).
  var links = toc ? Array.prototype.slice.call(toc.querySelectorAll('a[href^="#"]')) : [];
  if (links.length && 'IntersectionObserver' in window) {
    var byId = {};
    links.forEach(function (a) { byId[decodeURIComponent(a.getAttribute('href').slice(1))] = a; });
    var heads = Object.keys(byId).map(function (id) { return document.getElementById(id); }).filter(Boolean);
    var currentHead = null;
    var io = new IntersectionObserver(function () {
      var top = null;
      heads.forEach(function (h) { if (h.getBoundingClientRect().top < 140) top = h; });
      top = top || heads[0];
      if (top !== currentHead) {
        if (currentHead) { byId[currentHead.id].classList.remove('active'); byId[currentHead.id].removeAttribute('aria-current'); }
        byId[top.id].classList.add('active');
        byId[top.id].setAttribute('aria-current', 'location');
        currentHead = top;
      }
    }, { rootMargin: '0px 0px -60% 0px', threshold: [0, 1] });
    heads.forEach(function (h) { io.observe(h); });
  }

  // Search: /docs/search-index.json, loaded on first use.
  var q = document.getElementById('q'), list = document.getElementById('results');
  if (!q || !list) return;
  var index = null, loading = null, shown = [], offline = false;
  // "auto-deploy" and "autodeploy", "<project>" and "project" are the same word here: hyphens, angle brackets,
  // backticks and underscores are dropped on both sides; a few words with their other spellings are one group.
  function norm(s) { return s.toLowerCase().replace(/[-_`<>]/g, ''); }
  var SYNONYMS = [['rollback', 'roll back', 'zurückrollen', 'zurückrolle'], ['autodeploy', 'autobuild', 'auto build']];
  function variants(t) {
    for (var i = 0; i < SYNONYMS.length; i++) { if (SYNONYMS[i].indexOf(t) >= 0) return SYNONYMS[i]; }
    return [t];
  }
  function load() {
    if (!loading) {
      loading = fetch('/docs/search-index.json').then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); }).then(function (d) {
        offline = false;
        index = d.map(function (e) { return { e: e, p: norm(e.p), h: norm(e.h), t: norm(e.t) }; });
      }).catch(function () {
        // not cached as a failure: the next focus asks again (offline, a changed network)
        index = null; loading = null; offline = true;
      });
    }
    return loading;
  }
  function esc(s) { return s.replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  // A pattern that finds a search word in the raw text whatever hyphens it has: "autodeploy" finds "auto-deploy".
  function loose(t) {
    return variants(t).map(function (v) {
      return v.split('').map(function (ch) { return ch.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }).join('[-_`<>]*');
    }).join('|');
  }
  // The hits are found in the raw text, and each piece is escaped on its own: a search for "lt" must not cut an
  // entity such as &lt; in two.
  function mark(s, terms) {
    var re = new RegExp('(' + terms.map(loose).join('|') + ')', 'gi'), out = '', last = 0, m;
    while ((m = re.exec(s))) {
      if (!m[0]) { re.lastIndex++; continue; }
      out += esc(s.slice(last, m.index)) + '<mark>' + esc(m[0]) + '</mark>';
      last = m.index + m[0].length;
    }
    return out + esc(s.slice(last));
  }
  function snippet(text, terms) {
    var low = norm(text), at = -1;
    terms.some(function (t) { return variants(t).some(function (v) { at = low.indexOf(v); return at >= 0; }); });
    // norm() keeps the length except for the characters it drops; close enough for a window of text
    var from = Math.max(0, at - 50);
    var s = text.slice(from, from + 150);
    return (from > 0 ? '…' : '') + s + (from + 150 < text.length ? '…' : '');
  }
  function search(value) {
    var terms = norm(value).split(/\s+/).filter(function (t) { return t.length > 1 || /\w/.test(t); });
    if (!terms.length || !index) return [];
    var whole = norm(value).trim(), res = [];
    index.forEach(function (x) {
      var score = 0;
      for (var i = 0; i < terms.length; i++) {
        var vs = variants(terms[i]), s = 0;
        vs.forEach(function (t) {
          if (x.h.indexOf(t) >= 0) s = Math.max(s, 10);
          if (x.p.indexOf(t) >= 0) s += x.h ? 3 : 8;
          if (x.t.indexOf(t) >= 0) s += 1 + Math.min(3, x.t.split(t).length - 2);
        });
        if (!s) return;          // every word must match somewhere
        score += s;
      }
      if (x.h.indexOf(whole) >= 0) score += 15;
      res.push({ x: x, s: score });
    });
    res.sort(function (a, b) { return b.s - a.s; });
    return res.slice(0, 10).map(function (r) { return { e: r.x.e, terms: terms }; });
  }
  function setStatus(text) { var st = document.getElementById('rstatus'); if (st) st.textContent = text; }
  function render() {
    var v = q.value.trim();
    if (!v) { close(); return; }
    if (offline) {
      list.innerHTML = '<li class="empty">Search is not available offline. Try again when you are back online.</li>';
      list.hidden = false; setStatus('Search is not available offline'); return;
    }
    shown = search(v);
    // a plain list of links: Tab and the arrow keys move through them, Enter opens one
    list.innerHTML = shown.length ? shown.map(function (r) {
      var title = r.e.h ? r.e.p + ' › ' + r.e.h : r.e.p;
      return '<li><a href="' + esc(r.e.u) + '">' + mark(title, r.terms) +
        '<small>' + mark(snippet(r.e.t, r.terms), r.terms) + '</small></a></li>';
    }).join('') : '<li class="empty">No results for “' + esc(v) + '”</li>';
    list.hidden = false;
    setStatus(shown.length ? shown.length + (shown.length === 1 ? ' result' : ' results') : 'No results');
  }
  function close() { setStatus(''); list.hidden = true; }
  function move(d) {
    var items = Array.prototype.slice.call(list.querySelectorAll('a'));
    if (!items.length) return;
    var at = items.indexOf(document.activeElement);
    if (at < 0) { items[d > 0 ? 0 : items.length - 1].focus(); return; }
    var next = at + d;
    if (next < 0) q.focus(); else if (next < items.length) items[next].focus();
  }
  q.addEventListener('focus', load);
  q.addEventListener('input', function () { load().then(render); });
  q.addEventListener('keydown', function (e) {
    if (e.key === 'ArrowDown') { e.preventDefault(); move(1); }
    else if (e.key === 'Enter') {
      var a = list.querySelector('a');
      if (a) { e.preventDefault(); close(); location.href = a.getAttribute('href'); }
    } else if (e.key === 'Escape') { close(); q.blur(); }
  });
  list.addEventListener('keydown', function (e) {
    if (e.key === 'ArrowDown') { e.preventDefault(); move(1); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); move(-1); }
    else if (e.key === 'Escape') { close(); q.focus(); }
  });
  list.addEventListener('click', function (e) { if (e.target.closest('a')) close(); });
  document.addEventListener('click', function (e) { if (!e.target.closest('.search')) close(); });
  // Tab out of the search group: the list closes (it would cover the top of the page)
  var group = q.closest('.search'), pressing = false;
  list.addEventListener('mousedown', function () { pressing = true; setTimeout(function () { pressing = false; }, 400); });   // Safari does not focus a link on click
  if (group) group.addEventListener('focusout', function (e) {
    if (pressing) return;
    if (!e.relatedTarget || !group.contains(e.relatedTarget)) close();
  });
  document.addEventListener('keydown', function (e) {
    var tag = (e.target.tagName || '').toLowerCase();
    if (e.key === '/' && tag !== 'input' && tag !== 'textarea' && !e.metaKey && !e.ctrlKey) { e.preventDefault(); q.focus(); }
  });
})();
