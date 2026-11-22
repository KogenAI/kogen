'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');
const {Given, When, Then, setDefaultTimeout} = require('@cucumber/cucumber');

setDefaultTimeout(115000);

const ROOT = path.resolve(__dirname, '../..');
const CLI = path.join(ROOT, 'cli');
// The Go files that sit directly in cli/ before this change, and the digest of the pin test.
const BASELINE = new Set([
  'approve_deadline_test.go', 'assembly_test.go', 'claude_runtime_test.go', 'completion_test.go', 'context_test.go',
  'engine.go', 'executor_hook_test.go', 'executor_wiring_test.go', 'facts.go', 'facts_test.go', 'help.go',
  'help_pages_spec_test.go', 'help_test.go', 'init_readiness_test.go', 'login_claude_managed_test.go',
  'login_guided.go', 'login_guided_test.go', 'login_installed_test.go', 'loop_pin_test.go', 'main.go', 'native.go',
  'package_docs_list_test.go', 'parse_test.go', 'probe_deadline_test.go', 'providers_guide_test.go',
  'pty_darwin_test.go', 'pty_linux_test.go', 'race_shards_test.go', 'readiness.go', 'receipt.go', 'release_test.go',
  'repository_config_test.go', 'run_test.go', 'spec_check_test.go', 'terminal_darwin.go', 'terminal_linux.go',
  'terminal_other.go', 'testing_rules_test.go', 'testmain_test.go', 'usage.go', 'usage_coverage.go',
  'usage_coverage_test.go', 'usage_limit_installed_test.go', 'usage_test.go',
]);
const PIN_TEST_SHA256 = '21e9c261c183595980468f428c259917f33fac6d9be70ebb73e92bd9d293bf2e';

function newGoFiles() {
  return fs.readdirSync(CLI).filter((f) => f.endsWith('.go') && !BASELINE.has(f)).sort();
}

function testNames(file) {
  const src = fs.readFileSync(path.join(CLI, file), 'utf8');
  return [...src.matchAll(/^func (Test\w+)\(t \*testing\.T\)/gm)].map((m) => m[1]);
}

function goTest(dir, names) {
  const r = spawnSync('go', ['test', '-count=1', '-v', '-run', '^(' + names.join('|') + ')$', '.'], {
    cwd: dir, encoding: 'utf8', timeout: 100000, env: process.env,
  });
  return {code: r.status, out: (r.stdout || '') + (r.stderr || '') + (r.error ? String(r.error) : '')};
}

function newTests() {
  const files = newGoFiles();
  assert.equal(files.length, 1, `want exactly one new Go file in cli/, found ${JSON.stringify(files)}`);
  const names = testNames(files[0]);
  assert.ok(names.length > 0, `cli/${files[0]} defines no Test function`);
  return {file: files[0], names};
}

// runMutated copies the cli tree, edits one vendored file and runs the new tests in the copy.
function runMutated(rel, from, to) {
  const {file, names} = newTests();
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-loop-pin-'));
  const dir = path.join(tmp, 'cli');
  fs.cpSync(CLI, dir, {recursive: true});
  const target = path.join(dir, rel);
  const src = fs.readFileSync(target, 'utf8');
  assert.ok(src.includes(from), `${rel} no longer contains ${from}`);
  fs.writeFileSync(target, src.replace(from, to));
  const res = goTest(dir, names);
  fs.rmSync(tmp, {recursive: true, force: true});
  return {file, names, res};
}

Given('kogen-loop-pin-chat-streaming: the CLI carries the vendored Chat Completions client', function () {
  for (const f of ['chat.go', 'idle.go']) {
    assert.ok(fs.existsSync(path.join(CLI, 'third_party/kogen-loop/provider', f)), `${f} missing from the vendored provider`);
  }
});

When('kogen-loop-pin-chat-streaming: the change is inspected', function () {
  this.newFiles = newGoFiles();
});

Then('kogen-loop-pin-chat-streaming: exactly one new Go test file is added to the cli package and no other Go file in it changes name', function () {
  assert.equal(this.newFiles.length, 1, `want exactly one new Go file in cli/, found ${JSON.stringify(this.newFiles)}`);
  assert.ok(this.newFiles[0].endsWith('_test.go'), `${this.newFiles[0]} is not a Go test file`);
});

Then('kogen-loop-pin-chat-streaming: the new tests pass on the adopted tree', function () {
  const {file, names} = newTests();
  const res = goTest(CLI, names);
  assert.equal(res.code, 0, `go test -run ${names.join('|')} in cli (${file}) exited ${res.code}:\n${res.out}`);
  for (const n of names) {
    assert.ok(res.out.includes('--- PASS: ' + n), `${n} did not report PASS:\n${res.out}`);
  }
});

Then('kogen-loop-pin-chat-streaming: the new tests fail when the vendored chat.go sends stream false', function () {
  const {file, names, res} = runMutated('third_party/kogen-loop/provider/chat.go', '"stream": true', '"stream": false');
  assert.notEqual(res.code, 0, `the new tests (${file}: ${names.join(', ')}) still passed with "stream": false in the vendored chat.go:\n${res.out}`);
  assert.ok(res.out.includes('--- FAIL: '), `no new test reported FAIL with "stream": false:\n${res.out}`);
});

Then('kogen-loop-pin-chat-streaming: the new tests fail when the vendored first byte wait is 45 seconds', function () {
  const {file, names, res} = runMutated('third_party/kogen-loop/provider/idle.go',
    'DefaultHeaderTimeout = 120 * time.Second', 'DefaultHeaderTimeout = 45 * time.Second');
  assert.notEqual(res.code, 0, `the new tests (${file}: ${names.join(', ')}) still passed with a 45 s watchdog in the vendored client:\n${res.out}`);
  assert.ok(res.out.includes('--- FAIL: '), `no new test reported FAIL with a 45 s watchdog:\n${res.out}`);
});

Then('kogen-loop-pin-chat-streaming: the pin test is unchanged and TestLoopPin passes', function () {
  const sum = crypto.createHash('sha256').update(fs.readFileSync(path.join(CLI, 'loop_pin_test.go'))).digest('hex');
  assert.equal(sum, PIN_TEST_SHA256, 'cli/loop_pin_test.go was changed');
  newTests();
  const res = goTest(CLI, ['TestLoopPin']);
  assert.equal(res.code, 0, `go test -run ^TestLoopPin$ in cli exited ${res.code}:\n${res.out}`);
  assert.ok(res.out.includes('--- PASS: TestLoopPin'), `TestLoopPin did not report PASS:\n${res.out}`);
  assert.ok(!res.out.includes('SKIP'), `TestLoopPin was skipped:\n${res.out}`);
});
