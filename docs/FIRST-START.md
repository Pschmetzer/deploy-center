# First start

What you see the first time Deploy Center opens, and what each step does. Nothing here changes a project until you press a button and confirm.

The tour has three steps: **Skip** closes it, **Back** and **Next** move between steps, and you can show it again with **Show the first-start guide again** in Settings → Help.

## 1. Only look

The app reads your projects from Vercel, Render and GitHub and shows how many still build on every push. It changes nothing. If something needed is missing, the step says so instead of saying "connected".

The tour uses your real projects, not a demo. For screenshots or a screen share, turn on **Demo mode** in Settings → General: project names, repos and domains are replaced by stand-ins.

## 2. A dry run

The second step asks "What would auto-deploy cost?": it counts the pushes to each project's deploy branch on GitHub and prices each as one build, at the project's average. You can look back 7 to 90 days. It is an estimate and changes nothing. The same estimate is `deploys simulate` ([SAVINGS.md](SAVINGS.md)).

## 3. One project first

Pick one project you can afford to have wait a little. Auto-deploy goes off for it alone and you confirm in a dialog. The rest stays as it is. A push to that project no longer builds it; you deploy it from the app.

To undo it, see [AUTO-DEPLOY.md](AUTO-DEPLOY.md#back-to-auto-deploy).

## After the tour

- Turn off auto-deploy for a whole platform with the button above the list.
- Read [SAFE-START.md](SAFE-START.md) for the same three steps in Terminal.
- If a connection is missing or an error appears, look it up word for word in [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
- All settings, with an example each: [SETTINGS.md](SETTINGS.md).

## When you want more than the tour

Each of these is a file in your config folder (`~/.config/deploys`, shown by `deploys where`) and starts nothing by itself. Ready-made files you can copy are in [examples/config/](../examples/config/); `sh examples/config/validate.sh` checks them without an account.

- **Close a time.** `deploys freeze add fri 15:00 --reason "no deploys before the weekend"`, then `deploys freeze` to read it back ([SAFE-DEPLOY.md](SAFE-DEPLOY.md)).
- **Cap the cost.** `deploys budget set 50` stops `deploy-changed --yes` before it goes over $50 of Vercel charges in a month ([CLI.md](CLI.md)).
- **Let small things ship.** A rule in `rules.json` and `deploys rules check` to see what it would do ([CLI.md](CLI.md#rules)).
- **Run your own script.** A `pre-deploy` or `post-deploy` file in `hooks.d` ([CLI.md](CLI.md#hooks-scripts-around-a-start-hooksd)).
- **A monorepo that builds everything.** Vercel's Ignored Build Step: [examples/config/vercel-ignored-build-step.sh](../examples/config/vercel-ignored-build-step.sh) and the [Glossary](GLOSSARY.md#ignored-build-step).
- **Questions.** [FAQ.md](FAQ.md) has short answers, and [GLOSSARY.md](GLOSSARY.md) the words.
