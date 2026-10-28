'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');
When('the Build budget contract test {string} runs', { timeout: 250000 }, function (name) {
  assert.match(name, /^TestBuildRequestBudget(AcrossPasses|Resume|Off|Review)$/);
  this.budgetTestName = name;
  this.budgetTestResult = spawnSync('go', ['test', './build', '-count=1', '-json', '-run', '^' + name + '$'], {
    cwd: path.resolve(__dirname, '../../cli'), encoding: 'utf8', timeout: 240000, maxBuffer: 8388608
  });
});
Then('the Build budget contract test passes with a recorded execution', function () {
  const r = this.budgetTestResult;
  assert.ifError(r.error);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  const records = r.stdout.split('\n').filter(line => line.startsWith('{')).map(line => JSON.parse(line));
  assert.ok(records.some(e => e.Action === 'run' && e.Test === this.budgetTestName), 'required behavioral test did not execute: ' + this.budgetTestName);
  assert.ok(records.some(e => e.Action === 'pass' && e.Test === this.budgetTestName), 'required behavioral test did not pass');
});
