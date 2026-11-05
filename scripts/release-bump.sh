#!/usr/bin/env bash
# Prints the version bump for a batch of merged PRs: the highest of their bumps (major > minor > patch), or "none" when
# every PR is labelled no-release (or there are none). Input on stdin, one PR per line: "<title>\t<labels, space-separated>".
# Per PR: label major/minor/patch, else the title's conventional-commit type (type!: major, feat: minor), else patch.
# Rules: docs/RELEASING.md.
set -euo pipefail

rank=0
while IFS=$'\t' read -r title labels || [ -n "$title" ]; do
  [ -n "$labels$title" ] || continue
  labels=" $labels "
  if [[ "$labels" == *" no-release "* ]]; then continue
  elif [[ "$labels" == *" major "* ]]; then r=3
  elif [[ "$labels" == *" minor "* ]]; then r=2
  elif [[ "$labels" == *" patch "* ]]; then r=1
  elif [[ "$title" =~ ^[a-z]+(\([^\)]*\))?!: ]]; then r=3
  elif [[ "$title" =~ ^feat(\([^\)]*\))?: ]]; then r=2
  else r=1; fi
  [ "$r" -gt "$rank" ] && rank=$r
done
case "$rank" in
  3) echo major ;;
  2) echo minor ;;
  1) echo patch ;;
  *) echo none ;;
esac
