'use strict';
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const assert = require('node:assert/strict');
function accepts(code, events, name) {
  return code === 0 && events.some(e => e.Test === name && e.Action === 'run') && events.some(e => e.Test === name && e.Action === 'pass') && !events.some(e => e.Action === 'skip' || e.Action === 'fail');
}
if (require.main === module) {
  const name = 'TestControl';
  const events = [{ Test: name, Action: 'run' }, { Test: name, Action: 'pass' }];
  if (process.argv[2] === 'good') {
    assert.equal(accepts(0, events, name), true);
    console.log('accepted');
  } else {
    const bad = [ [0, [], name], [0, events.slice(0, 1), name], [1, events, name], [0, events.concat({Test: name + '/child', Action: 'skip'}), name], [0, events, 'Other'] ];
    for (const args of bad) assert.equal(accepts(...args), false);
    console.log('rejected');
    process.exitCode = 1;
  }
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('the submission retry integration test {string} runs', { timeout: 240000 }, function (name) {
    const r = spawnSync('go', ['test', '-json', '-count=1', '-run', '^' + name + '$', './shape'], { cwd: path.resolve(__dirname, '../../cli'), encoding: 'utf8', timeout: 230000, maxBuffer: 16 * 1024 * 1024 });
    assert.ifError(r.error);
    this.retryResult = { code: r.status, name, events: r.stdout.split('\n').filter(l => l.startsWith('{')).map(l => JSON.parse(l)), output: r.stdout + r.stderr };
  });
  Then('that submission retry test passed without skipping', function () {
    const r = this.retryResult;
    assert.ok(accepts(r.code, r.events, r.name), r.output);
  });
}
