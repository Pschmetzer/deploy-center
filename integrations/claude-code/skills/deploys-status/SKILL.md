---
description: Show what is building, live or failed on Vercel and Render (deploys status). Read-only.
disable-model-invocation: true
allowed-tools: Bash(deploys status *)
---

Run `deploys status --json`. It is read-only.

Summarize: what is building right now, what failed (with the project name and when), and what is
live. Keep it to a few lines. For each failed build, suggest `/deploy-center:deploys-fix <project>`.

If `deploys` is not installed, say so and point to https://deploycenter.app. Do not deploy anything.
