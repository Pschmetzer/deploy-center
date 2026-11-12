#!/bin/bash
# Tests for the release and website scripts: scripts/check-release.py (the release gate),
# scripts/bump.sh, scripts/check-site.py, scripts/check-links.py, scripts/check-public.sh,
# scripts/check-strings.py and scripts/homebrew-cask.sh. Each runs on a small copy in a temporary folder; nothing is pushed,
# downloaded or published. Run: tests/release-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
repo="$PWD"
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect()   { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }
contains() { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1" "[$3] not in [$2]" ;; esac; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -C "$1" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c tag.gpgsign=false "${@:2}"; }

# A repo with VERSION, a home page and an appcast. $1 VERSION, $2 site version, $3.. appcast items.
release_repo() {
  local d="$tmp/rel-$RANDOM$RANDOM" v="$1" site="$2"; shift 2
  mkdir -p "$d/site"
  echo "$v" > "$d/VERSION"
  printf '<script type="application/ld+json">{"@type": "SoftwareApplication", "softwareVersion": "%s"}</script>\n<p id="version">Version %s · <a href="/">notes</a></p>\n' "$site" "$site" > "$d/site/index.html"
  {
    echo '<?xml version="1.0" encoding="utf-8"?>'
    echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>t</title>'
    for i in "$@"; do echo "<item><title>Version $i</title><sparkle:version>$i</sparkle:version><sparkle:shortVersionString>$i</sparkle:shortVersionString></item>"; done
    echo '</channel></rss>'
  } > "$d/site/appcast.xml"
  g "$d" init -q && g "$d" add -A && g "$d" commit -qm init
  echo "$d"
}
gate() { python3 -I "$repo/scripts/check-release.py" "$1" 2>&1; }

# --- check-release.py: the release gate ------------------------------------------------------
d="$(release_repo 1.2.0 1.2.0 1.2.0 1.1.0)"; g "$d" tag v1.2.0
out="$(gate "$d")"; expect "gate: released and in step" "$?" 0
contains "gate: says what it saw" "$out" "VERSION 1.2.0 (tagged), site 1.2.0, appcast 1.2.0"

d="$(release_repo 1.2.0 1.2.0 1.1.0)"
out="$(gate "$d")"; expect "gate: after the bump, before publishing, the appcast may lag" "$?" 0

g "$d" tag v1.2.0
out="$(gate "$d")"; expect "gate: tagged but not in the appcast fails" "$?" 1
contains "gate: names the appcast PR" "$out" "merge the appcast-1.2.0 PR"

d="$(release_repo 1.2.0 1.1.0 1.1.0)"
out="$(gate "$d")"; expect "gate: an old site version fails" "$?" 1
contains "gate: names the line under the button" "$out" 'says "Version 1.1.0", VERSION is 1.2.0'
contains "gate: names the JSON-LD" "$out" '"softwareVersion" is 1.1.0'

d="$(release_repo 1.2.0 1.2.0 1.3.0 1.2.0)"
out="$(gate "$d")"; expect "gate: an appcast newer than VERSION fails" "$?" 1
contains "gate: says which" "$out" "newest item is 1.3.0, newer than VERSION 1.2.0"

d="$(release_repo 1.10.0 1.10.0 1.9.0 1.10.0)"; g "$d" tag v1.10.0
out="$(gate "$d")"; expect "gate: versions compare as numbers, not text" "$?" 0

d="$(release_repo 1.2.0 1.2.0 1.1.0)"; printf '<p>no version here</p>\n' > "$d/site/index.html"
out="$(gate "$d")"; expect "gate: a home page without the version fails" "$?" 1
contains "gate: says it is missing" "$out" 'no "Version x.y.z ·" line'

d="$(release_repo 1.2.0 1.2.0 1.1.0)"; echo '<rss><channel>' > "$d/site/appcast.xml"
out="$(gate "$d")"; expect "gate: a broken appcast fails" "$?" 1

# --- bump.sh: VERSION, CHANGELOG.md and the home page move together ------------------------
bump_repo() {
  local d="$tmp/bump-$RANDOM$RANDOM"
  mkdir -p "$d/scripts" "$d/site"
  cp "$repo/scripts/bump.sh" "$d/scripts/"
  echo "$1" > "$d/VERSION"
  printf '# Changelog\n\n## Unreleased\n\n- A change.\n\n## %s\n\n- Before.\n' "$1" > "$d/CHANGELOG.md"
  printf '{"softwareVersion": "%s"}\n<p>Version %s · notes</p>\n' "$2" "$2" > "$d/site/index.html"
  echo "$d"
}
d="$(bump_repo 1.2.0 1.2.0)"
out="$(bash "$d/scripts/bump.sh" patch 2>&1)"; expect "bump: patch works" "$?" 0
expect "bump: VERSION" "$(cat "$d/VERSION")" 1.2.1
contains "bump: CHANGELOG has the new section" "$(cat "$d/CHANGELOG.md")" $'## Unreleased\n\n## 1.2.1\n\n- A change.'
contains "bump: home page line" "$(cat "$d/site/index.html")" "Version 1.2.1 ·"
contains "bump: home page JSON-LD" "$(cat "$d/site/index.html")" '"softwareVersion": "1.2.1"'

d="$(bump_repo 1.2.0 1.1.0)"
out="$(bash "$d/scripts/bump.sh" minor 2>&1)"; expect "bump: a home page on another version stops it" "$?" 1
contains "bump: says why" "$out" "site/index.html has no 'Version 1.2.0 ·'"
expect "bump: and changes nothing" "$(cat "$d/VERSION")" 1.2.0

d="$(bump_repo 1.2.0 1.2.0)"; printf '%s\n' '- nothing' > "$d/CHANGELOG.md"
bash "$d/scripts/bump.sh" patch >/dev/null 2>&1; expect "bump: no Unreleased section fails" "$?" 1

# --- check-site.py and check-links.py: a broken page is caught -----------------------------
site="$tmp/site"; mkdir -p "$site/docs/a"
page() {  # $1 file, $2 canonical path, $3 extra body
  cat > "$site/$1" <<HTML
<!doctype html><html lang="en"><head><title>T</title>
<meta name="description" content="d"><link rel="canonical" href="https://deploycenter.app$2">
<meta property="og:title" content="t"><meta property="og:url" content="https://deploycenter.app$2">
<meta property="og:image" content="https://deploycenter.app/og.png">
<link rel="shortcut icon" href="/favicon.ico">
<script type="application/ld+json">{"@context": "https://schema.org", "@type": "WebPage"}</script>
</head><body><h1 id="top">T</h1>$3</body></html>
HTML
}
page index.html / '<a href="/docs/a/">a</a> <a href="#top">top</a>'
page docs/a/index.html /docs/a/ '<a href="/">home</a>'
touch "$site/favicon.ico"
printf '<urlset><url><loc>https://deploycenter.app/</loc></url><url><loc>https://deploycenter.app/docs/a/</loc></url></urlset>\n' > "$site/sitemap.xml"
out="$(python3 "$repo/scripts/check-site.py" "$site" 2>&1)"; expect "check-site: a good site passes" "$?" 0
out="$(python3 "$repo/scripts/check-links.py" "$site" 2>&1)"; expect "check-links: a good site passes" "$?" 0

rm "$site/favicon.ico"
out="$(python3 "$repo/scripts/check-site.py" "$site" 2>&1)"; expect "check-site: a missing rel=\"shortcut icon\" fails" "$?" 1
contains "check-site: names it" "$out" "broken link /favicon.ico"
touch "$site/favicon.ico"

page docs/a/index.html /docs/a/ '<a href="/docs/gone/">gone</a> <a href="/#nowhere">x</a>'
out="$(python3 "$repo/scripts/check-site.py" "$site" 2>&1)"; expect "check-site: a broken link fails" "$?" 1
contains "check-site: names the link" "$out" "broken link /docs/gone/"
contains "check-site: names the anchor" "$out" "missing anchor /#nowhere"
out="$(python3 "$repo/scripts/check-links.py" "$site" 2>&1)"; expect "check-links: a broken link fails" "$?" 1
contains "check-links: names the link" "$out" "/docs/gone/"

page docs/a/index.html /docs/b/ ''
out="$(python3 "$repo/scripts/check-site.py" "$site" 2>&1)"; expect "check-site: a page missing from the sitemap fails" "$?" 1
contains "check-site: names the canonical" "$out" "canonical https://deploycenter.app/docs/b/ is not in sitemap.xml"

page docs/a/index.html /docs/a/ ''
sed -i.bak 's/"@type": "WebPage"/"@type": "WebPage",/' "$site/index.html"
out="$(python3 "$repo/scripts/check-site.py" "$site" 2>&1)"; expect "check-site: broken JSON-LD fails" "$?" 1
contains "check-site: says so" "$out" "index.html: invalid JSON-LD"

# --- check-public.sh: personal data in a tracked file is caught -----------------------------
pub="$tmp/pub"; mkdir -p "$pub/scripts"
cp "$repo/scripts/check-public.sh" "$pub/scripts/"
printf 'Install into /Users/YOURNAME/bin.\nA test token: ghp_abcdefghijklmnopqrstuvwxyz0123\n' > "$pub/README.md"
g "$pub" init -q && g "$pub" add -A
out="$(bash "$pub/scripts/check-public.sh" 2>&1)"; expect "check-public: placeholders pass" "$?" 0
# The leaks are put together at run time, so this file itself passes check-public.sh.
r=Zq81LmX0pRt7Vw2Ys5Kb9Nc4
for leak in "/Us""ers/someone/Projects" "Team""Identifier=AB12CD34EF" "export GITHUB_TOKEN=gh""p_${r}${r:0:12}" \
            "sk-""ant-api03-$r" "gl""pat-$r" "tea""m_$r"; do
  echo "$leak" > "$pub/leak.txt"; g "$pub" add leak.txt
  out="$(bash "$pub/scripts/check-public.sh" 2>&1)"; rc=$?
  expect "check-public: catches ${leak:0:16}…" "$rc:$(grep -c '^leak.txt:1:' <<<"$out")" "1:1"
done
echo 'only a picture' > "$pub/leak.txt"; g "$pub" add leak.txt
out="$(bash "$pub/scripts/check-public.sh" 2>&1)"; expect "check-public: clean again" "$?" 0

# --- check-strings.py: every L(en, de) has both texts with the same values ------------------
sw="$tmp/strings.swift"
cat > "$sw" <<'SWIFT'
let a = L("\(n) \(n == 1 ? "commit" : "commits") waiting", "\(n) \(n == 1 ? "Commit wartet" : "Commits warten")")
let b = L("Deploy", "Deploy")
SWIFT
out="$(python3 -I scripts/check-strings.py "$sw" 2>&1)"; expect "strings: good pairs pass" "$?" 0
contains "strings: counts them" "$out" "2 L(en, de) pairs in 1 files, 0 problems"
cat > "$sw" <<'SWIFT'
let a = L("\(n) projects", "\(count) Projekte")
let b = L("Turn off auto-deploy for all", "Turn off auto-deploy for all")
let c = L("Open", "")
SWIFT
out="$(python3 -I scripts/check-strings.py "$sw" 2>&1)"; expect "strings: bad pairs fail" "$?" 1
contains "strings: other values" "$out" "strings.swift:1: English and German interpolate different values"
contains "strings: German left out" "$out" "strings.swift:2: the German text is the English one"
contains "strings: empty text" "$out" "strings.swift:3: an empty text"

# --- homebrew-cask.sh ----------------------------------------------------------------------
sha="$(printf '%064d' 7)"
cask="$(scripts/homebrew-cask.sh 1.2.3 "$sha" 2>&1)"; expect "cask: exit 0" "$?" 0
contains "cask: version" "$cask" 'version "1.2.3"'
contains "cask: sha256" "$cask" "sha256 \"$sha\""
contains "cask: url of the release zip" "$cask" 'releases/download/v#{version}/DeployCenter-#{version}-universal.zip'
contains "cask: updates itself (Sparkle)" "$cask" "auto_updates true"
contains "cask: zap removes the log and the preferences" "$cask" '"~/Library/Preferences/app.deploycenter.mac.plist"'
contains "cask: macOS 15" "$cask" "depends_on macos: :sequoia"
if command -v ruby >/dev/null; then
  ruby -c <<<"$cask" >/dev/null 2>&1 && ok "cask: valid Ruby" || fail "cask: valid Ruby" "ruby -c failed"
fi
mkdir -p "$tmp/tap"
scripts/homebrew-cask.sh --write "$tmp/tap" --no-check 1.2.3 "$sha" >/dev/null 2>&1
[ -f "$tmp/tap/Casks/deploy-center.rb" ] && ok "cask --write" || fail "cask --write" "no Casks/deploy-center.rb"
scripts/homebrew-cask.sh 1.2 "$sha" >/dev/null 2>&1; expect "cask: bad version fails" "$?" 1
scripts/homebrew-cask.sh 1.2.3 abc >/dev/null 2>&1; expect "cask: bad sha fails" "$?" 1

# --- CI lane: scripts/build-docs.py and scripts/sparkle.sh catch what they promise to catch ---
# build-docs.py on a copy of the tracked files: a good tree builds; a link to a missing file or out
# of the repo stops it, with the file named.
docs="$tmp/docs-copy"; mkdir -p "$docs"
git -C "$repo" ls-files -z | (cd "$repo" && xargs -0 tar -cf - 2>/dev/null) | tar -xf - -C "$docs"
out="$(python3 "$docs/scripts/build-docs.py" 2>&1)"; rc=$?
expect "build-docs: the tree as it is builds" "$rc" 0
n="$(find "$docs/site/docs" -name index.html | wc -l | tr -d ' ')"
[ "$n" -ge 15 ] && ok "build-docs: the pages are written ($n)" || fail "build-docs: the pages are written" "only $n"
cp "$docs/docs/FAQ.md" "$tmp/faq.md"
printf '\nSee [the gone page](GONE.md).\n' >> "$docs/docs/FAQ.md"
out="$(python3 "$docs/scripts/build-docs.py" 2>&1)"; rc=$?
expect "build-docs: a link to a missing file fails" "$rc" 1
contains "build-docs: and names the file and the link" "$out" "docs/FAQ.md: link 'GONE.md'"
cp "$tmp/faq.md" "$docs/docs/FAQ.md"; printf '\nSee [up](../../outside.md).\n' >> "$docs/docs/FAQ.md"
out="$(python3 "$docs/scripts/build-docs.py" 2>&1)"; rc=$?
expect "build-docs: a link out of the repo fails" "$rc:$(grep -c 'points outside the repo' <<<"$out")" "1:1"
cp "$tmp/faq.md" "$docs/docs/FAQ.md"
# The hand-written sitemap URLs get their lastmod from git (here no git: today), not by hand.
sed -i.bak 's#<loc>https://deploycenter.app/guides/</loc><lastmod>[^<]*#<loc>https://deploycenter.app/guides/</loc><lastmod>1999-01-01#' "$docs/site/sitemap.xml"
python3 "$docs/scripts/build-docs.py" >/dev/null 2>&1
expect "build-docs: a static page's lastmod comes from git, not the hand" \
  "$(grep -c '<lastmod>1999-01-01' "$docs/site/sitemap.xml"):$(grep -c "guides/</loc><lastmod>$(date +%Y-%m-%d)" "$docs/site/sitemap.xml")" "0:1"

# sparkle.sh with a stand-in curl: a download with the wrong SHA-256 is refused and not kept.
sp="$tmp/sparkle"; mkdir -p "$sp/scripts" "$sp/bin"
cp "$repo/scripts/sparkle.sh" "$sp/scripts/"
cat > "$sp/bin/curl" <<'C'
#!/bin/bash
while [ $# -gt 0 ]; do [ "$1" = -o ] && { echo "not sparkle" > "$2"; }; shift; done
C
chmod +x "$sp/bin/curl"
out="$(PATH="$sp/bin:$PATH" bash "$sp/scripts/sparkle.sh" 2>&1)"; rc=$?
expect "sparkle.sh: a wrong SHA-256 fails" "$rc" 1
contains "sparkle.sh: and says so" "$out" "Sparkle download has SHA-256"
expect "sparkle.sh: nothing is kept" "$(ls "$sp/vendor" 2>/dev/null | wc -l | tr -d ' ')" 0
printf '#!/bin/sh\nexit 22\n' > "$sp/bin/curl"
out="$(PATH="$sp/bin:$PATH" bash "$sp/scripts/sparkle.sh" 2>&1)"; rc=$?
expect "sparkle.sh: a failed download fails" "$rc:$(grep -c 'could not download' <<<"$out")" "1:1"

# check-site.py page rules (on the small site above): lang, alt, one h1, image weight, security.txt.
mv "$site/index.html.bak" "$site/index.html"
cs() { python3 "$repo/scripts/check-site.py" "$site" 2>&1; }
out="$(cs)"; expect "check-site: the small site passes again" "$?" 0
page docs/a/index.html /docs/a/ '<img src="/favicon.ico" width="1" height="1">'
out="$(cs)"; expect "check-site: an img without alt fails" "$?:$(grep -c 'has no alt' <<<"$out")" "1:1"
page docs/a/index.html /docs/a/ '<img src="/favicon.ico" alt="">'
out="$(cs)"; expect "check-site: alt=\"\" passes; no width/height only warns" "$?:$(grep -c '^warning: .*no width and height' <<<"$out")" "0:1"
page docs/a/index.html /docs/a/ '<h1>again</h1>'
out="$(cs)"; expect "check-site: two h1 fail" "$?:$(grep -c '2 <h1>' <<<"$out")" "1:1"
page docs/a/index.html /docs/a/ ''
sed -i.bak 's/<html lang="en">/<html>/' "$site/docs/a/index.html"
out="$(cs)"; expect "check-site: no html lang fails" "$?:$(grep -c 'no <html lang>' <<<"$out")" "1:1"
page docs/a/index.html /docs/a/ ''; rm -f "$site/docs/a/index.html.bak"
head -c 500000 /dev/zero > "$site/big.png"
out="$(cs)"; expect "check-site: an image over the limit fails" "$?:$(grep -c 'big.png: 488 KB' <<<"$out")" "1:1"
rm "$site/big.png"; mkdir -p "$site/.well-known"
printf 'Contact: mailto:security@example.com\n' > "$site/.well-known/security.txt"
out="$(cs)"; expect "check-site: security.txt without Expires fails" "$?:$(grep -c 'no Expires' <<<"$out")" "1:1"
printf 'Contact: mailto:security@example.com\nExpires: 2020-01-01T00:00:00Z\n' > "$site/.well-known/security.txt"
out="$(cs)"; expect "check-site: an expired security.txt fails" "$?:$(grep -c 'expired on 2020' <<<"$out")" "1:1"
printf 'Contact: mailto:security@example.com\nExpires: 2999-01-01T00:00:00Z\n' > "$site/.well-known/security.txt"
out="$(cs)"; expect "check-site: a valid security.txt passes" "$?" 0

# indexnow-urls.py: only what a push changed, and only URLs of the sitemap.
sm="$tmp/sitemap.xml"
printf '<urlset><url><loc>https://deploycenter.app/</loc></url><url><loc>https://deploycenter.app/guides/a/</loc></url><url><loc>https://deploycenter.app/docs/</loc></url><url><loc>https://deploycenter.app/docs/faq/</loc></url><url><loc>https://deploycenter.app/impressum.html</loc></url></urlset>\n' > "$sm"
iu() { printf '%s\n' "$@" | python3 -I "$repo/scripts/indexnow-urls.py" "$sm"; }
expect "indexnow: a changed guide is its URL" "$(iu site/guides/a/index.html)" '["https://deploycenter.app/guides/a/"]'
expect "indexnow: the home page" "$(iu site/index.html site/css/site.css)" '["https://deploycenter.app/"]'
expect "indexnow: a docs source means every docs URL" "$(iu docs/FAQ.md)" '["https://deploycenter.app/docs/", "https://deploycenter.app/docs/faq/"]'
expect "indexnow: a page not in the sitemap and CSS ping nothing" "$(iu site/404.html site/css/site.css app/Store.swift)" '[]'
expect "indexnow: a plain .html page" "$(iu site/impressum.html)" '["https://deploycenter.app/impressum.html"]'
expect "indexnow: --all is the sitemap" "$(python3 -I "$repo/scripts/indexnow-urls.py" "$sm" --all | jq length)" 5

echo
if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "All release tests passed."
