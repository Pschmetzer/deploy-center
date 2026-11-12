# Security

## Report a problem

Open a [private security advisory](https://github.com/Pschmetzer/deploy-center/security/advisories/new)
(Security tab), not a public issue. Please include the version (Settings → Help → "Copy diagnostics")
and the steps to see the problem. Leave out real project names, domains and keys.

Deploy Center is maintained by one person in their spare time. The aim is a first answer within
7 days, and a fix in a new release as soon as one is ready. There is no bug bounty.

## Supported versions

Only the newest release gets fixes. Update with **Check for Updates …** in the app menu or
`brew upgrade --cask --greedy deploy-center`. The `deploys` CLI, the Docker image and the
integrations in `integrations/` (MCP server, VS Code and Raycast extensions, GitHub Action) are
fixed in the same repo: use the newest release. The iPhone app gets fixes in its newest
build.

| Version | Fixes |
|---|---|
| newest release (see [Releases](https://github.com/Pschmetzer/deploy-center/releases/latest)) | yes |
| anything older | no, update first |

## Threat model

Deploy Center runs as you, on your Mac (or in your CI job), with your Vercel, Render and GitHub
logins. It has no server of its own. What it protects:

1. **Your keys**: the Render API key, the Claude routine token, the Anthropic API key, the tokens
   of the opt-in hosts (Netlify, Cloudflare, DigitalOcean, Coolify; an AWS profile name for
   Amplify), deploy hook URLs, the Vercel, GitHub and GitLab CLI logins, and the keys handed to
   the iPhone app.
2. **Your build minutes and live sites**: nothing may start a build, a rollback or a cancel unless
   you asked for it.
3. **Your Mac**: text that comes from somewhere else must never run as code.

Text from somewhere else is everything the tool did not get from you directly: project and service
names, repo names, commit messages, build logs and workflow file names from the APIs of the hosts
and of GitHub and GitLab; a `deploy-center.json` in a repo (team mode: anyone with push rights
writes it); a `deploycenter://` link any web page can open; arguments an AI agent passes through
the MCP server; Claude's answers in the app; and the build log a Claude routine reads. It is
handled as data:

- `deploys` passes it to `jq` as `--arg`, never inside a filter; builds JSON with `jq`, never with
  `printf`; passes it to `bash -c` as an argument, never as part of the script.
- A project name or deploy id that goes into an API path or query string may not contain
  `/ ? # & % \` or control characters, may not be `.` or `..`, and may not start with `-`. A Vercel
  team id is letters, digits, `_` and `-` only. Anything else is refused before any request.
- The MCP server runs `deploys` with an argument array (no shell), accepts only names matching
  `[A-Za-z0-9._:-]+`, and offers deploy and rollback only with `DEPLOYS_MCP_ALLOW_DEPLOY=1`, one
  project per call. Even then it asks you itself (MCP elicitation) before each one, and refuses a
  client that cannot ask unless started with `DEPLOYS_MCP_CONFIRM=client` (then the client's own
  approval is the only yes; see [integrations/mcp](integrations/mcp/README.md#safety)).

Out of scope: someone who already runs code as your Mac user (they can read your keychain items
the same way the app does), and Vercel, Render, GitHub and their CLIs themselves (report those to
the vendor).

## What is sent where

| What | To | How |
|---|---|---|
| Project lists, deploys, build logs, starts and rollbacks | Vercel | the `vercel` CLI, with its own login |
| Service lists, deploys, build logs, starts and rollbacks | `api.render.com` | `curl` over HTTPS; the key on stdin (`curl -K -`) |
| Commits, compares, pull requests, check runs, workflow files | `api.github.com` | the `gh` CLI, with its own login |
| Commits, compares, merge requests (only for repos on GitLab) | `GITLAB_HOST` (`gitlab.com` when unset) | the `glab` CLI with its login, or `curl` with `GITLAB_TOKEN` on stdin; never to another host a repo URL names |
| Site lists, deploys, logs, starts and rollbacks (opt-in hosts, only after `deploys providers enable <p>`) | `api.netlify.com`, `api.cloudflare.com`, `api.digitalocean.com`, your Coolify server; AWS through the `aws` CLI | `curl` over HTTPS with the token on stdin; Amplify with the `aws` CLI's own credentials |
| A POST that starts a build | the deploy hook URL you added | `curl`, URL and headers on stdin |
| Claude in the app (opt-in, your own key): masked log excerpts, commit titles, file names | `api.anthropic.com` | `curl` over HTTPS; the key on stdin; only after `deploys ai set-key`, with a monthly token cap |
| Keys for the iPhone app: the Vercel token for the iPhone, the Render key, the `gh` token | iCloud Keychain (end-to-end encrypted by Apple), or a QR code on screen | only when you turn on Settings → iPhone or show the QR code; see [iPhone link](#iphone-link) |
| The `deploy-center` MCP entry: paths to `node`, the server and `deploys`, and `DEPLOYS_MCP_ALLOW_DEPLOY=1` only if you allow deploys; no key | `~/Library/Application Support/Claude/claude_desktop_config.json`, Claude Code's config | only on Connect in Settings → Claude; only that entry is added or removed |
| The update feed (once a day, can be turned off; no system profile), then the zip | `deploycenter.app/appcast.xml`, `github.com` | HTTPS, see [Updates](#updates) |
| Project icons | each project's own domain | HTTPS to `https://<domain>/`; icon links in that page are followed |
| Is a host down? (a plain GET, nothing of yours) | `www.vercel-status.com`, `status.render.com`, `www.githubstatus.com` | HTTPS, from the app |
| Commits, compares and merge requests (repos on GitLab only) | `gitlab.com` or your `GITLAB_HOST` | the `glab` CLI with its own login, or `curl` with `GITLAB_TOKEN` on stdin; only for projects whose repo is on GitLab |
| Opt-in hosts, once turned on (`deploys providers enable <name>`): site lists, deploys, build logs, starts, rollbacks | `api.netlify.com`, `api.cloudflare.com`, AWS Amplify (through the `aws` CLI and your AWS profile), `api.digitalocean.com`, your own Coolify instance (`COOLIFY_URL`) | HTTPS; each key from the keychain (`deploy-center-<name>`; for Amplify only a profile name) or the environment, on stdin |
| A deploy hook: the POST that starts a build, with the method, headers and body you set | the hook URL you added (`deploys hook add`) | `curl` over HTTPS (or `http://` to `localhost`); the URL from the keychain, on stdin |
| Claude in the app / `deploys ai` (opt-in, your own key): the masked log excerpt around the first error, or the titles of waiting commits and PRs, or diff stats and risky file names ([details](docs/CLAUDE.md#privacy)) | `api.anthropic.com` | `curl` over HTTPS; the key on stdin; only after you turn it on and save a key, and only when you ask |
| Autofix: project, repo, branch, commit, deploy id and the last 60 KB of the build log, masked | `api.anthropic.com` (your routine) | `curl` over HTTPS; the token on stdin; only after you set up a routine and a token |
| A daily summary of project names and counts | the webhook you set in `DEPLOYS_NOTIFY_URL` | `integrations/notify/notify.sh`, only when you run it |
| The agent digest: project names, commit titles and authors, PR titles, risk hints | the webhook you set, and an issue in a GitHub repo of yours | `integrations/digest/`, only when you run it (usually from your own GitHub workflow) |
| The iPhone app: the Vercel token, Render key and GitHub token of this Mac | your iCloud Keychain (end-to-end encrypted by Apple), or a QR code shown for a minute | only when you turn on *Connect the iPhone app* or show the code |

The MCP server, the Claude Code plugin, the Raycast and VS Code extensions run on your Mac and call
`deploys`; they send nothing on their own. The Autofix routine runs in Anthropic's cloud under your
Claude account and reads your repo there; what it keeps is governed by Anthropic's terms, not ours.

Nothing else leaves the Mac: no telemetry, no crash reports.

### Getting the software

| What | From |
|---|---|
| The app (zip), by hand or through an update | `github.com` releases (the feed: `deploycenter.app/appcast.xml`, GitHub Pages) |
| The app with Homebrew (`brew install --cask`) | the tap `Pschmetzer/homebrew-tap` on GitHub, the zip from `github.com` releases. Homebrew itself may send its own analytics; `brew analytics off` turns them off. |
| The CLI with `install.sh` | the script from `deploycenter.app` (GitHub Pages), `checksums.txt` and the tarball from `github.com` releases |
| The CLI with Homebrew (`brew install pschmetzer/tap/deploys`) | the formula from the tap, the tarball from `github.com` releases |

GitHub sees the IP address and time of each download, as for any download from GitHub.

## Keys and secrets

- The Render key is stored in the macOS keychain (service `deploy-center-render`), the routine token
  under `deploy-center-routine`, the Anthropic key under `deploy-center-anthropic`, the keys of the
  opt-in hosts under `deploy-center-<name>`, each deploy hook URL under `deploy-center-hook-<name>`
  and a Vercel token made for the iPhone under `deploy-center-phone-vercel`. All of them are read from stdin when you set them, stored through
  `security -i` on stdin, and handed to `curl` on stdin. They are never a command-line argument
  (visible in `ps`), and never printed: not by `where`, `doctor`, `autofix status`, `--json` output
  or error messages. Prefer a key made only for this app.
- *Connect the iPhone app* copies the Vercel token, the Render key and the GitHub token into one
  item of your iCloud Keychain (`app.deploycenter.link`), end-to-end encrypted by Apple. Turning the
  switch off deletes that item on all your devices.
- `RENDER_API_KEY` and `DEPLOYS_ROUTINE_TOKEN` in the environment take precedence (for CI). They are
  not checked like a key typed into `set-key`, so set them only from a secret store.
- While `render json` reads many services at once, the key sits in a `0600` file inside a `0700`
  `mktemp -d` folder and is removed right after.
- `~/.config/deploys` is set to `0700` on every run. It holds the remembered repos, the team id,
  the ignore list, locks and the Autofix state, but no API key. Deploy hook URLs (Netlify's in
  `netlify-hooks.json`, and `hook-urls/` when there is no keychain) are secrets too: anyone with
  one can start a build. They are `0600` files and never printed.

### Autofix log masking

Before a build log goes to the routine, `deploys` masks what it recognises: `Authorization: Bearer …`
headers; `NAME=value`, `NAME: value` and `"name": "value"` where the name ends in `token`, `secret`,
`password`, `api_key`, `access_key`, `_key`, `auth`, `credentials` or `dsn`; `--token`/`--password`
arguments; passwords in URLs; private key blocks; and tokens with a known prefix (Anthropic/OpenAI
`sk-`, Stripe `sk_`/`rk_`/`pk_`/`whsec_`, GitHub `ghp_`…/`github_pat_`, GitLab `glpat-`, Slack
`xox?-`, AWS `AKIA`/`ASIA`, Google `AIza`, npm `npm_`, Render `rnd_`, and JWTs). A Vercel token has
no fixed prefix: it is masked only next to a telling name (`VERCEL_TOKEN=`, `--token`). Masking is a
help, not a guarantee. If a build can print secrets in another shape, do not turn Autofix on.

The routine's prompt tells it that the payload is untrusted data and never to merge; a person
merges the fix PR, and a merged fix is only announced, never deployed by itself.

## iPhone link

The iPhone app has no login of its own. It gets keys from the Mac in one of two ways:

- **iCloud Keychain** (Settings → iPhone → *Connect the iPhone app*): one synced keychain item
  (service `app.deploycenter.link`) holds the Vercel token made for the iPhone, the Render key and
  the GitHub token of the `gh` CLI. It reaches every device signed in with your Apple ID. Turning
  the switch off deletes it there too (`PhoneLink.remove`); deleting the app does not.
- **QR code** (*Show a QR code for the iPhone …*): the same keys, as base64 JSON behind
  `deploycenter-link:1:`. They are not encrypted: anyone who sees or photographs the code has the
  keys. The window closes after 60 seconds, and the iPhone app refuses a code made more than five
  minutes ago, but the keys in it do not expire.

Use a Vercel token made only for the phone, and a Render key you can revoke. If a code may have
been seen, or a device is lost, revoke the keys at Vercel, Render and GitHub; removing the link
does not make a copied key useless.

## Nothing starts a build by itself

- Every start, rollback and cancel is a click in the app or a command (`deploy-changed` only with
  `--yes`). A second start of the same project within a minute is refused.
- `deploycenter://select?project=<name>` (or `platform:name`) only shows that project in the main
  window, and `deploycenter://settings/<tab>` only opens a settings tab. Neither ticks, starts or
  rolls back anything, whatever the link says.
- Autofix and the guard run as LaunchAgents (`app.deploycenter.autofix`, `app.deploycenter.guard`)
  only after `deploys autofix schedule on` / `deploys guard schedule on` (or the switch in
  Settings → Deploy for the guard and Settings → Claude for Autofix). The guard only turns
  auto-deploy off; Autofix opens fix PRs and never merges.
- The GitHub Action deploys only with `deploy: true`. Its inputs reach the scripts through `env:`,
  never as `${{ … }}` inside a `run:` script (a test checks this). It has no
  `pull_request_target` trigger. The examples set `permissions: contents: read` (or none) and
  pass keys as secrets. Pin the action to a release tag or a commit SHA, not `@main`.
- The MCP server is read-only unless you start it with `DEPLOYS_MCP_ALLOW_DEPLOY=1`. Build logs it
  returns are masked first (the same masker as Autofix; a help, not a guarantee), and they are text from somewhere else: an agent with deploy rights could
  be talked into a deploy by a log line. Keep deploy rights off unless you watch the agent.

## Provenance of the CLI download

`install.sh` checks the tarball against `checksums.txt` (SHA-256) before it writes anything. Both
come from the same GitHub release, so this catches a broken or swapped download, but not a release
that was replaced as a whole (for example from a stolen GitHub login). There is no signing key and
no build attestation for the CLI yet, so `install.sh` has nothing more to check against. Planned,
not built: releases with a GitHub artifact attestation (`gh attestation verify <tarball> --repo
Pschmetzer/deploy-center`) or a minisign signature whose public key is built into `install.sh`;
the script has a `TODO(provenance)` at the place where that check goes. Until then, if this matters
to you: download from a tagged release, compare the SHA-256 with the release notes, read
`install.sh` before you run it (it is short), or build from a commit you checked.

The Mac app is different: it is signed with a Developer ID, notarized, and every update is checked
against an EdDSA key (see [Updates](#updates)).

## Webhooks

`notify.sh` posts to the one URL you give it. The URL (it may carry a token, as Telegram's does)
goes to `curl` on stdin, redirects are not followed, and only `https://` and `http://` are
accepted. `http://` is meant for a server on your own network; the message, and any token in the
URL, then travel unencrypted. Since only you choose the URL, a request to an internal address
(SSRF) gains nothing you could not do yourself.

## Updates

Releases are built by `release.sh`: signed with a Developer ID certificate, notarized by Apple and
stapled. The release notes give the SHA-256 of the zip.

The app updates itself with [Sparkle 2](https://sparkle-project.org) (pinned version, its
SHA-256 checked by `scripts/sparkle.sh`). The feed is https://deploycenter.app/appcast.xml
(GitHub Pages, from `site/appcast.xml`); the zip comes from the GitHub release over HTTPS.
`release.sh --publish` signs the zip with an EdDSA key that lives only in the release Mac's
keychain; the app holds the public key (`SUPublicEDKey`) and refuses a download whose signature
does not match, checked before the archive is unpacked (`SUVerifyUpdateBeforeExtraction`).
Sparkle also checks the new app's code signature against the running one. Nothing is installed
while deploys are running. A self-built (ad hoc signed) app is still checked against the EdDSA key.

## Known limits

- Project icons: the app follows icon links in the project's own page, which may point at another
  host or address. The request is a plain GET; the answer is only shown if it is an image.
- `notify.sh` and the GitHub Action write project names into messages, the job summary and
  `$GITHUB_OUTPUT`. Names come from your own Vercel and Render accounts.

## For new code (providers, plugins, MCP tools)

- A key goes in the keychain and reaches the tool on stdin, never in argv, a file outside a `0700`
  folder, a log line or `--json` output.
- Text from an API or a person goes to `jq --arg`, to `bash -c` as an argument, and to URLs only
  after `safe_arg` (in `deploys`) or `NAME_RE` (in the MCP server).
- Nothing new may start a build, rollback or cancel without an explicit click, `--yes`, or an
  opt-in like `DEPLOYS_MCP_ALLOW_DEPLOY=1`.
- Add a test with stand-ins (`gh`, `vercel`, `curl`, `security`) to `tests/script-tests.sh`; no
  test may reach the network.

## Scope

In scope: the app, the `deploys` CLI, `integrations/`, the update path, `build.sh` / `release.sh`,
and the website in `site/`.

Out of scope: Vercel, Render, GitHub and their CLIs themselves (report those to the vendor), and
problems that need an attacker who already controls your Mac account.
