'use strict';
// K-REVIEW-SOURCE-BOUND acceptance: the real Build over the real Claude Code adapter, against a
// scripted fake `claude` (k_review_source_bound_driver.go, mounted as a test with go -overlay),
// for both the build and the review role. The steps assert the facts the driver observed: the
// exact first prompts the fake received, the retained review material and the Build's result.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const FIXTURES = ['small', 'six', 'repro', 'large', 'part1-block', 'part2-block', 'authority', 'refusal'];
let observed;

// Runs every fixture once, in one go test, and keeps the facts by fixture name.
function observe(fixture) {
  if (!observed) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-krsb-'));
    fs.chmodSync(dir, 0o700);
    try {
      const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
      fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/build/k_review_source_bound_acceptance_test.go')]: path.join(__dirname, 'k_review_source_bound_driver.go') } }), { mode: 0o600 });
      const r = spawnSync('go', ['test', '-overlay', overlay, './build', '-run', '^TestKReviewSourceBoundObservation$', '-count=1'], {
        cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 280000, maxBuffer: 16 * 1024 * 1024,
        env: { ...process.env, KOGEN_KRSB_MODES: FIXTURES.join(','), KOGEN_KRSB_OUTPUT: output, GOWORK: 'off', GOPROXY: 'off', GOTOOLCHAIN: 'local' },
      });
      assert.ifError(r.error);
      // Go success alone is not proof: the driver must have written the facts of every fixture.
      assert.ok(fs.existsSync(output), `the observation driver wrote no facts (go test exit ${r.status}):\n${r.stdout}\n${r.stderr}`);
      observed = { facts: JSON.parse(fs.readFileSync(output, 'utf8')), log: `${r.stdout}\n${r.stderr}` };
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  }
  const d = observed.facts[fixture];
  assert.ok(d && d.mode === fixture && 'exit' in d && 'outcome' in d, `no complete facts for fixture ${fixture}; driver output:\n${observed.log.slice(-4000)}`);
  return d;
}

const list = v => (Array.isArray(v) ? v : []);

function checkLanded(d) {
  assert.equal(d.exit, 0, `the Build did not land:\n${d.stdout}`);
  assert.equal(d.outcome, 'landed');
  assert.equal(d.commits, '1', 'exactly one new commit');
  assert.ok(d.stdout.includes('review: approved'), d.stdout);
}
function checkInline(d, ceiling) {
  assert.equal(d.review_sessions, 1, 'one review session');
  assert.equal(d.review_sessions_fresh, true, 'the review session is its own, not the builder\'s');
  assert.equal(d.inline_exact, true, 'the review prompt is the review constraints, the authority and the complete source, unchanged');
  assert.ok(list(d.review_prompt_bytes).length === 1 && d.review_prompt_bytes[0] <= ceiling, `review prompt bytes ${d.review_prompt_bytes} within ${ceiling}`);
  assert.equal(d.authority_in_every_prompt, true, 'the prompt carries the Intent and its feature');
  assert.equal(d.parts, 0, 'no review parts');
  assert.deepEqual(list(d.review_parts_events), [], 'no review_parts event');
}
function checkParts(d, atLeast, n, ceiling) {
  if (atLeast) assert.ok(d.parts >= n, `at least ${n} review parts, got ${d.parts}`);
  else assert.equal(d.parts, n, `review parts`);
  assert.equal(d.review_sessions, d.parts, 'one review session per part');
  assert.equal(d.review_sessions_fresh, true, 'every part session is fresh and none is the builder\'s');
  const sizes = list(d.review_prompt_bytes);
  assert.equal(sizes.length, d.parts);
  for (const s of sizes) assert.ok(s <= ceiling, `a review prompt of ${s} bytes exceeds ${ceiling}`);
  assert.equal(d.parts_exact_prompts, true, 'each part prompt is the review constraints, the authority file and that part file, exactly');
  assert.equal(d.parts_headed, true, 'each part file starts with "# Review part k of N"');
  assert.equal(d.parts_prompt_bytes_recorded, true, 'review_parts records each prompt\'s exact bytes and session');
  assert.equal(d.parts_delivered, true, 'every part is recorded as delivered');
  assert.equal(d.authority_in_every_prompt, true, 'every part prompt carries the Intent and its feature');
  assert.deepEqual(list(d.review_parts_events), [d.parts], 'one review_parts event naming the part count');
}
function checkSlices(d) {
  assert.equal(d.parts_contiguous, true, 'the parts cover the complete source in order without gaps or overlaps');
  assert.equal(d.parts_carry_slices, true, 'each part file carries its exact source slice');
}
function checkWhole(d) {
  assert.deepEqual(list(d.blocks_split), [], 'changed files that fit one part are never split');
}
function checkLines(d) {
  assert.ok(d.parts > 1, 'the source was split');
  assert.equal(d.slices_ending_mid_line, 0, 'a part that ends inside a file ends at a line boundary');
}
function checkStopped(d, result, line) {
  assert.equal(d.exit, 1, d.stdout);
  assert.ok(d.stdout.includes(result), `missing ${result}:\n${d.stdout}`);
  assert.ok(d.stdout.includes(line), `missing ${line}:\n${d.stdout}`);
  assert.equal(d.commits, '0', 'nothing committed');
  assert.equal(d.head_same, true, 'HEAD unchanged');
  assert.equal(d.candidate_kept, true, 'the candidate files are kept');
}
function checkSessions(d, n) {
  assert.equal(d.review_sessions, n, 'review sessions started');
}
function checkBlockedInParts(d, n) {
  assert.equal(d.outcome, 'review_blocked');
  assert.ok(d.parts >= 2, 'the review was in parts');
  checkSessions(d, n);
}
function checkTooLarge(d, ceiling) {
  checkStopped(d, 'candidate/context_budget_exceeded: review: mandatory', 'nothing was sent');
  assert.equal(d.outcome, 'context_budget_exceeded');
  assert.ok(d.stdout.includes(String(ceiling)), `the stop names the ${ceiling}-byte ceiling:\n${d.stdout}`);
  checkSessions(d, 0);
}
function checkRefused(d) {
  checkStopped(d, 'candidate/context_budget_exceeded: ', 'blocking_limit');
  assert.ok(!d.stdout.includes('executor/failed'), `reported as an ordinary executor failure:\n${d.stdout}`);
  assert.equal(d.outcome, 'context_budget_exceeded');
  assert.deepEqual(list(d.round_failed_reasons), ['context_budget_exceeded'], 'the run log records the refused round as context_budget_exceeded');
  checkSessions(d, 1);
}

// Known-good and known-bad controls of the checks above (Feasibility observer).
function controls(kind) {
  const C = 524288;
  const out = 'building fixture\nlanded fixture 1 (Build 2)\n  review: approved\n';
  const small = { mode: 'small', exit: 0, outcome: 'landed', commits: '1', stdout: out, review_sessions: 1, review_sessions_fresh: true, inline_exact: true,
    review_prompt_bytes: [19793], authority_in_every_prompt: true, parts: 0, review_parts_events: null };
  const six = { mode: 'six', exit: 0, outcome: 'landed', commits: '1', stdout: out, parts: 2, review_sessions: 2, review_sessions_fresh: true,
    review_prompt_bytes: [491000, 258000], parts_exact_prompts: true, parts_headed: true, parts_prompt_bytes_recorded: true, parts_delivered: true,
    authority_in_every_prompt: true, review_parts_events: [2], parts_contiguous: true, parts_carry_slices: true, blocks_split: null, slices_ending_mid_line: 0 };
  const large = { ...six, mode: 'large', parts: 3, review_sessions: 3, review_prompt_bytes: [524288, 524000, 220000], review_parts_events: [3] };
  const blocked = { mode: 'part2-block', exit: 1, outcome: 'review_blocked', commits: '0', head_same: true, candidate_kept: true, parts: 2, review_sessions: 2,
    stdout: 'candidate/review_blocked: the reviewer could not resolve a substantive blocker within the approved Intent; edits are left in place\n  review: big-1.txt:1: part blocker\n' };
  const tooLarge = { mode: 'authority', exit: 1, outcome: 'context_budget_exceeded', commits: '0', head_same: true, candidate_kept: true, review_sessions: 0,
    stdout: 'candidate/context_budget_exceeded: review: mandatory review prompt of executor claude-code is 633000 bytes without candidate source, under the inclusive 524288-byte ceiling; nothing was sent\n' };
  const refused = { mode: 'refusal', exit: 1, outcome: 'context_budget_exceeded', commits: '0', head_same: true, candidate_kept: true, review_sessions: 1,
    round_failed_reasons: ['context_budget_exceeded'],
    stdout: 'candidate/context_budget_exceeded: Claude Code refused the review prompt as too long for its context (terminal reason "blocking_limit": Prompt is too long)\n' };
  const good = () => {
    checkLanded(small); checkInline(small, C);
    checkLanded(six); checkParts(six, false, 2, C); checkSlices(six); checkWhole(six);
    checkLanded(large); checkParts(large, true, 3, C); checkSlices(large); checkLines(large);
    checkStopped(blocked, 'candidate/review_blocked', 'review: big-1.txt:1: part blocker'); checkBlockedInParts(blocked, 2);
    checkTooLarge(tooLarge, C); checkRefused(refused);
  };
  good();
  if (kind === 'good') { console.log('krsb observer good'); return; }
  assert.equal(kind, 'bad');
  const bad = (fn, d, mutate, ...args) => { const c = structuredClone(d); mutate(c); assert.throws(() => fn(c, ...args), `accepted a known-bad fixture: ${fn.name}`); };
  // Today's behavior: one oversized inline prompt.
  bad(checkParts, six, d => { d.parts = 0; d.review_sessions = 1; d.review_prompt_bytes = [723764]; d.review_parts_events = null; }, false, 2, C);
  bad(checkParts, six, d => { d.review_prompt_bytes = [524289, 200000]; }, false, 2, C);
  bad(checkParts, six, d => { d.review_sessions = 1; d.review_prompt_bytes = [491000]; }, false, 2, C);
  bad(checkParts, six, d => { d.review_sessions_fresh = false; }, false, 2, C);
  bad(checkParts, six, d => { d.parts_exact_prompts = false; }, false, 2, C);
  bad(checkParts, six, d => { d.authority_in_every_prompt = false; }, false, 2, C);
  bad(checkParts, six, d => { d.parts_delivered = false; }, false, 2, C);
  bad(checkParts, six, d => { d.parts = 3; d.review_sessions = 3; d.review_prompt_bytes = [1, 2, 3]; d.review_parts_events = [3]; }, false, 2, C);
  bad(checkParts, large, d => { d.parts = 2; d.review_sessions = 2; d.review_prompt_bytes = [1, 2]; d.review_parts_events = [2]; }, true, 3, C);
  bad(checkSlices, six, d => { d.parts_contiguous = false; });
  bad(checkSlices, six, d => { d.parts_carry_slices = false; });
  bad(checkWhole, six, d => { d.blocks_split = ['big-5.txt']; });
  bad(checkLines, large, d => { d.slices_ending_mid_line = 1; });
  bad(checkLanded, six, d => { d.exit = 1; d.outcome = 'failed'; d.commits = '0'; });
  bad(checkLanded, six, d => { d.commits = '2'; });
  bad(checkInline, small, d => { d.inline_exact = false; }, C);
  bad(checkInline, small, d => { d.parts = 2; d.review_sessions = 2; d.review_prompt_bytes = [10000, 10000]; }, C);
  bad(checkBlockedInParts, blocked, d => { d.review_sessions = 3; }, 2);
  bad(checkBlockedInParts, blocked, d => { d.parts = 0; }, 2);
  bad(checkStopped, blocked, d => { d.commits = '1'; }, 'candidate/review_blocked', 'review: big-1.txt:1: part blocker');
  bad(checkStopped, blocked, d => { d.candidate_kept = false; }, 'candidate/review_blocked', 'review: big-1.txt:1: part blocker');
  bad(checkTooLarge, tooLarge, d => { d.review_sessions = 1; }, C);
  bad(checkTooLarge, tooLarge, d => { d.stdout = 'executor/failed: Claude Code reported an error result\n'; d.outcome = 'failed'; }, C);
  bad(checkTooLarge, tooLarge, d => { d.stdout = d.stdout.replace('nothing was sent', ''); }, C);
  // Today's behavior: the refusal is an ordinary executor failure.
  bad(checkRefused, refused, d => { d.stdout = 'executor/failed: Claude Code reported an error result: subtype "success", terminal reason "blocking_limit"\n'; d.outcome = 'failed'; d.round_failed_reasons = ['failed']; });
  bad(checkRefused, refused, d => { d.round_failed_reasons = ['failed']; });
  bad(checkRefused, refused, d => { d.commits = '1'; });
  console.log('krsb observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  const STEP = { timeout: 300000 };
  When('the krsb Build runs the fixture {string}', STEP, function (fixture) { this.krsb = observe(fixture); });
  Then('the krsb Build landed one commit after an approving review', function () { checkLanded(this.krsb); });
  Then('the krsb review used one session whose prompt carried the complete authority and source inline within {int} bytes', function (c) { checkInline(this.krsb, c); });
  Then('the krsb review was cut into {int} parts, each sent to its own fresh session within {int} bytes with the complete authority', function (n, c) { checkParts(this.krsb, false, n, c); });
  Then('the krsb review was cut into at least {int} parts, each sent to its own fresh session within {int} bytes with the complete authority', function (n, c) { checkParts(this.krsb, true, n, c); });
  Then('the krsb parts carry the exact review source in order without clipping', function () { checkSlices(this.krsb); });
  Then('no krsb changed file that fits one part was split across parts', function () { checkWhole(this.krsb); });
  Then('every krsb part that ends inside a file ends at a line boundary', function () { checkLines(this.krsb); });
  Then('the krsb Build stopped with {string} and {string}, committed nothing and kept the candidate files', function (result, line) { checkStopped(this.krsb, result, line); });
  Then('the krsb review was in parts and stopped as review_blocked after {int} review session(s)', function (n) { checkBlockedInParts(this.krsb, n); });
  Then('the krsb Build stopped before sending any review, naming the mandatory review material and the {int}-byte ceiling', function (c) { checkTooLarge(this.krsb, c); });
  Then('the krsb Build reported the refusal as a context result naming blocking_limit, never as an executor failure', function () { checkRefused(this.krsb); });
}
