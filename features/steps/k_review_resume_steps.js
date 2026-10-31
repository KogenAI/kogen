'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const cache = new Map();

// Runs the observation driver, mounted as a test with go -overlay, once per mode.
function observe(mode) {
  if (cache.has(mode)) return cache.get(mode);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-krr-'));
  fs.chmodSync(dir, 0o700);
  try {
    const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/build/k_review_resume_acceptance_test.go')]: path.join(__dirname, 'k_review_resume_driver.go') } }), { mode: 0o600 });
    const cwd = path.join(ROOT, 'cli');
    const r = spawnSync('go', ['test', '-overlay', overlay, './build', '-run', '^TestKReviewResumeObservation$', '-count=1'], {
      cwd, encoding: 'utf8', timeout: 280000, maxBuffer: 16 * 1024 * 1024,
      env: { ...process.env, PWD: cwd, KOGEN_KRR_MODE: mode, KOGEN_KRR_OUTPUT: output, GOWORK: 'off', GOPROXY: 'off', GOTOOLCHAIN: 'local' },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `observation driver (mode ${mode}) failed:\n${r.stdout}\n${r.stderr}`);
    // Go success alone is not proof: the driver must have written its observation.
    const data = JSON.parse(fs.readFileSync(output, 'utf8'));
    assert.equal(data.mode, mode);
    cache.set(mode, data);
    return data;
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

const has = (text, part, what) => assert.ok(String(text).includes(part), `${what}: missing ${JSON.stringify(part)} in:\n${text}`);
const lacks = (text, part, what) => assert.ok(!String(text).includes(part), `${what}: unexpected ${JSON.stringify(part)} in:\n${text}`);
const GUIDANCE = 'start a fresh Build from a Build-clean checkout under the still-current exact approval';

function base(d) {
  const b = d.parent && d.parent.continuation && d.parent.continuation.base;
  assert.ok(b && typeof b === 'object', `the checkpoint records continuation.base: ${JSON.stringify(d.parent && d.parent.continuation)}`);
  assert.equal(b.green, true, 'the base pass is green');
  assert.ok(Number.isInteger(b.n) && b.n >= 1, `base pass number ${b.n}`);
  assert.match(String(b.tree), /^[0-9a-f]{40,64}$/, 'base tree');
  return b;
}
function reviews(d) {
  const n = d.parent.result.reviews;
  assert.ok(Number.isInteger(n) && n >= 1, `parent reviews ${n}`);
  return n;
}
function lineA(n, p) {
  return `review ${n} by executor claude-code cannot be continued (resume capability: none); starting fresh review ${n + 1} of the green candidate verified in pass ${p}, with no builder round and no rerun of its checks`;
}
function lineB(n) { return `discarded review ${n}'s uncommitted edits, which are not part of that green candidate: `; }

// ---- a claude-code builder, native reviewer, stopped in the final verification ----
function checkFinalVerifyStop(d) {
  assert.equal(d.paused, true, 'the final verification of the reviewer repair was running when stopped');
  assert.notEqual(d.stop.exit, 0);
  has(d.stop.shown, 'stopped in verifying: interrupted', 'stop');
  assert.equal(d.parent.continuation.stage, 'review_verify');
  assert.equal(d.parent.executor && d.parent.executor.name, 'claude-code', 'the builder was claude-code');
}
function checkFinalVerifyResume(d) {
  assert.equal(d.resume.error, '', `resume error ${d.resume.error}: ${d.resume.detail}`);
  assert.equal(d.resume.exit, 0);
  has(d.resume.stdout, `resuming Build ${d.parent.id} as `, 'resume');
  has(d.resume.stdout, 'landed fixture ', 'resume');
  assert.equal(d.committed_app, 'reviewer repair', 'the approved reviewer repair landed');
  assert.equal(d.commits, '1');
  assert.equal(d.new_provider_requests, 0, 'no new review request');
  assert.equal(d.new_builder_starts, 0, 'no builder session');
  assert.equal(d.child.result.resumed_from, d.parent.id);
  assert.equal(d.child.result.outcome, 'landed');
}

// ---- a claude-code builder stopped in its own stage ----
function checkBuilderStage(d) {
  has(d.stop.shown, 'candidate/executor_round_limit', 'stop');
  assert.equal(d.parent.continuation.stage, 'builder_verify');
  assert.equal(d.resume.error, 'candidate/resume_refused');
  has(d.resume.detail, 'Builds by executor claude-code cannot be resumed in this version (resume capability: none)', 'refusal');
  has(d.resume.detail, 'inspect the preserved candidate or start a fresh Build', 'refusal');
  assert.equal(d.executor_reached, 0, 'the refusal reached no executor');
  assert.equal(d.checkpoint_same, true);
  assert.equal(d.app, 'red\n');
  assert.equal(d.commits, '0');
  assert.equal(d.runs, 1, 'no new run');
  assert.equal(d.new_provider_requests, 0);
}

// ---- claude-code reviewer stops ----
function checkRoundLimitStop(d) {
  has(d.stop.shown, 'candidate/executor_round_limit', 'stop');
  has(d.stop.shown, 'stopped in verifying: executor_round_limit', 'stop');
  assert.equal(d.parent.continuation.stage, 'review_verify');
  assert.equal(d.app_before_resume, 'red\n', 'the stopped reviewer left its red edit');
  base(d);
}
function checkNoEditsStop(d) {
  has(d.stop.shown, 'executor/failed', 'stop');
  assert.equal(d.parent.continuation.stage, 'review');
  assert.equal(d.app_before_resume, 'candidate\n', 'the candidate is the green builder tree');
  base(d);
}
function checkFresh(d, discarded) {
  const b = base(d), n = reviews(d);
  assert.equal(d.resume.error, '', `resume error ${d.resume.error}: ${d.resume.detail}`);
  assert.equal(d.resume.exit, 0);
  has(d.resume.stdout, `resuming Build ${d.parent.id} as `, 'resume');
  has(d.resume.stdout, lineA(n, b.n), 'resume');
  if (discarded) has(d.resume.stdout, lineB(n) + 'app.txt\n', 'resume');
  else lacks(d.resume.stdout, 'discarded review', 'resume');
  has(d.resume.stdout, 'landed fixture ', 'resume');
  assert.equal(d.committed_app, 'candidate', 'the green builder candidate landed');
  assert.equal(d.app, 'candidate\n');
  assert.equal(d.commits, '1');
  assert.equal(d.head_tree, b.tree, 'the landed tree is the green base tree');
  assert.equal(d.resumed_review_starts, 1, 'one fresh review session');
  assert.equal(d.resumed_build_starts, 0, 'no builder session');
  assert.equal(d.resumed_builder_rounds, 0, 'no builder round');
  assert.equal(d.resumed_review_feedback[0], '', 'the fresh review starts without the stopped session\'s feedback');
  const c = d.child;
  assert.ok(c && c.result, 'the resume made a child run');
  assert.equal(c.result.resumed_from, d.parent.id);
  assert.equal(c.result.outcome, 'landed');
  assert.equal(c.result.passes, d.parent.result.passes, 'no verification pass was rerun');
  assert.equal(c.result.reviews, n + 1);
  assert.notEqual(c.result.review_executor.session_id, d.parent.result.review_executor.session_id, 'a new reviewer session');
  const m = c.materials[`review-${n + 1}-material.json`];
  assert.ok(m, `review ${n + 1} material: ${Object.keys(c.materials)}`);
  assert.equal(m.tree, b.tree, 'the fresh review was given the green base tree');
  if (discarded) {
    assert.equal(c.discarded.length, 1, 'one review_edits_discarded event');
    assert.equal(c.discarded[0].review, n);
    assert.equal(c.discarded[0].tree, b.tree);
    assert.deepEqual(c.discarded[0].paths.map(p => p.path), ['app.txt']);
  } else {
    assert.equal(c.discarded.length, 0, 'nothing discarded');
  }
  assert.equal(d.provider_requests, 0);
}
function checkResumedRed(d) {
  const b = base(d), n = reviews(d);
  assert.equal(d.resume.exit, 1);
  has(d.resume.stdout, lineA(n, b.n), 'resume');
  has(d.resume.shown, 'candidate/executor_round_limit', 'resume');
  lacks(d.resume.stdout, 'landed fixture', 'resume');
  assert.equal(d.commits, '0', 'nothing landed');
  assert.equal(d.app, 'red\n', 'the fresh reviewer\'s work is preserved');
  assert.equal(d.resumed_review_starts, 1);
  assert.equal(d.resumed_builder_rounds, 0);
  assert.equal(d.resumed_review_feedback.length, 2);
  assert.equal(d.resumed_review_feedback[0], '');
  assert.equal(d.child.result.reviews, n + 1);
  assert.equal(d.child.result.outcome, 'executor_round_limit');
}
function checkRefusedUnchanged(d, app) {
  assert.equal(d.resume.error, 'candidate/resume_refused', `resume error ${d.resume.error}: ${d.resume.detail}`);
  assert.equal(d.checkpoint_same, true, 'the checkpoint is unchanged');
  assert.equal(d.app, app, 'the candidate is unchanged');
  assert.equal(d.commits, '0');
  assert.equal(d.runs, 1, 'no new run');
  assert.equal(d.resumed_review_starts, 0, 'no reviewer started');
  assert.equal(d.resumed_build_starts, 0, 'no builder started');
}
function checkBlocked(d) {
  has(d.stop.shown, 'candidate/review_blocked', 'stop');
  const n = reviews(d);
  checkRefusedUnchanged(d, 'candidate\n');
  has(d.resume.detail, `review ${n} by executor claude-code ended with a blocking finding that only that reviewer's own new decision can clear, and its session cannot be resumed (resume capability: none)`, 'refusal');
  has(d.resume.detail, GUIDANCE, 'refusal');
}
function checkLegacy(d) {
  assert.equal(d.legacy_removed_base, true, 'the fixture removed a recorded base');
  const n = reviews(d);
  checkRefusedUnchanged(d, 'red\n');
  has(d.resume.detail, `review ${n} by executor claude-code cannot be continued (resume capability: none) and this checkpoint records no complete green pass that review started from`, 'refusal');
  has(d.resume.detail, GUIDANCE, 'refusal');
}

// ---- known-good and known-bad controls of the assertions above ----
function controls(kind) {
  const T = 'a'.repeat(40);
  const parentReview = (stage, extra) => ({ id: 'p1', continuation: { stage, base: { n: 1, green: true, tree: T } },
    result: { passes: 3, reviews: 1, review_executor: { session_id: 'old' } }, ...extra });
  const fresh = (stage, app, discarded) => ({
    mode: 'x', stop: { exit: 1, shown: stage === 'review' ? 'executor/failed:' : 'candidate/executor_round_limit: x\n stopped in verifying: executor_round_limit;' },
    parent: parentReview(stage), app_before_resume: app,
    resume: { exit: 0, error: '', detail: '', shown: '', stdout: 'resuming Build p1 as c1 (root p1)\n' + lineA(1, 1) + '\n' + (discarded ? lineB(1) + 'app.txt\n' : '') + 'landed fixture abc\n' },
    committed_app: 'candidate', app: 'candidate\n', commits: '1', head_tree: T, resumed_review_starts: 1, resumed_build_starts: 0,
    resumed_builder_rounds: 0, resumed_review_feedback: [''], provider_requests: 0,
    child: { result: { resumed_from: 'p1', outcome: 'landed', passes: 3, reviews: 2, review_executor: { session_id: 'new' } },
      materials: { 'review-2-material.json': { tree: T } }, discarded: discarded ? [{ review: 1, tree: T, paths: [{ path: 'app.txt', change: 'modified' }] }] : [] },
  });
  const roundLimit = fresh('review_verify', 'red\n', true), noEdits = fresh('review', 'candidate\n', false);
  const red = { ...fresh('review_verify', 'red\n', true), resume: { exit: 1, error: '', detail: '', stdout: lineA(1, 1) + '\n', shown: lineA(1, 1) + '\ncandidate/executor_round_limit: x' },
    commits: '0', app: 'red\n', resumed_review_feedback: ['', 'Final verification failed'], child: { result: { reviews: 2, outcome: 'executor_round_limit' } } };
  const refused = (detail, app, extra) => ({ stop: { shown: 'candidate/review_blocked: x' }, parent: parentReview('review_verify'), checkpoint_same: true, app, commits: '0', runs: 1,
    resumed_review_starts: 0, resumed_build_starts: 0, resume: { exit: 1, error: 'candidate/resume_refused', detail }, ...extra });
  const blocked = refused(`Build p1: review 1 by executor claude-code ended with a blocking finding that only that reviewer's own new decision can clear, and its session cannot be resumed (resume capability: none); ${GUIDANCE}`, 'candidate\n');
  const legacy = refused(`Build p1: review 1 by executor claude-code cannot be continued (resume capability: none) and this checkpoint records no complete green pass that review started from; ${GUIDANCE}`, 'red\n', { legacy_removed_base: true });
  const final = { paused: true, stop: { exit: 143, shown: 'stopped in verifying: interrupted;' }, parent: { id: 'p1', continuation: { stage: 'review_verify' }, executor: { name: 'claude-code' } },
    resume: { exit: 0, error: '', stdout: 'resuming Build p1 as c1 (root p1)\nlanded fixture abc\n' }, committed_app: 'reviewer repair', commits: '1',
    new_provider_requests: 0, new_builder_starts: 0, child: { result: { resumed_from: 'p1', outcome: 'landed' } } };
  const builder = { stop: { shown: 'candidate/executor_round_limit: x' }, parent: { continuation: { stage: 'builder_verify' } },
    resume: { error: 'candidate/resume_refused', detail: 'Build p1: Builds by executor claude-code cannot be resumed in this version (resume capability: none); inspect the preserved candidate or start a fresh Build' },
    executor_reached: 0, checkpoint_same: true, app: 'red\n', commits: '0', runs: 1, new_provider_requests: 0 };

  checkFinalVerifyStop(final); checkFinalVerifyResume(final); checkBuilderStage(builder);
  checkRoundLimitStop(roundLimit); checkFresh(roundLimit, true); checkNoEditsStop(noEdits); checkFresh(noEdits, false);
  checkResumedRed(red); checkBlocked(blocked); checkLegacy(legacy);
  if (kind === 'good') { console.log('k-review-resume observer good'); return; }
  assert.equal(kind, 'bad');
  const bad = (fn, d, mutate) => { const c = structuredClone(d); mutate(c); assert.throws(() => fn(c), undefined, `accepted a known-bad fixture: ${fn.name} ${mutate}`); };
  bad(checkFinalVerifyStop, final, d => { d.paused = false; });
  bad(checkFinalVerifyStop, final, d => { d.parent.continuation.stage = 'review'; });
  bad(checkFinalVerifyStop, final, d => { d.parent.executor = null; });
  bad(checkFinalVerifyResume, final, d => { d.resume = { exit: 1, error: 'candidate/resume_refused', stdout: '' }; });
  bad(checkFinalVerifyResume, final, d => { d.committed_app = 'baseline'; });
  bad(checkFinalVerifyResume, final, d => { d.new_provider_requests = 1; });
  bad(checkFinalVerifyResume, final, d => { d.new_builder_starts = 1; });
  bad(checkBuilderStage, builder, d => { d.resume.error = ''; });
  bad(checkBuilderStage, builder, d => { d.resume.detail = 'Build p1: refused'; });
  bad(checkBuilderStage, builder, d => { d.executor_reached = 1; });
  bad(checkBuilderStage, builder, d => { d.runs = 2; });
  bad(checkRoundLimitStop, roundLimit, d => { delete d.parent.continuation.base; });
  bad(checkRoundLimitStop, roundLimit, d => { d.parent.continuation.base.green = false; });
  bad(checkRoundLimitStop, roundLimit, d => { d.app_before_resume = 'candidate\n'; });
  bad(checkNoEditsStop, noEdits, d => { d.parent.continuation.stage = 'review_verify'; });
  bad(c => checkFresh(c, true), roundLimit, d => { d.resume = { exit: 1, error: 'candidate/resume_refused', detail: 'x', stdout: '' }; });
  bad(c => checkFresh(c, true), roundLimit, d => { d.resume.stdout = d.resume.stdout.replace(lineA(1, 1), 'starting a review'); });
  bad(c => checkFresh(c, true), roundLimit, d => { d.resume.stdout = d.resume.stdout.replace(lineB(1) + 'app.txt\n', ''); });
  bad(c => checkFresh(c, true), roundLimit, d => { d.committed_app = 'red'; });
  bad(c => checkFresh(c, true), roundLimit, d => { d.head_tree = 'b'.repeat(40); });
  bad(c => checkFresh(c, true), roundLimit, d => { d.resumed_review_starts = 0; });
  bad(c => checkFresh(c, true), roundLimit, d => { d.resumed_builder_rounds = 1; });
  bad(c => checkFresh(c, true), roundLimit, d => { d.resumed_review_feedback = ['Final verification failed']; });
  bad(c => checkFresh(c, true), roundLimit, d => { d.child.result.passes = 4; });
  bad(c => checkFresh(c, true), roundLimit, d => { d.child.result.review_executor.session_id = 'old'; });
  bad(c => checkFresh(c, true), roundLimit, d => { d.child.materials['review-2-material.json'].tree = 'b'.repeat(40); });
  bad(c => checkFresh(c, true), roundLimit, d => { d.child.discarded = []; });
  bad(c => checkFresh(c, false), noEdits, d => { d.resume.stdout += lineB(1) + 'app.txt\n'; });
  bad(c => checkFresh(c, false), noEdits, d => { d.child.discarded = [{ review: 1, tree: T, paths: [] }]; });
  bad(checkResumedRed, red, d => { d.commits = '1'; });
  bad(checkResumedRed, red, d => { d.resume.stdout += 'landed fixture abc\n'; });
  bad(checkResumedRed, red, d => { d.resumed_builder_rounds = 1; });
  bad(checkBlocked, blocked, d => { d.resume.detail = 'Build p1: an independent review by executor claude-code cannot be resumed (resume capability: none); ' + GUIDANCE; });
  bad(checkBlocked, blocked, d => { d.resume.error = ''; });
  bad(checkBlocked, blocked, d => { d.resumed_review_starts = 1; });
  bad(checkBlocked, blocked, d => { d.checkpoint_same = false; });
  bad(checkBlocked, blocked, d => { d.app = 'red\n'; });
  bad(checkLegacy, legacy, d => { d.legacy_removed_base = false; });
  bad(checkLegacy, legacy, d => { d.resume.detail = 'Build p1: an independent review by executor claude-code cannot be resumed (resume capability: none); ' + GUIDANCE; });
  bad(checkLegacy, legacy, d => { d.runs = 2; });
  console.log('k-review-resume observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  const STEP = { timeout: 300000 };
  When('the k-review-resume driver observes {string}', STEP, function (mode) { this.krr = observe(mode); });
  Then('the claude-code builder\'s Build was stopped by SIGTERM in the final verification of the approved reviewer repair', function () { checkFinalVerifyStop(this.krr); });
  Then('its resume landed the reviewer repair with no new builder session and no new review request', function () { checkFinalVerifyResume(this.krr); });
  Then('the claude-code builder\'s own stage stays refused with no executor reached and nothing changed', function () { checkBuilderStage(this.krr); });
  Then('the Build stopped at the claude-code reviewer\'s round limit with the green pass recorded as the review base', function () { checkRoundLimitStop(this.krr); });
  Then('the Build stopped in the claude-code review of the unchanged green candidate with the review base recorded', function () { checkNoEditsStop(this.krr); });
  Then('its resume discarded the stopped review\'s edits and landed the green candidate after one fresh claude-code review, with no builder round and no rerun of checks', function () { checkFresh(this.krr, true); });
  Then('its resume discarded nothing and landed the green candidate after one fresh claude-code review, with no builder round and no rerun of checks', function () { checkFresh(this.krr, false); });
  Then('the fresh review\'s red edits stopped at its own round limit without a commit', function () { checkResumedRed(this.krr); });
  Then('the resume of the blocked claude-code review was refused, naming the blocker only that reviewer can clear, with nothing changed', function () { checkBlocked(this.krr); });
  Then('the resume of a checkpoint without a review base was refused, naming the work to redo, with nothing changed', function () { checkLegacy(this.krr); });
}
