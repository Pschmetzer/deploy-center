# Alfred

A Script Filter for [Alfred](https://www.alfredapp.com) (Powerpack): type a keyword, see which
projects are building, failed or waiting, from `deploys status --json`. It deploys nothing.

| Key | What happens |
|---|---|
| ↵ | The project in Deploy Center (`deploycenter://select?project=…`) |
| ⌘↵ | Its site (`deploys open`) |

Building comes first, then failed, then waiting, then the rest. Typing filters by name.

## What the next deploy costs

A second Script Filter, `deploys-plan.sh` (keyword `dcp`), reads `deploys plan --json`: the first
item is the sum ("3 builds, about $1.20"), then one item per project with its price. The numbers
are an estimate (minutes times the rate you set with `deploys prices`); a project without a price
is counted apart. ↵ shows the project in Deploy Center. It starts nothing. Set it up like the first
filter, with its own keyword.

## What a rollback would do

A third Script Filter, `deploys-rollback.sh` (keyword `dcr`), previews a rollback. Type part of a
name, press Tab to complete it ("web "), and the list shows the newest deploy ("Now"), the deploy
production would go back to (the newest earlier one that went live), and the newest deploys, from
`deploys history <project> 5 --json`. ↵ shows the project in Deploy Center. It rolls nothing back:
a rollback is done in Deploy Center or the CLI, which asks first. Set it up like the first filter,
with its own keyword.

## Costs, journal and guard

Three more Script Filters, each read-only (they start, roll back and run nothing):

| Script | Keyword | What it shows |
|---|---|---|
| `deploys-costs.sh` | `dcc` | This month's Vercel charges (`deploys costs 31`), then each project of the last 7 days with its price and, where the count is known, the price of one build. ↵ shows the project in Deploy Center. Alfred keeps the answer for 5 minutes: the CLI makes one billing call per day. |
| `deploys-journal.sh` | `dcj` | Search the journal of the last 90 days (`deploys journal export`): every word of the query must be in the project, platform, result or text. Newest first, 40 at most. ↵ shows the project, ⌘C copies the line. |
| `deploys-guard.sh` | `dcg` | Is the guard on, when it ran last, what it did, the running allowances, and whether deploys are closed now (`deploys freeze`). It never runs the guard. |

Set each up like the first filter (Script Filter, `/bin/bash`, "with input as argv", the script with `"$1"`),
with its own keyword and an **Open URL** action with `{query}` for ↵ (the costs and journal items).

## Set it up

1. Alfred Preferences → Workflows → **+** → Blank Workflow, name it "Deploy Center".
2. Add **Inputs → Script Filter**: keyword `dc`, Language `/bin/bash`, "with input as argv", and as
   script `"/path/to/deploy-center/integrations/alfred/deploys-filter.sh" "$1"`.
3. Connect it to **Actions → Open URL** with `{query}` (for ↵).
4. Add **Actions → Run Script** (`/bin/bash`, input as argv):
   `"/path/to/deploy-center/integrations/alfred/deploys-open.sh" "$1"`, and connect it with the
   ⌘ modifier.

The scripts find `deploys` in the Deploy Center app, then on `PATH` (Homebrew's folders are
added), or in `DEPLOYS` if you set it in the workflow's environment variables. A deploy stays in
Deploy Center, the terminal or Raycast, where it asks first.

Tested here: the filter's JSON against a stand-in `deploys` (`integrations/tests/run.sh`), and the costs, journal
and guard filters with `integrations/alfred/test.sh`. Not tested: inside Alfred.
