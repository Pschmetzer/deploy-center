// The build cost calculator (English and German page). Runs in the browser; nothing is sent anywhere.
// The numbers are in the address (?p=&u=&c=&d=), so a copied link shows the same result.
// ?embed=1 hides the site frame, for an <iframe> on another page.
(function () {
  var $ = function (id) { return document.getElementById(id); };
  var de = (document.documentElement.lang || 'en').slice(0, 2) === 'de';
  var T = de ? {
    locale: 'de-DE', unit: ' $',
    said: function (save, now, after) { return 'Du würdest etwa ' + save + ' im Monat sparen. Mit Auto-Deploy ' + now + ', mit Deploy von Hand ' + after + '.'; },
    tweet: function (now, after) { return 'Auto-Deploy würde mich etwa ' + now + ' im Monat an Builds kosten. Von Hand deployen: ' + after + '. Berechnet mit Deploy Center'; },
    share: function (now, after) { return 'Auto-Deploy würde mich etwa ' + now + ' im Monat an Builds kosten. Von Hand deployen: ' + after + '.'; },
    shareTitle: 'Vercel-Build-Kosten-Rechner', copy: 'Link kopieren', copied: 'Kopiert', failed: 'Kopieren fehlgeschlagen', valuetext: function (c) { return c.toFixed(2).replace('.', ',') + ' $'; }
  } : {
    locale: 'en-US', unit: '',
    said: function (save, now, after) { return 'You would save about ' + save + ' a month. With auto-deploy ' + now + ', deploying by hand ' + after + '.'; },
    tweet: function (now, after) { return 'Auto-deploy would cost me about ' + now + '/month in builds. Deploying by hand: ' + after + '. Calculated with Deploy Center'; },
    share: function (now, after) { return 'Auto-deploy would cost me about ' + now + '/month in builds. Deploying by hand: ' + after + '.'; },
    shareTitle: 'Vercel build cost calculator', copy: 'Copy link', copied: 'Copied', failed: 'Copy failed', valuetext: function (c) { return '$' + c.toFixed(2); }
  };
  var ids = ['p', 'u', 'c', 'd'];
  if (!$('p')) return;
  var q = new URLSearchParams(location.search);
  if (q.get('embed') === '1') document.documentElement.classList.add('embed');

  // under $10 with cents, so a small saving does not show as $0
  function fmt(v) {
    var n = v > 0 && v < 10 ? v.toLocaleString(T.locale, { minimumFractionDigits: 2, maximumFractionDigits: 2 })
                            : Math.round(v).toLocaleString(T.locale);
    return de ? n + T.unit : '$' + n;
  }
  function setValue(id, v) {
    var el = $(id);
    if (v >= +el.min && v <= +el.max) el.value = v;
  }
  ids.forEach(function (id) { setValue(id, +q.get(id)); });

  var moved = false;
  function link() {
    var canon = document.querySelector('link[rel="canonical"]');
    var base = canon ? canon.href.split('?')[0] : location.origin + location.pathname;
    return base + '?' + ids.map(function (id) { return id + '=' + $(id).value; }).join('&');
  }
  function calc() {
    var p = +$('p').value, u = +$('u').value, c = +$('c').value / 100, d = +$('d').value;
    ids.forEach(function (id) { var n = $(id + 'n'); if (document.activeElement !== n) n.value = $(id).value; });
    $('c').setAttribute('aria-valuetext', T.valuetext(c));
    var days = 22, now = p * u * c * days, after = p * Math.min(d, u) * c * days, save = Math.max(0, now - after);
    $('now').textContent = fmt(now); $('after').textContent = fmt(after); $('save').textContent = fmt(save);
    $('tweet').href = 'https://x.com/intent/post?text=' + encodeURIComponent(T.tweet(fmt(now), fmt(after))) + '&url=' + encodeURIComponent(link());
    // the address bar carries the numbers too, so a copied URL shows the same result
    if (moved) {
      try {
        var keep = q.get('embed') === '1' ? '&embed=1' : '';
        history.replaceState(null, '', '?' + ids.map(function (id) { return id + '=' + $(id).value; }).join('&') + keep);
      } catch (e) { /* no history API access: the page still works */ }
    }
    return { now: now, after: after, save: save };
  }
  // read out only the saving, and only once a slider is let go
  function say() { var r = calc(); $('said').textContent = T.said(fmt(r.save), fmt(r.now), fmt(r.after)); }

  ids.forEach(function (id) {
    var r = $(id), n = $(id + 'n');
    r.addEventListener('input', function () { moved = true; calc(); });
    r.addEventListener('change', say);
    // the number field sets the slider, within its limits
    n.min = r.min; n.max = r.max;
    n.addEventListener('input', function () { var v = Math.round(+n.value); if (v >= +r.min && v <= +r.max) { r.value = v; moved = true; calc(); } });
    n.addEventListener('change', function () {
      var v = Math.min(+r.max, Math.max(+r.min, Math.round(+n.value) || +r.min));
      r.value = v; n.value = v; moved = true; say();
    });
  });

  // example scenarios: they set projects, pushes and deploys by hand, never the cost per build
  document.querySelectorAll('button[data-scenario]').forEach(function (b) {
    b.addEventListener('click', function () {
      var v = b.getAttribute('data-scenario').split(',');
      ['p', 'u', 'd'].forEach(function (id, i) { setValue(id, +v[i]); });
      moved = true; say();
    });
  });

  $('copylink').addEventListener('click', function () {
    var b = $('copylink');
    (navigator.clipboard ? navigator.clipboard.writeText(link()) : Promise.reject()).then(function () { b.textContent = T.copied; }, function () { b.textContent = T.failed; })
      .then(function () { setTimeout(function () { b.textContent = T.copy; }, 1800); });
  });
  if (navigator.share) {
    var sb = $('sharebtn');
    sb.hidden = false;
    sb.addEventListener('click', function () {
      var r = calc();
      navigator.share({ title: T.shareTitle, text: T.share(fmt(r.now), fmt(r.after)), url: link() }).catch(function () { /* cancelled */ });
    });
  }
  calc();
})();
