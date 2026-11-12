import * as assert from 'assert';
import { execFileSync } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import test from 'node:test';
import { filterChangedNames, findGitRoot, findXmlRoot, getGitFiles, pathsFromStatus, subPathOf, toLoadRelativePaths } from './changes';
import { connectionToken, parseIbases, platformVersionOf } from './ibases';
import { buildDesignerArgs, clearRepositoryLog, copyFailureLog } from './load';
import { compareVersions, versionPrefixMatch } from './version';

const sample = `
[dev_feature]
Connect=Srvr="s-app-crm-dev-01:6541";Ref="dev_feature";
Version=8.3.27
DefaultVersion=8.3.27.1559
[Файловая]
Connect=File="C:\\bases\\demo";
Version=8.3.24
[Пустая]
ID=1
`;

test('parseIbases читает серверную и файловую базу', () => {
  const bases = parseIbases(sample);
  assert.strictEqual(bases.length, 2);
  assert.strictEqual(bases[0].isServer, true);
  assert.strictEqual(bases[0].server, 's-app-crm-dev-01:6541');
  assert.strictEqual(bases[0].ref, 'dev_feature');
  assert.strictEqual(platformVersionOf(bases[0]), '8.3.27.1559');
  assert.strictEqual(connectionToken(bases[0]), 's-app-crm-dev-01:6541\\dev_feature');
  assert.strictEqual(bases[1].isServer, false);
  assert.strictEqual(bases[1].filePath, 'C:\\bases\\demo');
  assert.strictEqual(platformVersionOf(bases[1]), '8.3.24');
});

test('версия: префикс и порядок', () => {
  assert.strictEqual(versionPrefixMatch('8.3.27.1559', '8.3.27'), true);
  assert.strictEqual(versionPrefixMatch('8.3.26.1000', '8.3.27'), false);
  assert.ok(compareVersions('8.3.27.1600', '8.3.27.1559') > 0);
});

test('git-список оставляет xml и bsl внутри корня конфигурации', () => {
  const names = filterChangedNames([
    'src/CommonModules/Модуль/Ext/Module.bsl',
    'src/Documents/Док/Forms/Форма/Ext/Form.xml',
    'README.md',
    'src/note.txt',
    'other/Module.bsl'
  ], 'src');
  assert.deepStrictEqual(names, [
    'src/CommonModules/Модуль/Ext/Module.bsl',
    'src/Documents/Док/Forms/Форма/Ext/Form.xml'
  ]);
  assert.deepStrictEqual(toLoadRelativePaths(names, 'src'), [
    'CommonModules\\Модуль\\Ext\\Module.bsl',
    'Documents\\Док\\Forms\\Форма\\Ext\\Form.xml'
  ]);
});

test('git status: правки и новые файлы, без удалений', () => {
  const names = pathsFromStatus([
    ' M src/CommonModules/Модуль/Ext/Module.bsl',
    'D  src/Catalogs/Старый/Ext/ObjectModule.bsl',
    '?? src/Catalogs/Новый/Ext/ObjectModule.bsl',
    'R  src/old.bsl -> src/new.bsl',
    'MM README.md'
  ]);
  assert.deepStrictEqual(names, [
    'src/CommonModules/Модуль/Ext/Module.bsl',
    'src/Catalogs/Новый/Ext/ObjectModule.bsl',
    'src/new.bsl',
    'README.md'
  ]);
});

test('расширенный список берет коммиты текущей ветки и незакоммиченные файлы без дублей', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'onec-loader-history-'));
  const git = (args: string[]) => execFileSync('git', args, { cwd: root, stdio: 'ignore' });
  try {
    git(['init', '-q']);
    git(['config', 'user.email', 'test@example.com']);
    git(['config', 'user.name', 'Test']);
    fs.writeFileSync(path.join(root, 'main.xml'), '<main/>');
    git(['add', '.']);
    git(['commit', '-qm', 'main']);
    git(['checkout', '-qb', 'feature']);
    fs.writeFileSync(path.join(root, 'branch.xml'), '<branch/>');
    git(['add', '.']);
    git(['commit', '-qm', 'branch']);
    fs.writeFileSync(path.join(root, 'second.bsl'), 'Процедура Тест(); КонецПроцедуры');
    git(['add', '.']);
    git(['commit', '-qm', 'second']);
    fs.writeFileSync(path.join(root, 'deleted.xml'), '<deleted/>');
    git(['add', '.']);
    git(['commit', '-qm', 'add deleted']);
    fs.rmSync(path.join(root, 'deleted.xml'));
    git(['add', '.']);
    git(['commit', '-qm', 'delete it']);
    fs.writeFileSync(path.join(root, 'working.xml'), '<working/>');
    fs.appendFileSync(path.join(root, 'branch.xml'), '<changed/>');

    assert.deepStrictEqual(await getGitFiles(root, '', false), [
      'branch.xml',
      'second.bsl',
      'working.xml'
    ]);
    assert.deepStrictEqual(await getGitFiles(root, '', true), [
      'branch.xml',
      'working.xml'
    ]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('корень Configuration.xml ищется в src', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'onec-loader-'));
  fs.mkdirSync(path.join(root, 'src'), { recursive: true });
  fs.writeFileSync(path.join(root, 'src', 'Configuration.xml'), '<MetaDataObject/>');
  fs.writeFileSync(path.join(root, '.git'), 'gitdir: somewhere');
  assert.strictEqual(findXmlRoot(root), path.join(root, 'src'));
  assert.strictEqual(findGitRoot(path.join(root, 'src')), root);
  assert.strictEqual(subPathOf(root, path.join(root, 'src')), 'src');
  fs.rmSync(root, { recursive: true, force: true });
});

test('аргументы дизайнера содержат listFile и не пишут devbase', () => {
  const args = buildDesignerArgs({
    infobase: {
      name: 'dev',
      server: 'srv',
      ref: 'base',
      filePath: '',
      isServer: true,
      version: '8.3.27',
      defaultVersion: '8.3.27.1559'
    },
    xmlDir: 'C:\\repo\\src',
    listFile: 'C:\\temp\\files.txt',
    logFile: 'C:\\temp\\log.txt'
  });
  assert.ok(args.includes('-listFile'));
  assert.ok(args.includes('C:\\temp\\files.txt'));
  assert.ok(!args.includes('/UpdateDBCfg'));
  assert.ok(args.includes('/S'));
  assert.ok(args.includes('srv\\base'));
  assert.ok(!args.some(arg => arg.toLowerCase().includes('devbase')));
});

test('ошибка загрузки сохраняется в корне репозитория', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'onec-loader-log-'));
  const tempLog = path.join(root, 'temp-log.txt');
  const repositoryLog = path.join(root, '.1c-log.txt');
  fs.writeFileSync(repositoryLog, 'старый лог', 'utf8');
  clearRepositoryLog(root);
  assert.strictEqual(fs.existsSync(repositoryLog), false);

  fs.writeFileSync(tempLog, 'ошибка 1С', 'utf8');
  copyFailureLog(tempLog, root, 'резервная ошибка');
  assert.strictEqual(fs.readFileSync(repositoryLog, 'utf8'), 'ошибка 1С');

  fs.rmSync(root, { recursive: true, force: true });
});
