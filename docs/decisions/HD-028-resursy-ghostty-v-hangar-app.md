# HD-028 — 2026-10-18 — Ресурсы Ghostty в `Hangar.app`:

`scripts/bundle.sh` копирует terminfo и `share/ghostty` из `zig-out/share` в `Contents/Resources`. Почему: иначе при запуске из Finder нет `xterm-ghostty` и shell integration (нет `PWD`, `COMMAND_FINISHED`). Отвергнуто: полагаться на env родителя.
