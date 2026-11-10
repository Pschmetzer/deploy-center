# Integrations

Small add-ons that call the `deploys` CLI. Each one only reads, except the GitHub Action when a
workflow sets `deploy: true` (also the digest's approve workflow, after a person approved), the MCP server when it is started with `DEPLOYS_MCP_ALLOW_DEPLOY=1`, and the Raycast extension after you confirm a deploy. Auto-deploy
stays off: nothing here deploys unless a person asks for it.

| Folder | What it does |
|---|---|
| [action/](action/) | A GitHub Action that lists what has changes (`deploys changed --json`), and deploys only with `deploy: true`. It includes an example workflow for a `[deploy]` commit marker. |
| [hooks/](hooks/) | A git `pre-push` hook. It warns how many builds a push would start on projects that still deploy on push. |
| [badge/](badge/) | An SVG badge per project, for example `deployed · 3 d ago · 4 commits waiting`. No server needed. |
| [statuspage/](statuspage/) | A static "what shipped when" page (`index.html`, an Atom feed, `status.json`) for the projects you list, with an optional site check. Any static host. |
| [notify/](notify/) | A daily summary ("live today / waiting") sent to one webhook: Discord, Slack-compatible, ntfy or Telegram. |
| [claude-code/](claude-code/) | A Claude Code plugin: a skill, `/deploys-*` commands, and a read-only reminder after `git push`. It deploys only after you say yes. Install: `/plugin marketplace add Pschmetzer/deploy-center`, then `/plugin install deploy-center@deploy-center`. See [docs/CLAUDE-CODE.md](../docs/CLAUDE-CODE.md). |
| [mcp/](mcp/) | An MCP server for AI coding agents (Claude Code, Claude Desktop, Cursor, VS Code). Read-only tools for what is waiting, building, release notes and logs; deploy and rollback of one project only with `DEPLOYS_MCP_ALLOW_DEPLOY=1`. |
| [raycast/](raycast/) | A Raycast extension: Waiting Deploys, Deploy Status and Deploy All Changed. It deploys only after a confirmation. Not on the Raycast Store yet ([PUBLISHING.md](raycast/PUBLISHING.md)). |
| [vscode/](vscode/) | A VS Code extension, also for Cursor and Windsurf (Open VSX): `⏳ 3 waiting` in the status bar for this folder's repo, a project tree, deploy with confirmation, the build log and "Copy for AI". Deploys only after a click and a confirmation. |
| [digest/](digest/) | A daily digest of what waits, agent and human commits apart, as Markdown, an issue and a webhook message. A person approves with a button or the `deploy-approved` label; an example workflow then deploys only the approved projects. |
| [docker/](docker/) | A Linux image with `deploys` and its tools, for CI. |
| [VERIFY.md](VERIFY.md) | How to check a release: SHA-256, `codesign`, `spctl`. |

Tests: `integrations/tests/run.sh`. They use a stand-in `deploys`, `curl` and `gh`, so they need no
network and no accounts. The MCP tests also need `node` and `npm ci` in `mcp/`, the Action and
approve-workflow tests need `ruby`, and the VS Code tests `npm ci` in `vscode/`; each part says
`skip …` when its tool is missing.

## What is tested, and what is not

| Add-on | Tested here (stand-ins, no network) | Not tested by the project |
|---|---|---|
| MCP server | every tool, the server's own confirmation (yes, no, cancel, no tick, no elicitation), limits, timeouts, masking | a real deploy through each host (Claude Code, Claude Desktop, Cursor, VS Code) |
| Action | the steps' scripts (changed, only/exclude, dry-run, deploy, wait for builds, risk gate, setup checks) | a run on GitHub's runners against real accounts |
| Digest and approve workflow | the scripts, the issue and message texts, the approval checks | a run on GitHub and a real post |
| Notify, badge, status page | the texts, payloads, files and failure cases | a real post, a published page |
| Claude Code plugin | the hook (which commands count), the files with `claude plugin validate` when installed | a session against real accounts |
| pre-push hook | which pushes start builds, the timeouts | — |
| VS Code extension | the CLI runner, the model, the masker, scoping; the controller against a stand-in `vscode` (confirmation, double start, deploy a repo, failures, Copy for AI) | inside a real editor (no `@vscode/test-electron` run) |
| Raycast extension | type check | the commands in Raycast |
| Docker image | builds and runs `doctor` (by hand) | a run against real accounts |

## Reading every project

The badge, notify, the status page and the hook need every project, including the ones that are up to
date. That is `deploys list --json`: every provider that is on and set up (see [lib/projects.sh](lib/projects.sh)).
Render is read only when a key is there, in `RENDER_API_KEY` or the Mac keychain. With a Render
key that is wrong or expired, `deploys render list --json` currently does not come back. Set a
working key, or remove the wrong one.
