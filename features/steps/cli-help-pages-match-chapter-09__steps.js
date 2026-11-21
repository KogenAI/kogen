const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, When, Then } = require('@cucumber/cucumber');

const P = 'cli-help-pages-match-chapter-09: ';
const root = process.cwd();
const PROSE = 'spec/prose/09-cli-and-process.md';
const HANDLERS = 'test/acceptance/support/handlers.js';
const TEST_FILE = 'cli/help_pages_spec_test.go';
const LOGIN = '  login                    On an interactive terminal, ask which account to use and guide the sign-in\n';
const PREFLIGHT = '  preflight <slug>         Observe read-only prerequisites\n';

let built;
let last;

function binary() {
  if (built) return built;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-help-pages-'));
  const bin = path.join(dir, 'cli.test');
  const r = spawnSync('go', ['test', '-c', '-o', bin, '.'], { cwd: path.join(root, 'cli'), encoding: 'utf8', timeout: 100000, env: { ...process.env, GOFLAGS: '-trimpath' } });
  assert.equal(r.status, 0, `go test -c in cli failed: ${r.stdout}${r.stderr}`);
  built = { dir, bin };
  return built;
}

function testNames() {
  const file = path.join(root, TEST_FILE);
  assert.ok(fs.existsSync(file), `${TEST_FILE} does not exist`);
  return [...fs.readFileSync(file, 'utf8').matchAll(/^func (Test\w+)\(/gm)].map((m) => m[1]);
}

function count(text, part) {
  return text.split(part).length - 1;
}

function dropOnce(text, part, what) {
  assert.equal(count(text, part), 1, `${what}: expected exactly one occurrence of ${JSON.stringify(part)}`);
  return text.replace(part, '');
}

const MUTATIONS = {
  'none': (prose, js) => [prose, js],
  'one space added at the end of a line of the intent page in the chapter 09 text': (prose, js) => {
    assert.equal(count(prose, PREFLIGHT), 1, 'chapter 09 preflight line');
    return [prose.replace(PREFLIGHT, PREFLIGHT.replace('\n', ' \n')), js];
  },
  'the login line missing from the provider page in the chapter 09 text': (prose, js) => [dropOnce(prose, LOGIN, 'chapter 09 login line'), js],
  'the login line missing from the providerHelp constant of handlers.js': (prose, js) => [prose, dropOnce(js, LOGIN.replace(/\n$/, '\\n'), 'handlers.js login line')],
  'a line missing from the intentHelp constant of handlers.js': (prose, js) => [prose, dropOnce(js, PREFLIGHT.replace(/\n$/, '\\n'), 'handlers.js preflight line')],
  'the intent page missing from the chapter 09 text': (prose, js) => {
    const m = prose.match(/`kogen intent`:\n```\n[\s\S]*?```\n\n/);
    assert.ok(m, 'chapter 09 intent block');
    return [prose.replace(m[0], ''), js];
  },
  'the provider page appearing twice in the chapter 09 text': (prose, js) => {
    const m = prose.match(/`kogen provider`:\n```\n[\s\S]*?```\n\n/);
    assert.ok(m, 'chapter 09 provider block');
    return [prose.replace(m[0], m[0] + m[0]), js];
  },
  'the final line end missing from the provider page in the chapter 09 text': (prose, js) => {
    const m = prose.match(/(`kogen provider`:\n```\n[\s\S]*?)\n```\n/);
    assert.ok(m, 'chapter 09 provider block');
    return [prose.replace(m[0], m[1] + '```\n'), js];
  },
};

function runTests(mutation) {
  const { bin } = binary();
  const names = testNames();
  const [prose, js] = MUTATIONS[mutation](fs.readFileSync(path.join(root, PROSE), 'utf8'), fs.readFileSync(path.join(root, HANDLERS), 'utf8'));
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-help-case-'));
  for (const [rel, text] of [[PROSE, prose], [HANDLERS, js]]) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), text);
  }
  fs.mkdirSync(path.join(dir, 'cli'));
  const r = spawnSync(bin, ['-test.v', '-test.count=1', '-test.run', `^(${names.join('|')})$`], { cwd: path.join(dir, 'cli'), encoding: 'utf8', timeout: 100000 });
  fs.rmSync(dir, { recursive: true, force: true });
  last = { names, status: r.status, out: `${r.stdout}${r.stderr}` };
}

Given(P + 'the cli test binary is built', function () {
  binary();
});

When(P + 'the help page tests run on the {string} state of the help sources', function (mutation) {
  assert.ok(MUTATIONS[mutation], `unknown state ${mutation}`);
  runTests(mutation);
});

Then(P + 'cli\\/help_pages_spec_test.go declares exactly four tests and all of them pass', function () {
  assert.equal(last.names.length, 4, `${TEST_FILE} declares ${last.names.length} tests: ${last.names.join(', ')}`);
  assert.equal(last.status, 0, `tests of ${TEST_FILE} failed on the committed sources:\n${last.out}`);
  for (const n of last.names) assert.match(last.out, new RegExp(`--- PASS: ${n} `), `${n} did not run and pass:\n${last.out}`);
});

Then(P + 'a help page test fails', function () {
  assert.ok(last.names.length > 0, `${TEST_FILE} declares no tests`);
  assert.notEqual(last.status, 0, `the tests of ${TEST_FILE} passed although the sources drifted:\n${last.out}`);
  assert.match(last.out, /--- FAIL: /, `no test failed:\n${last.out}`);
});

Then(P + 'the failure output contains {string}', function (text) {
  assert.ok(last.out.includes(text), `the failure output lacks ${JSON.stringify(text)}:\n${last.out}`);
});

Then(P + 'the failure output contains the provider login line', function () {
  const line = LOGIN.replace(/\n$/, '');
  assert.ok(last.out.includes(line), `the failure output does not quote ${JSON.stringify(line)}:\n${last.out}`);
});
