const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { Given, When, Then } = require('@cucumber/cucumber');
const REPO = path.resolve(__dirname, '../..');
let exercise, exerciseInput;

// Independent protected harness. Installation/HTTP transport helpers are reused,
// never the implementation's obligation parser, validator, or test assertions.
// Everything is observed through the installed `kogen` (the one Go program) and the files it keeps.
const H = require('./go_driver_support.js');
const { fn: f } = H;
const sha = x => crypto.createHash('sha256').update(x).digest('hex');
const same = (a, b) => JSON.stringify(sortKeys(a)) === JSON.stringify(sortKeys(b));
const ORIGINAL = `"Repair unsupported cache capability fallback" - that means our shaping process isn't good, right?
Aren't we supposed to do probing during shaping? We wasted hours and hours basically for something that could have been figured out during shaping with a couple of curl calls, right?
So what's the status of cache now?
Are we even used those endpoints mentioned in the docs?
There are multiple login routes and multiple API endpoints for conversations.
So, are using proper ones?

For the Studio stuff, what's the problem? Were we not thorough enough during some of the phases? How come you've had to verify outside Kogen shaping, build, and review to find out that Kogen build of Studio wasn't thorough? These are all Kogen issues - we gotta fix them.
What else did we encounter in this conversation? What other Kogen issues?
`;

async function runMode(suite, mode, spec) {
  const c = await H.project(suite, [], { stagedIntent: false });
  try {
    const put = (p, bytes) => { const full = path.join(c.repo, p); fs.mkdirSync(path.dirname(full), { recursive: true }); fs.writeFileSync(full, bytes); };
    const readRecord = slug => { try { return JSON.parse(fs.readFileSync(path.join(c.repo, `.kogen/local/readiness/${slug}.json`), 'utf8')); } catch { return {}; } };
    const lines = p => fs.existsSync(p) ? fs.readFileSync(p, 'utf8').split('\n').filter(Boolean) : [];
    const trace = path.join(c.root, 'controls.trace'), acceptanceTrace = path.join(c.root, 'acceptance.trace');
    const yaml = fs.readFileSync(path.join(c.repo, '.kogen/project.yaml'), 'utf8');
    const stepsDir = /steps_dir: '?([^'\n]+)'?/.exec(yaml)[1];
    const acceptanceRun = /^    run: '((?:[^']|'')*)'$/m.exec(yaml)[1].replaceAll("''", "'");
    H.configure(c, { acceptance: { run: `if grep -q 'Scenario:' "$KOGEN_ACCEPTANCE_FEATURES"; then printf 'run\\n' >> '${acceptanceTrace}'; fi; ${acceptanceRun}`, stepsDir } });
    const routeBytes = JSON.stringify(spec.capability);
    put('route.json', routeBytes);
    put('route.cjs', `const fs=require('node:fs');const s=fs.readFileSync('route.json','utf8');console.log(s);process.exit(JSON.parse(s).error?${spec.rejection_exit}:0);\n`);
    const selected = spec.cases[0];
    const controlBytes = item => JSON.stringify(Object.fromEntries(['good', 'bad'].map(k => [k, { ...item[k], kind: item.id }])));
    put('controls.json', controlBytes(selected));
    await H.gitBang(c, ['add', '.kogen/project.yaml', 'route.json', 'route.cjs', 'controls.json']);
    await H.gitBang(c, ['commit', '-qm', 'Configure local evidence controls']);
    const head = () => H.git(c, ['rev-parse', 'HEAD']);
    const initialHead = await head(), initialIndex = fs.readFileSync(path.join(c.repo, '.git/index'));
    const slug = mode === 'refine' ? 'fixture' : `quality-${mode}`;
    const md = H.intentMd(slug), ft = H.featurePath(slug);
    const observer = mode === 'refine' ? 'features/steps/integration_steps.js' : 'features/steps/quality.js';
    const observerBody = flawed => `
const fs=require('node:fs'); const assert=require('node:assert/strict');
const flawed=${flawed};
function equal(a,b){try{assert.deepEqual(a,b);return true;}catch{return false;}}
function observe(d){
  switch(d.kind){
    case 'json-object': {const a=JSON.parse(d.actual_json),b=JSON.parse(d.expected_json);return flawed ? JSON.stringify(a)===JSON.stringify(b) : equal(a,b);}
    case 'json-array': return flawed ? equal([...d.actual].sort(),[...d.expected].sort()) : equal(d.actual,d.expected);
    case 'json-string': return flawed ? d.actual.replaceAll(' ','')===d.expected.replaceAll(' ','') : d.actual===d.expected;
    case 'oklch': {const m=d.actual.match(flawed ? /^rgb\\((\\d+)/ : /^oklch\\(([0-9.]+)/); return !!m && Number(m[1])<=d.maximum;}
    case 'markdown': return d.actual.includes(flawed ? d.raw : d.rendered);
    case 'search': {const event=flawed?d.events.at(-1):d.events.find(e=>e.action==='search');return event.results.includes(d.query);}
    case 'history': return d.actual.actor===(flawed?'guessed-user':d.seed.actor);
    case 'cold-output': return (flawed?d.stdout:d.payload)===d.expected;
    case 'legacy-84-plus-one': return flawed ? equal(d.actual.data.totals,d.expected.data.totals) : equal(d.actual,d.expected);
    default: throw new Error('unknown local control '+d.kind);
  }
}
const fixture=()=>JSON.parse(fs.readFileSync('controls.json','utf8'));
if(require.main===module){const ok=observe(fixture()[process.argv[2]]);process.stdout.write(ok?'accepted\\n':'rejected\\n');process.exit(ok?0:1);}
else {const {Given,Then}=require('@cucumber/cucumber');
  Given('the requested product is not implemented',()=>{throw new Error('legitimate missing product');});
  Then('the protected observer accepts the good fixture',()=>{assert.equal(observe(fixture().good),true);});
}
`;
    const goodBody = observerBody(false), badBody = observerBody(true);
    const command = text => `printf 'control\\n' >> '${trace}'; ${text}`;
    const observerObligation = suffix => ({ id: 'protected-observer', kind: 'observer', inputs: ['controls.json'], observers: [observer], checks: ['good', 'bad'].map(name => ({ ...spec[name], name, command: command(`node ${observer} ${name}${suffix}`) })) });
    const routeObligation = honest => ({ id: 'target-route', kind: 'capability', inputs: ['route.json', 'route.cjs'], observers: [], checks: [{ name: 'support', command: command('node route.cjs'), exit: honest ? spec.rejection_exit : 0, output: honest ? `${routeBytes}\n` : 'supported\n' }] });
    const text = obligations => {
      const feasibility = obligations.length === 0 ? '- none' : obligations.map(o => `- evidence: ${JSON.stringify(o)}`).join('\n');
      return `# Qualify the local evidence fixture\n\nSlug: ${slug}\nModel: not applicable — local fixture controls\nAcceptance:\n- ${ft}\n- ${observer}\n\n## Decisions\n- Use bounded local controls. (source: request)\n\n## Source comparison\n- addressed: bounded local controls stay; source request; contract Tests and acceptance.feature.\n\n## Tests\n- missing product and observer controls: actual commands (regression)\n\n## Feasibility\n${feasibility}\n`;
    };
    const feature = 'Feature: Actual local observer\n  Scenario: Missing product masks a later protected assertion\n    Given the requested product is not implemented\n    Then the protected observer accepts the good fixture\n';
    const pkg = (obligations, body) => [{ path: md, content: text(obligations) }, { path: ft, content: feature }, { path: observer, content: body }];
    const writePkg = files => files.forEach(x => put(x.path, x.content));
    const sub = (tool, files) => f(tool, { files });
    const ack = tool => sub(tool, [{ path: ft, content: feature }]);
    const script = actions => c.server.setScript(actions);
    const request = path.join(c.root, 'request.txt');
    const requestBytes = `${ORIGINAL}\nKnown supplied counterexamples (exercise in acceptance):\n${JSON.stringify(spec.cases)}\nRequire truthful external pixel handoff; no native image capability is asserted.\n`;
    fs.writeFileSync(request, requestBytes);
    const invoke = args => H.runKogen(c, args);
    const count = () => lines(trace).length;
    const card = () => invoke(['intent', 'approve', slug]);
    const hash = () => H.baselineHash(c, slug);
    const recordPath = path.join(c.repo, `.kogen/local/readiness/${slug}.json`);
    const proof = async obligations => {
      const r = readRecord(slug), actual = r.feasibility || [];
      const identities = paths => Object.fromEntries(paths.map(p => [p, sha(fs.readFileSync(path.join(c.repo, p)))]));
      return r.sha256 === await hash() && r.head === await head() && r.candidate_tree === await H.candidateTree(c, await head()) && actual.length === obligations.length &&
        actual.every((a, i) => { const d = obligations[i]; return a.id === d.id && a.kind === d.kind && same(a.inputs, identities(d.inputs)) && same(a.observers, identities(d.observers)) && Array.isArray(a.checks) && a.checks.length === d.checks.length && a.checks.every((ac, j) => { const dc = d.checks[j]; const taken = Object.fromEntries(['name', 'command', 'exit', 'output'].filter(k => k in ac).map(k => [k, ac[k]])); return same(sortKeys(taken), sortKeys(dc)) && ac.timed_out === false; }); });
    };
    const red = () => (readRecord(slug).scenarios || []).some(s => s.status === 'failed' && String(s.detail || '').includes('legitimate missing product'));
    const feedback = () => { const last = c.server.providerRequests().at(-1); return last ? (last.json.input || []).filter(i => i.type === 'function_call_output').map(i => i.output || '') : []; };
    const refused = id => feedback().filter(x => x.includes('not ready') && x.includes(id)).length >= 2;
    let results;
    if (['ordinary', 'capability', 'masked'].includes(mode)) {
      const obligations = { ordinary: [], capability: [routeObligation(true)], masked: [observerObligation('')] }[mode];
      const actions = {
        ordinary: [sub('submit', pkg([], goodBody)), ack('submit')],
        capability: [sub('submit', pkg([routeObligation(false)], goodBody)), ack('submit'), sub('submit', [{ path: md, content: text(obligations) }]), ack('submit')],
        masked: [sub('submit', pkg(obligations, badBody)), ack('submit'), sub('submit', [{ path: observer, content: goodBody }]), ack('submit')],
      }[mode];
      // A shaper inspects the repository before it declares readiness (shape/uninspected otherwise).
      script([H.fn('read_file', { path: 'README.md' }), ...actions]);
      const { out, code: status } = await invoke(['intent', 'shape', slug, request]);
      const beforeCard = lines(acceptanceTrace).length;
      const noApproval = !fs.existsSync(H.approvalPath(c.repo, slug));
      const { code: cardStatus } = await card();
      const { code: approveStatus } = await invoke(['intent', 'approve', slug, await hash()]);
      const requests = c.server.providerRequests();
      const inputs = requests.map(r => H.FakeProvider.inputText(r)).join('\n');
      const policyText = r => [r.json.instructions || '', ...(r.json.input || []).filter(i => i.role === 'developer').flatMap(i => (i.content || []).filter(b => b.type === 'input_text' && typeof b.text === 'string').map(b => b.text))].join('\n');
      const instructions = requests.map(policyText).join('\n').toLowerCase();
      const events = lines(path.join(c.repo, `.kogen/local/shaping/${slug}/events.ndjson`)).map(l => JSON.parse(l));
      const allFeedback = feedback().join('\n');
      const id = mode === 'capability' ? 'target-route' : 'protected-observer';
      results = {
        'shape exit': status, 'card exit': cardStatus, 'exact approval exit': approveStatus,
        'acceptance executions': lines(acceptanceTrace).length, 'acceptance before card': beforeCard,
        'feasibility probe executions': events.filter(e => e.event === 'probe_result').length,
        'Shape did not approve': noApproval, 'complete request delivered': inputs.includes(requestBytes),
        'critical guidance delivered': spec.guidance.every(g => instructions.includes(g)),
        'unchanged acknowledgment refused': refused(id), 'diagnostic names failed obligation': allFeedback.includes(id),
        'actual rejection returned': allFeedback.includes('invalid_parameter') && allFeedback.includes('prompt_cache_options') && allFeedback.includes(String(spec.rejection_exit)),
        'corrected observer published': fs.existsSync(path.join(c.repo, observer)) && fs.readFileSync(path.join(c.repo, observer), 'utf8') === goodBody,
        'exact proof': await proof(obligations), 'product red retained': red(), output: out,
      };
    } else if (mode === 'counterexamples') {
      const cases = {};
      for (const item of spec.cases) {
        put('controls.json', controlBytes(item));
        const obligations = [observerObligation('')];
        writePkg(pkg(obligations, badBody));
        fs.rmSync(recordPath, { force: true });
        const bad = await card();
        const invalid = ![0, 5].includes(bad.code) && bad.out.includes('protected-observer');
        writePkg(pkg(obligations, goodBody));
        const n = count();
        const good = await card();
        cases[item.id] = { 'faulty observer refused': invalid, 'corrected observer ready': good.code === 5, 'both controls executed': count() - n === 2, 'exact proof': await proof(obligations), 'bad output': bad.out, 'good output': good.out };
      }
      results = { cases };
    } else if (mode === 'binding') {
      const obligations = [observerObligation('')];
      writePkg(pkg(obligations, goodBody));
      let n = count(); await card(); const first = count() - n;
      const initial = await proof(obligations);
      const measured = async action => { await action(); const k = count(); await card(); return count() - k; };
      const repeat = await measured(() => {});
      n = count(); await invoke(['intent', 'approve', slug, await hash()]); const approve = count() - n;
      const observerChange = await measured(() => put(observer, `${goodBody}\n// final observer bytes changed\n`));
      const inputChange = await measured(() => put('controls.json', `${controlBytes(selected)}\n`));
      const next = [observerObligation(' ')];
      const commandChange = await measured(() => put(md, text(next)));
      const forged = await measured(() => {
        const r = readRecord(slug); const fe = r.feasibility || [];
        let changed = [];
        if (fe.length) { const [entry, ...rest] = fe; const checks = entry.checks || []; const altered = checks.length ? [{ ...checks[0], output: 'forged' }, ...checks.slice(1)] : []; changed = [{ ...entry, checks: altered }, ...rest]; }
        fs.writeFileSync(recordPath, JSON.stringify({ ...r, feasibility: changed }));
      });
      const missing = await measured(() => { const r = readRecord(slug); delete r.feasibility; fs.writeFileSync(recordPath, JSON.stringify(r)); });
      const headChange = await measured(() => H.gitBang(c, ['commit', '--allow-empty', '-qm', 'Move evidence fixture HEAD']));
      results = { 'initial proof': initial, 'controls on first card': first, 'controls on exact repeat': repeat, 'controls on exact approval': approve, 'controls after observer change': observerChange, 'controls after input change': inputChange, 'controls after command change': commandChange, 'controls after forged outcome': forged, 'controls after missing proof': missing, 'controls after HEAD change': headChange, 'final exact proof': await proof(next) };
    } else {
      const obligations = [observerObligation('')];
      const originalPkg = pkg(obligations, goodBody);
      writePkg(originalPkg);
      const a0 = await invoke(['intent', 'approve', slug, await hash()]); assert.equal(a0.code, 0, a0.out);
      const approval = H.approvalPath(c.repo, slug);
      const raw = fs.readFileSync(approval);
      const originalHash = await hash();
      const changedText = text(obligations).replace('# Qualify', '# Requalify');
      script([sub('submit_refinement', [{ path: md, content: changedText }, { path: observer, content: badBody }]), ack('submit_refinement')]);
      const bad = await invoke(['intent', 'refine', slug, originalHash, request]);
      const preserved = originalPkg.every(x => fs.existsSync(path.join(c.repo, x.path)) && fs.readFileSync(path.join(c.repo, x.path), 'utf8') === x.content);
      const approvalPreserved = fs.existsSync(approval) && fs.readFileSync(approval).equals(raw);
      const refusedAck = refused('protected-observer');
      const finalBody = `${goodBody}\n// requalified final bytes\n`;
      script([sub('submit_refinement', [{ path: md, content: changedText }, { path: observer, content: finalBody }]), ack('submit_refinement')]);
      const good = await invoke(['intent', 'refine', slug, originalHash, request]);
      const archived = H.wildcard(path.join(c.repo, '.kogen/local/refinements/*/revoked-approval.json'));
      results = {
        'bad refinement refused': bad.code !== 0, 'unchanged acknowledgment refused': refusedAck, 'original package preserved': preserved, 'original approval preserved': approvalPreserved,
        'good refinement exit': good.code, 'qualified refinement published': fs.readFileSync(path.join(c.repo, observer), 'utf8') === finalBody && fs.readFileSync(path.join(c.repo, md), 'utf8') === changedText,
        'exact proof': await proof(obligations), 'approval revoked not replaced': !fs.existsSync(approval) && archived.some(p => fs.readFileSync(p).equals(raw)), 'bad output': bad.out, 'good output': good.out,
      };
    }
    return { ...results, 'unchanged caller index and HEAD': fs.readFileSync(path.join(c.repo, '.git/index')).equals(initialIndex) && (await head()) === initialHead };
  } finally { await H.cleanupCase(c); }
}
const sortKeys = x => Array.isArray(x) ? x.map(sortKeys) : x && typeof x === 'object' ? Object.fromEntries(Object.keys(x).sort().map(k => [k, sortKeys(x[k])])) : x;
async function runExercise(input) {
  const spec = JSON.parse(input);
  const suite = await H.setupSuite();
  try {
    const results = {};
    for (const mode of ['ordinary', 'capability', 'masked', 'counterexamples', 'binding', 'refine']) results[mode] = await runMode(suite, mode, spec);
    return results;
  } finally { H.cleanupSuite(suite); }
}
Given('the shaping evidence controls:', function (raw) {
  this.qualityInput = JSON.stringify(JSON.parse(raw));
});
When('I qualify native shaping evidence in mode {string}', { timeout: 900000 }, async function (mode) {
  if (!exercise) { exerciseInput = this.qualityInput; exercise = runExercise(exerciseInput); }
  assert.equal(this.qualityInput, exerciseInput, 'all scenarios must use the same complete controls');
  const results = await exercise;
  assert.ok(Object.hasOwn(results, mode), mode);
  this.qualityResult = results[mode];
});
Then('the shaping evidence observations are:', function (table) {
  const failures = [];
  for (const [key, raw] of table.raw()) {
    try { assert.deepEqual(this.qualityResult[key], JSON.parse(raw)); }
    catch { failures.push(`${key}: expected ${raw}, observed ${JSON.stringify(this.qualityResult[key])}`); }
  }
  assert.deepEqual(failures, [], JSON.stringify(this.qualityResult, null, 2));
});
Then('each evidence counterexample has these observations:', function (table) {
  const expectedCases = JSON.parse(this.qualityInput).cases.map(c => c.id);
  assert.deepEqual(Object.keys(this.qualityResult.cases).sort(), expectedCases.sort());
  const failures = [];
  for (const [id, observations] of Object.entries(this.qualityResult.cases)) {
    for (const [key, raw] of table.raw()) {
      try { assert.deepEqual(observations[key], JSON.parse(raw)); }
      catch { failures.push(`${id}: ${key}: expected ${raw}, observed ${JSON.stringify(observations[key])}`); }
    }
  }
  assert.deepEqual(failures, [], JSON.stringify(this.qualityResult, null, 2));
});
