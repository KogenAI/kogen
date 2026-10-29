'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
function observe(name, result) {
  const command = `go test -json ./build -run ^${name}$ -count=1`;
  const output = (result.stdout || '') + (result.stderr || '');
  const diagnostic = `${name}: ${command}; status=${result.status}; error=${result.error || 'none'}; absent, skipped or zero-run tests are not passes\n${output}`;
  assert.ok(!result.error && result.status === 0, diagnostic);
  const events = (result.stdout || '').split('\n').filter(Boolean).map(line => JSON.parse(line));
  const own = events.filter(e => e.Test === name);
  assert.equal(own.filter(e => e.Action === 'run').length, 1, diagnostic);
  assert.equal(own.filter(e => e.Action === 'pass').length, 1, diagnostic);
  assert.equal(own.filter(e => e.Action === 'skip' || e.Action === 'fail').length, 0, diagnostic);
}
if (require.main === module) {
  const name = 'TestKRevodGateHunkApproval';
  const actions = process.argv[2] === 'good' ? ['run', 'pass'] : ['run', 'skip'];
  try {
    observe(name, { status: 0, stdout: actions.map(Action => JSON.stringify({ Test: name, Action })).join('\n') });
    console.log('observer accepted');
  } catch (_) {
    console.log('observer rejected');
    process.exitCode = 1;
  }
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('the revod gate test {string} runs', { timeout: 290000 }, function (name) {
    assert.ok(/^TestKRevodGate(HunkCoverage|InvalidBlocker|HunkApproval|MissingRead|PartsUnchanged)$/.test(name), `Unknown required test ${name}`);
    this.revodGateName = name;
    this.revodGateResult = spawnSync('go', ['test', '-json', './build', '-run', `^${name}$`, '-count=1'], {
      cwd: path.resolve(__dirname, '../../cli'), encoding: 'utf8', timeout: 280000, maxBuffer: 16 * 1024 * 1024,
    });
  });
  Then('that revod gate test ran and passed', function () {
    observe(this.revodGateName, this.revodGateResult);
  });
}
