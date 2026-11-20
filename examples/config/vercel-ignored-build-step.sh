#!/bin/sh
# Vercel: Settings -> Git -> Ignored Build Step -> "Run my bash script": sh ./vercel-ignored-build-step.sh
# Exit 0 skips the build, exit 1 runs it (Vercel's own convention). Put the script in the project's
# folder of a monorepo; it builds only when something under that folder, or the shared packages, changed.
# PATHS can be set in the setting's command: PATHS="apps/web packages/ui" sh ./vercel-ignored-build-step.sh
PATHS="${PATHS:-. ../../packages}"
# The first push of a branch has no parent to compare with: build.
git rev-parse --verify -q HEAD^ >/dev/null || { echo "no parent commit: building"; exit 1; }
# shellcheck disable=SC2086
if git diff --quiet HEAD^ HEAD -- $PATHS; then
  echo "nothing changed in: $PATHS: skipping the build"
  exit 0
fi
echo "changes in: $PATHS: building"
exit 1
