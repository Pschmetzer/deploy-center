#!/bin/bash
# deploys backup and deploys restore (lib/x-backup.sh).
. "$(dirname "$0")/lib.sh"
C="$DEPLOYS_CONFIG"; rm -f "$C/providers.json"
printf '{"deny":[{"days":["fri"],"from":"15:00"}]}' > "$C/window.json"
printf '{"monthlyUsd":50}' > "$C/budget.json"
printf '{"x":' > "$C/rules.json"
printf '{"token":"ghp_abcdefghijklmnopqrstuvwxyz0123456789ABCD"}' > "$C/prices.json"
printf '{"web":{"until":"2099-01-01"}}' > "$C/autodeploy-allow.json"
printf 'line\n' > "$tmp/journal.jsonl"
b="$(cli backup)"
expect "backup: window and budget go in" "$(jq -c '.files | keys' <<<"$b")" '["budget.json","window.json"]'
expect "backup: the invalid file and the secret are named" "$(jq -c '[.skipped[] | .file]' <<<"$b" | jq -c 'sort')" '["prices.json","rules.json"]'
case "$b" in *ghp_*) fail "backup: no secret in the output" "found" ;; *) ok "backup: no secret in the output" ;; esac
case "$b" in *autodeploy*|*journal*) fail "backup: allowances and journal stay out" "found" ;; *) ok "backup: allowances and journal stay out" ;; esac
has "backup: --out writes and says what was left out" "$(cli backup --out "$tmp/b.json")" "2 settings files, left out: "
expect "backup: the file is private" "$(stat -c %a "$tmp/b.json" 2>/dev/null || stat -f %Lp "$tmp/b.json")" "600"
# restore into a fresh config
rm -f "$C/window.json" "$C/budget.json"; printf '{"monthlyUsd":10}' > "$C/budget.json"
out="$(cli restore "$tmp/b.json")"
has "restore: window is new" "$out" "new      window.json"
has "restore: budget changed" "$out" "changed  budget.json"
has "restore: nothing written without --yes" "$out" "2 files would change. Nothing was written"
[ ! -f "$C/window.json" ] && ok "restore: window.json still absent" || fail "restore: dry run" "wrote"
out="$(cli restore "$tmp/b.json" --yes)"
has "restore: --yes says what it did" "$out" "Restored 2 files."
expect "restore: budget is back" "$(jq -c . "$C/budget.json")" '{"monthlyUsd":50}'
expect "restore: window is back" "$(jq -c '.deny | length' "$C/window.json")" "1"
expect "restore: the old budget was kept" "$(jq -c . "$C"/restore-backup-*/budget.json)" '{"monthlyUsd":10}'
has "restore: a second run is all same" "$(cli restore "$tmp/b.json")" "0 files would change"
# refusals
printf '{"deployCenterBackup":1,"files":{"../evil.json":{}}}' > "$tmp/bad.json"
cli restore "$tmp/bad.json" --yes >/dev/null 2>&1; expect "restore: a path outside is refused" "$?" "1"
printf '{"deployCenterBackup":1,"files":{"autodeploy-allow.json":{}}}' > "$tmp/bad2.json"
cli restore "$tmp/bad2.json" --yes >/dev/null 2>&1; expect "restore: allowances are not restored" "$?" "1"
printf 'nope' > "$tmp/bad3.json"; cli restore "$tmp/bad3.json" >/dev/null 2>&1; expect "restore: not a backup" "$?" "1"
cli restore "$tmp/b.json" --bad >/dev/null 2>&1; expect "restore: unknown option exits 2" "$?" "2"
rm -f "$C/window.json"; DEPLOYS_READONLY=1 cli restore "$tmp/b.json" --yes >/dev/null 2>&1; expect "restore: observer mode refuses --yes" "$?" "1"
[ ! -f "$C/window.json" ] && ok "restore: and writes nothing" || fail "restore: observer" "wrote"
exit "$fails"
