#!/usr/bin/env bash
# Prints the Homebrew cask for a release. Put the output in the tap repo
# (github.com/Pschmetzer/homebrew-tap, file Casks/deploy-center.rb).
#   scripts/homebrew-cask.sh            uses VERSION and build/DeployCenter-VERSION-universal.zip
#   scripts/homebrew-cask.sh 0.5.0 <sha256>
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:-$(cat VERSION)}"
sha="${2:-}"
if [ -z "$sha" ]; then
  zip="build/DeployCenter-${version}-universal.zip"
  [ -f "$zip" ] || { echo "no $zip; run ./release.sh first or pass the sha256" >&2; exit 1; }
  sha="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
fi
cat <<CASK
cask "deploy-center" do
  version "${version}"
  sha256 "${sha}"

  url "https://github.com/Pschmetzer/deploy-center/releases/download/v#{version}/DeployCenter-#{version}-universal.zip"
  name "Deploy Center"
  desc "Turn off auto-deploy on Vercel and Render and deploy by hand"
  homepage "https://deploycenter.app"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sequoia"

  app "Deploy Center.app"
  binary "#{appdir}/Deploy Center.app/Contents/Resources/deploys"

  zap trash: [
    "~/Library/Preferences/app.deploycenter.mac.plist",
    "~/Library/Logs/DeployCenter.log",
    "~/.config/deploys",
  ]
end
CASK
