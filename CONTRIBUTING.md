# Contributing

Thanks for helping. Small, focused pull requests are easiest to review. For a bigger change,
open an issue first.

## Rules

- No personal project names, team IDs, domains or paths in commits, issues or screenshots (the repo
  is public). Take screenshots in **demo mode** (Settings → General → "Demo mode"): it replaces project names,
  repos and domains with stand-ins.
- Texts are English and German: use `L("English", "Deutsch")`.
- Nothing may start a build without an explicit click or a command with `--yes`.
- Add a line under `## Unreleased` in `CHANGELOG.md` for anything a user would notice.

## Build

Needs macOS 15 and `swiftc` (Xcode or the Command Line Tools), plus `jq`.
There is no Xcode project: `build.sh` compiles `app/*.swift` and `shared/*.swift` into a universal app (widgets and the iOS app: docs/WIDGETS-IOS.md).

```bash
./build.sh
```

```bash
./build.sh --install
```

The first builds `build/Deploy Center.app`; `--install` also copies it to `~/Applications`.
Without a Developer ID certificate the app is signed ad hoc: it runs, but macOS refuses it as a
login item.

The logic lives in one bash script, `deploys`, which the app calls; it also works alone
(`./deploys` without arguments prints the help). Each platform is one file in `providers/`
(`vercel.sh`, `render.sh`, `netlify.sh`, …), sourced by `deploys`. To add a platform, add one file there and its
fixtures; nothing else changes. See [docs/PROVIDERS.md](docs/PROVIDERS.md). Keep `providers/` next to
`deploys` (or set `DEPLOYS_DIR`).

## Tests

All suites at once, with a summary at the end (no network, no real projects):

```bash
bash tests/all.sh            # CLI, team, install, release, app (on macOS) and integration tests
bash tests/all.sh --quick    # without the app and integration tests (no Swift build, no node)
```

The integration tests need `npm ci` in `integrations/mcp` and `integrations/vscode` first.

CI (`.github/workflows/ci.yml`) runs these on macOS, and they must pass:

```bash
scripts/check-public.sh             # no personal data in tracked files
actionlint .github/workflows/*.yml docs/deploy-on-label.yml examples/*.yml integrations/*/examples/*.yml
shellcheck --severity=warning deploys providers/*.sh build.sh release.sh scripts/*.sh tests/*.sh tests/lib/*.sh tests/providers/*.sh lib/*.sh
shellcheck --severity=warning integrations/*/*.sh integrations/claude-code/scripts/*.sh integrations/hooks/pre-push integrations/tests/*.sh
shellcheck site/install.sh
plutil -lint scripts/*.plist.example
swiftc -typecheck scripts/make-icon.swift
bash tests/script-tests.sh          # the rules in deploys, and tests/providers/*.sh
bash tests/team-tests.sh            # team mode
bash tests/install-tests.sh         # install.sh, the release tarball, the Homebrew formula
bash tests/release-tests.sh         # release gate, bump.sh, site checks, check-public, Homebrew cask
bash tests/app-tests.sh             # the rules in the app, in English and German
./build.sh --widgets                # ad hoc signed, universal, with the widgets
```

The other CI jobs:

- **ios:** the iPhone app and its widgets, built for the simulator without signing (`xcodebuild … -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build`).
- **linux-cli:** `script-tests.sh`, `team-tests.sh` and `release-tests.sh` on Ubuntu (GNU tools, bash 5).
- **cli-install:** `tests/install-tests.sh` with `dash` and with bash as `sh`.
- **integrations:** `bash integrations/tests/run.sh` (MCP server, Action, notify, digest, statuspage, badge, hooks, Claude Code plugin). It may fail for now without failing the run.
- **docker:** the image in `integrations/docker/` builds and finds its providers.
- **vscode:** `integrations/vscode`: `npm ci`, `npm run typecheck`, `npm test`, `npm run package`.
- **docs:** `python3 scripts/build-docs.py`, `python3 scripts/check-links.py site`, `python3 scripts/check-site.py` (titles, canonical links, JSON-LD, sitemap), `python3 -I scripts/check-strings.py` (every `L(English, Deutsch)` has both texts), and `python3 -I scripts/check-release.py` (`VERSION`, the home page and the appcast name the same release; a warning for now).
- **changelog:** on a pull request that changes `deploys` or `app/` but not `CHANGELOG.md`, a warning. The label `no-changelog` silences it.

Not in CI, run it by hand when you touch the app:

```bash
swiftc -parse-as-library -swift-version 5 -typecheck app/*.swift shared/*.swift
```

`script-tests.sh` checks the rules in `deploys` with a stand-in for `gh`, without network. It also
runs `tests/providers/*.sh`, the provider contract, against the fixtures in `tests/fixtures/<p>/`.
`app-tests.sh` compiles the app's sources (without `App.swift`) with `tests/app-tests.swift`.

## Releases (maintainer)

`release.sh` reads `DEVELOPER_ID` and `NOTARY_PROFILE` from the environment, or from `.release.env`
in the repo root (ignored by git):

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
NOTARY_PROFILE=deploy-center
```

The file is sourced, so whatever is in it runs as shell code: keep only these two lines in it,
and make it yours alone with `chmod 600 .release.env`. It holds no secret itself (the notary
password stays in the keychain profile), but the team id in it is personal: never commit it.

`release.sh` does this today:

1. Refuses to run if `CHANGELOG.md` has nothing under `## Unreleased` or under the version in
   `VERSION`, and (with `--publish`) if the tag `vVERSION` already exists.
2. Builds and signs with `build.sh`, using `DEVELOPER_ID` (from the environment or `.release.env`,
   which is not tracked).
3. Submits to Apple's notary service with the `NOTARY_PROFILE` keychain profile and waits; if the
   wait breaks off, it waits again for the same submission.
4. Staples the ticket, checks it with `stapler validate` and `spctl`, zips the app as
   `build/DeployCenter-VERSION-universal.zip` and prints its SHA-256.
5. With `--publish`: creates the GitHub release `vVERSION` with the zip. The notes are that
   version's section of `CHANGELOG.md` plus the SHA-256.

6. With `--publish`: also uploads the CLI tarball and `checksums.txt`, signs the zip with the
   Sparkle EdDSA key (in the release Mac's keychain) into `site/appcast.xml`, and writes the
   Homebrew cask and formula into a clone of the tap. Nothing is pushed.

Before that, `scripts/bump.sh patch|minor|major` (or a version) sets `VERSION`, turns
`## Unreleased` into the new version and updates the version on `site/index.html`. Commit that.

After `--publish`: open a pull request with `site/appcast.xml` (`appcast-VERSION`, the script
prints the commands). Installed apps see the update only once it is on `main` and the website is
published. Then propose the cask and formula in the tap. Check that `VERSION`, the newest appcast
entry and the version on `site/index.html` agree.
