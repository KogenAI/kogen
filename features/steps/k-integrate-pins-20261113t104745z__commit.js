'use strict';
const assert = require('assert');
const path = require('path');
const { spawnSync } = require('child_process');
const { When, Then } = require('@cucumber/cucumber');

When('k-integrate-pins-20261113t104745z: the spec scenario {string} is run', { timeout: 600000 }, function (target) {
  const root = process.cwd();
  const dir = path.join(root, 'test', 'acceptance');
  const rel = path.join('..', '..', target);
  this.pinsRun = spawnSync('npx', ['cucumber-js', '--strict', '--tags', 'not @live',
    '--require', 'steps/*.js', '--require', 'support/*.js', rel],
  { cwd: dir, encoding: 'utf8', timeout: 540000 });
});

Then('k-integrate-pins-20261113t104745z: it exits 0 with that scenario passed', function () {
  const r = this.pinsRun;
  const out = `${r.stdout || ''}${r.stderr || ''}`;
  assert.strictEqual(r.status, 0, `cucumber-js exited ${r.status}: ${out.slice(-3000)}`);
  assert.match(out, /1 scenario \(1 passed\)/, out.slice(-3000));
});
