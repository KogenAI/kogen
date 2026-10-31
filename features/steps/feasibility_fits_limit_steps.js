'use strict';
const { Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');

Then('focused Shape budget regression {string} passes', { timeout: 110000 }, function (name) {
  const args = ['test', '-json', '-count=1', '-run', '^' + name + '$', './shape'];
  const r = spawnSync('go', args, { cwd: path.resolve(__dirname, '../../cli'), encoding: 'utf8', timeout: 105000, maxBuffer: 8 * 1024 * 1024 });
  const diagnostic = `${name}: go ${args.join(' ')}; exit=${r.status} signal=${r.signal} error=${r.error || 'none'}\n${r.stdout || ''}\n${r.stderr || ''}`;
  const events = (r.stdout || '').split('\n').filter(line => line.startsWith('{')).map(line => JSON.parse(line));
  assert.ok(events.some(e => e.Test === name && e.Action === 'run'), 'Required test absent or ran zero times: ' + diagnostic);
  assert.ok(events.some(e => e.Test === name && e.Action === 'pass') && !events.some(e => e.Test === name && (e.Action === 'skip' || e.Action === 'fail')), 'Required test failed or skipped: ' + diagnostic);
  assert.equal(r.status, 0, diagnostic);
});
