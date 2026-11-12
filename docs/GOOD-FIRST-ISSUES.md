# Good first issues

Small, self-contained tasks for a first pull request. The owner can turn each one into an issue
with the label `good first issue`. Please read [CONTRIBUTING.md](../CONTRIBUTING.md) first:
no real project names in examples, texts in English and German, nothing builds without `--yes`.

1. **fish completion.** `deploys completion` knows `zsh` and `bash`. Add `fish`, in the same place in
   [`deploys`](../deploys) (look for `completion`), and a test in `tests/script-tests.sh`.

2. **`--json` examples in the CLI reference.** Add a short sample output of `deploys changed --json`
   and `deploys status --json` to [docs/CLI.md](CLI.md), with made-up project names.

3. **Fix and test the CI example.** [examples/daily-deploy.yml](../examples/daily-deploy.yml) downloads only
   the single file `deploys`, which needs `providers/` next to it since 0.8.0. Switch it to
   `install.sh --version` (SHA-256 checked) and run it in a test repo.

4. **More screenshots.** Take a screenshot of the menu bar and of Settings in demo mode, add them to
   `docs/images/`, and use them with a one-line caption in [docs/SAFE-START.md](SAFE-START.md).

5. **Microsoft Teams in notify.** [integrations/notify/notify.sh](../integrations/notify/notify.sh)
   knows Discord, Slack-style, ntfy and Telegram. Add a Teams format and a test in
   [integrations/tests/run.sh](../integrations/tests/run.sh).

6. **Troubleshooting entry from a real error.** Pick an error message in [`deploys`](../deploys) that
   is not in [docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md) yet and add what it means and what to do.
