const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { isDeepStrictEqual } = require('node:util');
const { When, Then } = require('@cucumber/cucumber');
const H = require('./go_driver_support.js');
const { fn: f } = H;
const same = isDeepStrictEqual;

// Independent installed-CLI harness. No production file or builder-owned implementation test is frozen here.
async function exercise(mode) {
  const suite = await H.setupSuite(); let c;
  try {
    c = await H.project(suite, [], { stagedIntent: false });
    const put = (p, text) => { const file = path.join(c.repo, p); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text); };
    const git = args => H.git(c, args);
    put('.gitignore', '.kogen/local/\n');
    put('app.txt', 'baseline\n');
    put('policy.qnt', 'module policy { val Allowed = true }\n');
    // External trace is evidence only. It supplies no candidate inputs.
    const trace = path.join(c.root, 'trace'); fs.writeFileSync(trace, '');
    put('gate.sh', "set -eu\nprintf '%s|%s|%s\\n' \"$(pwd -P)\" \"$(cat app.txt)\" \"$1\" >> \"$FF_TRACE\"\ncase \"$1:$(cat app.txt)\" in setup-1:setup-red|z-cheap:project-red) echo definitive-fixture-red; exit 19;; esac\n");
    const original = fs.readFileSync(path.join(c.repo, '.kogen/project.yaml'), 'utf8');
    const stepsDir = /steps_dir: '?([^'\n]+)'?/.exec(original)[1];
    const acceptanceRun = /^    run: '((?:[^']|'')*)'$/m.exec(original)[1].replaceAll("''", "'");
    // A wrapper containing shell syntax must remain verbatim, not be parsed or rewritten.
    const runner = `printf 'wrapper\\n' >> "$FF_WRAPPER"; ${acceptanceRun}${mode === 'custom' ? '' : ' --fail-fast'}`;
    H.configure(c, { setup: ['sh gate.sh setup-1'], checks: [{ name: 'z-cheap', run: 'sh gate.sh z-cheap' }, { name: 'a-later', run: 'sh gate.sh a-later' }], protect: ['gate.sh'], acceptance: { run: runner, stepsDir } });
    await git(['add', '-A']); await git(['commit', '-qm', 'Configure fail-fast fixture']);
    const dir = '.kogen/intents/fixture';
    put(`${dir}/intent.md`, `# Verify candidate gates\n\nSlug: fixture\nModel: ${dir}/model.qnt invariants=Valid seed=31 samples=2 steps=2\nAcceptance:\n- ${dir}/acceptance.feature\n- features/steps/integration_steps.js\n\nExercise candidate gates.\n\n## Decisions\n- Keep every gate. (source: request)\n\n## Source comparison\n- addressed: every gate stays; source request; contract Tests and acceptance.feature.\n\n## Tests\n- Candidate: installed fixture (scenario)\n\n## Feasibility\n- none\n`);
    put(`${dir}/model.qnt`, "module fixture {\n import policy.* from \"../../../policy\"\n var n: int\n action init = n' = 0\n action step = n' = n + 1\n val Valid = Allowed\n}\n");
    put(`${dir}/acceptance.feature`, 'Feature: Gates\n  Scenario: First case\n    Then candidate gate 1 succeeds\n  Scenario: Later case\n    Then candidate gate 2 succeeds\n');
    put('features/steps/integration_steps.js', "const {Then}=require('@cucumber/cucumber'); const fs=require('node:fs'); const assert=require('node:assert/strict'); Then('candidate gate {int} succeeds', n=>{const app=fs.readFileSync('app.txt','utf8').trim(); fs.appendFileSync(process.env.FF_TRACE, fs.realpathSync('.')+'|'+app+'|acceptance-'+n+'\\n'); if(n===1) assert.notEqual(app,'acceptance-red','definitive acceptance red');});\n");
    const wrapper = path.join(c.root, 'wrapper');
    const opts = { env: { FF_TRACE: trace, FF_WRAPPER: wrapper } };
    const card = await H.runKogen(c, ['intent', 'approve', 'fixture'], opts); assert.equal(card.code, 5, card.out);
    const hash = /SHA-256: ([0-9a-f]{64})/.exec(card.out)[1];
    const approved = await H.runKogen(c, ['intent', 'approve', 'fixture', hash], opts); assert.equal(approved.code, 0, approved.out);
    await git(['add', dir, 'features/steps/integration_steps.js']);
    const index = fs.readFileSync(path.join(c.repo, '.git/index'));
    const approval = fs.readFileSync(H.approvalPath(c.repo, 'fixture'));
    const start = await git(['rev-parse', 'HEAD']);
    // Sign only the actual Build result, not setup commits.
    await H.signCommits(c);
    const signers = path.join(c.root, 'allowed-signers');
    const red = { acceptance: 'acceptance-red', custom: 'acceptance-red', project: 'project-red', setup: 'setup-red', model: 'model-red', reviewer: 'builder-green' }[mode];
    const edit = value => f('write_file', { path: 'app.txt', content: `${value}\n` });
    const policy = ok => f('write_file', { path: 'policy.qnt', content: `module policy { val Allowed = ${ok} }\n` });
    const finish = f('finish', { summary: 'Verify the candidate' });
    const approve = f('submit_review', { verdict: 'approve', findings: [] });
    const stop = { http: [400, { error: { message: 'bounded fixture stop', code: 'invalid_request_error' } }] };
    const script = [edit(red), ...(mode === 'model' ? [policy(false)] : []), finish, ...(mode === 'reviewer' ? [edit('acceptance-red'), approve, edit('reviewer-green'), approve] : [stop])];
    c.server.setScript(script);
    fs.writeFileSync(trace, '');
    const { out: output, code: status } = await H.runKogen(c, ['intent', 'build', 'fixture'], opts);
    const [resultPath] = H.wildcard(path.join(c.repo, '.kogen/local/runs/*/result.json'));
    const runDir = path.dirname(resultPath);
    const result = JSON.parse(fs.readFileSync(resultPath, 'utf8'));
    const readLogs = d => fs.readFileSync(path.join(d, 'log.jsonl'), 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l));
    const logs = readLogs(runDir);
    const passes = logs.filter(e => e.event === 'pass');
    const first = passes[0];
    const saved = JSON.parse(fs.readFileSync(path.join(runDir, 'checkpoint.json'), 'utf8')).state;
    const required = ['model', 'z-cheap', 'a-later'];
    const expected = { setup: ['acceptance', ...required], model: ['z-cheap', 'a-later'], project: ['a-later'], reviewer: [] }[mode] || required;
    const requests = c.server.providerRequests();
    const feedback = requests.map(r => JSON.stringify(r.json.input)).join('\n');
    const names = (text, list) => /not[ _-]run|unrun|skipped/i.test(text) && list.every(n => text.includes(n));
    const traceRows = () => fs.readFileSync(trace, 'utf8').split('\n').filter(Boolean).map(l => l.split('|'));
    const nativeTrace = value => traceRows().filter(([cwd, app]) => cwd !== c.repo && app === value).map(r => r.at(-1));
    const initialTrace = nativeTrace(red);
    const redCustody = (await git(['rev-parse', 'HEAD'])) === start && fs.readFileSync(path.join(c.repo, '.git/index')).equals(index) && fs.existsSync(H.approvalPath(c.repo, 'fixture')) && fs.readFileSync(H.approvalPath(c.repo, 'fixture')).equals(approval);
    const firstHistory = fs.readFileSync(resultPath, 'utf8');
    const firstTraceCount = initialTrace.length;
    let resumeOutput, resumeStatus;
    if (mode !== 'reviewer') {
      // The first finish on resume is unchanged red: it cannot reuse an incomplete pass.
      c.server.setScript([finish, edit('repaired-green'), policy(true), finish, approve]);
      ({ out: resumeOutput, code: resumeStatus } = await H.runKogen(c, ['intent', 'resume', path.basename(runDir)], opts));
    } else { resumeOutput = output; resumeStatus = status; }
    const results = H.wildcard(path.join(c.repo, '.kogen/local/runs/*/result.json')).map(p => JSON.parse(fs.readFileSync(p, 'utf8')));
    const landed = results.find(r => r.outcome === 'landed');
    const finalValue = mode === 'reviewer' ? 'reviewer-green' : 'repaired-green';
    const finalTrace = nativeTrace(finalValue);
    const expectedTrace = ['setup-1', 'acceptance-1', 'acceptance-2', 'z-cheap', 'a-later'];
    const count = Number(await git(['rev-list', '--count', `${start}..HEAD`]));
    const verify = await H.run('git', ['-C', c.repo, '-c', `gpg.ssh.allowedSignersFile=${signers}`, 'verify-commit', 'HEAD'], { env: H.envFor(c) });
    const allLogs = H.wildcard(path.join(c.repo, '.kogen/local/runs/*/log.jsonl')).flatMap(p => readLogs(path.dirname(p)));
    const allPasses = allLogs.filter(e => e.event === 'pass');
    const reviews = c.server.reviewRequests();
    const reviewerRed = passes.find(p => p.green === false);
    const show = p => git(['show', `HEAD:${p}`]);
    // These are observed public evidence fields, not helper-call or implementation-structure assertions.
    return {
      firstTrace: initialTrace, notRun: first.not_run,
      actualFailure: first.green === false && first.failing.length > 0 && (feedback.includes('definitive') || feedback.includes('invariant')),
      feedbackNamesNotRun: names(feedback, expected), logNamesNotRun: same(first.not_run, expected),
      checkpointNamesNotRun: same(saved.last_pass.not_run, expected) && !saved.last_pass.green,
      resultNamesNotRun: same(result.not_run, expected),
      stoppedSummaryNamesNotRun: names(output, expected),
      noCommitOnRed: status !== 0 && redCustody, indexAndApprovalPreserved: redCustody,
      unchangedRedRetested: nativeTrace(red).length === firstTraceCount * 2 && fs.readFileSync(resultPath, 'utf8') === firstHistory && allPasses.filter(p => p.green === false).length >= 2,
      repairedCandidateRunsAll: same(finalTrace, expectedTrace) && allPasses.some(p => p.green === true && same(p.not_run, [])),
      signedLanding: resumeStatus === 0 && count === 1 && verify.code === 0 && landed !== undefined,
      exactFinalTree: landed !== undefined && (await show('app.txt')) === finalValue && (await show('policy.qnt')) === 'module policy { val Allowed = true }' && allPasses.some(p => p.green === true),
      oneReviewStage: landed !== undefined && landed.reviews === 1,
      reviewerRedStops: same(nativeTrace('acceptance-red'), ['setup-1', 'acceptance-1']) && reviewerRed !== undefined && same(reviewerRed.not_run, required),
      sameReviewerGetsFailure: reviews.length === 4 && reviews.some(r => JSON.stringify(r.json.input).includes('Final verification')),
      unchangedGreenReused: passes.length === 3 && same(nativeTrace('builder-green'), expectedTrace) && same(finalTrace, expectedTrace),
      output, resumeOutput, passEvidence: allPasses, wrapperExecuted: fs.existsSync(wrapper), runtime: suite.release,
    };
  } finally { await H.cleanupCase(c); H.cleanupSuite(suite); }
}
When('I exercise installed fail-fast verification in mode {string}', { timeout: 360000 }, async function (mode) {
  assert.ok(['acceptance', 'custom', 'model', 'project', 'setup', 'reviewer'].includes(mode));
  this.failFastReceipt = await exercise(mode);
  await this.attach(JSON.stringify(this.failFastReceipt), 'application/json');
});
Then('the fail-fast verification observations are:', function (table) {
  assert.ok(this.failFastReceipt, 'missing installed observations');
  for (const [key, value] of table.raw()) assert.deepEqual(this.failFastReceipt[key], JSON.parse(value), `${key}: ${JSON.stringify(this.failFastReceipt)}`);
});
