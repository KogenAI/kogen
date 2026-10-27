'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Then } = require('@cucumber/cucumber');
const ROOT = path.resolve(__dirname, '../..');

// Runs one named Go test of cli/build and requires an explicit pass event for it: a package
// that merely reports ok with no matching test is not a pass.
Then('the k18 Go test {string} runs and passes', { timeout: 250000 }, function (name) {
  const r = spawnSync('go', ['test', '-json', '-run', '^' + name + '$', '-count=1', './build'], {
    cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 240000, maxBuffer: 16 * 1024 * 1024,
  });
  assert.ifError(r.error);
  const text = r.stdout + r.stderr;
  const events = r.stdout.split('\n').filter(l => l.startsWith('{')).map(l => JSON.parse(l));
  assert.equal(r.status, 0, text);
  assert.ok(events.some(e => e.Action === 'pass' && e.Test === name), `test ${name} did not run and pass:\n${text}`);
});

Then('the k18 vendored loop and its pin are unchanged', function () {
  const r = spawnSync('git', ['status', '--porcelain', '--', 'cli/third_party', 'cli/loop-pin.json'], { cwd: ROOT, encoding: 'utf8' });
  assert.ifError(r.error);
  assert.equal(r.stdout, '', `vendored loop or pin edited:\n${r.stdout}`);
});

function goSources(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) goSources(p, out);
    else if (e.name.endsWith('.go') && !e.name.endsWith('_test.go')) out.push(p);
  }
  return out;
}

Then('no non-test Go source sends the drop_block binding option or its beta header', function () {
  const bad = goSources(path.join(ROOT, 'cli'), []).filter(f => {
    const s = fs.readFileSync(f, 'utf8');
    return s.includes('drop_block') || s.includes('thinking-binding-controls') || s.includes('prefix_mismatch_behavior');
  });
  assert.deepEqual(bad, [], 'beta binding option used in: ' + bad.join(', '));
});
