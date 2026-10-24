'use strict';
// The four production journeys. Each one runs the installed kogen against the scripted local provider and
// leaves chains of observations (see lab.js). A journey drives; it never says what the model expects. When the
// kogen under test is a mutant, deviations are recorded and the journey carries on instead of failing.
const fs = require('node:fs');
const path = require('node:path');
const { call } = require('./fake.js');
const { SLUG, PACKAGE, BASELINE, baselineHash, sleep } = require('./lab.js');

const FEATURE = `.kogen/intents/${SLUG}/acceptance.feature`;
const INTENT = `.kogen/intents/${SLUG}/intent.md`;
const APPROVAL = `.kogen/local/approvals/${SLUG}.json`;

const write = (file, content, id) => call('write_file', { path: file, content }, id);
const finish = id => call('finish', { summary: 'done' }, id);
const approve = id => call('submit_review', { verdict: 'approve', findings: [] }, id);
const changes = id => call('submit_review', { verdict: 'changes', findings: [{ path: 'hello.txt', line: 1, severity: 'blocking', message: 'The greeting is not what the Intent asks for.' }] }, id);

// The scripted provider answers by role in order; `at` is called with a label while kogen waits for the answer.
function scripted(lab, answers) {
  const counters = { build: 0, review: 0 };
  lab.fake.script = async r => {
    if (r.kind !== 'build' && r.kind !== 'review') return { status: 500 };
    const n = ++counters[r.kind];
    await lab.snap(`${r.kind === 'build' ? 'builder' : 'reviewer'}-request-${n}`);
    const answer = answers[r.kind][n - 1] || answers[r.kind][answers[r.kind].length - 1];
    return typeof answer === 'function' ? answer(r, n) : answer;
  };
  return counters;
}

// The id of the Build a command printed ("(Build 1a2b3c4d)").
const buildId = result => /\(Build ([a-f0-9]{8})\b/.exec(result.stdout)?.[1] || null;

async function approveIntent(lab) {
  const card = await lab.run(['intent', 'approve', SLUG]);
  const hash = /^SHA-256: ([a-f0-9]{64})$/m.exec(card.stdout)?.[1];
  lab.expect(hash, `kogen intent approve ${SLUG} printed no SHA-256 line (exit ${card.code})`);
  const done = await lab.run(['intent', 'approve', SLUG, hash]);
  lab.expect(done.code === 0, `kogen intent approve ${SLUG} <hash> exited ${done.code}`);
  return hash;
}

// A project with an approved Intent package, as a user leaves it after shaping.
async function approvedProject(lab) {
  lab.project({ withPackage: true });
  await approveIntent(lab);
}

// ---------------------------------------------------------------------------------------------- approval
// shape -> approve -> build start custody. A Build refuses an Intent changed after approval; the approved Intent
// then starts a Build whose first request already sees the approved baseline and an untouched HEAD; the builder
// reports an invalid blocker (feedback only) and then a valid one (the Build stops, nothing is committed).
async function approval(lab) {
  lab.project({ withPackage: false });
  // Since 2ca0e06 a shaper must inspect the repository before it submits files: read README.md first.
  lab.fake.script = async r => r.kind !== 'shape' ? { status: 500 }
    : !(r.body.input || []).some(i => i.type === 'function_call_output') ? { items: [call('read_file', { path: 'README.md' }, `inspect_${lab.fake.requests.length}`)] }
    : { items: [call('submit', { files: lab.packageFiles() }, `shape_${lab.fake.requests.length}`)] };
  const shape = await lab.run(['intent', 'shape', SLUG, '-'], { input: 'Add hello.txt saying hello\n' });
  lab.expect(shape.code === 0, `kogen intent shape exited ${shape.code}: ${shape.stderr}${shape.stdout}`);
  lab.expect(PACKAGE.every(p => fs.existsSync(path.join(lab.repo, p))), 'shaping did not write the Intent package');
  const hash = await approveIntent(lab);
  const head = lab.git(['rev-parse', 'HEAD']);
  lab.note('approved', { sha256: hash, baselineHash: baselineHash(lab.repo, BASELINE), head, approvalFile: lab.read(APPROVAL).toString('utf8').trim() });
  lab.expect(hash === baselineHash(lab.repo, BASELINE), 'the approved hash is not the hash of the baseline files');

  // The Intent is edited after approval: a Build must refuse. (A Build that does not would ask the provider.)
  const original = lab.read(INTENT);
  lab.put(INTENT, Buffer.concat([original, Buffer.from('\nAn edit after approval.\n')]));
  lab.beginChain('tampered-build');
  scripted(lab, { build: [{ items: [write('hello.txt', 'hi\n', 't1'), finish('t2')] }], review: [{ items: [approve('t3')] }] });
  const runsBefore = lab.runIds().length, requestsBefore = lab.fake.requests.length;
  const tampered = await lab.run(['intent', 'build', SLUG]);
  lab.refusal('build after an edit of the approved Intent', tampered, { newRuns: lab.runIds().length - runsBefore, providerRequests: lab.fake.requests.length - requestsBefore });
  lab.expect(tampered.code === 1 && lab.runIds().length === runsBefore && lab.fake.requests.length === requestsBefore, `a Build started on an Intent changed after approval (exit ${tampered.code})`);
  if (lab.chain.snapshots.length > 0) await lab.snap('exit');
  lab.put(INTENT, original);
  if (lab.git(['rev-parse', 'HEAD']) !== head) { lab.note('head-moved-by-tampered-build', {}); return; }

  // The approved Intent: start custody, an invalid blocker, a valid blocker.
  lab.fake.requests.length = 0;
  lab.beginChain('build');
  const blocker = paths => call('report_blocker', { paths, reason: 'The scenario cannot pass as written.', evidence: 'Observed while building.' }, `b${lab.fake.requests.length}`);
  scripted(lab, { build: [() => ({ items: [blocker(['not/a/protected/path'])] }), () => ({ items: [blocker([FEATURE])] })], review: [{ status: 500 }] });
  const built = await lab.run(['intent', 'build', SLUG]);
  lab.expect(built.code === 1 && /failed add-greeting: build_blocked/.test(built.stdout), `the blocked Build ended with exit ${built.code}: ${built.stdout}`);
  await lab.snap('exit');
  lab.expect(lab.git(['rev-parse', 'HEAD']) === head, 'HEAD moved');
}

// ---------------------------------------------------------------------------------------------- verification-review
// red pass repaired by the builder, green pass, a blocked review, an explicit resume that reopens the blocker,
// fresh verification, an approving review and the commit.
async function verificationReview(lab) {
  await approvedProject(lab);
  const head = lab.git(['rev-parse', 'HEAD']);
  lab.beginChain('build');
  scripted(lab, {
    build: [{ items: [write('hello.txt', 'wrong\n', 'w1'), finish('f1')] }, { items: [write('hello.txt', 'hi\n', 'w2'), finish('f2')] }],
    review: [{ items: [changes('r1')] }, { items: [approve('r2')] }],
  });
  const first = await lab.run(['intent', 'build', SLUG]);
  lab.expect(first.code === 1 && /failed add-greeting: review_blocked/.test(first.stdout), `the first Build ended with exit ${first.code}: ${first.stdout}`);
  await lab.snap('exit');
  const id = buildId(first);
  lab.expect(id, 'the first Build printed no id');
  lab.expect(lab.git(['rev-parse', 'HEAD']) === head, 'HEAD moved before the blocked review was reopened');
  const resumed = await lab.run(['intent', 'resume', id || '00000000']);
  lab.expect(resumed.code === 0 && /landed add-greeting /.test(resumed.stdout), `the resume ended with exit ${resumed.code}: ${resumed.stdout}${resumed.stderr}`);
  await lab.snap('exit');
}

// ---------------------------------------------------------------------------------------------- interruption-resume
// SIGINT while the builder waits, a resume after the approval file was edited (refused), a resume with the approval
// as it was (continues the same conversation and lands once).
async function interruptionResume(lab) {
  await approvedProject(lab);
  const head = lab.git(['rev-parse', 'HEAD']);
  lab.beginChain('build');
  let phase = 'wait';
  scripted(lab, {
    build: [(r, n) => phase === 'wait' ? (n === 1 ? { items: [write('hello.txt', 'hi\n', 'i1')] } : { hold: true }) : { items: [finish(`i${n}`)] }],
    review: [{ items: [approve('i9')] }],
  });
  const first = lab.start(['intent', 'build', SLUG]);
  const raced = await Promise.race([lab.fake.next(r => r.held, 120000).then(() => 'held', () => 'timeout'), first.done.then(() => 'ended')]);
  lab.expect(raced === 'held', `kogen did not wait for the builder (${raced})`);
  if (raced === 'held') first.child.kill('SIGINT'); // the request's own snapshot was taken as it arrived
  const stopped = await first.done;
  lab.expect(stopped.code === 130 && /stopped add-greeting: interrupted \(Build /.test(stopped.stdout), `the interrupted Build ended with exit ${stopped.code}: ${stopped.stdout}`);
  await lab.snap('exit');
  const id = buildId(stopped);
  lab.expect(lab.git(['rev-parse', 'HEAD']) === head, 'HEAD moved by an interrupted Build');
  lab.expect(id, 'the interrupted Build printed no id');

  // The approval file is edited: the resume must refuse. (The scripted builder finishes, so a resume that does not
  // refuse ends instead of waiting.)
  phase = 'finish';
  const approvalFile = lab.read(APPROVAL);
  lab.put(APPROVAL, Buffer.concat([approvalFile, Buffer.from(' ')]));
  const runsBefore = lab.runIds().length, requestsBefore = lab.fake.requests.length;
  const refused = await lab.run(['intent', 'resume', id || '00000000']);
  lab.refusal('resume after an edit of the approval file', refused, { newRuns: lab.runIds().length - runsBefore, providerRequests: lab.fake.requests.length - requestsBefore });
  lab.expect(refused.code === 1 && lab.runIds().length === runsBefore && lab.fake.requests.length === requestsBefore, `a resume went on with a changed approval (exit ${refused.code})`);
  if (lab.runIds().length > runsBefore) await lab.snap('exit');
  lab.put(APPROVAL, approvalFile);

  const resumed = await lab.run(['intent', 'resume', id || '00000000']);
  lab.expect(resumed.code === 0 && /resuming Build [a-f0-9]{8} as [a-f0-9]{8}/.test(resumed.stdout), `the resume ended with exit ${resumed.code}: ${resumed.stdout}${resumed.stderr}`);
  if (lab.runIds().length > runsBefore) await lab.snap('exit');
}

// ---------------------------------------------------------------------------------------------- commit-recovery
// kogen is killed right after it created the commit (the user's post-commit hook holds `git commit` open once);
// the resume must report that commit and make no second one.
async function commitRecovery(lab) {
  await approvedProject(lab);
  const head = lab.git(['rev-parse', 'HEAD']);
  const marker = path.join(lab.dir, 'post-commit-ran');
  lab.put('.git/hooks/post-commit', `#!/bin/sh\nif [ ! -e '${marker}' ]; then : > '${marker}'; sleep 600; fi\n`, 0o755);
  lab.beginChain('build');
  scripted(lab, { build: [{ items: [write('hello.txt', 'hi\n', 'c1'), finish('c2')] }], review: [{ items: [approve('c3')] }] });
  const first = lab.start(['intent', 'build', SLUG]);
  let ended = false; first.done.then(() => { ended = true; });
  const limit = Date.now() + 5 * 60000;
  while (!fs.existsSync(marker) && !ended && Date.now() < limit) await sleep(20);
  lab.expect(fs.existsSync(marker), 'kogen ended before it created the commit');
  first.child.kill('SIGKILL');
  const killed = await first.done;
  const id = lab.latestRun();
  await lab.snap('killed');
  lab.expect(lab.git(['rev-parse', 'HEAD']) !== head, 'no commit existed when kogen was killed');
  const landed = lab.git(['rev-parse', 'HEAD']);
  const resumed = await lab.run(['intent', 'resume', id || '00000000']);
  const out = `${resumed.stdout}\n${resumed.stderr}`;
  lab.note('resume-after-kill', { killedBy: killed.signal, exit: resumed.code, namesTheCommit: out.includes(landed) || out.includes(landed.slice(0, 8)), headAfter: lab.git(['rev-parse', 'HEAD']) === landed });
  await lab.snap('after-resume');
  lab.expect(lab.git(['rev-parse', 'HEAD']) === landed && lab.git(['rev-list', '--count', `${landed}..HEAD`]) === '0', 'the resume moved HEAD or made a second commit');
  lab.expect(out.includes(landed) || out.includes(landed.slice(0, 8)), `the resume's output does not name commit ${landed}:\n${out}`);
}

module.exports = { journeys: { approval, 'verification-review': verificationReview, 'interruption-resume': interruptionResume, 'commit-recovery': commitRecovery } };
