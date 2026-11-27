'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { After, Given, When, Then } = require('@cucumber/cucumber');

const prefix = 'missing-task-arguments-report-usage: ';
const projectRoot = path.resolve(__dirname, '../../examples/tiny_tasks');

function mix(world, args) {
  const r = spawnSync('mix', args, {
    cwd: projectRoot,
    encoding: 'utf8',
    timeout: 100000,
    env: { ...process.env, TODO_FILE: world.missingArgFile }
  });
  assert.equal(r.error, undefined, `mix ${args.join(' ')} failed to run: ${r.error}`);
  return { status: r.status, output: (r.stdout || '') + (r.stderr || '') };
}

function freshFile(world) {
  world.missingArgScratch = fs.mkdtempSync(path.join(os.tmpdir(), 'missing-task-args-'));
  world.missingArgFile = path.join(world.missingArgScratch, 'tasks.tsv');
}

After(function () {
  if (this.missingArgScratch) fs.rmSync(this.missingArgScratch, { recursive: true, force: true });
});

Given(prefix + 'there is no task file yet', function () {
  freshFile(this);
  assert.equal(fs.existsSync(this.missingArgFile), false);
});

Given(prefix + 'a task file holding the task {string}', { timeout: 110000 }, function (title) {
  freshFile(this);
  const added = mix(this, ['todo.add', title]);
  assert.equal(added.status, 0, `setup todo.add failed:\n${added.output}`);
  this.missingArgBefore = fs.readFileSync(this.missingArgFile);
  // An old timestamp makes even an identical in-place rewrite observable.
  fs.utimesSync(this.missingArgFile, new Date('2000-01-01T00:00:00Z'), new Date('2000-01-01T00:00:00Z'));
  this.missingArgStat = fs.statSync(this.missingArgFile);
});

When(prefix + 'I run {string} with no arguments', { timeout: 110000 }, function (task) {
  this.missingArgResult = mix(this, [task]);
});

Then(prefix + 'the command exits unsuccessfully', function () {
  const { status, output } = this.missingArgResult;
  assert.notEqual(status, 0, `expected a nonzero exit status, got ${status}; output:\n${output}`);
});

Then(prefix + 'the output names the missing {string}', function (word) {
  const { output } = this.missingArgResult;
  const re = new RegExp(`\\b${word}\\b`, 'i');
  assert.match(output, re, `expected the output to name the missing ${word}; output:\n${output}`);
});

Then(prefix + 'the output reports no function clause error', function () {
  const { output } = this.missingArgResult;
  assert.doesNotMatch(output, /FunctionClauseError|no function clause/i, `output is a function-clause failure:\n${output}`);
});

Then(prefix + 'no task file exists', function () {
  assert.equal(fs.existsSync(this.missingArgFile), false, `task file was created at ${this.missingArgFile}`);
});

Then(prefix + 'the task file is byte-for-byte unchanged', function () {
  const after = fs.readFileSync(this.missingArgFile);
  assert.equal(after.toString('hex'), this.missingArgBefore.toString('hex'), 'task file bytes changed');
  const stat = fs.statSync(this.missingArgFile);
  assert.equal(stat.ino, this.missingArgStat.ino, 'task file was replaced');
  assert.equal(stat.mtimeMs, this.missingArgStat.mtimeMs, 'task file was rewritten');
});
