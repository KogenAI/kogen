'use strict';
// K-ACCEPT-SERVER-LEAK: background servers started by an acceptance run must not outlive it.
// Two observations, each made once per Cucumber process, kept outside the checkout and cleaned up whatever
// their result (every server they caused is killed afterwards, so a red run leaves nothing on the host):
// - the packaged Kogen (the newest dist/ archive, installed into a private prefix by go_driver_support.js) runs
//   `kogen intent approve leak` on a fixture project whose acceptance runs through the bundled lib/cucumber; its
//   two fixture scenarios (one passes, one fails) each put `python3 -m http.server` in the background in a new
//   session, and record the server's pid and process group;
// - the Go driver k_accept_server_leak_driver.go, mounted into package verify with `go test -overlay`, runs
//   acceptance commands through verify.RunAcceptance: a passing Build-route run, a failing approval-route run and
//   an approval-route run that outlives a contracted 3-second step bound.
// In both, a server started outside the runs must still be running afterwards.
// `node k_accept_server_leak_steps.js --control good|bad` checks the judging functions below against
// known-good and known-bad observations without running anything.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const PYTHON = process.env.KOGEN_TEST_PYTHON_BIN || 'python3';
const SLUG = 'leak';
const DRIVER_TEST = 'TestKAcceptServerLeakObservation';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const alive = pid => { try { process.kill(pid, 0); return true; } catch (e) { return e.code !== 'ESRCH'; } };
async function goneWithin(pid, ms) {
  for (const deadline = Date.now() + ms; ; await sleep(50)) {
    if (!alive(pid)) return true;
    if (Date.now() > deadline) return false;
  }
}
const kill = pid => { if (pid > 0) { try { process.kill(pid, 'SIGKILL'); } catch {} } };

// ------------------------------------------------------------------ the fixture project of the approval observation

// Its own step file runs inside the inner acceptance run, under the bundled Cucumber. The server answers HTTP
// before the step records it, so a recorded server was really serving when the run ended.
const FIXTURE_STEPS = `'use strict';
const { When, Then } = require('@cucumber/cucumber');
const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const freePort = () => new Promise((resolve, reject) => { const s = net.createServer(); s.once('error', reject); s.listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)); }); });
const get = port => new Promise(resolve => { const r = http.get({ host: '127.0.0.1', port, path: '/' }, res => { res.resume(); resolve(res.statusCode); }); r.once('error', () => resolve(0)); });
const pgidOf = pid => Number(spawnSync('ps', ['-o', 'pgid=', '-p', String(pid)], { encoding: 'utf8' }).stdout.trim());
When('a server is put in the background as {string}', { timeout: 20000 }, async function (name) {
  const port = await freePort();
  const child = spawn(process.env.KASL_PYTHON, ['-m', 'http.server', String(port), '--bind', '127.0.0.1'], { detached: true, stdio: 'ignore' });
  child.unref();
  let status = 0;
  for (const deadline = Date.now() + 10000; status !== 200 && Date.now() < deadline; ) { await new Promise(r => setTimeout(r, 100)); status = await get(port); }
  if (status !== 200) throw new Error('the background server never answered on port ' + port);
  fs.writeFileSync(path.join(process.env.KASL_PIDS, name + '.json'), JSON.stringify({ pid: child.pid, pgid: pgidOf(child.pid), runner_pgid: pgidOf(process.pid), port }));
});
Then('the scenario passes', function () {});
Then('the scenario fails on purpose', function () { throw new Error('this fixture scenario fails on purpose'); });
`;
const FIXTURE_FEATURE = `Feature: Background server fixture
  Scenario: A passing scenario leaves a server in the background
    When a server is put in the background as "passing"
    Then the scenario passes

  Scenario: A failing scenario leaves a server in the background
    When a server is put in the background as "failing"
    Then the scenario fails on purpose
`;
const FIXTURE_INTENT = `# Leave a server in the background

Slug: ${SLUG}
Model: not applicable — fixture with no state
Acceptance:
- .kogen/intents/${SLUG}/acceptance.feature
- features/steps/leak_steps.js

A fixture whose acceptance puts a server in the background.

## Decisions
- Keep the fixture minimal. (source: request)

## Source comparison
- addressed: fixture request; acceptance.feature.

## Tests
- background server fixture: the acceptance scenarios (scenario)

## Feasibility
- none
`;
const PROJECT_YAML = `version: 1
commands:
  setup: []
  fix: []
  checks: []
  acceptance:
    run: 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require ''features/steps/*.js'' --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"'
    steps_dir: 'features/steps'
protect: []
`;

function newestArchive() {
  const dist = path.join(ROOT, 'dist');
  const files = fs.existsSync(dist) ? fs.readdirSync(dist).filter(f => /^kogen-.*\.tar\.gz$/.test(f)).map(f => path.join(dist, f)) : [];
  files.sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
  return files[0];
}

let approval;
// The approval observation, made once: { approve: {code, out, timed}, servers: {passing, failing}, unrelated, unrelatedBefore, unrelatedAfter }.
function observeApproval() {
  if (!approval) approval = approveFixture();
  return approval;
}
async function approveFixture() {
  const H = require('./go_driver_support.js');
  // The release the scenarios install is the newest in dist/ (the configured setup builds it); without one the
  // shared support packages the checkout itself.
  if (!process.env.KOGEN_ARCHIVE && newestArchive()) process.env.KOGEN_ARCHIVE = newestArchive();
  const suite = await H.setupSuite();
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-kasl-')));
  const pids = path.join(root, 'pids'), repo = path.join(root, 'repo'), home = path.join(root, 'home'), tmp = path.join(root, 'tmp');
  for (const d of [pids, repo, home, tmp]) fs.mkdirSync(d, { recursive: true });
  // The unrelated server: started here, outside the approval run, in its own session.
  const child = spawn(PYTHON, ['-m', 'http.server', '0', '--bind', '127.0.0.1'], { detached: true, stdio: 'ignore' });
  child.unref();
  const e = { unrelated: child.pid, servers: {} };
  try {
    await sleep(500);
    e.unrelatedBefore = alive(e.unrelated);
    const put = (p, b) => { const f = path.join(repo, p); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, b); };
    put('README.md', '# Background server fixture\n');
    put('.gitignore', '.kogen/local/\n');
    put('.kogen/project.yaml', PROJECT_YAML);
    put(`.kogen/intents/${SLUG}/intent.md`, FIXTURE_INTENT);
    put(`.kogen/intents/${SLUG}/acceptance.feature`, FIXTURE_FEATURE);
    put('features/steps/leak_steps.js', FIXTURE_STEPS);
    const gitconfig = path.join(home, '.gitconfig'); fs.writeFileSync(gitconfig, '');
    const env = { HOME: home, PATH: suite.path, TMPDIR: tmp, GIT_CONFIG_GLOBAL: gitconfig, GIT_CONFIG_NOSYSTEM: '1', KASL_PIDS: pids, KASL_PYTHON: PYTHON };
    for (const args of [['init', '-q', '--initial-branch=main'], ['config', 'user.name', 'Kogen Integration'], ['config', 'user.email', 'kogen-integration@example.invalid'], ['add', '-A'], ['commit', '-q', '-m', 'fixture']]) {
      const r = spawnSync('git', ['-C', repo, ...args], { env, encoding: 'utf8' });
      assert.equal(r.status, 0, `git ${args.join(' ')} failed: ${r.stdout}${r.stderr}`);
    }
    const r = await H.run(suite.release, ['intent', 'approve', SLUG], { cwd: repo, env, timeout: 90000 });
    e.approve = { code: r.code, out: r.out, timed: r.timed };
    for (const name of ['passing', 'failing']) {
      const file = path.join(pids, `${name}.json`);
      if (!fs.existsSync(file)) continue;
      const s = JSON.parse(fs.readFileSync(file, 'utf8'));
      s.goneWithin5s = await goneWithin(s.pid, 5000);
      e.servers[name] = s;
    }
    e.unrelatedAfter = alive(e.unrelated);
    return e;
  } finally {
    for (const name of ['passing', 'failing']) { try { kill(JSON.parse(fs.readFileSync(path.join(pids, `${name}.json`), 'utf8')).pid); } catch {} }
    kill(e.unrelated);
    fs.rmSync(root, { recursive: true, force: true });
    H.cleanupSuite(suite);
  }
}

// ------------------------------------------------------------------ the Go driver observation

const MODES = ['passed', 'failed', 'timed_out', 'unrelated'];
let driver;
// Runs the driver once per Cucumber process: every outcome is one observation of that single run.
function observeDriver() {
  if (driver) return driver;
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-kasl-go-')));
  fs.chmodSync(dir, 0o700);
  try {
    const overlay = path.join(dir, 'overlay.json');
    fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/verify/k_accept_server_leak_acceptance_test.go')]: path.join(__dirname, 'k_accept_server_leak_driver.go') } }));
    const out = path.join(dir, 'out'); fs.mkdirSync(out);
    const command = `go test -overlay <overlay> ./verify -run ^${DRIVER_TEST}$ -count=1 -timeout=90s (in cli/)`;
    const r = spawnSync('go', ['test', '-overlay', overlay, './verify', '-run', `^${DRIVER_TEST}$`, '-count=1', '-timeout=90s'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 100000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_KASL_OUTPUT: out, GOWORK: 'off', GOPROXY: 'off', GOTOOLCHAIN: 'local' },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `the observation driver ${DRIVER_TEST} did not pass: ${command} exited ${r.status}:\n${r.stdout}\n${r.stderr}`);
    // Go success alone is not proof: the driver must have written every observation.
    const data = {};
    for (const mode of MODES) {
      const file = path.join(out, `${mode}.json`);
      assert.ok(fs.existsSync(file), `${DRIVER_TEST} (${command}) did not run or wrote no ${mode} observation:\n${r.stdout}`);
      data[mode] = JSON.parse(fs.readFileSync(file, 'utf8'));
    }
    driver = data;
    return data;
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

// ------------------------------------------------------------------ judging (pure: the controls call these)

// The server must have left the group of the process that started it: otherwise it does not reproduce the leak.
function checkServer(label, pid, pgid, group, record) {
  assert.ok(pid > 0, `${label}: no background server pid was recorded: ${JSON.stringify(record)}`);
  assert.ok(pgid > 0 && group > 0, `${label}: the process groups were not recorded: ${JSON.stringify(record)}`);
  assert.notEqual(pgid, group, `${label}: the server stayed in the run's process group, so it does not reproduce the leak: ${JSON.stringify(record)}`);
}
function checkApproval(e) {
  assert.ok(e.approve, 'kogen intent approve never ran');
  assert.equal(e.approve.timed, false, `kogen intent approve did not finish:\n${e.approve.out}`);
  assert.equal(e.approve.code, 5, `kogen intent approve ${SLUG} should print its card (exit 5):\n${e.approve.out}`);
  assert.ok(e.approve.out.includes('A passing scenario leaves a server in the background (passes now)'), `the card does not show the passing fixture scenario passing:\n${e.approve.out}`);
  assert.ok(e.approve.out.includes('A failing scenario leaves a server in the background (fails now)'), `the card does not show the failing fixture scenario failing:\n${e.approve.out}`);
  for (const name of ['passing', 'failing']) {
    const s = e.servers[name];
    assert.ok(s, `the ${name} fixture scenario never recorded its background server`);
    checkServer(`the ${name} fixture scenario`, s.pid, s.pgid, s.runner_pgid, s);
  }
}
function checkApprovalUnrelated(e) {
  assert.equal(e.unrelatedBefore, true, 'the unrelated server never started');
  assert.equal(e.unrelatedAfter, true, `the unrelated server (pid ${e.unrelated}), started outside the approval run, was stopped`);
}
function checkApprovalServer(e, name) {
  const s = e.servers[name];
  assert.ok(s, `the ${name} fixture scenario never recorded its background server`);
  assert.equal(s.goneWithin5s, true, `the server (pid ${s.pid}, process group ${s.pgid}) that the ${name} fixture scenario put in the background was still running 5 seconds after kogen intent approve exited`);
}
function checkDriverUnrelated(u) {
  assert.equal(u.mode, 'unrelated');
  assert.equal(u.running_before, true, 'the unrelated server never started');
  assert.equal(u.running_after, true, `the unrelated server (pid ${u.pid}), started outside every acceptance run, was stopped`);
}
function checkDriverRun(d, mode) {
  assert.equal(d.mode, mode);
  checkServer(`the ${mode} acceptance command`, d.server_pid, d.server_pgid, d.command_group, d);
  if (mode === 'timed_out') {
    assert.equal(d.step_timeout, true, `the timed_out acceptance run was not stopped by its 3-second step bound: ${JSON.stringify(d)}`);
    assert.ok(d.elapsed_ms >= 3000 && d.elapsed_ms < 30000, `the timed_out acceptance run took ${d.elapsed_ms} ms: ${JSON.stringify(d)}`);
  } else {
    assert.equal(d.error, '', `the ${mode} acceptance run returned an error: ${JSON.stringify(d)}`);
    assert.equal(d.status, mode === 'passed' ? 0 : 1, `the ${mode} acceptance command exited ${d.status}: ${JSON.stringify(d)}`);
  }
  assert.equal(d.server_gone_within_5s, true, `the server (pid ${d.server_pid}, process group ${d.server_pgid}) that the ${mode} acceptance command put in the background was still running 5 seconds after RunAcceptance returned`);
}

// ------------------------------------------------------------------ observer controls

function controls(kind) {
  const server = (pid, done) => ({ pid, pgid: pid, runner_pgid: 500, port: 40000 + pid, goneWithin5s: done });
  const card = '  - A passing scenario leaves a server in the background (passes now)\n  - A failing scenario leaves a server in the background (fails now)\n';
  const approve = { approve: { code: 5, out: card, timed: false }, servers: { passing: server(601, true), failing: server(602, true) }, unrelated: 700, unrelatedBefore: true, unrelatedAfter: true };
  const run = (mode, extra) => ({ mode, status: 0, elapsed_ms: 600, error: '', step_timeout: false, server_pid: 800, server_pgid: 800, command_group: 790, server_alive_at_return: false, server_gone_within_5s: true, ...extra });
  const runs = { passed: run('passed'), failed: run('failed', { status: 1 }), timed_out: run('timed_out', { elapsed_ms: 3100, error: 'step acceptance timed out', step_timeout: true }) };
  const unrelated = { mode: 'unrelated', pid: 900, running_before: true, running_after: true };
  const good = () => {
    checkApproval(approve); checkApprovalUnrelated(approve); checkApprovalServer(approve, 'passing'); checkApprovalServer(approve, 'failing');
    for (const mode of ['passed', 'failed', 'timed_out']) checkDriverRun(runs[mode], mode);
    checkDriverUnrelated(unrelated);
  };
  good();
  if (kind === 'good') { console.log('k-accept-server-leak observer accepted good fixtures'); return; }
  assert.equal(kind, 'bad');
  const bad = (what, fn, record, mutate) => { const c = structuredClone(record); mutate(c); assert.throws(() => fn(c), assert.AssertionError, `accepted a known-bad observation: ${what}`); };
  // The reported leak: a background server still running after the run, whatever its outcome.
  bad('passing fixture server survived approval', e => checkApprovalServer(e, 'passing'), approve, e => { e.servers.passing.goneWithin5s = false; });
  bad('failing fixture server survived approval', e => checkApprovalServer(e, 'failing'), approve, e => { e.servers.failing.goneWithin5s = false; });
  for (const mode of ['passed', 'failed', 'timed_out']) bad(`${mode} server survived`, d => checkDriverRun(d, mode), runs[mode], d => { d.server_gone_within_5s = false; d.server_alive_at_return = true; });
  // Stopping too much: the unrelated server stopped, or never started.
  bad('unrelated stopped by approval', checkApprovalUnrelated, approve, e => { e.unrelatedAfter = false; });
  bad('unrelated never started (approval)', checkApprovalUnrelated, approve, e => { e.unrelatedBefore = false; });
  bad('unrelated stopped by RunAcceptance', checkDriverUnrelated, unrelated, u => { u.running_after = false; });
  bad('unrelated never started (driver)', checkDriverUnrelated, unrelated, u => { u.running_before = false; });
  // A fixture that does not reproduce the leak: the server stayed in the run's group, or was never recorded.
  bad('fixture server stayed in the runner group', checkApproval, approve, e => { e.servers.failing.pgid = 500; });
  bad('fixture server never recorded', checkApproval, approve, e => { delete e.servers.passing; });
  bad('driver server stayed in the command group', d => checkDriverRun(d, 'passed'), runs.passed, d => { d.server_pgid = 790; });
  bad('driver server never recorded', d => checkDriverRun(d, 'failed'), runs.failed, d => { d.server_pid = 0; d.server_pgid = 0; d.command_group = 0; });
  // The approval did not run both fixture scenarios through the bundled Cucumber, or refused.
  bad('approval refused', checkApproval, approve, e => { e.approve.code = 1; });
  bad('approval hung', checkApproval, approve, e => { e.approve.timed = true; });
  bad('passing fixture scenario not passing', checkApproval, approve, e => { e.approve.out = e.approve.out.replace('(passes now)', '(fails now)'); });
  bad('failing fixture scenario not run', checkApproval, approve, e => { e.approve.out = e.approve.out.replace(/.*failing scenario.*\n/, ''); });
  // The driver runs did not reach their outcome.
  bad('passed run exited 1', d => checkDriverRun(d, 'passed'), runs.passed, d => { d.status = 1; });
  bad('failed run exited 0', d => checkDriverRun(d, 'failed'), runs.failed, d => { d.status = 0; });
  bad('passed run errored', d => checkDriverRun(d, 'passed'), runs.passed, d => { d.error = 'boom'; });
  bad('timed_out run not stopped by its bound', d => checkDriverRun(d, 'timed_out'), runs.timed_out, d => { d.step_timeout = false; d.error = ''; });
  bad('timed_out run ended before its bound', d => checkDriverRun(d, 'timed_out'), runs.timed_out, d => { d.elapsed_ms = 500; });
  bad('wrong mode record', d => checkDriverRun(d, 'failed'), runs.passed, () => {});
  console.log('k-accept-server-leak observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  const STEP = { timeout: 115000 };
  When('the packaged Kogen approves a fixture whose passing and failing scenarios each put python3 -m http.server in the background', STEP, async function () {
    this.kasl = await observeApproval();
  });
  Then('the approval ran both fixture scenarios through the bundled Cucumber', function () { checkApproval(this.kasl); });
  Then('the server started outside the approval run is still running', function () { checkApprovalUnrelated(this.kasl); });
  Then('no background server from the approval run of the {string} fixture scenario is still running', function (name) { checkApprovalServer(this.kasl, name); });
  When('acceptance commands that put python3 -m http.server in the background are run through RunAcceptance', STEP, function () { this.kaslGo = observeDriver(); });
  Then('the server started outside the acceptance runs is still running', function () { checkDriverUnrelated(this.kaslGo.unrelated); });
  Then('no background server from the {string} acceptance run is still running', function (mode) { checkDriverRun(this.kaslGo[mode], mode); });
}
