'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Then } = require('@cucumber/cucumber');
const ROOT = path.resolve(__dirname, '../..');

// Runs one named Go test of one cli package and requires an explicit pass event for it: a package
// that merely reports ok with no matching test is not a pass.
Then('the k18b Go test {string} in package {string} runs and passes', { timeout: 250000 }, function (name, pkg) {
  const r = spawnSync('go', ['test', '-json', '-run', '^' + name + '$', '-count=1', pkg], {
    cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 240000, maxBuffer: 16 * 1024 * 1024,
  });
  assert.ifError(r.error);
  const text = r.stdout + r.stderr;
  const events = r.stdout.split('\n').filter(l => l.startsWith('{')).map(l => JSON.parse(l));
  assert.equal(r.status, 0, text);
  assert.ok(events.some(e => e.Action === 'pass' && e.Test === name), `test ${name} did not run and pass:\n${text}`);
});

function goSources(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (p === path.join(ROOT, 'cli', 'third_party')) continue;
      goSources(p, out);
    } else if (e.name.endsWith('.go') && !e.name.endsWith('_test.go')) out.push(p);
  }
  return out;
}

Then('exactly one non-test Go package under cli outside third_party strips thinking blocks and build and shape both use it', function () {
  const files = goSources(path.join(ROOT, 'cli'), []);
  const holders = files.filter(f => fs.readFileSync(f, 'utf8').includes('redacted_thinking'));
  assert.equal(new Set(holders.map(f => path.dirname(f))).size, 1, 'redacted_thinking handled in: ' + holders.join(', '));
  const dir = path.dirname(holders[0]);
  assert.notEqual(dir, path.join(ROOT, 'cli', 'build'), 'the stripper is still private to build');
  assert.notEqual(dir, path.join(ROOT, 'cli', 'shape'), 'the stripper is private to shape');
  const imp = '"kogen/' + path.basename(dir) + '"';
  for (const pkg of ['build', 'shape']) {
    const users = files.filter(f => path.dirname(f) === path.join(ROOT, 'cli', pkg) && fs.readFileSync(f, 'utf8').includes(imp));
    assert.ok(users.length > 0, `${pkg} does not import ${imp}`);
  }
});

Then('the k18b vendored loop and its pin are unchanged', function () {
  const r = spawnSync('git', ['status', '--porcelain', '--', 'cli/third_party', 'cli/loop-pin.json'], { cwd: ROOT, encoding: 'utf8' });
  assert.ifError(r.error);
  assert.equal(r.stdout, '', `vendored loop or pin edited:\n${r.stdout}`);
});
