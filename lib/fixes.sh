# shellcheck shell=bash
# lib/fixes.sh — `deploys doctor --fix`: what to do about each problem doctor finds, as text.
#
# It only shows. It runs nothing and changes nothing: every suggestion is a command for you to read and
# type yourself. Sourced by deploys; uses CONFIG_DIR, WINDOW, WINDOW_LINT and json from there.

# fixes_from <doctor json>: [{problem, command}] from what doctor knows (the same facts as doctor --text).
fixes_from() {
  jq -c '
    [ (if .jq != true then {problem:"jq is missing", command:"brew install jq"} else empty end),
      (if .githubCli != true then {problem:"gh (GitHub CLI) is missing", command:"brew install gh"} else empty end),
      (if .githubCli == true and .githubLoggedIn != true then {problem:"gh is not logged in", command:"gh auth login"} else empty end),
      (if .perl != true then {problem:"perl is missing (masking and time limits need it)", command:"install perl"} else empty end),
      (if .curl != true then {problem:"curl is missing", command:"install curl"} else empty end),
      (if .configWritable != true then {problem:"the settings folder is not writable", command:"chmod u+w the folder in DEPLOYS_CONFIG (default ~/.config/deploys)"} else empty end),
      ((.jobsMissing // [])[] | {problem:"the scheduled job \"\(.)\" lost a tool on its PATH", command:"deploys \(split(":")[0]) schedule on"}),
      ((.providers // {}) | to_entries[]
        | select((.value.tokenOk == false) or (.value.error != null and (.value.error | type) == "string" and .value.error != ""))
        | {problem:"\(.key): \(if .value.error then (.value.error | tostring | .[0:100]) else "the key does not work" end)", command:"deploys \(.key) set-key"}),
      (if .readonly == true then {problem:"observer mode is on: commands that change something are refused", command:"deploys readonly off"} else empty end)
    ]' 2>/dev/null <<<"$1" || echo '[]'
}

# fixes_window: lines of window.json that would not do what they say, as fixes.
fixes_window() {
  [ -f "$WINDOW" ] || { echo '[]'; return 0; }
  jq -R -s -c 'split("\n") | map(select(. != "")) | map({problem:("window.json: " + .), command:"deploys freeze   (shows the rules; deploys freeze remove <n> or edit the file)"})' \
    < <(jq -r "$WINDOW_LINT" "$WINDOW" 2>/dev/null || true) 2>/dev/null || echo '[]'
}

# fixes_print: stdin [{problem, command}]; text for a person. With --json the object {changed:false, fixes:[...]}.
fixes_print() {
  jq -r 'if length == 0 then "Nothing to fix."
    else "Suggestions (shown only: nothing was run or changed):",
         (to_entries[] | "  \(.key + 1). \(.value.problem)\n     try: \(.value.command)") end'
}

fixes_main() {  # fixes_main <doctor json>
  local all; all="$(jq -c -s 'add' <(fixes_from "$1") <(fixes_window))" || all='[]'
  if [ "${json:-0}" = 1 ]; then jq -c '{changed:false, fixes:.}' <<<"$all" | jq .; else fixes_print <<<"$all"; fi
}
