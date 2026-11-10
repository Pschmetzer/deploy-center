# Deploy Center for Raycast

See which projects have commits waiting (Vercel, Render, Netlify, Cloudflare, AWS Amplify, DigitalOcean, Coolify and deploy hooks), and deploy them by hand, from Raycast.

[Deploy Center](https://github.com/Pschmetzer/deploy-center) turns off Git auto-deploy on Vercel and
Render, so a push no longer starts a build. This extension is a front end for its `deploys` CLI:
it reads what is waiting and starts a deploy only when you confirm one.

<!-- Screenshots: add 2000×1250 PNGs to metadata/ before submitting (see PUBLISHING.md). -->
<!-- ![Waiting Deploys](metadata/deploy-center-1.png) -->
<!-- ![Deploy Status](metadata/deploy-center-2.png) -->
<!-- ![Deploy All Changed](metadata/deploy-center-3.png) -->

## Commands

| Command | What it shows | Actions |
|---|---|---|
| **Waiting Deploys** | Projects with commits or PRs not live yet, with the age of the oldest waiting commit (`deploys changed --json`). | Deploy (asks first), Open Site, Open Dashboard, Copy Release Notes, Show in Deploy Center |
| **Deploy Status** | Projects building right now, and projects whose newest deploy failed (`deploys status --json`). | Open Site, Open Dashboard, Copy Release Notes, Show in Deploy Center |
| **Deploy All Changed** | The same list as Waiting Deploys. Nothing starts until you press ↵ and confirm. | Deploy All (asks first, with every project named) |

Deploy All starts exactly the projects in the list you confirmed, one after the other, with
`deploys <vercel|render> deploy-json <name>`. Each row then shows "started" or "not started".

## Requirements

- macOS with [Deploy Center](https://github.com/Pschmetzer/deploy-center/releases) installed, or the `deploys` CLI alone.
- The logins Deploy Center uses: `vercel login`, a Render key (`deploys render set-key`), and `gh auth login` for the waiting commits.

The extension looks for `deploys` in this order:

1. the **Path to deploys** preference,
2. `/Applications/Deploy Center.app/Contents/Resources/deploys`,
3. `~/Applications/Deploy Center.app/Contents/Resources/deploys`,
4. every folder on `PATH`.

Raycast starts commands with a short `PATH`. Homebrew's folders (`/opt/homebrew/bin`,
`/usr/local/bin`) are always added, so `jq`, `gh` and `vercel` from Homebrew are found. If `vercel`
lives somewhere else (for example a global npm folder), add that folder under **Extra PATH**.

## Errors

- **Deploy Center's CLI was not found**: install the app, or set **Path to deploys**.
- **Not logged in**: the message from `deploys` says which login is missing.
- **Some projects could not be read**: shown as the first row. The list holds what could be read;
  what is missing is not counted as up to date.

## Privacy

The extension runs `deploys` on your Mac and nothing else. It sends no data anywhere itself.
