# Check a release before you open it

Every release on GitHub is one zip, `DeployCenter-<version>-universal.zip`. `release.sh` signs it
with a Developer ID, has Apple notarize it, staples the ticket, and writes the zip's SHA-256 into
the release notes. Three checks, each a single command, tell you the zip is that file.

Here, `<version>` stands for the version you downloaded, for example `0.9.1`.

## 1. The checksum matches the release notes

```bash
shasum -a 256 ~/Downloads/DeployCenter-<version>-universal.zip
```

Compare that with the line `SHA-256 of the zip:` in the release notes. You can also print the
line without a browser:

```bash
gh release view v<version> --repo Pschmetzer/deploy-center --json body -q .body | grep SHA-256
```

The Homebrew cask carries the same value in `sha256`, and `brew` checks it for you.

## 2. The signature is intact and is the project's own

Unzip the file first (Finder or `ditto -x -k <zip> .`), then run:

```bash
codesign --verify --deep --strict --verbose=2 "Deploy Center.app"
codesign -dv "Deploy Center.app" 2>&1 | grep -E 'Identifier|TeamIdentifier|flags'
```

What to expect:

- `valid on disk` and `satisfies its Designated Requirement` from the first command.
- `Identifier=app.deploycenter.mac`
- `TeamIdentifier=<TEAMID>`, a ten-character Apple team id. It must be the same id that `spctl`
  shows in parentheses on its `origin=` line (step 3). The app's updater pins this same team: it
  installs an update only when the update is signed by this team.
- `flags=0x10000(runtime)`, which means the hardened runtime is on, as notarization requires.

`TeamIdentifier=not set` or `Signature=adhoc` means a local build, not a release.

## 3. Gatekeeper accepts it as notarized

```bash
spctl --assess -vv "Deploy Center.app"
xcrun stapler validate "Deploy Center.app"
```

What to expect:

- `accepted`
- `source=Notarized Developer ID`
- `origin=` followed by the Developer ID with the same team id as above
- `The validate action worked!`, which means the ticket is stapled, so the check also works offline.

`rejected`, or `source=Unnotarized Developer ID`, means you should not open it. Report that in an
issue, together with the version and the zip's SHA-256.

## The `deploys` CLI on its own

The CLI is not signed. Each release has it as a tarball, `deploys-cli-<version>.tar.gz`, with
`deploys`, `VERSION` and `providers/` inside (the script alone does not run without `providers/`),
and a `checksums.txt` with the SHA-256 of every file of the release:

```bash
v=<version>
base="https://github.com/Pschmetzer/deploy-center/releases/download/v$v"
curl -fsSLO "$base/deploys-cli-$v.tar.gz"
curl -fsSLO "$base/checksums.txt"
shasum -a 256 -c checksums.txt --ignore-missing
```

`deploys-cli-<version>.tar.gz: OK` means it is the file of the release. The install script
(`curl -fsSL https://deploycenter.app/install.sh | sh`) runs the same check before it writes
anything. The files are plain text, so read them before you run them; to compare them with the
source, `git diff --no-index <unpacked folder>/deploys <checkout at tag v<version>>/deploys`.
