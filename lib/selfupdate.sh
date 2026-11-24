# shellcheck shell=bash
# lib/selfupdate.sh - `deploys self-update --check`: asks the release feed which version is newest and says
# whether this one is behind. It only checks and prints: it downloads no tarball and changes no file; the update
# itself is one command it prints (install.sh, or brew, or docker pull, depending on where this copy came from).
# Sourced by deploys.
#
#   deploys self-update --check [--json]
#     exit 0 up to date (or newer than the release feed), 10 an update is available, 1 the feed could not be read
#   DEPLOYS_UPDATE_BASE  where releases are listed (default: the GitHub releases; file://... in tests). Like
#                        install.sh's DEPLOYS_INSTALL_BASE. The proxy variables of curl (HTTPS_PROXY ...) are honoured.

SELFUPDATE_DEFAULT_BASE="https://github.com/Pschmetzer/deploy-center/releases"

# selfupdate_newer <a> <b>: 0 when version a is higher than b (numbers x.y.z, compared one by one; no sort -V on macOS 12).
selfupdate_newer() {
  local a="$1" b="$2" i x y
  for i in 1 2 3; do
    x="$(printf '%s' "$a" | cut -d. -f"$i")"; y="$(printf '%s' "$b" | cut -d. -f"$i")"
    x="${x:-0}"; y="${y:-0}"
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
  done
  return 1
}

# How this copy was installed, and the command that updates it. Only the printing depends on it.
selfupdate_how() {
  local d; d="$(script_dir "$SELF" 2>/dev/null)"
  case "$d" in
    */Cellar/*|*/homebrew/*|*/Homebrew/*|*/linuxbrew/*) echo "brew upgrade deploys" ;;
    /usr/local/bin) if [ -f /.dockerenv ]; then echo "docker pull (the image tag you run), then start a new container"; else echo "curl -fsSL https://deploycenter.app/install.sh | sh"; fi ;;
    *) echo "curl -fsSL https://deploycenter.app/install.sh | sh" ;;
  esac
}

selfupdate_main() {
  # --json is a global option of deploys (it is removed from the arguments and sets $json before this runs).
  local check=0 a
  json="${json:-0}"
  shift   # "self-update"
  for a in "$@"; do
    case "$a" in
      --check) check=1 ;;
      --json) json=1 ;;
      -h|--help) echo "Usage: deploys self-update --check [--json]   (only checks and prints; it installs nothing)"; return 0 ;;
      *) echo "Usage: deploys self-update --check [--json]" >&2; return 2 ;;
    esac
  done
  [ "$check" = 1 ] || { echo "Usage: deploys self-update --check [--json]   (this command only checks; it never installs)" >&2; return 2; }
  local base="${DEPLOYS_UPDATE_BASE:-$SELFUPDATE_DEFAULT_BASE}" cur sums latest err
  cur="$(deploys_version)"
  sums="$(curl -fsSL --proto '=https,file' --proto-redir '=https' --connect-timeout 10 --max-time 30 --retry 2 \
    "$base/latest/download/checksums.txt" 2>/dev/null)" || sums=""
  latest="$(printf '%s\n' "$sums" | sed -n 's/^[0-9a-f]\{64\}  deploys-cli-\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\.tar\.gz$/\1/p' | head -n 1)"
  if [ -z "$latest" ]; then
    err="could not read the latest release from $base (offline, behind a proxy that blocks it, or no CLI release yet)"
    if [ "$json" = 1 ]; then jq -nc --arg c "$cur" --arg e "$err" '{current:$c, latest:null, update:null, error:$e}'
    else echo "Error: $err. Running: deploys $cur" >&2; fi
    return 1
  fi
  if ! printf '%s' "$cur" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    # unknown or a development version: nothing to compare, so no claim either way
    if [ "$json" = 1 ]; then jq -nc --arg c "$cur" --arg l "$latest" '{current:$c, latest:$l, update:null, error:null}'
    else echo "This copy says its version is '$cur', so it cannot be compared. The latest release is $latest."; fi
    return 0
  fi
  local how; how="$(selfupdate_how)"
  if selfupdate_newer "$latest" "$cur"; then
    if [ "$json" = 1 ]; then jq -nc --arg c "$cur" --arg l "$latest" --arg h "$how" '{current:$c, latest:$l, update:true, command:$h, error:null}'
    else echo "Update available: $cur -> $latest"; echo "To update: $how"; fi
    return 10
  fi
  if [ "$json" = 1 ]; then jq -nc --arg c "$cur" --arg l "$latest" '{current:$c, latest:$l, update:false, error:null}'
  else echo "deploys $cur is up to date (latest release: $latest)."; fi
  return 0
}
