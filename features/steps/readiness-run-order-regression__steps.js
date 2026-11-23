'use strict';
// Acceptance steps of readiness-run-order-regression. They observe the Go tests of cli/readiness:
// a mutated Run (injected with go test -overlay, so no file of the tree is edited) must make
// the package tests fail, and the unmutated package tests must pass.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Then } = require('@cucumber/cucumber');

const root = fs.realpathSync(path.resolve(__dirname, '../..'));
const source = path.join(root, 'cli', 'readiness', 'readiness.go');
const PREFIX = 'readiness-run-order-regression: ';
const RETURN = '\treturn append(checks, gitCheck, checkConfig(root), checkModels(root, in))\n';
const REPO_ROOT = '\t\troot = repo.Dir\n';
const PROJECT_ROOT = '\troot := in.Project\n';

function tail(text, n = 3000) {
  return text.length > n ? '[...]' + text.slice(-n) : text;
}

// runTests runs the readiness package tests, with `mutate` applied to readiness.go when given.
function runTests(mutate) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'readiness-run-'));
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

Then(PREFIX + 'the readiness package tests pass', function () {
  const r = runTests(null);
  assert.equal(r.run.status, 0, `the unchanged Run fails the readiness tests\n${r.describe}`);
});

Then(PREFIX + 'the readiness tests reject a Run that returns the checks out of order', function () {
  const r = runTests(t => replaceOnce(t, RETURN, '\treturn append([]Check{gitCheck, checkConfig(root), checkModels(root, in)}, checks...)\n'));
  assertRejected(r, 'a Run that returns install last');
  const r2 = runTests(t => replaceOnce(t, RETURN, '\treturn append(checks, checkConfig(root), gitCheck, checkModels(root, in))\n'));
  assertRejected(r2, 'a Run that returns config before git');
});

Then(PREFIX + 'the readiness tests reject a Run that checks the nested working directory instead of the repository root', function () {
  const r = runTests(t => replaceOnce(t, REPO_ROOT, '\t\troot = in.Project\n'));
  assertRejected(r, 'a Run that checks the nested working directory');
});

Then(PREFIX + 'the readiness tests reject a Run that returns early after the Git failure', function () {
  const r = runTests(t => replaceOnce(t, RETURN, '\tif repo == nil {\n\t\treturn append(checks, gitCheck)\n\t}\n' + RETURN));
  assertRejected(r, 'a Run that returns early after the Git failure');
});

Then(PREFIX + 'the readiness tests reject a Run that checks the parent of a project outside Git', function () {
  const r = runTests(t => replaceOnce(t, PROJECT_ROOT, '\troot := filepath.Dir(in.Project)\n'));
  assertRejected(r, 'a Run that checks the parent directory of a project outside Git');
});
