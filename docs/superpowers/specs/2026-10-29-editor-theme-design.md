# Тема редактора и его настройки — дизайн (на согласование)

Макет: `docs/superpowers/mockups/editor-theme.html` (Настройки → Редактор, Dark+ и Navy, живой).
Просьба владельца: «тема в редакторе не такая, как у меня в VS Code». Решения владельца: импорта из VS Code нет
(ни кнопки, ни поиска, ни синхронизации); цвета его VS Code сняты один раз сейчас и зашиты в Hangar как встроенная тема;
плюс «Своя» тема с интерактивным редактором цветов и превью, плюс больше опций редактора.

## 1. Что стоит у владельца (снято 29.10, только чтение)
- `~/Library/Application Support/Code/User/settings.json`: `"workbench.colorTheme": "Dark Modern"`, без
  `editor.tokenColorCustomizations` / `workbench.colorCustomizations`. Cursor и VSCodium не установлены.
- Тема — встроенная `theme-defaults/themes/dark_modern.json` → `include: dark_plus.json` → `include: dark_vs.json`.
  **Синтаксис у Dark Modern — ровно Dark+**: dark_modern.json меняет только цвета интерфейса.
- Опции редактора: `editor.fontSize 12`, `editor.tabSize 2`, `editor.minimap.enabled false`, `editor.renderWhitespace "none"`,
  `editor.renderControlCharacters true`, `editor.formatOnPaste true`, `editor.codeActionsOnSave {source.fixAll}`;
  шрифт и высота строки — по умолчанию (macOS: Menlo, высота `round(12 × 1.5) = 18`). Курсор, мигание, текущая строка — по умолчанию
  VS Code (`line`, `blink`, `line`).
- Расширения: indent-rainbow, vscode-todo-highlight (у Hangar уже есть аналоги #84), иконки JetBrains. Тем из расширений нет.

Почему «не такая»: в Hangar сейчас Dark+ на фоне темы оформления — фон `#1e1e1e` вместо `#1f1f1f`, текст `#d4d4d4` вместо `#cccccc`,
номера `#858585` вместо `#6e7681`, курсор синий `accent` вместо серого `#aeafad`, текущая строка заливкой вместо рамки,
шрифт SF Mono 13/20 вместо Menlo 12/18. Таблица разницы — внизу макета.

## 2. Новая встроенная тема «VS Code Dark Modern» (`editor_palette = "dark-modern"`)
Значения — из dark_modern.json, недостающие — из dark_plus/dark_vs и из реестра цветов по умолчанию (`registerColor`, проверено
в нашем `Monaco/vs/editor-*.js`, Monaco 0.57 = VS Code). В отличие от «Dark+» и «Hangar», цвета интерфейса редактора у этой темы
свои и от темы оформления не зависят (как в VS Code). Виджеты (поиск, подсказки, меню) остаются в цветах Hangar (`sheet`, рамки).

Синтаксис (TextMate-скоуп VS Code → токен Monaco в `MonacoTheme.rules` → цвет):

| VS Code scope | Monaco token (Monarch / semantic) | Цвет |
|---|---|---|
| `keyword`, `storage`, `storage.type`, `constant.language`, `variable.language`, `entity.name.tag` | `keyword`, `tag`, `metatag`, `keyword.json` | `#569CD6` |
| `keyword.control` (+ import/export/return/await…) | `keyword.control` (наш патч Monarch `CONTROL`) | `#C586C0` |
| `variable`, `meta.object-literal.key`, `support.variable`, `entity.other.attribute-name` | `identifier`, `variable`, `parameter`, `property`, `attribute.name` | `#9CDCFE` |
| `support.type.property-name.json` | `string.key.json` | `#9CDCFE` |
| `entity.name.type/class/namespace`, `support.type/class` | `type`, `type.identifier`, `class`, `interface`, `enum`, `namespace`, `typeParameter`, `annotation` | `#4EC9B0` |
| `entity.name.function`, `support.function` | `function`, `member`, `predefined` | `#DCDCAA` |
| `variable.other.constant`, `variable.other.enummember` | `constant` (наш патч ALL_CAPS), `enumMember` | `#4FC1FF` |
| `string`, `string.value` | `string`, `string.value.json`, `attribute.value` | `#CE9178` |
| `constant.character.escape` | `string.escape` | `#D7BA7D` |
| `string.regexp` | `regexp` | `#D16969` |
| `constant.numeric` | `number` | `#B5CEA8` |
| `comment` | `comment`, `comment.doc` | `#6A9955` |
| `keyword.operator` | `operator` | `#D4D4D4` |
| пунктуация (своего цвета нет → `editor.foreground`) | `delimiter`, `delimiter.bracket` | `#CCCCCC` |
| текст без скоупа (`editor.foreground`) | `""` | `#CCCCCC` |

Отличие от нынешнего `dark-plus` в правилах — только две последние строки (`#D4D4D4` → `#CCCCCC`).

Интерфейс редактора (ключ VS Code → ключ Monaco в `MonacoTheme.colors` → значение):

| VS Code | Monaco | Значение | Источник |
|---|---|---|---|
| `editor.background` | то же, + `editorGutter.background`, `minimap.background`, `peekViewEditor.background` | `#1F1F1F` | dark_modern |
| `editor.foreground` | то же | `#CCCCCC` | dark_modern |
| `editorLineNumber.foreground` / `.activeForeground` | то же | `#6E7681` / `#CCCCCC` | dark_modern |
| `editorCursor.foreground` | то же | `#AEAFAD` | реестр (dark) |
| `editor.lineHighlightBorder` (заливки нет) | то же; `lineHighlightBackground` не задаём | `#282828` | реестр |
| `editor.selectionBackground` / `inactiveSelectionBackground` | то же | `#264F78` / `#3A3D41` | реестр / dark_vs |
| `editorIndentGuide.background1` / `activeBackground1` | то же | `#404040` / `#707070` | dark_vs |
| `editorWhitespace.foreground` | то же | `#E3E4E229` | реестр |
| `editor.findMatchBackground` / `findMatchHighlightBackground` | то же | `#9E6A03` / `#EA5C0055` | dark_modern / реестр |
| `editorBracketMatch.background` / `.border` | то же | `#0064001A` / `#888888` | реестр |
| `editorBracketHighlight.foreground1–3` | то же | `#FFD700` `#DA70D6` `#179FFF` | реестр (уже так) |
| `diffEditor.insertedLineBackground` / `removedLineBackground` | то же (+ `diffEditorGutter.*`) | `#9BB95533` / `#FF000033` | реестр |
| `diffEditor.insertedTextBackground` / `removedTextBackground` | то же | `#9CCC2C33` / `#FF000033` | реестр |

Опции, которые совпадут с VS Code владельца, — значения по умолчанию в новых настройках (§4) не меняем; владелец ставит их сам
(шрифт Menlo, 12, высота авто, табуляция 2). Предлагаю одно исключение: «Высота строки = авто (1,5 × размер)» по умолчанию,
как в VS Code, вместо фиксированных 20.

## 3. «Своя» тема и редактор цветов
- Плитки тем: «VS Code Dark Modern», «VS Code Dark+», «Hangar», «Своя» (мини-превью кода в цветах темы, выбранная — контур `accent` 2 pt,
  как плитки Оформления).
- Список цветов: 15 групп синтаксиса, 11 цветов редактора (скобки — тройка образцов в одной строке), 4 цвета diff. Строка: образец,
  название, hex `text3`; изменённая — точка `accentText` слева, под курсором hex сменяется кнопкой «Сбросить» (↺).
  Наведение на строку приглушает в превью всё, кроме её токенов (или обводит её область: выделение, текущую строку, курсор, diff).
  Клик по слову в превью открывает цвет его группы.
- Поповер цвета (`NSPopover`): образец и название, поле HEX (+ α для полупрозрачных: выделение, пробелы, найденное, diff), полосы
  оттенка и яркости, сетка «Цвета этой темы» (чтобы не плодить новые цвета), «Системная палитра…» (`NSColorPanel`, пипетка),
  «Сбросить». Изменение применяется сразу и записывается в конфиг (без «Применить»).
- Изменение цвета во встроенной теме создаёт «Свою» на её основе и переключает на неё (строка под страницей:
  «Создана тема «Своя» на основе …»). Встроенные темы не меняются. Если в «Своей» уже есть изменения на другой основе —
  сначала `ConfirmSheet` «Заменить свою тему?».
- «Сбросить всё» (действие в строке-подсказке под плитками) — только у «Своей».
- Превью — те же разметка и шрифт, что у Monaco, с сегментом «Всё / TypeScript / JSON / Diff»; в приложении это маленькая страница
  Monaco только для чтения (тот же `hangar-editor://`, своя модель, без tsserver: группы функций/переменных в TS-образце
  ставятся статической разметкой токенов, а не семантикой).

## 4. Новые опции редактора (все есть в Monaco, кроме отмеченного)
| Строка | Значения | Monaco |
|---|---|---|
| Шрифт | моноширинные шрифты системы (`NSFontManager`), по умолчанию `SF Mono` (как сейчас) | `fontFamily` |
| Размер | 9–24, 13 | `fontSize` |
| Высота строки | авто или 10–40 pt | `lineHeight` (0 = авто) |
| Лигатуры | вкл/выкл | `fontLigatures` |
| Ширина табуляции | 2 / 4 / 8 | модель `tabSize` |
| Определять по файлу | вкл | `detectIndentation` |
| Перенос строк | Нет / По ширине окна | `wordWrap off/on` |
| Текущая строка | Нет / Номер / Строка / Номер и строка | `renderLineHighlight none/gutter/line/all` |
| Курсор | Линия / Блок / Подчёркивание | `cursorStyle` |
| Мигание курсора | Мигает / Плавно / Не мигает | `cursorBlinking blink/smooth/solid` |
| Пробелы | Не показывать / В выделении / Все | `renderWhitespace none/selection/all` |
| Скобки по глубине | вкл | `bracketPairColorization.enabled` |
| Направляющие скобок | Нет / Активная пара / Все | `guides.bracketPairs false/'active'/true` |
| Направляющие отступов | вкл | `guides.indentation` |
| Радужные отступы, Подсветка TODO | как сейчас (#84) | наши декорации |
| Форматировать при сохранении | выкл | **не Monaco**: Hangar на ⌘S сначала шлёт уже существующий запрос `format` (tsserver/LSP), потом пишет файл; нет сервера — просто сохраняет |

Не выносим: миникарта (уже переключатель в строке состояния — без повторов), формат при вставке (нужен range formatting,
его у нас нет), `wordSeparators`, `unicodeHighlight`, `renderControlCharacters` (в Monaco и так вкл).

## 5. Данные
Всё в `~/.config/hangar/config.toml`, плоскими ключами — `ConfigWriter` умеет только ключи верхнего уровня, отдельный файл темы в
state dir не нужен (≈ 30 строк, править руками удобно, один источник настроек):
```toml
editor_palette = "custom"            # dark-modern | dark-plus | hangar | custom
editor_custom_base = "dark-modern"   # основа «Своей»
editor_color_string = "#d69d85"      # только изменённые; ключи — id групп: keyword, control, string, escape, regexp,
editor_color_background = "#1b1b1b"  # comment, number, type, function, variable, constant, json_key, punctuation, operator,
                                     # text, background, line, selection, find, gutter, gutter_active, cursor, indent,
                                     # indent_active, whitespace, bracket1..3, diff_added_line, diff_removed_line,
                                     # diff_added_text, diff_removed_text
editor_font_family = "Menlo"
editor_font_size = "12"
editor_line_height = "0"
editor_ligatures = false
editor_tab_size = "2"
editor_detect_indentation = true
editor_word_wrap = "off"
editor_line_highlight = "line"
editor_cursor_style = "line"
editor_cursor_blinking = "blink"
editor_whitespace = "none"
editor_bracket_colors = true
editor_bracket_guides = "active"
editor_indent_guides = true
editor_format_on_save = false
```
- `HangarConfig`: `EditorPalette` + `.darkModern`, `.custom`; `editorCustomBase`; `editorColors: [EditorColor: String]`;
  поля опций. Парсер: `editor_color_*` — неизвестный id → `unknownKey`, значение — `#rgb` / `#rrggbb` / `#rrggbbaa`, иначе
  `syntax` (как остальные ключи); числа — в диапазоне.
- `ConfigWriter.remove(key:)` — для «Сбросить» (удалить строку `editor_color_*`, комментарии и порядок остальных строк не трогать).
- `MonacoTheme`: таблица группа → токены Monaco (одна, общая для всех тем), значения групп по теме; `json(_:)` собирает rules/colors из
  `[группа: цвет]` поверх темы. Для «Своей»: цвета основы + `editorColors`; цвета интерфейса, которые не менялись, у основы
  «Dark+»/«Hangar» по-прежнему идут от темы оформления.

## 6. Живое применение
Уже есть путь: `setEditorAppearance` → `onEditorAppearance(EditorAppearance)` → каждая страница Monaco `setLook` →
`defineTheme` + `setTheme` (курсоры, undo и прокрутка сохраняются). Расширяем `EditorAppearance` полем `options` → в `setLook`
`editor.updateOptions(...)` (и у обеих сторон diff), `tabSize` / `detectIndentation` — на модели новых файлов (открытые не трогаем:
у них уже определён отступ). Перетаскивание по полосе оттенка — превью в настройках обновляется на каждый кадр, а в открытые редакторы
и в конфиг уходит одно значение по отпусканию (без записи файла на каждый пиксель).

## 7. Точность сопоставления VS Code → Monaco и рекомендация
Monaco красит Monarch-токенами (≈ 15 классов: keyword, string, identifier, type.identifier, number, comment, delimiter…) и
семантикой tsserver/LSP (class, function, variable, property…). TextMate-скоупы VS Code намного мельче. Для семейства Dark+
(≈ 12 цветов) таблица §2 покрывает почти всё. Расходится:
- TS до готовности tsserver (и JS без проекта): вызовы функций и типы в позиции значения — цвета переменных;
- `${…}` в шаблонных строках (VS Code — `#569CD6`), внутренности регулярных выражений (группы, классы, квантификаторы — у VS Code
  4 цвета, у нас один), JSX-теги и атрибуты;
- YAML, Markdown, Python, Go, Swift и др.: Monarch-грамматики грубее TextMate (декораторы, ключи YAML, заголовки Markdown —
  совпадут лишь частично); у языков с LSP семантика добирает классы, функции, параметры.
Полная точность = TextMate-токенизатор в Monaco: `vscode-textmate` + `vscode-oniguruma` (WASM ≈ 460 КБ) + грамматики языков
(.tmLanguage.json из VS Code, ≈ 1–3 МБ на десяток языков), свой `EncodedTokensProvider`, токенизация на главном потоке страницы
(медленнее Monarch на больших файлах), новая зависимость и её обновления, запись в `decisions.md`.
**Рекомендация: не делать.** Владелец использует встроенный Dark Modern — его синтаксис дают таблица §2 и семантика,
заметная разница была в интерфейсе и шрифте, а не в токенах. Вернуться, только если понадобится точная подсветка
конкретного языка (тогда — TextMate только для него).

## 8. Вне рамок
Импорт из VS Code (кнопка, поиск тем, синхронизация), темы из расширений VS Code, светлые темы, `tokenColorCustomizations`,
наследование тем (`include`), курсив/жирный на группу (только курсив комментариев у «Hangar», как сейчас), экспорт темы.

## 9. Тесты
- `ConfigTests`: разбор новых ключей и значения по умолчанию; плохой hex и неизвестная группа → ошибка с номером строки; запись и
  удаление `editor_color_*` не трогают соседние строки и комментарии.
- `MonacoThemeTests` (новый): `dark-modern` даёт значения таблиц §2 (сверка списком, как `ThemePaletteTests` с макетом);
  `custom` = основа + переопределения; у основы `dark-plus` не изменённые цвета интерфейса следуют теме оформления (navy ≠ dark-plus);
  у каждой группы есть хотя бы одно правило; контраст текста и комментариев на фоне ≥ 4.5 / 3 у встроенных тем.
- `EditorAppearance.json` содержит опции; значения опций уходят в Monaco как ожидается (`cursorBlinking`, `guides.bracketPairs`).
- Живая проверка (`hangar-test`, DEBUG с `HANGAR_CONFIG`/`HANGAR_STATE_DIR`): открыть .ts и diff, сменить тему и цвет в настройках —
  открытые редакторы перекрашиваются без перезагрузки, курсор и undo на месте; скриншоты сверить с макетом.

## Вопросы владельцу
1. Делать «VS Code Dark Modern» темой редактора по умолчанию для новых установок (сейчас — «VS Code Dark+»)?
2. Высота строки «авто» по умолчанию (как в VS Code) — да?
