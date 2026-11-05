#!/usr/bin/env bash
# Checks docs/decisions/: names HD-NNN-<slug>.md, unique numbers, each file opens with its own
# "# HD-NNN — " heading, and docs/decisions.md links every file (and only existing ones).
set -euo pipefail
cd "$(dirname "$0")/.."

dir=docs/decisions
index=docs/decisions.md
fail=0
err() { echo "check-decisions: $*" >&2; fail=1; }

[ -d "$dir" ] && [ -f "$index" ] || { echo "check-decisions: $dir or $index missing" >&2; exit 1; }

for path in "$dir"/*; do
  name=${path##*/}
  case "$name" in
    HD-*)
      if ! [[ "$name" =~ ^HD-([0-9]{3})-[a-z0-9]+(-[a-z0-9]+)*\.md$ ]]; then
        err "$name: name must match HD-NNN-<slug>.md (slug: a-z, 0-9, '-')"
        continue
      fi
      num=${BASH_REMATCH[1]}
      head -n 1 "$path" | grep -q "^# HD-$num — " || err "$name: first line must be '# HD-$num — <date> — <title>'"
      ;;
    *)
      [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*\.md$ ]] || err "$name: unexpected file name"
      ;;
  esac
  grep -qF "](decisions/$name)" "$index" || err "$name: not linked from $index"
done

dups=$(ls "$dir" | grep -o '^HD-[0-9]\{3\}' | sort | uniq -d || true)
[ -z "$dups" ] || err "duplicate numbers: $(echo $dups)"

for link in $(grep '^- \[' "$index" | grep -o '](decisions/[^)]*)' | sed 's/^](decisions\///; s/)$//'); do
  [ -f "$dir/$link" ] || err "$index links missing file decisions/$link"
done

[ "$fail" = 0 ] && echo "check-decisions: ok ($(ls "$dir" | grep -c '^HD-') decisions)"
exit "$fail"
