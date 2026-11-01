'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function observe(name, command, result) {
  const output = (result.stdout || '') + (result.stderr || '');
  const diagnostic = `${name}: ${command}; status=${result.status}; error=${result.error || 'none'}; absent, skipped or zero-run tests are not passes\n${output}`;
  assert.ok(!result.error && result.status === 0, diagnostic);
  const events = (result.stdout || '').split('\n').filter(Boolean).map(line => JSON.parse(line));
  const own = events.filter(event => event.Test === name);
  assert.equal(own.filter(event => event.Action === 'run').length, 1, diagnostic);
  assert.equal(own.filter(event => event.Action === 'pass').length, 1, diagnostic);
  assert.equal(own.filter(event => event.Action === 'skip' || event.Action === 'fail').length, 0, diagnostic);
}

if (require.main === module) {
  const name = 'TestNativeConformance';
  const actions = process.argv[2] === 'good' ? ['run', 'pass'] : ['run', 'skip'];
  try {
    observe(name, `go test -json ./build -run ^${name}$ -count=1`, {
      status: 0,
      stdout: actions.map(Action => JSON.stringify({ Test: name, Action })).join('\n'),
    });
    console.log('accepted');
  } catch (_) {
    console.log('rejected');
    process.exitCode = 1;
  }
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('repin adaptation runs {string} in {string}', { timeout: 110000 }, function (name, pkg) {
    assert.match(name, /^Test[A-Za-z0-9]+$/);
    assert.ok(['.', './agent', './build'].includes(pkg));
    this.repinName = name;
    this.repinCommand = `go test -json ${pkg} -run ^${name}$ -count=1`;
    this.repinResult = spawnSync('go', ['test', '-json', pkg, '-run', `^${name}$`, '-count=1'], {
      cwd: path.resolve(__dirname, '../../cli'), encoding: 'utf8', timeout: 100000,
      maxBuffer: 16 * 1024 * 1024,
    });
  });
  Then('repin adaptation observed {string} run and pass', function (name) {
    assert.equal(this.repinName, name, `${name}: ${this.repinCommand}; requested test differs`);
    observe(name, this.repinCommand, this.repinResult);
  });
}
