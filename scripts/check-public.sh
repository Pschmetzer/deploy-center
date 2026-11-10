#!/usr/bin/env bash
# This repo is public. Fails when a tracked file holds something personal: a home folder path,
# an Apple Team ID in a signing identity, Vercel team/project IDs, Render service IDs or keys,
# a token or private key, an email address, or a word from your private list.
#   scripts/check-public.sh            checks all tracked files (CI runs this)
#   git log --format=%B A..B | scripts/check-public.sh --stdin    checks text on stdin (commit messages)
# Private words: one per line in ${DEPLOYS_PRIVATE_WORDS:-~/.config/deploys/private-words} (never in
# the repo): your own project names, domains, people. Matched case-insensitively, as plain text.
# Empty lines and lines starting with # are ignored. CI has no such file; locally it catches what
# follows no pattern.
set -euo pipefail
cd "$(dirname "$0")/.."

stdin=0
case "${1:-}" in
  --stdin) stdin=1 ;;
  "") ;;
  *) echo "Usage: scripts/check-public.sh [--stdin]" >&2; exit 2 ;;
esac

patterns=(
  '/Users/[A-Za-z0-9._-]+'                      # macOS home folders
  '/home/[a-z][a-z0-9._-]+/'                    # Linux home folders
  'Developer ID Application: [^"]*\([A-Z0-9]{10}\)'  # a real Team ID (the placeholder is TEAMID)
  'team_[A-Za-z0-9]{20,}'                       # Vercel team ID
  'prj_[A-Za-z0-9]{20,}'                        # Vercel project ID
  '(srv|crn|usr|tea)-[a-z0-9]{16,}'             # Render IDs
  'rnd_[A-Za-z0-9]{20,}'                        # Render API key
)
# Placeholders that may appear in docs and examples.
allowed='/Users/(YOURNAME|you|me|name)\b'

# Tokens and keys. Tests carry made-up ones on purpose (to check the masking), so test folders are
# left out of these; everywhere else a token is never right.
tokens=(
  '\b(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})'   # GitHub
  '\bsk-ant-[A-Za-z0-9_-]{20,}'                                  # Anthropic
  '\bglpat-[A-Za-z0-9_-]{20,}'                                   # GitLab
  '\bAKIA[0-9A-Z]{16}\b'                                         # AWS access key
  '\bxox[abprs]-[A-Za-z0-9-]{10,}'                               # Slack
  '-----BEGIN ([A-Z]+ )*PRIVATE KEY-----'                        # a private key block
)
is_test_path() { case "$1" in tests/*|*/tests/*|*/test/*) return 0 ;; *) return 1 ;; esac; }

# Email addresses: not after ":" or "/" (user:password@host in a URL), and not the placeholders,
# no-reply addresses or git@host remotes. The legal pages carry the contact address the law asks for.
email='(^|[^A-Za-z0-9._%+:/-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
email_ok='git@|@([A-Za-z0-9-]+\.)*(example|invalid|test|localhost)\b|noreply|no-reply|@users\.noreply\.github\.com|\[bot\] <'
email_files='^site/(impressum|datenschutz)\.html$'

words_file="${DEPLOYS_PRIVATE_WORDS:-$HOME/.config/deploys/private-words}"
words=""
if [ -f "$words_file" ]; then
  # Without empty and comment lines: an empty pattern for grep -F matches every line.
  words="$(mktemp)"; trap 'rm -f "$words"' EXIT
  sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//' "$words_file" | grep -vE '^(#|$)' > "$words" || true
  [ -s "$words" ] || { rm -f "$words"; words=""; }
fi

found=0
report() { while IFS= read -r line; do echo "$1:$line"; done <<<"$2"; found=1; }

# check <name> <file>: every rule against one file (or the text from stdin, saved to a file).
check() {
  local name="$1" file="$2" p hits
  for p in "${patterns[@]}"; do
    if hits="$(grep -nIE -e "$p" "$file" | grep -vE "$allowed")"; then report "$name" "$hits"; fi
  done
  if ! is_test_path "$name"; then
    for p in "${tokens[@]}"; do
      if hits="$(grep -nIE -e "$p" "$file")"; then report "$name" "$hits"; fi
    done
  fi
  if ! [[ "$name" =~ $email_files ]] && hits="$(grep -nIE -e "$email" "$file" | grep -vE "$email_ok")"; then
    report "$name" "$hits"
  fi
  if [ -n "$words" ] && hits="$(grep -nIiF -f "$words" "$file")"; then
    # The line itself may hold the private word: say only where, not what.
    report "$name" "$(cut -d: -f1 <<<"$hits" | sed 's/$/: a word from your private list/')"
  fi
  return 0
}

if [ "$stdin" = 1 ]; then
  t="$(mktemp)"; cat > "$t"
  check stdin "$t"; rm -f "$t"
  if [ "$found" = 1 ]; then echo "check-public.sh: personal data in the text on stdin (above)." >&2; exit 1; fi
  echo "No personal data found in the text."
  exit 0
fi

while IFS= read -r -d '' file; do
  [ "$file" = scripts/check-public.sh ] && continue
  case "$file" in *.png|*.jpg|*.icns|*.ico|*.gif|*.webp) continue ;; esac
  [ -f "$file" ] || continue
  check "$file" "$file"
done < <(git ls-files -z)

if [ "$found" = 1 ]; then
  echo "check-public.sh: personal data in tracked files (above). Replace it with a placeholder." >&2
  exit 1
fi
echo "No personal data found in tracked files."
