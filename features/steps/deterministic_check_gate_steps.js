const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const feature = path.join(root, '.kogen/intents/deterministic-check-gate/acceptance.feature');

// Compare objects semantically, preserving array/string order. Expected values
// come from the feature, not from the implementation or a generated receipt.
function observe(actual, expected, label = 'observations') {
  if (expected && typeof expected === 'object' && !Array.isArray(expected)) {
    assert.ok(actual && typeof actual === 'object', `${label}: missing object`);
    for (const [key, value] of Object.entries(expected)) {
      assert.ok(Object.hasOwn(actual, key), `${label}.${key}: missing`);
      if (key === 'minimumPassed') {
        assert.ok(Number.isInteger(actual[key]) && actual[key] >= value, `${label}.${key}: ${actual[key]} < ${value}`);
      } else observe(actual[key], value, `${label}.${key}`);
    }
  } else assert.deepEqual(actual, expected, label);
}
function expectedControl() {
  const expected = {};
  for (const line of fs.readFileSync(feature, 'utf8').split('\n')) {
    const match = line.match(/^\s*\|\s*([^|]+?)\s*\|\s*(.*?)\s*\|\s*$/);
    if (match) expected[match[1]] = JSON.parse(match[2]);
  }
  assert.ok(Object.keys(expected).length > 0, 'no feature expectations');
  return expected;
}
function leaves(value, prefix = []) {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return Object.entries(value).flatMap(([key, v]) => leaves(v, [...prefix, key]));
  }
  return [prefix];
}
if (require.main === module && process.argv[2] === '--owner') {
  // The fixture owner of one lifecycle case: a separate process that ends normally on request or is killed by the harness.
  process.stdout.write('owner ready\n');
  process.stdin.on('data', data => { if (String(data).includes('finish')) process.exit(0); });
  process.stdin.on('end', () => process.exit(0));
  setInterval(() => {}, 1000);
} else if (require.main === module && process.argv[2] === '--control') {
  const expected = expectedControl();
  observe(structuredClone(expected), expected);
  if (process.argv[3] === 'good') {
    process.stdout.write('good control accepted\n');
  } else if (process.argv[3] === 'bad') {
    for (const keys of leaves(expected)) {
      const bad = structuredClone(expected);
      let parent = bad;
      for (const key of keys.slice(0, -1)) parent = parent[key];
      const key = keys.at(-1), old = parent[key];
      parent[key] = typeof old === 'boolean' ? !old : typeof old === 'number' ? (key === 'minimumPassed' ? old - 1 : old + 1) : 'wrong';
      assert.throws(() => observe(bad, expected), `accepted corruption ${keys.join('.')}`);
    }
    // Absent nested data must not silently pass either.
    assert.throws(() => observe({}, expected));
    process.stdout.write('bad controls rejected\n');
    process.exitCode = 1;
  } else throw new Error('unknown control');
} else {
  const { When, Then } = require('@cucumber/cucumber');
  const support = require('./go_driver_support.js');
  const { setupSuite, cleanupSuite, project, cleanupCase, envFor, fn, shellQuote, waitForFile, run, sleep, workDir, ROOT, MIN } = support;

  // ---------------------------------------------------------------- scenario 1: the fixture process lifecycle
  // The old driver opened an installed Build in a Port owned by a custodian, killed or ended the owning test process and then
  // observed that cleanup stopped the CLI and its command child, removed the case and left an unrelated process alone.
  // Here the installed Go candidate is started through the same relay (test/support/fixture_process.py), which keeps a
  // separate session leader alive until every process of the session has ended and publishes a `stopped` marker.
  const LAUNCHER = path.join(ROOT, 'test/support/fixture_process.py');
  const psTable = async () => {
    const r = await run('/bin/ps', ['-axo', 'pid=,ppid=,stat=,command=']);
    return r.out.split('\n').filter(Boolean).map(line => { const m = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/.exec(line); return m && { pid: Number(m[1]), ppid: Number(m[2]), stat: m[3], command: m[4] }; }).filter(Boolean);
  };
  // Alive means a process that is not a zombie (a zombie has ended; only its parent has not collected it).
  async function alive(pid) {
    const r = await run('/bin/ps', ['-o', 'stat=', '-p', String(pid)]);
    const stat = r.out.trim();
    return r.code === 0 && stat !== '' && !stat.startsWith('Z');
  }
  async function signal(pid, name) { return run('/bin/kill', ['-' + name, String(pid)]); }
  async function waitDead(pid, deadline) { while ((await alive(pid)) && Date.now() < deadline) await sleep(20); }

  // The relay's session leader is its only child; the CLI is the leader's child running the release.
  async function kogenPidOf(relay, release) {
    const table = await psTable();
    const leaders = table.filter(p => p.ppid === relay).map(p => p.pid);
    const mine = table.find(p => leaders.includes(p.ppid) && p.command.includes(release));
    assert.ok(mine, `no kogen process under relay ${relay}`);
    return mine.pid;
  }
  async function ownerCase(suite, how) {
    const custody = fs.mkdtempSync(path.join(workDir(), 'custody-'));
    const c = await project(suite, [], { stagedIntent: false });
    let relay, owner, unrelated, cliPid, kogenPid, childPid, started = false;
    const finalCleanup = async () => {
      // Scoped to recorded fixture pids; not the behaviour under test, and never alters the receipt collected before it.
      for (const pid of [cliPid, kogenPid].filter(Boolean)) if (await alive(pid)) await signal(pid, 'TERM');
      const deadline = Date.now() + 16000;
      for (const pid of [cliPid, kogenPid, childPid].filter(Boolean)) await waitDead(pid, deadline);
      for (const pid of [childPid, kogenPid, cliPid].filter(Boolean)) if (await alive(pid)) await signal(pid, 'KILL');
      if (owner) { try { owner.kill('SIGKILL'); } catch {} }
      if (unrelated) { try { unrelated.kill('SIGTERM'); } catch {} }
      await cleanupCase(c).catch(() => {});
      fs.rmSync(custody, { recursive: true, force: true });
    };
    try {
      const childFile = path.join(c.repo, '.kogen/local/owned-child');
      const heartbeat = path.join(c.repo, '.kogen/local/heartbeat');
      const command = `trap 'exit 0' TERM INT; echo $$ > ${shellQuote(childFile)}; while :; do printf alive > ${shellQuote(heartbeat)}; sleep 0.05; done`;
      c.server.setScript([fn('shell', { command })]); // after the configuration answer `kogen init` consumed

      // The owner is a separate process whose lifetime brackets the case.
      owner = spawn(process.execPath, [__filename, '--owner'], { stdio: ['pipe', 'pipe', 'inherit'] });
      const ownerExit = new Promise(resolve => owner.once('exit', (code, sig) => resolve({ code, sig })));
      await new Promise((resolve, reject) => { owner.stdout.once('data', resolve); owner.once('error', reject); ownerExit.then(() => reject(new Error('fixture owner exited before it was ready'))); });

      // The custodian (this process) holds the relay and its stdin, as the old custodian held the Port.
      relay = spawn('python3', [LAUNCHER, custody, c.suite.release, 'intent', 'build', 'fixture'], { cwd: c.repo, env: envFor(c), stdio: ['pipe', 'pipe', 'pipe'] });
      relay.stdin.on('error', () => {}); relay.stdout.resume(); relay.stderr.resume();
      cliPid = relay.pid;
      await waitForFile(childFile, 60000);
      childPid = Number(fs.readFileSync(childFile, 'utf8').trim());
      kogenPid = await kogenPidOf(cliPid, c.suite.release);

      unrelated = spawn('/bin/sleep', ['600'], { stdio: 'ignore' });
      const other = unrelated.pid;
      started = (await alive(cliPid)) && (await alive(kogenPid)) && (await alive(childPid)) && fs.statSync(c.root).isDirectory();

      if (how === 'normal') owner.stdin.write('finish\n'); else owner.kill('SIGKILL');
      await Promise.race([ownerExit, sleep(60000).then(() => { throw new Error('fixture owner did not terminate'); })]);

      // The cleanup under test: cancel through the relay, wait for the completion marker that proves descendant termination,
      // then remove the case. It must not touch the unrelated process.
      let cleanupReturned = true;
      try {
        await signal(cliPid, 'TERM');
        await waitForFile(path.join(custody, 'stopped'), 30000);
        await cleanupCase(c);
      } catch { cleanupReturned = false; }
      return {
        started, cleanupReturned,
        cliStopped: !(await alive(cliPid)) && !(await alive(kogenPid)),
        childStopped: !(await alive(childPid)),
        rootRemoved: !fs.existsSync(c.root),
        unrelatedAlive: await alive(other),
      };
    } finally { await finalCleanup(); }
  }
  async function measureLifecycle() {
    const suite = await setupSuite();
    try {
      const marker = path.join(suite.root, 'delayed-marker');
      const timer = setTimeout(() => fs.writeFileSync(marker, 'ready'), 11000);
      let delayed = false;
      try { await waitForFile(marker, 60000); delayed = fs.readFileSync(marker, 'utf8') === 'ready'; } catch {}
      clearTimeout(timer);
      const missingPath = path.join(suite.root, 'genuinely-missing-marker');
      let missing = false;
      try { await waitForFile(missingPath, 50); } catch (error) { missing = String(error.message).includes(missingPath); }
      const normal = await ownerCase(suite, 'normal');
      const aborted = await ownerCase(suite, 'aborted');
      return { delayedMarker: delayed, missingMarker: missing, normal, aborted };
    } finally { cleanupSuite(suite); }
  }

  // ---------------------------------------------------------------- scenario 2: the reported regression cases
  // Kogen's own ExUnit modules (test/integration/build_boundaries_test.exs, shape_context_publication_test.exs) were replaced
  // by Go tests; docs/evidence/go-core-migration/ledger.md records which Go tests cover each ExUnit case. The report below is
  // keyed by the same ExUnit test names. A case is `passed` only if every Go test the ledger maps it to passed.
  const BOUNDARIES = 'test/integration/build_boundaries_test.exs', PUBLICATION = 'test/integration/shape_context_publication_test.exs';
  const retry = o => ({ file: BOUNDARIES, ledger: 'blocked #{retry_outcome} retry provider failure retains fresh evidence and the saved reviewer', name: `blocked ${o} retry provider failure retains fresh evidence and the saved reviewer` });
  const clean = s => ({ file: BOUNDARIES, ledger: 'clean #{stage} input mutations cannot certify the workspace', name: `clean ${s} input mutations cannot certify the workspace` });
  const startup = s => ({ file: BOUNDARIES, ledger: 'GIT-8 restores the saved index when startup #{stage} fails', name: `GIT-8 restores the saved index when startup ${s} fails` });
  const plain = (file, name) => ({ file, ledger: name, name });
  const CASES = [
    ...[
      'REV-5 reviewer repairs are verified and committed without returning to the builder',
      'REV-5 final verification failures return to the same reviewer context',
      'preflight missing packages and malformed approval remain structured read observations',
      'resuming pending reviewer verification keeps repairs with the reviewer',
    ].map(n => plain(BOUNDARIES, n)),
    retry('green'), retry('setup_red'),
    plain(BOUNDARIES, 'pre-clean checkpoints cannot authorize resume'),
    clean('setup'), clean('checks'),
    ...[
      'clean setup failure returns command output without a partial green pass',
      'workspace drift during clean checks cannot certify a pass',
      'resume refuses damaged index custody, configuration and required saved state before effects',
      'a core death during resumed commit reports the created commit and cannot commit again',
      'REV-6 reviewer shell edits cannot change the approved baseline',
      'REV-5 interrupted targeted repair reports pending review and changed verification',
      'REV-5 unresolved substantive findings stop rather than start another builder round',
      'reopened reviewer resets preserve the unresolved blocker and cannot authorize commit',
      'REV-2 review retains full source without replaying new files twice',
    ].map(n => plain(BOUNDARIES, n)),
    startup('setup'), startup('checks'),
    ...[
      'GIT-8/CLI-7 restores the saved index and reports an interrupted startup',
      'CLI-7 undoes a commit interrupted during postcommit validation',
      'VER-10/GIT-4 excludes new siblings in another uncommitted Intent folder',
      'AUT-2 stops a preflight hook that changes the approved baseline',
      'GIT-8 restores the original index when a staging preflight hook rejects',
      'GIT-1 rejects a staged rename from outside the allowed Intent paths',
      'CLI-9 records a successful large Unicode startup check and continues',
    ].map(n => plain(BOUNDARIES, n)),
    plain(PUBLICATION, 'snapshot damaged by a completed tool refuses the next tool in the same batch'),
    plain(PUBLICATION, 'custody damaged during final readiness cannot publish successful evidence'),
  ];
  // The Go tests the ledger names for one ExUnit case (its row, matched by file and test name).
  function ledgerRows() {
    const rows = new Map();
    for (const line of fs.readFileSync(path.join(ROOT, 'docs/evidence/go-core-migration/ledger.md'), 'utf8').split('\n')) {
      const cells = line.split(/\s*\|\s*/);
      if (cells.length < 4) continue;
      const key = `${cells[1]}\0${cells[2]}`;
      rows.set(key, [...(rows.get(key) || []), ...new Set(cells.slice(3, -1).join('|').match(/\bTest[A-Za-z0-9_]+/g) || [])]);
    }
    return rows;
  }
  async function runGoCases() {
    const rows = ledgerRows();
    const mapping = CASES.map(c => {
      const tests = rows.get(`${c.file}\0${c.ledger}`);
      assert.ok(tests && tests.length, `the ledger has no Go test for ExUnit case "${c.name}" (${c.file})`);
      return { ...c, tests: [...new Set(tests)] };
    });
    const names = [...new Set(mapping.flatMap(c => c.tests))].sort();
    const env = { ...process.env, GOFLAGS: '-buildvcs=false', GOPROXY: 'off', GOTOOLCHAIN: 'local', GOWORK: 'off' };
    const result = await run('go', ['test', '-json', '-p', '1', '-count=1', '-run', `^(${names.join('|')})$`, './...'], { cwd: path.join(ROOT, 'cli'), env, timeout: 15 * MIN });
    assert.equal(result.timed, false, 'go test was killed by the watchdog');
    // Top-level Go test results by name, per package; package start/finish for the module peak.
    const outcomes = new Map(), active = new Set();
    let peak = 0;
    for (const line of result.out.split('\n')) {
      let e; try { e = JSON.parse(line); } catch { continue; }
      if (!e.Package) continue;
      if (!e.Test) {
        if (e.Action === 'start') { active.add(e.Package); peak = Math.max(peak, active.size); }
        else if (['pass', 'fail', 'skip'].includes(e.Action)) active.delete(e.Package);
      } else if (!e.Test.includes('/') && ['pass', 'fail', 'skip'].includes(e.Action)) {
        outcomes.set(e.Test, [...(outcomes.get(e.Test) || []), e.Action]);
      }
    }
    const report = { exit: result.code, passed: 0, failed: 0, invalid: 0, skipped: 0, excluded: 0, modulePeak: peak, tests: {}, goTests: {} };
    for (const name of names) report.goTests[name] = outcomes.get(name) || ['missing'];
    for (const c of mapping) {
      const seen = c.tests.map(t => outcomes.get(t));
      const state = seen.some(o => o && o.includes('fail')) ? 'failed'
        : seen.some(o => !o) ? 'invalid'
        : seen.some(o => o.includes('skip')) ? 'skipped' : 'passed';
      report.tests[c.name] = state;
      report[state] += 1;
    }
    return { report, output: result.out };
  }

  When('I measure native check fixture lifecycle', { timeout: 960000 }, async function () {
    this.nativeCheckObservations = await measureLifecycle();
    await this.attach(JSON.stringify(this.nativeCheckObservations), 'application/json');
  });
  When('I run the reported native check regression modules', { timeout: 960000 }, async function () {
    const { report, output } = await runGoCases();
    await this.attach(JSON.stringify(report, null, 1) + '\n' + output.split('\n').filter(l => /"Action":"(fail|skip)"|build-fail|FAIL/.test(l)).join('\n'), 'text/plain');
    this.nativeCheckObservations = { ...report, minimumPassed: report.passed };
  });
  Then('the native check observations include:', function (table) {
    const expected = Object.fromEntries(table.raw().map(([key, value]) => [key, JSON.parse(value)]));
    observe(this.nativeCheckObservations, expected);
  });
}
