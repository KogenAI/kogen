'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const slug = 'claudecode-transcript-pruning-tests';
const root = path.resolve(__dirname, '../..');
const cli = path.join(root, 'cli');
const pkg = './internal/claudecode';
const pkgDir = path.join(cli, pkg);
const testPath = 'cli/internal/claudecode/transcripts_test.go';

// Temporary wrong implementations of pruneTranscripts, applied only in scratch overlays of transcripts.go.
const mutations = {
  report: {
    'not counting removed transcripts': ['rep.removed++', ''],
    'not counting removed bytes': ['rep.removedBytes += fi.Size()', 'rep.removedBytes += 0'],
    'counting one byte per removed transcript': ['rep.removedBytes += fi.Size()', 'rep.removedBytes++'],
  },
  exclusions: {
    'removing the current session transcript': ['n == own || !transcriptName.MatchString(n)', '!transcriptName.MatchString(n)'],
    'removing fresh transcripts': ['if now.Sub(fi.ModTime()) <= retention {', 'if false {'],
    'removing non-UUID JSONL files': ['n == own || !transcriptName.MatchString(n)', 'n == own || filepath.Ext(n) != ".jsonl"'],
  },
  symlinks: {
    'treating a symlink as a regular transcript': ['!fi.Mode().IsRegular()', 'false'],
    'examining a symlink through its target': ['folder.Lstat(n)', 'folder.Stat(n)'],
  },
};

function runPackage({ testBody, mutation } = {}) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'claudecode-prune-'));
  try {
    const binary = path.join(tmp, 'claudecode.test');
    const args = ['test', '-trimpath', '-c', '-o', binary];
    const replacements = {};
    function overlay(file, target, body) {
      const scratch = path.join(tmp, file);
      fs.writeFileSync(scratch, body);
      replacements[path.join(pkgDir, target)] = scratch;
    }
    if (testBody !== undefined) overlay('t.go', 'transcripts_test.go', testBody);
    if (mutation) {
      const [find, replace] = mutation;
      const source = fs.readFileSync(path.join(pkgDir, 'transcripts.go'), 'utf8');
      assert.ok(source.includes(find), `Expected transcripts.go to contain ${JSON.stringify(find)}`);
      overlay('m.go', 'transcripts.go', source.replace(find, replace));
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
  assert.ok(passed(run), `Expected ${pkg} tests to pass under the real pruneTranscripts (exit ${run.status}):\n${run.out}`);
}

function survivors(category, testBody) {
  return Object.entries(mutations[category]).filter(([label, mutation]) => {
    const run = runPackage({ testBody, mutation });
    if (passed(run)) return true;
    assert.ok(run.status === 1 && /^FAIL$/m.test(run.out) && /^\s*--- FAIL: /m.test(run.out) &&
      /^\s+transcripts_test\.go:\d+: /m.test(run.out) && !/^panic:/m.test(run.out),
    `Expected ${pkg} to reject ${label} by an assertion in transcripts_test.go (exit ${run.status}):\n${run.out}`);
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
  console.log(mode === 'good' ? 'Transcript pruning tests caught every mutation.' : 'Incomplete transcript pruning tests let the corresponding mutations survive.');
  process.exitCode = mode === 'good' ? 0 : 1;
} else {
  const { Given, Then } = require('@cucumber/cucumber');
  let cleanPass = false;
  Given(`${slug}: the Claude Code package tests pass with the real pruneTranscripts`, { timeout: 95000 }, function () {
    if (!cleanPass) requirePass(runPackage());
    cleanPass = true;
  });
  for (const [category, sentence] of Object.entries({
    report: 'the tests require an expired transcript to be removed and the report to record its count and byte size',
    exclusions: 'the tests require the current session, fresh and non-UUID files to remain in place',
    symlinks: 'the tests require a symlink to an expired transcript to be neither followed nor removed',
  })) {
    Then(`${slug}: ${sentence}`, { timeout: 110000 }, function () {
      const missed = survivors(category);
      assert.deepEqual(missed, [], `${pkg} tests passed despite ${missed.join(', ')}; add direct pruneTranscripts coverage in transcripts_test.go`);
    });
  }
}
