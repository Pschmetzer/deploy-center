# Integrations

Small add-ons that call the `deploys` CLI. Each one only reads, except the GitHub Action when a
workflow sets `deploy: true` and the MCP server when it is started with `DEPLOYS_MCP_ALLOW_DEPLOY=1`. Auto-deploy stays off: nothing here deploys unless a person asks for it.

| Folder | What it does |
|---|---|
| [action/](action/) | A GitHub Action that lists what has changes (`deploys changed --json`), and deploys only with `deploy: true`. It includes an example workflow for a `[deploy]` commit marker. |
| [hooks/](hooks/) | A git `pre-push` hook. It warns how many builds a push would start on projects that still deploy on push. |
| [badge/](badge/) | An SVG badge per project, for example `deployed · 3 d ago · 4 commits waiting`. No server needed. |
| [statuspage/](statuspage/) | A static "what shipped when" page (`index.html`, an Atom feed, `status.json`) for the projects you list, with an optional site check. Any static host. |
| [notify/](notify/) | A daily summary ("live today / waiting") sent to one webhook: Discord, Slack-compatible, ntfy or Telegram. |
| [mcp/](mcp/) | An MCP server for AI coding agents (Claude Code, Claude Desktop, Cursor, VS Code). Read-only tools for what is waiting, building, release notes and logs; deploy and rollback of one project only with `DEPLOYS_MCP_ALLOW_DEPLOY=1`. |
| [docker/](docker/) | A Linux image with `deploys` and its tools, for CI. |
| [VERIFY.md](VERIFY.md) | How to check a release: SHA-256, `codesign`, `spctl`. |

Tests: `integrations/tests/run.sh`. They use a stand-in `deploys` and `curl`, so they need no
network and no accounts. The MCP tests also need `node` and `npm ci` in `mcp/`, and are skipped
without them.

## Reading every project

The badge, notify, the status page and the hook need every project, including the ones that are up to
date. That is `deploys list --json`: every provider that is on and set up (see [lib/projects.sh](lib/projects.sh)).
Render is read only when a key is there, in `RENDER_API_KEY` or the Mac keychain. With a Render
key that is wrong or expired, `deploys render list --json` currently does not come back. Set a
working key, or remove the wrong one.
