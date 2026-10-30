const { Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');

Then('the failing-check fixture test {string} passes', function (name) {
  assert.match(name, /^TestFailingCheckBuild(?:Repair|Evidence|Unrelated|Regression)$/);
  const args = ['test', '-count=1', '-json', './build', '-run', `^${name}$`];
  const r = spawnSync('go', args, { cwd: 'cli', encoding: 'utf8' });
  const diagnostic = `required test ${name}; command: cd cli && go ${args.join(' ')}; status=${r.status}; error=${r.error || ''}\n${r.stdout || ''}${r.stderr || ''}`;
  assert.equal(r.status, 0, diagnostic);
  const events = (r.stdout || '').split('\n').filter(Boolean).map(line => JSON.parse(line));
  assert.ok(events.some(e => e.Test === name && e.Action === 'run'), `absent or zero executions: ${diagnostic}`);
  assert.ok(events.some(e => e.Test === name && e.Action === 'pass'), `absent, skipped or not passed: ${diagnostic}`);
});
