# Check a release before you open it

Every release on GitHub is one zip, `DeployCenter-<version>-universal.zip`. `release.sh` signs it
with a Developer ID, has Apple notarize it, staples the ticket, and writes the zip's SHA-256 into
the release notes. Three checks, each a single command, tell you the zip is that file.

Here, `0.7.0` stands for the version you downloaded.

## 1. The checksum matches the release notes

```bash
shasum -a 256 ~/Downloads/DeployCenter-0.7.0-universal.zip
```

Compare that with the line `SHA-256 of the zip:` in the release notes. You can also print the
line without a browser:

```bash
gh release view v0.7.0 --repo Pschmetzer/deploy-center --json body -q .body | grep SHA-256
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
- `TeamIdentifier=QX3P875C86`. The app's updater pins this same team: it installs an update
  only when the update is signed by this team.
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

## The `deploys` script on its own

The script is not signed. It is plain text, so read it before you run it. To pin it to a release,
download it from the tag instead of `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/Pschmetzer/deploy-center/v0.7.0/deploys -o deploys
```

Then compare it with the file of the same name in the tag: `git show v0.7.0:deploys | diff - deploys`.
