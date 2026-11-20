#!/bin/sh
# Vercel: Settings -> Git -> Ignored Build Step -> "Run my bash script": sh ./vercel-ignored-build-step.sh
# Exit 0 skips the build, exit 1 runs it (Vercel's own convention). Vercel runs the command in the project's Root
# Directory, so PATHS are relative to it. For a monorepo with the project in apps/web:
#   PATHS=". ../../packages/ui" sh ./vercel-ignored-build-step.sh
# The baseline is VERCEL_GIT_PREVIOUS_SHA, the last commit of this branch that Vercel deployed, so a commit that
# only touched another app cannot hide an earlier change to this one. No baseline, or one this clone does not have
# (a shallow clone): build.
PATHS="${PATHS:-. ../../packages}"
base="${VERCEL_GIT_PREVIOUS_SHA:-}"
[ -n "$base" ] && git cat-file -e "$base^{commit}" 2>/dev/null || { echo "no previous deployment to compare with: building"; exit 1; }
# shellcheck disable=SC2086
if git diff --quiet "$base" HEAD -- $PATHS; then
  echo "nothing changed in: $PATHS since ${base%"${base#???????}"}: skipping the build"
  exit 0
fi
echo "changes in: $PATHS: building"
exit 1
