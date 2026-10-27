'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const cache = new Map();

function put(file, bytes) {
  fs.writeFileSync(file, bytes, { mode: 0o600 });
  fs.chmodSync(file, 0o600);
}
// Runs the observation driver, mounted as a test with go -overlay, once per mode.
function observe(mode) {
  if (cache.has(mode)) return cache.get(mode);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-k19-'));
  fs.chmodSync(dir, 0o700);
  try {
    const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    put(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/build/k19_no_progress_acceptance_test.go')]: path.join(__dirname, 'k19_no_progress_driver.go') } }));
    const r = spawnSync('go', ['test', '-overlay', overlay, './build', '-run', '^TestK19Observation$', '-count=1'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 280000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_K19_MODE: mode, KOGEN_K19_OUTPUT: output, GOWORK: 'off', GOPROXY: 'off', GOTOOLCHAIN: 'local' },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `observation failed:\n${r.stdout}\n${r.stderr}`);
    // Go success alone is not proof: the driver must have written its observation.
    const data = JSON.parse(fs.readFileSync(output, 'utf8'));
    assert.equal(data.mode, mode);
    cache.set(mode, data);
    return data;
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

function roundLimitStop(d, rounds) {
  assert.equal(d.exit, 1);
  assert.ok(d.stdout.includes('candidate/executor_round_limit'), d.stdout);
  assert.equal(d.outcome, 'executor_round_limit');
  assert.equal(d.rounds, rounds, `the builder ran ${d.rounds} rounds`);
  assert.equal(d.head_same, true, 'nothing was committed');
}
function oneNoProgress(d, rounds, failing) {
  assert.ok(Array.isArray(d.no_progress) && d.no_progress.length === 1, 'exactly one executor_no_progress event');
  const e = d.no_progress[0];
  assert.equal(e.event, 'executor_no_progress');
  assert.equal(e.rounds, rounds);
  assert.ok(typeof e.fingerprint === 'string' && e.fingerprint !== '', 'a fingerprint is recorded');
  assert.deepEqual(e.failing, failing);
  assert.equal(d.no_progress_before_outcome, true, 'the event precedes the outcome');
}
function checkIdentical(d) {
  roundLimitStop(d, 3);
  assert.equal(d.reviews, 0);
  oneNoProgress(d, 3, ['stuck']);
  assert.ok(!d.stdout.includes('8 rounds'), 'it stopped before the round cap');
}
function checkChanging(d) {
  roundLimitStop(d, 5);
  assert.ok(d.stdout.includes('5 rounds'), 'it ran to the round cap');
  assert.equal(d.no_progress.length, 0, 'no executor_no_progress event');
  assert.equal(d.reviews, 0);
}
function checkReset(d) {
  roundLimitStop(d, 5);
  assert.equal(d.reviews, 1, 'the green pass was reviewed once');
  oneNoProgress(d, 5, ['acceptance']);
  assert.ok(!d.stdout.includes('8 rounds'), 'it stopped before the round cap');
}

function controls(kind) {
  const stdout = 'kogen: candidate/executor_round_limit\n';
  const np = (rounds, failing) => ({ event: 'executor_no_progress', rounds, fingerprint: 'abc', failing });
  const identical = { mode: 'identical', exit: 1, stdout, outcome: 'executor_round_limit', rounds: 3, reviews: 0, head_same: true, no_progress: [np(3, ['stuck'])], no_progress_before_outcome: true };
  const changing = { mode: 'changing', exit: 1, stdout: 'kogen: candidate/executor_round_limit: the executor used its 5 rounds\n', outcome: 'executor_round_limit', rounds: 5, reviews: 0, head_same: true, no_progress: [], no_progress_before_outcome: false };
  const reset = { mode: 'green-reset', exit: 1, stdout, outcome: 'executor_round_limit', rounds: 5, reviews: 1, head_same: true, no_progress: [np(5, ['acceptance'])], no_progress_before_outcome: true };
  checkIdentical(identical); checkChanging(changing); checkReset(reset);
  if (kind === 'good') { console.log('k19 observer good'); return; }
  assert.equal(kind, 'bad');
  const bad = (fn, d, mutate) => { const c = structuredClone(d); mutate(c); assert.throws(() => fn(c), 'accepted a known-bad fixture'); };
  bad(checkIdentical, identical, d => { d.rounds = 8; });
  bad(checkIdentical, identical, d => { d.rounds = 4; });
  bad(checkIdentical, identical, d => { d.no_progress = []; });
  bad(checkIdentical, identical, d => { d.no_progress.push(np(3, ['stuck'])); });
  bad(checkIdentical, identical, d => { d.no_progress[0].rounds = 2; });
  bad(checkIdentical, identical, d => { d.no_progress[0].fingerprint = ''; });
  bad(checkIdentical, identical, d => { d.no_progress[0].failing = []; });
  bad(checkIdentical, identical, d => { d.no_progress_before_outcome = false; });
  bad(checkIdentical, identical, d => { d.stdout = 'kogen: executor/protocol\n'; });
  bad(checkIdentical, identical, d => { d.outcome = 'no_progress'; });
  bad(checkIdentical, identical, d => { d.head_same = false; });
  bad(checkIdentical, identical, d => { d.reviews = 1; });
  bad(checkChanging, changing, d => { d.rounds = 3; });
  bad(checkChanging, changing, d => { d.no_progress = [np(3, ['moving'])]; });
  bad(checkChanging, changing, d => { d.stdout = 'kogen: candidate/executor_round_limit\n'; });
  bad(checkChanging, changing, d => { d.outcome = 'commit'; });
  bad(checkReset, reset, d => { d.rounds = 3; });
  bad(checkReset, reset, d => { d.reviews = 0; });
  bad(checkReset, reset, d => { d.no_progress = []; });
  bad(checkReset, reset, d => { d.no_progress[0].rounds = 3; });
  bad(checkReset, reset, d => { d.no_progress[0].failing = ['stuck']; });
  bad(checkReset, reset, d => { d.rounds = 8; });
  console.log('k19 observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  const STEP = { timeout: 300000 };
  When('the k19 fake external builder finishes without edits against the same red check in the case {string}', STEP, function (mode) { this.k19 = observe(mode); });
  When('the k19 fake external builder meets a green pass between identical red passes in the case {string}', STEP, function (mode) { this.k19 = observe(mode); });
  Then('the k19 Build recorded one executor_no_progress event and stopped with candidate executor_round_limit after the third identical pass, before the round cap', function () { checkIdentical(this.k19); });
  Then('the k19 Build was not stopped early and ran to its round cap without an executor_no_progress event', function () { checkChanging(this.k19); });
  Then('the k19 Build counted again from one after the green pass and stopped on the third identical red pass after it', function () { checkReset(this.k19); });
}
