# Good first issues

Small, self-contained tasks for a first pull request. The owner can turn each one into an issue
with the label `good first issue`. Please read [CONTRIBUTING.md](../CONTRIBUTING.md) first:
no real project names in examples, texts in English and German, nothing builds without `--yes`.

1. **fish completion.** `deploys completion` knows `zsh` and `bash`. Add `fish`, in the same place in
   [`deploys`](../deploys) (look for `completion`), and a test in `tests/script-tests.sh`.

2. **`--json` examples in the CLI reference.** Add a short sample output of `deploys changed --json`
   and `deploys status --json` to [docs/CLI.md](CLI.md), with made-up project names.

3. **Try the CI example and report.** [examples/daily-deploy.yml](../examples/daily-deploy.yml) has not
   been tested by the project yet. Run it in a test repo, then fix what breaks or note what you found.

4. **More screenshots.** Take a screenshot of the menu bar and of Settings in demo mode, add them to
   `docs/images/`, and use them with a one-line caption in [docs/SAFE-START.md](SAFE-START.md).

5. **Microsoft Teams in notify.** [integrations/notify/notify.sh](../integrations/notify/notify.sh)
   knows Discord, Slack-style, ntfy and Telegram. Add a Teams format and a test in
   [integrations/tests/run.sh](../integrations/tests/run.sh).

6. **Fewer shellcheck warnings.** CI runs `shellcheck --severity=error`. Run it with
   `--severity=warning` on `deploys`, fix a few warnings without changing behavior, and keep the tests green.

7. **Troubleshooting entry from a real error.** Pick an error message in [`deploys`](../deploys) that
   is not in [docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md) yet and add what it means and what to do.

8. **Link check in CI.** Add a step to [.github/workflows/ci.yml](../.github/workflows/ci.yml) that
   fails when a relative link in `README.md`, `README.de.md` or `docs/*.md` points to a file that
   does not exist. A small bash or Python script is enough; no network needed.
