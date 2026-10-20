# Hangar — этап 3 (статусы агентов через hooks, уведомления macOS, лимиты подписок) — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** У каждой вкладки и задачи — живой статус агента (working / waiting / done / failed / idle) из hooks Claude Code и `notify` Codex (запасной путь — bell/OSC и коды выхода); уведомления macOS о waiting/done в невидимых вкладках с переходом по клику; подтверждение ⌘Q при работающих агентах; блок лимитов подписок внизу сайдбара с поповером ⌘⇧L; установка интеграции в `~/.claude/settings.json` и `~/.codex/config.toml` только с согласия, с diff, резервной копией и откатом.

**Порядок:** 1 → 2 → 3 → 7 → 8 → 9 → 10 → 11 → 12 → 13. Задачи 4, 5, 6 независимы (4 — после 2; 5 и 6 — после 1); 7 — после 2, 3, 4; 11 — после 4, 9; 12 — после 5, 6, 9.

**Architecture:** Четыре новых модуля только на Foundation: `AgentStatus` (свёртка сигналов в статус листа и задачи), `ControlServer` (протокол + Unix-сокет на `DispatchSource` + клиент + разбор входа CLI), `Usage` (окна лимитов, пороги, `codex app-server`), `Integration` (правка `settings.json` с сохранением порядка ключей, правка `notify` в TOML, построчный diff, безопасная запись). Исполняемый `hangar` — тонкая обёртка над `ControlServer` (`event`, `statusline`). `HangarUI` держит `StatusBoard` и `UsageBoard` в `AppState`, рисует точки, блок лимитов, уведомления и окно согласия.

**Tech Stack:** Swift 6.3, Swift Testing, AppKit + SwiftUI, `UserNotifications`, POSIX сокеты (`socket`/`bind`/`accept`, `DispatchSource`), `Process`, macOS 14+.

**Spec:** `docs/superpowers/specs/2026-10-18-hangar-design.md` (§2 `AgentStatus`/`Usage`/`ControlServer`/`hangar`, §4, §5, §5.1, §6 (⌘Q), §7 (только `event` и `statusline`), §8, §9, §10). Решения — `docs/decisions.md` (#12–#15, #25–#30, #26, #34, #38, #39, #41, #42; новое #43 — Task 1; открытые вопросы спайка). Дизайн — `docs/design/DESIGN.md` (статусы, ореол waiting, лимиты, «Блок/Поповер лимитов», курсор), макеты `docs/superpowers/mockups/limits.html`, `icons-sidebar.html`. Правила — `AGENTS.md`.

## Global Constraints

- macOS 14+, Apple Silicon. `AgentStatus`, `ControlServer`, `Usage`, `Integration` — без `AppKit`/`SwiftUI`, с юнит-тестами. Без новых зависимостей, без протоколов с одной реализацией (подмена в тестах — замыканиями).
- **Реальные `~/.claude` и `~/.codex` не трогаются ни тестами, ни проверкой.** Тесты — только временные копии. В DEBUG пути переопределяются `HANGAR_CLAUDE_SETTINGS`, `HANGAR_CODEX_CONFIG` (как `HANGAR_STATE_DIR`/`HANGAR_CONFIG`); ручная проверка запускает claude с `--settings <tmp>/settings.json` (через `[agents] claude = "claude --settings …"` в тестовом `HANGAR_CONFIG`).
- **Codex не установлен и не ставится.** Код Codex — по документированным схемам, тесты на фикстурах и фейковом исполняемом файле; каждое такое место помечено `// verify: проверить, когда codex будет установлен`.
- `hangar event` **никогда не пишет в stdout и всегда выходит с кодом 0** (stdout `UserPromptSubmit`/`SessionStart` попадает в контекст Claude, код 2 блокирует промпт).
- Граница доверия (сокет, stdin hooks/статус-лайна): строка сокета ≤ 64 KiB, `"v": 1`, схема проверяется, неизвестные id игнорируются; stdin ≤ 1 MiB; session id — `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` (первый символ не `-`: id не должен читаться как флаг `--resume`), иначе отбрасывается.
- Сокет: `<state dir>/hangar.sock` (в release — `~/Library/Application Support/Hangar/hangar.sock`, в DEBUG — `HANGAR_STATE_DIR`), права `0600`, проверка uid собеседника. `sun_path` ≤ 103 байт — тесты создают сокеты в `/tmp/hg-<8 hex>/`, не в `FileManager.temporaryDirectory`.
- Энергия: ноль таймеров и опросов. Сокет — `DispatchSource` (без циклов). `codex app-server` — короткоживущий, после конца хода не чаще раза в минуту. Сброс прошедшего окна лимита вычисляется при отрисовке, не таймером.
- `UserNotifications` — только когда процесс запущен из `.app` (`Bundle.main.bundleURL.pathExtension == "app"` и есть `bundleIdentifier`): в `swift run` и тестах `UNUserNotificationCenter.current()` падает.
- Все строки UI — через `L10n` (ru + en, `L10nTests.allKeysHaveRuAndEn`); иконки — `enum Icon`; цвета/размеры — `Theme`; `.pointingHand()` на всём кликабельном; анимации — только разовые, «Уменьшить движение» их отключает.
- Файлы пользователя: только после окна согласия с точным diff; копия `<имя>.hangar-backup-<yyyyMMdd-HHmmss>` рядом; атомарная запись; symlink остаётся ссылкой, права файла сохраняются; изменился на диске после показа diff — отказ.
- Вне рамок: блокировка сна §5.2, команды CLI/MCP кроме `event`/`statusline` (этап 5), строка состояния (этап 4), резервный источник Codex из rollout-файлов и распознавание `UsageLimitExceeded` (после установки codex).

## Review Focus

1. **Hook ломает агента.** Мусор/2 MiB в stdin, неизвестный kind, нет сокета, нет `HANGAR_TAB_ID` — ожидание: `hangar event` молчит в stdout, выходит 0 меньше чем за 1 с, ничего не шлёт при неизвестном kind. Тест — Task 3 `eventNeverPrintsAndExitsZero`.
2. **Файл настроек пользователя.** `settings.json` с ошибкой JSON (комментарий, хвостовая запятая), symlink в dotfiles с правами `0600`, правка файла между показом diff и «Применить» — ожидание: при ошибке и при изменении на диске ничего не пишется (сообщение в окне), иначе ссылка и права сохранены, копия создана. Тесты — Task 5 `invalidJSONThrows`, `writeKeepsSymlinkPermsAndBacksUp`, `writeRefusesWhenChangedOnDisk`.
3. **Мусор в сокете.** Строка 70 KB без `\n`, не-JSON, чужая версия, несуществующий leaf, session id `x; rm -rf ~` — ожидание: отказ/игнор, приложение живо, модель не меняется, id не сохраняется. Тесты — Task 2 `oversizeLineClosesConnection`, `invalidLinesRejectedServerSurvives`; Task 1 `invalidSessionIdIgnored`; Task 7 `unknownTabOrLeafIgnored`.
4. **Много коротких клиентов.** 5 агентов × `PostToolUse` — десятки `hangar` одновременно, каждый закрывает сокет, не дожидаясь ответа — ожидание: нет падения от SIGPIPE, все сообщения доставлены. Тесты — Task 2 `clientClosingEarlyDoesNotKillServer`, `concurrentClients`.
5. **Второй запуск и остатки после падения.** Сокет-файл остался после краша; второй экземпляр Hangar; слишком длинный путь — ожидание: старый файл заменяется, второй экземпляр активирует первый и выходит, длинный путь — ошибка (статусы только по запасному пути), не падение. Тесты — Task 2 `staleSocketReplaced`, `secondInstanceDetected`, `pathTooLong`.

Плюс: bell от shell при автодополнении не делает shell-вкладку `waiting` — Task 7 `bellOnShellIgnored`; приложение в папке с пробелами — Task 5 `pathWithSpaces`.

---

### Файловая структура

```
Package.swift                              + AgentStatus, ControlServer, Usage, Integration, hangar (exec) и их тесты
Sources/AgentStatus/AgentStatus.swift      AgentState, HookKind, AgentSignal, LeafStatus, fold, taskState, StatusBoard
Sources/ControlServer/Protocol.swift       ControlMessage, EventMessage, UsageMessage, WireWindow, кодирование/проверка
Sources/ControlServer/ControlServer.swift  сокет-сервер (DispatchSource), второй экземпляр
Sources/ControlServer/ControlClient.swift  отправка строки в сокет
Sources/ControlServer/CLISupport.swift     разбор аргументов/stdin для `hangar event` и `hangar statusline`
Sources/hangar/main.swift                  CLI (тонкий)
Sources/Usage/Usage.swift                  окна, уровни, UsageBoard, разбор Claude/Codex
Sources/Usage/CodexUsage.swift             CodexUsageReader (app-server), resolveCodex, CodexRefreshGate
Sources/Integration/JSONValue.swift        JSON с порядком ключей
Sources/Integration/ClaudeIntegration.swift  hooks + statusLine: install/uninstall/state
Sources/Integration/CodexIntegration.swift   notify в config.toml
Sources/Integration/LineDiff.swift, SafeWrite.swift
Sources/HangarUI/AppState+Agents.swift     приём сообщений, сигналы surface, статусы, reveal
Sources/HangarUI/Notifier.swift            UserNotifications + чистые правила
Sources/HangarUI/LimitsView.swift          блок лимитов + поповер
Sources/HangarUI/IntegrationModel.swift, IntegrationSheet.swift
```

### Task 1: Решение #43, спека и модуль `AgentStatus`

**Files:**
- Create: `Sources/AgentStatus/AgentStatus.swift`, `Tests/AgentStatusTests/AgentStatusTests.swift`
- Modify: `Package.swift` (`.target(name: "AgentStatus")`, `.testTarget(name: "AgentStatusTests", dependencies: ["AgentStatus"])`), `docs/decisions.md` (#43), `docs/superpowers/specs/2026-10-18-hangar-design.md` (§2, §5, §5.1, §8), `docs/design/DESIGN.md` («Блок лимитов (этап 5)» → этап 3; строка задачи: точка в жёлобке, иконка worktree в конце строки, в рейке — точка в углу монограммы, как в `icons-sidebar.html`)

**Interfaces:**
- Produces:
  - `public enum AgentState: String, Sendable, CaseIterable { case working, waiting, done, failed, idle }`
  - `public enum HookKind: String, Codable, Sendable, CaseIterable { case sessionStart = "session-start", prompt, tool, notification, stop, stopFailure = "stop-failure", codexNotify = "codex-notify" }` — это же `<kind>` в `hangar event <kind>`.
  - `public enum AgentSignal: Equatable, Sendable { case hook(HookKind, session: String?, notificationType: String?); case bell; case desktopNotification; case exited(code: Int32); case relaunched; case focused }`
  - `public struct LeafStatus: Equatable, Sendable { public var state: AgentState = .idle; public var claudeHooks = false; public var sessionId: String?; public init() }`
  - `public func validSessionId(_ s: String?) -> String?` — `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` (первый символ не `-`: id не должен читаться как флаг `--resume`), иначе nil.
  - `public func fold(_ status: LeafStatus, _ signal: AgentSignal) -> LeafStatus` — правила (таблица в тесте `foldTable`): `session-start` — состояние не меняется; `prompt`, `tool` → working; `notification` с типом nil, `permission_prompt`, `elicitation_dialog` → waiting, прочие (`idle_prompt`, `auth_success`) — без изменений; `stop` → done; `stop-failure` → failed; `codex-notify` → done. Любой hook, кроме `codex-notify`, ставит `claudeHooks = true`. Валидный session id из hook заменяет `sessionId`. `bell`/`desktopNotification` → waiting, только если `!claudeHooks`. `focused` → idle, только если waiting и `!claudeHooks` (запасной waiting гаснет, когда пользователь посмотрел). `exited(code)` → `code > 0` ? failed : idle. `relaunched` → idle, `claudeHooks = false`, `sessionId` остаётся.
  - `public func taskState(_ states: [AgentState]) -> AgentState` — waiting > failed > working > done > idle; пусто → idle.
  - `public struct Transition: Equatable, Sendable { public var leaf: UUID; public var from: AgentState; public var to: AgentState }`
  - `public struct StatusBoard: Equatable, Sendable { public private(set) var leaves: [UUID: LeafStatus]; public init(); public func status(_ leaf: UUID) -> LeafStatus; public mutating func apply(_ signal: AgentSignal, leaf: UUID) -> Transition? /* nil — состояние не изменилось */; public mutating func retain(_ live: Set<UUID>); public var workingCount: Int }`

- [ ] **Step 1: Запись #43 в `decisions.md`** (формат журнала). Содержание: решения контроллера (модули `AgentStatus`, `Usage`, минимальный `ControlServer` — только `event` и `usage`, остальные типы — этап 5; CLI только `event`/`statusline`; установка с согласием/diff/копией/откатом; запасные пути; уведомления; ⌘Q; лимиты — пороги 80/95, одно уведомление на пересечение, без опроса) и решения этого плана:
  - env `HANGAR_LEAF_ID` (id листа) рядом с `HANGAR_TAB_ID`: статус — на лист (сплиты, панель TERMINAL, где `HANGAR_TAB_ID` = id листа); событие с tab, не владеющим leaf, игнорируется.
  - CLI лежит в `Hangar.app/Contents/Helpers/hangar`, а не в `Contents/MacOS/hangar`: APFS по умолчанию нечувствительна к регистру, `MacOS/hangar` совпал бы с `MacOS/Hangar`.
  - Hooks Claude: `SessionStart` (id сессии), `UserPromptSubmit` → working, `PostToolUse` (matcher `*`) → working (выход из waiting после разрешения), `Notification` → waiting только для `permission_prompt`/`elicitation_dialog` (`idle_prompt` иначе превращал бы каждый done в waiting), `Stop` → done, `StopFailure` matcher `rate_limit` → failed + `limitReached`; у каждого `"timeout": 5`. Прерывание (Esc) не вызывает `Stop` — статус остаётся working до следующего промпта (ограничение Claude Code).
  - Запасные пути: bell/OSC-уведомление → waiting только у листов claude/codex и только если у листа не было hook Claude; гаснет в idle при фокусе листа; код выхода > 0 → failed, иначе idle; перезапуск → idle. У Codex нет события «начал работу» — working для Codex недоступен до hooks Codex (проверить, когда codex будет установлен).
  - Исходная статус-лайна хранится в самой команде: `'<cli>' statusline --then '<исходная команда>'` (остальные ключи `statusLine` не трогаются); исходный `notify` Codex — так же: `[cli, "event", "codex-notify", "--then", …исходный argv]`. Отдельного файла состояния нет; откат восстанавливает из команды.
  - `settings.json` правится через свой JSON с сохранением порядка ключей и литералов чисел, вывод с отступом 2 (модуль `Integration`); комментарии/ошибки JSON — отказ без записи.
  - Сокет — в папке состояния (DEBUG изолируется `HANGAR_STATE_DIR`); второй экземпляр — по успешному `connect` к существующему сокету, pid собеседника (`LOCAL_PEERPID`) активируется, новый процесс выходит; мёртвый сокет удаляется.
  - Строка задачи: точка статуса всегда в жёлобке, иконка worktree — в конце строки (12 pt), в рейке точка 7 pt в углу монограммы (`icons-sidebar.html`).
  - Ключи конфига `notifications = true|false`, `limit_notifications = true|false` (по умолчанию `true`, голые bool).
  - Лимиты без таймера: прошедшее окно сбрасывается при отрисовке (а она — при сообщении, открытии поповера, активации приложения). Резервный источник Codex (rollout) и `UsageLimitExceeded` — после установки codex.
  - Отвергнуто: `MacOS/hangar`; статус на вкладку вместо листа; `JSONSerialization` (теряет порядок ключей); отдельный файл с исходной статус-лайной; таймер сброса окна; опрос `codex app-server`.
- [ ] **Step 2: Спека.** §2: модуль `Integration` (правка файлов агентов) в таблицу; `ControlServer` на этапе 3 — типы `event`, `usage`. §5: env `HANGAR_LEAF_ID`; список hooks и правило `Notification` из #43; запасные пути — по #43. §5.1: путь CLI `Contents/Helpers/hangar`; хранение исходной статус-лайны в команде. §8: «сокет занят» — активировать существующий экземпляр по `connect` (#43).
- [ ] **Step 3: Тесты** (`AgentStatusTests`, RED):
  - `foldTable` — таблица (исходное состояние, сигнал) → ожидаемое: все строки правил из Interfaces, включая `notification` с `"idle_prompt"` → без изменений и `bell` при `claudeHooks == true` → без изменений.
  - `promptStopCycle` — `session-start(s: "abc")` → idle, `sessionId == "abc"`, `claudeHooks`; `prompt` → working; `notification("permission_prompt")` → waiting; `tool` → working; `stop` → done.
  - `bellFallbackOnlyWithoutClaudeHooks` — новый статус: `bell` → waiting, `focused` → idle; после `prompt`: `bell` и `focused` не меняют working.
  - `exitCodes` — `exited(1)` → failed, `exited(0)` → idle, `exited(-1)` → idle; `relaunched` → idle, `claudeHooks == false`, `sessionId` сохранён.
  - `invalidSessionIdIgnored` — `"x; rm -rf ~"`, `""`, 129 символов → `sessionId` прежний; `"0199a1b2-…"` и `"t.1_2-3"` принимаются.
  - `codexNotifyDone` — `hook(.codexNotify, session: "t1")` → done, `sessionId == "t1"`, `claudeHooks == false`, затем `bell` → waiting.
  - `taskPriority` — `[done, working] → working`, `[working, failed] → failed`, `[failed, waiting] → waiting`, `[idle, done] → done`, `[] → idle`.
  - `boardTransitions` — первый `prompt` → `Transition(from: .idle, to: .working)`; повторный `prompt` → nil; `retain([])` удаляет лист; `workingCount` считает только working.
- [ ] **Step 4:** Run: `swift test --filter AgentStatusTests` — Expected: FAIL (нет модуля).
- [ ] **Step 5: Реализовать** модуль по Interfaces.
- [ ] **Step 6:** Run: `swift test --filter AgentStatusTests` — Expected: PASS.
- [ ] **Step 7: Commit** — `git add Package.swift Sources/AgentStatus Tests/AgentStatusTests docs && git commit -m "feat(status): AgentStatus folding; decision #43"`

### Task 2: Модуль `ControlServer` — протокол, сервер, клиент

**Files:**
- Create: `Sources/ControlServer/Protocol.swift`, `ControlServer.swift`, `ControlClient.swift`, `Tests/ControlServerTests/ControlServerTests.swift`, `Tests/ControlServerTests/ProtocolTests.swift`
- Modify: `Package.swift` (`.target(name: "ControlServer", dependencies: ["AgentStatus"])`, testTarget `ControlServerTests`)

**Interfaces:**
- Consumes: `HookKind` (Task 1).
- Produces:
  - Строка протокола — один JSON-объект + `\n`. Событие: `{"v":1,"type":"event","tab":"<UUID>","leaf":"<UUID>","kind":"stop","session":"…","notificationType":"…","message":"…"}` (последние три — необязательные). Лимиты: `{"v":1,"type":"usage","agent":"claude","windows":[{"name":"five_hour","usedPercent":42.5,"resetsAt":1760000000}]}`. Ответ на каждую строку: `{"ok":true}` или `{"ok":false,"error":"<код>"}`, коды: `bad-json`, `bad-version`, `unknown-type`, `bad-field`, `too-large`.
  - `public struct EventMessage: Codable, Equatable, Sendable { public var tab: UUID; public var leaf: UUID; public var kind: HookKind; public var session: String?; public var notificationType: String?; public var message: String? }`
  - `public struct WireWindow: Codable, Equatable, Sendable { public var name: String; public var usedPercent: Double?; public var resetsAt: Double? /* epoch s */ }`
  - `public struct UsageMessage: Codable, Equatable, Sendable { public var agent: String /* "claude" | "codex" */; public var windows: [WireWindow] }`
  - `public enum ControlMessage: Equatable, Sendable { case event(EventMessage); case usage(UsageMessage); public func encoded() -> Data /* с "\n" */; public static func decode(_ line: Data) -> Result<ControlMessage, ProtocolError> }`
  - `public enum ProtocolError: String, Error, Sendable { case badJSON = "bad-json", badVersion = "bad-version", unknownType = "unknown-type", badField = "bad-field", tooLarge = "too-large" }`. Проверка в `decode`: `notificationType` ≤ 64, `message` обрезается до 500 символов, `agent` ∈ {claude, codex}, `windows` ≤ 8, `name` ≤ 64 и `[a-z0-9_]`, `usedPercent` конечное и зажимается в 0…100, `resetsAt` в (0, 2³³).
  - `public final class ControlServer: @unchecked Sendable { public static let maxLine = 65_536; public static let maxConnections = 32; public init(path: String, handler: @escaping @MainActor (ControlMessage) -> Void); public func start() throws(ControlServerError); public func stop() }` — `start`: путь > 103 байт → `.pathTooLong`; файл есть и `connect` удался → `.alreadyRunning(pid:)` (pid из `getsockopt(LOCAL_PEERPID)`); не удался → `unlink`; `bind`, `chmod 0600`, `listen`; accept и чтение — `DispatchSource.makeReadSource` на своей последовательной очереди; у принятого сокета `SO_NOSIGPIPE`, `getpeereid` ≠ `getuid()` → закрыть; больше `maxConnections` → новый закрывается сразу; строка без `\n` длиннее `maxLine` → ответ `too-large` и закрытие; валидные сообщения — `handler` на main. `stop` закрывает всё и удаляет файл.
  - `public enum ControlServerError: Error, Equatable { case pathTooLong; case alreadyRunning(pid: Int32); case system(call: String, errno: Int32) }`
  - `public enum ControlClient { public static func send(_ message: ControlMessage, to path: String) -> Bool }` — `connect`, запись, закрытие без ожидания ответа; `SO_SNDTIMEO` 1 с, `SO_NOSIGPIPE`; любая ошибка → false.

- [ ] **Step 1: Тесты** (RED; сокеты в `/tmp/hg-<8 hex>/s.sock`, чтение ответов — сырым сокетом в тесте):
  - `ProtocolTests.roundTrip` — `decode(encoded(m)) == .success(m)` для event со всеми полями и для usage.
  - `ProtocolTests.validation` — `"x"` → `.badJSON`; `{"v":2,…}` → `.badVersion`; `type:"tabs"` → `.unknownType`; `tab:"nope"`, `kind:"boom"`, `agent:"gpt"`, `usedPercent: "NaN"`-строка, 9 окон → `.badField`; `usedPercent: 140` → 100; `message` 2000 символов → 500.
  - `eventRoundTrip` — сервер + `ControlClient.send` → handler получает то же сообщение; сырой клиент получает `{"ok":true}`.
  - `invalidLinesRejectedServerSurvives` — в одном соединении: мусор, `{"v":2}`, неизвестный type → три ответа `ok:false` с кодами, handler не вызван; затем валидная строка → доставлена.
  - `splitAndBatchedLines` — строка, записанная двумя кусками, → одно сообщение; две строки в одной записи → два.
  - `oversizeLineClosesConnection` — 70 000 байт без `\n` → ответ `too-large`, соединение закрыто, handler не вызван; новое соединение работает.
  - `clientClosingEarlyDoesNotKillServer` — 50 раз: отправить и сразу закрыть → все 50 доставлены, тестовый процесс жив.
  - `concurrentClients` — 20 параллельных `send` (`DispatchQueue.concurrentPerform`) → 20 сообщений.
  - `staleSocketReplaced` — `bind` сокета и закрытие без `unlink` → `start()` успешен.
  - `secondInstanceDetected` — второй сервер на том же пути → `.alreadyRunning(pid: getpid())`.
  - `pathTooLong` — путь 120 байт → `.pathTooLong`.
  - `socketIsOwnerOnly` — права файла `0600`; `stop()` удаляет файл.
  - `sendToMissingSocketIsFastFalse` — нет файла → `false` быстрее 0.5 с.
- [ ] **Step 2:** Run: `swift test --filter ControlServerTests` — Expected: FAIL.
- [ ] **Step 3: Реализовать** протокол, сервер, клиент.
- [ ] **Step 4:** Run: `swift test --filter ControlServerTests` — Expected: PASS (3 прогона подряд — без флаков).
- [ ] **Step 5: Commit** — `git add Package.swift Sources/ControlServer Tests/ControlServerTests && git commit -m "feat(control): unix socket server with event/usage messages"`

### Task 3: CLI `hangar` (`event`, `statusline`), env `HANGAR_LEAF_ID`, сборка

**Files:**
- Create: `Sources/ControlServer/CLISupport.swift`, `Sources/hangar/main.swift`, `Tests/HangarCLITests/HangarCLITests.swift`
- Modify: `Package.swift` (`.executableTarget(name: "hangar", dependencies: ["ControlServer"])`, `.testTarget(name: "HangarCLITests", dependencies: ["hangar", "ControlServer"])` — зависимость гарантирует сборку бинарника), `Sources/Exec/Launch.swift` (env), `Tests/ExecTests/LaunchTests.swift`, `scripts/bundle.sh`

**Interfaces:**
- Consumes: `ControlMessage`, `EventMessage`, `UsageMessage`, `WireWindow`, `ControlClient` (Task 2), `HookKind`, `validSessionId` (Task 1).
- Produces:
  - `public func eventMessage(kind: String, args: [String], env: [String: String], stdin: Data?) -> EventMessage?` — nil, если нет/невалидны `HANGAR_TAB_ID`/`HANGAR_LEAF_ID` или kind неизвестен. Payload: последний аргумент, начинающийся с `{` (Codex), иначе stdin. Поля Claude: `session_id`, `notification_type`, `message`; Codex: `type` должен быть `agent-turn-complete` (иначе nil), `thread-id` → session, `last-assistant-message` → message (`// verify: проверить, когда codex будет установлен`). `--session ID` важнее payload. Невалидный JSON — событие без полей.
  - `public func chainedArgv(_ args: [String]) -> [String]?` — аргументы между `--then` и payload (исходный `notify` Codex).
  - `public func statuslineWindows(_ stdin: Data) -> [WireWindow]` — каждый ключ `rate_limits`, чьё значение — объект с `used_percentage` и/или `resets_at`; нет `rate_limits` → `[]`.
  - `hangar event <kind> [--session ID] [--then argv…] [payload]`: stdin читается, только если не TTY, до 1 MiB (остальное отбрасывается); нет `HANGAR_SOCKET` → выход; отправка `ControlClient.send`; `--then` → исходный argv + payload запускается отдельно (`Process.run`, без ожидания). Всегда exit 0, stdout пуст, stderr пуст.
  - `hangar statusline [--then <command>]`: stdin (до 1 MiB) → `statuslineWindows` → непусто → `usage` (agent `claude`) в `HANGAR_SOCKET` или `~/Library/Application Support/Hangar/hangar.sock`; затем `--then`: `/bin/sh -c <command>` с тем же stdin, его stdout/stderr — насквозь, код выхода — его; без `--then` — ничего не печатает, exit 0.
  - Неизвестная подкоманда → короткая подсказка в stderr, exit 1 (никогда 2).
  - `launchSpec` env: `["HANGAR_TAB_ID": tabId, "HANGAR_LEAF_ID": leaf.id, "HANGAR_SOCKET": socketPath]`.
  - `bundle.sh`: `mkdir -p Contents/Helpers`, `cp "$BIN_DIR/hangar" "$APP/Contents/Helpers/hangar"`, `codesign --force -s - "$APP/Contents/Helpers/hangar"` до подписи приложения.

- [ ] **Step 1: Тесты** (RED). Юнит (`ControlServerTests/CLISupportTests.swift`): `statuslineWindowsFixture` (stdin спайка: `rate_limits.five_hour {used_percentage: 42.5, resets_at: 1760000000}`, `seven_day {…}`, `seven_day_opus {…}`, плюс поле-строка → три окна в порядке ключей); `statuslineBeforeFirstResponse` (без `rate_limits` → `[]`); `eventFields` (stdin `{"session_id":"s1","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash","cwd":"/x","transcript_path":"/t"}` → поля; `--session s2` важнее); `codexPayloadFromArgv` (фикстура `{"type":"agent-turn-complete","thread-id":"t1","turn-id":"u1","cwd":"/x","input-messages":["hi"],"last-assistant-message":"ok"}` → `codex-notify`, `t1`, `"ok"`; `type:"other"` → nil); `chainedArgv` (`["--then","/bin/echo","a","{…}"]` → `["/bin/echo","a"]`). `LaunchTests.envHasLeafId`.
  Интеграция (`HangarCLITests`, настоящий бинарник рядом с тестовым бандлом, `ControlServer` в `/tmp/hg-…`):
  - `eventForwardsHookPayload` — `event stop` + env + stdin → сервер получил `EventMessage(kind: .stop, session: "s1")`.
  - `eventNeverPrintsAndExitsZero` — таблица: stdin `"not json"`; 2 MiB `a`; kind `boom`; без `HANGAR_TAB_ID`; `HANGAR_SOCKET` на несуществующий путь; без аргументов kind → у всех `exit 0`, stdout и stderr пусты, время < 1 с; для `boom` и без tab сервер ничего не получил.
  - `codexNotifyChainsOriginal` — `event codex-notify --then /bin/sh -c 'printf %s "$1" > <tmp>/out' sh '<payload>'` → в течение 2 с `out` == payload, сервер получил событие.
  - `statuslineSendsWindowsAndRunsOriginal` — `statusline --then cat` с фикстурой → stdout == stdin байт в байт, сервер получил `usage` с тремя окнами; `--then 'exit 3'` → код 3.
  - `statuslineWithoutDataOrSocket` — stdin без `rate_limits`, без `--then` → stdout пуст, exit 0, сервер ничего не получил; `HANGAR_SOCKET` на несуществующий путь + `--then 'echo hi'` → `hi\n`.
- [ ] **Step 2:** Run: `swift test --filter "CLISupportTests|HangarCLITests|LaunchTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать** `CLISupport`, `hangar/main.swift`, env, `bundle.sh`.
- [ ] **Step 4:** Run: `swift test --filter "CLISupportTests|HangarCLITests|LaunchTests"` — Expected: PASS. Run: `scripts/bundle.sh && ls -l build/Hangar.app/Contents/Helpers/hangar && codesign -v build/Hangar.app` — Expected: файл есть, подпись валидна.
- [ ] **Step 5: Commit** — `git add Package.swift Sources/ControlServer Sources/hangar Sources/Exec Tests scripts/bundle.sh && git commit -m "feat(cli): hangar event and statusline; HANGAR_LEAF_ID"`

### Task 4: Модуль `Usage`

**Files:**
- Create: `Sources/Usage/Usage.swift`, `Sources/Usage/CodexUsage.swift`, `Tests/UsageTests/UsageTests.swift`, `Tests/UsageTests/CodexUsageTests.swift`
- Modify: `Package.swift` (`.target(name: "Usage", dependencies: ["ControlServer", "Exec"])`, testTarget `UsageTests`)

**Interfaces:**
- Consumes: `WireWindow` (Task 2), `Runner` (Exec).
- Produces:
  - `public enum UsageAgent: String, Sendable, CaseIterable { case claude, codex }`
  - `public enum WindowKind: Hashable, Sendable { case session, weekly, weeklyModel(String) }`
  - `public struct UsageWindow: Equatable, Sendable { public var kind: WindowKind; public var usedPercent: Double; public var resetsAt: Date?; public var updatedAt: Date }`
  - `public struct AgentUsage: Equatable, Sendable { public var windows: [UsageWindow]; public var plan: String?; public var limitReached: Bool; public var limitResetsAt: Date?; public var updatedAt: Date }`
  - `public enum UsageLevel: Int, Comparable, Sendable { case ok, warn, full }`; `public enum UsageThreshold { public static let warn = 80.0; public static let full = 95.0 }` (единственное место порогов; `Theme` и уведомления берут их отсюда); `public func level(percent: Double, limitReached: Bool) -> UsageLevel`.
  - `public func claudeWindows(_ wire: [WireWindow], now: Date) -> [UsageWindow]` — `five_hour` → session, `seven_day` → weekly, `seven_day_<m>` → `weeklyModel(m)`; прочее и окна без `usedPercent` пропускаются.
  - `public func codexUsage(fromResult result: Any, now: Date) -> AgentUsage?` — все объекты в `result` с числовыми `usedPercent` и `windowDurationMins`: 300 → session, 10080 → weekly, иначе пропуск (по длительности, не по позиции); `planType` (строка где угодно) → `plan`; нет окон → nil (`// verify`).
  - `public struct UsageAlert: Equatable, Sendable { public var agent: UsageAgent; public var kind: WindowKind?; public var level: UsageLevel /* .warn | .full */; public var percent: Double? }`
  - `public struct UsageBoard: Equatable, Sendable { public init(); public mutating func update(_ agent: UsageAgent, windows: [UsageWindow], plan: String?, now: Date) -> [UsageAlert]; public mutating func markLimitReached(_ agent: UsageAgent, now: Date) -> [UsageAlert]; public func view(_ agent: UsageAgent, now: Date) -> AgentUsage?; public func level(_ agent: UsageAgent, now: Date) -> UsageLevel? }` — `update` заменяет окна агента целиком (план — если не nil); уведомление — при росте уровня окна выше уже уведомлённого для (агент, вид, `resetsAt`); новое `resetsAt` — снова можно. `markLimitReached`: `limitReached = true`, `limitResetsAt` = `resetsAt` самого заполненного окна; один `.full` с `kind: nil` до сброса. `limitReached` снимается, когда пришло обновление со всеми окнами < 95 или `limitResetsAt` прошло. `view`: окна с `resetsAt <= now` — `usedPercent = 0`; нет данных → nil.
  - `public struct CodexUsageReader: Sendable { public init(executable: String, timeout: Duration = .seconds(10)); public func read(now: Date) async throws -> AgentUsage }` — `<executable> app-server`, в stdin строки `{"method":"initialize","id":0,"params":{"clientInfo":{"name":"hangar","title":"Hangar","version":"0.3"}}}`, `{"method":"initialized"}`, `{"method":"account/rateLimits/read","id":1}`; читает stdout построчно до ответа с `"id":1`; `result` → `codexUsage`, `error` / нет окон / таймаут / выход процесса → throw; процесс завершается (`terminate`) в любом случае (`// verify`).
  - `public func resolveCodex(runner: Runner, shell: String) async -> String?` — `<shell> -l -i -c 'command -v codex'`, абсолютный путь или nil (#27).
  - `public struct CodexRefreshGate: Sendable { public init(); public mutating func begin(afterTurn: Bool, now: Date) -> Bool; public mutating func end(now: Date) }` — одновременно не больше одного чтения; после конца хода — только если прошлое завершилось ≥ 60 с назад; открытие поповера и ↻ — без минутного ограничения.

- [ ] **Step 1: Тесты** (RED):
  - `claudeWindowMapping` — `five_hour 86`, `seven_day 41`, `seven_day_opus 63`, `extra_x 5`, `seven_day` без процента → `[session 86, weekly 41, weeklyModel("opus") 63]`, `resetsAt` = `Date(timeIntervalSince1970:)`.
  - `codexMapping` — фикстура `{"rateLimits":{"primary":{"usedPercent":22,"windowDurationMins":300,"resetsAt":1760011000},"secondary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1760200000},"planType":"plus"}}` → session 22, weekly 100, plan `"plus"`; окно 60 мин пропущено; `{}` → nil.
  - `levels` — 79.9 → ok, 80 → warn, 94.9 → warn, 95 → full, (10, limitReached) → full.
  - `staleWindowResetsToZero` — `resetsAt = now − 1` → `view(now).windows[0].usedPercent == 0`.
  - `alertsOncePerWindowPeriod` — 79 → []; 81 → `[warn]`; 85 → []; 79, затем 81 → []; 96 → `[full]`; новое `resetsAt` + 81 → `[warn]`.
  - `limitReachedMarksAndClears` — `markLimitReached` → `level == .full`, один alert `kind: nil`; повтор → []; обновление со всеми < 95 → `limitReached == false`; `limitResetsAt` в прошлом → `view.limitReached == false`.
  - `noDataHidesAgent` — новый board → `view(.codex) == nil`.
  - `codexReaderWithFakeServer` — исполняемый скрипт в temp: проверяет `$1 = app-server`, читает 3 строки, печатает посторонний notification и ответ `{"id":1,"result":<фикстура>}` → `AgentUsage` как в `codexMapping`, процесса нет после возврата.
  - `codexReaderFailures` — скрипт `sleep 30` при `timeout: .milliseconds(500)` → throw < 2 с, процесс убит; ответ `{"id":1,"error":{"message":"x"}}` → throw; выход без ответа → throw.
  - `refreshGate` — `begin(afterTurn: false)` → true, повторный `begin` до `end` → false; после `end(t)`: `begin(afterTurn: true, t+30)` → false, `t+61` → true; `afterTurn: false` в `t+1` → true.
- [ ] **Step 2:** Run: `swift test --filter "UsageTests|CodexUsageTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать** `Usage.swift`, `CodexUsage.swift`.
- [ ] **Step 4:** Run: `swift test --filter "UsageTests|CodexUsageTests"` — Expected: PASS.
- [ ] **Step 5: Commit** — `git add Package.swift Sources/Usage Tests/UsageTests && git commit -m "feat(usage): limit windows, thresholds, codex app-server reader"`

### Task 5: `Integration` — `~/.claude/settings.json` (hooks + statusLine), diff, безопасная запись

**Files:**
- Create: `Sources/Integration/JSONValue.swift`, `ClaudeIntegration.swift`, `LineDiff.swift`, `SafeWrite.swift`, `Tests/IntegrationTests/JSONValueTests.swift`, `ClaudeIntegrationTests.swift`, `SafeWriteTests.swift`
- Modify: `Package.swift` (`.target(name: "Integration", dependencies: ["Exec"])`, testTarget `IntegrationTests`)

**Interfaces:**
- Consumes: `shellQuote` (Exec), `HookKind.rawValue` (строки kind — литералами, без зависимости от `AgentStatus`).
- Produces:
  - `public indirect enum JSONValue: Equatable, Sendable { case object([JSONMember]); case array([JSONValue]); case string(String); case number(String) /* литерал как в файле */; case bool(Bool); case null }`, `public struct JSONMember: Equatable, Sendable { public var key: String; public var value: JSONValue }`
  - `public func parseJSON(_ text: String) throws(IntegrationError) -> JSONValue`; `public func printJSON(_ value: JSONValue) -> String` — отступ 2, `"key": value`, пустые `{}`/`[]` в одну строку, `\n` в конце; не-ASCII не экранируется, `"`/`\\`/управляющие — экранируются.
  - `public enum IntegrationError: Error, Equatable { case invalidJSON(line: Int); case notAnObject; case unsupportedNotify; case invalidTOML(line: Int); case changedOnDisk }`
  - `public enum IntegrationState: Equatable, Sendable { case notInstalled, installed, outdated /* записи Hangar с другим путём CLI или не все */ }`
  - `public let claudeHooks: [(event: String, matcher: String?, kind: String)]` = `SessionStart`/nil/`session-start`, `UserPromptSubmit`/nil/`prompt`, `PostToolUse`/`*`/`tool`, `Notification`/nil/`notification`, `Stop`/nil/`stop`, `StopFailure`/`rate_limit`/`stop-failure`.
  - Запись hook: `{"matcher": m (если есть), "hooks": [{"type": "command", "command": "<shellQuote(cli)> event <kind>", "timeout": 5}]}` — добавляется в конец массива события; нет `hooks` — ключ в конец корня.
  - `public func shellWords(_ s: String) -> [String]?` — '…', "…", `\`; незакрытая кавычка → nil.
  - `public func isHangarCommand(_ command: String) -> Bool` — первое слово оканчивается на `/hangar` (или равно `hangar`), второе — `event` или `statusline`.
  - `public func claudeInstall(_ text: String?, cli: String) throws(IntegrationError) -> String` — nil/пусто → `{}`; сначала удаляет обработчики Hangar (любой путь), затем добавляет свежие. `statusLine`: нет → `{"type": "command", "command": "<cli> statusline"}`; команда Hangar → пересобрать с текущим cli, сохранив `--then`; чужая → `command` = `<cli> statusline --then <shellQuote(исходная)>`, прочие ключи (`padding`…) на месте.
  - `public func claudeUninstall(_ text: String) throws(IntegrationError) -> String` — удаляет только обработчики Hangar (пустая группа удаляется, пустой массив события — тоже, пустой `hooks` — тоже); `statusLine` с `--then X` → `command = X`, без → ключ удаляется.
  - `public func claudeState(_ text: String?, cli: String) -> IntegrationState`
  - `public enum DiffLine: Equatable, Sendable { case same(String), added(String), removed(String), skipped(Int) }`; `public func lineDiff(_ old: String, _ new: String) -> [DiffLine]` (LCS по строкам); `public func collapsed(_ diff: [DiffLine], context: Int = 3) -> [DiffLine]` — серии `same` длиннее `2·context` заменяются на `skipped(n)`.
  - `public func readUserFile(_ url: URL) throws -> String?` — nil, если файла нет.
  - `public func writeUserFile(_ url: URL, text: String, expected: String?, now: Date) throws -> URL?` — symlink разрешается (пишется цель); текущее содержимое ≠ `expected` → `.changedOnDisk`; файл был → копия `<имя цели>.hangar-backup-<yyyyMMdd-HHmmss>` рядом с целью (возвращается URL копии); папка создаётся; запись `.atomic`; права исходного файла восстанавливаются (новый файл — `0600`).

- [ ] **Step 1: Тесты** (RED; только temp-папки, фикстуры строками в тестах):
  - `jsonRoundTripPreservesOrderAndNumbers` — фикстура с отступом 2: вложенные объекты в «несортированном» порядке, `1.0`, `1e3`, `-0`, `"é"`, `"\"q\""`, `[]`, `{}` → `printJSON(parseJSON(x)) == x`.
  - `invalidJSONThrows` — `{"a": 1,}` и `// c\n{}` → `.invalidJSON(line:)` с верной строкой; `[1]` → `claudeInstall` бросает `.notAnObject`.
  - `installIntoEmpty` — `claudeInstall(nil, cli: "/A/hangar")` == точная ожидаемая строка (6 событий в порядке `claudeHooks`, `statusLine`).
  - `installPreservesUserHooksAndKeys` — у пользователя `"model"`, свой `Stop`-hook и `"permissions"` → их порядок и значения те же, наш `Stop`-обработчик после пользовательского.
  - `installIsIdempotent` — `install(install(x)) == install(x)` для 4 фикстур (пустой, с hooks, со statusLine, с hooks и statusLine).
  - `installUpdatesMovedApp` — установка с `/Old/hangar`, затем с `/New/hangar` → `/Old` не встречается, обработчиков по одному, `--then` сохранён; `claudeState(…, cli: "/New/hangar")`: до — `.outdated`, после — `.installed`; без записей — `.notInstalled`.
  - `statuslineWrapped` — исходная `"bash ~/.claude/sl.sh 'a b'"` с `"padding": 2` → `command == "/A/hangar statusline --then 'bash ~/.claude/sl.sh '\\''a b'\\'''"`, `padding` на месте.
  - `uninstallRestores` — для 4 фикстур `claudeUninstall(claudeInstall(x)) == x` байт в байт.
  - `uninstallRemovesOnlyHangar` — в группе пользовательский и наш обработчик → остаётся пользовательский.
  - `pathWithSpaces` — cli `/Users/me/My Apps/Hangar.app/Contents/Helpers/hangar` → команда в одинарных кавычках, `isHangarCommand` true, `shellWords` даёт путь целиком, uninstall всё убирает.
  - `lineDiffAndCollapse` — `lineDiff("a\nb\nc\n", "a\nx\nc\n") == [.same("a"), .removed("b"), .added("x"), .same("c")]`; 20 одинаковых строк вокруг одной правки при `context: 3` → `skipped` с верными счётчиками.
  - `SafeWriteTests.writeKeepsSymlinkPermsAndBacksUp` — `link → real/settings.json` с правами `0600`; запись через ссылку → ссылка осталась ссылкой, у цели `0600` и новый текст, копия `settings.json.hangar-backup-\d{8}-\d{6}` с исходными байтами.
  - `SafeWriteTests.writeRefusesWhenChangedOnDisk` — `expected` ≠ содержимому → `.changedOnDisk`, файл не изменён, копии нет.
  - `SafeWriteTests.newFileWithoutBackup` — файла и папки нет → создан, права `0600`, функция вернула nil.
- [ ] **Step 2:** Run: `swift test --filter IntegrationTests` — Expected: FAIL.
- [ ] **Step 3: Реализовать** по Interfaces.
- [ ] **Step 4:** Run: `swift test --filter IntegrationTests` — Expected: PASS.
- [ ] **Step 5: Commit** — `git add Package.swift Sources/Integration Tests/IntegrationTests && git commit -m "feat(integration): claude settings hooks/statusline with order-preserving JSON"`

### Task 6: `Integration` — `notify` в `~/.codex/config.toml`

**Files:**
- Create: `Sources/Integration/CodexIntegration.swift`, `Tests/IntegrationTests/CodexIntegrationTests.swift`

**Interfaces:**
- Consumes: `IntegrationError`, `IntegrationState`, `isHangarCommand`-логика по argv (Task 5).
- Produces:
  - `public func tomlRootStringArray(_ toml: String, key: String) throws(IntegrationError) -> (lines: Range<Int>, values: [String])?` — ключ только в корне (до первого `[таблица]`); массив может занимать несколько строк; строки `"…"` (с `\"`, `\\`, `\n`, `\t`, `\uXXXX`) и `'…'`; комментарии `#` вне строк; не массив строк → `.unsupportedNotify`; незакрытый массив → `.invalidTOML(line:)`.
  - `public func codexInstall(_ toml: String?, cli: String) throws(IntegrationError) -> String` — нет `notify` → строка `notify = ["<cli>", "event", "codex-notify"]` после последней непустой строки корня (как `HangarConfig.updating`), CRLF сохраняется; чужой `notify` → `["<cli>", "event", "codex-notify", "--then", …исходные]` на месте старых строк; уже Hangar → пересобрать с текущим cli, сохранив хвост `--then`.
  - `public func codexUninstall(_ toml: String) throws(IntegrationError) -> String` — Hangar с `--then` → исходный массив; без → строки ключа удаляются.
  - `public func codexState(_ toml: String?, cli: String) -> IntegrationState`
  - Строки TOML пишутся basic-строками с экранированием `"` и `\`.

- [ ] **Step 1: Тесты** (RED; помечены `// verify: проверить, когда codex будет установлен`):
  - `installWithoutNotify` — `model = "o3"\n\n[profiles.x]\nnotify = ["a"]\n` → новая строка после `model`, `[profiles.x]` и его `notify` не тронуты.
  - `chainsExistingMultilineNotify` — `notify = [\n  "python3",\n  '/u/n.py', # c\n]\n` → `["/A/hangar", "event", "codex-notify", "--then", "python3", "/u/n.py"]`; `codexUninstall` → `notify = ["python3", "/u/n.py"]` (значения равны исходным — проверка через `tomlRootStringArray`).
  - `uninstallRoundTripWithoutNotify` — `codexUninstall(codexInstall(x)) == x` для файла без `notify` и для пустого.
  - `idempotentAndMovedApp` — повторная установка не меняет текст; новый cli заменяет старый; `codexState` — `.notInstalled` / `.installed` / `.outdated`.
  - `rejectsUnsupported` — `notify = "x"` → `.unsupportedNotify`; `notify = [1]` → `.unsupportedNotify`; `notify = ["a"` без `]` → `.invalidTOML(line: 1)`.
- [ ] **Step 2:** Run: `swift test --filter CodexIntegrationTests` — Expected: FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4:** Run: `swift test --filter IntegrationTests` — Expected: PASS.
- [ ] **Step 5: Commit** — `git add Sources/Integration Tests/IntegrationTests && git commit -m "feat(integration): codex notify in config.toml"`

### Task 7: Приложение — сокет, приём событий, статусы листов, id сессий, запасные пути

**Files:**
- Create: `Sources/HangarUI/AppState+Agents.swift`, `Tests/HangarUITests/AgentWiringTests.swift`
- Modify: `Package.swift` (`HangarUI` deps += `AgentStatus`, `ControlServer`, `Usage`; `HangarApp` deps += `ControlServer`; `HangarUITests` deps += `AgentStatus`, `ControlServer`, `Usage`), `Sources/Workspace/Model.swift` (+ `setAgentSessionId`), `Tests/WorkspaceTests/ModelTests.swift`, `Sources/HangarUI/AppState.swift` (init `socketPath:`, поля, `retain` в `perform`), `Sources/HangarUI/SplitView.swift` (`LeafView`: `onBell`, `onNotification`, `onRelaunch`; проводка в `show`), `Sources/HangarUI/TerminalDrawerView.swift` (та же проводка), `Sources/HangarApp/main.swift`

**Interfaces:**
- Consumes: `StatusBoard`, `AgentSignal`, `Transition`, `taskState` (Task 1); `ControlServer`, `ControlMessage` (Task 2); `UsageBoard`, `claudeWindows` (Task 4); `HANGAR_LEAF_ID` (Task 3).
- Produces:
  - `WorkspaceState.setAgentSessionId(leafId: UUID, _ id: String)` — лист вкладки или панели TERMINAL; неизвестный id — без изменений.
  - `AppState.init(state:store:config:configURL:socketPath:)` (main передаёт `<stateDir>/hangar.sock`).
  - `AppState.statuses: StatusBoard` и `AppState.usage: UsageBoard` (observable, только в памяти); `@ObservationIgnored var onTransition: ((Transition) -> Void)?` (Task 9); `@ObservationIgnored var onUsageAlerts: (([UsageAlert]) -> Void)?` (Task 11); `@ObservationIgnored var onCodexTurn: (() -> Void)?` (Task 11).
  - `func handle(_ message: ControlMessage)` — event: лист должен существовать в неархивной задаче и принадлежать `tab` (у листа панели TERMINAL `tab == leaf`), иначе игнор; сигнал `.hook(kind, session, notificationType)`; валидный session id записывается в модель (`perform { setAgentSessionId }`), только если он изменился и вид листа совпадает с агентом (claude-kinds → `.claude`, `codex-notify` → `.codex`); `stop-failure` → `usage.markLimitReached(.claude)`; `codex-notify` → `onCodexTurn`. usage: `agent == "claude"` → `usage.update(.claude, claudeWindows(…))` → `onUsageAlerts`.
  - `func signal(_ signal: AgentSignal, leaf: UUID)` — сигналы surface; `bell`/`desktopNotification` для shell/editor игнорируются.
  - `var lastNotificationMessage: [UUID: String]` (текст `message` последнего события листа, для тела уведомления).
  - `func state(ofLeaf: UUID) -> AgentState`, `func state(of tab: Tab) -> AgentState`, `func state(of task: HangarTask) -> AgentState` (вкладки + лист панели), `var workingLeafCount: Int`.
  - `perform` после мутации вызывает `statuses.retain(<листья неархивных задач>)`.
  - main: до `startGhostty` — `ControlServer(path:handler: { app.handle($0) })`; `.alreadyRunning(pid)` → `NSRunningApplication(processIdentifier: pid)?.activate()` и `exit(0)` до загрузки состояния; другая ошибка → `uiLog.error`, работа без сокета; `applicationWillTerminate` → `server.stop()`. Handler использует `appState`, созданный позже: сообщения до создания `AppState` отбрасываются.

- [ ] **Step 1: Тесты** (RED):
  - `ModelTests.setAgentSessionId` — лист вкладки и лист панели получают id; неизвестный id — состояние равно прежнему.
  - `eventUpdatesLeafAndTaskState` — задача с claude-вкладкой: `handle(event prompt)` → `state(ofLeaf) == .working`, `state(of: task) == .working`, `workingLeafCount == 1`; `notification("permission_prompt")` → task `.waiting`, `onTransition` вызван с `.working → .waiting`.
  - `unknownTabOrLeafIgnored` — случайные UUID, leaf из другой вкладки, leaf архивной задачи → `statuses` пуст, `state` модели не изменился, `onTransition` не вызывался.
  - `sessionIdSavedToLeaf` — `session-start` с `"s1"` → `Leaf.agentSessionId == "s1"`; `resumeSet` включает лист; `launchSpec(…, restoring: true)` содержит `--resume s1`; повтор того же id не вызывает `perform` (счётчик `didChange` не растёт).
  - `sessionIdNotWrittenToShellLeaf` — событие `prompt` в shell-лист → статус working, `agentSessionId == nil`.
  - `drawerLeafEvent` — лист панели TERMINAL (`tab == leaf.id`) получает статус; `state(of: task)` его учитывает.
  - `bellOnShellIgnored` — `signal(.bell)` для shell → idle; для codex → waiting; `signal(.focused)` → idle.
  - `exitFailedThenRelaunchIdle` — `signal(.exited(code: 2))` → failed; `.relaunched` → idle.
  - `archivedTaskStatusesCleared` — working-лист, `archive(taskId:)` → `statuses.leaves` без него.
  - `usageMessagesUpdateBoard` — `usage claude [five_hour 86]` → `usage.view(.claude, now: Date())?.windows[0].usedPercent == 86`, `onUsageAlerts` с `[warn]`; `event stop-failure` → `usage.level(.claude, now: Date()) == .full`.
- [ ] **Step 2:** Run: `swift test --filter "AgentWiringTests|ModelTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать** модельную мутацию, `AppState+Agents`, проводку `LeafView` (`TerminalSurfaceView.onBell` / `onDesktopNotification` → `signal`; `childExited` → `.exited`; `relaunch` → `.relaunched`; `onFocus` → `.focused` вдобавок к `focused(leafId:)`), сервер в main.
- [ ] **Step 4:** Run: `swift test` — Expected: PASS (все цели).
- [ ] **Step 5: Проверить вручную** (DEBUG, `HANGAR_STATE_DIR=/tmp/hg-v/state HANGAR_CONFIG=/tmp/hg-v/config.toml swift run HangarApp`): `ls -l /tmp/hg-v/state/hangar.sock` → `srw-------`; второй такой же запуск активирует первое окно и выходит; в shell-вкладке `printf '{"v":1,"type":"event","tab":"%s","leaf":"%s","kind":"prompt"}\n' $HANGAR_TAB_ID $HANGAR_LEAF_ID | nc -U $HANGAR_SOCKET` → `{"ok":true}`.
- [ ] **Step 6: Commit** — `git add Package.swift Sources Tests && git commit -m "feat(status): control socket in app, leaf statuses, session ids, fallbacks"`

### Task 8: Точки статуса — вкладки, строки сайдбара, рейка

**Files:**
- Modify: `Sources/HangarUI/Icons.swift` (`StatusDot`), `Sources/HangarUI/Theme.swift`, `Sources/HangarUI/TabBarView.swift`, `Sources/HangarUI/SidebarView.swift` (строки задач, закреплённые, рейка), `Sources/HangarUI/AppState+Agents.swift`, `Tests/HangarUITests/AgentWiringTests.swift`

**Interfaces:**
- Consumes: `AgentState`, `state(of:)` (Task 7), `UsageBoard.level` (Task 4).
- Produces:
  - `Theme.ui.status(_ state: AgentState) -> Color` (цвета DESIGN.md «Статусы»); `Theme.haloWidth: CGFloat = 3`, `Theme.haloOpacity = 0.25`, `Theme.railDot: CGFloat = 7`, `Theme.railDotBorder: CGFloat = 1.5`, `Theme.worktreeEndIcon: CGFloat = 12`.
  - `StatusDot(state: AgentState)` — цвет по состоянию; у waiting — ореол (кольцо 3 pt `waiting` 25%); разовый импульс при переходе в waiting остаётся (без него при Reduce Motion).
  - `AppState.displayState(ofLeaf:) / displayState(of tab:) / displayState(of task:) -> AgentState` — как `state`, но лист claude/codex при `usage.level(agent, now:) == .full` (≥ 95% или `limitReached`) → `.failed`; `now` — `Date()`, с Task 11 — `usageClock`.
  - `func showsDot(_ tab: Tab, state: AgentState) -> Bool` — вкладка с агентом или со статусом ≠ idle.
- Вид: вкладка — `StatusDot(state: displayState(of: tab))` вместо заглушки `// shortcut: always idle…`; строка задачи — точка в жёлобке всегда, у worktree-задачи иконка `worktree` 12 pt в конце строки (перед `…`/булавкой, `text3`); рейка — монограмма с точкой 7 pt в правом верхнем углу (рамка `sidebar` 1.5), как `icons-sidebar.html`.

- [ ] **Step 1: Тесты** (RED): `limitReachedTurnsAgentDotsRed` — claude-лист working + `markLimitReached(.claude)` → `displayState == .failed`, codex-лист той же задачи не меняется, shell-лист не меняется; `showsDotRules` — shell-вкладка idle → false, shell-вкладка working → true, claude-вкладка idle → true.
- [ ] **Step 2:** Run: `swift test --filter AgentWiringTests` — Expected: FAIL.
- [ ] **Step 3: Реализовать** `Theme`, `StatusDot`, `displayState`, виды.
- [ ] **Step 4:** Run: `swift test` — Expected: PASS.
- [ ] **Step 5: Проверить вручную** (DEBUG, событие через `nc -U` как в Task 7): точки на вкладке, строке и в рейке меняют цвет; waiting — ореол и один импульс; worktree-задача — точка + иконка в конце; сверить с `icons-sidebar.html` и DESIGN.md.
- [ ] **Step 6: Commit** — `git add Sources/HangarUI Tests/HangarUITests && git commit -m "feat(ui): agent status dots on tabs, sidebar rows and rail"`

### Task 9: Уведомления macOS и настройки уведомлений в конфиге

**Files:**
- Create: `Sources/HangarUI/Notifier.swift`, `Tests/HangarUITests/NotificationsTests.swift`
- Modify: `Sources/Workspace/Config.swift`, `Sources/Workspace/ConfigWriter.swift`, `Tests/WorkspaceTests/ConfigTests.swift`, `Sources/HangarUI/AppState+Agents.swift` (`reveal`), `Sources/HangarUI/MainWindow.swift` (видимость окна, `reveal` → фокус surface), `Sources/HangarApp/main.swift`, `Sources/HangarUI/L10n.swift` + `.strings`

**Interfaces:**
- Consumes: `Transition`, `onTransition`, `lastNotificationMessage` (Task 7).
- Produces:
  - `HangarConfig.notifications: Bool = true`, `HangarConfig.limitNotifications: Bool = true` — ключи `notifications`, `limit_notifications`, значения — голые `true`/`false` (иначе `ParseError.syntax`).
  - `HangarConfig.updating(_ text: String, key: String, literal: String) -> String` и `save(key:literal:to:)` — как строковые варианты, но значение без кавычек.
  - `struct AgentNotice: Equatable { var id: String /* leaf uuid или "limit-<agent>" — новое заменяет прежнее */; var title: String; var subtitle: String; var body: String; var leaf: UUID? }`
  - `@MainActor func notice(for t: Transition, app: AppState, leafVisible: Bool) -> AgentNotice?` — только `to ∈ {waiting, done}`, `config.notifications`, `!leafVisible`; title `L10n.agentWaiting(agent)` / `L10n.agentDone(agent)` (agent — `claude`/`codex` по виду листа, у shell — заголовок листа); subtitle `"<проект> › <задача>"`; body — `lastNotificationMessage[leaf]` или подпись вкладки.
  - `@MainActor func leafVisible(_ leaf: UUID, app: AppState, windowVisible: Bool) -> Bool` — `windowVisible` (приложение активно, окно key и не свёрнуто) && лист в активной вкладке выбранной задачи или лист раскрытой панели TERMINAL выбранной задачи.
  - `func reveal(leafId: UUID)` (AppState) — выбирает задачу (из архива не восстанавливает — игнор), активирует вкладку или раскрывает панель, ставит `focusedLeafId`; `MainWindowController` затем активирует приложение и делает surface first responder.
  - `@MainActor final class Notifier: NSObject, UNUserNotificationCenterDelegate { static func makeIfAvailable() -> Notifier? /* nil вне .app */; func post(_ n: AgentNotice); var onOpen: ((UUID) -> Void)? }` — `requestAuthorization([.alert, .sound])` при первом `post`; отказ → молча ничего; `userInfo["leaf"]`; `willPresent` → `.banner` (на случай невидимой вкладки при активном приложении).
- L10n (ru / en): `agentWaiting` «%@ ждёт ответа» / «%@ is waiting for you»; `agentDone` «%@ закончил» / «%@ finished».

- [ ] **Step 1: Тесты** (RED):
  - `ConfigTests.notificationBools` — `notifications = false` → false; без ключа → true; `notifications = "no"` → `ParseError.syntax`; `updating("", key: "notifications", literal: "false") == "notifications = false"`; замена существующей строки сохраняет комментарий.
  - `noticeOnlyForWaitingAndDoneWhenHidden` — таблица: `idle→working` → nil; `working→waiting` скрыт → notice; видим → nil; `working→done` скрыт → notice; `→failed` → nil; `config.notifications == false` → nil.
  - `noticeText` — ru: title «claude ждёт ответа», subtitle «shop-api › fix-auth», body — `message` из события; en: «claude is waiting for you»; без message — подпись вкладки.
  - `leafVisibleRules` — активная вкладка выбранной задачи + `windowVisible` → true; та же при `windowVisible: false` → false; другая вкладка → false; лист панели при свёрнутой панели → false, при раскрытой → true.
  - `revealSelectsTaskTabAndDrawer` — `reveal` листа второй вкладки другой задачи → выбрана задача, `activeTabId` = вкладка, `focusedLeafId` = лист; лист панели → `drawer.visible == true`.
- [ ] **Step 2:** Run: `swift test --filter "NotificationsTests|ConfigTests|L10nTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать**; main: `Notifier.makeIfAvailable()`, `onOpen` → `wc.reveal(leafId:)`, `app.onTransition` → `notice(…)` → `post`.
- [ ] **Step 4:** Run: `swift test` — Expected: PASS.
- [ ] **Step 5: Проверить вручную** (`scripts/bundle.sh`, приложение с изолированным env): при первом событии — системный запрос разрешения; событие waiting в фоновой вкладке → баннер «claude ждёт ответа», клик → та задача и вкладка в фокусе; в видимой вкладке — без баннера.
- [ ] **Step 6: Commit** — `git add Sources Tests && git commit -m "feat(ui): macOS notifications for waiting/done in hidden tabs"`

### Task 10: Подтверждение ⌘Q и закрытия окна при работающих агентах

**Files:**
- Modify: `Sources/HangarApp/main.swift` (`applicationShouldTerminate`), `Sources/HangarUI/MainWindow.swift` (`windowShouldClose`), `Sources/HangarUI/AppState+Agents.swift`, `Sources/HangarUI/L10n.swift` + `.strings`, `Tests/HangarUITests/AgentWiringTests.swift`

**Interfaces:**
- Consumes: `workingLeafCount` (Task 7).
- Produces:
  - `@MainActor func quitConfirmation(working: Int) -> (message: String, info: String)?` — 0 → nil.
  - `MainWindowController.confirmQuitIfAgentsWork() -> Bool` — модальный `NSAlert` (`.warning`): `L10n.agentsWorking(n)`, `L10n.agentsWorkingInfo`, кнопки `L10n.quit` (первая) и `L10n.cancel`; подтверждение ставит `quitConfirmed = true`, чтобы закрытие окна → завершение не спросило второй раз. Проверка «создаётся worktree» (этап 2) идёт первой.
- L10n (ru / en): `agentsWorking` «Работают агенты: %d. Выйти?» / «Agents working: %d. Quit?»; `agentsWorkingInfo` «Их процессы будут завершены.» / «Their processes will be terminated.».

- [ ] **Step 1: Тесты** (RED): `quitConfirmationText` — `working: 0` → nil; `2` → ru «Работают агенты: 2. Выйти?», en «Agents working: 2. Quit?».
- [ ] **Step 2:** Run: `swift test --filter "AgentWiringTests|L10nTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4:** Run: `swift test --filter "AgentWiringTests|L10nTests"` — Expected: PASS.
- [ ] **Step 5: Проверить вручную:** working-событие → ⌘Q → алерт, «Отмена» — приложение живо; красная кнопка окна → тот же алерт один раз, «Выйти» — выход без второго вопроса; без working — выход без вопроса.
- [ ] **Step 6: Commit** — `git add Sources Tests && git commit -m "feat(ui): confirm quit while agents work"`

### Task 11: Блок лимитов в сайдбаре, поповер ⌘⇧L, обновление Codex, уведомления о лимитах

**Files:**
- Create: `Sources/HangarUI/LimitsView.swift`, `Tests/HangarUITests/LimitsTests.swift`
- Modify: `Sources/HangarUI/SidebarView.swift` (блок над нижней панелью; в рейке — плитка `Icon.limits`), `Sources/HangarUI/Shortcuts.swift` (`.limits`), `Tests/HangarUITests/ShortcutsTests.swift`, `Sources/HangarUI/MainWindow.swift` (шорткат, `didBecomeActive` → `usageClock`), `Sources/HangarUI/AppState+Agents.swift` (Codex, `displayState` на `usageClock`), `Sources/HangarUI/Theme.swift`, `Sources/HangarApp/main.swift` (уведомления о лимитах), `Sources/HangarUI/L10n.swift` + `.strings`

**Interfaces:**
- Consumes: `UsageBoard`, `UsageLevel`, `UsageThreshold`, `CodexUsageReader`, `resolveCodex`, `CodexRefreshGate` (Task 4); `onUsageAlerts`, `onCodexTurn` (Task 7); `Notifier`, `AgentNotice`, `limitNotifications` (Task 9); `ageLabel` (этап 2).
- Produces:
  - `Theme.Limit`: `track #30333b`, `ok #5b8def`, `warn #ffb340`, `full #ff453a`, `fullText #ff6b61`, бейдж — 15% цвета; `color(forPercent:limitReached:)` через `level(percent:limitReached:)`; размеры: имя 46, полоска блока 4, процент 10.5, поповер 330, полоска поповера 6.
  - `Shortcut.limits` — ⌘⇧ + keyCode 37 (L).
  - `AppState.usageClock: Date` (observable; обновляется при активации приложения, открытии поповера, ↻) — `now` для `usage.view`.
  - `AppState.limitsPopoverShown: Bool`; `func toggleLimitsPopover()` — без данных ни у одного агента → `NSSound.beep()`, поповер не открывается.
  - `AppState.codexRead: (() async throws -> AgentUsage)?` — по умолчанию: лениво `resolveCodex(runner: .local, shell: userShell)`, затем `CodexUsageReader(executable:).read`; codex не найден → nil, строки Codex нет. `func refreshCodexUsage(afterTurn: Bool) async` — через `CodexRefreshGate`; успех → `usage.update(.codex, …)` → `onUsageAlerts`; ошибка → лог, данные прежние. Вызовы: открытие поповера и ↻ (`afterTurn: false`), `onCodexTurn` (`afterTurn: true`).
  - `func limitWindowTitle(_ kind: WindowKind, agent: UsageAgent) -> String` — session → «Сессия (5 ч)» / «Session (5 h)»; weekly → у claude «Неделя · все модели» / «Week · all models», у codex «Неделя» / «Week»; `weeklyModel("opus")` → «Неделя · Opus» / «Week · Opus».
  - `func resetLabel(_ resetsAt: Date, now: Date, calendar: Calendar) -> String` — < 24 ч: «сброс через 1 ч 12 мин · 16:40» / «resets in 1 h 12 min · 16:40»; ≥ 24 ч: «сброс через 2 дн 4 ч · вс 13:20» / «resets in 2 d 4 h · Sun 13:20»; < 1 ч: «сброс через 12 мин · 16:40».
  - `func limitNotice(_ alert: UsageAlert) -> AgentNotice` — id `limit-<agent>`, title `L10n.limitAlmost(agent, percent)` «%@: почти лимит (%d%%)» / «%@: almost at the limit (%d%%)» или `L10n.limitReached(agent)` «%@: лимит исчерпан» / «%@: limit reached»; `leaf: nil`. Публикуется только при `config.limitNotifications`.
- Вид (DESIGN.md «Блок лимитов», «Поповер лимитов», макет `limits.html`): блок над нижней панелью, фон `bottomBar`; строка на агента с данными: имя (46, 11, `text2`), две полоски 4 (сессия, неделя; нет окна — дорожка пустая), максимальный процент (10.5) цветом уровня; наведение `hover`; клик — поповер (`.popover`, ширина 330, радиус 12). Нет данных — строки нет, нет ни одной — блока нет. Рейка: плитка `Icon.limits` цветом худшего уровня (только при данных), клик — тот же поповер. Поповер: на агента — заголовок (имя bold, план `text2`, «обновлено N мин назад» моно `text3` через `L10n.updatedAgo(ageLabel(...))`), на окно — название, бейдж `L10n.limitBadgeAlmost` «почти лимит» / «almost at limit» или `limitBadgeFull` «лимит исчерпан» / «limit reached», процент, полоска 6, `resetLabel`; разделитель между агентами; футер: «⌘⇧L — открыть/закрыть» (`L10n.limitsShortcutHint`) и кнопка `↻ обновить` (`Icon.refresh`, `L10n.refresh`). Всё кликабельное — `.pointingHand()`.

- [ ] **Step 1: Тесты** (RED):
  - `windowTitles` — три вида × два агента × ru/en по Interfaces.
  - `resetLabels` — `Calendar` с `TimeZone(identifier: "Europe/Moscow")`, `now` фиксирован: +1 ч 12 мин → «сброс через 1 ч 12 мин · 16:40»; +2 дн 4 ч → «сброс через 2 дн 4 ч · вс 13:20»; en — «resets in 1 h 12 min · 16:40».
  - `codexRefreshRules` — фейк `codexRead` со счётчиком: открытие поповера → 1 чтение; `onCodexTurn` через 30 с → 1; через 61 с → 2; два одновременных `refreshCodexUsage` → 1; `codexRead == nil` → строки Codex нет.
  - `limitAlertsNotifyOnce` — `usage claude 81` → один `limitNotice` «claude: почти лимит (81%)»; повтор 85 → нет; `limitNotifications = false` → нет.
  - `popoverNeedsData` — без данных `toggleLimitsPopover()` → `limitsPopoverShown == false`; с данными → true, повтор → false.
  - `ShortcutsTests.limits` — `shortcut(keyCode: 37, modifiers: [.command, .shift]) == .limits`; `allCases` содержит `.limits`.
- [ ] **Step 2:** Run: `swift test --filter "LimitsTests|ShortcutsTests|L10nTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4:** Run: `swift test` — Expected: PASS.
- [ ] **Step 5: Проверить вручную:** `usage`-сообщения через `nc -U` (86/41/63, затем 96) → блок и поповер как в `limits.html`, цвета порогов, бейджи, одно уведомление на порог; окно с прошедшим `resetsAt` после активации приложения — 0%; ⌘⇧L в русской раскладке; рейка — плитка; без данных блока нет.
- [ ] **Step 6: Commit** — `git add Sources Tests && git commit -m "feat(ui): subscription limits block, popover and alerts"`

### Task 12: Настройки — интеграция Claude/Codex с окном согласия, переключатели уведомлений

**Files:**
- Create: `Sources/HangarUI/IntegrationModel.swift`, `Sources/HangarUI/IntegrationSheet.swift`, `Tests/HangarUITests/IntegrationModelTests.swift`
- Modify: `Package.swift` (`HangarUI` deps += `Integration`), `Sources/HangarUI/SettingsWindow.swift`, `Sources/HangarApp/main.swift` (пути, DEBUG-переопределения), `Sources/HangarUI/Theme.swift`, `Sources/HangarUI/L10n.swift` + `.strings`

**Interfaces:**
- Consumes: `claudeInstall/Uninstall/State`, `codexInstall/Uninstall/State`, `lineDiff`, `collapsed`, `readUserFile`, `writeUserFile`, `IntegrationError`, `IntegrationState` (Tasks 5–6); `resolveCodex` (Task 4); `notifications`, `limitNotifications`, `save(key:literal:to:)` (Task 9).
- Produces:
  - `func hangarCLIPath(bundle: Bundle) -> String` — `<bundle>/Contents/Helpers/hangar`, если есть; иначе файл `hangar` рядом с `executableURL` (`swift run`).
  - `enum IntegrationTarget { case claude, codex }`; `struct IntegrationPlan: Equatable { var target: IntegrationTarget; var install: Bool; var url: URL; var original: String?; var updated: String; var diff: [DiffLine] /* collapsed */ }`
  - `@MainActor @Observable final class IntegrationModel { init(claudeSettings: URL, codexConfig: URL, cli: String, findCodex: @escaping () async -> String?); var claude: IntegrationState; var codex: CodexAvailability /* enum CodexAvailability: Equatable { case notFound, found(IntegrationState) } */; var error: String?; func refresh() async; func plan(_ target: IntegrationTarget, install: Bool) -> IntegrationPlan? /* ошибка → error */; func apply(_ plan: IntegrationPlan) -> Bool /* writeUserFile(expected: plan.original); backup → в сообщение; ошибка → error */ }`
  - Пути: `~/.claude/settings.json`, `~/.codex/config.toml`; в DEBUG — `HANGAR_CLAUDE_SETTINGS`, `HANGAR_CODEX_CONFIG`.
  - Ошибки → текст: `.invalidJSON(line)` → `L10n.settingsInvalidJSON(line)` «settings.json: ошибка JSON в строке %d — исправьте файл вручную» / «settings.json: JSON error on line %d — fix the file manually»; `.changedOnDisk` → `L10n.fileChanged` «Файл изменился — проверьте изменения ещё раз» / «The file changed — review the changes again» (окно пересчитывает diff); `.unsupportedNotify`/`.invalidTOML` → `L10n.codexConfigUnsupported` «config.toml: notify в неподдерживаемом виде — правьте вручную» / «config.toml: unsupported notify — edit it manually».
- Вид (окно настроек, карточка «подпись → значение» DESIGN.md):
  - «Claude Code» (`L10n.integrationClaude`): `.installed` — «Интеграция установлена» (`text2`) + «Удалить интеграцию» (`L10n.removeIntegration`); `.notInstalled` — предупреждение `failed`: «Hooks не установлены — статусы только по bell и выходу процесса» (`L10n.hooksMissing`) + «Установить…» (`L10n.installEllipsis`); `.outdated` — «Интеграция устарела (приложение перемещено)» + «Обновить…».
  - «Codex» (`L10n.integrationCodex`): `.notFound` — «Codex не найден» (`L10n.codexNotFound`, `text3`), без кнопок; иначе как у Claude (`notify`).
  - «Уведомления» и «Уведомления о лимитах» (`L10n.notificationsSetting`, `L10n.limitNotificationsSetting`) — `Toggle(.switch)`, запись `save(key:literal:)`.
- Окно согласия (`IntegrationSheet`, лист окна настроек, ширина 580): заголовок `L10n.integrationConfirmTitle(path)` «Изменить %@?» / «Change %@?», путь моно; diff моно 11.5 (добавленные — фон `add` + `+` цветом A, удалённые — `del` + `-` цветом D, `skipped(n)` — «… N строк без изменений» `text3`), прокрутка, макс. высота 360; строка `L10n.backupWillBeCreated` «Будет создана копия: %@» / «A backup will be created: %@» (если файл есть); ошибка — строкой `failed`; кнопки «Отмена» / «Применить» (`L10n.apply`, `primary`). Удаление — то же окно с diff удаления.

- [ ] **Step 1: Тесты** (RED; только temp-папки, `findCodex` — фейк):
  - `installFlowWritesBackupAndHooks` — temp `settings.json` со `statusLine` → `plan(.claude, install: true)` содержит `.added` строки с `statusline --then`; `apply` → файл = `claudeInstall(original)`, копия есть, `claude == .installed`.
  - `uninstallFlowRestores` — после установки `plan(install: false)` + `apply` → файл байт в байт исходный.
  - `missingSettingsCreated` — нет папки `.claude` → после `apply` файл создан, копии нет.
  - `changedOnDiskRefused` — между `plan` и `apply` дописать в файл → `apply == false`, `error == L10n.fileChanged`, файл с дописанным текстом не тронут.
  - `invalidJSONShowsError` — файл `{,}` → `plan == nil`, `error == L10n.settingsInvalidJSON(1)`, файл не тронут.
  - `codexNotFound` — `findCodex` → nil → `codex == .notFound`; путь → `.found(.notInstalled)`; установка в temp `config.toml` → `.found(.installed)`.
  - `cliPathPrefersHelpers` — temp `X.app/Contents/Helpers/hangar` + `Bundle(path:)` → этот путь; без Helpers → рядом с `executableURL`.
- [ ] **Step 2:** Run: `swift test --filter "IntegrationModelTests|L10nTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать** модель, окно согласия, строки настроек.
- [ ] **Step 4:** Run: `swift test` — Expected: PASS.
- [ ] **Step 5: Проверить вручную** (только temp-файлы: `HANGAR_CLAUDE_SETTINGS=/tmp/hg-v/claude/settings.json`, `HANGAR_CODEX_CONFIG=/tmp/hg-v/codex/config.toml`, DEBUG): строка Claude с предупреждением → «Установить…» → diff совпадает с итоговым файлом (`diff` вручную) → «Применить» → копия рядом, строка «установлена»; «Удалить интеграцию» → файл как исходный; Codex — «Codex не найден»; переключатели пишут `notifications = false` в `/tmp/hg-v/config.toml`. `stat -f %m ~/.claude/settings.json` до и после — одинаков.
- [ ] **Step 6: Commit** — `git add Package.swift Sources Tests && git commit -m "feat(ui): integration settings with consent diff, backup and removal"`

### Task 13: Приёмка этапа

**Files:**
- Modify: `docs/decisions.md` (дополнение #43 по ходу этапа, «Замеры» этапа 3, открытые вопросы Codex — без изменений: «проверить, когда codex будет установлен»), `docs/superpowers/plans/2026-10-20-hangar-stage3.md` (отметки, «Нужна проверка глазами»)

- [ ] **Step 1:** Run: `swift build && swift test` — Expected: всё PASS (показать сводку).
- [ ] **Step 2: Сценарий с настоящим Claude** без касания `~/.claude`: `scripts/bundle.sh`; DEBUG-сборка с `HANGAR_STATE_DIR=/tmp/hg-a/state HANGAR_CONFIG=/tmp/hg-a/config.toml HANGAR_CLAUDE_SETTINGS=/tmp/hg-a/claude.json`, в `/tmp/hg-a/config.toml` — `[agents] claude = "claude --settings /tmp/hg-a/claude.json"`; установить интеграцию в окне настроек (в `/tmp/hg-a/claude.json`). Задача с claude: промпт → working (голубая), запрос разрешения на Bash → waiting (ореол, импульс, уведомление при скрытой вкладке, клик — вкладка в фокусе), разрешить → working, ответ → done; ⌘Q во время работы — алерт; ⌘Q в простое → открыть → вкладка возобновилась `--resume <id>` (в логе `launch … restoring=true`, id из `state.json`); после первого ответа — блок лимитов claude с реальными процентами; исходная статус-лайна (если была в `--settings`-файле) печатается как раньше.
- [ ] **Step 3: Без hooks:** удалить интеграцию → `printf '\a'` из claude-подобного листа (codex-лист с `[agents] codex = "sh"`) → waiting, фокус → idle; `exit 3` → failed, ↩ → idle.
- [ ] **Step 4: Энергия.** Приложение в простое 5 минут, агенты не работают: `top -l 2 -s 5 -pid $(pgrep -f HangarApp | head -1) -stats pid,cpu | tail -1` — Expected: CPU < 1%; `pgrep -f 'hangar (event|statusline)'` и `pgrep -f 'app-server'` — Expected: пусто; `lsof -p <pid> | grep -c hangar.sock` — Expected: 1 (только слушающий).
- [ ] **Step 5:** `stat -f %m ~/.claude/settings.json` равен значению до этапа (записать оба), `~/.codex` не появился.
- [ ] **Step 6: Commit** — `git add docs && git commit -m "docs: stage 3 acceptance checklist"`

### Нужна проверка глазами (этап 3)

Заполняется по ходу этапа: то, что не проверяется тестами (вид поповера лимитов, ореол и импульс точки, баннер и клик по уведомлению, окно согласия с длинным diff, плитка лимитов в рейке, release idle CPU 5 мин).
