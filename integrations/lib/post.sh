#!/bin/bash
# Sourced by notify and digest: one message to one webhook (Discord, Slack-style, ntfy, Telegram,
# Microsoft Teams, Google Chat, Matrix hookshot, Pushover).
#
#   format="$(webhook_format "$url")"                 DEPLOYS_NOTIFY_FORMAT, or guessed from the host
#   webhook_body "$format" "$text" [url] [label]      sets $WEBHOOK_BODY and $WEBHOOK_TYPE; with a
#                                                     url, a link button (Slack, Telegram, ntfy) or a link line
#   webhook_send "$url" "$format"                     posts $WEBHOOK_BODY
#
# The webhook URL is a secret (Telegram's carries the bot token): it goes to curl on stdin, never
# on the command line. So does an ntfy access token (DEPLOYS_NOTIFY_TOKEN).
#
# custom:   DEPLOYS_NOTIFY_FORMAT=custom and DEPLOYS_NOTIFY_TEMPLATE='{summary: .text, link: .url}' (jq; input {text, url, label})
# ntfy:     DEPLOYS_NOTIFY_PRIORITY (1-5 or min, low, default, high, urgent), DEPLOYS_NOTIFY_TAGS (a,b),
#           DEPLOYS_NOTIFY_TOKEN (a protected topic)
# Pushover: DEPLOYS_PUSHOVER_TOKEN (the app) and DEPLOYS_PUSHOVER_USER (you); the URL is
#           https://api.pushover.net/1/messages.json

webhook_format() {
  local host
  [ -n "${DEPLOYS_NOTIFY_FORMAT:-}" ] && { echo "$DEPLOYS_NOTIFY_FORMAT"; return; }
  host="$(printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://([^/:?]+).*#\1#')"
  case "$host" in
    discord.com|*.discord.com|discordapp.com|*.discordapp.com) echo discord ;;
    api.telegram.org) echo telegram ;;
    ntfy.sh|*.ntfy.sh|ntfy.*) echo ntfy ;;
    *.webhook.office.com|*.logic.azure.com|*.powerplatform.com|*.powerautomate.com) echo teams ;;
    chat.googleapis.com) echo googlechat ;;
    api.pushover.net) echo pushover ;;
    *) echo slack ;;
  esac
}

# Discord takes 2000 characters, Telegram 4096: a longer text is cut, with a note, instead of
# the whole message being refused (HTTP 400).
cut_text() { jq -rn --arg t "$1" --argjson n "$2" '$t | if length > $n then .[0:$n] + "\n… (cut, see the full list in the issue or with deploys changed)" else . end'; }

webhook_body() {
  local format="$1" text="$2" link="${3:-}" label="${4:-Open}"
  WEBHOOK_LINK="$link"; WEBHOOK_LABEL="$label"
  case "$format" in
    discord)  text="$(cut_text "$text" 1800)" ;;
    telegram) text="$(cut_text "$text" 3900)" ;;
    pushover) text="$(cut_text "$text" 1000)" ;;
    googlechat) text="$(cut_text "$text" 4000)" ;;
  esac
  case "$format" in
    discord)  WEBHOOK_TYPE="application/json"
              WEBHOOK_BODY="$(jq -nc --arg t "$text" --arg u "$link" --arg l "$label" '{content:($t + (if $u != "" then "\n\($l): <\($u)>" else "" end)), allowed_mentions:{parse:[]}}')" ;;
    slack)    WEBHOOK_TYPE="application/json"
              # Slack reads <!channel>, <@U123> and <https://x|text> in any text: & < > are escaped
              # (Slack's own rule), so a project name or PR title cannot ping a channel or fake a link.
              text="$(jq -rn --arg t "$text" '$t | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")')"
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
    teams)    WEBHOOK_TYPE="application/json"
              # A Teams workflow ("Post to a channel when a webhook request is received") takes an
              # Adaptive Card; the link is a button.
              WEBHOOK_BODY="$(jq -nc --arg t "$text" --arg u "$link" --arg l "$label" '{type:"message", attachments:[{
                contentType:"application/vnd.microsoft.card.adaptive", contentUrl:null, content:({
                  "$schema":"http://adaptivecards.io/schemas/adaptive-card.json", type:"AdaptiveCard", version:"1.4",
                  body:[{type:"TextBlock", text:$t, wrap:true}]}
                  + (if $u != "" then {actions:[{type:"Action.OpenUrl", title:$l, url:$u}]} else {} end))}]}')" ;;
    googlechat) WEBHOOK_TYPE="application/json; charset=utf-8"
              WEBHOOK_BODY="$(jq -nc --arg t "$text" --arg u "$link" --arg l "$label" '{text:($t + (if $u != "" then "\n<\($u)|\($l)>" else "" end))}')" ;;
    matrix)   WEBHOOK_TYPE="application/json"
              # A matrix-hookshot generic webhook: text, plus html for clients that show it.
              WEBHOOK_BODY="$(jq -nc --arg t "$text" --arg u "$link" --arg l "$label" '{text:($t + (if $u != "" then "\n\($l): \($u)" else "" end)), username:"Deploy Center"}')" ;;
    pushover) WEBHOOK_TYPE="application/json"
              [ -n "${DEPLOYS_PUSHOVER_TOKEN:-}" ] && [ -n "${DEPLOYS_PUSHOVER_USER:-}" ] \
                || { echo "Pushover needs DEPLOYS_PUSHOVER_TOKEN and DEPLOYS_PUSHOVER_USER" >&2; return 1; }
              # The keys are added in webhook_send, so a dry run never prints them.
              WEBHOOK_BODY="$(jq -nc --arg t "$text" --arg u "$link" --arg l "$label" \
                '{title:"Deploy Center", message:$t} + (if $u != "" then {url:$u, url_title:$l} else {} end)')" ;;
    custom)   WEBHOOK_TYPE="application/json"
              # Your own body for PagerDuty, Opsgenie, Zulip, Mattermost attachments or a Lambda:
              # DEPLOYS_NOTIFY_TEMPLATE is a jq program. Its input is {text, url, label}; what it prints is the body.
              [ -n "${DEPLOYS_NOTIFY_TEMPLATE:-}" ] \
                || { echo "DEPLOYS_NOTIFY_FORMAT=custom needs DEPLOYS_NOTIFY_TEMPLATE (a jq program: input {text, url, label}, output the JSON body)" >&2; return 1; }
              WEBHOOK_BODY="$(jq -nc --arg t "$text" --arg u "$link" --arg l "$label" "{text:\$t, url:\$u, label:\$l} | ${DEPLOYS_NOTIFY_TEMPLATE}")" \
                || { echo "DEPLOYS_NOTIFY_TEMPLATE is not a valid jq program, or it failed on {text, url, label}" >&2; return 1; }
              [ -n "$WEBHOOK_BODY" ] || { echo "DEPLOYS_NOTIFY_TEMPLATE printed nothing" >&2; return 1; } ;;
    *) echo "Unknown DEPLOYS_NOTIFY_FORMAT: $format (discord, slack, ntfy, telegram, teams, googlechat, matrix, pushover, custom)" >&2; return 1 ;;
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
  f="$(mktemp)" || return 1
  if [ "$format" = pushover ]; then
    jq -c --arg k "${DEPLOYS_PUSHOVER_TOKEN:-}" --arg us "${DEPLOYS_PUSHOVER_USER:-}" '{token:$k, user:$us} + .' <<<"$WEBHOOK_BODY" > "$f"
  else printf '%s' "$WEBHOOK_BODY" > "$f"; fi
  local secret_header=""
  if [ "$format" = ntfy ]; then
    extra=(-H "Title: Deploy Center")
    # The Actions header is "view, label, url" separated by , and ;: a , or ; in the label becomes a
    # space, in the URL it is percent-encoded, or the action would silently be dropped.
    if [ -n "${WEBHOOK_LINK:-}" ]; then
      ntfy_label="${WEBHOOK_LABEL//[,;]/ }"; ntfy_url="${WEBHOOK_LINK//,/%2C}"; ntfy_url="${ntfy_url//;/%3B}"
      extra+=(-H "Actions: view, ${ntfy_label}, ${ntfy_url}")
    fi
    if [ -n "${DEPLOYS_NOTIFY_PRIORITY:-}" ]; then
      case "$DEPLOYS_NOTIFY_PRIORITY" in [1-5]|min|low|default|high|max|urgent) extra+=(-H "Priority: $DEPLOYS_NOTIFY_PRIORITY") ;;
        *) rm -f "$f"; echo "DEPLOYS_NOTIFY_PRIORITY must be 1-5 or min, low, default, high, urgent" >&2; return 1 ;; esac
    fi
    if [ -n "${DEPLOYS_NOTIFY_TAGS:-}" ]; then
      case "$DEPLOYS_NOTIFY_TAGS" in *[!A-Za-z0-9_,-]*) rm -f "$f"; echo "DEPLOYS_NOTIFY_TAGS: letters, digits, _ and - separated by commas" >&2; return 1 ;; esac
      extra+=(-H "Tags: $DEPLOYS_NOTIFY_TAGS")
    fi
    if [ -n "${DEPLOYS_NOTIFY_TOKEN:-}" ]; then
      case "$DEPLOYS_NOTIFY_TOKEN" in *[!A-Za-z0-9_.-]*) rm -f "$f"; echo "DEPLOYS_NOTIFY_TOKEN has characters a token cannot have" >&2; return 1 ;; esac
      # On stdin with the URL, not as -H: the token stays out of the process list.
      secret_header="$(printf 'header = "Authorization: Bearer %s"\n' "$DEPLOYS_NOTIFY_TOKEN")"
    fi
  fi
  # An optional signature for receivers of your own (n8n, a Lambda, a Worker): HMAC-SHA256 over
  # "<timestamp>.<body>" with DEPLOYS_NOTIFY_SECRET, in X-Deploy-Center-Signature, with the time in
  # X-Deploy-Center-Timestamp (reject old ones to stop replays). The secret goes to perl through
  # the environment, never through argv; the headers go to curl on stdin, like the token.
  local sig_headers=""
  if [ -n "${DEPLOYS_NOTIFY_SECRET:-}" ]; then
    local ts sig
    ts="$(date -u +%s)"
    sig="$(DC_SECRET="$DEPLOYS_NOTIFY_SECRET" DC_TS="$ts" perl -MDigest::SHA=hmac_sha256_hex -e 'local $/; my $b = <STDIN>; print hmac_sha256_hex("$ENV{DC_TS}.$b", $ENV{DC_SECRET})' < "$f")" \
      || { rm -f "$f"; echo "DEPLOYS_NOTIFY_SECRET: could not sign (perl with Digest::SHA is needed)" >&2; return 1; }
    sig_headers="$(printf 'header = "X-Deploy-Center-Timestamp: %s"\nheader = "X-Deploy-Center-Signature: sha256=%s"' "$ts" "$sig")"
  fi
  # curl reads the URL from its config on stdin (-K -), so the token is not in the process list.
  # Bounded: a hanging webhook must not hold a cron job or workflow until its limit; 408, 429 and 5xx
  # are retried a few times (not --retry-all-errors: a POST that was delivered and then timed out would be sent twice). `|| rc=$?` so a caller's set -e still reaches the rm.
  local rc=0
  { printf 'url = "%s"\n' "$url"; [ -z "$secret_header" ] || printf '%s\n' "$secret_header"; [ -z "$sig_headers" ] || printf '%s\n' "$sig_headers"; } \
    | curl -fsS -K - --connect-timeout 5 --max-time 20 --retry 3 \
        -X POST -H "Content-Type: $WEBHOOK_TYPE" ${extra[@]+"${extra[@]}"} --data-binary "@$f" -o /dev/null || rc=$?
  rm -f "$f"; return "$rc"
}
