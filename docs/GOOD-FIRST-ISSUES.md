# Good first issues

Small, self-contained tasks for a first pull request. The owner can turn each one into an issue
with the label `good first issue`. Please read [CONTRIBUTING.md](../CONTRIBUTING.md) first:
no real project names in examples, texts in English and German, nothing builds without `--yes`.

1. **More screenshots.** Take a screenshot of the menu bar and of Settings in demo mode, add them to
   `docs/images/`, and use them with a one-line caption in [docs/SAFE-START.md](SAFE-START.md).

2. **Troubleshooting entry from a real error.** Pick an error message in [`deploys`](../deploys) that
   is not in [docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md) yet and add what it means and what to do.

3. **A git host.** [GITHOSTS.md](GITHOSTS.md) says what a new host provides. Take Bitbucket or Gitea: the
   three `*_head_of`, `*_pending_of` and `*_open_prs_of` functions, a test in the style of `tests/providers/gitlab.sh`,
   and a docs page like [GITLAB.md](GITLAB.md).

4. **Screenshots for the Raycast and VS Code listings.** Both store listings have none yet; take them in demo mode.
