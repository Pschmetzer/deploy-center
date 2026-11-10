# Daily summary

The script posts one message to one webhook. It deploys nothing.

```
Deploy Center, 2026-11-10 (UTC)
Live today (1): site
Waiting (2): app-web (4 commits), api
Failed (1): api
```

"Failed" appears only when a newest build failed. Projects left out with `deploys ignore` do not
count as waiting. When `deploys` cannot be read at all, nothing is posted and the script exits 1,
so a broken setup never looks like "nothing waiting".

```bash
export DEPLOYS_NOTIFY_URL='https://hooks.slack.com/services/…'   # keep it secret
integrations/notify/notify.sh
integrations/notify/notify.sh --dry-run                          # print instead of posting
```

The format is guessed from the host. To choose it yourself, set `DEPLOYS_NOTIFY_FORMAT`.

| Format | Host | Sent as |
|---|---|---|
| `discord` | discord.com | `{"content": …}`, with mentions off (`allowed_mentions`) |
| `telegram` | api.telegram.org | `{"text": …}`. Put the chat in the URL: `…/bot<token>/sendMessage?chat_id=<id>` |
| `ntfy` | ntfy.sh, ntfy.* | plain text |
| `slack` | anything else | `{"text": …}`. Slack, Mattermost, Rocket.Chat and other compatible hooks. |

The URL goes to curl on stdin, so it never appears in the process list. It must be `https://`.
curl gives up after 20 seconds and retries a 429 or 5xx three times; a text over Discord's or
Telegram's limit is cut with a note. "Today" is the UTC day, or the day in `DEPLOYS_NOTIFY_TZ`
(for example `Europe/Berlin`).
To send it every day, schedule the script with launchd or cron, or in CI with the Docker image.

Not tested yet: a real post to each service. The payloads are checked with `--dry-run` and with a
stand-in curl.
All add-ons at a glance: [what is tested](../README.md#what-is-tested-and-what-is-not).