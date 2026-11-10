# Savings: simulate and ledger

German version: [ERSPARNIS.md](ERSPARNIS.md).

Two commands, two questions:

- `deploys simulate [--days 30]`: *What would auto-deploy cost me a month, next to deploying once a day?* Works before you turn anything off.
- `deploys ledger`: *What has turning auto-deploy off saved so far?* Counts from the day you turned it off.

Both need `gh` (logged in), because they count pushes on GitHub. Add `--json` for the machine answer. In the app: the Simulator (a banner before anything is turned off, and Settings → Costs) and the Ledger ("≈ $X saved since …", per project).

Every number is an estimate and shows "≈". The JSON says how it was made (`method`).

## How it is estimated

**pushes to the deploy branch × the project's average build**

1. **Pushes.** From GitHub's activity list for the deploy branch (`repos/{repo}/activity`, `activity_type=push`). Where that cannot be read, commits on the branch stand in. One push can carry several commits, so that count is an upper bound. `basis` says which one was used.
2. **Average build.** The mean duration of the project's last 20 finished builds (Vercel: `READY`; Render: `live` or `deactivated`). Failed and canceled builds are not measured.
3. **Price per build**, the first one that is known:
   1. Vercel billing (`deploys costs`, last 7 days): billed build dollars / builds of that project (`vercel-billing`).
   2. The team's price per build minute (billed build dollars / billed build minutes over all Vercel projects with billing) × the average build (`vercel-team-rate`).
   3. A rate you set (`rate-setting`): `DEPLOYS_VERCEL_USD_PER_MIN` for one Vercel build minute, `DEPLOYS_RENDER_USD_PER_MIN` for one Render pipeline minute.

   Render has no billing API. Without `DEPLOYS_RENDER_USD_PER_MIN`, Render shows pipeline minutes only, and the dollars stay `null` ("?").

**simulate**: every push in the window counts as one build ("auto-deploy"). "Once a day" counts one build on each day that had a push. Both are scaled from the window (`--days`, 1 to 90) to 30 days.

**ledger**: from the day auto-deploy was turned off (per project), every push whose commit was never built counts as a skipped build. Projects whose auto-deploy was never turned off here are left out.

## Examples

```bash
deploys simulate
```

```
Estimate over the last 30 days, per month:
  web (vercel): 6 pushes; auto-deploy ≈ $1.2, 18 build minutes; once a day ≈ $0.4
  api (render): 4 pushes; auto-deploy ≈ ?, 20 pipeline minutes; once a day ≈ ?
Auto-deploy would cost ≈ $1.2 a month; deploying once a day ≈ $0.4.
```

```bash
DEPLOYS_RENDER_USD_PER_MIN=0.01 deploys simulate --days 14
deploys ledger
```

```
Since 2026-01-20: ≈ $0.8 saved, 6 builds skipped (12 Vercel build minutes, 10 Render pipeline minutes).
  web (vercel), off since 2026-01-20: 4 of 5 pushes not built, ≈ $0.8, 12 build minutes
  api (render), off since 2026-01-25: 2 of 3 pushes not built, ≈ ?, 10 pipeline minutes
```

```bash
deploys ledger --json | jq '.total.usd'
```

## JSON

Both: `estimate` (always `true`), `kind` (`simulate` or `ledger`), `currency` (`USD`), `generatedAt`, `method`, `projects`, `total`.

Per project, both:

| Field | Meaning |
|---|---|
| `platform`, `name` | `vercel` or `render`, and the project |
| `unit` | `build minutes` (Vercel) or `pipeline minutes` (Render) |
| `basis` | `pushes` or `commits` (upper bound); `null` if GitHub could not be read |
| `problem` | why a number is missing, or `null` |
| `pushes` | pushes counted in the window |
| `avgBuildMinutes`, `buildsMeasured` | the average build and how many builds it is from (at most 20) |
| `usdPerBuild`, `priceSource` | the price of one build, and `vercel-billing`, `vercel-team-rate`, `rate-setting` or `null` |

simulate (`days`, `teamUsdPerBuildMinute` at the top):

| Field | Meaning |
|---|---|
| `auto` | auto-deploy is on now |
| `activeDays`, `pushesPerDay` | days with a push, pushes per day |
| `autoMonth`, `dailyMonth`, `savingMonth` | `{builds, minutes, usd}` per month: auto-deploy, once a day, the difference |
| `total.*Month` | `{usd, vercelMinutes, renderMinutes, builds}` over all projects |
| `total.usdComplete` | `false` if a project with pushes has no price, so `usd` is too low |

ledger (`since`, `days` since the first project was turned off, at the top):

| Field | Meaning |
|---|---|
| `offAt`, `offDay` | when auto-deploy was turned off |
| `builds`, `skipped` | builds since then, and pushes never built |
| `savedMinutes`, `savedUsd`, `builtUsd` | the skipped builds in minutes and dollars, and what the builds that did run cost |
| `skippedPushes` | the last 20 skipped pushes, `{day, sha}` |
| `total` | `skipped`, `pushes`, `builds`, `usd`, `builtUsd`, `vercelMinutes`, `renderMinutes`, `usdComplete` |

## Limits

- An estimate, not a bill. Your invoice from Vercel or Render is what counts.
- Every build is priced at the average. Build caches, larger machines and included minutes are not in it.
- Vercel billing covers the last 7 days only. A project without billed builds there falls back to the team rate.
- The commit fallback overcounts when a push carries several commits.
- A deploy started by a hook or a workflow counts as built; the ledger then does not count that push as saved.
- Without `gh`, or without a known repo and branch, a project has no numbers (`problem` says why).
