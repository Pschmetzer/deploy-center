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

Tested here: the filter's JSON against a stand-in `deploys` (`integrations/tests/run.sh`). Not
tested: inside Alfred.
