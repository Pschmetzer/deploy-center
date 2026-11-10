# Changelog

## Unreleased

- After a deploy starts, the extension follows it (every 15 s, at most 15 min) and says when it is live or failed, with "Copy for AI" and "Show log".
- Runs on your own machine in remote windows (SSH, WSL, Dev Containers), where `deploys` and its logins are.
- Build logs open in their own output channel ("Deploy Center: Build log"), so CLI warnings stay.
- A deploy start that times out says it may have started anyway, so you check before deploying again.
- A timeout stops `deploys` together with the `vercel`, `gh` or `curl` it started.
- A second click on Deploy while the dialog or the start of that project is open does not open a second one.
- "Copy for AI" masks the same key shapes as the CLI: GitLab, Stripe, Google, npm, AWS session keys, private keys.

## 0.2.0

- Every platform `deploys` knows (Netlify, Cloudflare, AWS Amplify, DigitalOcean, Coolify, deploy hooks), not only Vercel and Render.
- Building and failed come from the CLI's shared `phase` when it has one; a canceled build is no longer shown as failed.
- A project name on two platforms is passed as `platform:name`, so logs, notes and "Open site" reach the right one.
- With `deployCenter.scope` set to `repo` and no match, the tree says so and links to the setting.

## 0.1.0

- First version: waiting count in the status bar, the "Deploy Center" tree in the Explorer,
  deploy with confirmation, build log, "Copy for AI", release notes, open site.
