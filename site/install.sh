#!/bin/sh
# Installs the deploys CLI (Deploy Center) from its GitHub release.
#
#   curl -fsSL https://deploycenter.app/install.sh | sh
#   curl -fsSL https://deploycenter.app/install.sh | sh -s -- --prefix /usr/local
#
# Options:
#   --prefix <dir>     install into <dir>/bin and <dir>/lib/deploys (default: ~/.local)
#   --version <x.y.z>  a given release instead of the latest
#   --uninstall        remove what this script installed under the prefix (config stays)
#   --force            replace a deploys in <dir>/bin that this script did not install
#   -h, --help         this text
#
# The tarball is checked against the release's checksums.txt (SHA-256) before anything is
# written. sudo is used only when the prefix is not writable, and the script says so first.
# Source: https://github.com/Pschmetzer/deploy-center/blob/main/site/install.sh (MIT)
set -eu

REPO="Pschmetzer/deploy-center"
# Where releases are downloaded from: <base>/latest/download/<file> and
# <base>/download/v<version>/<file>. A mirror, or a local folder (file://…) for tests.
BASE="${DEPLOYS_INSTALL_BASE:-https://github.com/$REPO/releases}"
MARKER="# deploys launcher, written by deploycenter.app/install.sh"

say() { printf '%s\n' "$*"; }
warn() { printf 'install.sh: %s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }
# Piped into sh, $0 is not this file: the help text has to be here, not read from the top.
usage() {
  cat <<'USAGE'
Installs the deploys CLI (Deploy Center) from its GitHub release.

  curl -fsSL https://deploycenter.app/install.sh | sh
  curl -fsSL https://deploycenter.app/install.sh | sh -s -- --prefix /usr/local

Options:
  --prefix <dir>     install into <dir>/bin and <dir>/lib/deploys (default: ~/.local)
  --version <x.y.z>  a given release instead of the latest
  --uninstall        remove what this script installed under the prefix (config stays)
  --force            replace a deploys in <dir>/bin that this script did not install
  -h, --help         this text
USAGE
}
has() { command -v "$1" >/dev/null 2>&1; }

prefix="${DEPLOYS_PREFIX:-}"
version=""
action=install
force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || die "--prefix needs a folder"; prefix="$2"; shift 2 ;;
    --prefix=*) prefix="${1#*=}"; shift ;;
    --version) [ $# -ge 2 ] || die "--version needs a version, like 0.8.0"; version="$2"; shift 2 ;;
    --version=*) version="${1#*=}"; shift ;;
    --uninstall) action=uninstall; shift ;;
    --force) force=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

if [ -z "$prefix" ]; then
  [ -n "${HOME:-}" ] || die "HOME is not set; pass --prefix"
  prefix="$HOME/.local"
fi
case "$prefix" in /*) ;; *) prefix="$(pwd)/$prefix" ;; esac
prefix="${prefix%/}"
[ -n "$prefix" ] || prefix=/
bindir="$prefix/bin"
libdir="$prefix/lib/deploys"
version="${version#v}"
[ "$version" = latest ] && version=""
if [ -n "$version" ]; then
  printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "not a version: $version (like 0.8.0)"
fi

# --- privileges: sudo only when the prefix cannot be written --------------------------------
# The nearest folder that exists decides: ~/.local/bin may not exist yet, ~/.local does.
writable() {
  p="$1"
  while [ ! -e "$p" ]; do p="$(dirname "$p")"; done
  [ -w "$p" ]
}
SUDO=""
if [ "$(id -u)" != 0 ] && { ! writable "$bindir" || ! writable "$libdir"; }; then
  has sudo || die "$prefix is not writable and sudo is missing. Use --prefix \"\$HOME/.local\" or run as root."
  SUDO=sudo
  say "$prefix is not writable by $(id -un). The steps that write there run with sudo (it may ask for your password)."
fi
run() { if [ -n "$SUDO" ]; then sudo "$@"; else "$@"; fi; }

ours() { [ -f "$1" ] && grep -qF "$MARKER" "$1" 2>/dev/null; }

# --- uninstall ------------------------------------------------------------------------------
if [ "$action" = uninstall ]; then
  removed=0
  if ours "$bindir/deploys"; then run rm -f "$bindir/deploys"; say "Removed $bindir/deploys"; removed=1
  elif [ -e "$bindir/deploys" ] || [ -L "$bindir/deploys" ]; then
    warn "$bindir/deploys was not installed by this script (Homebrew or by hand?); left alone"
  fi
  if [ -f "$libdir/deploys" ]; then run rm -rf "$libdir"; say "Removed $libdir"; removed=1; fi
  [ "$removed" = 1 ] || say "Nothing to remove under $prefix."
  say "Kept: your config in \${DEPLOYS_CONFIG:-~/.config/deploys}. Delete that folder to remove it too."
  if has deploys; then say "Another deploys is still on your PATH: $(command -v deploys)"; fi
  exit 0
fi

# --- download and verify --------------------------------------------------------------------
has curl || die "curl is needed to download the release (see below for jq, which deploys needs too)"
has tar || die "tar is needed to unpack the release"
sha256() {
  if has sha256sum; then sha256sum "$1" | cut -d' ' -f1
  elif has shasum; then shasum -a 256 "$1" | cut -d' ' -f1
  elif has openssl; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  else die "no sha256sum, shasum or openssl to check the download with"; fi
}
fetch() { curl -fsSL --proto '=https,file' --retry 3 -o "$2" "$1"; }

tmp="$(mktemp -d 2>/dev/null || mktemp -d -t deploys)"
trap 'rm -rf "$tmp"' EXIT INT TERM

if [ -n "$version" ]; then
  sums_url="$BASE/download/v$version/checksums.txt"
else
  sums_url="$BASE/latest/download/checksums.txt"
fi
say "Downloading $sums_url"
fetch "$sums_url" "$tmp/checksums.txt" \
  || die "could not download $sums_url. ${version:+Is v$version a release with the CLI (0.8.0 or newer)? }See https://github.com/$REPO/releases"

line="$(grep -E '^[0-9a-f]{64}  deploys-cli-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$' "$tmp/checksums.txt" | head -n 1 || true)"
[ -n "$line" ] || die "checksums.txt names no deploys-cli tarball"
want="${line%% *}"
file="${line##* }"
got_version="${file#deploys-cli-}"; got_version="${got_version%.tar.gz}"
if [ -n "$version" ] && [ "$got_version" != "$version" ]; then
  die "release v$version lists $file, not deploys-cli-$version.tar.gz"
fi
version="$got_version"

# From the tagged release, not latest/: latest could move between the two downloads.
url="$BASE/download/v$version/$file"
say "Downloading $url"
fetch "$url" "$tmp/$file" || die "could not download $url"
got="$(sha256 "$tmp/$file")"
[ "$got" = "$want" ] || die "SHA-256 mismatch for $file: got $got, checksums.txt says $want. Nothing was installed."
say "SHA-256 ok: $want"

mkdir "$tmp/x"
tar -xzf "$tmp/$file" -C "$tmp/x"
src="$tmp/x/deploys-cli-$version"
[ -f "$src/deploys" ] || die "$file holds no deploys-cli-$version/deploys"

# --- install --------------------------------------------------------------------------------
if { [ -e "$bindir/deploys" ] || [ -L "$bindir/deploys" ]; } && ! ours "$bindir/deploys" && [ "$force" != 1 ]; then
  die "$bindir/deploys exists and was not installed by this script (Homebrew or by hand?). Remove it, pick another --prefix, or pass --force."
fi

# A small launcher in bin/ that runs the real script in lib/deploys/, so the script finds
# VERSION and providers/ next to itself.
q="$(printf '%s' "$libdir/deploys" | sed "s/'/'\\\\''/g")"
printf '#!/bin/sh\n%s\nexec '\''%s'\'' "$@"\n' "$MARKER" "$q" > "$tmp/launcher"

run mkdir -p "$bindir" "$prefix/lib"
run rm -rf "$libdir.new"
run cp -R "$src" "$libdir.new"
run chmod -R u=rwX,go=rX "$libdir.new"
run chmod 0755 "$libdir.new/deploys"
run rm -rf "$libdir"
run mv "$libdir.new" "$libdir"
run cp "$tmp/launcher" "$bindir/deploys.new"
run chmod 0755 "$bindir/deploys.new"
run mv -f "$bindir/deploys.new" "$bindir/deploys"

installed="$("$bindir/deploys" --version 2>/dev/null || true)"
say "Installed deploys $installed: $bindir/deploys (files in $libdir)"

# --- PATH -----------------------------------------------------------------------------------
case ":${PATH:-}:" in
  *":$bindir:"*) ;;
  *)
    say ""
    say "$bindir is not on your PATH. Add it, then open a new terminal:"
    say "  bash: echo 'export PATH=\"$bindir:\$PATH\"' >> ~/.bashrc"
    say "  zsh:  echo 'export PATH=\"$bindir:\$PATH\"' >> ~/.zshrc"
    say "  fish: fish_add_path $bindir"
    ;;
esac
if has deploys && [ "$(command -v deploys)" != "$bindir/deploys" ]; then
  say "Note: \`deploys\` on your PATH is $(command -v deploys), which comes first."
fi

# --- dependencies ---------------------------------------------------------------------------
os="$(uname -s 2>/dev/null || echo unknown)"
distro=""
if [ "$os" = Linux ] && [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  distro="$(. /etc/os-release && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
fi
pm=other
case "$os" in
  Darwin) pm=brew ;;
  Linux)
    case " $distro " in
      *" debian "*|*" ubuntu "*) pm=apt ;;
      *" fedora "*|*" rhel "*|*" centos "*) pm=dnf ;;
      *" arch "*) pm=pacman ;;
      *" alpine "*) pm=apk ;;
      *" suse "*|*" opensuse "*|*opensuse*) pm=zypper ;;
    esac ;;
esac
sudo_hint=""; [ "$(id -u)" != 0 ] && sudo_hint="sudo "

# How to install a tool here: hint <tool>
hint() {
  case "$1" in
    vercel) say "npm install -g vercel   (needs Node.js: https://nodejs.org), then: vercel login (or VERCEL_TOKEN in CI)"; return ;;
  esac
  case "$pm:$1" in
    brew:column) say "part of macOS" ;;
    brew:*) say "brew install $1" ;;
    apt:gh) say "${sudo_hint}apt-get install -y gh   (Debian 12+, Ubuntu 23.04+; older: https://github.com/cli/cli/blob/trunk/docs/install_linux.md)" ;;
    apt:column) say "${sudo_hint}apt-get install -y bsdextrautils" ;;
    apt:*) say "${sudo_hint}apt-get install -y $1" ;;
    dnf:column) say "${sudo_hint}dnf install -y util-linux" ;;
    dnf:*) say "${sudo_hint}dnf install -y $1" ;;
    pacman:gh) say "${sudo_hint}pacman -S github-cli" ;;
    pacman:column) say "${sudo_hint}pacman -S util-linux" ;;
    pacman:*) say "${sudo_hint}pacman -S $1" ;;
    apk:gh) say "${sudo_hint}apk add github-cli" ;;
    apk:column) say "${sudo_hint}apk add util-linux-misc" ;;
    apk:*) say "${sudo_hint}apk add $1" ;;
    zypper:column) say "${sudo_hint}zypper install util-linux" ;;
    zypper:*) say "${sudo_hint}zypper install $1" ;;
    *:gh) say "https://github.com/cli/cli#installation" ;;
    *:jq) say "https://jqlang.org/download/" ;;
    *) say "your package manager: $1" ;;
  esac
}

report() {  # report <tool> <required|optional> <what for>
  if has "$1"; then return; fi
  say "  $1 ($2: $3)"
  say "      install: $(hint "$1")"
}
say ""
say "Checking what deploys uses:"
out="$(
  report bash required "deploys is a bash script"
  report jq required "everything"
  report curl required "Render and the GitHub API"
  report vercel optional "Vercel projects"
  report gh optional "what is waiting to deploy: commits and PRs; then: gh auth login (or GH_TOKEN in CI)"
  report column optional "the tables of status, history and changed"
)"
if [ -z "$out" ]; then
  say "  all there (bash, jq, curl, vercel, gh, column)."
else
  say "$out"
fi
[ "$os" = Linux ] && grep -qi microsoft /proc/version 2>/dev/null \
  && say "  (WSL: install these inside the Linux distribution, not on Windows.)"

say ""
say "Next: deploys doctor   (checks tools and access)."
say "Keys: vercel login or VERCEL_TOKEN; RENDER_API_KEY for Render (on a Mac also: deploys render set-key)."
say "Docs: https://github.com/$REPO/blob/main/README-CLI.md"
{ has bash && has jq && has curl; } || warn "deploys is installed, but needs the required tools above before it can run."
exit 0
