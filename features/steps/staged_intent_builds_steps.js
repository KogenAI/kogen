const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { isDeepStrictEqual } = require('node:util');

// Observers for the Shape request and the invalid-plan refusal. They are pure so the synthetic controls below can run them
// without an installed Build (the Elixir driver's STAGED_OBSERVER_CONTROL mode, ported one for one).
// The factory has already called native init. Bound observation to this Shape invocation, and inspect only its first
// request, before any candidate echo.
const shapeRequestsSince = (retained, before) => retained.slice(before);
const shapeGuidance = requests => requests.length > 0 && JSON.stringify(requests[0].json).includes('## Stages');
// A custody refusal is not proof that stage lint ran.
const invalidPlanRefused = (status, out) => status === 1 && out.includes('intent/lint') && out.toLowerCase().includes('stage') && !out.includes('source_provenance_changed');

// One observer for native receipts and controls. Compare parsed objects semantically;
// array order and every string byte remain significant. Never accept stdout as a receipt.
function check(receipt, rows) {
  for (const [key, text] of rows) {
    assert.ok(Object.hasOwn(receipt, key), 'missing observation: ' + key);
    assert.deepEqual(receipt[key], JSON.parse(text), key + ': ' + JSON.stringify(receipt));
  }
}

if (require.main === module && process.argv[2] === '--shape-control') {
  // Synthetic request-selection and lint-output controls: no installed Build, account or inference.
  const request = text => ({ json: { input: [{ role: 'developer', content: text }] } });
  const init = request('native init: submit_configuration'), first = request('native Shape guidance: ## Stages'), later = request('candidate echo: ## Stages');
  const selected = shapeRequestsSince([init, first, later], 1);
  assert.deepEqual(selected, [first, later]);
  assert.equal(shapeGuidance(selected), true);
  assert.equal(invalidPlanRefused(1, 'intent/lint: stages: expected version 1 and at least two unique stages\n'), true);
  if (process.argv[3] === 'good') process.stdout.write('shape observer accepted\n');
  else if (process.argv[3] === 'bad') {
    for (const retained of [[first, request('native Shape without stage guidance'), later], [init, request('native Shape without stage guidance'), later], [first]]) {
      assert.equal(shapeGuidance(shapeRequestsSince(retained, 1)), false);
    }
    for (const [status, out] of [
      [1, 'candidate/source_provenance_changed: source provenance custody missing, changed or unsafe: stages/fixture/current.json\n'],
      [5, 'intent/lint: stages: invalid\n'], [0, 'intent/lint: stages: invalid\n'], [1, 'intent/lint: missing Tests section\n'],
      [1, 'stage command failed\n'], [1, 'candidate/source_provenance_changed: intent/lint stages was never reached\n'],
    ]) assert.equal(invalidPlanRefused(status, out), false);
    process.stdout.write('shape observer rejected counterexamples\n');
    process.exitCode = 1;
  } else throw new Error('unknown control');
} else if (require.main === module && process.argv[2] === '--control') {
  // Explicitly synthetic local observer controls, NOT native staged support evidence.
  // Reach each downstream comparison independently, even when a baseline feature red
  // would mask it. These include ordered nested command records and phase identity.
  const good = {
    shape_ok: true, shape_request_exact: true, shape_guidance: true, card_plan: true,
    first_stopped: true, stop_index_approval: true,
    stage_progress: { total: 2, completed: ['foundation'], active: 'surface', phase: 'stage' },
    stage_trace: [{ kind: 'stage-one', state: 'broken', status: 1 }, { kind: 'stage-one', state: 'phase-one', status: 0 }, { kind: 'stage-two', state: 'phase-two', status: 0 }],
    stage_records: [{ stage_id: 'foundation', green: false }, { stage_id: 'foundation', green: true }, { stage_id: 'surface', green: true }],
    no_full_before_stop: true, no_review_before_stop: true, resume_exact: true,
    first_result_unchanged: true, effect_once: true,
    final_trace: ['phase-two', 'final', 'review-broken', 'final-reviewed'],
    model_executed: true, configured_final: true, reviewer_repair_feedback: true,
    independent: true, landed: true, commits: '1', refused: true,
    refusal_unchanged: true, no_model: true, refined: true, revoked: true,
    build_needs_approval: true, changed_card: true, no_commit: true,
    invalid_refused: true, invalid_unchanged: true, no_approval: true
  };
  const rows = Object.entries(good).map(([k, v]) => [k, JSON.stringify(v)]);
  check(JSON.parse(JSON.stringify(good)), rows);
  if (process.argv[3] === 'good') {
    process.stdout.write('observer accepted\n');
  } else if (process.argv[3] === 'bad') {
    for (const key of Object.keys(good)) {
      const bad = structuredClone(good);
      if (typeof bad[key] === 'boolean') bad[key] = false;
      else if (typeof bad[key] === 'string') bad[key] = '0';
      else if (Array.isArray(bad[key])) bad[key].reverse();
      else bad[key].completed.push('surface');
      assert.throws(() => check(bad, rows), undefined, 'accepted corruption: ' + key);
      const missing = structuredClone(good); delete missing[key];
      assert.throws(() => check(missing, rows), undefined, 'accepted absence: ' + key);
    }
    process.stdout.write('observer rejected counterexamples\n');
    process.exitCode = 1;
  } else throw new Error('unknown control');
} else {
  const { Given, When, Then } = require('@cucumber/cucumber');
  const H = require('./go_driver_support.js');
  const ROOT = H.ROOT;
  const f = H.fn;
  const sameValue = (a, b) => isDeepStrictEqual(a, b);

  const put = (c, p, bytes) => { const file = path.join(c.repo, p); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, bytes); };
  const git = (c, args) => H.git(c, args);
  const append = (c, actions) => { c.server.script.push(...actions); };   // FakeProvider.append: after everything scripted so far
  const write = s => f('write_file', { path: 'app.txt', content: `${s}\n` });
  const finish = () => f('finish', { summary: 'verify current approved work' });
  const approveReview = () => f('submit_review', { verdict: 'approve', findings: [] });
  const requests = c => c.server.providerRequests();
  const input = r => r.json.input;
  const traceFile = c => path.join(c.root, 'trace.ndjson');
  const trace = c => fs.existsSync(traceFile(c)) ? fs.readFileSync(traceFile(c), 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l)) : [];
  const readJson = p => JSON.parse(fs.readFileSync(p, 'utf8'));
  const readOptional = p => fs.existsSync(p) ? fs.readFileSync(p).toString('base64') : null;
  const intentMd = H.intentMd, feature = H.featurePath;
  const modelPath = slug => `${H.intentDir(slug)}/model.qnt`;
  const sourcePath = (c, slug) => path.join(c.repo, `.kogen/local/provenance/${slug}/current.json`);
  const runPaths = (c, name) => H.wildcard(path.join(c.repo, '.kogen/local/runs/*', name));

  async function custody(c) {
    return {
      head: await git(c, ['rev-parse', 'HEAD']),
      index: fs.readFileSync(path.join(c.repo, '.git/index')).toString('base64'),
      approval: readOptional(H.approvalPath(c.repo, 'fixture')),
      app: fs.readFileSync(path.join(c.repo, 'app.txt'), 'utf8'),
    };
  }
  async function approve(c) {
    const { card, hash, out } = await H.approve(c);
    return { card, hash, out };
  }

  Given('the native staged fixture contract is:', function (text) {
    this.stagedSpec = JSON.parse(text);
  });
  When('I exercise native staged Builds in mode {string}', { timeout: 300000 }, async function (mode) {
    const suite = await H.setupSuite();
    let c;
    try {
      c = await H.project(suite, [], { stagedIntent: false });
      c.env = { ...c.env, STAGED_TRACE: traceFile(c) };
      this.stagedReceipt = await exercise(c, this.stagedSpec, mode);
      await this.attach(JSON.stringify(this.stagedReceipt), 'application/json');
    } finally {
      await H.cleanupCase(c);
      H.cleanupSuite(suite);
    }
  });
  Then('the native staged observations are:', function (table) {
    assert.ok(this.stagedReceipt, 'no native behavior observed');
    check(this.stagedReceipt, table.raw());
  });

  async function exercise(c, spec, mode) {
    // The factory really seeds baseline app.txt, native init and a default approval.
    await git(c, ['add', '.kogen/intents/fixture', 'features/steps/integration_steps.js']);
    await git(c, ['commit', '-qm', 'Commit seed fixture']);
    fs.rmSync(path.join(c.repo, intentMd('fixture')));
    fs.rmSync(path.join(c.repo, feature('fixture')));
    fs.rmdirSync(path.join(c.repo, H.intentDir('fixture')));
    await git(c, ['add', '-u']);
    await git(c, ['commit', '-qm', 'Remove seed package before native Shape']);
    fs.rmSync(H.approvalPath(c.repo, 'fixture'));
    let config = fs.readFileSync(path.join(c.repo, '.kogen/project.yaml'), 'utf8');

    // Reuse native init's real runner/models, with explicit local fixture commands.
    assert.ok(config.includes('setup: []') && config.includes('checks: []'), `native init wrote no empty setup/checks to replace:\n${config}`);
    config = config.replaceAll('setup: []', `setup:\n    - '"$KOGEN_NODE" features/steps/gate.cjs setup'`);
    config = config.replaceAll('checks: []', `checks:\n    - name: fixture-check\n      run: '"$KOGEN_NODE" features/steps/gate.cjs configured'`);
    put(c, '.kogen/project.yaml', config);

    put(c, 'features/steps/gate.cjs', "const fs=require('node:fs');const k=process.argv[2],s=fs.readFileSync('app.txt','utf8').trim();const ok=k==='stage-one'?s==='phase-one':k==='stage-two'?s==='phase-two':true;fs.appendFileSync(process.env.STAGED_TRACE,JSON.stringify({kind:k,state:s,status:ok?0:1})+'\\n');if(!ok){console.error(k+' failed: '+s);process.exitCode=1;}\n");
    await git(c, ['add', '.kogen/project.yaml', 'features/steps/gate.cjs']);
    await git(c, ['commit', '-qm', 'Configure deterministic local gates']);
    const plan = spec.plan;

    let md = '# Complete staged fixture\n\nSlug: fixture\nModel: .kogen/intents/fixture/model.qnt invariants=Safe seed=23 samples=10 steps=5\nAcceptance:\n- .kogen/intents/fixture/acceptance.feature\n- features/steps/stage_fixture.js\n- features/steps/gate.cjs\n\nImplement the complete local rewrite analogue.\n\n## Decisions\n- Keep one whole delivery. (source: request)\n\n## Source comparison\n- addressed: original staged-build request; local analogue only, no Go import.\n\n## Tests\n- whole output: real app file (scenario)\n\n## Feasibility\n- none\n';
    md += mode === 'single' ? '' : '\n## Stages\n```json\n' + JSON.stringify(plan) + '\n```\n';
    const featureText = 'Feature: Complete local rewrite\n  Scenario: Deliver all work\n    Then the local rewrite is complete\n';
    const step = "const {Then}=require('@cucumber/cucumber');const fs=require('node:fs');const assert=require('node:assert/strict');Then('the local rewrite is complete',()=>{const s=fs.readFileSync('app.txt','utf8').trim();fs.appendFileSync(process.env.STAGED_TRACE,JSON.stringify({kind:'acceptance',state:s,status:['final','final-reviewed'].includes(s)?0:1})+'\\n');assert.ok(['final','final-reviewed'].includes(s),'Go migration not implemented: lib remains (local analogue): '+s);});\n";
    const model = 'module fixture { var n: int action init = n\' = 0 action step = n\' = n val Safe = n == 0 }\n';

    const pkg = [
      { path: intentMd('fixture'), content: md },
      { path: feature('fixture'), content: featureText },
      { path: modelPath('fixture'), content: model },
      { path: 'features/steps/stage_fixture.js', content: step },
    ];

    const requestPath = path.join(c.root, 'original-request.md');
    fs.writeFileSync(requestPath, spec.request);
    // Exercise native discovery before submission, then acknowledge identical red.
    const discovery = [f('read_file', { path: 'app.txt' }), f('read_file', { path: '.kogen/project.yaml' })];
    append(c, [...discovery, f('submit', { files: pkg }), f('submit', { files: pkg })]);
    const shapeBefore = requests(c).length;
    const shape = await H.runKogen(c, ['intent', 'shape', 'fixture', requestPath]);
    assert.equal(shape.code, 0, shape.out + '\nNative tool feedback: ' + JSON.stringify(c.server.toolOutputs()));
    const shapeRequests = shapeRequestsSince(requests(c), shapeBefore);
    const { card, hash } = await approve(c);
    const start = await custody(c);
    fs.writeFileSync(traceFile(c), '');

    const common = {
      shape_ok: shape.code === 0,
      shape_request_exact: shapeRequests.some(r => H.FakeProvider.inputText(r).includes(spec.request)),
      // Later requests contain our candidate. Only the first can prove native guidance.
      shape_guidance: shapeGuidance(shapeRequests),
      card_plan: plan.stages.every(s => card.includes(s.title) && card.includes(s.goal) && s.checks.every(cmd => card.includes(cmd))),
    };

    if (mode.startsWith('invalid:')) {
      const bad = structuredClone(plan);
      switch (mode.slice('invalid:'.length)) {
        case 'empty': bad.stages = []; break;
        case 'duplicate': bad.stages = [plan.stages[0], plan.stages[0]]; break;
        case 'blank-check': bad.stages[0].checks = ['']; break;
        case 'version': bad.version = 99; break;
        default: throw new Error(`unknown invalid case ${mode}`);
      }
      // This package is deliberately never shaped or approved: the supported legacy route has no source receipt to
      // invalidate. Do not remove, forge or rebind the real Shape receipt or modify its approved package.
      const slug = 'invalid-fixture';
      const source = sourcePath(c, 'fixture'), legacySource = sourcePath(c, slug);
      assert.equal(fs.existsSync(path.join(c.repo, H.intentDir(slug))), false);
      assert.equal(fs.existsSync(legacySource), false);
      assert.equal(fs.existsSync(H.approvalPath(c.repo, slug)), false);
      assert.ok(fs.existsSync(source), `the real Shape receipt is missing: ${source}`);

      const legacy = {
        [intentMd(slug)]: md.replace('Slug: fixture\n', `Slug: ${slug}\n`).replaceAll('.kogen/intents/fixture/', `${H.intentDir(slug)}/`).replace(JSON.stringify(plan), JSON.stringify(bad)),
        [feature(slug)]: featureText,
        [modelPath(slug)]: model,
      };
      assert.ok(legacy[intentMd(slug)].includes(JSON.stringify(bad)), 'the invalid plan was not substituted');
      for (const [p, bytes] of Object.entries(legacy)) put(c, p, bytes);
      const watched = [...Object.keys(legacy), ...pkg.map(p => p.path), path.relative(c.repo, source)];
      const snapshot = () => Object.fromEntries(watched.map(p => [p, fs.readFileSync(path.join(c.repo, p)).toString('base64')]));
      const before = snapshot();
      const n = requests(c).length;
      const { out, code } = await H.runKogen(c, ['intent', 'approve', slug]);
      return {
        ...common,
        invalid_refused: invalidPlanRefused(code, out),
        no_model: requests(c).length === n,
        invalid_unchanged: sameValue(snapshot(), before) && sameValue(await custody(c), start) && !fs.existsSync(legacySource),
        no_approval: !fs.existsSync(H.approvalPath(c.repo, slug)),
        invalid_output: out,
        invalid_status: code,
      };
    }

    if (mode === 'refine') {
      const changed = md.replaceAll('Foundation', 'Reconciled foundation');
      const correction = path.join(c.root, 'correction.md');
      fs.writeFileSync(correction, 'Rename the first approved stage to Reconciled foundation; preserve scope and checks.');
      append(c, [f('read_file', { path: intentMd('fixture') }), f('submit_refinement', { files: [{ path: intentMd('fixture'), content: changed }] }), f('submit_refinement', { files: [{ path: intentMd('fixture'), content: changed }] })]);
      const refined = await H.runKogen(c, ['intent', 'refine', 'fixture', hash, correction]);
      const revoked = !fs.existsSync(H.approvalPath(c.repo, 'fixture'));
      const n = requests(c).length;
      const blocked = await H.runKogen(c, ['intent', 'build', 'fixture']);
      const newcard = await H.runKogen(c, ['intent', 'approve', 'fixture']);
      return {
        ...common,
        refined: refined.code === 0,
        refine_output: refined.out,
        revoked,
        build_needs_approval: blocked.code !== 0 && blocked.out.includes('not_approved') && requests(c).length === n,
        changed_card: newcard.code === 5 && newcard.out.includes('Reconciled foundation'),
        no_commit: (await git(c, ['rev-parse', 'HEAD'])) === start.head,
      };
    }

    if (mode === 'single') {
      append(c, [write('final'), finish(), approveReview()]);
      const built = await H.runKogen(c, ['intent', 'build', 'fixture']);
      return {
        ...common,
        landed: built.code === 0,
        output: built.out,
        commits: await git(c, ['rev-list', '--count', `${start.head}..HEAD`]),
        stage_trace: trace(c).filter(t => t.kind.startsWith('stage-')),
        final_trace: trace(c).filter(t => t.kind === 'acceptance').map(t => t.state),
      };
    }

    return flow(c, mode, start, common);
  }

  async function flow(c, mode, start, common) {
    const privateMessage = { type: 'message', id: 'stage-builder-private', role: 'assistant', phase: 'commentary', content: [{ type: 'output_text', text: 'BUILDER_PRIVATE_STAGE_CONVERSATION' }] };
    const privateReasoning = { type: 'reasoning', id: 'stage-opaque', encrypted_content: 'opaque-stage+/==', summary: [] };
    const effect = { type: 'function_call', id: 'stage-effect-item', call_id: 'stage-effect-call', name: 'shell', arguments: JSON.stringify({ command: "printf 'once\\n' >> .kogen/local/effects" }) };

    append(c, [{ items: [privateMessage, privateReasoning, effect] }, write('broken'), finish(), write('phase-one'), finish(), { http: [400, { error: { message: 'fixture stop', code: 'invalid_request_error' } }] }]);
    let n = requests(c).length;
    const first = await H.runKogen(c, ['intent', 'build', 'fixture']);
    const firstRequests = requests(c).slice(n);
    const checkpoints = runPaths(c, 'checkpoint.json');
    assert.equal(checkpoints.length, 1, `expected one checkpoint: ${checkpoints}\n${first.out}`);
    const runDir = path.dirname(checkpoints[0]);
    const resultPath = path.join(runDir, 'result.json');
    const oldResult = fs.readFileSync(resultPath);
    const stopped = JSON.parse(oldResult.toString('utf8'));
    const stoppedCustody = await custody(c);
    const firstTrace = trace(c);
    if (mode === 'candidate-drift') put(c, 'app.txt', 'operator edit\n');
    if (mode === 'plan-drift') put(c, intentMd('fixture'), fs.readFileSync(path.join(c.repo, intentMd('fixture')), 'utf8') + '\nSubstantive changed stage contract\n');

    if (mode === 'other-checkout') {
      const other = path.join(c.root, 'other-checkout');
      await H.checked('cp', ['-R', c.repo, other]);
      c = { ...c, repo: other };
    }

    const beforeResume = await custody(c);
    const id = path.basename(runDir);
    append(c, [write('phase-two'), finish(), write('final'), finish(), write('review-broken'), approveReview(), write('final-reviewed'), approveReview()]);
    n = requests(c).length;
    const last = await H.runKogen(c, ['intent', 'resume', id]);
    const resumed = requests(c).slice(n);
    const originalLog = path.join(c.repo, `.kogen/local/runs/${id}/log.jsonl`);
    const logs = [originalLog, ...runPaths(c, 'log.jsonl').filter(p => p !== originalLog)];
    const rows = logs.filter(p => fs.existsSync(p)).flatMap(p => fs.readFileSync(p, 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l)));
    const reviews = c.server.reviewRequests();
    const finalTrace = trace(c);

    return {
      ...common,
      first_stopped: first.code !== 0 && stoppedCustody.head === start.head,
      stop_index_approval: stoppedCustody.index === start.index && stoppedCustody.approval === start.approval,
      stage_progress: stopped.stage_progress,
      stage_trace: finalTrace.filter(t => t.kind.startsWith('stage-')),
      no_full_before_stop: !firstTrace.some(t => t.kind === 'acceptance'),
      no_review_before_stop: !firstRequests.some(r => H.FakeProvider.inputText(r).includes('You review code')),
      resume_exact: resumed.length > 0 && sameValue(input(resumed[0]), input(firstRequests.at(-1))),
      first_result_unchanged: fs.readFileSync(resultPath).equals(oldResult),
      effect_once: fs.readFileSync(path.join(c.repo, '.kogen/local/effects'), 'utf8') === 'once\n',
      landed: last.code === 0,
      commits: await git(c, ['rev-list', '--count', `${start.head}..HEAD`]),
      final_trace: finalTrace.filter(t => t.kind === 'acceptance').map(t => t.state),
      model_executed: rows.some(r => r.event === 'command_result' && r.name === 'model' && r.status === 0),
      configured_final: finalTrace.some(t => t.kind === 'configured' && t.state === 'final-reviewed' && t.status === 0),
      reviewer_repair_feedback: reviews.some(r => JSON.stringify(input(r)).includes('review-broken') && JSON.stringify(input(r)).includes('not green')),
      independent: reviews.length > 0 && !H.FakeProvider.inputText(reviews[0]).includes('BUILDER_PRIVATE_STAGE_CONVERSATION'),
      stage_records: rows.filter(r => r.event === 'stage_pass').map(r => ({ stage_id: r.stage_id, green: r.green })),
      refused: last.code !== 0 && /resume_refused|resume_unsupported/.test(last.out),
      refusal_unchanged: sameValue(await custody(c), beforeResume),
      no_model: resumed.length === 0,
      first_output: first.out,
      output: last.out,
    };
  }
}
