# HD-026 — 2026-10-18 — Код выхода через обёртку OSC 133:

Ghostty на macOS запускает команду через `/usr/bin/login`, код выхода всегда 0. Команда вкладки: `<shell> -l -i -c '<inner>; c=$?; printf "\e]133;C\a\e]133;D;%d\a" $c; exit $c'`; код берётся из `GHOSTTY_ACTION_COMMAND_FINISHED`, поэтому `<inner>` без `exec`. Почему: проверено спайком (`exit 3` → `exit_code=3`). Отвергнуто: `exec claude` и `exit_code` из `SHOW_CHILD_EXITED`.
