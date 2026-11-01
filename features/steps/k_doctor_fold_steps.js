'use strict';
// K-DOCTOR-FOLD: `kogen doctor` is removed; `kogen init` reports readiness in its own output and the existing commands name
// the fix in their own error messages. Through the installed release (the packaged suite of go_driver_support.js) in
// scratch Git repositories with an empty HOME and synthetic credentials only; init's one model request goes to a local
// scripted provider. stdout is compared exactly and separately from stderr (progress).
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { Given, When, Then, After, AfterAll } = require('@cucumber/cucumber');
const H = require('./go_driver_support.js');

const ROOT = path.resolve(__dirname, '../..');
let sharedSuite;
const suiteOnce = () => sharedSuite || (sharedSuite = H.setupSuite());
const dirs = [];

const FIXTURE_ID = ['-c', 'user.name=Fold Fixture', '-c', 'user.email=fold@example.invalid', '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null'];
const CONFIG = [
  'version: 1', 'commands:', '  setup: []', '  fix: []', '  checks: []', '  acceptance:',
  `    run: 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require ''features/steps/*.js'' --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"'`,
  "    steps_dir: 'features/steps'", 'protect: []', 'models:',
  '  shape: {model: gpt-6.1-sol, effort: high}', '  build: {model: gpt-6.1-sol, effort: medium}', '  review: {model: gpt-6.1-sol, effort: high}', '',
].join('\n');

const gitEnv = w => ({ PATH: process.env.PATH, HOME: w.home, GIT_CONFIG_GLOBAL: w.gitconfig, GIT_CONFIG_NOSYSTEM: '1' });
function git(w, args) {
  const r = spawnSync('git', ['-C', w.repo, ...args], { encoding: 'utf8', env: gitEnv(w) });
  assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.stdout}${r.stderr}`);
  return r.stdout.trim();
}
function write(w, rel, text) { const f = path.join(w.repo, rel); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, text); }

// A scratch root with an empty HOME and a Git repository `repo` (initialized unless git is false).
async function workspace(w, { git: makeRepo = true, commit = false, identity = false, login = false, config = false } = {}) {
  w.suite = await suiteOnce();
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kfold-')));
  dirs.push(root);
  w.root = root; w.repo = path.join(root, 'repo'); w.home = path.join(root, 'home'); w.cwd = w.repo;
  for (const d of [w.repo, w.home]) fs.mkdirSync(d, { recursive: true });
  w.gitconfig = path.join(w.home, '.gitconfig'); fs.writeFileSync(w.gitconfig, '');
  if (!makeRepo) return;
  git(w, ['init', '-q', '--initial-branch=main']);
  if (commit) {
    write(w, 'README.md', '# Fixture\n');
    write(w, 'app.txt', 'baseline\n');
    if (config) {
      write(w, '.kogen/project.yaml', CONFIG);
      write(w, '.gitignore', '.kogen/local/\n');
      write(w, 'features/steps/README.md', 'Cucumber step definitions.\n');
    }
    git(w, ['add', '-A']);
    git(w, [...FIXTURE_ID, 'commit', '-q', '-m', 'baseline']);
  }
  if (identity) { git(w, ['config', 'user.name', 'Fold Fixture']); git(w, ['config', 'user.email', 'fold@example.invalid']); }
  if (login) H.seedCredentials({ home: w.home });
}

// The installed kogen with a minimal environment; stdout and stderr are kept apart.
function kogen(w, args, { input, env = {} } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(w.suite.release, args, {
      cwd: w.cwd, stdio: [input === undefined ? 'ignore' : 'pipe', 'pipe', 'pipe'],
      env: { HOME: w.home, PATH: process.env.PATH, GIT_CONFIG_GLOBAL: w.gitconfig, GIT_CONFIG_NOSYSTEM: '1', ...env },
    });
    let stdout = '', stderr = '';
    child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
    child.stdout.on('data', b => { stdout += b; }); child.stderr.on('data', b => { stderr += b; });
    if (input !== undefined) { child.stdin.on('error', () => {}); child.stdin.end(input); }
    const timer = setTimeout(() => child.kill('SIGKILL'), 240000);
    child.once('error', e => { clearTimeout(timer); reject(e); });
    child.once('close', (code, signal) => { clearTimeout(timer); resolve({ args, code, signal, stdout, stderr }); });
  });
}
const shown = r => `kogen ${r.args.join(' ')} exited ${r.code}${r.signal ? ' (' + r.signal + ')' : ''}\n--- stdout\n${r.stdout}--- stderr\n${r.stderr}`;

// {repo}: the repository's real path; {version}: what `kogen version` prints; {sha8}: HEAD's 8-digit short hash.
async function expand(w, text) {
  let out = text.replaceAll('{repo}', w.repo);
  if (out.includes('{version}')) {
    const v = await kogen(w, ['version']);
    assert.equal(v.code, 0, shown(v));
    out = out.replaceAll('{version}', v.stdout.trim());
  }
  if (out.includes('{sha8}')) out = out.replaceAll('{sha8}', git(w, ['rev-parse', '--short=8', 'HEAD']));
  return out;
}

Given('a fold folder outside any Git repository', { timeout: 1800000 }, async function () {
  await workspace(this, { git: false });
});
Given('a fold repository with one commit, a Git identity and a ChatGPT login', { timeout: 1800000 }, async function () {
  await workspace(this, { commit: true, identity: true, login: true });
});
Given('a fold repository with one commit and no Git identity', { timeout: 1800000 }, async function () {
  await workspace(this, { commit: true, identity: false, login: true });
});
Given('a fold empty Git repository with a Git identity and no provider login', { timeout: 1800000 }, async function () {
  await workspace(this, { commit: false, identity: true, login: false });
});
Given('a fold repository with a committed Kogen configuration, a Git identity and no provider login', { timeout: 1800000 }, async function () {
  await workspace(this, { commit: true, identity: true, login: false, config: true });
});

When('the fold caller runs kogen {string}', { timeout: 300000 }, async function (args) {
  this.result = await kogen(this, args === '' ? [] : args.split(' '));
});
When('the fold caller runs kogen {string} with stdin {string}', { timeout: 300000 }, async function (args, input) {
  this.result = await kogen(this, args.split(' '), { input: input + '\n' });
});
When('the fold caller runs kogen init with a scripted provider that proposes no commands', { timeout: 600000 }, async function () {
  const server = await new H.FakeProvider([H.fn('submit_configuration', { setup: [], fix: [], checks: [], protect: [] })]).start();
  try {
    const url = `http://127.0.0.1:${server.port}`;
    this.result = await kogen(this, ['init'], { env: { KOGEN_PROVIDER_URL: url, KOGEN_AUTH_URL: url } });
  } finally { await server.stop().catch(() => {}); }
});

Then('the fold exit status is {int}', function (code) { assert.equal(this.result.code, code, shown(this.result)); });
Then('the fold stdout is:', { timeout: 120000 }, async function (doc) {
  assert.equal(this.result.stdout, (await expand(this, doc)) + '\n', shown(this.result));
});
Then('the fold commit at HEAD has the subject {string}', function (subject) {
  assert.equal(git(this, ['log', '-1', '--format=%s']), subject);
});
Then('the fold repository has no file {string}', function (rel) {
  assert.equal(fs.existsSync(path.join(this.repo, rel)), false, `${rel} exists`);
});
Then('none of these maintained files contains {string}, ignoring case:', function (term, table) {
  const found = [];
  for (const [rel] of table.raw()) {
    const lines = fs.readFileSync(path.join(ROOT, rel), 'utf8').split('\n');
    lines.forEach((line, i) => { if (line.toLowerCase().includes(term.toLowerCase())) found.push(`${rel}:${i + 1}: ${line}`); });
  }
  assert.deepEqual(found, [], `"${term}" is still mentioned:\n${found.join('\n')}`);
});

After(function () { for (const d of dirs.splice(0)) fs.rmSync(d, { recursive: true, force: true }); });
AfterAll(async () => { if (sharedSuite) { const s = await sharedSuite; sharedSuite = null; H.cleanupSuite(s); } });
