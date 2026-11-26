'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const slug = 'claude-version-helper-contract-tests';
const cli = path.resolve(__dirname, '../../cli');
const pkg = path.join(cli, 'internal/claudecode');
const signatures = {
  FirstField: ['answer string', 'string', ['answer']],
  Pinned: ['answer string', 'bool', ['answer']],
  NotPinnedMessage: ['path, answer, want string', 'string', ['path', 'answer', 'want']],
};

function runTests(overrides = {}, compileTimeout = 20000) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-version-tests-'));
  try {
    const binary = path.join(dir, 'claudecode.test');
    const args = ['test', '-trimpath', '-c', '-o', binary];
    const replace = {};
    for (const [name, source] of Object.entries(overrides)) {
      const file = path.join(dir, name);
      fs.writeFileSync(file, source);
      replace[path.join(pkg, name)] = file;
    }
    if (Object.keys(replace).length) {
      const overlay = path.join(dir, 'overlay.json');
      fs.writeFileSync(overlay, JSON.stringify({ Replace: replace }));
      args.push('-overlay', overlay);
    }
    args.push('./internal/claudecode');
    const build = spawnSync('go', args, { cwd: cli, encoding: 'utf8', timeout: compileTimeout });
    if (build.error) throw build.error;
    assert.equal(build.status, 0, `go test -c ./internal/claudecode failed:\n${build.stdout}${build.stderr}`);
    const run = spawnSync(binary, [], { cwd: pkg, encoding: 'utf8', timeout: 5000 });
    if (run.error) throw run.error;
    return run;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function passed(run) {
  return run.status === 0 && /^PASS$/m.test(run.stdout);
}

function requirePass(run) {
  assert.ok(passed(run), `Expected the ./internal/claudecode test binary to PASS (exit ${run.status}):\n${run.stdout}${run.stderr}`);
}

function catches(helper, args, expected, wrong, tests = {}) {
  const [params, result, names] = signatures[helper];
  assert.notEqual(wrong, expected, 'The mutant must differ from the expected result');
  const declaration = `func ${helper}(${params}) ${result} {`;
  const source = fs.readFileSync(path.join(pkg, 'runtime.go'), 'utf8');
  assert.equal(source.split(declaration).length, 2, `Expected one declaration of ${helper} in runtime.go`);
  const match = names.map((name, i) => `${name} == mutationArg${i}`).join(' && ');
  const payload = `\n\t${names.map((_, i) => `mutationArg${i}`).join(', ')} := ${args}\n\tif ${match} { return ${wrong} }\n`;
  const run = runTests({ ...tests, 'runtime.go': source.replace(declaration, () => declaration + payload) });
  if (passed(run)) return false;
  assert.ok(run.status === 1 && /^--- FAIL: /m.test(run.stdout) && /^\s+runtime_test\.go:\d+:/m.test(run.stdout),
    `Expected ./internal/claudecode runtime_test.go to fail an assertion for ${helper}(${args}) (exit ${run.status}):\n${run.stdout}${run.stderr}`);
  return true;
}

if (require.main === module) {
  const mode = process.argv[2];
  assert.ok(mode === 'good' || mode === 'bad', 'Expected observer control mode good or bad');
  const controls = require(path.join(__dirname, '../../.kogen/intents', slug, 'controls.json'));
  const fixture = mode === 'good' ? controls.correct : controls.wrong[0];
  const tests = { 'runtime_test.go': fixture.files['cli/internal/claudecode/runtime_test.go'] };
  requirePass(runTests(tests, 90000));
  const rejected = catches('FirstField', '" \\t2.1.300 (Claude Code)\\n"', '"2.1.300"', 'strings.TrimSpace(answer)', tests);
  console.log(rejected ? 'The test caught the wrong version result.' : 'The tests passed despite the wrong version result.');
  process.exitCode = rejected ? 0 : 1;
} else {
  const { Given, Then } = require('@cucumber/cucumber');
  let cleanPass = false;
  Given(`${slug}: the unmodified Claude Code package tests pass`, { timeout: 100000 }, function () {
    if (!cleanPass) requirePass(runTests({}, 90000));
    cleanPass = true;
  });
  Then(`${slug}: the package tests reject these wrong results for {word}`, { timeout: 115000 }, function (helper, table) {
    for (const { arguments: args, expected, 'wrong result': wrong } of table.hashes()) {
      assert.ok(catches(helper, args, expected, wrong),
        `./internal/claudecode tests passed with ${helper}(${args}) returning ${wrong} instead of ${expected}; add the direct assertion to runtime_test.go`);
    }
  });
}
