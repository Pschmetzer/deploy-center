# GitLab as a source

Deploy Center counts what is merged but not live: the commits between the live commit and the
branch, the merge requests among them, and the merge requests still open. For a project whose
repo is on GitLab (gitlab.com or your own GitLab) it now reads GitLab for this, the same way it
reads GitHub. The app needs no change: `vercel json`, `render json`, `changed --json` and
`details` give the same fields for both.

## Set up

Either of these works. With both, glab is used.

**glab** (the GitLab CLI):

```bash
brew install glab
```

```bash
glab auth login
```

For a self-managed GitLab, log in with `glab auth login --hostname git.example.com`.

**A token**, without glab: a personal access token with the `read_api` scope, in `GITLAB_TOKEN`.

```bash
export GITLAB_TOKEN=glpat-...
```

For a self-managed GitLab, also say where it is:

```bash
export GITLAB_HOST=git.example.com
```

The token is sent only to `GITLAB_HOST` (gitlab.com when unset), never to another host a repo URL
names, and it goes to curl on stdin, so it never shows in the process list. The app starts the
script from launchd, which does not read your shell profile: put the variables where the app's
login-shell PATH comes from (`~/.zprofile`), or use glab, whose login is stored by glab itself.

Check it:

```bash
deploys doctor
```

`gitlabCli` says whether glab is installed, `gitlabLoggedIn` whether glab is logged in to
`GITLAB_HOST` or `GITLAB_TOKEN` is accepted there. `deploys where` shows the GitLab user.

## Which repos count as GitLab

Each platform says where a project deploys from. Vercel's Git link has a type (`github`,
`gitlab`); Render gives the repo URL. In the JSON, `.repo` is:

| Repo | `.repo` |
|---|---|
| GitHub | `owner/name`, as before |
| gitlab.com | `gitlab.com/group/subgroup/name` |
| Self-managed GitLab | `git.example.com/group/name` |

A host is GitLab when it is `gitlab.com`, the host in `GITLAB_HOST`, one listed in
`DEPLOYS_GITLAB_HOSTS` (several hosts, spaces between), or has `gitlab` in its name. Any other
host (Bitbucket, Gitea, ...) is neither: those projects stay "branch head unknown", as before.

## What is read

All reads go to `https://<host>/api/v4/projects/<group%2Fname>/`, through `glab api --hostname <host>`
or curl.

| What | GitLab API | Same as on GitHub |
|---|---|---|
| Branch head | `repository/commits/<branch>` | `repos/…/commits/<branch>` |
| Commits waiting | `repository/compare?from=<live>&to=<branch>` | `compare/<live>...<branch>` |
| Ahead, behind, diverged | `repository/merge_base` of both; when live is not an ancestor, the comparison the other way gives `behindBy` | `status`, `behind_by` |
| Merged MRs in that range | `See merge request group/name!12` or `(!12)` in the message; for up to 10 commits without one, `repository/commits/<sha>/merge_requests` (merged only). Each MR is counted once. | `(#12)`, `Merge pull request #12`, `commits/<sha>/pulls` |
| Open MRs | `merge_requests?state=opened&per_page=100`; drafts from `draft`, bots by name (Renovate, Dependabot, `project_…_bot`, `…-bot`) | `pulls?state=open` |
| Details: commits and authors | the comparison: `author_name`, `committed_date`, `web_url` | `author.login`, `commit.committer.date` |
| Details: files and lines | the comparison's `diffs`; `+` and `-` lines counted | `files[].additions`, `deletions` |
| Details: CI of the branch head | `repository/commits/<sha>/statuses`: one per job; `failed`/`canceled` failed, `running`/`pending`/`created` running | check runs |

## Differences from GitHub

- **No cache.** gh caches comparisons for five minutes; glab and the API calls do not. A reload
  asks GitLab again. GitLab limits requests per minute, not per hour; a reload of a few dozen
  projects stays well below that.
- **No budget of its own.** GitLab has no hourly budget like GitHub's. The one check that exists
  is GitHub's: when fewer than 300 GitHub requests are left in the hour, a reload reads only the
  branch heads, for GitLab repos too.
- **Never a floor.** GitHub lists at most 250 commits of a comparison; GitLab lists them all, so
  `pendingPartial` is always false.
- **Open MRs in the details have no CI state** (`ci: "none"`): GitLab's list of merge requests
  does not carry their pipelines, and asking for each one would cost a call per MR.
- **Bots** are told by name, since GitLab marks few users as bots in these answers.
- `.gitlab-ci.yml` counts as a risky file in the details, next to `.github/workflows/`.
- `deploys triggers` lists GitHub workflows only; GitLab pipelines that deploy are not looked for.

## Vercel projects on GitLab

Turning auto-deploy off (`deploys vercel autodeploy-off`) remembers a GitLab link as
`{"type":"gitlab","repo":"gitlab.com/group/name","projectId":…,"ref":…}`, and
`deploys vercel deploy` then sends Vercel a GitLab `gitSource` with that project id. For a
project disconnected before, say where it deploys from:

```bash
deploys vercel map web gitlab.com/group/name main
```

This looks up the project id on GitLab, so glab or `GITLAB_TOKEN` must work for that host.

## Without lib/githost.sh

The GitLab code lives in `lib/githost.sh`, next to `deploys` (and inside the app, under
`Contents/Resources/lib/`). An older copy of `deploys` alone, without that folder, still reads
GitHub as before; GitLab projects then stay "branch head unknown".
