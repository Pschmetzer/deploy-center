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
#   DEPLOYS_NOTIFY_TZ      the time zone of "today", e.g. Europe/Berlin. Default: DEPLOYS_TZ
#                          (shared with the digest), else UTC.
#
# "Today" is the day in that zone, so a deploy just after local midnight is not counted on the
# day before. Telegram: put the chat in the URL,
#   https://api.telegram.org/bot<token>/sendMessage?chat_id=<chat>
set -euo pipefail
DEPLOYS="${DEPLOYS:-deploys}"
# shellcheck source=../lib/projects.sh
. "$(dirname "$0")/../lib/projects.sh"
# shellcheck source=../lib/post.sh
. "$(dirname "$0")/../lib/post.sh"
tz="${DEPLOYS_NOTIFY_TZ:-${DEPLOYS_TZ:-UTC}}"
[[ "$tz" =~ ^[A-Za-z0-9/_+-]+$ ]] || { echo "DEPLOYS_NOTIFY_TZ / DEPLOYS_TZ must be a zone name like Europe/Berlin" >&2; exit 1; }
dry=0; [ "${1:-}" = "--dry-run" ] && { dry=1; shift; }
from="${1:-}"
url="${DEPLOYS_NOTIFY_URL:-}"
[ "$dry" = 1 ] || [ -n "$url" ] || { echo "Set DEPLOYS_NOTIFY_URL (or use --dry-run)." >&2; exit 1; }

if [ -z "$from" ]; then
  list="$(all_projects)"
elif [ "$from" = - ]; then list="$(cat)"
else list="$(cat "$from")"
fi

text="$(echo "$list" | TZ="$tz" jq -r --argjson ign "$(ignored_names)" --arg tz "$tz" '
  (now | strflocaltime("%Y-%m-%d")) as $today
  | map(select(.name)) as $all
  | ($all | map(select(((.liveAt // .lastAt // 0) | if . > 0 then strflocaltime("%Y-%m-%d") else "" end) == $today)) | map(.name)) as $live
  # The newest build failed (Render: an older one may still be live).
  | ($all | map(select(((.lastState // "") | ascii_downcase | test("fail|error")) or (.phase // "") == "failed")) | map(.name)) as $failed
  | ($all | map(select(.changed and ((.name as $n | $ign | index($n)) | not))) | map(.name + (if .pendingCommits then " (\(.pendingCommits) commits)" else "" end))) as $wait
  | "Deploy Center, \($today) (\($tz))",
    "Live today (\($live | length)): \(if ($live | length) > 0 then $live | join(", ") else "none" end)",
    "Waiting (\($wait | length)): \(if ($wait | length) > 0 then $wait | join(", ") else "none" end)",
    (if ($failed | length) > 0 then "Failed (\($failed | length)): \($failed | join(", "))" else empty end)')"

format="$(webhook_format "$url")"
webhook_body "$format" "$text"

if [ "$dry" = 1 ]; then printf 'format: %s\n%s\n' "$format" "$WEBHOOK_BODY"; exit 0; fi

webhook_send "$url" "$format"
echo "Posted ($format)."
