'use strict';
const assert = require('node:assert/strict');
function check(report, count, allowed = []) {
  assert.equal(report.length, count, 'scenario inventory changed');
  const permitted = new Set(allowed);
  for (const row of report) {
    assert.ok(row.status === 'passed' || (row.status === 'failed' && permitted.has(row.key)), `unexpected scenario result: ${row.key}: ${row.status}`);
  }
  assert.equal(new Set(report.map(r => r.key)).size, count, 'duplicate scenario results');
}
module.exports = { check };
if (require.main === module) {
  const good = [{ key: 'a', status: 'passed' }, { key: 'b', status: 'failed' }];
  if (process.argv[2] === 'good') {
    check(good, 2, ['b']);
    console.log('accepted good report');
  } else if (process.argv[2] === 'bad') {
    const cases = [
      ['inventory', [good[0]]],
      ['regression', [{ key: 'a', status: 'failed' }, good[1]]],
      ['skipped', [{ key: 'a', status: 'skipped' }, good[1]]],
      ['duplicate', [good[0], good[0]]],
    ];
    for (const [label, rows] of cases) {
      let rejected = false;
      try { check(rows, 2, ['b']); } catch { rejected = true; }
      assert.ok(rejected, `bad ${label} report was accepted`);
      console.log(`rejected ${label} report`);
    }
    process.exitCode = 1;
  } else {
    throw new Error('expected good or bad control');
  }
}
