const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { After, Before, Given, When, Then } = require('@cucumber/cucumber');

const projectRoot = path.resolve(__dirname, '../..');

Before(function () {
  this.scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'tiny-tasks-cucumber-'));
  this.tasksFile = path.join(this.scratch, 'tasks.tsv');
  this.output = '';
});

After(function () {
  fs.rmSync(this.scratch, { recursive: true, force: true });
});

Given('an empty task list', function () {
  assert.equal(fs.existsSync(this.tasksFile), false);
});

When('I add a task {string}', function (title) {
  runMix(this, ['todo.add', title]);
});

When('I complete task {int}', function (id) {
  runMix(this, ['todo.complete', String(id)]);
});

When('I list all tasks', function () {
  runMix(this, ['todo.list']);
});

When('I list open tasks', function () {
  runMix(this, ['todo.list', '--open']);
});

Then('the output includes {string}', function (expected) {
  if (!this.output.includes(expected)) {
    throw new Error(`expected output to include "${expected}"`);
  }
});

// The task lines of the output (`<id> [<status>] <title>`), in order and exactly these.
Then('the tasks shown are:', function (expected) {
  const shown = this.output.split('\n').filter(line => /^\d+ \[/.test(line));
  const wanted = expected.split('\n').map(line => line.trim()).filter(Boolean);
  if (shown.join('\n') !== wanted.join('\n')) {
    throw new Error(`expected exactly these tasks, in order:\n${wanted.join('\n')}\ngot:\n${shown.join('\n')}`);
  }
});

Then('the output does not include {string}', function (unexpected) {
  if (this.output.includes(unexpected)) {
    throw new Error(`expected output not to include "${unexpected}"`);
  }
});

function runMix(world, args) {
  world.output = execFileSync('mix', args, {
    cwd: projectRoot,
    encoding: 'utf8',
    env: { ...process.env, TODO_FILE: world.tasksFile }
  });
}
