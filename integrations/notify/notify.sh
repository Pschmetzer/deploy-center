#!/bin/bash
# notify.sh — post one daily summary ("live today / waiting") to one webhook. Deploys nothing.
#
#   DEPLOYS_NOTIFY_URL=… integrations/notify/notify.sh              read through `deploys`, post
#   integrations/notify/notify.sh --dry-run [list.json|-]            print what would be posted
#   DEPLOYS_NOTIFY_URL=… integrations/notify/notify.sh list.json     post from a saved list
#
# Env:
#   DEPLOYS_NOTIFY_URL     where to post. A secret (Telegram's carries the bot token): it goes to
#                          curl on stdin, never on the command line.
#   DEPLOYS_NOTIFY_FORMAT  discord | slack | ntfy | telegram. Default: guessed from the host,
#                          anything unknown is sent Slack-style ({"text":…}, also Mattermost etc.).
#   DEPLOYS                the CLI to call (default: deploys on PATH)
#
# "Today" is the UTC day. Telegram: put the chat in the URL,
#   https://api.telegram.org/bot<token>/sendMessage?chat_id=<chat>
set -euo pipefail
DEPLOYS="${DEPLOYS:-deploys}"
# shellcheck source=../lib/projects.sh
. "$(dirname "$0")/../lib/projects.sh"
dry=0; [ "${1:-}" = "--dry-run" ] && { dry=1; shift; }
from="${1:-}"
url="${DEPLOYS_NOTIFY_URL:-}"
[ "$dry" = 1 ] || [ -n "$url" ] || { echo "Set DEPLOYS_NOTIFY_URL (or use --dry-run)." >&2; exit 1; }

if [ -z "$from" ]; then
  list="$(all_projects)"
elif [ "$from" = - ]; then list="$(cat)"
else list="$(cat "$from")"
fi

text="$(echo "$list" | jq -r '
  (now | strftime("%Y-%m-%d")) as $today
  | map(select(.name)) as $all
  | ($all | map(select(((.liveAt // .lastAt // 0) | if . > 0 then strftime("%Y-%m-%d") else "" end) == $today)) | map(.name)) as $live
  | ($all | map(select(.changed)) | map(.name + (if .pendingCommits then " (\(.pendingCommits) commits)" else "" end))) as $wait
  | "Deploy Center, \($today) (UTC)",
    "Live today (\($live | length)): \(if ($live | length) > 0 then $live | join(", ") else "none" end)",
    "Waiting (\($wait | length)): \(if ($wait | length) > 0 then $wait | join(", ") else "none" end)"')"

format="${DEPLOYS_NOTIFY_FORMAT:-}"
if [ -z "$format" ]; then
  host="$(printf '%s' "$url" | sed -E 's#^[a-zA-Z]+://([^/:?]+).*#\1#')"
  case "$host" in
    discord.com|*.discord.com|discordapp.com|*.discordapp.com) format=discord ;;
    api.telegram.org) format=telegram ;;
    ntfy.sh|*.ntfy.sh|ntfy.*) format=ntfy ;;
    *) format=slack ;;
  esac
fi

case "$format" in
  discord)  body="$(jq -nc --arg t "$text" '{content:$t}')"; type="application/json" ;;
  slack)    body="$(jq -nc --arg t "$text" '{text:$t}')"; type="application/json" ;;
  telegram) body="$(jq -nc --arg t "$text" '{text:$t, disable_web_page_preview:true}')"; type="application/json" ;;
  ntfy)     body="$text"; type="text/plain; charset=utf-8" ;;
  *) echo "Unknown DEPLOYS_NOTIFY_FORMAT: $format (discord, slack, ntfy, telegram)" >&2; exit 1 ;;
esac

if [ "$dry" = 1 ]; then printf 'format: %s\n%s\n' "$format" "$body"; exit 0; fi

case "$url" in https://*|http://*) ;; *) echo "DEPLOYS_NOTIFY_URL must start with https://" >&2; exit 1 ;; esac
case "$url" in *'"'*|*'\'*|*$'\n'*) echo "DEPLOYS_NOTIFY_URL has characters a URL cannot have" >&2; exit 1 ;; esac
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
printf '%s' "$body" > "$tmp"
extra=()
[ "$format" = ntfy ] && extra=(-H "Title: Deploy Center")
# curl reads the URL from its config on stdin (-K -), so the token is not in the process list.
printf 'url = "%s"\n' "$url" \
  | curl -fsS -K - -X POST -H "Content-Type: $type" ${extra[@]+"${extra[@]}"} --data-binary "@$tmp" -o /dev/null
echo "Posted ($format)."
