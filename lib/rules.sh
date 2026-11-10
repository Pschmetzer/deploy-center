# shellcheck shell=bash
# lib/rules.sh — "when … then …" rules for the daily deploy, from rules.json in the config folder
# (the app's rule editor writes it; by hand works too):
#   {"rules":[{"name":"docs only", "enabled":true,
#              "when":{"projects":["vercel/web"], "ciGreen":true, "paths":["docs/**","*.md"],
#                      "onlyPaths":true, "labels":["ship"], "minAgeHours":4},
#              "then":"deploy" | "hold" | "notify"}]}
# Every condition given must hold; one left out holds. The first enabled rule that matches a
# project decides for it:
#   hold    deploy-changed (and plan) leave the project out, and say which rule held it
#   deploy  deploy-changed --by-rules starts it (the deploy window still counts)
#   notify  named in rules check and plan; deploy-changed treats it as without a rule
# A deploy rule without any condition is ignored (it would deploy everything). Unknown keys are
# kept and ignored. Conditions:
#   projects     "<platform>/<name>" (a * matches any part)
#   ciGreen      true: the waiting head commit's CI is green (or has no checks)
#   paths        globs (** any folders, * within one, a pattern without / matches the file name)
#   onlyPaths    true: every changed file matches paths; false or left out: at least one does
#   labels       a pull request of the head commit has one of these labels
#   minAgeHours  the oldest waiting commit is at least this many hours old
# Sourced by deploys; uses ci_of, gh, cat_all from there.

RULES="$CONFIG_DIR/rules.json"

rules_on() { [ -f "$RULES" ] && jq -e '[.rules[]? | select(.enabled != false)] | length > 0' "$RULES" >/dev/null 2>&1; }

# The enabled rules, numbered, with what each needs asked: [{index, name, when, then, needs, problem}].
rules_list() {
  jq -c '[(.rules // []) | to_entries[] | .key as $i | .value | select(.enabled != false)
    | (.when // {}) as $w | (.then // "deploy") as $t
    | {index:$i, name:(.name // "rule \($i + 1)"), when:$w, then:$t,
       problem:(if (["deploy","hold","notify"] | index($t)) == null then "unknown action \"\($t)\""
                elif $t == "deploy" and ([$w | to_entries[] | select(.value != null and .value != [] and .value != false and .key != "onlyPaths")] | length) == 0
                  then "a deploy rule without a condition is ignored" else null end)}]' "$RULES" 2>/dev/null \
    || die "$RULES could not be read (see docs/CLI.md, Rules)."
}

# What the rules ask about each project, asked only when some rule needs it.
rules_facts() {  # rules_facts <changed list JSON> <rules list JSON>
  local list="$1" rl="$2" t n i nf nc nl
  nf="$(echo "$rl" | jq 'any(.[]; (.when.paths // []) | length > 0)')"
  nc="$(echo "$rl" | jq 'any(.[]; .when.ciGreen == true)')"
  nl="$(echo "$rl" | jq 'any(.[]; (.when.labels // []) | length > 0)')"
  t="$(mktemp -d)"; n="$(echo "$list" | jq length)"
  for ((i = 0; i < n; i++)); do
    [ $((i % 6)) = 0 ] && [ "$i" -gt 0 ] && wait
    (
      IFS=$'\x1f' read -r _ _ repo last ref sha < <(echo "$list" | jq -r ".[$i] | [.platform, .name, (.repo // \"\"), (.lastSha // \"\"), (.ref // \"\"), (.headSha // \"\")] | join(\"\u001f\")")
      files=null ci=null labels=null
      if [ "$nf" = true ] && [ -n "$repo" ] && [ -n "$last" ] && [ -n "$ref" ] && [ "$(githost_of "$repo" 2>/dev/null || echo github)" != gitlab ]; then
        # GitHub lists 300 files at most: past that the list is not the whole change (null).
        files="$(gh api --cache 5m "repos/$repo/compare/$last...$ref" 2>/dev/null </dev/null \
          | jq -c '(.files // null) | if . == null or length >= 300 then null else map(.filename) end' 2>/dev/null)" || files=null
        [ -n "$files" ] || files=null
      fi
      if [ "$nc" = true ] && [ -n "$repo" ] && [ -n "$sha" ]; then
        ci="$(ci_of "$repo" "$sha" </dev/null 2>/dev/null | jq -c .state 2>/dev/null)" || ci=null; [ -n "$ci" ] || ci=null
      fi
      if [ "$nl" = true ] && [ -n "$repo" ] && [ -n "$sha" ]; then
        labels="$(gh api --cache 5m "repos/$repo/commits/$sha/pulls" 2>/dev/null </dev/null | jq -c '[.[].labels[]?.name] | unique' 2>/dev/null)" || labels=null
        [ -n "$labels" ] || labels=null
      fi
      echo "$list" | jq -c ".[$i] | {platform, name, oldestPendingAt:(.oldestPendingAt // null), headAt:(.headAt // null)}
        + {files:$files, ci:$ci, labels:$labels}" > "$t/$(printf '%04d' "$i").json"
    ) &
  done
  wait
  cat_all "$t"/*.json | jq -sc .
  rm -rf "$t"
}

# For each project and rule: matched, and the conditions that did not hold.
RULES_JQ='
def glob2re: if test("/") | not then "(^|.*/)" + (gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*\\*"; "\u0001") | gsub("\\*"; "[^/]*") | gsub("\\?"; "[^/]") | gsub("\u0001"; ".*")) + "$"
  else "^" + (ltrimstr("/") | gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*\\*/"; "\u0002") | gsub("\\*\\*"; "\u0001") | gsub("\\*"; "[^/]*") | gsub("\\?"; "[^/]") | gsub("\u0002"; "(.*/)?") | gsub("\u0001"; ".*")) + "$" end;
def anyglob($gs): . as $f | any($gs[]; . as $g | $f | test($g | glob2re));
def unmet($w; $p; $now):
  [ (if ($w.projects // []) | length > 0 then
       ("\($p.platform)/\($p.name)") as $k
       | if any($w.projects[]; . as $g | $k | test("^" + ($g | gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*"; ".*")) + "$")) then empty
         else "project is not one of \($w.projects | join(", "))" end else empty end),
    (if $w.ciGreen == true then
       if ($p.ci == "green" or $p.ci == "none") then empty else "CI is \($p.ci // "unknown")" end else empty end),
    (if ($w.paths // []) | length > 0 then
       if $p.files == null then "the changed files are not known"
       elif $w.onlyPaths == true then
         ([$p.files[] | select(anyglob($w.paths) | not)]) as $out
         | if ($p.files | length) == 0 then "no changed files" elif ($out | length) > 0 then "\($out | length) changed files are outside \($w.paths | join(", ")) (\($out[0]))" else empty end
       elif any($p.files[]; anyglob($w.paths)) then empty
       else "no changed file is in \($w.paths | join(", "))" end else empty end),
    (if ($w.labels // []) | length > 0 then
       if $p.labels == null then "the pull request labels are not known"
       elif any($p.labels[]; . as $l | $w.labels | index($l)) then empty
       else "no pull request has a label \($w.labels | join(", "))" end else empty end),
    (if ($w.minAgeHours // null) != null then
       (($p.oldestPendingAt // $p.headAt) // null) as $at
       | if $at == null then "the age of the waiting commits is not known"
         elif ($now - $at) / 3600 >= $w.minAgeHours then empty
         else "the oldest waiting commit is \((($now - $at) / 3600) | floor) h old, not \($w.minAgeHours)" end else empty end) ];
[ $facts[] as $p | $rules[] as $r
  | (if $r.problem then [$r.problem] else unmet($r.when; $p; $now) end) as $u
  | {rule:$r.name, index:$r.index, project:"\($p.platform)/\($p.name)", platform:$p.platform, name:$p.name,
     matched:($u | length == 0), action:$r.then, unmet:$u} ]'

rules_check_json() {  # rules_check_json <changed list JSON>: [{rule, index, project, matched, action, unmet}]
  local rl facts; rl="$(rules_list)"
  [ "$(echo "$rl" | jq length)" != 0 ] || { echo '[]'; return 0; }
  facts="$(rules_facts "$1" "$rl")"
  jq -nc --argjson rules "$rl" --argjson facts "$facts" --argjson now "$(date +%s)" "$RULES_JQ"
}

# The first matching rule per project, added to the list as .rule {name, index, then}; nothing without rules.
with_rules() {  # with_rules <changed list JSON>
  rules_on || { echo "$1"; return 0; }
  local chk; chk="$(rules_check_json "$1")"
  echo "$1" | jq -c --argjson c "$chk" 'map(. as $p | ([$c[] | select(.platform == $p.platform and .name == $p.name and .matched)] | sort_by(.index) | .[0]) as $m
    | if $m then . + {rule:{name:$m.rule, index:$m.index, then:$m.action}} else . end)'
}

rules_main() {  # rules_main check
  case "${1:-}" in
    check)
      [ -f "$RULES" ] || { if [ "${json:-0}" = 1 ]; then echo '[]'; else echo "No rules ($RULES)."; fi; return 0; }
      local rc=0 list out; list="$(changed_json)" || rc=$?
      out="$(rules_check_json "$list")"
      if [ "${json:-0}" = 1 ]; then echo "$out" | jq .
      else
        rules_list | jq -r '.[] | select(.problem) | "Note: \(.name): \(.problem)"' >&2
        [ "$(echo "$out" | jq length)" != 0 ] || echo "Nothing waits, or no rule is on."
        echo "$out" | jq -r '.[] | "  \(.project)  \(.rule): \(if .matched then "matches -> \(.action)" else "no (\(.unmet | join("; ")))" end)"'
      fi
      return "$rc" ;;
    *) die "Usage: deploys rules check [--json]" ;;
  esac
}
