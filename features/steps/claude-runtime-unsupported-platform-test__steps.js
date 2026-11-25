'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const slug = 'claude-runtime-unsupported-platform-test';
const cli = path.resolve(__dirname, '../../cli');
const pkg = path.join(cli, 'internal/claudecode');
const testPath = 'cli/internal/claudecode/runtime_test.go';
const signature = 'func UnsupportedMessage(goos, goarch string) string {';

function runTests({ target, replacement, testBody } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-refusal-'));
  try {
    const binary = path.join(dir, 'claudecode.test');
    const args = ['test', '-trimpath', '-c', '-o', binary];
    const replace = {};
    function overlay(name, text) {
      const file = path.join(dir, name);
      fs.writeFileSync(file, text);
      replace[path.join(pkg, name)] = file;
    }
    if (target) {
      const source = fs.readFileSync(path.join(pkg, 'runtime.go'), 'utf8');
      assert.equal(source.split(signature).length, 2, 'expected one UnsupportedMessage declaration in runtime.go');
      const [goos, goarch] = target.map(value => JSON.stringify(value));
      overlay('runtime.go', source.replace(signature, () =>
        `${signature}\n\tif goos == ${goos} && goarch == ${goarch} {\n\t\treturn ${JSON.stringify(replacement)}\n\t}`));
    }
    if (testBody !== undefined) overlay('runtime_test.go', testBody);
    if (Object.keys(replace).length) {
      const manifest = path.join(dir, 'overlay.json');
      fs.writeFileSync(manifest, JSON.stringify({ Replace: replace }));
      args.push('-overlay', manifest);
    }
    args.push('./internal/claudecode');
    const build = spawnSync('go', args, { cwd: cli, encoding: 'utf8', timeout: 90000 });
    if (build.error) throw build.error;
    assert.equal(build.status, 0, `go test -c ./internal/claudecode failed:\n${build.stdout}${build.stderr}`);
    const run = spawnSync(binary, [], { cwd: pkg, encoding: 'utf8', timeout: 20000 });
    if (run.error) throw run.error;
    return run;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function passed({ status, stdout }) {
  return status === 0 && /^PASS\s*$/m.test(stdout);
}

function requirePass(run) {
  assert.ok(passed(run), `expected unmodified ./internal/claudecode tests to pass (exit ${run.status}):\n${run.stdout}${run.stderr}`);
}

function rejects(target, expected, replacement, testBody) {
  assert.notEqual(replacement, expected, 'the replacement must be different from the exact refusal');
  const run = runTests({ target, replacement, testBody });
  if (passed(run)) return false;
  assert.ok(run.status === 1 && /^--- FAIL: /m.test(run.stdout) && /^\s+runtime_test\.go:\d+:/m.test(run.stdout),
    `expected a runtime_test.go assertion to fail for ${target.join('/')} (exit ${run.status}):\n${run.stdout}${run.stderr}`);
  return true;
}

if (require.main === module) {
  // Readiness-only observer controls; acceptance itself runs the candidate's tests.
  const [mode, goos, goarch, expected, replacement] = process.argv.slice(2);
  assert.ok(mode === 'good' || mode === 'bad', 'expected observer control mode good or bad');
  const controls = require(path.join(__dirname, '../../.kogen/intents', slug, 'controls.json'));
  const testBody = (mode === 'good' ? controls.correct : controls.wrong[0]).files[testPath];
  assert.equal(typeof testBody, 'string');
  requirePass(runTests());
  requirePass(runTests({ testBody }));
  const rejected = rejects([goos, goarch], expected, replacement, testBody);
  console.log(rejected ? 'The refusal assertion failed as required.' : 'The package tests passed despite the wrong refusal.');
  process.exitCode = rejected ? 0 : 1;
} else {
  const { Given, Then } = require('@cucumber/cucumber');
  Given(`${slug}: the unmodified Claude Code runtime package tests pass`, { timeout: 115000 }, function () {
    requirePass(runTests());
  });
  Then(`${slug}: the tests expecting {string} for {string} and {string} reject {string}`, { timeout: 115000 },
    function (expected, goos, goarch, replacement) {
      assert.ok(rejects([goos, goarch], expected, replacement),
        `./internal/claudecode tests passed with the wrong refusal for ${goos}/${goarch}: ${JSON.stringify(replacement)}`);
    });
}
