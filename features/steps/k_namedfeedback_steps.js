'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Then } = require('@cucumber/cucumber');

Then('the namedfeedback regression {string} runs exactly once and passes in {string}', { timeout: 300000 }, function (name, pkg) {
  const r = spawnSync('go', ['test', '-json', '-count=1', pkg, '-run', `^${name}$`], {
    cwd: path.resolve(__dirname, '../../cli'), encoding: 'utf8', timeout: 280000,
    maxBuffer: 8 * 1024 * 1024,
    env: { ...process.env, GOWORK: 'off' },
  });
  const rows = (r.stdout || '').split('\n').filter(s => s.startsWith('{')).map(s => JSON.parse(s));
  const runs = rows.filter(x => x.Test === name && x.Action === 'run');
  const ends = rows.filter(x => x.Test === name && ['pass', 'fail', 'skip'].includes(x.Action));
  assert.ok(!r.error && r.status === 0 && runs.length === 1 && ends.length === 1 && ends[0].Action === 'pass',
    `required test ${name} must run exactly once and pass in go test ${pkg}; acceptance helper ${__filename}\n${r.error || ''}\n${r.stdout || ''}${r.stderr || ''}`);
});
