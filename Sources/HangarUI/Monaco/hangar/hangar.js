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
    const ls = monaco.languages;
    for (const d of [ls.typescript && ls.typescript.typescriptDefaults, ls.typescript && ls.typescript.javascriptDefaults,
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
      cursorBlinking: 'solid', renderLineHighlight: 'all', fixedOverflowWidgets: true, contextmenu: true,
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
    ed.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => save());
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

  function open(c) {
    if (!files.has(c.path)) {
      const f = { readOnly: c.readOnly, notice: c.notice, conflict: false, dirty: false, refused: c.text == null, view: null, model: null };
      if (c.text != null) {
        f.model = monaco.editor.createModel(c.text, undefined, monaco.Uri.file(c.path));
        f.saved = f.model.getAlternativeVersionId();
        f.model.onDidChangeContent(() => {
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
    for (const e of [orig, mod]) e.onDidFocusEditorText(() => post({ type: 'focus' }));
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

  // MARK: Language features (M2 answers from Swift; nothing yet)

  let nextId = 1;
  function ask(kind, model, position, token) {
    const file = model.uri.scheme === 'file' ? model.uri.path : null;
    if (!file) return Promise.resolve(null);
    const id = nextId++;
    return new Promise((resolve) => {
      pending.set(id, resolve);
      token.onCancellationRequested(() => { pending.delete(id); resolve(null); });
      post({ type: 'request', id, kind, file, line: position.lineNumber, column: position.column });
    });
  }
  const loc = (i) => ({ uri: monaco.Uri.file(i.path), range: new monaco.Range(i.line, i.column, i.line, i.column) });

  function registerProviders() {
    const ls = monaco.languages;
    ls.registerDefinitionProvider('*', { provideDefinition: (m, p, t) => ask('definition', m, p, t)
      .then((r) => (r && r.kind === 'locations' ? r.items.map(loc) : null)) });
    ls.registerReferenceProvider('*', { provideReferences: (m, p, _c, t) => ask('references', m, p, t)
      .then((r) => (r && r.kind === 'locations' ? r.items.map(loc) : null)) });
    ls.registerHoverProvider('*', { provideHover: (m, p, t) => ask('hover', m, p, t)
      .then((r) => (r && r.kind === 'hover' ? { contents: [{ value: r.markdown, isTrusted: false }] } : null)) });
    ls.registerCompletionItemProvider('*', { provideCompletionItems: (m, p, _c, t) => ask('completion', m, p, t).then((r) => {
      if (!r || r.kind !== 'completions') return { suggestions: [] };
      const w = m.getWordUntilPosition(p);
      const range = new monaco.Range(p.lineNumber, w.startColumn, p.lineNumber, w.endColumn);
      return { suggestions: r.items.map((i) => ({ label: i.label, detail: i.detail || undefined, insertText: i.insertText,
        kind: ls.CompletionItemKind.Text, range })) };
    }) });
    // Go to a definition in another file: Hangar opens it (in this editor tab).
    monaco.editor.registerEditorOpener({ openCodeEditor(_src, uri, sel) {
      if (uri.scheme !== 'file') return false;
      const s = sel && (sel.startLineNumber ? { line: sel.startLineNumber, column: sel.startColumn } : { line: sel.lineNumber, column: sel.column });
      post({ type: 'openFile', file: uri.path, line: (s && s.line) || 1, column: (s && s.column) || 1 });
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
