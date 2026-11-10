# Claude in Deploy Center

Deploy Center can ask Claude three questions about your deploys, with **your own Anthropic API key**.
It is opt-in and off by default.

| Question | Where | What is sent |
|---|---|---|
| **Explain this failure** | detail sheet and build log, when the last build failed: *Ask Claude* | the part of the build log around the first error, masked |
| **Release notes for humans** (EN/DE) | detail sheet, when commits are waiting: *Ask Claude* | the titles of the waiting commits and PRs (no authors, no ids) |
| **Is this safe to ship?** | detail sheet, when commits are waiting: *Ask Claude* | the diff stats, the risky file names (migrations, env files, lockfiles, build config, workflows), the commit titles, whether auto-deploy is on |

*Explain this failure* also offers **Fix with Claude**, the same button as on the row: the failed
build goes to your [Autofix](AUTOFIX.md) routine (`deploys autofix --only <platform> <project>`),
under the usual caps. Without Autofix set up, it offers the setup instead.

## Turning it on

Settings → **Claude in the app** → *Ask Claude with my own API key*. Paste a key from
[console.anthropic.com](https://console.anthropic.com/settings/keys), **Save**, then **Verify**
(it looks up the model with the key; that costs nothing). The *Ask Claude* menu shows up only when
the switch is on and a key is saved.

- **Model:** Claude Opus 5.5 by default; Claude Sonnet 5.5 and Claude Haiku 5.5 are cheaper.
- **Monthly cap:** 300,000 tokens by default. It is checked before every request; once reached,
  nothing is sent until the next month or until you raise it. The tally is kept on this Mac
  (`~/.config/deploys/ai-usage.json`), so the Anthropic Console stays the source of truth for billing.

## Privacy

- No server of ours and no telemetry: the app (through `deploys`) talks straight to `api.anthropic.com`.
- The key lives in the macOS keychain (item `deploy-center-anthropic`), written by `deploys ai set-key`
  over stdin. It is never printed and never passed as a command argument. `ANTHROPIC_API_KEY` in the
  environment is used instead when it is set.
- Everything sent goes through the same masker as Autofix first: API keys and tokens (`sk-…`,
  `ghp_…`, `github_pat_…`, `xox…`, `AKIA…`, `rnd_…`, JWTs), `token=` / `password:` style values,
  passwords in URLs, and email addresses. A help, not a guarantee: read [SECURITY.md](../SECURITY.md).
- The prompts tell Claude to treat logs and commit titles as data, never as instructions.

## Command line

The app runs these; you can too.

```bash
pbpaste | deploys ai set-key          # store the key (or set ANTHROPIC_API_KEY)
deploys ai verify                     # the key works and the model is available
deploys ai explain my-project         # why the newest build failed, and the likely fix
deploys ai notes my-project --lang de # plain release notes, English (default) or German
deploys ai ship my-project            # Risk: low, medium or high, and what to check
deploys ai model claude-sonnet-5-5    # claude-opus-5-5 (default), claude-sonnet-5-5, claude-haiku-5-5
deploys ai cap 500000                 # tokens per month
deploys ai status                     # key set (never the key), model, cap, used this month
deploys ai forget-key
```

Add `--json` to `explain`, `notes` and `ship` for `{text, model, tokens, used, cap}`.

The request is the Messages API (`anthropic-version: 2026-10-21`) at low effort. On Opus and Sonnet
the server-side fallback is on (`fallbacks: "default"`): if a safety classifier declines, the API
answers with a fallback model in the same call. A refusal that remains is reported as such.

## "What this ships" on every pull request

[examples/claude-pr-ship-check.yml](../examples/claude-pr-ship-check.yml) is a GitHub workflow for
your app's repo. On each pull request it:

1. runs `deploys changed --json` through [the Deploy Center action](../integrations/action/)
   (report only, it never deploys),
2. lists every project that deploys from this repo with its auto-deploy setting
   (`deploys vercel json` / `render json`) and what already waits on it,
3. runs Anthropic's [Claude Code GitHub Action](https://github.com/anthropics/claude-code-action)
   (`anthropics/claude-code-action` v1, pinned to a commit) with that list in the prompt; Claude reads the PR diff and
   posts one comment, *What this ships*: the projects affected, a risk level, and whether
   auto-deploy is off (then nothing ships on merge until someone deploys).

Claude may only run `gh pr diff`, `gh pr view` and `gh pr comment`. It needs the
secrets `ANTHROPIC_API_KEY` and `VERCEL_TOKEN` and/or `RENDER_API_KEY`, and the workflow
permissions `contents: read`, `pull-requests: write`, `id-token: write`. Pull requests from forks
get no secrets and are skipped; do not switch it to `pull_request_target`.

## Other ways to use Claude with Deploy Center

- **Copy for Claude** in the build log: a ready prompt with the masked log, for any Claude chat.
- [Autofix](AUTOFIX.md): a failed build goes to a Claude Code routine that opens a fix PR.
- Settings → Claude connects Claude Desktop and Claude Code (the [MCP server](../integrations/mcp/)
  and the [Claude Code plugin](../integrations/claude-code/)).
