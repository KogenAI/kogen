'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Then } = require('@cucumber/cucumber');
const ROOT = path.resolve(__dirname, '../..');

// Runs one named Go test of cli/build and requires an explicit pass event for it: a package
// that merely reports ok with no matching test is not a pass.
function runGo(name) {
  const r = spawnSync('go', ['test', '-json', '-run', '^' + name + '$', '-count=1', './build'], {
    cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 240000, maxBuffer: 16 * 1024 * 1024,
  });
  assert.ifError(r.error);
  const events = r.stdout.split('\n').filter(l => l.startsWith('{')).map(l => JSON.parse(l));
  return { status: r.status, events, text: r.stdout + r.stderr };
}

Then('the k15 Go test {string} runs and passes', { timeout: 250000 }, function (name) {
  const res = runGo(name);
  assert.equal(res.status, 0, res.text);
  assert.ok(res.events.some(e => e.Action === 'pass' && e.Test === name), `test ${name} did not run and pass:\n${res.text}`);
});

Then('the k15 loop change note {string} contains {string}', function (file, text) {
  const full = path.join(ROOT, file);
  assert.ok(fs.existsSync(full), `${file} is missing`);
  assert.ok(fs.readFileSync(full, 'utf8').includes(text), `${file} lacks: ${text}`);
});

Then('the k15 vendored loop and its pin are unchanged', function () {
  const r = spawnSync('git', ['status', '--porcelain', '--', 'cli/third_party', 'cli/loop-pin.json'], { cwd: ROOT, encoding: 'utf8' });
  assert.ifError(r.error);
  assert.equal(r.stdout, '', `vendored loop or pin edited:\n${r.stdout}`);
});
