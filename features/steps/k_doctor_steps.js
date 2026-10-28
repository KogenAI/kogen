'use strict';
// K-DOCTOR: `kogen doctor` and the summary at the end of `kogen init`, through the installed `kogen` command in scratch
// Git repositories with an empty HOME, a minimal PATH (git and sh only, plus an optional fake `claude`), and synthetic
// credentials only. No model call, no real provider.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, When, Then, After, AfterAll } = require('@cucumber/cucumber');
const H = require('./go_driver_support.js');

let sharedSuite;
const suiteOnce = () => sharedSuite || (sharedSuite = H.setupSuite());
const dirs = [];

const yamlFor = ({ checks = [], shape = '{model: gpt-6.1-sol, effort: high}', build = '{model: gpt-6.1-sol, effort: medium}', review = '{model: gpt-6.1-sol, effort: high}' } = {}) =>
  'version: 1\ncommands:\n  setup: []\n  fix: []\n' +
  (checks.length ? '  checks:\n' + checks.map(c => `    - name: ${c.name}\n      run: '${c.run.replaceAll("'", "''")}'\n`).join('') : '  checks: []\n') +
  '  acceptance:\n    run: null\n    steps_dir: null\nprotect: []\nmodels:\n' +
  `  shape: ${shape}\n  build: ${build}\n  review: ${review}\n`;

function realGit() {
  const r = spawnSync('/bin/sh', ['-c', 'command -v git'], { encoding: 'utf8' });
  assert.equal(r.status, 0, 'git not found');
  return r.stdout.trim();
}

function gitEnv(w) {
  return { PATH: process.env.PATH, HOME: w.home, GIT_CONFIG_GLOBAL: w.gitconfig, GIT_CONFIG_NOSYSTEM: '1' };
}
function git(w, args, identity) {
  const pre = identity ? ['-c', 'user.name=Doctor Fixture', '-c', 'user.email=doctor@example.invalid', '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null'] : [];
  const r = spawnSync('git', ['-C', w.repo, ...pre, ...args], { encoding: 'utf8', env: gitEnv(w) });
  assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.stdout}${r.stderr}`);
  return r.stdout.trim();
}

async function fixture(world, { yaml, identity, chatgpt, claude }) {
  const suite = await suiteOnce();
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kdoctor-')));
  dirs.push(root);
  const w = world;
  w.suite = suite; w.root = root;
  w.repo = path.join(root, 'repo'); w.home = path.join(root, 'home');
  const bin = path.join(root, 'bin');
  for (const d of [w.repo, w.home, bin]) fs.mkdirSync(d, { recursive: true });
  fs.symlinkSync(realGit(), path.join(bin, 'git'));
  fs.symlinkSync('/bin/sh', path.join(bin, 'sh'));
  let pathValue = bin;
  if (claude) {
    const cdir = path.join(root, 'claude-bin'); fs.mkdirSync(cdir);
    fs.writeFileSync(path.join(cdir, 'claude'), `#!/bin/sh\nif [ "$1" = "--version" ]; then echo '${claude} (Claude Code)'; exit 0; fi\necho '{}'\nexit 0\n`, { mode: 0o755 });
    pathValue = cdir + ':' + bin;
  }
  w.pathValue = pathValue;
  w.gitconfig = path.join(w.home, '.gitconfig'); fs.writeFileSync(w.gitconfig, '');
  git(w, ['init', '-q', '--initial-branch=main']);
  fs.mkdirSync(path.join(w.repo, '.kogen'));
  fs.writeFileSync(path.join(w.repo, '.kogen', 'project.yaml'), yaml);
  fs.writeFileSync(path.join(w.repo, 'app.txt'), 'baseline\n');
  git(w, ['add', '-A']);
  git(w, ['commit', '-q', '-m', 'fixture'], true);
  if (identity) { git(w, ['config', 'user.name', 'Doctor Fixture']); git(w, ['config', 'user.email', 'doctor@example.invalid']); }
  if (chatgpt) H.seedCredentials({ home: w.home });
}

const kogenEnv = w => ({ HOME: w.home, XDG_CONFIG_HOME: path.join(w.home, 'xdg'), GIT_CONFIG_GLOBAL: w.gitconfig, GIT_CONFIG_NOSYSTEM: '1', PATH: w.pathValue });
async function doctor(w, args) {
  const r = await H.run(w.suite.release, ['doctor', ...args], { cwd: w.repo, env: kogenEnv(w) });
  assert.equal(r.timed, false, 'doctor timed out');
  return { code: r.code, out: r.out };
}

function parseText(out, strict) {
  const checks = [];
  for (const line of out.split('\n')) {
    if (line === '') continue;
    let m = /^(ok|fail|skip) (\S+) - (.*)$/.exec(line);
    if (m) { checks.push({ check: m[2], status: m[1], detail: m[3], fix: '' }); continue; }
    m = /^ {2}fix: (.*)$/.exec(line);
    if (m && checks.length) { checks[checks.length - 1].fix = m[1]; continue; }
    if (strict) assert.fail(`unexpected doctor output line: ${line}`);
  }
  return checks;
}
const find = (w, name) => {
  const c = parseText(w.result.out, false).find(x => x.check === name);
  assert.ok(c, `no ${name} line in: ${w.result.out}`);
  return c;
};

function snapshot(w) {
  const files = [];
  const walk = (d, rel) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      if (rel === '' && e.name === '.git') continue;
      const p = path.join(d, e.name), r = path.join(rel, e.name);
      if (e.isDirectory()) walk(p, r); else files.push(`${r}:${fs.statSync(p).mode}:${H.sha(fs.readFileSync(p))}`);
    }
  };
  walk(w.repo, '');
  return { head: git(w, ['rev-parse', 'HEAD']), index: H.sha(fs.readFileSync(path.join(w.repo, '.git', 'index'))), files };
}

Given('a doctor fixture repository with no Git identity, no provider login and an unsupported effort', { timeout: 900000 }, async function () {
  await fixture(this, { yaml: yamlFor({ shape: '{model: gpt-6.1-sol, effort: ultra}' }), identity: false, chatgpt: false });
});
Given('a doctor fixture repository with an identity and a ChatGPT login whose committed check {string} runs {string}', { timeout: 900000 }, async function (name, run) {
  await fixture(this, { yaml: yamlFor({ checks: [{ name, run }] }), identity: true, chatgpt: true });
});
Given('a doctor fixture repository with an identity whose roles use the claude-code executor and no claude on PATH', { timeout: 900000 }, async function () {
  const r = '{executor: claude-code, model: claude-sonnet-5-5, effort: high}';
  await fixture(this, { yaml: yamlFor({ shape: r, build: r, review: r }), identity: true, chatgpt: false });
});
Given('a doctor fixture repository with an identity whose roles use the claude-code executor and a claude reporting version {string}', { timeout: 900000 }, async function (v) {
  const r = '{executor: claude-code, model: claude-sonnet-5-5, effort: high}';
  await fixture(this, { yaml: yamlFor({ shape: r, build: r, review: r }), identity: true, chatgpt: false, claude: v });
});
Given('the checkout identity is recorded', function () { this.snapshot = snapshot(this); });

When('I run kogen doctor', { timeout: 300000 }, async function () { this.result = await doctor(this, []); });
When('I run kogen doctor with {string}', { timeout: 300000 }, async function (args) { this.result = await doctor(this, args.split(' ')); });
When('I run kogen doctor in text and in JSON form', { timeout: 300000 }, async function () {
  this.result = await doctor(this, []);
  this.json = await doctor(this, ['--json']);
});
When('I apply the fixes the doctor printed', function () {
  git(this, ['config', 'user.name', 'Doctor Fixture']);
  git(this, ['config', 'user.email', 'doctor@example.invalid']);
  const file = path.join(this.repo, '.kogen', 'project.yaml');
  fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('effort: ultra', 'effort: high'));
  git(this, ['commit', '-q', '-am', 'fix effort'], true);
  H.seedCredentials({ home: this.home });
});
When('I run kogen init in a new Git repository with a ChatGPT login', { timeout: 600000 }, async function () {
  const suite = await suiteOnce();
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kdoctor-init-')));
  dirs.push(root);
  const repo = path.join(root, 'repo'), home = path.join(root, 'home');
  for (const d of [repo, home]) fs.mkdirSync(d, { recursive: true });
  const gitconfig = path.join(home, '.gitconfig'); fs.writeFileSync(gitconfig, '');
  const w = { repo, home, gitconfig };
  git(w, ['init', '-q', '--initial-branch=main']);
  git(w, ['config', 'user.name', 'Doctor Fixture']); git(w, ['config', 'user.email', 'doctor@example.invalid']);
  fs.writeFileSync(path.join(repo, 'README.md'), '# Fixture\n'); fs.writeFileSync(path.join(repo, 'app.txt'), 'baseline\n');
  git(w, ['add', '-A']); git(w, ['commit', '-q', '-m', 'baseline'], true);
  H.seedCredentials({ home });
  const server = await new H.FakeProvider([H.fn('submit_configuration', { setup: [], fix: [], checks: [], protect: [] })]).start();
  try {
    const env = { HOME: home, PATH: suite.path, GIT_CONFIG_GLOBAL: gitconfig, GIT_CONFIG_NOSYSTEM: '1', KOGEN_PROVIDER_URL: `http://127.0.0.1:${server.port}`, KOGEN_AUTH_URL: `http://127.0.0.1:${server.port}` };
    const r = await H.run(suite.release, ['init'], { cwd: repo, env });
    this.result = { code: r.code, out: r.out };
  } finally { await server.stop().catch(() => {}); }
});

Then('the doctor exits with status {int}', function (code) { assert.equal(this.result.code, code, this.result.out); });
Then('the doctor output has only check lines and fix lines', function () { parseText(this.result.out, true); });
Then('the doctor checks appear in the order install, git, config, models, commands', function () {
  assert.deepEqual(parseText(this.result.out, true).map(c => c.check), ['install', 'git', 'config', 'models', 'commands']);
});
Then('the {string} line is {string}', function (name, status) { assert.equal(find(this, name).status, status, this.result.out); });
Then('the {string} detail contains {string}', function (name, text) { const c = find(this, name); assert.ok(c.detail.includes(text), `missing ${text} in: ${c.detail}`); });
Then('the {string} fix contains {string}', function (name, text) { const c = find(this, name); assert.ok(c.fix.includes(text), `missing ${text} in fix: ${JSON.stringify(c.fix)}`); });
Then('the {string} line mentions a duration', function (name) { assert.match(find(this, name).detail, /\d+(\.\d+)?(ns|µs|us|ms|s)\b/); });
Then('the {string} line is not {string}', function (name, status) { assert.notEqual(find(this, name).status, status, this.result.out); });
Then('no doctor line is {string}', function (status) { const bad = parseText(this.result.out, true).filter(c => c.status === status); assert.deepEqual(bad, []); });
Then('the JSON output is an array of objects with exactly check, status, detail and fix that equals the text output', function () {
  const arr = JSON.parse(this.json.out);
  assert.ok(Array.isArray(arr));
  const text = parseText(this.result.out, true);
  assert.equal(this.json.code, this.result.code);
  assert.deepEqual(arr.map(o => Object.keys(o).sort()), arr.map(() => ['check', 'detail', 'fix', 'status']));
  assert.deepEqual(arr.map(o => ({ check: o.check, status: o.status, detail: o.detail, fix: o.status === 'fail' ? o.fix : '' })), text);
  assert.ok(arr.some(o => o.status === 'fail' && o.fix !== ''), 'expected failing entries with a fix');
});
Then('the checkout identity is unchanged', function () { assert.deepEqual(snapshot(this), this.snapshot); });
Then('the checkout has no file named {string}', function (name) { assert.equal(fs.existsSync(path.join(this.repo, name)), false, name + ' exists in the checkout'); });
Then('the init command succeeds and its output ends with the doctor summary with the install, git, config and models lines ok and the commands line skip', function () {
  assert.equal(this.result.code, 0, this.result.out);
  const checks = parseText(this.result.out, false);
  assert.deepEqual(checks.map(c => `${c.status} ${c.check}`), ['ok install', 'ok git', 'ok config', 'ok models', 'skip commands'], this.result.out);
  const lines = this.result.out.trimEnd().split('\n');
  assert.match(lines[lines.length - 1], /^(ok|fail|skip) commands - /, 'the summary is the last output');
});

After(function () { for (const d of dirs.splice(0)) fs.rmSync(d, { recursive: true, force: true }); });
AfterAll(async () => { if (sharedSuite) { const s = await sharedSuite; sharedSuite = null; H.cleanupSuite(s); } });
