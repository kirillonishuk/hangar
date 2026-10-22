# Hangar — этап 6 (SSH-проекты) — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Проект может жить на сервере (`location: ssh(host, path)`): вкладки агентов, Helix и шелла — сессии tmux на сервере, которые переживают обрыв и сон Mac; статусы, лимиты и «не засыпать» работают для удалённых агентов; Files/Changes/diff и worktree — через git на сервере; при подключении Hangar проверяет сервер и ставит недостающее только после подтверждения с показом точных команд.

**Порядок:** 1 → 2 → 3 → 6 → 7 → 8 → 9 → 10. Задачи 4 и 5 независимы (после 2), обе нужны до 6.

**Architecture:** Всё удалённое идёт через системный `/usr/bin/ssh` и один мастер на хост (`ControlMaster`, путь в папке состояния): мастер — дочерний процесс Hangar, его готовность — строка-маркер в stdout, обрыв — завершение процесса (события, без опроса). `Exec` получает `Runner.ssh` (тот же `Runner`, через него ходят `Git` и служебные команды), `SSHMaster`, проверку сервера и команду удалённого листа. Статусы с сервера идут через `ssh -O forward -R` в отдельный сокет хоста: он принимает только события, и только для листов этого хоста. На сервере их шлёт POSIX-скрипт `hangar-remote`, JSON он не разбирает. Состоянием хостов (подключение, переподключение, проверка) владеет `RemoteHosts` в `HangarUI`.

**Tech Stack:** Swift 6.3, Swift Testing, AppKit + SwiftUI, `/usr/bin/ssh` (OpenSSH, ControlMaster, `-O forward`), tmux на сервере, POSIX sh, macOS 14+.

**Spec:** `docs/superpowers/specs/2026-10-18-hangar-design.md`: §11.1 целиком; §2 (`Exec`, `ControlServer`), §3 (`Project.location`), §5 (env листа, hooks, запасные пути), §5.2 (удалённые `working` держат блокировку), §6 (восстановление), §7 (CLI), §8, §9. Решения в `docs/decisions.md`: #15 (согласие и diff), #19–#21 (этап 6, tmux, `ssh -R` + `hangar-remote`), #26/#27 (обёртка OSC 133, `-l -i`), #35 (слот `SSH HOSTS`), #41 (режим запуска), #42 (`Runner`, worktree), #43 (статус на лист, hooks, id сессии), #44 (инспектор, Helix), #45 (CLI/MCP), #46. Новое решение #47 записано вместе с этим планом. Дизайн: `docs/design/DESIGN.md` (иконка `sshHost` = `server.rack`, сайдбар, листы 580, курсор). Правила: `AGENTS.md`.

## Global Constraints

- Без новых зависимостей. Только `/usr/bin/ssh` (путь подменяется лишь в DEBUG через `HANGAR_SSH` и в тестах). `~/.ssh/**` Hangar никогда не пишет. `~/.ssh/config` читается только ради списка `Host` (DEBUG-подмена — `HANGAR_SSH_CONFIG`). Сокеты мастера лежат в `<папка состояния>/ssh/` (0700).
- Все ssh-вызовы вне терминала идут с `-o BatchMode=yes`, `-o ControlMaster=no -S <controlPath>` (кроме самого мастера) и `--` перед хостом. Хост: 1…255 байт, не начинается с `-`, без пробелов, управляющих символов и `'"\`$;&|<>()`. Удалённый путь абсолютный (`/…`; `~/…` раскрывается по `$HOME` сервера при добавлении), ≤ 1024 байт, без управляющих символов.
- Удалённые команды всегда `/bin/sh -c '<скрипт>' sh <аргументы…>`: аргументы приходят позиционными параметрами, а не вклеиваются в скрипт (логин-шелл сервера может быть fish). Кавычки — только `shellQuote`.
- Установка на сервер — только после явного подтверждения в листе, где показаны точные команды. Показанный текст байт в байт совпадает с выполняемым (один источник — `InstallStep.command`). `sudo` выполняется только во вкладке-терминале внутри листа, пароль Hangar не видит. Правка файлов агентов на сервере (`settings.json`, `config.toml`) — через существующий лист согласия с diff (#15), с копией рядом. В CLI/MCP методов установки нет; будущий метод обязан требовать `yes: true`.
- Энергия: никаких опросов хостов. Таймеры этапа: (1) переподключение с backoff 2, 4, 8, 16, 32, 60, 60… с, не больше 10 попыток, только пока приложение активно или у хоста были `working`-листья, иначе пауза до активации; (2) один таймаут 10 с на пробу `true` после пробуждения Mac; (3) задержка 600 мс после `Esc` в удалённый Helix. В простое с подключёнными хостами таймеров и процессов, кроме мастеров и вкладок, нет. Удалённый инспектор не использует FSEvents и не опрашивает.
- Сокет хоста (`<state>/ssh/r-<id>.sock`, 0600, uid-проверка как у основного) принимает только `hook`/`statusline` (Task 4): одно сообщение на соединение, заголовок ≤ 4096 байт, `len` ≤ 262 144. Запросы `method` получают отказ `unknown-method` («not available over ssh»). Событие для листа чужого хоста или локального проекта игнорируется.
- Тесты не ходят ни на какой реальный хост. ssh — фейковый скрипт (`Tests/ExecTests/FakeSSH.swift`, копия в `HangarUITests`): он выполняет удалённую команду локально с `HOME`, равным собственному каталогу фейка. tmux в тестах — локальный с изолированным `TMUX_TMPDIR`, тест пропускается (`.enabled(if:)`), если `tmux` нет в PATH. Ничего не устанавливается.
- Всё видимое — через `L10n` (ru + en, `L10nTests.allKeysHaveRuAndEn`). Иконки — `enum Icon`, цвета и размеры — `Theme`, `.pointingHand()` на кликабельном. Вывод CLI/MCP — английский.
- Вне рамок этапа (список «Отложено (этап 6)» — Task 10): вход по паролю/2FA в фоне (askpass), `Include` в `~/.ssh/config`, дерево файлов не-git удалённой папки, симлинки-каталоги в удалённом дереве, `projects add --host` в CLI, несколько Mac на одном сервере (побеждает последний проброс), прокрутка мышью в tmux (`mouse` не трогаем), уборка tmux-сессий, осиротевших без связи, свои команды агентов на хост, логин-шелл csh/tcsh на сервере (сейчас — ошибка «не поддерживается»).

## Review Focus

1. **Враждебный хост или путь.** Хост `-oProxyCommand=touch /tmp/x`, `a b`, `h;rm`, путь с `'`, пробелом, `$(…)`, кириллицей, переводом строки. Ожидание: хост отклоняется до запуска ssh; путь доходит до сервера одним аргументом, ничего не исполняется. Тесты — Task 2 `hostValidated`, `remoteArgsArePositional`.
2. **Сервер управляет Mac.** Процесс на сервере пишет в проброшенный сокет запрос `tabs.send` или событие с id локального листа. Ожидание: запрос отклонён, событие проигнорировано, локальные терминалы не тронуты. Тесты — Task 4 `remoteSocketRejectsRequests`, Task 6 `eventForForeignLeafIgnored`.
3. **Обрыв посреди работы и сон Mac.** Пропала сеть, пока агент работает; Mac уснул; пользователь отсоединил tmux (`prefix d`). Ожидание: лист не становится `failed` и не закрывается, полоса «Соединение прервано», после переподключения — `attach` к той же сессии, первое сообщение второй раз не отправляется. Тесты — Task 7 `exit255IsDetached`, `reattachNeverResendsPrompt`, `tmuxSessionSurvivesClient`; Task 6 `lossKeepsStatusesThenReconnects`.
4. **Шторм переподключений.** Хост выключен, приложение в фоне, агентов нет. Ожидание: ни одного таймера и процесса ssh до активации приложения; после 10 попыток — «недоступен» и тишина. Тесты — Task 6 `noBackoffWhileInactiveIdle`, `givesUpAfterTenAttempts`.
5. **Установка не та, что показали.** Нажали «Отмена»; root без sudo; неизвестный пакетный менеджер; `hx` нет в apt. Ожидание: до «Установить» на сервере не запускается ничего, кроме проверки; выполняется ровно показанный текст; ручные пункты только перечислены. Тесты — Task 5 `planTable`, `planIsWhatRuns`; Task 9 `cancelRunsNothing`.

Плюс: закрытие вкладки, архив и удаление задачи убивают её tmux-сессии, а выход из приложения — нет (Task 7 `closingLeafKillsSession`); ⌘Q не спрашивает про удалённых агентов в tmux (Task 7 `quitIgnoresTmuxLeaves`).

---

### Файловая структура

```
Sources/Workspace/Model.swift              Location.ssh(host:path:), Project.host, addRemoteProject
Sources/Exec/SSH.swift                     SSHHost, sshPaths, Runner.ssh, sshWrite, directoryExists
Sources/Exec/SSHMaster.swift               мастер: connect / forward / probe / exit
Sources/Exec/RemoteCheck.swift             скрипт проверки, ServerReport, installPlan
Sources/Exec/RemoteLaunch.swift            RemoteTarget, remoteLaunchSpec, имена tmux-сессий
Sources/Exec/Launch.swift                  общая сборка внутренней команды, LaunchError.notConnected, LaunchContext.reattach
Sources/Exec/SSHConfig.swift               sshConfigHosts(_:)
Sources/ControlServer/RemoteScript.swift   hangarRemoteScript, hangarRemoteVersion
Sources/ControlServer/ControlServer.swift  режим remote (hook/statusline, одно сообщение)
Sources/ControlServer/Protocol.swift       RemoteMessage
Sources/Integration/ClaudeIntegration.swift  isHangarCommand: + hangar-remote
Sources/Git/Git.swift, Git+Inspect.swift   lastFetch через Runner, dirLinks только локально
Sources/HangarUI/RemoteHosts.swift         состояние хостов, переподключение, сокеты хостов
Sources/HangarUI/AppState+Remote.swift     runner(for:), git(for:), маршрутизация событий, kill-session
Sources/HangarUI/RemoteProjectSheet.swift  «Удалённый проект»
Sources/HangarUI/ServerCheckSheet.swift    отчёт, план установки, терминал установки, интеграции
Sources/HangarUI/SidebarView.swift, SidebarRows.swift, Actions.swift, SplitView.swift, TerminalDrawerView.swift,
  InspectorWatch.swift, InspectorModel.swift, NewTaskModel.swift, TaskDeletion.swift, MainWindow.swift,
  ProjectSettingsSheet.swift, IntegrationSheet.swift, AppState+Control.swift, L10n.swift, Resources/*.lproj
Tests/ExecTests/FakeSSH.swift (+ копия в Tests/HangarUITests/), SSHTests, SSHMasterTests, RemoteCheckTests, RemoteLaunchTests
Tests/ControlServerTests/RemoteSocketTests.swift, Tests/HangarUITests/RemoteHostsTests.swift, RemoteTabsTests.swift, RemoteGitTests.swift
```

### Task 1: Решение #47, спека, модель `Location.ssh`

**Files:**
- Modify: `docs/decisions.md` («Открытые вопросы»: пункт SSH), спека §11.1 и §2 (строка `Exec`), `Sources/Workspace/Model.swift`, `Tests/WorkspaceTests/ModelTests.swift`

**Interfaces:**
- Produces (`Workspace`):
  - `enum Location { case local(path: String); case ssh(host: String, path: String) }`. Codable синтезирован: `{"ssh":{"host":"h","path":"/p"}}`; старые `{"local":{"path":…}}` читаются как раньше.
  - `Project.path` — путь в обоих случаях; `Project.host: String?` (nil у локального).
  - `WorkspaceState.addRemoteProject(name: String, host: String, path: String) -> UUID`: тот же `host` + `path` уже есть → возвращает существующий id. Смена пути в настройках проекта (`Model.swift:484`) сохраняет хост.

- [ ] **Step 1: Спека** — привести §11.1 и §2 к решению #47 (записано вместе с планом): мастер — дочерний процесс без `ControlPersist`; сессия `hangar-<leafId>`; отдельный сокет хоста только для событий; `hangar-remote` без разбора JSON; коды 255/254 и `reattach`; проверка при каждом подключении; таймеры переподключения. В «Открытых вопросах» `decisions.md` закрыть пункт SSH ссылкой на #47 (`rm` перед `-O forward`; версии tmux — ручная проверка).
- [ ] **Step 2: Тесты** (`ModelTests`, RED): `remoteLocationRoundTrip` — проект `.ssh(host: "dev", path: "/srv/app")` переживает encode/decode, `host == "dev"`, `path == "/srv/app"`; `oldLocalStillDecodes` — JSON вида `{"local":{"path":"/a"}}` даёт `.local`; `addRemoteProjectDedupes` — два вызова с одной парой дают один id, а `"/srv/app"` на другом хосте — другой проект; `setPathKeepsHost` — смена пути у удалённого проекта даёт `.ssh(host: "dev", path: new)`.
- [ ] **Step 3:** Run: `swift test --filter ModelTests` — Expected: FAIL.
- [ ] **Step 4: Реализовать** по Interfaces; все `switch` по `Location` в коде доделать (компилятор покажет).
- [ ] **Step 5:** Run: `swift build && swift test --filter "ModelTests|StoreTests"` — Expected: PASS.
- [ ] **Step 6: Commit** — `git add docs Sources/Workspace Tests/WorkspaceTests && git commit -m "feat(workspace): ssh project location; decision #47"`

### Task 2: `Runner.ssh`, проверка хоста, фейковый ssh

**Files:**
- Create: `Sources/Exec/SSH.swift`, `Sources/Exec/SSHConfig.swift`, `Tests/ExecTests/FakeSSH.swift`, `Tests/ExecTests/SSHTests.swift`
- Modify: `Sources/Exec/Runner.swift` (`isLocal`), `Sources/Git/Git.swift` (`lastFetch`), `Sources/Git/Git+Inspect.swift` (`isDirectoryLink` только при `runner.isLocal`), `Tests/GitTests/GitTests.swift`

**Interfaces:**
- Produces (`Exec`, `public`, `Sendable`):
  - `func validSSHHost(_ s: String) -> String?` — по правилам Global Constraints, `nil` = отказ.
  - `struct SSHPaths { var stateDir: String; func controlPath(_ host: String) -> String; func hostSocket(_ host: String) -> String }` — `cm-<16 hex>` / `r-<16 hex>.sock` в `<stateDir>/ssh/` (FNV-1a 64 от хоста), запасной путь `/tmp/hangar-<uid>/` по правилу #47; `func prepare() throws` — каталог 0700.
  - `func sshBaseArgs(host: String, controlPath: String) -> [String]` = `["-S", cp, "-o", "ControlMaster=no", "-o", "BatchMode=yes"]`; хост всегда после `"--"`.
  - `func remoteShellArgs(script: String, _ args: [String]) -> String` = `"/bin/sh -c " + shellQuote(script) + " sh " + args.map(shellQuote).joined(" ")`.
  - `extension Runner { static func ssh(host: String, controlPath: String, sshPath: String = "/usr/bin/ssh") -> Runner }` — `ssh <base> -T -- host <remoteShellArgs(script: R, [cwd] + args)>`, где `R` = `cd "${1:-$HOME}" && shift && exec env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" "$@"`. Пустой `cwd` = `$HOME`. Отмена убивает локальный ssh (как у `.local`). `isLocal == false`.
  - `public var isLocal: Bool` у `Runner` (`.local` — true, init по умолчанию — false).
  - `func sshWrite(host:controlPath:sshPath:script:args:input: Data) async throws -> RunResult` — то же, но stdin = `input` (для `hangar-remote` и файлов интеграций).
  - `func directoryExists(_ path: String, runner: Runner) async -> Bool` — `test -d`.
  - `func sshConfigHosts(_ text: String) -> [String]` — слова строк `Host` (ключ без учёта регистра, `Host=a` тоже), без `*`, `?`, `!`, без повторов, в порядке файла; `Include` не читается (`shortcut:`).
  - `Git.lastFetch()` — через runner: `["sh", "-c", "[ -s \"$1\" ] && date -r \"$1\" +%s", "sh", <FETCH_HEAD>]`, пустой вывод → nil.
- Фейковый ssh (`FakeSSH.make(dir:) -> (path: String, log: String, home: String)`) — sh-скрипт. Пишет argv в лог. Пропускает опции (`-o -S -O -R -L -p -l -i` с аргументом, прочие `-x`), `--`, хост. Дальше: `-O forward -R a:b` → `ln -sf b a`, `-O exit` → `kill` pid из `$FAKE_SSH_DIR/master.pid`, другие `-O` → 0; `-M` → записывает свой pid и выполняет команду. Удалённая команда — `export HOME=<home фейка>; exec sh -c "$*"`. Поведение задают файлы в каталоге фейка (их видит любой процесс, в том числе запущенный приложением): `fail` с текстом `auth` → stderr `Permission denied (publickey).`, код 255; `fail` с `refused` → `ssh: connect to host dev port 22: Connection refused`, 255; `hang` → `sleep 30`. `FakeSSH.make(dir:)` возвращает также `home` (`<dir>/home`).

- [ ] **Step 1: Тесты** (RED):
  - `hostValidated` — принимаются `dev`, `user@host.example`, `[::1]`, `h-1_2`; отклоняются `-oProxyCommand=x`, `a b`, `h;rm`, `"$(id)"`, `""`, 256 байт, `a\nb`.
  - `remoteArgsArePositional` — через фейк: `Runner.ssh(...).run(["printf", "%s|", "a b", "it's", "$(touch pwned)", "привет"], cwd: dir)` → stdout `a b|it's|$(touch pwned)|привет|`, файла `pwned` нет ни в `dir`, ни в `<home фейка>`; в логе после `--` идёт хост, перед ним — `-o BatchMode=yes` и `-S <cp>`.
  - `gitOverSSH` — `Git(repo: tempRepo, runner: .ssh(...))`: `currentBranch()` и `status()` совпадают с результатами `.local`; `lastFetch()` = nil без fetch и mtime ±1 с после записи непустого `FETCH_HEAD`.
  - `sshAuthFailureIsStatus` — файл `fail` = `auth` → `status == 255`, stderr содержит `Permission denied`, без throw.
  - `controlPathFitsSocketLimit` — `stateDir` из 120 символов → путь в `/tmp/hangar-<uid>/`, длина + 17 ≤ 104; короткий — внутри `stateDir/ssh`; один хост — один путь, два хоста — разные.
  - `sshConfigHostList` — текст с `Host dev prod`, `host=box`, `Host *`, `Host !bad`, `Match all`, повтором `dev` → `["dev", "prod", "box"]`.
  - `directoryExistsRemote` — существующая папка → true, файл → false.
- [ ] **Step 2:** Run: `swift test --filter "SSHTests|GitTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать** по Interfaces.
- [ ] **Step 4:** Run: `swift build && swift test --filter "SSHTests|GitTests|RunnerTests|InspectTests"` — Expected: PASS.
- [ ] **Step 5: Commit** — `git add Sources/Exec Sources/Git Tests && git commit -m "feat(exec): ssh runner over a control master path"`

### Task 3: Мастер-соединение `SSHMaster`

**Files:**
- Create: `Sources/Exec/SSHMaster.swift`, `Tests/ExecTests/SSHMasterTests.swift`

**Interfaces:**
- Consumes: Task 2 (`SSHPaths`, `sshBaseArgs`, `remoteShellArgs`, `Runner.ssh`, фейк).
- Produces (`Exec`):
  - `enum SSHFailure: Error, Equatable { case auth(String), unreachable(String), exited(Int32, String) }` — по stderr: `Permission denied` / `Host key verification failed` / `passphrase` → `.auth`; `Could not resolve` / `Connection refused` / `timed out` / `No route` → `.unreachable`; иначе `.exited`. Строка — последняя непустая строка stderr, ≤ 300 символов.
  - `final class SSHMaster: @unchecked Sendable { init(host: String, controlPath: String, sshPath: String = "/usr/bin/ssh"); var onExit: (@Sendable (SSHFailure) -> Void)?; func connect(timeout: Double = 30) async -> Result<String /* $HOME сервера */, SSHFailure>; func forward(remote: String, local: String) async -> Bool; func probe(timeout: Double) async -> Bool; func exit() }`.
  - `connect`: процесс `ssh -M -T -S cp -o ControlPersist=no -o BatchMode=yes -o ConnectTimeout=15 -- host <remoteShellArgs(script: "printf 'HANGAR-READY %s\\n' \"$HOME\"; exec cat >/dev/null", [])>`. stdin — `Pipe`, его конец для записи хранится до `exit()`. Строка `HANGAR-READY <home>` в stdout → `.success(home)`. Процесс вышел раньше → `.failure` по stderr. Таймаут → `terminate` и `.unreachable("timed out")`. После успеха выход процесса вызывает `onExit` (один раз) с причиной; после `exit()` — не вызывает.
  - `forward`: `Runner.ssh(...).run(["sh", "-c", "mkdir -p -m 700 \"$HOME/.hangar/run\" && rm -f \"$1\"", "sh", remote], "")`, затем `ssh -S cp -O forward -R <remote>:<local> -- host`, итог — код 0.
  - `probe`: `true` через runner, `false` при таймауте или коде ≠ 0 (таймаут — `Task` с отменой; отмена убивает ssh).
  - `exit()`: `ssh -S cp -O exit -- host` (fire-and-forget), закрыть stdin, `terminate` процесса.

- [ ] **Step 1: Тесты** (RED, фейк):
  - `connectReturnsHome` — `.success(<home фейка>)`; в логе мастера есть `-M`, `ControlPersist=no`, `BatchMode=yes`, `--`, а `-f` нет.
  - `authFailureClassified` — файл `fail` = `auth` → `.failure(.auth("Permission denied (publickey)."))` за < 2 с, `onExit` не вызван.
  - `connectTimeout` — файл `hang`, `timeout: 0.5` → `.unreachable`, процесс фейка мёртв.
  - `deathFiresOnExitOnce` — после connect убить pid мастера → `onExit` ровно один раз за < 2 с; `exit()` после успешного connect → `onExit` не вызван, в логе `-O exit`.
  - `forwardLinksSocket` — `forward(remote: home/.hangar/hangar.sock, local: x.sock)` → true, `home/.hangar/run` существует, `hangar.sock` — симлинк на `x.sock` (в фейке), старый файл на этом месте удалён до проброса.
  - `probeTimesOut` — мастер жив, следующий вызов с файл `hang`, `probe(timeout: 0.3)` → false за < 1 с.
- [ ] **Step 2:** Run: `swift test --filter SSHMasterTests` — Expected: FAIL.
- [ ] **Step 3: Реализовать** по Interfaces.
- [ ] **Step 4:** Run: `swift test --filter "SSHMasterTests|SSHTests"` — Expected: PASS, 2 прогона подряд.
- [ ] **Step 5: Commit** — `git add Sources/Exec Tests/ExecTests && git commit -m "feat(exec): ssh control master owned by the app"`

### Task 4: Сокет хоста и `hangar-remote`

**Files:**
- Create: `Sources/ControlServer/RemoteScript.swift`, `Tests/ControlServerTests/RemoteSocketTests.swift`
- Modify: `Sources/ControlServer/ControlServer.swift` (`remote: Bool`), `Sources/ControlServer/Protocol.swift`, `Sources/ControlServer/CLISupport.swift` (`eventMessage` по tab/leaf/payload), `Sources/Integration/ClaudeIntegration.swift` (`isHangarCommand`), `Tests/IntegrationTests/ClaudeIntegrationTests.swift`

**Interfaces:**
- Consumes: `EventMessage`, `UsageMessage`, `statuslineWindows`, `validSessionId`, `HookKind`.
- Produces (`ControlServer`):
  - `ControlServer.init(path:remote: Bool = false, handler:onRequest:)`. В режиме remote соединение читает строку-заголовок (≤ 4096 байт), затем ровно `len` байт (≤ 262 144). Отвечает `{"ok":true}` или `{"ok":false,"error":…}` и закрывает соединение. Строки `method` → `{"id":…,"error":{"code":"unknown-method","message":"not available over ssh"}}`. `event`/`usage` прежнего вида тоже отклоняются (`unknown-type`).
  - Заголовок: `{"v":1,"type":"hook","tab":"<uuid>","leaf":"<uuid>","kind":"<HookKind>","session":"…"?,"len":N}` или `{"v":1,"type":"statusline","len":N}`.
  - `enum RemoteMessage { static func decode(header: Data, payload: Data) -> Result<ControlMessage, ProtocolError> }`. `hook` → `.event` через ту же функцию, что у `hangar event`: `eventMessage(kind:tab:leaf:args:payload:)`; payload не JSON → пустой объект, событие всё равно идёт. `statusline` → `.usage(UsageMessage(agent: "claude", windows: statuslineWindows(payload)))`, пустые окна → `badField`.
  - `let hangarRemoteVersion = 1`; `let hangarRemoteScript: String` — POSIX sh, первая строка `#!/bin/sh`, вторая `# hangar-remote <version>`. Команды: `version` (печатает номер); `event <kind> [--session ID] [--then argv…] [json]`; `statusline [--then CMD]`. `event` всегда выходит с 0, ничего не печатает, при отсутствии `HANGAR_TAB_ID`/`HANGAR_LEAF_ID`/`HANGAR_SOCKET` ничего не шлёт. Payload — stdin (≤ 262 144 байт, `head -c`), у `codex-notify` — последний аргумент `{…}`, после отправки запускает `--then` argv. `statusline` читает stdin один раз, шлёт его, затем передаёт тот же stdin в `sh -c CMD` и выходит с его кодом. UUID и `kind` проверяются `case`-шаблонами, `session` проходит через `tr -cd 'A-Za-z0-9._-'`. Клиент: `python3 -c` (таймаут 2 с) → `socat -t2 - UNIX-CONNECT:` → `nc -U -w 2`; весь вывод клиента — в `/dev/null`.
  - `isHangarCommand` распознаёт и `…/hangar-remote` (`event`/`statusline`).

- [ ] **Step 1: Тесты** (RED; сервер в режиме remote во временном каталоге; скрипт пишется в файл и запускается `/bin/sh`, а если есть `/bin/dash` — то и им; PATH урезан до каталога с симлинком на нужный клиент):
  - `hookDelivered` — `printf '{"session_id":"abc","source":"startup"}' | sh hangar-remote event session-start` с env листа → handler получил `.event` с `kind == .sessionStart`, `session == "abc"`, `source == "startup"`; варианты PATH «только python3» и «только nc» дают одно и то же (вариант `socat` — если он установлен).
  - `remoteSocketRejectsRequests` — строка `{"v":1,"id":1,"method":"tabs.send","params":{…}}` → ответ `unknown-method`, `onRequest` вызван 0 раз; прежний `{"v":1,"type":"event",…}` → `unknown-type`, handler 0 раз.
  - `oneMessagePerConnection` — после ответа соединение закрыто (EOF), второй заголовок в том же соединении не обработан.
  - `badPayloadStillCounts` — payload `{"session_id":` (обрезан) → событие с `session == nil`; `len` 300 000 → `too-large`, соединение закрыто; заголовок без `\n` длиннее 4096 → закрыто.
  - `noHangarEnvIsSilent` — без `HANGAR_*` → код 0, пустой stdout и stderr, сервер ничего не получил; сокета нет (`HANGAR_SOCKET` на несуществующий путь) → код 0 меньше чем за 3 с.
  - `statuslineChains` — stdin с `rate_limits.five_hour` → handler получил `.usage` с окном `five_hour`; `--then 'cat; echo X'` печатает исходный stdin и `X`, код 0; `--then 'exit 3'` → код 3.
  - `codexNotifyArgPayload` — `hangar-remote event codex-notify --then /bin/echo hi '{"type":"agent-turn-complete","thread-id":"t1"}'` → событие `codexNotify`, `session == "t1"`; stdout пустой, `echo` получил `hi` и JSON.
  - `scriptParsesAsPOSIX` — `sh -n` (и `dash -n`, если есть) по тексту — код 0; вторая строка — `# hangar-remote 1`.
  - `ClaudeIntegrationTests.remoteCommandRecognized` — `claudeInstall(nil, cli: "/home/u/.hangar/bin/hangar-remote")` → `claudeState(_, cli:) == .installed`; `isHangarCommand("'/home/u/.hangar/bin/hangar-remote' event stop")` → true.
- [ ] **Step 2:** Run: `swift test --filter "RemoteSocketTests|ClaudeIntegrationTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать** по Interfaces.
- [ ] **Step 4:** Run: `swift build && swift test --filter "RemoteSocketTests|ControlServerTests|ProtocolTests|HangarCLITests|ClaudeIntegrationTests|CodexIntegrationTests"` — Expected: PASS.
- [ ] **Step 5: Commit** — `git add Sources Tests && git commit -m "feat(control): events-only host socket and hangar-remote script"`

### Task 5: Проверка сервера и план установки

**Files:**
- Create: `Sources/Exec/RemoteCheck.swift`, `Tests/ExecTests/RemoteCheckTests.swift`

**Interfaces:**
- Consumes: Task 2 (`Runner.ssh`, фейк), `hangarRemoteVersion` (передаётся параметром: `Exec` не зависит от `ControlServer`).
- Produces (`Exec`):
  - `let serverCheckScript: String` — POSIX sh. Запускается так: `["/bin/sh", "-c", "exec \"${SHELL:-/bin/sh}\" -l -i -c \"$1\" </dev/null 2>/dev/null", "sh", serverCheckScript]`, то есть с PATH логин-шелла, как у вкладок. Печатает только строки `HANGAR <ключ> <значение>`: `os` (`uname -s`), `distro` (`ID` из `/etc/os-release`), `pm` (первый найденный из `apt-get dnf yum pacman apk brew`, иначе `none`), `uid`, `sudo yes|no`, `home`, `shell`, `tool <git|tmux|claude|codex|hx|curl|npm> <путь> <первая строка --version / -V, ≤ 80 символов>` или `missing <имя>`, `client <python3|socat|nc|none>`, `remote <версия|none>` (вторая строка `~/.hangar/bin/hangar-remote`), `claude_dir <${CLAUDE_CONFIG_DIR:-$HOME/.claude}>`, `codex_home <${CODEX_HOME:-$HOME/.codex}>`, последней — `end`.
  - `enum PackageManager: String { case aptGet = "apt-get", dnf, yum, pacman, apk, brew }`; `enum RemoteTool: String, CaseIterable { case git, tmux, claude, codex, hx, curl, npm }`; `struct ToolInfo: Equatable { var path: String; var version: String }`.
  - `struct ServerReport: Equatable { var os, home, shell, claudeDir, codexHome: String; var distro: String?; var packageManager: PackageManager?; var uid: Int; var hasSudo: Bool; var tools: [RemoteTool: ToolInfo]; var socketClient: String?; var remoteVersion: Int? }`; `var tmux: Bool`; `var missingRequired: [RemoteTool]` (`git`, `tmux`); `func remoteOutdated(current: Int) -> Bool`.
  - `func parseServerReport(_ stdout: String) -> ServerReport?` — строки без префикса `HANGAR ` пропускаются (шум rc-файлов); без `end` или без `home` → nil.
  - `func checkServer(_ runner: Runner) async -> Result<ServerReport, SSHFailure>`.
  - `struct InstallStep: Equatable { var title: String; var command: String; var inTerminal: Bool }`; `func installPlan(_ r: ServerReport, remoteVersion: Int) -> (steps: [InstallStep], manual: [RemoteTool])`. Таблица:
    - Пакеты (одна строка на все): нет `git` → `git`, нет `tmux` → `tmux`, нет клиента сокета → `socat`, нет `hx` → `helix` (кроме apt-get: `hx` идёт в `manual`), нет `claude` и `curl` → `curl`. Префикс `sudo ` — если `uid != 0` и `hasSudo` (у brew префикса нет). `apt-get`: `sudo apt-get update && sudo apt-get install -y <пакеты>`; `dnf`/`yum`: `sudo dnf install -y <пакеты>`; `pacman`: `sudo pacman -S --needed --noconfirm <пакеты>`; `apk`: `sudo apk add <пакеты>`; `brew`: `brew install <пакеты>`. Нет пакетного менеджера или (`uid != 0` и нет sudo) → все пакеты в `manual`. `inTerminal: true`.
    - Нет `claude`: `curl -fsSL https://claude.ai/install.sh | bash` (`inTerminal: true`, после пакетов).
    - Нет `codex`: brew → `brew install codex`; есть `npm` → `npm install -g @openai/codex`; иначе `manual`. Пометка `// verify: codex не установлен — команда не проверена`.
    - `hangar-remote` нет или устарел: `title` «hangar-remote», `command` = `mkdir -p "$HOME/.hangar/bin" && cat > "$HOME/.hangar/bin/hangar-remote" && chmod 700 "$HOME/.hangar/bin/hangar-remote"`, `inTerminal: false` (выполняется `sshWrite` с текстом скрипта в stdin).
  - `func terminalScript(_ steps: [InstallStep]) -> String` = `"set -e\n" + steps.filter(\.inTerminal).map(\.command).joined("\n")` — ровно то, что показывает лист и получает `ssh -t`.

- [ ] **Step 1: Тесты** (RED):
  - `parseFullReport` — записанный вывод (Ubuntu, uid 1000, sudo, git 2.43, `missing tmux`, `client python3`, `remote none`, плюс строки «Welcome!» и `motd`) → поля совпадают; `tmux == false`; `missingRequired == [.tmux]`.
  - `parseRejectsTruncated` — без `end` → nil.
  - `planTable` — таблица (менеджер, uid, sudo, нет чего) → ожидаемые `command`: apt + нет git, tmux, hx → `sudo apt-get update && sudo apt-get install -y git tmux`, `manual == [.hx]`; pacman с uid 0 → `pacman -S --needed --noconfirm git tmux helix`; brew → без `sudo`; uid 1000 без sudo → пакетных шагов нет, в `manual` всё; `pm none` → то же; `claude` нет, `curl` нет → `curl` в пакетах и шаг `install.sh` после них; всё есть, `remote 1` → шагов нет.
  - `planIsWhatRuns` — `terminalScript(plan.steps)` == `"set -e\n" +` команды шагов `inTerminal` в порядке показа; шаг `hangar-remote` в него не входит.
  - `checkViaFakeSSH` — `checkServer(.ssh(фейк))` на этой машине → `.success`, `home == <home фейка>`, `os == "Darwin"`, `tools[.git] != nil`; файл `fail` = `auth` → `.failure(.auth)`.
- [ ] **Step 2:** Run: `swift test --filter RemoteCheckTests` — Expected: FAIL.
- [ ] **Step 3: Реализовать** по Interfaces.
- [ ] **Step 4:** Run: `swift test --filter RemoteCheckTests` — Expected: PASS.
- [ ] **Step 5: Commit** — `git add Sources/Exec Tests/ExecTests && git commit -m "feat(exec): server check and confirmed install plan"`

### Task 6: `RemoteHosts` — подключение, сокеты хостов, переподключение

**Files:**
- Create: `Sources/HangarUI/RemoteHosts.swift`, `Sources/HangarUI/AppState+Remote.swift`, `Tests/HangarUITests/FakeSSH.swift` (копия помощника), `Tests/HangarUITests/RemoteHostsTests.swift`
- Modify: `Sources/HangarUI/AppState.swift` (`remote`, `workingLeafCount` без изменений), `Sources/HangarApp/main.swift` (`didBecomeActive`, `didWake`, `applicationWillTerminate` → `appState?.remote.stopAll()`; DEBUG `HANGAR_SSH`)

**Interfaces:**
- Consumes: Task 3 (`SSHMaster`), Task 4 (`ControlServer(remote: true)`, `hangarRemoteScript`, `hangarRemoteVersion`), Task 5 (`checkServer`, `ServerReport`), `AppState.handle(_:)`.
- Produces:
  - `enum HostState: Equatable { case disconnected, connecting, connected, reconnecting(attempt: Int), unreachable(String) }`.
  - `struct HostInfo: Equatable { var state: HostState; var home: String?; var report: ServerReport?; var forwarding: Bool; var authFailed: Bool; var needsAttention: Bool /* missingRequired, remoteOutdated, нет клиента сокета, !forwarding */ }`.
  - `@MainActor @Observable final class RemoteHosts { init(paths: SSHPaths, sshPath: String, schedule: @escaping (Duration, @escaping @MainActor () -> Void) -> (() -> Void) = KeepAwake.taskSchedule, isActive: @escaping () -> Bool, hasWorking: @escaping (String) -> Bool, onMessage: @escaping (String, ControlMessage) -> Void); private(set) var hosts: [String: HostInfo]; var onConnected: ((String) -> Void)?; var onLost: ((String) -> Void)?; func connect(_ host: String) async -> HostState; func recheck(_ host: String) async; func runner(_ host: String) -> Runner; func target(_ host: String) -> RemoteTarget?; func disconnect(_ host: String); func appBecameActive(); func didWake(); func stopAll() }`.
  - Сценарий `connect` (повторный вызов во время подключения ждёт ту же попытку): `connecting` → `SSHMaster.connect` → при неудаче `unreachable(текст)` (`.auth` ставит `authFailed`, переподключения нет) → `checkServer` → старт сокета хоста `ControlServer(path: hostSocket, remote: true)`, сообщения уходят в `onMessage(host, …)` → `forward(remote: home + "/.hangar/hangar.sock", local: hostSocket)` → `connected`, `onConnected(host)`. `RemoteTarget` (Task 7) строится из `home`, `report.tmux`, `controlPath`.
  - Потеря (`onExit` мастера): `onLost(host)`; дальше `reconnecting(1…10)` с задержками 2, 4, 8, 16, 32, 60… с. Следующая попытка ставится только при `isActive() || hasWorking(host)`, иначе таймера нет до `appBecameActive()`. Если все 10 попыток неудачны → `unreachable`. `disconnect` (действие пользователя) → `-O exit`, `disconnected`, без переподключения. `didWake()` → `probe(timeout: 10)` каждому `connected`; `false` → `master.exit()` и путь потери. `stopAll()` — `-O exit` всем, сокеты хостов закрыты, таймеры отменены.
  - `AppState+Remote.swift`: `lazy var remote: RemoteHosts`. `func handleRemote(host: String, _ m: ControlMessage)` — `.event` проходит в `handle`, только если лист принадлежит неархивной задаче проекта с `host == host`; `.usage` проходит всегда. `func remoteLeafHost(_ leafId: UUID) -> String?`. `hasWorking(host)` — есть `working`-лист этого хоста. При `unreachable` листья хоста получают `.relaunched` (→ `idle`).

- [ ] **Step 1: Тесты** (RED; фейк + ручной `schedule`, хранящий тела; `isActive` — переменная теста):
  - `connectSequence` — `connect("dev")` → `connected`; `home == <home фейка>`; `report != nil`; в `<home фейка>/.hangar/hangar.sock` симлинк на `hostSocket`; `forwarding == true`; `onConnected` вызван один раз; два одновременных `connect` → в логе один `-M`.
  - `eventForForeignLeafIgnored` — через `hangar-remote` в фейковом «сервере» (env листа локального проекта, затем листа проекта хоста `other`) → статусы не изменились; лист проекта `dev` → `working`; `.usage` по сокету хоста → `usage.claude` обновлён.
  - `lossKeepsStatusesThenReconnects` — лист хоста в `working`, убит мастер → `onLost`, статус по-прежнему `working`, `reconnecting(attempt: 1)`, `schedule` вызван с 2 с; тело → `connected`, `onConnected` второй раз.
  - `noBackoffWhileInactiveIdle` — `isActive = false`, `working` нет, потеря → `schedule` 0 раз, процессов ssh не прибавилось; `appBecameActive()` → одна попытка.
  - `givesUpAfterTenAttempts` — файл `fail` = `refused` после потери, 10 тел подряд → `unreachable`, задержки 2, 4, 8, 16, 32, 60, 60, 60, 60, 60 с; 11-го `schedule` нет; листья хоста `idle`.
  - `authFailureNoRetry` — файл `fail` = `auth` → `unreachable`, `authFailed`, `schedule` 0 раз.
  - `wakeProbeDropsDeadLink` — `didWake()` при файл `hang` на пробе → через ≤ 10 с (в тесте таймаут 0.3) путь потери.
  - `stopAllExitsMasters` — `stopAll()` → в логе `-O exit` для каждого хоста, файл сокета хоста удалён, `onLost` не вызван.
- [ ] **Step 2:** Run: `swift test --filter RemoteHostsTests` — Expected: FAIL.
- [ ] **Step 3: Реализовать** по Interfaces.
- [ ] **Step 4:** Run: `swift build && swift test --filter "RemoteHostsTests|AgentWiringTests"` — Expected: PASS, 2 прогона.
- [ ] **Step 5: Commit** — `git add Sources Tests && git commit -m "feat(remote): host connections, events-only host sockets, bounded reconnect"`

### Task 7: Удалённые вкладки в tmux

**Files:**
- Create: `Sources/Exec/RemoteLaunch.swift`, `Tests/ExecTests/RemoteLaunchTests.swift`, `Tests/HangarUITests/RemoteTabsTests.swift`
- Modify: `Sources/Exec/Launch.swift`, `Sources/HangarUI/AppState.swift` (`spec`, `perform` → kill-session), `Sources/HangarUI/SplitView.swift` (`LeafView`, `TerminalArea.hostConnected`), `Sources/HangarUI/TerminalDrawerView.swift`, `Sources/HangarUI/MainWindow.swift` (`currentQuitDecision`), `Sources/HangarUI/L10n.swift` + строки

**Interfaces:**
- Consumes: Task 6 (`remote.target`, `remote.connect`, `onConnected`, `remoteLeafHost`), `launchSpec`, `launchMode`.
- Produces (`Exec`):
  - `struct RemoteTarget: Equatable, Sendable { var host: String; var controlPath: String; var home: String; var tmux: Bool; var sshPath: String }`.
  - `LaunchError` + `case notConnected(host: String)`; `LaunchContext` + `case reattach(previous: LaunchMode)` → `launchMode` = `LaunchMode(restoring: kind ∈ {claude, codex} || previous.restoring, initialPrompt: nil)`.
  - Внутренняя команда собирается одной функцией для локального и удалённого запуска: `agentCommand(for: Leaf, agent: (LeafKind) -> String, editor: String, shell: String, restoring: Bool, initialPrompt: String?) -> String`. Локально `agent` = `[agents]` из конфига, удалённо — `kind.rawValue`.
  - `func remoteSessionName(_ leaf: UUID) -> String` = `"hangar-" + uuid.lowercased()`; `func killSessionArgs(_ leaf: UUID) -> [String]` = `["tmux", "kill-session", "-t", "=" + name]`.
  - `func remoteLaunchSpec(for leaf: Leaf, tabId: UUID, target: RemoteTarget, editor: String, restoring: Bool, initialPrompt: String?) -> LaunchSpec`: `cwd` = `NSHomeDirectory()`, `env` = `[:]`. Команда: `<posixShell> -l -i -c '<inner>; c=$?; printf OSC133 …; exit $c'`, как в #26. `inner` = `TERM=xterm-256color <sshPath> -t <sshBaseArgs> -- <host> <remoteShellArgs(script: S, [cwd, name, exitFile, envLine, agentCmd])>`, где `exitFile = home/.hangar/run/<name>.exit`, а `envLine` — строка `HANGAR_TAB_ID=… HANGAR_LEAF_ID=… HANGAR_SOCKET=<home>/.hangar/hangar.sock` для `env`. Скрипт `S` (tmux):

    ```sh
    cd "$1" 2>/dev/null || { echo "hangar: no such folder: $1" >&2; exit 254; }
    if ! tmux has-session -t "=$2" 2>/dev/null && [ -f "$3" ]; then c=$(cat "$3"); rm -f "$3"; exit "${c:-0}"; fi
    rm -f "$3"
    tmux new-session -A -s "$2" -c "$1" "env $4 \"\${SHELL:-/bin/sh}\" -l -i -c \"\$0\"; c=\$?; [ \$c = 255 ] && c=254; echo \$c > '$3'" "$5" \; set-option -t "$2" status off
    if [ -f "$3" ]; then c=$(cat "$3"); rm -f "$3"; exit "$c"; fi
    exit 255
    ```
    Это эскиз: точное экранирование — на исполнителе, тесты ниже фиксируют поведение. Без tmux: `cd "$1" && exec env $4 "${SHELL:-/bin/sh}" -l -i -c "$5"`, код 255 агента → 254.
- Produces (`HangarUI`):
  - `AppState.spec`: у проекта есть `host` → `remote.target(host)`. `nil` → `Task { await remote.connect(host) }` и `throw .notConnected(host)`. Иначе `remoteLaunchSpec(…, restoring: mode.restoring, initialPrompt: mode.initialPrompt)`.
  - `LeafView`: на `.notConnected` — полоса `L10n.hostNotConnected(host)` и запомненный контекст; `func resumeIfWaiting()`. Код 255 у удалённого листа — полоса `L10n.sessionDetached`, `signal(.exited)` не шлётся, лист не закрывается. ↩ и `hostConnected` делают `relaunch` с `.reattach(previous:)`. `var isDetached: Bool`.
  - `TerminalArea.hostConnected(_ host: String)` (и то же в `TerminalDrawer`): у созданных `LeafView` этого хоста — `resumeIfWaiting()` или, если `isDetached`, `relaunch(focus: false)`. Вызывается из `remote.onConnected`.
  - `perform`: листья, которые были живыми у проекта с `host`, а после мутации исчезли из `liveLeafIds` (закрытие, архив, удаление задачи или проекта) → `remote.runner(host).run(killSessionArgs(id), "")` в фоне, только при `connected` (`shortcut:` без связи сессия остаётся — в followups).
  - `currentQuitDecision`: `working` = рабочие листья, кроме удалённых при `target.tmux == true`.
  - Удалённый Helix: в `openInEditor` после `Esc` пауза 600 мс, а не 50 (лист удалённый).
  - L10n: `hostNotConnected` «Нет соединения с %@ · подключение…» / «Not connected to %@ · connecting…»; `sessionDetached` «Соединение прервано · ↩ переподключиться» / «Connection lost · ↩ reconnect».

- [ ] **Step 1: Тесты** (RED):
  - `RemoteLaunchTests.commandShape` — claude-лист с `initialPrompt: "fix it"` → команда содержит `TERM=xterm-256color`, `-t`, `ControlMaster=no`, `-- 'dev'`, `hangar-<leaf lowercased>`, `claude 'fix it'`; `restoring` с id `abc` → `claude --resume abc`; локальный `[agents] claude = "/Users/me/bin/claude"` в удалённую команду не попадает; editor с `openFile` `/srv/a b.txt`, `openLine` 3 → `hx '/srv/a b.txt:3'`.
  - `RemoteLaunchTests.reattachMode` — `.reattach(previous: (false, "hi"))` у claude → `(true, nil)`; у shell → `(false, nil)`.
  - `RemoteLaunchTests.tmuxSessionSurvivesClient` (нужен tmux, `TMUX_TMPDIR` — временный, фейковый ssh) — команда листа, где агент = `sh -c 'echo started; sleep 30'`, запускается через `/bin/sh -c`. После `started` клиент убивается → `tmux has-session` true. Повторный запуск той же командой показывает тот же pane (без второго `started`, `list-panes` — тот же pid). Затем `tmux kill-session` по `killSessionArgs`.
  - `RemoteLaunchTests.exitCodesThroughTmux` (tmux) — агент `exit 3` → у команды код 3; `exit 0` → 0; `exit 255` → 254; `tmux detach-client` → 255; агент вышел с 5, пока клиента не было → следующий запуск возвращает 5 без новой сессии.
  - `RemoteLaunchTests.missingFolder` — `cwd` нет → код 254, stderr `hangar: no such folder`.
  - `RemoteTabsTests.notConnectedThenStarts` — `AppState` с `RemoteHosts` на фейке, задача удалённого проекта, `spec` → `notConnected`, `connect` запущен. После `onConnected` у `TerminalArea` (тестовый хук) вызван `resumeIfWaiting`.
  - `RemoteTabsTests.exit255IsDetached` — `onExit(255)` у удалённого листа в `working` → статус `working`, лист в модели на месте, `isDetached`; у локального листа 255 → как раньше `failed`.
  - `RemoteTabsTests.reattachNeverResendsPrompt` — новая задача с первым сообщением, лист отсоединён, `hostConnected` → контекст перезапуска `.reattach`, `initialPrompt == nil`.
  - `RemoteTabsTests.closingLeafKillsSession` — закрыть вкладку удалённой задачи → в логе фейка `tmux kill-session -t =hangar-<id>`; архив задачи — то же для всех её листьев; `stopAll` (выход) — kill-session не вызывается.
  - `RemoteTabsTests.quitIgnoresTmuxLeaves` — один удалённый `working` (tmux) → `currentQuitDecision` не спрашивает; плюс один локальный `working` → спрашивает.
- [ ] **Step 2:** Run: `swift test --filter "RemoteLaunchTests|RemoteTabsTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать** по Interfaces.
- [ ] **Step 4:** Run: `swift build && swift test --filter "RemoteLaunchTests|RemoteTabsTests|LaunchTests|RestoreTests|AgentWiringTests|EditorOpenerTests"` — Expected: PASS.
- [ ] **Step 5: Commit** — `git add Sources Tests && git commit -m "feat(remote): tabs as tmux sessions on the server; reattach on reconnect"`

### Task 8: Git, инспектор, worktree и удаление для удалённых проектов

**Files:**
- Create: `Tests/HangarUITests/RemoteGitTests.swift`
- Modify: `Sources/HangarUI/AppState+Remote.swift` (`runner(for:)`, `git(for:)`), `Sources/HangarUI/AppState.swift:183`, `Sources/HangarUI/AppState+Control.swift` (`ProjectInfo.host`, `exists`), `Sources/ControlServer/Protocol.swift` (`ProjectInfo.host: String?`), `Sources/ControlServer/CLICommands.swift` (`<id8>  <name>  <host>:<path>`), `Sources/HangarUI/MainWindow.swift:496,591`, `Sources/HangarUI/Actions.swift`, `Sources/HangarUI/TaskDeletion.swift`, `Sources/HangarUI/NewTaskModel.swift`, `Sources/HangarUI/InspectorWatch.swift`, `Sources/HangarUI/InspectorModel.swift`, `Sources/HangarUI/ProjectSettingsSheet.swift`, `Sources/HangarUI/L10n.swift` + строки

**Interfaces:**
- Consumes: Task 2 (`Runner.ssh`, `directoryExists`, `isLocal`), Task 6 (`remote.runner`, `hosts`).
- Produces:
  - `AppState.runner(for project: Project) -> Runner` (`.local` или `remote.runner(host)`), `git(for project: Project, repo: String? = nil) -> Git`. Все `Git(repo: project.path)` из списка Files заменяются на них.
  - `InspectorModel.show(taskId:root:git: @escaping @Sendable (String) -> Git, remote: Bool, baseBranch:)` — `git` теперь по контексту, а не из `init`. Если `remote` и не git — пустое дерево, `isGit = false`, `remoteNoGit` вместо дерева, без `listDirectory`.
  - `InspectorWatch`: у удалённой задачи `FileWatcher` нет. `update()` показывает задачу как раньше. `NSWindow.didBecomeKeyNotification` при показанной удалённой задаче → `inspector.refresh(.all)`. `leafDone` — как раньше.
  - `NewTaskModel`: у проекта с `host` проверка `FileManager` в `suggestBranch` пропускается.
  - `deleteTaskPermanently` и «есть ли папка» у удалённых задач — `await directoryExists(path, runner:)`. Серые строки удалённого проекта — по `remote.hosts[host]?.state == .unreachable`, а не по диску.
  - `Action.isEnabled`: `revealInFinder`, `openInEditor` (внешний редактор) — false для удалённых; `copyPath` копирует `host:path`.
  - `ProjectSettingsSheet`: у удалённого проекта путь и папка worktree — текстовые поля без «Выбрать…»; ветки — через `git(for:)`.
  - `ProjectInfo.host` (nil у локального); `exists` у удалённого = состояние хоста не `unreachable`. `projects add` по-прежнему только локальный.
  - L10n `remoteNoGit` «Удалённая папка без git — дерево файлов недоступно» / «Remote folder without git — no file tree».

- [ ] **Step 1: Тесты** (RED; фейковый ssh, «сервер» — локальный temp-репо):
  - `inspectorLoadsOverSSH` — удалённая задача на temp-репо с изменённым и неотслеживаемым файлом → `inspector` показывает дерево, `Changes` из двух файлов, diff файла; ни один `FileWatcher` не создан (счётчик фабрики = 0); в логе фейка есть `git … status`.
  - `remoteRefreshTriggers` — `didBecomeKey` → одна новая загрузка; без событий 1 с → вызовов git не прибавилось.
  - `remoteWorktreeCreate` — `NewTaskModel` удалённого проекта: `create` с worktree → `git worktree add` через фейк, папка `repo.worktrees/fix-login` появилась; `lastFetch` — через `date -r` (в логе).
  - `remoteDeleteChecksServer` — удаление worktree-задачи: папки нет → ветка «папки нет» без `FileManager` (у проекта путь, которого нет локально, но он есть «на сервере» → ветка «есть»).
  - `remoteActionsDisabled` — `revealInFinder`/`openInEditor` у удалённой задачи и проекта → `isEnabled == false`; `copyPath` → `"dev:/srv/app"`.
  - `ControlRequestTests.projectsListHost` — удалённый проект в `projects.list` → `host == "dev"`; `CLICommandsTests.humanFormat` с хостом → `dev:/srv/app`.
- [ ] **Step 2:** Run: `swift test --filter "RemoteGitTests|ControlRequestTests|CLICommandsTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать** по Interfaces.
- [ ] **Step 4:** Run: `swift build && swift test --filter "RemoteGitTests|ControlRequestTests|CLICommandsTests|InspectorModelTests|FileWatcherTests|NewTaskModelTests|TaskDeletionTests|ActionsTests"` — Expected: PASS.
- [ ] **Step 5: Commit** — `git add Sources Tests && git commit -m "feat(remote): git, inspector, worktrees and deletion through ssh"`

### Task 9: UI — удалённый проект, SSH-хосты, проверка сервера и установка

**Files:**
- Create: `Sources/HangarUI/RemoteProjectSheet.swift`, `Sources/HangarUI/ServerCheckSheet.swift`, `Tests/HangarUITests/ServerCheckModelTests.swift`
- Modify: `Sources/HangarUI/SidebarView.swift` (слот `SSH HOSTS`), `Sources/HangarUI/SidebarRows.swift`, `Sources/HangarUI/MainWindow.swift` (`chooseProject` → меню «Локальная папка…» / «Удалённый (SSH)…» у `+`, ⌘⇧N и пустого экрана), `Sources/HangarUI/Actions.swift` (`reconnect`), `Sources/HangarUI/IntegrationSheet.swift` (`IntegrationPlan.displayPath: String?`), `Sources/HangarUI/IntegrationModel.swift`, `Sources/HangarUI/Icons.swift` (`sshHost`), `Sources/HangarUI/L10n.swift` + строки, `docs/design/DESIGN.md` (сайдбар: `SSH HOSTS`; листы «Удалённый проект» и «Сервер»)

**Interfaces:**
- Consumes: Task 5 (`ServerReport`, `installPlan`, `terminalScript`), Task 6 (`RemoteHosts`), Task 2 (`sshConfigHosts`, `sshWrite`, `remoteShellArgs`), `claudeInstall`/`codexInstall`/`claudeState`/`codexState`, `IntegrationSheet`, `TerminalSurfaceView(spec:)` + `onChildExit`.
- Produces:
  - `@MainActor @Observable final class ServerCheckModel { init(host: String, remote: RemoteHosts, run: @escaping (InstallStep, Data?) async -> RunResult); var report: ServerReport?; var plan: (steps: [InstallStep], manual: [RemoteTool]); var phase: Phase /* .checking, .ready, .installing, .failed(String) */; func refresh() async; func terminalSpec() -> LaunchSpec /* ssh -t … terminalScript */; func installFinished(code: Int32) async /* запись hangar-remote, если был в плане, затем recheck */; func integrationPlan(_ t: IntegrationTarget, install: Bool) async -> IntegrationPlan?; func applyIntegration(_ p: IntegrationPlan) async -> Bool }`. Файлы интеграций: `claude_dir/settings.json`, `codex_home/config.toml`. Чтение — `cat` через runner (код 1 и `No such file` → nil). Запись — `sshWrite` скриптом «сверить текущий с ожидаемым (`cmp`), иначе код 3 → `fileChanged`; `cp -p` в `<файл>.hangar-backup-<yyyyMMdd-HHmmss>`; temp + `mv`». `cli` = `home/.hangar/bin/hangar-remote`. `displayPath` = `host:path`.
  - **Лист «Удалённый проект»** (580, одна карточка): «Хост» — поле с выпадающим списком из `sshConfigHosts` (подсказка `user@host или имя из ~/.ssh/config`), «Путь» — моно-поле. Кнопка «Подключиться» → `remote.connect` (строка состояния «подключение…» / ошибка stderr моно `failed`, при `authFailed` — `sshAuthFailed`) → `cd <path> && pwd -P` через runner (`~/` раскрыт по `home`; ошибка → `remotePathMissing`) → встроенный отчёт `ServerCheckSheet` в том же листе. «Добавить» доступна, когда путь найден; отсутствующие инструменты её не блокируют. Добавление → `addRemoteProject(name: basename, host:, path:)`.
  - **Лист «Сервер <host>»** (580; открывается из строки хоста и из «Удалённый проект»). Карточка инструментов: строка на `git`, `tmux`, `claude`, `codex`, `hx`, «клиент сокета», `hangar-remote` — «есть · <версия>» `text2` / «нет» `failed` (обязательные) / «нет · необязательно» `text3`. Строки «Claude Code на сервере» / «Codex на сервере» — состояние + `SheetButton` «Установить…» → `IntegrationSheet`. Блок «План установки» — каждая `command` моно `small`, выделяемая, с переносом; `manual` — «Установите вручную: …»; подсказка `sudoHint`. «Отмена» / «Установить» (`primary`). «Установить» показывает в листе терминал 560×260 (`TerminalSurfaceView` с `terminalSpec()`), после выхода → `installFinished`. Без шагов — «Всё установлено». Предупреждения: нет клиента сокета → `noStatusClient`; `!forwarding` → `forwardFailed`.
  - **Сайдбар `SSH HOSTS`** (между закреплёнными и проектами; скрыт, если удалённых проектов нет): строка хоста — `Icon.sshHost` 13 pt, имя (моно нет, системный 13), справа `text3`: «подключён» / «подключение…» / «переподключение…» / «недоступен» / «не подключён». При `needsAttention` — точка `waiting` 7 pt. Клик и «…» → меню «Переподключиться» / «Проверить сервер» / «Отключиться». Задачи недоступного хоста серые (как у пропавшей папки), в их контекстном меню — `Action.reconnect` «Переподключиться» (включено, когда хост не `connected`).
  - L10n (ru/en): `addLocalProject` «Локальная папка…»/«Local folder…», `addRemoteProject` «Удалённый (SSH)…»/«Remote (SSH)…», `sectionSSHHosts` «SSH-ХОСТЫ»/«SSH HOSTS», `hostConnected` «подключён»/«connected», `hostConnecting` «подключение…»/«connecting…», `hostReconnecting` «переподключение…»/«reconnecting…», `hostUnreachable` «недоступен»/«unreachable», `hostDisconnected` «не подключён»/«not connected», `reconnect` «Переподключиться»/«Reconnect», `checkServer` «Проверить сервер»/«Check server», `disconnect` «Отключиться»/«Disconnect», `remoteProjectTitle` «Удалённый проект»/«Remote project», `hostLabel` «Хост»/«Host», `pathLabel` «Путь»/«Path», `hostPlaceholder` «user@host или имя из ~/.ssh/config»/«user@host or a name from ~/.ssh/config», `connect` «Подключиться»/«Connect», `add` «Добавить»/«Add», `remotePathMissing` «Папка не найдена на сервере»/«No such folder on the server», `serverTitle` «Сервер %@»/«Server %@», `toolFound` «есть · %@»/«found · %@», `toolMissing` «нет»/«missing», `toolOptional` «нет · необязательно»/«missing · optional», `socketClient` «клиент сокета»/«socket client», `installPlanTitle` «План установки»/«Install plan», `install` «Установить»/«Install», `installManual` «Установите вручную: %@»/«Install manually: %@», `allInstalled` «Всё установлено»/«Everything is installed», `sudoHint` «Пароль sudo вводится в терминале ниже — Hangar его не видит»/«Type the sudo password in the terminal below — Hangar never sees it», `noStatusClient` «Нет python3, socat или nc — статусов агентов с сервера не будет»/«No python3, socat or nc — no agent statuses from this server», `forwardFailed` «Сервер запретил проброс сокета — статусов агентов не будет»/«The server refused socket forwarding — no agent statuses», `sshAuthFailed` «Не удалось войти без пароля. Выполните ssh %@ в Терминале, затем «Переподключиться»»/«Could not log in without a password. Run ssh %@ in Terminal, then Reconnect», `remoteIntegration` «%@ на сервере»/«%@ on the server».

- [ ] **Step 1: Тесты** (RED, `ServerCheckModelTests`, фейк):
  - `cancelRunsNothing` — открыть модель, `refresh()`, закрыть без «Установить» → в логе фейка только проверка (одна команда с `serverCheckScript`), `run` вызван 0 раз.
  - `installRunsShownScript` — `terminalSpec().command` содержит `shellQuote(terminalScript(plan.steps))` дословно; `installFinished(0)` с шагом `hangar-remote` → `run` получил ровно этот шаг и `hangarRemoteScript` в stdin; в `<home фейка>/.hangar/bin/hangar-remote` текст скрипта, права 700; после recheck `remoteVersion == 1`, шагов нет.
  - `remoteIntegrationDiffAndWrite` — `integrationPlan(.claude, install: true)` при отсутствии файла → `original == nil`, `updated` содержит `hangar-remote' event prompt`, `displayPath` начинается с `dev:`; `applyIntegration` → файл записан; при изменении файла между планом и записью → false, ошибка `fileChanged`; существующий файл → рядом появилась `.hangar-backup-…`.
  - `L10nTests.allKeysHaveRuAndEn` — проходит.
- [ ] **Step 2:** Run: `swift test --filter "ServerCheckModelTests|L10nTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать** по Interfaces.
- [ ] **Step 4:** Run: `swift build && swift test --filter "ServerCheckModelTests|L10nTests|IntegrationModelTests|ActionsTests"` — Expected: PASS.
- [ ] **Step 5: Проверить вручную** (DEBUG, `HANGAR_SSH` = фейк из `Tests/ExecTests/FakeSSH.swift`, выложенный в `/tmp/hg-s6/`, `HANGAR_SSH_CONFIG` = temp-файл с `Host dev`, изолированные `HANGAR_STATE_DIR`/`HANGAR_CONFIG`). Проверить: `+` → меню из двух пунктов; лист «Удалённый проект» с хостом `dev` подключается и показывает отчёт; «Установить» показывает терминал с теми же командами, что в плане; `SSH HOSTS` с состоянием; курсор-рука; ширина 580 без переносов подписей. Сверить с DESIGN.md.
- [ ] **Step 6: Commit** — `git add Sources Tests docs/design && git commit -m "feat(remote): remote project sheet, SSH hosts in the sidebar, server check and install"`

### Task 10: Приёмка этапа

**Files:**
- Modify: `docs/decisions.md` (дополнения #47 по ходу, «Замеры» этапа 6), `docs/superpowers/stage1-followups.md` (разделы «Этап 6 — нужна проверка глазами» и «Отложено (этап 6)»), этот план (отметки)

- [ ] **Step 1:** Run: `swift build && swift test` — Expected: всё PASS, 2 прогона подряд (показать сводку).
- [ ] **Step 2: Сквозной сценарий без сети.** DEBUG-сборка, изолированные `HANGAR_STATE_DIR`/`HANGAR_CONFIG`, `HANGAR_SSH` = фейк из `/tmp/hg-s6` (home фейка — `/tmp/hg-s6/home`), `TMUX_TMPDIR=/tmp/hg-s6/tmux`, `HANGAR_DEBUG_NO_ACTIVATE=1`. Фейковый claude — `<home фейка>/bin/claude` (в PATH через `<home фейка>/.zprofile`): печатает `started`, шлёт `hangar-remote event prompt`, затем ждёт в `cat`. Шаги: добавить удалённый проект `dev:/tmp/hg-s6/repo` → отчёт (tmux есть, `hangar-remote` нет) → «Установить» → скрипт в `<home фейка>/.hangar/bin` → интеграция Claude через лист diff → создать задачу → вкладка claude в `working` (точка, ☕ и `pmset` по PID). `kill` мастера → полоса «Соединение прервано», статус `working`, `TMUX_TMPDIR=/tmp/hg-s6/tmux tmux ls` показывает `hangar-<leaf>`. Переподключение → тот же pane, `started` один раз. Changes показывает правку файла в репо после `done`. ⌘W вкладки → сессии нет. ⌘Q → сессии остальных листьев живы, после запуска — `attach`. Записать результаты.
- [ ] **Step 3: Энергия.** Подключённый хост, агенты в простое 3 мин, видимое не-key окно («Замеры», этап 5): `top -l 37 -s 5 -pid <pid> -stats pid,cpu` → 0,0 % (как этап 5); `pgrep -P <pid> -f ssh` — только мастер и вкладки, новых процессов за 3 мин 0; лог фейка за 3 мин не растёт. Хост «выключен» (файл `fail` = `refused`, приложение в фоне, `working` нет) → за 3 мин ни одной строки в логе фейка. Записать в «Замеры».
- [ ] **Step 4: Живой сервер — ручная проверка пользователя.** `ssh localhost` недоступен: Remote Login выключен, порт 22 не слушается, а включать его — менять настройку системы. Поэтому в `stage1-followups.md` «Этап 6 — нужна проверка глазами» вносятся пункты для настоящего хоста: подключение по имени из `~/.ssh/config`; проверка сервера на Linux (apt, `sudo` в терминале листа); `ssh -O forward -R` с `StreamLocalBindUnlink` по умолчанию; hooks Claude на сервере → статусы и лимиты; обрыв Wi-Fi и сон Mac → переподключение и `attach`; Helix `:open` через tmux (пауза 600 мс); `hx` на сервере с LSP; tmux старше 3.0; хост с fish в качестве логин-шелла. «Отложено (этап 6)» — список из Global Constraints.
- [ ] **Step 5: Commit** — `git add docs && git commit -m "docs: stage 6 acceptance"`
