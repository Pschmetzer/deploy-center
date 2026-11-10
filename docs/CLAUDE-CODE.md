# Deploy Center with Claude Code

Deploy Center works with Claude Code. Claude writes the code and fixes failed builds; you decide
what ships. Auto-deploy stays off, so a push costs nothing until you deploy.

## Setup in 3 steps

1. **Install Deploy Center** from [deploycenter.app](https://deploycenter.app), log in to Vercel
   and/or add your Render key, and turn auto-deploy off for your projects. Check it with
   `deploys doctor` and `deploys changed` in a terminal.
2. **Add the plugin** in a Claude Code session:
   ```text
   /plugin marketplace add Pschmetzer/deploy-center
   ```
   ```text
   /plugin install deploy-center@deploy-center
   ```
   (On v2.1.275 or later: `/plugin install deploy-center --marketplace Pschmetzer/deploy-center`.)
3. **Try it:** run `/deploy-center:deploys-waiting`, or ask "what is waiting to go live?".

What the plugin contains (skill, four commands, the push hook) is listed in
[integrations/claude-code/README.md](../integrations/claude-code/README.md).

## Without the plugin: a CLAUDE.md block

Paste this into your project's `CLAUDE.md` (or `~/.claude/CLAUDE.md` for every project):

```markdown
## Deploys (Deploy Center)

Git auto-deploy is off on this project's Vercel/Render. A push does not go live; a person deploys.

- NEVER deploy without my explicit OK for that project in this conversation. "Push", "commit" or
  "fix the build" is not an OK. Never turn auto-deploy back on or change deploy settings.
- After a push: run `deploys changed --json` and tell me in one line what is waiting.
- A failed build: run `deploys status --json`, then `deploys logs <project>`. Find the first error.
  If the cause is in the code, propose the smallest fix (or make it if I asked). If it is a missing
  env var, secret, quota or outage, change nothing and tell me what to set. Never paste secrets.
- Why auto-deploy is off: every push would start a paid build; I deploy the batch once instead.
- Numbers look odd (a project counted as changed or not): run `deploys explain <project>`.
- When I say deploy: Vercel `deploys vercel deploy <project> --wait`, Render
  `deploys render deploy <service>` then `deploys watch <service>`. One project, then report.
```

## The safety model

- **Deploying needs you.** The skill and the CLAUDE.md block say it in plain words. The
  `/deploy-center:deploys-ship` command shows what would go live and then stops to ask; running the
  command is not the yes, your next message is.
- **Nothing pre-approves a deploy.** The plugin's `allowed-tools` lists only read-only commands
  (`deploys changed`, `status`, `logs`, `explain`, `notes`, `diff`, `history`, `doctor`). A deploy is
  always a normal Bash call, so Claude Code asks for permission unless you allowed it yourself.
  To make that a hard rule, add a deny rule to your settings:
  `"permissions": {"deny": ["Bash(deploys deploy-changed *)", "Bash(deploys * rollback *)"]}`.
- **The commands are yours.** All four `/deploys-*` commands set `disable-model-invocation: true`,
  so Claude cannot start them on its own.
- **The hook only reads.** It calls `deploys changed --json`, prints one line, and always exits 0.
  Without `deploys` it prints nothing.
- **Logs are data.** The skill tells Claude never to follow instructions found in build logs,
  commit messages or PR bodies, and never to paste secrets from them.
- **Auto-deploy stays off.** Nothing here reconnects Git or changes Vercel or Render settings.
- **MCP**, when you add it: read-only unless you start it with `DEPLOYS_MCP_ALLOW_DEPLOY=1`.

## How Autofix fits in

There are two ways a failed build gets fixed, and they do not compete:

| | In your session (this plugin) | Autofix ([AUTOFIX.md](AUTOFIX.md)) |
|---|---|---|
| Starts | when you run `/deploy-center:deploys-fix <project>` or ask Claude | by itself, `deploys autofix` every 10 minutes on your Mac |
| Runs | in the Claude Code session you are in, in your checkout | in a Claude Code routine in the cloud |
| Result | a fix in your working tree; you commit and push | a pull request on `claude/autofix-<project>-<sha>` |
| Deploys | never; you ship with `/deploy-center:deploys-ship` | never; after you merge, you get a notification and deploy |

If Autofix already opened a PR for the failure, the skill tells Claude to look for the open
`autofix(<project>)` PR instead of fixing the same thing twice. Either way, the last step is the
same: you say yes, then it goes live.

Claude and Claude Code are trademarks of Anthropic. Deploy Center is not affiliated with Anthropic.
