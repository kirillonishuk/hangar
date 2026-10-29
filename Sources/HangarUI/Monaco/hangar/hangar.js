// Hangar ↔ Monaco (decision #80). Swift drives through `hangar.receive(cmd)`; the page answers with
// `post(msg)` (validated in Swift: BridgeMessage). One page is either the editor of every file tab (#83: a model per
// tab, keyed by its `doc`, the Hangar tab strip outside the page) or the diff (keyed by path).
'use strict';
(function () {
  const cfg = window.hangarConfig;
  const post = (m) => window.webkit.messageHandlers.hangar.postMessage(JSON.stringify(m));
  window.addEventListener('error', (e) => post({ type: 'log', text: `${e.message} ${e.filename}:${e.lineno}` }));
  window.addEventListener('unhandledrejection', (e) => post({ type: 'log', text: 'rejection: ' + String(e.reason && (e.reason.stack || e.reason)) }));
  const applyCss = (css) => { for (const [k, v] of Object.entries(css)) document.documentElement.style.setProperty(k, v); };
  applyCss(cfg.appearance.css);
  if (cfg.mode === 'diff') document.body.classList.add('diff');

  const $ = (id) => document.getElementById(id);
  const files = new Map();   // doc (diff: path) → { doc, path, model, view, readOnly, notice, conflict, saved, dirty, refused, at }
  let active = null;         // the shown doc (diff: path)
  const keyOf = (c) => c.doc || c.path;
  // Every message about a file names its tab (`doc`) and its path.
  const postFile = (f, m) => post(Object.assign(m, { doc: f.doc, file: f.path }));
  let editor = null, diff = null, monaco = null;
  let diffPath = null, inline = !!cfg.inline, minimap = !!cfg.minimap;
  let look = cfg.appearance;   // { palette, rainbow, todo, themes, css, options, formatOnSave } (Settings → Editor #84, #108)
  const queue = [];
  const pending = new Map(); // provider request id → resolve

  $('bar-reload').textContent = cfg.strings.reload;
  $('bar-keep').textContent = cfg.strings.keepMine;
  $('bar-text').textContent = cfg.strings.conflict;
  const conflictChoice = (keepMine) => { const f = active && files.get(active); if (f) postFile(f, { type: 'conflict', keepMine }); };
  $('bar-reload').onclick = () => conflictChoice(false);
  $('bar-keep').onclick = () => conflictChoice(true);

  function boot() {
    require.config({ paths: { vs: '../vs' } });
    require(['vs/editor/editor.main'], () => { try { start(); } catch (e) { post({ type: 'log', text: 'start: ' + (e && e.stack || e) }); } },
      (e) => post({ type: 'log', text: 'load: ' + (e && e.message || e) }));
  }
  // Russian UI strings: a plain script that sets the message table before the editor loads (not an AMD module).
  if (cfg.lang === 'ru') {
    const s = document.createElement('script');
    s.src = '../vs/nls/lang/ru.js';
    s.onload = s.onerror = boot;
    document.head.appendChild(s);
  } else {
    boot();
  }
  function start() {
    monaco = window.monaco;
    // Only the editor worker is bundled: the TS/CSS/HTML/JSON language services are dropped (the language server, M2,
    // gives definitions and diagnostics); Monarch highlighting stays.
    const env = self.MonacoEnvironment, make = env && env.getWorker;
    if (make) env.getWorker = (id) => make(id, 'editorWorkerService');
    const off = { completionItems: false, hovers: false, documentSymbols: false, definitions: false, references: false,
      documentHighlights: false, rename: false, diagnostics: false, documentRangeFormattingEdits: false,
      signatureHelp: false, onTypeFormattingEdits: false, codeActions: false, inlayHints: false, links: false,
      colors: false, foldingRanges: false, selectionRanges: false, tokens: false, documentFormattingEdits: false };
    // JSON has no Monarch grammar: its tokens (keys, strings, numbers) come from the json mode's own tokenizer, which
    // runs on the main thread with no worker. Switching `tokens` off with the rest left every .json plain white.
    const jsonOn = Object.assign({}, off, { tokens: true });
    const ls = monaco.languages, mts = monaco.typescript || ls.typescript;
    try { ls.json && ls.json.jsonDefaults.setModeConfiguration(jsonOn); } catch (e) { /* not in this build */ }
    extraExtensions();
    for (const d of [mts && mts.typescriptDefaults, mts && mts.javascriptDefaults,
      ls.css && ls.css.cssDefaults, ls.css && ls.css.scssDefaults, ls.css && ls.css.lessDefaults, ls.html && ls.html.htmlDefaults]) {
      try { d && d.setModeConfiguration(off); } catch (e) { /* not in this build */ }
    }
    defineThemes(look.themes);
    patchTokenizers();
    // Hangar's palette (⌘P / ⇧⌘P) is the one palette: Monaco's F1 command palette is unbound.
    monaco.editor.addKeybindingRules([
      { keybinding: monaco.KeyCode.F1, command: '-editor.action.quickCommand' },
      { keybinding: monaco.KeyMod.CtrlCmd | monaco.KeyMod.Shift | monaco.KeyCode.KeyP, command: '-editor.action.quickCommand' },
    ]);
    registerProviders();
    // Font, cursor, guides, whitespace, wrap, tab size: Settings → Editor (look.options), also live in setLook.
    const common = Object.assign({ theme: 'hangar-' + look.palette,
      automaticLayout: true, minimap: { enabled: minimap }, scrollBeyondLastLine: false, smoothScrolling: false,
      fixedOverflowWidgets: true, contextmenu: false,
      scrollbar: { verticalScrollbarSize: 10, horizontalScrollbarSize: 10, useShadows: false }, padding: { top: 6 },
      stickyScroll: { enabled: false }, overviewRulerBorder: false, hideCursorInOverviewRuler: true, mouseWheelZoom: false,
      'semanticHighlighting.enabled': true }, look.options);
    if (cfg.mode === 'diff') {
      diff = monaco.editor.createDiffEditor($('host'), Object.assign({}, common, {
        renderSideBySide: !inline, originalEditable: false, readOnly: true, renderOverviewRuler: false,
        hideUnchangedRegions: { enabled: false }, useInlineViewWhenSpaceIsLimited: false, ignoreTrimWhitespace: false,
        lineDecorationsWidth: 26 }));  // the +/- marker sits centred here, clear of the number and the code
      wireDiff();
      decorations(diff.getOriginalEditor());
      decorations(diff.getModifiedEditor());
    } else {
      editor = monaco.editor.create($('host'), Object.assign({}, common, { model: null }));
      wireEditor(editor);
      decorations(editor);
    }
    window.hangar.ready = true;
    post({ type: 'ready' });
    while (queue.length) receive(queue.shift());
  }

  // Files Monaco's own lists miss: the same grammar under more names (registering an id again adds to it). There is
  // no TOML grammar; INI's (sections, key = value, # comments) is the closest.
  const MORE = { json: ['.jsonc', '.json5', '.geojson', '.webmanifest', '.code-workspace', '.mcmeta', '.jsonl'],
    ini: ['.toml', '.cfg', '.conf', '.env'], shell: ['.zsh', '.ksh', '.zshrc', '.bashrc', '.zprofile', '.bash_profile', '.profile', '.envrc'],
    yaml: ['.yaml', '.yml'], javascript: ['.mjs', '.cjs'], typescript: ['.mts', '.cts'], xml: ['.plist', '.xib', '.storyboard', '.svg'] };
  function extraExtensions() {
    for (const [id, extensions] of Object.entries(MORE)) monaco.languages.register({ id, extensions });
    monaco.languages.register({ id: 'dockerfile', filenamePatterns: ['Dockerfile.*', '*.Dockerfile'] });
  }

  // MARK: Editor

  function wireEditor(ed) {
    wireMenu(ed);
    ed.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => save());
    ed.addCommand(monaco.KeyMod.WinCtrl | monaco.KeyCode.Minus, () => navigate(back, fwd));
    ed.addCommand(monaco.KeyMod.WinCtrl | monaco.KeyMod.Shift | monaco.KeyCode.Minus, () => navigate(fwd, back));
    ed.onDidFocusEditorText(() => { const f = active && files.get(active); post(f ? { type: 'focus', doc: f.doc } : { type: 'focus' }); });
    let timer = null;
    // One-shot, only after a move: the cursor is kept for restore without a message per keystroke.
    ed.onDidChangeCursorPosition(() => {
      clearTimeout(timer);
      timer = setTimeout(() => {
        const p = ed.getPosition(), f = fileOf(ed.getModel());
        if (p && f) postFile(f, { type: 'cursor', line: p.lineNumber, column: p.column });
      }, 400);
    });
  }

  function fileOf(model) {
    if (!model) return null;
    for (const f of files.values()) if (f.model === model) return f;
    return null;
  }
  const activePath = () => { const f = active && files.get(active); return f ? f.path : null; };

  function save() {
    const f = active && files.get(active);
    if (f && f.model && !f.readOnly) formatThen(editor, () => postFile(f, { type: 'save', text: f.model.getValue() }));
  }

  // «Форматировать при сохранении» (#108): the language server's format first (the menu's own action, so only files
  // with a provider), then the save; a server that doesn't answer in 3 s doesn't hold the save up.
  function formatThen(ed, then) {
    const action = look.formatOnSave && ed.getAction('editor.action.formatDocument');
    if (!action || !action.isSupported()) { then(); return; }
    let done = false;
    const finish = () => { if (!done) { done = true; then(); } };
    Promise.race([action.run(), new Promise((r) => setTimeout(r, 3000))]).then(finish, finish);
  }

  // Buffers with a language server are mirrored there (tsserver #82, LSP #90): every change goes to Swift as an
  // incremental edit.
  const tsLike = /\.((m|c)?[jt]sx?|pyi?|swift|go|rs)$/i;

  // A tab's file arrives (also for tabs not on screen: their models wait). One file open in two sessions' tabs is
  // two buffers.
  function open(c) {
    // The doc already here (a pane moved back with its buffer, a load racing a move): the new text replaces it.
    if (files.has(c.doc)) { const shown = active === c.doc; close(c.doc); if (shown) active = c.doc; }
    const f = { doc: c.doc, path: c.path, readOnly: c.readOnly, notice: c.notice, conflict: false, dirty: false,
      refused: c.text == null, view: null, model: null, at: { line: c.line, column: c.column } };
    if (c.text != null) {
      dropPreview(c.path);
      // The plain file URI (titles, peeks read it); a second tab of the same file (another session) gets its own.
      const plain = monaco.Uri.file(c.path);
      f.model = monaco.editor.createModel(c.text, undefined,
        monaco.editor.getModel(plain) ? monaco.Uri.from({ scheme: 'file', authority: c.doc.toLowerCase(), path: c.path }) : plain);
      // A moved unsaved buffer (c.dirty) matches no saved version until it is saved.
      f.saved = c.dirty ? -1 : f.model.getAlternativeVersionId();
      f.dirty = !!c.dirty;
      const mirror = tsLike.test(c.path);
      f.model.onDidChangeContent((e) => {
        if (mirror) postFile(f, { type: 'edit', changes: e.changes.map((ch) => ({ line: ch.range.startLineNumber,
          column: ch.range.startColumn, endLine: ch.range.endLineNumber, endColumn: ch.range.endColumn, text: ch.text })) });
        if (f.reloading) return;  // the disk's text replacing a clean buffer: still clean (Swift knows)
        const dirty = f.model.getAlternativeVersionId() !== f.saved;
        if (dirty !== f.dirty) { f.dirty = dirty; postFile(f, { type: 'changed', dirty }); }
      });
    }
    files.set(c.doc, f);
    if (active === c.doc) show(f, c.line, c.column);
  }

  // The tab on screen (Swift's `activate`): its model in the editor, with its own view state; a line moves the cursor.
  function activate(doc, line, column) {
    const cur = active && files.get(active);
    if (cur && cur.model && active !== doc && editor.getModel() === cur.model) cur.view = editor.saveViewState();
    active = doc;
    const f = files.get(doc);
    if (!f) { editor.setModel(null); renderChrome(); return; }  // its file is still loading
    show(f, line, column);
  }

  function show(f, line, column) {
    if (editor.getModel() !== f.model) editor.setModel(f.model);
    editor.updateOptions({ readOnly: f.readOnly });
    if (f.model && f.view && !line) editor.restoreViewState(f.view);
    else if (f.model && !line && f.at) { line = f.at.line; column = f.at.column; }
    f.at = null;
    if (f.model && line) {
      const pos = { lineNumber: line, column: column || 1 };
      editor.setPosition(pos);
      editor.revealPositionInCenterIfOutsideViewport(pos);
    }
    renderChrome();
    if (f.model) editor.focus();
  }

  function close(doc) {
    const f = files.get(doc);
    if (!f) return;
    if (editor && editor.getModel() === f.model) editor.setModel(null);
    if (f.model) f.model.dispose();
    files.delete(doc);
    if (active === doc) active = null;
    renderChrome();
  }

  function renderChrome() {
    const f = active && files.get(active);
    $('bar').hidden = !(f && f.conflict);
    $('notice').hidden = !(f && f.notice && !f.refused);
    $('notice').textContent = (f && f.notice) || '';
    $('refused').hidden = !(f && f.refused);
    $('refused').textContent = (f && f.refused && f.notice) || '';
  }

  function reload(doc, text) {
    const f = files.get(doc);
    if (!f || !f.model) return;
    const view = doc === active ? editor.saveViewState() : null;
    // An edit, not setValue: undo can go back past the reload.
    f.reloading = true;
    f.model.pushEditOperations([], [{ range: f.model.getFullModelRange(), text }], () => null);
    f.reloading = false;
    f.saved = f.model.getAlternativeVersionId();
    f.dirty = false;
    if (view) editor.restoreViewState(view);
    renderChrome();
  }

  // MARK: Looks (#84): Dark+ tokens, rainbow indents, TODO pills

  // Monarch can't tell `import`/`return` (control flow, purple in Dark+) from `const` (blue), nor an UPPER_CASE
  // constant: the TS/JS tokenizers get both, once, from their own definitions.
  const CONTROL = ['import', 'export', 'from', 'as', 'return', 'if', 'else', 'for', 'while', 'do', 'switch', 'case',
    'break', 'continue', 'throw', 'try', 'catch', 'finally', 'default', 'await', 'yield', 'with'];
  // Our own tokens factory for TS/JS (registered before any model, so it replaces Monaco's): its Monarch
  // definition with the control-flow keywords and ALL_CAPS constants added.
  function patchTokenizers() {
    for (const id of ['typescript', 'javascript']) {
      const def = monaco.languages.getLanguages().find((l) => l.id === id);
      if (!def || !def.loader) continue;
      monaco.languages.registerTokensProviderFactory(id, { create: () => def.loader().then((mod) => {
        const lang = Object.assign({}, mod.language, { control: CONTROL });
        const common = (lang.tokenizer.common || []).map((rule) => {
          if (!Array.isArray(rule)) return rule;
          const cases = rule[1] && rule[1].cases;
          if (cases && cases['@keywords']) {
            return [rule[0], { cases: Object.assign({ '@control': 'keyword.control', '@keywords': 'keyword' }, cases) }];
          }
          // Capitalised names are types to Monarch; ALL_CAPS ones are constants.
          if (rule[1] === 'type.identifier') return [rule[0], { cases: { '[A-Z][A-Z0-9_]+': 'constant', '@default': 'type.identifier' } }];
          return rule;
        });
        lang.tokenizer = Object.assign({}, lang.tokenizer, { common });
        return lang;
      }) });
    }
  }

  // Rainbow indents (indent-rainbow's faint bands) and TODO/FIXME/HACK/XXX pills in comments: decorations for the
  // visible lines only, recomputed once per frame after a scroll, an edit or a model switch (no timer otherwise).
  const TODO = /\b(TODO|FIXME|HACK|XXX)\b:?/g;
  function decorations(ed) {
    const set = ed.createDecorationsCollection();
    let queued = false;
    const run = () => {
      queued = false;
      const model = ed.getModel();
      if (!model || (!look.rainbow && !look.todo)) { set.clear(); return; }
      const indent = model.getOptions().indentSize || model.getOptions().tabSize || 4;
      const out = [];
      for (const r of ed.getVisibleRanges()) {
        for (let n = r.startLineNumber; n <= r.endLineNumber; n++) {
          const text = model.getLineContent(n);
          if (look.rainbow) {
            let col = 0, width = 0, level = 0, start = 0;
            while (col < text.length && (text[col] === ' ' || text[col] === '\t')) {
              width += text[col] === '\t' ? indent - (width % indent) : 1;
              col++;
              if (width % indent === 0) {
                out.push({ range: new monaco.Range(n, start + 1, n, col + 1), options: { inlineClassName: 'ir ir' + (level % 4) } });
                level++; start = col;
              }
            }
          }
          if (look.todo) {
            const slash = text.indexOf('//'), block = text.indexOf('/*');
            const from = slash >= 0 ? slash : block >= 0 ? block : /^\s*\*/.test(text) ? 0 : -1;
            if (from < 0) continue;
            TODO.lastIndex = from;
            for (let m; (m = TODO.exec(text));) {
              out.push({ range: new monaco.Range(n, m.index + 1, n, m.index + m[0].length + 1),
                options: { inlineClassName: 'todo todo-' + m[1].toLowerCase() } });
            }
          }
        }
      }
      set.set(out);
    };
    const later = () => { if (!queued) { queued = true; requestAnimationFrame(run); } };
    ed.onDidScrollChange(later);
    ed.onDidChangeModelContent(later);
    ed.onDidChangeModel(later);
    ed.onDidLayoutChange(later);
    redecorate.push(later);
  }
  const redecorate = [];

  function defineThemes(themes) {
    for (const [name, theme] of Object.entries(themes)) monaco.editor.defineTheme('hangar-' + name, theme);
  }

  // App theme or editor setting changed: no reload, so cursors, undo and scroll stay.
  function setLook(c) {
    look = c;
    applyCss(c.css);
    defineThemes(c.themes);
    monaco.editor.setTheme('hangar-' + look.palette);
    if (editor) editor.updateOptions(look.options);
    if (diff) diff.updateOptions(look.options);
    redecorate.forEach((f) => f());
  }

  // MARK: Context menu

  // Hangar's own menu instead of Monaco's (that one lists «Command Palette» and VS Code commands, #81): a fixed list,
  // greyed when the editor can't run an item (no language provider yet, read-only). Labels come from Hangar's L10n.
  const MENU = [
    { action: 'editor.action.revealDefinition', label: 'definition', keys: 'F12', provider: true },
    { action: 'editor.action.goToReferences', label: 'references', keys: '⇧F12', provider: true },
    { action: 'editor.action.rename', label: 'rename', keys: 'F2', edits: true },
    null,
    { action: 'editor.action.formatDocument', label: 'format', keys: '⇧⌥F', edits: true },
    { action: 'editor.action.commentLine', label: 'comment', keys: '⌘/', edits: true },
    null,
    { clipboard: 'cut', label: 'cut', keys: '⌘X', edits: true },
    { clipboard: 'copy', label: 'copy', keys: '⌘C' },
    { clipboard: 'paste', label: 'paste', keys: '⌘V', edits: true },
  ];
  let menu = null;   // { el, items: [{ el, run }], sel }

  function wireMenu(ed) {
    ed.getContainerDomNode().addEventListener('contextmenu', (e) => e.preventDefault(), true);  // no WebKit menu either
    ed.onContextMenu((e) => {
      // As in VS Code: a right click outside the selection moves the cursor there first.
      const pos = e.target.position, sel = ed.getSelection();
      if (pos && sel && !sel.containsPosition(pos)) ed.setPosition(pos);
      ed.focus();
      showMenu(ed, e.event.posx, e.event.posy);
    });
  }

  function showMenu(ed, x, y) {
    hideMenu();
    const readOnly = ed.getOption(monaco.editor.EditorOption.readOnly);
    const el = document.createElement('div');
    el.className = 'ctx';
    const items = [];
    for (const m of MENU) {
      if (!m) {
        if (el.lastChild && !el.lastChild.classList.contains('sep')) { const sep = document.createElement('div'); sep.className = 'sep'; el.appendChild(sep); }
        continue;
      }
      // Go-to commands are not editor actions in this Monaco (`getAction` is null): our '*' providers answer for
      // every file model, so they're on there and run through `trigger`, as F12 does.
      const a = m.action && !m.provider && ed.getAction(m.action);
      const model = ed.getModel();
      const on = !(m.edits && readOnly) && (m.clipboard ? true
        : m.provider ? !!(model && model.uri.scheme === 'file') : !!(a && a.isSupported()));
      const row = document.createElement('div');
      row.className = 'item' + (on ? '' : ' off');
      const label = document.createElement('span');
      label.textContent = cfg.menu[m.label] || m.label;
      const keys = document.createElement('span');
      keys.className = 'keys';
      keys.textContent = m.keys;
      row.append(label, keys);
      // mousedown, not click: the editor keeps its focus and selection (the clipboard commands act on them).
      row.addEventListener('mousedown', (e) => { e.preventDefault(); e.stopPropagation(); });
      if (on) {
        const run = () => { hideMenu(); ed.focus(); if (m.clipboard) post({ type: 'clipboard', action: m.clipboard }); else if (a) a.run(); else ed.trigger('menu', m.action, null); };
        row.addEventListener('mouseup', (e) => { if (e.button === 0) run(); });
        row.addEventListener('mouseenter', () => select(items.findIndex((i) => i.el === row)));
        items.push({ el: row, run });
      }
      el.appendChild(row);
    }
    document.body.appendChild(el);
    // Inside the page: flipped left / up at the edges.
    const w = el.offsetWidth, h = el.offsetHeight, W = window.innerWidth, H = window.innerHeight;
    el.style.left = Math.max(0, x + w > W ? x - w : x) + 'px';
    el.style.top = Math.max(0, y + h > H ? y - h : y) + 'px';
    menu = { el, items, sel: -1 };
  }

  function select(i) {
    if (!menu) return;
    menu.items.forEach((it, k) => it.el.classList.toggle('sel', k === i));
    menu.sel = i;
  }

  function hideMenu() { if (menu) { menu.el.remove(); menu = null; } }

  window.addEventListener('mousedown', (e) => { if (menu && !menu.el.contains(e.target)) hideMenu(); }, true);
  window.addEventListener('blur', hideMenu);
  window.addEventListener('resize', hideMenu);
  window.addEventListener('wheel', hideMenu, true);
  // While open, the keys drive the menu (the editor keeps focus underneath).
  window.addEventListener('keydown', (e) => {
    if (!menu) return;
    const n = menu.items.length;
    if (e.key === 'Escape') hideMenu();
    else if (e.key === 'ArrowDown' && n) select((menu.sel + 1) % n);
    else if (e.key === 'ArrowUp' && n) select((menu.sel - 1 + n) % n);
    else if (e.key === 'Enter' && menu.sel >= 0) menu.items[menu.sel].run();
    else { hideMenu(); return; }
    e.preventDefault();
    e.stopPropagation();
  }, true);

  // MARK: Diff

  function wireDiff() {
    const orig = diff.getOriginalEditor(), mod = diff.getModifiedEditor();
    const openAt = (line, column) => post({ type: 'openAt', line, column });
    // ↩ on the read-only side (or a read-only diff) and ⌘↩ anywhere: the working file in the editor at that line.
    orig.addCommand(monaco.KeyCode.Enter, () => { const p = orig.getPosition(); openAt(toModified(p.lineNumber), 1); });
    orig.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter, () => { const p = orig.getPosition(); openAt(toModified(p.lineNumber), 1); });
    mod.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter, () => { const p = mod.getPosition(); openAt(p.lineNumber, p.column); });
    mod.addCommand(monaco.KeyCode.Enter, () => {
      if (!diffPath) { const p = mod.getPosition(); openAt(p.lineNumber, p.column); return; }
      mod.trigger('keyboard', 'type', { text: '\n' });
    });
    mod.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => {
      const f = diffPath && files.get(diffPath);
      if (f && f.model) formatThen(mod, () => post({ type: 'save', file: diffPath, text: f.model.getValue() }));
    });
    for (const e of [orig, mod]) { e.onDidFocusEditorText(() => { lastSide = e; post({ type: 'focus' }); report(); }); wireMenu(e); }
    orig.onDidChangeCursorPosition(() => report());
    // The first change is shown (centered) once the diff is computed; a computed diff is also what the header's
    // counter («2 из 5») and the empty state wait for. Typing ends the wait, so a later recompute never scrolls.
    mod.onDidChangeModelContent(() => { awaiting = false; });
    mod.onDidChangeCursorPosition(() => report());
    diff.onDidUpdateDiff(() => {
      const lines = changeLines();
      if (awaiting && lines.length && !pendingLine) {
        awaiting = false;
        mod.revealLineInCenter(lines[0]);
        mod.setPosition({ lineNumber: lines[0], column: 1 });
      }
      report(true);
    });
    resetFirst = () => { awaiting = true; lastReport = ''; lastSide = null; };
  }
  let resetFirst = () => {};
  let awaiting = true, lastReport = '', lastSide = null;

  /// The cursor's line on the modified side, from whichever side was focused last (the base side is mapped across).
  function cursorLine() {
    const mod = diff.getModifiedEditor();
    return lastSide === diff.getOriginalEditor() ? toModified(lastSide.getPosition().lineNumber) : mod.getPosition().lineNumber;
  }

  /// The modified-side line each change starts at (a pure deletion: the line it follows).
  function changeLines() {
    return (diff.getLineChanges() || []).map((c) => c.modifiedEndLineNumber > 0 ? c.modifiedStartLineNumber : Math.max(1, c.modifiedStartLineNumber));
  }

  /// The change the cursor is in or after (1-based; 0 before the first one) and the count, to Swift when they changed.
  function report(computed) {
    if (!diff.getModel()) return;
    const lines = changeLines(), line = cursorLine();
    if (!lines.length && !computed) return;
    let index = 0;
    for (const l of lines) if (l <= line) index++;
    if (lines.length) index = Math.max(1, index);
    const key = index + '/' + lines.length;
    if (key === lastReport) return;
    lastReport = key;
    post({ type: 'changes', index, count: lines.length });
  }

  /// F7 / ⇧F7 and the header's arrows: the next / previous change from the cursor, wrapping at the ends.
  function goChange(next) {
    const lines = changeLines();
    if (!lines.length) return;
    const mod = diff.getModifiedEditor(), at = cursorLine();
    let target;
    if (next) target = lines.find((l) => l > at) ?? lines[0];
    else target = [...lines].reverse().find((l) => l < at) ?? lines[lines.length - 1];
    awaiting = false;
    lastSide = mod;
    mod.revealLineInCenter(target);
    mod.setPosition({ lineNumber: target, column: 1 });
    mod.focus();
  }

  let pendingLine = null;

  /// A line of the original side → the same place on the modified side.
  function toModified(line) {
    let delta = 0;
    for (const c of diff.getLineChanges() || []) {
      const oStart = c.originalStartLineNumber, oEnd = c.originalEndLineNumber;
      const mLen = c.modifiedEndLineNumber > 0 ? c.modifiedEndLineNumber - c.modifiedStartLineNumber + 1 : 0;
      const oLen = oEnd > 0 ? oEnd - oStart + 1 : 0;
      if (oEnd > 0 && line >= oStart && line <= oEnd) return Math.max(1, c.modifiedStartLineNumber);
      if ((oEnd > 0 ? oEnd : oStart) < line) delta += mLen - oLen; else break;
    }
    return Math.max(1, line + delta);
  }

  function showDiff(c) {
    const old = diff.getModel();
    files.clear();
    diffPath = c.path;
    const original = monaco.editor.createModel(c.original, undefined, monaco.Uri.from({ scheme: 'hangar-base', path: '/' + c.name }));
    const modified = monaco.editor.createModel(c.modified, undefined,
      c.path ? monaco.Uri.file(c.path) : monaco.Uri.from({ scheme: 'hangar-new', path: '/' + c.name }));
    if (c.path) {
      const f = { path: c.path, model: modified, readOnly: false, conflict: false, dirty: false, saved: modified.getAlternativeVersionId() };
      files.set(c.path, f);
      modified.onDidChangeContent(() => {
        if (f.reloading) return;
        const dirty = modified.getAlternativeVersionId() !== f.saved;
        if (dirty !== f.dirty) { f.dirty = dirty; post({ type: 'changed', file: c.path, dirty }); }
      });
      active = c.path;
    } else {
      active = null;
    }
    pendingLine = c.line || null;
    resetFirst();
    diff.setModel({ original, modified });
    diff.getModifiedEditor().updateOptions({ readOnly: !c.path });
    if (old) { old.original.dispose(); old.modified.dispose(); }
    if (pendingLine) {
      const mod = diff.getModifiedEditor();
      mod.revealLineInCenter(pendingLine);
      mod.setPosition({ lineNumber: pendingLine, column: 1 });
    }
    renderChrome();
    diff.getModifiedEditor().focus();
  }

  // MARK: Language features (tsserver through Swift, #82)

  let nextId = 1;
  function ask(kind, model, position, token, name, extra) {
    // Only a tab's own file (the diff: its working file): Swift answers through that tab (its host, its project).
    const f = model.uri.scheme === 'file' ? fileOf(model) : null;
    if (!f) return Promise.resolve(null);
    const file = f.path;
    const id = nextId++;
    return new Promise((resolve) => {
      pending.set(id, resolve);
      // A dropped request is dropped in Swift too (the language server gets `$/cancelRequest`).
      token.onCancellationRequested(() => { if (pending.delete(id)) post({ type: 'cancel', doc: f.doc, id }); resolve(null); });
      post(Object.assign({ type: 'request', doc: f.doc, id, kind, file, line: position.lineNumber, column: position.column, name }, extra));
    });
  }
  const range = (i) => new monaco.Range(i.line, i.column, i.endLine, i.endColumn);
  // A location in a file a tab has open points at that tab's model (the peek shows its live buffer).
  const docUri = (path) => { const f = active && files.get(active); if (f && f.path === path && f.model) return f.model.uri;
    for (const g of files.values()) if (g.path === path && g.model) return g.model.uri; return monaco.Uri.file(path); };
  const loc = (i) => ({ uri: docUri(i.path), range: new monaco.Range(i.line, i.column, i.endLine || i.line, i.endColumn || i.column) });

  // Files the references peek shows but the page has no model of: read-only previews until the next search.
  const previews = new Map();
  function dropPreview(path) {
    const m = previews.get(path);
    if (m) { m.dispose(); previews.delete(path); }
  }
  function setPreviews(texts) {
    for (const p of [...previews.keys()]) if (!(p in texts)) dropPreview(p);
    for (const [p, text] of Object.entries(texts || {})) {
      if ([...files.values()].some((f) => f.path === p) || previews.has(p) || monaco.editor.getModel(monaco.Uri.file(p))) continue;
      previews.set(p, monaco.editor.createModel(text, undefined, monaco.Uri.file(p)));
    }
  }

  // tsserver's ScriptElementKind → the list's icon.
  function completionKind(k) {
    const K = monaco.languages.CompletionItemKind;
    switch (k) {
      case 'method': case 'construct': return K.Method;
      case 'function': case 'local function': return K.Function;
      case 'constructor': return K.Constructor;
      case 'property': case 'getter': case 'setter': return K.Property;
      case 'var': case 'let': case 'local var': case 'parameter': return K.Variable;
      case 'const': return K.Constant;
      case 'class': case 'local class': return K.Class;
      case 'interface': return K.Interface;
      case 'type': case 'alias': case 'type parameter': return K.TypeParameter;
      case 'enum': return K.Enum;
      case 'enum member': return K.EnumMember;
      case 'module': case 'external module name': return K.Module;
      case 'keyword': return K.Keyword;
      case 'directory': return K.Folder;
      case 'script': return K.File;
      default: return K.Text;
    }
  }

  // Back / forward over jumps (⌃- / ⌃⇧-, as in VS Code): positions before each go-to-definition or peek open.
  const back = [], fwd = [];
  function here() {
    const p = editor && editor.getPosition();
    return activePath() && p ? { path: activePath(), line: p.lineNumber, column: p.column } : null;
  }
  function go(t) {
    if (t.path === activePath()) {
      const pos = { lineNumber: t.line, column: t.column };
      editor.setPosition(pos);
      editor.revealPositionInCenterIfOutsideViewport(pos);
      editor.focus();
    } else {
      // Another file: its own Hangar tab (opened or focused there).
      const f = active && files.get(active);
      post({ type: 'openFile', doc: f ? f.doc : undefined, file: t.path, line: t.line, column: t.column });
    }
  }
  function remember() {
    const h = here();
    if (!h) return;
    back.push(h);
    if (back.length > 50) back.shift();
    fwd.length = 0;
  }
  function navigate(from, to) {
    const target = from.pop();
    if (!target) return;
    const h = here();
    if (h) to.push(h);
    go(target);
  }

  const SEMANTIC = { tokenTypes: ['class', 'enum', 'interface', 'namespace', 'typeParameter', 'type', 'parameter', 'variable',
    'enumMember', 'property', 'function', 'member', 'constant'], tokenModifiers: ['declaration', 'static', 'async', 'readonly',
    'defaultLibrary', 'local'] };
  const UPPER = /^[A-Z][A-Z0-9_]+$/;
  // Offsets (UTF-16) → Monaco's relative line / column quintuples.
  function encodeSemantic(model, data) {
    const out = [];
    let line = 0, char = 0;
    for (let i = 0; i + 3 < data.length; i += 4) {
      const p = model.getPositionAt(data[i]);
      const l = p.lineNumber - 1, c = p.column - 1;
      let type = data[i + 2];
      if (type === 7 && UPPER.test(model.getValueInRange(monaco.Range.fromPositions(p, model.getPositionAt(data[i] + data[i + 1]))))) type = 12;
      out.push(l - line, l === line ? c - char : c, data[i + 1], type, data[i + 3]);
      line = l; char = c;
    }
    return { data: new Uint32Array(out) };
  }

  function registerProviders() {
    const ls = monaco.languages;
    ls.registerDefinitionProvider('*', { provideDefinition: (m, p, t) => ask('definition', m, p, t)
      .then((r) => (r && r.kind === 'locations' ? r.items.map(loc) : null)) });
    ls.registerReferenceProvider('*', { provideReferences: (m, p, _c, t) => ask('references', m, p, t).then((r) => {
      if (!r || r.kind !== 'locations') return null;
      setPreviews(r.previews);
      return r.items.map(loc);
    }) });
    ls.registerHoverProvider('*', { provideHover: (m, p, t) => ask('hover', m, p, t)
      .then((r) => (r && r.kind === 'hover' ? { contents: [{ value: r.markdown, isTrusted: false }] } : null)) });
    ls.registerCompletionItemProvider('*', {
      triggerCharacters: ['.'],
      provideCompletionItems: (m, p, _c, t) => ask('completion', m, p, t).then((r) => {
        if (!r || r.kind !== 'completions') return { suggestions: [] };
        const w = m.getWordUntilPosition(p);
        const range = new monaco.Range(p.lineNumber, w.startColumn, p.lineNumber, w.endColumn);
        return { suggestions: r.items.map((i) => ({ label: i.label, detail: i.detail || undefined, insertText: i.insertText,
          insertTextRules: i.snippet ? monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet : undefined,
          kind: completionKind(i.kind), sortText: i.sortText || undefined, hangarAt: { model: m, position: p },
          // The server's own range (LSP textEdit, validated in Swift: this line, around the cursor), else the word.
          range: i.range ? { insert: new monaco.Range(p.lineNumber, i.range.start, p.lineNumber, i.range.end),
            replace: new monaco.Range(p.lineNumber, i.range.start, p.lineNumber, i.range.replaceEnd) } : range })) };
      }),
      // The docs of the selected entry, on demand.
      resolveCompletionItem: (item, t) => {
        const at = item.hangarAt;
        if (!at || at.model.isDisposed()) return item;
        return ask('details', at.model, at.position, t, item.label).then((r) => {
          if (r && r.kind === 'hover') item.documentation = { value: r.markdown, isTrusted: false };
          return item;
        });
      },
    });
    // tsserver's semantic classes (2020 legend; UPPER_CASE variables as `constant`, as Dark+ colours them).
    for (const lang of ['typescript', 'javascript']) {
      ls.registerDocumentSemanticTokensProvider(lang, {
        getLegend: () => SEMANTIC,
        provideDocumentSemanticTokens: (m, _last, t) => ask('semantic', m, { lineNumber: 1, column: 1 }, t, undefined,
          { length: m.getValueLength() }).then((r) => (r && r.kind === 'semantic' ? encodeSemantic(m, r.data) : null)),
        releaseDocumentSemanticTokens: () => {},
      });
    }
    // Rename and format: the languages with a server (tsserver; LSP #90); others have none, so the menu greys them.
    for (const lang of ['typescript', 'javascript', 'python', 'swift', 'go', 'rust']) {
      ls.registerRenameProvider(lang, {
        resolveRenameLocation: (m, p, t) => ask('rename', m, p, t).then((r) => {
          if (r && r.kind === 'rejected') return { range: new monaco.Range(p.lineNumber, p.column, p.lineNumber, p.column), text: '', rejectReason: r.reason };
          const w = m.getWordAtPosition(p);
          return w ? { range: new monaco.Range(p.lineNumber, w.startColumn, p.lineNumber, w.endColumn), text: w.word }
            : { range: new monaco.Range(p.lineNumber, p.column, p.lineNumber, p.column), text: '', rejectReason: cfg.menu.renameRefused };
        }),
        provideRenameEdits: (m, p, newName, t) => ask('rename', m, p, t, newName).then((r) => {
          if (!r) return { edits: [] };
          if (r.kind === 'rejected') return { edits: [], rejectReason: r.reason };
          const versionId = m.getVersionId();
          return { edits: r.items.map((i) => ({ resource: m.uri, versionId,
            textEdit: { range: range(i), text: i.prefix + newName + i.suffix } })) };
        }),
      });
      ls.registerDocumentFormattingEditProvider(lang, {
        provideDocumentFormattingEdits: (m, o, t) => {
          const end = { lineNumber: m.getLineCount(), column: m.getLineMaxColumn(m.getLineCount()) };
          return ask('format', m, end, t, undefined, { tabSize: o.tabSize, insertSpaces: o.insertSpaces })
            .then((r) => (r && r.kind === 'edits' ? r.items.map((i) => ({ range: range(i), text: i.text })) : []));
        },
      });
    }
    // Every go-to-definition and peek open lands here: same file in place, another one through Hangar (this tab).
    monaco.editor.registerEditorOpener({ openCodeEditor(_src, uri, sel) {
      if (uri.scheme !== 'file') return false;
      const s = sel && (sel.startLineNumber ? { line: sel.startLineNumber, column: sel.startColumn } : { line: sel.lineNumber, column: sel.column });
      const target = { path: uri.path, line: (s && s.line) || 1, column: (s && s.column) || 1 };
      if (!editor) { post({ type: 'openFile', file: target.path, line: target.line, column: target.column }); return true; }
      remember();
      go(target);
      return true;
    } });
  }

  // MARK: Swift → page

  function receive(c) {
    if (!window.hangar.ready) { queue.push(c); return; }
    switch (c.type) {
      case 'open': open(c); break;
      case 'activate': activate(c.doc, c.line, c.column); break;
      case 'close': close(c.doc); break;
      case 'reload': if (cfg.mode === 'diff') reloadDiff(c.path, c.text); else reload(c.doc, c.text); break;
      case 'saved': { const f = files.get(keyOf(c)); if (f && f.model) { f.saved = f.model.getAlternativeVersionId(); f.dirty = false; } renderChrome(); break; }
      case 'conflict': { const f = files.get(keyOf(c)); if (f) { f.conflict = c.shown; renderChrome(); } break; }
      case 'notice': { const f = files.get(keyOf(c)); if (f) { f.notice = c.text; renderChrome(); } break; }
      case 'markers': { const f = files.get(keyOf(c)); if (f && f.model) monaco.editor.setModelMarkers(f.model, 'hangar', c.markers.map((m) => ({
        startLineNumber: m.line, startColumn: m.column, endLineNumber: m.endLine, endColumn: m.endColumn, message: m.message,
        severity: { error: 8, warning: 4, info: 2, hint: 1 }[m.severity] }))); break; }
      case 'resolve': { const r = pending.get(c.id); if (r) { pending.delete(c.id); r(c.result); } break; }
      case 'diff': showDiff(c); break;
      case 'options':
        inline = c.inline; minimap = c.minimap;
        if (diff) { diff.updateOptions({ renderSideBySide: !inline }); if (inline) { lastSide = diff.getModifiedEditor(); report(); } }
        if (editor) editor.updateOptions({ minimap: { enabled: minimap } });
        break;
      case 'appearance': setLook(c); break;
      case 'goChange': if (diff) goChange(c.next); break;
      case 'focus': (editor || (diff && diff.getModifiedEditor())).focus(); break;
    }
  }

  function reloadDiff(path, text) {
    const f = files.get(path);
    if (!f || !f.model) return;
    f.reloading = true;
    f.model.pushEditOperations([], [{ range: f.model.getFullModelRange(), text }], () => null);
    f.reloading = false;
    f.saved = f.model.getAlternativeVersionId();
    f.dirty = false;
    renderChrome();
  }

  /// For Swift: the text of a tab's file (diff: of a path) — save before closing, tsserver after a crash, debug checks.
  function text(key) { const f = files.get(key); return f && f.model ? f.model.getValue() : null; }

  window.hangar = { ready: false, receive, text, find: () => {
    const e = editor || (diff && diff.getModifiedEditor());
    e.focus();
    e.getAction('actions.find').run();
  } };
})();
