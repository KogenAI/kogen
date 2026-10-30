const { Given, Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');

Given('the probe count regression case {string} represents count {string} with emptiness {string}', function (name, count, empty) {
  const cases = {
    'unpadded-zero': ['0', 'true'],
    'padded-zero': ['0', 'true'],
    'unpadded-one': ['1', 'false'],
    'padded-one': ['1', 'false'],
  };
  assert.deepEqual([count.trim(), empty], cases[name], `invalid probe count case ${name}`);
});

Then('the probe count Go test {string} passes', function (name) {
  assert.match(name, /^TestShapeProbe(?:MinimalEnvironmentWiring|HomeEmptinessRegression(?:\/(?:unpadded|padded)-(?:zero|one))?)$/);
  const pattern = name.split('/').map(part => `^${part}$`).join('/');
  const args = ['test', '-count=1', '-json', './shape', '-run', pattern];
  const result = spawnSync('go', args, { cwd: 'cli', encoding: 'utf8' });
  const output = (result.stdout || '') + (result.stderr || '');
  const diagnostic = `required test ${name}; command: cd cli && go ${args.join(' ')}; status=${result.status}; error=${result.error || ''}\n${output}`;
  assert.equal(result.status, 0, diagnostic);
  const events = (result.stdout || '').split('\n').filter(Boolean).map(line => JSON.parse(line));
  assert.ok(events.some(e => e.Test === name && e.Action === 'run'), `absent or zero executions: ${diagnostic}`);
  assert.ok(events.some(e => e.Test === name && e.Action === 'pass'), `absent, skipped or not passed: ${diagnostic}`);
});
