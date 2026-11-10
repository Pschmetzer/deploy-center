# The auto-deploy guard, and allowing auto-deploy for a while

Deploy Center turns auto-deploy off so nothing builds without a click. It can come back on by
itself: someone reconnects Git in the Vercel dashboard, a Render Blueprint sync sets
`autoDeployTrigger` back, a teammate flips it. The guard notices and turns it off again.

When you do want pushes to build (a busy afternoon, an incident), give an **allowance**: auto-deploy
on for 1 to 168 hours. The guard leaves it on until the allowance ends, then turns it off.

> While auto-deploy is allowed, every push builds and costs money. So does every merged
> autofix PR: autofix never deploys a fix itself, but with auto-deploy on, the merge does.

## Commands

```bash
deploys vercel autodeploy-on my-project       # connect Git again from the remembered repo (or --all)
deploys render autodeploy-on my-service       # auto-deploy "On Commit" again (or --all)

deploys autodeploy allow vercel my-project 4  # on for 4 hours, then the guard turns it off
deploys autodeploy allow render --all 1       # every Render service, 1 hour
deploys autodeploy allow all --all 24         # everything, 24 hours
deploys autodeploy allowed [--json]           # running allowances
deploys autodeploy revoke vercel my-project   # withdraw now (and turn off what nothing else allows)

deploys guard --dry-run                       # what it would turn off; changes nothing
deploys guard                                 # one run
deploys guard schedule on|off                 # every 30 minutes through launchd
deploys guard status [--json]                 # on/off, last run, what it did, allowances
```

In the app: **Settings → Deploy & guard → Auto-deploy guard** has the same: the switch, the last run, running
allowances with the time left and **Revoke now**, and **Allow auto-deploy …** for one project or
all, for 1, 4 or 24 hours.

## How it works

- `autodeploy-on`, Vercel: `POST /v9/projects/<p>/link` with `{"type":"github","repo":"<org>/<repo>"}`
  from `~/.config/deploys/vercel-repos.json`. A project whose repo is not known there stops with an
  error; set it with `deploys vercel map <p> <owner/repo> [branch]`. After turning it on, check that
  **Settings → Git → Production Branch** matches the `ref` in that file.
- `autodeploy-on`, Render: `PATCH /services/<id>` with `{"autoDeployTrigger":"commit"}`.
- `autodeploy allow` writes the allowance first, then turns auto-deploy on. A guard run in between
  already sees it. If turning on fails for a single project, the allowance is withdrawn again.
  With `--all`, Vercel projects whose repo is not known stay manual (counted in the output).
- The guard reads every Vercel project and Render service. Where auto-deploy is on and no running
  allowance covers it, it turns it off: on Vercel the repo is remembered first (as with
  `autodeploy-off`), on Render the trigger goes to `off`. Then it sends a notification.
- Right before each switch the guard takes a lock shared with `allow` and `revoke`, and reads the
  allowances again. An allowance given a moment ago wins.
- Expired allowances are removed at the start of each run (not in a dry run).
- A platform that cannot be read is an error (exit 1, notification), never "nothing is on". The
  other platform is still checked. One project that cannot be switched does not stop the rest.
- The first run after `guard schedule on` is a dry run: a notification says what it would turn
  off, and from the next run it does. The job runs every 30 minutes while this Mac is awake; log:
  `~/Library/Logs/DeployCenter-guard.log`.
- `revoke` is never a dry run: it removes the allowance and turns off what it alone kept on.
  Revoking `vercel my-project` while an `all --all` allowance runs leaves the project on.

Platforms the guard looks at: Vercel when the `vercel` CLI is there (or projects are remembered),
Render when a key is set.

## Files

`~/.config/deploys/autodeploy-allow.json`: the allowances, key → expiry (Unix seconds).

```json
{ "vercel:my-project": 1794300000, "render:*": 1794290000, "*": 1794280000 }
```

`<platform>:<name>` is one project (Render: the service name, not the `srv-` id),
`<platform>:*` every project of a platform, `*` everything.

`~/.config/deploys/guard.json`: the last run (`lastRun`, `lastDry`, `lastActions`) and
`firstRunPending`.

## JSON for the app

`deploys autodeploy allowed --json`:

```json
[ { "platform": "vercel", "project": "my-project", "expiresAt": 1794300000 },
  { "platform": "all", "project": "*", "expiresAt": 1794280000 } ]
```

`platform` is `vercel`, `render` or `all`; `project` is a name or `*`. Sorted by `expiresAt`.

`deploys guard status --json`:

```json
{
  "enabled": true,
  "lastRun": 1794290000,
  "lastDry": false,
  "firstRunPending": false,
  "lastActions": [
    { "at": 1794290000, "platform": "render", "project": "api", "action": "off", "error": null },
    { "at": 1794290000, "platform": "vercel", "project": null, "action": "error", "error": "vercel: not logged in" }
  ],
  "allowances": [ { "platform": "vercel", "project": "my-project", "expiresAt": 1794300000 } ]
}
```

`action`: `off` (turned off), `wouldOff` (dry run), `failed` (could not switch; `error` says why),
`error` (the platform could not be read; `project` is null). `lastRun` is null before the first run.

## Exit codes

`guard`: 0 done, 1 a platform could not be read or a switch failed (the rest is done).
`autodeploy allow`: 0 done, 1 bad input or something could not be turned on.
`autodeploy revoke`: 0 done, 1 something could not be turned off.
