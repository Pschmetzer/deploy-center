# Daily summary

The script posts one message to one webhook. It deploys nothing.

```
Deploy Center, 2026-11-10 (UTC)
Live today (1): site
Waiting (2): app-web (4 commits), api
```

```bash
export DEPLOYS_NOTIFY_URL='https://hooks.slack.com/services/…'   # keep it secret
integrations/notify/notify.sh
integrations/notify/notify.sh --dry-run                          # print instead of posting
```

The format is guessed from the host. To choose it yourself, set `DEPLOYS_NOTIFY_FORMAT`.

| Format | Host | Sent as |
|---|---|---|
| `discord` | discord.com | `{"content": …}` |
| `telegram` | api.telegram.org | `{"text": …}`. Put the chat in the URL: `…/bot<token>/sendMessage?chat_id=<id>` |
| `ntfy` | ntfy.sh, ntfy.* | plain text |
| `slack` | anything else | `{"text": …}`. Slack, Mattermost, Rocket.Chat and other compatible hooks. |

The URL goes to curl on stdin, so it never appears in the process list. "Today" is the UTC day.
To send it every day, schedule the script with launchd or cron, or in CI with the Docker image.

Not tested yet: a real post to each service. The payloads are checked with `--dry-run` and with a
stand-in curl.
