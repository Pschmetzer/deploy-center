# shellcheck shell=bash
# lib/x-lint.sh — `deploys lint`: the settings files of the config folder, checked for syntax and for what each one expects.
#
#   deploys lint [--json]       exit 1 when a file has a problem; files that are not there are skipped
#
# Checked: window.json (deny rules: days, dates, from/to), budget.json (monthlyUsd), slo.json (percent), checklists.json
# (lists of short texts), and for rules, prices, ignored, groups, guard, providers, clean, nightly, prepare and sessions that
# the file is valid JSON. Read-only. `deploys doctor` checks tools and access; this checks your files. Sourced by deploys;
# uses CONFIG_DIR and die.
# x-command: lint | check the settings files (window, budget, slo, checklists, rules …) for syntax and the fields each expects | deploys lint [--json]

LINT_FILES="window rules budget prices ignored groups guard providers clean nightly prepare autofix-limits slo checklists sessions"

# lint_check <name> <file>: the problems of one file, one per line (nothing when it is fine).
lint_check() {
  local name="$1" f="$2" err
  if ! err="$(jq -e . "$f" 2>&1 >/dev/null)"; then
    printf 'not valid JSON: %s\n' "$(printf '%s' "$err" | head -n 1 | cut -c1-120)"; return 0
  fi
  case "$name" in
    window) jq -r '
      def hm: type == "string" and test("^([01][0-9]|2[0-3]):[0-5][0-9]$|^24:00$");
      if type != "object" then "must be an object with a \"deny\" list"
      elif ((.deny // []) | type) != "array" then "\"deny\" must be a list"
      else (.deny // []) | to_entries[] | .key as $i | .value as $r
        | if ($r | type) != "object" then "rule \($i + 1) must be an object" else
            ( (($r.days // []) | if type != "array" then "rule \($i + 1): \"days\" must be a list" else .[] | select(IN("mon","tue","wed","thu","fri","sat","sun") | not) | "rule \($i + 1): \"\(.)\" is not mon, tue, wed, thu, fri, sat or sun" end),
              (($r.dates // []) | if type != "array" then "rule \($i + 1): \"dates\" must be a list" else .[] | select((type == "string" and test("^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$")) | not) | "rule \($i + 1): date \(tojson) is not YYYY-MM-DD" end),
              (["from", "to"][] as $k | select($r | has($k)) | select(($r[$k] | hm) | not) | "rule \($i + 1): \"\($k)\" must be HH:MM") ) end end' "$f" ;;
    budget) jq -r 'if type != "object" then "must be an object" elif (.monthlyUsd | type) != "number" or .monthlyUsd <= 0 then "\"monthlyUsd\" must be a number above 0" else empty end' "$f" ;;
    slo) jq -r 'if type != "object" then "must be an object" elif (.percent | type) != "number" or .percent < 1 or .percent > 100 then "\"percent\" must be a number from 1 to 100" else empty end' "$f" ;;
    checklists) jq -r 'if type != "object" then "must be an object: {\"project\": [\"point\"]}" else to_entries[] | .key as $k | if (.value | type) != "array" then "\"\($k)\" must be a list of texts" else (.value[] | select((type == "string" and length > 0 and length <= 200) | not) | "\"\($k)\": a point must be a text of 1 to 200 characters") end end' "$f" ;;
    *) : ;;
  esac
}

x_lint_main() {
  local name f probs rows="[]" bad=0 checked=0
  [ "$#" -eq 0 ] || die "Unknown option $1. Usage: deploys lint [--json]"
  for name in $LINT_FILES; do
    f="$CONFIG_DIR/$name.json"; [ -f "$f" ] || continue
    checked=$((checked + 1))
    probs="$(lint_check "$name" "$f")"
    if [ -n "$probs" ]; then bad=$((bad + 1)); fi
    rows="$(jq -c --arg n "$name.json" --arg p "$probs" '. + [{file:$n, ok:($p == ""), problems:($p | split("\n") | map(select(. != "")))}]' <<<"$rows")"
  done
  if [ "${json:-0}" = 1 ]; then jq -n --argjson c "$checked" --argjson b "$bad" --argjson r "$rows" '{checked:$c, withProblems:$b, files:$r}'
  else
    [ "$checked" -gt 0 ] || echo "No settings files in $CONFIG_DIR: nothing to check."
    jq -r '.[] | if .ok then "  ok       \(.file)" else "  PROBLEM  \(.file)", (.problems[] | "             \(.)") end' <<<"$rows"
    [ "$checked" = 0 ] || echo "$checked files checked, $bad with problems."
  fi
  [ "$bad" = 0 ]
}
