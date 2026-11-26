'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const slug = 'claude-setup-token-output-contract';
const root = path.resolve(__dirname, '../..');
const pkg = 'cli/internal/claudecode';
const production = `${pkg}/setup_token.go`;
const tests = `${pkg}/setup_token_test.go`;
const redact = 's.out.Write(data[:i])';
const markerInWrite = 'bytes.Contains(p, []byte(tokenMarker))';

// These local mutations change the real implementation, never the test runner or its output.
const mutations = {
  'finding the marker only within a single write': [
    ['if i := bytes.Index(data, []byte(tokenMarker)); i >= 0 {',
      'if j := bytes.Index(p, []byte(tokenMarker)); j >= 0 {\n\t\ti := len(data) - len(p) + j'],
  ],
  'dropping the text before a split marker': [
    ['s.out.Write(data[:len(data)-keep])', 'if keep == 0 { s.out.Write(data) }'],
  ],
  'forwarding token text after a whole marker in the same write': [
    [redact, `${redact}\n\t\tif ${markerInWrite} { s.out.Write(data[i+len(tokenMarker):]) }`],
  ],
  'forwarding later writes after a whole marker': [
    ['cut      bool', 'cut      bool\n\tcutOnWhole bool'],
    ['s.cut = true', `s.cut = true\n\t\ts.cutOnWhole = ${markerInWrite}`],
    ['if s.cut {', 'if s.cut {\n\t\tif s.cutOnWhole { s.out.Write(p) }'],
  ],
  'returning the token without trimming it': [
    ['var parts []string', 'var parts []string\n\tvar raw string'],
    ['line = strings.TrimSpace(line)', 'raw = line\n\t\tline = strings.TrimSpace(line)'],
    ['parts = append(parts, line)', 'parts = append(parts, raw)'],
    ['if !tokenRe.MatchString(token)', 'if !tokenRe.MatchString(strings.TrimSpace(token))'],
  ],
  'accepting arbitrary screen text without a marker': [
    ['if start < 0 {\n\t\treturn ""', 'if start < 0 {\n\t\treturn strings.TrimSpace(text)'],
  ],
  'returning a nonempty token when only the marker is present': [
    ['if !tokenRe.MatchString(token)', 'if token == "" { return "fake-missing-token" }\n\tif !tokenRe.MatchString(token)'],
  ],
};

const offline = { ...process.env, GOFLAGS: '', GOPROXY: 'off', GOSUMDB: 'off', GOTOOLCHAIN: 'local', GOWORK: 'off' };

function execute(program, args, cwd, timeout) {
  const result = spawnSync(program, args, { cwd, timeout, env: offline, encoding: 'utf8' });
  if (result.error) throw result.error;
  assert.equal(result.signal, null, `${program} terminated by ${result.signal}`);
  return result;
}

function runTests(overrides = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'setup-token-contract-'));
  try {
    const binary = path.join(dir, 'claudecode.test');
    const args = ['test', '-trimpath', '-c', '-o', binary];
    const replace = {};
    for (const [relative, contents] of Object.entries(overrides)) {
      const scratch = path.join(dir, path.basename(relative));
      fs.writeFileSync(scratch, contents);
      replace[path.join(root, relative)] = scratch;
    }
    if (Object.keys(replace).length > 0) {
      const overlay = path.join(dir, 'overlay.json');
      fs.writeFileSync(overlay, JSON.stringify({ Replace: replace }));
      args.push('-overlay', overlay);
    }
    args.push('./internal/claudecode');
    const build = execute('go', args, path.join(root, 'cli'), 60000);
    assert.equal(build.status, 0, `Cannot compile ./internal/claudecode:\n${build.stdout}${build.stderr}`);
    return execute(binary, ['-test.v'], path.join(root, pkg), 20000);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function passed({ status, stdout }) {
  return status === 0 && /^--- PASS: Test/m.test(stdout) && /^PASS$/m.test(stdout);
}

function requirePass(run) {
  assert.ok(passed(run), `Expected tests in ./internal/claudecode to run and pass (exit ${run.status}):\n${run.stdout}${run.stderr}`);
}

function rejects(name, fixture = {}) {
  assert.ok(Object.hasOwn(mutations, name), `Unknown setup-token mutation: ${name}`);
  let source = fs.readFileSync(path.join(root, production), 'utf8');
  for (const [anchor, replacement] of mutations[name]) {
    assert.equal(source.split(anchor).length, 2, `Expected one mutation anchor for ${name} in ${production}`);
    source = source.replace(anchor, () => replacement);
  }
  const run = runTests({ ...fixture, [production]: source });
  if (passed(run)) return false;
  assert.ok(run.status === 1 && /^--- FAIL: Test/m.test(run.stdout) && /^FAIL$/m.test(run.stdout)
    && /^\s+setup_token_test\.go:\d+:/m.test(run.stdout) && !/^panic:/m.test(run.stderr),
  `Expected a failing assertion in ${tests} for ${name} (exit ${run.status}):\n${run.stdout}${run.stderr}`);
  return true;
}

if (require.main === module) {
  const mode = process.argv[2];
  assert.ok(mode === 'good' || mode === 'bad');
  const { correct, wrong } = require(path.join(root, '.kogen/intents', slug, 'controls.json'));
  // Check every assertion with real compiled fixtures, even if baseline red would skip it.
  requirePass(runTests());
  let detected = 0;
  for (const name of Object.keys(mutations)) {
    const fixture = mode === 'good' ? correct.files : wrong.find(control => control.name === name).files;
    requirePass(runTests(fixture));
    const caught = rejects(name, fixture);
    assert.equal(caught, mode === 'good', `Unexpected assertion result for ${name} with ${mode} coverage`);
    detected += Number(caught);
  }
  console.log(`Setup-token coverage detected ${detected} of ${Object.keys(mutations).length} targeted mutations.`);
  process.exitCode = detected === Object.keys(mutations).length ? 0 : 1;
} else {
  const { Given, Then } = require('@cucumber/cucumber');
  let checkedBaseline = false;
  Given(`${slug}: the Claude Code package tests pass on the unchanged implementation`, { timeout: 90000 }, function () {
    if (!checkedBaseline) requirePass(runTests());
    checkedBaseline = true;
  });
  Then(`${slug}: the tests reject {string}`, { timeout: 90000 }, function (name) {
    assert.ok(rejects(name),
      `./internal/claudecode tests passed despite ${name}; add an assertion of the forwarded output or parsed token in ${tests}`);
  });
}
