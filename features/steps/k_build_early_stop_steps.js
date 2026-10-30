'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const cache = new Map();

const MISSING = ['failed: Second (line 4)', 'failed: Third (line 6)'];
const NOTICE = 'Required acceptance items are still missing: verification pass 2 is the same red as the pass before it, ' +
  'and your last round ended without a tool call. The Build is not complete until each of these acceptance scenarios passes:\n' +
  '- failed: Second (line 4)\n- failed: Third (line 6)\n' +
  'Work on them now with your tools (write the missing tests and the implementation they need), then call finish. ' +
  'Another round without a tool call into the same red stops the Build as no_progress.\n\n' +
  'Verification pass 2 is not green.';
const NOTICE_HEAD = 'Required acceptance items are still missing';
const STOP_AFTER_NOTICE = 'candidate/no_progress: the builder was told which required acceptance items are missing and answered again ' +
  'without a tool call; verification pass 3 is the same red as the pass before it; edits are left in place\n';
const STOP_PLAIN = 'candidate/no_progress: the builder answered the failure feedback without a tool call, and verification pass 2 ' +
  'is the same red as the pass before it; edits are left in place\n';

function put(file, bytes) {
  fs.writeFileSync(file, bytes, { mode: 0o600 });
  fs.chmodSync(file, 0o600);
}
// Runs the observation driver, mounted as a test with go -overlay, once per mode.
function observe(mode) {
  if (cache.has(mode)) return cache.get(mode);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-kbes-'));
  fs.chmodSync(dir, 0o700);
  try {
    const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    put(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/build/k_build_early_stop_acceptance_test.go')]: path.join(__dirname, 'k_build_early_stop_driver.go') } }));
    const r = spawnSync('go', ['test', '-overlay', overlay, './build', '-run', '^TestKBuildEarlyStopObservation$', '-count=1'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 280000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_KBES_MODE: mode, KOGEN_KBES_OUTPUT: output, GOWORK: 'off', GOPROXY: 'off', GOTOOLCHAIN: 'local' },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `observation driver TestKBuildEarlyStopObservation (go test ./build, mode ${mode}) failed:\n${r.stdout}\n${r.stderr}`);
    // Go success alone is not proof: the driver must have written its observation.
    const data = JSON.parse(fs.readFileSync(output, 'utf8'));
    assert.equal(data.mode, mode);
    cache.set(mode, data);
    return data;
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

function oneNotice(d) {
  assert.equal(d.notices.length, 1, `exactly one missing_items_notice event, got ${JSON.stringify(d.notices)}`);
  assert.equal(d.notices[0].pass, 2, 'the notice answers verification pass 2');
  assert.deepEqual(d.notices[0].missing, MISSING);
  assert.equal(d.inputs.length >= 2, true, `the builder received ${d.inputs.length + 1} requests`);
  assert.ok(!d.inputs[0].includes(NOTICE_HEAD), 'the first red pass gets ordinary feedback only');
  assert.ok(d.inputs[1].startsWith(NOTICE), `the builder was not told the missing items before pass 2's feedback:\n${d.inputs[1].slice(0, 1200)}`);
  assert.ok(!d.inputs[1].includes('First (line 2)'), 'the passing scenario is not named as missing');
}
function checkRepair(d) {
  assert.equal(d.mode, 'partial-then-repair');
  assert.equal(d.exit, 0, d.stdout);
  assert.equal(d.outcome, 'landed');
  assert.equal(d.passes, 3);
  assert.equal(d.requests, 3, `the builder got ${d.requests} model requests`);
  oneNotice(d);
  assert.equal(d.candidate, 'all\n');
  assert.equal(d.head_same, false, 'the repaired candidate was committed');
}
function checkStuck(d) {
  assert.equal(d.mode, 'partial-stuck');
  assert.equal(d.exit, 1, d.stdout);
  assert.equal(d.outcome, 'no_progress');
  assert.equal(d.passes, 3, `passes ${d.passes}: the Build stops on the first identical red after the notice`);
  assert.equal(d.requests, 3, `the builder got ${d.requests} model requests; no endless loop`);
  oneNotice(d);
  assert.ok(d.stdout.includes(STOP_AFTER_NOTICE), d.stdout);
  assert.ok(d.stdout.includes('  failing: acceptance\n  missing: failed: Second (line 4)\n  missing: failed: Third (line 6)\n'), d.stdout);
  assert.ok(!d.stdout.includes('missing: failed: First'), d.stdout);
  assert.equal(d.candidate, 'one\n', 'edits are left in place');
  assert.equal(d.head_same, true, 'nothing was committed');
}
function checkChecksOnly(d) {
  assert.equal(d.mode, 'checks-only');
  assert.equal(d.exit, 1, d.stdout);
  assert.equal(d.outcome, 'no_progress');
  assert.equal(d.passes, 2);
  assert.equal(d.requests, 2, `the builder got ${d.requests} model requests`);
  assert.deepEqual(d.notices, []);
  assert.ok(d.inputs.every(s => !s.includes(NOTICE_HEAD)), 'no missing-items notice without missing acceptance items');
  assert.ok(d.stdout.includes(STOP_PLAIN), d.stdout);
  assert.ok(d.stdout.includes('  failing: done\n'), d.stdout);
  assert.ok(!d.stdout.includes('  missing: '), d.stdout);
  assert.equal(d.candidate, 'one\n');
  assert.equal(d.head_same, true);
}

function controls(kind) {
  const notice = { event: 'missing_items_notice', pass: 2, missing: MISSING };
  const pass1 = 'Verification pass 1 is not green. Fix the implementation (the approved acceptance files cannot change), then call finish again.\n  failed: Second (line 4)';
  const repair = { mode: 'partial-then-repair', exit: 0, stdout: 'building fixture\nlanded\n', outcome: 'landed', passes: 3, requests: 3,
    inputs: [pass1, NOTICE + ' Fix the implementation.'], notices: [notice], head_same: false, candidate: 'all\n' };
  const stuck = { mode: 'partial-stuck', exit: 1, outcome: 'no_progress', passes: 3, requests: 3, inputs: [pass1, NOTICE + ' Fix.'],
    notices: [notice], head_same: true, candidate: 'one\n',
    stdout: 'failed fixture: no_progress (Build x)\n' + STOP_AFTER_NOTICE + '  candidate tree: abc\n  failing: acceptance\n  missing: failed: Second (line 4)\n  missing: failed: Third (line 6)\n  No further verification\n' };
  const only = { mode: 'checks-only', exit: 1, outcome: 'no_progress', passes: 2, requests: 2, inputs: ['Verification pass 1 is not green.\ncheck done'],
    notices: [], head_same: true, candidate: 'one\n', stdout: STOP_PLAIN + '  candidate tree: abc\n  failing: done\n  No further verification\n' };
  checkRepair(repair); checkStuck(stuck); checkChecksOnly(only);
  if (kind === 'good') { console.log('k-build-early-stop observer accepted good fixtures'); return; }
  assert.equal(kind, 'bad');
  const bad = (fn, d, mutate) => { const c = structuredClone(d); mutate(c); assert.throws(() => fn(c), 'accepted a known-bad fixture'); };
  // The old behavior: a stop at the first tool-free identical red, without a notice.
  bad(checkStuck, stuck, d => { d.passes = 2; d.requests = 2; d.notices = []; d.inputs = [pass1]; d.stdout = STOP_PLAIN + '  failing: acceptance\n'; });
  bad(checkRepair, repair, d => { d.exit = 1; d.outcome = 'no_progress'; d.passes = 2; d.requests = 2; d.notices = []; d.inputs = [pass1]; d.candidate = 'one\n'; d.head_same = true; });
  // An endless loop or a stop without naming the missing items.
  bad(checkStuck, stuck, d => { d.requests = 13; d.passes = 13; });
  bad(checkStuck, stuck, d => { d.stdout = d.stdout.replace('  missing: failed: Second (line 4)\n', ''); });
  bad(checkStuck, stuck, d => { d.stdout = d.stdout.replace('  missing: failed: Second (line 4)\n', '  missing: failed: First (line 2)\n  missing: failed: Second (line 4)\n'); });
  bad(checkStuck, stuck, d => { d.stdout = d.stdout.replace(STOP_AFTER_NOTICE, STOP_PLAIN); });
  bad(checkStuck, stuck, d => { d.head_same = false; });
  bad(checkStuck, stuck, d => { d.candidate = 'baseline\n'; });
  // A notice that is missing, repeated, misplaced or names the wrong items.
  bad(checkRepair, repair, d => { d.notices = []; });
  bad(checkRepair, repair, d => { d.notices.push(notice); });
  bad(checkRepair, repair, d => { d.notices[0].pass = 3; });
  bad(checkRepair, repair, d => { d.notices[0].missing = ['failed: First (line 2)', ...MISSING]; });
  bad(checkRepair, repair, d => { d.inputs[1] = 'Verification pass 2 is not green.\n' + NOTICE; });
  bad(checkRepair, repair, d => { d.inputs[1] = d.inputs[1].replace('- failed: Third (line 6)\n', ''); });
  bad(checkRepair, repair, d => { d.inputs[1] += '\n- failed: First (line 2)'; });
  bad(checkRepair, repair, d => { d.inputs[0] = NOTICE; });
  bad(checkRepair, repair, d => { d.requests = 4; });
  bad(checkRepair, repair, d => { d.head_same = true; });
  // Without missing acceptance items the stop stays immediate and unchanged.
  bad(checkChecksOnly, only, d => { d.passes = 3; d.requests = 3; });
  bad(checkChecksOnly, only, d => { d.notices = [{ event: 'missing_items_notice', pass: 2, missing: [] }]; });
  bad(checkChecksOnly, only, d => { d.stdout = d.stdout.replace(STOP_PLAIN, STOP_AFTER_NOTICE); });
  bad(checkChecksOnly, only, d => { d.stdout += '  missing: failed: done\n'; });
  bad(checkChecksOnly, only, d => { d.inputs.push(NOTICE); });
  console.log('k-build-early-stop observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  const STEP = { timeout: 300000 };
  When('the early-stop fake builder writes one of three required scenarios and then answers without a tool call in the case {string}', STEP, function (mode) { this.kbes = observe(mode); });
  When('the early-stop fake builder breaks a configured check while acceptance stays green and then answers without a tool call in the case {string}', STEP, function (mode) { this.kbes = observe(mode); });
  Then('the builder was told the missing scenarios Second and Third once, wrote them, and the Build landed', function () { checkRepair(this.kbes); });
  Then('the Build stopped as no_progress on the next identical red after the notice, naming the missing scenarios Second and Third', function () { checkStuck(this.kbes); });
  Then('the Build stopped as no_progress at the first identical red without a missing-items notice, as before', function () { checkChecksOnly(this.kbes); });
}
