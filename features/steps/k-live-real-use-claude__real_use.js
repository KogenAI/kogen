'use strict';
// k-live-real-use-claude: runs the candidate test/live/real-use.sh end to end on a fresh home, offline.
// The archive is the one the configured setup packaged (KOGEN_ARCHIVE, else the newest
// dist/kogen-*.tar.gz); the project is a fresh Git repository of the py-calc fixture; a fake
// ChatGPT server (test/acceptance/support/fake-servers.js) listens on KOGEN_PROVIDER_URL on both
// routes; the repository's fake Claude Code (test/acceptance/fixtures/claude/fake-claude.js) is
// served as Kogen's managed runtime through the loopback download origin KOGEN_CLAUDE_CODE_URL.
// The login reaches the run home only through KOGEN_LIVE_CREDENTIALS, as a seat's login does.
// Observers judge what the run left: its exit code, transcript and command outputs, leak report,
// landed commit, and what each fake received.
//
//   node features/steps/k-live-real-use-claude__real_use.js control good|bad
// runs the observers on known-good and known-bad observations (no process, server or network).
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const cp = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const P = 'k-live-real-use-claude: ';
const MIN = 60 * 1000;
const RUN_LIMIT = 25 * MIN;
// How long the first Build's model turn is held, so the script's SIGINT finds a Build in progress.
const HOLD_SECONDS = 60;
const PROJECT = 'real-use-fixture';
const SLUG = 'is-even';
const CLAUDE_TOKEN = 'sk-ant-oat01-KOGEN_REAL_USE_FIXTURE_TOKEN_20261106';
const FAKE_CLAUDE = path.join(ROOT, 'test/acceptance/fixtures/claude/fake-claude.js');
const FAKE_SERVERS = path.join(ROOT, 'test/acceptance/support/fake-servers.js');
const PY_CALC = path.join(ROOT, 'test/acceptance/fixtures/projects/py-calc');
const ROLES = ['shape', 'build', 'review'];
const INIT_KEYS = ['setup', 'fix', 'checks', 'protect'];
const HINT = 'provider login chatgpt';
const STAMP = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ /;

// ------------------------------------------------------------------ observers

const tail = (text, n) => String(text || '').split('\n').slice(-n).join('\n');
function describe(o) {
  return `real-use.sh exit ${o.code}; run folder ${o.run} (kept)\n--- transcript, last 60 lines\n${tail(o.transcript, 60)}\n--- script output, last 30 lines\n${tail(o.output, 30)}`;
}
// The transcript's lines without the UTC time `say` puts in front.
const said = o => String(o.transcript || '').split('\n').filter(l => l !== '').map(l => l.replace(STAMP, ''));

// The roles of a lineup file in init's block form: models:, then two-space role keys, then
// four-space settings.
function parseModels(text) {
  const roles = {};
  let top = false, current = null;
  for (const line of String(text || '').split('\n')) {
    if (/^models:\s*$/.test(line)) { top = true; current = null; continue; }
    let m = /^ {2}([a-z]+):\s*$/.exec(line);
    if (top && m) { current = roles[m[1]] = {}; continue; }
    m = /^ {4}([a-z_]+):\s*(\S.*?)\s*$/.exec(line);
    if (current && m) { current[m[1]] = m[2]; continue; }
    if (line.trim() !== '') { top = /^\s/.test(line) && top; current = null; }
  }
  return roles;
}

const O = {
  exit(o, n) { assert.equal(o.code, n, `real-use.sh exit code: ${describe(o)}`); },
  inOrder(o, wanted) {
    const lines = said(o);
    let at = 0;
    for (const w of wanted) {
      const i = lines.indexOf(w, at);
      assert.ok(i >= 0, `the transcript has no line ${JSON.stringify(w)} after its line ${at} (wanted in order: ${JSON.stringify(wanted)}): ${describe(o)}`);
      at = i + 1;
    }
  },
  lastLine(o, want) {
    const lines = said(o);
    assert.equal(lines[lines.length - 1], want, `the transcript's last line: ${describe(o)}`);
  },
  leakLists(o, file) {
    const want = file.replaceAll('{run}', o.run);
    const listed = String(o.leak || '').split('\n').filter(Boolean);
    assert.ok(listed.includes(want), `the leak report ${o.run}/leak.txt lists ${JSON.stringify(listed)}, not ${want}: ${describe(o)}`);
  },
  noChatgpt(o) {
    assert.deepEqual(o.chatgpt.received, [], `the fake ChatGPT server received requests: ${describe(o)}`);
  },
  chatgptAnswered(o, kinds) {
    for (const kind of kinds) assert.ok(o.chatgpt.kinds.includes(kind), `the fake ChatGPT server answered no ${kind} request (answered ${JSON.stringify(o.chatgpt.kinds)}): ${describe(o)}`);
  },
  seamOnce(o) {
    const runtime = o.seam.filter(u => /^\/[^/]+\/[^/]+\/claude$/.test(u));
    assert.equal(runtime.length, 1, `the Claude Code download origin served the runtime ${runtime.length} times (requests ${JSON.stringify(o.seam)}): ${describe(o)}`);
    const other = o.seam.filter(u => !/^\/[^/]+\/manifest\.json$/.test(u) && !/^\/[^/]+\/[^/]+\/claude$/.test(u));
    assert.deepEqual(other, [], `the Claude Code download origin received other requests: ${describe(o)}`);
  },
  seamNone(o) {
    assert.deepEqual(o.seam, [], `the Claude Code download origin received requests: ${describe(o)}`);
  },
  claudeRoles(o) {
    const c = o.claude;
    const first = c.schemas[0] || [];
    assert.ok(INIT_KEYS.every(k => first.includes(k)), `the first fake Claude Code invocation was not kogen init's (its schema has ${JSON.stringify(first)}): ${describe(o)}`);
    assert.ok(c.schemas.slice(1).some(keys => !keys.includes('protect')), `no fake Claude Code shape invocation followed init (schemas ${JSON.stringify(c.schemas)}): ${describe(o)}`);
    assert.ok(c.build >= 1, `the fake Claude Code served no build invocation: ${describe(o)}`);
    assert.ok(c.review >= 1, `the fake Claude Code served no review invocation: ${describe(o)}`);
  },
  noHint(o, text) {
    const hits = Object.keys(o.outputs).filter(name => o.outputs[name].includes(text)).sort();
    assert.deepEqual(hits, [], `transcript or command outputs in ${o.run} contain ${JSON.stringify(text)}: ${describe(o)}`);
  },
  lineup(o, route) {
    const roles = parseModels(o.models);
    for (const name of ROLES) {
      const r = roles[name];
      assert.ok(r, `the landed .kogen/models.yaml has no ${name} role:\n${o.models}\n${describe(o)}`);
      if (route === 'claude-code') {
        assert.ok(r.executor === 'claude-code' && r.provider === undefined, `the landed ${name} role is not on claude-code: ${JSON.stringify(r)}\n${o.models}`);
      } else {
        assert.equal(route, 'chatgpt');
        assert.ok(r.provider === 'chatgpt' && (r.executor === undefined || r.executor === 'native'), `the landed ${name} role is not on chatgpt: ${JSON.stringify(r)}\n${o.models}`);
      }
    }
  },
  landed(o, title) {
    assert.equal(o.subject, title, `the landed commit's subject: ${describe(o)}`);
    assert.match(o.calc, /^def is_even\(/m, `the landed calc.py has no is_even:\n${o.calc}\n${describe(o)}`);
  },
};

// ------------------------------------------------------------------ observer controls

function controls(mode) {
  const run = '/tmp/klr-control/run';
  const t = s => `2026-11-06T12:00:00Z ${s}`;
  const claudeLines = ['ok: kogen version works from /', 'route: claude-code', 'ok: kogen provider list shows claude-code: token saved (not verified)',
    'ok: .kogen/models.yaml from kogen init runs shape, build and review on claude-code', 'ok: the managed Claude Code runtime is installed in the run home',
    'ok: the Intent is ready with its scenarios failing', 'ok: no new commit after the interrupt', 'ok: at least one Claude Code round ran in the Build',
    'ok: the Build landed with review: approved', 'ok: no credential token in the project, .kogen/local, the transcript or the command outputs',
    'ok: no ChatGPT login hint in the transcript or the command outputs', 'ok: kogen is gone', 'ok: the project and ~/.kogen are intact', `REL-1 passed for ${PROJECT}`];
  const claudeModels = 'models:\n  shape:\n    executor: claude-code\n    model: claude-sonnet-5-5\n    effort: high\n  build:\n    executor: claude-code\n    model: claude-sonnet-5-5\n    effort: medium\n  review:\n    executor: claude-code\n    model: claude-sonnet-5-5\n    effort: high\n';
  const chatgptModels = 'models:\n  shape:\n    provider: chatgpt\n    model: gpt-6.1-sol\n    effort: low\n  build:\n    provider: chatgpt\n    model: gpt-6.1-terra\n    effort: high\n  review:\n    provider: chatgpt\n    model: gpt-6.1-terra\n    effort: medium\n';
  const calc = 'def add(a, b):\n    return a + b\n\ndef is_even(n):\n    if not isinstance(n, int) or isinstance(n, bool):\n        raise TypeError("n must be an integer")\n    return n % 2 == 0\n';
  const transcript = [t('run folder ' + run), ...claudeLines.slice(0, 5).map(t), 'Init: ok', 'Scenarios: 3 (3 fail now, 0 pass now)', ...claudeLines.slice(5).map(t)].join('\n') + '\n';
  const good = {
    code: 0, run, output: '', transcript, leak: '',
    outputs: { 'transcript.txt': transcript, 'shape.out': 'Scenarios: 3 (3 fail now, 0 pass now)\n', 'build2.out': '  review: approved\n', 'leak.txt': '' },
    models: claudeModels, subject: 'Add an is-even helper', calc,
    chatgpt: { received: [], kinds: [] },
    seam: ['/2.1.318/manifest.json', '/2.1.318/darwin-arm64/claude'],
    claude: { shape: 3, build: 2, review: 1, schemas: [INIT_KEYS, ['files', 'questions', 'blocked'], ['files', 'questions', 'blocked']] },
  };
  const chatgptRun = { ...good, models: chatgptModels, seam: [], claude: { shape: 0, build: 0, review: 0, schemas: [] }, chatgpt: { received: ['POST /v1/responses'], kinds: ['init', 'shape', 'build', 'review'] } };
  const leakFail = 'FAIL: no credential token in the project, .kogen/local, the transcript or the command outputs';
  const leaked = { ...good, code: 1, transcript: good.transcript + t(leakFail) + '\n', leak: `${run}/transcript.txt\n` };
  const checks = [
    [good, o => O.exit(o, 0)], [good, o => O.inOrder(o, claudeLines)], [good, o => O.noChatgpt(o)], [good, o => O.noHint(o, HINT)],
    [good, o => O.seamOnce(o)], [good, o => O.claudeRoles(o)], [good, o => O.lineup(o, 'claude-code')], [good, o => O.landed(o, 'Add an is-even helper')],
    [chatgptRun, o => O.chatgptAnswered(o, ['init', 'shape', 'build', 'review'])], [chatgptRun, o => O.seamNone(o)], [chatgptRun, o => O.lineup(o, 'chatgpt')],
    [leaked, o => O.exit(o, 1)], [leaked, o => O.lastLine(o, leakFail)], [leaked, o => O.leakLists(o, '{run}/transcript.txt')],
  ];
  const without = (o, line) => ({ ...o, transcript: o.transcript.split('\n').filter(l => l.replace(STAMP, '') !== line).join('\n') });
  const swapped = { ...good, transcript: good.transcript.replace('route: claude-code', 'ok: TMP').replace('ok: kogen provider list shows claude-code: token saved (not verified)', 'route: claude-code').replace('ok: TMP', 'ok: kogen provider list shows claude-code: token saved (not verified)') };
  const bad = [
    [{ ...good, code: 1 }, o => O.exit(o, 0)],
    [without(good, 'ok: the managed Claude Code runtime is installed in the run home'), o => O.inOrder(o, claudeLines)],
    [without(good, 'ok: no ChatGPT login hint in the transcript or the command outputs'), o => O.inOrder(o, claudeLines)],
    [swapped, o => O.inOrder(o, claudeLines)],
    [{ ...good, transcript: good.transcript.replace('claude-code: token saved (not verified)', 'chatgpt: signed in') }, o => O.inOrder(o, claudeLines)],
    [{ ...good, chatgpt: { received: ['POST /v1/responses'], kinds: ['init'] } }, o => O.noChatgpt(o)],
    [{ ...good, chatgpt: { received: ['auth POST /api/accounts/oauth/token'], kinds: [] } }, o => O.noChatgpt(o)],
    [{ ...chatgptRun, chatgpt: { received: ['POST /v1/responses'], kinds: ['init', 'shape', 'build'] } }, o => O.chatgptAnswered(o, ['init', 'shape', 'build', 'review'])],
    [{ ...good, seam: [...good.seam, '/2.1.318/darwin-arm64/claude'] }, o => O.seamOnce(o)],
    [{ ...good, seam: [] }, o => O.seamOnce(o)],
    [{ ...good, seam: [...good.seam, '/latest'] }, o => O.seamOnce(o)],
    [{ ...chatgptRun, seam: ['/2.1.318/manifest.json'] }, o => O.seamNone(o)],
    [{ ...good, claude: { ...good.claude, schemas: [INIT_KEYS] } }, o => O.claudeRoles(o)],
    [{ ...good, claude: { ...good.claude, schemas: [['files', 'questions', 'blocked'], ['files', 'questions', 'blocked']] } }, o => O.claudeRoles(o)],
    [{ ...good, claude: { ...good.claude, build: 0 } }, o => O.claudeRoles(o)],
    [{ ...good, claude: { ...good.claude, review: 0 } }, o => O.claudeRoles(o)],
    [{ ...good, outputs: { ...good.outputs, 'init.out': 'models: shape: chatgpt has no stored login\n  fix: kogen provider login chatgpt\n' } }, o => O.noHint(o, HINT)],
    [{ ...good, outputs: { ...good.outputs, 'transcript.txt': good.transcript + 'run kogen provider login chatgpt\n' } }, o => O.noHint(o, HINT)],
    [{ ...good, models: claudeModels.replace('  build:\n    executor: claude-code', '  build:\n    provider: chatgpt') }, o => O.lineup(o, 'claude-code')],
    [{ ...good, models: claudeModels.replace('  review:\n    executor: claude-code', '  review:\n    executor: claude-code\n    provider: chatgpt') }, o => O.lineup(o, 'claude-code')],
    [{ ...good, models: claudeModels.split('  review:')[0] }, o => O.lineup(o, 'claude-code')],
    [{ ...good, models: '' }, o => O.lineup(o, 'claude-code')],
    [{ ...chatgptRun, models: claudeModels }, o => O.lineup(o, 'chatgpt')],
    [{ ...good, subject: 'Configure Kogen' }, o => O.landed(o, 'Add an is-even helper')],
    [{ ...good, calc: 'def add(a, b):\n    return a + b\n' }, o => O.landed(o, 'Add an is-even helper')],
    [{ ...leaked, code: 0 }, o => O.exit(o, 1)],
    [{ ...leaked, transcript: good.transcript }, o => O.lastLine(o, leakFail)],
    [{ ...leaked, leak: '' }, o => O.leakLists(o, '{run}/transcript.txt')],
    [{ ...leaked, leak: `${run}/project/leaked-token.json\n` }, o => O.leakLists(o, '{run}/transcript.txt')],
  ];
  const outcome = list => list.map(([o, f]) => { try { f(o); return true; } catch (e) { if (!(e instanceof assert.AssertionError)) throw e; return false; } });
  if (mode === 'good') {
    const results = outcome(checks);
    process.stdout.write(results.every(Boolean) ? 'accepted\n' : 'rejected\n');
    process.exitCode = results.every(Boolean) ? 0 : 1;
  } else {
    assert.equal(mode, 'bad');
    const results = outcome(bad);
    process.stdout.write(results.some(Boolean) ? 'accepted\n' : 'rejected\n');
    process.exitCode = results.some(Boolean) ? 0 : 1;
  }
}

// ------------------------------------------------------------------ the offline real-use run

const shq = s => `'${String(s).replace(/'/g, `'\\''`)}'`;
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
function put(p, text, mode) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, text);
  if (mode !== undefined) fs.chmodSync(p, mode);
}
const read = p => { try { return fs.readFileSync(p, 'utf8'); } catch { return ''; } };
function git(c, cwd, args) {
  const r = cp.spawnSync('git', args, { cwd, env: c.env, encoding: 'utf8' });
  assert.equal(r.status, 0, `git ${args.join(' ')} in ${cwd}: ${r.error || ''}${r.stdout}${r.stderr}`);
  return r.stdout;
}
function resolvePython() {
  const r = cp.spawnSync('python3', ['-c', 'import sys; print(sys.executable)'], { encoding: 'utf8' });
  assert.equal(r.status, 0, `python3 is needed for the py-calc fixture: ${r.error || ''}${r.stderr}`);
  return r.stdout.trim();
}
function archive() {
  if (process.env.KOGEN_ARCHIVE) return path.resolve(process.env.KOGEN_ARCHIVE);
  const dist = path.join(ROOT, 'dist');
  const found = (fs.existsSync(dist) ? fs.readdirSync(dist) : []).filter(n => /^kogen-.+\.tar\.gz$/.test(n))
    .map(n => path.join(dist, n)).sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
  assert.ok(found.length, `no release archive in ${dist}; the configured setup packages one with sh packaging/package.sh`);
  return found[0];
}
function platformKey() {
  if (process.platform === 'darwin' && process.arch === 'arm64') return 'darwin-arm64';
  if (process.platform === 'linux' && process.arch === 'x64') return 'linux-x64';
  throw new Error(`Kogen's managed Claude Code supports darwin-arm64 and linux-x64, not ${process.platform}/${process.arch}`);
}

// The fake Claude Code's script: kogen init's configuration, then the is-even Intent; the first
// Build invocation is held before it writes, later ones write the implementation; Review approves.
function claudeScript(version) {
  const { correctFiles } = require(FAKE_SERVERS);
  const writes = correctFiles().map(f => ({ write: { path: f.path, content: f.content } }));
  return {
    version: `${version} (Claude Code)`,
    roles: {
      shape: { rounds: [
        { actions: [], structured: { setup: [], fix: [], checks: [], protect: [] } },
        { actions: [{ read: 'README.md' }], structured_intent: { name: SLUG } },
        { actions: [], structured_intent: { name: SLUG, only: ['/acceptance.feature'] } },
      ] },
      build: { rounds: [
        { actions: [{ sleep: HOLD_SECONDS }, ...writes], claim: 'Implemented calc.is_even.' },
        { actions: writes, claim: 'Implemented calc.is_even.' },
      ] },
      review: { rounds: [{ actions: [{ read: 'calc.py' }], structured: { verdict: 'approve', findings: [] } }] },
    },
  };
}

// The loopback download origin: the official manifest shape at /<version>/manifest.json and the
// runtime at /<version>/<platform>/claude, a shim that runs the fake Claude Code.
async function serveRuntime(c) {
  const platform = platformKey();
  const script = path.join(c.d, 'claude-script.json');
  const binary = Buffer.from(`#!/bin/sh\nKOGEN_FAKE_CLAUDE_SCRIPT=${shq(script)} KOGEN_FAKE_CLAUDE_STATE=${shq(c.state)} exec ${shq(process.execPath)} ${shq(FAKE_CLAUDE)} "$@"\n`);
  const s = { requests: [] };
  s.http = http.createServer((req, res) => {
    s.requests.push(req.url);
    let m = /^\/([^/]+)\/manifest\.json$/.exec(req.url);
    if (m) {
      put(script, JSON.stringify(claudeScript(m[1])));
      const body = JSON.stringify({ version: m[1], platforms: { [platform]: { binary: 'claude', checksum: sha(binary), size: binary.length } } });
      res.writeHead(200, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) });
      return res.end(body);
    }
    m = /^\/([^/]+)\/([^/]+)\/claude$/.exec(req.url);
    if (m && m[2] === platform) {
      res.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': binary.length });
      return res.end(binary);
    }
    res.writeHead(404, { 'content-length': 0 });
    return res.end();
  });
  await new Promise((resolve, reject) => { s.http.once('error', reject); s.http.listen(0, '127.0.0.1', resolve); });
  s.url = `http://127.0.0.1:${s.http.address().port}`;
  return s;
}

// The fake ChatGPT server: every request is recorded (answered or refused), and the first Build
// request's turn is held for HOLD_SECONDS before it completes.
function fakeChatgpt() {
  const { FakeServers } = require(FAKE_SERVERS);
  class RealUseServers extends FakeServers {
    constructor() { super(); this.received = []; this.heldBuild = false; }
    handleProvider(req, res) { this.received.push(`${req.method} ${req.url}`); return super.handleProvider(req, res); }
    handleAuth(req, res) { this.received.push(`auth ${req.method} ${req.url}`); return super.handleAuth(req, res); }
    scriptResponse(record, ordinal) {
      const outcome = super.scriptResponse(record, ordinal);
      if (record.kind !== 'build' || this.heldBuild) return outcome;
      this.heldBuild = true;
      setTimeout(() => this.continue(), HOLD_SECONDS * 1000).unref();
      return { ...outcome, pause: 'first build request' };
    }
  }
  return new RealUseServers();
}

async function setup(world, route) {
  assert.ok(route === 'claude-code' || route === 'chatgpt', `unknown route ${route}`);
  const d = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-klr-')));
  const c = { d, route, leak: null, home: path.join(d, 'host-home'), origin: path.join(d, 'origin'), run: path.join(d, 'run'), state: path.join(d, 'claude-state'), settings: path.join(d, `${PROJECT}.sh`) };
  world.klr = c;
  // The host's own Git configuration that real-use.sh includes: an identity, no signing.
  put(path.join(c.home, '.gitconfig'), '[user]\n\tname = Real Use Fixture\n\temail = real-use@example.invalid\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n');
  const env = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (!/^(KOGEN_|GIT_|ANTHROPIC_|CLAUDE_|OPENAI_)/.test(k) && !['NODE_PATH', 'NODE_OPTIONS', 'DISABLE_UPDATES', 'DISABLE_AUTOUPDATER'].includes(k)) env[k] = v;
  }
  env.PATH = [path.dirname(process.execPath), path.dirname(resolvePython()), process.env.PATH].join(path.delimiter);
  Object.assign(env, { HOME: c.home, GIT_CONFIG_NOSYSTEM: '1', KOGEN_NO_BROWSER: '1', KOGEN_LIVE_RUN_DIR: c.run });
  c.env = env;
  fs.cpSync(PY_CALC, c.origin, { recursive: true });
  for (const a of [['init', '-q'], ['add', '-A'], ['commit', '-qm', 'py-calc baseline']]) git(c, c.origin, a);
  c.fake = fakeChatgpt();
  await c.fake.start();
  c.seam = await serveRuntime(c);
  Object.assign(env, { KOGEN_PROVIDER_URL: c.fake.providerUrl, KOGEN_AUTH_URL: c.fake.authUrl, KOGEN_CLAUDE_CODE_URL: c.seam.url });
  if (route === 'claude-code') {
    const token = path.join(d, 'claude-code-token.txt');
    put(token, `${CLAUDE_TOKEN}\n`, 0o600);
    env.KOGEN_LIVE_CREDENTIALS = `kogen provider login claude-code < ${shq(token)}`;
  } else {
    const { FAKE_ACCESS_TOKEN, FAKE_REFRESH_TOKEN } = require(FAKE_SERVERS);
    c.fake.configure('shape-ready-is-even');
    const login = path.join(d, 'chatgpt.json');
    put(login, JSON.stringify({ client_id: 'oaiapp_real_use_fixture', access_token: FAKE_ACCESS_TOKEN, refresh_token: FAKE_REFRESH_TOKEN, expires_at: Math.floor(Date.now() / 1000) + 30 * 24 * 3600 }), 0o600);
    env.KOGEN_LIVE_CREDENTIALS = `umask 077 && mkdir -p "$HOME/.kogen/credentials" && cp ${shq(login)} "$HOME/.kogen/credentials/chatgpt.json"`;
  }
}

function settingsText(c) {
  const leak = c.leak === 'transcript' ? '  cat "$HOME/.kogen/credentials/claude-code.json"\n'
    : c.leak === 'project' ? '  cp "$HOME/.kogen/credentials/claude-code.json" leaked-token.json\n' : '';
  return `# py-calc for k-live-real-use-claude's offline real-use runs.
REPO=${shq(c.origin)}
SLUG=${SLUG}
REQUEST='Add calc.is_even(n) to calc.py: it returns True for even integers and False for odd ones, and raises TypeError for a value that is not an integer.'
INTERRUPT_AFTER=15
configure() { :; }
verify_without_kogen() {
  python3 -m unittest -q
${leak}}
`;
}

async function runRealUse(c) {
  put(c.settings, settingsText(c));
  const url = `file://${archive()}`;
  const outFile = path.join(c.d, 'real-use.out');
  const fd = fs.openSync(outFile, 'w');
  let child;
  try {
    child = cp.spawn('/bin/sh', [path.join(ROOT, 'test/live/real-use.sh'), c.settings, url], { cwd: c.d, env: c.env, stdio: ['ignore', fd, fd], detached: true });
  } finally { fs.closeSync(fd); }
  c.code = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      // Only the process group this step started.
      try { process.kill(-child.pid, 'SIGKILL'); } catch { /* already gone */ }
      resolve(`killed after ${RUN_LIMIT / MIN} minutes`);
    }, RUN_LIMIT);
    child.once('error', error => { clearTimeout(timer); reject(error); });
    child.once('exit', (code, signal) => { clearTimeout(timer); resolve(code === null ? `signal ${signal}` : code); });
  });
  c.output = read(outFile);
}

function schemaKeys(file) {
  try {
    const args = JSON.parse(fs.readFileSync(file, 'utf8'));
    const i = args.indexOf('--json-schema');
    return Object.keys(JSON.parse(args[i + 1]).properties || {});
  } catch { return []; }
}

function collect(c) {
  const outputs = {};
  if (fs.existsSync(c.run)) {
    for (const e of fs.readdirSync(c.run, { withFileTypes: true })) {
      if (e.isFile() && e.name !== 'kogen.tar.gz') outputs[e.name] = read(path.join(c.run, e.name));
    }
  }
  const project = path.join(c.run, 'project');
  const show = args => {
    if (!fs.existsSync(path.join(project, '.git'))) return '';
    const r = cp.spawnSync('git', args, { cwd: project, env: c.env, encoding: 'utf8' });
    return r.status === 0 ? r.stdout : '';
  };
  const count = name => Number(read(path.join(c.state, name)).trim() || 0);
  const schemas = [];
  for (let n = 1; fs.existsSync(path.join(c.state, `argv-shape-${n}.json`)); n++) schemas.push(schemaKeys(path.join(c.state, `argv-shape-${n}.json`)));
  return {
    code: c.code, run: c.run, output: c.output, outputs,
    transcript: outputs['transcript.txt'] || '', leak: outputs['leak.txt'] || '',
    models: show(['show', 'HEAD:.kogen/models.yaml']), subject: show(['log', '-1', '--format=%s']).trim(), calc: show(['show', 'HEAD:calc.py']),
    chatgpt: { received: c.fake.received.slice(), kinds: c.fake.requests.map(r => r.kind) },
    seam: c.seam.requests.slice(),
    claude: { shape: count('calls-shape'), build: count('calls-build'), review: count('calls-review'), schemas },
  };
}

if (require.main === module) {
  if (process.argv[2] !== 'control' || !['good', 'bad'].includes(process.argv[3])) {
    process.stderr.write('usage: node k-live-real-use-claude__real_use.js control good|bad\n');
    process.exitCode = 2;
  } else {
    controls(process.argv[3]);
  }
} else {
  const { Given, When, Then, After } = require('@cucumber/cucumber');
  const ctx = world => { assert.ok(world.klr && world.klr.code !== undefined, 'the real-use script has not run in this scenario'); return collect(world.klr); };

  Given(P + 'a fresh real-use run whose only login is {string}', { timeout: 2 * MIN }, async function (route) { await setup(this, route); });
  Given(P + "the project's own checks copy the saved claude-code token into the {word}", function (place) {
    assert.ok(this.klr, 'no real-use run was set up');
    assert.ok(place === 'transcript' || place === 'project', `unknown place ${place}`);
    this.klr.leak = place;
  });
  When(P + 'the real-use script runs on the py-calc fixture', { timeout: RUN_LIMIT + 2 * MIN }, async function () { await runRealUse(this.klr); });

  Then(P + 'the real-use script exits {int}', function (n) { O.exit(ctx(this), n); });
  Then(P + 'the transcript has these lines in order:', function (table) { O.inOrder(ctx(this), table.raw().map(row => row[0])); });
  Then(P + "the transcript's last line is {string}", function (line) { O.lastLine(ctx(this), line); });
  Then(P + 'the leak report lists {string}', function (file) { O.leakLists(ctx(this), file); });
  Then(P + 'the fake ChatGPT server received no request', function () { O.noChatgpt(ctx(this)); });
  Then(P + 'the fake ChatGPT server answered init, shape, build and review requests', function () { O.chatgptAnswered(ctx(this), ['init', 'shape', 'build', 'review']); });
  Then(P + 'no transcript or command output contains {string}', function (text) { O.noHint(ctx(this), text); });
  Then(P + 'the Claude Code download origin served the runtime once', function () { O.seamOnce(ctx(this)); });
  Then(P + 'the Claude Code download origin received no request', function () { O.seamNone(ctx(this)); });
  Then(P + 'the fake Claude Code runtime answered kogen init and then the shape, build and review roles', function () { O.claudeRoles(ctx(this)); });
  Then(P + 'the landed .kogen\\/models.yaml runs shape, build and review on {string}', function (route) { O.lineup(ctx(this), route); });
  Then(P + 'the landed commit is {string} and adds calc.is_even', function (title) { O.landed(ctx(this), title); });

  After({ timeout: 2 * MIN }, async function (scenario) {
    const c = this.klr;
    if (!c) return;
    if (c.fake) await c.fake.close();
    if (c.seam) await new Promise(resolve => { c.seam.http.closeAllConnections(); c.seam.http.close(() => resolve()); });
    // A failed scenario keeps its folder: the assertion messages name it.
    if (scenario.result && scenario.result.status === 'PASSED') fs.rmSync(c.d, { recursive: true, force: true });
  });
}
