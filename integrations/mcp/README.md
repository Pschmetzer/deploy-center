# MCP server for AI agents

An [MCP](https://modelcontextprotocol.io) server (stdio) that wraps the `deploys` CLI. A coding
agent such as Claude Code, Cursor, Codex or VS Code Copilot can then ask "what is waiting to go
live?", read release notes and build logs, and, only if you turn it on, deploy one project after
you said yes.

It is read-only by default. Nothing here turns auto-deploy back on.

## Install

Needs Node 20 or newer and the `deploys` CLI (it comes with Deploy Center).

```bash
cd integrations/mcp
```

```bash
npm ci
```

The server finds `deploys` in this order: `DEPLOYS_BIN`, then
`/Applications/Deploy Center.app/Contents/Resources/deploys`, then the same under
`~/Applications`, then `PATH`. The VS Code and Raycast add-ons and the Claude Code hook use the
same order, so an older `deploys` on `PATH` never wins over the app's. Replace `/path/to/deploy-center` below with where you cloned this repo.

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
| `deploys_status(project?)` | `deploys status --json` | What is building, and the newest state of each project (failed ones too). With `project`: only that one, via `--no-github` (no GitHub calls), to follow a deploy. |
| `deploys_list` | `deploys list --json` | Every project with its platform, repo, branch and auto-deploy flag. No GitHub calls. |
| `deploys_risk(project)` | `deploys risk <p> --json` | Green, yellow or red for what waits: migrations, lockfiles, config, size. |
| `deploys_diff(project)` | `deploys diff <p>` | Commits and files between what is live and the branch. |
| `deploys_history(project, count?)` | `deploys history <p> <n>` | The last deploys (default 10): when, state, commit, source. Read it before a rollback. |
| `deploys_explain(project)` | `deploys explain <p>` | Why a project is, or is not, counted as changed. |
| `deploys_notes(project)` | `deploys notes <p>` | Release notes (Markdown) between what is live and the branch. |
| `deploys_logs(project, lines)` | `deploys logs <p> <lines>` | The end of the newest build log. `lines` 1–2000, default 80. |
| `deploys_doctor` | `deploys doctor` | Tools and logins, as JSON. No key is printed. |
| `deploys_simulate(days?)` | `deploys simulate --days <n> --json` | Estimate: what auto-deploy would cost per month (builds, minutes, USD) vs. deploying once a day. `days` 1–90, default 30. |
| `deploys_ledger` | `deploys ledger --json` | Estimate: builds skipped and minutes and USD saved since auto-deploy was turned off. |
| `deploys_deploy(project, preview?, force?)` | `deploys vercel\|render deploy-json <p> [--preview]` | Only with `DEPLOYS_MCP_ALLOW_DEPLOY=1`. Returns `id`, `url`, `state`. Preview is Vercel only. A production deploy of a project with nothing waiting needs `force: true`. |
| `deploys_rollback(project)` | `deploys vercel\|render rollback <p>` | Only with `DEPLOYS_MCP_ALLOW_DEPLOY=1`. Production back to the deploy that was live before. |

`deploys_simulate` and `deploys_ledger` answer "what does auto-deploy cost us?" and "what did
turning it off save?". Their numbers are estimates from pushes on GitHub and each project's average
build; the `method` field in the result says how they were counted and priced, and the tool
descriptions tell the agent to quote them as estimates. They read GitHub and the build history of
every project, so they can take a minute or two, and have their own timeout
(`DEPLOYS_MCP_SLOW_TIMEOUT`, default 300 s).

Tools that answer JSON (changed, status, list, risk, doctor, simulate, ledger, deploy, rollback)
also return it as `structuredContent` (an array under `result`), so a client need not parse text.

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
> **Agent** calls `deploys_deploy(project: "app-web")`. Your client shows the server's own
> question, "Deploy app-web on Vercel now: production, 4 commits waiting?", and you tick yes.
>
> Started: `dpl_…`, https://app-web-….vercel.app (QUEUED). I can check `deploys_status(project: "app-web")` in a minute.

Without `DEPLOYS_MCP_ALLOW_DEPLOY=1` the last step is not possible: the agent has no deploy tool
and tells you to deploy in Deploy Center or with `deploys vercel deploy app-web`.

## Safety

- **Read-only by default.** `deploys_deploy` and `deploys_rollback` are not even listed unless the
  server is started with `DEPLOYS_MCP_ALLOW_DEPLOY=1` (exactly `1`). A call to them without it is
  refused.
- **The server asks you itself.** Before a deploy or rollback starts, the server sends an MCP
  elicitation (a question with one "Yes, do it" box) to your client, naming the project, the
  platform and how many commits wait. Decline, cancel or no tick, and nothing starts. This holds
  even when the agent's tool calls are auto-approved or a build log tries to talk the agent into
  a deploy. A client without elicitation support gets a refusal by default. If your client asks
  you before every tool call anyway, `DEPLOYS_MCP_CONFIRM=client` lets it decide instead.
- **Ask first, too.** The tool descriptions tell the agent to ask you before each call, and they
  are marked `destructiveHint`, so most hosts ask you to approve the call as well. Keep that
  approval prompt on for these two tools; do not auto-approve them. In Claude Code, put them in
  `ask` (or `deny`) in `.claude/settings.json`:

  ```json
  { "permissions": { "ask": ["mcp__deploys__deploys_deploy", "mcp__deploys__deploys_rollback"] } }
  ```
- **One at a time, a few per run.** A second deploy or rollback while one is starting is refused.
  After `DEPLOYS_MCP_MAX_DEPLOYS` (default 3) per server run, further ones are refused; restart the
  server or deploy the rest in Deploy Center.
- **Nothing waiting, no deploy.** A production deploy checks `deploys changed --json` first; when
  the project has nothing waiting, the agent must pass `force: true` (a rebuild the human asked for).
- **One project per call.** Each call takes one name. There is no "deploy everything"
  (`deploy-changed`) tool.
- **No shell.** `deploys` is started with an argument array. Names must match
  `^[A-Za-z0-9._:-]+$`, at most 100 characters, and must not start with `-` (so a name cannot
  become an option). A rejected name never reaches `deploys`.
- **Bounded.** Each command has a timeout (`DEPLOYS_MCP_TIMEOUT`, default 90 s; simulate and
  ledger `DEPLOYS_MCP_SLOW_TIMEOUT`, default 300 s; a deploy or rollback start
  `DEPLOYS_MCP_WRITE_TIMEOUT`, default 300 s); then it is
  stopped together with the `vercel`, `gh` or `curl` it started. A deploy stopped this way may
  have started anyway, so the error tells the agent to check `deploys_status` and not to call it
  again. Output is trimmed to `DEPLOYS_MCP_MAX_OUTPUT` characters (default 20000; logs keep the end).
- **Masked text.** Logs, notes and explain output pass through the same masker as `deploys`
  autofix (known token prefixes, `NAME=secret`, `user:password@` in URLs) before the agent sees
  them. A help, not a guarantee: a token with no known shape still goes through.
- **Your logins.** The server uses the same Vercel CLI login, GitHub CLI login and Render key as
  `deploys` in your terminal. It adds none and prints none. The host's own model keys
  (`ANTHROPIC_*`, `OPENAI_*` and the like) are not passed on to `deploys`; provider keys are. The agent can read whatever those
  commands print (commit messages, build logs).

| Env | Default | |
|---|---|---|
| `DEPLOYS_MCP_ALLOW_DEPLOY` | off | `1` adds `deploys_deploy` and `deploys_rollback`. `preview` adds only `deploys_deploy`, for preview deploys. |
| `DEPLOYS_MCP_PROJECTS` | all | Comma-separated names: the only projects a deploy or rollback may touch. |
| `DEPLOYS_MCP_CONFIRM` | `ask` | `ask`: the server asks you (elicitation) and refuses clients that cannot ask. `client`: rely on the client's own approval. |
| `DEPLOYS_MCP_MAX_DEPLOYS` | `3` | Deploys and rollbacks per server run. |
| `DEPLOYS_MCP_WRITE_TIMEOUT` | `300` | Seconds for a deploy or rollback to start. |
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
rejects bad names, and deploys through a stand-in `deploys`: the server's question and the
answers yes, no, cancel and no tick, a client without elicitation, the limit per run, two calls at
once, a timed-out start, and masked logs.

Not tested yet: a real deploy through each host (Claude Code, Claude Desktop, Cursor, VS Code).
