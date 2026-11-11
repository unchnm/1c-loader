import { execFile, spawn, ChildProcess } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { Infobase, VersionMismatch } from './types';
import { connectionToken } from './ibases';

export interface LoadRequest {
  exePath: string;
  infobase: Infobase;
  xmlDir: string;
  listFile: string;
  logFile: string;
}

const MISMATCH_RE = /\(\s*([0-9]+(?:\.[0-9]+){1,3})\s*-\s*([0-9]+(?:\.[0-9]+){1,3})\s*\)/;

export function buildDesignerArgs(req: Omit<LoadRequest, 'exePath'>): string[] {
  const args = ['DESIGNER', '/AppAutoCheckVersion-'];
  if (req.infobase.isServer) {
    args.push('/S', connectionToken(req.infobase));
  } else {
    args.push('/F', req.infobase.filePath);
  }
  args.push(
    '/DisableStartupDialogs',
    '/LoadConfigFromFiles',
    req.xmlDir,
    '-listFile',
    req.listFile,
    '-Format',
    'Hierarchical',
    '-updateConfigDumpInfo',
    '/Out',
    req.logFile
  );
  return args;
}

export function writeListFile(target: string, relativePaths: string[]): void {
  const body = relativePaths.join('\r\n') + (relativePaths.length ? '\r\n' : '');
  fs.writeFileSync(target, '\uFEFF' + body, 'utf8');
}

export function readLogText(logPath: string): string {
  if (!logPath || !fs.existsSync(logPath)) {
    return '';
  }
  const buf = fs.readFileSync(logPath);
  if (buf.length >= 2 && buf[0] === 0xff && buf[1] === 0xfe) {
    return buf.subarray(2).toString('utf16le').trim();
  }
  const utf8 = buf.toString('utf8').replace(/^\uFEFF/, '');
  if (!utf8.includes('\uFFFD')) {
    return utf8.trim();
  }
  try {
    return new TextDecoder('windows-1251').decode(buf).trim();
  } catch {
    return utf8.trim();
  }
}

export function readVersionMismatch(logPath: string): VersionMismatch | null {
  const text = readLogText(logPath);
  if (!text) {
    return null;
  }
  const match = MISMATCH_RE.exec(text);
  if (!match) {
    return null;
  }
  return { client: match[1], server: match[2] };
}

export function startDesignerLoad(req: LoadRequest): ChildProcess {
  return spawn(req.exePath, buildDesignerArgs(req), { windowsHide: true, stdio: 'ignore' });
}

export function openConfigurator(exePath: string, infobase: Infobase): ChildProcess {
  const args = ['DESIGNER', '/AppAutoCheckVersion-'];
  if (infobase.isServer) {
    args.push('/S', connectionToken(infobase));
  } else {
    args.push('/F', infobase.filePath);
  }
  const proc = spawn(exePath, args, { detached: true, stdio: 'ignore', windowsHide: false });
  proc.unref();
  return proc;
}

function commandLines(): Promise<string[]> {
  const script = "Get-CimInstance Win32_Process -Filter \"Name='1cv8.exe'\" | ForEach-Object { $_.CommandLine }";
  return new Promise(resolve => {
    execFile(
      'powershell.exe',
      ['-NoProfile', '-Command', script],
      { windowsHide: true, maxBuffer: 16 * 1024 * 1024 },
      (err, stdout) => {
        if (err) {
          resolve([]);
          return;
        }
        resolve(stdout.split(/\r?\n/).map(line => line.trim()).filter(Boolean));
      }
    );
  });
}

export async function configuratorBusyMessage(infobase: Infobase): Promise<string | null> {
  let lines: string[] = [];
  try {
    lines = await commandLines();
  } catch {
    return null;
  }
  const token = connectionToken(infobase).toLowerCase();
  const alt = token.replace(/\\/g, '/');
  const busy = lines.some(line => {
    const text = line.toLowerCase();
    return text.includes('designer') && (text.includes(token) || text.includes(alt));
  });
  if (!busy) {
    return null;
  }
  return `Конфигуратор базы "${infobase.name}" уже открыт.\n\nЗакройте конфигуратор и повторите загрузку.`;
}

export function tempLoadPaths(): { listFile: string; logFile: string } {
  const dir = os.tmpdir();
  const stamp = `${process.pid}-${Date.now()}`;
  return {
    listFile: path.join(dir, `1c-loader-${stamp}-files.txt`),
    logFile: path.join(dir, `1c-loader-${stamp}-log.txt`)
  };
}

export function clearRepositoryLog(repositoryRoot: string): void {
  if (!repositoryRoot) {
    return;
  }
  try {
    const target = path.join(repositoryRoot, '.1c-log.txt');
    if (fs.existsSync(target)) {
      fs.unlinkSync(target);
    }
  } catch {
    // старый лог не должен блокировать новую загрузку
  }
}

export function copyFailureLog(logPath: string, repositoryRoot: string, fallbackText: string): void {
  if (!repositoryRoot) {
    return;
  }
  try {
    const target = path.join(repositoryRoot, '.1c-log.txt');
    if (logPath && fs.existsSync(logPath) && fs.statSync(logPath).size > 0) {
      fs.copyFileSync(logPath, target);
      return;
    }
    if (fallbackText) {
      fs.writeFileSync(target, `${fallbackText}\r\n`, 'utf8');
    }
  } catch {
    // запись диагностического лога не должна скрывать исходную ошибку загрузки
  }
}

export function copyMismatchLog(logPath: string): void {
  if (!logPath || !fs.existsSync(logPath)) {
    return;
  }
  try {
    fs.copyFileSync(logPath, path.join(os.tmpdir(), '1c-loader-last-cmd.txt'));
  } catch {
    // копия лога не обязательна для сообщения об ошибке
  }
}
