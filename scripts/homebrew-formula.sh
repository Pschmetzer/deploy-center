#!/usr/bin/env bash
# Prints the Homebrew formula for the CLI (macOS and Linux), or writes it into a clone of the tap
# repo (github.com/Pschmetzer/homebrew-tap, file Formula/deploys.rb). Users install it with:
#   brew install pschmetzer/tap/deploys
#   scripts/homebrew-formula.sh                      VERSION and the tarball in dist/
#   scripts/homebrew-formula.sh 0.8.0 <sha256>
#   scripts/homebrew-formula.sh --write <tap-dir> [version [sha256]]
# With --write, the published tarball is downloaded and must have the same SHA-256
# (--no-check skips that, e.g. before the release is up).
set -euo pipefail
cd "$(dirname "$0")/.."
die() { echo "homebrew-formula.sh: $*" >&2; exit 1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

write="" check=1 pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --write) [ $# -ge 2 ] || die "--write needs the tap directory"; write="$2"; shift 2 ;;
    --no-check) check=0; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) pos+=("$1"); shift ;;
  esac
done
[ "${#pos[@]}" -le 2 ] || die "too many arguments"
version="${pos[0]:-$(cat VERSION)}"
sha="${pos[1]:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "not a version: $version"
if [ -z "$sha" ]; then
  tarball="dist/deploys-cli-${version}.tar.gz"
  [ -f "$tarball" ] || die "no $tarball; run scripts/package-cli.sh first or pass the sha256"
  sha="$(sha256 < "$tarball")"
fi
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "not a SHA-256: $sha"

url="https://github.com/Pschmetzer/deploy-center/releases/download/v${version}/deploys-cli-${version}.tar.gz"

# The script lives in libexec with VERSION (and providers/, once there); bin/deploys is a small
# wrapper that execs it, so it finds them next to itself. No generated completions: the
# completion text names the config folder of whoever generates it.
formula() {
cat <<FORMULA
class Deploys < Formula
  desc "Turn off auto-deploy on Vercel and Render, then deploy what changed by hand"
  homepage "https://deploycenter.app/"
  url "${url}"
  sha256 "${sha}"
  license "MIT"

  livecheck do
    url :stable
    strategy :github_latest
  end

  depends_on "jq"
  uses_from_macos "bash"
  uses_from_macos "curl"

  def install
    libexec.install "deploys", "VERSION"
    libexec.install "providers" if File.directory?("providers")
    (bin/"deploys").write_env_script libexec/"deploys", {}
    doc.install "README-CLI.md"
  end

  def caveats
    <<~EOS
      Homebrew 6 installs from this tap only after you trust it once:
        brew trust pschmetzer/tap
      For Vercel install the Vercel CLI (npm install -g vercel); for what is waiting
      to deploy, the GitHub CLI (brew install gh). Then run: deploys doctor
      Tab completion: eval "\$(deploys completion zsh)" in ~/.zshrc (or bash in ~/.bashrc).
    EOS
  end

  test do
    ENV["DEPLOYS_CONFIG"] = (testpath/"config").to_s
    assert_equal version.to_s, shell_output("#{bin}/deploys --version").strip
    assert_match "deploys doctor", shell_output("#{bin}/deploys --help")
  end
end
FORMULA
}

[ -n "$write" ] || { formula; exit 0; }

[ -d "$write" ] || die "no directory $write"
if [ "$check" = 1 ]; then
  got="$(curl -fsSL --retry 3 "$url" | sha256)" || die "could not download $url"
  [ "$got" = "$sha" ] || die "the published tarball has SHA-256 $got, not $sha ($url)"
fi
mkdir -p "$write/Formula"
formula > "$write/Formula/deploys.rb"
echo "Wrote $write/Formula/deploys.rb ($version)"
