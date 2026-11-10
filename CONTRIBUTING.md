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
There is no Xcode project: `build.sh` compiles `app/*.swift` into a universal app.

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
(`vercel.sh`, `render.sh`), sourced by `deploys`. To add a platform, add one file there and its
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
shellcheck --severity=warning deploys providers/*.sh build.sh release.sh scripts/*.sh tests/*.sh tests/lib/*.sh tests/providers/*.sh
```

```bash
swiftc -parse-as-library -swift-version 5 -typecheck app/*.swift
```

`script-tests.sh` checks the rules in `deploys` with a stand-in for `gh`, without network. It also
runs `tests/providers/*.sh`, the provider contract, against the fixtures in `tests/fixtures/<p>/`.
`app-tests.sh` compiles the app's sources (without `App.swift`) with `tests/app-tests.swift`.

## Releases (maintainer)

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

Raising `VERSION` and moving the changelog lines from Unreleased to the new version are done by
hand before that.
