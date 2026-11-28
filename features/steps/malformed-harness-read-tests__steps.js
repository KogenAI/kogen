'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const slug = 'malformed-harness-read-tests';
const root = path.resolve(__dirname, '../..');
const cli = path.join(root, 'cli');
const pkg = './internal/claudecode';
const pkgDir = path.join(cli, pkg);
const testPath = 'cli/internal/claudecode/update_test.go';

// Temporary wrong implementations of readHarness, applied only in scratch overlays of update.go.
const readLine = 'b, err := os.ReadFile(filepath.Join(root, HarnessFile))';
const tail = 'return h\n}\n\n// writeFile replaces path';
const mutations = {
  missing: {
    'returning a non-empty record for a missing file': [
      readLine,
      readLine + '\n\tif err != nil {\n\t\treturn Harness{LastResult: "missing"}\n\t}',
    ],
    'creating the harness file when it is missing': [
      readLine,
      readLine + '\n\tif err != nil {\n\t\tos.WriteFile(filepath.Join(root, HarnessFile), []byte("{}\\n"), 0o600)\n\t}',
    ],
    'creating the harness folder when it is missing': [
      readLine,
      readLine + '\n\tif err != nil {\n\t\tos.MkdirAll(root, 0o755)\n\t}',
    ],
  },
  malformed: {
    'keeping every field decoded before the error': [
      'h = Harness{}',
      '_ = h',
    ],
    'keeping the failed versions decoded before the error': [
      'h = Harness{}',
      'h = Harness{Failed: h.Failed}',
    ],
    'keeping the checked time and result decoded before the error': [
      'h = Harness{}',
      'h = Harness{CheckedAt: h.CheckedAt, LastResult: h.LastResult}',
    ],
  },
  valid: {
    'discarding the checked time of a valid file': [
      tail,
      'h.CheckedAt = ""\n\t' + tail,
    ],
    'discarding the last result of a valid file': [
      tail,
      'h.LastResult = ""\n\t' + tail,
    ],
    'discarding the failed versions of a valid file': [
      tail,
      'h.Failed = nil\n\t' + tail,
    ],
  },
};

function runPackage({ testBody, mutation } = {}) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'claudecode-harness-'));
  try {
    const binary = path.join(tmp, 'claudecode.test');
    const args = ['test', '-trimpath', '-c', '-o', binary];
    const replacements = {};
    function overlay(file, target, body) {
      const scratch = path.join(tmp, file);
      fs.writeFileSync(scratch, body);
      replacements[path.join(pkgDir, target)] = scratch;
    }
    if (testBody !== undefined) overlay('t.go', 'update_test.go', testBody);
    if (mutation) {
      const [find, replace] = mutation;
      const source = fs.readFileSync(path.join(pkgDir, 'update.go'), 'utf8');
      assert.equal(source.split(find).length - 1, 1, `Expected update.go to contain ${JSON.stringify(find)} exactly once`);
      overlay('m.go', 'update.go', source.replace(find, () => replace));
    }
    if (Object.keys(replacements).length) {
      const overlayFile = path.join(tmp, 'overlay.json');
      fs.writeFileSync(overlayFile, JSON.stringify({ Replace: replacements }));
      args.push('-overlay', overlayFile);
    }
    args.push(pkg);
    const build = spawnSync('go', args, { cwd: cli, encoding: 'utf8', timeout: mutation ? 12000 : 85000 });
    if (build.error) throw build.error;
    assert.equal(build.status, 0, `Could not build ${pkg} tests:\n${build.stdout}${build.stderr}`);
    const run = spawnSync(binary, [], { cwd: pkgDir, encoding: 'utf8', timeout: 5000 });
    if (run.error) throw run.error;
    return { status: run.status, out: run.stdout + run.stderr };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

// Applies a unified diff of the test file to its correct body, as Kogen does for a wrong implementation.
function applyPatch(body, patch) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'claudecode-patch-'));
  try {
    fs.mkdirSync(path.join(tmp, path.dirname(testPath)), { recursive: true });
    fs.writeFileSync(path.join(tmp, testPath), body);
    fs.writeFileSync(path.join(tmp, 'wrong.patch'), patch);
    const applied = spawnSync('git', ['apply', 'wrong.patch'], { cwd: tmp, encoding: 'utf8' });
    assert.equal(applied.status, 0, `Could not apply the wrong implementation patch:\n${applied.stdout}${applied.stderr}`);
    return fs.readFileSync(path.join(tmp, testPath), 'utf8');
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

function passed({ status, out }) {
  return status === 0 && /^PASS$/m.test(out);
}

function requirePass(run) {
  assert.ok(passed(run), `Expected ${pkg} tests to pass under the real readHarness (exit ${run.status}):\n${run.out}`);
}

function survivors(category, testBody) {
  return Object.entries(mutations[category]).filter(([label, mutation]) => {
    const run = runPackage({ testBody, mutation });
    if (passed(run)) return true;
    assert.ok(run.status === 1 && /^FAIL$/m.test(run.out) && /^\s*--- FAIL: /m.test(run.out) &&
      /^\s+update_test\.go:\d+: /m.test(run.out) && !/^panic:/m.test(run.out),
    `Expected ${pkg} to reject ${label} by an assertion in update_test.go (exit ${run.status}):\n${run.out}`);
    return false;
  }).map(([label]) => label);
}

if (require.main === module) {
  const mode = process.argv[2];
  assert.ok(mode === 'good' || mode === 'bad', 'Expected observer control good or bad');
  const controls = require(path.join(root, '.kogen/intents', slug, 'controls.json'));
  for (const [i, category] of Object.keys(mutations).entries()) {
    const testBody = mode === 'good' ? controls.correct.files[testPath] : applyPatch(controls.correct.files[testPath], controls.wrong[i].files[testPath].patch);
    assert.equal(typeof testBody, 'string');
    requirePass(runPackage({ testBody }));
    const missed = survivors(category, testBody);
    assert.deepEqual(missed, mode === 'good' ? [] : Object.keys(mutations[category]), category);
  }
  console.log(mode === 'good' ? 'Harness read tests caught every mutation.' : 'Incomplete harness read tests let the corresponding mutations survive.');
  process.exitCode = mode === 'good' ? 0 : 1;
} else {
  const { Given, Then } = require('@cucumber/cucumber');
  let cleanPass = false;
  Given(`${slug}: the Claude Code package tests pass with the real readHarness`, { timeout: 95000 }, function () {
    if (!cleanPass) requirePass(runPackage());
    cleanPass = true;
  });
  for (const [category, sentence] of Object.entries({
    missing: 'the tests require a missing harness file to load as an empty Harness without creating anything',
    malformed: 'the tests require a malformed JSON harness to load as an empty Harness with no decoded field kept',
    valid: 'the tests require a valid harness file to keep its checked time, result and failed versions',
  })) {
    Then(`${slug}: ${sentence}`, { timeout: 110000 }, function () {
      const missed = survivors(category);
      assert.deepEqual(missed, [], `${pkg} tests passed despite ${missed.join(', ')}; add direct readHarness coverage in update_test.go`);
    });
  }
}
