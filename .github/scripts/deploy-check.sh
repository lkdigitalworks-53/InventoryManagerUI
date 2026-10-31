#!/usr/bin/env bash
# Prints `true` or `false`: does a Firebase deploy need to run for $GITHUB_SHA?
#
# Compares against the LAST DEPLOYED commit (tag `deployed-main`), not against the push, so a deploy
# that was rejected or superseded can never lose a change. FAILS OPEN: anything unexpected prints
# `true` (a needless approval prompt is cheap, a silently skipped deploy is not).
#
# env: GITHUB_SHA (default HEAD), EVENT (`workflow_dispatch` => always true: manual re-run).
set -uo pipefail
sha="${GITHUB_SHA:-HEAD}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${EVENT:-}" = "workflow_dispatch" ] || ! git rev-parse -q --verify refs/tags/deployed-main >/dev/null; then
  echo true
  exit 0
fi

# --no-renames: a file moved OUT of functions/ must show up as a deletion at its old path.
# -z: raw NUL-separated paths; without it git quotes non-ASCII names and the prefix match is lost.
# pipefail (above): a failing `git diff` fails the whole substitution => fail open.
if out=$(git diff --name-only --no-renames -z refs/tags/deployed-main "$sha" | node "$here/deploy-paths.js") \
   && { [ "$out" = true ] || [ "$out" = false ]; }; then
  echo "$out"
else
  echo true
fi
