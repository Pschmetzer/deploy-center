# Good first issues

Small, self-contained tasks for a first pull request. The owner can turn each one into an issue
with the label `good first issue`. Please read [CONTRIBUTING.md](../CONTRIBUTING.md) first:
no real project names in examples, texts in English and German, nothing builds without `--yes`.
Each task says what to do, where, and when it is done. Add one line under `## Unreleased` in
`CHANGELOG.md` for anything a user would notice. German version: [GOOD-FIRST-ISSUES.de.md](GOOD-FIRST-ISSUES.de.md).

## Screenshots

1. **More screenshots.** Take a screenshot of the menu bar and of Settings in **demo mode**
   (Settings → General), add them to `docs/images/`, and use them with a one-line caption in
   [SAFE-START.md](SAFE-START.md). *Done when:* the page shows both pictures and none contains a real name.

2. **Screenshots for the Raycast and VS Code listings.** Both store listings have none yet; take them
   in demo mode. *Done when:* the files are where `integrations/raycast/PUBLISHING.md` and
   `integrations/vscode/PUBLISHING.md` say listings take them, and no real name is on them.

## Docs

3. **A troubleshooting entry from a real error.** Pick an error message in [`deploys`](../deploys) that is not
   in [TROUBLESHOOTING.md](TROUBLESHOOTING.md) yet and add what it means and what to do. Search the exact
   text with `grep`. *Done when:* the message is quoted word for word and the cause and next step are one short paragraph.

4. **A German page for the team docs.** [TEAM.md](TEAM.md) has no German version. Write `docs/TEAM.de.md` in
   the style of [FAQ.de.md](FAQ.de.md) (it begins with a line naming the English original; commands and file
   names stay as they are), link it from `docs/README.md` and add it to `ALIAS` in `scripts/check-docs.py`.
   *Done when:* `python3 -I scripts/check-docs.py` passes.

5. **A German page for GitLab.** The same for [GITLAB.md](GITLAB.md): `docs/GITLAB.de.md`, linked from
   `docs/README.md`. Keep `glab`, `GITLAB_TOKEN` and the commands untranslated.

6. **A German page for deploy windows.** The same for [SAFE-DEPLOY.md](SAFE-DEPLOY.md): `docs/SAFE-DEPLOY.de.md`.
   The `window.json` example stays as it is; translate what the fields mean.

7. **The rest of the German glossary.** [GLOSSARY.de.md](GLOSSARY.de.md) has the newer entries only. Translate
   the older entries of [GLOSSARY.md](GLOSSARY.md) that it lacks (for example Git connection, Rollback, Blueprint and
   Build minutes), in the same order. *Done when:* every `##` heading of the English page has a German one.

8. **A read-through by a native German speaker.** Read [FAQ.de.md](FAQ.de.md) and [FIRST-START.de.md](FIRST-START.de.md) aloud and fix
   stiff or machine-sounding sentences. Do not change commands, file names or numbers. *Done when:* the diff only touches prose.

9. **Try the CLI install from scratch.** In a fresh Ubuntu container (or WSL) follow [README-CLI.md](../README-CLI.md) word
   for word. Where a step is missing or wrong, fix the page; report anything that is a bug in the script instead of working around it.

## Examples and tests

10. **Run the examples in CI.** [examples/config/validate.sh](../examples/config/validate.sh) checks the ready-made
    configs without an account. Wrap it as `tests/examples-tests.sh`, list it in `tests/suites.txt` and give it a step in
    `.github/workflows/ci.yml` (`tests/release-tests.sh` checks that both agree). *Done when:* `bash tests/all.sh --list` shows it and the suite passes.

11. **An example of a shared config with a window.** Add `examples/config/deploy-center-window.json`: a
    [deploy-center.json](TEAM.md#1-shared-config-deploy-centerjson) with a shared `window` (a list: any open one is enough)
    and `approvals` for one project, using made-up names. Add it to the schema check in `validate.sh`.

12. **A hook that writes a local log.** Add `examples/config/hooks.d/post-deploy-log`: one line per start
    (UTC time, platform, project, sha, state) appended to a file whose path comes from a variable, with
    no network. Add a check to `validate.sh` that runs it with the variables `deploys` sets and reads the line back.

13. **A provider test for a failed login.** Pick one host in `tests/providers/` and add a fixture under
    `tests/fixtures/<host>/` for a 401 answer, and a test that the provider says so instead of printing an empty list.
    The contract is in [PROVIDERS.md](PROVIDERS.md).

## Bigger, still self-contained

14. **A git host.** [GITHOSTS.md](GITHOSTS.md) says what a new host provides. Take Bitbucket or Gitea: the
    three `*_head_of`, `*_pending_of` and `*_open_prs_of` functions, a test in the style of
    `tests/providers/gitlab.sh`, and a docs page like [GITLAB.md](GITLAB.md).

15. **A guide for the website.** Write `site/guides/<slug>/index.html` about closing deploys on Friday afternoons
    with `deploys freeze` (sources: [SAFE-DEPLOY.md](SAFE-DEPLOY.md), [FAQ.md](FAQ.md)). The list of places a new guide
    goes (sitemap, `llms.txt`, footers, related links) is in [CONTRIBUTING.md](../CONTRIBUTING.md#website).
    *Done when:* `python3 -I scripts/check-site.py` and `scripts/check-links.py site` pass.
