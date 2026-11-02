export function launcherHtml(nonce: string): string {
  return `<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8" />
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';" />
<style>
  body {
    margin: 0;
    padding: 12px;
    color: var(--vscode-foreground);
    font-family: var(--vscode-font-family);
    font-size: var(--vscode-font-size);
  }
  p { margin: 0 0 12px; line-height: 1.4; }
  button {
    width: 100%;
    padding: 8px;
    cursor: pointer;
    color: var(--vscode-button-foreground);
    background: var(--vscode-button-background);
    border: none;
    font: inherit;
    font-weight: 600;
  }
</style>
</head>
<body>
  <p>Форма загрузки открывается отдельной вкладкой редактора.</p>
  <button type="button" id="open">Открыть вкладку</button>
  <script nonce="${nonce}">
    const vscode = acquireVsCodeApi();
    document.getElementById('open').addEventListener('click', () => vscode.postMessage({ type: 'openWindow' }));
  </script>
</body>
</html>`;
}

export function webviewHtml(nonce: string): string {
  return `<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8" />
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>1C: Загрузка изменённых файлов</title>
<style>
  :root { color-scheme: light dark; }
  html, body { height: 100%; margin: 0; }
  body {
    box-sizing: border-box;
    display: flex;
    flex-direction: column;
    padding: 14px 16px;
    color: var(--vscode-foreground);
    background: var(--vscode-editor-background);
    font-family: var(--vscode-font-family);
    font-size: var(--vscode-font-size);
  }
  #form {
    flex: 1;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }
  h1 { font-size: 13px; font-weight: 600; margin: 0; }
  .unsupported {
    padding: 8px;
    border: 1px solid var(--vscode-inputValidation-warningBorder, var(--vscode-panel-border));
    background: var(--vscode-inputValidation-warningBackground, transparent);
  }
  label.field { display: block; margin-bottom: 4px; }
  .row { display: flex; gap: 6px; }
  input[type="text"], select {
    flex: 1;
    min-width: 0;
    width: 100%;
    box-sizing: border-box;
    color: var(--vscode-input-foreground);
    background: var(--vscode-input-background);
    border: 1px solid var(--vscode-input-border, transparent);
    padding: 4px 6px;
  }
  button, select { font-family: inherit; font-size: inherit; }
  button {
    color: var(--vscode-button-secondaryForeground);
    background: var(--vscode-button-secondaryBackground);
    border: 1px solid var(--vscode-button-border, transparent);
    padding: 4px 8px;
    cursor: pointer;
  }
  button:hover:not(:disabled) { background: var(--vscode-button-secondaryHoverBackground); }
  button:disabled { opacity: 0.55; cursor: default; }
  button.primary {
    color: var(--vscode-button-foreground);
    background: var(--vscode-button-background);
    font-weight: 600;
  }
  button.primary:hover:not(:disabled) { background: var(--vscode-button-hoverBackground); }
  button.tiny { padding: 0 6px; min-width: 26px; }
  .settings { display: flex; flex-direction: column; gap: 4px; }
  .settings label { display: flex; gap: 6px; align-items: flex-start; }
  details.settings-box { margin: 0 0 22px; }
  details.settings-box summary {
    cursor: pointer;
    font-weight: 600;
    font-size: 13px;
  }
  details.settings-box .settings { margin-top: 8px; }
  .folder-block { margin-bottom: 20px; }
  .base-block { margin-bottom: 22px; }
  .read-row {
    display: flex;
    align-items: center;
    justify-content: flex-start;
    gap: 12px;
    margin-bottom: 20px;
  }
  .select-row { display: flex; align-items: center; gap: 6px; margin-bottom: 8px; }
  .found { font-size: 12px; }
  .found.success { color: var(--vscode-testing-iconPassed, #3fb950); }
  .found.error, .status.error { color: var(--vscode-errorForeground); }
  .status.progress { color: var(--vscode-progressBar-background, var(--vscode-foreground)); }
  .status.success { color: var(--vscode-testing-iconPassed, #3fb950); }
  .list {
    flex: 1;
    min-height: 220px;
    overflow: auto;
    border: 1px solid var(--vscode-panel-border, var(--vscode-widget-border, rgba(128,128,128,.4)));
    background: var(--vscode-editor-background);
    padding: 4px 0;
  }
  .file {
    display: flex;
    gap: 6px;
    align-items: flex-start;
    padding: 2px 8px;
    white-space: nowrap;
  }
  .file span { font-family: var(--vscode-editor-font-family); font-size: 12px; }
  .footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    margin-top: 18px;
    min-height: 32px;
  }
  .status {
    flex: 1;
    display: flex;
    align-items: center;
    margin: 0;
    min-height: 32px;
    line-height: 1.3;
    white-space: pre-wrap;
  }
  #load {
    flex: 0 0 auto;
    height: 32px;
    margin: 0;
    padding: 0 14px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
  }
</style>
</head>
<body>
  <div id="unsupported" class="unsupported" hidden>Загрузка доступна только в Windows: нужны 1cv8.exe и список баз ibases.v8i.</div>
  <div id="form">
    <details class="settings-box">
      <summary>Настройки</summary>
      <div class="settings">
        <label><input id="skipDb" type="checkbox" /> Не обновлять конфигурацию базы данных</label>
        <label><input id="openConf" type="checkbox" /> Открыть конфигуратор после успешной загрузки</label>
      </div>
    </details>
    <div class="folder-block">
      <label class="field" for="path">Папка проекта</label>
      <div class="row">
        <input id="path" type="text" spellcheck="false" />
        <button id="browse" type="button">Обзор...</button>
      </div>
    </div>
    <div class="base-block">
      <label class="field" for="base">База 1С</label>
      <div class="row">
        <select id="base"></select>
        <button id="refresh" type="button">Обновить</button>
      </div>
    </div>
    <div class="read-row">
      <button id="read" type="button">Прочитать изменения</button>
      <span id="found" class="found">Изменений не найдено</span>
    </div>
    <div class="select-row">
      <button id="all" class="tiny" type="button" title="Выделить все">✓</button>
      <button id="none" class="tiny" type="button" title="Снять выделение">□</button>
    </div>
    <div id="list" class="list"></div>
    <div class="footer">
      <div id="status" class="status">Выберите папку и базу, затем нажмите «Прочитать изменения»</div>
      <button id="load" class="primary" type="button" disabled>Загрузить выбранные</button>
    </div>
  </div>
  <script nonce="${nonce}">
    const vscode = acquireVsCodeApi();
    const $ = (id) => document.getElementById(id);
    let fileSig = '';
    let applying = false;

    const post = (message) => vscode.postMessage(message);

    $('browse').addEventListener('click', () => post({ type: 'browse' }));
    $('refresh').addEventListener('click', () => post({ type: 'refreshBases' }));
    $('read').addEventListener('click', () => post({ type: 'readChanges' }));
    $('load').addEventListener('click', () => post({ type: 'load' }));
    $('all').addEventListener('click', () => post({ type: 'selectAll', checked: true }));
    $('none').addEventListener('click', () => post({ type: 'selectAll', checked: false }));
    $('path').addEventListener('change', () => post({ type: 'setProjectPath', path: $('path').value }));
    $('base').addEventListener('change', () => post({ type: 'selectBase', index: Number($('base').value) }));
    $('skipDb').addEventListener('change', () => post({ type: 'setUpdateDatabase', value: !$('skipDb').checked }));
    $('openConf').addEventListener('change', () => post({ type: 'setOpenConfigurator', value: $('openConf').checked }));

    function setDisabled(loading, windows) {
      const off = loading || !windows;
      for (const id of ['path', 'browse', 'base', 'refresh', 'read', 'skipDb', 'openConf', 'all', 'none']) {
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
        text.textContent = file.path;
        row.append(box, text);
        list.append(row);
      });
      list.scrollTop = scroll;
    }

    function render(state) {
      applying = true;
      $('unsupported').hidden = state.windows;
      $('form').hidden = !state.windows;
      if (document.activeElement !== $('path')) $('path').value = state.projectPath || '';
      const base = $('base');
      const labels = state.bases.map((b) => b.label).join('\\n');
      if (base.dataset.labels !== labels) {
        base.dataset.labels = labels;
        base.replaceChildren();
        if (!state.bases.length) {
          const opt = document.createElement('option');
          opt.value = '-1';
          opt.textContent = 'Базы не найдены — запустите 1С:Предприятие и добавьте базы';
          base.append(opt);
        } else {
          state.bases.forEach((item, index) => {
            const opt = document.createElement('option');
            opt.value = String(index);
            opt.textContent = item.label;
            base.append(opt);
          });
        }
      }
      if (document.activeElement !== base) {
        base.value = state.bases.length ? String(state.selectedBase) : '-1';
      }
      base.disabled = !state.bases.length;
      $('skipDb').checked = !state.updateDatabase;
      $('openConf').checked = state.openConfigurator;
      const found = $('found');
      found.textContent = state.foundText || 'Изменений не найдено';
      found.className = 'found ' + (state.foundTone || 'muted');
      const status = $('status');
      status.textContent = state.statusText || '';
      status.className = 'status ' + (state.statusTone || 'muted');
      renderFiles(state.files || []);
      const checked = (state.files || []).filter((f) => f.checked).length;
      const load = $('load');
      load.textContent = checked > 0 ? 'Загрузить выбранные (' + checked + ')' : 'Загрузить выбранные';
      setDisabled(!!state.loading, !!state.windows);
      if (!state.bases.length) base.disabled = true;
      load.disabled = !!state.loading || !state.windows || checked === 0 || !state.bases.length;
      document.querySelectorAll('#list input').forEach((el) => { el.disabled = !!state.loading; });
      applying = false;
    }

    window.addEventListener('message', (event) => {
      if (event.data && event.data.type === 'state') render(event.data.state);
    });
    post({ type: 'ready' });
  </script>
</body>
</html>`;
}
