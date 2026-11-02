import { execFile } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';
import { PlatformMatch } from './types';
import { compareVersions, versionPrefixMatch } from './version';

interface InstalledPlatform {
  version: string;
  path: string;
}

function execText(command: string, args: string[]): Promise<string> {
  return new Promise(resolve => {
    execFile(command, args, { windowsHide: true, maxBuffer: 8 * 1024 * 1024 }, (err, stdout) => {
      resolve(err ? '' : stdout);
    });
  });
}

function remember(found: Map<string, string>, version: string, exePath: string): void {
  const ver = version.trim();
  if (!ver || !exePath || !fs.existsSync(exePath)) {
    return;
  }
  found.set(ver, exePath);
}

export async function getInstalledPlatforms(): Promise<InstalledPlatform[]> {
  const found = new Map<string, string>();
  if (process.platform === 'win32') {
    for (const key of ['HKLM\\SOFTWARE\\1C\\1Cv8', 'HKLM\\SOFTWARE\\WOW6432Node\\1C\\1Cv8']) {
      const text = await execText('reg', ['query', key, '/s']);
      let currentVersion = '';
      for (const line of text.split(/\r?\n/)) {
        const keyLine = /^HKEY_LOCAL_MACHINE\\.+\\([^\\]+)\s*$/i.exec(line.trim());
        if (keyLine) {
          currentVersion = keyLine[1];
          continue;
        }
        const loc = /^\s*InstallLocation\s+REG_\w+\s+(.+)$/i.exec(line);
        if (loc && currentVersion) {
          remember(found, currentVersion, path.join(loc[1].trim(), 'bin', '1cv8.exe'));
        }
      }
    }
    const roots = [
      path.join(process.env['ProgramFiles'] || 'C:\\Program Files', '1cv8'),
      path.join(process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)', '1cv8')
    ];
    for (const root of roots) {
      if (!fs.existsSync(root)) {
        continue;
      }
      let entries: fs.Dirent[] = [];
      try {
        entries = fs.readdirSync(root, { withFileTypes: true });
      } catch {
        continue;
      }
      for (const entry of entries) {
        if (!entry.isDirectory()) {
          continue;
        }
        remember(found, entry.name, path.join(root, entry.name, 'bin', '1cv8.exe'));
      }
    }
  }
  return [...found.entries()]
    .filter(([version]) => version.split('.').length >= 2 && version.split('.').every(part => /^\d+$/.test(part)))
    .map(([version, exe]) => ({ version, path: exe }))
    .sort((a, b) => compareVersions(b.version, a.version));
}

export async function find1CExecutable(requiredVersion?: string | null): Promise<PlatformMatch> {
  const platforms = await getInstalledPlatforms();
  if (platforms.length === 0) {
    return { path: null, matchedVersion: null, usedFallback: false, warning: null };
  }
  if (!requiredVersion) {
    const best = platforms[0];
    return {
      path: best.path,
      matchedVersion: best.version,
      usedFallback: true,
      warning: 'Версия платформы для базы не указана в ibases.v8i — используется новейшая установленная.'
    };
  }
  const req = requiredVersion.trim();
  const exact = platforms.find(p => p.version === req);
  if (exact) {
    return { path: exact.path, matchedVersion: exact.version, usedFallback: false, warning: null };
  }
  const prefixed = platforms.find(p => versionPrefixMatch(p.version, req) && p.version !== req);
  if (prefixed) {
    return {
      path: prefixed.path,
      matchedVersion: prefixed.version,
      usedFallback: true,
      warning: `Точная версия ${req} не найдена — используется ${prefixed.version}`
    };
  }
  const newest = platforms[0];
  return {
    path: newest.path,
    matchedVersion: newest.version,
    usedFallback: true,
    warning: `Версия ${req} не установлена — используется ${newest.version}`
  };
}
