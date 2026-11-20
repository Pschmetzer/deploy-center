# FAQ

## What does it cost?
Nothing. Deploy Center is free and open source (MIT). You pay your hosts (Vercel, Render, and the opt-in ones: Netlify, Cloudflare Pages, AWS Amplify, DigitalOcean, Coolify) for the builds you start, and fewer of them.
`deploys simulate` estimates what auto-deploy would cost you a month, `deploys ledger` what turning it off saved: [SAVINGS.md](SAVINGS.md).

## Does it deploy anything by itself?
No. It deploys when you press **Deploy** or run a `deploys` command. The daily reminder in Settings is only a notification, and only when something waits. If you want a scheduled deploy, set it up yourself: [`scripts/daily-deploy.plist.example`](../scripts/daily-deploy.plist.example) on a Mac, or [examples/](../examples/) for CI.

## What happens when I turn auto-deploy off?
See [AUTO-DEPLOY.md](AUTO-DEPLOY.md). In short: Vercel loses the Git connection (the repo is remembered), Render's auto-deploy is set to *Off*, and a push builds nothing.

## Can I go back?
Yes: `deploys vercel autodeploy-on <project>` connects Git again from the remembered repo, `deploys render autodeploy-on <service>` sets auto-deploy to *On Commit* (both take `--all`; add `--dry-run` to see first what would change). The dashboards work too. See [AUTO-DEPLOY.md](AUTO-DEPLOY.md#back-to-auto-deploy).

## Where is my Render key stored?
In your macOS keychain, as the item `deploy-center-render`. `deploys` hands it to `curl` on stdin, so it does not show in the process list, and sends it only to api.render.com. The key gives full access to your Render account.

## Does the app send data anywhere?
No telemetry, no account, no server of ours. It talks to Vercel and Render with your logins, to GitHub through your `gh` login, to your own sites for their logos and the check after a deploy, to the public status pages of Vercel, Render and GitHub (a plain GET, nothing of yours), and once a day to `deploycenter.app/appcast.xml` to see whether a new version is out; the update itself comes from GitHub (Settings → **Check for updates automatically** turns the daily check off). Claude in the app and Autofix talk to Anthropic only when you set them up with your own key or routine. More: [SECURITY.md](../SECURITY.md#what-is-sent-where).

## Do I need the GitHub CLI?
For deploying, no. For seeing what is waiting (**New changes**, commits and PRs waiting, **Select all changed**, `deploys changed` and `deploy-changed`), yes: those read GitHub through `gh`.

## GitLab or Bitbucket?
GitLab, yes: for a project whose repo is on gitlab.com or your own GitLab, what is waiting (commits, merged and open merge requests) is read from GitLab through `glab` or `GITLAB_TOKEN`. See [GITLAB.md](GITLAB.md). Bitbucket and other hosts, not yet: those projects show "branch head unknown".

## How do I switch the app to English or German?
Settings → General → **Language**: English, Deutsch, or the Mac's language (the default). It takes effect after a restart (**Restart now** is right there); the widgets follow it. Messages from the `deploys` CLI stay English.

## How do I update?
The app checks once a day (Settings → General → **Check for updates automatically**) and on **Check for Updates …** in the app menu. Sparkle shows what is new and installs once no deploy is running. With Homebrew: `brew upgrade --cask --greedy deploy-center`.

## Windows or Linux?
The app needs macOS 15 or newer. The `deploys` script is bash and runs on Linux and in WSL (install it inside the Linux distribution): `curl -fsSL https://deploycenter.app/install.sh | sh`. In CI the key comes from `RENDER_API_KEY` instead of the keychain. See [examples/](../examples/).

## I disconnected a Vercel project before I used Deploy Center. It says "repo unknown".
Tell it where the project deploys from: `deploys vercel map my-project me/my-repo main`.

## My login has several Vercel teams.
`deploys vercel team <id>` picks one. The error message lists the ids.

## A monorepo builds every project on every deploy.
Use Vercel's Ignored Build Step, see [GLOSSARY.md](GLOSSARY.md#ignored-build-step).

## A build ran although auto-deploy is off.
Run `deploys triggers`. It lists builds of the last 24 hours that nobody started from here, GitHub workflows that deploy, and Render Blueprints with auto-sync.

## How are "commits waiting" and "PRs waiting" counted?
See [NUMBERS.md](NUMBERS.md).

## Where can I see what was deployed, and export it?
The deploy journal on your Mac lists every deploy. `deploys journal export` writes it as CSV and `deploys journal report` as a monthly Markdown report. See [JOURNAL.md](JOURNAL.md).

## How do I find the failed Render services quickly?
Type `is:failed host:render` in the search field and save it with the bookmark button. See [SEARCH.md](SEARCH.md).

## Something does not work.
See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Does it do preview deploys?
Where the host has them: `deploys deploy <project> --preview` (Vercel, Cloudflare Pages, AWS Amplify; see [the host table](providers/README.md)). Render, Netlify, DigitalOcean and Coolify have no preview deploy here.

## Can I roll back?
Yes, on every host except a plain deploy hook: the Rollback button in the app, or `deploys <host> rollback <project>`. `deploys verify` rolls back by itself when the site answers 5xx after a deploy, unless you pass `--no-rollback`. See [SAFE-DEPLOY.md](SAFE-DEPLOY.md).

## Is there an iPhone app?
It is built for the App Store: what waits, deploy and rollback with Face ID, and widgets. It shows Vercel and Render projects only (the other hosts are not in the iPhone app or the widgets). How it works: [WIDGETS-IOS.md](WIDGETS-IOS.md).

## Can my team use it?
Yes, without a server: a shared `deploy-center.json` per repo, observer mode and an optional two-person rule. See [TEAM.md](TEAM.md).

## Do I need an Anthropic key?
Only for Claude in the app (explain a failure, release notes, ship check). Autofix uses a Claude Code routine instead. See [CLAUDE-IN-APP.md](CLAUDE-IN-APP.md).

## Where are the step-by-step guides?
On the website: [all guides](https://deploycenter.app/guides/) (build minutes, deploy queue, automatic rollback, monorepo ignore rules, deploy freeze, status page, daily deploy, risk checks, one per host), [comparisons](https://deploycenter.app/compare/) and the [blog](https://deploycenter.app/blog/). A German set is at [deploycenter.app/de/anleitungen/](https://deploycenter.app/de/anleitungen/).
