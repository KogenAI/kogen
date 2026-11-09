const {Given, When, Then, After, setDefaultTimeout} = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const cp = require('node:child_process');
const {hasWorkingRoute} = require('./claude-code-token-route-not-circular__doc/route');
setDefaultTimeout(180000);
const P = 'claude-code-token-route-not-circular: ';
const TOKEN = 'sk-ant-oat01-SYNTHETIC-ROUTE-TOKEN-0000';
const PROVIDER_LINES = ['chatgpt: not signed in', 'supergrok: not signed in', 'opencode-go: not signed in', 'anthropic: not signed in'];
let binary;
function build() {
  if (binary) return;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-ccroute-bin-'));
  binary = path.join(dir, 'kogen');
  const r = cp.spawnSync('go', ['build', '-o', binary, '.'], {cwd: path.resolve('cli'), encoding: 'utf8', timeout: 170000});
  assert.equal(r.status, 0, `go build in cli failed: ${r.stdout}${r.stderr}${r.error || ''}`);
}
function kogen(world, args, input = '') {
  const r = cp.spawnSync(binary, args, {cwd: world.cwd, env: world.env, input, encoding: 'utf8', timeout: 20000});
  assert.ok(!r.error, `kogen ${args.join(' ')}: ${r.error}`);
  return {status: r.status, out: (r.stdout || '') + (r.stderr || ''), stdout: r.stdout || ''};
}
function lines(world) { assert.ok(world.list, 'no provider list was run'); return world.list.stdout.split('\n'); }
function runtimeLine(world) {
  const found = lines(world).filter(l => l.startsWith('claude-code runtime:'));
  assert.equal(found.length, 1, `want exactly one runtime line in:\n${world.list.stdout}`);
  return found[0];
}
function claudeIndex(world) {
  const at = lines(world).map((x, i) => x.startsWith('claude-code: ') ? i : -1).filter(i => i >= 0);
  assert.equal(at.length, 1, `want exactly one claude-code line in:\n${world.list.stdout}`);
  return at[0];
}
Given(P + 'a compiled CLI and a fresh Kogen home', function () {
  build();
  this.sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-ccroute-'));
  this.home = path.join(this.sandbox, 'home'); this.cwd = path.join(this.sandbox, 'cwd');
  fs.mkdirSync(this.home); fs.mkdirSync(this.cwd);
  this.env = {...process.env, HOME: this.home, XDG_CONFIG_HOME: this.home, TMPDIR: this.sandbox, GIT_CONFIG_NOSYSTEM: '1'};
  for (const k of Object.keys(this.env)) if (/TOKEN|API_KEY|PASSWORD|SECRET|^CLAUDE|^ANTHROPIC|^KOGEN_/.test(k)) delete this.env[k];
});
Given(P + 'a Claude Code token is saved with kogen provider login claude-code from standard input', function () {
  const r = kogen(this, ['provider', 'login', 'claude-code'], TOKEN + '\n');
  assert.equal(r.status, 0, r.out); assert.equal(r.out, 'claude-code: token saved (not verified)\n');
});
Given(P + 'Kogen\'s Claude Code runtime file is installed in the home', function () {
  const root = path.join(this.home, '.kogen', 'claude-code');
  this.version = '2.1.318'; this.runtimeFile = path.join(root, this.version, 'claude');
  fs.mkdirSync(path.dirname(this.runtimeFile), {recursive: true}); fs.writeFileSync(this.runtimeFile, '#!/bin/sh\n', {mode: 0o755});
});
When(P + 'I run {string}', function (command) {
  const args = command.split(' '); assert.equal(args[0], 'kogen', command); this.list = kogen(this, args.slice(1));
});
Then(P + 'the exit status is {int}', function (status) { assert.equal(this.list.status, status, this.list.out); });
Then(P + 'the first four lines are the ChatGPT, SuperGrok, OpenCode Go and Anthropic lines', function () { assert.deepEqual(lines(this).slice(0, 4), PROVIDER_LINES, this.list.stdout); });
Then(P + 'the claude-code line is {string} and comes right after the Anthropic line', function (text) { assert.equal(claudeIndex(this), 4, this.list.stdout); assert.equal(lines(this)[4], text, this.list.stdout); });
Then(P + 'the runtime line says not installed and comes right after the claude-code line', function () {
  assert.equal(lines(this).indexOf(runtimeLine(this)), claudeIndex(this) + 1, this.list.stdout);
  assert.equal(runtimeLine(this), 'claude-code runtime: Claude Code 2.1.318 not installed', this.list.stdout);
});
Then(P + 'the runtime line says installed with the home\'s runtime path and comes right after the claude-code line', function () {
  assert.equal(lines(this).indexOf(runtimeLine(this)), claudeIndex(this) + 1, this.list.stdout);
  assert.equal(runtimeLine(this), `claude-code runtime: Claude Code ${this.version} installed (${this.runtimeFile})`, this.list.stdout);
});
Then(P + 'the official compatibility text follows the runtime line', function () { const l = lines(this); assert.equal(l[l.indexOf(runtimeLine(this)) + 1], 'Official compatibility (text/tool input, normal routes only):', this.list.stdout); });
Then(P + 'no line is {string}', function (text) { assert.ok(!lines(this).includes(text), `unexpected line ${JSON.stringify(text)} in:\n${this.list.stdout}`); });
Then(P + 'the home has no Claude Code folder', function () { assert.ok(!fs.existsSync(path.join(this.home, '.kogen', 'claude-code')), 'provider list created Claude Code folder'); });
Then(P + 'the output is JSON without any claude-code login or runtime line', function () {
  const actual = JSON.parse(this.list.stdout);
  const expected = JSON.parse(fs.readFileSync('cli/third_party/kogen-loop/provider/profiles.json', 'utf8'));
  assert.deepEqual(actual, expected, 'provider list --json differs from the existing offline catalog');
});
function doc(name) { return fs.readFileSync(path.join('docs', name), 'utf8'); }
Then(P + 'getting-started gives the working order:', function (expected) { assert.ok(hasWorkingRoute(doc('getting-started.md'), expected.trim()), 'getting-started is missing the exact positive working-order line'); });
Then(P + 'getting-started says the runtime path exists only after a Build or Refine installed it', function () { assert.match(doc('getting-started.md').replace(/\s+/g, ' '), /runtime.{0,200}only after.{0,200}(?:Build|Refine)/i); });
Then(P + 'getting-started no longer tells a fresh install to run setup-token from the runtime', function () {
  const text = doc('getting-started.md'); assert.ok(!text.includes('once the runtime is installed'));
  assert.deepEqual(text.split('\n').filter(l => l.includes('setup-token') && l.includes('CLAUDE_CONFIG_DIR')), []);
});
Then(P + 'the getting-started provider list excerpt has the claude-code lines', function () {
  const m = doc('getting-started.md').match(/```output provider-list\n([\s\S]*?)```/); assert.ok(m, 'provider-list block missing');
  const excerpt = m[1].split('\n').map(l => l.trim());
  assert.ok(excerpt.includes('claude-code: not signed in'), m[1]);
  assert.ok(excerpt.some(l => /^claude-code runtime: Claude Code (\S+|<[a-z]+>) not installed$/.test(l)), m[1]);
});
After(function () { if (this.sandbox) fs.rmSync(this.sandbox, {recursive: true, force: true}); });

Then(P + 'the existing offline pinned runtime lifecycle tests pass', function () {
  const pkg = 'github.com/KogenAI/kogen-executor/executor/claudecode';
  const names = ['TestPinTable', 'TestInstallsThePinnedRuntime', 'TestInstalledRuntimeIsNeverReplaced', 'TestOlderVersionDirectoryIsUntouched'];
  const args = ['test', pkg, '-run', '^Test(PinTable|InstallsThePinnedRuntime|InstalledRuntimeIsNeverReplaced|OlderVersionDirectoryIsUntouched)$', '-count=1', '-v'];
  const r = cp.spawnSync('go', args, {cwd: path.resolve('cli'), encoding: 'utf8', timeout: 170000});
  const output = (r.stdout || '') + (r.stderr || '');
  for (const name of names) {
    const message = `go ${args.join(' ')}: ${name} absent, skipped, or failed; status ${r.status}; ${r.error || ''}\n${output}`;
    assert.equal(r.status, 0, message);
    assert.ok(output.split('\n').some(line => line.startsWith('--- PASS: ' + name + ' (')), message);
  }
  assert.match(output, /^PASS$/m, `go ${args.join(' ')} missing PASS; status ${r.status}\n${output}`);
});

Then(P + 'the unrelated getting-started guide content is preserved', function () {
  const baseline = fs.readFileSync('.kogen/intents/claude-code-token-route-not-circular/guide-baseline.md', 'utf8');
  const oldRoute = /Without an own Claude Code, make the token with [^\n]*?once the runtime is installed\. /;
  const parts = baseline.split(oldRoute);
  assert.equal(parts.length, 2, 'baseline circular instruction missing');
  const login = parts[1].split('## 3. Log in\n\n');
  assert.equal(login.length, 2, 'baseline login heading missing');
  const listing = login[1].split(/```output provider-list\n[\s\S]*?```/);
  assert.equal(listing.length, 2, 'baseline list excerpt missing');
  const chunks = [parts[0], login[0] + '## 3. Log in\n\n', listing[0], listing[1]];
  const current = doc('getting-started.md'); let from = 0;
  for (const chunk of chunks) {
    const at = current.indexOf(chunk, from);
    assert.ok(at >= 0, 'unrelated getting-started content changed or reordered');
    from = at + chunk.length;
  }
});

Then(P + 'the installed runtime file remains unchanged', function () {
  assert.ok(fs.existsSync(this.runtimeFile), 'provider list removed the installed runtime');
  assert.equal(fs.readFileSync(this.runtimeFile, 'utf8'), '#!/bin/sh\n', 'provider list replaced the installed runtime');
  assert.equal(fs.statSync(this.runtimeFile).mode & 0o777, 0o755, 'provider list changed runtime permissions');
});
