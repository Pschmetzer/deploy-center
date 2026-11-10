#!/bin/bash
# Tests for the CLI's own install paths: scripts/package-cli.sh, site/install.sh and
# scripts/homebrew-formula.sh. A fake release folder stands in for GitHub Releases
# (file:// URLs), so nothing touches the network. Run: tests/install-tests.sh
# INSTALL_SH=dash tests/install-tests.sh runs install.sh with another POSIX shell (default: sh).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
repo="$PWD"
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails+1)); }
expect()   { [ "$2" = "$3" ] && ok "$1" || fail "$1" "expected [$3], got [$2]"; }
contains() { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1" "[$3] not in [$2]" ;; esac; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
export HOME="$tmp/home" DEPLOYS_CONFIG="$tmp/config"
mkdir -p "$HOME"
sh_="${INSTALL_SH:-sh}"
version="$(cat VERSION)"

# --- package-cli.sh -------------------------------------------------------------------------
out="$(scripts/package-cli.sh --out "$tmp/pkg" LICENSE 2>&1)"; rc=$?
expect "package: exit 0" "$rc" 0
tarball="$tmp/pkg/deploys-cli-$version.tar.gz"
[ -f "$tarball" ] && ok "package: tarball written" || fail "package: tarball written" "$out"
listing="$(tar -tzf "$tarball" | sort | tr '\n' ' ')"
expect "package: contents" "$listing" "deploys-cli-$version/ deploys-cli-$version/LICENSE deploys-cli-$version/README-CLI.md deploys-cli-$version/VERSION deploys-cli-$version/deploys "
expect "package: checksums.txt" "$(cat "$tmp/pkg/checksums.txt")" "$(sha256 "$tarball")  deploys-cli-$version.tar.gz
$(sha256 LICENSE)  LICENSE"
cp LICENSE "$tmp/pkg/"
(cd "$tmp/pkg" && sha256sum -c checksums.txt >/dev/null 2>&1 || shasum -a 256 -c checksums.txt >/dev/null 2>&1) \
  && ok "package: checksums.txt checks with sha256sum -c" || fail "package: checksums.txt checks" "sha256sum -c failed"

# The later layout: providers/ next to deploys. A copy of the repo with one, as a git repo,
# so --ref is tested too.
lay="$tmp/layout"
mkdir -p "$lay/scripts" "$lay/providers"
cp deploys VERSION LICENSE README-CLI.md "$lay/"
cp scripts/package-cli.sh "$lay/scripts/"
printf '#!/bin/bash\necho vercel provider\n' > "$lay/providers/vercel.sh"
(cd "$lay" && git init -q && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm t) \
  || fail "layout: git repo" "could not commit"
"$lay/scripts/package-cli.sh" --out "$tmp/pkg2" >/dev/null 2>&1
contains "package: providers/ goes in" "$(tar -tzf "$tmp/pkg2/deploys-cli-$version.tar.gz")" "deploys-cli-$version/providers/vercel.sh"
"$lay/scripts/package-cli.sh" --ref HEAD --out "$tmp/ref1" >/dev/null 2>&1
"$lay/scripts/package-cli.sh" --ref HEAD --out "$tmp/ref2" >/dev/null 2>&1
contains "package --ref: providers/ goes in" "$(tar -tzf "$tmp/ref1/deploys-cli-$version.tar.gz")" "deploys-cli-$version/providers/vercel.sh"
expect "package --ref: same commit, same bytes" "$(cat "$tmp/ref1/checksums.txt")" "$(cat "$tmp/ref2/checksums.txt")"
expect "package --ref: deploys stays executable" \
  "$(tar -tvzf "$tmp/ref1/deploys-cli-$version.tar.gz" "deploys-cli-$version/deploys" | cut -c1-10)" "-rwxr-xr-x"
"$repo/scripts/package-cli.sh" --ref no-such-commit --out "$tmp/x" >/dev/null 2>&1
expect "package --ref: unknown commit fails" "$?" 1

# --- a fake GitHub Releases folder ----------------------------------------------------------
rel="$tmp/releases"
release() {  # release <version> <folder with deploys-cli-<version>.tar.gz and checksums.txt>
  mkdir -p "$rel/download/v$1"
  cp "$2/deploys-cli-$1.tar.gz" "$2/checksums.txt" "$rel/download/v$1/"
}
release "$version" "$tmp/pkg"
# An older release with providers/, to install by --version.
old="$tmp/old"; mkdir -p "$old/src/deploys-cli-0.6.9/providers"
cp deploys LICENSE README-CLI.md "$old/src/deploys-cli-0.6.9/"
echo 0.6.9 > "$old/src/deploys-cli-0.6.9/VERSION"
echo 'echo provider' > "$old/src/deploys-cli-0.6.9/providers/render.sh"
(cd "$old/src" && tar -czf ../deploys-cli-0.6.9.tar.gz deploys-cli-0.6.9)
(cd "$old" && printf '%s  %s\n' "$(sha256 deploys-cli-0.6.9.tar.gz)" deploys-cli-0.6.9.tar.gz > checksums.txt)
release 0.6.9 "$old"
mkdir -p "$rel/latest"; cp -R "$rel/download/v$version" "$rel/latest/download"
export DEPLOYS_INSTALL_BASE="file://$rel"

inst() { "$sh_" "$repo/site/install.sh" "$@" 2>&1; }

# --- install.sh -----------------------------------------------------------------------------
out="$(inst --help)"; rc=$?
expect "install --help: exit 0" "$rc" 0
contains "install --help: names --prefix" "$out" "--prefix <dir>"
out="$("$sh_" -s -- --help < site/install.sh 2>&1)"
contains "install --help piped into sh" "$out" "--uninstall"

prefix="$tmp/pre fix"   # a space, as in many home folders
out="$(inst --prefix "$prefix")"; rc=$?
expect "install latest: exit 0" "$rc" 0
contains "install latest: says the checksum is ok" "$out" "SHA-256 ok"
contains "install latest: says what is installed" "$out" "Installed deploys $version"
case "$out" in *"run with sudo"*) fail "install latest: no sudo for a writable prefix" "$out" ;; *) ok "install latest: no sudo for a writable prefix" ;; esac
help="$("$prefix/bin/deploys" --help 2>&1)"; rc=$?
expect "deploys --help: exit 0" "$rc" 0
contains "deploys --help: the command list" "$help" "deploys doctor"
expect "deploys --version" "$("$prefix/bin/deploys" --version)" "$version"
[ -f "$prefix/lib/deploys/README-CLI.md" ] && ok "files in lib/deploys" || fail "files in lib/deploys" "no README-CLI.md"
contains "install: PATH hint when bin is not on PATH" "$out" "is not on your PATH"
contains "install: dependency check runs" "$out" "Checking what deploys uses"
out="$(PATH="$prefix/bin:$PATH" inst --prefix "$prefix")"; rc=$?
expect "install again (update): exit 0" "$rc" 0
case "$out" in *"is not on your PATH"*) fail "install: no PATH hint when on PATH" "$out" ;; *) ok "install: no PATH hint when on PATH" ;; esac

# Missing tools: a PATH without jq, gh, vercel shows how to install them.
nojq="$tmp/nojq"; mkdir -p "$nojq"
for t in sh bash curl tar gzip mkdir rm cp mv chmod grep sed cut head dirname uname id mktemp sha256sum shasum awk cat env printf tr ln readlink pwd basename; do
  p="$(command -v "$t" 2>/dev/null)" && [ -n "$p" ] && [ "$t" != "$p" ] && ln -sf "$p" "$nojq/$t"
done
p="$(command -v "$sh_")"; ln -sf "$p" "$nojq/$(basename "$sh_")"
out="$(PATH="$nojq" "$nojq/$(basename "$sh_")" "$repo/site/install.sh" --prefix "$tmp/p2" 2>&1)"; rc=$?
expect "install without jq: still exit 0" "$rc" 0
contains "install without jq: jq is named as required" "$out" "jq (required"
contains "install without jq: with an install command" "$out" "install: "
contains "install without jq: vercel via npm" "$out" "npm install -g vercel"
contains "install without jq: warns at the end" "$out" "needs the required tools"

out="$(inst --prefix "$tmp/p3" --version 0.6.9)"; rc=$?
expect "install --version 0.6.9: exit 0" "$rc" 0
expect "install --version 0.6.9: that version" "$("$tmp/p3/bin/deploys" --version)" 0.6.9
[ -f "$tmp/p3/lib/deploys/providers/render.sh" ] && ok "install: providers/ next to deploys" || fail "install: providers/" "missing"
out="$(inst --prefix "$tmp/p3" --version="v$version")"; rc=$?
expect "install --version=v<x>: exit 0" "$rc" 0
[ ! -e "$tmp/p3/lib/deploys/providers" ] && ok "install: an update leaves no old files behind" || fail "install: old files" "providers/ still there"

out="$(inst --prefix "$tmp/p4" --version 9.9.9)"; rc=$?
expect "install a missing version: fails" "$rc" 1
contains "install a missing version: says why" "$out" "could not download"
out="$(inst --prefix "$tmp/p4" --version banana)"; rc=$?
expect "install --version banana: fails" "$rc" 1
out="$(inst --bogus)"; rc=$?
expect "install unknown option: fails" "$rc" 1

# A tarball that does not match checksums.txt is never installed.
bad="$tmp/bad"; cp -R "$rel" "$bad"
printf 'x' >> "$bad/download/v$version/deploys-cli-$version.tar.gz"
out="$(DEPLOYS_INSTALL_BASE="file://$bad" inst --prefix "$tmp/p5")"; rc=$?
expect "bad checksum: fails" "$rc" 1
contains "bad checksum: says so" "$out" "SHA-256 mismatch"
[ ! -e "$tmp/p5/bin/deploys" ] && [ ! -e "$tmp/p5/lib/deploys" ] && ok "bad checksum: nothing installed" \
  || fail "bad checksum: nothing installed" "files written"

# A deploys this script did not put there (Homebrew, by hand) is not replaced without --force.
mkdir -p "$tmp/p6/bin"; printf '#!/bin/sh\necho other\n' > "$tmp/p6/bin/deploys"; chmod +x "$tmp/p6/bin/deploys"
out="$(inst --prefix "$tmp/p6")"; rc=$?
expect "foreign deploys: refused" "$rc" 1
expect "foreign deploys: untouched" "$("$tmp/p6/bin/deploys")" other
out="$(inst --prefix "$tmp/p6" --uninstall)"; rc=$?
expect "foreign deploys: uninstall leaves it" "$("$tmp/p6/bin/deploys")" other
out="$(inst --prefix "$tmp/p6" --force)"; rc=$?
expect "foreign deploys: --force replaces it" "$("$tmp/p6/bin/deploys" --version)" "$version"

# Uninstall.
mkdir -p "$DEPLOYS_CONFIG"; echo '{}' > "$DEPLOYS_CONFIG/vercel-repos.json"
out="$(inst --prefix "$prefix" --uninstall)"; rc=$?
expect "uninstall: exit 0" "$rc" 0
[ ! -e "$prefix/bin/deploys" ] && [ ! -e "$prefix/lib/deploys" ] && ok "uninstall: files gone" || fail "uninstall: files gone" "still there"
[ -f "$DEPLOYS_CONFIG/vercel-repos.json" ] && ok "uninstall: config stays" || fail "uninstall: config stays" "removed"
out="$(inst --prefix "$prefix" --uninstall)"
contains "uninstall twice: nothing to remove" "$out" "Nothing to remove"

# sudo only when needed, and said first. Root can write anywhere, so only as another user.
if [ "$(id -u)" != 0 ]; then
  ro="$tmp/ro"; mkdir -p "$ro"; chmod 555 "$ro"
  fake="$tmp/fakesudo"; mkdir -p "$fake"
  printf '#!/bin/sh\necho "$*" >> "%s/sudo.log"\nchmod u+w "%s"\n"$@"\n' "$tmp" "$ro" > "$fake/sudo"; chmod +x "$fake/sudo"
  out="$(PATH="$fake:$PATH" inst --prefix "$ro")"; rc=$?
  expect "read-only prefix: exit 0 (with sudo)" "$rc" 0
  contains "read-only prefix: says sudo is used" "$out" "run with sudo"
  [ -s "$tmp/sudo.log" ] && ok "read-only prefix: sudo was used" || fail "read-only prefix: sudo was used" "no sudo calls"
  expect "read-only prefix: installed" "$("$ro/bin/deploys" --version)" "$version"
else
  echo "skip sudo tests (running as root)"
fi

# --- homebrew-formula.sh --------------------------------------------------------------------
f="$(scripts/homebrew-formula.sh "$version" "$(sha256 "$tarball")")"; rc=$?
expect "formula: exit 0" "$rc" 0
contains "formula: url" "$f" "releases/download/v$version/deploys-cli-$version.tar.gz"
contains "formula: depends on jq" "$f" 'depends_on "jq"'
contains "formula: test runs --version" "$f" 'deploys --version'
if command -v ruby >/dev/null; then
  ruby -c <<<"$f" >/dev/null 2>&1 && ok "formula: valid Ruby" || fail "formula: valid Ruby" "ruby -c failed"
fi
mkdir -p "$tmp/tap"
scripts/homebrew-formula.sh --write "$tmp/tap" --no-check "$version" "$(sha256 "$tarball")" >/dev/null
[ -f "$tmp/tap/Formula/deploys.rb" ] && ok "formula --write" || fail "formula --write" "no Formula/deploys.rb"
scripts/homebrew-formula.sh 1.2 abc >/dev/null 2>&1
expect "formula: bad version fails" "$?" 1

echo
if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "All install tests passed."
