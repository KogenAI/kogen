'use strict';
const assert = require('node:assert/strict');

function observe(report, paths, expected) {
  const c = report.Check;
  assert.equal(c.Check, 'install');
  const failures = Object.entries(expected).filter(([, status]) => status !== 0);
  assert.equal(c.Status, failures.length ? 'fail' : 'ok', 'install status must reflect command outcomes');
  assert.equal(c.Fix, failures.length ? 'reinstall Kogen' : '');
  assert.equal(report.Text, `${c.Status} install - ${c.Detail}\n` + (failures.length ? `  fix: ${c.Fix}\n` : ''));
  assert.ok(!report.Text.includes('PRIVATE_SUBPROCESS_OUTPUT'), 'do not report arbitrary subprocess output');
  if (!failures.length) {
    assert.equal(c.Detail, 'fixture; node, cucumber and quint run');
    return;
  }
  const clauses = c.Detail.split(/[;\n]/).filter(x => x.trim());
  assert.equal(clauses.length, failures.length, 'one install report must contain all failures and no successful commands');
  for (const [tool, status] of Object.entries(expected)) {
    const matches = clauses.filter(x => new RegExp(`\\b${tool}\\b`, 'i').test(x));
    assert.equal(matches.length, status ? 1 : 0, `${tool}: report only failing commands, independently`);
    if (status) {
      assert.ok(matches[0].includes(paths[tool]), `${tool}: include configured path ${paths[tool]}`);
      assert.match(matches[0], new RegExp(`\\b${status}\\b`), `${tool}: include exit status ${status}`);
    }
  }
}
module.exports = observe;

if (require.main === module) {
  const fixtures = JSON.parse(require('node:fs').readFileSync(process.argv[2], 'utf8'))[process.argv[3]];
  assert.ok(fixtures.length > 0);
  let rejected = 0;
  for (const fixture of fixtures) {
    try { observe(fixture.report, fixture.paths, fixture.expected); }
    catch (err) {
      if (!(err instanceof assert.AssertionError)) throw err;
      rejected++;
    }
  }
  if (!rejected) console.log('accepted');
  else if (rejected === fixtures.length) { console.log('rejected'); process.exitCode = 1; }
  else { console.log('mixed results'); process.exitCode = 2; }
}
