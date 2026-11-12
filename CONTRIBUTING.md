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
(such as `vercel.sh` or `netlify.sh`), sourced by `deploys`. To add a platform, add one file there and its
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
bash tests/ios-rule-tests.sh        # the "waiting" rule in deploys and in the iPhone app agree
REQUIRE_ALL=1 bash integrations/tests/run.sh   # needs npm ci in integrations/mcp and integrations/vscode
./build.sh --widgets                # ad hoc signed, universal, with the widgets
```

The other CI jobs:

- **ios:** the iPhone app and its widgets, built for the simulator without signing (`xcodebuild … -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build`), and `bash ios/Tests/run.sh` (the log masking against the script's, no simulator).
- **linux-cli:** `script-tests.sh`, `team-tests.sh`, `release-tests.sh` and `ios-rule-tests.sh` on Ubuntu (GNU tools, bash 5).
- **cli-install:** `tests/install-tests.sh` with `dash` and with bash as `sh`.
- **integrations:** `REQUIRE_ALL=1 bash integrations/tests/run.sh` on Ubuntu (MCP server, Action, notify, digest, statuspage, badge, hooks, Claude Code plugin). A part that cannot run fails the job.
- **docker:** the image in `integrations/docker/` builds and finds its providers.
- **vscode:** `integrations/vscode`: `npm ci`, `npm run typecheck`, `npm test`, `npm run package`.
- **raycast:** `integrations/raycast`: `ray build` (offline), ESLint and Prettier.
- **docs:** `python3 scripts/build-docs.py`, `python3 scripts/check-links.py site`, `python3 scripts/check-site.py` (titles, canonical links, JSON-LD, sitemap), `python3 -I scripts/check-strings.py` (every `L(English, Deutsch)` has both texts), and `python3 -I scripts/check-release.py` (`VERSION`, the home page and the appcast name the same release; a mismatch fails the job).
- **public-commits:** on a pull request, `scripts/check-public.sh --stdin` over the commit messages.
- **changelog:** on a pull request that changes `deploys` or `app/` but not `CHANGELOG.md`, a warning. The label `no-changelog` silences it.

Not in CI, run it by hand when you touch the app:

```bash
swiftc -parse-as-library -swift-version 5 -typecheck app/*.swift shared/*.swift
```

`script-tests.sh` checks the rules in `deploys` with a stand-in for `gh`, without network. It also
runs `tests/providers/*.sh`, the provider contract, against the fixtures in `tests/fixtures/<p>/`.
`app-tests.sh` compiles the app's sources (without `App.swift`) with `tests/app-tests.swift`.

## Website

`site/` is the static website (deploycenter.app), published by the Website workflow. The docs
pages under `site/docs/` are generated from the Markdown in this repo and are not tracked.

```bash
python3 scripts/build-docs.py
python3 scripts/check-links.py site
python3 scripts/check-site.py
python3 -m http.server -d site 8000
```

The first writes `site/docs/` and the docs part of `site/sitemap.xml`, and puts `VERSION` into
`site/index.html`. The checks need no network. The last serves the site at http://localhost:8000.

A new guide is a folder `site/guides/<slug>/index.html`. Add it by hand to `site/sitemap.xml`,
`site/llms.txt`, the guides list in the footer of the other guides and of `site/404.html`, and the
related links of the guides on the same topic. A new docs page is one line in `PAGES` in
`scripts/build-docs.py`.

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


1. `scripts/bump.sh patch|minor|major` (or a version) sets `VERSION`, moves the lines under
   `## Unreleased` in `CHANGELOG.md` to the new version and changes the version in
   `site/index.html`. Commit that.
2. `./release.sh` refuses to run if `CHANGELOG.md` has nothing for the version in `VERSION`, and
   (with `--publish`) if the tag `vVERSION` already exists.
3. It builds and signs with `build.sh`, using `DEVELOPER_ID` (from the environment or
   `.release.env`, which is not tracked).
4. It submits to Apple's notary service with the `NOTARY_PROFILE` keychain profile and waits; if
   the wait breaks off, it waits again for the same submission.
5. It staples the ticket, checks it with `stapler validate` and `spctl`, zips the app into `dist/`
   and prints its SHA-256.
6. With `--publish`:
   - packs the CLI tarball `deploys-cli-VERSION.tar.gz` and `checksums.txt` from the same commit
     (`scripts/package-cli.sh`);
   - creates the GitHub release `vVERSION` with the zip, its `.sha256`, the tarball and
     `checksums.txt`; the notes are that version's section of `CHANGELOG.md` plus the checksums;
   - downloads both files again and compares the SHA-256;
   - signs the zip for Sparkle (EdDSA, key in the login keychain) and adds it to
     `site/appcast.xml` (`scripts/appcast.py`);
   - writes the Homebrew cask and formula into a clone of the tap (`scripts/homebrew-cask.sh`,
     `scripts/homebrew-formula.sh`). Nothing is pushed.
7. By hand: a pull request with `site/appcast.xml` (installed apps see the update once it is on
   `main`), and one in the tap with the cask and the formula. `release.sh` prints the commands.

`./release.sh --publish-only` publishes the zip already in `dist/` after a failed upload.
