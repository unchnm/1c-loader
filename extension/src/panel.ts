import * as crypto from 'crypto';
import * as fs from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';
import { ChildProcess } from 'child_process';
import {
  findGitRoot,
  findXmlRoot,
  getGitChangedFiles,
  gitAvailable,
  subPathOf,
  toLoadRelativePaths
} from './changes';
import { infobaseLabel, platformVersionOf, readIbases } from './ibases';
import {
  configuratorBusyMessage,
  copyMismatchLog,
  openConfigurator,
  readLogText,
  readVersionMismatch,
  startDesignerLoad,
  tempLoadPaths,
  writeListFile
} from './load';
import { find1CExecutable } from './platform';
import { FileItem, Infobase, PanelState, StatusTone } from './types';
import { launcherHtml, webviewHtml } from './webviewHtml';

function showToast(text: string, ms: number): void {
  const title = text.replace(/\s*\n\s*/g, ' ').trim();
  void vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title },
    () => new Promise<void>(resolve => setTimeout(resolve, ms))
  );
}

interface LoadContext {
  xmlDir: string;
  relFiles: string[];
  listFile: string;
  logFile: string;
  base: Infobase;
  updateDatabase: boolean;
}

export class LoaderViewProvider implements vscode.WebviewViewProvider {
  public static readonly viewType = 'onecLoader.panel';

  private view?: vscode.WebviewView;
  private formPanel?: vscode.WebviewPanel;
  private formWebview?: vscode.Webview;
  private projectPath = '';
  private bases: Infobase[] = [];
  private selectedIndex = 0;
  private files: FileItem[] = [];
  private foundText = 'Изменений не найдено';
  private foundTone: StatusTone = 'muted';
  private statusText = 'Выберите папку и базу, затем нажмите «Прочитать изменения»';
  private statusTone: StatusTone = 'muted';
  private loading = false;
  private loadGen = 0;
  private settledGen = -1;
  private versionRetried = false;
  private loadTicks = 0;
  private timer: NodeJS.Timeout | null = null;
  private proc: ChildProcess | null = null;
  private loadCtx: LoadContext | null = null;
  private loadingExe = '';

  constructor(private readonly context: vscode.ExtensionContext) {}

  resolveWebviewView(webviewView: vscode.WebviewView): void {
    this.view = webviewView;
    webviewView.webview.options = { enableScripts: true };
    const nonce = crypto.randomBytes(16).toString('hex');
    webviewView.webview.html = launcherHtml(nonce);
    webviewView.webview.onDidReceiveMessage(message => {
      if (message?.type === 'openWindow') {
        void this.openFormWindow();
      }
    });
    webviewView.onDidChangeVisibility(() => {
      if (webviewView.visible) {
        void this.openFormWindow();
      }
    });
    void this.openFormWindow();
  }

  async openFormWindow(): Promise<void> {
    if (process.platform !== 'win32') {
      showToast('Загрузка доступна только в Windows: нужны 1cv8.exe и список баз ibases.v8i.', 3000);
      return;
    }
    if (this.formPanel) {
      this.formPanel.reveal(vscode.ViewColumn.Active, false);
      return;
    }
    this.createFormWindow();
  }

  private createFormWindow(): void {
    if (!this.projectPath) {
      this.projectPath = this.defaultProjectPath();
    }
    this.reloadBases(false);
    const panel = vscode.window.createWebviewPanel(
      'onecLoader.form',
      '1C: Загрузка изменённых файлов',
      vscode.ViewColumn.Active,
      { enableScripts: true, retainContextWhenHidden: true }
    );
    this.formPanel = panel;
    this.attachForm(panel.webview);
    panel.onDidDispose(() => {
      if (this.formPanel === panel) {
        this.formPanel = undefined;
        this.formWebview = undefined;
      }
    });
  }

  private attachForm(webview: vscode.Webview): void {
    this.formWebview = webview;
    const nonce = crypto.randomBytes(16).toString('hex');
    webview.html = webviewHtml(nonce);
    webview.onDidReceiveMessage(message => {
      void this.onMessage(message);
    });
    this.postState();
  }

  notifyConfig(): void {
    this.postState();
  }

  private defaultProjectPath(): string {
    const saved = this.context.workspaceState.get<string>('projectPath');
    if (saved && fs.existsSync(saved)) {
      return saved;
    }
    const folders = vscode.workspace.workspaceFolders ?? [];
    for (const folder of folders) {
      if (folder.uri.scheme !== 'file') {
        continue;
      }
      if (findXmlRoot(folder.uri.fsPath)) {
        return folder.uri.fsPath;
      }
    }
    const first = folders.find(folder => folder.uri.scheme === 'file');
    return first ? first.uri.fsPath : '';
  }

  private config() {
    return vscode.workspace.getConfiguration('onecLoader');
  }

  private updateDatabase(): boolean {
    return this.config().get<boolean>('updateDatabase', true);
  }

  private openConfiguratorAfter(): boolean {
    return this.config().get<boolean>('openConfigurator', false);
  }

  private state(): PanelState {
    return {
      windows: process.platform === 'win32',
      projectPath: this.projectPath,
      bases: this.bases.map(base => ({ name: base.name, label: infobaseLabel(base) })),
      selectedBase: this.bases.length ? this.selectedIndex : -1,
      files: this.files,
      foundText: this.foundText,
      foundTone: this.foundTone,
      statusText: this.statusText,
      statusTone: this.statusTone,
      loading: this.loading,
      updateDatabase: this.updateDatabase(),
      openConfigurator: this.openConfiguratorAfter()
    };
  }

  private postState(): void {
    void this.formWebview?.postMessage({ type: 'state', state: this.state() });
  }

  private setStatus(text: string, tone: StatusTone): void {
    this.statusText = text;
    this.statusTone = tone;
    this.postState();
  }

  private async rememberPath(folder: string): Promise<void> {
    this.projectPath = folder;
    await this.context.workspaceState.update('projectPath', folder);
  }

  private reloadBases(keepSelection: boolean): void {
    const prev = keepSelection && this.bases[this.selectedIndex] ? this.bases[this.selectedIndex].name : this.context.workspaceState.get<string>('baseName');
    const list = readIbases();
    this.bases = list ?? [];
    const idx = prev ? this.bases.findIndex(base => base.name === prev) : 0;
    this.selectedIndex = idx >= 0 ? idx : 0;
  }

  private clearFiles(status: string): void {
    this.files = [];
    this.foundText = 'Изменений не найдено';
    this.foundTone = 'muted';
    this.setStatus(status, 'muted');
  }

  private async onMessage(message: { type: string; path?: string; index?: number; checked?: boolean; value?: boolean }): Promise<void> {
    if (process.platform !== 'win32' && message.type !== 'ready') {
      this.postState();
      return;
    }
    switch (message.type) {
      case 'ready':
        this.postState();
        return;
      case 'browse':
        await this.browse();
        return;
      case 'setProjectPath': {
        if (this.loading) {
          return;
        }
        const next = (message.path || '').trim();
        if (next === this.projectPath) {
          return;
        }
        await this.rememberPath(next);
        this.clearFiles('Папка выбрана. Нажмите «Прочитать изменения».');
        return;
      }
      case 'refreshBases':
        if (this.loading) {
          return;
        }
        this.reloadBases(true);
        this.postState();
        return;
      case 'selectBase':
        if (this.loading || message.index === undefined || message.index < 0 || message.index >= this.bases.length) {
          return;
        }
        this.selectedIndex = message.index;
        await this.context.workspaceState.update('baseName', this.bases[this.selectedIndex].name);
        return;
      case 'readChanges':
        await this.readChanges();
        return;
      case 'toggleFile':
        if (this.loading || message.index === undefined || !this.files[message.index]) {
          return;
        }
        this.files[message.index].checked = !!message.checked;
        this.postState();
        return;
      case 'selectAll':
        if (this.loading) {
          return;
        }
        for (const file of this.files) {
          file.checked = !!message.checked;
        }
        this.postState();
        return;
      case 'setUpdateDatabase':
        await this.config().update('updateDatabase', !!message.value, this.configTarget());
        return;
      case 'setOpenConfigurator':
        await this.config().update('openConfigurator', !!message.value, this.configTarget());
        return;
      case 'load':
        await this.startLoad();
        return;
      default:
        return;
    }
  }

  private configTarget(): vscode.ConfigurationTarget {
    return vscode.workspace.workspaceFolders?.length
      ? vscode.ConfigurationTarget.Workspace
      : vscode.ConfigurationTarget.Global;
  }

  private async browse(): Promise<void> {
    if (this.loading) {
      return;
    }
    const current = this.projectPath && fs.existsSync(this.projectPath) ? vscode.Uri.file(this.projectPath) : undefined;
    const picked = await vscode.window.showOpenDialog({
      canSelectFiles: false,
      canSelectFolders: true,
      canSelectMany: false,
      defaultUri: current,
      openLabel: 'Выбрать',
      title: 'Выберите папку проекта'
    });
    if (!picked || !picked[0]) {
      return;
    }
    await this.rememberPath(picked[0].fsPath);
    this.clearFiles('Папка выбрана. Нажмите «Прочитать изменения».');
  }

  private async readChanges(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.files = [];
    this.foundTone = 'muted';
    const folder = this.projectPath.trim();
    if (!folder) {
      this.foundText = 'Изменений не найдено';
      this.setStatus('Сначала выберите папку проекта.', 'muted');
      return;
    }
    if (!fs.existsSync(folder) || !fs.statSync(folder).isDirectory()) {
      this.foundText = 'Изменений не найдено';
      this.setStatus(`Папка не найдена: ${folder}`, 'error');
      return;
    }
    if (!(await gitAvailable())) {
      this.foundText = 'Изменений не найдено';
      this.setStatus('Ошибка: git не найден в PATH. Установите Git for Windows.', 'error');
      return;
    }
    const gitRoot = findGitRoot(folder);
    if (!gitRoot) {
      this.foundText = 'Изменений не найдено';
      this.setStatus('Ошибка: папка не является git-репозиторием (нет .git).', 'error');
      return;
    }
    this.setStatus('Читаем git diff...', 'muted');
    const xmlDir = findXmlRoot(folder) ?? folder;
    const subPath = subPathOf(gitRoot, xmlDir);
    try {
      const names = await getGitChangedFiles(gitRoot, subPath);
      if (names.length === 0) {
        this.files = [];
        this.foundText = 'Нет изменений';
        this.foundTone = 'muted';
        this.setStatus('Незакоммиченных изменений в XML/BSL-файлах не обнаружено.', 'muted');
        return;
      }
      this.files = names.map(name => ({ path: name, checked: true }));
      this.foundText = `Найдено: ${names.length} файлов`;
      this.foundTone = 'success';
      this.setStatus('Снимите галочки с ненужных файлов и нажмите «Загрузить».', 'muted');
    } catch (error) {
      this.foundText = 'Изменений не найдено';
      this.setStatus(`Ошибка git: ${error instanceof Error ? error.message : String(error)}`, 'error');
    }
  }

  private async startLoad(): Promise<void> {
    if (this.loading) {
      return;
    }
    if (this.selectedIndex < 0 || !this.bases[this.selectedIndex]) {
      showToast('Выберите базу 1С.', 2500);
      return;
    }
    const selected = this.files.filter(file => file.checked).map(file => file.path);
    if (selected.length === 0) {
      showToast('Нет выбранных файлов.', 2500);
      return;
    }
    const folder = this.projectPath.trim();
    const gitRoot = findGitRoot(folder);
    if (!gitRoot) {
      this.setStatus('Ошибка: папка не является git-репозиторием (нет .git).', 'error');
      return;
    }
    const xmlDir = findXmlRoot(folder) ?? folder;
    const subPath = subPathOf(gitRoot, xmlDir);
    const relFiles = toLoadRelativePaths(selected, subPath);
    const base = this.bases[this.selectedIndex];
    const required = platformVersionOf(base);
    const platform = await find1CExecutable(required);
    if (!platform.path) {
      void vscode.window.showErrorMessage('1cv8.exe не найден. Установите платформу 1С:Предприятие.');
      return;
    }
    const busy = await configuratorBusyMessage(base);
    if (busy) {
      showToast(busy, 3000);
      return;
    }
    if (platform.warning) {
      showToast(`Платформа: ${platform.matchedVersion}. ${platform.warning}`, 3000);
    }
    const paths = tempLoadPaths();
    writeListFile(paths.listFile, relFiles);
    this.loadCtx = {
      xmlDir,
      relFiles,
      listFile: paths.listFile,
      logFile: paths.logFile,
      base,
      updateDatabase: this.updateDatabase()
    };
    this.loading = true;
    this.versionRetried = false;
    this.loadingExe = platform.path;
    this.loadTicks = 0;
    const verNote = required
      ? `Платформа: ${required} → ${platform.matchedVersion}. Подготовка...`
      : `Платформа: ${platform.matchedVersion}. Подготовка...`;
    this.setStatus(verNote, 'progress');
    this.spawnLoad(platform.path);
  }

  private spawnLoad(exePath: string): void {
    const ctx = this.loadCtx;
    if (!ctx) {
      return;
    }
    try {
      if (fs.existsSync(ctx.logFile)) {
        fs.unlinkSync(ctx.logFile);
      }
    } catch {
      // старый лог не мешает новому запуску
    }
    const gen = ++this.loadGen;
    let proc: ChildProcess;
    try {
      proc = startDesignerLoad({
        exePath,
        infobase: ctx.base,
        xmlDir: ctx.xmlDir,
        listFile: ctx.listFile,
        logFile: ctx.logFile,
        updateDatabase: ctx.updateDatabase
      });
    } catch (error) {
      this.failStart(error instanceof Error ? error.message : String(error));
      return;
    }
    this.proc = proc;
    this.setStatus('Загрузка запущена...', 'progress');
    this.stopTimer();
    this.timer = setInterval(() => {
      if (!this.loading || gen !== this.loadGen) {
        return;
      }
      this.loadTicks++;
      const dots = '.'.repeat((this.loadTicks % 3) + 1);
      this.setStatus(`Загрузка${dots}  (${this.loadTicks}с)`, 'progress');
    }, 1000);
    proc.on('error', err => {
      if (gen === this.loadGen) {
        void this.finishLoad(gen, -1, err.message);
      }
    });
    proc.on('close', code => {
      if (gen === this.loadGen) {
        void this.finishLoad(gen, code ?? -1);
      }
    });
  }

  private failStart(message: string): void {
    this.cleanupFiles();
    this.loading = false;
    this.proc = null;
    this.loadCtx = null;
    this.setStatus(`Ошибка запуска загрузки: ${message}`, 'error');
  }

  private stopTimer(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  private cleanupFiles(): void {
    const ctx = this.loadCtx;
    if (!ctx) {
      return;
    }
    for (const file of [ctx.listFile, ctx.logFile]) {
      try {
        if (fs.existsSync(file)) {
          fs.unlinkSync(file);
        }
      } catch {
        // временный файл можно оставить
      }
    }
  }

  private async finishLoad(gen: number, exitCode: number, spawnError?: string): Promise<void> {
    if (gen !== this.loadGen || gen === this.settledGen) {
      return;
    }
    this.settledGen = gen;
    this.stopTimer();
    const ctx = this.loadCtx;
    const mismatch = ctx ? readVersionMismatch(ctx.logFile) : null;
    let code = exitCode;
    if (mismatch && code === 0) {
      code = 1;
    }
    if (mismatch && ctx && !this.versionRetried) {
      const retry = await find1CExecutable(mismatch.server);
      const same = !!retry.path && path.normalize(retry.path).toLowerCase() === path.normalize(this.loadingExe).toLowerCase();
      if (retry.path && !retry.usedFallback && !same) {
        this.versionRetried = true;
        this.loadingExe = retry.path;
        this.loadTicks = 0;
        this.setStatus(`Сервер ${mismatch.server}. Повтор клиентом ${retry.matchedVersion}...`, 'progress');
        this.spawnLoad(retry.path);
        return;
      }
    }
    const logText = ctx ? readLogText(ctx.logFile) : '';
    if (code !== 0 && ctx) {
      copyMismatchLog(ctx.logFile);
    }
    this.cleanupFiles();
    this.loading = false;
    this.proc = null;
    this.loadCtx = null;
    if (code === 0 && !spawnError) {
      this.setStatus('Загрузка завершена успешно!', 'success');
      showToast('Загрузка завершена успешно!', 2000);
      if (this.openConfiguratorAfter() && ctx && this.loadingExe) {
        openConfigurator(this.loadingExe, ctx.base);
      }
      return;
    }
    this.setStatus(spawnError ? `Ошибка запуска загрузки: ${spawnError}` : `Ошибка загрузки (код: ${code}).`, 'error');
    if (mismatch) {
      void vscode.window.showErrorMessage(
        `Несоответствие версий клиента и сервера 1С.\nКлиент: ${mismatch.client}\nСервер: ${mismatch.server}\n\nДля сервера нужна платформа ${mismatch.server}.`
      );
      return;
    }
    const detail = logText ? `\n${logText.slice(0, 1500)}` : '';
    void vscode.window.showErrorMessage(
      spawnError
        ? `Ошибка запуска загрузки: ${spawnError}`
        : `Загрузка завершилась с ошибкой.\nКод возврата: ${code}${detail}`
    );
  }
}
