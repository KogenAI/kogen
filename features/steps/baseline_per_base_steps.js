const { Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');

Then('baseline per-base test {string} passes proving:', { timeout: 120000 }, function (name, contract) {
  assert.match(name, /^TestBaselinePerBase(?:Installed|Identity|Custody|Failures|Eligibility)$/);
  assert.ok(contract.trim().length > 0, `required test ${name}: missing contract`);
  const args = ['test', '-count=1', '-json', './build', '-run', `^${name}$`];
  const r = spawnSync('go', args, { cwd: 'cli', encoding: 'utf8', timeout: 110000, maxBuffer: 16 * 1024 * 1024 });
  const diagnostic = `required test ${name}; command: cd cli && go ${args.join(' ')}; status=${r.status}; error=${r.error || ''}\n${r.stdout || ''}${r.stderr || ''}\nRequired behavior:\n${contract}`;
  assert.equal(r.status, 0, diagnostic);
  const events = (r.stdout || '').split('\n').filter(Boolean).map(line => JSON.parse(line));
  assert.ok(events.some(e => e.Test === name && e.Action === 'run'), `absent or zero executions: ${diagnostic}`);
  assert.ok(events.some(e => e.Test === name && e.Action === 'pass'), `absent, skipped or not passed: ${diagnostic}`);
});
