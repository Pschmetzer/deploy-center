# Alfred

A Script Filter for [Alfred](https://www.alfredapp.com) (Powerpack): type a keyword, see which
projects are building, failed or waiting, from `deploys status --json`. It deploys nothing.

| Key | What happens |
|---|---|
| ↵ | The project in Deploy Center (`deploycenter://select?project=…`) |
| ⌘↵ | Its site (`deploys open`) |

Building comes first, then failed, then waiting, then the rest. Typing filters by name.

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
