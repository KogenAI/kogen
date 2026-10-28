'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');
When('the krevodb regression {string} runs', { timeout: 290000 }, function (name) {
  assert.ok(['TestKRevodBOnDemandReset', 'TestKRevodBPartsReset'].includes(name));
  this.krevodbName = name;
  this.krevodbResult = spawnSync('go', ['test', './build', '-run', '^' + name + '$', '-count=1', '-v'], {
    cwd: path.resolve(__dirname, '../../cli'), encoding: 'utf8', timeout: 280000,
    maxBuffer: 8 * 1024 * 1024,
  });
});
Then('the krevodb regression passes with reset sentence {string}', function (sentence) {
  const r = this.krevodbResult;
  assert.ifError(r.error);
  const output = (r.stdout || '') + (r.stderr || '');
  assert.equal(r.status, 0, output);
  assert.ok(output.includes('--- PASS: ' + this.krevodbName + ' '), 'Required regression did not execute and pass: ' + output);
  assert.ok(output.includes(sentence), 'Regression must log the observed post-reset handoff note: ' + output);
});
