# deploys: the Deploy Center CLI

`deploys` turns off auto-deploy on Vercel and Render (and, opt-in, on Netlify, Cloudflare Pages,
AWS Amplify, DigitalOcean App Platform, Coolify and any deploy hook), then deploys by hand: what
changed, when you say so. It is the same script the Mac app runs, and it works on its own on macOS, Linux,
WSL and in CI. MIT licensed. Website: [deploycenter.app](https://deploycenter.app/).

## Install

**Script** (macOS, Linux, WSL): downloads the latest release, checks its SHA-256 against the
release's `checksums.txt`, and installs into `~/.local/bin`. No sudo.

```bash
curl -fsSL https://deploycenter.app/install.sh | sh
```

Options go after `sh -s --`:

```bash
curl -fsSL https://deploycenter.app/install.sh | sh -s -- --prefix /usr/local     # /usr/local/bin; asks for sudo only if needed, and says so
curl -fsSL https://deploycenter.app/install.sh | sh -s -- --version <x.y.z>       # a given release
curl -fsSL https://deploycenter.app/install.sh | sh -s -- --uninstall             # remove it again (config stays)
```

To read the script first: `curl -fsSLO https://deploycenter.app/install.sh`, then `sh install.sh --help`.
In CI, fetch a copy that is pinned to one release and installs that release by default: `curl -fsSL https://deploycenter.app/install/<x.y.z>.sh | sh` (a release's copy is the script as of its tag; `--version latest` still asks for the newest). Add `--sha256 <hash>` to pin the tarball too.
It installs the files into `<prefix>/lib/deploys/` and a small launcher into `<prefix>/bin/deploys`,
then lists what is missing (`jq`, `gh`, `vercel`, …) with the install command for your system.

**Homebrew** (macOS and Linux):

```bash
brew install pschmetzer/tap/deploys
```

Homebrew 6 asks you to trust a third-party tap once: `brew trust pschmetzer/tap`. The Mac app
(`brew install --cask deploy-center`) has its own copy of the CLI inside; you do not need both.

**Docker** (CI, or nothing installed locally): the image has bash, jq, curl, git, gh and a pinned
Vercel CLI. Build it from a checkout:

```bash
docker build -f integrations/docker/Dockerfile -t deploys .
docker run --rm -e VERCEL_TOKEN -e RENDER_API_KEY -e GH_TOKEN -v "$PWD/deploys-config:/config" deploys changed --json
```

See [integrations/docker](integrations/docker/README.md). For GitHub Actions there is also
[an action](integrations/action/README.md).

**By hand:** download `deploys-cli-<version>.tar.gz` and `checksums.txt` from
[Releases](https://github.com/Pschmetzer/deploy-center/releases), run `sha256sum -c checksums.txt --ignore-missing` (macOS: `shasum -a 256 -c checksums.txt --ignore-missing`),
unpack, and put the folder anywhere; run `deploys` from inside it (it reads `VERSION` and
`providers/` next to itself).

## Requirements

| Tool | Needed for |
| --- | --- |
| `bash` (3.2 or newer), `curl` | everything |
| `jq` (1.6 or newer) | everything |
| Vercel CLI (`npm i -g vercel`) | Vercel projects |
| GitHub CLI `gh` | optional: what is waiting to deploy (commits, PRs) on GitHub |
| GitLab CLI `glab`, or `GITLAB_TOKEN` | optional: the same for repos on GitLab ([docs/GITLAB.md](docs/GITLAB.md)) |
| `aws` CLI | only for AWS Amplify |
| `openssl` | only for `deploys certs` (TLS certificate dates) |
| `git` | only for `deploys hooks install` |
| `perl` | `autofix` and `ai` (masking keys in logs), `check`, and the time limit on `gh`/`vercel` calls; on every Mac, and in most Linux images |
| `security` (macOS) | the keychain; on Linux and in CI the keys come from environment variables instead (below) |
| `column` | optional: without it the tables are padded by awk (`bsdextrautils` on Debian/Ubuntu) |

## Where each command is described

`deploys --help` lists all of them. The full reference is [docs/CLI.md](docs/CLI.md) ([online](https://deploycenter.app/docs/cli/)); the manual page is installed with the script and with Homebrew (`man deploys`).

| Commands | Page |
| --- | --- |
| `list`, `changed`, `deploy`, `deploy-changed`, `watch`, `logs`, `rollback`, `cancel`, `open`, `diff`, `notes`, `history`, `explain` | [docs/CLI.md](docs/CLI.md) |
| `plan`, `ci`, `window`, `verify`, `readonly`, `rules`, `risk`, `simulate`, `idle`, `status` | [docs/SAFE-DEPLOY.md](docs/SAFE-DEPLOY.md) |
| `guard`, `autodeploy allow\|allowed\|revoke` | [docs/GUARD.md](docs/GUARD.md) |
| `autofix`, `ai` | [docs/AUTOFIX.md](docs/AUTOFIX.md), [docs/CLAUDE-IN-APP.md](docs/CLAUDE-IN-APP.md) |
| `scan`, `check` | [docs/SCAN.md](docs/SCAN.md) |
| `costs`, `ledger`, `price`, `budget` | [docs/SAVINGS.md](docs/SAVINGS.md), [docs/CLI.md](docs/CLI.md) |
| `journal`, `triggers`, `certs`, `metrics`, `creds`, `schedule`, `watch` | [docs/CLI.md](docs/CLI.md), [docs/JOURNAL.md](docs/JOURNAL.md) |
| `team`, `config` | [docs/TEAM.md](docs/TEAM.md) |
| `providers`, `netlify`, `cloudflare`, `amplify`, `coolify`, `hook` | [docs/PROVIDERS.md](docs/PROVIDERS.md), [docs/providers/](docs/providers/README.md) |
| `gitlab` | [docs/GITLAB.md](docs/GITLAB.md) |
| `hooks install` (a Git hook in one repo) and the `hooks.d` folder (scripts around a deploy) | [docs/CLI.md](docs/CLI.md) |

## First steps

```bash
deploys doctor                      # tools and access, as JSON
vercel login                        # or VERCEL_TOKEN, see below
deploys vercel list                 # your projects, and whether a push still deploys them
deploys vercel autodeploy-off --all # pushes stop building (the repo is remembered first)
deploys changed                     # what has commits on GitHub that are not live
deploys deploy-changed              # shows the list; add --yes to deploy it
```

Render: `export RENDER_API_KEY=…` (on a Mac, `deploys render set-key` stores it in the keychain
instead), then `deploys render list`. `deploys --help` lists every command. Tab completion:
`eval "$(deploys completion bash)"` in `~/.bashrc` (or `zsh` in `~/.zshrc`; fish: `deploys completion fish | source`).

## In CI

No login, no keychain: keys come from the environment and are never printed.

| Variable | What |
| --- | --- |
| `VERCEL_TOKEN` | Vercel access token (vercel.com/account/tokens), read by the Vercel CLI |
| `RENDER_API_KEY` | Render API key (dashboard: Account settings, API keys) |
| `GH_TOKEN` | optional, for `gh`: the GitHub API without the low anonymous rate limit |
| `GITLAB_TOKEN`, `GITLAB_HOST` | optional: GitLab repos; `GITLAB_HOST` for self-managed GitLab (default gitlab.com) |
| `NETLIFY_AUTH_TOKEN` | Netlify, once enabled with `deploys providers enable netlify` |
| `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | Cloudflare Pages (the account id only when the token sees more than one) |
| `AWS_PROFILE` or `DEPLOYS_AMPLIFY_PROFILE`, `AWS_REGION` | AWS Amplify, through the `aws` CLI |
| `DIGITALOCEAN_TOKEN` | DigitalOcean App Platform |
| `COOLIFY_TOKEN`, `COOLIFY_URL` | Coolify, and the URL of your instance |
| `<NAME>_CMD` | a command that prints a key when the variable is not set, e.g. `RENDER_API_KEY_CMD='op read op://vault/render/key'` (1Password, pass, Vault; no keychain needed) |
| `DEPLOYS_NOTIFY_CMD` | your own notification command (ntfy, Slack through `curl`); the text is in `DEPLOYS_MESSAGE` and on stdin |
| `DEPLOYS_SCAN_FOREGROUND` | `1`: `scan` and `check` finish before the command returns, so a CI job does not end first |
| `DEPLOYS_VERCEL_TEAM` | the Vercel team id, if the token sees several teams |
| `DEPLOYS_CLI_TIMEOUT` | seconds a `gh`, `glab` or `vercel` call may take (default 90; `0` no limit) |
| `DEPLOYS_NO_GITHUB` | `1`: ask no git host (nothing counts as changed then) |
| `DEPLOYS_CONFIG` | config folder (default `~/.config/deploys`); keep `vercel-repos.json` there between runs |

The opt-in hosts are off until `deploys providers enable <name>`; see [docs/PROVIDERS.md](docs/PROVIDERS.md).

In CI, pin the release you tested with `--version`: runs stay reproducible, and a new release
(good or bad) reaches your pipeline only when you raise the number.

Vercel needs two things in CI that a Mac has already: the Vercel CLI, and `vercel-repos.json`
(where each disconnected project deploys from). Without the CLI, Vercel is not set up and is left
out; without the file, no Vercel project is deployable. Keep the config folder between runs:

```yaml
- run: curl -fsSL https://deploycenter.app/install.sh | sh -s -- --version <x.y.z>   # pin a release, see the Releases page
- run: echo "$HOME/.local/bin" >> "$GITHUB_PATH"
- run: npm i -g vercel
- uses: actions/cache@v4
  with:
    path: deploys-config
    key: deploys-config-${{ github.run_id }}
    restore-keys: deploys-config-
- run: deploys deploy-changed --yes
  env:
    DEPLOYS_CONFIG: ${{ github.workspace }}/deploys-config
    VERCEL_TOKEN: ${{ secrets.VERCEL_TOKEN }}
    RENDER_API_KEY: ${{ secrets.RENDER_API_KEY }}
    GH_TOKEN: ${{ github.token }}
```

Team mode: when a shared `deploy-center.json` lists observers, `deploys` must know who runs it,
and refuses to deploy otherwise. The Actions `github.token` cannot read `/user`: use a token
that can (a fine-grained personal access token) as `GH_TOKEN` there.

The first time, create `deploys-config/vercel-repos.json` with `deploys vercel map <project>
<owner/repo> <branch>` (or copy it from `~/.config/deploys` on your Mac).

## Update and uninstall

Run the install command again for the newest release, or `brew upgrade deploys`. To remove:
`… | sh -s -- --uninstall` (same `--prefix` as the install), or `brew uninstall deploys`. Your
config in `~/.config/deploys` stays; delete it by hand if you want it gone.
