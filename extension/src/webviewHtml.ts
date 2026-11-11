export function webviewHtml(nonce: string, fontUri: string, cspSource: string): string {
  return `<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8" />
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; font-src ${cspSource}; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>1C: Загрузка</title>
<style>
  @font-face {
    font-family: "codicon";
    src: url("${fontUri}") format("truetype");
  }
  .codicon {
    font-family: "codicon";
    font-size: 16px;
    line-height: 16px;
    font-style: normal;
    font-weight: normal;
    letter-spacing: normal;
    text-decoration: none;
    text-transform: none;
    -webkit-font-smoothing: antialiased;
  }
  .codicon-search:before { content: "\\ea6d"; }
  .codicon-chevron-down:before { content: "\\eab4"; }
  .codicon-refresh:before { content: "\\eb37"; }
  .codicon-check:before { content: "\\eab2"; }
  .codicon-primitive-square:before { content: "\\ea72"; }
  html, body { height: 100%; margin: 0; }
  body {
    box-sizing: border-box;
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding: 8px 10px 10px;
    color: var(--vscode-foreground);
    background: var(--vscode-sideBar-background);
    font-family: var(--vscode-font-family);
    font-size: var(--vscode-font-size);
  }
  .unsupported {
    padding: 8px;
    border: 1px solid var(--vscode-inputValidation-warningBorder, var(--vscode-panel-border));
  }
  label.field { display: block; margin: 0 0 4px; font-size: 12px; opacity: 0.9; }
  .path-row { position: relative; }
  input[type="text"], select {
    width: 100%;
    box-sizing: border-box;
    color: var(--vscode-input-foreground);
    background: var(--vscode-input-background);
    border: 1px solid var(--vscode-input-border, transparent);
    padding: 4px 6px;
    font: inherit;
  }
  #path, #base { padding-right: 28px; }
  select {
    appearance: none;
    -webkit-appearance: none;
  }
  button { font: inherit; cursor: pointer; }
  button:disabled { opacity: 0.45; cursor: default; }
  .icon-btn {
    color: var(--vscode-icon-foreground);
    background: transparent;
    border: none;
    border-radius: 5px;
    width: 22px;
    height: 22px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
  }
  .icon-btn:hover:not(:disabled) { background: var(--vscode-toolbar-hoverBackground); }
  .selection-icon {
    position: relative;
    width: 14px;
    height: 14px;
    display: inline-block;
  }
  .selection-icon::before {
    content: "";
    position: absolute;
    inset: 1px;
    box-sizing: border-box;
    border: 1px solid currentColor;
    border-radius: 1px;
  }
  .selection-icon-checked::after {
    content: "";
    position: absolute;
    left: 3px;
    top: 5px;
    width: 6px;
    height: 3px;
    box-sizing: border-box;
    border-left: 1.5px solid currentColor;
    border-bottom: 1.5px solid currentColor;
    transform: rotate(-45deg);
  }
  #browse, .select-chevron {
    position: absolute;
    right: 1px;
    top: 50%;
    transform: translateY(-50%);
  }
  .select-chevron {
    width: 22px;
    height: 22px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    pointer-events: none;
    color: var(--vscode-icon-foreground);
  }
  #base:disabled + .select-chevron { opacity: 0.45; }
  .changes {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-height: 0;
  }
  .toolbar { display: flex; align-items: center; justify-content: flex-end; gap: 2px; height: 22px; min-width: 0; }
  .toolbar button[hidden] { display: none; }
  .list {
    flex: 1;
    min-height: 0;
    overflow: auto;
  }
  .file {
    display: flex;
    align-items: center;
    gap: 6px;
    height: 22px;
    padding: 0 2px;
    cursor: pointer;
  }
  .file:hover { background: var(--vscode-list-hoverBackground); }
  .file input { margin: 0; flex: 0 0 auto; }
  .file .text {
    display: flex;
    align-items: baseline;
    gap: 6px;
    min-width: 0;
    flex: 1;
  }
  .file .name { flex: 0 0 auto; }
  .file .dir {
    flex: 1 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--vscode-descriptionForeground);
  }
  .status {
    flex: 1;
    min-width: 0;
    margin-right: auto;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: 12px;
  }
  .status:empty { display: none; }
  .status.success { color: var(--vscode-testing-iconPassed, #3fb950); }
  .status.error { color: var(--vscode-errorForeground); }
  .status.progress { color: var(--vscode-foreground); }
  #load {
    width: 100%;
    border: none;
    padding: 6px 10px;
    color: var(--vscode-button-foreground);
    background: var(--vscode-button-background);
    font-weight: 600;
  }
  #load:hover:not(:disabled) { background: var(--vscode-button-hoverBackground); }
</style>
</head>
<body>
  <div id="unsupported" class="unsupported" hidden>Загрузка доступна только в Windows: нужны 1cv8.exe и список баз ibases.v8i.</div>
  <div id="form" style="display:flex;flex-direction:column;gap:10px;flex:1;min-height:0;">
    <div>
      <label class="field" for="path">Папка проекта</label>
      <div class="path-row">
        <input id="path" type="text" spellcheck="false" />
        <button id="browse" class="icon-btn" type="button" title="Выбрать папку"><span class="codicon codicon-search"></span></button>
      </div>
    </div>
    <div>
      <label class="field" for="base">База 1С</label>
      <div class="path-row">
        <select id="base"></select>
        <span class="select-chevron codicon codicon-chevron-down" aria-hidden="true"></span>
      </div>
    </div>
    <button id="load" type="button" disabled>Загрузить</button>
    <div class="changes">
      <div class="toolbar">
        <div id="status" class="status"></div>
        <button id="all" class="icon-btn" type="button" title="Выделить все"><span class="selection-icon selection-icon-checked" aria-hidden="true"></span></button>
        <button id="none" class="icon-btn" type="button" title="Снять выделение"><span class="selection-icon" aria-hidden="true"></span></button>
      </div>
      <div id="list" class="list"></div>
    </div>
  </div>
  <script nonce="${nonce}">
    const vscode = acquireVsCodeApi();
    const $ = (id) => document.getElementById(id);
    let fileSig = '';
    const post = (message) => vscode.postMessage(message);

    $('browse').addEventListener('click', () => post({ type: 'browse' }));
    $('load').addEventListener('click', () => post({ type: 'load' }));
    $('all').addEventListener('click', () => post({ type: 'selectAll', checked: true }));
    $('none').addEventListener('click', () => post({ type: 'selectAll', checked: false }));
    $('path').addEventListener('change', () => post({ type: 'setProjectPath', path: $('path').value }));
    let lastState = null;
    $('base').addEventListener('pointerenter', () => post({ type: 'refreshBases' }));
    $('base').addEventListener('pointerdown', () => post({ type: 'refreshBases' }));
    $('base').addEventListener('change', () => post({ type: 'selectBase', index: Number($('base').value) }));
    $('base').addEventListener('blur', () => { if (lastState) render(lastState); });

    function fileParts(filePath) {
      const norm = String(filePath).replace(/\\\\/g, '/');
      const slash = norm.lastIndexOf('/');
      return {
        name: slash >= 0 ? norm.slice(slash + 1) : norm,
        dir: slash >= 0 ? norm.slice(0, slash).replace(/\\//g, '\\\\') : ''
      };
    }

    function setDisabled(loading, windows) {
      const off = loading || !windows;
      for (const id of ['path', 'browse', 'base', 'all', 'none']) {
        $(id).disabled = off;
      }
    }

    function renderFiles(files) {
      const sig = files.map((f) => f.path + (f.checked ? '1' : '0')).join('\\n');
      if (sig === fileSig) return;
      fileSig = sig;
      const list = $('list');
      const scroll = list.scrollTop;
      list.replaceChildren();
      files.forEach((file, index) => {
        const row = document.createElement('label');
        row.className = 'file';
        const box = document.createElement('input');
        box.type = 'checkbox';
        box.checked = file.checked;
        box.addEventListener('change', () => post({ type: 'toggleFile', index, checked: box.checked }));
        const text = document.createElement('span');
        text.className = 'text';
        const parts = fileParts(file.path);
        const name = document.createElement('span');
        name.className = 'name';
        name.textContent = parts.name;
        const dir = document.createElement('span');
        dir.className = 'dir';
        dir.textContent = parts.dir;
        text.append(name, dir);
        row.title = parts.dir ? parts.dir + '\\\\' + parts.name : parts.name;
        row.append(box, text);
        list.append(row);
      });
      list.scrollTop = scroll;
    }

    function render(state) {
      lastState = state;
      $('unsupported').hidden = state.windows;
      $('form').hidden = !state.windows;
      if (document.activeElement !== $('path')) $('path').value = state.projectPath || '';
      const base = $('base');
      const labels = (state.bases || []).map((b) => b.name).join('\\n');
      const editingBase = document.activeElement === base;
      if (!editingBase && base.dataset.labels !== labels) {
        base.dataset.labels = labels;
        base.replaceChildren();
        if (!state.bases.length) {
          const opt = document.createElement('option');
          opt.value = '-1';
          opt.textContent = 'Базы не найдены';
          base.append(opt);
        } else {
          state.bases.forEach((item, index) => {
            const opt = document.createElement('option');
            opt.value = String(index);
            opt.textContent = item.name;
            opt.title = item.label;
            base.append(opt);
          });
        }
      }
      if (!editingBase) {
        base.value = state.bases.length ? String(state.selectedBase) : '-1';
      }
      const status = $('status');
      status.textContent = state.statusText || '';
      status.title = state.statusText || '';
      status.className = 'status ' + (state.statusTone || 'muted');
      renderFiles(state.files || []);
      const checked = (state.files || []).filter((f) => f.checked).length;
      const load = $('load');
      load.textContent = checked > 0 ? 'Загрузить (' + checked + ')' : 'Загрузить';
      setDisabled(!!state.loading, !!state.windows);
      const hasFiles = (state.files || []).length > 0;
      $('all').hidden = !hasFiles;
      $('none').hidden = !hasFiles;
      if (!state.bases.length) base.disabled = true;
      load.disabled = !!state.loading || !state.windows || checked === 0 || !state.bases.length;
      document.querySelectorAll('#list input').forEach((el) => { el.disabled = !!state.loading; });
    }

    window.addEventListener('message', (event) => {
      if (event.data && event.data.type === 'state') render(event.data.state);
    });
    post({ type: 'ready' });
  </script>
</body>
</html>`;
}
