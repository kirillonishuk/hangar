# Hangar — этапы 0 (спайк) и 1 (сайдбар, задачи, вкладки, восстановление) — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Подтвердить, что GhosttyKit встраивается и отвечает на открытые вопросы (этап 0), затем собрать первое рабочее приложение: проекты и задачи в сайдбаре, вкладки-терминалы (claude/codex/hx/zsh) со сплитами, сохранение и восстановление после перезапуска (этап 1).

**Порядок:** 6 → 6d → 6b → 6c → 7.

**Architecture:** SwiftPM-пакет: библиотеки `Workspace` и `Exec` (без UI, с тестами), `GhosttyBridge` (единственная точка C-API GhosttyKit), `HangarUI` (AppKit + SwiftUI), исполняемый `HangarApp`. `.app` собирается скриптом из бинарника SwiftPM — без `.xcodeproj` в репозитории. GhosttyKit — `binaryTarget` на локально собранный xcframework (в `.gitignore`).

**Tech Stack:** Swift 6.3, Swift Testing (`import Testing`), AppKit + SwiftUI, GhosttyKit (Zig-сборка Ghostty на закреплённом коммите), macOS 14+, Apple Silicon.

**Spec:** `docs/superpowers/specs/2026-10-18-hangar-design.md` (§2, §3, §4, §6, §9, §11). Правила — `AGENTS.md`. Дизайн — `docs/design/DESIGN.md`. Решения — `docs/decisions.md`.

Этапы 2–6 получат отдельные планы после спайка: их интерфейсы зависят от ответов этапа 0.

## Global Constraints

- macOS 14+, Apple Silicon; `platforms: [.macOS(.v14)]`.
- Только `GhosttyBridge` импортирует GhosttyKit. `Workspace`, `Exec` — без `AppKit`/`SwiftUI`.
- Без сторонних зависимостей, кроме GhosttyKit. Новая — только с записью в `decisions.md`.
- Данные: `~/Library/Application Support/Hangar/state.json`; конфиг `~/.config/hangar/config.toml`.
- Запись состояния: debounce 500 мс + при выходе; атомарно (temp + rename); битый файл → `state.json.bak`, пустое состояние, предупреждение.
- В простое — ноль таймеров и опросов; скрытые surface на паузе рендера.
- Цвета и размеры UI — только из `Theme` (значения `DESIGN.md`), не литералами.
- `⌘`-клавиши сопоставляются по `keyCode` (работают в русской раскладке).
- Агент по умолчанию — `claude` (`default_agent` в конфиге).
- Ничего не устанавливать и не менять в `~/.claude`, `~/.codex`, конфиге Ghostty без явного согласия пользователя.
- Diff-вкладки не сохраняются (появятся на этапе 4).
- Команды вкладок: `<shell> -l -i -c` + обёртка OSC 133 для кода выхода (решения #26, #27).

## Review Focus

1. **PATH у GUI-приложения.** Hangar, запущенный из Finder/Dock, не наследует PATH из `~/.zshrc`; `claude` лежит в `~/.local/bin`. Ожидание: вкладки claude/codex/hx стартуют так же, как из терминала. Тест — Task 4 (`launchUsesLoginShell`: `-l -i`, решение #27).
2. **Падение посреди записи `state.json`.** Ожидание: на диске всегда либо старое, либо новое целое состояние. Тест — Task 3 (`saveIsAtomic`), плюс `corruptFileIsBackedUp`.
3. **Папку проекта удалили/переместили между запусками.** Ожидание: проект восстанавливается с пометкой «папка не найдена», вкладки не стартуют, приложение не падает. Тест — Task 4 (`missingCwdIsReported`), UI — Task 7.
4. **Имена задач с пробелами, кириллицей, `/`.** Ожидание: работают; id не выводятся из имён; в команды имя не подставляется без экранирования. Тест — Task 2 (`taskNamesAreNotIdentifiers`), Task 4 (`argumentsAreShellQuoted`).
5. **Русская раскладка.** Ожидание: `⌘T`, `⌘W`, `⌘1…9`, `⌘N`, `⌘D` работают при включённой русской раскладке. Тест — Task 6 (`shortcutsMatchByKeyCode`).

---

## Этап 0 — спайк (код выбрасывается, результат — ответы в `decisions.md`)

### Task 0.1: Инструменты и сборка GhosttyKit

**Files:**
- Create: `scripts/build-ghosttykit.sh`
- Create: `vendor/GHOSTTY_COMMIT` (одна строка — SHA)
- Modify: `.gitignore` (добавить `vendor/ghostty-src/`, `vendor/GhosttyKit.xcframework/`)

- [ ] **Step 1: Согласовать установку.** Спросить пользователя одним сообщением: `brew install zig helix` и способ установки Codex CLI (`brew install codex` или `npm i -g @openai/codex`). Версию Zig взять из `build.zig.zon` / README Ghostty на выбранном коммите. Без «да» — стоп.
- [ ] **Step 2: Закрепить коммит.** Взять последний релизный тег Ghostty (`gh api repos/ghostty-org/ghostty/releases/latest`), записать SHA в `vendor/GHOSTTY_COMMIT`.
- [ ] **Step 3: Написать `scripts/build-ghosttykit.sh`.** Клонирует в `vendor/ghostty-src` на SHA из `vendor/GHOSTTY_COMMIT`, собирает xcframework командой из `HACKING.md`/`macos/` Ghostty на этом коммите, копирует результат в `vendor/GhosttyKit.xcframework`. `set -euo pipefail`; повторный запуск — без повторного клона.
- [ ] **Step 4: Запустить.** Run: `scripts/build-ghosttykit.sh && ls vendor/GhosttyKit.xcframework/macos-arm64*/`
  Expected: в каталоге есть `libghostty.a` (или `.framework`) и `Headers/ghostty.h`.
- [ ] **Step 5: Commit** — `git add scripts/build-ghosttykit.sh vendor/GHOSTTY_COMMIT .gitignore && git commit -m "build: script to build GhosttyKit at pinned commit"`

### Task 0.2: Один терминал в своём окне + ответы по API

**Files:**
- Create: `spike/` (выбрасывается)
- Modify: `.gitignore` (добавить `spike/`)

- [ ] **Step 1:** Минимальное AppKit-приложение в `spike/`, которое по образцу `macos/Sources/Ghostty/` из Ghostty создаёт `ghostty_app_t` и одну surface с `zsh` в `NSWindow`. Run: собрать и запустить. Expected: в окне работает zsh, ввод и вывод корректны, применяется `~/.config/ghostty/config` (видна `background-opacity = 0.95`).
- [ ] **Step 2: Ответить и записать в черновик ответов** (по каждому пункту — имя функции/колбэка C-API или «нет»):
  1. Как задать на surface команду, `cwd` и env (`HANGAR_TAB_ID`, `HANGAR_SOCKET`).
  2. Колбэки: смена заголовка, bell, desktop notification (OSC 9/777), выход дочернего процесса и его код.
  3. Пауза рендера скрытой surface (явный API или occlusion/`ghostty_surface_set_occlusion`); замер: 10 скрытых surface с `yes > /dev/null` не грузят GPU.
  4. Чтение текста экрана (для `hangar tabs read`).
  5. Сплиты: поддерживает ли API только surface (сплиты делаем сами в AppKit) — ожидаемо да.
  6. Запускает ли Ghostty команду через login shell (`$SHELL -l -c`) — важно для PATH (Review Focus 1).
- [ ] **Step 3: Замер простоя.** Окно с 1 surface, 10 минут без активности. Run: `top -l 2 -s 5 -pid <pid> -stats pid,cpu,mem | tail -1`. Expected: CPU ≈ 0%. Записать CPU и RSS.

### Task 0.3: Проверки агентов (без изменения файлов пользователя)

- [ ] **Step 1: Claude.** Временный файл настроек в `spike/claude-settings.json` со `statusLine` (команда пишет stdin в `spike/sl.json`) и hook `StopFailure` (`matcher: "rate_limit"`) — подключать через `claude --settings spike/claude-settings.json` (не трогая `~/.claude/settings.json`). Проверить: есть ли `rate_limits.five_hour/seven_day` в `spike/sl.json`; приходит ли `session_id` в hooks; `claude --resume <id>` открывает ту же сессию; есть ли `claude --continue` для «последней в cwd».
- [ ] **Step 2: Codex** (если установлен в Task 0.1). Проверить: `codex app-server` отвечает на `account/rateLimits/read`; формат `~/.codex/hooks.json` установленной версии (события, payload, есть ли session id) — только чтение; `codex resume <id>` и `codex resume --last`.
- [ ] **Step 3: Записать ответы.** В `docs/decisions.md` закрыть пункты «Открытые вопросы» (отметить `[x]` + короткий ответ) и добавить запись-решение «Интерфейс `GhosttyBridge`» с точными сигнатурами (см. Task 5). Если embed не работает — стоп, сообщить пользователю (возврат к выбору подхода, решение #2).
- [ ] **Step 4: Commit** — `git commit -am "docs: spike results (GhosttyKit API, agent CLIs)"`

**Gate:** этап 1 начинается только после Task 0.3 Step 3 без блокеров.

---

## Этап 1 — сайдбар, задачи, вкладки, восстановление

### Файловая структура

```
Package.swift
Sources/Workspace/        Model.swift, Store.swift, Config.swift
Sources/Exec/             Launch.swift, ShellQuote.swift
Sources/GhosttyBridge/    GhosttyApp.swift, TerminalSurfaceView.swift
Sources/HangarUI/         Theme.swift, AppState.swift, MainWindow.swift,
                          SidebarView.swift, TabBarView.swift, SplitView.swift,
                          NewTaskSheet.swift, Shortcuts.swift
Sources/HangarApp/        main.swift
Tests/WorkspaceTests/     ModelTests.swift, StoreTests.swift, ConfigTests.swift
Tests/ExecTests/          LaunchTests.swift
Tests/HangarUITests/      ShortcutsTests.swift
scripts/bundle.sh         Resources/Info.plist
```

### Task 1: Пакет, Theme, пустое окно, сборка `.app`

**Files:**
- Create: `Package.swift`, `Sources/HangarApp/main.swift`, `Sources/HangarUI/Theme.swift`, `Sources/HangarUI/MainWindow.swift`, `scripts/bundle.sh`, `Resources/Info.plist`

**Interfaces:**
- Produces: `enum Theme` со статическими `NSColor`/`Color` и `CGFloat` из `DESIGN.md` (цвета: `bg, sidebar, panel, line, control, field, text, textStrong, textRow, text2, text3, selection, accent, primary`, статусы `working, waiting, done, failed, idle`; размеры: `sidebarWidth = 220, sidebarMin = 180, sidebarMax = 320, tabBarHeight = 38, trafficLightsHeight = 38, windowRadius = 12`); `final class MainWindowController: NSWindowController`.

- [ ] **Step 1:** `Package.swift`: targets `Workspace`, `Exec` (depends `Workspace`), `GhosttyBridge` (depends binaryTarget `GhosttyKit` path `vendor/GhosttyKit.xcframework`), `HangarUI` (depends все), executable `HangarApp`; test targets `WorkspaceTests`, `ExecTests`, `HangarUITests`.
- [ ] **Step 2:** `MainWindowController` — `NSWindow` со `.fullSizeContentView`, прозрачный titlebar, без тулбара; `NSSplitViewController`: сайдбар (`Theme.sidebarWidth`, min/max) | пустая область `Theme.panel`.
- [ ] **Step 3:** `scripts/bundle.sh`: `swift build -c release`, собирает `build/Hangar.app` (`Contents/MacOS/Hangar`, `Info.plist` с `CFBundleIdentifier = app.hangar.Hangar`, `LSMinimumSystemVersion = 14.0`), ad-hoc `codesign -s -`; копирует ресурсы Ghostty (`vendor/ghostty-src/zig-out/share/terminfo` → `Contents/Resources/terminfo`, `vendor/ghostty-src/zig-out/share/ghostty` → `Contents/Resources/ghostty`; решение #28).
- [ ] **Step 4: Проверить.** Run: `scripts/bundle.sh && open build/Hangar.app`. Expected: окно со светофором над сайдбаром 220 pt, цвета `#1a1b1f` / `#282a31`; при запуске из Finder `echo $TERM` в терминале (после Task 5) = `xterm-ghostty`.
- [ ] **Step 5: Commit** — `feat: package skeleton, theme, empty main window`

### Task 2: Модель `Workspace`

**Files:**
- Create: `Sources/Workspace/Model.swift`, `Tests/WorkspaceTests/ModelTests.swift`

**Interfaces:**
- Produces:
  - `struct Project: Codable, Identifiable { id: UUID; name: String; location: Location; lastBaseBranch: String? }`, `enum Location: Codable { case local(path: String) }` (ssh — этап 6, кейс не добавлять).
  - `struct HangarTask: Codable, Identifiable { id: UUID; projectId: UUID; name: String; mode: TaskMode; order: Int; archived: Bool; tabs: [Tab]; activeTabId: UUID? }`, `enum TaskMode: Codable { case mainFolder; case worktree(path: String, branch: String, base: String) }`.
  - `struct Tab: Codable, Identifiable { id: UUID; title: String; root: SplitNode; focusedLeafId: UUID }`.
  - `indirect enum SplitNode: Codable { case leaf(Leaf); case split(axis: Axis, ratio: Double, first: SplitNode, second: SplitNode) }`, `enum Axis: String, Codable { case horizontal, vertical }`.
  - `struct Leaf: Codable, Identifiable { id: UUID; kind: LeafKind; cwd: String; agentSessionId: String?; openFile: String? }`, `enum LeafKind: String, Codable { case claude, codex, editor, shell }`.
  - `struct WorkspaceState: Codable { var projects: [Project]; var tasks: [HangarTask]; var selectedTaskId: UUID?; var inspectorVisible: Bool }` с мутациями: `addProject(name:path:) -> UUID`, `addTask(projectId:name:) -> UUID`, `addTab(taskId:kind:) -> UUID`, `closeTab(taskId:tabId:)`, `split(taskId:tabId:leafId:axis:kind:) -> UUID`, `closeLeaf(taskId:tabId:leafId:)`, `moveTask(id:to:)`, `select(taskId:)`, `archiveTask(id:)`, `tasks(in projectId: UUID) -> [HangarTask]` (по `order`, без архивных).

- [ ] **Step 1: Тесты** (Swift Testing):
  - `addTaskAppendsInOrder`: две задачи → `order` 0, 1; `tasks(in:)` в этом порядке.
  - `taskNamesAreNotIdentifiers`: задачи `"fix auth"`, `"исправить/логин"`, `"fix auth"` (дубль) создаются, у всех разные `id`.
  - `newTaskCwdIsProjectPath`: `addTab(kind: .claude)` в задаче `.mainFolder` → `leaf.cwd == project path`.
  - `closeLastLeafClosesTab`: split → два листа; `closeLeaf` одного → `.leaf`; `closeLeaf` последнего → вкладки нет, `activeTabId` переходит на соседнюю или `nil`.
  - `closeActiveTabSelectsNeighbor`: три вкладки, закрыть среднюю активную → активна следующая справа (или левая, если закрыта последняя).
  - `archivedTasksHidden`.
  - `roundTripCodable`: состояние со сплитом и всеми видами листов → JSON → равно исходному.
- [ ] **Step 2:** Run: `swift test --filter WorkspaceTests.ModelTests` — Expected: FAIL (типов нет).
- [ ] **Step 3:** Реализовать типы и мутации в `Model.swift`. `Equatable` на всех типах для тестов.
- [ ] **Step 4:** Run: `swift test --filter WorkspaceTests.ModelTests` — Expected: PASS.
- [ ] **Step 5: Commit** — `feat(workspace): project/task/tab/split model`

### Task 3: Хранилище состояния

**Files:**
- Create: `Sources/Workspace/Store.swift`, `Tests/WorkspaceTests/StoreTests.swift`

**Interfaces:**
- Consumes: `WorkspaceState` (Task 2).
- Produces: `final class StateStore { init(directory: URL, debounce: Duration = .milliseconds(500)); func load() -> LoadResult; func scheduleSave(_ state: WorkspaceState); func saveNow(_ state: WorkspaceState) throws }`, `enum LoadResult { case empty; case loaded(WorkspaceState); case recoveredFromCorrupt(backup: URL) }`. Файл `directory/state.json`; каталог создаётся при необходимости.

- [ ] **Step 1: Тесты** (временный каталог):
  - `missingFileLoadsEmpty`.
  - `saveThenLoadRoundTrips`.
  - `saveIsAtomic`: `saveNow` пишет через временный файл в том же каталоге и `rename` — после записи в каталоге только `state.json`, содержимое целиком декодируется; при `throws` на кодировании старый файл не изменён.
  - `corruptFileIsBackedUp`: `state.json` = `"{not json"` → `load()` == `.recoveredFromCorrupt`, есть `state.json.bak` с тем же содержимым, `state.json` больше не мешает следующему `saveNow`.
  - `debouncedSavesCoalesce`: `debounce: .milliseconds(50)`, три `scheduleSave` подряд → через 200 мс на диске последнее состояние; запись произошла 1 раз (счётчик через внедрённый `writeHook: ((Data) -> Void)?` для тестов).
- [ ] **Step 2:** Run: `swift test --filter StoreTests` — Expected: FAIL.
- [ ] **Step 3:** Реализовать. Debounce — `Task` с `sleep(for:)` и отменой предыдущего; без `Timer`. Атомарность — `Data.write(to:options: .atomic)`.
- [ ] **Step 4:** Run: `swift test --filter StoreTests` — Expected: PASS.
- [ ] **Step 5: Commit** — `feat(workspace): atomic debounced state store with corrupt-file backup`

### Task 4: Конфиг и команды запуска вкладок

**Files:**
- Create: `Sources/Workspace/Config.swift`, `Sources/Exec/Launch.swift`, `Sources/Exec/ShellQuote.swift`, `Tests/WorkspaceTests/ConfigTests.swift`, `Tests/ExecTests/LaunchTests.swift`
- Modify: `docs/superpowers/specs/2026-10-18-hangar-design.md` §6 — добавить «claude без `sessionId` → `claude --continue` в cwd» (если спайк подтвердил флаг).

**Interfaces:**
- Consumes: `Leaf`, `LeafKind` (Task 2).
- Produces:
  - `struct HangarConfig: Equatable { defaultAgent: LeafKind = .claude; editor: String = "hx"; agentCommands: [LeafKind: String] = [.claude: "claude", .codex: "codex"] }`, `static func parse(_ toml: String) throws -> HangarConfig`, `static func load(from url: URL) -> HangarConfig` (нет файла → значения по умолчанию).
  - `struct LaunchSpec: Equatable { command: String; cwd: String; env: [String: String] }`.
  - `func launchSpec(for leaf: Leaf, tabId: UUID, config: HangarConfig, socketPath: String, userShell: String, restoring: Bool, initialPrompt: String?) throws -> LaunchSpec`; `enum LaunchError: Error, Equatable { case missingCwd(String) }`.
  - `func shellQuote(_ s: String) -> String`.

- [ ] **Step 1: Тесты конфига:**
  - `defaultsWhenEmpty`: `parse("")` == значения по умолчанию.
  - `parsesSubset`: `default_agent = "codex"`, `editor = "nvim"`, секция `[agents]` с `claude = "claude --model opus"` → поля заполнены; комментарии `#` и пустые строки игнорируются.
  - `rejectsUnknownAgent`: `default_agent = "gpt"` → `throws`.
- [ ] **Step 2: Тесты запуска:**
  - `launchUsesLoginShell`: команда имеет вид `/bin/zsh -l -i -c '<inner>; c=$?; printf ...; exit $c'` (решения #26, #27; `-i` нужен, чтобы PATH был как в терминале); для shell-листа `<inner>` = `/bin/zsh -l -i`, для claude-листа `<inner>` = `claude`.
  - `exitCodeWrapperPresent`: команда содержит `c=$?; printf "\e]133;C\a\e]133;D;%d\a" $c; exit $c` и не содержит `exec`.
  - `claudeResumesById`: `agentSessionId = "abc"` → inner `claude --resume abc` (без `exec`); без id → `claude --continue`.
  - `initialPromptIsArgument`: `initialPrompt = "fix it's bug"` → inner `claude 'fix it'\''s bug'` (и аналогично для codex).
  - `codexResume`: с id → inner `codex resume <id>`; без id и при восстановлении → `codex resume --last`.
  - `editorOpensFile`: `openFile = "src/a b.ts"` → inner `hx 'src/a b.ts'`.
  - `argumentsAreShellQuoted`: `shellQuote("it's")` == `'it'\''s'`; session id с `;` не ломает команду.
  - `envHasTabAndSocket`: `env["HANGAR_TAB_ID"] == tabId.uuidString`, `env["HANGAR_SOCKET"] == socketPath`.
  - `missingCwdIsReported`: cwd не существует → `throws LaunchError.missingCwd`.
- [ ] **Step 3:** Run: `swift test --filter "ConfigTests|LaunchTests"` — Expected: FAIL.
- [ ] **Step 4:** Реализовать. Парсер — только подмножество: `key = "string"` и секции `[name]`; `// shortcut: минимальный TOML-подмножество, менять, если конфиг вырастет за плоские строки`.
- [ ] **Step 5:** Run: `swift test --filter "ConfigTests|LaunchTests"` — Expected: PASS.
- [ ] **Step 6: Commit** — `feat(exec): config subset and tab launch specs via login shell`

### Task 5: `GhosttyBridge`

**Files:**
- Create: `Sources/GhosttyBridge/GhosttyApp.swift`, `Sources/GhosttyBridge/TerminalSurfaceView.swift`

**Interfaces:**
- Consumes: `LaunchSpec` (Task 4); точные функции C-API — из записи «Интерфейс `GhosttyBridge`» в `decisions.md` (Task 0.3).
- Produces:
  - `@MainActor final class GhosttyApp { static let shared: GhosttyApp; func start() throws }` — один `ghostty_app_t`, конфиг пользователя.
  - `@MainActor final class TerminalSurfaceView: NSView { init(spec: LaunchSpec); var onTitleChange: ((String) -> Void)?; var onBell: (() -> Void)?; var onDesktopNotification: ((String, String) -> Void)?; var onChildExit: ((Int32) -> Void)?; func setVisible(_ visible: Bool); func sendText(_ text: String); func sendEnter(); func screenText() -> String? }`. `setVisible(false)` ставит рендер на паузу через `ghostty_surface_set_occlusion`. `sendText` — вставка (bracketed paste), Enter — `sendEnter()`. `onChildExit(-1)` = код неизвестен (нет `COMMAND_FINISHED`); обычный код — из OSC 133 D (решение #26).

- [ ] **Step 1:** Перенести рабочий код из `spike/` в эти два файла, оставив только перечисленный интерфейс; всё, что знает о `ghostty_*`, — внутри `GhosttyBridge`.
- [ ] **Step 2: Проверить вручную.** Временно в `MainWindowController` показать одну `TerminalSurfaceView` со spec из `launchSpec(kind: .shell)`. Run: `scripts/bundle.sh && open build/Hangar.app`. Expected: zsh работает; `echo $HANGAR_TAB_ID` печатает UUID; `which claude` находит `~/.local/bin/claude` при запуске из Finder; `exit 3` → `onChildExit(3)` (лог через `os_log`).
- [ ] **Step 3: Commit** — `feat(ghostty): bridge with surface view, callbacks and render pause`

### Task 6: UI — сайдбар, вкладки, сплиты, клавиши

**Files:**
- Create: `Sources/HangarUI/AppState.swift`, `SidebarView.swift`, `TabBarView.swift`, `SplitView.swift`, `NewTaskSheet.swift`, `Shortcuts.swift`, `Tests/HangarUITests/ShortcutsTests.swift`
- Modify: `Sources/HangarUI/MainWindow.swift`

**Interfaces:**
- Consumes: `WorkspaceState` и мутации (Task 2), `StateStore` (Task 3), `HangarConfig`, `launchSpec` (Task 4), `TerminalSurfaceView` (Task 5).
- Produces: `@MainActor @Observable final class AppState { var state: WorkspaceState; func perform(_ mutate: (inout WorkspaceState) -> Void) }` — каждая мутация вызывает `store.scheduleSave`. `enum Shortcut: CaseIterable { case newTask, newTab, closeTab, splitRight, splitDown, tab(Int), prevTask, nextTask, toggleInspector }`, `func shortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Shortcut?`.

- [ ] **Step 1: Тест клавиш** `shortcutsMatchByKeyCode`: `keyCode 17 + .command` → `.newTab` (T), `13` → `.closeTab` (W), `45` → `.newTask` (N), `2` → `.splitRight` (D), `2 + [.command, .shift]` → `.splitDown`, цифры `1…9` = keyCode `18, 19, 20, 21, 23, 22, 26, 28, 25` → `.tab(1…9)`, `33/30 + [.command, .shift]` → `.prevTask/.nextTask`, `34 + [.command, .option]` → `.toggleInspector`; без `.command` → `nil`. (keyCode — физические клавиши ANSI; русская раскладка не меняет keyCode.)
- [ ] **Step 2:** Run: `swift test --filter ShortcutsTests` — FAIL; реализовать `Shortcuts.swift`; PASS.
- [ ] **Step 3: Сайдбар** по `style-a-v2.html`: заголовки проектов (капс, `text3`, 10.5) с `+`; строки задач (точка статуса `idle` — статусы появятся на этапе 3; выбранная — `selection`); низ: «+ проект» (`NSOpenPanel`, только папки) и `⌘K`-подсказка. Контекстное меню задачи: «Переименовать», «Архивировать». Проект с несуществующей папкой — серый, подпись «папка не найдена».
- [ ] **Step 4: Полоса вкладок** по `style-a-v2.html`: название задачи (12 semibold) слева, вкладки (11.5, активная `panel`), `+` → меню Claude / Codex / Helix / Shell; закрытие `⌘W` и ×; заголовок вкладки — из `onTitleChange`.
- [ ] **Step 5: Сплиты.** `SplitView` строит `NSSplitView` из `SplitNode`; `⌘D` — вправо, `⌘⇧D` — вниз, новый лист — shell в cwd задачи; перетаскивание разделителя обновляет `ratio`. Выход процесса листа: код 0 — лист закрывается; ≠ 0 — лист остаётся с сообщением «процесс завершился с кодом N · ↩ перезапустить».
- [ ] **Step 6: Видимость.** При смене задачи/вкладки все невидимые `TerminalSurfaceView` получают `setVisible(false)`, видимые — `true`. Surface создаются лениво при первом показе вкладки и не пересоздаются при переключении.
- [ ] **Step 7: Лист новой задачи (этап 1 — без worktree)** по `new-task-v4.html`: ширина 580, название (моно 14, фокус `accent`), поле «Первое сообщение для claude»; `⌘↩` — создать: задача `.mainFolder`, одна вкладка `defaultAgent`; если сообщение не пустое — передать как `initialPrompt` в `launchSpec` (аргумент CLI, решение #29). Строки Worktree на этом этапе не показывать.
- [ ] **Step 8: Проверить вручную.** Run: `scripts/bundle.sh && open build/Hangar.app`. Expected: добавить проект, две задачи, в одной — claude + codex + сплит hx; переключение задач мгновенное; всё по макету `style-a-v2.html`; клавиши работают в русской раскладке.
- [ ] **Step 9: Commit** — `feat(ui): sidebar, task tab bar, splits, new task sheet, shortcuts`

### Task 6d: Локализация ru / en и экран настроек (минимальный)

Решение пользователя: интерфейс на русском и английском, переключение в настройках. `decisions.md` — #38. Выполняется сразу после Task 6 (до 6b/6c), чтобы все новые строки шли через локализацию.

**Files:**
- Create: `Sources/HangarUI/Resources/Localizable.xcstrings` (String Catalog, языки `ru` — исходный, `en`), `Sources/HangarUI/L10n.swift`, `Sources/HangarUI/SettingsWindow.swift`, `Tests/HangarUITests/L10nTests.swift`
- Modify: `Package.swift` (`defaultLocalization: "ru"`, `resources: [.process("Resources")]` у HangarUI), все строки UI в `Sources/HangarUI/*` → `L10n`, `Sources/Workspace/Config.swift` (`language`), `scripts/bundle.sh` (бандл ресурсов SwiftPM внутрь `.app`, `CFBundleLocalizations = [ru, en]` в Info.plist), `docs/decisions.md`, `docs/design/DESIGN.md` (правило: никаких строк литералами в UI).

**Interfaces:**
- `enum L10n` — статические функции/свойства по ключам (`L10n.sectionPinned`, `L10n.exitedWithCode(_ code: Int32)` …), читают `String(localized:bundle:locale:)` из `Bundle.module` для выбранного языка.
- `HangarConfig.language: Language` где `enum Language: String { case system, ru, en }`, ключ `language = "ru" | "en" | "system"`, по умолчанию `system` (system: ru если первый язык системы русский, иначе en).
- Переключение языка — без перезапуска: `AppState.language` (Observable) → SwiftUI-вью перерисовываются; AppKit-части (меню, NSAlert) берут строки в момент показа. Выбор сохраняется в `config.toml` (запись только ключа `language`, остальное содержимое файла сохраняется как было; если файла нет — создаётся с одной строкой).

**Экран настроек** (`⌘,` и шестерёнка внизу сайдбара; окно 520, стиль листа `new-task-v4`, одна карточка): Язык (Системный / Русский / English), Агент по умолчанию (claude / codex), Редактор (`hx`/`nvim`), Внешний редактор (`external_editor`, пусто = выкл), Фон терминала (Hangar / Тема Ghostty). Каждое изменение сразу пишется в `config.toml` тем же «точечным» способом (меняется только своя строка/ключ; комментарии и прочие строки не трогаются). Ошибка записи — сообщение в окне.

- [ ] **Step 1: Тесты** (RED сначала): `allKeysHaveRuAndEn` (каждый ключ каталога имеет ru и en, пустых нет); `pluralizedExitCode` (`L10n.exitedWithCode(3)` ru → «процесс завершился с кодом 3», en → «process exited with code 3»); `languageFromConfig` (`language = "en"` → `.en`; нет ключа → `.system`; `"de"` → ошибка парсинга с номером строки); `configWriterChangesOnlyOneKey` (файл с комментарием и тремя ключами → смена `language` меняет только эту строку; без ключа — строка дописывается в конец корневой секции, до первого `[section]`).
- [ ] **Step 2:** Run `swift test --filter "L10nTests|ConfigTests"` — FAIL → реализовать → PASS.
- [ ] **Step 3:** Перевести все существующие строки UI (сайдбар, вкладки, лист новой задачи, сообщения листа, алерты, меню, пустые состояния) на `L10n`; заголовки секций: ru «ЗАКРЕПЛЁННЫЕ / ПРОЕКТЫ / АРХИВ / SSH-ХОСТЫ», en «PINNED / PROJECTS / ARCHIVED / SSH HOSTS».
- [ ] **Step 4:** Экран настроек по описанию.
- [ ] **Step 5: Проверить вручную:** `scripts/bundle.sh && open build/Hangar.app`; сменить язык в настройках — интерфейс переключился сразу; перезапуск — язык сохранён; `grep -rn '"[А-Яа-я]' Sources/HangarUI --include=*.swift` — пусто (кроме `L10n.swift`, если там нет литералов — тоже пусто).
- [ ] **Step 6: Commit** — `feat(ui): ru/en localization and settings window`

### Task 6b: Действия над проектами, задачами и вкладками (контекстные меню, переименование, архив)

Источник: инвентаризация Pane (`pane-sidebar-actions.md` в этой же папке) + решения пользователя. Выполняется после Task 6 (сайдбар с секциями PINNED / PROJECTS / ARCHIVED уже есть). В `decisions.md` — запись #35.

**Files:**
- Create: `Sources/HangarUI/Actions.swift` (единый список действий: id, заголовок, иконка `Icon`, шорткат, `isEnabled(for:)`, `perform`), `Sources/HangarUI/RenameField.swift` (инлайн-редактирование), `Sources/HangarUI/ProjectSettingsSheet.swift`, `Tests/HangarUITests/ActionsTests.swift`
- Modify: `Sources/Workspace/Model.swift` (+ мутации ниже), `Tests/WorkspaceTests/ModelTests.swift`, `Sources/Workspace/Config.swift` (`external_editor`), `Sources/HangarUI/Shortcuts.swift`, `SidebarView.swift`, `TabBarView.swift`, `docs/decisions.md`, `docs/superpowers/plans/2026-10-18-hangar-stage0-1.md` (вставить этот Task 6b)

**Interfaces:**
- Consumes: `WorkspaceState` и мутации Task 2 + Task 6 (`setPinned`, `setProjectCollapsed`, `restoreTask`, `renameTask`, `renameProject`), `AppState.perform`, `Shortcut`, `Icon`.
- Produces (Model): `renameTab(taskId:tabId:title:)`, `deleteTask(id:)` (только из архива; удаляет из состояния), `removeProject(id:)` (удаляет проект и все его задачи из состояния; файлы на диске не трогает), `moveProject(id:to:)`, `updateProject(id:name:path:)`. Пустое/пробельное имя при переименовании — отказ (имя не меняется). Пользовательский заголовок вкладки (`Tab.customTitle: String?`, back-compat decode) имеет приоритет над `onTitleChange`.
- Produces (Config): `externalEditor: String?` (ключ `external_editor = "code"` / `"cursor"` / `"zed"`), по умолчанию `nil` — пункт меню «Открыть в …» скрыт.

**Действия (меню по правому клику и `…`; одно определение на действие — меню, шорткаты и палитра ⌘K берут его из `Actions`):**

| Объект | Действия |
|---|---|
| Задача | Переименовать (F2 / двойной клик, инлайн), Закрепить / Открепить, Открыть в Finder, Скопировать путь, Открыть в `<external_editor>`, Архивировать (⌘⇧W) |
| Архивная задача | Восстановить, Удалить навсегда (подтверждение `NSAlert`: «Задача будет удалена из Hangar. Файлы на диске не трогаются.») |
| Проект | Новая задача (+), Переименовать (F2), Настройки проекта…, Открыть в Finder, Скопировать путь, Открыть в `<external_editor>`, Удалить из Hangar (подтверждение: «Проект и его задачи будут убраны из Hangar. Папка на диске не удаляется.») |
| Вкладка | Переименовать (F2 / двойной клик), Сплит вправо (⌘D) / вниз (⌘⇧D), Закрыть (⌘W) |

- Настройки проекта (лист 580, стиль `new-task-v4`): Название, Путь (с кнопкой «Выбрать…», `NSOpenPanel`), Ветка по умолчанию — только показ, редактирование на этапе 2. Сохранение — `updateProject`; несуществующий путь — ошибка в листе, не сохраняется.
- Перетаскивание: задачи внутри проекта (`moveTask`, индекс по видимым), проекты между собой (`moveProject`). Между проектами задачи не переносятся.
- Шорткаты (по keyCode): ⌘⇧N — новый проект; F2 — переименовать выделенное; ⌘⇧W — архивировать задачу; ⌘B — дополнительно к ⌘0 сворачивает сайдбар (привычка из Pane); ⌘⌥↑ / ⌘⌥↓ — предыдущая/следующая задача в сайдбаре (⌘↑/↓ не трогаем — их использует терминал).
- Отказались (не делать): git-действия, Sessions / Mission Control, build/run-скрипты, «Archive Entire Folder», F10-меню, свои custom-команды, Toggle Zoom. SSH-действия — этап 6.

- [ ] **Step 1: Тесты модели** (RED сначала): `renameRejectsBlank` (`"  "` → имя прежнее), `renameTabSetsCustomTitle` (customTitle важнее авто-заголовка), `deleteOnlyArchived` (неархивную задачу `deleteTask` не удаляет), `removeProjectRemovesItsTasks` (задачи другого проекта остаются), `moveProjectReorders`, `oldStateWithoutCustomTitleDecodes`.
- [ ] **Step 2: Тесты действий** (`ActionsTests`): `archivedTaskActions` == [restore, deletePermanently]; `externalEditorHiddenWhenUnset`; `copyPathPutsPathOnPasteboard` (через внедрённый `NSPasteboard(name:)` с уникальным именем); `shortcutsForActions` (F2 = keyCode 120 без модификаторов → rename; ⌘⇧W → archive; ⌘B → toggleSidebar; ⌘⇧N → newProject).
- [ ] **Step 3:** Run: `swift test --filter "ModelTests|ActionsTests|ShortcutsTests"` — FAIL; реализовать; PASS.
- [ ] **Step 4: UI.** Контекстные меню в `SidebarView` и `TabBarView` из `Actions`; инлайн-переименование (Enter — сохранить, Esc — отмена, потеря фокуса — сохранить); перетаскивание с подсветкой места вставки (линия `accent`, 2 pt); подтверждения через `NSAlert` sheet. «Открыть в …» — `NSWorkspace.open` c `/usr/bin/env <external_editor> <path>` через `Process`, ошибка запуска — `NSAlert` с текстом.
- [ ] **Step 5: Проверить вручную.** `scripts/bundle.sh && open build/Hangar.app`: переименовать задачу и вкладку (F2), закрепить → появилась в PINNED, архивировать ⌘⇧W → в ARCHIVED N, восстановить, удалить навсегда, перетащить задачу и проект, «Открыть в Finder», «Скопировать путь», настройки проекта; после перезапуска всё сохранено. Список «Нужна проверка глазами».
- [ ] **Step 6: Commit** — `feat(ui): context actions — rename, pin, archive/restore/delete, project settings, reorder`

### Task 6c: Нижняя панель TERMINAL (shell задачи под агентами)

Решение пользователя (как в Pane). В `decisions.md` — #37. Выполняется после Task 6b.

**Files:**
- Modify: `Sources/Workspace/Model.swift` (+ поля, мутации), `Tests/WorkspaceTests/ModelTests.swift`, `Sources/HangarUI/` (новый `TerminalDrawerView.swift`, правки окна задачи), `Sources/HangarUI/Shortcuts.swift` + тест, `docs/decisions.md`, `docs/design/DESIGN.md` (компонент «Нижняя панель»), план.

**Interfaces:**
- Produces (Model): у `HangarTask` — `drawer: Drawer` где `struct Drawer: Codable, Equatable { var leaf: Leaf?; var visible: Bool = false; var height: Double = 220 }` (back-compat decode: нет ключа → значения по умолчанию). Мутации: `toggleDrawer(taskId:)` (первый показ создаёт `Leaf(kind: .shell, cwd: cwd задачи)`), `setDrawerHeight(taskId:_:)` (клэмп 120…70% высоты окна задаётся в UI; в модели клэмп ≥ 120).
- Shortcut: `toggleDrawer` = ⌃` (keyCode 50 + .control) — по keyCode, работает в русской раскладке.

**Поведение:**
- Полоса внизу области задачи (высота 26, фон `#212936`, иконка `terminal` + «TERMINAL», шеврон ↑/↓). Клик или ⌃` — раскрыть/свернуть (анимация высоты 180 мс, без анимаций при Reduce Motion).
- Внутри — `TerminalSurfaceView` с shell задачи (cwd задачи). Surface создаётся при первом раскрытии и не пересоздаётся; свёрнута → `setVisible(false)`.
- Высота меняется перетаскиванием верхней кромки; высота и видимость сохраняются по задаче и восстанавливаются после перезапуска (Task 7 восстанавливает и этот лист как обычный shell).
- Фокус: при раскрытии фокус уходит в панель; ⌃` при открытой панели с фокусом — свернуть и вернуть фокус во вкладку.
- Выход shell с кодом 0 → панель сворачивается и лист удаляется (следующий показ — новый shell).

- [ ] **Step 1: Тесты модели** (RED сначала): `toggleDrawerCreatesShellOnce`, `drawerHeightClampedMin`, `oldStateWithoutDrawerDecodes`, `drawerLeafCwdIsTaskCwd`.
- [ ] **Step 2: Тест клавиши** `toggleDrawerShortcut` (keyCode 50 + .control → `.toggleDrawer`; без модификатора → nil).
- [ ] **Step 3:** Run `swift test --filter "ModelTests|ShortcutsTests"` — FAIL → реализовать → PASS.
- [ ] **Step 4: UI** по описанию выше; цвета/размеры из `Theme`.
- [ ] **Step 5: Проверить вручную:** раскрыть/свернуть, изменить высоту, перезапустить — высота и видимость на месте; `ps` — один shell на задачу; скрытая панель на паузе рендера (лог `setVisible(false)`).
- [ ] **Step 6: Commit** — `feat(ui): bottom terminal drawer per task`

### Task 7: Восстановление и приёмка этапа

**Files:**
- Modify: `Sources/HangarUI/AppState.swift`, `Sources/HangarApp/main.swift`, `docs/decisions.md`

**Interfaces:**
- Consumes: `StateStore.load()`, `launchSpec(…, restoring: true)`.

- [ ] **Step 1: Старт.** `load()`: `.loaded` — восстановить выбор задачи, активные вкладки, сплиты, видимость инспектора; surface видимой вкладки стартуют сразу, остальные — при первом показе; `.recoveredFromCorrupt` — `NSAlert` «Состояние повреждено, копия: <путь>»; `missingCwd` у листа — лист показывает «папка не найдена» без запуска. `LoadResult.unreadable(URL)` — `NSAlert` «Файл состояния не читается: <путь>. Hangar работает без сохранения.» Листья нижней панели TERMINAL (Task 6c) восстанавливаются так же, как листья шелла.
- [ ] **Step 2: Выход.** `applicationWillTerminate` → `saveNow`. (Подтверждение `⌘Q` при `working` — этап 3, когда появятся статусы.)
- [ ] **Step 3: Проверить вручную.** Сценарий: 2 проекта, 3 задачи, 6 вкладок (claude, codex, hx с файлом, zsh, сплит) → `⌘Q` → открыть. Expected: всё на месте, claude продолжает прежний разговор (`--continue`), hx открыл тот же файл. Удалить папку одного проекта → открыть → проект серый, приложение работает.
- [ ] **Step 4: Энергия.** Тот же набор вкладок, агенты в простое, 10 минут. Run: `top -l 2 -s 5 -pid $(pgrep -x Hangar) -stats pid,cpu,mem | tail -1`, затем то же для Pane (`pgrep -f Pane.app`). Expected: Hangar CPU < 1%; записать CPU/RSS обоих в `decisions.md` (раздел «Замеры»).
- [ ] **Step 5:** Run: `swift test` — Expected: все тесты PASS.
- [ ] **Step 6: Commit** — `feat: session restore; stage 1 acceptance measurements`
