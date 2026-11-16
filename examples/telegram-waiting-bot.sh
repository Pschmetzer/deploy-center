#!/bin/bash
# telegram-waiting-bot.sh — a read-only Telegram bot: ask "/waiting" in a chat, get what is
# waiting to go live (deploys changed --json). It never deploys and has no command that could.
#
#   TELEGRAM_BOT_TOKEN=… DEPLOYS_BOT_CHATS=12345,-100678 examples/telegram-waiting-bot.sh
#   examples/telegram-waiting-bot.sh --reply '<update JSON>'   the answer to one update (for tests)
#
# Only chats in DEPLOYS_BOT_CHATS get an answer; every other message is ignored. In a group,
# every member of the chat could ask: DEPLOYS_BOT_USERS=111,222 (Telegram user ids) narrows it to
# those people. Commands:
# /waiting (what has commits that are not live), /failed (newest build failed), /help.
# Runs where `deploys` and its logins are (your Mac, a small server). Long polling: no webhook,
# no open port. The token goes to curl on stdin, never on the command line.
set -euo pipefail
DEPLOYS="${DEPLOYS:-deploys}"

# The reply to one Telegram update, or nothing. Pure apart from the deploys call.
reply_to() {
  local u="$1" chat text allowed
  chat="$(jq -r '.message.chat.id // empty' <<<"$u")"; text="$(jq -r '.message.text // empty' <<<"$u")"
  [ -n "$chat" ] && [ -n "$text" ] || return 0
  allowed="$(printf '%s' "${DEPLOYS_BOT_CHATS:-}" | tr ',' ' ' | tr -s ' ' '\n' | grep -cxF -- "$chat" || true)"
  [ "$allowed" -gt 0 ] || return 0
  if [ -n "${DEPLOYS_BOT_USERS:-}" ]; then
    local from
    from="$(jq -r '.message.from.id // empty' <<<"$u")"
    [ -n "$from" ] && [ "$(printf '%s' "$DEPLOYS_BOT_USERS" | tr ',' ' ' | tr -s ' ' '\n' | grep -cxF -- "$from" || true)" -gt 0 ] || return 0
  fi
  case "${text%%[ @]*}" in
    /waiting)
      "$DEPLOYS" changed --json </dev/null 2>/dev/null | jq -r 'if type != "array" then "Could not read the projects."
        elif length == 0 then "Nothing is waiting: every project is live."
        else "Waiting to go live (\(length)):\n" + (map("• \(.name) (\(.platform // "?")): \(if (.pendingCommits | type) == "number" then "\(.pendingCommits) commit(s)" else "changes" end)") | join("\n")) end' \
        || echo "Could not read the projects." ;;
    /failed)
      "$DEPLOYS" status --json --no-github </dev/null 2>/dev/null | jq -r 'if type != "array" then "Could not read the projects."
        else map(select((.state // "") | test("error|fail"; "i"))) | if length == 0 then "No newest build failed."
        else "Newest build failed (\(length)):\n" + (map("• \(.name) (\(.platform // "?")): \(.state)") | join("\n")) end end' \
        || echo "Could not read the projects." ;;
    /help|/start) echo "Read-only Deploy Center bot. /waiting: what is not live yet. /failed: failed builds. It never deploys." ;;
    *) return 0 ;;
  esac
}

if [ "${1:-}" = --reply ]; then reply_to "${2:?--reply needs an update}"; exit 0; fi

: "${TELEGRAM_BOT_TOKEN:?set TELEGRAM_BOT_TOKEN}"; : "${DEPLOYS_BOT_CHATS:?set DEPLOYS_BOT_CHATS (the chat ids that may ask)}"
case "$TELEGRAM_BOT_TOKEN" in *[!A-Za-z0-9:_-]*) echo "TELEGRAM_BOT_TOKEN has characters a token cannot have" >&2; exit 1 ;; esac
api() {  # api <method> [JSON body]: the URL (with the token) on curl's stdin
  printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$TELEGRAM_BOT_TOKEN" "$1" \
    | curl -fsS -K - --max-time 70 -H 'Content-Type: application/json' --data-binary "${2:-{\}}"
}
# The next update id is kept in a file: after a restart Telegram would otherwise send the
# unconfirmed updates of the last 24 hours again, and every one would be answered twice.
state="${DEPLOYS_BOT_STATE:-$HOME/.local/state/deploys-telegram-bot.offset}"
mkdir -p "$(dirname "$state")"
offset="$(cat "$state" 2>/dev/null || echo 0)"; case "$offset" in ''|*[!0-9]*) offset=0 ;; esac
while :; do
  updates="$(api getUpdates "$(jq -nc --argjson o "$offset" '{offset:$o, timeout:50, allowed_updates:["message"]}')")" || { sleep 10; continue; }
  while IFS= read -r u; do
    offset="$(( $(jq -r '.update_id' <<<"$u") + 1 ))"; printf '%s' "$offset" > "$state"
    r="$(reply_to "$u")"
    # Telegram refuses more than 4096 characters (HTTP 400): a longer answer is cut, with a note.
    r="$(jq -rn --arg t "$r" '$t | if length > 3900 then .[0:3900] + "\n… (cut, ask deploys changed for the rest)" else . end')"
    [ -n "$r" ] || continue
    api sendMessage "$(jq -nc --argjson c "$(jq '.message.chat.id' <<<"$u")" --arg t "$r" '{chat_id:$c, text:$t, disable_web_page_preview:true}')" >/dev/null || true
  done < <(jq -c '.result[]?' <<<"$updates")
done
