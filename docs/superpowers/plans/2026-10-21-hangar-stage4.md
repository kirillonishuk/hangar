# Hangar — этап 4 (инспектор: Files / Changes / read-only diff / открытие в Helix) — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Справа от области задачи — инспектор (`⌘⌥I`, ширина сохраняется) с сегментами `Files` (дерево с учётом `.gitignore`, бейджи M/A/D/?/R, клик — файл в Helix) и `Changes N` (файлы с `+N −M` относительно merge-base с базовой веткой или только незакоммиченное по `⌥B`; клик — временная diff-вкладка с unified diff, `↑/↓` — соседний файл, `↩` — Helix на строке). Обновление — FSEvents видимой задачи, без опроса.

**Порядок:** 1 → 2 → 5 → 6 → 7 → 8 → 9. Задача 3 независима; 4 — после 3; 8 — после 2, 4, 7.

**Architecture:** `Git` (UI-free) получает чтение для инспектора: `status` (porcelain v2), `listFiles` (`ls-files`), `changedFiles`, `diff` с чистым парсером unified diff — всё через `Runner`, чтобы на этапе 6 подменить исполнителя на ssh. В `HangarUI` — `InspectorModel` (одна на видимую задачу: загрузка, отмена, состояние diff), `FileTree` (ленивое построение строк), `FileWatcher` (FSEvents), `InspectorView` (SwiftUI, третий элемент `NSSplitViewController`), временная diff-вкладка в памяти `AppState` и `DiffView`. Открытие в Helix — `EditorOpener` (чистые правила) + `TerminalSurfaceView.sendKey` в `GhosttyBridge`.

**Tech Stack:** Swift 6.3, Swift Testing, AppKit + SwiftUI, CoreServices FSEvents, `git` CLI через `Exec.Runner`, macOS 14+.

**Spec:** `docs/superpowers/specs/2026-10-18-hangar-design.md` (§2 `Git`, §3 diff-вкладка временная, §4 «Инспектор», §8 «нет git», §9 FSEvents + debounce 300 мс только для видимой задачи, §11 этап 4, §11.1 git через `Exec`). Решения — `docs/decisions.md` (#6 только просмотр, #23 только unified, #34 шкала шрифтов, #38 L10n, #39 реестр действий и шорткаты по keyCode, #41 запуск листа, #42 `Git` поверх `Runner`; новое #44 — Task 1). Дизайн — `docs/design/DESIGN.md` («Git и diff», «Сегмент», «Дерево файлов», «Diff», «Инспектор справа: ширина 220», моно-шрифт, курсор), макет `docs/superpowers/mockups/style-a-v2.html` (экран 1 — Files, экран 2 — diff + Changes). Правила — `AGENTS.md`.

## Global Constraints

- macOS 14+, Apple Silicon. Без новых зависимостей (tree-sitter не подключается — #44). `Git` — без `AppKit`/`SwiftUI`, тесты на настоящих временных репозиториях (`Tests/GitTests/TempRepo.swift`, путь с пробелом и кириллицей), без моков вывода git.
- Только чтение (#6): ни одной команды, меняющей репозиторий. Все команды инспектора идут как `git --no-optional-locks …` (иначе `status`/`diff` переписывают `.git/index` → FSEvents → бесконечный цикл обновлений).
- Вывод git — только машинный: `-z` везде, где есть пути; `--no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ --find-renames` у `diff`; `--untracked-files=all --find-renames` у `status` (пользовательские `status.showUntrackedFiles`, `diff.external`, `diff.noprefix`, `color.ui=always` не влияют). Пути — после `--`.
- Данные git — только через `Git`/`Runner`, не чтением `.git` с диска. `FileManager` — только для дерева не-git локального проекта (`// shortcut: локальный FileManager, этап 6 — через Exec`).
- Лимиты: `status` и `changedFiles` — до 5 000 записей (дальше `truncated`); `listFiles` — до 200 000 путей (дальше `truncated`); ≥ 50 000 путей — дерево не раскрывается автоматически; diff файла > 20 000 изменённых строк (по `--numstat`) — состояние «слишком большой diff» без загрузки текста.
- Энергия: ноль таймеров и опросов. FSEvents — только корень видимой задачи и её git-dir, только пока инспектор показан и окно не перекрыто/не свёрнуто; `latency` потока 0.3 с. git — вне main (nonisolated async через `Runner`), одна загрузка на контекст.
- Все строки — через `L10n` (ru + en, `L10nTests.allKeysHaveRuAndEn`); иконки — `enum Icon`; цвета/размеры — `Theme`; `.pointingHand()` на всём кликабельном; шорткаты — по keyCode (`⌥B` = option + 11, `↑` 126, `↓` 125, `↩` 36).
- Diff-вкладка временная: не попадает в `state.json` и `WorkspaceState`, не восстанавливается.
- Вне рамок: подсветка синтаксиса (#44), split-diff (#23), строка состояния (`+N −M · K файлов` — отдельно, см. Task 9), `⌘K/⌘P`, ssh-проекты (этап 6), любые git-действия.

## Review Focus

1. **Самоподпитывающийся цикл обновлений.** `git status` без `--no-optional-locks` перезаписывает `.git/index` → событие FSEvents → снова `status` → … CPU не падает до нуля. Ожидание: команды инспектора не меняют mtime `.git/index`; события в `objects/`, `logs/`, `*.lock` не вызывают обновления. Тесты — Task 1 `inspectorCommandsDoNotWriteIndex`, Task 6 `classifyGitInternals`.
2. **Особые пути.** Пробел, кириллица, `'`, `` ` ``, `"`, `%`, ведущий `-`, переименование в каталог с пробелом. Ожидание: Files/Changes показывают имена как есть, diff открывается, Helix открывает тот же файл (или, если путь нельзя безопасно записать в командной строке Helix, — новая editor-вкладка). Тесты — Task 1 `statusParsesSpecialPaths`, Task 2 `renameWithSpaces`, Task 4 `helixQuoting`.
3. **Содержимое diff, похожее на заголовки.** Удалённая строка `-- comment`, добавленная `++ x`, строка `@@ fake @@` внутри ханка, `\ No newline at end of file`; бинарный файл, 25 000 строк, только смена режима, удалённый файл. Ожидание: парсер верит счётчикам ханка, номера строк верные; бинарный/большой/режим — отдельные состояния, без зависания. Тесты — Task 2 `parserTrustsHunkCounts`, `diffStates`.
4. **Клавиши, украденные у терминала.** `⌥B` в zsh — слово назад; `↑/↓/↩` нужны агенту и шеллу. Ожидание: Hangar перехватывает `↑/↓/↩/⌥B` только когда активна diff-вкладка выбранной задачи и фокус не в поле ввода, иначе клавиша уходит в терминал. Тест — Task 8 `diffKeyRoute`.
5. **Устаревшие и «голодные» обновления.** Агент пишет файлы непрерывно, git медленный; переключение задачи посреди загрузки. Ожидание: обновление того же контекста не отменяется новыми событиями (доводится и повторяется один раз), смена задачи/режима отменяет загрузку, результат старой задачи никогда не показывается. Тесты — Task 5 `contextSwitchCancelsAndDropsStale`, `burstCoalescesWithoutStarvation`.

Плюс: репозиторий без коммитов и удалённая базовая ветка — Task 2 `noCommitsAndMissingBase`; worktree (`.git` — файл, index в `<common>/worktrees/<name>`) — Task 6 `watchPathsForWorktree`.

---

### Файловая структура

```
Sources/Git/Git+Inspect.swift          toplevel, gitDir, status, listFiles, changedFiles, diff (через Runner)
Sources/Git/GitParse.swift             чистые парсеры: porcelain v2, name-status/numstat -z, unified diff
Sources/Workspace/Model.swift          inspectorWidth, Leaf.openLine, addTab(openFile:openLine:), setOpenFile
Sources/Exec/Launch.swift              редактор с файлом и строкой (hx path:N, nvim +N path), isHelix
Sources/GhosttyBridge/TerminalSurfaceView.swift   sendKey(.escape | .colon)
Sources/HangarUI/EditorOpener.swift    helixQuoted, helixCommands, editorRoute
Sources/HangarUI/FileTree.swift        индекс каталогов, видимые строки
Sources/HangarUI/InspectorModel.swift  загрузка Files/Changes/diff, отмена, режим ⌥B
Sources/HangarUI/FileWatcher.swift     FSEvents + классификация событий
Sources/HangarUI/InspectorView.swift   сегмент, дерево, список изменений, подсказки
Sources/HangarUI/AppState+Diff.swift   временная diff-вкладка (в памяти)
Sources/HangarUI/DiffView.swift        строки diff, выбор строки
```

### Task 1: Решение #44, спека, `Git.status` и `Git.listFiles`

**Files:**
- Create: `Sources/Git/Git+Inspect.swift`, `Sources/Git/GitParse.swift`, `Tests/GitTests/InspectTests.swift`
- Modify: `docs/decisions.md` (#44), `docs/superpowers/specs/2026-10-18-hangar-design.md` (§4 «Инспектор»: tree-sitter → «подсветка синтаксиса отложена (#44)»; ⌥B — только при активной diff-вкладке, иначе клик по подсказке под Changes; §9 — `latency` 0.3 с и правило коалесцирования), `docs/design/DESIGN.md` («Git и diff»: бейджи `?` цветом A, `R` цветом M, `U` цветом D; «Дерево файлов»: строка 13 (`row`), отступ уровня 12; «Инспектор»: ширина 220, перетаскиванием 180–480, сохраняется; «Diff»: моно 12.5, колонка номеров 34 — одна колонка: новый номер у `+`/контекста, старый у `-`)

**Interfaces:**
- Produces (в `Git`, все `public`, `Sendable`, `Equatable`):
  - `enum FileChange: String { case modified = "M", added = "A", deleted = "D", renamed = "R", untracked = "?", conflicted = "U" }` — `rawValue` и есть бейдж.
  - `struct StatusEntry { var path: String; var origPath: String?; var change: FileChange }`
  - `struct StatusResult { var entries: [StatusEntry]; var truncated: Bool }`
  - `struct FileListing { var paths: [String]; var truncated: Bool }`
  - `extension Git { func toplevel() async throws -> String /* show-toplevel */; func gitDir() async throws -> String /* rev-parse --absolute-git-dir */; func status(limit: Int = 5_000) async throws -> StatusResult; func listFiles(limit: Int = 200_000) async throws -> FileListing }`
  - `func parseStatusV2(_ out: String, limit: Int) -> StatusResult` (internal, в `GitParse.swift`). Правила: `1 XY …` — `D` в X или Y → deleted, `A` в X → added, иначе modified; `2 …` — renamed, `origPath` из следующего NUL-поля; `u …` → conflicted; `? path` → untracked; `#` и `!` пропускаются.
- Команды: `git --no-optional-locks status --porcelain=v2 -z --untracked-files=all --find-renames`; `git --no-optional-locks ls-files -co --exclude-standard -z` (cwd — `toplevel`; пути относительно корня репозитория).

- [ ] **Step 1: Запись #44 в `decisions.md`** (формат журнала). Решения контроллера: без tree-sitter и новых зависимостей на этапе 4 — unified diff с фоном строк `+/-`, заголовками ханков, номерами строк, моно; подсветка синтаксиса отложена (почему: цена зависимости — грамматики, сборка, размер; вернуться по слову пользователя); split-diff нет (#23). Git-чтение — в модуле `Git` через `Runner` (этап 6 подменит исполнителя): `status --porcelain=v2 -z`, `changedFiles` (merge-base с базовой веткой / незакоммиченное), `diff` с разбором `-U3`, `listFiles` через `ls-files -co --exclude-standard -z`. Files: ленивые каталоги, бейджи из status, каталоги первыми; клик — Helix (`Esc` + `:open <path>` + ↩ в существующий editor-лист, иначе новая editor-вкладка). Не-git — только Files (FileManager, без `.git`). Changes: `+N −M`, временная diff-вкладка (курсив, не сохраняется, заменяется, ⌘W), `↑/↓`, `↩` (`:goto N` / `hx path:N`), `⌥B`. Обновление: FSEvents видимой задачи, только при видимом инспекторе и неперекрытом окне, плюс `done` агента и смена задачи. Решения плана:
  - `--no-optional-locks` у всех команд инспектора (иначе цикл: `status` пишет index → FSEvents → `status`).
  - Debounce = `latency` 0.3 с потока FSEvents, своих таймеров нет. Новое событие во время загрузки того же контекста не отменяет её: ставится флаг «повторить», после завершения — ровно одна повторная загрузка (иначе при непрерывной записи агента загрузка не завершалась бы никогда). Смена задачи, режима `⌥B` или корня — отмена загрузки (`Task.cancel` → `Runner` убивает git).
  - События: внутри git-dir обновляют только `index`, `HEAD`, `refs/**`, `packed-refs`, `MERGE_HEAD`; `objects/`, `logs/`, `*.lock`, `FETCH_HEAD` — нет. Создание/удаление/переименование вне git-dir — перечитать и дерево, и статус; изменение содержимого — только статус. Игнорируемые файлы (сборка) тоже вызывают обновление статуса (`// shortcut: без check-ignore — коалесцирование ограничивает частоту одной загрузкой подряд; фильтровать, если сборки заметно грузят CPU`).
  - Пути — от `git rev-parse --show-toplevel` (проект в подпапке репозитория показывает весь репозиторий); в Helix уходит абсолютный путь.
  - Лимиты: 5 000 записей статуса/изменений, 200 000 путей дерева, ≥ 50 000 путей — без автораскрытия; diff > 20 000 изменённых строк — «слишком большой diff». «Ленивое дерево» — строки строятся только для раскрытых каталогов из индекса одного `ls-files`; `ls-files` повторяется только при создании/удалении/переименовании файлов.
  - Untracked-файлы — в Changes обоих режимов, без `+N −M` (счётчики через `--no-index` на каждый файл — лишние процессы; `// shortcut:`), diff открывается (`--no-index /dev/null`).
  - Режим «незакоммиченное» — против `HEAD`, без коммитов — против пустого дерева (`git hash-object -t tree --stdin` с пустым stdin). Базовой ветки нет, merge-base не найден или имя начинается с `-` → показ незакоммиченного с пометкой «базовая ветка не найдена».
  - Базовая ветка: worktree-задача — её `base`; задача в основной папке — `Project.lastBaseBranch ?? defaultBranch()`.
  - `⌥B`, `↑/↓`, `↩` перехватываются только при активной diff-вкладке (фокус не в поле ввода); иначе уходят в терминал (`⌥B` — слово назад в zsh).
  - Helix: открытие в существующем листе — только если редактор `hx`/`helix` (первое слово команды). Путь в командной строке Helix: `'…'`, если нет `'`; иначе `` `…` ``, если нет `` ` ``; иначе `"…"`, если нет `"` и `%`; иначе — новая вкладка (argv квотируется shell'ом). После `Esc` остаток отправляется через 50 мс (одноразово): иначе `Esc :` в одном чтении терминал без kitty-протокола понимает как `Alt-:`. Текст команды — вставкой (bracketed paste) в промпт `:`, буквы не печатаются по одной. Лист не запущен (вкладка не показывалась) — меняется `openFile`/`openLine` и вкладка активируется; лист завершился — то же + перезапуск. Другой редактор (`nvim` …) — всегда новая вкладка (`nvim +N path`).
  - `Leaf.openLine: Int?` рядом с `openFile` (восстановление открывает файл на той же строке; старые файлы читаются).
  - Бейджи: `?` цветом A, `R` цветом M, `U` цветом D. Строки дерева и списка — системный шрифт 13 (`row`); моно — в diff (12.5) и заголовке diff.
  - Diff-вкладка — по одной на задачу, в памяти `AppState`; ⌘1…9 считают только обычные вкладки; активная diff-вкладка не меняет `activeTabId` (после перезапуска — прежняя вкладка).
  - Сегмент и режим `⌥B` — в памяти (не сохраняются); ширина инспектора — `WorkspaceState.inspectorWidth` (220, 180–480).
  - Отвергнуто: tree-sitter; libgit2; опрос; отмена на каждое событие; глобальный `⌥B`; печать команды Helix посимвольно; `git add -N` для счётчиков untracked (запись в index); хранение diff-вкладки в модели.
- [ ] **Step 2: Спека и DESIGN.md** — правки из списка Files выше.
- [ ] **Step 3: Тесты** (`InspectTests`, RED; `TempRepo`):
  - `statusKinds` — изменённый `a.txt`, новый staged `n.txt`, удалённый `d.txt`, untracked `u/x.txt`, `git mv b.txt "c с пробелом.txt"` → записи `[M a.txt, A n.txt, D d.txt, ? u/x.txt, R "c с пробелом.txt" (origPath "b.txt")]` (порядок не важен — сравнивать множеством).
  - `statusParsesSpecialPaths` — untracked `it's "q" %{x}.txt`, `-dash.txt`, `` back`tick.txt ``, `папка/файл.txt` → пути байт в байт.
  - `statusConflict` — конфликт слияния двух веток в `a.txt` → `.conflicted`.
  - `statusIgnoresUserConfig` — `git config status.showUntrackedFiles no` → untracked всё равно есть.
  - `statusTruncated` — 12 untracked, `limit: 10` → 10 записей, `truncated == true`.
  - `listFilesRespectsGitignore` — `.gitignore` с `build/`, файлы `build/o.bin`, `src/m.swift`, untracked `new.txt` → `src/m.swift`, `new.txt`, `a.txt`, `.gitignore` есть, `build/o.bin` нет; `limit: 2` → `truncated`.
  - `toplevelFromSubdir` — `Git(repo: repo + "/sub")` → `toplevel() == repo` (через `realpath`), `gitDir()` оканчивается на `/.git`; в worktree — на `/worktrees/<name>`.
  - `inspectorCommandsDoNotWriteIndex` — `touch a.txt` (меняется stat), mtime `.git/index` до; `status()` + `listFiles()` → mtime `.git/index` тот же.
  - `notARepository` — `status()` в простой папке бросает `GitError`.
- [ ] **Step 4:** Run: `swift test --filter InspectTests` — Expected: FAIL (нет `status`).
- [ ] **Step 5: Реализовать** по Interfaces; приватный помощник `inspect(_ args: [String]) async throws -> String` добавляет `--no-optional-locks` и бросает `GitError` при ненулевом коде.
- [ ] **Step 6:** Run: `swift test --filter GitTests` — Expected: PASS (старые тесты `GitTests` тоже).
- [ ] **Step 7: Commit** — `git add Sources/Git Tests/GitTests docs && git commit -m "feat(git): status and file listing for the inspector; decision #44"`

### Task 2: `Git.changedFiles` и `Git.diff` с парсером unified diff

**Files:**
- Modify: `Sources/Git/Git+Inspect.swift`, `Sources/Git/GitParse.swift`
- Create: `Tests/GitTests/DiffParseTests.swift`, `Tests/GitTests/ChangesTests.swift`

**Interfaces:**
- Consumes: `FileChange`, `inspect(_:)` (Task 1).
- Produces (`public`, `Sendable`, `Equatable`):
  - `enum DiffMode: Hashable { case base(String), uncommitted }`
  - `struct ChangedFile: Identifiable { var path: String; var origPath: String?; var change: FileChange; var added: Int?; var deleted: Int? /* nil — бинарный или untracked */; var id: String { path } }`
  - `struct ChangeSet { var files: [ChangedFile]; var from: String /* sha merge-base, HEAD или пустого дерева */; var mode: DiffMode /* фактический (после отката) */; var baseMissing: Bool; var truncated: Bool }`
  - `struct DiffLine { enum Kind: Sendable { case context, added, deleted }; var kind: Kind; var text: String; var oldLine: Int?; var newLine: Int?; var noNewlineAtEnd: Bool }`
  - `struct Hunk { var header: String /* вся строка @@ … @@ ctx */; var oldStart: Int; var newStart: Int; var lines: [DiffLine] }`
  - `enum FileDiff { case text(hunks: [Hunk], oldMode: String?, newMode: String?); case binary; case tooLarge(lines: Int) }` — смена режима без правок = `.text(hunks: [], oldMode:, newMode:)`.
  - `extension Git { func changedFiles(_ mode: DiffMode, limit: Int = 5_000) async throws -> ChangeSet; func diff(file: ChangedFile, from: String, maxLines: Int = 20_000) async throws -> FileDiff }`
  - `func parseUnifiedDiff(_ out: String) -> FileDiff` (internal) — режимы из `old mode`/`new mode`/`new file mode`/`deleted file mode`; `Binary files … differ` или `GIT binary patch` → `.binary`; ханк `@@ -a[,b] +c[,d] @@` (счётчик по умолчанию 1), строки читаются строго по счётчикам `b`/`d`; `\ No newline at end of file` ставит `noNewlineAtEnd` предыдущей строке.
- Команды: `merge-base HEAD <base>` (base с ведущим `-` → сразу `baseMissing`); `diff --name-status -z --find-renames <from>` + `diff --numstat -z --find-renames <from>` (сопоставление по новому пути; numstat переименования — `a\td\t\0old\0new\0`) + untracked из `status`; файл: сначала `diff --numstat -z <from> -- [orig] path` (`-\t-` → `.binary`, сумма > `maxLines` → `.tooLarge`), затем `diff --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ --find-renames -U3 <from> -- [orig] path`; untracked — те же два шага с `--no-index -- /dev/null path` (код выхода 1 = «есть различия», не ошибка).

- [ ] **Step 1: Тесты парсера** (`DiffParseTests`, RED, на строках):
  - `hunkHeaderForms` — `@@ -41,14 +41,29 @@ export async function refresh(token: string)` → `oldStart 41, newStart 41`, `header` целиком; `@@ -1 +1 @@` → по одной строке; `@@ -0,0 +1,3 @@` → три `added` с `newLine` 1…3, `oldLine == nil`.
  - `lineNumbers` — контекст/удаление/добавление: контекст 41/41, удалённые 42, 43 (old), добавленные 42…44 (new), следующий контекст 44/45.
  - `parserTrustsHunkCounts` — ханк `-1,3 +1,3`, удалённая строка `-- comment` (в выводе `--- comment`), добавленная `+++ x` (в выводе `++++ x`), контекстная ` @@ fake @@` → 1 ханк, тексты `-- comment`, `+++ x`, `@@ fake @@`; затем второй настоящий ханк распознан.
  - `noNewlineMarker` — `\ No newline at end of file` после удалённой и после добавленной строки → `noNewlineAtEnd` у них, лишних строк нет.
  - `binaryAndModes` — `Binary files a/x.png and b/x.png differ` → `.binary`; `old mode 100644`/`new mode 100755` без ханков → `.text(hunks: [], oldMode: "100644", newMode: "100755")`.
- [ ] **Step 2: Тесты на репозиториях** (`ChangesTests`, RED, `TempRepo`; ветка `feat` от `main`, коммит в `feat` + незакоммиченные правки):
  - `baseVsUncommitted` — `.base("origin/main")` содержит закоммиченный в `feat` `c.txt` (+3 −0) и незакоммиченный `a.txt`; `.uncommitted` — только `a.txt`; `ChangeSet.from` — sha merge-base / `HEAD`.
  - `untrackedInBothModes` — untracked `u.txt` есть в обоих, `added == nil`; `diff` → `.text` с одним ханком `@@ -0,0 +1,N @@`.
  - `renameWithSpaces` — `git mv a.txt "dir с пробелом/b.txt"` + правка → `.renamed`, `origPath == "a.txt"`, numstat сопоставлен (`added`, `deleted` не nil); `diff` возвращает ханк с правкой.
  - `diffStates` — PNG-байты → `.binary`, `added == nil`; файл 25 000 строк → `.tooLarge(lines: 25000)`; `chmod +x` без правок → `.text(hunks: [], oldMode: "100644", newMode: "100755")`; удалённый файл → все строки `deleted`.
  - `noCommitsAndMissingBase` — пустой репозиторий с untracked и staged файлами: `.uncommitted` работает, `from` — хеш пустого дерева; `.base("origin/gone")` и `.base("-x")` → `mode == .uncommitted`, `baseMissing == true`.
  - `ignoresDiffUserConfig` — `git config diff.noprefix true`, `color.ui always`, `diff.external /bin/false` → `diff` разбирается как обычно.
- [ ] **Step 3:** Run: `swift test --filter "DiffParseTests|ChangesTests"` — Expected: FAIL.
- [ ] **Step 4: Реализовать** по Interfaces.
- [ ] **Step 5:** Run: `swift test --filter GitTests` — Expected: PASS.
- [ ] **Step 6: Commit** — `git add Sources/Git Tests/GitTests && git commit -m "feat(git): changed files against merge-base or HEAD, parsed unified diff"`

### Task 3: Модель и запуск редактора с файлом и строкой; ширина инспектора

**Files:**
- Modify: `Sources/Workspace/Model.swift`, `Sources/Exec/Launch.swift`, `Tests/WorkspaceTests/ModelTests.swift`, `Tests/ExecTests/LaunchTests.swift`

**Interfaces:**
- Produces:
  - `Leaf.openLine: Int?` (`init(..., openFile: String? = nil, openLine: Int? = nil)`; ключ декодируется `decodeIfPresent`).
  - `WorkspaceState.inspectorWidth: Double` (220; `decodeIfPresent`; `init(..., inspectorWidth: Double = 220)`).
  - `WorkspaceState.addTab(taskId: UUID, kind: LeafKind, openFile: String? = nil, openLine: Int? = nil) -> UUID` (замена текущей сигнатуры, вызывающие не меняются).
  - `WorkspaceState.setOpenFile(leafId: UUID, path: String, line: Int?)`
  - `public func isHelix(_ editorCommand: String) -> Bool` (Exec) — basename первого слова ∈ {`hx`, `helix`}.
  - Команда editor-листа: `hx` → `hx 'path:N'`; `nvim`/`vim` → `nvim +N 'path'`; иное или `openLine == nil` → как сейчас (`<editor> 'path'`, ведущий `-` → `./`).

- [ ] **Step 1: Тесты** (RED):
  - `ModelTests.oldStateWithoutInspectorWidthLoads` — JSON без ключа → 220; round-trip 300 → 300.
  - `ModelTests.leafOpenLineRoundTrip` — `openLine` сохраняется; JSON листа без ключа → nil.
  - `ModelTests.addEditorTabWithFile` — `addTab(kind: .editor, openFile: "/r/a b.txt", openLine: 7)` → лист с файлом и строкой, вкладка активна; `setOpenFile` меняет оба поля у листа в сплите.
  - `LaunchTests.editorWithLine` — `hx` + `"/r/a b.txt"`, 7 → команда содержит `hx '/r/a b.txt:7'`; `nvim` → `nvim +7 '/r/a b.txt'`; `code` → `code '/r/a b.txt'`; `hx` + `"-x"` без строки → `./-x`.
  - `LaunchTests.isHelix` — `"hx"`, `"/opt/homebrew/bin/hx --config x"`, `"helix"` → true; `"nvim"`, `"hxx"` → false.
- [ ] **Step 2:** Run: `swift test --filter "ModelTests|LaunchTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4:** Run: `swift test --filter "WorkspaceTests|ExecTests"` — Expected: PASS.
- [ ] **Step 5: Commit** — `git add Sources/Workspace Sources/Exec Tests && git commit -m "feat(model): editor leaf line, inspector width"`

### Task 4: Открытие файла в Helix (`EditorOpener`, `sendKey`)

**Files:**
- Create: `Sources/HangarUI/EditorOpener.swift`, `Tests/HangarUITests/EditorOpenerTests.swift`
- Modify: `Sources/GhosttyBridge/TerminalSurfaceView.swift`, `Sources/HangarUI/SplitView.swift` (`TerminalArea.openInEditor`), `Sources/HangarUI/AppState.swift`, `Sources/HangarUI/MainWindow+Debug.swift` (команда `open <path> [line]`)

**Interfaces:**
- Consumes: `isHelix`, `addTab(…openFile:openLine:)`, `setOpenFile` (Task 3).
- Produces:
  - GhosttyBridge: `public enum SurfaceKey: Sendable { case escape /* kVK_Escape 53 */, colon /* kVK_ANSI_Semicolon 41 + shift, text ":" */ }`; `TerminalSurfaceView.sendKey(_ key: SurfaceKey)` — press + release через `ghostty_surface_key`, как `sendEnter`.
  - `func helixQuoted(_ path: String) -> String?` — правило из #44.
  - `func helixCommands(path: String, line: Int?) -> [String]?` — `["open <quoted>"]` + `"goto N"` при строке; nil, если путь не квотируется.
  - `enum EditorRoute: Equatable { case sendKeys(tab: UUID, leaf: UUID); case launch(tab: UUID, leaf: UUID) /* лист не запущен или завершился: openFile + (пере)запуск */; case newTab }`
  - `@MainActor func editorRoute(task: HangarTask, isHelix: Bool, quotable: Bool, isLive: (UUID) -> Bool) -> EditorRoute` — editor-лист: сфокусированный лист активной вкладки, иначе первый editor-лист активной вкладки, иначе первый по порядку вкладок; нет листа, `!isHelix` или `!quotable` → `.newTab`; `isLive(leaf)` (surface есть, `exitCode == nil`, `!failed`) → `.sendKeys`, иначе `.launch`.
  - `AppState.openInEditor(path: String /* абсолютный */, line: Int?)` → вызывает `onOpenInEditor` (ставит `TerminalArea`), без задачи — ничего.
  - `TerminalArea.openInEditor(path:line:)`: `.sendKeys` — `setOpenFile`, активировать вкладку, фокус листа, `sendKey(.escape)`, через 50 мс (`DispatchQueue.main.asyncAfter`, одноразово) для каждой команды: `sendKey(.colon)`, `sendText(cmd)`, `sendEnter()`; `.launch` — `setOpenFile`, активировать вкладку, завершившийся лист — `relaunch()`; `.newTab` — `addTab(kind: .editor, openFile:, openLine:)`.

- [ ] **Step 1: Тесты** (`EditorOpenerTests`, RED):
  - `helixQuoting` — `/r/a b.txt` → `'/r/a b.txt'`; `/r/it's.txt` → в обратных кавычках; путь с `'` и обратной кавычкой → в двойных кавычках; путь с `'`, обратной кавычкой и `"` (или `%`) → nil; `/r/%{sh}.txt` → `'/r/%{sh}.txt'` (в одинарных кавычках Helix не раскрывает `%{}`).
  - `helixCommandsWithLine` — `(“/r/a.txt”, 12)` → `["open '/r/a.txt'", "goto 12"]`; без строки — одна команда.
  - `routePrefersFocusedEditor` — вкладка [shell │ editor] с фокусом на editor + отдельная editor-вкладка → `.sendKeys` с листом из активной вкладки; фокус на shell → первый editor-лист активной вкладки; активная вкладка без editor → editor-лист другой вкладки.
  - `routeFallbacks` — нет editor-листа → `.newTab`; `isHelix == false` → `.newTab`; `quotable == false` → `.newTab`; лист не живой → `.launch`.
- [ ] **Step 2:** Run: `swift test --filter EditorOpenerTests` — Expected: FAIL.
- [ ] **Step 3: Реализовать** (C-API — только в `GhosttyBridge`).
- [ ] **Step 4:** Run: `swift build && swift test --filter HangarUITests` — Expected: PASS.
- [ ] **Step 5: Проверить вручную** (DEBUG, `HANGAR_DEBUG_PROJECT=<tmp-репо>`, `hx` 25.07): editor-вкладка с `README`; в Helix режим вставки, набран текст → debug `open <tmp>/dir with space/it's %{x}.txt 3` → Helix открыл файл на строке 3, в буфер ничего не вставлено, предыдущий файл не изменён (`:buffer-close` без запроса сохранения); то же при открытом пикере (`Space f`); путь с `'`, `` ` `` и `"` одновременно → новая вкладка `hx '…:3'`. Если `Esc :` всё же понят как `Alt-:` или вставка в промпт не работает — записать в #44 и перейти на печать команды через `ghostty_surface_key` по символу.
- [ ] **Step 6: Commit** — `git add Sources Tests && git commit -m "feat(editor): open a file in the task's Helix or a new editor tab"`

### Task 5: `FileTree` и `InspectorModel` (загрузка, отмена, режим)

**Files:**
- Create: `Sources/HangarUI/FileTree.swift`, `Sources/HangarUI/InspectorModel.swift`, `Tests/HangarUITests/FileTreeTests.swift`, `Tests/HangarUITests/InspectorModelTests.swift`
- Modify: `Sources/HangarUI/AppState.swift` (`let inspector: InspectorModel`, базовая ветка задачи)

**Interfaces:**
- Consumes: `Git.toplevel/gitDir/status/listFiles/changedFiles/diff`, `ChangedFile`, `ChangeSet`, `DiffMode`, `FileDiff`, `FileChange` (Tasks 1–2).
- Produces:
  - `struct FileTree: Equatable, Sendable { struct Entry: Equatable, Sendable { var name: String; var path: String /* от корня */; var isDir: Bool }; init(paths: [String]) /* git: индекс всех каталогов сразу */; init() /* не-git: пусто */; func children(of dir: String /* "" — корень */) -> [Entry]? /* nil — каталог не загружен */; mutating func setChildren(_ entries: [Entry], of dir: String) /* не-git */; var count: Int }` — каталоги первыми, внутри групп `localizedStandardCompare`.
  - `struct TreeRow: Identifiable, Equatable { var entry: FileTree.Entry; var depth: Int; var expanded: Bool; var id: String { entry.path } }`; `func visibleRows(_ tree: FileTree, expanded: Set<String>) -> [TreeRow]` — только раскрытые и загруженные каталоги.
  - `func autoExpanded(for changes: [String], fileCount: Int) -> Set<String>` — предки первых 50 путей; `fileCount >= 50_000` → пусто.
  - `func listDirectory(_ url: URL) -> [FileTree.Entry]` (nonisolated, не-git; без `.git` и `.DS_Store`).
  - `enum DiffState: Equatable { case none, loading, loaded(FileDiff), notChanged, failed(String) }`
  - `@MainActor @Observable final class InspectorModel { enum Segment { case files, changes }; var segment: Segment; private(set) var root: String?; private(set) var isGit: Bool; private(set) var tree: FileTree; var expanded: Set<String>; private(set) var badges: [String: FileChange]; private(set) var changes: ChangeSet?; private(set) var statusTruncated: Bool; private(set) var filesTruncated: Bool; private(set) var error: String?; private(set) var diff: DiffState; enum ModeChoice { case base, uncommitted }; private(set) var modeChoice: ModeChoice /* запрошенный; фактический — changes?.mode */; init(git: @escaping @Sendable (String) -> Git = { Git(repo: $0) }); func show(taskId: UUID?, root: String?, baseBranch: @escaping @Sendable () async -> String?); func refresh(_ parts: RefreshParts); func toggleMode(); func expand(_ dir: String); func collapse(_ dir: String); func loadDiff(path: String?); var loading: Task<Void, Never>? /* для тестов */ }`
  - `struct RefreshParts: OptionSet, Sendable { static let status, tree; static let all: RefreshParts = [.status, .tree] }` — `.status` = badges + changes + открытый diff.
  - Правила загрузки: контекст = (taskId, root, modeChoice). `show` с другим контекстом и `toggleMode` отменяют текущую загрузку и сбрасывают данные; `refresh` в том же контексте во время загрузки — накапливает части и ставит «повторить»; после завершения — одна повторная загрузка с накопленными частями. Результат применяется, только если контекст не изменился и задача не отменена. Не-git (`Git.isRepository() == false`) — `isGit = false`, корень из `listDirectory`, `segment` принудительно `.files`.
  - `AppState.baseBranch(of task: HangarTask) async -> String?` — worktree → `base`; иначе `project.lastBaseBranch ?? Git(repo:).defaultBranch()`.

- [ ] **Step 1: Тесты** (RED; `TempRepo` из `HangarUITests`, `Runner.local`; медленный git — `Runner { args, cwd in try await Task.sleep(for: .milliseconds(300)); return try await Runner.local.run(args, cwd) }`):
  - `FileTreeTests.dirsFirstSorted` — `["b.txt", "src/z.swift", "a.txt", "src/lib/x.swift", "Docs/r.md", "file10.txt", "file2.txt"]` → корень: `Docs`, `src`, `a.txt`, `b.txt`, `file2.txt`, `file10.txt`; `src` → `lib`, `z.swift`.
  - `FileTreeTests.visibleRowsOnlyExpanded` — раскрыт `src` → строки корня + дети `src` (глубина 1), `lib` свёрнут; не-git дерево без `setChildren` для `src` → только корень.
  - `FileTreeTests.autoExpand` — `["src/db/pool.ts", "x.ts"]` → `["src", "src/db"]`; `fileCount: 60_000` → пусто.
  - `loadsFilesAndChanges` — репозиторий с правкой `a.txt` и untracked `u.txt` → после `loading?.value`: `tree.children(of: "")` содержит оба, `badges["a.txt"] == .modified`, `badges["u.txt"] == .untracked`, `changes?.files.count == 2`.
  - `toggleModeReloads` — коммит в ветке задачи + правка: режим base → 2 файла; `toggleMode()` → 1 файл, `changes?.mode == .uncommitted`.
  - `baseMissingShowsUncommitted` — `baseBranch` → `"origin/gone"` → `changes?.baseMissing == true`.
  - `contextSwitchCancelsAndDropsStale` — медленный runner, `show(A)`, сразу `show(B)` → после ожидания `changes` от B; данных A нет ни в какой момент после `show(B)` (проверка после каждого `await Task.yield()` в цикле до завершения).
  - `burstCoalescesWithoutStarvation` — медленный runner; во время загрузки 10 раз `refresh(.status)` с интервалом 50 мс → загрузка завершилась, повторная — ровно одна (счётчик вызовов `status` в обёртке runner = 2).
  - `nonGitFolder` — папка без git с `a.txt`, `.DS_Store`, `sub/x.txt` → `isGit == false`, `segment == .files`, корень: `sub`, `a.txt`; `expand("sub")` загружает `x.txt`. Отдельно `listDirectory` на папке с пустым каталогом `.git` → его нет в результате.
  - `diffStateFollowsChanges` — `loadDiff(path: "a.txt")` → `.loaded(.text…)`; файл откатили (`git checkout a.txt`) и `refresh(.status)` → `.notChanged`.
- [ ] **Step 2:** Run: `swift test --filter "FileTreeTests|InspectorModelTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать.** Построение `FileTree(paths:)` — в nonisolated функции (вне main); git — через `Git` с runner из `init`.
- [ ] **Step 4:** Run: `swift test --filter HangarUITests` — Expected: PASS.
- [ ] **Step 5: Commit** — `git add Sources/HangarUI Tests/HangarUITests && git commit -m "feat(inspector): model with cancellable, coalesced loading"`

### Task 6: `FileWatcher` (FSEvents) и когда обновлять

**Files:**
- Create: `Sources/HangarUI/FileWatcher.swift`, `Tests/HangarUITests/FileWatcherTests.swift`
- Modify: `Sources/HangarUI/MainWindow.swift` (жизненный цикл), `Sources/HangarUI/AppState+Agents.swift` (`onLeafDone`)

**Interfaces:**
- Consumes: `InspectorModel.show/refresh`, `RefreshParts`, `Git.gitDir` (Tasks 1, 5).
- Produces:
  - `func classify(_ events: [(path: String, flags: FSEventStreamEventFlags)], root: String, gitDir: String?) -> RefreshParts` — внутри `gitDir`: `index`, `HEAD`, `refs/…`, `packed-refs`, `MERGE_HEAD` → `.status`; `objects/`, `logs/`, `*.lock`, `FETCH_HEAD`, прочее → ничего. Вне `gitDir` (включая `<root>/.git` как файл worktree): флаги `ItemCreated|ItemRemoved|ItemRenamed` → `.all`, иначе `.status`. `kFSEventStreamEventFlagMustScanSubDirs`/`RootChanged` → `.all`.
  - `func watchPaths(root: String, gitDir: String?) -> [String]` — `[root]` + `gitDir`, если он не внутри `root`.
  - `func shouldWatch(inspectorVisible: Bool, windowVisible: Bool, hasTask: Bool) -> Bool`
  - `final class FileWatcher { init(paths: [String], onChange: @escaping @MainActor (RefreshParts) -> Void, classify: …); func stop() }` — `FSEventStreamCreate` с `kFSEventStreamCreateFlagFileEvents | UseCFTypes`, `latency: 0.3`, очередь `DispatchQueue` (без run loop), `deinit` → `stop`; пустой результат классификации не вызывает `onChange`.
  - `AppState.onLeafDone: ((UUID) -> Void)?` — вызывается при переходе листа в `done`.
  - `MainWindowController`: наблюдение `inspectorVisible`, выбранной задачи, `NSWindow.didChangeOcclusionStateNotification`, `didMiniaturize/didDeminiaturize`; `shouldWatch` true → `inspector.show(…)` + `FileWatcher(watchPaths)` (пересоздаётся при смене задачи/корня); false → `watcher = nil`. Переход в видимость — `refresh(.all)`; `onLeafDone` листа видимой задачи — `refresh(.status)`. Лог `uiLog.info("watch start|stop root=…")`.

- [ ] **Step 1: Тесты** (RED):
  - `classifyGitInternals` — `.git/objects/ab/cd`, `.git/logs/HEAD`, `.git/index.lock`, `.git/FETCH_HEAD` → пусто; `.git/index`, `.git/HEAD`, `.git/refs/heads/main`, `.git/packed-refs` → `.status`.
  - `classifyWorktreeFiles` — изменение `src/a.swift` → `.status`; создание/удаление/переименование → `.all`; `MustScanSubDirs` → `.all`.
  - `watchPathsForWorktree` — `root=/r/wt`, `gitDir=/r/main/.git/worktrees/wt` → оба пути; `gitDir=/r/wt/.git` → только `/r/wt`; `gitDir=nil` (не-git) → `[root]`.
  - `shouldWatchMatrix` — true только при всех трёх true.
  - `watcherDeliversOnce` — настоящий `FileWatcher` на temp-папке: запись в 20 файлов подряд → `onChange` вызван 1–2 раза за 1.5 с (не 20); после `stop()` запись → ни одного вызова.
- [ ] **Step 2:** Run: `swift test --filter FileWatcherTests` — Expected: FAIL.
- [ ] **Step 3: Реализовать** и подключить в `MainWindowController`.
- [ ] **Step 4:** Run: `swift test --filter HangarUITests` — Expected: PASS.
- [ ] **Step 5: Commit** — `git add Sources/HangarUI Tests/HangarUITests && git commit -m "feat(inspector): FSEvents refresh for the visible task only"`

### Task 7: Вид инспектора — сегмент, Files, Changes, ширина

**Files:**
- Create: `Sources/HangarUI/InspectorView.swift`
- Modify: `Sources/HangarUI/MainWindow.swift` (третий `NSSplitViewItem`, ширина, `⌘⌥I` без `shortcut:`-комментария), `Sources/HangarUI/TabBarView.swift` (кнопка инспектора — тот же путь), `Sources/HangarUI/Theme.swift`, `Sources/HangarUI/L10n.swift`, `Sources/HangarUI/Resources/{ru,en}.lproj/Localizable.strings`, `Tests/HangarUITests/L10nTests.swift` (если ключи перечисляются явно)

**Interfaces:**
- Consumes: `InspectorModel`, `visibleRows`, `TreeRow` (Task 5); `AppState.openInEditor` (Task 4); `AppState.openDiff(path:)` (Task 8 — до него клик по Changes вызывает `inspector.loadDiff` и ничего не открывает; подключение — в Task 8).
- Produces:
  - `Theme`: `inspectorWidth 220`, `inspectorMin 180`, `inspectorMax 480`, `treeIndent 12`, `fileRowPaddingV 3`; `Theme.Diff`: `hunk #56b6c2`, `hunkBg #56b6c2 7%`, `badgeM #e5c07b`, `badgeA #98c379`, `badgeD #e06c75`, `font 12.5`, `gutter 34`, `func badge(_ c: FileChange) -> Color` (`?` → A, `R` → M, `U` → D).
  - `L10n` (ru / en): `segmentFiles` «Files»/«Files», `segmentChanges` «Changes %d»/«Changes %d», `changesHintBase` «Сравнение с базовой веткой %@»/«Compared with base branch %@», `changesHintToBase` «⌥B — сравнить с %@»/«⌥B — compare with %@», `changesHintUncommitted` «Только незакоммиченное»/«Uncommitted only», `changesHintToUncommitted` «⌥B — только незакоммиченное»/«⌥B — uncommitted only», `baseMissing` «Базовая ветка %@ не найдена — показано незакоммиченное»/«Base branch %@ not found — showing uncommitted», `noChanges` «Нет изменений»/«No changes», `statusTruncated` «Показаны первые %d изменений»/«Showing the first %d changes», `filesTruncated` «Показаны не все файлы (больше %d)»/«Not all files shown (over %d)», `gitFailed` «git: %@»/«git: %@», `inspectorNoTask` «Задача не выбрана»/«No task selected».
  - `InspectorView(app:)`: сегмент (DESIGN «Сегмент»: дорожка `panel`, отступ 2, радиус 6/4, активный `control` + `textStrong`, подпись 12; у не-git проекта сегмента нет); Files — строки `visibleRows`, отступ `depth * treeIndent`, шеврон `chevronDown/Right` у каталогов, имя 13, справа бейдж цветом `Theme.Diff.badge`; клик по каталогу — `expand/collapse`, по файлу — `app.openInEditor(path: root + "/" + path, line: nil)`; Changes — строка: имя, каталог `text3` (усечение в начале), `+N` (`badgeA`) `−M` (`badgeD`) 11.5, бейдж; выбранная (файл diff-вкладки) — `selection`; под списком — подсказка (2 строки, 11.5 `text3`, `base` — моно), клик по ней = `⌥B`; пометки `baseMissing`, `statusTruncated`, `filesTruncated`, `error` — строкой `text3` над списком; пусто — `noChanges`. Наведение 120 мс, `.pointingHand()` на строках, сегментах, подсказке. Список — `ScrollView` + `LazyVStack`.
  - Сплит: `[sidebar, column, inspector]`, `inspectorItem.isCollapsed = !inspectorVisible`, ширина из `state.inspectorWidth` в пределах 180–480; на отпускании разделителя — `perform { $0.inspectorWidth = … }` (только если изменилась ≥ 1, как у сайдбара; отличать, какой разделитель тащили).

- [ ] **Step 1: Тесты** (RED): `L10nTests.allKeysHaveRuAndEn` (новые ключи — в `Key`); `InspectorLayoutTests.widthClamped` — `clampInspectorWidth(1000) == 480`, `clampInspectorWidth(100) == 180`, `clampInspectorWidth(300) == 300` (`func clampInspectorWidth(_ w: CGFloat) -> CGFloat` в `MainWindow.swift`).
- [ ] **Step 2:** Run: `swift test --filter "L10nTests|InspectorLayoutTests"` — Expected: FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4:** Run: `swift build && swift test --filter HangarUITests` — Expected: PASS.
- [ ] **Step 5: Проверить вручную** (DEBUG, temp-репо с правками и `node_modules/` в `.gitignore`): сверить с `style-a-v2.html` экран 1 и правой колонкой экрана 2 (отступы 14, высота строки ~22, бейджи, сегмент); `⌘⌥I` в русской раскладке; ширина перетаскивается и восстанавливается после перезапуска; `node_modules` в дереве нет; не-git папка — только дерево, без сегмента; рука на строках и сегментах; без «прыжков» при переключении сегмента.
- [ ] **Step 6: Commit** — `git add Sources/HangarUI Tests/HangarUITests && git commit -m "feat(inspector): Files tree and Changes list"`

### Task 8: Временная diff-вкладка, `DiffView`, клавиши

**Files:**
- Create: `Sources/HangarUI/AppState+Diff.swift`, `Sources/HangarUI/DiffView.swift`, `Tests/HangarUITests/DiffTabTests.swift`
- Modify: `Sources/HangarUI/TabBarView.swift`, `Sources/HangarUI/SplitView.swift` (`TerminalArea`: показ diff вместо вкладки), `Sources/HangarUI/MainWindow.swift` (маршрут клавиш), `Sources/HangarUI/AppState.swift` (`activate(tabId:)`, `activate(tabNumber:)`), `Sources/HangarUI/InspectorView.swift` (клик по Changes → `openDiff`), `Sources/HangarUI/MainWindow+Debug.swift` (команды `inspector` — дамп, `change <n>`, `diffKey up|down|enter|optB|cmdW`)

**Interfaces:**
- Consumes: `InspectorModel.loadDiff/changes/diff/toggleMode`, `DiffState` (Task 5), `FileDiff`, `DiffLine`, `Hunk` (Task 2), `AppState.openInEditor` (Task 4).
- Produces:
  - `struct DiffTab: Equatable { var path: String; var active: Bool; var selectedRow: Int? }`; `AppState.diffTabs: [UUID: DiffTab]` (по задаче, только в памяти); `var activeDiff: DiffTab? /* у выбранной задачи и active */`.
  - `AppState.openDiff(path: String)` — заменяет/создаёт вкладку выбранной задачи, `active = true`, `inspector.loadDiff(path:)`; `closeDiff()`; `diffNeighbour(_ offset: Int)` — соседний файл в `inspector.changes.files` без зацикливания; `activate(tabId:)` и `activate(tabNumber:)` ставят `active = false` (⌘1…9 считают только обычные вкладки).
  - `enum DiffRow: Equatable, Identifiable { case meta(String) /* «режим 100644 → 100755», «переименован из …» */; case hunk(String); case line(DiffLine); case notice(String) /* бинарный, большой, не изменён, ошибка */ }`; `func diffRows(_ state: DiffState, origPath: String?) -> [DiffRow]`.
  - `func openTarget(rows: [DiffRow], selected: Int?) -> Int?` — строка выбрана: её `newLine`, у удалённой — `newLine` следующей не удалённой строки ханка, иначе `newStart` ханка; не выбрана — первая добавленная строка, иначе `newStart` первого ханка; ханков нет или результат 0 (удалённый файл: `+0,0`) — nil, ничего не открывается.
  - `enum DiffKey: Equatable { case up, down, enter, toggleMode, close }`; `func diffKeyRoute(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, diffActive: Bool, editingText: Bool) -> DiffKey?` — только при `diffActive && !editingText`: 126 → up, 125 → down, 36 → enter, ⌥ + 11 → toggleMode, ⌘ + 13 → close; иначе nil. В `route` проверяется до `shortcut(…)`.
  - `TabBarView`: после обычных вкладок — diff-вкладка `± <имя файла>` курсивом (DESIGN «Полоса вкладок»), активная — как активная вкладка, `×` закрывает, клик — `active = true`; без статус-точки и контекстного меню.
  - `TerminalArea.sync`: активная diff-вкладка — все вкладки скрыты, их surface `setVisible(false)`, показан `DiffView` (`NSHostingView`), первым ответчиком становится он (печать не уходит в скрытый терминал); иначе — как раньше.
  - `DiffView`: заголовок (путь моно `textStrong` 500, `+N` `badgeA`, `−M` `badgeD`), затем `ScrollView([.vertical, .horizontal])` + `LazyVStack(spacing: 0)`: строки без переноса, ширина ≥ видимой (фон до края), колонка номера 34 `text3` вправо, маркер `+`/`-` цветом A/D, фон `add`/`del`, ханк `hunk` на `hunkBg`; клик — выбор строки (`selection`), двойной клик и `↩` — `openInEditor(path: root + "/" + path, line: openTarget(...))`.
  - `L10n` (ru/en): `diffBinary` «Бинарный файл»/«Binary file», `diffTooLarge` «Слишком большой diff (%d строк)»/«Diff too large (%d lines)», `diffModeChange` «Режим %@ → %@»/«Mode %@ → %@», `diffRenamedFrom` «Переименован из %@»/«Renamed from %@», `diffNotChanged` «Файл больше не изменён»/«File is no longer changed», `diffTabHelp` «Закрыть ⌘W»/«Close ⌘W».

- [ ] **Step 1: Тесты** (`DiffTabTests`, RED; `AppState` как в `ActionsTests`, `TempRepo` с тремя изменёнными файлами):
  - `clickReplacesDiffTab` — `openDiff("a.txt")`, `openDiff("b.txt")` → у задачи одна diff-вкладка `b.txt`, активна; `state.tasks[…].tabs.count` не изменился.
  - `notPersisted` — после `openDiff` закодированный `WorkspaceState` не содержит `"b.txt"`, `activeTabId` прежний.
  - `neighbourWithoutWrap` — на первом файле `diffNeighbour(-1)` → тот же; `+1` → второй; на последнем `+1` → тот же.
  - `tabActivationDeactivatesDiff` — `activate(tabNumber: 1)` → `activeDiff == nil`, diff-вкладка осталась; клик по ней → снова активна; `closeDiff()` → нет.
  - `diffKeyRoute` — `↑` при `diffActive: false` → nil; при `true` → `.up`; `⌥B` (option, 11) при false → nil; при `true` и `editingText: true` → nil; ⌘W при `true` → `.close`.
  - `openTargetRules` — выбранная добавленная строка → её `newLine`; выбранная удалённая перед добавленной → `newLine` добавленной; без выбора — первая добавленная; ханки только с удалениями (удалённый файл) → nil; `.binary` → nil.
- [ ] **Step 2:** Run: `swift test --filter DiffTabTests` — Expected: FAIL.
- [ ] **Step 3: Реализовать.**
- [ ] **Step 4:** Run: `swift build && swift test` — Expected: PASS.
- [ ] **Step 5: Проверить вручную** (DEBUG, temp-репо: правки, переименование с пробелом, PNG, файл 25 000 строк, untracked): сверить diff с экраном 2 `style-a-v2.html` (заголовок, ханк, фон строк, колонка номеров); клик по Changes открывает курсивную `±`-вкладку, следующий клик заменяет её; `↑/↓` — соседний файл, выделение в Changes следует; `↩` — Helix на строке (существующий лист и новая вкладка); `⌘W` закрывает только diff; `⌥B` в diff переключает режим, а в shell-вкладке — слово назад (diff не активен); печать букв при активной diff-вкладке не попадает в терминал; после перезапуска приложения diff-вкладки нет.
- [ ] **Step 6: Commit** — `git add Sources/HangarUI Tests/HangarUITests && git commit -m "feat(diff): temporary read-only diff tab with keyboard navigation"`

### Task 9: Приёмка этапа

**Files:**
- Modify: `docs/decisions.md` (дополнения #44 по ходу этапа, «Замеры» этапа 4), `docs/superpowers/stage1-followups.md` (раздел «Этап 4 — нужна проверка глазами»; «Отложено»: строка состояния `⎇ ветка · +N −M · K файлов · статус агента` из §4 — данные уже есть в `InspectorModel.changes`, этап не назначен; подсветка синтаксиса (#44); фильтр игнорируемых путей в FSEvents), этот план (отметки)

- [x] **Step 1:** Run: `swift build && swift test` — Expected: всё PASS (показать сводку).
- [ ] **Step 2: Сценарий** (DEBUG, изолированные `HANGAR_STATE_DIR`/`HANGAR_CONFIG` в /tmp, worktree-задача в temp-репо, claude или shell пишет файлы): инспектор открыт → правка файла из терминала появляется в Changes и бейджем в Files за ≤ 1 с; `git commit` в терминале → файл уходит из «незакоммиченного», остаётся в base; смена задачи — данные другой задачи без мигания старых; Helix открывает файл из Files и строку из diff.
- [ ] **Step 3: Энергия.** Инспектор открыт, агенты в простое 3 мин: `top -l 37 -s 5 -pid <pid> -stats pid,cpu | tail -36` — Expected: 0,0 % в простое; `log stream --predicate 'subsystem == "dev.hangar"'` — нет загрузок без изменений файлов; `pgrep -P <pid> git` в простое — пусто; инспектор скрыт / окно свёрнуто — в логе `watch stop`; правка файла при скрытом инспекторе — ни одного запуска git. Записать в «Замеры».
- [ ] **Step 4: Большой репозиторий.** Клон ≥ 50 000 файлов (например, локальная копия любого крупного репо, уже имеющегося на диске; ничего не устанавливать): открытие инспектора не блокирует UI (окно отвечает на ⌘1…9 во время загрузки), дерево не раскрыто автоматически, при > 5 000 изменений — пометка.
- [x] **Step 5: Commit** — `git add docs && git commit -m "docs: stage 4 acceptance"`
