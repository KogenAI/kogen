const { Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');

Then('dist isolation Go test {string} passes in package {string}', { timeout: 120000 }, function (name, pkg) {
  const args = ['test', '-count=1', '-json', pkg, '-run', `^${name}$`];
  const result = spawnSync('go', args, { cwd: 'cli', encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  const diagnostic = `required test ${name}; command: cd cli && go ${args.join(' ')}; status=${result.status}; error=${result.error || ''}\n${result.stdout || ''}${result.stderr || ''}`;
  assert.equal(result.status, 0, diagnostic);
  const events = (result.stdout || '').split('\n').filter(line => line.startsWith('{')).map(line => JSON.parse(line));
  assert.ok(events.some(e => e.Test === name && e.Action === 'run'), `required test absent or ran zero times: ${diagnostic}`);
  assert.ok(events.some(e => e.Test === name && e.Action === 'pass'), `required test skipped or did not pass: ${diagnostic}`);
});
