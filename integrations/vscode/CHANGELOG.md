# Changelog

## 0.2.0

- Every platform `deploys` knows (Netlify, Cloudflare, AWS Amplify, DigitalOcean, Coolify, deploy hooks), not only Vercel and Render.
- Building and failed come from the CLI's shared `phase` when it has one; a canceled build is no longer shown as failed.
- A project name on two platforms is passed as `platform:name`, so logs, notes and "Open site" reach the right one.
- With `deployCenter.scope` set to `repo` and no match, the tree says so and links to the setting.

## 0.1.0

- First version: waiting count in the status bar, the "Deploy Center" tree in the Explorer,
  deploy with confirmation, build log, "Copy for AI", release notes, open site.
