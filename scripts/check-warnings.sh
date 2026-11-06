#!/bin/sh
# Fails if a build log has a compiler or linker warning of ours: located in Sources/ or Tests/, inside a macro expansion
# (`#expect` in our tests), or not tied to a file (linker, SwiftPM). Warnings located in other files (GhosttyKit's
# headers) are not ours. The one allowed line is the linker's debug-map note on Ghostty's ImGui inspector symbols.
# Usage: scripts/check-warnings.sh <build log>   (e.g. swift build --build-tests 2>&1 | tee build.log)
set -eu

log=${1:?usage: check-warnings.sh <build log>}
root=$(pwd -P)  # swiftc prints resolved paths (/tmp is /private/tmp)

found=$(perl -pe 's/\e\[[0-9;]*m//g; s/\e\]8;;.*?\e\\//g' "$log" \
  | grep -E "^(($root/)?(Sources|Tests)/[^:]+:[0-9]+:[0-9]+: warning:|macro expansion [^:]+:[0-9]+:[0-9]+: warning:|(ld: )?warning:)" \
  | grep -vE "^warning: \(arm64\) +could not find symbol '_(ImGuiStyle_ImGuiStyle|ImFontConfig_ImFontConfig)' in object file '[^']*/libghostty-fat\.a\(ext\.o\)'$" \
  | sort -u || true)

[ -z "$found" ] && { echo "No warnings."; exit 0; }
echo "$found" | while IFS= read -r line; do echo "::error::$line"; done
echo "$(echo "$found" | wc -l | tr -d ' ') warning(s) in our code: fix them, the build stays warning-free." >&2
exit 1
