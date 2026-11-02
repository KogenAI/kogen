'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const MODES = ['native-env', 'native-ordinary', 'native-not-in-a-row', 'external-env'];
let observed;

const FAILURE = 'panic: test timed out after 10m0s';
const stopHead = (a, b) => `environment/host_or_base_failure: check go-test failed the same way in verification passes ${a} and ${b}: ` +
  `${FAILURE}; this failure is in the host or the base, not in the candidate, so no further builder round was requested; edits are left in place\n`;
const ORDINARY = '--- FAIL: TestAppIsReady (0.00s)';

function put(file, bytes) {
  fs.writeFileSync(file, bytes, { mode: 0o600 });
  fs.chmodSync(file, 0o600);
}
// Runs the observation driver, mounted as a test with go -overlay, once: every mode is a subtest.
function observe() {
  if (observed) return observed;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-kefp-'));
  fs.chmodSync(dir, 0o700);
  try {
    const overlay = path.join(dir, 'overlay.json');
    put(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli/build/k_env_failure_park_acceptance_test.go')]: path.join(__dirname, 'k_env_failure_park_driver.go') } }));
    const r = spawnSync('go', ['test', '-overlay', overlay, './build', '-run', '^TestKEnvFailureParkObservation$', '-count=1', '-timeout=100s'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 110000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_KEFP_OUTPUT: dir, GOWORK: 'off', GOPROXY: 'off', GOTOOLCHAIN: 'local' },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `observation driver TestKEnvFailureParkObservation (go test ./build) failed:\n${r.stdout}\n${r.stderr}`);
    // Go success alone is not proof: the driver must have written every mode's observation.
    const data = {};
    for (const mode of MODES) {
      data[mode] = JSON.parse(fs.readFileSync(path.join(dir, mode + '.json'), 'utf8'));
      assert.equal(data[mode].mode, mode);
    }
    observed = data;
    return data;
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

// stoppedAt checks the host-or-base stop after passes a and b, with no builder request after b.
function stoppedAt(d, a, b, candidate) {
  const out = d.stdout;
  assert.equal(d.exit, 3, `exit ${d.exit}, want 3:\n${out}`);
  assert.equal(d.outcome, 'host_or_base_failure', `outcome ${d.outcome}:\n${out}`);
  assert.equal(d.passes, b, `the Build ran ${d.passes} verification passes; it must stop after pass ${b}`);
  assert.equal(d.rounds, b, `the builder got ${d.rounds} requests/rounds; after pass ${b} no further builder request may be made`);
  assert.equal(d.inputs.length, b - 1, `the builder received ${d.inputs.length} feedback messages, want ${b - 1}`);
  assert.deepEqual(d.events, [{ event: 'host_or_base_failure', check: 'go-test', failure: FAILURE, passes: [a, b] }]);
  assert.ok(out.includes(`failed fixture: host_or_base_failure (Build `), out);
  const head = stopHead(a, b);
  const at = out.indexOf(head);
  assert.ok(at >= 0, `the stop does not name the check, the repeated failure and its passes:\n${out}`);
  const lines = out.slice(at + head.length).split('\n');
  assert.equal(lines[0], `  check: go-test (${d.command})`, out);
  assert.equal(lines[1], `  failure: ${FAILURE}`, out);
  assert.match(lines[2], new RegExp(`^  evidence: go-test output of verification passes ${a} and ${b} in /.+/\\.kogen/local/runs/[0-9a-f]{8}/log\\.jsonl$`), out);
  assert.match(lines[3], /^  candidate tree: [0-9a-f]{40}$/, out);
  assert.ok(lines[4].startsWith('  No further builder round was requested.'), out);
  assert.deepEqual(d.still_failing, ['go-test']);
  assert.equal(d.head_same, true, 'nothing was committed');
  assert.equal(d.candidate, candidate, 'the candidate is left in place');
}

function checkNativeEnv(d) {
  assert.equal(d.mode, 'native-env');
  stoppedAt(d, 1, 2, 'slow-2\n');
  assert.ok(d.inputs[0].startsWith('Verification pass 1 is not green.') && d.inputs[0].includes(FAILURE), 'the first timed-out pass still goes to the builder as feedback');
}
function checkExternalEnv(d) {
  assert.equal(d.mode, 'external-env');
  stoppedAt(d, 1, 2, 'slow-2\n');
  assert.ok(d.inputs[0].startsWith('Verification pass 1 is not green.') && d.inputs[0].includes(FAILURE), 'the first timed-out pass still goes to the executor as feedback');
}
function checkNotInARow(d) {
  assert.equal(d.mode, 'native-not-in-a-row');
  stoppedAt(d, 3, 4, 'slow-4\n');
  assert.ok(d.inputs[0].includes(FAILURE) && !d.inputs[0].includes(ORDINARY), 'pass 1 timed out');
  assert.ok(d.inputs[1].includes(ORDINARY) && !d.inputs[1].includes(FAILURE), 'pass 2 is an ordinary test failure');
  assert.ok(d.inputs[2].startsWith('Verification pass 3 is not green.') && d.inputs[2].includes(FAILURE), 'pass 3 timed out after an ordinary failure, which is not two in a row');
}
function checkOrdinary(d) {
  assert.equal(d.mode, 'native-ordinary');
  assert.equal(d.exit, 0, d.stdout);
  assert.equal(d.outcome, 'landed', d.stdout);
  assert.equal(d.passes, 3);
  assert.equal(d.rounds, 3, `the builder got ${d.rounds} requests; an ordinary test failure repeated twice still gets builder rounds`);
  assert.equal(d.inputs.length, 2);
  for (const [i, input] of d.inputs.entries()) {
    assert.ok(input.startsWith(`Verification pass ${i + 1} is not green.`) && input.includes(ORDINARY), `feedback ${i + 1}: ${input.slice(0, 400)}`);
  }
  assert.deepEqual(d.events, []);
  assert.ok(!d.stdout.includes('host_or_base_failure'), d.stdout);
  assert.equal(d.head_same, false, 'the repaired candidate was committed');
  assert.equal(d.candidate, 'ready\n');
}

function controls(kind) {
  const cmd = "sh '/tmp/x/go-test.sh'";
  const timed = n => `Verification pass ${n} is not green. Fix the implementation (the approved acceptance files cannot change), then call finish again.\ncheck go-test (${cmd}): failed, exit status 1\n  ${FAILURE}`;
  const plain = n => `Verification pass ${n} is not green. Fix the implementation (the approved acceptance files cannot change), then call finish again.\ncheck go-test (${cmd}): failed, exit status 1\n  ${ORDINARY}`;
  const stop = (a, b) => `building fixture\nfailed fixture: host_or_base_failure (Build abcd1234)\n${stopHead(a, b)}  check: go-test (${cmd})\n  failure: ${FAILURE}\n` +
    `  evidence: go-test output of verification passes ${a} and ${b} in /tmp/r/.kogen/local/runs/abcd1234/log.jsonl\n  candidate tree: ${'a'.repeat(40)}\n` +
    `  No further builder round was requested. Fix the host or the base, then resume or start a fresh Build.\n  still failing: go-test\n       after output:\n         ${FAILURE}\n`;
  const ev = (a, b) => [{ event: 'host_or_base_failure', check: 'go-test', failure: FAILURE, passes: [a, b] }];
  const env = { mode: 'native-env', command: cmd, exit: 3, outcome: 'host_or_base_failure', passes: 2, rounds: 2, inputs: [timed(1)],
    events: ev(1, 2), stdout: stop(1, 2), still_failing: ['go-test'], head_same: true, candidate: 'slow-2\n' };
  const ext = { ...structuredClone(env), mode: 'external-env' };
  const row = { mode: 'native-not-in-a-row', command: cmd, exit: 3, outcome: 'host_or_base_failure', passes: 4, rounds: 4, inputs: [timed(1), plain(2), timed(3)],
    events: ev(3, 4), stdout: stop(3, 4), still_failing: ['go-test'], head_same: true, candidate: 'slow-4\n' };
  const ord = { mode: 'native-ordinary', command: cmd, exit: 0, outcome: 'landed', passes: 3, rounds: 3, inputs: [plain(1), plain(2)], events: [],
    stdout: 'building fixture\nlanded fixture 83ec2072 (Build abcd1234)\n', still_failing: null, head_same: false, candidate: 'ready\n' };
  checkNativeEnv(env); checkExternalEnv(ext); checkNotInARow(row); checkOrdinary(ord);
  if (kind === 'good') { console.log('k-env-failure-park observer accepted good fixtures'); return; }
  assert.equal(kind, 'bad');
  const bad = (fn, d, mutate) => { const c = structuredClone(d); mutate(c); assert.throws(() => fn(c), `accepted a known-bad ${d.mode} fixture`); };
  // The old behavior: the timed-out check keeps getting builder rounds until another limit ends the Build.
  const old = d => { d.exit = 4; d.outcome = 'refused'; d.passes = 5; d.rounds = 6; d.inputs = [timed(1), timed(2), timed(3), timed(4), timed(5)]; d.events = []; d.candidate = 'slow-5\n';
    d.stdout = 'failed fixture: refused (Build abcd1234)\nprovider/refused: ChatGPT refused the request: 400 scripted provider refusal\n'; };
  bad(checkNativeEnv, env, old);
  bad(checkExternalEnv, ext, d => { old(d); d.exit = 1; d.outcome = 'executor_round_limit'; d.passes = 6; d.rounds = 6; });
  bad(checkNotInARow, row, d => { old(d); d.passes = 7; d.rounds = 8; });
  // One more builder request, a stop one pass early or late, or a wrong exit or outcome.
  bad(checkNativeEnv, env, d => { d.rounds = 3; });
  bad(checkNativeEnv, env, d => { d.inputs.push(timed(2)); });
  bad(checkNativeEnv, env, d => { d.passes = 1; d.rounds = 1; d.inputs = []; });
  bad(checkNativeEnv, env, d => { d.exit = 1; });
  bad(checkNativeEnv, env, d => { d.outcome = 'no_progress'; });
  bad(checkNativeEnv, env, d => { d.stdout = d.stdout.replace('environment/host_or_base_failure', 'candidate/no_progress'); });
  // A stop that does not name the check, the repeated failure, the passes or the evidence.
  bad(checkNativeEnv, env, d => { d.stdout = d.stdout.replace('  check: go-test', '  check: test'); });
  bad(checkNativeEnv, env, d => { d.stdout = d.stdout.replace(`  failure: ${FAILURE}\n`, '  failure: exit status 1\n'); });
  bad(checkNativeEnv, env, d => { d.stdout = d.stdout.replace('  evidence: go-test output of verification passes 1 and 2 in /tmp/r/.kogen/local/runs/abcd1234/log.jsonl\n', ''); });
  bad(checkNativeEnv, env, d => { d.stdout = d.stdout.replace('passes 1 and 2:', 'passes 0 and 2:'); });
  bad(checkNativeEnv, env, d => { d.events = []; });
  bad(checkNativeEnv, env, d => { d.events = [...ev(1, 2), ...ev(1, 2)]; });
  bad(checkNativeEnv, env, d => { d.events[0].failure = 'timed out'; });
  // The candidate must be left in place and nothing committed.
  bad(checkNativeEnv, env, d => { d.candidate = 'baseline\n'; });
  bad(checkNativeEnv, env, d => { d.head_same = false; });
  bad(checkNativeEnv, env, d => { d.inputs = ['Verification pass 1 is not green.']; });
  bad(checkExternalEnv, ext, d => { d.rounds = 3; d.inputs.push(timed(2)); });
  // Two timeouts that are not in a row must not stop the Build.
  bad(checkNotInARow, row, d => { d.passes = 3; d.rounds = 3; d.inputs = [timed(1), plain(2)]; d.events = ev(1, 3); d.stdout = stop(1, 3); d.candidate = 'slow-3\n'; });
  bad(checkNotInARow, row, d => { d.inputs[1] = timed(2); });
  // An ordinary failure, even repeated identically, still gets builder rounds.
  bad(checkOrdinary, ord, d => { d.exit = 3; d.outcome = 'host_or_base_failure'; d.passes = 2; d.rounds = 2; d.inputs = [plain(1)]; d.events = ev(1, 2); d.stdout = stop(1, 2); d.head_same = true; d.candidate = 'ordinary-2\n'; });
  bad(checkOrdinary, ord, d => { d.rounds = 4; });
  bad(checkOrdinary, ord, d => { d.events = ev(1, 2); });
  console.log('k-env-failure-park observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  const STEP = { timeout: 115000 };
  When('the env-failure fake builders run Builds whose configured go-test check times out or fails ordinarily', STEP, function () { this.kefp = observe(); });
  Then('the native Build whose go-test check timed out in passes 1 and 2 stopped as host_or_base_failure after pass 2 without another builder request', function () { checkNativeEnv(this.kefp['native-env']); });
  Then('the external-executor Build whose go-test check timed out in passes 1 and 2 stopped as host_or_base_failure after pass 2 without another round', function () { checkExternalEnv(this.kefp['external-env']); });
  Then('the native Build whose go-test check timed out in passes 1, 3 and 4 with an ordinary failure in pass 2 stopped as host_or_base_failure after pass 4', function () { checkNotInARow(this.kefp['native-not-in-a-row']); });
  Then('the native Build whose go-test check failed the same ordinary way in passes 1 and 2 got builder rounds and landed', function () { checkOrdinary(this.kefp['native-ordinary']); });
}
