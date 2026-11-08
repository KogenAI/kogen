const { Then, setDefaultTimeout } = require('@cucumber/cucumber');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const assert = require('node:assert/strict');

setDefaultTimeout(60000);
Then('k-integrate-pins-20261108t025831z: the consumed executor contract package passes', function () {
  const result = spawnSync('go', ['test', '-count=1', './consumes/kogen-executor'], {
    cwd: path.resolve('cli'), encoding: 'utf8', timeout: 55000,
    env: { ...process.env, GOFLAGS: '-trimpath' }
  });
  assert.equal(result.status, 0, `go test -count=1 ./consumes/kogen-executor: ${result.error || result.signal || result.status}\n${result.stdout || ''}${result.stderr || ''}`);
});
