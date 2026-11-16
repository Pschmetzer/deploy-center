# Good first issues

Small, self-contained tasks for a first pull request. The owner can turn each one into an issue
with the label `good first issue`. Please read [CONTRIBUTING.md](../CONTRIBUTING.md) first:
no real project names in examples, texts in English and German, nothing builds without `--yes`.

1. **`--json` examples in the CLI reference.** Add a short sample output of `deploys changed --json`
   and `deploys status --json` to [docs/CLI.md](CLI.md), with made-up project names.

2. **More screenshots.** Take a screenshot of the menu bar and of Settings in demo mode, add them to
   `docs/images/`, and use them with a one-line caption in [docs/SAFE-START.md](SAFE-START.md).

3. **Troubleshooting entry from a real error.** Pick an error message in [`deploys`](../deploys) that
   is not in [docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md) yet and add what it means and what to do.

4. **A test for the fish completion.** `deploys completion fish` exists; add a check to
   `tests/script-tests.sh` that its output names the commands and loads in `fish` when `fish` is installed.

5. **A git host.** [GITHOSTS.md](GITHOSTS.md) says what a new host provides. Take Bitbucket or Gitea: the
   three `*_head_of`, `*_pending_of` and `*_open_prs_of` functions, a test in the style of `tests/providers/gitlab.sh`,
   and a docs page like [GITLAB.md](GITLAB.md).

6. **Screenshots for the Raycast and VS Code listings.** Both store listings have none yet; take them in demo mode.
