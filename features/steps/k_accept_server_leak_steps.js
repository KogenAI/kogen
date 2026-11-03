'use strict';
// K-ACCEPT-SERVER-LEAK: background servers started by an acceptance run must not outlive it.
// The observation is made once per Cucumber process, kept outside the checkout and cleaned up whatever its result
// (every server it caused is killed afterwards, so a red run leaves nothing on the host): the packaged Kogen (the
// newest dist/ archive, installed into a private prefix by go_driver_support.js) runs `kogen intent approve leak`
// on a fixture project whose acceptance runs through the bundled lib/cucumber; its two fixture scenarios (one
// passes, one fails) each put `python3 -m http.server` in the background in a new session, and record the
// server's pid and process group. A server started outside the approval run must still be running afterwards.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const PYTHON = process.env.KOGEN_TEST_PYTHON_BIN || 'python3';
const SLUG = 'leak';
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
const { When, Then } = require('@cucumber/cucumber');
const STEP = { timeout: 115000 };
When('the packaged Kogen approves a fixture whose passing and failing scenarios each put python3 -m http.server in the background', STEP, async function () {
  this.kasl = await observeApproval();
});
Then('the approval ran both fixture scenarios through the bundled Cucumber', function () { checkApproval(this.kasl); });
Then('the server started outside the approval run is still running', function () { checkApprovalUnrelated(this.kasl); });
Then('no background server from the approval run of the {string} fixture scenario is still running', function (name) { checkApprovalServer(this.kasl, name); });
