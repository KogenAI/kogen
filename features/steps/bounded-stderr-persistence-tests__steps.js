'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const slug = 'bounded-stderr-persistence-tests';
const root = path.resolve(__dirname, '../..');
const cli = path.join(root, 'cli');
const pkg = './internal/claudecode';
const pkgDir = path.join(cli, pkg);
const testPath = 'cli/internal/claudecode/persistence_test.go';

// Temporary wrong implementations of stderrPersistence.Write, applied only in scratch overlays of persistence.go.
const mutations = {
  cap: {
    'rejecting a write that crosses the cap': [
      'n > 0 {',
      'n > 0 && int64(len(b)) <= p.cap-p.kept {',
    ],
    'returning only the retained count when a write crosses the cap': [
      'return len(b), nil',
      'if written > 0 && written < len(b) && p.kept == p.cap {\n\t\treturn written, nil\n\t}\n\treturn len(b), nil',
    ],
    'undercounting the overflow when a write crosses the cap': [
      'p.lost += int64(len(b) - written)',
      'p.lost += int64(len(b) - written)\n\tif written > 0 && written < len(b) && p.kept == p.cap {\n\t\tp.lost--\n\t}',
    ],
  },
  short: {
    'counting a short write as fully written': [
      'written, _ = p.w.Write(b[:n])',
      'written, _ = p.w.Write(b[:n])\n\t\twritten = n',
    ],
    'returning the short count': [
      'written, _ = p.w.Write(b[:n])',
      'written, _ = p.w.Write(b[:n])\n\t\tif written < n {\n\t\t\tp.kept += int64(written)\n\t\t\tp.lost += int64(len(b) - written)\n\t\t\treturn written, nil\n\t\t}',
    ],
    'counting the requested bytes as kept after a short write': [
      'p.kept += int64(written)',
      'p.kept += int64(n)',
    ],
  },
  exhausted: {
    'not counting writes after the cap is exhausted': [
      'p.lost += int64(len(b) - written)',
      'if !(written == 0 && p.kept >= p.cap) {\n\t\tp.lost += int64(len(b) - written)\n\t}',
    ],
    'counting one byte of each write after the cap is exhausted': [
      'p.lost += int64(len(b) - written)',
      'if written == 0 && p.kept >= p.cap {\n\t\tp.lost++\n\t} else {\n\t\tp.lost += int64(len(b) - written)\n\t}',
    ],
    'growing kept after the cap is exhausted': [
      'return len(b), nil',
      'if written == 0 && p.kept >= p.cap {\n\t\tp.kept++\n\t}\n\treturn len(b), nil',
    ],
    'returning zero after the cap is exhausted': [
      'return len(b), nil',
      'if written == 0 && p.kept >= p.cap {\n\t\treturn 0, nil\n\t}\n\treturn len(b), nil',
    ],
  },
};

function runPackage({ testBody, mutation } = {}) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'claudecode-persist-'));
  try {
    const binary = path.join(tmp, 'claudecode.test');
    const args = ['test', '-trimpath', '-c', '-o', binary];
    const replacements = {};
    function overlay(file, target, body) {
      const scratch = path.join(tmp, file);
      fs.writeFileSync(scratch, body);
      replacements[path.join(pkgDir, target)] = scratch;
    }
    if (testBody !== undefined) overlay('t.go', 'persistence_test.go', testBody);
    if (mutation) {
      const [find, replace] = mutation;
      const source = fs.readFileSync(path.join(pkgDir, 'persistence.go'), 'utf8');
      assert.equal(source.split(find).length - 1, 1, `Expected persistence.go to contain ${JSON.stringify(find)} exactly once`);
      overlay('m.go', 'persistence.go', source.replace(find, () => replace));
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
  assert.ok(passed(run), `Expected ${pkg} tests to pass under the real stderrPersistence (exit ${run.status}):\n${run.out}`);
}

function survivors(category, testBody) {
  return Object.entries(mutations[category]).filter(([label, mutation]) => {
    const run = runPackage({ testBody, mutation });
    if (passed(run)) return true;
    assert.ok(run.status === 1 && /^FAIL$/m.test(run.out) && /^\s*--- FAIL: /m.test(run.out) &&
      /^\s+persistence_test\.go:\d+: /m.test(run.out) && !/^panic:/m.test(run.out),
    `Expected ${pkg} to reject ${label} by an assertion in persistence_test.go (exit ${run.status}):\n${run.out}`);
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
  console.log(mode === 'good' ? 'Stderr persistence tests caught every mutation.' : 'Incomplete stderr persistence tests let the corresponding mutations survive.');
  process.exitCode = mode === 'good' ? 0 : 1;
} else {
  const { Given, Then } = require('@cucumber/cucumber');
  let cleanPass = false;
  Given(`${slug}: the Claude Code package tests pass with the real stderrPersistence`, { timeout: 95000 }, function () {
    if (!cleanPass) requirePass(runPackage());
    cleanPass = true;
  });
  for (const [category, sentence] of Object.entries({
    cap: 'the tests require writes that cross the cap to return the full length with no error, retain at most the cap and count every unretained byte as lost',
    short: 'the tests require a short underlying write to count the unwritten portion as lost while Write accepts the full input',
    exhausted: 'the tests require a write after the cap is exhausted to add its full length to lost without increasing kept',
  })) {
    Then(`${slug}: ${sentence}`, { timeout: 110000 }, function () {
      const missed = survivors(category);
      assert.deepEqual(missed, [], `${pkg} tests passed despite ${missed.join(', ')}; add direct stderrPersistence coverage in persistence_test.go`);
    });
  }
}
