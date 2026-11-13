import * as vscode from 'vscode';
import { LoaderViewProvider } from './panel';

export function activate(context: vscode.ExtensionContext): void {
  const provider = new LoaderViewProvider(context);
  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider(LoaderViewProvider.viewType, provider, {
      webviewOptions: { retainContextWhenHidden: true }
    }),
    vscode.commands.registerCommand('onecLoader.show', async () => {
      if (process.platform !== 'win32') {
        void vscode.window.showWarningMessage('Загрузка доступна только в Windows: нужны 1cv8.exe и список баз ibases.v8i.');
      }
      await vscode.commands.executeCommand('onecLoader.panel.focus');
    }),
    vscode.commands.registerCommand('onecLoader.refresh', () => {
      provider.refresh();
    })
  );
}

export function deactivate(): void {
  // процесс 1cv8, если он уже запущен, завершается вместе с конфигуратором сам
}
