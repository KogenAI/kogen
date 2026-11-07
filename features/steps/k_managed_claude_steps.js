'use strict';
// K-MANAGED-CLAUDE acceptance: the installed Kogen installs and runs its own pinned Claude Code
// runtime (2.1.318, under ~/.kogen/claude-code) from the loopback download seam
// KOGEN_CLAUDE_CODE_URL, never the Claude Code on PATH, and leaves the user's own Claude Code
// setup untouched. The served or seeded runtime is a wrapper that records how Kogen started it
// and then runs the repository's fake claude (test/acceptance/fixtures/claude/fake-claude.js),
// which runs Kogen's hooks like Claude Code does. Nothing here contacts the network or a model.
//
// Every Then step checks one collected observation with a pure checker below.
// `node features/steps/k_managed_claude_steps.js control good|bad` runs the same checkers on a
// known-good observation (prints `accepted`, exit 0) and on known-bad ones (prints `rejected`,
// exit 1), independently of the unimplemented feature.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const FAKE = path.join(ROOT, 'test/acceptance/fixtures/claude/fake-claude.js');
const PIN = '2.1.318';
const SLUG = 'managed-fixture';
const MIN = 60000;
const RUNNER = 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require "features/steps/*.js" --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"';
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const unescape = s => s.replaceAll('\\n', '\n');

// ------------------------------------------------------------------ pure checkers

function expand(text, o) {
  return text.replaceAll('<home>', o.home).replaceAll('<server>', o.server)
    .replaceAll('<platform>', o.platform).replaceAll('<served-sha256>', o.servedSha);
}
const outLines = r => r.out.split('\n').map(l => l.replace(/\r$/, ''));

const C = {
  landed(o, file, content) {
    assert.equal(o.result.code, 0, `the Build did not land (exit ${o.result.code}):\n${o.result.out}`);
    assert.notEqual(o.headAfter, o.headBefore, 'the Build made no commit');
    assert.equal(o.committed[file], unescape(content), `${file} at HEAD`);
  },
  line(o, text) {
    const want = expand(text, o);
    assert.ok(outLines(o.result).includes(want), `no output line ${JSON.stringify(want)} in:\n${o.result.out}`);
  },
  refused(o, cls, message) {
    const want = expand(message, o);
    assert.equal(o.result.code, 1, `expected exit 1 (${cls}), got ${o.result.code}:\n${o.result.out}`);
    assert.ok(o.result.out.includes(cls), `no ${cls} in:\n${o.result.out}`);
    assert.ok(o.result.out.includes(want), `no message ${JSON.stringify(want)} in:\n${o.result.out}`);
  },
  runtimeBytes(o, file) {
    const p = expand(file, o), f = o.files[p];
    assert.ok(f && f.type === 'file', `${p} is not an installed regular file: ${JSON.stringify(f)}`);
    assert.equal(f.sha, o.servedSha, `${p} does not hold exactly the served runtime bytes`);
    assert.equal(f.mode & 0o111, 0o111, `${p} mode ${f.mode.toString(8)} is not executable`);
  },
  servedTimes(o, version, n) {
    const p = `/${version}/${o.platform}/claude`;
    assert.equal(o.downloads.filter(x => x === p).length, n, `downloads of ${p}: ${JSON.stringify(o.downloads)}`);
  },
  noDownload(o) { assert.deepEqual(o.downloads, [], 'the download server received requests'); },
  children(o, self, config, updates) {
    const want = expand(self, o), partial = `${o.home}/.kogen/claude-code/.partial-`;
    assert.ok(o.children.some(c => c.self === want), `no Claude Code child ran ${want}: ${JSON.stringify(o.children.map(c => c.self))}`);
    for (const c of o.children) {
      const verifying = c.self.startsWith(partial) && JSON.stringify(c.args) === '["--version"]';
      assert.ok(c.self === want || verifying, `a Claude Code child ran ${c.self} ${JSON.stringify(c.args)}`);
      assert.equal(c.config, expand(config, o), `CLAUDE_CONFIG_DIR of ${c.self} ${JSON.stringify(c.args)}`);
      assert.equal(c.updates, updates, `DISABLE_UPDATES of ${c.self} ${JSON.stringify(c.args)}`);
    }
  },
  neverStarted(o) { assert.deepEqual(o.children, [], 'a downloaded or installed runtime was started'); },
  roles(o) {
    assert.ok(o.roles.build >= 1, 'the build role never ran on the managed runtime');
    assert.ok(o.roles.review >= 1, 'the review role never ran on the managed runtime');
  },
  noRounds(o) {
    assert.equal(o.roles.build + o.roles.review + o.roles.shape, 0, `Claude Code rounds ran: ${JSON.stringify(o.roles)}`);
    assert.ok(!o.children.some(c => c.args[0] === '-p'), 'a Claude Code round was started');
  },
  hook(o, file) {
    assert.ok(o.hooks.some(h => h.hook === 'pretool' && h.tool_name === 'Write' && String(h.path || '').endsWith(file) && h.decision === 'allow'),
      `no allowed PreToolUse record of Kogen's hook for ${file}: ${JSON.stringify(o.hooks)}`);
  },
  dirMode(o, dir, mode) {
    const p = expand(dir, o), f = o.files[p];
    assert.ok(f && f.type === 'dir', `${p} is not a directory: ${JSON.stringify(f)}`);
    assert.equal((f.mode & 0o777).toString(8), mode, `${p} mode`);
  },
  noPartial(o) {
    const left = (o.managed || []).filter(n => n.startsWith('.partial-'));
    assert.deepEqual(left, [], 'partial installation directories remain');
  },
  nothingInstalled(o, version) {
    assert.ok(!(o.managed || []).includes(version), `${version} was installed: ${JSON.stringify(o.managed)}`);
    C.noPartial(o);
  },
  pathNeverRun(o) { assert.deepEqual(o.pathRuns, [], 'the Claude Code on PATH was run'); },
  setupUnchanged(o) {
    assert.ok(Object.keys(o.setupBefore || {}).length >= 8, 'the customized user setup was not recorded');
    assert.deepEqual(o.setupAfter, o.setupBefore, "the user's own Claude Code setup changed");
  },
  oldUnchanged(o) {
    assert.ok(o.oldBefore, 'no earlier runtime was recorded');
    assert.deepEqual(o.oldAfter, o.oldBefore, 'the earlier runtime changed');
    assert.deepEqual(o.oldRuns, [], 'the earlier runtime was run');
  },
  projectUnchanged(o) {
    assert.equal(o.headAfter, o.headBefore, 'HEAD moved');
    assert.equal(o.app, 'baseline\n', 'app.txt changed');
  },
  listLine(o, text) {
    assert.equal(o.list.code, 0, o.list.out);
    assert.ok(outLines(o.list).includes(expand(text, o)), `no provider list line ${JSON.stringify(expand(text, o))} in:\n${o.list.out}`);
  },
  listAfter(o, text, before) {
    const lines = outLines(o.list), i = lines.indexOf(expand(before, o));
    assert.ok(i >= 0, `no provider list line ${JSON.stringify(before)} in:\n${o.list.out}`);
    assert.equal(lines[i + 1], expand(text, o), `the line after ${JSON.stringify(before)}`);
  },
  uninstalled(o, text) {
    assert.equal(o.uninstall.code, 0, o.uninstall.out);
    const lines = outLines(o.uninstall), i = lines.indexOf(expand(text, o));
    assert.ok(i > 0 && lines[i - 1].startsWith('Uninstalled kogen from ') && String(lines[i + 1]).startsWith('Kept your '),
      `${JSON.stringify(expand(text, o))} is not the line between the Uninstalled and Kept lines:\n${o.uninstall.out}`);
  },
  absent(o, p) { assert.strictEqual(o.files[expand(p, o)], null, `${expand(p, o)} still exists`); },
  tokenUnchanged(o) {
    const p = `${o.home}/.kogen/credentials/claude-code.json`;
    assert.ok(o.tokenBefore, 'no saved token was recorded');
    assert.deepEqual(o.files[p], o.tokenBefore, 'the saved Claude Code token changed');
  },
};
const runAll = (o, checks) => { for (const [fn, ...args] of checks) fn(o, ...args); };

// ------------------------------------------------------------------ controls

function controls(bad) {
  const home = '/h', m = `${home}/.kogen/claude-code`, rt = `${m}/2.1.318/claude`, cfg = `${m}/config`;
  const cred = `${home}/.kogen/credentials/claude-code.json`, served = 'a'.repeat(64);
  const env = { config: cfg, updates: '1' };
  const setup = {};
  for (const p of ['.claude', '.claude/settings.json', '.claude/CLAUDE.md', '.claude/skills', '.claude/skills/user-skill', '.claude/skills/user-skill/SKILL.md', '.claude/.credentials.json', '.claude.json', '.local/bin', '.local/bin/claude'])
    setup[`${home}/${p}`] = p.includes('.') && !p.endsWith('.claude') ? { type: 'file', mode: 0o644, sha: sha(p) } : { type: 'dir', mode: 0o755 };
  const base = {
    home, server: 'http://127.0.0.1:9', platform: 'darwin-arm64', servedSha: served,
    result: { code: 0, out: '' }, list: { code: null, out: '' }, uninstall: { code: null, out: '' },
    children: [], roles: { build: 0, review: 0, shape: 0 }, hooks: [], pathRuns: [], oldRuns: [],
    setupBefore: setup, setupAfter: structuredClone(setup), oldBefore: null, oldAfter: null,
    managed: ['config', 'install.lock'], files: { [rt]: null, [cfg]: { type: 'dir', mode: 0o700 }, [m]: { type: 'dir', mode: 0o700 }, [cred]: null },
    tokenBefore: null, headBefore: '1'.repeat(40), headAfter: '1'.repeat(40), app: 'baseline\n', committed: { 'app.txt': 'baseline\n' }, downloads: [],
  };
  const landed = structuredClone(base);
  Object.assign(landed, {
    result: { code: 0, out: `kogen: installing Claude Code 2.1.318 into ${m}/2.1.318\nkogen: installed Claude Code 2.1.318 (sha256 ${served})\nLanded\n` },
    list: { code: 0, out: `chatgpt: not signed in\nclaude-code runtime: Claude Code 2.1.318 installed (${rt})\n` },
    children: [{ self: `${m}/.partial-ab12/claude`, args: ['--version'], ...env }, { self: rt, args: ['--version'], ...env }, { self: rt, args: ['auth', 'status', '--json'], ...env }, { self: rt, args: ['-p', '--session-id', 'x'], ...env }],
    roles: { build: 1, review: 1, shape: 0 }, hooks: [{ hook: 'pretool', tool_name: 'Write', path: 'app.txt', decision: 'allow' }],
    oldBefore: { type: 'file', mode: 0o755, sha: 'b'.repeat(64) }, oldAfter: { type: 'file', mode: 0o755, sha: 'b'.repeat(64) },
    managed: ['2.1.300', '2.1.318', 'config', 'install.lock'], headAfter: '2'.repeat(40), app: 'built on the managed Claude Code\n',
    committed: { 'app.txt': 'built on the managed Claude Code\n' }, downloads: ['/2.1.318/manifest.json', '/2.1.318/darwin-arm64/claude'],
  });
  landed.files[rt] = { type: 'file', mode: 0o755, sha: served };
  const landedChecks = [
    [C.landed, 'app.txt', 'built on the managed Claude Code\\n'],
    [C.line, 'kogen: installing Claude Code 2.1.318 into <home>/.kogen/claude-code/2.1.318'],
    [C.line, 'kogen: installed Claude Code 2.1.318 (sha256 <served-sha256>)'],
    [C.runtimeBytes, '<home>/.kogen/claude-code/2.1.318/claude'], [C.servedTimes, '2.1.318', 1],
    [C.children, '<home>/.kogen/claude-code/2.1.318/claude', '<home>/.kogen/claude-code/config', '1'],
    [C.roles], [C.hook, 'app.txt'], [C.dirMode, '<home>/.kogen/claude-code/config', '700'], [C.noPartial],
    [C.pathNeverRun], [C.oldUnchanged], [C.setupUnchanged],
    [C.listLine, 'claude-code runtime: Claude Code 2.1.318 installed (<home>/.kogen/claude-code/2.1.318/claude)'],
  ];
  const refused = structuredClone(base);
  Object.assign(refused, {
    result: { code: 1, out: 'executor/unavailable: the downloaded Claude Code reports 2.1.314 (Claude Code), not 2.1.318; nothing was installed\n' },
    children: [{ self: `${m}/.partial-cd34/claude`, args: ['--version'], ...env }], downloads: ['/2.1.318/manifest.json', '/2.1.318/darwin-arm64/claude'],
  });
  const refusedChecks = [
    [C.refused, 'executor/unavailable', 'the downloaded Claude Code reports 2.1.314 (Claude Code), not 2.1.318; nothing was installed'],
    [C.nothingInstalled, '2.1.318'], [C.noRounds], [C.projectUnchanged], [C.pathNeverRun], [C.setupUnchanged],
  ];
  const kept = structuredClone(base);
  Object.assign(kept, {
    result: { code: 1, out: `executor/unavailable: the downloaded Claude Code 2.1.318 does not match its pinned SHA-256; nothing was installed\n` },
    downloads: ['/2.1.318/manifest.json', '/2.1.318/darwin-arm64/claude'],
  });
  const keptChecks = [
    [C.refused, 'executor/unavailable', 'the downloaded Claude Code 2.1.318 does not match its pinned SHA-256; nothing was installed'],
    [C.nothingInstalled, '2.1.318'], [C.neverStarted], [C.projectUnchanged],
  ];
  const wrong = structuredClone(base);
  Object.assign(wrong, {
    result: { code: 1, out: `executor/unavailable: Kogen's Claude Code at ${rt} reports 2.1.314 (Claude Code), not the pinned 2.1.318; remove ${m}/2.1.318 to reinstall it\n` },
    children: [{ self: rt, args: ['--version'], ...env }], managed: ['2.1.318', 'config'],
  });
  wrong.files[rt] = { type: 'file', mode: 0o755, sha: 'c'.repeat(64) };
  const wrongChecks = [
    [C.refused, 'executor/unavailable', "Kogen's Claude Code at <home>/.kogen/claude-code/2.1.318/claude reports 2.1.314 (Claude Code), not the pinned 2.1.318; remove <home>/.kogen/claude-code/2.1.318 to reinstall it"],
    [C.noDownload], [C.noRounds], [C.projectUnchanged], [C.pathNeverRun],
  ];
  const status = structuredClone(base);
  status.list = { code: 0, out: 'chatgpt: not signed in\nclaude-code: token saved (not verified)\nclaude-code runtime: Claude Code 2.1.318 not installed\nOfficial compatibility (text/tool input, normal routes only):\n' };
  const statusChecks = [
    [C.listLine, 'claude-code runtime: Claude Code 2.1.318 not installed'],
    [C.listAfter, 'claude-code runtime: Claude Code 2.1.318 not installed', 'claude-code: token saved (not verified)'],
  ];
  const removed = structuredClone(base);
  Object.assign(removed, {
    uninstall: { code: 0, out: `Uninstalled kogen from /p\nRemoved Kogen's Claude Code runtime from ${m}\nKept your ChatGPT logins\n` },
    tokenBefore: { type: 'file', mode: 0o600, sha: 'd'.repeat(64) }, managed: null,
  });
  removed.files[m] = null; removed.files[cfg] = null; removed.files[cred] = { type: 'file', mode: 0o600, sha: 'd'.repeat(64) };
  const removedChecks = [
    [C.uninstalled, "Removed Kogen's Claude Code runtime from <home>/.kogen/claude-code"], [C.absent, '<home>/.kogen/claude-code'],
    [C.tokenUnchanged], [C.setupUnchanged], [C.pathNeverRun],
  ];
  const cases = [[landed, landedChecks], [refused, refusedChecks], [kept, keptChecks], [wrong, wrongChecks], [status, statusChecks], [removed, removedChecks]];
  for (const [o, checks] of cases) runAll(o, checks);
  if (!bad) { process.stdout.write('accepted\n'); return; }
  const rejected = (o, checks, mutate) => {
    const copy = structuredClone(o); mutate(copy);
    assert.throws(() => runAll(copy, checks), Error, `observer accepted a known-bad observation: ${mutate}`);
  };
  for (const mutate of [
    x => { x.children[3].self = `${home}/.local/bin/claude`; },
    x => { x.children[0].config = `${home}/.claude`; },
    x => { x.children[2].config = null; },
    x => { x.children[3].updates = null; },
    x => { x.children.push({ self: `${m}/2.1.300/claude`, args: ['-p'], ...env }); },
    x => { x.pathRuns = [`${home}/.local/bin/claude -p`]; },
    x => { x.oldRuns = ['2.1.300 --version']; },
    x => { x.oldAfter.sha = 'e'.repeat(64); },
    x => { x.setupAfter[`${home}/.claude/settings.json`].sha = 'f'.repeat(64); },
    x => { delete x.setupAfter[`${home}/.claude.json`]; },
    x => { x.files[rt].sha = 'f'.repeat(64); },
    x => { x.files[rt].mode = 0o644; },
    x => { x.downloads.push('/2.1.318/darwin-arm64/claude'); },
    x => { x.hooks = []; },
    x => { x.hooks[0].decision = 'deny'; },
    x => { x.roles.review = 0; },
    x => { x.result.out = x.result.out.replace('kogen: installing', 'kogen: fetching'); },
    x => { x.result.out = x.result.out.replace(served, 'f'.repeat(64)); },
    x => { x.result.code = 1; },
    x => { x.committed['app.txt'] = 'baseline\n'; },
    x => { x.headAfter = x.headBefore; },
    x => { x.files[cfg].mode = 0o755; },
    x => { x.managed.push('.partial-ab12'); },
    x => { x.list.out = 'claude-code runtime: Claude Code 2.1.318 not installed\n'; },
  ]) rejected(landed, landedChecks, mutate);
  for (const mutate of [
    x => { x.result.code = 0; },
    x => { x.result.out = 'executor/unavailable: something else\n'; },
    x => { x.result.out = x.result.out.replace('executor/unavailable', 'executor/failed'); },
    x => { x.managed.push('2.1.318'); },
    x => { x.managed.push('.partial-cd34'); },
    x => { x.children.push({ self: rt, args: ['-p'], ...env }); },
    x => { x.roles.build = 1; },
    x => { x.headAfter = '3'.repeat(40); },
    x => { x.app = 'built on the managed Claude Code\n'; },
    x => { x.pathRuns = ['claude --version']; },
    x => { x.setupAfter[`${home}/.claude/.credentials.json`].mode = 0o600; },
  ]) rejected(refused, refusedChecks, mutate);
  rejected(kept, keptChecks, x => { x.children.push({ self: `${m}/.partial-ef56/claude`, args: ['--version'], ...env }); });
  rejected(kept, keptChecks, x => { x.managed.push('2.1.318'); });
  rejected(wrong, wrongChecks, x => { x.downloads.push('/2.1.318/manifest.json'); });
  rejected(wrong, wrongChecks, x => { x.result.out = x.result.out.replace('2.1.314 (Claude Code)', '2.1.314'); });
  rejected(status, statusChecks, x => { x.list.out = 'claude-code runtime: Claude Code 2.1.318 not installed\nclaude-code: token saved (not verified)\n'; });
  rejected(status, statusChecks, x => { x.list.out = 'claude-code: token saved (not verified)\n'; });
  for (const mutate of [
    x => { x.uninstall.code = 3; },
    x => { x.uninstall.out = 'Uninstalled kogen from /p\nKept your ChatGPT logins\n'; },
    x => { x.uninstall.out = `Removed Kogen's Claude Code runtime from ${m}\nUninstalled kogen from /p\nKept your ChatGPT logins\n`; },
    x => { x.files[m] = { type: 'dir', mode: 0o700 }; },
    x => { x.files[cred] = null; },
    x => { x.files[cred].sha = 'f'.repeat(64); },
    x => { x.setupAfter[`${home}/.local/bin/claude`] = null; },
  ]) rejected(removed, removedChecks, mutate);
  process.stdout.write('rejected\n');
  process.exitCode = 1;
}

// ------------------------------------------------------------------ observation and steps

if (require.main === module) {
  try { assert.equal(process.argv[2], 'control'); controls(process.argv[3] === 'bad'); }
  catch (e) { process.stderr.write(`${e.message}\n`); process.exitCode = 2; }
} else {
  const { Given, When, Then, After } = require('@cucumber/cucumber');
  const H = require('./go_driver_support.js');

  const put = (p, s, mode) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, s); if (mode !== undefined) fs.chmodSync(p, mode); };
  const lines = f => (fs.existsSync(f) ? fs.readFileSync(f, 'utf8').split('\n').filter(Boolean) : []);
  const jsonl = f => lines(f).map(l => JSON.parse(l));
  const count = f => (fs.existsSync(f) ? Number(fs.readFileSync(f, 'utf8').trim()) : 0);
  // The lstat-level state of one path: null when absent, never following a symlink.
  function state(p) {
    let st;
    try { st = fs.lstatSync(p); } catch { return null; }
    if (st.isSymbolicLink()) return { type: 'link', mode: st.mode & 0o7777, target: fs.readlinkSync(p) };
    if (st.isDirectory()) return { type: 'dir', mode: st.mode & 0o7777 };
    return { type: 'file', mode: st.mode & 0o7777, sha: sha(fs.readFileSync(p)) };
  }
  function tree(p, out) {
    const s = state(p);
    if (!s) return out;
    out[p] = s;
    if (s.type === 'dir') for (const n of fs.readdirSync(p).sort()) tree(path.join(p, n), out);
    return out;
  }
  // The user's own Claude Code: settings, plugins, skills, credentials, global config and install.
  function userSetup(home) {
    const out = {};
    for (const p of ['.claude', '.claude.json', '.local/bin', '.local/share/claude']) tree(path.join(home, p), out);
    return out;
  }
  function find(dir, name, out = []) {
    if (!fs.existsSync(dir)) return out;
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) find(p, name, out); else if (e.name === name) out.push(p);
    }
    return out;
  }
  function platformKey() {
    if (process.platform === 'darwin' && process.arch === 'arm64') return 'darwin-arm64';
    if (process.platform === 'linux' && process.arch === 'x64') return 'linux-x64';
    throw new Error(`Kogen's managed Claude Code supports darwin-arm64 and linux-x64, not ${process.platform}/${process.arch}`);
  }
  function ctx(world) { assert.ok(world.kmc, 'no managed-runtime user was set up'); return world.kmc; }
  function git(c, args) {
    const r = spawnSync('git', args, { cwd: c.repo, env: c.env, encoding: 'utf8' });
    assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.stdout}${r.stderr}`);
    return r.stdout;
  }
  const kogen = (c, args, input) => H.run(c.bin, args, { cwd: c.repo || c.d, env: c.env, input, timeout: 8 * MIN });

  // The Claude Code fake's script: the Build writes app.txt, the Review approves.
  function script(version, extra = {}) {
    return {
      version, ...extra, roles: {
        build: { rounds: [{ actions: [{ write: { path: 'app.txt', content: 'built on the managed Claude Code\n' } }], claim: 'Wrote app.txt.' }] },
        review: { rounds: [{ structured: { verdict: 'approve', findings: [] }, actions: [{ read: 'app.txt' }] }] },
      },
    };
  }
  // A runtime executable: it records its own path, argv, CLAUDE_CONFIG_DIR and DISABLE_UPDATES,
  // then runs the repository's fake claude with the given script.
  function wrapper(c, label, scriptValue) {
    const scriptPath = path.join(c.state, `script-${label}.json`);
    put(scriptPath, JSON.stringify(scriptValue));
    return Buffer.from(`#!${process.execPath}
'use strict';
const fs = require('node:fs');
const cp = require('node:child_process');
const args = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(path.join(c.state, 'runtime-children.jsonl'))}, JSON.stringify({ self: process.argv[1], args, config: process.env.CLAUDE_CONFIG_DIR ?? null, updates: process.env.DISABLE_UPDATES ?? null }) + '\\n');
const r = cp.spawnSync(process.execPath, [${JSON.stringify(FAKE)}, ...args], { stdio: 'inherit', env: { ...process.env, KOGEN_FAKE_CLAUDE_SCRIPT: ${JSON.stringify(scriptPath)}, KOGEN_FAKE_CLAUDE_STATE: ${JSON.stringify(path.join(c.state, 'fake'))} } });
process.exit(r.status === null ? 1 : r.status);
`);
  }
  // The loopback download seam: the official manifest shape and the runtime at
  // /<version>/<platform>/claude. `drop` closes the connection halfway through the runtime.
  async function serve(c, mode, reported) {
    if (!c.server) {
      const s = { requests: [], generation: 0 };
      s.http = http.createServer((req, res) => {
        s.requests.push(req.url);
        if (req.url === `/${PIN}/manifest.json`) {
          const body = JSON.stringify({ version: PIN, platforms: { [c.platform]: { binary: 'claude', checksum: s.checksum, size: s.binary.length } } });
          res.writeHead(200, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) });
          return res.end(body);
        }
        if (req.url === `/${PIN}/${c.platform}/claude`) {
          res.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': s.binary.length });
          if (s.mode === 'drop') return res.write(s.binary.subarray(0, Math.floor(s.binary.length / 2)), () => res.socket.destroy());
          return res.end(s.binary);
        }
        res.writeHead(404, { 'content-length': 0 });
        return res.end();
      });
      await new Promise(resolve => s.http.listen(0, '127.0.0.1', resolve));
      s.url = `http://127.0.0.1:${s.http.address().port}`;
      c.env.KOGEN_CLAUDE_CODE_URL = s.url;
      c.server = s;
    }
    const s = c.server;
    s.mode = mode;
    s.binary = wrapper(c, `served-${s.generation++}`, script(reported || `${PIN} (Claude Code)`));
    s.checksum = mode === 'mismatch' ? sha('not the served runtime') : sha(s.binary);
  }

  function collect(c) {
    const m = path.join(c.home, '.kogen/claude-code');
    const watched = [path.join(m, `${PIN}/claude`), path.join(m, 'config'), m, path.join(c.home, '.kogen/credentials/claude-code.json')];
    const show = c.repo ? spawnSync('git', ['show', 'HEAD:app.txt'], { cwd: c.repo, env: c.env, encoding: 'utf8' }) : { status: 1 };
    const app = c.repo ? path.join(c.repo, 'app.txt') : '';
    return {
      home: c.home, server: c.server ? c.server.url : '', platform: c.platform, servedSha: c.server ? sha(c.server.binary) : '',
      result: c.last || { code: null, out: '' }, list: c.list || { code: null, out: '' }, uninstall: c.uninstallResult || { code: null, out: '' },
      children: jsonl(path.join(c.state, 'runtime-children.jsonl')),
      roles: { build: count(path.join(c.state, 'fake/calls-build')), review: count(path.join(c.state, 'fake/calls-review')), shape: count(path.join(c.state, 'fake/calls-shape')) },
      hooks: c.repo ? find(path.join(c.repo, '.kogen/local'), 'hook-log.jsonl').flatMap(jsonl) : [],
      pathRuns: lines(path.join(c.state, 'path-claude.log')), oldRuns: lines(path.join(c.state, 'old-runtime.log')),
      setupBefore: c.setupBefore, setupAfter: userSetup(c.home),
      oldBefore: c.oldBefore || null, oldAfter: c.oldPath ? state(c.oldPath) : null,
      managed: fs.existsSync(m) ? fs.readdirSync(m).sort() : null,
      files: Object.fromEntries(watched.map(p => [p, state(p)])),
      tokenBefore: c.tokenBefore || null,
      headBefore: c.headBefore || null, headAfter: c.repo ? git(c, ['rev-parse', 'HEAD']).trim() : null,
      app: app && fs.existsSync(app) ? fs.readFileSync(app, 'utf8') : null,
      committed: { 'app.txt': show.status === 0 ? show.stdout : null },
      downloads: c.server ? c.server.requests.slice() : [],
    };
  }

  Given('a managed-runtime user whose PATH has Claude Code {string} and a customized Claude Code setup', { timeout: 40 * MIN }, async function (version) {
    const suite = await H.setupSuite();
    const d = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-kmc-')));
    const home = path.join(d, 'home'), st = path.join(d, 'state');
    fs.mkdirSync(home, { recursive: true }); fs.mkdirSync(st, { recursive: true });
    put(path.join(home, '.gitconfig'), '');
    // The user's own Claude Code in the native installer's layout; every start is recorded.
    put(path.join(home, `.local/share/claude/versions/${version}`), `#!/bin/sh\nprintf '%s\\n' "$0 $*" >> '${path.join(st, 'path-claude.log')}'\necho '${version} (Claude Code)'\n`, 0o755);
    fs.mkdirSync(path.join(home, '.local/bin'), { recursive: true });
    fs.symlinkSync(`../share/claude/versions/${version}`, path.join(home, '.local/bin/claude'));
    put(path.join(home, '.claude/settings.json'), JSON.stringify({ hooks: { PreToolUse: [{ matcher: 'Write', hooks: [{ type: 'command', command: 'echo user-hook' }] }] }, permissions: { allow: ['Bash(rm -rf:*)'] }, env: { USER_SETTING: '1' } }) + '\n');
    put(path.join(home, '.claude/CLAUDE.md'), "# The user's personal instructions\n");
    put(path.join(home, '.claude/skills/user-skill/SKILL.md'), '---\nname: user-skill\ndescription: A personal skill\n---\nPersonal.\n');
    put(path.join(home, '.claude/agents/user-agent.md'), '---\nname: user-agent\ndescription: A personal agent\n---\nPersonal.\n');
    put(path.join(home, '.claude/plugins/installed_plugins.json'), '{"version":2,"plugins":{"user-plugin@user":[{"scope":"user"}]}}\n');
    put(path.join(home, '.claude/.credentials.json'), '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-USER-OWN-SYNTHETIC"}}\n', 0o600);
    put(path.join(home, '.claude.json'), '{"numStartups":42,"autoUpdates":true}\n');
    const env = { ...process.env, HOME: home, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(home, '.gitconfig'), PATH: path.join(home, '.local/bin') + path.delimiter + (process.env.PATH || '') };
    for (const k of Object.keys(env)) {
      if (/^(ANTHROPIC_|CLAUDE_|AWS_|GOOGLE_|AZURE_)/.test(k) || ['DISABLE_UPDATES', 'DISABLE_AUTOUPDATER', 'KOGEN_CLAUDE_CODE_URL', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE'].includes(k)) delete env[k];
    }
    this.kmc = { d, home, state: st, env, suite, bin: suite.release, platform: platformKey(), setupBefore: userSetup(home) };
  });
  Given('an earlier Kogen managed Claude Code runtime {string} is installed', function (version) {
    const c = ctx(this), p = path.join(c.home, '.kogen/claude-code', version, 'claude');
    put(p, `#!/bin/sh\nprintf '%s\\n' "$0 $*" >> '${path.join(c.state, 'old-runtime.log')}'\necho '${version} (Claude Code)'\n`, 0o755);
    c.oldPath = p; c.oldBefore = state(p);
  });
  Given('the managed Claude Code runtime {string} is already installed reporting {string}', function (dir, reported) {
    const c = ctx(this);
    put(path.join(c.home, '.kogen/claude-code', dir, 'claude'), wrapper(c, `installed-${dir}`, script(reported)), 0o755);
  });
  Given('the managed Claude Code runtime {string} is already installed and reports that it is not signed in', function (dir) {
    const c = ctx(this);
    const signedOut = script(`${dir} (Claude Code)`, { auth: { loggedIn: false, authMethod: 'none', apiProvider: 'firstParty' } });
    put(path.join(c.home, '.kogen/claude-code', dir, 'claude'), wrapper(c, `signed-out-${dir}`, signedOut), 0o755);
  });
  Given('a leftover {string} directory from an interrupted managed Claude Code installation', function (name) {
    const c = ctx(this);
    put(path.join(c.home, '.kogen/claude-code', name, 'claude'), '#!/bin/sh\n# cut off by an interrupted download\n', 0o755);
  });
  Given('the managed Claude Code configuration directory holds session data', function () {
    const c = ctx(this), cfg = path.join(c.home, '.kogen/claude-code/config');
    put(path.join(cfg, '.claude.json'), '{"numStartups":3}\n');
    put(path.join(cfg, 'projects/fixture/session.jsonl'), '{"type":"system"}\n');
  });
  Given('the managed-runtime user saved the Claude Code token {string}', { timeout: 2 * MIN }, async function (token) {
    const c = ctx(this);
    const r = await kogen(c, ['provider', 'login', 'claude-code'], token + '\n');
    assert.equal(r.code, 0, r.out);
    c.tokenBefore = state(path.join(c.home, '.kogen/credentials/claude-code.json'));
    assert.ok(c.tokenBefore, 'kogen provider login claude-code saved no token file');
  });
  Given('the managed-runtime download server serves a runtime reporting {string}', async function (reported) { await serve(ctx(this), 'ok', reported); });
  Given('the managed-runtime download server serves a runtime whose bytes do not match its manifest checksum', async function () { await serve(ctx(this), 'mismatch'); });
  Given('the managed-runtime download server drops the connection halfway through the runtime', async function () { await serve(ctx(this), 'drop'); });
  Given('an approved managed-runtime fixture Intent whose Build and Review use the Claude Code executor', { timeout: 10 * MIN }, async function () {
    const c = ctx(this), repo = path.join(c.d, 'repo'), dir = `.kogen/intents/${SLUG}`;
    fs.mkdirSync(repo); c.repo = repo;
    put(path.join(repo, '.gitignore'), '.kogen/local/\n');
    put(path.join(repo, 'README.md'), '# Managed runtime fixture\n');
    put(path.join(repo, 'app.txt'), 'baseline\n');
    const role = '{executor: claude-code, model: claude-sonnet-5-5, effort: high}';
    put(path.join(repo, '.kogen/project.yaml'), `version: 1\ncommands:\n  setup: []\n  fix: []\n  checks:\n    - {name: local-check, run: 'true'}\n  acceptance:\n    run: '${RUNNER}'\n    steps_dir: features/steps\nprotect: []\n`);
    put(path.join(repo, '.kogen/models.yaml'), `models:\n  shape: ${role}\n  build: ${role}\n  review: ${role}\n`);
    for (const a of [['init', '-q', '--initial-branch=main'], ['config', 'user.name', 'Managed Fixture'], ['config', 'user.email', 'managed@example.invalid'], ['add', '.'], ['commit', '-qm', 'Fixture baseline']]) git(c, a);
    put(path.join(repo, dir, 'intent.md'), `# Build the managed fixture app

Slug: ${SLUG}
Model: not applicable — one fixed file replacement has no state
Acceptance:
- ${dir}/acceptance.feature
- features/steps/app_steps.js

Replace the baseline text of app.txt with the text built on the managed Claude Code.

## Decisions
- Keep the fixture minimal. (source: request)

## Source comparison
- addressed: the app.txt text is checked by the fixture scenario.

## Tests
- app.txt text: fixture scenario (scenario)

## Feasibility
- none
`);
    put(path.join(repo, dir, 'acceptance.feature'), 'Feature: Managed fixture\n  Scenario: The app is built\n    Then the managed fixture app is built\n');
    put(path.join(repo, 'features/steps/app_steps.js'), "const {Then}=require('@cucumber/cucumber'); const fs=require('node:fs'); const assert=require('node:assert/strict'); Then('the managed fixture app is built',()=>assert.equal(fs.readFileSync('app.txt','utf8'),'built on the managed Claude Code\\n'));\n");
    const card = await kogen(c, ['intent', 'approve', SLUG]);
    assert.equal(card.code, 5, card.out);
    const hash = card.out.match(/^SHA-256: ([a-f0-9]{64})$/m)?.[1];
    assert.ok(hash, card.out);
    const approved = await kogen(c, ['intent', 'approve', SLUG, hash]);
    assert.equal(approved.code, 0, approved.out);
    c.headBefore = git(c, ['rev-parse', 'HEAD']).trim();
  });

  When('I build the managed-runtime fixture Intent', { timeout: 10 * MIN }, async function () { const c = ctx(this); c.last = await kogen(c, ['intent', 'build', SLUG]); });
  When('I list the providers of the managed-runtime user', { timeout: 2 * MIN }, async function () { const c = ctx(this); c.list = await kogen(c, ['provider', 'list']); });
  When('I uninstall the managed-runtime Kogen', { timeout: 2 * MIN }, async function () { const c = ctx(this); c.uninstallResult = await kogen(c, ['uninstall']); });

  Then('the managed-runtime Build landed {string} with the content {string}', function (file, content) { C.landed(collect(ctx(this)), file, content); });
  Then('the managed-runtime output has the line {string}', function (text) { C.line(collect(ctx(this)), text); });
  Then('the managed-runtime Build was refused with {string} and the message {string}', function (cls, message) { C.refused(collect(ctx(this)), cls, message); });
  Then('the managed runtime {string} holds exactly the served bytes and is executable', function (file) { C.runtimeBytes(collect(ctx(this)), file); });
  Then('the managed-runtime download server served the {string} runtime {int} time(s)', function (version, n) { C.servedTimes(collect(ctx(this)), version, n); });
  Then('the managed-runtime download server received no request', function () { C.noDownload(collect(ctx(this))); });
  Then('every managed Claude Code child ran {string} with CLAUDE_CONFIG_DIR {string} and DISABLE_UPDATES {string}', function (self, config, updates) { C.children(collect(ctx(this)), self, config, updates); });
  Then('no downloaded or installed managed Claude Code runtime was started', function () { C.neverStarted(collect(ctx(this))); });
  Then('the managed Claude Code runtime served both the build and the review role', function () { C.roles(collect(ctx(this))); });
  Then('no managed Claude Code round ran', function () { C.noRounds(collect(ctx(this))); });
  Then('the Kogen PreToolUse hook allowed the managed Claude Code write of {string}', function (file) { C.hook(collect(ctx(this)), file); });
  Then('the managed-runtime directory {string} exists with mode {string}', function (dir, mode) { C.dirMode(collect(ctx(this)), dir, mode); });
  Then('the managed Claude Code directory holds no partial installation', function () { C.noPartial(collect(ctx(this))); });
  Then('nothing is installed for managed Claude Code {string}', function (version) { C.nothingInstalled(collect(ctx(this)), version); });
  Then('the Claude Code on the PATH of the managed-runtime user was never run', function () { C.pathNeverRun(collect(ctx(this))); });
  Then('the own Claude Code setup of the managed-runtime user is byte-for-byte unchanged', function () { C.setupUnchanged(collect(ctx(this))); });
  Then('the earlier managed Claude Code runtime is unchanged and was never run', function () { C.oldUnchanged(collect(ctx(this))); });
  Then('the managed-runtime fixture project is unchanged', function () { C.projectUnchanged(collect(ctx(this))); });
  Then('the managed-runtime provider list has the line {string}', function (text) { C.listLine(collect(ctx(this)), text); });
  Then('the managed-runtime provider list has the line {string} right after the line {string}', function (text, before) { C.listAfter(collect(ctx(this)), text, before); });
  Then('the managed-runtime uninstall succeeded with the line {string}', function (text) { C.uninstalled(collect(ctx(this)), text); });
  Then('the managed-runtime path {string} does not exist', function (p) { C.absent(collect(ctx(this)), p); });
  Then('the saved Claude Code token of the managed-runtime user is unchanged', function () { C.tokenUnchanged(collect(ctx(this))); });

  After(async function () {
    const c = this.kmc;
    if (!c) return;
    if (c.server) await new Promise(resolve => { c.server.http.closeAllConnections(); c.server.http.close(() => resolve()); });
    if (!process.env.KOGEN_KMC_KEEP) { fs.rmSync(c.d, { recursive: true, force: true }); H.cleanupSuite(c.suite); }
  });
}
