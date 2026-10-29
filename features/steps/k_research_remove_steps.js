const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');
const root = path.resolve(__dirname, '../..');

Then('the research removal path {string} is absent', function (file) {
  assert.equal(fs.existsSync(path.join(root, file)), false, `Removed research path still exists: ${file}`);
});

When('I run research removal test {string}', { timeout: 300000 }, function (name) {
  this.researchRemoval = spawnSync('go', ['test', '-count=1', '-v', '-run', `^${name}$`, '.'], {
    cwd: path.join(root, 'cli'), encoding: 'utf8', timeout: 290000,
  });
});

Then('research removal test {string} passes', function (name) {
  const r = this.researchRemoval;
  const message = `Required ${name}; command: cd cli && go test -count=1 -v -run ^${name}$ .; status=${r.status}; error=${r.error || ''}\n${r.stdout || ''}${r.stderr || ''}`;
  assert.ok(r.status === 0 && (r.stdout || '').includes(`--- PASS: ${name} (`), message);
});
