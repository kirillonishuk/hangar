# Hangar — этап 5 (CLI `hangar`, MCP-сервер, «не засыпать») — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Агенты и скрипты управляют Hangar через `hangar projects|tasks|tabs …` и MCP-сервер `hangar mcp` (те же операции по тому же сокету), а Mac не засыпает, пока хотя бы один агент в `working` (+2 мин), с ☕ в сайдбаре и переключателем в настройках.

**Порядок:** 1 → 2 → 3 → 4 → 5 → 6 → 8. Задача 7 независима (можно параллельно после 1).

**Architecture:** NDJSON-протокол `ControlServer` получает третий вид сообщений — запрос/ответ с `id` и `method`; параметры каждого метода описаны одной таблицей `ControlMethod`, из неё же — проверка на сервере, сборка запроса в CLI и JSON Schema инструментов MCP. Приложение отвечает в `AppState+Control.swift` (разрешение ссылок, мутации через существующие `perform`/`createTask`/`NewTaskModel`, доступ к терминалам через замыкания `TerminalAccess`, которые ставит `TerminalArea`). CLI и MCP — чистые функции в модуле `ControlServer` (как `CLISupport.swift`) плюс тонкий `Sources/hangar/main.swift`. «Не засыпать» — новый модуль `Power` (`KeepAwake` поверх `IOPMAssertion`), питается счётчиком `working` из `AppState`.

**Tech Stack:** Swift 6.3, Swift Testing, AppKit + SwiftUI, IOKit (`IOPMAssertionCreateWithName`), Unix-сокет (Darwin), MCP поверх JSON-RPC 2.0 по stdio (руками, без SDK), macOS 14+.

**Spec:** `docs/superpowers/specs/2026-10-18-hangar-design.md` — §2 (`Power`, `ControlServer`, `hangar`), §5.2 (не засыпать), §7 (таблица команд, `--yes` / `yes: true`, `--json`), §8 (сокет занят), §9 (ноль таймеров в простое). Решения — `docs/decisions.md` (#7 CLI и MCP в v1, #18 блокировка сна, #39 реестр действий, #41 запуск листа, #42 worktree / `NewTaskModel`, #43 сокет и протокол, #44 Helix-ввод и вставка; новое #45 — Task 1). Дизайн — `docs/design/DESIGN.md` (иконка `keepAwake` = `cup.and.saucer`, нижняя панель сайдбара, окно настроек, курсор). Правила — `AGENTS.md`.

## Global Constraints

- macOS 14+, Apple Silicon. Без новых зависимостей: MCP и JSON-RPC пишутся руками; IOKit — системный фреймворк.
- Протокол: одна строка JSON на сообщение, `"v":1`, строка ≤ 65 536 байт (`ControlServer.maxLine`); `event`/`usage` и их ответы `{"ok":…}` не меняются. Запрос `{"v":1,"id":N,"method":"…","params":{…}}` → `{"id":N,"result":{…}}` или `{"id":N,"error":{"code":"…","message":"…"}}`. Неизвестный метод → `unknown-method`; неизвестный ключ в `params` → `bad-params`. Проверка `getpeereid` = uid приложения — как сейчас, для всех видов.
- Лимиты: путь ≤ 1024 байт, ссылки (`project`/`task`/`tab`) ≤ 256, имя задачи 1…200 символов без управляющих, `base` ≤ 255, `prompt` ≤ 16 384 байт, `text` в `tabs.send` ≤ 32 768 байт без NUL, `keys` ≤ 32, `lines` 1…5000 (по умолчанию 100), текст ответа `tabs.read` ≤ 512 KiB, ответ ≤ 1 MiB, очередь записи соединения ≤ 4 MiB, запросов в работе на соединение ≤ 8.
- Разрушительное (`tasks archive`): CLI без `--yes` — отказ с кодом выхода 2 без обращения к сокету; MCP без `yes: true` — `isError`; сервер без `yes: true` — `confirm-required`. Других разрушительных команд на этапе нет.
- Вывод CLI и тексты MCP — только английский (машинный интерфейс, вне `L10n`); всё видимое в приложении — через `L10n` (ru + en, `L10nTests.allKeysHaveRuAndEn`), иконки — `enum Icon`, цвета/размеры — `Theme`, `.pointingHand()` на кликабельном.
- Коды выхода CLI: 0 — успех, 1 — ошибка приложения / Hangar не запущен / таймаут, 2 — ошибка использования или нет `--yes`. С `--json`: результат — JSON в stdout, ошибка — `{"error":{"code","message"}}` в stderr.
- Энергия: ноль опросов. Единственный таймер этапа — одноразовый 120 с на снятие блокировки сна, взводится только при переходе «работающих стало 0» при удерживаемой блокировке; в простое без блокировки таймеров нет. Таймаут запроса CLI — `SO_RCVTIMEO`, не таймер.
- Ничего не писать в `~/.claude.json`, `~/.claude/settings.json`, `~/.codex/config.toml` на этом этапе: MCP подключается командами агента, которые пользователь запускает сам.
- Вне рамок: ssh (этап 6), ресурсы/промпты MCP, `tabs close`, `tasks delete`, git-действия.

## Review Focus

1. **Ответ не тому клиенту.** Клиент ушёл, пока запрос выполнялся, а новый клиент получил тот же номер fd. Ожидание: поздний ответ отбрасывается (сверка по объекту соединения, не по fd), текст экрана не уходит чужому соединению, сервер жив. Тест — Task 2 `responseAfterDisconnectDropped`.
2. **Долгие запросы и большие ответы.** `tasks create --worktree` с `git fetch` дольше 10 с (таймаут простоя), `tabs read` ≈ 1 MiB в неблокирующий сокет к медленному читателю. Ожидание: в работе запроса таймер простоя не срабатывает; ответ приходит целиком; CLI ждёт `tasks create` до 300 с. Тесты — Task 2 `slowRequestOutlivesIdleTimeout`, `largeResponseArrivesWhole`; Task 5 `timeoutsPerCommand`.
3. **CLI крадёт фокус и клавиши пользователя.** Агент создаёт задачу или вкладку, пока пользователь печатает в другом терминале. Ожидание: выбранная задача, активная вкладка и первый ответчик не меняются; новая вкладка запускается скрытой. Тесты — Task 3 `createMainFolderKeepsSelection`, Task 4 `tabsOpenKeepsActiveTab`.
4. **Неоднозначная или устаревшая ссылка бьёт не туда.** Два проекта с одним именем, префикс id подходит к двум задачам, имя архивной задачи, id закрытой вкладки. Ожидание: ошибка `ambiguous` (со списком id) или `not-found`, никогда не угадываем. Тесты — Task 3 `resolveRefRules`, `archiveResolvesStrictly`; Task 4 `tabsSendTargets`.
5. **Блокировка сна «залипает» или дёргается.** Флаппинг working → done → working внутри 2 мин, выключение фичи в паузе, выход из приложения, сработавший отменённый таймер. Ожидание: одна блокировка на серию, снятие сразу при выключении/выходе, устаревший таймер ничего не делает. Тесты — Task 7 `flapWithinGraceKeepsOneAssertion`, `disableReleasesImmediately`, `staleTimerIgnored`, `stopReleases`.

Плюс: враждебные параметры по сокету (NUL, переполнение, лишние ключи, `lines: "5"`) — Task 1 `paramsValidated`; stdout `hangar mcp` содержит только JSON-RPC строки — Task 6 `mcpOverStdio`.

---

### Файловая структура

```
Sources/ControlServer/Protocol.swift        + case request; ControlRequest/ControlResponse/ControlError; Envelope без изменений
Sources/ControlServer/Methods.swift         ControlMethod (таблица параметров), ControlCall, TabKind, SendKey, типы результатов
Sources/ControlServer/ControlServer.swift   onRequest, запросы в работе, очередь записи, сверка соединения
Sources/ControlServer/ControlClient.swift   request(_:to:timeout:)
Sources/ControlServer/CLICommands.swift     argv → ControlCall, человекочитаемый вывод, таймауты
Sources/ControlServer/MCP.swift             MCPSession: initialize, ping, tools/list, tools/call
Sources/hangar/main.swift                   projects/tasks/tabs/mcp + прежние event/statusline
Sources/Workspace/Refs.swift                resolveRef (id / имя / путь / префикс)
Sources/HangarUI/AppState+Control.swift     handle(ControlCall) async → результат; TerminalAccess
Sources/HangarUI/SplitView.swift            TerminalArea: startHidden / send / read
Sources/GhosttyBridge/TerminalSurfaceView.swift  SurfaceKey: tab, backspace, стрелки, ctrl-c, ctrl-d
Sources/Power/KeepAwake.swift               KeepAwake + PowerAssertions (IOKit)
Sources/HangarUI/SidebarView.swift, SettingsWindow.swift, IntegrationModel.swift, L10n.swift, Resources/*.lproj
```

### Task 1: Решение #45, спека, запросы протокола и таблица методов

**Files:**
- Create: `Sources/ControlServer/Methods.swift`
- Modify: `Sources/ControlServer/Protocol.swift`, `Tests/ControlServerTests/ProtocolTests.swift`, `docs/decisions.md` (#45), спека (§2 строка `ControlServer`: «этап 5 — запросы/ответы»; §5.2: таймер снятия — единственный, взводится на переходе; §7: `tabs send --tab ID [<text>] [--enter] [--key K]…`, `tabs read --tab ID [--lines N]`, ссылки, коды выхода, английский вывод, подключение MCP командами)

**Interfaces:**
- Produces (`ControlServer`, всё `public`, `Sendable`):
  - `enum TabKind: String, CaseIterable { case claude, codex, editor, shell }`
  - `enum SendKey: String, CaseIterable { case enter, escape, tab, backspace, up, down, left, right, ctrlC = "ctrl-c", ctrlD = "ctrl-d" }`
  - `enum ParamType { case string(maxBytes: Int), bool, int(ClosedRange<Int>), oneOf([String]), list(of: [String], max: Int) }`; `struct ParamSpec { var name: String; var type: ParamType; var required: Bool; var summary: String }`
  - `enum ControlMethod: String, CaseIterable { case projectsList = "projects.list", projectsAdd = "projects.add", tasksList = "tasks.list", tasksCreate = "tasks.create", tabsOpen = "tabs.open", tabsSend = "tabs.send", tabsRead = "tabs.read", tasksArchive = "tasks.archive" }` с `var toolName: String` (`.` → `_`), `var params: [ParamSpec]`, `var summary: String` (англ., описание инструмента MCP).
  - `enum ControlCall: Equatable { case projectsList; case projectsAdd(path: String); case tasksList(project: String?); case tasksCreate(project: String, name: String, worktree: Bool, base: String?, prompt: String?); case tabsOpen(task: String, kind: TabKind, prompt: String?); case tabsSend(tab: String, text: String?, keys: [SendKey]); case tabsRead(tab: String, lines: Int); case tasksArchive(task: String) }`; `var method: ControlMethod`; `func paramsJSON() -> Data` (объект; `tasksArchive` пишет `"yes":true`); `static func decode(method: String, params: [String: Any]) -> Result<ControlCall, ControlError>` — общая проверка по `ControlMethod.params` (лишние/недостающие ключи, типы, лимиты), затем частные правила: `path` абсолютный; `name` после trim непустой, без управляющих символов; `base` только при `worktree: true`; `text` без NUL; в `tabs.send` есть `text` или `keys`; `prompt` у `tabs.open` только для claude/codex; `tasks.archive` без `yes: true` → `.confirmRequired`.
  - `enum ControlErrorCode: String, Codable { case badRequest = "bad-request", unknownMethod = "unknown-method", badParams = "bad-params", notFound = "not-found", ambiguous, confirmRequired = "confirm-required", notStarted = "not-started", exited, failed, busy, tooLarge = "too-large", notRunning = "not-running", timeout }`; `struct ControlError: Error, Equatable, Codable { var code: ControlErrorCode; var message: String }`.
  - `struct ControlRequest: Equatable { var id: Int; var call: Result<ControlCall, ControlError> }`; `ControlMessage` + `case request(ControlRequest)`; `ProtocolError` + `case badRequest = "bad-request"`.
  - `struct ControlResponse { var id: Int?; var body: Result<Data, ControlError> }`, `static func ok<T: Encodable>(_ id: Int, _ value: T) -> ControlResponse`, `func encoded() -> Data` (одна строка + `\n`).
  - Результаты (`Codable, Equatable`): `ProjectInfo { id: UUID; name; path; exists: Bool }`, `LeafInfo { id; kind: TabKind; status: String }`, `TabInfo { id; kind: TabKind /* фокусный лист */; title; status; leaves: [LeafInfo] }`, `TaskInfo { id; name; project: UUID; projectName; status; mode: String /* "main-folder" | "worktree" */; path; branch: String?; base: String?; tabs: [TabInfo] }`; обёртки `ProjectsResult { projects }`, `ProjectAddResult { project; added: Bool }`, `TasksResult { tasks }`, `TaskResult { task }`, `TabResult { task: UUID; tab: TabInfo }`, `SendResult { tab: UUID; leaf: UUID }`, `ScreenResult { tab; leaf; text; lines: Int; truncated: Bool }`, `ArchiveResult { task: UUID; archived: Bool }`.
- Разбор строки: есть `"method"` → запрос (`id` — целое 0…2⁵³, иначе `.badRequest`); есть `"type"` → как раньше.

- [ ] **Step 1: Запись #45 в `decisions.md`** (формат журнала). Решения контроллера: протокол запрос/ответ поверх NDJSON (версия, лимиты, проверка по методу, та же проверка uid); команды §7 с `--json`; ссылки — UUID, уникальный префикс или имя, неоднозначность — ошибка; разрушительное без `--yes`/`yes: true` — отказ (CLI — код 2); MCP — `hangar mcp`, JSON-RPC 2.0 руками (initialize, tools/list, tools/call, ping), тот же сокет; безопасность: любой локальный процесс пользователя может управлять Hangar и печатать в любой терминал (`tabs send`) и читать экран (`tabs read`, может содержать секреты) — это то же доверие, что у самого терминала, ограничение — uid сокета; `tabs send` в лист, ждущий разрешения, разрешён (так оркестратор отвечает на запрос); «не засыпать» — `PreventUserIdleSystemSleep`, снятие через 2 мин одноразовым таймером. Решения плана:
  - Таблица `ControlMethod` — единственный источник параметров: проверка сервера, CLI и JSON Schema MCP. Лишние ключи — `bad-params` (опечатка в `yes` не проходит молча).
  - Разрешение ссылок: полный UUID → точное имя (у проекта — и путь) → префикс id ≥ 4 символов без учёта регистра; на любом шаге > 1 совпадения — `ambiguous` со списком id; архивные задачи не находятся. Вкладки — только по id/префиксу (заголовки меняет терминал); `--tab` принимает id вкладки (→ её фокусный лист) или id листа; лист панели TERMINAL не адресуется (`shortcut:`).
  - Задачи и вкладки из CLI/MCP не меняют выбранную задачу, активную вкладку и фокус; их surface запускаются сразу скрытыми (иначе агент с `--prompt` не стартовал бы до показа).
  - `tasks create --worktree` — через тот же `NewTaskModel` без листа (fetch, проверка ветки, путь worktree как в UI); ошибка fetch — ошибка команды (кнопки «без fetch» нет); идёт в счёт «создаётся задача» для ⌘Q.
  - `tabs send`: текст — вставкой (bracketed paste, как #44), клавиши — настоящими нажатиями из фиксированного набора `SendKey`; сначала текст, потом клавиши. Невидимая, ещё не запускавшаяся вкладка сначала запускается. `tabs read`: последние N строк (по умолчанию 100) без хвостовых пустых, ≤ 512 KiB.
  - Вывод CLI/MCP — английский, включая «Hangar is not running» (код `not-running`).
  - MCP подключается командами `claude mcp add --scope user hangar -- '<cli>' mcp` и `codex mcp add hangar -- '<cli>' mcp`, которые настройки показывают с кнопкой «Скопировать»; Hangar сам конфиги агентов не правит (их формат и место — дело агента; для Codex не нужен редактор таблиц TOML).
  - `Power` — отдельный модуль SwiftPM; имя блокировки меняется `IOPMAssertionSetProperty(kIOPMAssertionNameKey)`, при ошибке — пересоздание. ☕ — кнопка в строке «Настройки» нижней панели развёрнутого сайдбара (в рейке нет, `shortcut:`), неактивный пункт «Не засыпать» в меню «…» удаляется.
  - Отвергнуто: правка `~/.claude.json` и `config.toml` для MCP; MCP SDK; HTTP-транспорт; опрос статусов; печать текста посимвольными нажатиями.
- [ ] **Step 2: Тесты** (`ProtocolTests`, RED):
  - `requestRoundTrip` — для каждого образца `ControlCall` (все 8 методов) `decode(method:params:)` от `paramsJSON()` возвращает тот же `ControlCall`; строка `{"v":1,"id":7,"method":"tasks.list","params":{}}` → `.request(ControlRequest(id: 7, call: .success(.tasksList(project: nil))))`.
  - `unknownMethodKeepsId` — `"method":"tabs.close"` с `id` 7 → `id == 7`, `call` = `.failure(code: .unknownMethod)`.
  - `paramsValidated` — каждое → `.badParams`: лишний ключ `"force":1` в `tasks.archive`; нет `name` в `tasks.create`; `"lines":"5"`; `lines` 0 и 5001; `text` с `\u0000`; `text` 32 769 байт; `kind:"diff"`; `keys:["f13"]`; 33 ключа; `name:"  "`; `name:"a\nb"`; `path:"rel/dir"`; `base` без `worktree:true`; `prompt` у `tabs.open` с `kind:"shell"`; `tabs.send` без `text` и `keys`.
  - `archiveNeedsYes` — без `yes` и с `yes:false` → `.confirmRequired`; `yes:true` → `.tasksArchive(task:)`.
  - `missingIdIsBadRequest` — без `id`, `"id":"7"`, `"id":-1`, `"v":2` → `.failure(.badRequest)` / `.badVersion`.
  - `responseEncoding` — `.ok(3, ArchiveResult(task: u, archived: true))` → одна строка `{"id":3,"result":{…}}\n`; ошибка → `{"id":3,"error":{"code":"not-found","message":"no task \"x\""}}\n`; `id: nil` → `"id":null`.
  - Прежние тесты `event`/`usage` не меняются и проходят.
- [ ] **Step 3:** Run: `swift test --filter ProtocolTests` — Expected: FAIL (нет `ControlCall`).
- [ ] **Step 4: Реализовать** `Methods.swift` и расширение `Protocol.swift` по Interfaces (разбор `params` через `JSONSerialization`; `Bool` из `NSNumber` отличать от чисел по `CFBooleanGetTypeID`).
- [ ] **Step 5:** Run: `swift test --filter ProtocolTests` — Expected: PASS.
- [ ] **Step 6: Commit** — `git add docs Sources/ControlServer Tests/ControlServerTests && git commit -m "feat(control): request/response protocol with per-method validation"`

### Task 2: Сервер отвечает на запросы, клиент `request`

**Files:**
- Modify: `Sources/ControlServer/ControlServer.swift`, `Sources/ControlServer/ControlClient.swift`, `Tests/ControlServerTests/ControlServerTests.swift`

**Interfaces:**
- Consumes: Task 1 (`ControlRequest`, `ControlResponse`, `ControlError`, `ControlCall.paramsJSON`).
- Produces:
  - `ControlServer.init(path: String, handler: @escaping @MainActor (ControlMessage) -> Void, onRequest: @escaping @MainActor (Int, ControlCall) async -> ControlResponse = { id, _ in ControlResponse(id: id, body: .failure(ControlError(code: .unknownMethod, message: "not supported"))) })`
  - `static let maxResponse = 1_048_576`, `maxOutbox = 4_194_304`, `maxInFlight = 8`.
  - `ControlClient.request(_ call: ControlCall, to path: String, timeout: Double) -> Result<Data, ControlError>` — `Data` = JSON значения `result`; `connect` с `ENOENT`/`ECONNREFUSED` → `.notRunning` («Hangar is not running»); истёк `SO_RCVTIMEO`/`SO_SNDTIMEO` → `.timeout`; ответ > 2 MiB или чужой `id` → `.badRequest`.
- Правила сервера: запрос с `call = .failure` отвечается сразу с очереди, без main; успешный — `Task { @MainActor in … }`, ответ возвращается на `queue` и пишется, только если `connections[fd] === тот же Connection`. Пока у соединения есть запросы в работе, таймер простоя не взводится; после записи последнего ответа — взводится. Девятый одновременный запрос — `busy`. Все ответы (и `{"ok":…}`) идут через очередь записи соединения: `write` до `EAGAIN`, остаток — `DispatchSourceWrite`; очередь > `maxOutbox` — соединение закрывается. Ответ > `maxResponse` заменяется ошибкой `too-large`.

- [ ] **Step 1: Тесты** (`ControlServerTests`, RED; сырые сокеты — существующий помощник):
  - `requestGetsResponse` — `onRequest` возвращает `.ok(id, ProjectsResult(projects: []))`; строка `projects.list` с `id` 5 → ответ `{"id":5,"result":{"projects":[]}}`.
  - `invalidRequestAnsweredWithoutHandler` — `tasks.archive` без `yes` → `{"id":1,"error":{"code":"confirm-required",…}}`, счётчик вызовов `onRequest` = 0.
  - `slowRequestOutlivesIdleTimeout` — `idleTimeout = 0.2`, обработчик спит 0.6 с → ответ получен, EOF нет до него.
  - `largeResponseArrivesWhole` — результат `ScreenResult` с текстом 900 000 байт; клиент ждёт 0.3 с, потом читает → строка разбирается, длина текста 900 000.
  - `responseAfterDisconnectDropped` — первый клиент шлёт запрос (обработчик ждёт сигнала) и закрывается; второй клиент подключается и шлёт `event`; сигнал → второй получил только `{"ok":true}`; сервер отвечает третьему клиенту.
  - `inFlightCapPerConnection` — 9 запросов одной пачкой при блокирующем обработчике → ровно один ответ `busy` до разблокировки, затем 8 результатов.
  - `slowReaderOverOutboxCapDropped` — 8 запросов по 900 000 байт, клиент не читает → соединение закрыто (EOF при чтении после паузы), новый клиент обслуживается.
  - `clientRequestRoundTrip` — `ControlClient.request(.tasksList(project: nil), …, timeout: 2)` → `.success`, JSON декодируется в `TasksResult`.
  - `clientNotRunning` — нет сокета → `.failure(code: .notRunning)` за < 0.5 с.
  - `clientTimeout` — обработчик не отвечает, `timeout: 0.3` → `.failure(code: .timeout)` за < 1.5 с.
- [ ] **Step 2:** Run: `swift test --filter ControlServerTests` — Expected: FAIL.
- [ ] **Step 3: Реализовать** по Interfaces.
- [ ] **Step 4:** Run: `swift test --filter "ControlServerTests|ProtocolTests|HangarCLITests"` — Expected: PASS (прежние тесты событий не тронуты).
- [ ] **Step 5: Commit** — `git add Sources/ControlServer Tests/ControlServerTests && git commit -m "feat(control): server answers requests; client request with timeout"`

### Task 3: Ссылки и команды проектов/задач в приложении

**Files:**
- Create: `Sources/Workspace/Refs.swift`, `Tests/WorkspaceTests/RefsTests.swift`, `Sources/HangarUI/AppState+Control.swift`, `Tests/HangarUITests/ControlRequestTests.swift`
- Modify: `Sources/HangarUI/AppState.swift` (`createTask(…, select:)`, `controlCreating`), `Sources/HangarUI/MainWindow.swift:566` (`creating: isCreatingTask || app.controlCreating > 0`), `Sources/HangarApp/main.swift` (`onRequest: { [weak self] id, call in await self?.appState?.respond(id, call) ?? … }`)

**Interfaces:**
- Consumes: Task 1 (`ControlCall`, результаты, `ControlError`), `NewTaskModel` (`load()`, `name`, `worktree`, `base`, `branches`, `availability`, `create(skipFetch:)`, `createError`, `branchError`, `fetch`), `AppState.addProject(path:)`, `archive(taskId:)`, `displayState(of:)`.
- Produces:
  - `Workspace`: `struct RefCandidate { var id: UUID; var names: [String] }`, `enum RefError: Error, Equatable { case notFound, ambiguous([UUID]) }`, `func resolveRef(_ ref: String, in: [RefCandidate]) -> Result<UUID, RefError>`.
  - `AppState`: `func respond(_ id: Int, _ call: ControlCall) async -> ControlResponse`; `private(set) var controlCreating: Int`; `createTask(projectId:name:firstMessage:mode:select: Bool = true) -> (task: UUID, tab: UUID)` (`@discardableResult`); `func taskInfo(_ task: HangarTask) -> TaskInfo`.
  - `struct TerminalAccess { var start: (UUID /* tab */) -> Void; var send: (UUID /* leaf */, String?, [SendKey]) -> SendOutcome; var read: (UUID /* leaf */) -> String? }`, `enum SendOutcome { case sent, notStarted, exited }`; `@ObservationIgnored var terminals: TerminalAccess?` — здесь используется только `start` (после create).
- Правила ответов: `projects.add` — папка должна существовать (`not-found` «no such directory»), уже есть проект с тем же путём → `added: false` и он же. `tasks.list` — неархивные задачи в порядке сайдбара (проекты → `order`), статус — `displayState(...).rawValue`. `tasks.create` — без worktree `.mainFolder`; с worktree: `availability` ≠ `.ready` → `failed` («not a git repository» / «repository has no commits»), `base` нет среди `branches` → `not-found`, `create` вернул nil → `failed` с `createError ?? branchError ?? текст fetch`. Результат — `TaskResult` с первой вкладкой. `tasks.archive` — `archive(taskId:)`, worktree остаётся (#42).

- [ ] **Step 1: Тесты** (RED):
  - `RefsTests.resolveRefRules` — полный UUID (верхний регистр тоже) → он; UUID, которого нет → `.notFound`; префикс `"ab12"` одного id → он, двух → `.ambiguous([a, b])`; префикс 3 символа → `.notFound`; точное имя → он, два одинаковых имени → `.ambiguous`; имя важнее префикса (задача по имени `"abcd"` и другой id на `abcd…` → задача по имени); `""` и `"  "` → `.notFound`.
  - `ControlRequestTests` (`AppState` как в `ActionsTests`, `TempRepo`):
    - `projectsListAndAdd` — `projects.add` temp-папки → `added: true`; повтор → `added: false`, тот же id; несуществующая папка → `not-found`; `projects.list` → `exists: true` у живой, `false` у удалённой с диска.
    - `tasksListShape` — две задачи, у одной сплит claude│shell и лист в `working` → `status: "working"`, `tabs[0].leaves.count == 2`, `mode: "main-folder"`; архивная не в списке; фильтр `project` по имени и по пути.
    - `createMainFolderKeepsSelection` — выбрана задача A; `tasks.create(project, "B", prompt: "hi")` → задача B есть, `selectedTaskId == A`, у B одна вкладка вида `config.defaultAgent`, `launchContext(for: leaf) == .created(prompt: "hi")`, фейк `terminals.start` вызван с id этой вкладки.
    - `createWorktree` — репо с коммитом без remote: `worktree: true, base: <текущая ветка>`, имя «Fix login» → `mode` worktree, папка существует, ветка `fix-login`; `base: "nope"` → `not-found`; не-git папка → `failed`, задач не прибавилось; `controlCreating == 0` после каждого вызова.
    - `archiveResolvesStrictly` — две задачи «x» в разных проектах → `ambiguous`, ни одна не архивирована; по id → `archived: true`, папка worktree на месте; повтор по тому же id → `not-found`.
- [ ] **Step 2:** Run: `swift test --filter "RefsTests|ControlRequestTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать** по Interfaces; `respond` — `switch` по `ControlCall`, ошибки `RefError` → `not-found` («no project "x"») / `ambiguous` («"x" matches: <id>, <id>», до 5 id).
- [ ] **Step 4:** Run: `swift build && swift test --filter "RefsTests|ControlRequestTests|ActionsTests|NewTaskModelTests"` — Expected: PASS.
- [ ] **Step 5: Commit** — `git add Sources Tests && git commit -m "feat(control): projects and tasks commands in the app"`

### Task 4: Вкладки — открыть, отправить, прочитать

**Files:**
- Modify: `Sources/HangarUI/AppState+Control.swift`, `Sources/HangarUI/SplitView.swift` (`TerminalArea`: ставит `app.terminals` в `init`), `Sources/GhosttyBridge/TerminalSurfaceView.swift` (`SurfaceKey`), `Tests/HangarUITests/ControlRequestTests.swift`

**Interfaces:**
- Consumes: Task 3 (`TerminalAccess`, `SendOutcome`, `resolveRef`, `respond`), `WorkspaceState.addTab(taskId:kind:)` (сам ставит `activeTabId` — восстановить прежний), `pendingPrompts` через `launchContext`.
- Produces:
  - `SurfaceKey` + `case tab /* 48 */, backspace /* 51 */, up /* 126 */, down /* 125 */, left /* 123 */, right /* 124 */, ctrlC /* 8 + ctrl, codepoint "c" */, ctrlD /* 2 + ctrl, "d" */`; `.enter` — существующий `sendEnter()`.
  - `TerminalArea.startHidden(tabId: UUID)` — `show(tab)` для вкладки неархивной задачи и `sync()` (вид скрыт, `setVisible(false)`, первый ответчик не меняется); `send` — нет `LeafView`/surface → `.notStarted`, `needsRelaunch` → `.exited`, иначе `sendText` + клавиши по порядку; `read` — `surface?.screenText()`.
- Правила: `tabs.open` — задача по ссылке, вкладка добавлена в конец, `activeTabId` задачи прежний (если был), `prompt` → `pendingPrompts[leaf]`, затем `terminals.start(tab)`; результат `TabResult`. `tabs.send` — ссылка среди вкладок и листьев неархивных задач (лист TERMINAL — нет); `.notStarted` → `start(tab)` и повтор; повтор снова `.notStarted` → `not-started`; `.exited` → `exited` («process has exited; relaunch the tab»). `tabs.read` — `nil` → `not-started`; текст без хвостовых пустых строк, последние `lines` строк; если строк было больше или обрезано по 512 KiB (с начала) → `truncated: true`.

- [ ] **Step 1: Тесты** (RED; фейковый `TerminalAccess` пишет вызовы):
  - `tabsOpenKeepsActiveTab` — выбрана задача с активной вкладкой X; `tabs.open(kind: .claude, prompt: "go")` → вкладок +1, `activeTabId == X`, `selectedTaskId` прежний, `start` вызван с новым id, `launchContext` нового листа `.created(prompt: "go")`; задача по архивному имени → `not-found`.
  - `tabsSendTargets` — сплит-вкладка: ссылка на вкладку → `send` получил её `focusedLeafId`; id второго листа → этот лист; id листа TERMINAL → `not-found`; `text: "hi", keys: [.enter]` → фейк получил `("hi", [.enter])`; первый ответ фейка `.notStarted`, второй `.sent` → `start` вызван один раз, ответ `SendResult`; `.exited` → `exited`.
  - `waitingLeafAcceptsSend` — лист в `waiting` → `tabs.send` успешен, статус не изменён отправкой.
  - `tabsReadLastLines` — экран `"a\nb\nc\n\n\n"`, `lines: 2` → `text == "b\nc"`, `lines == 2`, `truncated == true`; `lines: 10` → `"a\nb\nc"`, `truncated == false`; экран 2 MiB одной длинной строкой → `text.utf8.count <= 524_288`, `truncated == true`; `nil` → `not-started`.
- [ ] **Step 2:** Run: `swift test --filter ControlRequestTests` — Expected: FAIL.
- [ ] **Step 3: Реализовать** по Interfaces.
- [ ] **Step 4:** Run: `swift build && swift test --filter "ControlRequestTests|AgentWiringTests|EditorOpenerTests"` — Expected: PASS.
- [ ] **Step 5: Commit** — `git add Sources Tests && git commit -m "feat(control): open, send to and read tabs"`

### Task 5: Команды CLI `hangar projects|tasks|tabs`

**Files:**
- Create: `Sources/ControlServer/CLICommands.swift`, `Tests/ControlServerTests/CLICommandsTests.swift`
- Modify: `Sources/hangar/main.swift` (новые ветки `switch`, `usage` со всеми командами), `Tests/HangarCLITests/HangarCLITests.swift`

**Interfaces:**
- Consumes: Task 1 (`ControlCall`, результаты), Task 2 (`ControlClient.request`).
- Produces:
  - `enum CLIParse: Equatable { case call(ControlCall, json: Bool); case usage(String); case confirmRequired(String) }`; `func parseCLI(_ args: [String], cwd: String) -> CLIParse` (`args` — после имени программы, первое слово — `projects`/`tasks`/`tabs`).
  - `func requestTimeout(_ call: ControlCall) -> Double` — `tasksCreate` 300, остальное 10.
  - `func formatHuman(_ call: ControlCall, result: Data) -> String`.
- Правила разбора: флаги в любом порядке, `--` завершает флаги; `tabs send` — позиционные слова до/после флагов склеиваются пробелом в `text`, `--enter` = `.enter` в конец `keys`, `--key K` повторяется (имя из `SendKey`); `projects add <path>` — относительный путь от `cwd`, `standardized`; `--base` без `--worktree`, неизвестный флаг, нет обязательного, `--lines abc`, `--kind diff` → `.usage`; `tasks archive` без `--yes` → `.confirmRequired("refusing to archive without --yes")`. Человекочитаемо: `projects list` — `<id8>  <name>  <path>`; `tasks list` — `<id8>  <status>  <project>/<name>[  ⎇ <branch>]`, под ней вкладки `    <id8>  <kind>  <status>  <title>`; `tasks create` — `task <id> tab <id>`; `tabs open` — `tab <id>`; `tabs send` — пусто; `tabs read` — сам текст; `projects add` — `<id>  <path>` (+ `  (already added)`); `archive` — `archived <id>`.
- `main.swift`: `.usage`/`.confirmRequired` → stderr, `exit(2)` без подключения; ошибка запроса → stderr `hangar: <message>` (с `--json` — JSON ошибки), `exit(1)`; успех → stdout (`--json` — `result` с `.prettyPrinted, .sortedKeys`).

- [ ] **Step 1: Тесты** (RED):
  - `CLICommandsTests.parsesEveryCommand` — таблица: `["tasks","create","--project","p","--name","N","--worktree","--base","origin/main","--prompt","do it"]` → `.tasksCreate(project: "p", name: "N", worktree: true, base: "origin/main", prompt: "do it")`; `["tabs","send","--tab","ab12","hello","world","--enter"]` → `.tabsSend(tab: "ab12", text: "hello world", keys: [.enter])`; `["tabs","send","--tab","x","--key","escape","--key","down"]` → `text: nil, keys: [.escape, .down]`; `["tabs","read","--tab","x","--lines","20","--json"]` → `.tabsRead(tab: "x", lines: 20)`, `json: true`; `["projects","add","../x"]` при `cwd: "/tmp/a/b"` → `.projectsAdd(path: "/tmp/a/x")`; `["tasks","list","--project","p"]`.
  - `textAfterDoubleDash` — `["tabs","send","--tab","x","--","--enter"]` → `text: "--enter", keys: []`.
  - `usageErrors` — каждое перечисленное в правилах → `.usage`; `["tasks","archive","--task","t"]` → `.confirmRequired`.
  - `timeoutsPerCommand` — `tasksCreate` → 300, `tabsRead` → 10.
  - `humanFormat` — `TasksResult` с задачей в worktree и двумя вкладками → ровно три строки в описанном формате.
  - `HangarCLITests` (бинарник против `ControlServer` с фейковым `onRequest`):
    - `cliJSONOutput` — `hangar tasks list --json` → exit 0, stdout декодируется в тот же `TasksResult`, фейк получил `.tasksList(project: nil)`.
    - `cliNotRunning` — сокета нет → exit 1, stderr содержит `Hangar is not running`, < 2 с.
    - `cliArchiveWithoutYes` — exit 2, фейк получил 0 запросов.
    - `cliAppError` — фейк отвечает `not-found` → exit 1, stderr `hangar: no task "x"`; с `--json` stderr — `{"error":{"code":"not-found",…}}`.
    - Прежние тесты `event`/`statusline` — без изменений, PASS.
- [ ] **Step 2:** Run: `swift test --filter "CLICommandsTests|HangarCLITests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать** по Interfaces.
- [ ] **Step 4:** Run: `swift build && swift test --filter "CLICommandsTests|HangarCLITests"` — Expected: PASS.
- [ ] **Step 5: Commit** — `git add Sources Tests && git commit -m "feat(cli): projects, tasks and tabs commands with --json"`

### Task 6: MCP-сервер `hangar mcp` и строка «MCP-сервер Hangar» в настройках

**Files:**
- Create: `Sources/ControlServer/MCP.swift`, `Tests/ControlServerTests/MCPTests.swift`
- Modify: `Sources/hangar/main.swift` (`case "mcp"`), `Tests/HangarCLITests/HangarCLITests.swift`, `Sources/HangarUI/IntegrationModel.swift` (`mcpAddCommands`), `Sources/HangarUI/SettingsWindow.swift`, `Sources/HangarUI/L10n.swift` + `Resources/{ru,en}.lproj/Localizable.strings`, `Tests/HangarUITests/IntegrationModelTests.swift`, `docs/design/DESIGN.md` (окно настроек: строка «MCP-сервер Hangar»)

**Interfaces:**
- Consumes: Task 1 (`ControlMethod.params`/`summary`/`toolName`, `ControlCall.decode`), Task 2 (`ControlClient.request`), Task 5 (`requestTimeout`), `hangarCLIPath(bundle:)`, `shellQuote` (`Exec`).
- Produces:
  - `struct MCPSession { init(call: @escaping (ControlCall) -> Result<Data, ControlError>); mutating func handle(_ line: Data) -> Data? }` — ответ одной строкой без `\n` внутри (вызывающий дописывает `\n`); `nil` для уведомлений (нет `id`).
  - `let mcpProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]`.
  - `func mcpAddCommands(cli: String) -> (claude: String, codex: String)` (HangarUI).
- Правила: `initialize` → `{"protocolVersion": <версия клиента, если в списке, иначе первая>, "capabilities":{"tools":{}}, "serverInfo":{"name":"hangar","version":<CFBundleShortVersionString или "dev">}}`; `ping` → `{}`; `tools/list` → инструменты в порядке `ControlMethod.allCases`, `inputSchema` = `{"type":"object","properties":{…},"required":[…],"additionalProperties":false}` из `ParamSpec` (`string` → `{"type":"string","maxLength"}`, `oneOf` → `enum`, `list` → `array` с `items.enum` и `maxItems`, `int` → `integer` с `minimum`/`maximum`); `tools/call` → имя инструмента → метод, `arguments` → `ControlCall.decode`; ошибка проверки или ответа приложения → `{"content":[{"type":"text","text":<message>}],"isError":true}`; успех → `text` = компактный JSON результата, `isError: false`. JSON-RPC ошибки: разбор → `-32700` (`id: null`), не объект/массив (батч) → `-32600`, неизвестный метод → `-32601`, неизвестный инструмент → `-32602`. `id` (строка или число) возвращается как есть. Строка stdin > 1 MiB → `-32600` и пропуск.
  - `hangar mcp`: читает stdin построчно до EOF, отвечает в stdout (`fflush` на каждую строку), логи — только stderr; запросы последовательно; сокет — `defaultSocketPath()`; exit 0 на EOF.
  - Настройки: строка «MCP-сервер Hangar» после «Codex»: две моно-команды (`small`, `text2`, перенос) с кнопками `SheetButton` «Скопировать» (`NSPasteboard`, затем сообщение внизу «Команда скопирована»); вне собранного .app — текст «Доступно только в собранном приложении» (существующий ключ `integrationNeedsApp`). Подсказка `text3`: «Запустите в терминале — Hangar сам конфиги агентов не меняет».

- [ ] **Step 1: Тесты** (RED; записанные обмены — строки JSON в тесте):
  - `initializeHandshake` — `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}` → `result.protocolVersion == "2025-06-18"`, `result.capabilities.tools` — объект, `serverInfo.name == "hangar"`; с `"2099-01-01"` → `"2025-06-18"`; `{"jsonrpc":"2.0","method":"notifications/initialized"}` → `nil`; `ping` с `id` 2 → `{"jsonrpc":"2.0","id":2,"result":{}}`.
  - `toolsListMatchesMethods` — имена ровно `["projects_list","projects_add","tasks_list","tasks_create","tabs_open","tabs_send","tabs_read","tasks_archive"]`; у каждого `additionalProperties == false`; `tasks_archive.required == ["task","yes"]`; `tabs_send.properties.keys.items.enum` == `SendKey.allCases.map(\.rawValue)`; `tabs_read.properties.lines.maximum == 5000`.
  - `toolsCallSuccess` — фейк возвращает `{"tasks":[]}` → `content[0].type == "text"`, `text == "{\"tasks\":[]}"`, `isError == false`; фейк получил `.tasksList(project: nil)`.
  - `toolsCallErrors` — `tasks_archive` с `{"task":"t"}` → `isError: true`, текст содержит `yes: true`, фейк не вызван; фейк `.notRunning` → `isError: true`, текст `Hangar is not running`; `{"lines":"5"}` у `tabs_read` → `isError: true`; имя `tabs_close` → JSON-RPC ошибка `-32602`.
  - `protocolErrors` — `not json` → `{"jsonrpc":"2.0","id":null,"error":{"code":-32700,…}}`; `[{…}]` → `-32600`; `resources/list` с `id` → `-32601`; `"id":"a1"` → в ответе `"id":"a1"`.
  - `HangarCLITests.mcpOverStdio` — бинарник `hangar mcp` с `HANGAR_SOCKET` тестового сервера; stdin: initialize, `notifications/initialized`, tools/list, tools/call `tasks_list`, EOF → exit 0, в stdout ровно 3 строки, каждая — объект с `"jsonrpc":"2.0"` и `id` 1, 2, 3; stderr пуст.
  - `IntegrationModelTests.mcpAddCommandsQuoted` — cli `/Applications/My Hangar.app/Contents/Helpers/hangar` → `claude mcp add --scope user hangar -- '/Applications/My Hangar.app/Contents/Helpers/hangar' mcp` и `codex mcp add hangar -- '/Applications/My Hangar.app/Contents/Helpers/hangar' mcp`.
- [ ] **Step 2:** Run: `swift test --filter "MCPTests|HangarCLITests|IntegrationModelTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать** по Interfaces; L10n (ru/en): `integrationMCP` «MCP-сервер Hangar»/«Hangar MCP server», `copyCommand` «Скопировать»/«Copy», `commandCopied` «Команда скопирована»/«Command copied», `mcpHint` «Запустите в терминале — Hangar сам конфиги агентов не меняет»/«Run it in a terminal — Hangar does not edit agent configs itself». Пометка `// verify: codex mcp add — codex не установлен` у команды Codex.
- [ ] **Step 4:** Run: `swift build && swift test --filter "MCPTests|HangarCLITests|IntegrationModelTests|L10nTests"` — Expected: PASS.
- [ ] **Step 5: Проверить вручную** — окно настроек: строка не ломает ширину 580, команды переносятся, «Скопировать» кладёт команду в буфер, курсор — рука.
- [ ] **Step 6: Commit** — `git add Sources Tests docs/design && git commit -m "feat(mcp): stdio MCP server over the control socket; settings show install commands"`

### Task 7: «Не засыпать, пока агенты работают» (`Power`, ☕, настройка)

**Files:**
- Create: `Sources/Power/KeepAwake.swift`, `Tests/PowerTests/KeepAwakeTests.swift`
- Modify: `Package.swift` (`.target(name: "Power", linkerSettings: [.linkedFramework("IOKit")])`, `HangarUI` зависит от `Power`, `.testTarget(name: "PowerTests", dependencies: ["Power"])`), `Sources/Workspace/Config.swift` (`keepAwake`, ключ `keep_awake`), `Tests/WorkspaceTests/ConfigTests.swift`, `Sources/HangarUI/AppState.swift` (`keepAwake`, `statuses` `didSet`), `Sources/HangarUI/SidebarView.swift`, `Sources/HangarUI/SettingsWindow.swift`, `Sources/HangarUI/L10n.swift` + строки, `Sources/HangarApp/main.swift` (`applicationWillTerminate` → `appState?.keepAwake.stop()`), `Tests/HangarUITests/AgentWiringTests.swift`, `docs/design/DESIGN.md` («Сайдбар»: ☕ в строке «Настройки»; окно настроек: строка «Не засыпать»)

**Interfaces:**
- Consumes: `AppState.workingLeafCount`, `setConfig(_:flag:apply:)`, `Icon.keepAwake`, `Theme.ui.accent`.
- Produces (`Power`):
  - `struct PowerAssertions: Sendable { var create: @Sendable (String) -> UInt32?; var rename: @Sendable (UInt32, String) -> Bool; var release: @Sendable (UInt32) -> Void; static let system: PowerAssertions }` — `system`: `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionLevelOn, name)`, `IOPMAssertionSetProperty(id, kIOPMAssertionNameKey, name)`, `IOPMAssertionRelease`.
  - `@MainActor @Observable final class KeepAwake { init(assertions: PowerAssertions = .system, grace: Duration = .seconds(120), name: @escaping (Int) -> String, schedule: @escaping (Duration, @escaping @MainActor () -> Void) -> (() -> Void) = KeepAwake.taskSchedule); private(set) var held: Bool; private(set) var working: Int; func update(working: Int, enabled: Bool); func stop() }` — `taskSchedule` = `Task { try? await Task.sleep(for:); body() }` с отменой.
  - Автомат: `enabled && working > 0` — отменить ожидающее снятие; нет блокировки → `create(name(n))` (nil → `held = false`, повтор при следующем изменении счётчика); есть и `n` изменился → `rename`, при `false` — `create` нового и `release` старого. `enabled && working == 0 && held && нет ожидания` → одно `schedule(grace)`; срабатывание проверяет поколение (отменённое/устаревшее — ничего) → `release`. `!enabled` → отменить ожидание, `release` сразу. `stop()` — то же и дальше `update` игнорируется.
  - `HangarConfig.keepAwake = true` (голый bool, как `notifications`). `AppState`: `@ObservationIgnored lazy var keepAwake = KeepAwake(name: L10n.keepAwakeAssertion)` (тесты подменяют до первого события); `statuses` `didSet` и `setConfig("keep_awake")` → `keepAwake.update(working: workingLeafCount, enabled: config.keepAwake)`.
  - Сайдбар: в строке «Настройки» перед «…» — кнопка `IconView(icon: .keepAwake)` 15 pt, зона 28×28, цвет `accent` при `held`, иначе `text3`; клик — переключает `keep_awake`; `.help` — выключено: «Не засыпать: выключено», ждёт: «Не засыпать, пока агенты работают», держит: «Mac не уснёт: работающих агентов — N» (при N = 0 — «Mac не уснёт ещё до 2 мин»); `.pointingHand()`. Пункт меню «…» `L10n.keepAwake` (неактивный) удалить.
  - Настройки: строка «Не засыпать, пока агенты работают» — `Segment` вкл/выкл после «Уведомления о лимитах».
  - `L10n.keepAwakeAssertion(_ n: Int) -> String` — ru: 1, 21, 101 → «Hangar: N агент работает»; 2–4, 22–24 → «Hangar: N агента работают»; 0, 5–20, 11–14, 111 → «Hangar: N агентов работают»; en: 1 → «Hangar: 1 agent working», иначе «Hangar: N agents working». Ключи `keepAwakeAssertionOne/Few/Many` (en few = many), `keepAwakeTitle`, `keepAwakeOffHelp`, `keepAwakeIdleHelp`, `keepAwakeActiveHelp` (`%ld`), `keepAwakeGraceHelp`.

- [ ] **Step 1: Тесты** (RED; фейковые `PowerAssertions` и ручной `schedule`, возвращающий отмену и хранящий тело):
  - `holdsWhileWorking` — `update(1, true)` → `create` один раз с `name(1)`, `held`; `update(3, true)` → `rename(id, name(3))`, `create` всё ещё 1.
  - `releaseAfterGrace` — после `update(0, true)` `held` ещё true, `schedule` вызван 1 раз с 120 с; тело → `release` 1 раз, `held == false`; повторный `update(0, true)` → `schedule` всё ещё 1.
  - `noTimerWhenIdle` — новый `KeepAwake`, `update(0, true)` → `create` 0, `schedule` 0.
  - `flapWithinGraceKeepsOneAssertion` — 1 → 0 → 1 до срабатывания → `create` 1, `release` 0, отмена вызвана.
  - `staleTimerIgnored` — 1 → 0 (таймер A) → 1 → 0 (таймер B); вызвать тело A → `release` 0; тело B → `release` 1.
  - `disableReleasesImmediately` — держит, `update(2, false)` → `release` 1 сразу, ожидание отменено; `update(2, true)` → `create` 2.
  - `stopReleases` — держит → `stop()` → `release` 1; `update(1, true)` после → `create` не растёт.
  - `createFailureRetries` — `create` → nil: `held == false`; `update(2, true)` → `create` 2 вызова.
  - `renameFallbackRecreates` — `rename` → false → `create` нового, `release` старого id.
  - `ConfigTests.keepAwakeFlag` — по умолчанию `true`; `keep_awake = false` → `false`; `keep_awake = "no"` → ошибка разбора; запись через `setConfig` сохраняет остальные ключи.
  - `L10nTests.keepAwakeAssertionPlurals` — ru: 0 → «Hangar: 0 агентов работают», 1 → «Hangar: 1 агент работает», 3 → «Hangar: 3 агента работают», 5, 11, 12 → «…агентов работают», 21 → «Hangar: 21 агент работает», 22 → «Hangar: 22 агента работают»; en: 1 → «Hangar: 1 agent working», 2 → «Hangar: 2 agents working».
  - `AgentWiringTests.keepAwakeFollowsStatuses` — `AppState` с фейком: событие `.prompt` на лист → `create` с `name(1)`; `stop` → `schedule` 1; `setConfig("keep_awake", flag: false)` → `release`.
- [ ] **Step 2:** Run: `swift test --filter "KeepAwakeTests|ConfigTests|L10nTests|AgentWiringTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать** по Interfaces.
- [ ] **Step 4:** Run: `swift build && swift test --filter "KeepAwakeTests|ConfigTests|L10nTests|AgentWiringTests"` — Expected: PASS.
- [ ] **Step 5: Проверить вручную** (DEBUG, изолированные `HANGAR_STATE_DIR`/`HANGAR_CONFIG`, фейковый агент: `[agents] claude = "sh"` + `hangar event prompt` из листа (и `hangar event stop`)): ☕ серый → после события акцентный; `pmset -g assertions | grep Hangar` → `PreventUserIdleSystemSleep … "Hangar: 1 агент работает"`; второй лист в working → имя «2 агента работают»; `stop` обоих → строка остаётся ~2 мин, затем исчезает; клик по ☕ при работе → строка исчезает сразу, тултип «выключено»; ⌘Q при блокировке → после выхода строки нет. Сверить ☕ с `icons-sidebar.html` и DESIGN (размер, цвет, рука).
- [ ] **Step 6: Commit** — `git add Package.swift Sources Tests docs/design && git commit -m "feat(power): keep the Mac awake while agents work"`

### Task 8: Приёмка этапа

**Files:**
- Modify: `docs/decisions.md` (дополнения #45 по ходу, «Замеры» этапа 5), `docs/superpowers/stage1-followups.md` (раздел «Этап 5 — нужна проверка глазами»; «Отложено»: ☕ в рейке, адресация листа TERMINAL, `tabs close`), этот план (отметки)

- [x] **Step 1:** Run: `swift build && swift test` — Expected: всё PASS, 2 прогона подряд (показать сводку).
- [x] **Step 2: Сценарий CLI** (собранный `build/Hangar.app`, DEBUG-окружение изолировано, `HANGAR_SOCKET` на сокет изолированного состояния, `H=build/Hangar.app/Contents/Helpers/hangar`): `$H projects add <temp-repo>`; `$H tasks create --project <имя> --name "CLI test" --worktree --base <ветка> --prompt "echo hi"` — выбранная задача и фокус в окне не изменились, в сайдбаре новая задача, её агент запущен (статус меняется без показа); `$H tasks list --json | jq .` — статусы; `$H tabs open --task "CLI test" --kind shell`; `$H tabs send --tab <id8> "echo ok" --enter`; `$H tabs read --tab <id8> --lines 5` — содержит `ok`; `$H tabs send --tab <id8> --key ctrl-c`; `$H tasks archive --task "CLI test"` → код 2; с `--yes` → задача в архиве, папка worktree на месте; приложение закрыто → `$H tasks list` → код 1, «Hangar is not running».
- [x] **Step 3: Сценарий MCP с настоящим claude** (приёмка: скриптовый JSON-RPC-клиент через `$H mcp`; настоящий claude — ручная проверка в stage1-followups.md, он пишет `~/.claude.json` при старте) без правки файлов пользователя: temp-файл `/tmp/hg-s5/mcp.json` = `{"mcpServers":{"hangar":{"command":"<H>","args":["mcp"],"env":{"HANGAR_SOCKET":"<сокет>"}}}}`; `env -u CLAUDECODE claude --mcp-config /tmp/hg-s5/mcp.json --strict-mcp-config` в терминале вне Hangar → `/mcp` показывает `hangar` с 8 инструментами; попросить «перечисли задачи Hangar» → вызов `tasks_list`; «архивируй задачу X» без подтверждения → инструмент вернул ошибку про `yes: true`. `~/.claude.json` и `~/.claude/settings.json` — mtime до и после одинаковые.
- [x] **Step 4: Энергия и таймеры.** (замер сделан; 0,0 % в первом прогоне НЕ подтверждено — плато ~1,2 %, см. «Замеры» этап 5 и ручную проверку) Агенты в простое 3 мин после сценария: `top -l 37 -s 5 -pid <pid> -stats pid,cpu | tail -36` — Expected: 0,0 % в простое; `pmset -g assertions | grep -c Hangar` = 0 через 2 мин после последнего `working`; `lsof -p <pid> | grep -c hangar.sock` = 1 (нет висящих соединений после CLI). Записать в «Замеры».
- [x] **Step 5: Commit** — `git add docs && git commit -m "docs: stage 5 acceptance"`
