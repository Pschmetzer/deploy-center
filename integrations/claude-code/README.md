# Claude Code plugin

Deploy Center works with Claude Code. This plugin teaches Claude how the `deploys` CLI fits into
your work: after a push it says what is waiting to go live, it reads failed build logs and fixes
them, and it deploys only after you say yes. Nothing here turns auto-deploy back on.

Claude writes the code and fixes failed builds. You decide what ships.

## Install

You need Claude Code and the `deploys` CLI (it comes with [Deploy Center](https://deploycenter.app)).
In a Claude Code session:

```text
/plugin marketplace add Pschmetzer/deploy-center
```

```text
/plugin install deploy-center@deploy-center
```

On Claude Code v2.1.275 or later, one line does both:

```text
/plugin install deploy-center --marketplace Pschmetzer/deploy-center
```

From your shell: `claude plugin install deploy-center --marketplace Pschmetzer/deploy-center`
(v2.1.292 or later). `/plugin` > **Installed** lists it; `claude plugin details deploy-center`
shows what it loaded. More in [docs/CLAUDE-CODE.md](../../docs/CLAUDE-CODE.md).

## What it adds

| Part | Name in Claude Code | What it does |
|---|---|---|
| Skill | `deploy-center` | Claude loads it on its own when you push, deploy, or a build failed. The rules: never deploy without your OK; after a push run `deploys changed --json` and say what is waiting; on a failed build read `deploys logs <p>`, find the first error, fix it; explain why auto-deploy is off; use `deploys explain` when numbers look odd. |
| Command | `/deploy-center:deploys-waiting` | What is waiting to go live (`deploys changed --json`). Read-only. |
| Command | `/deploy-center:deploys-status` | What is building, live or failed (`deploys status --json`). Read-only. |
| Command | `/deploy-center:deploys-fix <project>` | Reads the build log and fixes the cause in the current repository. Never deploys. |
| Command | `/deploy-center:deploys-ship <project>` | Shows what would go live, asks "Deploy … now? (yes/no)", and deploys only on yes. |
| Command | `/deploy-center:deploys-notes <project>` | The release notes of what waits, and one or two sentences on what changes for users. |
| Command | `/deploy-center:deploys-rollback <project>` | Shows the last deploys, asks "Roll back … ? (yes/no)", and rolls back only on yes. |
| Subagent | `ship-reviewer` | Read-only: plan, notes and risk per project, then ship now / check first / wait. Never deploys. |
| Hook | PostToolUse on `git push` | One line after Claude pushes, for example `3 commits waiting on app-web: deploy when ready (deploys changed)`. |
| MCP | optional, not loaded | See [MCP server](#mcp-server). |

Plugin commands carry the plugin name, so type `/deploys` and pick from the menu. They are
written as skills (`skills/<name>/SKILL.md`), the format the docs recommend for new commands,
with `disable-model-invocation: true`: only you start them.

## The hook

[`scripts/after-push.sh`](scripts/after-push.sh) runs after each command of Claude's Bash tool and
ends at once unless the command was a `git push` (also `cd dir && git push` and `git -C dir push`;
not `git stash push`, `--dry-run` or a rejected push). An `if: Bash(git push *)` rule would miss
some of those, so the script filters. It finds the pushed remote's repo (`owner/name` on GitHub,
`gitlab.com/group/name` on GitLab), calls
`deploys changed --json`, and prints one line for the projects that deploy that branch of that
repository (a push to a feature branch says nothing):
to you as a notice (`systemMessage`), and to Claude as context, with "do not deploy unless the
user says so".

- **Read-only.** It calls `deploys changed --json` and nothing else.
- **Fast.** It gives up after 15 seconds (`DEPLOYS_HOOK_TIMEOUT`) and says nothing.
- **Silent** when `deploys` or `jq` is missing, the remote is not a git URL it knows, nothing is waiting,
  or the CLI does not answer. It always exits 0, so it never gets in the way of a push.
- **Optional.** Turn it off with the plugin option `push_reminder` (`/plugin` > Installed >
  deploy-center > Configure options) or `DEPLOYS_PUSH_REMINDER=off`.
- **At session start too, if you want.** The plugin option `session_hint` (off by default, since it
  asks GitHub at every start) prints the same line when a session opens in a repository with
  waiting commits. `DEPLOYS_SESSION_HINT=off` turns it off for one shell.
- It finds `deploys` in `DEPLOYS`, then on `PATH`, then in `/Applications/Deploy Center.app` and
  `~/Applications/Deploy Center.app`.

## MCP server

The MCP server in `integrations/mcp/` (read-only tools `deploys_changed`, `deploys_status`,
`deploys_plan`, `deploys_explain`, `deploys_notes`, `deploys_logs`, `deploys_doctor`, the prompt
`ship-check`, and the estimates
`deploys_simulate` and `deploys_ledger`; deploy and rollback only with `DEPLOYS_MCP_ALLOW_DEPLOY=1`) is not started by the
plugin: a plugin may only point at files inside its own folder, and the server is not in it.
The Mac app ships it ready to run (with its packages) in its bundle, so no clone and no `npm ci`
are needed. Add it yourself once:

```bash
claude mcp add deploys -- node "/Applications/Deploy Center.app/Contents/Resources/mcp/server.mjs"
```

(`~/Applications/…` when the app is there), or put [`mcp/deploys.mcp.json`](mcp/deploys.mcp.json)
into a project's `.mcp.json`. Without the app, use a clone: `node /path/to/deploy-center/integrations/mcp/server.mjs`
after `npm ci` there. The skill and commands work without it: they call the CLI.

## Files

```text
.claude-plugin/marketplace.json        (repo root) the marketplace: deploy-center
integrations/claude-code/
├── .claude-plugin/plugin.json         the manifest (name, version, push_reminder and session_hint)
├── .claude-plugin/icon.png
├── skills/deploy-center/SKILL.md      the skill Claude loads by itself
├── skills/deploys-*/SKILL.md          the six commands
├── agents/ship-reviewer.md            the read-only review subagent
├── hooks/hooks.json                   PostToolUse, matcher Bash (the script finds the git push); SessionStart
├── scripts/after-push.sh              the hook (--session-start for the session hint)
└── mcp/deploys.mcp.json               optional MCP config (the app's bundled server), not loaded by the plugin
```

## Tests

`integrations/tests/run.sh` runs [`integrations/tests/claude-code.sh`](../tests/claude-code.sh),
which checks both JSON files, `hooks.json` and every `SKILL.md` against the documented format
(and runs `claude plugin validate --strict` when `claude` is installed). It also runs shellcheck on the
hook, and runs the hook against a stand-in `deploys`, including without any `deploys` at all, where it
must print nothing.

To try local changes: `claude --plugin-dir integrations/claude-code`.

## Docs this follows

- Plugins, components and layout: https://code.claude.com/docs/en/plugins/components
- `plugin.json`: https://code.claude.com/docs/en/plugins-reference (manifest reference)
- Marketplaces: https://code.claude.com/docs/en/plugin-marketplaces and https://code.claude.com/docs/en/plugins/marketplace-reference
- Installing: https://code.claude.com/docs/en/plugins/install
- Skills and slash commands (`SKILL.md`, `$ARGUMENTS`, `disable-model-invocation`): https://code.claude.com/docs/en/skills
- Hooks (PostToolUse, `systemMessage`, `additionalContext`): https://code.claude.com/docs/en/hooks
- Permission rule syntax used in `allowed-tools`: https://code.claude.com/docs/en/permissions
- MCP servers in Claude Code: https://code.claude.com/docs/en/mcp

Claude and Claude Code are trademarks of Anthropic. Deploy Center is not affiliated with Anthropic.
