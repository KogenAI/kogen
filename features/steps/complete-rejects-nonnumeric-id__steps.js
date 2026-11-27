const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { After, Given, When, Then } = require('@cucumber/cucumber');

const projectRoot = path.resolve(process.cwd(), 'examples/tiny_tasks');
const oldTime = new Date('2000-01-01T00:00:00Z');

function runMix(world, args) {
  const result = spawnSync('mix', args, {
    cwd: projectRoot,
    encoding: 'utf8',
    timeout: 100000,
    env: { ...process.env, TODO_FILE: world.tasksFile }
  });
  assert.equal(result.error, undefined, `mix ${args.join(' ')} did not run: ${result.error}`);
  return result;
}

After(function () {
  if (this.scratch) fs.rmSync(this.scratch, { recursive: true, force: true });
});

Given('complete-rejects-nonnumeric-id: a task file holding the open tasks {string} and {string} with an old modification time', function (first, second) {
  this.scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'complete-nonnumeric-'));
  this.tasksFile = path.join(this.scratch, 'tasks.tsv');
  for (const title of [first, second]) {
    const added = runMix(this, ['todo.add', title]);
    assert.equal(added.status, 0, `mix todo.add ${title} failed: ${added.stdout}${added.stderr}`);
  }
  fs.utimesSync(this.tasksFile, oldTime, oldTime);
  this.before = fs.readFileSync(this.tasksFile);
  this.beforeMtime = fs.statSync(this.tasksFile, { bigint: true }).mtimeNs;
});

When('complete-rejects-nonnumeric-id: I run todo.complete with the ID {string}', function (id) {
  const result = runMix(this, ['todo.complete', id]);
  this.status = result.status;
  this.output = `${result.stdout}${result.stderr}`;
});

Then('complete-rejects-nonnumeric-id: the command exits unsuccessfully', function () {
  assert.notEqual(this.status, 0, `expected a nonzero exit, got ${this.status}; output:\n${this.output}`);
});

Then('complete-rejects-nonnumeric-id: the output shows no implementation exception', function () {
  assert.doesNotMatch(this.output, /ArgumentError/, `output shows an implementation exception:\n${this.output}`);
  assert.doesNotMatch(this.output, /\*\* \((?!Mix\))[\w.]+\)/, `output shows an implementation exception:\n${this.output}`);
});

Then('complete-rejects-nonnumeric-id: the output reports {string} as an invalid task ID', function (id) {
  assert.ok(this.output.includes(id), `output does not name ${id}:\n${this.output}`);
  assert.match(this.output, /invalid/i, `output does not say the ID is invalid:\n${this.output}`);
});

Then('complete-rejects-nonnumeric-id: the output reports that task {string} was not found', function (id) {
  assert.ok(this.output.includes(id), `output does not name ${id}:\n${this.output}`);
  assert.match(this.output, /not found/i, `output does not say the task was not found:\n${this.output}`);
  assert.doesNotMatch(this.output, /invalid/i, `an unknown ID must not be reported as invalid:\n${this.output}`);
});

Then('complete-rejects-nonnumeric-id: the task file bytes and modification time are unchanged', function () {
  const after = fs.readFileSync(this.tasksFile);
  assert.ok(after.equals(this.before), `task file bytes changed:\n${this.before}\n---\n${after}`);
  const mtime = fs.statSync(this.tasksFile, { bigint: true }).mtimeNs;
  assert.equal(mtime, this.beforeMtime, 'task file modification time changed');
});
