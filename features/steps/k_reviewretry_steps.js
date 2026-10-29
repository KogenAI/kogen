'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const names = ['TestKReviewRetryFreshConversation', 'TestKReviewRetryReviewOnlyResume', 'TestKReviewRetryChangedCheckout', 'TestKReviewRetrySeparateAllowances', 'TestKReviewRetryReminderChoice', 'TestKReviewRetryUnchangedValidRequests', 'TestKReviewRetrySafetyBoundaries'];
function observe(result, name) {
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  const rows = result.stdout.split('\n').filter(Boolean).map(line => JSON.parse(line));
  const testRows = rows.filter(row => row.Test === name);
  assert.equal(testRows.filter(row => row.Action === 'run').length, 1, 'required test must run exactly once');
  assert.equal(testRows.filter(row => row.Action === 'pass').length, 1, 'required test must pass exactly once');
  assert.ok(!rows.some(row => row.Action === 'fail' || (row.Test === name && row.Action === 'skip')), 'failure or skipped required test');
}
function control(kind) {
  const name = names[0];
  const fixture = rows => ({ status: 0, stdout: rows.map(row => JSON.stringify(row)).join('\n'), stderr: '' });
  const good = [{ Test: name, Action: 'run' }, { Test: name, Action: 'pass' }];
  observe(fixture(good), name);
  if (kind === 'good') { console.log('reviewretry observer good'); return; }
  assert.equal(kind, 'bad');
  for (const rows of [[], [{Action:'pass'}], [{Test:name,Action:'run'},{Test:name,Action:'skip'}], good.concat({Action:'fail'}), good.concat(good)]) {
    assert.throws(() => observe(fixture(rows), name));
  }
  assert.throws(() => observe({status:1,stdout:fixture(good).stdout,stderr:''}, name));
  console.log('reviewretry observer rejected bad fixtures');
  process.exitCode = 1;
}
if (require.main === module && process.argv[2] === '--control') {
  control(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('the reviewretry contract test {string} runs', { timeout: 290000 }, function (name) {
    assert.ok(names.includes(name), 'unknown contract test');
    this.reviewretryName = name;
    this.reviewretryResult = spawnSync('go', ['test', '-json', './...', '-run', '^' + name + '$', '-count=1'], {
      cwd: path.resolve(__dirname, '../../cli'), encoding: 'utf8', timeout: 280000, maxBuffer: 32 * 1024 * 1024,
    });
  });
  Then('that reviewretry contract test executes once and passes', function () {
    observe(this.reviewretryResult, this.reviewretryName);
  });
}
