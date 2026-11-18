# Settings, with an example each

The window Settings has the tabs General, Platforms, Projects, Deploy, Costs, Claude, iPhone, Team and Help. This page lists the options you will most likely change, with a made-up example for each. Examples use made-up names.

## General

| Option | Example |
| --- | --- |
| Reload the lists every | Set 15 minutes on a slow connection, so the app asks Vercel, Render and GitHub less often. |
| Show in the menu bar / No Dock icon | Turn both on to keep Deploy Center as a small menu bar item and nothing in the Dock. |
| Open at login | On when you deploy every morning. A build without a Developer ID signature cannot be a login item. |
| Demo mode | On before a screen share: `my-shop` shows as a stand-in name. Shortcut ⇧⌘D. |
| Compact list | On with 40 projects, to see more rows at once. |
| Colour-blind friendly | Blue instead of green for "live". |
| Load logos from the project sites | Off if you do not want the app to fetch icons from your project domains. |
| Language | Switch the app between English and Deutsch. |

## Notifications

| Option | Example |
| --- | --- |
| Notify when a deploy ends | A notification "my-shop is live" when the build finishes. |
| Daily reminder to deploy | 09:00: one notification with the number of commits waiting. |
| Summary of the day | 17:00: what went live today and what still waits. |
| Week in review on Mondays | A Monday note: the last 7 days against the 7 before. The same review is shown in Settings → Costs. |
| Quiet hours (from / to) | 22:00 to 07:00: no notification in between. |
| Remind again after 30 minutes | A failure you did not open comes back once. |

## Deploy

| Option | Example |
| --- | --- |
| Builds at the same time | 2: deploying ten projects starts two builds, then the next two. |
| Wait before a deploy starts | 10 seconds: after you confirm, you can still cancel. |
| Ask before a single deploy | On: a row's "Deploy" asks once more. |
| Warn when commits wait longer than | 7 days: a project with a week-old merge is flagged. |
| Watch the site after going live | 15 minutes: the site is checked every minute; two failures in a row warn, or roll back where the project does that itself. |
| Neutral notifications | On: a notification says "A deploy ended" without the project name, safe on a locked screen. |
| Ask for Touch ID before risky steps | On: deploying several projects at once, a rollback by hand and allowing auto-deploy ask for your fingerprint or password. The automatic rollback after a failed check does not wait. |

## Costs: goals and idle projects

| Option | Example |
| --- | --- |
| Weekly deploy goal | 10: "This week: 7 of 10" turns orange at the last deploy and red when over. 0 turns it off. Counted from Monday. |
| Idle projects | Lists projects with no deploy for 90 days, as candidates to pause. The same list in Terminal: `deploys idle`. |

## Budget

`deploys budget set 50` (or the Budget section) caps Vercel build spend at $50 a month: `deploy-changed --yes` stops before going over. Add `--strict` to stop when spending is unknown. See [CLI.md](CLI.md).

## Files behind the settings

The CLI keeps its own settings as files in `~/.config/deploys/`; [CLI.md](CLI.md#settings) lists them. For example `window.json` closes deploys on Friday afternoons ([SAFE-DEPLOY.md](SAFE-DEPLOY.md)). Settings are never sent anywhere.

Stuck? [TROUBLESHOOTING.md](TROUBLESHOOTING.md) has every error message word for word.
