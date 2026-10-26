// Hangar ↔ Monaco (decision #80). Swift drives through `hangar.receive(cmd)`; the page answers with
// `post(msg)` (validated in Swift: BridgeMessage). One page is either the editor (file tabs, many models) or the diff.
'use strict';
(function () {
  const cfg = window.hangarConfig;
  const post = (m) => window.webkit.messageHandlers.hangar.postMessage(JSON.stringify(m));
  window.addEventListener('error', (e) => post({ type: 'log', text: `${e.message} ${e.filename}:${e.lineno}` }));
  window.addEventListener('unhandledrejection', (e) => post({ type: 'log', text: 'rejection: ' + String(e.reason && (e.reason.stack || e.reason)) }));
  for (const [k, v] of Object.entries(cfg.css)) document.documentElement.style.setProperty(k, v);
  if (cfg.mode === 'diff') document.body.classList.add('diff');

  const $ = (id) => document.getElementById(id);
  const files = new Map();   // path → { model, view, readOnly, notice, conflict, saved, dirty, refused }
  let order = [];            // tab order (paths)
  let active = null;         // path
  let editor = null, diff = null, monaco = null;
  let diffPath = null, inline = !!cfg.inline, minimap = !!cfg.minimap;
  const queue = [];
  const pending = new Map(); // provider request id → resolve

  $('bar-reload').textContent = cfg.strings.reload;
  $('bar-keep').textContent = cfg.strings.keepMine;
  $('bar-text').textContent = cfg.strings.conflict;
  $('bar-reload').onclick = () => active && post({ type: 'conflict', file: active, keepMine: false });
  $('bar-keep').onclick = () => active && post({ type: 'conflict', file: active, keepMine: true });

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
    const ls = monaco.languages, mts = monaco.typescript || ls.typescript;
    for (const d of [mts && mts.typescriptDefaults, mts && mts.javascriptDefaults,
      ls.css && ls.css.cssDefaults, ls.css && ls.css.scssDefaults, ls.css && ls.css.lessDefaults, ls.json && ls.json.jsonDefaults,
      ls.html && ls.html.htmlDefaults]) {
      try { d && d.setModeConfiguration(off); } catch (e) { /* not in this build */ }
    }
    monaco.editor.defineTheme('hangar', cfg.theme);
    // Hangar's palette (⌘P / ⇧⌘P) is the one palette: Monaco's F1 command palette is unbound.
    monaco.editor.addKeybindingRules([
      { keybinding: monaco.KeyCode.F1, command: '-editor.action.quickCommand' },
      { keybinding: monaco.KeyMod.CtrlCmd | monaco.KeyMod.Shift | monaco.KeyCode.KeyP, command: '-editor.action.quickCommand' },
    ]);
    registerProviders();
    const common = { theme: 'hangar', fontFamily: 'ui-monospace, Menlo, monospace', fontSize: cfg.fontSize, lineHeight: cfg.lineHeight,
      automaticLayout: true, minimap: { enabled: minimap }, scrollBeyondLastLine: false, smoothScrolling: false,
      cursorBlinking: 'solid', renderLineHighlight: 'all', fixedOverflowWidgets: true, contextmenu: false,
      scrollbar: { verticalScrollbarSize: 10, horizontalScrollbarSize: 10, useShadows: false }, padding: { top: 6 },
      stickyScroll: { enabled: false }, overviewRulerBorder: false, hideCursorInOverviewRuler: true, mouseWheelZoom: false,
      'semanticHighlighting.enabled': false };
    if (cfg.mode === 'diff') {
      diff = monaco.editor.createDiffEditor($('host'), Object.assign({}, common, {
        renderSideBySide: !inline, originalEditable: false, readOnly: true, renderOverviewRuler: false,
        hideUnchangedRegions: { enabled: false }, useInlineViewWhenSpaceIsLimited: false, ignoreTrimWhitespace: false }));
      wireDiff();
    } else {
      editor = monaco.editor.create($('host'), Object.assign({}, common, { model: null }));
      wireEditor(editor);
      renderTabs();
    }
    window.hangar.ready = true;
    post({ type: 'ready' });
    while (queue.length) receive(queue.shift());
  }

  // MARK: Editor

  function wireEditor(ed) {
    wireMenu(ed);
    ed.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => save());
    ed.addCommand(monaco.KeyMod.WinCtrl | monaco.KeyCode.Minus, () => navigate(back, fwd));
    ed.addCommand(monaco.KeyMod.WinCtrl | monaco.KeyMod.Shift | monaco.KeyCode.Minus, () => navigate(fwd, back));
    ed.onDidFocusEditorText(() => post({ type: 'focus' }));
    let timer = null;
    // One-shot, only after a move: the cursor is kept for restore without a message per keystroke.
    ed.onDidChangeCursorPosition(() => {
      clearTimeout(timer);
      timer = setTimeout(() => {
        const p = ed.getPosition(), path = pathOf(ed.getModel());
        if (p && path) post({ type: 'cursor', file: path, line: p.lineNumber, column: p.column });
      }, 400);
    });
  }

  function pathOf(model) {
    if (!model) return null;
    for (const [p, f] of files) if (f.model === model) return p;
    return null;
  }

  function save() {
    const f = active && files.get(active);
    if (f && f.model && !f.readOnly) post({ type: 'save', file: active, text: f.model.getValue() });
  }

  // TS/JS buffers are mirrored in tsserver (#82): every change goes to Swift as an incremental edit.
  const tsLike = /\.(m|c)?[jt]sx?$/i;

  function open(c) {
    if (!files.has(c.path)) {
      const f = { readOnly: c.readOnly, notice: c.notice, conflict: false, dirty: false, refused: c.text == null, view: null, model: null, lang: null };
      if (c.text != null) {
        dropPreview(c.path);
        f.model = monaco.editor.createModel(c.text, undefined, monaco.Uri.file(c.path));
        f.saved = f.model.getAlternativeVersionId();
        const mirror = tsLike.test(c.path);
        f.model.onDidChangeContent((e) => {
          if (mirror) post({ type: 'edit', file: c.path, changes: e.changes.map((ch) => ({ line: ch.range.startLineNumber,
            column: ch.range.startColumn, endLine: ch.range.endLineNumber, endColumn: ch.range.endColumn, text: ch.text })) });
          const dirty = f.model.getAlternativeVersionId() !== f.saved;
          if (dirty !== f.dirty) { f.dirty = dirty; post({ type: 'changed', file: c.path, dirty }); renderTabs(); }
        });
      }
      files.set(c.path, f);
      order.push(c.path);
    }
    activate(c.path, c.line, c.column);
  }

  function activate(path, line, column) {
    const f = files.get(path);
    if (!f) return;
    const cur = active && files.get(active);
    if (cur && cur.model && active !== path) cur.view = editor.saveViewState();
    active = path;
    editor.setModel(f.model);
    editor.updateOptions({ readOnly: f.readOnly });
    if (f.model && f.view && active === path && !line) editor.restoreViewState(f.view);
    if (f.model && line) {
      const pos = { lineNumber: line, column: column || 1 };
      editor.setPosition(pos);
      editor.revealPositionInCenterIfOutsideViewport(pos);
    }
    renderChrome();
    if (f.model) editor.focus();
  }

  function close(path) {
    const f = files.get(path);
    if (!f) return;
    if (f.model) f.model.dispose();
    files.delete(path);
    order = order.filter((p) => p !== path);
    if (active === path) { active = null; editor.setModel(null); }
    renderChrome();
  }

  function renderChrome() {
    const f = active && files.get(active);
    $('bar').hidden = !(f && f.conflict);
    $('notice').hidden = !(f && f.notice && !f.refused);
    $('notice').textContent = (f && f.notice) || '';
    $('refused').hidden = !(f && f.refused);
    $('refused').textContent = (f && f.refused && f.notice) || '';
    renderTabs();
  }

  function renderTabs() {
    if (cfg.mode === 'diff') return;
    const bar = $('tabs');
    bar.textContent = '';
    const names = order.map((p) => p.split('/').pop());
    order.forEach((path, i) => {
      const f = files.get(path);
      const tab = document.createElement('div');
      tab.className = 'tab' + (path === active ? ' active' : '') + (f.dirty ? ' dirty' : '');
      tab.title = path;
      const name = document.createElement('span');
      name.className = 'name';
      name.textContent = names[i];
      tab.appendChild(name);
      // Two open files with one name: their folder tells them apart.
      if (names.filter((n) => n === names[i]).length > 1) {
        const dir = document.createElement('span');
        dir.className = 'dir';
        dir.textContent = path.split('/').slice(-2, -1)[0] || '';
        tab.appendChild(dir);
      }
      const x = document.createElement('span');
      x.className = 'x';
      x.onclick = (e) => { e.stopPropagation(); post({ type: 'close', file: path }); };
      tab.appendChild(x);
      tab.onmousedown = (e) => {
        if (e.button === 1) { e.preventDefault(); post({ type: 'close', file: path }); return; }
        if (e.button !== 0 || e.target === x) return;
        if (path !== active) { activate(path); post({ type: 'activate', file: path }); }
      };
      bar.appendChild(tab);
      if (path === active) requestAnimationFrame(() => tab.scrollIntoView({ block: 'nearest', inline: 'nearest' }));
    });
    const end = document.createElement('div');
    end.className = 'tabs-end';
    bar.appendChild(end);
    const cur = active && files.get(active);
    if (cur && cur.lang) {
      // tsserver's state for this file; a click restarts it (or looks for TypeScript again).
      const s = document.createElement('div');
      s.className = 'tool lang ' + cur.lang.level;
      s.textContent = cur.lang.text;
      s.title = cur.lang.tooltip;
      s.onclick = () => post({ type: 'restartLanguage', file: active });
      bar.appendChild(s);
    }
    const map = document.createElement('div');
    map.className = 'tool' + (minimap ? ' on' : '');
    map.textContent = cfg.strings.minimap;
    map.onclick = () => post({ type: 'minimap', on: !minimap });
    bar.appendChild(map);
  }

  function reload(path, text) {
    const f = files.get(path);
    if (!f || !f.model) return;
    const view = path === active ? editor.saveViewState() : null;
    // An edit, not setValue: undo can go back past the reload.
    f.model.pushEditOperations([], [{ range: f.model.getFullModelRange(), text }], () => null);
    f.saved = f.model.getAlternativeVersionId();
    f.dirty = false;
    if (view) editor.restoreViewState(view);
    renderChrome();
  }

  // MARK: Context menu

  // Hangar's own menu instead of Monaco's (that one lists «Command Palette» and VS Code commands, #81): a fixed list,
  // greyed when the editor can't run an item (no language provider yet, read-only). Labels come from Hangar's L10n.
  const MENU = [
    { action: 'editor.action.revealDefinition', label: 'definition', keys: 'F12' },
    { action: 'editor.action.goToReferences', label: 'references', keys: '⇧F12' },
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
      const a = m.action && ed.getAction(m.action);
      const on = !(m.edits && readOnly) && (m.clipboard ? true : !!(a && a.isSupported()));
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
        const run = () => { hideMenu(); ed.focus(); if (m.clipboard) post({ type: 'clipboard', action: m.clipboard }); else a.run(); };
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
      if (f && f.model) post({ type: 'save', file: diffPath, text: f.model.getValue() });
    });
    for (const e of [orig, mod]) { e.onDidFocusEditorText(() => post({ type: 'focus' })); wireMenu(e); }
    let first = true;
    diff.onDidUpdateDiff(() => {
      if (!first) return;
      first = false;
      const changes = diff.getLineChanges() || [];
      if (changes.length && !pendingLine) {
        const c = changes[0], line = c.modifiedEndLineNumber > 0 ? c.modifiedStartLineNumber : Math.max(1, c.modifiedStartLineNumber);
        mod.revealLineInCenter(line);
        mod.setPosition({ lineNumber: line, column: 1 });
      }
    });
    resetFirst = () => { first = true; };
  }
  let resetFirst = () => {};
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
      const f = { model: modified, readOnly: false, conflict: false, dirty: false, saved: modified.getAlternativeVersionId() };
      files.set(c.path, f);
      modified.onDidChangeContent(() => {
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
    const file = model.uri.scheme === 'file' ? model.uri.path : null;
    if (!file) return Promise.resolve(null);
    const id = nextId++;
    return new Promise((resolve) => {
      pending.set(id, resolve);
      token.onCancellationRequested(() => { pending.delete(id); resolve(null); });
      post(Object.assign({ type: 'request', id, kind, file, line: position.lineNumber, column: position.column, name }, extra));
    });
  }
  const range = (i) => new monaco.Range(i.line, i.column, i.endLine, i.endColumn);
  const loc = (i) => ({ uri: monaco.Uri.file(i.path), range: new monaco.Range(i.line, i.column, i.endLine || i.line, i.endColumn || i.column) });

  // Files the references peek shows but the page has no model of: read-only previews until the next search.
  const previews = new Map();
  function dropPreview(path) {
    const m = previews.get(path);
    if (m) { m.dispose(); previews.delete(path); }
  }
  function setPreviews(texts) {
    for (const p of [...previews.keys()]) if (!(p in texts)) dropPreview(p);
    for (const [p, text] of Object.entries(texts || {})) {
      if (files.has(p) || previews.has(p) || monaco.editor.getModel(monaco.Uri.file(p))) continue;
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
    return active && p ? { path: active, line: p.lineNumber, column: p.column } : null;
  }
  function go(t) {
    if (t.path === active) {
      const pos = { lineNumber: t.line, column: t.column };
      editor.setPosition(pos);
      editor.revealPositionInCenterIfOutsideViewport(pos);
      editor.focus();
    } else {
      post({ type: 'openFile', file: t.path, line: t.line, column: t.column });
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
          kind: completionKind(i.kind), sortText: i.sortText || undefined, range, hangarAt: { model: m, position: p } })) };
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
    // Rename and format: tsserver, TS/JS only (other languages have no server, so the menu greys them).
    for (const lang of ['typescript', 'javascript']) {
      ls.registerRenameProvider(lang, {
        resolveRenameLocation: (m, p, t) => ask('rename', m, p, t).then((r) => {
          if (r && r.kind === 'rejected') return { range: new monaco.Range(p.lineNumber, p.column, p.lineNumber, p.column), text: '', rejectReason: r.reason };
          const w = m.getWordAtPosition(p);
          return w ? { range: new monaco.Range(p.lineNumber, w.startColumn, p.lineNumber, w.endColumn), text: w.word }
            : { range: new monaco.Range(p.lineNumber, p.column, p.lineNumber, p.column), text: '', rejectReason: cfg.menu.renameRefused };
        }),
        provideRenameEdits: (m, p, newName, t) => ask('rename', m, p, t).then((r) => {
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
      case 'activate': activate(c.path, c.line, c.column); break;
      case 'close': close(c.path); break;
      case 'reload': if (cfg.mode === 'diff') reloadDiff(c.path, c.text); else reload(c.path, c.text); break;
      case 'saved': { const f = files.get(c.path); if (f && f.model) { f.saved = f.model.getAlternativeVersionId(); f.dirty = false; } renderChrome(); break; }
      case 'conflict': { const f = files.get(c.path); if (f) { f.conflict = c.shown; renderChrome(); } break; }
      case 'notice': { const f = files.get(c.path); if (f) { f.notice = c.text; renderChrome(); } break; }
      case 'markers': { const f = files.get(c.path); if (f && f.model) monaco.editor.setModelMarkers(f.model, 'hangar', c.markers.map((m) => ({
        startLineNumber: m.line, startColumn: m.column, endLineNumber: m.endLine, endColumn: m.endColumn, message: m.message,
        severity: { error: 8, warning: 4, info: 2, hint: 1 }[m.severity] }))); break; }
      case 'language': { const f = files.get(c.path); if (f) { f.lang = c.status; if (c.path === active) renderTabs(); } break; }
      case 'resolve': { const r = pending.get(c.id); if (r) { pending.delete(c.id); r(c.result); } break; }
      case 'diff': showDiff(c); break;
      case 'options':
        inline = c.inline; minimap = c.minimap;
        if (diff) diff.updateOptions({ renderSideBySide: !inline });
        if (editor) { editor.updateOptions({ minimap: { enabled: minimap } }); renderTabs(); }
        break;
      case 'focus': (editor || (diff && diff.getModifiedEditor())).focus(); break;
    }
  }

  function reloadDiff(path, text) {
    const f = files.get(path);
    if (!f || !f.model) return;
    f.model.pushEditOperations([], [{ range: f.model.getFullModelRange(), text }], () => null);
    f.saved = f.model.getAlternativeVersionId();
    f.dirty = false;
    renderChrome();
  }

  /// For Swift: the text of a file (save before closing, debug checks).
  function text(path) { const f = files.get(path); return f && f.model ? f.model.getValue() : null; }

  window.hangar = { ready: false, receive, text, find: () => {
    const e = editor || (diff && diff.getModifiedEditor());
    e.focus();
    e.getAction('actions.find').run();
  } };
})();
