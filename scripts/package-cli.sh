#!/usr/bin/env bash
# Builds the CLI release tarball and its checksums, for GitHub Releases, install.sh and the
# Homebrew formula.
#   scripts/package-cli.sh                       from the working tree, into dist/
#   scripts/package-cli.sh --ref <commit>        from that commit (what release.sh uses)
#   scripts/package-cli.sh --out <dir> [file…]   other output folder; the files are added to checksums.txt
# Writes <out>/deploys-cli-<version>.tar.gz, holding one folder deploys-cli-<version>/ with
# deploys, VERSION, LICENSE, README-CLI.md and providers/ (when the repo has it), and
# <out>/checksums.txt ("<sha256>  <file name>", one per line, the format of sha256sum -c).
set -euo pipefail
caller="$PWD"
cd "$(dirname "$0")/.."
# Paths given on the command line are relative to where it was run, not to the repo.
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$caller" "$1" ;; esac; }
die() { echo "package-cli.sh: $*" >&2; exit 1; }

out="$PWD/dist" ref="" extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || die "--out needs a folder"; out="$(abs "$2")"; shift 2 ;;
    --ref) [ $# -ge 2 ] || die "--ref needs a commit"; ref="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) f="$(abs "$1")"; [ -f "$f" ] || die "no file $1"; extra+=("$f"); shift ;;
  esac
done

check_version() { [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must be x.y.z, not \"$version\""; }
sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
mkdir -p "$out"

if [ -n "$ref" ]; then
  # From git: the same commit gives the same bytes (git archive, gzip -n), so a --publish-only
  # retry uploads what was there before.
  git rev-parse -q --verify "$ref^{commit}" >/dev/null || die "no commit $ref"
  version="$(git show "$ref:VERSION")"
  check_version
  paths=(deploys VERSION LICENSE README-CLI.md)
  for f in "${paths[@]}"; do git cat-file -e "$ref:$f" 2>/dev/null || die "$f is missing at $ref"; done
  # providers/ may not exist at that commit; git archive fails on a missing path.
  git cat-file -e "$ref:providers" 2>/dev/null && paths+=(providers)
  name="deploys-cli-$version"
  tarball="$out/$name.tar.gz"
  git -c tar.umask=022 archive --format=tar --prefix="$name/" "$ref" -- "${paths[@]}" | gzip -n -9 > "$tarball"
else
  version="$(cat VERSION)"
  check_version
  for f in deploys LICENSE README-CLI.md; do [ -f "$f" ] || die "$f is missing"; done
  name="deploys-cli-$version"
  dir="$stage/$name"
  mkdir -p "$dir"
  cp deploys VERSION LICENSE README-CLI.md "$dir/"
  [ -d providers ] && cp -R providers "$dir/providers"
  chmod -R u=rwX,go=rX "$dir"
  chmod 0755 "$dir/deploys"
  tarball="$out/$name.tar.gz"
  # COPYFILE_DISABLE: no ._ files from macOS tar.
  (cd "$stage" && COPYFILE_DISABLE=1 tar -cf - "$name") | gzip -n -9 > "$tarball"
fi

{
  printf '%s  %s\n' "$(sha256 "$tarball")" "$name.tar.gz"
  for f in ${extra[@]+"${extra[@]}"}; do printf '%s  %s\n' "$(sha256 "$f")" "$(basename "$f")"; done
} > "$out/checksums.txt"

echo "Wrote $tarball"
echo "Wrote $out/checksums.txt"
