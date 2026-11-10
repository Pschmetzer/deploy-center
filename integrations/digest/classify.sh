#!/bin/bash
# classify.sh — mark waiting commits as written by an agent or by a person. Pure: reads JSON on
# stdin, writes JSON on stdout, calls nothing but jq. Sourced by digest.sh; also runs alone:
#
#   deploys details me/app <live sha> main | jq .commits | integrations/digest/classify.sh
#
# In: an array of commits as `deploys details` prints them ({sha, msg, author, bot, coAuthors, pr}),
# optionally with the pull request's facts added: prAuthor, prBot, prLabels.
# Out: the same array, each commit with kind ("agent" or "human") and why (the first rule that matched).
#
# Rules, in order:
#   1. bot       GitHub says the author is a bot account (bot or prBot)
#   2. author    the author login matches a pattern in DEPLOYS_AGENT_AUTHORS
#   3. co-author a Co-Authored-By trailer names one (pattern with @ is matched against the email,
#                otherwise against the name and its first word)
#   4. label     the pull request has a label in DEPLOYS_AGENT_LABELS
#   5. pr author the pull request was opened by a matching login
#   Everything else counts as human.
#
# Env (comma- or space-separated; each replaces its default list; case does not matter):
#   DEPLOYS_AGENT_AUTHORS  globs (* and ?). Default: see DEFAULT_AGENT_AUTHORS below.
#   DEPLOYS_AGENT_LABELS   exact label names. Default: see DEFAULT_AGENT_LABELS below.

DEFAULT_AGENT_AUTHORS='*[bot] claude claude-code cursor cursoragent cursor-agent devin devin-ai-integration codex chatgpt-codex-connector copilot copilot-swe-agent'
DEFAULT_AGENT_LABELS='agent ai-generated ai claude codex cursor devin copilot'

# The list in $1 (commas or spaces) as a JSON array of lowercase strings.
_agent_list() { printf '%s' "$1" | tr ',' ' ' | jq -Rc 'ascii_downcase | [splits("[[:space:]]+") | select(length > 0)]'; }

classify() {
  jq --argjson authors "$(_agent_list "${DEPLOYS_AGENT_AUTHORS:-$DEFAULT_AGENT_AUTHORS}")" \
     --argjson labels "$(_agent_list "${DEPLOYS_AGENT_LABELS:-$DEFAULT_AGENT_LABELS}")" '
    def glob_re: "^" + (gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*"; ".*") | gsub("\\?"; ".")) + "$";
    ($authors | map(select(contains("@") | not) | glob_re)) as $names
    | ($authors | map(select(contains("@")) | glob_re)) as $emails
    | def login_hit: (. // "" | ascii_downcase) as $l | ($l != "") and any($names[]; . as $r | $l | test($r));
      def coauthor_hit:
        ((.name // "" | ascii_downcase) as $n | ($n != "") and any($names[]; . as $r | ($n | test($r)) or (($n | split(" ")[0]) | test($r))))
        or ((.email // "" | ascii_downcase) as $e | ($e != "") and any($emails[]; . as $r | $e | test($r)));
    if type != "array" then [] else . end
    | map(. as $c
      | ([(.coAuthors // [])[] | select(coauthor_hit)][0]) as $co
      | ([(.prLabels // [])[] | select((ascii_downcase) as $x | $labels | index($x))][0]) as $lab
      | . + (
          if (.bot == true) or (.prBot == true) then {kind:"agent", why:"bot account"}
          elif (.author | login_hit) then {kind:"agent", why:"author \(.author)"}
          elif $co then {kind:"agent", why:"co-author \($co.name // $co.email)"}
          elif $lab then {kind:"agent", why:"label \($lab)"}
          elif (.prAuthor | login_hit) then {kind:"agent", why:"pull request by \(.prAuthor)"}
          else {kind:"human", why:"no agent sign"} end))'
}

# Run alone: classify stdin.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then set -euo pipefail; classify; fi
