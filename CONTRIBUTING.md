# Contributing

Thanks for helping. Small, focused pull requests are easiest to review. For a bigger change,
open an issue first.

## Rules

- No personal project names, team IDs, domains or paths in commits, issues or screenshots (the repo
  is public). Take screenshots in **demo mode** (Settings → "Demo mode"): it replaces project names,
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

All of these run in CI (`.github/workflows/ci.yml`) and must pass:

```bash
bash tests/script-tests.sh
```

```bash
bash tests/app-tests.sh
```

```bash
shellcheck --severity=warning deploys providers/*.sh build.sh release.sh scripts/*.sh tests/*.sh tests/lib/*.sh tests/providers/*.sh lib/*.sh
shellcheck site/install.sh
```

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
