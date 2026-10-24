'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { isDeepStrictEqual } = require('node:util');
const H = require('./go_driver_support.js');
const FEATURE = '.kogen/intents/protected-harness-readiness/acceptance.feature';
const NOTICE = 'Skipped steps are unexercised; readiness does not prove their behavior or fixture validity.';
const hasLine = (out, line) => out.split('\n').some(s => s.trim() === line);
function view(record, out) {
  const scenarios = record.scenarios.map(s => ({ name: s.name, line: s.line, status: s.status, unexercised_steps: s.unexercised_steps ?? null }));
  const skipped = scenarios.flatMap(s => s.unexercised_steps || []);
  return {
    scenarios,
    notice: hasLine(out, NOTICE),
    listed: skipped.length > 0 && skipped.every(s => hasLine(out, `acceptance.feature line ${s.line}: ${s.keyword.trim()} ${s.text}`)),
    counted: skipped.length > 0 && hasLine(out, `Unexercised acceptance steps: ${skipped.length}`),
  };
}
function compare(actual, expected) {
  const errors = [];
  for (const [key, value] of Object.entries(expected)) {
    try { assert.deepEqual(actual[key], value); }
    catch { errors.push(`${key}: expected ${JSON.stringify(value)}, observed ${JSON.stringify(actual[key])}`); }
  }
  assert.equal(errors.length, 0, errors.join('\n'));
}
async function exercise(mode) {
  const suite = await H.setupSuite();
  let c;
  try {
    c = await H.project(suite, [], { stagedIntent: false });
    const put = (p, b) => { const f = path.join(c.repo, p); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, b); };
    const slug = 'fixture', ft = H.featurePath(slug), step = 'features/steps/integration_steps.js';
    const trace = path.join(c.root, 'history.jsonl'), runs = path.join(c.root, 'runs.txt');
    const lines = p => fs.existsSync(p) ? fs.readFileSync(p, 'utf8').split('\n').filter(Boolean) : [];
    fs.rmSync(H.approvalPath(c.repo, slug), { force: true });
    const baseline = await H.git(c, ['rev-parse', 'HEAD']);
    const history = [['diff', baseline, '--', 'app.txt'], ['ls-files', '--with-tree=' + baseline, '--', 'app.txt'], ['show', baseline + ':app.txt']];
    const sourceStatuses = [];
    for (const args of history) sourceStatuses.push((await H.run('git', args, { cwd: c.repo, env: H.envFor(c) })).code);
    const common = `const {Given,Then,Before}=require('@cucumber/cucumber'); const assert=require('node:assert/strict'); const fs=require('node:fs'); const {spawnSync}=require('node:child_process');\n`;
    let feature, body;
    if (mode === 'history') {
      feature = 'Feature: History fixture\n  Scenario: Masked history\n    Given the implementation exists\n    Then the historical baseline is readable\n    And the final assertion runs\n';
      body = common + `Given('the implementation exists',()=>assert.equal(fs.readFileSync('app.txt','utf8'),'implemented\\n','missing implementation'));\nThen('the historical baseline is readable',()=>{const statuses=${JSON.stringify(history)}.map(args=>spawnSync('git',args,{encoding:'utf8'}).status);fs.appendFileSync(${JSON.stringify(trace)},JSON.stringify(statuses)+'\\n');assert.deepEqual(statuses,[0,0,0],'history fixture');});\nThen('the final assertion runs',()=>assert.ok(true));\n`;
    } else if (mode === 'hook') {
      feature = 'Feature: Hook fixture\n  Background:\n    Given background is available\n  Scenario: Failed before hook\n    Then the final assertion runs\n';
      body = common + "Before(()=>{throw new Error('hook fixture failed');});\nGiven('background is available',()=>assert.ok(true));\nThen('the final assertion runs',()=>assert.ok(true));\n";
    } else if (mode === 'outline') {
      feature = 'Feature: Outline fixture\n  Background:\n    Given background is available\n  Scenario Outline: Case <value>\n    Given value <value> is implemented\n    Then result <value> is checked\n    And final <value> is checked\n    Examples:\n      | value |\n      | first |\n      | second |\n';
      body = common + "Given('background is available',()=>assert.ok(true));\nGiven('value {word} is implemented',value=>assert.notEqual(value,'first','missing first implementation'));\nThen('result {word} is checked',value=>assert.ok(value));\nThen('final {word} is checked',value=>assert.ok(value));\n";
    } else throw new Error('unsupported mode: ' + mode);
    const md = `# Inspect the fixture\n\nSlug: ${slug}\nModel: not applicable — diagnostic fixture\nAcceptance:\n- ${ft}\n- ${step}\n\n## Decisions\n- Observe the local fixture. (source: request)\n\n## Source comparison\n- addressed: local diagnostic fixture; source request; contract acceptance.feature.\n\n## Tests\n- fixture observation: real Cucumber (integration)\n\n## Feasibility\n- none\n`;
    put(H.intentMd(slug), md); put(ft, feature); put(step, body);
    put('runner.cjs', `const fs=require('node:fs');const {spawnSync}=require('node:child_process');fs.appendFileSync(${JSON.stringify(runs)},'run\\n');const r=spawnSync(process.env.KOGEN_NODE,[process.env.KOGEN_CUCUMBER+'/@cucumber/cucumber/bin/cucumber.js','--strict','--require','features/steps/*.js','--format','message:'+process.env.KOGEN_ACCEPTANCE_REPORT,process.env.KOGEN_ACCEPTANCE_FEATURES],{stdio:'inherit',env:{...process.env,NODE_PATH:process.env.KOGEN_CUCUMBER}});process.exit(r.status===null?99:r.status);\n`);
    H.configure(c, { acceptance: { run: '"$KOGEN_NODE" runner.cjs', stepsDir: 'features/steps' } });
    await H.gitBang(c, ['add', '.kogen/project.yaml', 'runner.cjs']);
    await H.gitBang(c, ['commit', '-qm', 'Configure local runner']);
    const head = await H.git(c, ['rev-parse', 'HEAD']);
    const index = fs.readFileSync(path.join(c.repo, '.git/index'));
    const recordPath = path.join(c.repo, `.kogen/local/readiness/${slug}.json`);
    const card = async () => {
      const r = await H.runKogen(c, ['intent', 'approve', slug]);
      assert.equal(r.code, 5, r.out);
      const rec = JSON.parse(fs.readFileSync(recordPath, 'utf8'));
      return { ...view(rec, r.out), failure: (rec.scenarios.find(s => s.status === 'failed') || {}).detail || '', rec, out: r.out };
    };
    const first = await card();
    const visible = x => ({ scenarios: x.scenarios, notice: x.notice, listed: x.listed, counted: x.counted });
    const result = { first: visible(first), source_statuses: sourceStatuses };
    const n = lines(runs).length;
    const cached = await card();
    result.retained = { executions: lines(runs).length - n, same: isDeepStrictEqual(cached.scenarios, first.scenarios), notice: cached.notice };
    // Schema completeness only: do not broaden the established evidence identity/reuse policy.
    const old = JSON.parse(JSON.stringify(cached.rec));
    for (const s of old.scenarios) delete s.unexercised_steps;
    fs.writeFileSync(recordPath, JSON.stringify(old));
    const nOld = lines(runs).length;
    await card();
    result.incomplete_record_executions = lines(runs).length - nOld;
    if (mode === 'history') {
      result.initial_history_executions = lines(trace).length;
      put('app.txt', 'implemented\n');
      const reached = await card();
      result.reached = { ...visible(reached), history_failure: reached.failure.includes('history fixture') };
      result.scratch_statuses = lines(trace).map(JSON.parse);
      // Explicit local fixture correction between cards, never a Build protected edit.
      put(step, common + "Given('the implementation exists',()=>assert.equal(fs.readFileSync('app.txt','utf8'),'implemented\\n'));\nThen('the historical baseline is readable',()=>assert.equal(spawnSync('git',['ls-files','--error-unmatch','app.txt'],{encoding:'utf8'}).status,0));\nThen('the final assertion runs',()=>assert.ok(true));\n");
      const fixed = await card();
      result.corrected = visible(fixed);
    }
    if (mode === 'hook') result.hook_failure_retained = first.failure.includes('hook fixture failed') && first.failure.includes('hook');
    result.no_approval = !fs.existsSync(H.approvalPath(c.repo, slug));
    result.index_and_head_unchanged = fs.readFileSync(path.join(c.repo, '.git/index')).equals(index) && await H.git(c, ['rev-parse', 'HEAD']) === head;
    result.no_provider_calls = c.server.providerRequests().length === 1; // local synthetic init only
    return result;
  } finally { if (c) await H.cleanupCase(c); H.cleanupSuite(suite); }
}
function controls(which) {
  const text = fs.readFileSync(path.join(H.ROOT, FEATURE), 'utf8');
  const expected = [...text.matchAll(/"""\s*\n([\s\S]*?)\n\s*"""/g)].map(m => JSON.parse(m[1]));
  assert.equal(expected.length, 3);
  const fixtures = JSON.parse(fs.readFileSync(path.join(H.ROOT, 'features/steps/protected_harness_readiness_controls.json'), 'utf8'));
  for (const f of fixtures) compare(view(f.record, f.out), expected[f.expectation][f.section]);
  if (which === 'good') { console.log('observer accepts known-good reports'); return; }
  assert.equal(which, 'bad');
  let accepted = false;
  function reject(f, mutate) {
    const bad = structuredClone(f); mutate(bad);
    try { compare(view(bad.record, bad.out), expected[f.expectation][f.section]); accepted = true; }
    catch (e) { if (!(e instanceof assert.AssertionError)) throw e; }
  }
  // Independent corruptions reach the real projection/comparator without an early product red.
  for (const f of fixtures) {
    reject(f, b => { delete b.record.scenarios[0].unexercised_steps; });
    reject(f, b => { b.record.scenarios[0].status = 'unknown'; });
    reject(f, b => { b.record.scenarios[0].line += 1; });
    const steps = f.record.scenarios[0].unexercised_steps;
    if (steps.length) {
      reject(f, b => { b.record.scenarios[0].unexercised_steps.reverse(); });
      reject(f, b => { b.record.scenarios[0].unexercised_steps = []; });
      reject(f, b => { b.record.scenarios[0].unexercised_steps[0].text += ' wrong'; });
      reject(f, b => { b.out = b.out.split('\n').filter(l => l !== NOTICE).join('\n'); });
      reject(f, b => { b.out = b.out.split('\n').filter(l => !l.startsWith('acceptance.feature line ')).join('\n'); });
      reject(f, b => { b.out = b.out.replace('Unexercised acceptance steps: 2', 'Unexercised acceptance steps: 99'); });
    } else reject(f, b => { b.out += '\n' + NOTICE + '\n'; });
  }
  if (accepted) { console.log('observer accepted a corrupt report'); process.exitCode = 0; }
  else { console.log('observer rejects independently corrupted reports'); process.exitCode = 1; }
}
if (require.main === module) {
  (async () => {
    if (process.argv[2] === '--control') controls(process.argv[3]);
    else if (process.argv[2] === '--explore') console.log(JSON.stringify(await exercise(process.argv[3]), null, 2));
    else throw new Error('unsupported control');
  })().catch(e => { console.error(e.stack); process.exitCode = 1; });
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('I inspect protected harness readiness for {string}', { timeout: 600000 }, async function (mode) { this.protectedHarness = await exercise(mode); });
  Then('the protected harness observations are:', function (json) { compare(this.protectedHarness, JSON.parse(json)); });
}
module.exports = { view, compare };
