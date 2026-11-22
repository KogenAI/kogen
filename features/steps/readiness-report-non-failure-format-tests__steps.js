'use strict';
// Acceptance steps of readiness-report-non-failure-format-tests. They observe the Go tests of
// cli/readiness: a mutated Text (injected with go test -overlay, so no file of the tree is
// edited) must make the package tests fail, and the unmutated package tests must pass.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Then } = require('@cucumber/cucumber');

const root = fs.realpathSync(path.resolve(__dirname, '../..'));
const source = path.join(root, 'cli', 'readiness', 'readiness.go');
const PREFIX = 'readiness-report-non-failure-format-tests: ';
const GATE = '\tif c.Status == "fail" {\n';
const BUILDER = '\tvar b strings.Builder\n';

function tail(text, n = 3000) {
  return text.length > n ? '[...]' + text.slice(-n) : text;
}

// runTests runs the readiness package tests, with `mutate` applied to readiness.go when given.
function runTests(mutate) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'readiness-format-'));
  try {
    const args = ['test', '-count=1', '-json'];
    if (mutate) {
      const original = fs.readFileSync(source, 'utf8');
      const mutated = mutate(original);
      assert.notEqual(mutated, original, 'the mutation changed nothing in cli/readiness/readiness.go');
      const file = path.join(dir, 'readiness.go');
      fs.writeFileSync(file, mutated);
      const overlay = path.join(dir, 'overlay.json');
      fs.writeFileSync(overlay, JSON.stringify({ Replace: { [source]: file } }));
      args.push('-overlay', overlay);
    }
    args.push('./readiness');
    const run = spawnSync('go', args, { cwd: path.join(root, 'cli'), encoding: 'utf8', timeout: 100000, maxBuffer: 64 * 1024 * 1024 });
    const events = [];
    for (const line of String(run.stdout || '').split('\n')) {
      if (!line.startsWith('{')) continue;
      try { events.push(JSON.parse(line)); } catch { /* not a test event */ }
    }
    const command = `go ${args.join(' ')}`;
    const describe = `${command}: exit ${run.status}${run.error ? `, ${run.error}` : ''}\n${tail(String(run.stdout || ''))}\n${tail(String(run.stderr || ''))}`;
    return { run, events, describe };
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function replaceOnce(text, from, to) {
  assert.equal(text.split(from).length - 1, 1, `cli/readiness/readiness.go no longer contains exactly one ${JSON.stringify(from)}`);
  return text.replace(from, () => to);
}

const failedTests = events => events.filter(e => e.Action === 'fail' && e.Test).map(e => e.Test);

function assertRejected(result, what) {
  assert.ok(result.run.status !== 0 && !result.run.error, `the readiness tests accepted ${what}: go test ./readiness did not fail\n${result.describe}`);
  assert.ok(failedTests(result.events).length > 0, `the readiness tests rejected ${what} without a failing test\n${result.describe}`);
}

Then(PREFIX + 'the readiness package tests pass and the existing TestText runs once and passes', function () {
  const r = runTests(null);
  assert.equal(r.run.status, 0, `the unchanged Text fails the readiness tests\n${r.describe}`);
  const own = r.events.filter(e => e.Test === 'TestText');
  const count = a => own.filter(e => e.Action === a).length;
  assert.equal(count('run'), 1, `TestText ran ${count('run')} times in go test ./readiness\n${r.describe}`);
  assert.equal(count('pass'), 1, `TestText did not pass in go test ./readiness\n${r.describe}`);
});

Then(PREFIX + 'the readiness tests reject a Text that prints a header for no checks', function () {
  const r = runTests(t => replaceOnce(t, BUILDER, BUILDER + '\tif len(checks) == 0 {\n\t\tb.WriteString("readiness\\n")\n\t}\n'));
  assertRejected(r, 'a Text that prints a header for no checks');
});

Then(PREFIX + 'the readiness tests reject a Text that prints a stray newline for no checks', function () {
  const r = runTests(t => replaceOnce(t, BUILDER, BUILDER + '\tif len(checks) == 0 {\n\t\tb.WriteString("\\n")\n\t}\n'));
  assertRejected(r, 'a Text that prints a stray newline for no checks');
});

Then(PREFIX + 'the readiness tests reject a Text that adds a fix line to every status other than ok', function () {
  const r = runTests(t => replaceOnce(t, GATE, '\tif c.Status != "ok" {\n'));
  assertRejected(r, 'a Text that adds a fix line to every status other than ok');
});

function assertTestTextFails(mutate, what) {
  const r = runTests(mutate);
  assertRejected(r, what);
  assert.ok(failedTests(r.events).includes('TestText'), `the existing TestText did not fail for ${what}; failing tests: ${failedTests(r.events).join(', ')}\n${r.describe}`);
}

Then(PREFIX + 'the existing TestText fails for a Text that adds a fix line to every status', function () {
  assertTestTextFails(t => replaceOnce(t, GATE, '\tif true {\n'), 'a Text that adds a fix line to every status');
});

Then(PREFIX + 'the existing TestText fails for a Text that never adds a fix line', function () {
  assertTestTextFails(t => replaceOnce(t, GATE, '\tif false {\n'), 'a Text that never adds a fix line');
});
