# Fixtures for tests/team-tests.sh

Answers of the stand-in `gh` (`tests/team-tests.sh` writes it). Every name is made up.

- `files/<owner>/<repo>/<file>`: a file in a repo; the stand-in answers `repos/<owner>/<repo>/contents/<file>`
  with it, base64-encoded as GitHub does. A file that is not here is a 404.
- `api/<path>.json`: the answer to `gh api <path>`, with `/ ? & =` in the path written as `_`.

The commits used by the approval tests:

| commit    | PR  | what is there                                                   | counts |
|-----------|-----|-----------------------------------------------------------------|--------|
| `aaaa111` | #12 | dev-two approved                                                | 1      |
| `bbbb222` | #13 | the deployer approved; dev-two approved, then asked for changes | 0      |
| `cccc333` | #14 | label for dev-three added by the deployer; dev-four labelled themself | 1 |
| `dddd444` | –   | open issue #20 names the commit, dev-two labelled it            | 1      |
