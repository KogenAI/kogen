const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { isDeepStrictEqual } = require('node:util');
const { When, Then } = require('@cucumber/cucumber');
const H = require('./go_driver_support.js');
let exercise;

// Reuse the installed-release fixture and fake provider, but do not depend on implementation tests or their
// assertions. Only these steps are frozen. The installed `kogen` (the one Go program) is driven and its files are read.
async function runMode(suite, mode) {
  const c = await H.project(suite, [], { stagedIntent: false });
  try {
    const slug = mode === 'shape' ? 'compact-observed' : 'fixture';
    const intent = H.intentMd(slug), feature = H.featurePath(slug);
    const helper = mode === 'shape' ? 'features/steps/compact_observed.js' : 'features/steps/integration_steps.js';
    const trace = path.join(c.root, 'compact-readiness-runs');
    const original = fs.readFileSync(path.join(c.repo, '.kogen/project.yaml'), 'utf8');
    const stepsDir = /steps_dir: '?([^'\n]+)'?/.exec(original)[1];
    const acceptanceRun = /^    run: '((?:[^']|'')*)'$/m.exec(original)[1].replaceAll("''", "'");
    const run = `if grep -q 'Scenario:' "$KOGEN_ACCEPTANCE_FEATURES"; then printf 'run\\n' >> '${trace}'; fi; ${acceptanceRun}`;
    H.configure(c, { acceptance: { run, stepsDir } });
    await H.gitBang(c, ['add', '.kogen/project.yaml']);
    await H.gitBang(c, ['commit', '-qm', 'Count compact readiness executions']);
    const hash = () => H.baselineHash(c, slug);
    // Refresh approval for the changed configuration, before freezing Refine.
    if (mode === 'refine') { const r = await H.runKogen(c, ['intent', 'approve', slug, await hash()]); assert.equal(r.code, 0, r.out); }
    const count = () => fs.existsSync(trace) ? fs.readFileSync(trace, 'utf8').split('\n').filter(Boolean).length : 0;
    const beforeCount = count();
    const readAll = async () => Object.fromEntries((await H.baselinePaths(c, slug)).map(p => [p, fs.readFileSync(path.join(c.repo, p), 'utf8')]));
    const originalBaseline = mode === 'refine' ? await readAll() : { '.kogen/project.yaml': fs.readFileSync(path.join(c.repo, '.kogen/project.yaml'), 'utf8') };
    const md = mode === 'shape'
      ? `# Observe compact acknowledgements\n\nSlug: ${slug}\nModel: not applicable \u2014 no state changes\nAcceptance:\n- ${feature}\n- ${helper}\n\n## Source comparison\n- addressed: compact acknowledgement stays observable; source request; contract Tests and acceptance.feature.\n\n## Tests\n- compact fixture: actual scenario (regression)\n\n## Feasibility\n- none\n`
      : fs.readFileSync(path.join(c.repo, intent), 'utf8');
    const ft = 'Feature: Compact acknowledgement\n  Scenario: Legitimate product red\n    Then compact product behavior exists\n';
    const body = message => `const { Then } = require('@cucumber/cucumber');\nThen('compact product behavior exists', function () { throw new Error('${message}'); });\n// large helper body\n${'// retained fixture padding\n'.repeat(100)}`;
    const initialHelper = body('incorrect fixture input'), correctedHelper = body('legitimate missing product behavior');
    const initial = [{ path: intent, content: md }, { path: feature, content: ft }, { path: helper, content: initialHelper }];
    const tool = mode === 'shape' ? 'submit' : 'submit_refinement';
    const submit = files => H.fn(tool, { files });
    const unsafe = [{ path: helper, content: "throw new Error('POISON MUST NOT SURVIVE');\n" }, { path: '../outside', content: 'unsafe' }];
    const ack = [{ path: feature, content: ft }];
    // A shaper inspects the repository before it declares readiness (shape/uninspected otherwise).
    c.server.setScript([H.fn('read_file', { path: 'README.md' }), submit([]), submit(initial), submit(unsafe), submit([{ path: helper, content: correctedHelper }]), submit(ack)]);
    const request = path.join(c.root, 'compact-request.txt');
    fs.writeFileSync(request, 'Inspect readiness; correct fixture inputs and acknowledge legitimate missing-feature red with the smallest eligible current-candidate artifact.');
    const args = mode === 'shape' ? ['intent', 'shape', slug, request] : ['intent', 'refine', slug, await hash(), request];
    const { out: output, code: status } = await H.runKogen(c, args);
    if (status !== 0) throw new Error(`${mode} failed: ${output}`);
    const requests = c.server.providerRequests().map(r => r.json).filter(req => (req.tools || []).some(t => t.name === tool));
    const first = requests[0];
    const definition = first.tools.find(t => t.name === tool);
    const prompt = `${first.instructions || ''}\n${definition.description || ''}`;
    const feedback = c.server.toolOutputs();
    const observations = feedback.filter(x => x.includes('Readiness observations')).join('\n');
    const expected = { ...originalBaseline, [intent]: md, [feature]: ft, [helper]: correctedHelper };
    const baseline = await H.baselinePaths(c, slug);
    const actual = await readAll();
    const record = JSON.parse(fs.readFileSync(path.join(c.repo, `.kogen/local/readiness/${slug}.json`), 'utf8'));
    const head = await H.git(c, ['rev-parse', 'HEAD']);
    // Cached readiness is usable when its record is a ready version-3 record for this baseline hash and HEAD.
    const ready = record.version === 3 && record.outcome === 'ready' && record.sha256 === await hash() && record.head === head;
    const size = x => Buffer.byteLength(x);
    const submittedSmallest = size(ft) === Math.min(...[md, ft, correctedHelper].map(size)) && ack.length === 1;
    return {
      'files minItems': (((definition.parameters || {}).properties || {}).files || {}).minItems || 0,
      'empty submission rejected': feedback.some(x => (x.startsWith('invalid:') || x.startsWith('invalid submission:')) && !x.includes('Readiness observations')),
      'unsafe submission rejected': feedback.some(x => x.includes('No proposals from this submission were retained') || x.includes('no proposals from this submission were retained')),
      'candidate readiness executions': count() - beforeCount,
      'smallest artifact submitted': submittedSmallest,
      'exact complete package retained': isDeepStrictEqual(actual, expected) && !fs.existsSync(path.join(c.root, 'outside')),
      'evidence matches complete inputs': ready && isDeepStrictEqual(record.baseline, baseline),
      'no approval': !fs.existsSync(H.approvalPath(c.repo, slug)),
      prompt: prompt.toLowerCase(), feedback: observations.toLowerCase(),
    };
  } finally { await H.cleanupCase(c); }
}
async function runExercise() {
  const suite = await H.setupSuite();
  try { const results = {}; for (const mode of ['shape', 'refine']) results[mode] = await runMode(suite, mode); return results; }
  finally { H.cleanupSuite(suite); }
}
When('I exercise compact acknowledgement through installed {string}', { timeout: 400000 }, async function (operation) {
  if (!exercise) exercise = runExercise();
  const results = await exercise;
  assert.ok(Object.hasOwn(results, operation), operation);
  this.compactAck = results[operation];
});
Then('the compact acknowledgement observations are:', function (table) {
  const failures = [];
  for (const row of table.hashes()) {
    const name = row.observation, expected = row.expected;
    let actual;
    if (name === 'prompt contains' || name === 'feedback contains') {
      actual = this.compactAck[name.split(' ')[0]].includes(expected.toLowerCase());
      if (!actual) failures.push(`${name}: missing ${JSON.stringify(expected)}`);
    } else if (name === 'obsolete feedback absent') {
      if (this.compactAck.feedback.includes(expected.toLowerCase())) failures.push(`${name}: ${expected}`);
    } else {
      actual = String(this.compactAck[name]);
      if (actual !== expected) failures.push(`${name}: expected ${expected}, got ${actual}`);
    }
  }
  assert.deepEqual(failures, []);
});
