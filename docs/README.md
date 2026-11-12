# Docs

| Page | For |
|---|---|
| [SAFE-START.md](SAFE-START.md) | Trying it safely: look first, then one project, then all |
| [SAFE-DEPLOY.md](SAFE-DEPLOY.md) | Deploys that are safe to batch: green CI, health check with rollback, deploy windows, risk light |
| [AUTO-DEPLOY.md](AUTO-DEPLOY.md) | What turning auto-deploy off changes, and how to turn it back on |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | The app's error messages and what to do about them |
| [CLI.md](CLI.md) | Every `deploys` command, CI variables and settings |
| [FAQ.md](FAQ.md) | Short answers |
| [GLOSSARY.md](GLOSSARY.md) | Ignored Build Step, preview, Blueprint and other words |
| [NUMBERS.md](NUMBERS.md) | How commits and PRs waiting are counted |
| [SAVINGS.md](SAVINGS.md) | `deploys simulate` and `deploys ledger`: what auto-deploy costs, what turning it off saved (estimates) |
| [TEAM.md](TEAM.md) | Team mode: a shared `deploy-center.json`, observers, the two-person rule |
| [GUARD.md](GUARD.md) | The guard that turns auto-deploy off again, and allowing it for a few hours |
| [CLAUDE.md](CLAUDE.md) | Claude in the app with your own key: explain a failure, plain release notes, ship check; the PR workflow |
| [AUTOFIX.md](AUTOFIX.md) | A failed build handed to a Claude Code routine, the fix deployed after you merge |
| [CLAUDE-CODE.md](CLAUDE-CODE.md) | Using Deploy Center with Claude Code: the plugin, a CLAUDE.md block, the safety model |
| [UNINSTALL.md](UNINSTALL.md) | Removing the app, the key and everything it kept |
| [GITLAB.md](GITLAB.md) | GitLab as a source next to GitHub: `glab` or `GITLAB_TOKEN`, your own GitLab |
| `providers/*.md` | The opt-in hosts: [Netlify](providers/netlify.md), [Cloudflare Pages](providers/cloudflare.md), [AWS Amplify](providers/amplify.md), [DigitalOcean](providers/digitalocean.md), [Coolify](providers/coolify.md), [deploy hook](providers/hook.md) |
| [WIDGETS-IOS.md](WIDGETS-IOS.md) | The Mac widgets and the iPhone app: how they get their data, building them |
| [APP-STORE.md](APP-STORE.md) | Releasing the iPhone app (maintainer) |
| [PROVIDERS.md](PROVIDERS.md) | Adding a platform: one file in `providers/`, the contract, the tests |
| [providers/](providers/) | The opt-in hosts: [Netlify](providers/netlify.md), [Cloudflare Pages](providers/cloudflare.md), [AWS Amplify](providers/amplify.md), [DigitalOcean](providers/digitalocean.md), [Coolify](providers/coolify.md), [deploy hooks](providers/hook.md) |
| [GITLAB.md](GITLAB.md) | GitLab (gitlab.com or self-managed) as a source next to GitHub |
| [WIDGETS-IOS.md](WIDGETS-IOS.md) | The Mac widget, the iPhone and iPad app and its widgets: how they are built |
| [../README-CLI.md](../README-CLI.md) | The CLI on its own: install on Linux, WSL and in CI, keys, Docker |
| [GOOD-FIRST-ISSUES.md](GOOD-FIRST-ISSUES.md) | Small tasks for a first pull request |
| [../README-CLI.md](../README-CLI.md) | The CLI on its own (the README in the release tarball) |
| [../examples/](../examples/) | Deploying without a Mac (CI) |

## The app's Settings

The pages write a setting as *Settings → tab → section*. The Mac app's Settings window has nine tabs:

| Tab (Deutsch) | What is on it |
|---|---|
| General (Allgemein) | reload interval, menu bar and Dock, open at login, demo mode, projects in Spotlight, tip of the day, compact list, colour-blind friendly colours, site logos, language; notifications (daily reminder, summary of the day, sounds, spoken result, week in review, quiet hours, a second reminder for a failure); updates; the global shortcut for the command palette (⌥⌘K) |
| Platforms (Plattformen) | which platforms are on; **Health**: what `deploys doctor` says per platform, with what to do |
| Projects (Projekte) | hidden projects; marks |
| Deploy | builds at the same time, the wait before a deploy starts, asking before a single deploy, the warning for commits that wait long, only when the checks are green, watching the site after going live, a tick before migrations, Touch ID before risky steps; the deploy window editor; the rule editor; the auto-deploy guard ([SAFE-DEPLOY.md](SAFE-DEPLOY.md), [GUARD.md](GUARD.md)) |
| Costs (Kosten) | a monthly build budget; the savings estimate ([SAVINGS.md](SAVINGS.md)) |
| Claude | Claude Desktop and Claude Code; Claude in the app ([CLAUDE.md](CLAUDE.md)); Autofix ([AUTOFIX.md](AUTOFIX.md)) |
| iPhone | the iPhone link: iCloud Keychain or a QR code ([WIDGETS-IOS.md](WIDGETS-IOS.md)) |
| Team | the shared `deploy-center.json` ([TEAM.md](TEAM.md)) |
| Help (Hilfe) | open the error log, copy diagnostics, show the first-start guide again; the keyboard shortcuts |

A link in the app that leads to a setting (for example the Autofix notice) opens the right tab, and so does `deploycenter://settings/<tab>` (for example `deploycenter://settings/claude`).

## Language

- English: everything for users. The [README](../README.md), the website (`site/`), this folder's pages listed above, [CHANGELOG.md](../CHANGELOG.md), `examples/`, and code comments.
- German: [README.de.md](../README.de.md), a translation of the README (a change to the README goes into it too), the legal pages on the website (`site/impressum.html`, `site/datenschutz.html`), [ZAHLEN.md](ZAHLEN.md) (the German original of [NUMBERS.md](NUMBERS.md)), [ERSPARNIS.md](ERSPARNIS.md) (the German version of [SAVINGS.md](SAVINGS.md)), and the working notes `IDEEN*.md`.
- The app itself speaks English and German. It follows the language the Mac prefers until you pick one in Settings (since 0.9.1).

A change to [NUMBERS.md](NUMBERS.md) goes into [ZAHLEN.md](ZAHLEN.md) too, and a change to [SAVINGS.md](SAVINGS.md) into [ERSPARNIS.md](ERSPARNIS.md).
