'use strict';
// Shared driver support for the accumulated Intent suites: it installs a packaged Kogen (the one Go program) into a
// private prefix and drives it the way a person would: the `kogen` command, files on disk, a scripted local provider.
// It defines no steps. It replaces the old ExUnit helpers (Kogen.Integration.Helpers and FakeProvider) one for one.
//
// Environment: KOGEN_ARCHIVE may name an existing release archive; otherwise the suite packages the checkout with
// `sh packaging/package.sh` once per run. Nothing here contacts a real provider or reads real credentials.

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const MIN = 60000;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const sha = x => crypto.createHash('sha256').update(x).digest('hex');
const shellQuote = s => `'${String(s).replaceAll("'", "'\\''")}'`;

// ------------------------------------------------------------------ processes

let work;
const groups = new Set();
function killGroup(pid) { if (pid) { try { process.kill(-pid, 'SIGKILL'); } catch {} } }
process.on('exit', () => { for (const pid of groups) killGroup(pid); if (work && !process.env.KOGEN_GM_KEEP) { try { fs.rmSync(work, { recursive: true, force: true }); } catch {} } });

function spawnProcess(file, args, { cwd = ROOT, env = process.env, input, timeout = 4 * MIN } = {}) {
  const child = spawn(file, args, { cwd, env, detached: true, stdio: [input === undefined ? 'ignore' : 'pipe', 'pipe', 'pipe'] });
  const pid = child.pid;
  if (pid) groups.add(pid);
  let out = '';
  let timed = false;
  const listeners = [];
  const feed = b => { out += b; for (const l of listeners.slice()) l(); };
  // Decode as a stream so a multibyte character split between two chunks is not corrupted.
  child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
  child.stdout.on('data', feed); child.stderr.on('data', feed);
  if (input !== undefined) { child.stdin.on('error', () => {}); child.stdin.end(input); }
  const timer = setTimeout(() => { timed = true; killGroup(pid); }, timeout);
  const done = new Promise((resolve, reject) => {
    child.once('error', e => { clearTimeout(timer); reject(new Error(`cannot start ${file}: ${e.message}`)); });
    child.once('close', (code, signal) => { clearTimeout(timer); groups.delete(pid); killGroup(pid); resolve({ out, code, signal, timed }); });
  });
  return { child, pid, done, output: () => out, onData: l => listeners.push(l) };
}
async function run(file, args, options) { const h = spawnProcess(file, args, options); return h.done; }
async function checked(file, args, options) {
  const r = await run(file, args, options);
  assert.equal(r.code, 0, `${file} ${args.join(' ')} failed (${r.code}): ${r.out}`);
  return r.out;
}

// ------------------------------------------------------------------ the shared archive and install template

const workDir = () => { if (!work) work = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-go-suite-'))); return work; };
const cache = new Map();
const once = (key, make) => { if (!cache.has(key)) cache.set(key, make()); return cache.get(key); };

function cucumberPaths() {
  const nodeModules = path.join(ROOT, 'test/acceptance/node_modules');
  return { node: process.execPath, nodeModules, cucumber: path.join(nodeModules, '@cucumber/cucumber/bin/cucumber.js') };
}
const archive = () => once('archive', async () => {
  const have = cucumberPaths();
  if (!fs.existsSync(have.cucumber)) await checked('npm', ['ci', '--no-audit', '--no-fund', '--silent'], { cwd: path.join(ROOT, 'test/acceptance'), timeout: 10 * MIN });
  let file = process.env.KOGEN_ARCHIVE;
  if (!file) {
    const r = await run('/bin/sh', ['packaging/package.sh'], { cwd: ROOT, timeout: 30 * MIN });
    assert.equal(r.code, 0, `sh packaging/package.sh failed (${r.code}): ${r.out}`);
    file = r.out.split('\n').findLast(line => line.startsWith('/') && line.endsWith('.tar.gz'));
  }
  file = path.resolve(ROOT, file || '');
  assert.ok(fs.existsSync(file), `release archive not found: ${file}`);
  return file;
});
const template = () => once('template', async () => {
  const file = await archive();
  const extract = path.join(workDir(), 'extract'); fs.mkdirSync(extract, { recursive: true });
  await checked('/usr/bin/tar', ['-xzf', file, '-C', extract]);
  const [releaseName] = fs.readdirSync(extract);
  const home = path.join(workDir(), 'install-home'); fs.mkdirSync(home, { recursive: true });
  const prefix = path.join(workDir(), 'install-template');
  await checked('/bin/sh', [path.join(extract, releaseName, 'install.sh'), '--prefix', prefix], { env: { HOME: home, PATH: process.env.PATH, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(home, '.gitconfig') }, timeout: 10 * MIN });
  return prefix;
});

const toolchainPath = process.env.PATH || '/usr/bin:/bin';
const tempDir = prefix => fs.realpathSync(fs.mkdtempSync(path.join(workDir(), `${prefix}-`)));

// An installation of the packaged Kogen in a private prefix: { root, prefix, release, cucumber, path }.
async function setupSuite() {
  const source = await template();
  const root = tempDir('suite');
  const prefix = path.join(root, 'prefix');
  await checked('cp', process.platform === 'darwin' ? ['-cR', source, prefix] : ['-R', '--reflink=auto', source, prefix]);
  fs.rmSync(path.join(prefix, 'bin/kogen'), { force: true });
  fs.symlinkSync(path.join(prefix, 'lib/kogen/bin/kogen'), path.join(prefix, 'bin/kogen'));
  return { root, prefix, install: path.join(prefix, 'lib/kogen'), release: path.join(prefix, 'bin/kogen'), cucumber: cucumberPaths(), path: toolchainPath };
}
function cleanupSuite(suite) { if (suite) fs.rmSync(suite.root, { recursive: true, force: true }); }

// ------------------------------------------------------------------ the scripted local provider (FakeProvider)

const REFUSED = { error: { message: 'scripted provider refusal', code: 'invalid_request_error' } };
const REASONS = { 200: 'OK', 400: 'Bad Request' };
const fn = (name, args) => ({ function: [name, args] });

class FakeProvider {
  constructor(script) {
    this.script = script; this.next = 0; this.provider = []; this.auth = [];
    this.pauses = []; this.pauseWaiters = []; this.opens = []; this.openWaiters = []; this.closes = []; this.closeWaiters = [];
    this.sockets = new Set();
  }
  async start() {
    this.server = http.createServer((req, res) => { this.handle(req, res).catch(() => { try { res.destroy(); } catch {} }); });
    this.server.on('connection', s => { this.sockets.add(s); s.once('close', () => this.sockets.delete(s)); });
    await new Promise(resolve => this.server.listen(0, '127.0.0.1', resolve));
    this.port = this.server.address().port;
    return this;
  }
  async stop() { for (const s of this.sockets) s.destroy(); await new Promise(resolve => this.server.close(resolve)); }
  providerRequests() { return this.provider.slice(); }
  authRequests() { return this.auth.slice(); }
  toolOutputs() { return this.provider.flatMap(r => (r.json.input || []).filter(i => i.type === 'function_call_output').map(i => i.output)); }
  reviewRequests() { return this.provider.filter(r => JSON.stringify([r.json.instructions || '', ...(r.json.input || [])]).includes('You review code')); }
  // The conversation a request replays, without the developer message that carries the policy.
  static userInput(request) { return (request.json.input || []).filter(i => i.role !== 'developer'); }
  static inputText(request) {
    return request.json.input.filter(i => i.role !== 'developer').map(i => typeof i.content === 'string' ? i.content : Array.isArray(i.content) ? i.content.map(b => b.text || '').join('') : '').join('\n');
  }
  // Replace the answers not yet consumed, as the old driver did.
  setScript(tail) { const kept = this.script.slice(0, this.next); while (kept.length < this.next) kept.push(null); this.script = kept.concat(tail); }
  waitPaused(ms = 15000) { return this.queued(this.pauses, this.pauseWaiters, ms, 'the provider did not reach its pause'); }
  waitOpen(ms = 15000) { return this.queued(this.opens, this.openWaiters, ms, 'the provider stream never opened'); }
  waitClosed(ms = 15000) { return this.queued(this.closes, this.closeWaiters, ms, 'the provider stream never closed'); }
  queued(items, waiters, ms, message) {
    if (items.length) return Promise.resolve(items.shift());
    return new Promise((resolve, reject) => { const w = { resolve, timer: setTimeout(() => reject(new Error(message)), ms) }; waiters.push(w); });
  }
  push(items, waiters, value) { const w = waiters.shift(); if (w) { clearTimeout(w.timer); w.resolve(value); } else items.push(value); }

  async handle(req, res) {
    const chunks = []; for await (const b of req) chunks.push(b);
    const body = Buffer.concat(chunks).toString('utf8');
    const url = req.url;
    let json = body;
    if (url === '/v1/responses') { try { json = JSON.parse(body); } catch { return this.send(res, 400, 'application/json', JSON.stringify(REFUSED)); } }
    else if (['/api/accounts/oauth/token', '/oauth2/token', '/oauth2/device/code'].includes(url)) json = Object.fromEntries(new URLSearchParams(body));
    const request = { method: req.method, path: url, json, body, headers: req.headers };
    if (url === '/api/accounts/oauth/token') {
      this.auth.push(request);
      return this.send(res, 200, 'application/json', JSON.stringify({ access_token: 'fake-rotated-access-token', refresh_token: 'fake-rotated-refresh-token', expires_in: 3600 }));
    }
    if (url === '/v1/responses') {
      const index = this.next++;
      this.provider.push(request);
      const action = index < this.script.length ? this.script[index] : { http: [400, REFUSED] };
      return this.respond(res, action || { http: [400, REFUSED] }, index);
    }
    if (url === '/oauth2/token' || url === '/oauth2/device/code') {
      this.auth.push(request);
      const action = this.next < this.script.length ? this.script[this.next] : { json: [400, {}] };
      this.next++;
      return this.respond(res, action, this.next - 1);
    }
    return this.send(res, 404, 'application/json', JSON.stringify({ error: 'not found' }));
  }
  async respond(res, action, index) {
    if (action.pause) {
      await new Promise(resolve => this.push(this.pauses, this.pauseWaiters, { continue: resolve }));
      return this.respond(res, action.pause, index);
    }
    if (action.http) return this.send(res, action.http[0], 'application/json', JSON.stringify(action.http[1]));
    if (action.json) return this.send(res, action.json[0], 'application/json', JSON.stringify(action.json[1]));
    if (action.text !== undefined) return this.sse(res, [{ type: 'message', id: `message-${index}`, role: 'assistant', content: [{ type: 'output_text', text: action.text, annotations: [] }] }]);
    if (action.function) return this.sse(res, [{ type: 'function_call', id: `function-${index}`, call_id: `call-${index}`, name: action.function[0], arguments: JSON.stringify(action.function[1]) }]);
    if (action.items) return this.sse(res, action.items);
    if (action.events) return this.send(res, 200, 'text/event-stream', action.events.map(e => `data: ${JSON.stringify(e)}\n\n`).join(''));
    if (action.openEvents) return this.open(res, action.openEvents);
    throw new Error(`unknown scripted action ${JSON.stringify(action)}`);
  }
  send(res, status, type, body) {
    res.writeHead(status, { 'content-type': type, 'x-request-id': 'req-fixture', 'content-length': Buffer.byteLength(body), connection: 'close' });
    res.end(body);
  }
  sse(res, items) {
    const events = items.map((item, i) => `data: ${JSON.stringify({ type: 'response.output_item.done', output_index: i, item })}\n\n`).join('');
    const done = JSON.stringify({ type: 'response.completed', response: { usage: { input_tokens: 1, input_tokens_details: { cached_tokens: 0 }, output_tokens: 1, output_tokens_details: { reasoning_tokens: 0 } } } });
    this.send(res, 200, 'text/event-stream', `${events}data: ${done}\n\n`);
  }
  // A real open stream: headers and frames are out, then the socket stays active until the client closes it.
  open(res, events) {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    for (const e of events) res.write(`data: ${JSON.stringify(e)}\n\n`);
    this.push(this.opens, this.openWaiters, { open: true });
    const deadline = Date.now() + 3000;
    return new Promise(resolve => {
      let finished = false;
      const finish = result => { if (finished) return; finished = true; clearInterval(timer); this.push(this.closes, this.closeWaiters, result); resolve(); };
      const timer = setInterval(() => { if (Date.now() > deadline) { finish('timeout'); try { res.end(); } catch {} } else { try { res.write(':\n\n'); } catch {} } }, 20);
      res.once('close', () => finish('closed'));
    });
  }
}

// ------------------------------------------------------------------ projects (Helpers.project!)

function isolatedEnv(context, change = {}) { return { ...context.env, ...change }; }
const envFor = (context, change) => {
  const env = isolatedEnv(context, change);
  for (const k of Object.keys(env)) if (env[k] === null || env[k] === undefined) delete env[k];
  return env;
};

async function project(suite, providerScript = [], opts = {}) {
  const root = tempDir('case');
  const repo = path.join(root, opts.repoName || 'repo'), home = path.join(root, 'home'), tmp = path.join(root, 'tmp');
  for (const d of [repo, home, tmp]) fs.mkdirSync(d, { recursive: true });
  const globalConfig = path.join(home, '.gitconfig'); fs.writeFileSync(globalConfig, '');
  const server = await new FakeProvider([fn('submit_configuration', { setup: [], fix: [], checks: [], protect: [] }), ...providerScript]).start();
  const env = { HOME: home, PATH: suite.path, GIT_CONFIG_GLOBAL: globalConfig, GIT_CONFIG_NOSYSTEM: '1', KOGEN_PROVIDER_URL: `http://127.0.0.1:${server.port}`, KOGEN_AUTH_URL: `http://127.0.0.1:${server.port}`, TMPDIR: tmp, ...(opts.lang ? { LANG: opts.lang } : {}) };
  const context = { suite, root, repo, home, tmp, env, globalConfig, server, started: new Set() };
  try {
    fs.writeFileSync(path.join(repo, 'README.md'), '# Fixture project\n');
    fs.writeFileSync(path.join(repo, 'app.txt'), 'baseline\n');
    for (const args of [['init', '-q', '--initial-branch=main'], ['config', 'user.name', 'Kogen Integration'], ['config', 'user.email', 'kogen-integration@example.invalid'], ['add', 'README.md', 'app.txt'], ['commit', '-q', '-m', 'fixture baseline']]) await gitBang(context, args);
    seedCredentials(context, 'valid');
    const init = await runKogen(context, ['init']);
    if (init.code !== 0) throw new Error(`kogen init failed: ${init.out}`);
    writeIntent(context);
    if (opts.stagedIntent !== false) await stageOtherIntent(context);
    await approve(context);
    return context;
  } catch (error) {
    await server.stop().catch(() => {});
    fs.rmSync(root, { recursive: true, force: true });
    throw error;
  }
}
async function cleanupCase(context) {
  if (!context) return;
  for (const h of context.started) { killGroup(h.pid); }
  if (process.env.KOGEN_GM_KEEP) { await context.server.stop().catch(() => {}); return; } // keep the case directory for inspection
  await context.server.stop().catch(() => {});
  fs.rmSync(context.root, { recursive: true, force: true });
}

// { out, code } with stderr interleaved into stdout, like the old System.cmd with stderr_to_stdout.
async function runKogen(context, args, opts = {}) {
  const r = await run(context.suite.release, args, { cwd: opts.cd || context.repo, env: envFor(context, opts.env), timeout: opts.timeout || 4 * MIN, input: opts.input });
  assert.equal(r.timed, false, `watchdog killed: kogen ${args.join(' ')}\n${r.out}`);
  return { out: r.out, code: r.code };
}
// A running kogen: { pid, output(), awaitOutput(needle, ms), awaitExit(ms) -> {out, code}, signal(name) }.
function startKogen(context, args, opts = {}) {
  const h = spawnProcess(context.suite.release, args, { cwd: opts.cd || context.repo, env: envFor(context, opts.env), timeout: 10 * MIN });
  context.started.add(h);
  const exited = h.done.then(r => { h.exit = r; return r; });
  return {
    pid: h.pid, output: h.output,
    awaitOutput(needle, ms = 10000) {
      return new Promise((resolve, reject) => {
        const check = () => { if (h.output().includes(needle)) { resolve(h.output()); return true; } return false; };
        if (check()) return;
        const timer = setTimeout(() => reject(new Error(`timed out waiting for kogen output ${JSON.stringify(needle)}: ${h.output()}`)), ms);
        h.onData(() => { if (check()) clearTimeout(timer); });
        exited.then(r => { clearTimeout(timer); if (!h.output().includes(needle)) reject(new Error(`kogen exited with ${r.code} before output ${JSON.stringify(needle)}: ${h.output()}`)); });
      });
    },
    async awaitExit(ms = 20000) {
      const r = await Promise.race([exited, sleep(ms).then(() => null)]);
      if (!r) throw new Error(`kogen did not exit within ${ms} ms: ${h.output()}`);
      return { out: r.out, code: r.code };
    },
    signal(name) { process.kill(h.pid, name); },
  };
}
async function gitBang(context, args) {
  const r = await run('git', ['-C', context.repo, ...args], { env: envFor(context) });
  assert.equal(r.code, 0, `git ${args.join(' ')} failed (${r.code}): ${r.out}`);
  return r.out;
}
const git = async (context, args) => (await gitBang(context, args)).trim();
const indexTree = context => git(context, ['write-tree']);

function writeHook(context, contents) {
  const hooks = path.join(context.root, 'git-hooks'); fs.mkdirSync(hooks, { recursive: true });
  const file = path.join(hooks, 'pre-commit');
  fs.writeFileSync(file, `#!/bin/sh\n${contents}`, { mode: 0o755 }); fs.chmodSync(file, 0o755);
  return git(context, ['config', 'core.hooksPath', hooks]).then(() => file);
}
function seedCredentials(context, freshness = 'valid') {
  const expires = Math.floor(Date.now() / 1000) + (freshness === 'expired' ? -120 : 86400);
  const dir = path.join(context.home, '.kogen/credentials');
  fs.mkdirSync(dir, { recursive: true });
  fs.chmodSync(path.dirname(dir), 0o700); fs.chmodSync(dir, 0o700);
  const file = path.join(dir, 'chatgpt.json');
  fs.writeFileSync(file, JSON.stringify({ client_id: 'oaiapp_fake-integration-client', access_token: 'fake-integration-access-token', refresh_token: 'fake-integration-refresh-token', expires_at: expires, scope: 'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct', email: 'integration@example.invalid' }));
  fs.chmodSync(file, 0o600);
}
async function waitForFile(file, ms = 10000) {
  const deadline = Date.now() + ms;
  while (!fs.existsSync(file)) { if (Date.now() >= deadline) throw new Error(`timed out waiting for ${file}`); await sleep(20); }
}
function runLog(context) {
  const found = runDirs(context).map(d => path.join(d, 'log.jsonl')).filter(f => fs.existsSync(f));
  assert.equal(found.length, 1, `expected one run log: ${found}`);
  return found[0];
}
const runDirs = context => { const dir = path.join(context.repo, '.kogen/local/runs'); return fs.existsSync(dir) ? fs.readdirSync(dir).sort().map(n => path.join(dir, n)) : []; };

function writeIntent(context) {
  const dir = path.join(context.repo, '.kogen/intents/fixture'), steps = path.join(context.repo, 'features/steps');
  fs.mkdirSync(dir, { recursive: true }); fs.mkdirSync(steps, { recursive: true });
  fs.writeFileSync(path.join(dir, 'intent.md'), `# Preserve the fixture

Slug: fixture
Model: not applicable — no model for this fixture

Acceptance:
- .kogen/intents/fixture/acceptance.feature
- features/steps/integration_steps.js

## Tests
- the fixture stays as it is: the acceptance scenario (existing)

## Source comparison
- addressed: preserve app.txt fixture behavior; source request; contract Tests and acceptance.feature.

## Feasibility
- none
`);
  fs.writeFileSync(path.join(dir, 'acceptance.feature'), `Feature: Integration fixture
  Scenario: The actual Cucumber runner passes
    Given the fixture is available
    Then the acceptance check passes
`);
  fs.writeFileSync(path.join(steps, 'integration_steps.js'), `const { Given, Then } = require('@cucumber/cucumber');

Given('the fixture is available', function () {
  this.fixtureAvailable = true;
});

Then('the acceptance check passes', function () {
  if (!this.fixtureAvailable) throw new Error('fixture was not available');
});
`);
}
async function stageOtherIntent(context) {
  const file = path.join(context.repo, '.kogen/intents/staged/draft.md');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, 'caller staged this Intent\n');
  await gitBang(context, ['add', '.kogen/intents/staged/draft.md']);
}
// Approves a slug (card, then the hash); returns { card, hash, out }.
async function approve(context, slug = 'fixture') {
  const card = await runKogen(context, ['intent', 'approve', slug]);
  if (card.code !== 5) throw new Error(`kogen approval card failed (${card.code}): ${card.out}`);
  const hash = /SHA-256: ([0-9a-f]{64})/.exec(card.out)[1];
  const done = await runKogen(context, ['intent', 'approve', slug, hash.slice(0, 8)]);
  if (done.code !== 0) throw new Error(`kogen approval failed: ${done.out}`);
  return { card: card.out, hash, out: done.out };
}
// SSH commit signing for the project (the same four settings the old drivers used).
async function signCommits(context) {
  const key = path.join(context.root, 'signing');
  await checked('/usr/bin/ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-f', key]);
  const allowed = path.join(context.root, 'allowed-signers');
  fs.writeFileSync(allowed, `kogen-integration@example.invalid ${fs.readFileSync(`${key}.pub`, 'utf8')}`);
  for (const pair of [['gpg.format', 'ssh'], ['user.signingkey', key], ['commit.gpgsign', 'true'], ['gpg.ssh.allowedSignersFile', allowed]]) await git(context, ['config', ...pair]);
}

// ------------------------------------------------------------------ small file helpers shared by the drivers

const intentDir = slug => `.kogen/intents/${slug}`;
const intentMd = slug => `${intentDir(slug)}/intent.md`;
const featurePath = slug => `${intentDir(slug)}/acceptance.feature`;
const approvalPath = (repo, slug) => path.join(repo, `.kogen/local/approvals/${slug}.json`);
function listFiles(p) {
  let st; try { st = fs.statSync(p); } catch { return []; }
  if (st.isDirectory()) return fs.readdirSync(p).sort().flatMap(n => listFiles(path.join(p, n)));
  return st.isFile() ? [p] : [];
}
// Paths under a root matching a glob made of literal segments and `*` segments (no `**`).
function wildcard(pattern) {
  const parts = pattern.split('/'); let found = [parts[0] === '' ? '/' : parts[0]];
  for (const part of parts.slice(1)) {
    if (part === '') continue;
    const next = [];
    for (const base of found) {
      if (part.includes('*')) {
        const re = new RegExp(`^${part.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*')}$`);
        let names = []; try { names = fs.readdirSync(base); } catch {}
        for (const n of names.sort()) if (re.test(n)) next.push(path.join(base, n));
      } else if (fs.existsSync(path.join(base, part))) next.push(path.join(base, part));
    }
    found = next;
  }
  return found.sort();
}
const mode = p => fs.statSync(p).mode & 0o777;

// What a Build replays of a received item (the supported fields only, in received order), and the output item that
// answers a call. Written independently of the engine, as the oracle for what the next request must carry.
const take = (item, keys) => Object.fromEntries(keys.filter(k => k in item).map(k => [k, item[k]]));
function replayItem(item) {
  if (item.type === 'function_call') return take(item, ['type', 'id', 'call_id', 'name', 'arguments', 'status']);
  if (item.type === 'reasoning') return take(item, ['type', 'id', 'encrypted_content', 'summary', 'status']);
  if (item.type === 'message' && Array.isArray(item.content)) {
    const content = item.content.flatMap(b => b.type === 'output_text' && typeof b.text === 'string' ? [{ type: 'output_text', text: b.text }] : b.type === 'refusal' && typeof b.refusal === 'string' ? [{ type: 'refusal', refusal: b.refusal }] : []);
    return content.length ? { ...take(item, ['type', 'id', 'role', 'phase', 'status']), content } : null;
  }
  return null;
}
const outputItem = (call, text) => ({ type: 'function_call_output', call_id: call.call_id, output: text });

// The tree Kogen builds for a candidate: the start commit's tree plus everything not ignored, in a private index.
async function candidateTree(context, start, excluded = []) {
  const index = path.join(context.tmp, `candidate-index-${process.pid}-${Date.now()}`);
  const env = { ...envFor(context), GIT_INDEX_FILE: index };
  try {
    const g = async args => { const r = await run('git', ['-C', context.repo, ...args], { env }); assert.equal(r.code, 0, `git ${args.join(' ')}: ${r.out}`); return r.out.trim(); };
    await g(['read-tree', start]);
    await g(['add', '-A', '--', '.', ...excluded.map(e => `:(exclude,literal)${e}`)]);
    return await g(['write-tree']);
  } finally { fs.rmSync(index, { force: true }); }
}
// The baseline hash of an Intent as its approval card shows it: SHA-256 over the sorted baseline files, each as
// `path NUL sha256(bytes) LF` (the Intent's files, its Acceptance paths, .kogen/project.yaml and the protected files).
async function baselinePaths(context, slug, protect = []) {
  const root = context.repo;
  const md = intentMd(slug), feature = featurePath(slug);
  const own = listFiles(path.join(root, intentDir(slug))).map(p => path.relative(root, p));
  own.sort((a, b) => { const ka = [a !== md, a !== feature, a], kb = [b !== md, b !== feature, b]; for (let i = 0; i < 3; i++) { if (ka[i] < kb[i]) return -1; if (ka[i] > kb[i]) return 1; } return 0; });
  const text = fs.existsSync(path.join(root, md)) ? fs.readFileSync(path.join(root, md), 'utf8') : '';
  const listed = []; let inList = false;
  for (const line of text.split('\n')) { if (/^Acceptance:/.test(line)) { inList = true; continue; } if (inList) { const m = /^- (.+)$/.exec(line); if (m) listed.push(m[1].trim()); else break; } }
  const first = [md, feature].filter(p => own.includes(p));
  const files = (await git(context, ['ls-files', '-z', '--cached', '--others', '--exclude-standard'])).split('\0').filter(Boolean);
  const protectedFiles = [...new Set(protect.flatMap(pat => { pat = pat.replace(/\/+$/, ''); return files.filter(f => f === pat || f.startsWith(`${pat}/`)); }))].sort();
  return [...new Set([...first, ...listed, ...own, '.kogen/project.yaml', ...protectedFiles])];
}
async function baselineHash(context, slug, protect = []) {
  const root = context.repo;
  const paths = (await baselinePaths(context, slug, protect)).sort();
  return sha(paths.map(p => `${p}\0${fs.existsSync(path.join(root, p)) ? sha(fs.readFileSync(path.join(root, p))) : 'missing'}\n`).join(''));
}

// Rewrites the commands of the project's .kogen/project.yaml (setup, fix, checks [{name, run}], protect), keeping its
// acceptance command and models as `kogen init` wrote them. Nothing is committed.
function configure(context, { setup = [], fix = [], checks = [], protect = [], acceptance: accept } = {}) {
  const file = path.join(context.repo, '.kogen/project.yaml');
  const text = fs.readFileSync(file, 'utf8');
  const q = x => `'${String(x).replaceAll("'", "''")}'`;
  const list = (key, items, render) => items.length ? `  ${key}:\n${items.map(i => `    - ${render(i)}`).join('\n')}\n` : `  ${key}: []\n`;
  const acceptance = accept ? `  acceptance:\n    run: ${q(accept.run)}\n    steps_dir: ${q(accept.stepsDir)}\n` : text.slice(text.indexOf('  acceptance:'), text.indexOf('protect:'));
  const models = text.slice(text.indexOf('models:'));
  const protectText = protect.length ? `protect:\n${protect.map(p => `  - ${q(p)}`).join('\n')}\n` : 'protect: []\n';
  fs.writeFileSync(file, `version: 1\ncommands:\n${list('setup', setup, q)}${list('fix', fix, q)}${list('checks', checks, c => `name: ${c.name}\n      run: ${q(c.run)}`)}${acceptance}${protectText}${models}`);
}

// A tiny Go program that uses Kogen's packages (a module outside the repository that replaces "kogen" by <repo>/cli), for
// the few observations that need an internal function and have no user-visible form. Built once per source; returns
// `(args, { input }) -> { out, code }`.
async function goDriver(name, source) {
  const key = `go:${name}:${sha(source)}`;
  const bin = await once(key, async () => {
    const dir = path.join(workDir(), `go-${name}-${sha(source).slice(0, 8)}`); fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'go.mod'), `module driver\n\ngo 1.27\n\nrequire kogen v0.0.0\n\nreplace kogen => ${path.join(ROOT, 'cli')}\n`);
    fs.writeFileSync(path.join(dir, 'main.go'), source);
    const env = { ...process.env, GOFLAGS: '-buildvcs=false', GOPROXY: 'off', GOTOOLCHAIN: 'local', GOWORK: 'off', HOME: process.env.HOME || dir };
    const out = path.join(dir, 'driver');
    const r = await run('go', ['build', '-o', out, '.'], { cwd: dir, env, timeout: 10 * MIN });
    assert.equal(r.code, 0, `go build of the ${name} driver failed:\n${r.out}`);
    return out;
  });
  return async (args = [], { input, env = {}, cwd } = {}) => { const r = await run(bin, args, { input, cwd, env: { ...process.env, ...env } }); return { out: r.out, code: r.code }; };
}

// A build lock held by this (live) process: a nonempty directory with one owner file holding the pid.
function acquireLock(lock) {
  fs.mkdirSync(path.dirname(lock), { recursive: true });
  const token = crypto.randomBytes(12).toString('hex'), tmp = `${lock}.${token}`;
  fs.mkdirSync(tmp); fs.writeFileSync(path.join(tmp, token), `${process.pid}\n`);
  fs.renameSync(tmp, lock);
  return () => { try { fs.rmSync(path.join(lock, token)); fs.rmdirSync(lock); } catch {} };
}

module.exports = {
  ROOT, MIN, sleep, sha, shellQuote, spawnProcess, run, checked, killGroup, archive, template, workDir, setupSuite, cleanupSuite, cucumberPaths,
  FakeProvider, fn, project, cleanupCase, runKogen, startKogen, git, gitBang, indexTree, writeHook, seedCredentials, waitForFile, runLog, runDirs,
  approve, signCommits, envFor, acquireLock, goDriver, configure, replayItem, outputItem, candidateTree, baselinePaths, baselineHash, intentDir, intentMd, featurePath, approvalPath, listFiles, wildcard, mode, REFUSED,
};

// ================================================================== Build-side accumulated suites (section added by the Build-side port)
// Helpers for the suites that observe a run of Build, Review, Resume or recovery. Nothing above is changed.

// A Go program kept in the repository at test/migration/drivers/<name>/ (its own module that replaces `kogen` by ../../../../cli),
// for the few observations that need an internal function and have no user-visible form. Built once per run into the work
// directory; returns `(args, { input, env, cwd }) -> { out, code }` (stdout and stderr interleaved).
async function driverProgram(name) {
  const source = path.join(ROOT, 'test/migration/drivers', name);
  assert.ok(fs.existsSync(path.join(source, 'main.go')), `missing Go driver ${source}`);
  const bin = await once(`driver:${name}`, async () => {
    const out = path.join(workDir(), `driver-${name}`);
    const env = { ...process.env, GOFLAGS: '-buildvcs=false', GOPROXY: 'off', GOTOOLCHAIN: 'local', GOWORK: 'off' };
    const r = await run('go', ['build', '-o', out, '.'], { cwd: source, env, timeout: 10 * MIN });
    assert.equal(r.code, 0, `go build of the ${name} driver failed:\n${r.out}`);
    return out;
  });
  return async (args = [], { input, env = {}, cwd } = {}) => { const r = await run(bin, args, { input, cwd, env: { ...process.env, ...env } }); return { out: r.out, code: r.code }; };
}
Object.assign(module.exports, { driverProgram });

// A Shape response that inspects the checkout (a same-response read_file of README.md) and then submits: the inspection gate
// of shaping-technical-discovery refuses a `files` publication that no completed read_file, list_files or search_text precedes.
// `tag` keeps the call ids of one script distinct. Returns a scripted FakeProvider action.
function inspectThenSubmit(kind, args, tag = 'shape') {
  return { items: [
    { type: 'function_call', id: `fc-inspect-${tag}`, call_id: `call-inspect-${tag}`, name: 'read_file', arguments: JSON.stringify({ path: 'README.md' }) },
    { type: 'function_call', id: `fc-submit-${tag}`, call_id: `call-submit-${tag}`, name: 'submit', arguments: JSON.stringify(args) },
  ] };
}
Object.assign(module.exports, { inspectThenSubmit });
