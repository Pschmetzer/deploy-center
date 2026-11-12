# Agent digest and approval

Coding agents (Claude Code, Cursor, Codex, Devin, bots like Dependabot) push many times a day.
With auto-deploy off, their commits wait. Once a day this digest says what waits, per project:
how many commits came from agents and how many from people, the pull requests, and what to check
first. A person approves with one click, and only then does anything deploy.

```
# Deploys waiting – 2026-11-10

2 projects waiting: 4 commits by agents, 2 by people.

## app-web (vercel, me/app)

4 commits waiting: 3 agent, 1 human

Pull requests:
- #12 Login page – agent (author claude, co-author Claude)
- #13 New copy – agent (label ai-generated)

Commits without a pull request:
- `c4` Fix typo – dev-two, human

Check before shipping:
- CI failed on the branch head
- changes package.json
```

No server of ours is involved. The approval is a GitHub workflow in a repo of yours:

- **Button:** the Slack message has an *Approve deploy* button (Telegram and ntfy get one too,
  Discord a link). It opens the `approve-deploy` workflow. Press **Run workflow** and enter the
  projects the message lists, or `all`.
- **Issue:** the digest opens one issue per day, "Deploys waiting – <date>", and updates it
  during the day. Add the label `deploy-approved` and the projects listed in that issue deploy.
  The run comments the result, takes the label off and closes the issue when every deploy started.
  The digest closes the issues of earlier days, so an old list cannot be approved.

Either way, the workflow checks the person against `DEPLOYS_APPROVERS`, refuses bots, leaves out
every project not approved (`deploys ignore`), then runs the [Action](../action/) with
`deploy: true`. Each approved project deploys at its branch head at that moment.

## Setup in 5 steps

1. **Pick a repo for approvals**, for example a private `ops` repo. Copy
   [examples/approve-deploy.yml](examples/approve-deploy.yml) and
   [examples/daily-digest.yml](examples/daily-digest.yml) to its `.github/workflows/`, on the
   default branch (GitHub only shows **Run workflow** for workflows there). Pin the
   `uses:` and `ref:` lines to a release tag or commit SHA.
2. **Add secrets**: `VERCEL_TOKEN`, `RENDER_API_KEY` (leave out what you don't use) and
   `DEPLOYS_NOTIFY_URL` (your Slack, Discord, ntfy or Telegram webhook, as for
   [notify](../notify/)). **Add variables**: `DEPLOYS_REPOS_JSON` (your
   `~/.config/deploys/vercel-repos.json`) and `DEPLOYS_VERCEL_TEAM` if you use a team.
3. **Say who may approve**: the variable `DEPLOYS_APPROVERS`, GitHub logins separated by commas.
   Without it, nothing deploys. Don't list a login whose token an agent uses.
4. **Say who counts as an agent** (optional): the variables `DEPLOYS_AGENT_AUTHORS` and
   `DEPLOYS_AGENT_LABELS`, see below. Labels the agents set on their pull requests help most.
5. **Try it**: run *daily digest* by hand (Actions tab). You get the issue and the message.
   Approve with the label or the button. Locally, without posting:
   ```bash
   DEPLOYS_DIGEST_REPO=you/ops integrations/digest/digest.sh --issue --post --dry-run
   ```

If the project repos are private, `github.token` of the ops repo cannot read them: give the
digest step a token that can read them and write issues in the ops repo.

## Who counts as an agent

[classify.sh](classify.sh) checks each waiting commit, first match wins:

| Rule | Example |
|---|---|
| GitHub marks the author (or the PR's author) as a bot | `dependabot[bot]` |
| The author login matches `DEPLOYS_AGENT_AUTHORS` | `claude`, `devin-ai-integration` |
| A `Co-Authored-By:` trailer matches it | `Co-Authored-By: Claude <noreply@anthropic.com>` |
| The pull request has a label in `DEPLOYS_AGENT_LABELS` | `ai-generated` |
| The pull request was opened by a matching login | an agent's PR, merged by a person |
| The pull request's branch starts with a prefix in `DEPLOYS_AGENT_BRANCHES` (default `claude/ cursor/ codex/ copilot/ devin/`) | `claude/fix-login` |

Everything else is human. A "Generated with …" line in a commit body is not read (the digest gets
commit titles only); the branch and the co-author trailer are the reliable signs. Patterns are globs (`*`, `?`), matched without case against the whole
login; for a co-author also against the first word of the name, and a pattern with `@` against
the email (`*@cursor.com`). Setting a variable replaces its default list:

- authors: `*[bot] claude claude-code cursor cursoragent cursor-agent devin devin-ai-integration codex chatgpt-codex-connector copilot copilot-swe-agent`
- labels: `agent ai-generated ai claude codex cursor devin copilot`

It reads JSON and calls only jq, so it also works alone:
`deploys details me/app <live sha> main | jq .commits | integrations/digest/classify.sh`.

## digest.sh

| | |
|---|---|
| `digest.sh` | Print the digest as Markdown. `--out file` also writes it, `--json` prints JSON. |
| `--issue` | Open or update today's issue in `DEPLOYS_DIGEST_REPO` (needs `gh`). |
| `--post` | Send a short version to `DEPLOYS_NOTIFY_URL`, with the button when `DEPLOYS_DIGEST_REPO` is set. |
| `--dry-run` | With `--issue`/`--post`: print what would be sent. |

It reads `deploys changed --json` (so `deploys ignore` applies), then `deploys details` per
project for the commits and `gh api` for each pull request's title, labels and author. For a
GitLab repo (`gitlab.com/group/name`) it asks `glab api` for each merge request instead, so glab
needs a login there (`glab auth login`, or `GITLAB_TOKEN`). "Check
before shipping" lists the files `deploys details` marks as risky, a failed CI run on the branch
head and, when the CLI has it, what `deploys risk <project> --json` says. `DEPLOYS_DIGEST_WORKFLOW`
names another workflow file. "Today" is the UTC day.

Without `gh` (or `glab` for GitLab), commit messages stand in for PR titles and labels are not read.

## Limits

- GitHub cannot fill in workflow inputs from a link, so the button opens the workflow page and
  the projects are typed in. The issue route needs no typing.
- Slack may show a small warning after a button click, because no server answers it. The link
  still opens.
- Approval is per project, not per commit: commits pushed after the digest go along.
- For a second check, add `environment: production` with required reviewers to the job.

Not tested yet: runs on GitHub's runners and real posts. The scripts and the workflow's steps are
tested locally with a stand-in `deploys`, `curl` and `gh` (`integrations/tests/run.sh`).
All add-ons at a glance: [what is tested](../README.md#what-is-tested-and-what-is-not).

The projects are read four at a time (`DEPLOYS_DIGEST_JOBS`, default `4`), each with one
`deploys details` and one GitHub call per pull request. A project that cannot be put together is
left out and the digest says that some projects could not be read.
