#!/usr/bin/env bash
# Prints the Homebrew cask for a release, or writes it into a clone of the tap repo
# (github.com/Pschmetzer/homebrew-tap, file Casks/deploy-center.rb).
#   scripts/homebrew-cask.sh                      VERSION and the zip in dist/ (or build/)
#   scripts/homebrew-cask.sh 0.5.0 <sha256>
#   scripts/homebrew-cask.sh --write <tap-dir> [version [sha256]]
# With --write, the published zip is downloaded and must have the same SHA-256
# (--no-check skips that, e.g. before the release is up).
set -euo pipefail
cd "$(dirname "$0")/.."
die() { echo "homebrew-cask.sh: $*" >&2; exit 1; }

write="" check=1 pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --write) [ $# -ge 2 ] || die "--write needs the tap directory"; write="$2"; shift 2 ;;
    --no-check) check=0; shift ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) pos+=("$1"); shift ;;
  esac
done
[ "${#pos[@]}" -le 2 ] || die "too many arguments"
version="${pos[0]:-$(cat VERSION)}"
sha="${pos[1]:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not a version: $version"
if [ -z "$sha" ]; then
  zip=""
  for z in "dist/DeployCenter-${version}-universal.zip" "build/DeployCenter-${version}-universal.zip"; do
    [ -f "$z" ] && { zip="$z"; break; }
  done
  [ -n "$zip" ] || die "no DeployCenter-${version}-universal.zip in dist/ or build/; run ./release.sh first or pass the sha256"
  sha="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
fi
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "not a SHA-256: $sha"

url="https://github.com/Pschmetzer/deploy-center/releases/download/v${version}/DeployCenter-${version}-universal.zip"

cask() {
cat <<CASK
cask "deploy-center" do
  version "${version}"
  sha256 "${sha}"

  url "https://github.com/Pschmetzer/deploy-center/releases/download/v#{version}/DeployCenter-#{version}-universal.zip"
  name "Deploy Center"
  desc "Deploy Vercel and Render projects by hand and keep build costs down"
  homepage "https://deploycenter.app/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on formula: "jq"
  depends_on macos: :sequoia

  # The app updates itself (Sparkle, signed appcast on deploycenter.app), so "brew upgrade"
  # leaves it alone unless --greedy is given; brew still sees the new version via livecheck.
  auto_updates true

  app "Deploy Center.app"

  uninstall quit: "app.deploycenter.mac"

  # ~/.config/deploys stays: it holds which repo each disconnected Vercel project came from.
  zap trash: [
    "~/Library/Logs/DeployCenter.log",
    "~/Library/Preferences/app.deploycenter.mac.plist",
  ]

  caveats <<~EOS
    Homebrew 6 installs from this tap only after you trust it once:
      brew trust pschmetzer/tap
    Without admin rights, install into your own Applications folder:
      brew install --cask --appdir="\$HOME/Applications" deploy-center
  EOS
end
CASK
}

[ -n "$write" ] || { cask; exit 0; }

[ -d "$write" ] || die "no directory $write"
if [ "$check" = 1 ]; then
  got="$(curl -fsSL --retry 3 "$url" | shasum -a 256 | cut -d' ' -f1)" || die "could not download $url"
  [ "$got" = "$sha" ] || die "the published zip has SHA-256 $got, not $sha ($url)"
fi
mkdir -p "$write/Casks"
cask > "$write/Casks/deploy-center.rb"
echo "Wrote $write/Casks/deploy-center.rb ($version)"
