#!/usr/bin/env bash
# This repo is public. Fails when a tracked file holds something personal: a home folder path,
# an Apple Team ID in a signing identity, Vercel team/project IDs, Render service IDs or keys.
#   scripts/check-public.sh          checks all tracked files (CI runs this)
set -euo pipefail
cd "$(dirname "$0")/.."

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

found=0
while IFS= read -r -d '' file; do
  [ "$file" = scripts/check-public.sh ] && continue
  case "$file" in *.png|*.jpg|*.icns|*.ico|*.gif|*.webp) continue ;; esac
  for p in "${patterns[@]}"; do
    if hits="$(grep -nIE "$p" "$file" | grep -vE "$allowed")"; then
      while IFS= read -r line; do echo "$file:$line"; done <<<"$hits"
      found=1
    fi
  done
done < <(git ls-files -z)

if [ "$found" = 1 ]; then
  echo "check-public.sh: personal data in tracked files (above). Replace it with a placeholder." >&2
  exit 1
fi
echo "No personal data found in tracked files."
