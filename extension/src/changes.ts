import { execFile } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';

const XML_SUBDIRS = ['src', 'src/cf', 'cf', 'config', '1c', 'src/1c', '1c/cf'];

export function findGitRoot(startPath: string): string | null {
  let cur = path.resolve(startPath);
  while (true) {
    if (fs.existsSync(path.join(cur, '.git'))) {
      return cur;
    }
    const parent = path.dirname(cur);
    if (parent === cur) {
      return null;
    }
    cur = parent;
  }
}

export function findXmlRoot(startPath: string): string | null {
  const start = path.resolve(startPath);
  if (fs.existsSync(path.join(start, 'Configuration.xml'))) {
    return start;
  }
  for (const sub of XML_SUBDIRS) {
    const candidate = path.join(start, ...sub.split('/'));
    if (fs.existsSync(path.join(candidate, 'Configuration.xml'))) {
      return candidate;
    }
  }
  let entries: fs.Dirent[] = [];
  try {
    entries = fs.readdirSync(start, { withFileTypes: true });
  } catch {
    return null;
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) {
      continue;
    }
    if (fs.existsSync(path.join(start, entry.name, 'Configuration.xml'))) {
      return path.join(start, entry.name);
    }
  }
  return null;
}

export function subPathOf(gitRoot: string, xmlDir: string): string {
  const rel = path.relative(gitRoot, xmlDir);
  if (!rel || rel.startsWith('..') || path.isAbsolute(rel)) {
    return '';
  }
  return rel.replace(/\\/g, '/');
}

export function filterChangedNames(names: string[], subPath: string): string[] {
  const uniq = new Set<string>();
  for (const name of names) {
    if (!name) {
      continue;
    }
    let norm = name.replace(/\\/g, '/').trim();
    if (norm.startsWith('"') && norm.endsWith('"')) {
      norm = norm.slice(1, -1);
    }
    if (!/\.(xml|bsl)$/i.test(norm)) {
      continue;
    }
    uniq.add(norm);
  }
  let all = [...uniq].sort((a, b) => a.localeCompare(b, 'ru'));
  if (subPath) {
    const prefix = subPath.replace(/\\/g, '/').replace(/\/$/, '') + '/';
    all = all.filter(file => file.startsWith(prefix));
  }
  return all;
}

export function toLoadRelativePaths(gitFiles: string[], subPath: string): string[] {
  const prefix = subPath ? subPath.replace(/\\/g, '/').replace(/\/$/, '') + '/' : '';
  return gitFiles.map(file => {
    const norm = file.replace(/\\/g, '/');
    const rel = prefix && norm.startsWith(prefix) ? norm.slice(prefix.length) : norm;
    return rel.replace(/\//g, '\\');
  });
}

function gitOutput(cwd: string, args: string[]): Promise<{ ok: boolean; lines: string[]; error: string }> {
  return new Promise(resolve => {
    execFile(
      'git',
      ['-c', 'core.quotepath=false', ...args],
      { cwd, windowsHide: true, maxBuffer: 32 * 1024 * 1024 },
      (err, stdout, stderr) => {
        const lines = stdout.split(/\r?\n/).map(line => line.trim()).filter(Boolean);
        if (err) {
          resolve({ ok: false, lines, error: (stderr || err.message).trim() });
          return;
        }
        resolve({ ok: true, lines, error: '' });
      }
    );
  });
}

export async function gitAvailable(): Promise<boolean> {
  return new Promise(resolve => {
    execFile('git', ['--version'], { windowsHide: true }, err => resolve(!err));
  });
}

export async function getGitChangedFiles(gitRoot: string, subPath = ''): Promise<string[]> {
  const unstaged = await gitOutput(gitRoot, ['diff', 'HEAD', '--name-only', '--diff-filter=ACMR']);
  if (!unstaged.ok) {
    throw new Error('git diff error: ' + unstaged.error);
  }
  const staged = await gitOutput(gitRoot, ['diff', '--cached', '--name-only', '--diff-filter=ACMR']);
  const untracked = await gitOutput(gitRoot, ['ls-files', '--others', '--exclude-standard']);
  const names = [
    ...unstaged.lines,
    ...(staged.ok ? staged.lines : []),
    ...(untracked.ok ? untracked.lines : [])
  ];
  return filterChangedNames(names, subPath);
}
