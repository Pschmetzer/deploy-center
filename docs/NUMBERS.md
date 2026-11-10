# How the app counts

English version of [ZAHLEN.md](ZAHLEN.md).

- **Has changes** (`CHANGED_RULE` in `deploys`): deployable, not suspended, not building, branch head known, and the live commit differs from the branch head (without a commit id: compared by time).
- **Commits waiting**: `ahead_by` from GitHub's comparison of the live commit with the branch (exact).
- **PRs waiting**: PR numbers in the commit messages (`(#12)`, `Merge pull request #12`). For rebase merges without a number, GitHub is asked through `commits/{sha}/pulls` (at most 10 commits). Past 250 commits the count is a lower bound ("at least").
- **One repo, several projects** (frontend and backend): counted once in the banner and the menu bar. In the list the rows stay together, and the later ones say "same changes as the row above (same repo)".
- **Open PRs**: per repo, with drafts and bots (Dependabot, Renovate) counted apart.
- **Force-push**: if the live commit is no longer in the repo, the row says "New changes (branch was rewritten)" instead of a number.
- **After a rollback**: what is live is older than the branch, so the row has changes again.
- **GitHub limit**: with fewer than 300 calls left, only the branch heads are read (no comparison, no open PRs).

## Repos on GitLab

The same rules apply to GitLab, with three differences ([GITLAB.md](GITLAB.md#differences-from-github)):

- **No floor.** GitLab lists every commit of a comparison, so a count past 250 is exact, never "at least".
- **No budget of its own.** GitLab limits requests per minute, not per hour. Only GitHub's limit above switches a reload to branch heads, for GitLab repos too.
- **Open MRs** are counted like open PRs, but without a CI state: GitLab's list of merge requests does not carry their pipelines.
