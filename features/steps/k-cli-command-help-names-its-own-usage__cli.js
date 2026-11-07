const {Given, When, Then, After, setDefaultTimeout} = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const cp = require('node:child_process');
setDefaultTimeout(120000);
let binary;
const prefix = 'k-cli-command-help-names-its-own-usage: ';
function snapshot(root) {
  const out = {};
  function walk(dir) {
    for (const name of fs.readdirSync(dir).sort()) {
      const p = path.join(dir, name), s = fs.lstatSync(p), rel = path.relative(root, p);
      out[rel] = s.isDirectory() ? ['dir', s.mode] : ['file', s.mode, fs.readFileSync(p).toString('base64'), s.mtimeMs];
      if (s.isDirectory()) walk(p);
    }
  }
  walk(root); return out;
}
Given(prefix + 'a compiled CLI and an isolated non-Git directory', function () {
  this.sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-help-'));
  if (!binary) {
    binary = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-help-bin-')), 'kogen');
    const r = cp.spawnSync('go', ['build', '-o', binary, '.'], {cwd: path.resolve('cli'), encoding: 'utf8', timeout: 110000});
    assert.equal(r.status, 0, `go build: ${r.stdout}${r.stderr}`);
  }
  for (const name of ['cwd', 'home', 'tmp', 'bin']) fs.mkdirSync(path.join(this.sandbox, name));
  fs.writeFileSync(path.join(this.sandbox, 'cwd', 'sentinel'), 'unchanged\n');
  this.env = {...process.env, HOME: path.join(this.sandbox, 'home'), XDG_CONFIG_HOME: path.join(this.sandbox, 'home'), TMPDIR: path.join(this.sandbox, 'tmp'), PATH: path.join(this.sandbox, 'bin'), GIT_CONFIG_NOSYSTEM: '1'};
  for (const key of Object.keys(this.env)) if (/TOKEN|API_KEY|PASSWORD|SECRET/.test(key)) delete this.env[key];
  this.before = snapshot(this.sandbox);
});
When(prefix + 'I run {string}', function (args) {
  this.result = cp.spawnSync(binary, args.split(' '), {cwd: path.join(this.sandbox, 'cwd'), env: this.env, encoding: 'utf8', timeout: 10000});
  this.output = (this.result.stdout || '') + (this.result.stderr || '');
});
Then(prefix + 'the exit status is {int}', function (status) { assert.equal(this.result.status, status, this.output + String(this.result.error || '')); });
Then(prefix + 'the first line names {string}', function (command) { assert.match(this.output.split('\n')[0], new RegExp('^Usage: kogen ' + command.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '(?: |$)'), this.output); });
Then(prefix + 'the help contains {string}', function (text) { assert.ok(this.output.toLowerCase().includes(text.toLowerCase()), `Missing ${text}: ${this.output}`); });
Then(prefix + 'the sandbox is unchanged', function () { assert.deepEqual(snapshot(this.sandbox), this.before); });
Then(prefix + 'the global command list is printed', function () { assert.ok(this.output.includes('Commands:\n  context    Read checkout-local facts (JSON)\n'), this.output); });
Then(prefix + 'the unknown flag is refused', function () { assert.equal(this.result.status, 2, this.output); });
After(function () { if (this.sandbox) fs.rmSync(this.sandbox, {recursive: true, force: true}); });
