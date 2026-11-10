#!/bin/bash
# Sourced by notify and digest: one message to one webhook (Discord, Slack-style, ntfy, Telegram).
#
#   format="$(webhook_format "$url")"                 DEPLOYS_NOTIFY_FORMAT, or guessed from the host
#   webhook_body "$format" "$text" [url] [label]      sets $WEBHOOK_BODY and $WEBHOOK_TYPE; with a
#                                                     url, a link button (Slack, Telegram, ntfy) or a link line
#   webhook_send "$url" "$format"                     posts $WEBHOOK_BODY
#
# The webhook URL is a secret (Telegram's carries the bot token): it goes to curl on stdin, never
# on the command line.

webhook_format() {
  local host
  [ -n "${DEPLOYS_NOTIFY_FORMAT:-}" ] && { echo "$DEPLOYS_NOTIFY_FORMAT"; return; }
  host="$(printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://([^/:?]+).*#\1#')"
  case "$host" in
    discord.com|*.discord.com|discordapp.com|*.discordapp.com) echo discord ;;
    api.telegram.org) echo telegram ;;
    ntfy.sh|*.ntfy.sh|ntfy.*) echo ntfy ;;
    *) echo slack ;;
  esac
}

webhook_body() {
  local format="$1" text="$2" link="${3:-}" label="${4:-Open}"
  WEBHOOK_LINK="$link"; WEBHOOK_LABEL="$label"
  case "$format" in
    discord)  WEBHOOK_TYPE="application/json"
              WEBHOOK_BODY="$(jq -nc --arg t "$text" --arg u "$link" --arg l "$label" '{content:($t + (if $u != "" then "\n\($l): <\($u)>" else "" end))}')" ;;
    slack)    WEBHOOK_TYPE="application/json"
              # Block Kit for Slack; other Slack-style hooks (Mattermost, …) show text, which has the link too.
              WEBHOOK_BODY="$(jq -nc --arg t "$text" --arg u "$link" --arg l "$label" '
                ($t + (if $u != "" then "\n\($l): \($u)" else "" end)) as $full
                | {text:$full}
                + (if $u == "" then {} else {blocks:[
                    {type:"section", text:{type:"mrkdwn", text:($t | if length > 2900 then .[0:2900] + "…" else . end)}},
                    {type:"actions", elements:[{type:"button", style:"primary", text:{type:"plain_text", text:$l}, url:$u}]}]} end)')" ;;
    telegram) WEBHOOK_TYPE="application/json"
              WEBHOOK_BODY="$(jq -nc --arg t "$text" --arg u "$link" --arg l "$label" '{text:$t, disable_web_page_preview:true}
                + (if $u != "" then {reply_markup:{inline_keyboard:[[{text:$l, url:$u}]]}} else {} end)')" ;;
    ntfy)     WEBHOOK_TYPE="text/plain; charset=utf-8"; WEBHOOK_BODY="$text" ;;
    *) echo "Unknown DEPLOYS_NOTIFY_FORMAT: $format (discord, slack, ntfy, telegram)" >&2; return 1 ;;
  esac
}

webhook_send() {
  local url="$1" format="$2" f extra=()
  # https only: a Telegram URL carries the bot token, a webhook URL is a secret. Plain http only
  # for a local test server, with DEPLOYS_NOTIFY_ALLOW_HTTP=1.
  case "$url" in
    https://*) ;;
    http://localhost[:/]*|http://127.0.0.1[:/]*)
      [ "${DEPLOYS_NOTIFY_ALLOW_HTTP:-}" = 1 ] || { echo "DEPLOYS_NOTIFY_URL must start with https:// (http://localhost needs DEPLOYS_NOTIFY_ALLOW_HTTP=1)" >&2; return 1; } ;;
    *) echo "DEPLOYS_NOTIFY_URL must start with https://" >&2; return 1 ;;
  esac
  case "$url" in *'"'*|*'\'*|*$'\n'*) echo "DEPLOYS_NOTIFY_URL has characters a URL cannot have" >&2; return 1 ;; esac
  f="$(mktemp)" || return 1
  printf '%s' "$WEBHOOK_BODY" > "$f"
  if [ "$format" = ntfy ]; then
    extra=(-H "Title: Deploy Center")
    [ -n "${WEBHOOK_LINK:-}" ] && extra+=(-H "Actions: view, ${WEBHOOK_LABEL//,/ }, ${WEBHOOK_LINK}")
  fi
  # curl reads the URL from its config on stdin (-K -), so the token is not in the process list.
  # Bounded: a hanging webhook must not hold a cron job or workflow until its limit; 429 and 5xx
  # are retried a few times. `|| rc=$?` so a caller's set -e still reaches the rm.
  local rc=0
  printf 'url = "%s"\n' "$url" \
    | curl -fsS -K - --connect-timeout 5 --max-time 20 --retry 3 --retry-all-errors \
        -X POST -H "Content-Type: $WEBHOOK_TYPE" ${extra[@]+"${extra[@]}"} --data-binary "@$f" -o /dev/null || rc=$?
  rm -f "$f"; return "$rc"
}
