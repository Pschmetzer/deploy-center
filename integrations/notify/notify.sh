#!/bin/bash
# notify.sh — post one daily summary ("live today / waiting") to one webhook. Deploys nothing.
#
#   DEPLOYS_NOTIFY_URL=… integrations/notify/notify.sh              read through `deploys`, post
#   integrations/notify/notify.sh --dry-run [list.json|-]            print what would be posted
#   DEPLOYS_NOTIFY_URL=… integrations/notify/notify.sh list.json     post from a saved list
#
# Options may stand before or after the list: `notify.sh list.json --dry-run` is a dry run too.
#   --dry-run  --quiet-when-empty  --link <url>   (--link: a button or link line, e.g. the status page)
#
# Env:
#   DEPLOYS_NOTIFY_URL     where to post. A secret (Telegram's carries the bot token): it goes to
#                          curl on stdin, never on the command line.
#   DEPLOYS_NOTIFY_URLS    more targets, comma-separated (Slack and ntfy at once). One that fails does not
#                          stop the others; the exit code is 1 if any failed.
#   DEPLOYS_NOTIFY_URL_FILE a file (chmod 600) whose first line is the URL, for launchd and cron: the
#                          secret stays out of a plist or crontab.
#   DEPLOYS_NOTIFY_LINK    the same as --link.
#   DEPLOYS_NOTIFY_FORMAT  discord | slack | ntfy | telegram | teams | googlechat | matrix | pushover |
#                          plain ({"text":…} only, for Mattermost, Rocket.Chat, Zulip-style hooks) |
#                          custom (your own jq program in DEPLOYS_NOTIFY_TEMPLATE). Default: guessed from
#                          the host, anything unknown is sent Slack-style (with blocks when there is a link).
#   DEPLOYS                the CLI to call (default: deploys on PATH)
#   DEPLOYS_NOTIFY_TZ      the time zone of "today", e.g. Europe/Berlin. Default: DEPLOYS_TZ
#                          (shared with the digest), else UTC.
#   DEPLOYS_LANG           en (default) or de: the language of the message.
#   --quiet-when-empty     post nothing when no project went live, waits or failed (for cron).
# A failed build sets ntfy's priority to high with the tag rotating_light, unless you set
# DEPLOYS_NOTIFY_PRIORITY or DEPLOYS_NOTIFY_TAGS yourself.
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
dry=0 quiet=0 from="" link="${DEPLOYS_NOTIFY_LINK:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --quiet-when-empty) quiet=1 ;;
    --link) link="${2:?--link <url>}"; shift ;;
    -) from=- ;;
    -*) echo "Unknown option $1 (--dry-run, --quiet-when-empty, --link <url>)" >&2; exit 1 ;;
    *) [ -z "$from" ] || { echo "Only one list file, got $from and $1" >&2; exit 1; }; from="$1" ;;
  esac
  shift
done
lang="${DEPLOYS_LANG:-en}"; case "$lang" in en|de) ;; *) echo "DEPLOYS_LANG must be en or de" >&2; exit 1 ;; esac
urls="$(webhook_urls)" || exit 1
[ "$dry" = 1 ] || [ -n "$urls" ] || { echo "Set DEPLOYS_NOTIFY_URL, DEPLOYS_NOTIFY_URLS or DEPLOYS_NOTIFY_URL_FILE (or use --dry-run)." >&2; exit 1; }
export WEBHOOK_CUT_HINT="see deploys changed"

chg=null
if [ -z "$from" ]; then
  list="$(all_projects)"
  # What waits is what `deploys changed` says (its ignore rules, the team's list and overrides),
  # not a copy of those rules here. A saved list has no such answer: then ignored.json is used.
  chg="$(changed_projects | jq -c 'map(.name)')"
elif [ "$from" = - ]; then list="$(cat)"
else list="$(cat "$from")"
fi

res="$(echo "$list" | TZ="$tz" jq -c --argjson ign "$(ignored_names)" --argjson chg "$chg" --arg lang "$lang" --arg tz "$tz" '
  # A name on two platforms is shown as platform:name, so "web" is one project, not two.
  def lbl($twice): if (.name as $n | $twice | index($n)) and .platform then "\(.platform):\(.name)" else .name end;
  (now | strflocaltime("%Y-%m-%d")) as $today
  | map(select(.name)) as $all
  | ($all | map(.name) | group_by(.) | map(select(length > 1) | .[0])) as $twice
  # Live today: the commit that went live (liveAt), or the last attempt when it did not fail
  # (a platform without liveAt must not count a failed attempt as live).
  | ($all | map(select(((.liveAt // (if ((.lastState // "") | ascii_downcase | test("fail|error")) or (.phase // "") == "failed" then 0 else .lastAt end) // 0)
        | if . > 0 then strflocaltime("%Y-%m-%d") else "" end) == $today)) | map(lbl($twice))) as $live
  # The newest build failed (Render: an older one may still be live).
  | ($all | map(select(((.lastState // "") | ascii_downcase | test("fail|error")) or (.phase // "") == "failed")) | map(lbl($twice))) as $failed
  | ($all | map(select(.changed and ((.name as $n | $ign | index($n)) | not) and (if $chg == null then true else (.name as $n | $chg | index($n)) != null end)))
      | map(lbl($twice) + (if .pendingCommits then " (\(.pendingCommits) \(if $lang == "de" then "Commits" else "commits" end))" else "" end))) as $wait
  | (if $lang == "de" then {live: "Heute live", wait: "Wartend", fail: "Fehlgeschlagen", none: "keine"} else {live: "Live today", wait: "Waiting", fail: "Failed", none: "none"} end) as $t
  | {failed: ($failed | length), live: ($live | length), wait: ($wait | length),
     text: ([ "Deploy Center, \($today) (\($tz))",
    "\($t.live) (\($live | length)): \(if ($live | length) > 0 then $live | join(", ") else $t.none end)",
    "\($t.wait) (\($wait | length)): \(if ($wait | length) > 0 then $wait | join(", ") else $t.none end)",
    (if ($failed | length) > 0 then "\($t.fail) (\($failed | length)): \($failed | join(", "))" else empty end) ] | join("\n"))}')"
# From the data, not from the finished text: a changed wording cannot turn the priority off.
text="$(jq -r '.text' <<<"$res")"
failed_any=0; [ "$(jq '.failed' <<<"$res")" = 0 ] || failed_any=1
if [ "$quiet" = 1 ] && [ "$failed_any" = 0 ] && [ "$(jq '.live + .wait' <<<"$res")" = 0 ]; then
  echo "Nothing to report; nothing posted."; exit 0
fi
if [ "$failed_any" = 1 ]; then
  export DEPLOYS_NOTIFY_PRIORITY="${DEPLOYS_NOTIFY_PRIORITY:-high}" DEPLOYS_NOTIFY_TAGS="${DEPLOYS_NOTIFY_TAGS:-rotating_light}"
fi

rc=0
if [ -z "$urls" ]; then   # a dry run without a URL: the format comes from DEPLOYS_NOTIFY_FORMAT or the Slack default
  format="$(webhook_format "")"
  webhook_body "$format" "$text" "$link" "Open"
  printf 'format: %s\n%s\n' "$format" "$WEBHOOK_BODY"; exit 0
fi
while IFS= read -r url; do
  [ -n "$url" ] || continue
  format="$(webhook_format "$url")"
  webhook_body "$format" "$text" "$link" "Open" || { rc=1; continue; }
  if [ "$dry" = 1 ]; then printf 'format: %s\n%s\n' "$format" "$WEBHOOK_BODY"; continue; fi
  # webhook_send and curl say why on stderr; one target failing does not stop the next.
  if webhook_send "$url" "$format"; then echo "Posted ($format)."; else rc=1; fi
done <<<"$urls"
exit "$rc"
