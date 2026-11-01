'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, When, Then } = require('@cucumber/cucumber');
const name = 'TestExamplesRevertShapeApproval';
const command = 'go test -json ./shape -run ^TestExamplesRevertShapeApproval$ -count=1';
Given('the removed check compared these format-only values:', function (table) {
  assert.deepEqual(table.hashes(), [{ expected: '"status":0,"out":"61610a0a"', derived: '{"status":0,"out":"61610a0a"}' }]);
});
When('I run the focused example-removal Shape and approval regression', { timeout: 115000 }, function () {
  this.examplesRevert = spawnSync('go', ['test', '-json', './shape', '-run', `^${name}$`, '-count=1'], {
    cwd: path.resolve(__dirname, '../../cli'), encoding: 'utf8', timeout: 110000
  });
});
Then('the example-removal regression ran once and passed', function () {
  const r = this.examplesRevert;
  const output = `${r.stdout || ''}${r.stderr || ''}`;
  const message = `${name}: ${command}; status=${r.status}; error=${r.error || 'none'}\n${output}`;
  assert.equal(r.status, 0, message);
  const events = (r.stdout || '').split('\n').filter(Boolean).flatMap(line => {
    try { return [JSON.parse(line)]; } catch { return []; }
  }).filter(e => e.Test === name);
  assert.equal(events.filter(e => e.Action === 'run').length, 1, `${message}\nrequired test absent or ran zero/multiple times`);
  assert.equal(events.filter(e => e.Action === 'pass').length, 1, `${message}\nrequired test did not pass (absent, skipped or failed)`);
  assert.equal(events.filter(e => e.Action === 'skip' || e.Action === 'fail').length, 0, `${message}\nrequired test skipped or failed`);
});
