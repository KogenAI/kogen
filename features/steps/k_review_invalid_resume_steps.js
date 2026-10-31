'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const cache = new Map();

// Runs the observation driver, mounted as a test with go -overlay, once for every mode.
function observe(mode) {
  if (cache.has(mode)) return cache.get(mode);
  assert.equal(cache.size, 0, `the driver already ran without observing mode ${mode}`);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-krir-'));
  fs.chmodSync(dir, 0o700);
  try {
    const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/build/k_review_invalid_resume_acceptance_test.go')]: path.join(__dirname, 'k_review_invalid_resume_driver.go') } }), { mode: 0o600 });
    const cwd = path.join(ROOT, 'cli');
    const r = spawnSync('go', ['test', '-overlay', overlay, './build', '-run', '^TestKReviewInvalidResumeObservation$', '-count=1'], {
      cwd, encoding: 'utf8', timeout: 280000, maxBuffer: 16 * 1024 * 1024,
      env: { ...process.env, PWD: cwd, KOGEN_KRIR_OUTPUT: output, GOWORK: 'off', GOPROXY: 'off', GOTOOLCHAIN: 'local' },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `observation driver failed:\n${r.stdout}\n${r.stderr}`);
    // Go success alone is not proof: the driver must have written every mode's observation.
    const all = JSON.parse(fs.readFileSync(output, 'utf8'));
    for (const [m, data] of Object.entries(all)) {
      assert.equal(data.mode, m);
      cache.set(m, data);
    }
    assert.ok(cache.has(mode), `the driver wrote no observation of mode ${mode}`);
    return cache.get(mode);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

const has = (text, part, what) => assert.ok(String(text).includes(part), `${what}: missing ${JSON.stringify(part)} in:\n${text}`);
const lacks = (text, part, what) => assert.ok(!String(text).includes(part), `${what}: unexpected ${JSON.stringify(part)} in:\n${text}`);
const STOP = 'candidate/review_invalid: the reviewer did not return a valid verdict; edits are left in place';
const discardLine = n => `discarded review ${n}'s uncommitted edits, which are not part of that green candidate: app.txt\n`;

// The fixture of each mode: the invalid review that stopped the Build, the reviewer's edit left
// in place, and the verification passes the stopped Build ran.
const FIXTURE = {
  'native-edits': { n: 2, app: 'reviewer edit\n', passes: 1 },
  'native-repaired': { n: 1, app: 'red\nreviewer repair\n', passes: 2 },
  'native-resumed-invalid': { n: 2, app: 'reviewer edit\n', passes: 1 },
  'external-edits': { n: 2, app: 'reviewer edit\n', passes: 1 },
};

// The green pass the review-only checkpoint keeps: the builder's complete green pass 1.
function greenPass(d) {
  const c = d.parent && d.parent.continuation;
  assert.ok(c && c.pass, `the stopped Build's checkpoint has a saved pass (stage ${c && c.stage}, pass ${JSON.stringify(c && c.pass)})`);
  assert.equal(c.pass.green, true, 'the saved pass is green');
  assert.equal(c.pass.n, 1, 'the saved pass is the builder candidate\'s pass 1');
  assert.match(String(c.pass.tree), /^[0-9a-f]{40,64}$/, 'saved pass tree');
  return c.pass;
}

function checkStop(d) {
  const fx = FIXTURE[d.mode];
  assert.ok(fx, `unknown mode ${d.mode}`);
  assert.equal(d.stop.exit, 1, 'the Build stopped');
  has(d.stop.stdout, STOP, 'stop');
  const p = d.parent;
  assert.ok(p && p.result, 'the stopped Build left its result');
  assert.equal(p.result.outcome, 'review_invalid');
  assert.equal(p.result.reviews, fx.n, 'reviews of the stopped Build');
  assert.equal(p.result.passes, fx.passes, 'verification passes of the stopped Build');
  assert.equal(p.continuation.stage, 'review_only', 'the stop left a review-only checkpoint');
  const pass = greenPass(d);
  const last = p.review_only[p.review_only.length - 1];
  assert.ok(last, 'a review_only event was logged');
  assert.equal(last.eligible, true, `the last review_only event is eligible: ${JSON.stringify(last)}`);
  assert.equal(last.next, 'stop');
  assert.equal(last.review, fx.n);
  assert.equal(last.tree, pass.tree, 'the review-only stop names the green tree');
  assert.equal(p.review_retry && p.review_retry.tree, pass.tree, 'the retry record is the green tree\'s');
  assert.equal(d.app_after_stop, fx.app, 'the reviewer\'s edits are left in place at the stop');
  assert.equal(d.commits_after_stop, '0', 'nothing was committed at the stop');
}

function checkInspect(d) {
  const i = d.inspect;
  assert.equal(i.exit, 0, `inspect exit ${i.exit}`);
  has(i.stdout, `Build ${d.parent.id} · fixture · review_invalid · `, 'inspect');
  has(i.stdout, '  reason: review_invalid\n', 'inspect');
  has(i.stdout, '  resume: potentially_available (not authorization)\n', 'inspect');
  lacks(i.stdout, 'resume: unsupported', 'inspect');
  has(i.stdout, `kogen intent resume ${d.parent.id} --project `, 'inspect');
}

// The resumed run: one fresh review of the green tree, nothing else.
function checkResumedRun(d, landed) {
  const fx = FIXTURE[d.mode], pass = greenPass(d), c = d.child;
  assert.ok(c && c.result, 'the resume made a new run with its own result');
  assert.notEqual(c.id, d.parent.id);
  assert.equal(c.result.resumed_from, d.parent.id);
  assert.equal(c.result.passes, fx.passes, 'no verification pass was rerun');
  assert.equal(c.result.reviews, fx.n + 1, 'exactly one further review');
  for (const name of ['pass', 'command', 'command_result']) assert.equal(c.counts[name], 0, `${name} events in the resumed run`);
  assert.equal(c.review_edits_discarded.length, 1, 'one review_edits_discarded event');
  const ev = c.review_edits_discarded[0];
  assert.equal(ev.review, fx.n);
  assert.equal(ev.tree, pass.tree);
  assert.deepEqual(ev.paths, [{ path: 'app.txt', change: 'modified' }]);
  assert.equal(c.review_retry_events.length, 1, 'one review_retry event: the explicit resume, no automatic retry');
  const rr = c.review_retry_events[0];
  assert.equal(rr.kind, 'resume');
  assert.equal(rr.from_review, fx.n);
  assert.equal(rr.review, fx.n + 1);
  assert.equal(rr.tree, pass.tree);
  has(d.resume.stdout, `resuming Build ${d.parent.id} as ${c.id} (root ${d.parent.id})`, 'resume');
  has(d.resume.stdout, discardLine(fx.n), 'resume');
  if (d.mode.startsWith('native')) {
    assert.equal(d.new_review_requests, landed ? 1 : 2, 'review requests of the one fresh review');
    assert.equal(d.new_requests, d.new_review_requests, 'no builder request');
    const fr = d.fresh_review;
    assert.ok(fr, 'the fresh review sent a request');
    assert.equal(fr.input_items, 1, 'the fresh review is a new conversation');
    assert.equal(fr.reused_conversation, false, 'the fresh review has its own conversation identity');
    assert.equal(fr.has_reviewer_edit, false, 'the fresh review never saw the discarded edits');
    if (d.mode !== 'native-repaired') assert.equal(fr.same_material, true, 'the fresh review got the first review\'s material');
  } else {
    assert.equal(d.new_requests, 0, 'no provider request (no builder)');
    assert.equal(d.new_review_sessions, 1, 'one fresh reviewer session');
    assert.equal(d.new_builder_rounds, 0, 'no builder round');
  }
}

function checkLanded(d) {
  const pass = greenPass(d);
  assert.equal(d.resume.exit, 0, `resume exit ${d.resume.exit}:\n${d.resume.stdout}`);
  has(d.resume.stdout, 'landed fixture ', 'resume');
  checkResumedRun(d, true);
  assert.equal(d.child.result.outcome, 'landed');
  assert.equal(d.commits, '1', 'one commit');
  assert.equal(d.committed_app, 'candidate', 'the builder\'s green candidate landed');
  assert.equal(d.head_tree, pass.tree, 'the landed tree is the saved green tree');
  assert.equal(d.app, 'candidate\n');
  assert.equal(d.status, '', 'the checkout is clean');
}

function checkResumedInvalid(d) {
  const fx = FIXTURE[d.mode];
  assert.equal(d.resume.exit, 1, `resume exit ${d.resume.exit}`);
  has(d.resume.stdout, STOP, 'resume');
  lacks(d.resume.stdout, 'landed fixture', 'resume');
  checkResumedRun(d, false);
  assert.equal(d.child.result.outcome, 'review_invalid');
  assert.equal(d.child.continuation.stage, 'review_only', 'the resumed stop is again a review-only checkpoint');
  assert.equal(d.child.review_retry.automatic, true, 'the automatic retry stays spent');
  assert.equal(d.commits, '0', 'nothing landed');
  assert.equal(d.app, 'candidate\n', 'the checkout is the green candidate the fresh review judged');
  assert.equal(d.child_inspect.exit, 0);
  has(d.child_inspect.stdout, '  resume: potentially_available (not authorization)\n', 'inspect of the resumed run');
  assert.equal(d.child.result.reviews, fx.n + 1);
}

// ---- known-good and known-bad controls of the assertions above ----
function controls(kind) {
  const T = 'a'.repeat(40), O = 'b'.repeat(40);
  const make = (mode, landed) => {
    const fx = FIXTURE[mode], n = fx.n;
    const native = mode.startsWith('native');
    const d = {
      mode, stop: { exit: 1, stdout: `building fixture\nfailed fixture: review_invalid (Build p1)\n${STOP}\n` },
      parent: { id: 'p1', result: { outcome: 'review_invalid', reviews: n, passes: fx.passes },
        continuation: { stage: 'review_only', pass: { n: 1, green: true, tree: T } }, review_retry: { tree: T, automatic: n > 1 },
        review_only: [{ eligible: true, next: 'stop', review: n, tree: T }] },
      app_after_stop: fx.app, commits_after_stop: '0',
      inspect: { exit: 0, stdout: `Build p1 · fixture · review_invalid · reviewing\n  reason: review_invalid\n  resume: potentially_available (not authorization)\nkogen intent resume p1 --project '/x'\n` },
      resume: { exit: landed ? 0 : 1, stdout: `resuming Build p1 as c1 (root p1)\n${discardLine(n)}` + (landed ? 'landed fixture abc (Build c1)\n' : `failed fixture: review_invalid (Build c1)\n${STOP}\n`) },
      child: { id: 'c1', result: { resumed_from: 'p1', passes: fx.passes, reviews: n + 1, outcome: landed ? 'landed' : 'review_invalid' },
        continuation: { stage: landed ? 'landed' : 'review_only' }, review_retry: { tree: T, automatic: true },
        counts: { pass: 0, command: 0, command_result: 0 },
        review_edits_discarded: [{ review: n, tree: T, candidate: O, paths: [{ path: 'app.txt', change: 'modified' }] }],
        review_retry_events: [{ kind: 'resume', from_review: n, review: n + 1, tree: T }] },
      commits: landed ? '1' : '0', committed_app: landed ? 'candidate' : 'baseline', head_tree: landed ? T : O,
      app: 'candidate\n', status: landed ? '' : 'M app.txt',
      child_inspect: { exit: 0, stdout: '  resume: potentially_available (not authorization)\n' },
    };
    if (native) Object.assign(d, { new_requests: landed ? 1 : 2, new_review_requests: landed ? 1 : 2,
      fresh_review: { input_items: 1, reused_conversation: false, has_reviewer_edit: false, same_material: true } });
    else Object.assign(d, { new_requests: 0, new_review_sessions: 1, new_builder_rounds: 0 });
    return d;
  };
  const edits = make('native-edits', true), repaired = make('native-repaired', true);
  const again = make('native-resumed-invalid', false), external = make('external-edits', true);
  for (const d of [edits, repaired, again, external]) { checkStop(d); checkInspect(d); }
  checkLanded(edits); checkLanded(repaired); checkResumedInvalid(again); checkLanded(external);
  if (kind === 'good') { console.log('k-review-invalid-resume observer good'); return; }
  assert.equal(kind, 'bad');
  const bad = (fn, d, mutate) => { const c = structuredClone(d); mutate(c); assert.throws(() => fn(c), undefined, `accepted a known-bad fixture: ${fn.name} ${mutate}`); };
  // Today's behavior on the provider route: a tool-boundary stop that inspect reports unsupported.
  bad(checkStop, edits, d => { d.parent.continuation = { stage: 'tool', owner: 'review' }; });
  bad(checkStop, edits, d => { d.parent.review_only[0] = { eligible: false, review: 2, why: 'the candidate changed after its green pass' }; });
  bad(checkStop, repaired, d => { d.parent.continuation.pass = { n: 2, green: false, tree: O }; });
  bad(checkStop, edits, d => { d.app_after_stop = 'candidate\n'; });
  bad(checkStop, edits, d => { d.stop.stdout = 'landed fixture abc\n'; });
  bad(checkStop, edits, d => { d.parent.review_only[0].next = 'automatic'; });
  bad(checkInspect, edits, d => { d.inspect.stdout = d.inspect.stdout.replace('potentially_available', 'unsupported'); });
  bad(checkInspect, edits, d => { d.inspect.stdout = d.inspect.stdout.replace(/kogen intent resume .*\n/, ''); });
  bad(checkLanded, edits, d => { d.resume = { exit: 1, stdout: 'candidate/resume_refused: Build p1: uncertain tool boundary; inspect effects before starting a freshly approved Build\n' }; delete d.child; });
  bad(checkLanded, edits, d => { d.resume.stdout = d.resume.stdout.replace(discardLine(2), ''); });
  bad(checkLanded, edits, d => { d.child.counts.pass = 1; d.child.result.passes = 2; });
  bad(checkLanded, edits, d => { d.child.counts.command = 3; });
  bad(checkLanded, edits, d => { d.new_requests = 2; });
  bad(checkLanded, edits, d => { d.fresh_review.input_items = 9; });
  bad(checkLanded, edits, d => { d.fresh_review.reused_conversation = true; });
  bad(checkLanded, edits, d => { d.fresh_review.same_material = false; });
  bad(checkLanded, repaired, d => { d.fresh_review.has_reviewer_edit = true; });
  bad(checkLanded, edits, d => { d.committed_app = 'reviewer edit'; });
  bad(checkLanded, edits, d => { d.head_tree = O; });
  bad(checkLanded, edits, d => { d.child.review_edits_discarded = []; });
  bad(checkLanded, edits, d => { d.child.review_retry_events.push({ kind: 'automatic', from_review: 3, review: 4, tree: T }); });
  bad(checkLanded, external, d => { d.new_builder_rounds = 1; });
  bad(checkLanded, external, d => { d.new_review_sessions = 2; });
  bad(checkResumedInvalid, again, d => { d.new_review_requests = 4; d.new_requests = 4; d.child.result.reviews = 4; });
  bad(checkResumedInvalid, again, d => { d.commits = '1'; });
  bad(checkResumedInvalid, again, d => { d.child.continuation.stage = 'tool'; });
  bad(checkResumedInvalid, again, d => { d.child_inspect.stdout = '  resume: unsupported (not authorization)\n'; });
  console.log('k-review-invalid-resume observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  const STEP = { timeout: 300000 };
  When('the k-review-invalid-resume driver observes {string}', STEP, function (mode) { this.krir = observe(mode); });
  Then('the Build stopped with review_invalid and a review-only checkpoint of the green candidate, the reviewer\'s edits left in place', function () { checkStop(this.krir); });
  Then('kogen intent inspect reports the stopped Build\'s resume as potentially available', function () { checkInspect(this.krir); });
  Then('its resume discarded the stopped review\'s edits, ran only one fresh review of the unchanged green candidate and landed it', function () { checkLanded(this.krir); });
  Then('its resume discarded the stopped review\'s edits and the fresh review\'s invalid ending stopped again with no automatic retry and nothing committed', function () { checkResumedInvalid(this.krir); });
}
