'use strict';
// K-COMMIT-FAIL-RESUME acceptance: an independent installed-CLI harness. The packaged `kogen` (go_driver_support.js
// installs the release archive) runs a fixture Build with the scripted local provider; the builder edits app.txt,
// pass 1 is green, review 1 approves, and the signed commit fails because the configured signing program fails.
// After the signing program is fixed (and, in mode "edited", app.txt is edited) the same Build is resumed with
// `kogen intent resume <id>`. Run `node features/steps/k_commit_fail_resume_steps.js --control good|bad` for the
// known-good and known-bad controls of the assertions below.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const TITLE = 'Change the fixture app';
const SIGNER_ERROR = 'fixture signing program: no signing key under this HOME';
const cache = new Map();

async function observe(mode) {
  if (cache.has(mode)) return cache.get(mode);
  const H = require('./go_driver_support.js');
  const f = H.fn;
  const suite = await H.setupSuite(); let c;
  try {
    c = await H.project(suite, [], { stagedIntent: false });
    const put = (p, text) => { const file = path.join(c.repo, p); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text); };
    const read = p => { const file = path.join(c.repo, p); return fs.existsSync(file) ? fs.readFileSync(file) : null; };
    const git = args => H.git(c, args);
    const runGit = args => H.run('git', ['-C', c.repo, ...args], { env: H.envFor(c) });
    // Every configured check and acceptance run appends one line here, outside the checkout.
    const trace = path.join(c.root, 'trace'); fs.writeFileSync(trace, '');
    const traceLines = () => fs.readFileSync(trace, 'utf8').split('\n').filter(Boolean);
    const opts = { env: { KCFR_TRACE: trace } };
    put('.gitignore', '.kogen/local/\n');
    put('check.sh', 'set -eu\nprintf \'check|%s\\n\' "$(cat app.txt)" >> "$KCFR_TRACE"\n');
    H.configure(c, { checks: [{ name: 'trace', run: 'sh check.sh' }] });
    const dir = '.kogen/intents/fixture';
    put(`${dir}/intent.md`, `# ${TITLE}\n\nSlug: fixture\nModel: not applicable — the fixture has no state\nAcceptance:\n- ${dir}/acceptance.feature\n- features/steps/integration_steps.js\n\nChange app.txt to candidate.\n\n## Decisions\n- Use candidate. (source: request)\n\n## Source comparison\n- addressed: app.txt is candidate; source request; contract Tests and acceptance.feature.\n\n## Tests\n- app.txt is candidate: the acceptance scenario (scenario)\n\n## Feasibility\n- none\n`);
    put(`${dir}/acceptance.feature`, 'Feature: Fixture app\n  Scenario: The candidate app\n    Then the fixture app is "candidate"\n');
    put('features/steps/integration_steps.js', "const { Then } = require('@cucumber/cucumber'); const fs = require('node:fs'); const assert = require('node:assert/strict');\nThen('the fixture app is {string}', expected => { const app = fs.readFileSync('app.txt', 'utf8').trim(); fs.appendFileSync(process.env.KCFR_TRACE, 'acceptance|' + app + '\\n'); assert.equal(app, expected); });\n");
    await git(['add', '-A']); await git(['commit', '-qm', 'Configure the commit-failure fixture']);
    put(`${dir}/intent.md`, read(`${dir}/intent.md`).toString().replace('Change app.txt to candidate.', 'Change app.txt to candidate, the approved fixture change.'));
    const card = await H.runKogen(c, ['intent', 'approve', 'fixture'], opts); assert.equal(card.code, 5, card.out);
    const hash = /SHA-256: ([0-9a-f]{64})/.exec(card.out)[1];
    const approved = await H.runKogen(c, ['intent', 'approve', 'fixture', hash], opts); assert.equal(approved.code, 0, approved.out);
    const start = await git(['rev-parse', 'HEAD']);
    await H.signCommits(c);
    // The failing signing program: git cannot sign, so `git commit` exits nonzero and HEAD does not move.
    const signer = path.join(c.root, 'failing-signer');
    fs.writeFileSync(signer, `#!/bin/sh\necho "${SIGNER_ERROR}" >&2\nexit 1\n`, { mode: 0o755 }); fs.chmodSync(signer, 0o755);
    await git(['config', 'gpg.ssh.program', signer]);
    const indexBefore = fs.readFileSync(path.join(c.repo, '.git/index'));
    c.server.setScript([f('write_file', { path: 'app.txt', content: 'candidate\n' }), f('finish', { summary: 'candidate ready' }), f('submit_review', { verdict: 'approve', findings: [] })]);
    const stop = await H.runKogen(c, ['intent', 'build', 'fixture'], opts);
    const dirs = H.runDirs(c);
    assert.equal(dirs.length, 1, `the fixture Build made one run: ${dirs}\n${stop.out}`);
    const parentDir = dirs[0], parentId = path.basename(parentDir);
    const parentFile = name => fs.readFileSync(path.join(parentDir, name));
    const checkpointBytes = parentFile('checkpoint.json'), resultBytes = parentFile('result.json');
    const state = JSON.parse(checkpointBytes.toString()).state;
    const pick = (o, keys) => o ? Object.fromEntries(keys.map(k => [k, o[k]])) : null;
    const ins = await H.runKogen(c, ['intent', 'inspect', parentId, '--json']);
    let inspect = null; try { inspect = JSON.parse(ins.out.trim().split('\n').at(-1)).data; } catch {}
    const afterStop = {
      head: await git(['rev-parse', 'HEAD']), app: (read('app.txt') || '').toString(),
      indexSame: fs.readFileSync(path.join(c.repo, '.git/index')).equals(indexBefore),
      approvalPresent: fs.existsSync(H.approvalPath(c.repo, 'fixture')),
    };
    const traceAtStop = traceLines();
    const indexAtStop = fs.readFileSync(path.join(c.repo, '.git/index'));
    const approvalAtStop = read('.kogen/local/approvals/fixture.json');

    // The caller fixes the commit environment; in mode "edited" they also edit the verified tree.
    await git(['config', '--unset', 'gpg.ssh.program']);
    if (mode === 'edited') put('app.txt', 'edited\n');
    c.server.setScript([]);
    const requestsBefore = c.server.providerRequests().length;
    const resume = await H.runKogen(c, ['intent', 'resume', parentId], opts);
    const runsAfter = H.runDirs(c);
    const childDir = runsAfter.find(d => path.basename(d) !== parentId);
    const childResult = childDir && fs.existsSync(path.join(childDir, 'result.json')) ? JSON.parse(fs.readFileSync(path.join(childDir, 'result.json'), 'utf8')) : null;
    const head = await git(['rev-parse', 'HEAD']);
    const count = Number(await git(['rev-list', '--count', `${start}..HEAD`]));
    const verify = count === 1 ? await runGit(['verify-commit', 'HEAD']) : { code: null };
    const approvalNow = read('.kogen/local/approvals/fixture.json');
    const d = {
      mode, root: c.repo, start, parentId, stop,
      parent: { last_pass: pick(state.last_pass, ['n', 'green', 'tree']), last_review: pick(state.last_review, ['n', 'verdict', 'tree']), pass: state.pass, review: state.review },
      parentResult: JSON.parse(resultBytes.toString()),
      inspect: { code: ins.code, data: inspect ? pick(inspect, ['resume_status', 'next_command', 'blockers']) : null, out: ins.out },
      afterStop,
      resume,
      after: {
        head, count,
        parent: count === 1 ? await git(['rev-parse', 'HEAD^']) : null,
        tree: count === 1 ? await git(['rev-parse', 'HEAD^{tree}']) : null,
        message: count === 1 ? await git(['log', '-1', '--format=%B']) : null,
        signed: verify.code === 0,
        app: (read('app.txt') || '').toString(),
        approvalPresent: approvalNow !== null,
        approvalSame: approvalNow !== null && approvalAtStop !== null && approvalNow.equals(approvalAtStop),
        indexSame: fs.readFileSync(path.join(c.repo, '.git/index')).equals(indexAtStop),
        status: await git(['status', '--porcelain']),
        runs: runsAfter.map(p => path.basename(p)),
        childId: childDir ? path.basename(childDir) : null,
        childResult: childResult ? pick(childResult, ['outcome', 'resumed_from', 'root_build', 'passes', 'reviews', 'commit']) : null,
        newRequests: c.server.providerRequests().length - requestsBefore,
        newTrace: traceLines().slice(traceAtStop.length),
        parentCheckpointSame: parentFile('checkpoint.json').equals(checkpointBytes),
        parentResultSame: parentFile('result.json').equals(resultBytes),
      },
    };
    cache.set(mode, d);
    return d;
  } finally { await H.cleanupCase(c); H.cleanupSuite(suite); }
}

const q = s => `'${String(s).replaceAll("'", "'\\''")}'`;
const has = (text, part, what) => assert.ok(String(text).includes(part), `${what}: missing ${JSON.stringify(part)} in:\n${text}`);
const lacks = (text, part, what) => assert.ok(!String(text).includes(part), `${what}: unexpected ${JSON.stringify(part)} in:\n${text}`);
const hint = d => `  commit checkpoint kept: kogen intent resume ${d.parentId} --project ${q(d.root)} commits this verified and reviewed candidate once the commit environment is fixed`;
const resumeLine = d => `finishing the commit of the candidate verified in pass ${d.parent.last_pass.n} and approved in review ${d.parent.last_review.n}, with no builder round, no review and no rerun of its checks`;

// The Build was verified green and approved, then stopped because git commit failed: nothing committed or staged.
function checkStopped(d) {
  const out = d.stop.out;
  assert.equal(d.stop.code, 3, `the Build exits 3 for environment/commit_failed:\n${out}`);
  has(out, `failed fixture: commit_failed (Build ${d.parentId})`, 'stop');
  has(out, 'environment/commit_failed: git commit failed (status ', 'stop');
  has(out, '; the verified changes are left uncommitted', 'stop');
  has(out, SIGNER_ERROR, 'stop (Git\'s output)');
  has(out, hint(d), 'stop (the resume hint)');
  assert.equal(d.parentResult.outcome, 'commit_failed', 'result.json outcome');
  const p = d.parent.last_pass, r = d.parent.last_review;
  assert.ok(p && p.green === true && /^[0-9a-f]{40,64}$/.test(p.tree), `the last pass is green: ${JSON.stringify(p)}`);
  assert.ok(r && r.verdict === 'approve' && r.tree === p.tree, `the last review approved the green tree: ${JSON.stringify(r)}`);
  assert.equal(d.afterStop.head, d.start, 'HEAD did not move');
  assert.equal(d.afterStop.app, 'candidate\n', 'the verified change is left in place');
  assert.equal(d.afterStop.indexSame, true, 'the index is as before the Build (nothing staged)');
  assert.equal(d.afterStop.approvalPresent, true, 'the approval is kept');
}

// inspect offers the ordinary resume command and names the commit failure as the only blocker.
function checkInspect(d) {
  assert.equal(d.inspect.code, 0, `inspect --json:\n${d.inspect.out}`);
  const data = d.inspect.data;
  assert.ok(data, `inspect --json data:\n${d.inspect.out}`);
  assert.equal(data.resume_status, 'potentially_available', `resume_status:\n${d.inspect.out}`);
  assert.equal(data.next_command, `kogen intent resume ${d.parentId} --project ${q(d.root)}`, 'next_command');
  assert.equal(data.blockers.length, 1, `one blocker: ${JSON.stringify(data.blockers)}`);
  const [b] = data.blockers;
  assert.equal(b.class, 'environment', `blocker class: ${JSON.stringify(b)}`);
  assert.equal(b.reason, 'commit_failed', `blocker reason: ${JSON.stringify(b)}`);
  assert.ok(String(b.detail).startsWith('git commit failed (status '), `blocker detail: ${JSON.stringify(b)}`);
  lacks(JSON.stringify(data.blockers), 'unsafe_boundary', 'blockers');
}

// The resume made exactly one signed commit of the reviewed tree on the start HEAD, and nothing else ran.
function checkLanded(d) {
  const out = d.resume.out, a = d.after;
  assert.equal(d.resume.code, 0, `resume exits 0:\n${out}`);
  assert.ok(a.childId, `the resume made a new run: ${a.runs}`);
  has(out, `resuming Build ${d.parentId} as ${a.childId} (root ${d.parentId})`, 'resume');
  has(out, resumeLine(d), 'resume');
  has(out, 'kogen: committing', 'resume');
  for (const step of ['kogen: running setup', 'kogen: building', 'kogen: verifying', 'kogen: reviewing', 'request gpt-']) lacks(out, step, 'resume');
  assert.equal(a.count, 1, 'one new commit');
  has(out, `landed fixture ${a.head.slice(0, 8)} (Build ${a.childId})`, 'resume');
  assert.equal(a.parent, d.start, 'the commit\'s parent is the Build\'s start HEAD');
  assert.equal(a.tree, d.parent.last_pass.tree, 'the commit\'s tree is the verified and reviewed tree');
  assert.equal(a.message, `${TITLE}\n\nKogen-Intent: fixture`, 'commit message');
  assert.equal(a.signed, true, 'the commit is signed by the fixed signing setup');
  assert.equal(a.app, 'candidate\n');
  assert.equal(a.status, '', 'the checkout is clean after the commit');
  assert.equal(a.approvalPresent, false, 'landing consumed the approval');
  assert.deepEqual(a.runs.length, 2, `runs: ${a.runs}`);
  assert.deepEqual(a.childResult, { outcome: 'landed', resumed_from: d.parentId, root_build: d.parentId, passes: d.parentResult.passes, reviews: d.parentResult.reviews, commit: a.head }, 'the child result.json');
  assert.equal(a.newRequests, 0, 'no provider request');
  assert.deepEqual(a.newTrace, [], 'no configured check or acceptance run');
  assert.equal(a.parentResultSame, true, 'the stopped run\'s result.json is unchanged');
}

// The resume after the tree was edited is refused with the existing drift reason and changes nothing.
function checkRefused(d) {
  const out = d.resume.out, a = d.after;
  assert.equal(d.resume.code, 1, `resume exits 1:\n${out}`);
  has(out, `candidate/resume_refused: Build ${d.parentId}: candidate contents/modes or unrelated paths changed: app.txt; inspect the checkpoint and checkout, correct drift or obtain fresh approval for a new Build`, 'refusal');
  has(out, 'no newly created Build run', 'refusal');
  lacks(out, 'uncertain commit boundary', 'refusal');
  assert.deepEqual(a.runs, [d.parentId], 'no new run');
  assert.equal(a.head, d.start, 'HEAD unchanged');
  assert.equal(a.count, 0, 'no commit');
  assert.equal(a.app, 'edited\n', 'the edit is left in place');
  assert.equal(a.parentCheckpointSame, true, 'checkpoint unchanged');
  assert.equal(a.parentResultSame, true, 'result.json unchanged');
  assert.equal(a.approvalSame, true, 'approval unchanged');
  assert.equal(a.indexSame, true, 'index unchanged');
  assert.equal(a.newRequests, 0, 'no provider request');
  assert.deepEqual(a.newTrace, [], 'no configured check or acceptance run');
}

// ---- known-good and known-bad controls of the assertions above ----
function controls(kind) {
  const T = 'a'.repeat(40), S = 'b'.repeat(40), C = 'c'.repeat(40), root = '/tmp/kcfr/repo';
  const base = {
    mode: 'fixed', root, start: S, parentId: 'p1',
    stop: { code: 3, out: `failed fixture: commit_failed (Build p1)\nenvironment/commit_failed: git commit failed (status 128); the verified changes are left uncommitted\n  error: ${SIGNER_ERROR}\n  commit checkpoint kept: kogen intent resume p1 --project '${root}' commits this verified and reviewed candidate once the commit environment is fixed\n` },
    parent: { last_pass: { n: 1, green: true, tree: T }, last_review: { n: 1, verdict: 'approve', tree: T }, pass: 1, review: 1 },
    parentResult: { outcome: 'commit_failed', passes: 1, reviews: 1 },
    inspect: { code: 0, out: '{}', data: { resume_status: 'potentially_available', next_command: `kogen intent resume p1 --project '${root}'`, blockers: [{ class: 'environment', reason: 'commit_failed', detail: 'git commit failed (status 128); the verified changes are left uncommitted', paths: [] }] } },
    afterStop: { head: S, app: 'candidate\n', indexSame: true, approvalPresent: true },
  };
  const landed = { ...base,
    resume: { code: 0, out: `resuming Build p1 as c1 (root p1)\nfinishing the commit of the candidate verified in pass 1 and approved in review 1, with no builder round, no review and no rerun of its checks\nkogen: committing\nlanded fixture cccccccc (Build c1)\n` },
    after: { head: C, count: 1, parent: S, tree: T, message: `${TITLE}\n\nKogen-Intent: fixture`, signed: true, app: 'candidate\n', approvalPresent: false, approvalSame: false, indexSame: false, status: '',
      runs: ['c1', 'p1'], childId: 'c1', childResult: { outcome: 'landed', resumed_from: 'p1', root_build: 'p1', passes: 1, reviews: 1, commit: C }, newRequests: 0, newTrace: [], parentCheckpointSame: false, parentResultSame: true } };
  const refused = { ...base, mode: 'edited',
    resume: { code: 1, out: `candidate/resume_refused: Build p1: candidate contents/modes or unrelated paths changed: app.txt; inspect the checkpoint and checkout, correct drift or obtain fresh approval for a new Build\n  no newly created Build run; correct the named prerequisite before trying again\n` },
    after: { head: S, count: 0, parent: null, tree: null, message: null, signed: false, app: 'edited\n', approvalPresent: true, approvalSame: true, indexSame: true, status: ' M app.txt',
      runs: ['p1'], childId: null, childResult: null, newRequests: 0, newTrace: [], parentCheckpointSame: true, parentResultSame: true } };
  checkStopped(landed); checkInspect(landed); checkLanded(landed);
  checkStopped(refused); checkInspect(refused); checkRefused(refused);
  if (kind === 'good') { console.log('k-commit-fail-resume observer good'); return; }
  assert.equal(kind, 'bad');
  const bad = (fn, d, mutate) => { const c = structuredClone(d); mutate(c); assert.throws(() => fn(c), undefined, `accepted a known-bad fixture: ${fn.name} ${mutate}`); };
  // Today's stop: no resume hint; and a stop that committed or moved anything.
  bad(checkStopped, landed, d => { d.stop.out = d.stop.out.split('\n').filter(l => !l.includes('commit checkpoint kept')).join('\n'); });
  bad(checkStopped, landed, d => { d.stop.code = 1; });
  bad(checkStopped, landed, d => { d.stop.out = d.stop.out.replace('environment/commit_failed', 'candidate/hook_changed_commit'); });
  bad(checkStopped, landed, d => { d.afterStop.head = C; });
  bad(checkStopped, landed, d => { d.afterStop.indexSame = false; });
  bad(checkStopped, landed, d => { d.parent.last_review.verdict = 'changes'; });
  bad(checkStopped, landed, d => { d.parent.last_pass.green = false; });
  // Today's inspect: unsupported with the unsafe_boundary blocker and no next command.
  bad(checkInspect, landed, d => { d.inspect.data = { resume_status: 'unsupported', next_command: null, blockers: [{ reason: 'unsafe_boundary', detail: 'uncertain commit boundary; inspect effects and obtain fresh exact approval for a new Build', paths: [] }] }; });
  bad(checkInspect, landed, d => { d.inspect.data.resume_status = 'unsupported'; });
  bad(checkInspect, landed, d => { d.inspect.data.next_command = null; });
  bad(checkInspect, landed, d => { d.inspect.data.blockers.push({ reason: 'unsafe_boundary' }); });
  // Today's resume: refused at the uncertain commit boundary.
  bad(checkLanded, landed, d => { d.resume = { code: 1, out: 'candidate/resume_refused: Build p1: uncertain commit boundary; inspect effects before starting a freshly approved Build; inspect the checkpoint and checkout, correct drift or obtain fresh approval for a new Build\n' }; d.after = refused.after; });
  // Plausible wrong implementations: redoing work, committing the wrong tree or parent, unsigned, unused approval.
  bad(checkLanded, landed, d => { d.resume.out += 'kogen: verifying (pass 2)\n'; });
  bad(checkLanded, landed, d => { d.resume.out += 'kogen: reviewing (review 2)\n'; });
  bad(checkLanded, landed, d => { d.resume.out = d.resume.out.replace(/finishing the commit[^\n]*\n/, ''); });
  bad(checkLanded, landed, d => { d.after.newTrace = ['check|candidate']; });
  bad(checkLanded, landed, d => { d.after.newRequests = 1; });
  bad(checkLanded, landed, d => { d.after.tree = 'd'.repeat(40); });
  bad(checkLanded, landed, d => { d.after.parent = C; });
  bad(checkLanded, landed, d => { d.after.count = 2; });
  bad(checkLanded, landed, d => { d.after.signed = false; });
  bad(checkLanded, landed, d => { d.after.approvalPresent = true; });
  bad(checkLanded, landed, d => { d.after.childResult.passes = 2; });
  bad(checkLanded, landed, d => { d.after.childResult.reviews = 2; });
  bad(checkLanded, landed, d => { d.after.childResult.resumed_from = null; });
  bad(checkLanded, landed, d => { d.after.parentResultSame = false; });
  bad(checkLanded, landed, d => { d.after.status = ' M app.txt'; });
  // Today's refusal (the uncertain boundary, not the drift), and a refusal that changed or committed something.
  bad(checkRefused, refused, d => { d.resume.out = 'candidate/resume_refused: Build p1: uncertain commit boundary; inspect effects before starting a freshly approved Build; inspect the checkpoint and checkout, correct drift or obtain fresh approval for a new Build\n  no newly created Build run; correct the named prerequisite before trying again\n'; });
  bad(checkRefused, refused, d => { d.resume = landed.resume; d.after = { ...landed.after, app: 'edited\n' }; });
  bad(checkRefused, refused, d => { d.after.runs = ['c1', 'p1']; });
  bad(checkRefused, refused, d => { d.after.app = 'candidate\n'; });
  bad(checkRefused, refused, d => { d.after.parentCheckpointSame = false; });
  bad(checkRefused, refused, d => { d.after.approvalSame = false; });
  bad(checkRefused, refused, d => { d.after.indexSame = false; });
  bad(checkRefused, refused, d => { d.after.newTrace = ['check|edited']; });
  console.log('k-commit-fail-resume observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  const STEP = { timeout: 900000 };
  When('commit-fail-resume runs a verified, approved fixture Build whose signed commit fails, then resumes it in mode {string}', STEP, async function (mode) {
    assert.ok(['fixed', 'edited'].includes(mode), `unknown mode ${mode}`);
    this.kcfr = await observe(mode);
  });
  Then('commit-fail-resume sees the Build stopped as environment\\/commit_failed with HEAD unchanged, the verified change uncommitted and the resume command named', function () { checkStopped(this.kcfr); });
  Then('commit-fail-resume sees inspect offer the resume with the commit failure as the only blocker', function () { checkInspect(this.kcfr); });
  Then('commit-fail-resume sees the resume make one signed commit of exactly the reviewed tree on the start HEAD, with no builder round, review, check or provider request', function () { checkLanded(this.kcfr); });
  Then('commit-fail-resume sees the resume refused naming the edited path, with no new run, commit or change', function () { checkRefused(this.kcfr); });
}
