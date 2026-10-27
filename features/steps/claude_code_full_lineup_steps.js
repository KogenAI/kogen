'use strict';
// Independent outer harness. Product tests/specifications remain editable implementation
// artifacts; an absent test, an empty selection or a skipped tail is never proof.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const GO_WATCHDOG = 240000;
const INSTALLED_WATCHDOG = 540000;
const CLEANUP_BOUND = 10000;
const GO_STEP_TIMEOUT = 3 * (GO_WATCHDOG + CLEANUP_BOUND) + 30000;
const INSTALLED_STEP_TIMEOUT = INSTALLED_WATCHDOG + CLEANUP_BOUND + 30000;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

// No command names, arguments, environment or global group membership confer ownership.
// A census is asynchronous and independently bounded: it cannot hold up the watchdog.
async function census(limit = 750) {
  return new Promise((resolve, reject) => {
    let ps, timer, text = '', diagnostic = '', settled = false;
    const finish = error => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      const problems = error ? [error] : [];
      for (const stream of [ps?.stdout, ps?.stderr]) {
        try { stream?.destroy(); } catch (failure) { problems.push(failure); }
      }
      if (problems.length) {
        try { if (Number.isInteger(ps?.pid) && ps.pid > 0) ps.kill('SIGKILL'); } catch (failure) { problems.push(failure); }
        try { ps?.unref(); } catch (failure) { problems.push(failure); }
        reject(new Error(problems.map(failure => failure.stack || String(failure)).join('\n')));
        return;
      }
      try {
        const rows = new Map();
        for (const line of text.split('\n').filter(line => line.trim())) {
          const m = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.+?)\s*$/.exec(line);
          assert.ok(m, 'unparseable process census');
          const row = { pid: +m[1], ppid: +m[2], pgid: +m[3], state: m[4], start: m[5] };
          if (process.platform === 'linux') {
            try {
              const stat = fs.readFileSync(`/proc/${row.pid}/stat`, 'utf8');
              const fields = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
              row.state = fields[0]; row.ppid = +fields[1]; row.pgid = +fields[2]; row.start = fields[19];
            } catch (error) { if (error.code === 'ENOENT' || error.code === 'ESRCH') continue; throw error; }
          }
          rows.set(row.pid, row);
        }
        assert.ok(rows.has(process.pid), 'incomplete process census');
        resolve(rows);
      } catch (error) { reject(error); }
    };
    try {
      ps = spawn('/bin/ps', ['-axo', 'pid=,ppid=,pgid=,stat=,lstart='], {
        env: { ...process.env, LC_ALL: 'C', TZ: 'UTC' }, stdio: ['ignore', 'pipe', 'pipe'],
      });
      // Keep the listener after settlement: kill failures can emit another error.
      // In particular, failed spawn can have NO streams and emit error next tick.
      ps.on('error', finish);
      for (const stream of [ps.stdout, ps.stderr]) stream?.on('error', finish);
      ps.once('close', code => finish(code === 0 ? null : new Error(`process census failed (${code}): ${diagnostic}`)));
      timer = setTimeout(() => finish(new Error('process census deadline expired')), limit);
      if (!Number.isInteger(ps.pid) || ps.pid <= 0) { finish(new Error('process census failed (no positive integer pid; spawn failed)')); return; }
      if (!ps.stdout || !ps.stderr) { finish(new Error('process census has absent stdio (failed spawn)')); return; }
      ps.stdout.setEncoding('utf8'); ps.stderr.setEncoding('utf8');
      ps.stdout.on('data', b => { text += b; });
      ps.stderr.on('data', b => { diagnostic += b; });
    } catch (error) { finish(error); }
  });
}
const sameProcess = (a, b) => !!a && !!b && a.pid === b.pid && a.start === b.start;
function captureDescendants(owned, rows) {
  let changed;
  do {
    changed = false;
    for (const row of rows.values()) {
      if (owned.has(row.pid) && sameProcess(owned.get(row.pid), row)) continue;
      const parent = owned.get(row.ppid);
      if (parent && sameProcess(parent, rows.get(parent.pid))) {
        owned.set(row.pid, { ...row, depth: parent.depth + 1 });
        changed = true;
      }
    }
  } while (changed);
}
const living = (owned, rows) => [...owned.values()].filter(p => sameProcess(p, rows.get(p.pid)));
function signalIdentity(identity, rows, signal) {
  if (!Number.isInteger(identity?.pid) || identity.pid <= 0 || !sameProcess(identity, rows.get(identity.pid))) return;
  try { process.kill(identity.pid, signal); } catch (error) { if (error.code !== 'ESRCH') throw error; }
}
function evidenceIO(result, file, operation) {
  try { return operation(); } catch (error) {
    (result.evidenceErrors ||= []).push(`${file}: ${error.stack || String(error)}`);
  }
}
function retainedFailure(result, error) {
  const reason = error.stack || String(error);
  result.reason = reason;
  const file = path.join(result.dir, 'failure.txt');
  evidenceIO(result, file, () => fs.writeFileSync(file, reason + '\n' + (result.evidenceErrors || []).join('\n'), { mode: 0o600 }));
  const tail = result.out.slice(-4000);
  const failure = new assert.AssertionError({ message: `${reason.length > 3000 ? reason.slice(0, 3000) + '\n[reason display abbreviated; complete reason in result.reason; failure.txt write attempted]' : reason}\nretained directory: ${result.dir}\ncomplete output: ${result.outputPath}\nreport: ${result.reportPath}\nsurvivors: ${JSON.stringify(result.survivors)}\nevidence I/O errors (not hidden): ${(result.evidenceErrors || []).join('\n') || 'none'}\noutput tail (${tail.length} of ${result.out.length} characters read; original output path retained):\n${tail}` });
  failure.result = result;
  return failure;
}
function validateOwned(result, observer) {
  try {
    assert.equal(result.cleanupProven, true, 'descendant disappearance was not proven');
    assert.deepEqual(result.survivors, [], 'owned process survivors');
    observer();
  } catch (error) { throw retainedFailure(result, error); }
}
function removePassing(results) {
  // Call only after EVERY observer for the step passed. Keep evidence outside tmp
  // while removing the potentially large inner workspace/release state.
  for (const result of results) {
    try {
      assert.equal(result.cleanupProven, true);
      fs.rmSync(result.tmp, { recursive: true, force: true });
      fs.rmSync(result.dir, { recursive: true });
    } catch (error) { throw retainedFailure(result, error); }
  }
}

// Exported interface: timeout is mandatory, in milliseconds, with no env override.
// args may be an array or a function of { dir, tmp, reportPath, outputPath }.
// A successful invocation is retained until the step's semantic observers pass.
// Failure throws an AssertionError carrying .result and absolute evidence paths.
async function runOwned(file, args, { timeout, cwd = ROOT, env = process.env } = {}) {
  assert.ok(Number.isInteger(timeout) && timeout > 0, 'explicit positive watchdog required');
  let dir = path.join(os.tmpdir(), 'kogen-lineup-owned-');
  const result = { dir, tmp: path.join(dir, 'tmp'), reportPath: path.join(dir, 'report.json'), outputPath: path.join(dir, 'output.log'), out: '', code: null, signal: null, timed: false, survivors: [], cleanupProven: false, evidenceErrors: [] };
  try {
    dir = fs.mkdtempSync(dir);
    result.dir = dir;
    result.tmp = path.join(dir, 'tmp'); result.reportPath = path.join(dir, 'report.json'); result.outputPath = path.join(dir, 'output.log');
    fs.chmodSync(dir, 0o700);
    fs.mkdirSync(result.tmp, { mode: 0o700 });
  } catch (error) { throw retainedFailure(result, error); }
  const owned = new Map();
  let rows = new Map(), child, exited = false, ending = false, cleanupDeadline = Infinity, fault, forceTimer;
  let lastWave = 0;
  const faults = [];
  const signalOwned = p => {
    if (exited && p.pid === child?.pid) return;
    try { signalIdentity(p, rows, 'SIGKILL'); } catch (error) { faults.push(error.message); }
  };
  const killLeaves = () => {
    if (Date.now() - lastWave < 150) return;
    lastWave = Date.now();
    const active = living(owned, rows).filter(p => !(exited && p.pid === child?.pid));
    for (const p of active.sort((a, b) => b.depth - a.depth)) {
      // Keep parents alive to reap children, including zombies. A zombie is NOT
      // disappearance. The final bounded census, not kill(pid, 0), proves cleanup.
      if (active.some(q => q.ppid === p.pid)) continue;
      signalOwned(p);
    }
  };
  const end = () => {
    if (!ending) {
      ending = true; cleanupDeadline = Date.now() + CLEANUP_BOUND;
      clearTimeout(watchdog);
      const began = Date.now();
      // Observation-independent escalation, still leaf first. Space depths so
      // already-killed children can be reaped even when every census is failing.
      forceTimer = setInterval(() => {
        const active = living(owned, rows).sort((a, b) => b.depth - a.depth);
        const threshold = (active[0]?.depth || 0) - Math.floor((Date.now() - began - 3000) / 250);
        for (const p of active) if (p.depth >= threshold) signalOwned(p);
      }, 250);
    }
    killLeaves(); // Deliberately no await/census here, including in the timer.
  };
  const watchdog = setTimeout(() => { result.timed = true; end(); }, timeout);
  try {
    const fd = fs.openSync(result.outputPath, 'wx', 0o600);
    try {
      const argv = typeof args === 'function' ? args(result) : args;
      // Establish the root's start identity before it can exec or fork. Positional
      // arguments are passed intact, never interpolated into a shell command.
      child = spawn('/bin/sh', ['-c', 'kill -STOP "$$"; exec "$@"', 'lineup-owned', file, ...argv], {
        cwd, env: { ...env, TMPDIR: result.tmp, TMP: result.tmp, TEMP: result.tmp },
        detached: true, stdio: ['ignore', fd, fd],
      });
      child.on('error', error => { fault ||= error; if (!Number.isInteger(child.pid) || child.pid <= 0) exited = true; end(); });
      child.once('exit', (code, signal) => { result.code = code; result.signal = signal; exited = true; end(); });
      // A failed spawn can retain a native pid-0 handle until next tick.
      // Mark it not started BEFORE any await; keep the error listener attached.
      if (!Number.isInteger(child.pid) || child.pid <= 0) {
        exited = true;
        fault ||= new Error('owned root spawn failed (no positive integer pid)');
        faults.push(fault.message);
        end();
      }
    } finally { fs.closeSync(fd); }
    rows = await census();
    const root = rows.get(child.pid);
    assert.ok(root && root.ppid === process.pid, 'owned root was not observed');
    owned.set(root.pid, { ...root, depth: 0 });
    if (!ending) signalIdentity(root, rows, 'SIGCONT');
    else killLeaves();
    while (!ending) {
      await sleep(20);
      rows = await census();
      captureDescendants(owned, rows);
    }
  } catch (error) {
    fault ||= error; end();
    // Before the initial gate opens no descendants can exist. Only a positive
    // PID can identify an unreaped direct child; a failed handle may mean pid 0.
    if (!owned.size && Number.isInteger(child?.pid) && child.pid > 0 && !exited) {
      try { child.kill('SIGKILL'); } catch (failure) { faults.push(failure.message); }
    }
  }
  if (!child) result.cleanupProven = true;
  while (!result.cleanupProven && Date.now() < cleanupDeadline) {
    try {
      rows = await census(Math.max(1, Math.min(750, cleanupDeadline - Date.now())));
      captureDescendants(owned, rows);
      if (exited && living(owned, rows).length === 0) { result.cleanupProven = true; break; }
    } catch (error) { faults.push(error.message); }
    killLeaves(); // Census failure must not suppress signalling or escalation.
    await sleep(Math.max(0, Math.min(50, cleanupDeadline - Date.now())));
  }
  clearTimeout(watchdog); clearInterval(forceTimer);
  result.survivors = living(owned, rows);
  if (!result.cleanupProven && !owned.size && !exited) result.survivors.push({ pid: child?.pid, start: 'unobserved initial gate' });
  result.observed = [...owned.values()];
  result.faults = faults;
  evidenceIO(result, result.outputPath, () => { result.out = fs.readFileSync(result.outputPath, 'utf8'); });
  const resultPath = path.join(dir, 'result.json');
  evidenceIO(result, resultPath, () => fs.writeFileSync(resultPath, JSON.stringify({ ...result, out: undefined }, null, 2) + '\n', { mode: 0o600 }));
  validateOwned(result, () => {
    if (fault) throw fault;
    assert.deepEqual(faults, [], 'process observation/signalling failed');
    assert.deepEqual(result.evidenceErrors, [], 'evidence I/O failed');
    processEvidence(result);
  });
  return result;
}

// Real local fixture: root -> intermediate -> detached grandchild. The
// intermediate stays alive and reaps its child if the runner kills leaf-first.
// The grandchild inherits output handles in the new-runner control.
function lifecycleFixture(role, directory, pipes) {
  const opts = { stdio: pipes === 'hold' ? ['ignore', 1, 2] : 'ignore' };
  if (role === 'root') {
    fs.writeFileSync(path.join(directory, 'root.pid'), String(process.pid));
    fs.writeFileSync(path.join(directory, 'report.json'), JSON.stringify({ fixture: 'lifecycle', tmp: process.env.TMPDIR }));
    fs.mkdirSync(path.join(process.env.TMPDIR, 'kogen-acceptance-release-control'));
    fs.mkdirSync(path.join(process.env.TMPDIR, 'kogen-acceptance-workspace-control'));
    fs.writeFileSync(path.join(process.env.TMPDIR, `kogen-acceptance-shared-${process.pid}.json`), '{}');
    process.stdout.write('lifecycle complete output\n');
    spawn(process.execPath, [__filename, 'lifecycle-fixture', 'middle', directory, pipes], opts);
  } else if (role === 'middle') {
    spawn(process.execPath, [__filename, 'lifecycle-fixture', 'leaf', directory, pipes], { ...opts, detached: true });
  } else {
    assert.equal(role, 'leaf');
    fs.writeFileSync(path.join(directory, 'leaf.pid'), String(process.pid));
    if (pipes === 'hold') process.stderr.write('grandchild inherited output\n');
  }
  setInterval(() => {}, 1000);
}
async function waitUntil(test, ms = 5000) {
  const deadline = Date.now() + ms;
  while (!(await test())) { assert.ok(Date.now() < deadline, 'control deadline expired'); await sleep(20); }
}
function lifecycleEvidence(witness) {
  assert.ok(witness.elapsed < 1500 + CLEANUP_BOUND + 2000, 'runner completion was unbounded');
  assert.match(witness.error.message, /watchdog expired/);
  for (const name of [witness.result.dir, witness.result.outputPath, witness.result.reportPath]) assert.ok(witness.error.message.includes(name), `missing retained path: ${name}`);
  assert.ok(witness.error.message.includes('survivors:'));
  assert.ok(fs.statSync(witness.result.dir).isDirectory(), 'failed directory removed');
  assert.equal(fs.statSync(witness.result.dir).mode & 0o777, 0o700);
  assert.match(fs.readFileSync(witness.result.outputPath, 'utf8'), /lifecycle complete output/);
  assert.equal(JSON.parse(fs.readFileSync(witness.result.reportPath, 'utf8')).fixture, 'lifecycle');
  assert.equal(witness.observed.length, 3, 'fixture lineage was not observed before termination');
  assert.notEqual(witness.observed[0].pgid, witness.observed[2].pgid, 'grandchild did not detach');
  assert.deepEqual(witness.survivors, [], 'detached grandchild survived');
}
async function retentionControls() {
  const kept = [];
  try {
    for (const finish of ['process.exit(7)', 'if (Number.isInteger(process.pid) && process.pid > 0) process.kill(process.pid,"SIGTERM")']) {
      let failure;
      try {
        await runOwned(process.execPath, r => ['-e', `require('fs').writeFileSync(${JSON.stringify(r.reportPath)}, '{"retained":true}'); process.stdout.write('x'.repeat(9000)); process.stderr.write('stderr diagnostic\\n'); ${finish}`], { timeout: 1500 });
      } catch (error) { failure = error; }
      assert.ok(failure?.result, 'abnormal exit must retain a result');
      const r = failure.result; kept.push(r);
      assert.ok(failure.message.includes(r.dir) && failure.message.includes(r.outputPath));
      assert.ok(failure.message.includes('survivors: []'));
      assert.ok(r.cleanupProven);
      assert.equal(fs.readFileSync(r.outputPath, 'utf8'), 'x'.repeat(9000) + 'stderr diagnostic\n');
      assert.deepEqual(JSON.parse(fs.readFileSync(r.reportPath, 'utf8')), { retained: true });
      if (finish.includes('exit')) assert.equal(r.code, 7);
      else { assert.equal(r.signal, 'SIGTERM'); assert.match(failure.message, /process was signalled/); }
    }
    const mismatch = await runOwned(process.execPath, r => ['-e', `require('fs').writeFileSync(${JSON.stringify(r.reportPath)}, '[]'); console.log('compiler diagnostic')`], { timeout: 1500 });
    kept.push(mismatch);
    assert.throws(() => validateOwned(mismatch, () => scenarioEvidence(mismatch, fs.readFileSync(mismatch.reportPath, 'utf8'), ['Required'])), /scenarios must execute exactly once/);
    assert.ok(fs.existsSync(mismatch.reportPath));
    assert.throws(() => validateOwned(mismatch, () => goEvidence(mismatch, 'kogen/fixture', ['TestBoundary'])), /retained directory:/);
    assert.equal(fs.readFileSync(mismatch.outputPath, 'utf8'), 'compiler diagnostic\n');
    const passed = await runOwned(process.execPath, ['-e', 'process.stdout.write("passed\\n")'], { timeout: 1500 });
    kept.push(passed);
    validateOwned(passed, () => processEvidence(passed));
    removePassing([passed]);
    assert.equal(fs.existsSync(passed.dir), false, 'passing invocation was not removed');
  } finally {
    for (const r of kept) fs.rmSync(r.dir, { recursive: true, force: true });
  }
}
async function lifecycleControl(mode) {
  assert.equal(process.umask(), 0o077, 'run lifecycle controls under actual umask 077');
  assert.ok(['good', 'bad'].includes(mode));
  const isGood = mode === 'good';
  const controlDir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-lineup-control-')));
  const owned = new Map();
  let fixtureDir = controlDir, result, error, pending;
  const started = Date.now();
  try {
    if (isGood) {
      pending = runOwned(process.execPath, r => {
        fixtureDir = r.dir;
        return [__filename, 'lifecycle-fixture', 'root', fixtureDir, 'hold'];
      }, { timeout: 1500 }).then(r => { result = r; }, e => { error = e; result = e.result; });
    } else {
      const H = require('./go_driver_support');
      fs.mkdirSync(path.join(controlDir, 'tmp'));
      pending = H.run(process.execPath, [__filename, 'lifecycle-fixture', 'root', controlDir, 'ignore'], { timeout: 1500, env: { ...process.env, TMPDIR: path.join(controlDir, 'tmp') } }).then(r => { result = { ...r, dir: controlDir, tmp: path.join(controlDir, 'tmp'), outputPath: path.join(controlDir, 'output.log'), reportPath: path.join(controlDir, 'report.json') }; });
    }
    await waitUntil(() => fs.existsSync(path.join(fixtureDir, 'root.pid')));
    const rootPid = +fs.readFileSync(path.join(fixtureDir, 'root.pid'), 'utf8');
    let snapshot = await census();
    const root = snapshot.get(rootPid);
    assert.ok(root && root.ppid === process.pid, 'control root is not our child');
    owned.set(rootPid, { ...root, depth: 0 });
    await waitUntil(async () => {
      snapshot = await census(); captureDescendants(owned, snapshot);
      return owned.size === 3 && fs.existsSync(path.join(fixtureDir, 'leaf.pid'));
    }, 1000);
    await pending;
    if (isGood) {
      assert.ok(error && result, 'watchdog must fail with retained result');
      assert.match(result.out, /grandchild inherited output/);
      assert.ok(fs.existsSync(path.join(result.tmp, 'kogen-acceptance-release-control')));
      assert.ok(fs.existsSync(path.join(result.tmp, 'kogen-acceptance-workspace-control')));
      assert.ok(fs.readdirSync(result.tmp).some(n => n.startsWith('kogen-acceptance-shared-')));
      assert.equal(JSON.parse(fs.readFileSync(result.reportPath, 'utf8')).tmp, result.tmp);
    } else {
      fs.writeFileSync(result.outputPath, result.out);
      result.survivors = living(owned, await census());
      error = retainedFailure(result, new Error(result.timed ? 'watchdog expired' : 'watchdog did not expire'));
    }
    const witness = { result, error, observed: [...owned.values()].sort((a, b) => a.depth - b.depth), survivors: living(owned, await census()), elapsed: Date.now() - started };
    if (isGood) {
      lifecycleEvidence(witness);
      assert.deepEqual(result.survivors, []);
      await retentionControls();
      process.stdout.write('full-lineup lifecycle accepts owned cleanup and retained failure\n');
    } else {
      assert.equal(witness.survivors.length, 1, 'old path must leave only the detached grandchild');
      assert.equal(witness.survivors[0].pid, +fs.readFileSync(path.join(fixtureDir, 'leaf.pid'), 'utf8'));
      assert.throws(() => lifecycleEvidence(witness), /detached grandchild survived/);
      process.stdout.write('full-lineup lifecycle rejects plain H.run orphan\n');
      process.exitCode = 19;
    }
  } finally {
    if (pending) await pending;
    const snapshot = await census();
    // The negative control cleans only its exact lineage-observed grandchild.
    for (const p of living(owned, snapshot)) if (isGood || p.depth === 2) signalIdentity(p, snapshot, 'SIGKILL');
    await waitUntil(async () => living(owned, await census()).length === 0);
    if (result?.dir !== controlDir && result?.dir) fs.rmSync(result.dir, { recursive: true, force: true });
    fs.rmSync(controlDir, { recursive: true, force: true });
  }
}

// Verbatim e502c4f7 functions, with only the declaration names restored before
// replay. They are inert except in the isolated negative control workers.
async function baselineCensus(limit = 750) {
  return new Promise((resolve, reject) => {
    const ps = spawn('/bin/ps', ['-axo', 'pid=,ppid=,pgid=,stat=,lstart='], {
      env: { ...process.env, LC_ALL: 'C', TZ: 'UTC' }, stdio: ['ignore', 'pipe', 'pipe'],
    });
    let text = '', diagnostic = '', settled = false;
    const finish = error => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      ps.stdout.destroy(); ps.stderr.destroy();
      if (error) { ps.kill('SIGKILL'); ps.unref(); reject(error); return; }
      try {
        const rows = new Map();
        for (const line of text.split('\n').filter(line => line.trim())) {
          const m = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.+?)\s*$/.exec(line);
          assert.ok(m, 'unparseable process census');
          const row = { pid: +m[1], ppid: +m[2], pgid: +m[3], state: m[4], start: m[5] };
          if (process.platform === 'linux') {
            try {
              const stat = fs.readFileSync(`/proc/${row.pid}/stat`, 'utf8');
              const fields = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
              row.state = fields[0]; row.ppid = +fields[1]; row.pgid = +fields[2]; row.start = fields[19];
            } catch (error) { if (error.code === 'ENOENT' || error.code === 'ESRCH') continue; throw error; }
          }
          rows.set(row.pid, row);
        }
        assert.ok(rows.has(process.pid), 'incomplete process census');
        resolve(rows);
      } catch (error) { reject(error); }
    };
    const timer = setTimeout(() => finish(new Error('process census deadline expired')), limit);
    ps.stdout.setEncoding('utf8'); ps.stderr.setEncoding('utf8');
    ps.stdout.on('data', b => { text += b; });
    ps.stderr.on('data', b => { diagnostic += b; });
    ps.once('error', finish);
    ps.once('close', code => finish(code === 0 ? null : new Error(`process census failed (${code}): ${diagnostic}`)));
  });
}
async function baselineRunOwned(file, args, { timeout, cwd = ROOT, env = process.env } = {}) {
  assert.ok(Number.isInteger(timeout) && timeout > 0, 'explicit positive watchdog required');
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-lineup-owned-')));
  fs.chmodSync(dir, 0o700);
  const result = { dir, tmp: path.join(dir, 'tmp'), reportPath: path.join(dir, 'report.json'), outputPath: path.join(dir, 'output.log'), out: '', code: null, signal: null, timed: false, survivors: [], cleanupProven: false };
  fs.mkdirSync(result.tmp, { mode: 0o700 });
  const owned = new Map();
  let rows = new Map(), child, exited = false, ending = false, cleanupDeadline = Infinity, fault, forceTimer;
  let lastWave = 0;
  const faults = [];
  const signalOwned = p => {
    if (exited && p.pid === child?.pid) return;
    try { signalIdentity(p, rows, 'SIGKILL'); } catch (error) { faults.push(error.message); }
  };
  const killLeaves = () => {
    if (Date.now() - lastWave < 150) return;
    lastWave = Date.now();
    const active = living(owned, rows).filter(p => !(exited && p.pid === child?.pid));
    for (const p of active.sort((a, b) => b.depth - a.depth)) {
      // Keep parents alive to reap children, including zombies. A zombie is NOT
      // disappearance. The final bounded census, not kill(pid, 0), proves cleanup.
      if (active.some(q => q.ppid === p.pid)) continue;
      signalOwned(p);
    }
  };
  const end = () => {
    if (!ending) {
      ending = true; cleanupDeadline = Date.now() + CLEANUP_BOUND;
      clearTimeout(watchdog);
      // Independent escalation also reaches parents if observation is stalled or
      // a parent cannot reap. It uses only previously observed owned identities.
      forceTimer = setTimeout(() => {
        for (const p of living(owned, rows).sort((a, b) => b.depth - a.depth)) signalOwned(p);
      }, 3000);
    }
    killLeaves(); // Deliberately no await/census here, including in the timer.
  };
  const watchdog = setTimeout(() => { result.timed = true; end(); }, timeout);
  try {
    const fd = fs.openSync(result.outputPath, 'wx', 0o600);
    try {
      const argv = typeof args === 'function' ? args(result) : args;
      // Establish the root's start identity before it can exec or fork. Positional
      // arguments are passed intact, never interpolated into a shell command.
      child = spawn('/bin/sh', ['-c', 'kill -STOP "$$"; exec "$@"', 'lineup-owned', file, ...argv], {
        cwd, env: { ...env, TMPDIR: result.tmp, TMP: result.tmp, TEMP: result.tmp },
        detached: true, stdio: ['ignore', fd, fd],
      });
    } finally { fs.closeSync(fd); }
    child.once('error', error => { fault = error; exited = true; end(); });
    child.once('exit', (code, signal) => { result.code = code; result.signal = signal; exited = true; end(); });
    rows = await census();
    const root = rows.get(child.pid);
    assert.ok(root && root.ppid === process.pid, 'owned root was not observed');
    owned.set(root.pid, { ...root, depth: 0 });
    if (!ending) signalIdentity(root, rows, 'SIGCONT');
    else killLeaves();
    while (!ending) {
      await sleep(20);
      rows = await census();
      captureDescendants(owned, rows);
    }
  } catch (error) {
    fault = error; end();
    // Before the initial gate opens no descendants can exist. The ChildProcess
    // handle still owns this unreaped direct child even if the census failed.
    if (!owned.size && child && !exited) child.kill('SIGKILL');
  }
  while (Date.now() < cleanupDeadline) {
    try {
      rows = await census(Math.max(1, Math.min(750, cleanupDeadline - Date.now())));
      captureDescendants(owned, rows);
      if (exited && living(owned, rows).length === 0) { result.cleanupProven = true; break; }
      killLeaves();
    } catch (error) { faults.push(error.message); }
    await sleep(50);
  }
  clearTimeout(watchdog); clearTimeout(forceTimer);
  result.survivors = living(owned, rows);
  if (!result.cleanupProven && !owned.size && !exited) result.survivors.push({ pid: child?.pid, start: 'unobserved initial gate' });
  result.observed = [...owned.values()];
  result.out = fs.readFileSync(result.outputPath, 'utf8');
  fs.writeFileSync(path.join(dir, 'result.json'), JSON.stringify({ ...result, out: undefined, faults }, null, 2) + '\n', { mode: 0o600 });
  validateOwned(result, () => {
    if (fault) throw fault;
    assert.deepEqual(faults, [], 'process observation/signalling failed');
    processEvidence(result);
  });
  return result;
}

// Replay final runner bytes in a private lexical scope; injections are confined
// to controls, never an exported runner option or an environment budget knob.
function runnerSource() {
  const source = fs.readFileSync(__filename, 'utf8');
  return source.slice(source.indexOf('async function census'), source.indexOf('// Real local fixture'));
}
function compileRunner(source, { spawnImpl = spawn, fsImpl = fs, processImpl = process, observed = () => {} } = {}) {
  return new Function('spawn', 'fs', 'assert', 'os', 'path', 'process', 'ROOT', 'CLEANUP_BOUND', 'sleep', 'observed', 'processEvidence', source + '\nconst capture = captureDescendants; captureDescendants = (owned, rows) => { capture(owned, rows); observed(owned, rows); }; return { runOwned, census };')(spawnImpl, fsImpl, assert, os, path, processImpl, ROOT, CLEANUP_BOUND, sleep, observed, processEvidence);
}
function livenessEvidence(witness) {
  assert.equal(witness.code, 0, 'runner crashed or control failed');
  assert.equal(witness.stderr, '', 'uncaught/process diagnostic');
  assert.equal(witness.notice.observed.length, 3, 'runner did not observe complete lineage');
  assert.deepEqual(witness.notice.observed.map(p => p.depth).sort(), [0, 1, 2]);
  const done = witness.done;
  assert.equal(done?.name, 'AssertionError', 'runner must return retained-path AssertionError');
  assert.ok(done.elapsed >= CLEANUP_BOUND - 50 && done.elapsed < CLEANUP_BOUND + 2500, 'cleanup was abandoned or unbounded');
  assert.equal(done.cleanupProven, false, 'no disappearance proof is possible while exhausted');
  assert.equal(done.survivors.length, 3, 'unresolved previously observed identities must be reported');
  for (const p of [witness.notice.dir, done.outputPath, done.reportPath]) assert.ok(done.message.includes(p), 'retained path missing');
  for (const name of ['output.log', 'result.json', 'failure.txt']) assert.ok(done.evidenceErrors.some(e => e.includes(name) && e.includes('EMFILE')), `missing evidence I/O failure: ${name}`);
  assert.deepEqual(witness.survivors, [], 'owned identity survived after fd release');
  assert.ok(fs.existsSync(witness.notice.dir), 'failed directory removed');
  assert.match(fs.readFileSync(done.outputPath, 'utf8'), /lifecycle complete output/);
  assert.equal(JSON.parse(fs.readFileSync(done.reportPath, 'utf8')).fixture, 'lifecycle');
}
async function livenessWorker(mode) {
  assert.equal(process.umask(), 0o077);
  void process.stdout; void process.stderr; // Prime lazy stdio BEFORE exhaustion.
  let source = runnerSource();
  if (mode === 'bad') {
    const oldCensus = baselineCensus.toString().replace('baselineCensus', 'census');
    const oldRun = baselineRunOwned.toString().replace('baselineRunOwned', 'runOwned');
    const sha = s => require('node:crypto').createHash('sha256').update(s).digest('hex');
    assert.equal(sha(oldCensus), 'f228bebe2a713865af10d6065a4357ef08a4d2778f24acac741e07ab1a0288b7');
    assert.equal(sha(oldRun), '48b66bb7633e138f67edceaa553080087b9802190d1b23bbcb52826f426ab922');
    source = source.replace(census.toString(), oldCensus).replace(runOwned.toString(), oldRun);
  } else assert.equal(mode, 'good');
  const held = [];
  let injected = 0, directory;
  const send = value => fs.writeSync(1, JSON.stringify(value) + '\n');
  const runner = compileRunner(source, { observed: owned => {
    if (owned.size !== 3 || injected) return;
    injected = Date.now();
    const observed = [...owned.values()];
    assert.notEqual(observed.find(p => p.depth === 0).pgid, observed.find(p => p.depth === 2).pgid);
    send({ type: 'observed', observed, dir: directory });
    let exhausted = false;
    try { for (let i = 0; i < 512; i++) held.push(fs.openSync('/dev/null', 'r')); } catch (error) { assert.equal(error.code, 'EMFILE'); exhausted = true; }
    assert.ok(exhausted, 'bounded fd control did not observe EMFILE');
    assert.ok(held.length > 20, 'own-process fd exhaustion was not reached');
  } });
  let error;
  try {
    await runner.runOwned(process.execPath, r => {
      directory = r.dir;
      return [__filename, 'lifecycle-fixture', 'root', r.dir, 'hold'];
    }, { timeout: 5000 });
  } catch (failure) { error = failure; }
  finally { for (const fd of held) fs.closeSync(fd); }
  // Leave time for the old 750ms timer's second uncaught path, if still armed.
  await sleep(900);
  assert.ok(injected, 'exhaustion did not follow actual owned lineage observation');
  send({ type: 'done', name: error?.name, message: error?.message, elapsed: Date.now() - injected - 900, cleanupProven: error?.result?.cleanupProven, survivors: error?.result?.survivors, evidenceErrors: error?.result?.evidenceErrors, outputPath: error?.result?.outputPath, reportPath: error?.result?.reportPath });
}
async function failureBranchControls() {
  const { EventEmitter } = require('node:events');
  const { PassThrough } = require('node:stream');
  for (const mode of ['spawn', 'error', 'no-stream', 'nonzero', 'timeout', 'stream-error', 'destroy', 'kill']) {
    const spawnImpl = () => {
      if (mode === 'spawn') throw new Error('scoped spawn throw');
      const ps = new EventEmitter();
      if (!['error', 'no-stream'].includes(mode)) ps.pid = 12345;
      ps.kill = () => { assert.ok(Number.isInteger(ps.pid) && ps.pid > 0, 'never signal a failed spawn'); if (mode === 'kill') throw new Error('scoped kill throw'); };
      ps.unref = () => {};
      if (!['error', 'no-stream'].includes(mode)) {
        ps.stdout = new PassThrough(); ps.stderr = new PassThrough();
        if (mode === 'destroy') ps.stdout.destroy = () => { throw new Error('scoped destroy throw'); };
      }
      process.nextTick(() => {
        if (mode === 'error' || mode === 'no-stream') ps.emit('error', new Error('scoped spawn error'));
        else if (mode === 'stream-error') ps.stdout.emit('error', new Error('scoped stream error'));
        else if (mode === 'nonzero') { ps.stderr.write('scoped diagnostic'); ps.emit('close', 7); }
        else if (mode === 'destroy') ps.emit('close', 0);
      });
      return ps;
    };
    const started = Date.now();
    await assert.rejects(compileRunner(runnerSource(), { spawnImpl }).census(30), /scoped|deadline|absent stdio|process census failed/);
    assert.ok(Date.now() - started < 1000, `unbounded scoped ${mode}`);
    await sleep(40); // An armed timer or late error must not escape settlement.
  }
  for (const name of ['output.log', 'result.json', 'failure.txt']) {
    const fsImpl = new Proxy(fs, { get(target, key) {
      if (key === 'readFileSync' || key === 'writeFileSync') return (file, ...args) => {
        if (path.basename(String(file)) === name) throw Object.assign(new Error(`scoped evidence I/O ${name}`), { code: 'EMFILE' });
        return target[key](file, ...args);
      };
      return target[key];
    } });
    let error;
    try { await compileRunner(runnerSource(), { fsImpl }).runOwned(process.execPath, ['-e', 'process.exit(7)'], { timeout: 1500 }); }
    catch (failure) { error = failure; }
    try {
      assert.ok(error instanceof assert.AssertionError);
      assert.ok(error.result.cleanupProven);
      assert.ok(error.message.includes(error.result.dir));
      assert.ok(error.result.evidenceErrors.some(e => e.includes(name)));
      assert.match(error.message, /scoped evidence I\/O/);
    } finally { if (error?.result?.dir) fs.rmSync(error.result.dir, { recursive: true, force: true }); }
  }
  let injected = false, failure;
  const processImpl = new Proxy(process, { get(target, key) {
    if (key === 'kill') return (pid, signal) => {
      if (signal === 'SIGKILL' && !injected) { injected = true; throw new Error('scoped signal failure'); }
      assert.ok(Number.isInteger(pid) && pid > 0, 'never signal an invalid pid');
      return process.kill(pid, signal);
    };
    return target[key];
  } });
  try { await compileRunner(runnerSource(), { processImpl }).runOwned(process.execPath, ['-e', 'setInterval(()=>{},1000)'], { timeout: 300 }); }
  catch (error) { failure = error; }
  try {
    assert.ok(injected && failure instanceof assert.AssertionError);
    assert.ok(failure.result.cleanupProven);
    assert.ok(failure.result.faults.includes('scoped signal failure'));
  } finally { if (failure?.result?.dir) fs.rmSync(failure.result.dir, { recursive: true, force: true }); }
}
async function livenessControl(mode) {
  assert.equal(process.umask(), 0o077, 'run liveness controls under actual umask 077');
  assert.ok(['good', 'bad'].includes(mode));
  const worker = spawn('/bin/sh', ['-c', 'ulimit -n 256; exec "$@"', 'liveness-worker', process.execPath, __filename, 'liveness-worker', mode], { stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '', stderr = '', notice, done, timer;
  const owned = new Map();
  try {
    const completion = new Promise((resolve, reject) => {
      worker.on('error', reject);
      worker.stdout.on('error', reject); worker.stderr.on('error', reject);
      worker.stdout.setEncoding('utf8'); worker.stderr.setEncoding('utf8');
      worker.stdout.on('data', text => { stdout += text; });
      worker.stderr.on('data', text => { stderr += text; });
      worker.once('close', (code, signal) => resolve({ code, signal }));
      timer = setTimeout(() => { if (Number.isInteger(worker.pid) && worker.pid > 0) worker.kill('SIGKILL'); reject(new Error('liveness worker deadline expired')); }, 20000);
    });
    const outcome = await completion;
    clearTimeout(timer);
    for (const line of stdout.split('\n').filter(Boolean)) {
      const event = JSON.parse(line);
      if (event.type === 'observed') notice = event;
      else if (event.type === 'done') done = event;
      else assert.fail('unknown liveness event');
    }
    assert.equal(notice?.observed.length, 3, 'baseline and candidate must reach the same injection gate');
    for (const p of notice.observed) owned.set(p.pid, p);
    const witness = { ...outcome, stderr, notice, done, survivors: living(owned, await census()) };
    if (mode === 'good') {
      livenessEvidence(witness);
      await failureBranchControls();
      process.stdout.write('full-lineup liveness accepts bounded exhausted cleanup and reported I/O failures\n');
    } else {
      assert.ok(outcome.code !== 0 || witness.survivors.length, 'unchanged e502 runner unexpectedly satisfied liveness');
      if (outcome.code !== 0) assert.match(stderr, /EMFILE|TypeError/);
      assert.throws(() => livenessEvidence(witness), /runner crashed|AssertionError|survived/);
      process.stdout.write('full-lineup liveness rejects unchanged e502 runner under fd exhaustion\n');
      process.exitCode = 19;
    }
  } finally {
    clearTimeout(timer);
    // Parse the notice even if a worker failure masked subsequent checks.
    if (!notice) for (const line of stdout.split('\n').filter(Boolean)) {
      const event = JSON.parse(line); if (event.type === 'observed') notice = event;
    }
    for (const p of notice?.observed || []) owned.set(p.pid, p);
    // Only exact reported lineage identities, leaf first; no name/group sweep.
    for (const depth of [2, 1, 0]) {
      const rows = await census();
      for (const p of living(owned, rows)) if (p.depth === depth) signalIdentity(p, rows, 'SIGKILL');
      await sleep(250);
    }
    await waitUntil(async () => living(owned, await census()).length === 0);
    if (notice?.dir) fs.rmSync(notice.dir, { recursive: true, force: true });
  }
}

// Regression for the failed-spawn pid-0 native handle. Only the isolated bad
// worker replays the deliberately unsafe, hash-checked historical functions.
async function failedSpawnWorker(mode, directory) {
  assert.equal(process.umask(), 0o077);
  assert.ok(['good', 'bad'].includes(mode));
  const sentinel = spawn(process.execPath, ['-e', 'setInterval(()=>{},1000)'], { stdio: 'ignore' });
  let sentinelError;
  sentinel.on('error', error => { sentinelError = error; });
  await new Promise((resolve, reject) => { sentinel.once('spawn', resolve); sentinel.once('error', reject); });
  sentinel.unref(); // Parent control owns cleanup, including after worker exit.
  fs.writeFileSync(path.join(directory, 'notice.json'), JSON.stringify({ worker: process.pid, sentinel: sentinel.pid }));
  await waitUntil(() => fs.existsSync(path.join(directory, 'gate')));
  let source = runnerSource();
  if (mode === 'bad') {
    const oldCensus = baselineCensus.toString().replace('baselineCensus', 'census');
    const oldRun = baselineRunOwned.toString().replace('baselineRunOwned', 'runOwned');
    const sha = s => require('node:crypto').createHash('sha256').update(s).digest('hex');
    assert.equal(sha(oldCensus), 'f228bebe2a713865af10d6065a4357ef08a4d2778f24acac741e07ab1a0288b7');
    assert.equal(sha(oldRun), '48b66bb7633e138f67edceaa553080087b9802190d1b23bbcb52826f426ab922');
    source = source.replace(census.toString(), oldCensus).replace(runOwned.toString(), oldRun);
  }
  const rootErrors = [];
  let failedChild, invocationDir;
  const runner = compileRunner(source, { spawnImpl: (file, args, options) => {
    if (file === '/bin/sh') {
      assert.equal(failedChild, undefined, 'only one owned-root spawn');
      failedChild = spawn(path.join(directory, 'nonexistent-owned-root'), args, options);
      failedChild.on('error', error => { rootErrors.push(error.code); });
      assert.equal(failedChild.pid, undefined, 'must be a real failed spawn handle');
      return failedChild;
    }
    assert.equal(file, '/bin/ps');
    const ps = new (require('node:events').EventEmitter)(); // Absent stdio, no real census process.
    ps.unref = () => {};
    if (!fs.existsSync(path.join(directory, 'armed.json'))) {
      fs.writeFileSync(path.join(directory, 'armed.json'), JSON.stringify({ rootPidAbsent: failedChild.pid === undefined, rootErrors: rootErrors.length, absentStdio: !ps.stdout && !ps.stderr }));
    }
    return ps;
  } });
  let error;
  const began = Date.now();
  // This async continuation is a microtask drain, BEFORE the failed spawn's
  // next-tick error. The census rejection must not signal its pid-0 handle.
  try {
    await runner.runOwned(process.execPath, r => {
      invocationDir = r.dir;
      fs.writeFileSync(path.join(directory, 'invocation.json'), JSON.stringify(r.dir));
      return ['-e', ''];
    }, { timeout: 1500 });
  } catch (failure) { error = failure; }
  await sleep(30); // Exercise the real late error without an uncaught event.
  assert.equal(sentinelError, undefined);
  fs.writeFileSync(path.join(directory, 'done.json'), JSON.stringify({ name: error?.name, message: error?.message, result: error?.result, elapsed: Date.now() - began, rootErrors, invocationDir }));
}
function failedSpawnEvidence(witness) {
  assert.equal(witness.code, 0, 'worker did not exit normally');
  assert.equal(witness.signal, null, 'worker was signalled');
  assert.equal(witness.stdout, '', 'unexpected worker output');
  assert.equal(witness.stderr, '', 'uncaught/process diagnostic');
  assert.equal(witness.sentinelAlive, true, 'same-group sentinel was killed');
  const done = witness.done;
  assert.equal(done?.name, 'AssertionError', 'retained-path AssertionError required');
  assert.ok(done.elapsed >= CLEANUP_BOUND - 50 && done.elapsed < CLEANUP_BOUND + 2500, 'cleanup was abandoned or unbounded');
  assert.deepEqual(done.rootErrors, ['ENOENT'], 'real late spawn error was not tolerated');
  const r = done.result;
  assert.equal(r.cleanupProven, false, 'failed observation cannot prove disappearance');
  assert.equal(r.code, null); assert.equal(r.signal, null); assert.equal(r.timed, false);
  assert.deepEqual(r.observed, []); assert.deepEqual(r.survivors, []);
  assert.deepEqual(r.evidenceErrors, []);
  assert.ok(r.faults.some(fault => fault.includes('owned root spawn failed')), 'synchronous spawn fault was not recorded');
  assert.match(r.reason, /descendant disappearance was not proven/);
  for (const file of [r.dir, r.outputPath, r.reportPath]) assert.ok(done.message.includes(file), 'retained path missing');
  assert.ok(fs.statSync(r.dir).isDirectory());
  assert.equal(fs.statSync(r.dir).mode & 0o777, 0o700);
  assert.ok(fs.existsSync(r.outputPath));
  assert.ok(fs.existsSync(path.join(r.dir, 'result.json')));
  assert.ok(fs.readFileSync(path.join(r.dir, 'failure.txt'), 'utf8').includes(r.reason));
}
async function failedSpawnControl(mode) {
  assert.equal(process.umask(), 0o077, 'run failed-spawn controls under actual umask 077');
  assert.ok(['good', 'bad'].includes(mode));
  const directory = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-lineup-failed-spawn-')));
  const owned = new Map();
  let stdout = '', stderr = '', timer, timed = false, notice, done, spawnError;
  const worker = spawn(process.execPath, [__filename, 'failed-spawn-worker', mode, directory], { detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  const completion = new Promise(resolve => {
    worker.on('error', error => { spawnError = error; });
    worker.stdout?.on('error', error => { spawnError = error; });
    worker.stderr?.on('error', error => { spawnError = error; });
    worker.stdout?.setEncoding('utf8'); worker.stderr?.setEncoding('utf8');
    worker.stdout?.on('data', text => { stdout += text; });
    worker.stderr?.on('data', text => { stderr += text; });
    worker.once('close', (code, signal) => resolve({ code, signal }));
    timer = setTimeout(() => {
      timed = true;
      if (Number.isInteger(worker.pid) && worker.pid > 0) worker.kill('SIGKILL');
    }, 18000);
  });
  try {
    assert.ok(Number.isInteger(worker.pid) && worker.pid > 0, 'control worker failed to spawn');
    await waitUntil(() => fs.existsSync(path.join(directory, 'notice.json')));
    notice = JSON.parse(fs.readFileSync(path.join(directory, 'notice.json'), 'utf8'));
    const rows = await census(), root = rows.get(worker.pid), sentinel = rows.get(notice.sentinel);
    assert.equal(notice.worker, worker.pid);
    assert.ok(root && root.ppid === process.pid && root.pgid === root.pid, 'worker needs its own process group');
    owned.set(root.pid, { ...root, depth: 0 });
    assert.ok(sentinel && sentinel.ppid === root.pid && sentinel.pgid === root.pgid, 'sentinel must share only the worker group');
    owned.set(sentinel.pid, { ...sentinel, depth: 1 });
    fs.writeFileSync(path.join(directory, 'gate'), 'observed');
    const outcome = await completion;
    clearTimeout(timer);
    assert.equal(timed, false, 'control deadline expired');
    assert.equal(spawnError, undefined);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(directory, 'armed.json'), 'utf8')), { rootPidAbsent: true, rootErrors: 0, absentStdio: true }, 'both runners must reach the pre-next-tick failure gate');
    if (fs.existsSync(path.join(directory, 'done.json'))) done = JSON.parse(fs.readFileSync(path.join(directory, 'done.json'), 'utf8'));
    const snapshot = await census();
    const sentinelAlive = sameProcess(sentinel, snapshot.get(sentinel.pid)) && !snapshot.get(sentinel.pid).state.startsWith('Z');
    const witness = { ...outcome, stdout, stderr, sentinelAlive, done };
    if (mode === 'good') {
      failedSpawnEvidence(witness);
      process.stdout.write('full-lineup failed-spawn accepts retained failure without group signalling\n');
    } else {
      assert.equal(outcome.code, null); assert.equal(outcome.signal, 'SIGKILL', 'old worker must lose its group to SIGKILL');
      assert.equal(sentinelAlive, false, 'old same-group sentinel must be killed');
      assert.equal(done, undefined, 'old runner must not return a result');
      assert.equal(stderr, '');
      assert.throws(() => failedSpawnEvidence(witness), /worker did not exit normally/);
      process.stdout.write('full-lineup failed-spawn rejects unchanged e502 group SIGKILL\n');
      process.exitCode = 19;
    }
  } finally {
    clearTimeout(timer);
    // Exact census identities only, sentinel first; never kill a process group.
    for (const depth of [1, 0]) {
      const rows = await census();
      for (const p of living(owned, rows)) if (p.depth === depth) signalIdentity(p, rows, 'SIGKILL');
      await sleep(100);
    }
    await completion;
    await waitUntil(async () => living(owned, await census()).length === 0);
    // The bad worker dies before returning a result; its argv callback records
    // this invocation's exact directory before the failed spawn.
    const invocationFile = path.join(directory, 'invocation.json');
    if (fs.existsSync(invocationFile)) fs.rmSync(JSON.parse(fs.readFileSync(invocationFile, 'utf8')), { recursive: true, force: true });
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

function processEvidence(result) {
  assert.equal(result.timed, false, 'watchdog expired');
  assert.equal(result.signal, null, 'process was signalled');
  assert.equal(result.code, 0, result.out);
}

function goEvidence(result, pkg, names) {
  processEvidence(result);
  assert.ok(names.length && new Set(names).size === names.length, 'empty or duplicate requested tests');
  const events = result.out.split('\n').filter(line => line.trim()).map(line => JSON.parse(line));
  assert.ok(events.length, 'no Go events');
  assert.ok(events.every(event => event.Package === pkg), 'unexpected Go package');
  assert.ok(!events.some(event => ['fail', 'skip'].includes(event.Action)), 'failed or skipped Go result');
  assert.equal(events.filter(event => !event.Test && event.Action === 'pass').length, 1, 'package must pass once');
  const roots = events.filter(event => event.Test && !event.Test.includes('/') && event.Action === 'run').map(event => event.Test);
  assert.deepEqual([...roots].sort(), [...names].sort(), 'wrong top-level Go tests');
  for (const name of names) {
    assert.equal(events.filter(event => event.Test === name && event.Action === 'run').length, 1, `${name} must run once`);
    assert.equal(events.filter(event => event.Test === name && event.Action === 'pass').length, 1, `${name} must pass once`);
  }
}

function scenarioEvidence(result, report, names) {
  processEvidence(result);
  assert.ok(names.length && new Set(names).size === names.length, 'empty or duplicate requested scenarios');
  const features = JSON.parse(report);
  assert.ok(Array.isArray(features), 'not a Cucumber JSON report');
  const elements = features.flatMap(feature => feature.elements || []);
  const scenarios = elements.filter(element => element.type === 'scenario');
  assert.deepEqual(scenarios.map(scenario => scenario.name), names, 'scenarios must execute exactly once in declared order');
  for (const element of elements) {
    assert.ok(['scenario', 'background'].includes(element.type), 'unknown report element');
    assert.ok(element.steps && element.steps.length, `${element.name}: no executed steps`);
    for (const step of [...(element.before || []), ...element.steps, ...(element.after || [])]) {
      assert.equal(step.result && step.result.status, 'passed', `${element.name}: unpassed step or hook`);
    }
  }
  for (const feature of features) {
    for (const hook of [...(feature.before || []), ...(feature.after || [])]) {
      assert.equal(hook.result && hook.result.status, 'passed', 'unpassed feature hook');
    }
  }
}

function controls(mode) {
  const result = { code: 0, signal: null, timed: false, out: '' };
  const events = [
    { Action: 'run', Package: 'kogen/fixture', Test: 'TestBoundary' },
    { Action: 'pass', Package: 'kogen/fixture', Test: 'TestBoundary' },
    { Action: 'pass', Package: 'kogen/fixture' },
  ];
  const encode = values => values.map(value => JSON.stringify(value)).join('\n') + '\n';
  const scenario = { type: 'scenario', name: 'Boundary', steps: [{ result: { status: 'passed' } }], before: [{ result: { status: 'passed' } }], after: [{ result: { status: 'passed' } } ] };
  const report = elements => JSON.stringify([{ elements }]);
  goEvidence({ ...result, out: encode(events) }, 'kogen/fixture', ['TestBoundary']);
  scenarioEvidence(result, report([scenario]), ['Boundary']);
  if (mode === 'good') {
    process.stdout.write('full-lineup observers accept known-good evidence\n');
    return;
  }
  assert.equal(mode, 'bad');
  for (const bad of [[], events.slice(1), [events[0], events[2]], events.slice(0, 2), [...events, events[1]], [...events, events[0]], events.map(event => ({ ...event, Package: 'wrong' })), events.map(event => event.Test && event.Action === 'pass' ? { ...event, Action: 'skip' } : event)]) {
    assert.throws(() => goEvidence({ ...result, out: encode(bad) }, 'kogen/fixture', ['TestBoundary']));
  }
  for (const bad of [[], [scenario, scenario], [{ ...scenario, steps: [] }], [{ ...scenario, steps: [{ result: { status: 'skipped' } }] }], [{ ...scenario, before: [{ result: { status: 'failed' } }] }], [{ ...scenario, after: [{ result: { status: 'failed' } }] }]]) {
    assert.throws(() => scenarioEvidence(result, report(bad), ['Boundary']));
  }
  for (const bad of [{ ...result, code: 1 }, { ...result, timed: true }, { ...result, signal: 'SIGTERM' }]) {
    assert.throws(() => scenarioEvidence(bad, report([scenario]), ['Boundary']));
    assert.throws(() => goEvidence({ ...bad, out: encode(events) }, 'kogen/fixture', ['TestBoundary']));
  }
  assert.throws(() => scenarioEvidence(result, JSON.stringify([{ elements: [scenario], after: [{ result: { status: 'failed' } }] }]), ['Boundary']));
  assert.throws(() => scenarioEvidence(result, report([scenario, { ...scenario, name: 'Second' }]), ['Second', 'Boundary']));
  assert.throws(() => goEvidence({ ...result, out: 'compiler diagnostic\n' }, 'kogen/fixture', ['TestBoundary']));
  process.stdout.write('full-lineup observers reject known-bad evidence\n');
  process.exitCode = 19;
}

module.exports = { runOwned };
if (require.main === module) {
  const mode = process.argv[2];
  if (mode === 'lifecycle-fixture') lifecycleFixture(...process.argv.slice(3));
  else if (mode === 'lifecycle-good' || mode === 'lifecycle-bad') lifecycleControl(mode.slice(10)).catch(error => { console.error(error.stack); process.exitCode = 2; });
  else if (mode === 'liveness-good' || mode === 'liveness-bad') livenessControl(mode.slice(9)).catch(error => { console.error(error.stack); process.exitCode = 2; });
  else if (mode === 'liveness-worker') livenessWorker(process.argv[3]).catch(error => { console.error(error.stack); process.exitCode = 2; });
  else if (mode === 'failed-spawn-good' || mode === 'failed-spawn-bad') failedSpawnControl(mode.slice(13)).catch(error => { console.error(error.stack); process.exitCode = 2; });
  else if (mode === 'failed-spawn-worker') failedSpawnWorker(...process.argv.slice(3)).catch(error => { console.error(error.stack); process.exitCode = 2; });
  else controls(mode);
} else {
  let cucumber;
  try { cucumber = require('@cucumber/cucumber'); } catch (error) {
    if (error.code !== 'MODULE_NOT_FOUND' || !error.message.includes("'@cucumber/cucumber'")) throw error;
  }
  if (cucumber && cucumber.supportCodeLibraryBuilder.status !== 'PENDING') registerSteps(cucumber);
}

function registerSteps({ When, Then }) {
  When('I execute the Claude lineup Go contracts:', { timeout: GO_STEP_TIMEOUT }, async function (table) {
    this.lineupGo = [];
    const groups = new Map();
    for (const row of table.hashes()) {
      assert.match(row.package, /^\.\/[a-z]+(?:\/[a-z]+)*$/);
      assert.match(row.test, /^Test[A-Za-z0-9_]+$/);
      if (!groups.has(row.package)) groups.set(row.package, []);
      groups.get(row.package).push(row.test);
    }
    assert.ok(groups.size <= 3, 'Go step budget covers at most three package groups');
    for (const [pkg, names] of groups) {
      const result = await runOwned('go', ['test', '-count=1', '-json', '-run', `^(${names.join('|')})$`, pkg], {
        cwd: path.join(ROOT, 'cli'), timeout: GO_WATCHDOG,
        env: { ...process.env, GOWORK: 'off', GOPROXY: 'off', GOTOOLCHAIN: 'local' },
      });
      this.lineupGo.push({ result, pkg: `kogen/${pkg.slice(2)}`, names });
    }
  });
  Then('every named Claude lineup Go contract runs and passes once', { timeout: 60000 }, function () {
    assert.ok(this.lineupGo && this.lineupGo.length, 'no requested Go contracts');
    for (const group of this.lineupGo) validateOwned(group.result, () => goEvidence(group.result, group.pkg, group.names));
    removePassing(this.lineupGo.map(group => group.result));
  });

  When('I execute the installed Claude lineup specification {string}', { timeout: INSTALLED_STEP_TIMEOUT }, async function (file) {
    const result = await runOwned(process.execPath, r => ['node_modules/@cucumber/cucumber/bin/cucumber.js', '--strict', '--tags', 'not @live', '--require', 'steps/*.js', '--require', 'support/*.js', '--format', `json:${r.reportPath}`, path.resolve(ROOT, file)], {
      cwd: path.join(ROOT, 'test/acceptance'), timeout: INSTALLED_WATCHDOG,
    });
    this.lineupInstalled = { result };
  });
  Then('exactly these installed Claude lineup scenarios execute with every step passing:', { timeout: 60000 }, function (table) {
    assert.ok(this.lineupInstalled, 'no installed specification result');
    const { result } = this.lineupInstalled;
    validateOwned(result, () => scenarioEvidence(result, fs.readFileSync(result.reportPath, 'utf8'), table.raw().map(row => row[0])));
    removePassing([result]);
  });
}
