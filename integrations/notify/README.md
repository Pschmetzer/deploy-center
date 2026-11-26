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
integrations/notify/notify.sh list.json --dry-run                # options may stand before or after the list
integrations/notify/notify.sh --link https://status.example.com  # a button (or a link line) to your status page
```

**One deploy as a rich message.** `--event <event.json|->` posts one finished deploy instead of the daily
summary: Slack blocks (header, facts, a context line, a button), a Discord embed (colored by status, never
pings) or a Microsoft Teams Adaptive Card (facts and an `Action.OpenUrl` button); every other format gets the
same facts as text. The event is JSON, `project` and `status` are required:

```json
{"project": "web", "status": "failed", "platform": "vercel", "duration": 125, "commit": "abc1234", "url": "https://status.example.com/web"}
```

`status` is `live`, `failed`, `building` or `rolledback`; `duration` is in seconds ("2 min 05 s"); `url` (https
only) or `--link` becomes the button. A `live` or `failed` message carries a rollback hint: the commands to look
at first (`deploys history web`, then `deploys rollback web --yes`) and the line "This message rolls nothing
back." Nothing is rolled back or deployed by posting it. A failed event sets ntfy's priority to high. A bad
event (a name that is no project name, an unknown status, a link that is not https) is refused with a message.
`DEPLOYS_LANG=de` for German. `--dry-run` prints the body instead of posting.

**More than one target.** `DEPLOYS_NOTIFY_URLS` takes several URLs separated by commas (Slack and ntfy at
once); one that fails does not stop the others, and the exit code is 1 if any failed.
**Keep the URL out of a plist or crontab.** `DEPLOYS_NOTIFY_URL_FILE` names a file (`chmod 600`) whose first
line is the URL; a file that group or others can read is refused. **Rotate a signing secret without an
outage:** besides `DEPLOYS_NOTIFY_SECRET` set `DEPLOYS_NOTIFY_SECRET_PREV` (the old one) and
`DEPLOYS_NOTIFY_KEY_ID`: the post then carries `X-Deploy-Center-Signature` (new), `X-Deploy-Center-Signature-Previous`
(old) and `X-Deploy-Center-Key-Id`, and the receiver accepts either until the old secret is dropped.

The format is guessed from the host. To choose it yourself, set `DEPLOYS_NOTIFY_FORMAT`.

| Format | Host | Sent as |
|---|---|---|
| `discord` | discord.com | `{"content": …}`, with mentions off (`allowed_mentions`) |
| `telegram` | api.telegram.org | `{"text": …}`. Put the chat in the URL: `…/bot<token>/sendMessage?chat_id=<id>` |
| `ntfy` | ntfy.sh, ntfy.* | plain text |
| `teams` | *.webhook.office.com, *.logic.azure.com, Power Automate | An Adaptive Card. Make the URL in Teams with the workflow "Post to a channel when a webhook request is received". |
| `googlechat` | chat.googleapis.com | `{"text": …}`, the link as `<url\|label>` |
| `matrix` | (set `DEPLOYS_NOTIFY_FORMAT=matrix`) | `{"text": …, "username": …}` for a [matrix-hookshot](https://github.com/matrix-org/matrix-hookshot) generic webhook |
| `custom` | never guessed: set `DEPLOYS_NOTIFY_FORMAT=custom` | Your own body for PagerDuty, Opsgenie, Zulip, a Lambda: `DEPLOYS_NOTIFY_TEMPLATE` is a jq program whose input is `{text, url, label}` and whose output is the JSON body, e.g. `{summary: .text}`. |
| `pushover` | api.pushover.net | JSON with your keys from `DEPLOYS_PUSHOVER_TOKEN` (the app) and `DEPLOYS_PUSHOVER_USER`. URL: `https://api.pushover.net/1/messages.json` |
| `slack` | anything else | `{"text": …}`, with Block Kit blocks when there is a link. Slack and most compatible hooks. |
| `plain` | never guessed: set `DEPLOYS_NOTIFY_FORMAT=plain` | `{"text": …}` and nothing else, no blocks: for a self-hosted Mattermost, Rocket.Chat or Zulip-style hook that dislikes Slack's blocks. |

ntfy also takes `DEPLOYS_NOTIFY_PRIORITY` (`1`–`5`, or `min`, `low`, `default`, `high`, `urgent`),
`DEPLOYS_NOTIFY_TAGS` (`rocket,warning`) and `DEPLOYS_NOTIFY_TOKEN`, an access token for a protected
topic; the token goes to curl on stdin like the URL. For e-mail, use ntfy's or Pushover's e-mail
forwarding: the script sends no mail itself.

The URL goes to curl on stdin, so it never appears in the process list. It must be `https://` (`http://` only for localhost).
curl gives up after 20 seconds and retries a 429 or 5xx three times; a text over Discord's or
Telegram's limit is cut with a note. "Today" is the UTC day, or the day in `DEPLOYS_NOTIFY_TZ`
(for example `Europe/Berlin`), else in `DEPLOYS_TZ`, which the digest uses too. A zone name that
is not one is refused.

To send it every day, schedule the script with launchd or cron, or in CI with the Docker image.

Not tested yet: a real post to each service. The payloads are checked with `--dry-run` and with a
stand-in curl.
All add-ons at a glance: [what is tested](../README.md#what-is-tested-and-what-is-not).
## More settings

| Variable | Meaning |
| --- | --- |
| `DEPLOYS_NOTIFY_LINK` | the link of the "Open" button and line (same as `--link`): `https://` only, no quotes or spaces |
| `DEPLOYS_NOTIFY_ALLOW_HTTP_HOSTS` | comma-separated host names that may be reached over `http://` (a ntfy or Matrix server in your own network); `localhost` always may |

A rejected post prints the first line of the answer (Slack's `invalid_blocks`, a Discord JSON error), shortened and without anything that looks like a token. A zone name in `DEPLOYS_NOTIFY_TZ` that this machine does not know is refused instead of reading the clock as UTC. ntfy messages also carry a `Click` header: a tap opens the link.
