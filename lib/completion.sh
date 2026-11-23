# shellcheck shell=bash
# lib/completion.sh - `deploys completion zsh|bash|fish`, moved out of the script. The commands are read from the case
# labels of $SELF; the second words and the flags come from two tables below. Sourced by deploys.

completion_main() {
    # Tab completion: eval "$(deploys completion zsh)" in ~/.zshrc, or bash in ~/.bashrc.
    # Per provider: the verbs every provider has, plus its own commands (<p>_cli_<verb>).
    # The commands are read from the case labels of this script (the same source as the typo hint), so a new
    # command is completed the day it exists; the providers and the flags are added.
    cmds="$( { sed -n 's/^  "\([a-z][a-z-]*\)[ "].*/\1/p' "$SELF" 2>/dev/null; printf '%s\n' "${PROVIDERS[@]}" completion --help --version; } | sort -u | paste -sd' ' -)"
    # The case labels cannot be read when this script is not a readable file (a pipe, a different layout): then the
    # built-in list is what is completed, so a completion is never empty.
    [ "$(printf '%s\n' $cmds | wc -l | tr -d ' ')" -ge 30 ] || cmds="$cmds $(printf '%s ' list deploy deploy-changed rollback status cancel logs watch verify risk history diff notes open details doctor config guard freeze digest journal idle certs creds secrets plan rules team scan check autofix autodeploy schedule readonly price budget hooks hook ignore metrics explain simulate triggers where window providers ai gitlab completion | tr ' ' '\n' | sort -u | paste -sd' ' -)"
    # The words that follow a command (second place), one line per command: "<command>:<words>". The one place for
    # them: zsh, bash and fish read this table (a word listed three times drifts apart).
    subs_table="autodeploy:allow allowed revoke
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
domains:--warn --json
forecast:--warn --json
secrets:--stdin --json
plan:--when-green --since --json
list:--platform --auto --manual --format --json
ignore:--list --undo --json
readonly:on off
config:--refresh export import
doctor:--text --fix --json
freeze:status add import remove clear --json
digest:--days --json --no-savings --format
preview:--json
timeline:--days --project --limit --json
recovery:--days --project --json
streak:--days --project --json
when:--days --by --json
savings:--format --json
rollback:
cancel:
ai:explain notes ship ask slow risk set-key forget-key verify model cap status
gitlab:set-token forget-token
providers:enable disable
completion:zsh bash fish
exit-codes:"
    # The flags of a command or provider verb (third place on): "<verb>:<flags>". Offered after a word that starts with -.
    flags_table="deploy:--preview --sha --wait --timeout --dry-run --force --yes --no-cache --json
deploy-changed:--yes --dry-run --when-green --wait --strict --by-rules --only --exclude --platform --max --wait-for-window --force --json
watch:--preview --timeout --interval --quiet --json --and
verify:--path --expect --follow --tries --every --need --max-time --match --header --cert-days --warmup --retry-connrefused --watch-timeout --rollback-after --no-rollback --url --json
logs:--id --runtime --follow --json
rollback:--yes --dry-run --to --json
cancel:--yes --json
status:--json --no-github --watch --platform
history:--json --days --limit
risk:--json
autodeploy-off:--yes --dry-run
autodeploy-on:--yes --dry-run"
    verbs_of() {
      local v="list deploy rollback status cancel autodeploy-off json" x
      for x in $(declare -F | sed -n "s/^declare -f ${1}_cli_//p" | tr '_' '-'); do [[ " $v " == *" $x "* ]] || v="$v $x"; done
      grep -q '"keychain":"' <<<"$("${1}_meta")" && v="$v set-key"
      echo "$v"
    }
    # Where the command word is: after the global options (--json, --quiet, --debug, --no-color, --color=…), so
    # `deploys --json list <TAB>` completes like `deploys list <TAB>`. cmd is the command, pos 2 its first argument.
    zpre='local sub=2 cmd pos; while [[ $words[sub] == --* && sub -lt CURRENT ]]; do (( sub++ )); done; cmd=$words[sub]; pos=$(( CURRENT - sub + 2 ))'
    bpre='local sub=1 cmd pos; while [[ ${COMP_WORDS[sub]} == --* && $sub -lt $COMP_CWORD ]]; do sub=$((sub + 1)); done; cmd=${COMP_WORDS[sub]}; pos=$((COMP_CWORD - sub + 1))'
    zv=""; bv=""
    for p in "${PROVIDERS[@]}"; do
      zv="$zv  elif [[ \$cmd == $p && \$pos == 3 ]]; then compadd $(verbs_of "$p")"$'\n'
      bv="$bv  elif [ \$pos -eq 2 ] && [ \"\$cmd\" = $p ]; then COMPREPLY=(\$(compgen -W \"$(verbs_of "$p")\" -- \"\$cur\"))"$'\n'
    done
    while IFS=: read -r _c _w; do
      [ -n "$_w" ] || continue
      zv="$zv  elif [[ \$cmd == $_c && \$pos == 3 ]]; then compadd -- $_w"$'\n'
      bv="$bv  elif [ \$pos -eq 2 ] && [ \"\$cmd\" = $_c ]; then COMPREPLY=(\$(compgen -W \"$_w\" -- \"\$cur\"))"$'\n'
    done <<< "$subs_table"
    # Flags: for a word that starts with "-", whatever command it follows (a provider verb takes the flags of the verb).
    zfl=""; bfl=""
    while IFS=: read -r _c _w; do
      [ -n "$_w" ] || continue
      zfl="$zfl    [[ \$cmd == $_c || \$words[sub+1] == $_c || \$words[sub+2] == $_c ]] && { compadd -- $_w; return; }"$'\n'
      bfl="$bfl    [ \"\$cmd\" = $_c ] || [ \"\${COMP_WORDS[sub+1]}\" = $_c ] || [ \"\${COMP_WORDS[sub+2]}\" = $_c ] && { COMPREPLY=(\$(compgen -W \"$_w\" -- \"\$cur\")); return; }"$'\n'
    done <<< "$flags_table"
    # The names file, written so a folder with a space or a quote in its name still works (printf %q).
    nq="$(printf '%q' "$CONFIG_DIR/names")"
    case "${2:-zsh}" in
      zsh) cat <<ZSH
_deploys() {
  local -a names; names=(\${(f)"\$(cat $nq 2>/dev/null)"})
  $zpre
  if [[ \$PREFIX == -* ]]; then
$zfl    compadd -- --json --quiet --debug --no-color --force; return
  fi
  if (( pos == 2 )); then compadd $cmds
${zv}  elif [[ \$cmd == completion ]]; then compadd zsh bash fish
  else compadd -a names; fi
}
# compdef exists only after compinit; load it if ~/.zshrc has not.
(( \$+functions[compdef] )) || { autoload -Uz compinit && compinit; }
compdef _deploys deploys
ZSH
      ;;
      bash) cat <<BASH
_deploys() {
  local cur=\${COMP_WORDS[COMP_CWORD]}
  $bpre
  if [[ \$cur == -* ]]; then
$bfl    COMPREPLY=(\$(compgen -W "--json --quiet --debug --no-color --force" -- "\$cur")); return
  fi
  if [ \$COMP_CWORD -eq \$sub ]; then COMPREPLY=(\$(compgen -W "$cmds" -- "\$cur"))
${bv}  else
    # Matched by hand, not with compgen -W: that expands each word, and a name is data.
    local n; COMPREPLY=()
    while IFS= read -r n; do [[ \$n == "\$cur"* ]] && COMPREPLY+=("\$n"); done 2>/dev/null < $nq
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
        for p in "${PROVIDERS[@]}"; do echo "complete -c deploys -n '__fish_seen_subcommand_from $p' -a '$(verbs_of "$p")'"; done
        while IFS=: read -r _c _w; do
          [ -n "$_w" ] && echo "complete -c deploys -n '__fish_seen_subcommand_from $_c' -a '$_w'"
        done <<< "$subs_table"
        while IFS=: read -r _c _w; do
          [ -n "$_w" ] && for _f in $_w; do echo "complete -c deploys -n '__fish_seen_subcommand_from $_c' -l ${_f#--}"; done
        done <<< "$flags_table"
        printf "complete -c deploys -n 'not __fish_use_subcommand' -a '(cat %s 2>/dev/null)'\n" "$nq" ;;
      *) die "zsh, bash or fish" ;;
    esac
}
