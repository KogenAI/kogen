const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const project = path.resolve(__dirname, '../../examples/tiny_tasks');
const prefix = 'tiny-tasks-complete-command: ';

function runMix(file, ...args) {
  const result = spawnSync('mix', args, {
    cwd: project,
    env: { ...process.env, TODO_FILE: file },
    encoding: 'utf8',
    timeout: 15000,
  });
  if (result.error) throw result.error;
  assert.equal(result.signal, null, `mix ${args.join(' ')} was terminated`);
  return result;
}

function assertSuccess(result, command) {
  assert.equal(result.status, 0, `${command} failed:\n${result.stdout}${result.stderr}`);
}

function taskLines(stdout) {
  return stdout.split(/\r?\n/).filter(line => /^\d+ \[/.test(line));
}

function assertListed(stdout, ids, rows) {
  assert.deepEqual(taskLines(stdout), rows.map(([status, title], i) => `${ids[i]} [${status}] ${title}`),
    'plain list must preserve every task and its position');
}

function assertStatusChange(before, after, id) {
  const lines = before.toString('utf8').split('\n');
  const original = `${id}\topen\t`;
  const index = lines.findIndex(line => line.startsWith(original));
  assert.notEqual(index, -1, `seed file lacks open task ${id}`);
  lines[index] = `${id}\tdone\t${lines[index].slice(original.length)}`;
  assert.deepEqual(after, Buffer.from(lines.join('\n')), 'only the selected status field may change on disk');
}

function assertUnknown(result, id) {
  assert.ok(result.status > 0, `expected mix todo.complete ${id} to fail`);
  const diagnostic = `${result.stdout}\n${result.stderr}`.split(/\r?\n/)
    .filter(line => !/^Compiling \d+ files? \(\.ex\)$/.test(line)).join('\n');
  assert.match(diagnostic, new RegExp(`\\b${id}\\b`), `diagnostic must identify task ID ${id}: ${diagnostic}`);
}

function snapshot(file) {
  const { ino, mtimeNs } = fs.statSync(file, { bigint: true });
  return { bytes: fs.readFileSync(file), ino, mtimeNs };
}

function markOld(file) {
  // A fixed old mtime lets the test detect even an identical rewrite on a coarse filesystem.
  fs.utimesSync(file, 946684800, 946684800);
}

function assertUntouched(before, after) {
  assert.deepEqual(after.bytes, before.bytes, 'unknown completion changed task file bytes');
  assert.equal(after.ino, before.ino, 'unknown completion replaced the task file');
  assert.equal(after.mtimeNs, before.mtimeNs, 'unknown completion rewrote the task file');
}

function bindSteps() {
  const { After, Given, When, Then } = require('@cucumber/cucumber');

  After({ name: `${prefix}remove temporary task file` }, function () {
    if (this.completeScratch) fs.rmSync(this.completeScratch, { recursive: true, force: true });
  });

  Given(`${prefix}I add these tasks to a fresh temporary task file in this order:`, { timeout: 75000 }, function (table) {
    this.completeScratch = fs.mkdtempSync(path.join(os.tmpdir(), 'tiny-tasks-complete-'));
    this.file = path.join(this.completeScratch, 'tasks.tsv');
    this.titles = table.raw().flat();
    for (const title of this.titles) assertSuccess(runMix(this.file, 'todo.add', title), 'mix todo.add');
    const listed = runMix(this.file, 'todo.list');
    assertSuccess(listed, 'mix todo.list');
    this.ids = taskLines(listed.stdout).map(line => line.split(' ')[0]);
    assert.equal(this.ids.length, this.titles.length, 'seed list did not return every added task');
    assert.equal(new Set(this.ids).size, this.ids.length, 'seed IDs must be distinct');
    assertListed(listed.stdout, this.ids, this.titles.map(title => ['open', title]));
  });

  When(`${prefix}I run mix todo.complete with the ID of {string}`, { timeout: 20000 }, function (title) {
    this.id = this.ids[this.titles.indexOf(title)];
    assert.ok(this.id, `no seed ID found for ${title}`);
    this.before = snapshot(this.file);
    this.completed = runMix(this.file, 'todo.complete', this.id);
  });

  When(`${prefix}I run mix todo.complete with an ID absent from the list`, { timeout: 20000 }, function () {
    this.id = String(Math.max(...this.ids.map(Number)) + 1);
    markOld(this.file);
    this.before = snapshot(this.file);
    this.completed = runMix(this.file, 'todo.complete', this.id);
  });

  Then(`${prefix}mix todo.complete succeeds`, function () {
    assertSuccess(this.completed, `mix todo.complete ${this.id}`);
  });

  Then(`${prefix}plain mix todo.list shows exactly these tasks with their original IDs in order:`, { timeout: 20000 }, function (table) {
    const listed = runMix(this.file, 'todo.list');
    assertSuccess(listed, 'mix todo.list');
    assertListed(listed.stdout, this.ids, table.raw());
  });

  Then(`${prefix}only the selected task's status field changes on disk`, function () {
    assertStatusChange(this.before.bytes, fs.readFileSync(this.file), this.id);
  });

  Then(`${prefix}mix todo.complete fails and reports the offending ID`, function () {
    assertUnknown(this.completed, this.id);
  });

  Then(`${prefix}the task file is unchanged and was not rewritten`, function () {
    assertUntouched(this.before, snapshot(this.file));
  });
}

// Focused observer controls: execute the same assertion functions against local fixture observations.
function qualify(mode) {
  assert.ok(['good', 'bad'].includes(mode), 'expected good or bad');
  const good = mode === 'good';
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tiny-tasks-observer-'));
  try {
    const file = path.join(dir, 'tasks.tsv');
    const seed = Buffer.from('1\topen\tQQ==\n2\topen\tQg==\n');
    const completed = Buffer.from(good ? '1\tdone\tQQ==\n2\topen\tQg==\n' : '1\tdone\tQQ==\n2\tdone\tQg==\n');
    fs.writeFileSync(file, seed);
    markOld(file);
    const before = snapshot(file);
    if (!good) fs.writeFileSync(file, seed);
    const observations = [
      () => assertListed(good ? '1 [done] A\n2 [open] B\n' : '2 [open] B\n1 [done] A\n', ['1', '2'], [['done', 'A'], ['open', 'B']]),
      () => assertStatusChange(seed, completed, '1'),
      () => assertUnknown({ status: 1, stdout: 'Compiling 3 files (.ex)', stderr: good ? '** (Mix) Unknown task ID: 3' : '** (Mix) Task not found' }, '3'),
      () => assertUnknown({ status: 1, stdout: good ? 'Task 3 does not exist' : 'Task does not exist', stderr: '' }, '3'),
      () => assertUntouched(before, snapshot(file)),
    ];
    for (const observe of observations) {
      if (good) observe();
      else assert.throws(observe, { code: 'ERR_ASSERTION' });
    }
    console.log(good ? 'good observations accepted' : 'all bad observations rejected');
    if (!good) process.exitCode = 1;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

if (require.main === module) qualify(process.argv[2]);
else bindSteps();
