# Hangar — уведомления по причинам, «Входящие», настройки — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Уведомление говорит, *что* нужно (разрешение, вопрос, готово, ошибка, лимит), клик ведёт в нужный лист локально и по SSH, всё ждущее собрано во «Входящих» (колокольчик, ⌥⌘A), шум настраивается по причинам, проектам и сессиям.

**Architecture:** `AgentStatus` получает модель «Внимание»: `fold` кроме `AgentState` выводит `Attention` (причина, детали, `since`, `requestKey`), `StatusBoard` выдаёт ключи запросов, а чистые функции дают порядок, счётчик, следующий элемент и решение «показывать ли баннер». `HangarUI` строит из `StatusBoard` + `WorkspaceState` один список `AttentionItem`. Из него питаются Dock, колокольчик, «Входящие» и `Notifier`. Ввод из кнопок уведомления идёт тем же путём `TerminalAccess.send`, что и у CLI/MCP, и только если `requestKey` совпадает с текущим.

**Tech Stack:** Swift 6.3, Swift Testing, AppKit + SwiftUI, `UserNotifications` (`UNNotificationCategory`, `UNTextInputNotificationAction`, `threadIdentifier`, `interruptionLevel`), macOS 14+.

**Spec:** `docs/superpowers/specs/2026-10-27-notifications-design.md` (целиком). Контекст: `docs/superpowers/specs/2026-10-18-hangar-design.md` §5 (статусы, hooks, запасные пути), `docs/decisions.md` #30 (OSC 1/сек), #43 (hooks, статус на лист, id сессии, ключи `notifications`/`limit_notifications`), #47 (`ssh -R`, `hangar-remote`), #64 (простые SSH-терминалы), #67 (фильтр «Требуют внимания»), #85 (палитры тем). Дизайн: `docs/design/DESIGN.md`, `docs/superpowers/mockups/icons-v2.html` (глиф колокольчика, тултипы), `limits.html` (вид поповера). Правила: `AGENTS.md`, `.claude/skills/hangar-code|hangar-test|hangar-commit`.

## Global Constraints

- **Ветка.** Одна ветка `feat/notifications` (от `origin/main`, с cherry-pick коммита спеки из `docs/notifications-spec`; план — её третий коммит). Задачи коммитятся по очереди в эту ветку, после каждой задачи `git push`; длинная задача — WIP-пуши по ходу. Итоговый PR: `feat: notifications by reason, inbox and per-project settings` (minor → v0.4.0).
- **Авторство.** Коммиты — только от пользователя из `git config`: без `--author`, `GIT_AUTHOR_*`, `-c user.*`, без `Co-Authored-By` и любых подписей/трейлеров. Перед пушем: `scripts/check-commits.sh origin/main..HEAD`.
- **Ресурсы.** Каждый `swift build` / `swift test` — под общим замком и с `nice`:
  ```sh
  until mkdir /tmp/hangar-heavy.lock 2>/dev/null; do sleep 15; done
  nice -n 15 swift test --parallel --num-workers 3 --filter <Suite>; rmdir /tmp/hangar-heavy.lock
  ```
  (`swift build` — так же, с `nice -n 15 swift build`). Замок снимать и при ошибке. Ниже «Run (heavy)» означает «в этой обёртке». В свежем worktree — `cp -cR "$(git rev-parse --path-format=absolute --git-common-dir)/../vendor/GhosttyKit.xcframework" vendor/`.
- **Живые проверки.** Только `.build/debug/HangarApp`, изолированно (`hangar-test`: `HANGAR_STATE_DIR`, `HANGAR_CONFIG`, `HANGAR_CLAUDE_SETTINGS`, `HANGAR_CODEX_CONFIG`, `HANGAR_SSH*` под `/tmp`, `HANGAR_DEBUG_NO_ACTIVATE=1`, свой `HANGAR_DEBUG_CHANNEL`), **с `HANGAR_DEBUG_BEHIND=1`**, одно DEBUG-приложение за раз (под тем же замком). Никогда не запускать release-сборку, `build/Hangar.app` и `/Applications/Hangar.app`. Не трогать файлы пользователя (`~/.claude`, `~/.codex`, `~/.config/hangar`, `~/Library/Application Support/Hangar`, `~/Library/Sounds`, Ghostty-конфиг). Настоящий `claude`/`codex` не запускать: любая живая проверка, где открываются сессии/вкладки агентов, задаёт ПОДДЕЛЬНЫЕ агенты через `[agents]` в изолированном `config.toml` (`claude = "/tmp/…/bin/claude"`, `codex = "/tmp/…/bin/codex"`). Временного `HOME` недостаточно: Ghostty запускает вкладки через `/usr/bin/login` с настоящим `HOME` аккаунта, и без `[agents]` запустился бы настоящий `claude`. Реальные ssh-хосты не трогать. Не вызывать `activate` и полноэкранные снимки. После проверки всё остановить.
- **Модули.** Логика внимания — в `AgentStatus` (без UI-импортов, юнит-тесты в `Tests/AgentStatusTests`). Поля состояния — в `Workspace`. UI и `UNUserNotificationCenter` — только в `HangarUI`. Только `GhosttyBridge` трогает `ghostty_*`.
- **Без новых зависимостей и таргетов.** Только Foundation/AppKit/SwiftUI/UserNotifications.
- **Энергия.** Ни таймеров, ни опросов. «3 мин» во «Входящих» считается при показе от `since` и часов, снятых при открытии поповера (как `usageClock`). Тикающего таймера нет. Звуки не перечитываются: список системных звуков читается при открытии страницы настроек.
- **Строки и вид.** Всё видимое — через `L10n` (ключ + строки в `Resources/ru.lproj` и `Resources/en.lproj/Localizable.strings`, ru — исходный). Цвета, размеры, шрифты — только `Theme` (новый цвет — во все три `ThemePalette`). Иконки — `enum Icon`. На кликабельном — `.pointingHand()`, без скачков раскладки (резерв места под число и кнопки).
- **Клавиши.** Только через таблицу `Shortcut` по `keyCode`: ⌥⌘A = `([.command, .option], 0, "A")`.
- **Копирайт уведомлений (спека §2).** Заголовки: «Claude просит разрешение», «Claude спрашивает», «Codex закончил», «Claude: ошибка», «Claude упёрся в лимит». Подзаголовок «Проект › сессия» (+ « · host»). Тело обрезается до 160 символов (`noticeBodyLimit`, многоточие). Пустой список во «Входящих» — существующий `L10n.nobodyWaiting` («Никто не ждёт»).
- **Порядок срочности:** permission > question > failed > limit > done, внутри причины старше выше. **Dock и колокольчик:** число = permission + question + failed.
- **Конфиг** (корневые плоские ключи, `ConfigWriter` правит только их): `notifications` (общий выключатель баннеров), `notify_permission`, `notify_question`, `notify_done`, `notify_failed` (bool, по умолчанию `true`), причина limit = существующий `limit_notifications`; `sound_permission`, `sound_question`, `sound_done`, `sound_failed`, `sound_limit` (строка: `""` — без звука, `"default"` — стандартный, иначе имя из `/System/Library/Sounds` без `.aiff`; по умолчанию `"default"`, у done — `""`); `notify_when_active = true`, `allow_from_notification = false`, `ssh_terminal_bell = false`. `dock_badge`, `keep_awake` — как есть. Проект: `Project.notifications` (`all`/`urgent`/`off`, по умолчанию `all`), сессия: `HangarTask.muted` (по умолчанию `false`) — в `state.json`, старые файлы читаются.
- **Решения.** Спайк → запись **#95** в `docs/decisions.md` (#94 занят PR переносимости; если и #95 окажется занят к моменту коммита — следующий свободный, и сдвинуть номер поведения). Поведение → запись **#96** «Уведомления по причинам и «Входящие»». Её создаёт Task 3, а Tasks 2, 5–8 дописывают свои пункты в том же коммите, что и код. Task 9 обновляет §5 основной спеки.

## Review Focus

1. **Устаревшая команда у «Разрешить».** `PermissionRequest` пришёл, вызов авто-отклонён, а позже `permission_prompt` пришёл от другого запроса (сетевой запрос песочницы без `PermissionRequest`). Ожидание: детали не прилипают к чужому запросу, кнопки «Разрешить» нет. Тест: Task 3 `stalePendingPermissionIsNotUsed`.
2. **Нажали на старый баннер.** Человек уже ответил в терминале, или пришёл другой запрос, а потом нажал «Разрешить»/«Ответить» на старом баннере. Ожидание: ничего не вводится, только «Открыть». Тест: Task 6 `staleRequestKeyOnlyOpens`.
3. **Лист исчез.** Вкладку закрыли, сессию архивировали, хост отключился (`.relaunched`). Ожидание: элемент пропал из списка, доставленный баннер убран. Тест: Task 5 `droppedLeavesClearAttention`.
4. **Заглушено.** Проект `off`/`urgent` или сессия «Без уведомлений». Ожидание: элемент есть во «Входящих» и в счётчике, но нет баннера, звука и подпрыгивания Dock. Тесты: Task 3 `bannerPolicyTable`, Task 5 `mutedStillCountsButNoBounce`.
5. **Враждебная полезная нагрузка хука.** `tool_name` на 10 КБ, команда с управляющими символами и переводами строк, `error` длиннее 64. Ожидание: поля обрезаны или отброшены на границе, в баннере нет управляющих символов. Тесты: Task 2 `hookDetailFieldsAreBounded`, Task 6 `noticeBodyStripsControls`.

---

### Файловая структура

| Файл | Что меняется |
|---|---|
| `Sources/AgentStatus/AgentStatus.swift` | `HookKind.permissionRequest` (ветка A), `HookDetail`, `AgentSignal.desktopNotification(text:)`, `LeafStatus.attention/pendingPermission`, `fold(…now:)`, `StatusBoard` ключи + `dismissDone` |
| `Sources/AgentStatus/Attention.swift` (новый) | `AttentionReason`, `Attention`, `AttentionItem`, порядок, счётчик, `nextAttention`, `BannerContext`/`shouldBanner` |
| `Sources/ControlServer/Protocol.swift`, `CLISupport.swift` | поля `tool`, `command`, `error` в `EventMessage`; разбор `tool_name`, `tool_input.command`, `error`, `last_assistant_message`; лимиты длины |
| `Sources/Integration/ClaudeIntegration.swift` | `claudeHooks`: `StopFailure` без matcher, `PermissionRequest` (ветка A) |
| `Sources/Workspace/Model.swift`, `Config.swift` | `ProjectNotifications`, `Project.notifications`, `HangarTask.muted`, мутаторы; новые ключи конфига |
| `Sources/HangarUI/AppState+Attention.swift` (новый) | список внимания, Dock, `onAttention`, `dismissDone/clearDone`, глушение, `nextAttentionLeaf`, `notificationAction` |
| `Sources/HangarUI/Notifier.swift` | содержимое по причине, категории/действия, звук, срочность, уборка, статус разрешения |
| `Sources/HangarUI/InboxView.swift` (новый) | колокольчик в заголовке, поповер «Входящие» |
| `SettingsView.swift`, `ProjectSettingsSheet.swift`, `Actions.swift`, `SidebarRows.swift`, `Icons.swift`, `Shortcuts.swift`, `StatusBar.swift`, `WindowTitleBar.swift`, `MainWindow.swift`, `MainWindow+Debug.swift`, `SplitView.swift`, `TerminalDrawerView.swift`, `L10n.swift`, `Theme*.swift`, `Localizable.strings` | проводка и UI |

---

### Task 1: Спайк — нагрузка хуков, клавиша одобрения, `.timeSensitive`, звуки

Одноразовая работа, код в репозиторий не идёт. Результат — запись #95 и ответы S1–S5, на которых ветвятся следующие задачи.

**Files:**
- Modify: `docs/decisions.md` (новая запись 95; #94 занят PR переносимости — взять следующий свободный номер на момент коммита)

**Interfaces:**
- Produces: исходы **S1** (A/B), **S2** (ключи одобрения), **S3** (T-yes/T-no), **S4** (SND-yes/SND-no), **S5** (Ответить в Claude: да/нет). Дальше задачи ссылаются на них по имени.

- [ ] **Step 1: S1 — откуда tool/command.** Прочитать https://code.claude.com/docs/en/hooks (WebFetch, страница длинная, читать с `offset`): разделы Notification, PermissionRequest, PermissionDenied, Stop, StopFailure. Записать поля. Ожидаемый факт: у `Notification` только `message`, `title`, `notification_type` (без инструмента). У `PermissionRequest` есть `tool_name` и `tool_input.command` (Bash/PowerShell), без `tool_use_id`. Он срабатывает перед показом диалога или при авто-отказе, и не срабатывает для сетевого запроса песочницы. У `Stop` текст в `last_assistant_message`, у `StopFailure` тип в `error` (`rate_limit`, `overloaded`, …, `unknown`). Исход **A**: tool/command берём из нового хука `PermissionRequest` (меняет `claudeHooks`, интеграция станет «устарела», переустановка из Настроек с diff по #15). Исход **B**: деталей нет, кнопки «Разрешить» нет. **Гейт:** оркестратор задаёт владельцу один вопрос: «Добавить хук PermissionRequest (вместе с StopFailure по всем ошибкам) — интеграцию Claude нужно будет обновить в Настройках?» Да → A, нет → B. Реальный `claude` не запускать.
- [ ] **Step 2: S2 — клавиша одобрения.** По документации (permissions / interactive mode) найти, как диалог разрешения принимает ответ. По умолчанию подсвечен первый вариант «Yes», так что ожидается `Enter` (`[SendKey.enter]`). Если в документации не сказано, записать `[.enter]` с пометкой «проверить владельцу вживую». Цифра «1» через `sendText` не годится: это вставка, а не нажатие.
- [ ] **Step 3: S3 — `.timeSensitive` при ad-hoc подписи.** По документации Apple (entitlement `com.apple.developer.usernotifications.time-sensitive`, Signing & Capabilities) выяснить, нужен ли provisioning profile на macOS. `scripts/bundle.sh` подписывает `-s -` без entitlements. Выключено ли уведомление пользователем, проверяется через `UNNotificationSettings.timeSensitiveSetting`. Если документация не даёт ответа, можно собрать в `/tmp` пустой Swift-бинарник (не Hangar) в `.app`, подписать ad-hoc с этим entitlement и проверить `codesign -d --entitlements -` и запуск: AMFI убьёт процесс, если нужен профиль. Исход **T-yes**: entitlement добавляется в `bundle.sh`. Исход **T-no**: `.active` плюс пояснение в Настройках (ожидаемый вариант).
- [ ] **Step 4: S4 — системные звуки.** По документации `UNNotificationSound(named:)` выяснить, ищет ли macOS имена из `/System/Library/Sounds`. **SND-yes**: выбор из списка системных звуков. **SND-no**: только «Стандартный» (`.default`) и «Без звука». `NSSound` в обход центра уведомлений не годится: он игнорирует фокус-режим. Не решается по документам — SND-no, с пометкой «проверить владельцу».
- [ ] **Step 5: S5 — «Ответить» для Claude.** `elicitation_dialog` — форма MCP-запроса. По документации выяснить, принимает ли она свободный текст + Enter. Нет или неясно — у вопросов Claude только «Открыть», «Ответить» остаётся для колокола/OSC (Codex и др.), пометка «проверить владельцу».
- [ ] **Step 6: Записать #95** одним пунктом: даты, факты со ссылками, исходы S1–S5, что проверить владельцу. Формат как у соседних записей.
- [ ] **Step 7: Commit + push**
```bash
git add docs/decisions.md
git commit -m "docs: notifications spike outcomes"
git push
```

---

### Task 2: Нагрузка хуков — детали события на границе доверия

**Files:**
- Modify: `Sources/AgentStatus/AgentStatus.swift:7-12` (`HookKind`)
- Modify: `Sources/ControlServer/Protocol.swift:4-24` (`EventMessage`), `:93-99` (лимиты при декоде)
- Modify: `Sources/ControlServer/CLISupport.swift:20-41` (`eventMessage`)
- Modify: `Sources/Integration/ClaudeIntegration.swift:11-20` (`claudeHooks`)
- Modify: `docs/decisions.md` (#96, пункт про хуки)
- Test: `Tests/HangarCLITests` (разбор), `Tests/ControlServerTests` (декод/лимиты, путь `RemoteMessage`), `Tests/IntegrationTests` (план установки)

**Interfaces:**
- Consumes: S1 (Task 1).
- Produces: `EventMessage.tool: String?`, `.command: String?`, `.error: String?` (новые поля, `message` по-прежнему текст). Ветка A: `HookKind.permissionRequest = "permission-request"`.

- [ ] **Step 1: Write the failing tests**
```swift
@Test func permissionRequestPayloadCarriesToolAndCommand() {   // ветка A
    let m = eventMessage(kind: "permission-request", tab: t, leaf: l, args: [],
        payload: #"{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"rm -rf node_modules"}}"#.data)
    #expect(m?.kind == .permissionRequest && m?.tool == "Bash" && m?.command == "rm -rf node_modules")
}
@Test func stopTextComesFromLastAssistantMessage() {
    #expect(eventMessage(kind: "stop", …, payload: #"{"last_assistant_message":"Готово"}"#)?.message == "Готово")
}
@Test func stopFailureCarriesErrorType() {
    #expect(eventMessage(kind: "stop-failure", …, payload: #"{"error":"overloaded","last_assistant_message":"API Error"}"#)?.error == "overloaded")
}
@Test func hookDetailFieldsAreBounded() {
    // decode через ControlMessage.decode: tool > 64 символов → nil, error > 64 → nil, command → prefix(500)
}
@Test func installPlanHasStopFailureForAllErrors() { /* claudeHooks: ("StopFailure", nil, "stop-failure"); ветка A: ("PermissionRequest", nil, "permission-request") */ }
```
- [ ] **Step 2: Run (heavy):** `swift test --filter "HangarCLITests|ControlServerTests|IntegrationTests"`. Expected: FAIL (нет полей/кейса).
- [ ] **Step 3: Implement.** В `eventMessage` для не-codex: `tool` = `tool_name`, `command` = `tool_input.command` (только строка), `error` = `error`. `message` = `message`, а если его нет — `last_assistant_message`. В `ControlMessage.decode` (event): `tool`/`error` длиннее 64 → `nil`, `command` → `prefix(500)`. Путь `RemoteMessage` получает это даром, через тот же декодер. В `claudeHooks`: `StopFailure` без matcher; ветка A — `PermissionRequest` без matcher. Хук ничего не печатает и выходит с 0, так что диалог идёт как обычно. `ClaudeIntegration` сам покажет «устарела» по несовпадению ожидаемого набора (`:208`). Ветка B: только `StopFailure` и разбор `error`/`last_assistant_message`.
- [ ] **Step 4: Run (heavy)** те же фильтры. Expected: PASS. Плюс `swift build`.
- [ ] **Step 5: Commit + push** — `feat(status): read tool, command and error from claude hooks` (+ пункт #96: хуки и переустановка интеграции).

---

### Task 3: Модель «Внимание» в `AgentStatus`

**Files:**
- Create: `Sources/AgentStatus/Attention.swift`
- Modify: `Sources/AgentStatus/AgentStatus.swift:14-31` (`AgentSignal`, `LeafStatus`), `:57-96` (`fold`), `:117-141` (`StatusBoard`)
- Modify: `docs/decisions.md` (создать #96)
- Test: `Tests/AgentStatusTests/AttentionTests.swift` (новый). Существующие `AgentStatusTests`/`SubagentTests` должны пройти без правок, кроме нового `desktopNotification(text:)`.

**Interfaces:**
- Consumes: `HookKind.permissionRequest` (Task 2, ветка A).
- Produces:
```swift
public enum AttentionReason: String, CaseIterable, Sendable { case permission, question, failed, limit, done } // порядок = срочность
public struct HookDetail: Equatable, Sendable { public var tool, command, text, error: String? }
public struct Attention: Equatable, Sendable {
    public var reason: AttentionReason; public var tool, command, text: String?
    public var since: Date; public var requestKey: UUID
    public func sameRequest(_ o: Attention) -> Bool   // reason, tool, command, text
}
// AgentSignal: case hook(HookKind, session:, notificationType:, source: String? = nil, detail: HookDetail = .init())
//              case desktopNotification(text: String? = nil)
// LeafStatus: public var attention: Attention?; var pendingPermission: (tool, command, at) — ветка A
public func fold(_ status: LeafStatus, _ signal: AgentSignal, agent: SessionAgent?, now: Date = Date()) -> LeafStatus
// StatusBoard.apply(_:leaf:agent:now:) -> Transition?  (ключ сохраняется при sameRequest, иначе новый UUID)
// StatusBoard.dismissDone(_ leaf: UUID) -> Bool        (снимает только reason == .done, state не трогает)
public struct AttentionItem: Equatable, Sendable, Identifiable {
    public var leafId, taskId, projectId: UUID; public var host: String?; public var agent: String; public var attention: Attention
    public var id: UUID { leafId }
}
public func sortedAttention(_ items: [AttentionItem]) -> [AttentionItem]
public func inboxSections(_ items: [AttentionItem]) -> (urgent: [AttentionItem], recentDone: [AttentionItem])
public func attentionCount(_ items: [AttentionItem]) -> Int
public func nextAttention(_ ordered: [UUID], after current: UUID?) -> UUID?
public struct BannerContext: Equatable, Sendable {
    public var enabled, reasonEnabled, projectUrgentOnly, projectOff, sessionMuted, leafVisible, appActive, notifyWhenActive: Bool
}
public func shouldBanner(_ reason: AttentionReason, _ c: BannerContext) -> Bool
```

- [ ] **Step 1: Write the failing tests** (`AttentionTests`), таблицей по спеке §1:
```swift
@Test func sourcesMapToReasons() {
    // notification permission_prompt → state .waiting, reason .permission, text = message
    // notification elicitation_dialog → .question; notification без type → .question (старый claude)
    // stop → .done text; codexNotify → .done text
    // stopFailure error nil|"rate_limit" → state .limit, reason .limit; "overloaded" → state .failed, reason .failed
    // exited(code: 2) → .failed; exited(code: 0) → nil; bell / desktopNotification(text: "build?") без hooks → .question, text "build?"
}
@Test func activityClearsAttention() { // prompt, tool, sessionStart, subagentStart, relaunched → attention == nil
}
@Test func focusClearsOnlyHooklessQuestion() { // как сейчас: focused гасит waiting без hooks; permission от hooks и done остаются
}
@Test func permissionUsesPendingDetails() {        // ветка A
    // permissionRequest(tool "Bash", command "ls") в t0 → state не меняется, attention nil
    // notification permission_prompt в t0+2s → attention.tool == "Bash", command == "ls"; pending снят
}
@Test func stalePendingPermissionIsNotUsed() {     // ветка A
    // pending в t0, permission_prompt в t0+31s → tool/command nil; pending снимают prompt/tool/stop/stopFailure/sessionStart/relaunched
}
@Test func requestKeyStableForSameRequest() {
    // повтор того же permission_prompt → тот же key и since; другой text/reason → новый key
}
@Test func dismissDoneOnlyForDone() { // dismissDone на .done → attention nil, state всё ещё .done; на .permission → false
}
@Test func orderAndSections() {
    // sortedAttention: permission < question < failed < limit < done, внутри старше выше
    // inboxSections: urgent = всё кроме done; recentDone = 10 самых свежих done, показаны старше выше
    // attentionCount считает permission+question+failed (limit и done — нет)
}
@Test func nextAttentionCycles() { // [a,b,c]: after nil → a, after a → b, after c → a, after x(не в списке) → a, [] → nil
}
@Test func bannerPolicyTable() {
    // enabled=false → нет; reasonEnabled=false → нет; leafVisible → нет; sessionMuted → нет;
    // projectOff → нет; projectUrgentOnly → только permission/question; appActive && !notifyWhenActive → нет
}
```
- [ ] **Step 2: Run (heavy):** `swift test --filter AgentStatusTests`. Expected: FAIL (типов нет).
- [ ] **Step 3: Implement** по Interfaces. `fold` ставит `Attention(since: now, requestKey: placeholder)`, а `StatusBoard.apply` нормализует: при `sameRequest` со старым — старые `since`/`requestKey`, иначе `UUID()`. Окно годности `pendingPermission` — 30 с (`pendingPermissionTTL`). Существующий порядок `taskState` и правило «чужой session id» (`acceptsHook`) не менять.
- [ ] **Step 4: Run (heavy)** `--filter AgentStatusTests`. Expected: PASS. Плюс `swift build`: вызовы `.desktopNotification` в `HangarUI` собираются с `text: nil` по умолчанию.
- [ ] **Step 5: Commit + push** — `feat(status): attention model with reasons, request keys and banner policy` (+ запись #96: модель, источники, снятие, порядок, Dock-число).

---

### Task 4: Состояние и конфиг — глушение проекта/сессии, новые ключи

**Files:**
- Modify: `Sources/Workspace/Model.swift:8-55` (`Project`), `:250-305` (`HangarTask`), мутаторы рядом с `setPinned` (`:559`)
- Modify: `Sources/Workspace/Config.swift:9-30` (поля), `:69-80` (флаги), разбор строк (`:84-120`)
- Test: `Tests/WorkspaceTests` (`ConfigTests`, `ModelCodingTests` или существующие файлы этих тем)

**Interfaces:**
- Produces:
```swift
public enum ProjectNotifications: String, Codable, Sendable, CaseIterable { case all, urgent, off }
// Project.notifications: ProjectNotifications = .all;  HangarTask.muted: Bool = false
// WorkspaceState.setProjectNotifications(projectId:_:) ; WorkspaceState.setMuted(taskId:_:)
// HangarConfig: notifyPermission, notifyQuestion, notifyDone, notifyFailed: Bool = true
//   sounds: [String: String]  // ключ — AttentionReason.rawValue (Workspace не импортирует AgentStatus); значения по Global Constraints
//   notifyWhenActive = true, allowFromNotification = false, sshTerminalBell = false
```
- [ ] **Step 1: Write the failing tests:** `oldStateDecodesWithDefaults` (JSON без `notifications`/`muted` → `.all`/`false`), `notificationFieldsRoundTrip`, `newConfigKeysParse` (все ключи из Global Constraints, `sound_done = ""` → `""`, неизвестное значение строки допустимо), `defaultsMatchSpec` (`sounds["done"] == ""`, остальные `"default"`, `allowFromNotification == false`, `sshTerminalBell == false`).
- [ ] **Step 2: Run (heavy):** `swift test --filter WorkspaceTests`. Expected: FAIL.
- [ ] **Step 3: Implement** по образцу `worktreeByDefault` (`decodeIfPresent ?? default`) и списка `flags` в `parse`. Строковые `sound_*` — ветка `("", key)` в `switch`.
- [ ] **Step 4: Run (heavy)** `--filter WorkspaceTests`. Expected: PASS.
- [ ] **Step 5: Commit + push** — `feat(workspace): per-project and per-session notification settings`.

---

### Task 5: Проводка в `AppState` — список внимания, Dock, глушение, ⌥⌘A-логика

**Files:**
- Create: `Sources/HangarUI/AppState+Attention.swift`
- Modify: `Sources/HangarUI/AppState+Agents.swift:16-43` (`handle`: `HookDetail` из `EventMessage`), `:46-50` (`signal`: колокол простого SSH-терминала), `:113-128` (`apply`: `now: clock()`, `onAttention`, подпрыгивание)
- Modify: `Sources/HangarUI/AppState.swift:35-40,57-59` (колбэки), `:236-256` (`perform`: сброшенные листья → `onAttention(id, nil)`), `:594-603,632` (`updateDockBadge` от `attentionCount`; `waitingTaskCount` удалить, если больше не используется)
- Modify: `Sources/HangarUI/SplitView.swift:137-139,219,677-678`, `Sources/HangarUI/TerminalDrawerView.swift:260-261` (текст OSC: `onNotification: ((String) -> Void)?`, title + body через « — »)
- Test: `Tests/HangarUITests/AttentionWiringTests.swift` (новый, фикстура как в `NotificationsTests.make`)

**Interfaces:**
- Consumes: Task 3 (всё), Task 4 (`Project.notifications`, `HangarTask.muted`, `HangarConfig.sshTerminalBell`).
- Produces:
```swift
extension AppState {
    var attentionItems: [AttentionItem] { get }            // sortedAttention; только живые листья неархивных задач
    @ObservationIgnored var onAttention: ((UUID, Attention?) -> Void)?   // изменение/снятие у листа
    @ObservationIgnored var onLeafSeen: ((UUID) -> Void)?  // лист получил фокус (убрать доставленный баннер)
    func dismissDone(leafId: UUID); func clearDone()
    func setProjectNotifications(_ id: UUID, _ v: ProjectNotifications); func setMuted(taskId: UUID, _ muted: Bool)
    func signal(_ signal: AgentSignal, leaf: UUID)          // + .desktopNotification(text:) ; bell шелла host-терминала при sshTerminalBell
    func nextAttentionLeaf() -> UUID?                       // nextAttention(порядок списка: urgent + recentDone, после фокусного листа выбранной задачи)
}
```
`AttentionItem.host` — `remoteLeafHost` или `hostShellHost`. `projectId` у host-терминала — id `HostShell`. `agent` — `claude`/`codex`, для остальных `title(of:)`.

- [ ] **Step 1: Write the failing tests:**
```swift
@Test func hookEventBecomesItem()          // .event(permission_prompt, message) → attentionItems.first?.attention.reason == .permission
@Test func osctextBecomesQuestionText()    // signal(.desktopNotification(text: "Run tests?")) в codex-листе → text "Run tests?"
@Test func hostShellBellOnlyWhenEnabled()  // шелл openHostShell: bell → нет элемента; sshTerminalBell = true → .question
@Test func dockCountsUrgentAndFailed()     // permission + question + failed + done → badge "3"; dock_badge=false → ""
@Test func droppedLeavesClearAttention()   // closeTab / archive / .relaunched → onAttention(leaf, nil) вызван, список пуст
@Test func mutedStillCountsButNoBounce()   // setMuted(task) → элемент есть, badge есть, requestAttention не вызван
@Test func dismissAndClearDone()           // dismissDone/clearDone убирают только done, точка вкладки (state) остаётся .done
@Test func nextAttentionFromFocusedLeaf()  // фокус на 1-м элементе → nextAttentionLeaf() == 2-й; на последнем → 1-й
```
- [ ] **Step 2: Run (heavy):** `swift test --filter AttentionWiringTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** `apply` сравнивает `attention` до и после и при отличии зовёт `onAttention`. Подпрыгивание Dock (`requestAttention`) — только при новом permission/question и если не заглушено (`shouldBanner` без условий видимости). `lastNotificationMessage` больше не нужен, раз текст живёт в `Attention.text`: удалить вместе с вызывающими. `onLeafSeen` вызывать из `focused(leafId:)` (`AppState.swift:566`).
- [ ] **Step 4: Run (heavy):** `--filter "AttentionWiringTests|NotificationsTests|AgentWiringTests|HostShellUITests"`. Expected: PASS. `NotificationsTests` пока проверяет старый `notice(for:)`. Если его сломало удаление `lastNotificationMessage`, перевести тело уведомления на `Attention.text` прямо в этой задаче (без `.disabled`).
- [ ] **Step 5: Commit + push** — `feat(ui): one attention list for dock, inbox and notifications`.

---

### Task 6: `Notifier` — текст по причине, действия с защитой, группировка, уборка, звук, срочность

**Files:**
- Modify: `Sources/HangarUI/Notifier.swift` (весь файл: `AgentNotice`, `notice(for:)`, `Notifier`)
- Modify: `Sources/HangarUI/LimitsView.swift:60` (`limitNotices` → категория `limit`)
- Modify: `Sources/HangarUI/MainWindow.swift:657-694` (`enableNotifications`, `reveal`)
- Modify: `Sources/HangarUI/MainWindow+Debug.swift` (команды `notices <file>`, `noticeAction <n> open|allow|reply <text>`)
- Modify: `Sources/HangarUI/L10n.swift` + оба `Localizable.strings` (заголовки §2, кнопки «Открыть», «Разрешить», «Ответить», «Открыть лимиты»)
- Modify (ветка T-yes): `scripts/bundle.sh`, новый `Resources/Hangar.entitlements`
- Test: `Tests/HangarUITests/NotificationsTests.swift` (переписать под новые сигнатуры)

**Interfaces:**
- Consumes: Task 5 (`attentionItems`, `onAttention`, `onLeafSeen`), Task 3 (`shouldBanner`, `BannerContext`), S2–S5.
- Produces:
```swift
enum NoticeCategory: String { case permission, permissionAllow = "permission-allow", question, questionReply = "question-reply", open, limit }
struct AgentNotice: Equatable { var id, title, subtitle, body: String; var leaf: UUID?; var category: NoticeCategory
                                var thread: String?; var sound: String?  /* nil — без звука */; var urgent: Bool; var requestKey: UUID? }
enum NoticeAction: Equatable { case open, allow, reply(String), limits }
enum NoticeResult: Equatable { case reveal, send(text: String?, keys: [SendKey]), showLimits }
@MainActor func notice(for item: AttentionItem, app: AppState) -> AgentNotice
@MainActor func bannerAllowed(_ item: AttentionItem, app: AppState, leafVisible: Bool, appActive: Bool) -> Bool
extension AppState { func notificationAction(leaf: UUID?, requestKey: UUID?, _ action: NoticeAction) -> NoticeResult }
let permissionApproveKeys: [SendKey]   // из S2, по умолчанию [.enter]
// Notifier: registerCategories() (при init и смене языка), post(_:), remove(leaf:), removeAllDelivered() (при init),
//           authorizationStatus() async -> UNAuthorizationStatus, var onAction: ((UUID?, UUID?, NoticeAction) -> Void)?
```
Правила, которые тесты закрепляют:
- `id` = `leafId.uuidString` (новое заменяет старое), `thread` = `taskId.uuidString`. Пороговые уведомления лимитов — как сейчас: `limit-<agent>`, категория `limit`.
- Категория: permission → `permissionAllow`, только если `allowFromNotification`, `tool != nil`, `command != nil` и S1 = A; иначе `permission`. question → `questionReply` для листов claude/codex (для Claude только при S5 = да), иначе `open` (ответ в шелл host-терминала не вводим). done/failed → `open`, limit → `limit`.
- Тело: permission — `"tool: command"`, иначе `text`. question/done/failed — `text`, иначе подпись вкладки. Управляющие символы → пробел, затем обрезка до 160.
- `sound` из `config.sounds[reason]`: `""` → `nil`; `"default"` → `.default`; имя → `UNNotificationSound(named:)` при SND-yes, иначе `.default`. `urgent` = permission/question; `interruptionLevel` = `.timeSensitive` при T-yes, иначе `.active`.
- `notificationAction`: `.open` → `.reveal`, `.limits` → `.showLimits`. `.allow` → `.send(nil, permissionApproveKeys)` только если `allowFromNotification`, текущее внимание листа — permission с тем же `requestKey`, а `terminals?.state(leaf) == .running`. `.reply(t)` → `.send(t', [.enter])` при тех же условиях для question, где `t'` — `t` без управляющих символов, переводы строк → пробел, `prefix(2000)`, пустой → `.reveal`. Любое несовпадение → `.reveal`, ничего не вводится.

- [ ] **Step 1: Write the failing tests:**
```swift
@Test func titlesByReason()          // permission/claude → "Claude просит разрешение" (ru) и en-аналог; done/codex → L10n.agentDone("codex")
@Test func subtitleHasHostForRemote() // "shop-api › fix-auth · devbox"
@Test func permissionBodyAndCategory() // tool "Bash", command "ls" → body "Bash: ls"; allowFromNotification=false → .permission; true → .permissionAllow (ветка A)
@Test func noticeBodyStripsControls() // text "a\u{1b}[31mb\nc" → без \u{1b} и \n; 300 символов → 160 с «…»
@Test func soundAndUrgency()          // done по умолчанию sound nil; permission urgent == true
@Test func staleRequestKeyOnlyOpens() // allow с чужим key → .reveal; с текущим и allowFromNotification → .send(nil, [.enter]); лист не running → .reveal
@Test func replySanitizes()           // reply("да\nну") → .send("да ну", [.enter]); reply("  ") → .reveal; host-терминал → .reveal
@Test func bannerAllowedUsesPolicy()  // проект .urgent + done → false; лист видим → false
@Test func revealSelectsTaskTabAndDrawer() // существующий тест остаётся
```
- [ ] **Step 2: Run (heavy):** `swift test --filter NotificationsTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Проводка в `MainWindow.enableNotifications`. `app.onAttention`: `nil` → `notifier.remove(leaf:)`; новый `requestKey` и `bannerAllowed` → `post(notice(for:))`. `app.onLeafSeen` → `remove(leaf:)`. `notifier.onAction` → `notificationAction`: `.reveal` → `reveal(leafId:)`; `.send` → `app.terminals?.send(leaf, text, keys)` без активации окна; `.showLimits` → поднять окно и `app.toggleLimitsPopover()`, если он закрыт. Клик по баннеру (`UNNotificationDefaultActionIdentifier`) = `.open`. Без бандла (`Notifier.makeIfAvailable() == nil`, DEBUG) уведомления пишутся в `debugNotices` для команды `notices`, а `noticeAction` вызывает тот же `notificationAction`. T-yes: entitlement в `bundle.sh` (`codesign --entitlements`).
- [ ] **Step 4: Run (heavy):** `--filter "NotificationsTests|LimitsTests|L10nTests"`, затем `swift build`. Expected: PASS.
- [ ] **Step 5: Commit + push** — `feat(notifications): reasons, guarded actions, grouping and cleanup` (+ пункт #96: категории, защита `requestKey`, клавиша из S2, срочность по S3, звуки по S4).

---

### Task 7: «Входящие» — колокольчик, поповер, счётчик в нижней строке, ⌥⌘A

**Files:**
- Create: `Sources/HangarUI/InboxView.swift` (`InboxBell`, `InboxPopover`, строка элемента)
- Modify: `Sources/HangarUI/WindowTitleBar.swift:59-65` (колокольчик слева от переключателя инспектора)
- Modify: `Sources/HangarUI/StatusBar.swift:141-142` (клик по «ждут» открывает «Входящие» вместо фильтра; подсказка — `L10n.help(L10n.inbox, .nextAttention)`)
- Modify: `Sources/HangarUI/Shortcuts.swift:3-14,20-56` (`.nextAttention`), `Palette.swift:110`, `PaletteView.swift:272`, `MainWindow.swift:479` и обработчик шортката (`reveal(leafId:)` для `app.nextAttentionLeaf()`)
- Modify: `Theme*.swift` (размеры поповера `Theme.Inbox.*`), `L10n` (+ строки «Входящие», «Недавно готово», «Убрать», «Очистить», «< 1 мин», «%d мин», «%d ч», `cmdNextAttention`)
- Modify: `Sources/HangarUI/MainWindow+Debug.swift` (`inbox open|close|snap <png>`)
- Test: `Tests/HangarUITests/InboxTests.swift` (новый), `ShortcutsTests`, `PaletteTests`

**Interfaces:**
- Consumes: Task 5 (`attentionItems`, `dismissDone`, `clearDone`, `nextAttentionLeaf`), Task 6 (`notificationAction`, `NoticeAction`), Task 3 (`inboxSections`, `attentionCount`).
- Produces:
```swift
enum BellTint: Equatable { case accent, failed, muted }
func inboxBell(_ items: [AttentionItem]) -> (count: Int, tint: BellTint) // accent при permission/question, failed если только ошибки, muted без числа
@MainActor func waitingTime(since: Date, now: Date) -> String           // «< 1 мин», «3 мин», «2 ч»
extension AppState { var inboxShown: Bool; var inboxClock: Date; func toggleInbox(); func inboxClicked() } // как limitsPopover*
// Shortcut.nextAttention: ([.command, .option], 0, "A")
```
Поповер — SwiftUI `.popover` на колокольчике (как `LimitsView.swift:142`), вид как у `LimitsPopover` (`Theme.ui.sheet`, `lineSheet`). Колокольчик — существующий `Icon.bell`. Значки причин — из имеющихся `Icon` по `icons-v2.html` (новый глиф только если подходящего нет, тогда в `Icons.swift` + `IconsTests`). Строка: значок причины, «Проект › сессия», текст в одну строку, время, кнопки как в баннере. «Разрешить» — при тех же условиях, что категория `permissionAllow`. «Ответить» раскрывает в строке `.inputField`, ↩ отправляет через `notificationAction(.reply)`. Клик по строке → `.open`. Секции: urgent, затем «Недавно готово» с «Убрать» на строке и «Очистить» в заголовке. Пусто — `L10n.nobodyWaiting`. `inboxClock` ставится в `toggleInbox()` при открытии. Таймера нет.

- [ ] **Step 1: Write the failing tests:**
```swift
@Test func bellCountAndTint()      // permission → (1, .accent); только failed → (1, .failed); только done → (0, .muted)
@Test func waitingTimeText()       // 20 с → «< 1 мин», 190 с → «3 мин», 7300 с → «2 ч» (ru) и en
@Test func inboxToggleIgnoresClosingClick() // как limitsClicked: клик в течение 0.3 с после закрытия не открывает снова
@Test func statusCounterOpensInbox()        // действие кнопки «ждут» → inboxShown == true, attentionOnly не меняется
// ShortcutsTests: shortcut(keyCode: 0, modifiers: [.command, .option]) == .nextAttention; label "⌥⌘A"; без конфликтов в таблице
// PaletteTests: команда .nextAttention есть в палитре
```
- [ ] **Step 2: Run (heavy):** `--filter "InboxTests|ShortcutsTests|PaletteTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** по Interfaces.
- [ ] **Step 4: Run (heavy)** те же фильтры + `L10nTests`, `ThemePaletteTests`, `WindowChromeTests`. Expected: PASS.
- [ ] **Step 5: Commit + push** — `feat(ui): inbox popover, title bar bell and next-attention shortcut`.

---

### Task 8: Настройки, меню проекта и сессии, перечёркнутый колокольчик

**Files:**
- Modify: `Sources/HangarUI/SettingsView.swift:36-45` (`labelKeys` страницы уведомлений), `:236-262` (страница)
- Modify: `Sources/HangarUI/ProjectSettingsSheet.swift:116-120` (строка «Уведомления» с `Segment` all/urgent/off)
- Modify: `Sources/HangarUI/Actions.swift:41-61` (+ `.toggleMute` для `.task`, `.projectNotifications` для `.project`), заголовки/иконки/`perform` там же
- Modify: `Sources/HangarUI/SidebarRows.swift:280-307` (`SessionStatusLine` + `muted: Bool` → `IconView(icon: .bellSlash)`), место вызова в `SidebarView.swift`
- Modify: `Sources/HangarUI/Icons.swift` (`.bellSlash`), `L10n` + строки, `Notifier` (`authorizationStatus`) уже есть из Task 6
- Test: `SettingsTests`, `SettingsCategoryTests`, `ActionsTests`, `IconsTests`, `SidebarPolishTests` (или новый `NotificationSettingsTests`)

**Interfaces:**
- Consumes: Task 4 (поля и ключи), Task 5 (`setProjectNotifications`, `setMuted`), Task 6 (`Notifier.authorizationStatus()`).
- Produces: `func systemSoundNames(in dir: URL = URL(fileURLWithPath: "/System/Library/Sounds")) -> [String]` (имена `.aiff` без расширения, по алфавиту; при SND-no не используется); `Action.toggleMute`, `Action.projectNotifications`.

Страница «Уведомления» сверху вниз:
1. Общий выключатель `notifications`.
2. По причине из `AttentionReason.allCases` — переключатель и меню звука. limit → `limit_notifications`, `sound_limit`. Меню звука — `PopoverMenuButton`: «Без звука», «Стандартный», затем системные звуки (SND-yes).
3. «Разрешать из уведомления» (`allow_from_notification`) с подсказкой о риске. Ветка B — строки нет.
4. «Уведомлять, даже когда Hangar впереди», «Число на иконке в Dock», «Сигнал простого SSH-терминала», «Не засыпать».
5. Строка статуса разрешения macOS. `.denied` → «Выключены в macOS» и кнопка «Открыть системные настройки» (`x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=<bundle id>`). Без бандла строки нет. T-no → там же пояснение, что срочные уведомления идут как обычные.

Меню проекта: пункт «Уведомления: все / только разрешения и вопросы / выключены»; клик переключает по кругу. Меню сессии: «Без уведомлений» / «С уведомлениями». Для host-терминала меню пустое, как сейчас.

- [ ] **Step 1: Write the failing tests:** `notificationPageLabels` (labelKeys содержат новые ключи; ветка B — без `allowFromNotificationTitle`), `soundNamesFromDirectory` (temp-папка с `A.aiff`, `b.txt` → `["A"]`), `muteActionsInMenus` (`Action.list(.task)` содержит `.toggleMute`; `.project` — `.projectNotifications`; perform меняет `muted` / цикл all→urgent→off→all), `settingWritesConfig` (переключатель причины пишет `notify_done = false` во временный `configURL`), `bellSlashIconDrawn` (IconsTests по `allCases`).
- [ ] **Step 2: Run (heavy):** `--filter "SettingsTests|SettingsCategoryTests|ActionsTests|IconsTests|NotificationSettingsTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** по описанию; строки только через `L10n`.
- [ ] **Step 4: Run (heavy)** те же фильтры + `L10nTests`. Expected: PASS.
- [ ] **Step 5: Commit + push** — `feat(settings): notification reasons, sounds, project and session muting`.

---

### Task 9: Живая проверка в DEBUG, снимки 3 темы × ru/en, документы, PR

**Files:**
- Modify: `docs/superpowers/specs/2026-10-18-hangar-design.md` §5 (ссылка на спеку уведомлений, новые ключи конфига в строке «Настройки» §4/85)
- Modify: `docs/decisions.md` #96 (итог живой проверки и что осталось владельцу)
- Снимки — только в `/tmp/hg-notif-out`, в репозиторий не кладутся.

**Interfaces:**
- Consumes: всё выше; debug-команды `notices`, `noticeAction`, `inbox`, `settings notifications`, `theme`, `lang`, `snap`, `dump`.

- [ ] **Step 1: Полный прогон** (heavy): `nice -n 15 swift test --no-parallel` под `AppleLanguages ru` и `en` (как CI). Expected: всё зелёное.
- [ ] **Step 2: Мир фикстур** в `/tmp/hg-notif`; в его `config.toml` обязательно `[agents]` с путями к поддельным `claude`/`codex` (см. Global Constraints). по образцу `scripts/readme-media/setup.sh`. Поддельный `claude` — скрипт, который вызывает `.build/debug/hangar event <kind>` с JSON по команде из файла-триггера (permission-request + notification permission_prompt, elicitation_dialog, stop с `last_assistant_message`, stop-failure `overloaded` и `rate_limit`). Поддельный `codex` печатает OSC 9 с текстом. Удалённый проект — через поддельный ssh из `scripts/readme-media` (`HANGAR_SSH`, `HANGAR_SSH_CONFIG`), события с «сервера» идут через `hangar-remote`. Плюс host-терминал с колоколом при `ssh_terminal_bell = true`.
- [ ] **Step 3: Сценарии** (одно приложение, `HANGAR_DEBUG_BEHIND=1`), результат — `notices`/`dump` в файлы:
  - каждая причина даёт элемент, верный заголовок, тело и категорию, в том числе для удалённого листа (« · host»);
  - `noticeAction … allow` при включённой настройке вводит `[enter]` в поддельный claude (он пишет полученный ввод в файл). После повторного запроса старый ключ даёт только переход;
  - ответ на OSC-вопрос Codex доходит текстом + Enter;
  - `PostToolUse`/`UserPromptSubmit` снимают элемент, `notices` показывает удаление;
  - фокус на листе, закрытие вкладки, архив, отключение хоста снимают элемент;
  - проект `off`/`urgent` и сессия «Без уведомлений»: элемент во «Входящих» есть, уведомления нет;
  - ⌥⌘A (`post 0 cmd,opt`) обходит элементы по кругу;
  - Dock-число (`dump`) = permission + question + failed.
- [ ] **Step 4: Снимки** (`snap`, по id окна): заголовок с колокольчиком (пусто / accent / failed), открытые «Входящие» (обе секции, пусто), нижняя строка, строка сессии с перечёркнутым колокольчиком, «Настройки → Уведомления», лист настроек проекта. Каждый — в `theme dark-plus|graphite|navy` × `lang ru|en`. Сверить с `DESIGN.md`, `icons-v2.html`, `limits.html`: нет скачков, нет литеральных цветов, курсор-рука. Найденное — исправить в этой задаче отдельными `fix(ui): …` коммитами.
- [ ] **Step 5: Остановить всё** (`kill -TERM`, поддельные агенты, ssh, `tmux -L hangar` под `/tmp/hg-notif`). Проверить, что ничего не осталось.
- [ ] **Step 6: Документы.** §5 основной спеки и #96: итог и список «проверить владельцу вживую» (настоящие баннеры macOS в собранной `.app`, клавиша S2, звук S4, ответ S5, `.timeSensitive` S3).
- [ ] **Step 7: Commit, проверка авторства, push, PR**
```bash
git add docs/
git commit -m "docs: notifications live check and spec update"
scripts/check-commits.sh origin/main..HEAD
git push
gh pr create --base main --head feat/notifications --title "feat: notifications by reason, inbox and per-project settings" --body-file /tmp/hg-notif-pr.md
```
Тело PR — по `docs/RELEASING.md` (чек-лист, что проверено, что осталось владельцу), без подписей. Merge — только по слову владельца (`hangar-release`).
