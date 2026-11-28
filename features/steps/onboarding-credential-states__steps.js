'use strict';
// Drives a freshly built kogen binary against a local fixture server. The binary is laid out like an
// installation (<tmp>/lib/kogen/bin/kogen with <tmp>/lib/kogen/docs/providers.md beside it) so it
// finds the docs it ships with. The saved key is written the way the login stores it, bound to the
// fixture's origin. No network beyond 127.0.0.1 and no model is used.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { Given, When, Then, After } = require('@cucumber/cucumber');

const ROOT = path.resolve(__dirname, '../..');
const FAKE_KEY = 'sk-fake-credential-states-0123456789';
const MODEL = 'qwen4-max';
const TIME_RE = /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/;
const LABELS = ['key saved', 'connection tested', 'role verified'];
const MODELS = (base) => 'models:\n  shape:\n    provider: chatgpt\n    model: gpt-6.1-sol\n    effort: low\n  build:\n    provider: openai-compatible\n    model: ' + MODEL + '\n    effort: high\n    base_url: ' + base + '\n  review:\n    provider: chatgpt\n    model: gpt-6.1-terra\n    effort: medium\n';

let installed;
function kogenBinary() {
  if (!installed) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ocs-install-'));
    fs.mkdirSync(path.join(dir, 'lib', 'kogen', 'bin'), { recursive: true });
    fs.mkdirSync(path.join(dir, 'lib', 'kogen', 'docs'), { recursive: true });
    fs.copyFileSync(path.join(ROOT, 'docs', 'providers.md'), path.join(dir, 'lib', 'kogen', 'docs', 'providers.md'));
    const out = path.join(dir, 'lib', 'kogen', 'bin', 'kogen');
    const r = spawnSync('go', ['build', '-o', out, '.'], { cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 100000 });
    assert.equal(r.status, 0, 'go build of cli failed: ' + r.stdout + r.stderr);
    installed = out;
  }
  return installed;
}

const servers = [];
After(async function () {
  while (servers.length) {
    const s = servers.pop();
    await new Promise((resolve) => {
      s.close(() => resolve());
      s.closeAllConnections();
    });
  }
});

function completionChunks() {
  return [
    { id: 'chatcmpl-fixture', object: 'chat.completion.chunk', model: MODEL, choices: [{ index: 0, delta: { role: 'assistant', content: 'ok' }, finish_reason: null }] },
    { id: 'chatcmpl-fixture', object: 'chat.completion.chunk', model: MODEL, choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] },
  ];
}

function startFixture(world, mode) {
  world.mode = mode;
  world.requests = [];
  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => (raw += c));
    req.on('end', () => {
      let body = null;
      try { body = JSON.parse(raw); } catch (e) { body = null; }
      world.requests.push({ method: req.method, url: req.url, auth: req.headers.authorization || '', body });
      if (req.method !== 'POST' || !req.url.endsWith('/chat/completions')) {
        res.writeHead(404, { 'content-type': 'application/json' });
        res.end('{"error":"not found"}');
        return;
      }
      if (world.mode === 'silent') return; // never answers; the server closes the connection after the scenario
      if (world.mode === '401') {
        res.writeHead(401, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { message: 'Incorrect API key provided: ' + FAKE_KEY, type: 'invalid_request_error', code: 'invalid_api_key' } }));
        return;
      }
      if (body && body.stream === true) {
        res.writeHead(200, { 'content-type': 'text/event-stream' });
        for (const c of completionChunks()) res.write('data: ' + JSON.stringify(c) + '\n\n');
        res.end('data: [DONE]\n\n');
      } else {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ id: 'chatcmpl-fixture', object: 'chat.completion', model: MODEL, choices: [{ index: 0, message: { role: 'assistant', content: 'ok' }, finish_reason: 'stop' }], usage: { prompt_tokens: 3, completion_tokens: 1, total_tokens: 4 } }));
      }
    });
  });
  servers.push(server);
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => {
    world.origin = 'http://127.0.0.1:' + server.address().port;
    resolve();
  }));
}

Given('onboarding-credential-states: a fixture OpenAI-compatible server that answers every chat request with a completion', { timeout: 110000 }, async function () {
  kogenBinary();
  await startFixture(this, 'ok');
});

Given('onboarding-credential-states: a fixture OpenAI-compatible server that never sends its first byte', { timeout: 110000 }, async function () {
  kogenBinary();
  await startFixture(this, 'silent');
});

Given('onboarding-credential-states: the fixture now answers every request with HTTP 401 and a body that echoes the key', function () {
  this.mode = '401';
  this.requests = [];
});

function listFiles(dir) {
  const out = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      if (e.name === '.git') continue;
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p); else out.push(path.relative(dir, p) + ':' + fs.readFileSync(p, 'utf8'));
    }
  };
  walk(dir);
  return out.sort();
}

Given('onboarding-credential-states: a project whose QwenCloud build role uses the fixture, with a saved fake key', function () {
  this.project = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'ocs-project-')));
  this.home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'ocs-home-')));
  spawnSync('git', ['init', '-q'], { cwd: this.project });
  fs.mkdirSync(path.join(this.project, '.kogen'));
  fs.copyFileSync(path.join(ROOT, '.kogen', 'project.yaml'), path.join(this.project, '.kogen', 'project.yaml'));
  fs.writeFileSync(path.join(this.project, '.kogen', 'models.yaml'), MODELS(this.origin + '/v1'));
  const cred = path.join(this.home, '.kogen', 'credentials');
  fs.mkdirSync(cred, { recursive: true, mode: 0o700 });
  fs.writeFileSync(path.join(cred, 'openai-compatible.json'), JSON.stringify({ provider: 'openai-compatible', api_key: FAKE_KEY, origin: this.origin }), { mode: 0o600 });
  this.projectBefore = listFiles(this.project);
  this.outputs = [];
});

function runKogen(world, args, limitMs) {
  return new Promise((resolve) => {
    const started = Date.now();
    const child = spawn(kogenBinary(), args, { cwd: world.project, env: { ...process.env, HOME: world.home }, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    child.stdout.on('data', (c) => (out += c));
    child.stderr.on('data', (c) => (out += c));
    let killed = false;
    const t = setTimeout(() => { killed = true; child.kill('SIGKILL'); }, limitMs);
    child.on('close', (code) => {
      clearTimeout(t);
      world.out = out;
      world.exit = code;
      world.killed = killed;
      world.elapsedMs = Date.now() - started;
      world.outputs.push(out);
      resolve();
    });
  });
}

// The harness gives a step 120 seconds, so a command that has not ended by itself after 60 seconds hangs.
When('onboarding-credential-states: I run kogen provider test openai-compatible', { timeout: 110000 }, async function () {
  await runKogen(this, ['provider', 'test', 'openai-compatible'], 60000);
});

When('onboarding-credential-states: I run kogen provider list', { timeout: 110000 }, async function () {
  await runKogen(this, ['provider', 'list'], 60000);
});

Then('onboarding-credential-states: the command succeeds and prints connection tested with a time', function () {
  assert.equal(this.exit, 0, 'provider test exited ' + this.exit + ': ' + this.out);
  const line = this.out.split('\n').find((l) => l.includes('connection tested'));
  assert.ok(line, 'no connection tested line in: ' + this.out);
  assert.match(line, TIME_RE, 'connection tested line has no time: ' + line);
});

Then('onboarding-credential-states: the fixture received exactly one minimal streaming request carrying the fake key and no tools', function () {
  assert.equal(this.requests.length, 1, 'requests received: ' + JSON.stringify(this.requests));
  const r = this.requests[0];
  assert.equal(r.auth, 'Bearer ' + FAKE_KEY);
  assert.ok(r.body && typeof r.body === 'object', 'request body is not JSON');
  assert.equal(r.body.stream, true, 'the request does not stream');
  assert.ok(!('tools' in r.body) && !('functions' in r.body) && !('tool_choice' in r.body), 'the request carries tools: ' + JSON.stringify(r.body));
  assert.ok(Array.isArray(r.body.messages) && r.body.messages.length === 1 && r.body.messages[0].role === 'user', 'expected one user prompt: ' + JSON.stringify(r.body.messages));
  assert.ok(typeof r.body.messages[0].content === 'string' && r.body.messages[0].content.trim() !== '', 'the prompt is empty: ' + JSON.stringify(r.body.messages));
  const ceiling = r.body.max_tokens !== undefined ? r.body.max_tokens : r.body.max_completion_tokens;
  assert.ok(Number.isInteger(ceiling) && ceiling > 0, 'the request has no output ceiling: ' + JSON.stringify(r.body));
});

Then('onboarding-credential-states: the result is recorded outside the project and the project files are unchanged', function () {
  assert.deepEqual(listFiles(this.project), this.projectBefore, 'the project changed');
  const dir = path.join(this.home, '.kogen', 'credentials');
  const time = this.out.match(TIME_RE)[0];
  const records = fs.readdirSync(dir).filter((n) => n !== 'openai-compatible.json' && !n.endsWith('.lock'));
  assert.ok(records.length >= 1, 'no record next to the credential in ' + dir);
  assert.ok(records.some((n) => fs.readFileSync(path.join(dir, n), 'utf8').includes(time)), 'no record names the time ' + time);
  for (const n of fs.readdirSync(dir)) {
    if (n === 'openai-compatible.json') continue;
    assert.ok(!fs.readFileSync(path.join(dir, n), 'utf8').includes(FAKE_KEY), 'the key is written to ' + n);
  }
});

// The role line is the list line that names the build role and its model; the provider lines are the
// other lines that name the provider (the existing status line included).
function roleLine(out) {
  const line = out.split('\n').find((l) => /\bbuild\b/.test(l) && l.includes(MODEL));
  assert.ok(line, 'no list line names the build role and ' + MODEL + ' in: ' + out);
  return line;
}

function providerLines(out) {
  const lines = out.split('\n').filter((l) => l.includes('openai-compatible') && !l.includes(MODEL));
  assert.ok(lines.length > 0, 'no list line names openai-compatible in: ' + out);
  return lines;
}

Then('onboarding-credential-states: the openai-compatible provider shows key saved and connection tested', function () {
  const lines = providerLines(this.out);
  const line = lines.find((l) => l.includes('key saved') && l.includes('connection tested'));
  assert.ok(line, 'no provider line shows both states in: ' + lines.join('\n'));
  assert.match(line, TIME_RE, line);
  assert.ok(!line.includes('role verified'), line);
});

Then('onboarding-credential-states: the build role shows key saved and connection tested but not role verified', function () {
  const line = roleLine(this.out);
  assert.ok(line.includes('key saved') && line.includes('connection tested'), line);
  assert.ok(!line.includes('role verified'), line);
});

Then('onboarding-credential-states: the openai-compatible provider shows key saved but not connection tested', function () {
  const lines = providerLines(this.out);
  assert.ok(lines.some((l) => l.includes('key saved')), 'no provider line shows key saved in: ' + lines.join('\n'));
  assert.ok(lines.every((l) => !l.includes('connection tested')), 'a provider line still shows connection tested: ' + lines.join('\n'));
});

Then('onboarding-credential-states: the build role shows key saved but not connection tested', function () {
  const line = roleLine(this.out);
  assert.ok(line.includes('key saved'), line);
  assert.ok(!line.includes('connection tested') && !line.includes('role verified'), line);
});

Then('onboarding-credential-states: the fake key appears nowhere in the output', function () {
  for (const out of this.outputs) assert.ok(!out.includes(FAKE_KEY), 'the key is printed in: ' + out);
});

Then('onboarding-credential-states: the command fails and prints the auth failure class', function () {
  assert.notEqual(this.exit, 0, 'the command succeeded: ' + this.out);
  assert.ok(/\bauth\b/.test(this.out), 'no auth class in: ' + this.out);
  assert.ok(!this.out.includes('connection tested'), 'a failed test prints connection tested: ' + this.out);
  assert.equal(this.requests.length, 1, 'requests received: ' + JSON.stringify(this.requests));
});

Then('onboarding-credential-states: the command ends by itself while the fixture still withholds its first byte, fails and prints the timeout failure class', function () {
  assert.equal(this.requests.length, 1, 'the fixture received ' + this.requests.length + ' requests: ' + this.out);
  assert.ok(!this.killed, 'the command hung and was killed after ' + this.elapsedMs + ' ms: ' + this.out);
  assert.notEqual(this.exit, 0, 'the command succeeded: ' + this.out);
  assert.ok(/\btimeout\b/.test(this.out), 'no timeout class in: ' + this.out);
  assert.ok(!this.out.includes('connection tested'), 'a failed test prints connection tested: ' + this.out);
});

function docDefinitions() {
  const text = fs.readFileSync(path.join(ROOT, 'docs', 'providers.md'), 'utf8');
  const parts = text.split(/^## /m).slice(1);
  const section = parts.find((s) => /^(Credential states|State labels)\s*$/.test(s.split('\n')[0]));
  assert.ok(section, 'docs/providers.md has no "## Credential states" section');
  return [...section.matchAll(/^- `([^`]+)` means (.+)$/gm)].map((x) => ({ label: x[1], sentence: x[2] }));
}

Then('onboarding-credential-states: the CLI output contains the three labels key saved, connection tested and role verified exactly', function () {
  const all = this.outputs.join('\n');
  for (const label of LABELS) {
    assert.ok(all.includes(label), 'the CLI output never prints "' + label + '": ' + all);
    // Another capitalization or spelling of the label is a different label.
    const variants = all.match(new RegExp(label.replace(/ /g, '\\s+'), 'gi')) || [];
    for (const v of variants) assert.equal(v, label, 'the CLI prints "' + v + '" for the label "' + label + '"');
  }
});

Then('onboarding-credential-states: the labels defined in the state labels section of docs\\/providers.md are identical to the labels printed by the CLI', function () {
  const defs = docDefinitions().map((d) => d.label);
  assert.deepEqual(defs, LABELS, 'docs label order or wording');
  const all = this.outputs.join('\n');
  for (const label of defs) assert.ok(all.includes(label), 'the CLI output does not print the docs label "' + label + '"');
});

Then('onboarding-credential-states: each definition in docs\\/providers.md is one sentence', function () {
  const defs = docDefinitions();
  assert.equal(defs.length, 3);
  for (const d of defs) {
    // The file name providers.md holds a full stop that does not end a sentence.
    const s = d.sentence.trim().split('providers.md').join('providers_md');
    assert.ok(s.endsWith('.') && !/[.!?]/.test(s.slice(0, -1)), 'not one sentence: ' + d.sentence);
  }
  const by = Object.fromEntries(defs.map((d) => [d.label, d.sentence]));
  assert.match(by['key saved'], /credential is stored locally/);
  assert.match(by['connection tested'], /minimal request/);
  assert.match(by['connection tested'], /endpoint/);
  assert.match(by['connection tested'], /recorded time/);
  assert.match(by['role verified'], /qualification record/);
  assert.match(by['role verified'], /docs\/providers\.md/);
});
