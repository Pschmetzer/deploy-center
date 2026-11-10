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
curl -fsSL https://deploycenter.app/install.sh | sh -s -- --version 0.8.0         # a given release
curl -fsSL https://deploycenter.app/install.sh | sh -s -- --uninstall             # remove it again (config stays)
```

To read the script first: `curl -fsSLO https://deploycenter.app/install.sh`, then `sh install.sh --help`.
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
| `bash`, `curl` | everything |
| `jq` | everything |
| Vercel CLI (`npm i -g vercel`) | Vercel projects |
| GitHub CLI `gh` | optional: what is waiting to deploy (commits, PRs) on GitHub |
| GitLab CLI `glab`, or `GITLAB_TOKEN` | optional: the same for repos on GitLab ([docs/GITLAB.md](docs/GITLAB.md)) |
| `aws` CLI | only for AWS Amplify |
| `column` | optional: the tables (`bsdextrautils` on Debian/Ubuntu) |

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
`eval "$(deploys completion bash)"` in `~/.bashrc` (or `zsh` in `~/.zshrc`).

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
| `DEPLOYS_CONFIG` | config folder (default `~/.config/deploys`); keep `vercel-repos.json` there between runs |

The opt-in hosts are off until `deploys providers enable <name>`; see [docs/PROVIDERS.md](docs/PROVIDERS.md).

In CI, pin the release you tested with `--version`: runs stay reproducible, and a new release
(good or bad) reaches your pipeline only when you raise the number.

```yaml
- run: curl -fsSL https://deploycenter.app/install.sh | sh -s -- --version 0.9.1
- run: echo "$HOME/.local/bin" >> "$GITHUB_PATH"
- run: deploys deploy-changed --yes
  env:
    VERCEL_TOKEN: ${{ secrets.VERCEL_TOKEN }}
    RENDER_API_KEY: ${{ secrets.RENDER_API_KEY }}
    GH_TOKEN: ${{ github.token }}
```

## Update and uninstall

Run the install command again for the newest release, or `brew upgrade deploys`. To remove:
`… | sh -s -- --uninstall` (same `--prefix` as the install), or `brew uninstall deploys`. Your
config in `~/.config/deploys` stays; delete it by hand if you want it gone.
