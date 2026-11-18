# Deploying from the app

Nothing deploys until you tick projects and press **Deploy live**, then confirm. This page says what you see on the way.

## Before you press it: the cost

The bottom bar shows about what the ticked Vercel builds cost. It is an estimate from your own past builds, shown before anything starts.

## The confirmation

**Put this live now?** lists what will go live. It can also show:

- the newest commit message of each project with changes waiting (up to 5; hidden in demo mode),
- a note when a project is already on its newest commit (building it costs and changes nothing),
- what the builds cost and whether your budget holds,
- a warning for a project deployed less than 5 minutes ago, and for a waiting project whose newest commit is over 30 days old,
- your own marks on the projects (a note, "critical").

With more than 3 projects, a red risk score or a mark, **Cancel** is the default button, so Return does not take you live by accident.

After you confirm, **Settings → Deploy → Wait before a deploy starts** can give you a few seconds to cancel. See [SETTINGS.md](SETTINGS.md).

## Looking without deploying

A row's menu has **Check the site now**: one request, with the answer and its time in a note. It only looks; nothing is rolled back. The window subtitle says how many projects failed their last deploy.

## Copying

**Copy list** in the confirmation puts the projects about to go live on the clipboard. A row's menu has **Copy summary**: name, platform and what waits, in one line.

## Costs

**Costs …** opens the costs sheet. It has a 7-day sparkline, a chart of 7 or 14 days, the dearest project of the week, a monthly budget per project with a traffic light (right-click a project), a "what if one build a day" estimate and a Markdown report you can copy. A monthly cap for the CLI is `deploys budget set 50` ([CLI.md](CLI.md)).

The menu bar icon turns into a dollar sign when the month is over budget at the current pace.

## After a deploy

Every deploy is written to the [journal](JOURNAL.md). The list refreshes while a deploy runs, and **Settings → Deploy → Watch the site after going live** checks the site for a few minutes.
