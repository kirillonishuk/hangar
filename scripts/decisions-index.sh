#!/usr/bin/env bash
# Prints the decision list on demand: HD-NNN — date — title — path (from each file's first line).
set -euo pipefail
cd "$(dirname "$0")/.."
for f in docs/decisions/HD-*.md; do
  printf '%s — %s\n' "$(head -n 1 "$f" | sed 's/^# //')" "$f"
done
