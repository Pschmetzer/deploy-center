# MCP server for AI agents

An [MCP](https://modelcontextprotocol.io) server (stdio) that wraps the `deploys` CLI. A coding
agent such as Claude Code, Cursor, Codex or VS Code Copilot can then ask "what is waiting to go
live?", read release notes and build logs, and, only if you turn it on, deploy one project after
you said yes.

It is read-only by default. Nothing here turns auto-deploy back on.

## Install

There are three ways to run it. They all start the same server, `server.js`.

| | Needs Node? | For |
|---|---|---|
| [Claude Desktop extension](#claude-desktop-one-click) (`deploys.mcpb`) | No: Claude Desktop brings its own | Claude Desktop, by double-click |
| [From the Mac app](#from-the-mac-app) (`Contents/Resources/mcp/`) | Yes, 18 or newer | Claude Code, Claude Desktop, Cursor, VS Code |
| [From a checkout](#from-a-checkout) (`integrations/mcp/server.js`) | Yes, 18 or newer, and `npm ci` | Development |

The server finds `deploys` in this order: `DEPLOYS_BIN`, then `PATH`, then
`/Applications/Deploy Center.app/Contents/Resources/deploys`, then the same under
`~/Applications`.

**Why Node:** the official TypeScript SDK runs as one plain JavaScript file with no build step,
and the lockfile pins it (`@modelcontextprotocol/sdk` 1.32.2). Claude Desktop ships Node for its
extensions, and every other MCP host already starts Node servers. For the app and the extension,
esbuild bundles the server and the SDK into one file (`dist/server.js`, about 600 KB) with no
`node_modules` and no native code.

### Claude Desktop: one click

1. Build it with `integrations/mcp/desktop-extension/build.sh`; this writes `build/deploys.mcpb`.
   `./build.sh` writes it too, next to the app's zip.
2. Double-click `deploys.mcpb`, or drag it onto Claude Desktop under Settings → Extensions.
3. Click Install. In the extension's settings:
   - **Allow deploys**: off by default (read-only). On adds the deploy and rollback tools.
   - **deploys CLI**: leave it empty to use the one in Deploy Center.app.

The extension runs on Claude Desktop's own Node, so Node does not have to be installed. It is
macOS only (`compatibility.platforms: darwin`), like the app. The bundle is not signed yet
(`mcpb sign`), so Claude Desktop shows it as unverified.

### From the Mac app

The app contains the bundled server and a launcher:

```
/Applications/Deploy Center.app/Contents/Resources/mcp/deploys-mcp   launcher (bash)
/Applications/Deploy Center.app/Contents/Resources/mcp/server.js     the server, bundled
```

These are the entries for the app to write, or for you to paste.

The launcher finds Node itself: `DEPLOYS_MCP_NODE`, then `PATH`, Homebrew (`/opt/homebrew/bin`,
`/usr/local/bin`), Volta, the newest nvm and fnm installs, and last the login shell (at most 3 s).
This matters because a GUI app does not get your shell's `PATH`. Without Node 18 or newer it
writes the reason to stderr and exits 1, and the host shows that in its MCP log:

```
deploys-mcp: Node.js 18 or newer is needed and was not found.
deploys-mcp: Install it (https://nodejs.org or: brew install node) and restart the app that started this server.
deploys-mcp: Or use the Claude Desktop extension (deploys.mcpb): Claude Desktop brings its own Node.
```

It also sets `DEPLOYS_BIN` to the app's own `deploys` when you have not set one.

**Claude Code**, for every project (`--scope user`), read-only:

```bash
claude mcp add --scope user deploys -- "/Applications/Deploy Center.app/Contents/Resources/mcp/deploys-mcp"
```

With deploys allowed (see [Safety](#safety)):

```bash
claude mcp add --scope user deploys -e DEPLOYS_MCP_ALLOW_DEPLOY=1 -- "/Applications/Deploy Center.app/Contents/Resources/mcp/deploys-mcp"
```

`claude mcp get deploys` shows the entry; `claude mcp remove --scope user deploys` removes it.

**Claude Desktop** (instead of the extension): the entry under `mcpServers` in
`~/Library/Application Support/Claude/claude_desktop_config.json`. Keep the other entries and
restart Claude Desktop after a change.

```json
{
  "mcpServers": {
    "deploys": {
      "command": "/Applications/Deploy Center.app/Contents/Resources/mcp/deploys-mcp",
      "args": [],
      "env": {
        "DEPLOYS_MCP_ALLOW_DEPLOY": "0"
      }
    }
  }
}
```

`"1"` allows deploys. For an app in `~/Applications`, use that path in `command`.

**Cursor** uses the same `mcpServers` entry, in `~/.cursor/mcp.json` (all projects) or
`.cursor/mcp.json` (one project).

**VS Code**: `.vscode/mcp.json` in the workspace (or "MCP: Add Server" in the command palette):

```json
{
  "servers": {
    "deploys": {
      "type": "stdio",
      "command": "/Applications/Deploy Center.app/Contents/Resources/mcp/deploys-mcp",
      "args": []
    }
  }
}
```

### From a checkout

```bash
cd integrations/mcp
```

```bash
npm ci
```

Then use `node /path/to/deploy-center/integrations/mcp/server.js` as the command, for example:

```bash
claude mcp add deploys -- node /path/to/deploy-center/integrations/mcp/server.js
```

`integrations/mcp/deploys-mcp` works from a checkout too: it finds Node the same way and runs the
`server.js` next to it. `integrations/mcp/build.sh` writes the bundled `dist/server.js`.

## Tools

| Tool | Runs | |
|---|---|---|
| `deploys_changed` | `deploys changed --json` | Projects with commits or PRs that are not live yet. |
| `deploys_status` | `deploys status --json` | What is building, and the newest state of each project (failed ones too). |
| `deploys_explain(project)` | `deploys explain <p>` | Why a project is, or is not, counted as changed. |
| `deploys_notes(project)` | `deploys notes <p>` | Release notes (Markdown) between what is live and the branch. |
| `deploys_logs(project, lines)` | `deploys logs <p> <lines>` | The end of the newest build log. `lines` 1–2000, default 80. |
| `deploys_doctor` | `deploys doctor` | Tools and logins, as JSON. No key is printed. |
| `deploys_deploy(project, preview?)` | `deploys vercel\|render deploy-json <p> [--preview]` | Only with `DEPLOYS_MCP_ALLOW_DEPLOY=1`. Returns `id`, `url`, `state`. Preview is Vercel only. |
| `deploys_rollback(project)` | `deploys vercel\|render rollback <p>` | Only with `DEPLOYS_MCP_ALLOW_DEPLOY=1`. Production back to the deploy that was live before. |

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
  server is started with `DEPLOYS_MCP_ALLOW_DEPLOY=1` (or `true`, the extension's "Allow deploys").
  A call to them without it is refused.
- **Ask first.** Their descriptions tell the agent to ask you before each call, and they are marked
  `destructiveHint`, so most hosts ask you to approve the call too. Keep that approval prompt on
  for these two tools; do not auto-approve them.
- **One project per call.** Each call takes one name. There is no "deploy everything"
  (`deploy-changed`) tool.
- **No shell.** `deploys` is started with an argument array. Names must match
  `^[A-Za-z0-9._:-]+$`, at most 100 characters, and must not start with `-` (so a name cannot
  become an option). A rejected name never reaches `deploys`.
- **Bounded.** Each command has a timeout (`DEPLOYS_MCP_TIMEOUT`, default 90 s); then it is
  stopped together with the `vercel`, `gh` or `curl` it started. Output is trimmed to
  `DEPLOYS_MCP_MAX_OUTPUT` characters (default 20000; logs keep the end).
- **Your logins.** The server uses the same Vercel CLI login, GitHub CLI login and Render key as
  `deploys` in your terminal. It adds none and prints none. The agent can read whatever those
  commands print (commit messages, build logs).

| Env | Default | |
|---|---|---|
| `DEPLOYS_MCP_ALLOW_DEPLOY` | off | `1` (or `true`, which the extension's toggle sends) adds `deploys_deploy` and `deploys_rollback`. Anything else is read-only. |
| `DEPLOYS_BIN` | search | The `deploys` to run. Empty means search. |
| `DEPLOYS_MCP_TIMEOUT` | `90` | Seconds per command. |
| `DEPLOYS_MCP_MAX_OUTPUT` | `20000` | Characters per answer. |
| `DEPLOYS_MCP_LOGIN_PATH` | on | `0` stops the server from reading the login shell's `PATH` on macOS. That `PATH` is what lets `deploys` find `jq`, `vercel` and `gh` when a GUI app started the server. |
| `DEPLOYS_MCP_NODE` | search | Launcher only: the `node` to use. |

These names, the paths `integrations/mcp/server.js` and `Contents/Resources/mcp/deploys-mcp`,
and the tool names are stable.

## Tests

```bash
integrations/tests/run.sh
```

The MCP part runs when `node` is installed and `npm ci` was run here; otherwise it says `skip mcp`.
It lists the tools, calls the read tools, checks that the write tools are missing without the flag,
rejects bad names, and deploys through a stand-in `deploys`. It also covers the launcher (with no
Node, or too old a Node), runs the bundle on its own in the app's folder layout, and packs and
validates the `.mcpb`.

Not tested yet: a real deploy through each host (Claude Code, Claude Desktop, Cursor, VS Code),
installing the `.mcpb` in Claude Desktop, and the launcher inside a signed, notarized app.
