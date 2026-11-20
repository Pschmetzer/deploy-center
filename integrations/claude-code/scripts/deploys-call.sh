#!/bin/bash
# deploys-call.sh — sourced by before-deploy.sh and after-failure.sh. Reads only; prints nothing itself.
#
# shellcheck disable=SC2034 # the DC_* variables are read by the scripts that source this file
# deploys_call "<the Bash command Claude ran>" looks for a `deploys` call that starts or undoes a deploy and sets:
#   DC_SUB      deploy | deploy-changed | rollback   (empty: the command is none of these)
#   DC_PROJECT  the project word that follows, only when it is one plain name (letters, digits, . _ : -), else empty
#   DC_YES      1 when the call has --yes
#   DC_DRY      1 when the call has --dry-run or -n (it only shows what would happen)
# The command is split at && || ; | and newlines, so `cd app && deploys deploy web` is found. `deploys vercel deploy web`
# and `deploys render rollback api` count too. `deploys deploy-changed` without --yes only lists, so it is not a deploy.
# Not found: another word that merely contains "deploy", `git stash push`, `echo deploys deploy`.

deploys_call() {
  local words="$1" sep w seg=()
  DC_SUB="" DC_PROJECT="" DC_YES=0 DC_DRY=0
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

deploys_segment() {
  local i=0 n=${#seg[@]} w sub a rest=()
  [ "$n" -gt 0 ] || return 0
  while [ "$i" -lt "$n" ] && [[ "${seg[$i]}" == [A-Za-z_]*=* ]]; do i=$((i+1)); done
  w="${seg[$i]:-}"
  [ "${w##*/}" = deploys ] || return 0
  i=$((i+1))
  while [ "$i" -lt "$n" ] && [[ "${seg[$i]}" == -* ]]; do i=$((i+1)); done
  sub="${seg[$i]:-}"
  case "$sub" in
    deploy|deploy-changed|rollback) ;;
    # deploys vercel deploy <project>, deploys render rollback <project>
    [a-z]*) case "${seg[$((i+1))]:-}" in deploy|deploy-json|rollback) i=$((i+1)); sub="${seg[$i]}" ;; *) return 0 ;; esac ;;
    *) return 0 ;;
  esac
  [ "$sub" != deploy-json ] || sub=deploy
  rest=("${seg[@]:$((i+1))}")
  for a in ${rest[@]+"${rest[@]}"}; do
    case "$a" in --yes|-y) DC_YES=1 ;; --dry-run|-n) DC_DRY=1 ;; esac
  done
  # deploy-changed starts something only with --yes.
  [ "$sub" != deploy-changed ] || [ "$DC_YES" = 1 ] || { DC_YES=0; return 0; }
  for a in ${rest[@]+"${rest[@]}"}; do
    case "$a" in -*) continue ;; esac
    case "$a" in ''|*[!A-Za-z0-9._:-]*) ;; *) DC_PROJECT="$a" ;; esac
    break
  done
  [ "$sub" = deploy-changed ] && DC_PROJECT=""
  DC_SUB="$sub"
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
