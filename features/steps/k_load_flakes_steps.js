'use strict';
// K-LOAD-FLAKES: TestPreflightStopsOwnedChildren waits on the preflight's own observable start, not a
// fixed wall-clock bound. The test itself delays or prevents that start: the driver, mounted with
// go -overlay, sets the test's preflightFakeStart from KOGEN_K_LOAD_FLAKES_START. No extra host load.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const TEST = 'TestPreflightStopsOwnedChildren';
const SUBTESTS = ['early_exit', 'cancelled'];
const PKG = './executor/claudecode';

function command(start) {
  const env = start === undefined ? '' : `KOGEN_K_LOAD_FLAKES_START=${JSON.stringify(start)} `;
  return `${env}go test -json -trimpath -count=1 -timeout 60s -overlay <driver> -run '^${TEST}$' ${PKG}`;
}

// summary reduces go test -json events to the outcome of TEST and of each of its subtests.
function summary(events) {
  const tests = {};
  const output = {};
  for (const e of events) {
    if (!e.Test) continue;
    if (e.Action === 'output') output[e.Test] = (output[e.Test] || '') + e.Output;
    if (['pass', 'fail', 'skip'].includes(e.Action)) tests[e.Test] = { action: e.Action, elapsed: e.Elapsed };
  }
  return { tests, output };
}

function describe(result) {
  return `${result.command}\nexit ${result.code}\n${result.text.slice(-6000)}`;
}

function checkRan(result, action) {
  const { tests } = summary(result.events);
  const names = Object.keys(tests).sort();
  const want = [TEST, ...SUBTESTS.map(s => `${TEST}/${s}`)].sort();
  for (const name of want) {
    const got = tests[name];
    assert.ok(got, `${name} did not run (absent from the go test -json events, or ran zero times): ${describe(result)}`);
    assert.notEqual(got.action, 'skip', `${name} was skipped: ${describe(result)}`);
    assert.equal(got.action, action, `${name} was expected to ${action} but did ${got.action}: ${describe(result)}`);
  }
  assert.deepEqual(names, want, `${TEST} ran other tests or subtests than ${want.join(', ')}: ${describe(result)}`);
  assert.ok(!/panic: test timed out/.test(result.text), `${TEST} hit the 60 s go test timeout instead of ending on its own: ${describe(result)}`);
  return tests;
}

function observePass(result, minSeconds) {
  assert.equal(result.code, 0, `${TEST} did not pass (go test exit ${result.code}): ${describe(result)}`);
  const tests = checkRan(result, 'pass');
  if (minSeconds !== undefined) {
    for (const s of SUBTESTS) {
      const name = `${TEST}/${s}`;
      assert.ok(tests[name].elapsed > minSeconds, `${name} passed in ${tests[name].elapsed} s, not after a start slower than ${minSeconds} s, so the delay never applied: ${describe(result)}`);
    }
  }
}

function observeNoStart(result, message) {
  assert.notEqual(result.code, 0, `${TEST} passed although its preflight never started (go test exit 0): ${describe(result)}`);
  checkRan(result, 'fail');
  const { output } = summary(result.events);
  for (const s of SUBTESTS) {
    const name = `${TEST}/${s}`;
    assert.ok((output[name] || '').includes(message), `${name} failed without "${message}": ${describe(result)}`);
  }
}

async function run(start) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-k-load-flakes-'));
  const overlay = path.join(dir, 'overlay.json');
  fs.writeFileSync(overlay, JSON.stringify({ Replace: {
    [path.join(ROOT, 'cli/executor/claudecode/k_load_flakes_acceptance_test.go')]: path.join(__dirname, 'k_load_flakes_driver.go'),
  } }));
  const env = { ...process.env, GOWORK: 'off', GOPROXY: 'off', GOTOOLCHAIN: 'local' };
  delete env.KOGEN_K_LOAD_FLAKES_START;
  if (start !== undefined) env.KOGEN_K_LOAD_FLAKES_START = start;
  let child;
  try {
    return await new Promise((resolve, reject) => {
      child = spawn('go', ['test', '-json', '-trimpath', '-count=1', '-timeout', '60s', '-overlay', overlay, '-run', `^${TEST}$`, PKG],
        { cwd: path.join(ROOT, 'cli'), env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
      let text = '';
      const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 100000);
      child.stdout.on('data', b => { text += b; });
      child.stderr.on('data', b => { text += b; });
      child.on('error', e => { clearTimeout(timer); reject(e); });
      child.on('close', code => {
        clearTimeout(timer);
        const events = text.split('\n').flatMap(line => { try { return [JSON.parse(line)]; } catch { return []; } });
        const shown = events.length ? events.filter(e => e.Action === 'output' || e.Action === 'build-output').map(e => e.Output).join('') + text.split('\n').filter(l => !l.startsWith('{')).join('\n') : text;
        resolve({ command: command(start), code, events, text: shown });
      });
    });
  } finally {
    if (child?.pid) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// Known-good and known-bad go test -json results for the observers above (Feasibility controls).
function control(kind) {
  const ev = (Test, Action, extra = {}) => ({ Action, Package: 'kogen/executor/claudecode', Test, ...extra });
  const result = (code, specs, text = '') => ({ command: 'control', code, text, events: specs });
  const passing = elapsed => result(0, [
    ev(TEST, 'run'), ev(`${TEST}/early_exit`, 'run'), ev(`${TEST}/early_exit`, 'pass', { Elapsed: elapsed }),
    ev(`${TEST}/cancelled`, 'run'), ev(`${TEST}/cancelled`, 'pass', { Elapsed: elapsed }), ev(TEST, 'pass', { Elapsed: 2 * elapsed }),
  ]);
  const msg = '    preflight_process_test.go:45: preflight did not start\n';
  const failing = (outs, extraText = '') => result(1, [
    ev(TEST, 'run'), ev(`${TEST}/early_exit`, 'run'), ev(`${TEST}/early_exit`, 'output', { Output: outs[0] }), ev(`${TEST}/early_exit`, 'fail', { Elapsed: 0.1 }),
    ev(`${TEST}/cancelled`, 'run'), ev(`${TEST}/cancelled`, 'output', { Output: outs[1] }), ev(`${TEST}/cancelled`, 'fail', { Elapsed: 0.1 }), ev(TEST, 'fail', { Elapsed: 0.2 }),
  ], extraText);
  observePass(passing(0.6));
  observePass(passing(6.02), 5);
  observeNoStart(failing([msg, msg]), 'preflight did not start');
  const bad = [
    () => observePass(passing(5.0), 5),
    () => observePass(passing(4.9), 5),
    () => observePass({ ...passing(6.02), code: 1 }, 5),
    () => { const r = passing(0.6); r.events = r.events.filter(e => e.Test !== `${TEST}/cancelled`); observePass(r); },
    () => { const r = passing(0.6); r.events = r.events.map(e => e.Test === `${TEST}/early_exit` && e.Action === 'pass' ? { ...e, Action: 'skip' } : e); observePass(r); },
    () => { const r = passing(0.6); r.events.push(ev('TestOther', 'pass', { Elapsed: 0 })); observePass(r); },
    () => observePass(result(1, [], '# kogen/executor/claudecode\nundefined: preflightFakeStart\n')),
    () => observeNoStart({ ...failing([msg, msg]), code: 0 }, 'preflight did not start'),
    () => observeNoStart(failing([msg, '    other failure\n']), 'preflight did not start'),
    () => observeNoStart(failing([msg, msg], 'panic: test timed out after 1m0s\n'), 'preflight did not start'),
    () => observeNoStart(passing(0.6), 'preflight did not start'),
  ];
  let rejected = 0;
  for (const attempt of bad) { try { attempt(); } catch { rejected++; } }
  if (kind === 'good') {
    assert.equal(rejected, bad.length, `only ${rejected} of ${bad.length} known-bad results were rejected`);
    console.log('k-load-flakes observer accepted good');
    return;
  }
  assert.equal(kind, 'bad');
  console.log(rejected === bad.length ? 'k-load-flakes observer rejected bad' : 'k-load-flakes observer accepted a bad result');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') control(process.argv[3]);
else {
  const { When, Then } = require('@cucumber/cucumber');
  When('TestPreflightStopsOwnedChildren runs with the fake claude first running {string}', { timeout: 105000 }, async function (start) {
    this.kLoadFlakes = await run(start);
  });
  When('TestPreflightStopsOwnedChildren runs with its fake claude unchanged', { timeout: 105000 }, async function () {
    this.kLoadFlakes = await run(undefined);
  });
  Then('TestPreflightStopsOwnedChildren passes with early_exit and cancelled', function () {
    observePass(this.kLoadFlakes);
  });
  Then('TestPreflightStopsOwnedChildren passes with early_exit and cancelled each taking more than {float} seconds', function (seconds) {
    observePass(this.kLoadFlakes, seconds);
  });
  Then('TestPreflightStopsOwnedChildren fails with {string} in early_exit and in cancelled', function (message) {
    observeNoStart(this.kLoadFlakes, message);
  });
}
