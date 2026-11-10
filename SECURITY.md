# Security

## Report a problem

Open a [private security advisory](https://github.com/Pschmetzer/deploy-center/security/advisories/new)
(Security tab), not a public issue. Please include the version (Settings → "Copy diagnostics")
and the steps to see the problem. Leave out real project names, domains and keys.

Deploy Center is maintained by one person in their spare time. The aim is a first answer within
7 days, and a fix in a new release as soon as one is ready. There is no bug bounty.

## Supported versions

Only the newest release gets fixes. Update with **Update now** in Settings or
`brew upgrade --cask deploy-center`.

| Version | Fixes |
|---|---|
| newest release (see [Releases](https://github.com/Pschmetzer/deploy-center/releases/latest)) | yes |
| anything older | no, update first |

## How it handles your data

- No server and no telemetry. The app calls the Vercel CLI, the GitHub CLI and the Render API with
  your own logins. It also asks GitHub once a day for the newest release (can be turned off in
  Settings) and loads project icons from your projects' own domains.
- The Render API key is stored in the macOS keychain (service `deploy-center-render`) and is passed
  to `curl` on stdin, never as a command-line argument. Prefer a key made only for this app.
- Nothing starts a build without an explicit click or a command with `--yes`.

## Updates

Releases are built by `release.sh`: signed with a Developer ID certificate, notarized by Apple and
stapled. The release notes give the SHA-256 of the zip.

**Update now** downloads the zip of the newest GitHub release over HTTPS, unpacks it to a
temporary folder and, before it replaces the app, checks it with
`codesign --verify --deep --strict` and with Gatekeeper (`spctl -a -t exec`). If either check
fails, the app is left as it is.

## Scope

In scope: the app, the `deploys` CLI, the update path, `build.sh` / `release.sh`, and the website in
`site/`.

Out of scope: Vercel, Render, GitHub and their CLIs themselves (report those to the vendor), and
problems that need an attacker who already controls your Mac account.
