'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { After, Given, When, Then } = require('@cucumber/cucumber');

const prefix = 'task-store-reports-malformed-row: ';
const projectRoot = path.resolve(__dirname, '../../examples/tiny_tasks');

After(function () {
  if (this.malformedRowScratch) fs.rmSync(this.malformedRowScratch, { recursive: true, force: true });
});

Given(prefix + 'a task file whose contents are {string}', function (text) {
  const contents = text.replace(/\\t/g, '\t').replace(/\\n/g, '\n');
  this.malformedRowScratch = fs.mkdtempSync(path.join(os.tmpdir(), 'malformed-row-'));
  this.malformedRowFile = path.join(this.malformedRowScratch, 'tasks.tsv');
  fs.writeFileSync(this.malformedRowFile, contents);
  // An old timestamp makes even an identical in-place rewrite observable.
  const old = new Date('2000-01-01T00:00:00Z');
  fs.utimesSync(this.malformedRowFile, old, old);
  this.malformedRowBefore = fs.readFileSync(this.malformedRowFile);
  this.malformedRowStat = fs.statSync(this.malformedRowFile);
});

When(prefix + 'I run {string} on that task file', { timeout: 110000 }, function (task) {
  const r = spawnSync('mix', [task], {
    cwd: projectRoot,
    encoding: 'utf8',
    timeout: 100000,
    env: { ...process.env, TODO_FILE: this.malformedRowFile }
  });
  assert.equal(r.error, undefined, `mix ${task} failed to run: ${r.error}`);
  this.malformedRowResult = { status: r.status, output: (r.stdout || '') + (r.stderr || '') };
});

Then(prefix + 'the command exits unsuccessfully', function () {
  const { status, output } = this.malformedRowResult;
  assert.notEqual(status, 0, `expected a nonzero exit status, got ${status}; output:\n${output}`);
});

Then(prefix + 'the command exits successfully', function () {
  const { status, output } = this.malformedRowResult;
  assert.equal(status, 0, `expected exit status 0, got ${status}; output:\n${output}`);
});

Then(prefix + 'the output names the task file path and line {int}', function (line) {
  const { output } = this.malformedRowResult;
  const file = this.malformedRowFile;
  assert.ok(output.includes(file), `expected the output to name ${file}; output:\n${output}`);
  const located = output.includes(`${file}:${line}`) || new RegExp(`\\bline ${line}(?!\\d)`, 'i').test(output);
  assert.ok(located, `expected the output to name one-based line ${line}; output:\n${output}`);
});

Then(prefix + 'the output reports no raw exception', function () {
  const { output } = this.malformedRowResult;
  assert.doesNotMatch(
    output,
    /MatchError|ArgumentError|FunctionClauseError|no match of right hand side|\(stdlib\)|\(elixir\)/,
    `output shows a raw exception instead of a concise error:\n${output}`
  );
});

Then(prefix + 'the task file is byte-for-byte unchanged', function () {
  const after = fs.readFileSync(this.malformedRowFile);
  assert.equal(after.toString('hex'), this.malformedRowBefore.toString('hex'), 'task file bytes changed');
  const stat = fs.statSync(this.malformedRowFile);
  assert.equal(stat.ino, this.malformedRowStat.ino, 'task file was replaced');
  assert.equal(stat.mtimeMs, this.malformedRowStat.mtimeMs, 'task file was rewritten');
});

Then(prefix + 'the listed tasks are exactly, in order:', function (table) {
  const expected = table.raw().map((row) => row[0]);
  const { output } = this.malformedRowResult;
  const actual = output.split('\n').filter((l) => /^\d+ \[/.test(l));
  assert.deepEqual(actual, expected, `listed task lines differ; output:\n${output}`);
});
