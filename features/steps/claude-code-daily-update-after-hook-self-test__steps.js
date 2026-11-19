'use strict';
// Acceptance for the daily Claude Code update after Kogen's hook self-test. Everything runs the
// shipped Kogen against a loopback origin (KOGEN_CLAUDE_CODE_URL) serving `latest`, manifests and
// scripted runtimes; no network, no model. The pinned runtime and the candidates are node scripts:
// outside the self-test they delegate to the repository's fake claude; in the self-test (the argv
// has -p and ANTHROPIC_BASE_URL is set) they talk to Kogen's loopback model stand-in with the
// Anthropic streaming wire format, run the hook commands of the --settings file the way Claude
// Code does (or skip them, or ignore a denial, depending on the candidate's kind) and write files.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, When, Then, After } = require('@cucumber/cucumber');
const H = require('./go_driver_support.js');

const P = 'claude-code-daily-update-after-hook-self-test: ';
const ROOT = path.resolve(__dirname, '../..');
const FAKE = path.join(ROOT, 'test/acceptance/fixtures/claude/fake-claude.js');
const PIN = '2.1.318';
const TOKEN = 'sk-ant-oat01-SAVED-SYNTHETIC-TOKEN';
const MIN = 60000;
const RUNNER = 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require "features/steps/*.js" --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"';
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const J = JSON.stringify;
const put = (p, s, mode) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, s); if (mode !== undefined) fs.chmodSync(p, mode); };
const jsonl = f => (fs.existsSync(f) ? fs.readFileSync(f, 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l)) : []);
const outLines = r => r.out.split('\n').map(l => l.replace(/\r$/, ''));
function tree(p, out = {}) {
  let st;
  try { st = fs.lstatSync(p); } catch { return out; }
  if (st.isDirectory()) { out[p] = 'dir'; for (const n of fs.readdirSync(p).sort()) tree(path.join(p, n), out); } else out[p] = `${st.mode & 0o7777}:${sha(fs.readFileSync(p))}`;
  return out;
}
function platformKey() {
  if (process.platform === 'darwin' && process.arch === 'arm64') return 'darwin-arm64';
  if (process.platform === 'linux' && process.arch === 'x64') return 'linux-x64';
  throw new Error(`unsupported platform ${process.platform}/${process.arch}`);
}
const ctx = w => { assert.ok(w.cdu, 'no user was set up'); return w.cdu; };
const kogen = (c, args, cwd) => H.run(c.bin, args, { cwd: cwd || c.d, env: c.env, timeout: 8 * MIN });
function git(c, args) {
  const r = spawnSync('git', args, { cwd: c.repo, env: c.env, encoding: 'utf8' });
  assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.stdout}${r.stderr}`);
  return r.stdout;
}
const mdir = c => path.join(c.home, '.kogen/claude-code');

// One installation of the shipped Kogen is shared by every scenario of the run (the copy is slow).
let sharedSuite = null;
async function suiteOnce() {
  if (!sharedSuite) {
    sharedSuite = H.setupSuite();
    process.on('exit', () => { try { H.cleanupSuite(sharedSuite.suite); } catch {} });
    sharedSuite = sharedSuite.then(s => { sharedSuite = { suite: s, then: undefined }; return s; });
  }
  return sharedSuite.suite || sharedSuite;
}

function script(version) {
  return {
    version: `${version} (Claude Code)`, roles: {
      build: { rounds: [
        { actions: [{ write: { path: 'app.txt', content: 'built\n' } }], claim: 'Wrote app.txt.' },
        { actions: [{ write: { path: 'app2.txt', content: 'built\n' } }], claim: 'Wrote app2.txt.' },
      ] },
      review: { rounds: [{ structured: { verdict: 'approve', findings: [] }, actions: [] }] },
    },
  };
}

// A runtime executable. kind: pinned | works | skips-hook | allows-protected. nested: the first
// Build round of this runtime runs `kogen provider update claude-code` before delegating.
function runtime(c, version, kind, nested) {
  const sp = path.join(c.state, `script-${version}-${kind}.json`);
  put(sp, J(script(version)));
  return Buffer.from(`#!${process.execPath}
'use strict';
const fs = require('node:fs'), cp = require('node:child_process'), path = require('node:path'), http = require('node:http');
const args = process.argv.slice(2), state = ${J(c.state)}, kind = ${J(kind)};
const flag = n => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : ''; };
const log = (f, o) => fs.appendFileSync(path.join(state, f), J(o) + '\\n');
function J(o) { return JSON.stringify(o); }
if (args.length === 1 && args[0] === '--version') { process.stdout.write(${J(version + ' (Claude Code)')} + '\\n'); process.exit(0); }
const selfTest = args[0] === '-p' && !!process.env.ANTHROPIC_BASE_URL;
if (!selfTest) {
  if (args[0] === '-p') {
    log('role-children.jsonl', { self: process.argv[1], args });
    const marker = path.join(state, 'nested.done');
    if (${J(!!nested)} && !fs.existsSync(marker)) {
      fs.writeFileSync(marker, 'x');
      const env = JSON.parse(fs.readFileSync(path.join(state, 'kogen-env.json'), 'utf8'));
      const r = cp.spawnSync(${J(c.bin)}, ['provider', 'update', 'claude-code'], { cwd: state, env, encoding: 'utf8' });
      log('nested.jsonl', { status: r.status, out: (r.stdout || '') + (r.stderr || '') });
    }
  }
  const r = cp.spawnSync(process.execPath, [${J(FAKE)}, ...args], { stdio: 'inherit', env: { ...process.env, KOGEN_FAKE_CLAUDE_SCRIPT: ${J(sp)}, KOGEN_FAKE_CLAUDE_STATE: path.join(state, 'fake') } });
  process.exit(r.status === null ? 1 : r.status);
}
const env = process.env;
log('selftest.jsonl', { self: process.argv[1], args, config: env.CLAUDE_CONFIG_DIR || null, fdVar: env.CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR || null,
  leaked: Object.values(env).some(v => String(v).includes(${J(TOKEN)})), base: env.ANTHROPIC_BASE_URL, hasToken: !!env.ANTHROPIC_AUTH_TOKEN, cwd: process.cwd() });
let settings = {};
try { const s = flag('--settings'); settings = s.trim().startsWith('{') ? JSON.parse(s) : JSON.parse(fs.readFileSync(s, 'utf8')); } catch {}
const cwd = fs.realpathSync(process.cwd());
const sessionId = flag('--session-id') || 'selftest';
const out = o => process.stdout.write(J(o) + '\\n');
function denied(name, input, id) {
  let d = false;
  for (const entry of (settings.hooks && settings.hooks.PreToolUse) || []) {
    if (!new RegExp('^(?:' + (entry.matcher || '.*') + ')$').test(name)) continue;
    for (const hook of entry.hooks || []) {
      const stdin = J({ session_id: sessionId, cwd, hook_event_name: 'PreToolUse', permission_mode: 'acceptEdits', tool_name: name, tool_input: input, tool_use_id: id });
      const r = cp.spawnSync(hook.command, hook.args || [], { input: stdin, cwd, env: process.env, encoding: 'utf8' });
      const code = r.error ? 127 : r.status;
      if (code === 2 || /"permissionDecision"\\s*:\\s*"deny"/.test(r.stdout || '')) d = true;
    }
  }
  return d;
}
const post = body => new Promise((res, rej) => {
  const r = http.request(new URL(env.ANTHROPIC_BASE_URL.replace(/\\/$/, '') + '/v1/messages'), { method: 'POST', headers: { 'content-type': 'application/json', 'anthropic-version': '2023-06-01', authorization: 'Bearer ' + env.ANTHROPIC_AUTH_TOKEN, 'x-api-key': env.ANTHROPIC_AUTH_TOKEN } }, resp => {
    let t = ''; resp.setEncoding('utf8'); resp.on('data', d => { t += d; }); resp.on('end', () => res({ status: resp.statusCode, text: t }));
  });
  r.on('error', rej); r.end(J(body));
});
function blocks(text) {
  const bs = [];
  for (const line of text.split('\\n')) {
    if (!line.startsWith('data:')) continue;
    let e; try { e = JSON.parse(line.slice(5)); } catch { continue; }
    if (e.type === 'content_block_start') bs[e.index] = { ...e.content_block, json: '' };
    if (e.type === 'content_block_delta' && bs[e.index]) { if (e.delta.type === 'input_json_delta') bs[e.index].json += e.delta.partial_json; if (e.delta.type === 'text_delta') bs[e.index].text = (bs[e.index].text || '') + e.delta.text; }
  }
  return bs.filter(Boolean).map(b => (b.type === 'tool_use' ? { type: 'tool_use', id: b.id, name: b.name, input: b.json ? JSON.parse(b.json) : (b.input || {}) } : { type: 'text', text: b.text || '' }));
}
(async () => {
  out({ type: 'system', subtype: 'init', cwd, session_id: sessionId, tools: ['Edit', 'Write'], mcp_servers: [], model: flag('--model') || 'claude-sonnet-5-5', permissionMode: 'acceptEdits', apiKeySource: 'none', claude_code_version: ${J(version)} });
  const messages = [{ role: 'user', content: 'run the self-test' }];
  for (let turn = 0; turn < 8; turn++) {
    const r = await post({ model: flag('--model') || 'claude-sonnet-5-5', max_tokens: 1024, stream: true, messages });
    if (r.status !== 200) { process.stderr.write('stand-in answered ' + r.status + '\\n'); process.exit(1); }
    const content = blocks(r.text), uses = content.filter(b => b.type === 'tool_use');
    messages.push({ role: 'assistant', content });
    if (!uses.length) break;
    const results = [];
    for (const u of uses) {
      let isError = false, text = 'ok';
      if (kind !== 'skips-hook' && denied(u.name, u.input, u.id) && kind !== 'allows-protected') { isError = true; text = 'PreToolUse:' + u.name + ' hook error: denied'; }
      else {
        try {
          const f = u.input.file_path;
          if (u.name === 'Write') { fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, u.input.content); }
          else if (u.name === 'Edit') { const s = fs.readFileSync(f, 'utf8'); if (!s.includes(u.input.old_string)) throw new Error('old_string not found'); fs.writeFileSync(f, s.replace(u.input.old_string, () => u.input.new_string)); }
          else throw new Error('unknown tool ' + u.name);
        } catch (e) { isError = true; text = String(e.message); }
      }
      results.push({ type: 'tool_result', tool_use_id: u.id, content: text, is_error: isError });
    }
    messages.push({ role: 'user', content: results });
  }
  out({ type: 'result', subtype: 'success', is_error: false, result: 'done', session_id: sessionId });
})().catch(e => { process.stderr.write(String(e && e.message) + '\\n'); process.exit(1); });
`);
}

async function startOrigin(c) {
  const s = c.origin;
  s.http = http.createServer((req, res) => {
    s.requests.push(req.url);
    const send = (code, body, type) => { res.writeHead(code, { 'content-type': type || 'text/plain', 'content-length': Buffer.byteLength(body) }); res.end(body); };
    if (req.url === '/latest') return send(200, `${s.latest}\n`);
    const m = req.url.match(/^\/([^/]+)\/(manifest\.json|[^/]+\/claude)$/);
    const cand = m && s.candidates[m[1]];
    if (!cand) return send(404, '');
    if (m[2] === 'manifest.json') return send(200, J({ version: m[1], platforms: { [c.platform]: { binary: 'claude', checksum: sha(cand), size: cand.length } } }), 'application/json');
    res.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': cand.length });
    return res.end(cand);
  });
  await new Promise(resolve => s.http.listen(s.port || 0, '127.0.0.1', resolve));
  s.port = s.http.address().port;
  c.env.KOGEN_CLAUDE_CODE_URL = `http://127.0.0.1:${s.port}`;
}
const stopOrigin = c => new Promise(resolve => { if (!c.origin.http) return resolve(); c.origin.http.closeAllConnections(); c.origin.http.close(() => resolve()); c.origin.http = null; });
const latestReqs = c => c.origin.requests.filter(r => r === '/latest').length;
const binaryReqs = (c, v) => c.origin.requests.filter(r => r === `/${v}/${c.platform}/claude`).length;

function fixtureIntent(c, slug, file, stepName) {
  const dir = `.kogen/intents/${slug}`;
  put(path.join(c.repo, dir, 'intent.md'), `# Build the ${slug} app

Slug: ${slug}
Model: not applicable — one fixed file has no state
Acceptance:
- ${dir}/acceptance.feature
- features/steps/${stepName}.js

Create ${file} with the text built.

## Decisions
- Keep the fixture minimal. (source: request)

## Source comparison
- addressed: the ${file} text is checked by the fixture scenario.

## Tests
- ${file} text: fixture scenario (scenario)

## Feasibility
- none
`);
  put(path.join(c.repo, dir, 'acceptance.feature'), `Feature: ${slug}\n  Scenario: The app is built\n    Then the ${slug} file is built\n`);
  put(path.join(c.repo, `features/steps/${stepName}.js`), `const {Then}=require('@cucumber/cucumber'); const fs=require('node:fs'); const assert=require('node:assert/strict'); Then('the ${slug} file is built',()=>assert.equal(fs.readFileSync('${file}','utf8'),'built\\n'));\n`);
}
async function approve(c, slug) {
  const card = await kogen(c, ['intent', 'approve', slug], c.repo);
  assert.equal(card.code, 5, card.out);
  const hash = card.out.match(/^SHA-256: ([a-f0-9]{64})$/m)?.[1];
  assert.ok(hash, card.out);
  const ok = await kogen(c, ['intent', 'approve', slug, hash], c.repo);
  assert.equal(ok.code, 0, ok.out);
}

Given(P + 'a user with Kogen\'s pinned Claude Code 2.1.318 installed, a saved Claude Code token and two fixture Intents', { timeout: 40 * MIN }, async function () {
  const suite = await suiteOnce();
  const d = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-cdu-')));
  const home = path.join(d, 'home'), st = path.join(d, 'state'), repo = path.join(d, 'repo');
  for (const p of [home, st, repo]) fs.mkdirSync(p, { recursive: true });
  put(path.join(home, '.gitconfig'), '');
  const env = { ...process.env, HOME: home, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(home, '.gitconfig') };
  for (const k of Object.keys(env)) if (/^(ANTHROPIC_|CLAUDE_|AWS_|GOOGLE_|AZURE_)/.test(k) || ['DISABLE_UPDATES', 'DISABLE_AUTOUPDATER', 'KOGEN_CLAUDE_CODE_URL', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE'].includes(k)) delete env[k];
  const c = { d, home, state: st, repo, env, suite, bin: suite.release, platform: platformKey(), origin: { requests: [], latest: PIN, candidates: {} }, approved: new Set() };
  this.cdu = c;
  put(path.join(mdir(c), PIN, 'claude'), runtime(c, PIN, 'pinned'), 0o755);
  await startOrigin(c);
  put(path.join(st, 'kogen-env.json'), J(c.env));
  const login = await H.run(c.bin, ['provider', 'login', 'claude-code'], { cwd: d, env: c.env, input: TOKEN + '\n', timeout: 2 * MIN });
  assert.equal(login.code, 0, login.out);
  put(path.join(repo, '.gitignore'), '.kogen/local/\n');
  put(path.join(repo, 'README.md'), '# Fixture\n');
  const role = '{executor: claude-code, model: claude-sonnet-5-5, effort: high}';
  put(path.join(repo, '.kogen/project.yaml'), `version: 1\ncommands:\n  setup: []\n  fix: []\n  checks:\n    - {name: local-check, run: 'true'}\n  acceptance:\n    run: '${RUNNER}'\n    steps_dir: features/steps\nprotect: []\n`);
  put(path.join(repo, '.kogen/models.yaml'), `models:\n  shape: ${role}\n  build: ${role}\n  review: ${role}\n`);
  for (const a of [['init', '-q', '--initial-branch=main'], ['config', 'user.name', 'Fixture'], ['config', 'user.email', 'fixture@example.invalid']]) git(c, a);
  fixtureIntent(c, 'first-fixture', 'app.txt', 'first_steps');
  fixtureIntent(c, 'second-fixture', 'app2.txt', 'second_steps');
  git(c, ['add', '.']); git(c, ['commit', '-qm', 'Fixture baseline']);
});
Given(P + 'the origin announces {string} and serves a candidate that {string}', function (version, kind) {
  const c = ctx(this);
  assert.ok(['works', 'skips-hook', 'allows-protected'].includes(kind), kind);
  c.origin.latest = version;
  c.origin.candidates[version] = runtime(c, version, kind, false);
});
Given(P + 'the origin announces {string} and serves no candidate', function (version) { ctx(this).origin.latest = version; });
Given(P + 'the origin announces {string} and serves a working candidate and the pinned runtime runs the update itself during its Build round', function (version) {
  const c = ctx(this);
  c.origin.latest = version;
  c.origin.candidates[version] = runtime(c, version, 'works', false);
  put(path.join(mdir(c), PIN, 'claude'), runtime(c, PIN, 'pinned', true), 0o755);
});
Given(P + 'harness.json says the last check ended {int} hours ago', function (hours) {
  const c = ctx(this);
  put(path.join(mdir(c), 'harness.json'), J({ checked_at: new Date(Date.now() - hours * 3600e3).toISOString() }) + '\n');
  c.hoursAgo = hours;
});
Given(P + 'the origin refuses connections', async function () { await stopOrigin(ctx(this)); });
Given(P + 'I note the state of the 2.1.318 directory', function () { const c = ctx(this); c.pinTree = tree(path.join(mdir(c), PIN)); });

When(P + 'I run kogen provider update claude-code', { timeout: 10 * MIN }, async function () { const c = ctx(this); c.update = await kogen(c, ['provider', 'update', 'claude-code']); });
When(P + 'I build the {string} fixture Intent', { timeout: 15 * MIN }, async function (name) {
  const c = ctx(this), slug = `${name}-fixture`;
  if (!c.approved.has(slug)) { await approve(c, slug); c.approved.add(slug); }
  const runs = path.join(c.repo, '.kogen/local/runs');
  const before = fs.existsSync(runs) ? fs.readdirSync(runs) : [];
  c.roleBefore = jsonl(path.join(c.state, 'role-children.jsonl')).length;
  c.build = await kogen(c, ['intent', 'build', slug], c.repo);
  const after = fs.existsSync(runs) ? fs.readdirSync(runs) : [];
  const fresh = after.filter(n => !before.includes(n) && fs.existsSync(path.join(runs, n, 'result.json')));
  c.result = fresh.length ? JSON.parse(fs.readFileSync(path.join(runs, fresh[fresh.length - 1], 'result.json'), 'utf8')) : null;
});
When(P + 'I list the providers with kogen provider list', { timeout: 2 * MIN }, async function () { const c = ctx(this); c.list = await kogen(c, ['provider', 'list']); });

Then(P + 'the update output has the line {string}', function (line) { const c = ctx(this); assert.ok(outLines(c.update).includes(line), `no line ${J(line)} in:\n${c.update.out}`); });
Then(P + 'the 2.1.318 directory is unchanged', function () { const c = ctx(this); assert.ok(Object.keys(c.pinTree).length > 1 || c.pinTree[path.join(mdir(c), PIN)], 'nothing recorded'); assert.deepEqual(tree(path.join(mdir(c), PIN)), c.pinTree); });
Then(P + 'the active version is {string}', function (v) { const c = ctx(this), f = path.join(mdir(c), 'active'); assert.ok(fs.existsSync(f), 'no active file'); assert.equal(fs.readFileSync(f, 'utf8').trim(), v); });
Then(P + 'the active version is not changed from 2.1.318', function () { const c = ctx(this), f = path.join(mdir(c), 'active'); assert.ok(!fs.existsSync(f) || fs.readFileSync(f, 'utf8').trim() === PIN, `active holds ${fs.readFileSync(f, 'utf8')}`); });
Then(P + 'the Build landed and its Claude Code roles ran {string}', function (rel) {
  const c = ctx(this), want = path.join(c.home, rel);
  assert.equal(c.build.code, 0, `the Build did not land (exit ${c.build.code}):\n${c.build.out}`);
  const roles = jsonl(path.join(c.state, 'role-children.jsonl')).slice(c.roleBefore);
  assert.ok(roles.length >= 1, 'no Claude Code role ran');
  for (const r of roles) assert.equal(r.self, want, `a role ran ${r.self}`);
});
Then(P + 'the Build landed', function () { const c = ctx(this); assert.equal(c.build.code, 0, `exit ${c.build.code}:\n${c.build.out}`); });
Then(P + 'the Build\'s first Claude Code role ran {string}', function (rel) {
  const c = ctx(this), roles = jsonl(path.join(c.state, 'role-children.jsonl')).slice(c.roleBefore);
  assert.ok(roles.length >= 1, 'no Claude Code role ran');
  assert.equal(roles[0].self, path.join(c.home, rel));
});
Then(P + 'the provider list has the line {string}', function (text) {
  const c = ctx(this), want = text.replaceAll('<home>', c.home);
  assert.equal(c.list.code, 0, c.list.out);
  assert.ok(outLines(c.list).includes(want), `no line ${J(want)} in:\n${c.list.out}`);
});
Then(P + 'the directory {string} does not exist in the Claude Code directory', function (name) {
  const c = ctx(this), m = mdir(c);
  assert.ok(!fs.existsSync(path.join(m, name)), `${name} exists: ${fs.readdirSync(m)}`);
  assert.deepEqual(fs.readdirSync(m).filter(n => n.startsWith('.partial-')), [], 'partial directories remain');
});
Then(P + 'harness.json records {string} as failed', function (v) {
  const c = ctx(this), h = JSON.parse(fs.readFileSync(path.join(mdir(c), 'harness.json'), 'utf8'));
  assert.ok(h.failed && typeof h.failed === 'object' && Object.keys(h.failed).includes(v), `no failed ${v} in ${J(h)}`);
  assert.ok(typeof h.checked_at === 'string' && !Number.isNaN(Date.parse(h.checked_at)), 'no checked_at');
});
Then(P + 'the origin served the {string} binary {int} time(s)', function (v, n) { const c = ctx(this); assert.equal(binaryReqs(c, v), n, J(c.origin.requests)); });
Then(P + 'the origin received {int} lookup(s) of latest', function (n) { const c = ctx(this); assert.equal(latestReqs(c), n, J(c.origin.requests)); });
Then(P + 'harness.json holds a checked_at within the last 10 minutes', function () {
  const c = ctx(this), h = JSON.parse(fs.readFileSync(path.join(mdir(c), 'harness.json'), 'utf8'));
  const age = Date.now() - Date.parse(h.checked_at);
  assert.ok(age >= -MIN && age < 10 * MIN, `checked_at ${h.checked_at}`);
});
Then(P + 'harness.json holds a checked_at older than 22 hours', function () {
  const c = ctx(this), h = JSON.parse(fs.readFileSync(path.join(mdir(c), 'harness.json'), 'utf8'));
  assert.ok(Date.now() - Date.parse(h.checked_at) > 22 * 3600e3, `checked_at ${h.checked_at}`);
});
Then(P + 'harness.json records an unreachable origin', function () {
  const c = ctx(this), h = JSON.parse(fs.readFileSync(path.join(mdir(c), 'harness.json'), 'utf8'));
  assert.match(String(h.last_result || ''), /unreachable/i, J(h));
});
Then(P + 'the candidate ran its self-test with the real argument list and its own throwaway sign-in', function () {
  const c = ctx(this), runs = jsonl(path.join(c.state, 'selftest.jsonl'));
  assert.ok(runs.length >= 1, 'the candidate never ran the self-test');
  for (const r of runs) {
    assert.ok(r.args.includes('-p') && r.args.includes('--settings'), J(r.args));
    assert.match(r.base, /^http:\/\/127\.0\.0\.1:\d+/, r.base);
    assert.ok(r.hasToken, 'no throwaway token');
    assert.equal(r.leaked, false, 'the saved Claude Code token reached the candidate');
    assert.equal(r.fdVar, null, 'a token pipe was handed to the candidate');
    assert.notEqual(r.config, path.join(mdir(c), 'config'), 'the candidate used the managed configuration directory');
    assert.ok(r.config, 'no CLAUDE_CONFIG_DIR');
    assert.ok(!r.cwd.startsWith(c.repo), `the self-test ran inside the user's checkout: ${r.cwd}`);
  }
});
Then(P + 'the Build result says claude_code_version {string} and claude_code_source {string}', function (v, src) {
  const c = ctx(this);
  assert.ok(c.result, `no result.json:\n${c.build.out}`);
  assert.equal(c.result.claude_code_version, v);
  assert.equal(c.result.claude_code_source, src);
});
Then(P + 'the update ran from inside the Build round and succeeded', function () {
  const c = ctx(this), n = jsonl(path.join(c.state, 'nested.jsonl'));
  assert.equal(n.length, 1, 'the nested update did not run');
  assert.equal(n[0].status, 0, n[0].out);
  assert.ok(n[0].out.includes("passed Kogen's hook self-test; now active (was 2.1.318)"), n[0].out);
});

After(async function () {
  const c = this.cdu;
  if (!c) return;
  await stopOrigin(c);
  if (!process.env.KOGEN_CDU_KEEP) fs.rmSync(c.d, { recursive: true, force: true });
});
