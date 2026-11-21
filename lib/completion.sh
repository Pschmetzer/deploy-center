# shellcheck shell=bash
# deploys completion zsh|bash|fish: tab completion, kept out of `deploys` (round 12 B, items 26-32).
# Sourced by deploys; uses PROVIDERS, SELF, CONFIG_DIR and the <provider>_cli_* functions from there.

# The commands, when the case labels of the script cannot be read (a copy of `deploys` without its source, a
# script piped in): this list keeps the completion usable. The labels win when they are there.
COMPLETION_FALLBACK_CMDS="ai autodeploy autofix budget cancel certs changed check ci completion config costs creds deploy deploy-changed details diff digest doctor explain freeze github-budget gitlab guard history hook hooks idle ignore journal list logs metrics notes open plan price providers readonly risk rollback rules scan schedule secrets simulate status team triggers verify watch where window"

# The words after a command (second place), one line per command: "<command>:<words>". One table feeds all three shells.
completion_subs_table() {
  cat <<'TABLE'
ai:explain notes ship ask slow risk set-key forget-key verify model cap status
gitlab:set-token forget-token
providers:enable disable
completion:zsh bash fish
autodeploy:allow allowed revoke
guard:status schedule
schedule:daily off status
hooks:install uninstall status
team:add remove list refresh journal init
scan:start status list log
check:start show
autofix:set-token routine list forget-token prompt status sync schedule
rules:check
price:set unset
budget:set off
journal:verify export report
idle:--days --json
creds:--max-age --json
certs:--days --json
secrets:--stdin --json
plan:--when-green --since --json
list:--platform --auto --manual --format --json
ignore:--list --undo --json
readonly:on off
config:--refresh
doctor:--text --fix --json
freeze:status add remove clear --json
digest:--days --json --no-savings
rollback:
cancel:
TABLE
}

# The commands: the case labels of the script (the same source as the typo hint), the providers, the flags.
completion_cmds() {
  local c=""
  [ -r "${SELF:-}" ] && c="$(sed -n 's/^  "\([a-z][a-z-]*\)[ "].*/\1/p' "$SELF" 2>/dev/null)"
  [ -n "$c" ] || c="$(printf '%s\n' $COMPLETION_FALLBACK_CMDS)"
  { printf '%s\n' "$c"; printf '%s\n' "${PROVIDERS[@]}" completion --help --version; } | sort -u | paste -sd' ' -
}

# What a provider's first word offers: the verbs every provider has plus its own <p>_cli_<verb> commands.
completion_verbs_of() {
  local v="list deploy rollback status cancel autodeploy-off json" x
  for x in $(declare -F | sed -n "s/^declare -f ${1}_cli_//p" | tr '_' '-'); do [[ " $v " == *" $x "* ]] || v="$v $x"; done
  grep -q '"keychain":"' <<<"$("${1}_meta")" && v="$v set-key"
  echo "$v"
}

completion_main() {
  local sh="${1:-zsh}" cmds zv="" bv="" p _c _w qdir
  case "$sh" in zsh|bash|fish) ;; *) die "zsh, bash or fish" ;; esac
  cmds="$(completion_cmds)"
  # %q: the names file sits in a path that may hold a space or a quote; shell syntax, not a bare word.
  qdir="$(printf '%q' "$CONFIG_DIR/names")"
  for p in "${PROVIDERS[@]}"; do
    zv="$zv  elif [[ \$words[2] == $p && CURRENT == 3 ]]; then compadd $(completion_verbs_of "$p")"$'\n'
    bv="$bv  elif [ \$COMP_CWORD -eq 2 ] && [ \"\${COMP_WORDS[1]}\" = $p ]; then COMPREPLY=(\$(compgen -W \"$(completion_verbs_of "$p")\" -- \"\$cur\"))"$'\n'
  done
  while IFS=: read -r _c _w; do
    [ -n "$_w" ] || continue
    zv="$zv  elif [[ \$words[2] == $_c && CURRENT == 3 ]]; then compadd $_w"$'\n'
    bv="$bv  elif [ \$COMP_CWORD -eq 2 ] && [ \"\${COMP_WORDS[1]}\" = $_c ]; then COMPREPLY=(\$(compgen -W \"$_w\" -- \"\$cur\"))"$'\n'
  done < <(completion_subs_table)
  case "$sh" in
    zsh) cat <<ZSH
_deploys() {
  local -a names; names=(\${(f)"\$(cat $qdir 2>/dev/null)"})
  if (( CURRENT == 2 )); then compadd $cmds
${zv}  else compadd -a names; fi
}
# compdef exists only after compinit; load it if ~/.zshrc has not.
(( \$+functions[compdef] )) || { autoload -Uz compinit && compinit; }
compdef _deploys deploys
ZSH
    ;;
    bash) cat <<BASH
_deploys() {
  local cur=\${COMP_WORDS[COMP_CWORD]}
  if [ \$COMP_CWORD -eq 1 ]; then COMPREPLY=(\$(compgen -W "$cmds" -- "\$cur"))
${bv}  else
    # Matched by hand, not with compgen -W: that expands each word, and a name is data.
    local n; COMPREPLY=()
    while IFS= read -r n; do [[ \$n == "\$cur"* ]] && COMPREPLY+=("\$n"); done 2>/dev/null < $qdir
  fi
}
complete -F _deploys deploys
BASH
    ;;
    fish)
      # deploys completion fish | source  (or save it as ~/.config/fish/completions/deploys.fish).
      # Names are read line by line by fish itself: nothing in them is run.
      echo "complete -c deploys -f"
      echo "complete -c deploys -n __fish_use_subcommand -a '$cmds'"
      for p in "${PROVIDERS[@]}"; do echo "complete -c deploys -n '__fish_seen_subcommand_from $p' -a '$(completion_verbs_of "$p")'"; done
      while IFS=: read -r _c _w; do
        [ -n "$_w" ] && echo "complete -c deploys -n '__fish_seen_subcommand_from $_c' -a '$_w'"
      done < <(completion_subs_table)
      printf "complete -c deploys -n 'not __fish_use_subcommand' -a '(cat %s 2>/dev/null)'\n" "$qdir" ;;
  esac
}
