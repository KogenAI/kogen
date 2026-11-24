'use strict';
const assert = require('node:assert/strict');

function exact(actual, expected) {
  assert.deepEqual(actual, expected, 'readiness config report differs');
}

function directory(actual, configPath) {
  const c = actual.Check;
  assert.equal(c.Check, 'config');
  assert.equal(c.Status, 'fail');
  assert.ok(c.Detail.includes(configPath), 'diagnostic must identify the config path');
  assert.doesNotMatch(c.Detail, /missing/i, 'an existing directory is not missing');
  assert.match(c.Detail, /directory/i, 'diagnostic must identify the directory cause');
  assert.match(c.Detail, /read|open/i, 'diagnostic must identify a config read failure');
  assert.ok(c.Fix.includes(configPath), 'fix must identify the config path');
  assert.match(c.Fix, /file/i, 'fix must explain restoring a config file');
  assert.match(c.Fix, /readable|regular|replace|directory/i, 'fix must address readability or the non-file path');
  assert.doesNotMatch(c.Fix, /kogen init/i, 'init is not the remedy for an existing unreadable path');
  assert.equal(actual.Text, `fail config - ${c.Detail}\n  fix: ${c.Fix}\n`);
}

module.exports = { exact, directory };

if (require.main === module) {
  const fixtures = JSON.parse(require('node:fs').readFileSync(process.argv[2], 'utf8'))[process.argv[3]];
  assert.ok(fixtures.length > 0, 'observer controls require fixtures');
  let rejected = 0;
  for (const fixture of fixtures) {
    try {
      if (fixture.kind === 'directory') directory(fixture.actual, fixture.expected);
      else exact(fixture.actual, fixture.expected);
    } catch (err) {
      if (!(err instanceof assert.AssertionError)) throw err;
      rejected++;
    }
  }
  if (rejected === 0) { console.log('accepted'); }
  else if (rejected === fixtures.length) { console.log('rejected'); process.exitCode = 1; }
  else { console.log('mixed results'); process.exitCode = 2; }
}
