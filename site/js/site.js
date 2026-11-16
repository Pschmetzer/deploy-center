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
