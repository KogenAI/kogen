'use strict';
// Drives a freshly built kogen binary. Interactive runs use a pseudo terminal through the
// python3 helper next to this file; non-interactive runs pipe stdin. No network, no model.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, When, Then } = require('@cucumber/cucumber');

const ROOT = path.resolve(__dirname, '../..');
const DRIVER = path.join(__dirname, 'onboarding-account-first__driver', 'pty_run.py');
const QUESTION = 'Which account do you want to use?';
const LABELS = ['ChatGPT', 'Claude subscription', 'Anthropic API key', 'SuperGrok', 'OpenCode Go', 'QwenCloud', 'Advanced setup'];
const TOKEN_URL = 'https://token-plan.maas.qwencloudapi.com/compatible-mode/v1';
const SG_URL = 'https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1';
const FAKE_KEY = 'sk-fake-onboarding-0123456789';
const MODELS = 'models:\n  shape:\n    provider: chatgpt\n    model: gpt-6.1-sol\n    effort: low\n  build:\n    provider: chatgpt\n    model: gpt-6.1-terra\n    effort: high\n  review:\n    provider: chatgpt\n    model: gpt-6.1-terra\n    effort: medium\n';
const MENU_END = '^.*Advanced setup[^\\n]*\\n';
const PLAN_END = '^.*Pay-as-you-go[^\\n]*\\n';
const ENDPOINT_END = '^.*Chat Completions[^\\n]*\\n';

let built;
function kogenBinary() {
  if (!built) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'oaf-bin-'));
    const out = path.join(dir, 'kogen');
    const r = spawnSync('go', ['build', '-o', out, '.'], { cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 100000 });
    assert.equal(r.status, 0, 'go build of cli failed: ' + r.stdout + r.stderr);
    built = out;
  }
  return built;
}

const credFile = w => path.join(w.home, '.kogen', 'credentials', 'openai-compatible.json');
const modelsFile = w => path.join(w.project, '.kogen', 'models.yaml');

function runPty(w, args, steps) {
  const r = spawnSync('python3', ['-I', DRIVER, kogenBinary(), w.project, w.home, JSON.stringify(steps), JSON.stringify(args)], { encoding: 'utf8', timeout: 100000 });
  assert.equal(r.status, 0, 'pty driver failed: ' + r.stdout + r.stderr);
  const got = JSON.parse(r.stdout);
  w.out = got.output;
  w.exit = got.exit;
  w.failed = got.failed;
}

Given('onboarding-account-first: a project with a lineup file and an empty home', { timeout: 110000 }, function () {
  kogenBinary();
  this.project = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'oaf-project-')));
  this.home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'oaf-home-')));
  spawnSync('git', ['init', '-q'], { cwd: this.project });
  fs.mkdirSync(path.join(this.project, '.kogen'));
  fs.writeFileSync(modelsFile(this), MODELS);
});

When('onboarding-account-first: I run kogen provider login on a simulated terminal and stop at the choices', { timeout: 110000 }, function () {
  runPty(this, ['provider', 'login'], [[MENU_END, null]]);
});

When('onboarding-account-first: I run kogen provider login with piped empty input', { timeout: 110000 }, function () {
  const r = spawnSync(kogenBinary(), ['provider', 'login'], { cwd: this.project, input: '', encoding: 'utf8', timeout: 30000, env: { ...process.env, HOME: this.home } });
  this.pipedOut = (r.stdout || '') + (r.stderr || '');
  this.pipedExit = r.status;
});

When('onboarding-account-first: I choose QwenCloud then {string} with the fake key and answer {string} to the confirmation', { timeout: 110000 }, function (plan, answer) {
  runPty(this, ['provider', 'login'], [[MENU_END, '@choice:QwenCloud'], [PLAN_END, '@choice:' + plan], ['API key:', FAKE_KEY], ['\\[y/N\\]', answer]]);
});

When('onboarding-account-first: I choose Advanced setup then Chat Completions with a base URL and the fake key', { timeout: 110000 }, function () {
  runPty(this, ['provider', 'login'], [[MENU_END, '@choice:Advanced setup'], [ENDPOINT_END, '@choice:Chat Completions'], ['Base URL:', 'https://example.com/v1'], ['API key:', FAKE_KEY]]);
});

When('onboarding-account-first: I run kogen provider login openai-compatible with a piped base URL and key', { timeout: 110000 }, function () {
  const r = spawnSync(kogenBinary(), ['provider', 'login', 'openai-compatible'], { cwd: this.project, input: 'https://example.com/v1\n' + FAKE_KEY + '\n', encoding: 'utf8', timeout: 30000, env: { ...process.env, HOME: this.home } });
  this.out = (r.stdout || '') + (r.stderr || '');
  this.exit = r.status;
});

function assertMenu(w) {
  assert.equal(w.failed, null, 'driver: ' + w.failed + '\n' + w.out);
  let at = w.out.indexOf(QUESTION);
  assert.ok(at >= 0, 'question missing in: ' + w.out);
  for (const label of LABELS) {
    const next = w.out.indexOf(label, at);
    assert.ok(next >= 0, 'choice ' + label + ' missing or out of order in: ' + w.out);
    at = next + label.length;
  }
}

Then('onboarding-account-first: the question and the seven choices appear in order', function () {
  assertMenu(this);
});

Then('onboarding-account-first: the terminal run asked the question and the piped run exited 2 with usage text and no prompt', function () {
  assertMenu(this);
  assert.equal(this.pipedExit, 2, this.pipedOut);
  assert.ok(!this.pipedOut.includes(QUESTION), 'prompted on non-interactive input: ' + this.pipedOut);
  assert.ok(!LABELS.every(l => this.pipedOut.includes(l)), 'choices listed on non-interactive input: ' + this.pipedOut);
  assert.match(this.pipedOut, /usage|Usage/, this.pipedOut);
});

Then('onboarding-account-first: the Token Plan automation warning is printed exactly once', function () {
  assert.equal(this.failed, null, 'driver: ' + this.failed + '\n' + this.out);
  assert.match(this.out, /terms restrict automation and non-interactive batch use/);
  assert.match(this.out, /pay-as-you-go suits unattended loops/);
  assert.equal(this.out.split(/terms restrict automation/).length - 1, 1, this.out);
});

Then('onboarding-account-first: no automation warning is printed', function () {
  assert.equal(this.failed, null, 'driver: ' + this.failed + '\n' + this.out);
  assert.ok(!/restrict automation|non-interactive batch/.test(this.out), this.out);
});

Then('onboarding-account-first: the experimental label is printed', function () {
  assert.ok(this.out.includes('experimental: Build verified with Claude Review; Shape and Review not qualified'), this.out);
});

Then('onboarding-account-first: the lineup preview names {string} with qwen4-max and effort high before the confirmation prompt', function (url) {
  const preview = this.out.indexOf('qwen4-max');
  const prompt = this.out.search(/\[y\/N\]/);
  assert.ok(preview >= 0 && prompt >= 0 && preview < prompt, 'preview must precede the confirmation: ' + this.out);
  const shown = this.out.slice(0, prompt);
  assert.ok(shown.includes(url), 'base URL missing from preview: ' + this.out);
  assert.match(shown, /high/);
  const other = url === TOKEN_URL ? SG_URL : TOKEN_URL;
  assert.ok(!this.out.includes(other), 'other base URL shown: ' + this.out);
});

Then('onboarding-account-first: the key never appears in the output', function () {
  assert.ok(!this.out.includes(FAKE_KEY), 'key echoed: ' + this.out);
});

Then('onboarding-account-first: an openai-compatible login bound to {string} is saved', function (origin) {
  assert.ok(fs.existsSync(credFile(this)), 'no credential file; output: ' + this.out);
  assert.ok(fs.readFileSync(credFile(this), 'utf8').includes(origin), 'login not bound to ' + origin);
});

Then('onboarding-account-first: models.yaml has the build role {string}, qwen4-max, effort high and the same shape and review', function (url) {
  const text = fs.readFileSync(modelsFile(this), 'utf8');
  const from = text.indexOf('build:');
  assert.ok(from >= 0, text);
  const rest = text.slice(from);
  const stop = rest.search(/review:/);
  const build = stop > 0 && rest.indexOf('shape:') < 0 ? rest.slice(0, stop) : rest;
  assert.match(build, /openai-compatible/);
  assert.ok(build.includes(url), text);
  assert.match(build, /qwen4-max/);
  assert.match(build, /effort:\s*high/);
  assert.match(text, /shape:\s*\n\s*provider: chatgpt\s*\n\s*model: gpt-6\.1-sol\s*\n\s*effort: low/);
  assert.match(text, /review:\s*\n\s*provider: chatgpt\s*\n\s*model: gpt-6\.1-terra\s*\n\s*effort: medium/);
});

Then('onboarding-account-first: no credential file exists and models.yaml is unchanged', function () {
  assert.equal(this.failed, null, 'driver: ' + this.failed + '\n' + this.out);
  assert.ok(this.out.includes(QUESTION), 'the account question was never shown: ' + this.out);
  assert.ok(!fs.existsSync(credFile(this)), 'credential saved without confirmation');
  assert.equal(fs.readFileSync(modelsFile(this), 'utf8'), MODELS);
});

Then('onboarding-account-first: the Base URL and API key prompts appear and only Chat Completions is offered', function () {
  assert.equal(this.failed, null, 'driver: ' + this.failed + '\n' + this.out);
  assert.match(this.out, /Chat Completions/);
  assert.ok(!/Messages/.test(this.out), 'Messages offered although no messages-compatible login exists: ' + this.out);
  assert.ok(this.out.indexOf('Base URL:') >= 0 && this.out.indexOf('API key:') > this.out.indexOf('Base URL:'), this.out);
});

Then('onboarding-account-first: the run exits 0, prompts for the base URL and key without a menu, and saves the login for {string}', function (origin) {
  assert.equal(this.exit, 0, this.out);
  assert.ok(!this.out.includes(QUESTION), this.out);
  assert.ok(this.out.includes('Base URL:') && this.out.includes('API key:'), this.out);
  assert.ok(!this.out.includes(FAKE_KEY), 'key echoed');
  assert.ok(fs.readFileSync(credFile(this), 'utf8').includes(origin));
});

Then('onboarding-account-first: models.yaml is unchanged', function () {
  assert.equal(fs.readFileSync(modelsFile(this), 'utf8'), MODELS);
});

Then('onboarding-account-first: the getting-started provider section starts with the question and the seven choices in order', function () {
  const doc = fs.readFileSync(path.join(ROOT, 'docs', 'getting-started.md'), 'utf8');
  const from = doc.indexOf('## 2. Sign in');
  assert.ok(from >= 0, 'section heading missing');
  const next = doc.indexOf('\n## ', from + 5);
  const section = doc.slice(from, next < 0 ? doc.length : next);
  const q = section.indexOf(QUESTION);
  assert.ok(q >= 0, 'question missing from the provider section');
  assert.ok(q < section.indexOf('kogen provider login'), 'question must come before the first command');
  let at = q;
  for (const label of LABELS) {
    const i = section.indexOf(label, at);
    assert.ok(i >= 0, 'label ' + label + ' missing or out of order in the provider section');
    at = i + label.length;
  }
});
