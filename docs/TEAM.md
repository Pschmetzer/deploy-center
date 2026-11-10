# Team mode

The same deploy rules on every teammate's Mac, with no server. Deploy Center still has no backend:
the shared settings are a file in your repo, approvals are GitHub reviews or labels, and each Mac
reads both with its own `gh` login.

Three parts:

1. **Shared config**: `deploy-center.json` at the root of a repo.
2. **Observer mode**: a Mac (or a CI job) that can look but never deploy.
3. **Two-person rule**: optional, per project. A production deploy needs someone else's approval.

> Team mode keeps a team consistent. It does not enforce anything. Anyone with a Vercel or Render
> login can still deploy from the dashboard. To enforce rules, use the platforms' roles and
> GitHub branch protection. Deploy Center makes the agreed way the easy way, and writes down
> every exception.

## 1. Shared config: `deploy-center.json`

Put it at the root of the repo, on the default branch. `.deploy-center.json` works too.
The schema is [`deploy-center.schema.json`](deploy-center.schema.json); point `$schema` at it and
your editor checks the file as you type.

```json
{
  "$schema": "https://raw.githubusercontent.com/Pschmetzer/deploy-center/main/docs/deploy-center.schema.json",
  "version": 1,
  "approvals": 1,
  "health": "/api/health",
  "window": { "days": ["mon", "tue", "wed", "thu"], "from": "09:00", "to": "16:00", "tz": "Europe/Berlin" },
  "projects": {
    "shop-web": { "platform": "vercel", "branch": "main", "health": "/healthz" },
    "shop-api": { "platform": "render", "approvals": 2 },
    "shop-docs": { "platform": "vercel", "approvals": 0 }
  },
  "ignored": ["shop-playground"],
  "groups": { "shop": ["shop-api", "shop-web"] },
  "observers": ["a-github-login"]
}
```

| Key | What it does |
|---|---|
| `approvals`, `health`, `window` at the top | Defaults for every project that deploys from this repo |
| `projects.<name>` | One Vercel project or Render service: `platform`, `repo` (default: this repo), `branch`, `health`, `window`, `approvals`, `ignored` |
| `ignored` | Left out of `deploys changed` and `deploy-changed` |
| `groups.<name>` | Projects deployed together, in order. `deploys deploy shop` starts `shop-web` once `shop-api` is live |
| `observers` | GitHub logins that may look but not deploy |

`health` and `window` are stored and shown here. The safe-deploy checks use them (health check
after a deploy, deploy windows). This file only says what they are.

### Which repos are read

`deploys` reads the file in each project's repo:

- every repo in `~/.config/deploys/vercel-repos.json` (remembered when auto-deploy was turned off),
- the repo of a Render service, when it is deployed,
- every repo you add: `deploys team add owner/repo`. A new teammate starts here. The file maps
  the team's projects to their repos, so they can deploy without disconnecting anything first.

Each file is read with `gh api repos/<repo>/contents/deploy-center.json` and kept for ten minutes
in `~/.config/deploys/team-cache/`. If GitHub cannot be reached, the saved copy is used and
marked as stale. Read again now with `deploys team refresh` or `deploys config --refresh`.

### Merge order

Lowest first. A later layer wins:

1. what the platform says (a Render service's repo and branch)
2. the repo file's top-level defaults
3. the repo file's entry for the project (`projects.<name>`, `ignored`)
4. this Mac: `vercel-repos.json` (repo, branch), `ignored.json`, `window.json`, then
   `overrides.json` (same shape as the repo file, for this Mac only)

Two exceptions. This Mac can only **tighten** these:

- `approvals`: a local number counts only if it is higher. To get past a missing approval, use
  `--force "reason"`, which is journaled.
- `observers`: all lists are joined. A Mac can add names but not remove them.

`deploys ignore <p> --undo` on a project the team file ignores writes `"ignored": false` to
`overrides.json`, so this Mac counts it again.

### Seeing the result

```bash
deploys config
```

```bash
deploys config --json
```

Every value is shown as `{"value": …, "from": …}`. `from` is `owner/repo:deploy-center.json`,
`vercel-repos.json`, `ignored.json`, `window.json`, `overrides.json`, `platform` or `default`.
The JSON also lists the files found (`sources`, with `stale` and `error`), the groups, the
observers, who you are on GitHub (`me`) and whether this Mac is an observer (`readonly`).

## 2. Observer mode

Any one of these makes a Mac (or a CI job) an observer:

- the environment variable `DEPLOYS_READONLY=1`,
- the file `~/.config/deploys/readonly` (`deploys readonly on` / `off`; the app's switch in
  **Settings → Team** does the same),
- your GitHub login is in `observers` in a shared file.

An observer can use every command that only reads. Commands that change something on Vercel,
Render or GitHub stop before they call anything:

`deploy`, `deploy-changed --yes`, `vercel deploy|deploy-json|rollback|cancel|map|autodeploy-off`,
`render deploy|deploy-json|rollback|cancel|autodeploy-off`, and `autofix` (except `--dry-run`).

```
Error: Observer mode (DEPLOYS_READONLY is set): "deploys vercel deploy" changes something and is refused. Observers can look, not deploy. To deploy from here: unset DEPLOYS_READONLY.
```

This Mac's own settings stay allowed: `ignore`, `team add`, `readonly`, keys and logins.
Observer mode protects the platforms, not your view of them. In the app, the deploy buttons are
hidden and the footer shows **Observer**.

## 3. Two-person rule

Set `"approvals": 1` (or more) for a project or a whole repo. A production deploy of that project
then needs that many approvals of the exact commit being deployed, from people other than the
deployer. The commit checked is pinned in the deploy, so a push that lands during the check does
not go live unapproved.

Each of these counts once per person:

- **An approving PR review** on a pull request the commit belongs to. Only that person's newest
  review counts. An approval later changed to "changes requested" does not count.
- **The label `deploy-approved-by:<login>`** on that pull request, or on an open issue whose title
  or body names the commit (its first 7 characters). It counts only if `<login>` added the label
  themself; this is read from the issue's events. Anyone can create a label with someone else's
  name in it, so that alone proves nothing. Use this for commits that came without a PR.

Your own reviews and labels never count. Previews need no approval.

```bash
deploys deploy shop-web
```

```
Approvals for shop-web at 3f2a9c1 (acme/shop:deploy-center.json):
  Found none. Your own reviews and labels do not count.
  Any of these counts:
    - an approving review on PR #42 (https://github.com/acme/shop/pull/42)
    - the label deploy-approved-by:<their login> on that PR, or an open issue in acme/shop that names 3f2a9c1, added by that person
  Or, deliberately: deploys deploy shop-web --force "reason" (written to the team journal)
Error: shop-web needs 1 approval(s) from someone other than you (a-login) before 3f2a9c1 goes live.
```

The same check runs wherever production deploys start: `deploys deploy`, `deploy-changed --yes`,
`vercel deploy`, `render deploy` and the app's buttons. The app shows the end of the message;
the whole message is in its log (Settings → Help → Open the error log).

### `--force`

```bash
deploys deploy shop-web --force "hotfix for the checkout outage"
```

The reason is required. It goes into `~/.config/deploys/team-journal.jsonl` together with the
commit, who deployed and which approvals there were. Approved deploys are journaled too. See
the journal with `deploys team journal` (`--json` for the raw lines). The journal is on this
Mac. To tell the team, paste the line into the PR or your channel.

## Groups

```bash
deploys deploy shop
```

This starts the members of `groups.shop` in order. Each one waits until the one before is live
(`deploys watch`). A failure stops the rest. Every member goes through the observer and approval
checks on its own.

## Files

| File | Where | What |
|---|---|---|
| `deploy-center.json` | repo root | shared config |
| `overrides.json` | `~/.config/deploys/` | this Mac's overrides, same shape |
| `team-repos` | `~/.config/deploys/` | repos added with `deploys team add` |
| `readonly` | `~/.config/deploys/` | present: observer mode |
| `team-cache/` | `~/.config/deploys/` | the shared files, ten minutes; your GitHub login, an hour |
| `team-journal.jsonl` | `~/.config/deploys/` | approved and forced deploys |

`lib/team.sh` sits next to the `deploys` script and is bundled with the app. A copy of the
script without it still deploys, without the shared config and the two-person rule. Observer
mode by `DEPLOYS_READONLY` or the `readonly` file still holds.
