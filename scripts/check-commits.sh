#!/bin/sh
# Fails if any commit in RANGE has a Co-Authored-By trailer or an author/committer outside the owner's emails.
# Usage: scripts/check-commits.sh <base>..<head>
set -eu

range=${1:?usage: check-commits.sh <base>..<head>}
owner='kirillonishuk@yandex.by 38956664+kirillonishuk@users.noreply.github.com'

allowed() { for e in $owner $2; do [ "$1" = "$e" ] && return 0; done; return 1; }

bad=0
for sha in $(git rev-list "$range"); do
  ae=$(git log -1 --format=%ae "$sha")
  ce=$(git log -1 --format=%ce "$sha")
  problems=''
  allowed "$ae" '' || problems="$problems author <$ae>;"
  # GitHub web merges and edits are committed by noreply@github.com.
  allowed "$ce" noreply@github.com || problems="$problems committer <$ce>;"
  coauthors=$(git log -1 --format=%B "$sha" | grep -i '^co-authored-by:' || true)
  [ -n "$coauthors" ] && problems="$problems Co-Authored-By trailer;"
  if [ -n "$problems" ]; then
    bad=1
    echo "::error::$(git log -1 --format='%h %s' "$sha"):$problems"
    [ -n "$coauthors" ] && echo "$coauthors" | sed 's/^/    /'
  fi
done

if [ "$bad" -ne 0 ]; then
  echo "Commits must be authored and committed by the owner (git config user.*), with no Co-Authored-By trailers."
  echo "Fix with an interactive rebase (reword / git commit --amend --reset-author), then force-push the branch."
  exit 1
fi
echo "All commits in $range: OK"
