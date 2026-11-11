import * as crypto from 'crypto';
import * as fs from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';
import { ChildProcess } from 'child_process';
import {
  findGitRoot,
  findXmlRoot,
  getGitChangedFiles,
  subPathOf,
  toLoadRelativePaths
} from './changes';
import { infobaseLabel, platformVersionOf, readIbases } from './ibases';
import {
  configuratorBusyMessage,
  clearRepositoryLog,
  copyFailureLog,
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
import { webviewHtml } from './webviewHtml';

function showToast(text: string, ms: number): void {
  const title = text.replace(/\s*\n\s*/g, ' ').trim();
  void vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title },
    () => new Promise<void>(resolve => setTimeout(resolve, ms))
  );
}

interface LoadContext {
  gitRoot: string;
  xmlDir: string;
  relFiles: string[];
  listFile: string;
  logFile: string;
  base: Infobase;
}

export class LoaderViewProvider implements vscode.WebviewViewProvider {
  public static readonly viewType = 'onecLoader.panel';

  private view?: vscode.WebviewView;
  private projectPath = '';
  private bases: Infobase[] = [];
  private selectedIndex = 0;
  private files: FileItem[] = [];
  private foundText = '';
  private foundTone: StatusTone = 'muted';
  private statusText = '';
  private statusTone: StatusTone = 'muted';
  private loading = false;
  private reading = false;
  private loadGen = 0;
  private settledGen = -1;
  private versionRetried = false;
  private proc: ChildProcess | null = null;
  private loadCtx: LoadContext | null = null;
  private loadingExe = '';
  private progressDone: (() => void) | null = null;

  constructor(private readonly context: vscode.ExtensionContext) {}

  resolveWebviewView(webviewView: vscode.WebviewView): void {
    this.view = webviewView;
    webviewView.webview.options = {
      enableScripts: true,
      localResourceRoots: [vscode.Uri.joinPath(this.context.extensionUri, 'media')]
    };
    const nonce = crypto.randomBytes(16).toString('hex');
    const fontUri = webviewView.webview.asWebviewUri(vscode.Uri.joinPath(this.context.extensionUri, 'media', 'codicon.ttf'));
    webviewView.webview.html = webviewHtml(nonce, fontUri.toString(), webviewView.webview.cspSource);
    webviewView.webview.onDidReceiveMessage(message => {
      void this.onMessage(message);
    });
    webviewView.onDidChangeVisibility(() => {
      if (webviewView.visible && !this.loading) {
        this.reloadBases(true);
        this.postState();
      }
    });
    if (!this.projectPath) {
      this.projectPath = this.defaultProjectPath();
    }
    this.reloadBases(false);
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
      reading: this.reading
    };
  }

  private postState(): void {
    void this.view?.webview.postMessage({ type: 'state', state: this.state() });
  }

  public refresh(): void {
    if (process.platform !== 'win32') {
      return;
    }
    void this.readChanges();
  }

  private startProgress(): void {
    this.stopProgress();
    let resolve!: () => void;
    const pending = new Promise<void>(done => {
      resolve = done;
    });
    this.progressDone = resolve;
    void vscode.window.withProgress(
      { location: { viewId: LoaderViewProvider.viewType }, cancellable: false },
      () => pending
    );
  }

  private stopProgress(): void {
    const resolve = this.progressDone;
    this.progressDone = null;
    resolve?.();
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

  private clearFiles(): void {
    this.files = [];
    this.foundText = '';
    this.foundTone = 'muted';
    this.setStatus('', 'muted');
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
        this.clearFiles();
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
      case 'load':
        await this.startLoad();
        return;
      default:
        return;
    }
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
    this.clearFiles();
  }

  private async readChanges(): Promise<void> {
    if (this.loading || this.reading) {
      return;
    }
    this.reading = true;
    this.files = [];
    this.foundText = '';
    this.foundTone = 'muted';
    this.startProgress();
    this.postState();
    try {
      const folder = this.projectPath.trim();
      if (!folder) {
        this.setStatus('Сначала выберите папку проекта.', 'error');
        return;
      }
      if (!fs.existsSync(folder) || !fs.statSync(folder).isDirectory()) {
        this.setStatus(`Папка не найдена: ${folder}`, 'error');
        return;
      }
      const gitRoot = findGitRoot(folder);
      if (!gitRoot) {
        this.setStatus('Ошибка: папка не является git-репозиторием (нет .git).', 'error');
        return;
      }
      const xmlDir = findXmlRoot(folder) ?? folder;
      const subPath = subPathOf(gitRoot, xmlDir);
      const names = await getGitChangedFiles(gitRoot, subPath);
      this.files = names.map(name => ({ path: name, checked: true }));
      this.setStatus('', 'muted');
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (message === 'ENOENT' || message.includes('ENOENT')) {
        this.setStatus('Ошибка: git не найден в PATH. Установите Git for Windows.', 'error');
      } else {
        this.setStatus(`Ошибка git: ${message}`, 'error');
      }
    } finally {
      this.reading = false;
      this.stopProgress();
      this.postState();
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

    // Показываем системный progress до долгих проверок платформы и конфигуратора.
    this.loading = true;
    this.versionRetried = false;
    this.loadingExe = '';
    this.statusText = '';
    this.statusTone = 'muted';
    this.startProgress();
    this.postState();

    const platform = await find1CExecutable(required);
    if (!platform.path) {
      this.loading = false;
      this.stopProgress();
      this.postState();
      void vscode.window.showErrorMessage('1cv8.exe не найден. Установите платформу 1С:Предприятие.');
      return;
    }
    const busy = await configuratorBusyMessage(base);
    if (busy) {
      this.loading = false;
      this.stopProgress();
      this.postState();
      showToast(busy, 3000);
      return;
    }
    try {
      const paths = tempLoadPaths();
      clearRepositoryLog(gitRoot);
      writeListFile(paths.listFile, relFiles);
      this.loadCtx = {
        gitRoot,
        xmlDir,
        relFiles,
        listFile: paths.listFile,
        logFile: paths.logFile,
        base
      };
      this.loadingExe = platform.path;
      this.spawnLoad(platform.path);
    } catch (error) {
      this.loading = false;
      this.stopProgress();
      this.proc = null;
      this.loadCtx = null;
      const message = error instanceof Error ? error.message : String(error);
      this.setStatus(`Ошибка подготовки загрузки: ${message}`, 'error');
    }
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
        logFile: ctx.logFile
      });
    } catch (error) {
      this.failStart(error instanceof Error ? error.message : String(error));
      return;
    }
    this.proc = proc;
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
    this.stopProgress();
    this.loading = false;
    this.proc = null;
    this.loadCtx = null;
    this.setStatus(`Ошибка запуска загрузки: ${message}`, 'error');
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
        this.spawnLoad(retry.path);
        return;
      }
    }
    const logText = ctx ? readLogText(ctx.logFile) : '';
    if (code !== 0 && ctx) {
      const fallback = spawnError
        ? `Ошибка запуска загрузки: ${spawnError}`
        : `Загрузка завершилась с ошибкой.\r\nКод возврата: ${code}`;
      copyFailureLog(ctx.logFile, ctx.gitRoot, fallback);
      if (mismatch) {
        copyMismatchLog(ctx.logFile);
      }
    }
    this.cleanupFiles();
    this.stopProgress();
    this.loading = false;
    this.proc = null;
    this.loadCtx = null;
    if (code === 0 && !spawnError) {
      this.postState();
      showToast('Загрузка завершена успешно!', 2000);
      if (ctx && this.loadingExe) {
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
