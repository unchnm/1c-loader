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

function gitOutput(cwd: string, args: string[]): Promise<{ ok: boolean; lines: string[]; error: string; code: string }> {
  return new Promise(resolve => {
    execFile(
      'git',
      ['-c', 'core.quotepath=false', ...args],
      { cwd, windowsHide: true, maxBuffer: 32 * 1024 * 1024 },
      (err, stdout, stderr) => {
        const lines = stdout.split(/\r?\n/).filter(line => line.trim().length > 0);
        if (err) {
          const code = (err as NodeJS.ErrnoException).code || '';
          resolve({ ok: false, lines, error: (stderr || err.message).trim(), code });
          return;
        }
        resolve({ ok: true, lines, error: '', code: '' });
      }
    );
  });
}

export function pathsFromStatus(lines: string[]): string[] {
  const names: string[] = [];
  for (const line of lines) {
    if (line.length < 4) {
      continue;
    }
    const x = line[0];
    const y = line[1];
    if ((x === 'D' || x === ' ') && (y === 'D' || y === ' ') && (x === 'D' || y === 'D')) {
      continue;
    }
    let file = line.slice(3);
    const arrow = file.lastIndexOf(' -> ');
    if ((x === 'R' || x === 'C' || y === 'R' || y === 'C') && arrow >= 0) {
      file = file.slice(arrow + 4);
    }
    names.push(file.trim());
  }
  return names;
}

export async function getGitChangedFiles(gitRoot: string, subPath = ''): Promise<string[]> {
  const prefix = subPath.replace(/\\/g, '/').replace(/\/$/, '');
  const args = ['--no-optional-locks', 'status', '--porcelain', '-uall'];
  if (prefix) {
    args.push('--', prefix);
  }
  const result = await gitOutput(gitRoot, args);
  if (!result.ok) {
    if (result.code === 'ENOENT') {
      throw new Error('ENOENT');
    }
    throw new Error('git status error: ' + result.error);
  }
  return filterChangedNames(pathsFromStatus(result.lines), subPath);
}
