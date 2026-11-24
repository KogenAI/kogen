'use strict';
const assert = require('node:assert/strict');

function observe(actual, expected) {
  assert.equal(actual.AuthProbed, true, 'fixture auth status response was not consumed');
  const c = actual.Check;
  assert.equal(c.Check, 'models');
  assert.equal(c.Status, expected.status, 'models readiness status');
  assert.equal(actual.Text, `${c.Status} models - ${c.Detail}\n${c.Status === 'fail' ? `  fix: ${c.Fix}\n` : ''}`, 'rendered report must carry the diagnosis');
  if (expected.message !== undefined) assert.equal(c.Detail, expected.message);
  if (expected.fix !== undefined) assert.equal(c.Fix, expected.fix);
  if (expected.diagnosis === 'unavailable' || expected.diagnosis === 'invalid or unavailable') {
    assert.match(c.Detail, /auth.*status|status.*auth/i, 'diagnosis must identify auth status');
    assert.match(c.Detail, expected.diagnosis === 'unavailable' ? /could not|cannot|unable|unavailable|failed|error/i : /invalid|malformed|could not|cannot|unable|unavailable|failed|error/i, 'diagnosis must explain unavailable or invalid status');
    assert.doesNotMatch(c.Detail, /no stored token and no claude\.ai subscription sign-in|logged[ -]out|not signed in/i, 'an uncertain status must not claim logged out');
  }
  if (expected.status === 'ok') {
    assert.equal(c.Detail, expected.message);
    assert.equal(c.Fix, '');
  }
}
module.exports = observe;

if (require.main === module) {
  const fixtures = JSON.parse(require('node:fs').readFileSync(process.argv[2], 'utf8'))[process.argv[3]];
  assert.ok(fixtures.length > 0);
  let rejected = 0;
  for (const fixture of fixtures) {
    try { observe(fixture.actual, fixture.expected); }
    catch (e) { if (!(e instanceof assert.AssertionError)) throw e; rejected++; }
  }
  if (rejected === 0) console.log('accepted');
  else if (rejected === fixtures.length) { console.log('rejected'); process.exitCode = 1; }
  else { console.log('mixed results'); process.exitCode = 2; }
}
