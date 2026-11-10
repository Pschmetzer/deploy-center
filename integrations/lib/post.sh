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
  # http:// only to this machine (a local ntfy, a test server): elsewhere a token in the URL
  # (Telegram, Slack, Discord) would cross the network in clear text.
  case "$url" in
    https://*) ;;
    http://localhost|http://localhost[:/]*|http://127.0.0.1|http://127.0.0.1[:/]*|http://\[::1\]|http://\[::1\][:/]*) ;;
    *) echo "DEPLOYS_NOTIFY_URL must start with https:// (http:// only for localhost)" >&2; return 1 ;;
  esac
  case "$url" in *'"'*|*'\'*|*$'\n'*) echo "DEPLOYS_NOTIFY_URL has characters a URL cannot have" >&2; return 1 ;; esac
  f="$(mktemp)"
  printf '%s' "$WEBHOOK_BODY" > "$f"
  if [ "$format" = ntfy ]; then
    extra=(-H "Title: Deploy Center")
    [ -n "${WEBHOOK_LINK:-}" ] && extra+=(-H "Actions: view, ${WEBHOOK_LABEL//,/ }, ${WEBHOOK_LINK}")
  fi
  # curl reads the URL from its config on stdin (-K -), so the token is not in the process list.
  printf 'url = "%s"\n' "$url" \
    | curl -fsS -K - -X POST -H "Content-Type: $WEBHOOK_TYPE" ${extra[@]+"${extra[@]}"} --data-binary "@$f" -o /dev/null
  local rc=$?; rm -f "$f"; return "$rc"
}
