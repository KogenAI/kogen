const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const prefix = 'tiny-tasks-open-task-filter: ';
const project = path.resolve(__dirname, '../../examples/tiny_tasks');

function assertListing(command, result, expected) {
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `${command} failed (${result.signal ?? result.status}):\n${result.stdout}${result.stderr}`);
  // A cold Mix invocation may write compilation diagnostics before the task runs.
  const listing = result.stdout.replace(/^(?:Compiling \d+ files? \(\.ex\)\n)?(?:Generated tiny_tasks app\n)?/, '');
  assert.equal(listing, `${expected}\n`, `${command} stdout differs from the expected listing`);
}

function bindSteps() {
  const { After, Given, When, Then } = require('@cucumber/cucumber');

  Given(`${prefix}a temporary task file contains these rows in order:`, function (table) {
    this.openListScratch = fs.mkdtempSync(path.join(os.tmpdir(), 'tiny-tasks-open-'));
    this.openListFile = path.join(this.openListScratch, 'tasks.tsv');
    const rows = table.raw().map(([id, status, title]) =>
      `${id}\t${status}\t${Buffer.from(title, 'utf8').toString('base64')}\n`);
    fs.writeFileSync(this.openListFile, rows.join(''));
  });

  When(`${prefix}I run {string}`, { timeout: 25000 }, function (command) {
    assert.ok(command === 'mix todo.list' || command === 'mix todo.list --open', command);
    this.openListCommand = command;
    this.openListResult = spawnSync('mix', command.split(' ').slice(1), {
      cwd: project,
      env: { ...process.env, MIX_ENV: 'dev', TODO_FILE: this.openListFile },
      encoding: 'utf8',
      timeout: 20000,
    });
  });

  for (const output of ['plain listing', 'filtered listing', 'empty result']) {
    Then(`${prefix}the ${output} is exactly:`, function (expected) {
      assertListing(this.openListCommand, this.openListResult, expected);
    });
  }

  After({ name: `${prefix}remove the temporary task file` }, function () {
    if (this.openListScratch) fs.rmSync(this.openListScratch, { recursive: true, force: true });
  });
}

function qualify(mode) {
  assert.ok(mode === 'good' || mode === 'bad', 'expected good or bad');
  const plain = '7 [open] Zebra\n4 [done] Finished\n9 [open] Apple\n2 [open] Mango';
  const filtered = '7 [open] Zebra\n9 [open] Apple\n2 [open] Mango';
  const empty = 'No tasks yet.';
  const observe = (stdout, expected, status = 0) =>
    assertListing('mix todo.list observer control', { status, stdout, stderr: '' }, expected);

  if (mode === 'good') {
    observe(`Compiling 5 files (.ex)\nGenerated tiny_tasks app\n${plain}\n`, plain);
    observe(`${filtered}\n`, filtered);
    observe(`${empty}\n`, empty);
    console.log('good listings accepted');
  } else {
    for (const [stdout, expected, status] of [
      [`${filtered}\n`, plain],
      [`${plain}\n`, filtered],
      ['2 [open] Mango\n7 [open] Zebra\n9 [open] Apple\n', filtered],
      ['4 [done] Finished\n', empty],
      ['', empty],
      [`${empty}\n`, empty, 1],
    ]) {
      assert.throws(() => observe(stdout, expected, status), { code: 'ERR_ASSERTION' });
    }
    console.log('all bad listings rejected');
    process.exitCode = 1;
  }
}

if (require.main === module) qualify(process.argv[2]);
else bindSteps();
