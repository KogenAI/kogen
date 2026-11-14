const { Given, When, Then } = require('@cucumber/cucumber');
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const repo = process.cwd();
let bin;
let state = {};

function build() {
  if (bin) return bin;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'k-cmlogin-bin-'));
  bin = path.join(dir, 'kogen');
  const r = spawnSync('go', ['build', '-o', bin, '.'], { cwd: path.join(repo, 'cli'), encoding: 'utf8' });
  assert.equal(r.status, 0, `go build in cli failed: ${r.stdout}${r.stderr}${r.error || ''}`);
  return bin;
}

Given('k-claude-managed-login: a fresh home', function () {
  state = { home: fs.mkdtempSync(path.join(os.tmpdir(), 'k-cmlogin-home-')) };
});

When('k-claude-managed-login: the token {string} is piped to provider login claude-code', function (token) {
  state.run = spawnSync(build(), ['provider', 'login', 'claude-code'], {
    input: token, encoding: 'utf8', timeout: 60000,
    env: { ...process.env, HOME: state.home },
  });
});

Then('k-claude-managed-login: the login exits 0', function () {
  assert.equal(state.run.status, 0, `exit ${state.run.status}: ${state.run.stdout}${state.run.stderr}`);
});

Then('k-claude-managed-login: the claude-code credential file holds {string} with mode 600', function (token) {
  const p = path.join(state.home, '.kogen', 'credentials', 'claude-code.json');
  assert.ok(fs.existsSync(p), `missing ${p}: ${state.run.stdout}${state.run.stderr}`);
  assert.equal(fs.statSync(p).mode & 0o777, 0o600);
  assert.ok(fs.readFileSync(p, 'utf8').includes(token), 'token not stored');
});

Then('k-claude-managed-login: no Claude Code runtime directory exists in the home', function () {
  const p = path.join(state.home, '.kogen', 'claude-code');
  assert.ok(!fs.existsSync(p), `${p} was created`);
});

function help() {
  const r = spawnSync(build(), ['provider', 'login', '--help'], { encoding: 'utf8', timeout: 60000, env: { ...process.env, HOME: state.home || os.tmpdir() } });
  assert.equal(r.status, 0, `${r.stdout}${r.stderr}`);
  return r.stdout + r.stderr;
}

Then('k-claude-managed-login: the login help mentions an interactive terminal sign-in and piped storage only', function () {
  const h = help().toLowerCase();
  assert.ok(h.includes('interactive terminal'), h);
  assert.ok(h.includes('piped'), h);
  assert.ok(h.includes('storage only'), h);
});

Then('k-claude-managed-login: the login help does not contain {string}', function (text) {
  assert.ok(!help().includes(text), `help still contains ${text}`);
});

Then('k-claude-managed-login: docs\\/getting-started.md describes the interactive sign-in and does not contain {string}', function (text) {
  const d = fs.readFileSync(path.join(repo, 'docs', 'getting-started.md'), 'utf8');
  assert.ok(!d.includes(text), `docs still contain ${text}`);
  assert.ok(d.toLowerCase().includes('interactive terminal'), 'docs lack interactive terminal sign-in');
  assert.ok(/storage only/i.test(d), 'docs lack storage-only piped note');
});

Then('k-claude-managed-login: cli\\/go.mod and cli\\/go.sum are unchanged from HEAD', function () {
  const r = spawnSync('git', ['diff', 'HEAD', '--exit-code', '--', 'cli/go.mod', 'cli/go.sum'], { cwd: repo, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stdout + r.stderr);
});
