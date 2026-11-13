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

async function gitRef(gitRoot: string, args: string[]): Promise<string | null> {
  const result = await gitOutput(gitRoot, args);
  return result.ok && result.lines[0] ? result.lines[0].trim() : null;
}

async function gitRefs(gitRoot: string): Promise<string[]> {
  const result = await gitOutput(gitRoot, [
    'for-each-ref',
    '--format=%(refname)',
    'refs/heads',
    'refs/remotes'
  ]);
  return result.ok ? result.lines.map(ref => ref.trim()).filter(Boolean) : [];
}

async function committedLogArgs(gitRoot: string): Promise<string[] | null> {
  const branch = await gitRef(gitRoot, ['branch', '--show-current']);
  const upstream = await gitRef(gitRoot, ['rev-parse', '--symbolic-full-name', '@{upstream}']);
  const refs = await gitRefs(gitRoot);
  const currentRefs = new Set<string>();
  if (branch) {
    currentRefs.add(`refs/heads/${branch}`);
  }
  if (upstream) {
    currentRefs.add(upstream);
  }

  // Все refs, кроме текущей ветки и её remote-tracking ref, являются
  // кандидатами на целевую ветку PR. Такой диапазон не зависит от имени
  // основной ветки (main, master, develop и т. п.) и не включает её историю.
  const targetRefs = refs.filter(ref => !currentRefs.has(ref));
  if (targetRefs.length === 0) {
    return null;
  }
  return ['--no-optional-locks', 'log', '--format=', '--name-only', '--diff-filter=ACMR', 'HEAD', '--not', ...targetRefs];
}

/**
 * Returns XML/BSL files changed in the current branch and in the working tree.
 * The committed part is limited to commits reachable from HEAD but not from
 * any other local or remote branch, which matches the commit set of a PR.
 * The default mode keeps the existing status-only behavior.
 */
export async function getGitFiles(gitRoot: string, subPath = '', onlyUncommitted = true): Promise<string[]> {
  const uncommitted = await getGitChangedFiles(gitRoot, subPath);
  if (onlyUncommitted) {
    return uncommitted;
  }

  const args = await committedLogArgs(gitRoot);
  if (!args) {
    return uncommitted;
  }
  const prefix = subPath.replace(/\\/g, '/').replace(/\/$/, '');
  if (prefix) {
    args.push('--', prefix);
  }
  const result = await gitOutput(gitRoot, args);
  if (!result.ok) {
    if (result.code === 'ENOENT') {
      throw new Error('ENOENT');
    }
    throw new Error('git log error: ' + result.error);
  }
  return filterChangedNames([...result.lines, ...uncommitted], subPath).filter(file => {
    try {
      return fs.existsSync(path.join(gitRoot, ...file.split('/')));
    } catch {
      return false;
    }
  });
}
