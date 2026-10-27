'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const STEPS_FILE = 'features/steps/integration_steps.js';
const INVALID = 'invalid blocker: supply exactly nonempty unique current protected paths, reason and observed evidence strings; no write permission is granted; continue ordinary implementation repairs';
const NATIVE = [
  'If observed evidence demonstrates that current protected files contradict the approved behavior or contain a fixture defect',
  'their exact protected paths, a concrete reason and observed command/step/error evidence',
  'Do not change production semantics solely to accommodate a demonstrated bad fixture.',
  'A valid report stops as BUILDER-REPORTED build_blocked with candidate/index/approval preserved; it is not independently proven and grants no protected edits, automatic refinement or approval. Plain blocked text does not stop the Build.',
];
const cache = new Map();

function put(file, bytes) {
  fs.writeFileSync(file, bytes, { mode: 0o600 });
  fs.chmodSync(file, 0o600);
}
// Runs the observation driver, mounted as a test with go -overlay, once per mode.
function observe(mode) {
  if (cache.has(mode)) return cache.get(mode);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-k16-'));
  fs.chmodSync(dir, 0o700);
  try {
    const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    put(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/build/k16_blocker_acceptance_test.go')]: path.join(__dirname, 'k16_cc_builder_blocker_driver.go') } }));
    const r = spawnSync('go', ['test', '-overlay', overlay, './build', '-run', '^TestK16Observation$', '-count=1'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 280000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_K16_MODE: mode, KOGEN_K16_OUTPUT: output, GOWORK: 'off', GOPROXY: 'off', GOTOOLCHAIN: 'local' },
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

function preserved(d) {
  assert.equal(d.app_before_recover, 'red\n', 'the candidate stays as the builder left it');
  assert.equal(d.index_same, true, 'the Git index is unchanged');
  assert.equal(d.approval_same, true, 'the approval is unchanged');
}
function checkBlocked(d) {
  assert.equal(d.exit, 1);
  assert.ok(d.stdout.includes('candidate/build_blocked'), d.stdout);
  assert.equal(d.outcome, 'build_blocked');
  assert.equal(d.calls, '1');
  const b = d.blocker;
  assert.ok(b && typeof b === 'object', 'a blocker is recorded');
  assert.deepEqual(Object.keys(b).sort(), ['classification', 'evidence', 'paths', 'reason']);
  assert.equal(b.classification, 'BUILDER-REPORTED');
  assert.deepEqual(b.paths, [STEPS_FILE]);
  assert.ok(typeof b.reason === 'string' && b.reason.trim() !== '');
  assert.ok(typeof b.evidence === 'string' && b.evidence.trim() !== '');
  assert.equal(d.head_same, true);
  preserved(d);
}
function checkRecovered(d) {
  assert.equal(d.recover_exit, 0, d.recover_shown);
  assert.equal(d.recover_state, 'cleaned');
  assert.equal(d.app_after_recover, 'baseline\n', 'recovery restores only the implementation delta');
}
function checkRefused(d) {
  assert.equal(d.blocker, null, 'no blocker is recorded');
  assert.notEqual(d.outcome, 'build_blocked');
  assert.ok(!d.stdout.includes('build_blocked'));
  assert.ok(d.stdout.includes('candidate/executor_round_limit'), 'the Build continued to its ordinary round limit');
  assert.equal(d.calls, '2');
  assert.ok(d.prompt2.includes(INVALID), 'the next round carries the native invalid-blocker feedback');
  assert.equal(d.head_same, true);
  preserved(d);
}
function checkHeadMoved(d) {
  assert.equal(d.exit, 1);
  assert.ok(d.stdout.includes('candidate/head_moved'), d.stdout);
  assert.equal(d.blocker, null);
  assert.notEqual(d.outcome, 'build_blocked');
  assert.equal(d.head_same, false, 'the fixture moved HEAD');
  assert.equal(d.calls, '1');
}
function checkUndeclared(d) {
  assert.equal(d.exit, 1);
  assert.ok(d.stdout.includes('executor/protocol'), d.stdout);
  assert.equal(d.blocker, null);
  assert.notEqual(d.outcome, 'build_blocked');
  assert.equal(d.calls, '1');
  assert.equal(d.head_same, true);
}
function checkDescriptor(d) {
  assert.equal(d.capabilities_blocker, true);
  assert.deepEqual(d.roles.build, { served: true, blocker: true });
  assert.deepEqual(d.roles.shape, { served: true, blocker: false });
  assert.deepEqual(d.roles.review, { served: true, blocker: false });
}
function checkConstraints(d) {
  const c = d.constraints;
  for (const s of NATIVE) assert.ok(c.build.includes(s), `missing native wording: ${s}`);
  assert.ok(c.build.includes('Do not edit the protected paths named in the task'), 'protected edits stay refused');
  assert.ok(c.build.includes('Do not commit, push'), 'the Git rules stay');
  assert.ok(!c.shape.includes('BUILDER-REPORTED') && !c.review.includes('BUILDER-REPORTED'), 'shape and review get no blocker wording');
}

function controls(kind) {
  const blocked = {
    mode: 'protected-step-file', exit: 1, stdout: 'kogen: candidate/build_blocked\n', err_class: 'candidate', err_reason: 'build_blocked',
    outcome: 'build_blocked', calls: '1', blocker: { paths: [STEPS_FILE], reason: 'r', evidence: 'e', classification: 'BUILDER-REPORTED' },
    app_before_recover: 'red\n', index_same: true, approval_same: true, head_same: true,
    recover_exit: 0, recover_shown: '', recover_state: 'cleaned', app_after_recover: 'baseline\n',
  };
  const refused = { mode: 'unprotected-path', exit: 1, stdout: 'kogen: candidate/executor_round_limit\n', outcome: 'executor_round_limit', calls: '2',
    prompt2: `Kogen's independent verification of your previous round:\n\n${INVALID}\nmore`, blocker: null, app_before_recover: 'red\n', index_same: true, approval_same: true, head_same: true };
  const moved = { mode: 'moved-head', exit: 1, stdout: 'kogen: candidate/head_moved\n', blocker: null, outcome: 'head_moved', head_same: false, calls: '1' };
  const undeclared = { mode: 'undeclared-blocker', exit: 1, stdout: 'kogen: executor/protocol\n', blocker: null, outcome: 'protocol', calls: '1', head_same: true };
  const desc = { capabilities_blocker: true, roles: { build: { served: true, blocker: true }, shape: { served: true, blocker: false }, review: { served: true, blocker: false } },
    constraints: { build: NATIVE.join('\n') + '\nDo not edit the protected paths named in the task.\nDo not commit, push.', shape: 'shape', review: 'review' } };
  checkBlocked(blocked); checkRecovered(blocked); checkRefused(refused); checkHeadMoved(moved); checkUndeclared(undeclared); checkDescriptor(desc); checkConstraints(desc);
  if (kind === 'good') { console.log('k16 observer good'); return; }
  assert.equal(kind, 'bad');
  const bad = (fn, d, mutate) => { const c = structuredClone(d); mutate(c); assert.throws(() => fn(c), 'accepted a known-bad fixture'); };
  bad(checkBlocked, blocked, d => { d.stdout = 'kogen: candidate/executor_round_limit\n'; });
  bad(checkBlocked, blocked, d => { d.blocker = null; });
  bad(checkBlocked, blocked, d => { d.blocker.paths = ['app.txt']; });
  bad(checkBlocked, blocked, d => { d.blocker.classification = 'x'; });
  bad(checkBlocked, blocked, d => { delete d.blocker.evidence; });
  bad(checkBlocked, blocked, d => { d.app_before_recover = 'baseline\n'; });
  bad(checkBlocked, blocked, d => { d.index_same = false; });
  bad(checkBlocked, blocked, d => { d.approval_same = false; });
  bad(checkBlocked, blocked, d => { d.head_same = false; });
  bad(checkRecovered, blocked, d => { d.recover_exit = 1; });
  bad(checkRecovered, blocked, d => { d.recover_state = 'preserved'; });
  bad(checkRecovered, blocked, d => { d.app_after_recover = 'red\n'; });
  bad(checkRefused, refused, d => { d.blocker = { paths: ['app.txt'] }; });
  bad(checkRefused, refused, d => { d.outcome = 'build_blocked'; });
  bad(checkRefused, refused, d => { d.stdout = 'kogen: executor/protocol\n'; });
  bad(checkRefused, refused, d => { d.prompt2 = 'nothing'; });
  bad(checkRefused, refused, d => { d.calls = '1'; });
  bad(checkHeadMoved, moved, d => { d.stdout = 'kogen: candidate/build_blocked\n'; });
  bad(checkHeadMoved, moved, d => { d.blocker = {}; });
  bad(checkHeadMoved, moved, d => { d.head_same = true; });
  bad(checkUndeclared, undeclared, d => { d.stdout = 'kogen: candidate/build_blocked\n'; });
  bad(checkUndeclared, undeclared, d => { d.stdout = 'kogen: candidate/executor_round_limit\n'; });
  bad(checkUndeclared, undeclared, d => { d.blocker = { paths: [] }; });
  bad(checkDescriptor, desc, d => { d.capabilities_blocker = false; });
  bad(checkDescriptor, desc, d => { d.roles.build.blocker = false; });
  bad(checkDescriptor, desc, d => { d.roles.review.blocker = true; });
  bad(checkDescriptor, desc, d => { d.roles.shape.blocker = true; });
  bad(checkConstraints, desc, d => { d.constraints.build = d.constraints.build.replace('BUILDER-REPORTED', 'x'); });
  bad(checkConstraints, desc, d => { d.constraints.build = d.constraints.build.replace('Plain blocked text does not stop the Build.', ''); });
  bad(checkConstraints, desc, d => { d.constraints.build = d.constraints.build.replace('Do not edit the protected paths named in the task', ''); });
  bad(checkConstraints, desc, d => { d.constraints.shape = 'BUILDER-REPORTED'; });
  console.log('k16 observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  const STEP = { timeout: 300000 };
  When('the k16 fake Claude Code build round reports the blocker case {string}', STEP, function (mode) { this.k16 = observe(mode); });
  When('the k16 Claude Code executor is described and its constraints read', STEP, function () { this.k16 = observe('static'); });
  Then('the k16 Build stopped with the candidate build_blocked result as BUILDER-REPORTED naming that protected step file, with the candidate, index and approval preserved', function () { checkBlocked(this.k16); });
  Then('the k16 intent recover of that Build succeeded and cleaned only the implementation', function () { checkRecovered(this.k16); });
  Then('the k16 Build refused the report as native does, recorded no blocker and fed the invalid-blocker message back', function () { checkRefused(this.k16); });
  Then('the k16 Build stopped with the candidate head_moved result and no recorded blocker', function () { checkHeadMoved(this.k16); });
  Then('the k16 Build stopped with the executor protocol failure and no recorded blocker', function () { checkUndeclared(this.k16); });
  Then('the k16 Claude Code build role declares Blocker while its shape and review roles do not', function () { checkDescriptor(this.k16); });
  Then('the k16 build constraints carry the native blocker wording and still refuse protected edits', function () { checkConstraints(this.k16); });
}
