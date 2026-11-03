'use strict';
// K-ACCEPT-WAIT-HANDLERS: the wait for a fake ChatGPT server request ends on that request or on the kogen
// process ending, never on a wall-clock guess.
// The observation runs once per Cucumber process, in a child Node process (`--observe`) that loads the real step
// dispatch of test/acceptance/support/handlers.js (with the acceptance suite's own Cucumber, from
// test/acceptance/node_modules) and drives the step "the fake ChatGPT server has sent the feedback of verification
// pass N" against minimal worlds: world.server.requests, the array the fake server records requests into, and
// world.currentProcess, a real child process recorded with child, code, signal and done as world.invoke records it.
// Every child process is killed afterwards, whatever the result.
// `node k_accept_wait_handlers_steps.js --control good|bad` checks the judging functions below against
// known-good and known-bad observations without running anything.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const STEP = '^the fake ChatGPT server has sent the feedback of verification pass (\\d+)$';
const OLD_WAIT_MS = 30000; // the fixed wait the unfixed handler gives passes 1 to 6
const LATE_MS = OLD_WAIT_MS + 1000; // when the late request arrives
const EXIT_MS = 500; // when the process of the "ended" case exits on its own
const GUARD_MS = 90000; // harness guard so that a wait that never ends is reported, not a product timeout
const CASES = { late: 1, prompt: 4, race: 5, ended: 7, none: 2 };
const passText = n => `Verification pass ${n} is not green.`;
const alive = pid => { try { process.kill(pid, 0); return true; } catch (e) { return e.code !== 'ESRCH'; } };

// ------------------------------------------------------------------ observation (child process)

function startProcess(exitAfterMs, exitCode) {
  const script = exitAfterMs === null ? 'setInterval(() => {}, 1000)' : `setTimeout(() => process.exit(${exitCode}), ${exitAfterMs})`;
  const child = spawn(process.execPath, ['-e', script], { detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  const record = { child, stdout: '', stderr: '', done: null, code: null, signal: null, raw: 'kogen intent build is-even', isKogen: true };
  record.done = new Promise(resolve => {
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', chunk => { record.stdout += chunk; });
    child.stderr.on('data', chunk => { record.stderr += chunk; });
    child.on('close', (code, sig) => { record.code = code === null ? 128 : code; record.signal = sig; resolve(record); });
  });
  return record;
}
function stopProcess(record) {
  if (record && record.child.pid && record.child.exitCode === null && record.child.signalCode === null) {
    try { process.kill(-record.child.pid, 'SIGKILL'); } catch {}
  }
}
const request = (order, text) => ({ order, kind: 'build', body: {}, tools: [], text, receivedAt: Date.now() });

async function runStep(dispatch, world, n) {
  const start = Date.now();
  let guard;
  const outcome = await Promise.race([
    Promise.resolve()
      .then(() => dispatch(world, STEP, [String(n)]))
      .then(() => ({ settled: 'resolved', message: '' }), error => ({ settled: 'rejected', message: String((error && error.message) || error) })),
    new Promise(resolve => { guard = setTimeout(() => resolve({ settled: 'hung', message: '' }), GUARD_MS); }),
  ]);
  clearTimeout(guard);
  return { pass: n, ...outcome, elapsed_ms: Date.now() - start };
}

async function observeCases(dispatch) {
  const records = [];
  const timers = [];
  const track = record => { records.push(record); return record; };
  const at = (ms, fn) => timers.push(setTimeout(fn, ms));
  try {
    const late = async () => {
      // The reported failure: the request arrives later than the old fixed wait while kogen still runs.
      const record = track(startProcess(null));
      const world = { server: { requests: [request(1, 'Implement the Intent.')] }, currentProcess: record };
      at(LATE_MS, () => world.server.requests.push(request(2, passText(CASES.late))));
      const o = await runStep(dispatch, world, CASES.late);
      return { ...o, alive_after: alive(record.child.pid) && record.code === null };
    };
    const prompt = async () => {
      const record = track(startProcess(null));
      const world = { server: { requests: [request(1, passText(CASES.prompt))] }, currentProcess: record };
      return runStep(dispatch, world, CASES.prompt);
    };
    const race = async () => {
      // The request is recorded and the process ends in the same turn: the request was received, so it is found.
      const record = track(startProcess(null));
      const world = { server: { requests: [] }, currentProcess: record };
      at(300, () => { world.server.requests.push(request(1, passText(CASES.race))); stopProcess(record); });
      return runStep(dispatch, world, CASES.race);
    };
    const ended = async () => {
      // The process ends on its own (exit 3) without the awaited request; an earlier pass's request does not count.
      const record = track(startProcess(EXIT_MS, 3));
      const world = { server: { requests: [request(1, passText(CASES.ended - 1))] }, currentProcess: record };
      const o = await runStep(dispatch, world, CASES.ended);
      return { ...o, exit_code: record.code };
    };
    const none = async () => {
      const world = { server: { requests: [] }, currentProcess: null };
      return runStep(dispatch, world, CASES.none);
    };
    const [a, b, c, d, e] = await Promise.all([late(), prompt(), race(), ended(), none()]);
    return { late: a, prompt: b, race: c, ended: d, none: e };
  } finally {
    for (const timer of timers) clearTimeout(timer);
    for (const record of records) stopProcess(record);
  }
}

async function observeMain() {
  const { createRequire } = require('node:module');
  const acceptanceRequire = createRequire(path.join(ROOT, 'test/acceptance/package.json'));
  // handlers.js loads the suite's world.js, which registers its World with the suite's own Cucumber.
  acceptanceRequire('@cucumber/cucumber/lib/support_code_library_builder/index').default.reset(ROOT, () => 'k-accept-wait-handlers');
  const { dispatch } = acceptanceRequire('./support/handlers');
  const observation = await observeCases(dispatch);
  process.stdout.write(`${JSON.stringify(observation)}\n`);
  process.exit(0);
}

let observing = null;
function observe() {
  if (!observing) {
    observing = new Promise(resolve => {
      const child = spawn(process.execPath, [__filename, '--observe'], { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'] });
      let out = '';
      child.stdout.setEncoding('utf8');
      child.stderr.setEncoding('utf8');
      child.stdout.on('data', chunk => { out += chunk; });
      child.stderr.on('data', chunk => { out += chunk; });
      child.on('close', code => {
        const line = out.split('\n').reverse().find(l => l.startsWith('{"late":'));
        resolve(line ? JSON.parse(line) : { error: `node ${path.relative(ROOT, __filename)} --observe exited ${code} without an observation:\n${out}` });
      });
    });
  }
  return observing;
}

// ------------------------------------------------------------------ judging (pure: the controls call these)

const describe = o => JSON.stringify(o);
function checkObservation(obs) {
  assert.ok(obs && !obs.error, (obs && obs.error) || 'no observation was made');
}
function checkLate(obs, n, seconds) {
  checkObservation(obs);
  const o = obs.late;
  assert.equal(o.pass, n, `the late case awaited pass ${o.pass}, not ${n}`);
  assert.equal(LATE_MS, seconds * 1000, `the late request arrives after ${LATE_MS} ms, not ${seconds} s`);
  assert.equal(o.settled, 'resolved', `the wait for "${passText(n)}" did not end on that request, which arrived ${LATE_MS} ms later while the kogen process ran: ${describe(o)}`);
  assert.ok(o.elapsed_ms >= OLD_WAIT_MS, `the wait for "${passText(n)}" ended after ${o.elapsed_ms} ms, before its request arrived: ${describe(o)}`);
  assert.ok(o.elapsed_ms < LATE_MS + 10000, `the wait for "${passText(n)}" ended ${o.elapsed_ms} ms after it started, long after its request arrived: ${describe(o)}`);
  assert.equal(o.alive_after, true, `the kogen process was not still running after the wait for "${passText(n)}" ended: ${describe(o)}`);
}
function checkPrompt(obs) {
  checkObservation(obs);
  const o = obs.prompt;
  assert.equal(o.settled, 'resolved', `the wait for "${passText(o.pass)}", already recorded, did not end on it: ${describe(o)}`);
  assert.ok(o.elapsed_ms < 5000, `the wait for "${passText(o.pass)}", already recorded, took ${o.elapsed_ms} ms: ${describe(o)}`);
}
function checkRace(obs) {
  checkObservation(obs);
  const o = obs.race;
  assert.equal(o.settled, 'resolved', `the wait for "${passText(o.pass)}", recorded just before the kogen process ended, did not end on it: ${describe(o)}`);
}
function checkEnded(obs, n, text) {
  checkObservation(obs);
  const o = obs.ended;
  assert.equal(o.pass, n, `the ended case awaited pass ${o.pass}, not ${n}`);
  assert.equal(o.exit_code, 3, `the process of the ended case exited ${o.exit_code}, not 3: ${describe(o)}`);
  assert.equal(o.settled, 'rejected', `the wait for "${passText(n)}" did not fail after the kogen process ended without that request: ${describe(o)}`);
  assert.ok(o.message.includes(text), `the failure of the wait does not name the missing request ${JSON.stringify(text)}: ${describe(o)}`);
  assert.ok(o.elapsed_ms >= EXIT_MS - 100, `the wait for "${passText(n)}" failed after ${o.elapsed_ms} ms, before the kogen process ended: ${describe(o)}`);
  assert.ok(o.elapsed_ms < 10000, `the wait for "${passText(n)}" failed ${o.elapsed_ms} ms after it started, not when the kogen process ended (${EXIT_MS} ms): ${describe(o)}`);
}
function checkNone(obs, n, text) {
  checkObservation(obs);
  const o = obs.none;
  assert.equal(o.pass, n, `the no-process case awaited pass ${o.pass}, not ${n}`);
  assert.equal(o.settled, 'rejected', `the wait for "${passText(n)}" with no kogen process running did not fail: ${describe(o)}`);
  assert.ok(o.message.includes(text), `the failure of the wait does not name the missing request ${JSON.stringify(text)}: ${describe(o)}`);
  assert.ok(o.elapsed_ms < 10000, `the wait for "${passText(n)}" with no kogen process running failed only after ${o.elapsed_ms} ms: ${describe(o)}`);
}
function scenarioSteps(source, name) {
  const lines = source.split('\n');
  const start = lines.findIndex(line => line.trim() === `Scenario: ${name}`);
  assert.ok(start >= 0, `spec/features/04-building.feature has no scenario "${name}"`);
  const steps = [];
  for (const line of lines.slice(start + 1)) {
    const trimmed = line.trim();
    if (trimmed === '' || trimmed.startsWith('@') || /^(Scenario|Scenario Outline|Rule|Examples):/.test(trimmed)) break;
    steps.push(trimmed);
  }
  return steps;
}
function checkScenario(source, name, expected) {
  const want = expected.split('\n').map(line => line.trim()).filter(Boolean);
  assert.deepEqual(scenarioSteps(source, name), want, `the steps of scenario "${name}" changed`);
}

// ------------------------------------------------------------------ observer controls

function controls(kind) {
  const good = {
    late: { pass: 1, settled: 'resolved', message: '', elapsed_ms: 31012, alive_after: true },
    prompt: { pass: 4, settled: 'resolved', message: '', elapsed_ms: 3 },
    race: { pass: 5, settled: 'resolved', message: '', elapsed_ms: 310 },
    ended: { pass: 7, settled: 'rejected', message: 'the fake ChatGPT server did not receive the request "Verification pass 7 is not green." before the kogen command ended (exit code 3)', elapsed_ms: 560, exit_code: 3 },
    none: { pass: 2, settled: 'rejected', message: 'the fake ChatGPT server did not receive the request "Verification pass 2 is not green." and no kogen command is running', elapsed_ms: 1 },
  };
  const name = 'Ordinary implementation failures keep repairing until the caller stops it';
  const expected = 'Given the Intent "is-even" from fixture "is-even" is approved\nAnd the fake ChatGPT server plays script "build-wrong-forever"';
  const scenario = `  @LOOP-7\n  Scenario: ${name}\n    Given the Intent "is-even" from fixture "is-even" is approved\n    And the fake ChatGPT server plays script "build-wrong-forever"\n\n  Scenario: next\n`;
  const all = (obs, source) => {
    checkLate(obs, 1, 31); checkPrompt(obs); checkRace(obs);
    checkEnded(obs, 7, passText(7)); checkNone(obs, 2, passText(2));
    checkScenario(source, name, expected);
  };
  all(good, scenario);
  if (kind === 'good') { console.log('k-accept-wait-handlers observer accepted good observations'); return; }
  assert.equal(kind, 'bad');
  const bad = (what, mutate, source = scenario) => {
    const obs = structuredClone(good);
    mutate(obs);
    assert.throws(() => all(obs, source), assert.AssertionError, `accepted a known-bad observation: ${what}`);
  };
  // The reported failure: the old fixed wait gave up before the late request arrived.
  bad('late request: fixed wait failed', o => { o.late = { pass: 1, settled: 'rejected', message: 'the fake ChatGPT server did not receive the expected request', elapsed_ms: 30001, alive_after: true }; });
  bad('late request: resolved before it arrived', o => { o.late.elapsed_ms = 20; });
  bad('late request: wait never ended', o => { o.late = { pass: 1, settled: 'hung', message: '', elapsed_ms: 90000, alive_after: true }; });
  bad('late request: resolved long after it arrived', o => { o.late.elapsed_ms = 45000; });
  bad('late request: kogen process stopped', o => { o.late.alive_after = false; });
  bad('late request: wrong pass', o => { o.late.pass = 2; });
  bad('recorded request not found', o => { o.prompt.settled = 'rejected'; });
  bad('recorded request found slowly', o => { o.prompt.elapsed_ms = 30000; });
  bad('request recorded before the end lost', o => { o.race = { pass: 5, settled: 'rejected', message: passText(5), elapsed_ms: 320 }; });
  // The ended process: the old fixed wait, a message without the request, failing before the end, or no failure.
  bad('ended: old fixed wait', o => { o.ended = { pass: 7, settled: 'rejected', message: 'the fake ChatGPT server did not receive the expected request', elapsed_ms: 30001, exit_code: 3 }; });
  bad('ended: message does not name the request', o => { o.ended.message = 'the kogen command ended'; });
  bad('ended: failed before the process ended', o => { o.ended.elapsed_ms = 5; });
  bad('ended: resolved', o => { o.ended.settled = 'resolved'; o.ended.message = ''; });
  bad('ended: never ended', o => { o.ended.settled = 'hung'; o.ended.elapsed_ms = 90000; });
  bad('ended: process did not exit 3', o => { o.ended.exit_code = 0; });
  bad('none: old fixed wait', o => { o.none = { pass: 2, settled: 'rejected', message: 'the fake ChatGPT server did not receive the expected request', elapsed_ms: 30001 }; });
  bad('none: message does not name the request', o => { o.none.message = 'no kogen command is running'; });
  bad('none: resolved', o => { o.none.settled = 'resolved'; });
  bad('scenario step changed', () => {}, scenario.replace('build-wrong-forever', 'build-wrong-once'));
  assert.throws(() => all({ error: 'node --observe exited 1' }, scenario), assert.AssertionError, 'accepted a missing observation');
  bad('scenario step removed', () => {}, scenario.replace('    And the fake ChatGPT server plays script "build-wrong-forever"\n', ''));
  bad('scenario missing', () => {}, scenario.replace(name, 'Another scenario'));
  console.log('k-accept-wait-handlers observer rejected bad observations');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else if (require.main === module && process.argv[2] === '--observe') {
  observeMain().catch(error => { console.error(error); process.exit(1); });
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('the fake-server wait is observed through the acceptance step handler', { timeout: 115000 }, async function () {
    this.kawh = await observe();
  });
  Then('the wait for verification pass {int} ends on its request that arrives {int} seconds later while the kogen process runs', function (n, seconds) {
    checkLate(this.kawh, n, seconds);
  });
  Then('a request already recorded ends the wait at once', function () { checkPrompt(this.kawh); });
  Then('a request recorded just before the kogen process ends is found', function () { checkRace(this.kawh); });
  Then('the wait for verification pass {int} fails soon after the kogen process ends, naming {string}', function (n, text) {
    checkEnded(this.kawh, n, text);
  });
  Then('with no kogen process running the wait for verification pass {int} fails at once, naming {string}', function (n, text) {
    checkNone(this.kawh, n, text);
  });
  Then('spec\\/features\\/04-building.feature still has the scenario {string} with exactly these steps:', function (name, expected) {
    checkScenario(fs.readFileSync(path.join(ROOT, 'spec/features/04-building.feature'), 'utf8'), name, expected);
  });
}
