#!/bin/bash
# deploys-call.sh — sourced by before-deploy.sh and after-failure.sh. Reads only; prints nothing itself.
#
# shellcheck disable=SC2034 # the DC_* variables are read by the scripts that source this file
# deploys_call "<the Bash command Claude ran>" looks for a `deploys` call that starts or undoes a deploy and sets:
#   DC_SUB      deploy | deploy-changed | rollback   (empty: the command is none of these)
#   DC_PROJECT  the project word that follows, only when it is one plain name (letters, digits, . _ : -), else empty
#   DC_YES      1 when the call has --yes
#   DC_DRY      1 when the call has --dry-run or -n (it only shows what would happen)
#   DC_WEAKEN   a text when DC_SUB is "weaken": the call switches a safeguard off (autodeploy allow, freeze clear, ...)
# The command is split at && || ; | and newlines, so `cd app && deploys deploy web` is found. `deploys vercel deploy web`
# and `deploys render rollback api` count too. `deploys deploy-changed` without --yes only lists, so it is not a deploy.
# Not found: another word that merely contains "deploy", `git stash push`, `echo deploys deploy`.

deploys_call() {
  local words="$1" sep w seg=()
  DC_SUB="" DC_PROJECT="" DC_YES=0 DC_DRY=0 DC_WEAKEN=""
  case "$words" in
    *sh\ -*c\ *) words="$(printf '%s' "$words" | sed -E "s/(^|[[:space:];&|])(ba|z|da)?sh +-[a-z]*c +/ ; /g; s/[\"']/ /g")" ;;
  esac
  for sep in '&&' '||' ';' '|' $'\n'; do words="${words//"$sep"/ ; }"; done
  set -f   # split into words on purpose, without expanding globs
  # shellcheck disable=SC2086
  set -- $words
  set +f
  for w in "$@" ";"; do
    if [ "$w" = ";" ]; then deploys_segment; [ -n "$DC_SUB" ] && return 0; seg=()
    else seg+=("${w//[\"\']/}"); fi
  done
  return 0
}

# A word that may stand before `deploys` in a command of its own: a wrapper, a shell keyword, an option, a variable
# assignment, a number (nice -n 5, timeout 30). `echo deploys deploy web` has `echo` before it: not a call.
deploys_prefix_word() {  # deploys_prefix_word <word> <previous word>
  case "$1" in
    command|builtin|exec|env|nohup|time|sudo|doas|xargs|nice|ionice|caffeinate|stdbuf|timeout|gtimeout|setsid|eval|then|do|else|elif|if|while|until|!|'('|'{'|'&') return 0 ;;
    -*|[A-Za-z_]*=*|[0-9]*) return 0 ;;
  esac
  case "$2" in -*) return 0 ;; esac   # the value of an option: sudo -u root deploys deploy web
  return 1
}

# deploys_verbs <words...>: sets DC_SUB, DC_WEAKEN and DC_PROJECT from the words after `deploys`.
deploys_verbs() {
  local a prev="" idx=0 firsts=() sub="" k
  for a in "$@"; do
    case "$a" in -*) prev="$a"; continue ;; esac
    # A value of --config, --sha ... is no word of the command line.
    case "$prev" in --config|--profile) prev=""; continue ;; esac
    firsts+=("$a"); prev=""; idx=$((idx+1)); [ "$idx" -lt 4 ] || break
  done
  for a in ${firsts[@]+"${firsts[@]}"}; do
    case "$a" in deploy|deploy-json|deploy-changed|rollback) sub="$a"; break ;; esac
  done
  if [ -z "$sub" ]; then
    # Switches a safeguard off: its own question.
    local w1="${firsts[0]:-}" w2="${firsts[1]:-}" w3="${firsts[2]:-}" yes=0
    for a in "$@"; do case "$a" in --yes|-y) yes=1 ;; --dry-run|-n) DC_DRY=1 ;; esac; done
    case "$w1 $w2" in
      "autodeploy allow") DC_WEAKEN="turns auto-deploy on for a while" ;;
      "prepare run") [ "$yes" = 1 ] && DC_WEAKEN="starts prepared deploys" || true ;;
      "freeze clear"|"freeze remove") DC_WEAKEN="removes a freeze" ;;
      "guard schedule") [ "$w3" = off ] && DC_WEAKEN="switches the scheduled guard off" || true ;;
      "cancel "*|"ignore "*) case "$w1" in cancel) DC_WEAKEN="cancels a running build" ;; ignore) case "$w2" in list|show|status) ;; *) DC_WEAKEN="changes which projects are ignored" ;; esac ;; esac ;;
    esac
    [ -n "$DC_WEAKEN" ] && DC_SUB=weaken
    return 0
  fi
  [ "$sub" != deploy-json ] || sub=deploy
  local rest=() seen=0
  for a in "$@"; do
    if [ "$seen" = 0 ]; then case "$a" in deploy|deploy-json|deploy-changed|rollback) seen=1 ;; esac; continue; fi
    rest+=("$a")
  done
  for a in ${rest[@]+"${rest[@]}"}; do
    case "$a" in --yes|-y) DC_YES=1 ;; --dry-run|-n) DC_DRY=1 ;; esac
  done
  # deploy-changed starts something only with --yes.
  [ "$sub" != deploy-changed ] || [ "$DC_YES" = 1 ] || { DC_YES=0; return 0; }
  prev=""
  for a in ${rest[@]+"${rest[@]}"}; do
    case "$prev" in --sha|--wait|--force|--reason|--rollback-after|--max|--to|--id) prev=""; continue ;; esac
    case "$a" in -*) prev="$a"; continue ;; esac
    a="${a%\)}"; a="${a%\}}"
    case "$a" in ''|*[!A-Za-z0-9._:-]*) ;; *) DC_PROJECT="$a" ;; esac
    break
  done
  [ "$sub" = deploy-changed ] && DC_PROJECT=""
  DC_SUB="$sub"
}

deploys_segment() {
  local i=0 n=${#seg[@]} w prev="" j k indirect=0 verb=0 a
  [ "$n" -gt 0 ] || return 0
  # Through the words in front: wrappers, keywords, assignments. The first other word decides.
  while [ "$i" -lt "$n" ]; do
    w="${seg[$i]}"
    # $D deploy web, $(which deploys) deploy web, `which deploys` deploy web: the program is not known
    case "$w" in \$*|\`*|*\$\(*) indirect=1; break ;; esac
    w="${w#\(}"; w="${w#\{}"; w="${w%\)}"; w="${w%\}}"
    [ "${w##*/}" != deploys ] || break
    [ -n "$w" ] || { prev="${seg[$i]}"; i=$((i+1)); continue; }
    deploys_prefix_word "$w" "$prev" || return 0
    prev="${seg[$i]}"; i=$((i+1))
  done
  [ "$i" -lt "$n" ] || return 0
  if [ "$indirect" = 1 ]; then
    # Unknown program with a deploy verb among its words (or a word that names deploys): ask.
    for a in "${seg[@]:$i}"; do
      case "$a" in deploy|deploy-json|deploy-changed|rollback) verb=1 ;; esac
    done
    [ "$verb" = 1 ] || return 0
    case " ${seg[*]} " in *deploys*|*\$*) ;; *) return 0 ;; esac
    DC_SUB=deploy
    return 0
  fi
  deploys_verbs "${seg[@]:$((i+1))}"
}

# deploys_bin: the CLI as the other hook finds it (DEPLOYS, then the app bundle, then PATH); empty when none.
deploys_bin() {
  local c bin=""
  if [ -n "${DEPLOYS:-}" ]; then bin="$DEPLOYS"
  else
    for c in "/Applications/Deploy Center.app/Contents/Resources/deploys" \
             "$HOME/Applications/Deploy Center.app/Contents/Resources/deploys"; do
      [ -x "$c" ] && { bin="$c"; break; }
    done
    [ -n "$bin" ] || bin="$(command -v deploys 2>/dev/null)"
  fi
  [ -n "$bin" ] && command -v "$bin" >/dev/null 2>&1 && printf '%s' "$bin"
}

# run_limited <seconds> <outfile> <command...>: runs it, writes stdout to the file, stops it (and its children) at the limit.
run_limited() {
  local limit="$1" outf="$2" pid waited=0
  shift 2
  ( exec "$@" >"$outf" 2>/dev/null </dev/null ) & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge $((limit * 5)) ]; then pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; return 1; fi
    sleep 0.2; waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null
  return 0
}
