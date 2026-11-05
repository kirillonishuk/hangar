# Открытые вопросы (отвечает спайк, этап 0)

- [x] Жизнеспособность embed GhosttyKit: работает; v1.3.1 + upstream-фикс libtool a83a82b применяется в скрипте сборки, пока тег его не включит.
- [x] Пауза рендера скрытой surface: `ghostty_surface_set_occlusion(surface, false)`.
- [x] Чтение текста экрана: `ghostty_surface_read_text` (+ `ghostty_surface_free_text`).
- [ ] Codex: есть ли `~/.codex/hooks.json` в установленной версии или только `notify` — codex не установлен, проверка отложена.
- [ ] Codex: доступен ли `codex app-server` и `account/rateLimits/read` — codex не установлен, проверка отложена.
- [x] Claude 2.1.302: `rate_limits.five_hour/seven_day` в stdin статус-лайна приходят (после первого ответа); `StopFailure` matcher `rate_limit` принимается без ошибок, но не вызывался (не проверить).
- [x] `claude --resume <id>` и `claude --continue` восстанавливают сессию в cwd (да).
- [ ] `codex resume <id>` восстанавливает сессию — codex не установлен, проверка отложена.
- [x] Окружение: установлены zig@0.15 (keg-only), helix и Metal Toolchain — с согласия пользователя; codex отсутствует.
- [x] SSH (этап 6): закрыто решением #47 — `StreamLocalBindUnlink` обходится `rm -f` сокета перед `-O forward`; версии tmux на целевых серверах — ручная проверка.
