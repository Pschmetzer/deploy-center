# Changelog

## Unreleased

- German: every text, command and setting follows the editor's language (English and Deutsch). "Copy for AI" stays English, it is written for the AI.
- **Deploy Preview** (Vercel) and **Roll Back Production** (Vercel, Render), each after a confirmation, in the project menu and the tree.
- A folder's remote matches a project only on the same host: `gitlab.com:me/app` is not GitHub's `me/app`.
- After a deploy starts, the extension follows it (every 15 s, at most 15 min) and says when it is live or failed, with "Copy for AI" and "Show log".
- Runs on your own machine in remote windows (SSH, WSL, Dev Containers), where `deploys` and its logins are.
- A deploy start that times out says it may have started anyway, so you check before deploying again.
- A second click on Deploy while the dialog or the start of that project is open does not open a second one.
- "Copy for AI" masks the same key shapes as the CLI: GitLab, Stripe, Google, npm, AWS session keys, private keys.
- A timeout ends the CLI and everything it started (its process group), not only the shell.
- The build log masks what the app and the MCP server mask: GitLab, Stripe, Google, npm and Anthropic keys, private key blocks (also when cut off), `--token x` and email addresses.
- "Show log" opens a read-only document; the output channel keeps its earlier warnings and deploy results.
- A change of a setting while a refresh runs is no longer lost: one more refresh follows.
- GitLab repos match with host and subgroups (`gitlab.com/group/sub/app`), so the same owner/name on GitHub and GitLab are two repos.

## 0.2.0

- Every platform `deploys` knows (Netlify, Cloudflare, AWS Amplify, DigitalOcean, Coolify, deploy hooks), not only Vercel and Render.
- Building and failed come from the CLI's shared `phase` when it has one; a canceled build is no longer shown as failed.
- A project name on two platforms is passed as `platform:name`, so logs, notes and "Open site" reach the right one.
- With `deployCenter.scope` set to `repo` and no match, the tree says so and links to the setting.

## 0.1.0

- First version: waiting count in the status bar, the "Deploy Center" tree in the Explorer,
  deploy with confirmation, build log, "Copy for AI", release notes, open site.
