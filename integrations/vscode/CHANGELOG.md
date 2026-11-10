# Changelog

## Unreleased

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
