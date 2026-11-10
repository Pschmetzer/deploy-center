# MCP server for AI agents

An [MCP](https://modelcontextprotocol.io) server (stdio) that wraps the `deploys` CLI. A coding
agent such as Claude Code, Cursor, Codex or VS Code Copilot can then ask "what is waiting to go
live?", read release notes and build logs, and, only if you turn it on, deploy one project after
you said yes.

It is read-only by default. Nothing here turns auto-deploy back on.

## Install

Needs Node 18 or newer and the `deploys` CLI (it comes with Deploy Center).

```bash
cd integrations/mcp
```

```bash
npm ci
```

The server finds `deploys` in this order: `DEPLOYS_BIN`, then `PATH`, then
`/Applications/Deploy Center.app/Contents/Resources/deploys`, then the same under
`~/Applications`. Replace `/path/to/deploy-center` below with where you cloned this repo.

**Why Node:** the official TypeScript SDK runs as one plain `.mjs` file with no build step, and the
lockfile pins it (`@modelcontextprotocol/sdk` 1.32.2). Every agent host that speaks MCP already
starts Node servers, and the tests drive it over stdio from `integrations/tests/run.sh` with the
same stand-in `deploys` as the other add-ons.

### Claude Code

```bash
claude mcp add deploys -- node /path/to/deploy-center/integrations/mcp/server.mjs
```

With deploys allowed (see [Safety](#safety)):

```bash
claude mcp add deploys -e DEPLOYS_MCP_ALLOW_DEPLOY=1 -- node /path/to/deploy-center/integrations/mcp/server.mjs
```

Add `--scope user` to have it in every project. `claude mcp list` shows it.

### Claude Desktop

`~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "deploys": {
      "command": "node",
      "args": ["/path/to/deploy-center/integrations/mcp/server.mjs"],
      "env": { "DEPLOYS_MCP_ALLOW_DEPLOY": "0" }
    }
  }
}
```

An app started from the Dock does not get your shell's `PATH`. If Claude Desktop cannot start
`node`, give its full path (`which node`). The `deploys` from the app bundle is found without `PATH`;
a different one needs `DEPLOYS_BIN`.

### Cursor

`~/.cursor/mcp.json` (all projects) or `.cursor/mcp.json` (one project):

```json
{
  "mcpServers": {
    "deploys": {
      "command": "node",
      "args": ["/path/to/deploy-center/integrations/mcp/server.mjs"]
    }
  }
}
```

### VS Code

`.vscode/mcp.json` in the workspace (or "MCP: Add Server" in the command palette):

```json
{
  "servers": {
    "deploys": {
      "type": "stdio",
      "command": "node",
      "args": ["/path/to/deploy-center/integrations/mcp/server.mjs"]
    }
  }
}
```

## Tools

| Tool | Runs | |
|---|---|---|
| `deploys_changed` | `deploys changed --json` | Projects with commits or PRs that are not live yet. |
| `deploys_status` | `deploys status --json` | What is building, and the newest state of each project (failed ones too). |
| `deploys_explain(project)` | `deploys explain <p>` | Why a project is, or is not, counted as changed. |
| `deploys_notes(project)` | `deploys notes <p>` | Release notes (Markdown) between what is live and the branch. |
| `deploys_logs(project, lines)` | `deploys logs <p> <lines>` | The end of the newest build log. `lines` 1–2000, default 80. |
| `deploys_doctor` | `deploys doctor` | Tools and logins, as JSON. No key is printed. |
| `deploys_simulate(days?)` | `deploys simulate --days <n> --json` | Estimate: what auto-deploy would cost per month (builds, minutes, USD) vs. deploying once a day. `days` 1–90, default 30. |
| `deploys_ledger` | `deploys ledger --json` | Estimate: builds skipped and minutes and USD saved since auto-deploy was turned off. |
| `deploys_deploy(project, preview?)` | `deploys vercel\|render deploy-json <p> [--preview]` | Only with `DEPLOYS_MCP_ALLOW_DEPLOY=1`. Returns `id`, `url`, `state`. Preview is Vercel only. |
| `deploys_rollback(project)` | `deploys vercel\|render rollback <p>` | Only with `DEPLOYS_MCP_ALLOW_DEPLOY=1`. Production back to the deploy that was live before. |

`deploys_simulate` and `deploys_ledger` answer "what does auto-deploy cost us?" and "what did
turning it off save?". Their numbers are estimates from pushes on GitHub and each project's average
build; the `method` field in the result says how they were counted and priced, and the tool
descriptions tell the agent to quote them as estimates. They read GitHub and the build history of
every project, so they can take a minute or two, and have their own timeout
(`DEPLOYS_MCP_SLOW_TIMEOUT`, default 300 s).

To find out whether a name is on Vercel or Render, deploy and rollback use `deploys list --json`
when the CLI has it, and otherwise `deploys status --json --no-github`, which needs no GitHub calls.

## Example

> **You:** what's waiting to go live?
>
> **Agent** calls `deploys_changed`:
> Two projects have changes that are not live: **app-web** (4 commits since it was deployed 3 days
> ago) and **api** on Render. Want the release notes?
>
> **You:** notes for app-web
>
> **Agent** calls `deploys_notes(project: "app-web")` and shows the list of commits and PRs.
>
> **You:** ship app-web
>
> **Agent:** This deploys **app-web** to production on Vercel, with the 4 commits above. It starts
> one build. Go ahead?
>
> **You:** yes
>
> **Agent** calls `deploys_deploy(project: "app-web")`:
> Started: `dpl_…`, https://app-web-….vercel.app (QUEUED). I can check `deploys_status` in a minute.

Without `DEPLOYS_MCP_ALLOW_DEPLOY=1` the last step is not possible: the agent has no deploy tool
and tells you to deploy in Deploy Center or with `deploys vercel deploy app-web`.

## Safety

- **Read-only by default.** `deploys_deploy` and `deploys_rollback` are not even listed unless the
  server is started with `DEPLOYS_MCP_ALLOW_DEPLOY=1` (exactly `1`). A call to them without it is
  refused.
- **Ask first.** Their descriptions tell the agent to ask you before each call, and they are marked
  `destructiveHint`, so most hosts ask you to approve the call too. Keep that approval prompt on
  for these two tools; do not auto-approve them.
- **One project per call.** Each call takes one name. There is no "deploy everything"
  (`deploy-changed`) tool.
- **No shell.** `deploys` is started with an argument array. Names must match
  `^[A-Za-z0-9._:-]+$`, at most 100 characters, and must not start with `-` (so a name cannot
  become an option). A rejected name never reaches `deploys`.
- **Checked arguments.** Every call is checked against the tool's `inputSchema`: an argument the
  tool does not take (`deploys_deploy {project, sha}`), a wrong type (`lines: "80"`) or a value out
  of range is an error, and nothing runs.
- **Masked logs.** `deploys_logs` replaces obvious secrets (known token prefixes, `NAME=value` for
  names like `*_TOKEN`/`*PASSWORD`, `Bearer …`, `--token x`, `user:pass@` in URLs, private keys,
  emails) with `[masked]` before the agent sees the text: the same rules as `deploys autofix`. A
  help, not a guarantee: a token with no known prefix and no telling name still goes through.
- **Bounded.** Each command has a timeout (`DEPLOYS_MCP_TIMEOUT`, default 90 s; simulate and
  ledger `DEPLOYS_MCP_SLOW_TIMEOUT`, default 300 s); then it is
  stopped together with the `vercel`, `gh` or `curl` it started. Output is trimmed to
  `DEPLOYS_MCP_MAX_OUTPUT` characters (default 20000; logs keep the end, also of a log longer
  than the server collects). `deploys_changed` and `deploys_status` answer compact JSON and are
  never cut inside it: when the list does not fit, whole entries are left out and the answer is
  `{"projects": [...], "truncated": n, "total": N, "note": "..."}`.
- **Your logins.** The server uses the same Vercel CLI login, GitHub CLI login and Render key as
  `deploys` in your terminal. It adds none and prints none. The agent can read whatever those
  commands print (commit messages, build logs).

| Env | Default | |
|---|---|---|
| `DEPLOYS_MCP_ALLOW_DEPLOY` | off | `1` adds `deploys_deploy` and `deploys_rollback`. |
| `DEPLOYS_BIN` | search | The `deploys` to run. |
| `DEPLOYS_MCP_TIMEOUT` | `90` | Seconds per command. |
| `DEPLOYS_MCP_SLOW_TIMEOUT` | `300` | Seconds for `deploys_simulate` and `deploys_ledger`. |
| `DEPLOYS_MCP_MAX_OUTPUT` | `20000` | Characters per answer. |

## Tests

```bash
integrations/tests/run.sh
```

The MCP part runs when `node` is installed and `npm ci` was run here; otherwise it says `skip mcp`.
It lists the tools, calls the read tools (simulate and ledger answer from the fixture reports in
`tests/fixtures/savings/`), checks that the write tools are missing without the flag,
rejects bad names, and deploys through a stand-in `deploys`.

Not tested yet: a real deploy through each host (Claude Code, Claude Desktop, Cursor, VS Code).
