---
description: Show what is waiting to go live on Vercel and Render (deploys changed). Read-only.
disable-model-invocation: true
allowed-tools: Bash(deploys changed *)
---

Run `deploys changed --json`. It is read-only.

Answer with one line per project: name, platform, how many commits are waiting
(`pendingCommits`, or "changes waiting" when it is null), open PRs (`pendingPRs`) and the newest
commit message (`headMsg`), then one total line. If the list is empty, say everything is live.

If the command exits 1, some projects could not be read: list those from its error output, and
still show the rest. If `deploys` is not installed, say so and point to https://deploycenter.app.

Do not deploy anything. End with: "Deploy with /deploy-center:deploys-ship <project> when ready."
