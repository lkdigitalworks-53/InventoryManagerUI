#!/usr/bin/env bash
# Guards for the `deployed-main` tag (the last deployed commit).  usage: deploy-tag.sh stale | mark
#
#   stale  exit 1 when $GITHUB_SHA is STRICTLY OLDER than the tag (an older approved run must never
#          overwrite newer code). Equal or newer or no tag => exit 0 (re-deploying the same commit is fine).
#   mark   move the tag to $GITHUB_SHA and push it, FORWARD ONLY: when the tag is already ahead, leave it.
#
# env: GITHUB_SHA (required). Needs full history (checkout fetch-depth: 0) and, for `mark`, push rights.
set -euo pipefail
sha="${GITHUB_SHA:?GITHUB_SHA is required}"
tag=refs/tags/deployed-main

is_stale() {
  git rev-parse -q --verify "$tag" >/dev/null || return 1
  [ "$(git rev-parse "$tag^{commit}")" != "$sha" ] && git merge-base --is-ancestor "$sha" "$tag"
}

case "${1:-}" in
  stale)
    if is_stale; then
      echo "::error::$sha is older than the last deployed commit ($(git rev-parse --short "$tag^{commit}")). A newer deploy already shipped; refusing to deploy older code over it."
      exit 1
    fi
    ;;
  mark)
    if is_stale; then
      echo "deployed-main is already ahead of $sha; leaving it."
      exit 0
    fi
    git tag -f deployed-main "$sha"
    git push --force origin "$tag"
    ;;
  *)
    echo "usage: deploy-tag.sh stale|mark" >&2
    exit 2
    ;;
esac
