# Docs

| Page | For |
|---|---|
| [FIRST-START.md](FIRST-START.md) | The first-start tour, step by step |
| [DEPLOY-FROM-APP.md](DEPLOY-FROM-APP.md) | What you see before and while you deploy from the app |
| [JOURNAL.md](JOURNAL.md) | The deploy journal: verify, CSV export, monthly report |
| [SEARCH.md](SEARCH.md) | Search operators, saved searches, repo groups, merged fixes |
| [SETTINGS.md](SETTINGS.md) | The Settings options, with an example each |
| [SAFE-START.md](SAFE-START.md) | Trying it safely: look first, then one project, then all |
| [MIGRATING.md](MIGRATING.md) | Moving from auto-deploy to one deploy a day: find what builds, agree a rule, turn it off, add the safety nets |
| [SECURITY-MODEL.md](SECURITY-MODEL.md) | What the app reads, stores and sends, in plain language (the full model: SECURITY.md) |
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
| [PERF.md](PERF.md) | The performance guard: how full the Mac is, heavy checks that wait for room, orphaned processes, Docker stop and wake |
| [EXTRAS.md](EXTRAS.md) | The extra commands in `lib/x-*.sh` (`deploys more`): one file per command, how to add one |
| [LOCAL-SESSIONS.md](LOCAL-SESSIONS.md) | The local session counter: Claude Code sessions on this Mac, tasks started together that belong in fewer sessions, twins and idle ones |
| [PRS.md](PRS.md) | Pull request upkeep: open pull requests kept free of merge conflicts and merged once checks pass (`deploys prs`) |
| [REPOS.md](REPOS.md) | Repo upkeep: local checkouts kept on top of origin/main, merged branches back to main, the ones with changes reported |
| [CLAUDE-IN-APP.md](CLAUDE-IN-APP.md) | Claude in the app with your own key: explain a failure, plain release notes, ship check; the PR workflow |
| [SCAN.md](SCAN.md) | Bug scan: Claude Code looks through a repo and opens one fix PR; the security check with OSV-Scanner, gitleaks and Semgrep |
| [AUTOFIX.md](AUTOFIX.md) | A failed build handed to a Claude Code routine, the fix deployed after you merge |
| [DAILY.md](DAILY.md) | Daily tasks: your own prompts sent to a Claude Code routine for chosen repos at set times |
| [CLAUDE-CODE.md](CLAUDE-CODE.md) | Using Deploy Center with Claude Code: the plugin, a CLAUDE.md block, the safety model |
| [UNINSTALL.md](UNINSTALL.md) | Removing the app, the key and everything it kept |
| [GITLAB.md](GITLAB.md) | GitLab as a source next to GitHub: `glab` or `GITLAB_TOKEN`, your own GitLab |
| [providers/vercel.md](providers/vercel.md), [providers/render.md](providers/render.md) | The two default hosts: setup, turning auto-deploy off, deploying, undo |
| [providers/README.md](providers/README.md) | Which host can do what: a table, then one page per host |
| `providers/*.md` | The opt-in hosts: [Netlify](providers/netlify.md), [Cloudflare Pages](providers/cloudflare.md), [AWS Amplify](providers/amplify.md), [DigitalOcean](providers/digitalocean.md), [Coolify](providers/coolify.md), [deploy hook](providers/hook.md) |
| [WIDGETS-IOS.md](WIDGETS-IOS.md) | The Mac widgets and the iPhone app: how they get their data, building them |
| [APP-STORE.md](APP-STORE.md) | Releasing the iPhone app (maintainer) |
| [PROVIDERS.md](PROVIDERS.md) | Adding a platform: one file in `providers/`, the contract, the tests |
| [GITHOSTS.md](GITHOSTS.md) | Adding a git host (Bitbucket, Gitea, …): the repo slug, the functions, the tests |
| [../README-CLI.md](../README-CLI.md) | The CLI on its own: install on Linux, WSL and in CI, keys, Docker |
| [GOOD-FIRST-ISSUES.md](GOOD-FIRST-ISSUES.md) | Small tasks for a first pull request |
| [../examples/](../examples/) | Deploying without a Mac (CI) |

## The app's Settings

The pages write a setting as *Settings → tab → section*. The Mac app's Settings window has ten tabs:

| Tab (Deutsch) | What is on it |
|---|---|
| General (Allgemein) | reload interval, menu bar and Dock, open at login, demo mode, projects in Spotlight, tip of the day, compact list, colorblind-friendly colors, site logos, language; notifications (daily reminder, summary of the day, sounds, spoken result, week in review, quiet hours, a second reminder for a failure); updates; the global shortcut for the command palette (⌥⌘K) |
| Platforms (Plattformen) | which platforms are on; **Health**: what `deploys doctor` says per platform, with what to do |
| Projects (Projekte) | hidden projects; marks |
| Deploy | builds at the same time, the wait before a deploy starts, asking before a single deploy, the warning for commits that wait long, a red CI shown on the row (the CLI has `--when-green`), watching the site after going live, a tick before migrations, Touch ID before risky steps; the deploy window editor; the rule editor; the auto-deploy guard ([SAFE-DEPLOY.md](SAFE-DEPLOY.md), [GUARD.md](GUARD.md)) |
| Costs (Kosten) | a monthly build budget; the savings estimate ([SAVINGS.md](SAVINGS.md)) |
| Claude | Claude Desktop and Claude Code; Claude in the app ([CLAUDE-IN-APP.md](CLAUDE-IN-APP.md)); Autofix ([AUTOFIX.md](AUTOFIX.md)) |
| Daily tasks (Daily-Aufgaben) | your prompt blocks sent to a Claude Code routine for chosen repos at set times: tasks, blocks, the routine and its token, "Send now" ([DAILY.md](DAILY.md)) |
| iPhone | the iPhone link: iCloud Keychain or a QR code ([WIDGETS-IOS.md](WIDGETS-IOS.md)) |
| Team | the shared `deploy-center.json` ([TEAM.md](TEAM.md)) |
| Help (Hilfe) | open the error log, copy diagnostics, show the first-start guide again; the keyboard shortcuts |

A link in the app that leads to a setting (for example the Autofix notice) opens the right tab, and so does `deploycenter://settings/<tab>` (for example `deploycenter://settings/claude`).

## Language

- English: everything for users. The [README](../README.md), the website (`site/`), this folder's pages listed above, [CHANGELOG.md](../CHANGELOG.md), `examples/`, and code comments.
- German: [README.de.md](../README.de.md), a translation of the README (a change to the README goes into it too), the legal pages on the website (`site/impressum.html`, `site/datenschutz.html`), [ZAHLEN.md](ZAHLEN.md) (the German original of [NUMBERS.md](NUMBERS.md)), [ERSPARNIS.md](ERSPARNIS.md) (the German version of [SAVINGS.md](SAVINGS.md)), [FAQ.de.md](FAQ.de.md), [SAFE-START.de.md](SAFE-START.de.md), [FIRST-START.de.md](FIRST-START.de.md), [GLOSSARY.de.md](GLOSSARY.de.md) (the German entries of [GLOSSARY.md](GLOSSARY.md) that are new), [GOOD-FIRST-ISSUES.de.md](GOOD-FIRST-ISSUES.de.md), [SETTINGS.de.md](SETTINGS.de.md), [SEARCH.de.md](SEARCH.de.md), [AUTO-DEPLOY.de.md](AUTO-DEPLOY.de.md), [GUARD.de.md](GUARD.de.md), [PERF.de.md](PERF.de.md), [LOCAL-SESSIONS.de.md](LOCAL-SESSIONS.de.md), [PRS.de.md](PRS.de.md), [EXTRAS.de.md](EXTRAS.de.md), [REPOS.de.md](REPOS.de.md), [JOURNAL.de.md](JOURNAL.de.md), [DEPLOY-FROM-APP.de.md](DEPLOY-FROM-APP.de.md) and [AUTOFIX.de.md](AUTOFIX.de.md), [CLAUDE-CODE.de.md](CLAUDE-CODE.de.md), [CLAUDE-IN-APP.de.md](CLAUDE-IN-APP.de.md), [GITHOSTS.de.md](GITHOSTS.de.md), [GITLAB.de.md](GITLAB.de.md), [PROVIDERS.de.md](PROVIDERS.de.md), [SAFE-DEPLOY.de.md](SAFE-DEPLOY.de.md), [SCAN.de.md](SCAN.de.md), [TEAM.de.md](TEAM.de.md), [UNINSTALL.de.md](UNINSTALL.de.md), [WIDGETS-IOS.de.md](WIDGETS-IOS.de.md), [TROUBLESHOOTING.de.md](TROUBLESHOOTING.de.md), [MIGRATING.de.md](MIGRATING.de.md), [SECURITY-MODEL.de.md](SECURITY-MODEL.de.md) and [CLI.de.md](CLI.de.md) (the German versions of [FAQ.md](FAQ.md), [SAFE-START.md](SAFE-START.md) and [TROUBLESHOOTING.md](TROUBLESHOOTING.md), and a short German overview of [CLI.md](CLI.md)), and the working notes `IDEEN*.md`.
- The app itself speaks English and German. It follows the language the Mac prefers until you pick one in Settings (since 0.9.1).

A change to [NUMBERS.md](NUMBERS.md) goes into [ZAHLEN.md](ZAHLEN.md) too, and a change to [SAVINGS.md](SAVINGS.md) into [ERSPARNIS.md](ERSPARNIS.md).
