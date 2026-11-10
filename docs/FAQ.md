# FAQ

### What does it cost?
Nothing. Deploy Center is free and open source (MIT). You pay Vercel and Render for the builds you start, and fewer of them.
`deploys simulate` estimates what auto-deploy would cost you a month, `deploys ledger` what turning it off saved: [SAVINGS.md](SAVINGS.md).

### Does it deploy anything by itself?
No. It deploys when you press **Deploy** or run a `deploys` command. The daily reminder in Settings is only a notification, and only when something waits. If you want a scheduled deploy, set it up yourself: [`scripts/daily-deploy.plist.example`](../scripts/daily-deploy.plist.example) on a Mac, or [examples/](../examples/) for CI.

### What happens when I turn auto-deploy off?
See [AUTO-DEPLOY.md](AUTO-DEPLOY.md). In short: Vercel loses the Git connection (the repo is remembered), Render's auto-deploy is set to *Off*, and a push builds nothing.

### Can I go back?
Yes, in the Vercel and Render dashboards. There is no command for it. See [AUTO-DEPLOY.md](AUTO-DEPLOY.md#back-to-auto-deploy).

### Where is my Render key stored?
In your macOS keychain, as the item `deploy-center-render`. `deploys` hands it to `curl` on stdin, so it does not show in the process list, and sends it only to api.render.com. The key gives full access to your Render account.

### Does the app send data anywhere?
No telemetry, no account, no server of ours. It talks to Vercel and Render with your logins, to GitHub through your `gh` login, to your own sites for their logos and the check after a deploy, and once a day to GitHub's release page to see whether a new version is out (Settings → **Look for a new version once a day** turns that off).

### Do I need the GitHub CLI?
For deploying, no. For seeing what is waiting (**New changes**, commits and PRs waiting, **Select all changed**, `deploys changed` and `deploy-changed`), yes: those read GitHub through `gh`.

### GitLab or Bitbucket?
Not yet. Deploys start from GitHub (`gitSource` type `github`). GitLab is on the wish list in the README.

### Windows or Linux?
The app needs macOS 15 or newer. The `deploys` script is bash and runs on Linux too; in CI the key comes from `RENDER_API_KEY` instead of the keychain. See [examples/](../examples/).

### I disconnected a Vercel project before I used Deploy Center. It says "repo unknown".
Tell it where the project deploys from: `deploys vercel map my-project me/my-repo main`.

### My login has several Vercel teams.
`deploys vercel team <id>` picks one. The error message lists the ids.

### A monorepo builds every project on every deploy.
Use Vercel's Ignored Build Step, see [GLOSSARY.md](GLOSSARY.md#ignored-build-step).

### A build ran although auto-deploy is off.
Run `deploys triggers`. It lists builds of the last 24 hours that nobody started from here, GitHub workflows that deploy, and Render Blueprints with auto-sync.

### How are "commits waiting" and "PRs waiting" counted?
See [NUMBERS.md](NUMBERS.md).

### Something does not work.
See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
