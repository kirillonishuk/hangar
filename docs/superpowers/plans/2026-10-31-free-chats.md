# Чаты без проекта — план реализации

Спека: `docs/superpowers/specs/2026-10-31-free-chats-design.md` (утверждена вместе с макетом `mockups/free-chats.html`; владелец принял обе рекомендации: перетаскивание вставляет `@<файл> ` в ввод агента, «Все» в Истории показывает группу «Чаты» первой). Ветка `feat/free-chats`. Сборка — `../hg-build.sh swift build`, тесты — `../hg-heavy.sh swift test --num-workers 3 --filter …` (полный прогон перед PR).

Каждая задача: сначала тест (для логики), потом код, `swift build`, отфильтрованные тесты, коммит. Номера разделов — из спеки.

## Задача 1. Модель (§2) — `Workspace`
Файлы: `Sources/Workspace/FreeChat.swift` (новый), `Sources/Workspace/Model.swift`; тест `Tests/WorkspaceTests/FreeChatTests.swift`.
- `FreeChat { id, lastUsedAt }`; `WorkspaceState.freeChats` (decodeIfPresent), `chatsFolder` (не кодируется); `cwd(for:)`.
- `addFreeChat`, `freeChat(ofTask:)`, `isFreeChatTask`, `touchFreeChat`, `sleepFreeChat`, `wakeFreeChat`, `removeFreeChat`, `freeChatTasks` (порядок: закреплённые, затем `lastUsedAt`↓, затем id).
- `closeTab` последней вкладки чата без проекта → сон; `addResumeTab` разрешён.
Проверка: `swift test --filter FreeChatTests` и `--filter WorkspaceTests`.

## Задача 2. Состояние приложения (§3, §5, §7, §8) — `HangarUI`
Файлы: `AppState+FreeChats.swift` (новый), `AppState.swift`, `AppState+Agents.swift`, `AppState+Control.swift`, `AppState+Attention.swift`, `WindowTitleBar.swift`, `InspectorWatch.swift`, `SplitView.swift`, `EmptyState.swift`; тест `Tests/HangarUITests/FreeChatsTests.swift`.
- `chatsFolder` из `StateStore.directory`; `ensureChatsFolder()` перед запуском листа в этой папке.
- `newFreeChat()` («Чат N» по чатам без проекта, `autoNamed`, `defaultAgent`), `sleepFreeChat`/`wakeFreeChat`/`removeFreeChat` (остановка поверхностей как у архива), `placeName(of:)` («Без проекта»), `isOutsideProjects`.
- `touchFreeChat` на `.prompt`/`.codexNotify` своего агента; `orderedTasks` с открытыми видимыми чатами; CLI/MCP их не видят.
- Тулбар: «Без проекта», без кнопки ветки; инспектор: корень `chatsFolder`; пустое окно: вторая кнопка.
Проверка: `--filter FreeChatsTests`, `--filter RestoreTests`, `--filter ControlRequestTests`.

## Задача 3. Клавиша и палитра (§8)
Файлы: `Shortcuts.swift`, `Palette.swift`, `MainWindow.swift`, `L10n.swift`, `Localizable.strings` ru/en; тесты `ShortcutsTests`, `PaletteTests`.
- `Shortcut.newFreeChat` ⌥⌘N (keyCode 45); команда палитры; чаты без проекта в разделе «Чаты» палитры (выбор спящего будит).
Проверка: `--filter ShortcutsTests`, `--filter PaletteTests`, `--filter L10nTests`.

## Задача 4. Сайдбар (§4)
Файлы: `SidebarView.swift` (+ при необходимости `SidebarFreeChats.swift`), `Theme+Sidebar.swift`, `Actions.swift`, `PopoverMenu.swift`, `MainWindow.swift` (маршрут ⌘W/⇧⌘W), `L10n`.
- Секция «Чаты» первой; строки (точка/пусто, имя, слово или время), «Все чаты (N)…», пусто — заголовок с «+»; фильтр «ждущие»; рейка.
- `freeChatTime(_:now:calendar:)` — таблица §4.2 (тест).
- Меню открытого/спящего, «Убрать из списка…» с подтверждением; видимый список (≤ 7, открытый/выбранный всегда) — тест.
Проверка: `--filter FreeChatsTests`, `--filter SidebarRedesignTests`, `--filter ActionsTests`.

## Задача 5. Перетаскивание в «Файлы» (§7)
Файлы: `InspectorView.swift`, `AppState+FreeChats.swift`; тест в `FreeChatsTests` (копирование: имя занято → «имя 2.ext», оригинал цел; текст вставки).
Проверка: `--filter FreeChatsTests`.

## Задача 6. История (§6)
Файлы: `Sources/History/History.swift` (`matching`), `SessionsRows.swift`, `SessionsModel.swift`, `SessionsView.swift`, `SessionsRowViews.swift`, `AppState+History.swift`; тесты `HistoryTests`, `SessionsModelTests`.
- `SessionsScope.chats`, сегмент; источник «чаты»; группы по дню в «Чатах», группа «Чаты» первой во «Все»; действия (Перейти / Продолжить-будит / Продолжить-новый чат); «Убрать из списка» в меню; чипы состояний скрыты; плейсхолдер; поиск по тексту (250 мс); `Chats` исключена из сканов проектов.
Проверка: `--filter HistoryTests`, `--filter SessionsModelTests`.

## Задача 7. Документы
`specs/2026-10-30-design-system.md` §3.1, §3.3, §3.17; `docs/design/DESIGN.md` (⌥⌘N); `docs/decisions.md` — новая запись следующим свободным номером (проверить `origin/main` и открытые PR).

## Задача 8. Живая проверка и PR
- Изолированный DEBUG (`/tmp/hg-free-chats`: `HANGAR_STATE_DIR`, `HANGAR_CONFIG` с фейковыми `claude`/`codex`, `HANGAR_DEBUG_NO_ACTIVATE=1`, свой канал); сценарий §12; снимки окна по id (не полный экран; окно закрыто — так и сказать).
- Полный `swift test` (через `hg-heavy.sh`), `scripts/check-commits.sh`, rebase на `origin/main` (без force push — если нужен, спросить), PR «feat: chats without a project», метка `minor`, без merge.
