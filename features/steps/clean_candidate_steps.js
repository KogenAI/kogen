const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { isDeepStrictEqual } = require('node:util');
const { When, Then } = require('@cucumber/cucumber');
const H = require('./go_driver_support.js');
const { fn: f } = H;

// Independent harness: source under test stays editable; no generated implementation test is required. The installed
// `kogen` (the one Go program) is driven with a scripted local provider and its files are read.
async function exercise(mode) {
  const suite = await H.setupSuite(); let c;
  try {
    c = await H.project(suite, [], { stagedIntent: false });
    const repoCwd = fs.realpathSync(c.repo);
    const put = (p, text) => { const file = path.join(c.repo, p); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text); };
    const git = args => H.git(c, args);
    put('.gitignore', '.kogen/local/\nbuild/\n');
    put('src/app.sh', "printf 'baseline\\n'\n");
    put('launcher.sh', 'exec sh src/app.sh\n');
    put('generate.sh', "set -eu\nif [ -f build/app.sh ]; then prior=present; else prior=absent; fi\nmkdir -p build\nif [ -f candidate-input.sh ]; then cp candidate-input.sh build/app.sh; else cp src/app.sh build/app.sh; fi\nprintf '%s|%s|%s\\n' \"$(pwd -P)\" \"$prior\" \"$(sh build/app.sh)\" >> \"$CC_TRACE_FILE\"\n");
    put('check.sh', `set -eu\n${mode === 'check-output' ? 'sh generate.sh\n' : ''}actual=$(sh launcher.sh)\nif [ -f candidate-input.sh ]; then expected=$(sh candidate-input.sh); else expected=$(sh src/app.sh); fi\n[ "$actual" = "$expected" ]\n`);
    H.configure(c, { setup: mode === 'setup-output' ? ['sh generate.sh'] : [], checks: [{ name: 'shell-output', run: 'sh check.sh' }], protect: ['check.sh'] });
    await git(['add', '-A']); await git(['commit', '-qm', 'Configure shell output fixture']);
    const dir = '.kogen/intents/fixture';
    put(`${dir}/intent.md`, `# Verify shell output\n\nSlug: fixture\nModel: ${dir}/model.qnt invariants=Nonnegative seed=31 samples=2 steps=2\nAcceptance:\n- ${dir}/acceptance.feature\n- features/steps/integration_steps.js\n\nChange the launcher output.\n\n## Decisions\n- Use candidate-output. (source: request)\n\n## Source comparison\n- addressed: launcher output is candidate-output; source request; contract Tests and acceptance.feature.\n\n## Tests\n- Output: shell fixture (scenario)\n\n## Feasibility\n- none\n`);
    put(`${dir}/model.qnt`, "module fixture {\n var n: int\n action init = n' = 0\n action step = n' = n + 1\n val Nonnegative = n >= 0\n}\n");
    put(`${dir}/acceptance.feature`, 'Feature: Shell output\n  Scenario: Candidate output\n    Then shell output is "candidate-output"\n');
    const target = mode === 'check-output' ? 'candidate-input.sh' : 'launcher.sh';
    put('features/steps/integration_steps.js', `const {Then}=require('@cucumber/cucumber'); const {spawnSync}=require('node:child_process'); const assert=require('node:assert/strict'); Then('shell output is {string}', expected=>{const r=spawnSync('/bin/sh',[${JSON.stringify(target)}],{encoding:'utf8'}); assert.equal(r.status,0,r.stderr); assert.equal(r.stdout.trim(),expected);});\n`);
    const trace = path.join(c.root, 'generation.trace'); fs.writeFileSync(trace, '');
    const opts = { env: { CC_TRACE_FILE: trace } };
    const card = await H.runKogen(c, ['intent', 'approve', 'fixture'], opts); assert.equal(card.code, 5, card.out);
    const hash = /SHA-256: ([0-9a-f]{64})/.exec(card.out)[1];
    const approved = await H.runKogen(c, ['intent', 'approve', 'fixture', hash], opts); assert.equal(approved.code, 0, approved.out);
    await git(['add', dir, 'features/steps/integration_steps.js']);
    const index = fs.readFileSync(path.join(c.repo, '.git/index'));
    const approval = fs.readFileSync(H.approvalPath(c.repo, 'fixture'));
    const start = await git(['rev-parse', 'HEAD']);
    const hook = path.join(c.repo, '.git/hooks/pre-commit');
    fs.mkdirSync(path.dirname(hook), { recursive: true }); fs.writeFileSync(hook, '#!/bin/sh\nprintf hook > .kogen/local/hook-ran\n', { mode: 0o755 }); fs.chmodSync(hook, 0o755);
    const direct = 'exec sh candidate-input.sh\n', ignored = 'exec sh build/app.sh\n', poison = "printf 'candidate-output\\n'\n";
    // Use write_file for exact fixture bytes; shell only creates the ignored artifact.
    const build = [f('write_file', { path: 'candidate-input.sh', content: poison }), f('write_file', { path: 'launcher.sh', content: mode === 'reviewer-repair' ? direct : ignored }), f('shell', { command: 'mkdir -p build; cp candidate-input.sh build/app.sh' }), f('finish', { summary: 'candidate ready' })];
    const approve = f('submit_review', { verdict: 'approve', findings: [] });
    const tail = mode === 'ignored-shell' ? [{ http: [400, { error: { message: 'bounded red stop', code: 'invalid_request_error' } }] }]
      : mode === 'reviewer-repair' ? [f('write_file', { path: 'launcher.sh', content: ignored }), approve, f('write_file', { path: 'launcher.sh', content: `${direct}# reviewer repaired\n` }), approve] : [approve];
    c.server.setScript([...build, ...tail]);
    const t = Date.now();
    const { out: output, code: status } = await H.runKogen(c, ['intent', 'build', 'fixture'], opts);
    const wall = Date.now() - t;
    const requests = c.server.providerRequests(), reviews = c.server.reviewRequests();
    const feedback = requests.map(r => JSON.stringify(r.json.input)).join('\n');
    const [resultFile] = H.wildcard(path.join(c.repo, '.kogen/local/runs/*/result.json'));
    const result = JSON.parse(fs.readFileSync(resultFile, 'utf8'));
    const count = Number(await git(['rev-list', '--count', `${start}..HEAD`]));
    const generated = fs.readFileSync(trace, 'utf8').split('\n').filter(Boolean).some(line => { const [cwd, prior, out] = line.split('|'); return prior === 'absent' && out === 'candidate-output' && cwd !== repoCwd; });
    let fresh = false;
    if (count === 1) {
      const clone = path.join(c.root, 'fresh-result');
      await H.checked('git', ['clone', '--no-local', '-q', c.repo, clone], { env: H.envFor(c) });
      const commands = [...(mode === 'setup-output' ? ['sh generate.sh'] : []), 'sh check.sh', 'sh launcher.sh'];
      fresh = true;
      for (const cmd of commands) { const r = await H.run('/bin/sh', ['-c', cmd], { cwd: clone, env: H.envFor(c, { CC_TRACE_FILE: trace }) }); fresh = fresh && r.code === 0; }
    }
    const reviewFile = count === 1 ? H.wildcard(path.join(c.repo, '.kogen/local/runs/*/review-1.json'))[0] : null;
    const bound = reviewFile ? JSON.parse(fs.readFileSync(reviewFile, 'utf8')).tree === await git(['rev-parse', 'HEAD^{tree}']) : false;
    const same = (a, b) => isDeepStrictEqual(a, b);
    return {
      landed: status === 0 && result.outcome === 'landed', commitCount: count,
      cleanFailureFeedback: feedback.includes('Verification pass') && feedback.includes('build/app.sh') && feedback.includes('failed'),
      indexPreserved: fs.readFileSync(path.join(c.repo, '.git/index')).equals(index),
      approvalPreserved: fs.existsSync(H.approvalPath(c.repo, 'fixture')) && fs.readFileSync(H.approvalPath(c.repo, 'fixture')).equals(approval),
      workspaceArtifactPreserved: fs.existsSync(path.join(c.repo, 'build/app.sh')) && fs.readFileSync(path.join(c.repo, 'build/app.sh'), 'utf8') === poison,
      reviewStages: result.reviews, cleanGenerationObserved: generated, freshCloneRuns: fresh,
      generatedOutputCommitted: count === 1 && (await git(['ls-tree', '-r', '--name-only', 'HEAD'])).includes('build/app.sh'),
      candidateInputCommitted: count === 1 && (await git(['show', 'HEAD:candidate-input.sh'])) === poison.trim(),
      modelPassed: output.includes('model passed'), hookRan: fs.existsSync(path.join(c.repo, '.kogen/local/hook-ran')),
      sameReviewerRepair: reviews.length === 4 && reviews.some(r => JSON.stringify(r.json.input).includes('Final verification')) && result.reviews === 1,
      finalTreeBound: bound, wall_ms: wall, result, output, runtime: suite.release, mode,
    };
  } finally { await H.cleanupCase(c); H.cleanupSuite(suite); }
}
When('I exercise clean candidate verification in mode {string}', { timeout: 300000 }, async function (mode) {
  assert.ok(['ignored-shell', 'setup-output', 'check-output', 'reviewer-repair'].includes(mode));
  this.cleanCandidateReceipt = await exercise(mode);
  await this.attach(JSON.stringify(this.cleanCandidateReceipt), 'application/json');
});
Then('the clean candidate observations are:', function (table) {
  assert.ok(this.cleanCandidateReceipt, 'no native observations');
  for (const [key, value] of table.raw()) assert.deepEqual(this.cleanCandidateReceipt[key], JSON.parse(value), `${key}: ${JSON.stringify(this.cleanCandidateReceipt)}`);
});
