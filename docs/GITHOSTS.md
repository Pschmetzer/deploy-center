# Adding a git host

[PROVIDERS.md](PROVIDERS.md) is about where a project is *deployed* (Vercel, Render, …). This page is about where its *code lives*: the git host `deploys` asks "what is waiting?". GitHub and GitLab are built in. Bitbucket and Gitea are the most wanted next ones. A repo on a host `deploys` cannot ask is listed as `unknown` and never counted as waiting.

The code is `lib/githost.sh` (GitLab and the dispatchers) and, for GitHub, the functions `head_of`, `pending_of` and `open_prs_of` in `deploys`. Read [GITLAB.md](GITLAB.md) first for what a user sees.

## How a repo is written

Every platform JSON has a `repo` field, the slug of the repo:

| Slug | Host |
| --- | --- |
| `owner/name` | GitHub (the default, kept as it always was) |
| `gitlab.com/group/sub/name` | GitLab: the host first, then the full project path |
| `git.example.com/group/name` | a self-managed GitLab, see `githost_of` |

`githost_split` turns a URL or slug (`https://`, `ssh://`, `git@host:path`, `.git` dropped) into `host path`. `githost_of <slug>` answers `github`, `gitlab` or `unknown`. A new host starts here: teach `githost_of` which hosts are yours (GitLab also accepts `GITLAB_HOST`, `DEPLOYS_GITLAB_HOSTS` and any host with `gitlab` in its name) and teach `GITHOST_SLUG_JQ` and `GITHOST_VERCEL_LINK_JQ` how a platform's repo URL becomes your slug.

## The functions a host provides

The three dispatchers (`githost_head_of`, `githost_pending_of`, `githost_open_prs_of`) call a host's own functions with the same arguments and the same **output files** as the GitHub ones. Each function writes one JSON line to a file in `$out`, named with `githost_cache_name`, and writes nothing when it cannot answer (it never fails the run: `deploys` then shows "branch head unknown" instead of guessing).

| Function | Writes | Record (`key`, `value`) |
| --- | --- | --- |
| `<host>_head_of <repo> <ref> <out>` | the newest commit of a branch | `key` `repo@ref`; `value` `{at, msg, sha}`, or `{error}` when asking failed (use `head_why` for the text) |
| `<host>_pending_of <repo> <base> <ref> <out>` | the commits from the live commit (`base`) to the branch (`ref`) | the same record `pending_of` writes: the commits, the merge requests among them, and how the branch stands to what is live (ahead, behind, diverged, or "rewritten" when `base` is gone) |
| `<host>_open_prs_of <repo> <out>` | open pull or merge requests | `{all, partial, drafts, bots}` |

Also needed so the rest of the CLI works for a repo on your host:

- `<host>_details <repo> <base> <ref>`: the JSON of `deploys details` (commits, files, checks).
- `<host>_ci_of <slug> <sha or branch>`: the CI verdict `{state, reason, checks, failed, running}`, `state` one of `green`, `red`, `pending`, `none`, `unknown`. A pipeline that waits for a person is not `pending`.
- `<host>_risk_of <slug> <base> <ref>`: the risk of what waits (`deploys risk`).
- `<host>_default_branch <slug>` and, if a platform needs it, a project id.
- `<host>_logged_in` and `<host>_user`, for `deploys doctor` and `deploys where`.

Dispatch lines to add: the three `githost_*` functions in `lib/githost.sh`, and the places in `deploys` that test `githost_of` (details, CI, default branch).

## Rules that keep it safe

- **Reads only.** Every call is a GET. A rate limit (429), a server error (5xx), no answer or a hung call is asked again three times, 2 s then 4 s apart; a write is never repeated.
- **The token goes to one host only.** GitLab's `GITLAB_TOKEN` goes to curl on stdin (never in argv) and only to the host `GITLAB_HOST` names: a repo URL that comes from a platform must not be able to send a token elsewhere. A new host needs the same: its own token variable and a host check.
- **No private project turns into "rewritten".** A 404 can mean "private". Only call history rewritten when the branch itself can still be read.
- **Pagination is bounded.** GitLab reads up to five pages of 100 open requests; more is reported as `partial`.
- **Without any git host** (`githost_available` false), `with_heads` adds no heads and the app shows no counts; deploying keeps working.

## Tests

`tests/providers/gitlab.sh` is the model. It needs no network: it puts stand-ins for `glab` and `curl` into a temporary `bin/` and answers by request path (`projects/me%2Fapp/repository/commits/main`, `…/compare?from=…&to=…`, `…/merge_requests?state=opened&per_page=100&page=1`). It checks:

- a failure is asked again and a hung call ends;
- a private project's 404 is not "history rewritten";
- the merge requests a commit came from are asked once and cached;
- open requests past one page are counted.

`tests/script-tests.sh` covers the dispatch (`githost_of` for each spelling of a repo). Add the same cases for your host, and run `bash tests/all.sh --quick`.

## Open a pull request

Keep it small: one host, the functions above, the tests, and a docs page like [GITLAB.md](GITLAB.md). Use made-up project names. See [CONTRIBUTING.md](../CONTRIBUTING.md).
