# Hangar — этап 2 (worktree и полный лист новой задачи) — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Задача может работать в своём git worktree: лист новой задачи с переключателем Worktree, пикером базовой ветки с поиском, `git fetch` перед созданием и редактируемой новой веткой; вкладки задачи стартуют в папке worktree; «Удалить навсегда» может убрать worktree и ветку.

**Порядок:** 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 (2 и 3 независимы друг от друга, обе после 1).

**Architecture:** Новый модуль `Git` (только Foundation) вызывает `git` CLI через `Exec.Runner` — структуру с замыканием `run`; на этапе 2 есть только `Runner.local` (`Process`), этап 6 добавит `Runner.ssh(host:)` без смены сигнатур `Git`. Логика листа — `@Observable NewTaskModel` в `HangarUI` (тестируется на настоящих временных репозиториях), вид — SwiftUI. Модель `Workspace` получает поля проекта для worktree и `addTask(mode:)`.

**Tech Stack:** Swift 6.3, Swift Testing, AppKit + SwiftUI, `Process` + системный `git` (2.50 на машине), macOS 14+.

**Spec:** `docs/superpowers/specs/2026-10-18-hangar-design.md` (§2 `Git`/`Exec`, §3, §4 «Новая задача», §8, §10, §11 этап 2, §11.1). Решения — `docs/decisions.md` (#4, #5, #9, #10, #23, #36, #38, #39, #41; новое #42 — Task 1). Дизайн — `docs/design/DESIGN.md` («Лист новой задачи», «Раскладка», «Курсор»), макет `docs/superpowers/mockups/new-task-v4.html`. Правила — `AGENTS.md`.

## Global Constraints

- macOS 14+, Apple Silicon. `Git`, `Exec`, `Workspace` — без `AppKit`/`SwiftUI`; у `Git` — юнит-тесты на временных репозиториях (`git init` + bare-«origin»), без моков вывода git.
- `Process` + `git` CLI (не libgit2). Без новых зависимостей. Без протоколов с одной реализацией.
- Все команды git — массив аргументов, не строка shell (никакой подстановки имён в shell).
- Все строки UI — через `L10n` (ru + en, `L10nTests.allKeysHaveRuAndEn`); иконки — `enum Icon`; цвета/размеры — `Theme`, не литералами; `.pointingHand()` на всём кликабельном.
- Энергия: `git fetch` — только при открытии листа, по ↻ и перед созданием (если в этом открытии листа fetch ещё не прошёл); ноль таймеров и опросов. «обновлено N мин назад» пересчитывается только при перерисовке листа.
- Ошибка git → лист не закрывается, показывает stderr git (§8).
- Архив worktree не трогает (#39). «Удалить проект» worktree не трогает.
- Вне рамок: CLI/MCP (этап 5), инспектор Files/Changes и строка состояния (этап 4), git-действия (§1).

## Review Focus

1. **`git fetch` висит** (хост недоступен, ssh/https спрашивает пароль). Ожидание: git не ждёт ввода (`GIT_TERMINAL_PROMPT=0`, stdin `/dev/null`), отмена убивает процесс, лист показывает stderr и «Создать без fetch». Тесты — Task 1 `cancelTerminatesProcess`, Task 2 `fetchFailureCarriesStderr`.
2. **Папку worktree удалили руками**, потом «Удалить навсегда» с галочкой. Ожидание: `git worktree prune`, задача удаляется, ветка — `branch -d` как обычно, без ошибки «not a working tree». Тест — Task 7 `missingWorktreeFolderIsPruned`.
3. **Запомненная базовая ветка исчезла** (remote-ветку удалили). Ожидание: пикер выбирает ветку по умолчанию, создание не падает. Тест — Task 5 `staleLastBaseFallsBackToDefault`.
4. **Репозиторий без remote или без коммитов.** Ожидание: без remote fetch пропускается (нет подсказки «обновлено»), worktree создаётся от локальной ветки; без коммитов — переключатель Worktree выключен с подсказкой «в репозитории нет коммитов». Тесты — Task 2 `emptyRepoHasNoDefaultBranch`, Task 5 `noRemoteSkipsFetch`, `emptyRepoDisablesWorktree`.
5. **Папка worktree уже существует** (остаток старой задачи). Ожидание: лист остаётся открытым со stderr git, задача не создаётся, состояние не меняется. Тест — Task 5 `existingFolderKeepsSheetOpen`.

Плюс: путь проекта с пробелами и кириллицей — фикстура Task 2 создаёт репозитории в `…/проект с пробелом/`, все тесты `Git` и `NewTaskModel` идут через неё.

---

### Файловая структура

```
Package.swift                         + target Git (deps: Exec), testTarget GitTests; HangarUI deps += Git
Sources/Exec/Runner.swift             Runner, RunResult (local; форма под ssh этапа 6)
Sources/Git/Git.swift                 struct Git: команды git, Branch, GitError
Sources/Git/Naming.swift              branchSlug, worktreePath
Sources/Workspace/Model.swift         Project.worktreeByDefault/worktreeRoot, addTask(mode:), updateProject(...)
Sources/HangarUI/NewTaskModel.swift   логика листа (fetch, валидация, создание)
Sources/HangarUI/BranchPicker.swift   выпадающий список с поиском + branchPickerItems
Sources/HangarUI/NewTaskSheet.swift   вид листа (карточка Worktree / От ветки / Новая ветка)
Sources/HangarUI/TaskDeletion.swift   «Удалить навсегда» для worktree-задачи
Sources/HangarUI/ProjectSettingsSheet.swift  ветка по умолчанию (пикер), папка worktree
Tests/ExecTests/RunnerTests.swift
Tests/GitTests/{TempRepo.swift, GitTests.swift, NamingTests.swift}
Tests/HangarUITests/{NewTaskModelTests.swift, BranchPickerTests.swift, TaskDeletionTests.swift}
```

### Task 1: Решение #42, спека и `Exec.Runner`

**Files:**
- Create: `Sources/Exec/Runner.swift`, `Tests/ExecTests/RunnerTests.swift`
- Modify: `docs/decisions.md` (запись #42), `docs/superpowers/specs/2026-10-18-hangar-design.md` (§3, §4, §7, §8)

**Interfaces:**
- Produces:
  - `public struct RunResult: Equatable, Sendable { public var status: Int32; public var stdout: String; public var stderr: String }`
  - `public struct Runner: Sendable { public var run: @Sendable (_ args: [String], _ cwd: String) async throws -> RunResult; public init(run:); public static let local: Runner }`
  - `Runner.local`: `/usr/bin/env` + `args` (у приложения из Finder `/usr/bin` в PATH есть), `currentDirectoryURL = cwd`, env = окружение процесса + `GIT_TERMINAL_PROMPT=0`, stdin `FileHandle.nullDevice`. Ненулевой код — не ошибка (возвращается в `status`); `throws` — только если процесс не запустился или задача отменена (`CancellationError`, процесс получает `terminate()`).

- [x] **Step 1: Запись #42 в `decisions.md`** (формат журнала: решение, Почему, Отвергнуто). Содержание — решения контроллера этого плана: модуль `Git` поверх `Exec.Runner` (struct с замыканием, не протокол; `ssh` — этап 6); путь worktree `<родитель проекта>/<папка проекта>.worktrees/<slug ветки>`, настраивается в настройках проекта («Папка worktree»); slug (lowercase, транслит кириллицы по таблице Task 3, пробел и `/` → `-`, схлопывание `-`, пусто → `task`); новая ветка `--no-track` (не тянет upstream базы, `git push` не уйдёт в базовую ветку); переключатель Worktree запоминается по проекту (`Project.worktreeByDefault`), базовая ветка — `Project.lastBaseBranch`, её же правит «Ветка по умолчанию» в настройках проекта (`nil` = из `origin/HEAD`); «обновлено N мин назад» — по mtime `FETCH_HEAD` (учитывает и fetch из терминала, ничего не хранит); fetch — при открытии листа (фоном), по ↻, и перед созданием, если в этом открытии успешного fetch ещё не было; fetch только remote базовой ветки (для локальной базы — `origin`, нет remote — пропуск); архив worktree не трогает; «Удалить навсегда» — галочка «Также удалить worktree и ветку» (выкл.), грязный worktree — второе подтверждение, `--force` только после него, ветка — `branch -d` (не слита — сообщение, ветка остаётся); «Удалить из Hangar» worktree не трогает; не-git проект — строк worktree нет. Отвергнуто: протокол `GitRunner`, моки вывода git, `-D`, удаление worktree при архивации, опрос fetch.
- [x] **Step 2: Спека.** §3 Project: + «worktree по умолчанию (вкл/выкл), папка worktree (необязательно)». §4 «Новая задача»: ссылка на #42 (fetch, валидация `check-ref-format`, ошибка «ветка уже существует», не-git — строк нет). §7: `tasks archive` — «архивировать (worktree остаётся, #42)». §8: «нет коммитов → worktree недоступен; fetch не прошёл → stderr + «Создать без fetch»».
- [x] **Step 3: Тесты** (`RunnerTests`, RED): `runReturnsStatusAndOutput` (`["sh","-c","echo out; echo err >&2; exit 3"]` → `status == 3`, `stdout == "out\n"`, `stderr == "err\n"`); `runUsesCwd` (`["pwd"]` в temp-папке → stdout = её путь с `/private` префиксом допускается: сравнить `resolvingSymlinksInPath`); `largeOutputDoesNotDeadlock` (`["sh","-c","head -c 300000 /dev/zero | tr '\\0' a"]` → `stdout.count == 300000`); `noPromptEnv` (`["sh","-c","echo $GIT_TERMINAL_PROMPT"]` → `"0\n"`); `cancelTerminatesProcess` (`["sleep","30"]` в `Task`, `cancel()` через 0.2 с → бросает `CancellationError`, общее время < 3 с).
- [x] **Step 4:** Run: `swift test --filter RunnerTests` — Expected: FAIL (нет `Runner`).
- [x] **Step 5: Реализовать `Runner.local`.** stdout и stderr читать параллельно до выхода (иначе буфер пайпа 64 КБ блокирует процесс); ожидание выхода — `terminationHandler` + continuation внутри `withTaskCancellationHandler`.
- [x] **Step 6:** Run: `swift test --filter RunnerTests` — Expected: PASS.
- [x] **Step 7: Commit** — `git add Sources/Exec/Runner.swift Tests/ExecTests/RunnerTests.swift docs/decisions.md docs/superpowers/specs/2026-10-18-hangar-design.md && git commit -m "feat(exec): process runner for git; decision #42"`

### Task 2: Модуль `Git`

**Files:**
- Create: `Sources/Git/Git.swift`, `Tests/GitTests/TempRepo.swift`, `Tests/GitTests/GitTests.swift`
- Modify: `Package.swift` (`.target(name: "Git", dependencies: ["Exec"])`, `.testTarget(name: "GitTests", dependencies: ["Git", "Exec"])`, `HangarUI` deps += `"Git"`, `HangarUITests` deps += `"Git"`)

**Interfaces:**
- Consumes: `Runner`, `RunResult` (Task 1).
- Produces:
  - `public struct Branch: Equatable, Sendable { public var name: String /* "origin/main" | "main" */; public var isRemote: Bool; public var lastCommit: Date }`
  - `public struct GitError: Error, Equatable, Sendable { public var args: [String]; public var status: Int32; public var stderr: String /* trimmed */ }`
  - `public struct Git: Sendable { public init(repo: String, runner: Runner = .local) }` — все методы `async`, команды с cwd = `repo`:
    - `func isRepository() async -> Bool` — `rev-parse --is-inside-work-tree` = `true`
    - `func hasCommits() async -> Bool` — `rev-parse --verify --quiet HEAD`
    - `func currentBranch() async throws -> String?` — `symbolic-ref --quiet --short HEAD`; nil = detached
    - `func defaultBranch() async throws -> String?` — `symbolic-ref --quiet --short refs/remotes/origin/HEAD`, иначе первая существующая из `origin/main`, `origin/master`, `main`, `master`, иначе `currentBranch()`; nil — нет коммитов
    - `func listBranches() async throws -> [Branch]` — `for-each-ref --format=%(refname)%00%(symref)%00%(committerdate:unix) refs/remotes refs/heads`; символические ссылки (`origin/HEAD`) пропускаются; порядок: remote, затем local, внутри — `lastCommit` по убыванию
    - `func remotes() async throws -> [String]` — `remote`
    - `func fetch(remote: String) async throws` — `fetch --quiet <remote>`
    - `func lastFetch() async -> Date?` — mtime `FETCH_HEAD` в `rev-parse --git-common-dir` (относительный путь — от `repo`)
    - `func isValidBranchName(_ name: String) async -> Bool` — `check-ref-format --branch <name>`
    - `func addWorktree(path: String, newBranch: String, base: String) async throws` — `worktree add --no-track -b <newBranch> <path> <base>`
    - `func removeWorktree(path: String, force: Bool) async throws` — `worktree remove [--force] <path>`
    - `func pruneWorktrees() async throws` — `worktree prune`
    - `func isDirty(path: String) async throws -> Bool` — `status --porcelain` с cwd = `path`, непусто (неотслеживаемые файлы тоже грязь — их `worktree remove` тоже не удалит)
    - `func deleteBranch(_ name: String) async throws` — `branch -d <name>`
  - Ненулевой код любой команды, кроме «проверочных» (`isRepository`, `hasCommits`, `isValidBranchName`, `symbolic-ref`/`rev-parse --verify` внутри `defaultBranch`/`currentBranch`), → `GitError`.
- Фикстура `TempRepo` (тесты): папка `<tmp>/hangar-git-<uuid>/проект с пробелом/`; `origin.git` (bare), клон `repo` с коммитом в `main`, `push`; свой `git(_ args: String..., in:)` с env `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`, `GIT_AUTHOR/COMMITTER_NAME/EMAIL` и `-c commit.gpgsign=false` (настройки пользователя не влияют на фикстуру); `commit(file:on:)`, `pushBranch(_:)`, `cleanup()`.

- [x] **Step 1: Тесты** (`GitTests`, RED):
  - `defaultBranchFromOriginHead` — клон от bare: `defaultBranch() == "origin/main"`.
  - `defaultBranchFallsBackWithoutOriginHead` — после `git remote set-head origin -d`: `"origin/main"`; репо без remote с веткой `master`: `"master"`.
  - `emptyRepoHasNoDefaultBranch` — `git init` без коммитов: `defaultBranch() == nil`, `hasCommits() == false`, `listBranches().isEmpty`.
  - `listBranchesRemoteFirstWithoutHead` — запушена `release/2.4`, локальная `refactor-db` с более новым коммитом: имена == `["origin/main", "origin/release/2.4", …локальные…]` с remote впереди; нет `"origin/HEAD"`; `isRemote` верен; `lastCommit` > 0.
  - `fetchGetsNewRemoteBranch` — во втором клоне запушить `feat/x`; `fetch(remote: "origin")` → `listBranches()` содержит `origin/feat/x`; `lastFetch()` не nil и ≥ времени до fetch − 1 с.
  - `fetchFailureCarriesStderr` — `remote set-url origin /nonexistent/x.git`; `fetch` бросает `GitError` с `status != 0` и непустым `stderr`.
  - `addWorktreeCreatesBranchWithoutUpstream` — `addWorktree(path: <tmp>/проект с пробелом.worktrees/fix-login, newBranch: "fix-login", base: "origin/main")` → папка есть, `Git(repo: path).currentBranch() == "fix-login"`, `git config branch.fix-login.merge` пусто.
  - `addWorktreeExistingBranchFails` — второй `addWorktree` с той же веткой → `GitError`, stderr содержит `already exists`.
  - `branchNameValidation` — `"feat/ok"` true; `"bad..name"`, `"with space"`, `"end."`, `""` false.
  - `dirtyAndRemove` — чистый worktree: `isDirty == false`, `removeWorktree(force: false)` удаляет папку; новый worktree + неотслеживаемый файл: `isDirty == true`, `removeWorktree(force: false)` бросает, `force: true` удаляет.
  - `deleteBranchRefusesUnmerged` — ветка с коммитом, не слитым в `main`: `deleteBranch` бросает `GitError`, ветка на месте; слитая — удаляется.
  - `pruneForgetsDeletedFolder` — папку worktree удалить через `FileManager`; `pruneWorktrees()` → `git worktree list` её не содержит.
  - `nonRepository` — пустая temp-папка: `isRepository() == false`.
- [x] **Step 2:** Run: `swift test --filter GitTests` — Expected: FAIL (нет модуля `Git`).
- [x] **Step 3: Реализовать `Git`** по Interfaces.
- [x] **Step 4:** Run: `swift test --filter GitTests` — Expected: PASS. Run: `swift build` — Expected: собирается.
- [x] **Step 5: Commit** — `git add Package.swift Sources/Git Tests/GitTests && git commit -m "feat(git): git CLI module on temp-repo tests"`

### Task 3: Имя ветки и путь worktree

**Files:**
- Create: `Sources/Git/Naming.swift`, `Tests/GitTests/NamingTests.swift`

**Interfaces:**
- Produces:
  - `public func branchSlug(_ name: String) -> String` — lowercase; кириллица по таблице: а a, б b, в v, г g, д d, е e, ё e, ж zh, з z, и i, й y, к k, л l, м m, н n, о o, п p, р r, с s, т t, у u, ф f, х kh, ц ts, ч ch, ш sh, щ shch, ъ —, ы y, ь —, э e, ю yu, я ya; прочие буквы — `applyingTransform(.toLatin)` + `.stripDiacritics`; всё, кроме `[a-z0-9._]`, → `-`; `-` схлопываются; `-` и `.` по краям срезаются; пусто → `"task"`.
  - `public func worktreePath(projectPath: String, root: String?, branch: String) -> String` — `root` nil → `<dirname(projectPath)>/<basename(projectPath)>.worktrees/<branchSlug(branch)>`; иначе `<root>/<branchSlug(branch)>`. Хвостовой `/` у `projectPath` игнорируется.

- [x] **Step 1: Тесты** (RED): `slugCases` — таблица: `"Починить логин" → "pochinit-login"`, `"Rate limit / login" → "rate-limit-login"`, `"Щука  Ёж" → "shchuka-ezh"`, `"Объявления: Хабр" → "obyavleniya-khabr"`, `"fix: API v2.1" → "fix-api-v2.1"`, `"--Café--" → "cafe"`, `"!!!" → "task"`, `"feat/oauth" → "feat-oauth"`; `worktreePathDefault` — `("/u/dev/shop-api", nil, "feat/oauth") → "/u/dev/shop-api.worktrees/feat-oauth"`, то же с `"/u/dev/shop-api/"`; `worktreePathCustomRoot` — `("/u/dev/shop-api", "/tmp/wt", "Fix") → "/tmp/wt/fix"`.
- [x] **Step 2:** Run: `swift test --filter NamingTests` — Expected: FAIL.
- [x] **Step 3: Реализовать** `branchSlug`, `worktreePath`.
- [x] **Step 4:** Run: `swift test --filter NamingTests` — Expected: PASS.
- [x] **Step 5: Commit** — `git add Sources/Git/Naming.swift Tests/GitTests/NamingTests.swift && git commit -m "feat(git): branch slug and worktree path"`

### Task 4: Модель — поля проекта и задача с worktree

**Files:**
- Modify: `Sources/Workspace/Model.swift` (`Project`, `addTask`, `updateProject`), `Tests/WorkspaceTests/ModelTests.swift`, вызывающие `updateProject` / `addTask` (`Sources/HangarUI/MainWindow.swift`, `AppState.swift`, тесты)

**Interfaces:**
- Produces:
  - `Project.worktreeByDefault: Bool` (по умолчанию `false`), `Project.worktreeRoot: String?` (nil = путь по умолчанию Task 3); старый `state.json` без ключей читается с умолчаниями.
  - `addTask(projectId: UUID, name: String, mode: TaskMode = .mainFolder) -> UUID` — режим ставится до создания вкладок, поэтому `addTab`, `split`, `toggleDrawer` берут cwd = путь worktree (существующий `cwd(for:)`).
  - `updateProject(id: UUID, name: String, path: String, baseBranch: String?, worktreeRoot: String?)` — пустой `worktreeRoot` → nil; остальное как раньше.
  - `rememberNewTaskChoice(projectId: UUID, worktree: Bool, base: String?)` — `worktreeByDefault = worktree`; `base` не nil → `lastBaseBranch = base`.
  - `HangarTask.branch: String?` (computed) — ветка worktree-режима, иначе nil.

- [x] **Step 1: Тесты** (RED): `worktreeTaskLeavesUseWorktreePath` (`addTask(mode: .worktree(path: "/w/x", branch: "x", base: "origin/main"))` → `addTab`, `split`, `toggleDrawer` дают листья с `cwd == "/w/x"`, `branch == "x"`); `oldProjectWithoutWorktreeKeysDecodes` (JSON без ключей → `worktreeByDefault == false`, `worktreeRoot == nil`); `updateProjectSetsBaseAndRoot` (`baseBranch: "origin/dev", worktreeRoot: ""` → `lastBaseBranch == "origin/dev"`, `worktreeRoot == nil`); `updateProjectKeepsWorktreeCwds` (смена пути проекта не трогает cwd листьев worktree-задачи); `rememberNewTaskChoice` (worktree true + base nil → `lastBaseBranch` прежний).
- [x] **Step 2:** Run: `swift test --filter ModelTests` — Expected: FAIL.
- [x] **Step 3: Реализовать**; обновить вызывающих `updateProject` (лист настроек передаёт текущие значения до Task 8).
- [x] **Step 4:** Run: `swift test` — Expected: PASS (все цели).
- [x] **Step 5: Commit** — `git add Sources/Workspace Tests/WorkspaceTests Sources/HangarUI && git commit -m "feat(workspace): worktree fields on project, addTask(mode:)"`

### Task 5: Логика листа — `NewTaskModel`

**Files:**
- Create: `Sources/HangarUI/NewTaskModel.swift`, `Tests/HangarUITests/NewTaskModelTests.swift` (фикстура — копия подхода `TempRepo` из Task 2, тестовые цели не делятся кодом)
- Modify: `Sources/HangarUI/AppState.swift` (`createTask`), `Sources/HangarUI/L10n.swift` + `Resources/{ru,en}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `Git` (Task 2), `branchSlug`, `worktreePath` (Task 3), `Project.worktreeByDefault/worktreeRoot/lastBaseBranch`, `rememberNewTaskChoice`, `addTask(mode:)` (Task 4).
- Produces:
  - `@MainActor @Observable final class NewTaskModel { init(project: Project, git: Git, taskBranches: Set<String>) }`
    - Поля: `name: String`; `branch: String` (следует за `branchSlug(name)`, пока пользователь не правил; после правки — нет; очистка поля снова включает следование); `worktree: Bool` (из `worktreeByDefault`); `base: String?`; `branches: [Branch]`; `defaultBase: String?`; `currentBranch: String?`; `availability: Availability` (`.loading`, `.notRepository`, `.noCommits`, `.ready`); `fetch: FetchState` (`.idle`, `.running`, `.done`, `.failed(String)`, `.cancelled`, `.noRemote`); `lastFetch: Date?`; `branchError: String?`; `createError: String?` (stderr git); `creating: Bool`.
    - `func load() async` — `isRepository` → `hasCommits` → `listBranches`, `defaultBranch`, `currentBranch`, `lastFetch`; `base` = `lastBaseBranch`, если она есть в `branches`, иначе `defaultBase`; затем фоновый `refresh()`.
    - `func refresh() async` — fetch remote базы (`origin/x` → `origin`; локальная база → `origin`, если он есть; нет remote → `.noRemote`), затем перечитать `branches`, `lastFetch`. Повторный вызов во время `.running` ничего не делает.
    - `func validateBranch() async` — пусто → `L10n.branchRequired`; `isValidBranchName == false` → `L10n.branchInvalid`; есть локальная ветка с этим именем → `L10n.branchExists(name)`; иначе nil.
    - `func create(skipFetch: Bool) async -> TaskMode?` — без worktree → `.mainFolder`; с worktree: ждёт/запускает fetch, если в этом открытии ещё не было `.done` и не `skipFetch` (`.failed`/`.cancelled` → nil, лист показывает stderr и «Создать без fetch»), валидирует ветку, `addWorktree(path: worktreePath(...), newBranch: branch, base: base)`; `GitError` → `createError = stderr`, nil; успех → `.worktree(path:branch:base:)`.
    - `func cancelFetch()` — отменяет текущий fetch (`Task.cancel`), `fetch = .cancelled`.
    - `var canCreate: Bool` — имя не пусто, не `creating`; при worktree — `availability == .ready`, `base != nil`, `branchError == nil`.
  - `AppState.createTask(projectId: UUID, name: String, firstMessage: String, mode: TaskMode)` — `addTask(mode:)`, вкладка агента по умолчанию, `rememberNewTaskChoice(worktree: mode != .mainFolder, base: <base из mode>)`.
  - `taskBranches` — ветки worktree-задач проекта (для метки «задача» в пикере).
- L10n (ru / en): `branchRequired` «Введите имя ветки» / «Enter a branch name»; `branchInvalid` «Недопустимое имя ветки» / «Invalid branch name»; `branchExists` «Ветка «%@» уже существует» / «Branch “%@” already exists»; `fetchFailed` «git fetch не удался» / «git fetch failed»; `createWithoutFetch` «Создать без fetch» / «Create without fetch»; `fetchCancelled` «fetch отменён» / «fetch cancelled»; `noCommits` «в репозитории нет коммитов» / «the repository has no commits».

- [x] **Step 1: Тесты** (`NewTaskModelTests`, RED, настоящие temp-репозитории):
  - `branchFollowsNameUntilEdited` — `name = "Починить логин"` → `branch == "pochinit-login"`; `branch = "feat/login"`, `name = "x"` → `branch == "feat/login"`; `branch = ""`, `name = "y"` → `"y"`.
  - `defaultsFromProject` — `worktreeByDefault == true` → `worktree == true`; `lastBaseBranch == "origin/release"` (существует) → `base == "origin/release"`.
  - `staleLastBaseFallsBackToDefault` — `lastBaseBranch = "origin/gone"` → после `load()` `base == "origin/main"`.
  - `existingBranchIsRejected` — локальная `fix` есть; `branch = "fix"` → `validateBranch()` → `branchError == L10n.branchExists("fix")`, `canCreate == false`; `"bad..x"` → `L10n.branchInvalid`.
  - `createMakesWorktreeFromBase` — `create(skipFetch: false)` → `.worktree(path: <…>.worktrees/pochinit-login, branch: "pochinit-login", base: "origin/main")`, папка существует, `fetch == .done`.
  - `fetchFailureBlocksUntilSkip` — origin → `/nonexistent`; `create(skipFetch: false) == nil`, `fetch` = `.failed(stderr)` с непустым текстом, папки нет; `create(skipFetch: true)` → `.worktree`.
  - `existingFolderKeepsSheetOpen` — папка цели создана заранее с файлом; `create` → nil, `createError` непуст (stderr git), `AppState.state` не изменился.
  - `noRemoteSkipsFetch` — репо без remote, база `main`: `fetch == .noRemote` после `load()`, `create` → `.worktree(... base: "main")`.
  - `emptyRepoDisablesWorktree` — `git init` без коммитов: `availability == .noCommits`, при `worktree = true` `canCreate == false`; при `worktree = false` и имени → `canCreate == true`.
  - `nonRepositoryHidesWorktree` — обычная папка: `availability == .notRepository`, `create` → `.mainFolder`.
  - `createTaskRemembersChoice` (`AppState`) — `createTask(…, mode: .worktree(…, base: "origin/dev"))` → проект `worktreeByDefault == true`, `lastBaseBranch == "origin/dev"`, cwd листа агента = путь worktree, задача выбрана.
- [x] **Step 2:** Run: `swift test --filter "NewTaskModelTests|L10nTests"` — Expected: FAIL.
- [x] **Step 3: Реализовать** `NewTaskModel`, `AppState.createTask(mode:)`, строки L10n.
- [x] **Step 4:** Run: `swift test --filter "NewTaskModelTests|L10nTests|ActionsTests"` — Expected: PASS.
- [x] **Step 5: Commit** — `git add Sources/HangarUI Tests/HangarUITests && git commit -m "feat(ui): new-task model — fetch, branch validation, worktree create"`

### Task 6: Лист новой задачи — вид, пикер ветки, ветка в заголовке

**Files:**
- Create: `Sources/HangarUI/BranchPicker.swift`, `Tests/HangarUITests/BranchPickerTests.swift`
- Modify: `Sources/HangarUI/NewTaskSheet.swift`, `Sources/HangarUI/MainWindow.swift` (`presentNewTask`), `Sources/HangarUI/TabBarView.swift` (`TitleBarView`), `Sources/HangarUI/Theme.swift`, `Sources/HangarUI/Icons.swift` (`Icon.refresh`), `Sources/HangarUI/L10n.swift` + `.strings`

**Interfaces:**
- Consumes: `NewTaskModel` (Task 5), `Branch` (Task 2), `HangarTask.branch` (Task 4).
- Produces:
  - `struct BranchPickerItem: Equatable { var branch: Branch; var meta: Meta; enum Meta: Equatable { case isDefault, task, age(Date) } }`
  - `func branchPickerItems(_ branches: [Branch], query: String, defaultBase: String?, taskBranches: Set<String>) -> (remote: [BranchPickerItem], local: [BranchPickerItem])` — фильтр по подстроке без учёта регистра; ветка по умолчанию первой в remote; остальное — порядок `listBranches`; meta: `isDefault` > `task` (локальная ветка worktree-задачи) > `age`.
  - `func ageLabel(since: Date, now: Date) -> String` — `< 1 мин` → `L10n.justNow`; `< 60 мин` → `L10n.minutesAgo(n)`; `< 24 ч` → `L10n.hoursAgo(n)`; иначе `L10n.daysAgo(n)` (сокращения без склонений, копия — в тесте `ageLabels`). Используется и для «обновлено …» (`L10n.updatedAgo(ageLabel)`), и для меты ветки.
  - `struct BranchPicker: View { @Binding var selection: String?; let branches: [Branch]; let defaultBase: String?; let taskBranches: Set<String>; let defaultOption: String? /* Task 8: «по умолчанию (origin/HEAD)» = nil */ }`
- Вид (DESIGN.md «Лист новой задачи», макет v4): карточка строк «подпись 110 → значение» (`Theme.cardRow*`, разделители `lineSheet`, радиус 8):
  - Worktree: подсказка `L10n.worktreeOnHint` «отдельная папка и ветка» / «separate folder and branch» или `worktreeOffHint` «работать в основной папке» / «work in the main folder», справа `Toggle(.switch)`; при `.noCommits` — выключен, подсказка `L10n.noCommits`.
  - От ветки: кнопка-пикер `⎇ origin/main ▾` (моно) → popover (SwiftUI `.popover`, радиус 9, тень по DESIGN.md): поле поиска с фокусом (`L10n.searchBranches` «поиск ветки» / «search branches»), секции `L10n.branchesRemote` / `L10n.branchesLocal` («remote» / «local» в обоих языках, `text3`), строки с метой справа (`L10n.branchDefault` «по умолчанию» / «default», `L10n.branchTask` «задача» / «task», возраст); ↑/↓ — по строкам через обе секции, ↩ — выбрать и закрыть, Esc — закрыть popover (не лист), клик — выбрать. Рядом — `L10n.updatedAgo` «обновлено %@» / «updated %@» по `lastFetch`, спиннер (`ProgressView().controlSize(.small)`) при `.running`, кнопка ↻ (`Icon.refresh` — новый case, `arrow.clockwise`) → `refresh()`. `.noRemote` — без подсказки.
  - Новая ветка: моно-поле с `branch`, подсказка `L10n.fromName` «из названия» / «from the name», пока следует за именем; `branchError` — строкой `failed` под карточкой.
  - Без worktree строки веток — новый `Theme.dimmedRowOpacity` (0.38), неактивны, «Новая ветка» — `—`; футер слева `L10n.currentBranch` «текущая ветка: %@» / «current branch: %@» (из `currentBranch`), с worktree — `esc — отмена`.
  - `.notRepository` — строк карточки нет вовсе (карточка скрыта), лист как на этапе 1.
  - Ошибка fetch / создания — блок под карточкой: заголовок `fetchFailed` или stderr (моно, `failed`, до 6 строк, выделяемый текст) + при ошибке fetch кнопки «Повторить» (`L10n.retry`) и «Создать без fetch». Во время fetch-перед-созданием на «Создать» — спиннер, Esc / «Отмена» отменяет fetch (лист остаётся, `fetchCancelled` + «Создать без fetch»); второй Esc закрывает лист.
  - Всё кликабельное — `.pointingHand()`; новые размеры (ширина подписи 110, радиус выпадающего 9, высота строки списка, макс. высота списка 260) — в `Theme`.
- `presentNewTask`: создаёт `NewTaskModel(project:git: Git(repo: project.path), taskBranches:)`, `Task { await model.load() }`; `onCreate(mode)` закрывает лист и вызывает `AppState.createTask(…, mode:)`; закрытие листа отменяет фоновый fetch.
- `TitleBarView`: у worktree-задачи после иконки — `task.branch` моно `text3` (`Theme.fontSize.tab`).

- [x] **Step 1: Тесты** (`BranchPickerTests`, RED): `itemsRemoteFirstDefaultOnTop` (ветки `origin/feat` (новее), `origin/main`, `refactor-db`; default `origin/main` → `remote.map(\.branch.name) == ["origin/main", "origin/feat"]`, `remote[0].meta == .isDefault`, `local[0].meta == .age(...)`); `queryFiltersCaseInsensitive` (`"FEAT"` → только `origin/feat`, `local` пуст); `taskBranchMeta` (`taskBranches = ["refactor-db"]` → `local[0].meta == .task`); `ageLabels` (ru: 30 с → «только что», 2 мин → «2 мин назад», 3 ч → «3 ч назад», 3 дн → «3 дн назад»; en: «just now», «2 min ago», «3 h ago», «3 d ago»).
- [x] **Step 2:** Run: `swift test --filter "BranchPickerTests|L10nTests"` — Expected: FAIL.
- [x] **Step 3: Реализовать** `branchPickerItems`, `ageLabel`, `BranchPicker`, новый вид `NewTaskSheet` (принимает `NewTaskModel`, `onCreate: (String, String, TaskMode) -> Void`), `Icon.refresh`, строки, ветку в `TitleBarView`.
- [x] **Step 4:** Run: `swift test` — Expected: PASS.
- [x] **Step 5: Проверить вручную** (`scripts/bundle.sh && open build/Hangar.app`, проект — git-репо с `origin`): лист ⌘N сверить с макетом v4 (оба состояния); пикер — поиск, ↑/↓/↩/Esc, секции, меты; «обновлено N мин назад» и ↻; создать задачу с worktree → папка `<проект>.worktrees/<slug>`, вкладка claude в ней (`pwd` в ⌘T), иконка worktree в сайдбаре, ветка в заголовке; выключить сеть → ошибка fetch со stderr, «Создать без fetch» работает; существующая ветка → ошибка у поля; не-git папка → строк нет; переоткрыть лист → переключатель и база запомнены. Записать «Нужна проверка глазами».
- [x] **Step 6: Commit** — `git add Sources/HangarUI Tests/HangarUITests && git commit -m "feat(ui): new-task sheet with worktree, branch picker and fetch"`

### Task 7: «Удалить навсегда» для worktree-задачи

**Files:**
- Create: `Sources/HangarUI/TaskDeletion.swift`, `Tests/HangarUITests/TaskDeletionTests.swift`
- Modify: `Sources/HangarUI/Actions.swift` (`ActionContext`, `.deletePermanently`), `Sources/HangarUI/MainWindow.swift` (реализация нового замыкания), `Sources/HangarUI/L10n.swift` + `.strings`

**Interfaces:**
- Consumes: `Git.isDirty/removeWorktree/pruneWorktrees/deleteBranch` (Task 2), `HangarTask.branch` (Task 4), `deleteTask(id:)`.
- Produces:
  - `ActionContext.confirmWithCheckbox: (_ message: String, _ info: String, _ button: String, _ checkbox: String, _ then: @escaping (Bool) -> Void) -> Void` — `NSAlert` с `showsSuppressionButton = true`, заголовок галочки `checkbox`, по умолчанию снята; `then(checked)` — только при подтверждении.
  - `@MainActor func deleteTaskPermanently(_ id: UUID, alsoWorktree: Bool, ctx: ActionContext, git: Git) async` — порядок: без галочки → `deleteTask`; с галочкой: папки нет → `pruneWorktrees`; есть → `isDirty` → грязно: `ctx.confirm(L10n.worktreeDirty, L10n.worktreeDirtyInfo, L10n.deleteAnyway)` (отмена — ничего не меняется, задача остаётся), затем `removeWorktree(force: dirty)`; ошибка `removeWorktree` → `ctx.showError(L10n.worktreeRemoveFailed, stderr)`, задача остаётся; успех → `deleteTask`, затем `deleteBranch` → ошибка → `ctx.showError(L10n.branchKept(branch), stderr)` (задача уже удалена, ветка цела).
  - `.deletePermanently`: у `.mainFolder`-задачи — прежний `confirm`; у worktree — `confirmWithCheckbox(…, L10n.alsoDeleteWorktree)`, затем `Task { await deleteTaskPermanently(...) }` с `Git(repo: project.path)`.
- L10n (ru / en): `alsoDeleteWorktree` «Также удалить worktree и ветку» / «Also delete the worktree and branch»; `worktreeDirty` «В worktree есть незакоммиченные изменения» / «The worktree has uncommitted changes»; `worktreeDirtyInfo` «Они будут потеряны.» / «They will be lost.»; `deleteAnyway` «Удалить всё равно» / «Delete anyway»; `worktreeRemoveFailed` «Не удалось удалить worktree» / «Couldn't remove the worktree»; `branchKept` «Ветка «%@» не слита — оставлена» / «Branch “%@” is not merged — kept».
- `deleteTaskInfo` для worktree-задачи: прежний текст (файлы не трогаются, если галочка снята).

- [x] **Step 1: Тесты** (`TaskDeletionTests`, RED; temp-репо + `ActionContext` с фейковыми `confirm`/`showError`, записывающими вызовы):
  - `withoutCheckboxKeepsWorktreeAndBranch` — `alsoWorktree: false` → задачи нет в состоянии, папка worktree и ветка на месте, `git` не вызывался для удаления.
  - `cleanWorktreeAndMergedBranchRemoved` — папки нет, `git branch --list x` пусто, `confirm` не вызывался.
  - `dirtyAsksThenForces` — неотслеживаемый файл; фейк `confirm` подтверждает → папки нет, задачи нет; фейк отклоняет → папка, ветка и задача на месте.
  - `unmergedBranchIsKept` — коммит в ветке worktree → задачи и папки нет, ветка есть, `showError` вызван с `L10n.branchKept("x")`.
  - `missingWorktreeFolderIsPruned` — папку удалить через `FileManager` → задачи нет, `git worktree list` без неё, ветка удалена `-d` (не было коммитов), `showError` не вызван.
  - `archiveAndRemoveProjectKeepWorktree` — `archive` и `removeProject` для worktree-задачи → папка и ветка на месте.
  - `actionUsesCheckboxForWorktreeTask` (в `ActionsTests`) — `.deletePermanently` для архивной worktree-задачи вызывает `confirmWithCheckbox`, для `.mainFolder` — `confirm`.
- [x] **Step 2:** Run: `swift test --filter "TaskDeletionTests|ActionsTests|L10nTests"` — Expected: FAIL.
- [x] **Step 3: Реализовать** `deleteTaskPermanently`, `confirmWithCheckbox` в `ActionContext` и `MainWindowController`, строки.
- [x] **Step 4:** Run: `swift test --filter "TaskDeletionTests|ActionsTests|L10nTests"` — Expected: PASS.
- [x] **Step 5: Commit** — `git add Sources/HangarUI Tests/HangarUITests && git commit -m "feat(ui): delete worktree task with optional worktree and branch removal"`

### Task 8: Настройки проекта — ветка по умолчанию и папка worktree

**Files:**
- Modify: `Sources/HangarUI/ProjectSettingsSheet.swift`, `Sources/HangarUI/MainWindow.swift` (`presentProjectSettings`), `Sources/HangarUI/L10n.swift` + `.strings` (удалить `defaultBranchLater`), `Tests/HangarUITests/ActionsTests.swift`

**Interfaces:**
- Consumes: `BranchPicker` (Task 6), `Git.listBranches/defaultBranch/isRepository` (Task 2), `worktreePath` (Task 3), `updateProject(id:name:path:baseBranch:worktreeRoot:)` (Task 4).
- Produces: `ProjectSettingsSheet(project:git:onSave: (_ name: String, _ path: String, _ baseBranch: String?, _ worktreeRoot: String?) -> Void, onCancel:)`.
- «Ветка по умолчанию»: `BranchPicker` с первым пунктом `L10n.branchAuto` «по умолчанию (%@)» / «default (%@)» (подставлено значение `defaultBranch()`) = nil; ветки читаются при открытии без fetch. Не-git проект — строка «Ветка по умолчанию» и «Папка worktree» скрыты.
- «Папка worktree» (`L10n.worktreeFolder` «Папка worktree» / «Worktree folder»): моно-поле + «Выбрать…» (`NSOpenPanel`, можно создать папку); плейсхолдер — каталог по умолчанию (`dirname(worktreePath(projectPath:root:nil, branch:"x"))`); пусто → nil; `~` раскрывается; относительный путь — ошибка `L10n.pathMustBeAbsolute` «Нужен абсолютный путь» / «Use an absolute path», лист не сохраняется. Несуществующая папка допустима (git создаст).
- Смена пути не переносит существующие worktree-задачи (их `mode.path` остаётся).

- [x] **Step 1: Тест** (RED): `worktreeRootInputValidation` — вынести проверку пути в `func worktreeRootInput(_ text: String) -> Result<String?, String>` (в `ProjectSettingsSheet.swift`): `""` → `.success(nil)`, `"~/wt"` → `.success(<home>/wt)`, `"wt"` → `.failure(L10n.pathMustBeAbsolute)`.
- [x] **Step 2:** Run: `swift test --filter "ActionsTests|L10nTests"` — Expected: FAIL.
- [x] **Step 3: Реализовать** лист, `presentProjectSettings` (передаёт `Git(repo: project.path)`, сохраняет через `updateProject`).
- [x] **Step 4:** Run: `swift test` — Expected: PASS.
- [x] **Step 5: Проверить вручную:** выбрать ветку по умолчанию → новый лист предлагает её; «по умолчанию (origin/main)» → снова `origin/HEAD`; своя папка worktree → новая задача создаётся там; не-git проект — строк нет.
- [x] **Step 6: Commit** — `git add Sources/HangarUI Tests/HangarUITests && git commit -m "feat(ui): project settings — default base branch and worktree folder"`

### Task 9: Приёмка этапа

**Files:**
- Modify: `docs/decisions.md` (если что-то в ходе этапа менялось — новая запись или дополнение #42), `docs/superpowers/plans/2026-10-19-hangar-stage2.md` (отметки, «Нужна проверка глазами»)

- [x] **Step 1:** Run: `swift build && swift test` — Expected: всё PASS (показать сводку).
- [x] **Step 2: Сценарий вручную** (`scripts/bundle.sh && open build/Hangar.app`): задача с worktree → 3 вкладки (claude, ⌘T, сплит) и нижняя панель — все в папке worktree; ⌘Q → открыть → задача и вкладки в worktree восстановлены (`--continue` в cwd worktree); архив → папка на месте; восстановить → работает; архив → «Удалить навсегда» без галочки → папка на месте; с галочкой на грязном worktree → второе подтверждение; ветка с коммитами → сообщение «не слита — оставлена»; «Удалить из Hangar» → worktree на диске.
- [ ] **Step 3: Энергия.** (debug ~2 мин: 0,0 % CPU, 52 МБ — см. decisions «Замеры»; release 5 мин — вручную) Лист закрыт, приложение в простое 5 минут: `top -l 2 -s 5 -pid $(pgrep -x Hangar) -stats pid,cpu | tail -1` — Expected: CPU < 1%; `ps -o pid,command -g $(pgrep -x Hangar) | grep -c git` — Expected: `0` (нет висящих git).
- [x] **Step 4: Commit** — `git add docs && git commit -m "docs: stage 2 acceptance checklist"`

### Нужна проверка глазами (этап 2)

Не проверяется тестами и автоматикой; проверяет пользователь:

- [ ] Реальный NSPopover пикера ветки: позиция, Esc, клавиатура (↑/↓/Enter).
- [ ] Оттенок переключателя Worktree (tint) в листе.
- [ ] Приглушённые курсоры (pointing hand отключён у выключенных контролов).
- [ ] Не-git карточка: нет «прыжка» высоты листа.
- [ ] Алерт «Создаётся worktree…» закрывается вместе с листом.
- [ ] Отрисовка чекбокса в NSAlert «Удалить навсегда».
- [ ] Release-сборка: idle CPU 5 минут (`top -l 2 -s 5 -pid $(pgrep -x Hangar) -stats pid,cpu | tail -1`, < 1 %).
