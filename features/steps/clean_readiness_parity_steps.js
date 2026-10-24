const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { When, Then } = require('@cucumber/cucumber');
const H = require('./go_driver_support.js');
const { fn: f } = H;
let exercise;

// Independent frozen harness: use installed CLI, real bundled Cucumber and local generated imports. The helpers provide
// transport and installation, not test assertions. Every observation is read from the installed `kogen` and its files.
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

async function runMode(suite, mode) {
  let c = await H.project(suite, [], { stagedIntent: false });
  try {
    const put = (p, bytes) => { const full = path.join(c.repo, p); fs.mkdirSync(path.dirname(full), { recursive: true }); fs.writeFileSync(full, bytes); };
    const trace = path.join(c.root, 'acceptance.jsonl'), setupTrace = path.join(c.root, 'setup.jsonl'), probeTrace = path.join(c.root, 'probe-ok');
    const readLines = p => fs.existsSync(p) ? fs.readFileSync(p, 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l)) : [];
    const declared = !['shape-negative', 'refine-red', 'card-negative', 'approve-negative'].includes(mode);
    const acceptanceBlock = fs.readFileSync(path.join(c.repo, '.kogen/project.yaml'), 'utf8');
    const stepsDir = /steps_dir: '?([^'\n]+)'?/.exec(acceptanceBlock)[1];
    put('.gitignore', `${fs.readFileSync(path.join(c.repo, '.gitignore'), 'utf8')}\nnode_modules/\n_build/\n`);
    put('_build/tracked.txt', 'tracked ignored bytes\n');
    put('candidate.sh', "#!/bin/sh\nprintf 'exact\\n'\n");
    fs.chmodSync(path.join(c.repo, 'candidate.sh'), 0o755);
    put('.guard', 'protected baseline\n');
    const bootstrap = `const fs=require('node:fs'); const cold=!fs.existsSync('node_modules/parity-local/index.cjs')&&!fs.existsSync('_build/result.cjs'); fs.appendFileSync(${JSON.stringify(setupTrace)},JSON.stringify({cwd:process.cwd(),cold})+'\\n'); if(${declared}) {fs.mkdirSync('node_modules/parity-local',{recursive:true}); fs.mkdirSync('_build',{recursive:true}); fs.writeFileSync('node_modules/parity-local/index.cjs','module.exports=42;'); fs.writeFileSync('_build/result.cjs','module.exports=42;');}\n`;
    put('bootstrap.cjs', bootstrap);
    put('runner.cjs', `
const fs=require('node:fs'); const {spawnSync,execFileSync}=require('node:child_process');
const feature=fs.readFileSync(process.env.KOGEN_ACCEPTANCE_FEATURES,'utf8');
if(/Scenario(?: Outline)?:/.test(feature)) {
 const g=(...a)=>execFileSync('git',a,{encoding:'utf8'}).trim();
 fs.appendFileSync(${JSON.stringify(trace)},JSON.stringify({cwd:process.cwd(),dep:fs.existsSync('node_modules/parity-local/index.cjs'),build:fs.existsSync('_build/result.cjs'),git:g('rev-parse','--is-inside-work-tree')==='true',tracked:fs.readFileSync('_build/tracked.txt','utf8'),mode:!!(fs.statSync('candidate.sh').mode&0o111),env:process.env.PARITY_CALLER,app:fs.readFileSync('app.txt','utf8')})+'\\n');
 if(${mode === 'root-drift'}) fs.writeFileSync(${JSON.stringify(path.join(c.repo, 'app.txt'))},'external drift\\n');
}
const r=spawnSync(process.env.KOGEN_NODE,[process.env.KOGEN_CUCUMBER+'/@cucumber/cucumber/bin/cucumber.js','--strict','--require','features/steps/*.js','--format','message:'+process.env.KOGEN_ACCEPTANCE_REPORT,process.env.KOGEN_ACCEPTANCE_FEATURES],{stdio:'inherit',env:{...process.env,NODE_PATH:process.env.KOGEN_CUCUMBER}});
process.exit(r.status===null?99:r.status);
`);
    const configOptions = { setup: ['"$KOGEN_NODE" bootstrap.cjs'], protect: ['.guard'], acceptance: { run: '"$KOGEN_NODE" runner.cjs', stepsDir } };
    H.configure(c, configOptions);
    const configText = fs.readFileSync(path.join(c.repo, '.kogen/project.yaml'), 'utf8');
    await H.gitBang(c, ['add', '.kogen/project.yaml', '.gitignore', 'bootstrap.cjs', 'runner.cjs', 'candidate.sh', '.guard']);
    await H.gitBang(c, ['add', '-f', '_build/tracked.txt']);
    await H.gitBang(c, ['commit', '-qm', 'Configure local parity fixture']);
    c.env = { ...c.env, PARITY_CALLER: 'caller-value' };
    const slug = mode.startsWith('shape') ? 'parity-shaped' : 'fixture';
    const md = H.intentMd(slug), ft = H.featurePath(slug);
    const step = slug === 'fixture' ? 'features/steps/integration_steps.js' : 'features/steps/parity_steps.js';
    const feature = 'Feature: Local bootstrap\n  Scenario: Actual generated imports\n    Then the local generated modules return forty two\n';
    const body = "const {Then}=require('@cucumber/cucumber'); const assert=require('node:assert/strict'); Then('the local generated modules return forty two',()=>{assert.equal(require('../../node_modules/parity-local/index.cjs'),42);assert.equal(require('../../_build/result.cjs'),42);});\n";
    const text = `# Check local bootstrap parity\n\nSlug: ${slug}\nModel: not applicable — local fixture wiring\nAcceptance:\n- ${ft}\n- ${step}\n\n## Decisions\n- Use local imports. (source: request)\n\n## Source comparison\n- addressed: local generated imports resolve in the exact candidate; source request; contract Tests and acceptance.feature.\n\n## Tests\n- bootstrap imports: actual modules (regression)\n\n## Feasibility\n- none\n`;
    const pkg = [{ path: md, content: text }, { path: ft, content: feature }, { path: step, content: body }];
    put('node_modules/parity-local/index.cjs', 'module.exports=42;');
    put('_build/result.cjs', 'module.exports=42;');
    const evidence = path.join(c.repo, `.kogen/local/readiness/${slug}.json`);
    const approval = H.approvalPath(c.repo, slug);
    fs.rmSync(approval, { force: true });
    const hash = () => H.baselineHash(c, slug, ['.guard']);
    const invoke = args => H.runKogen(c, args);
    const script = actions => c.server.setScript(actions);
    const request = path.join(c.root, 'request.md');
    fs.writeFileSync(request, 'Inspect actual diagnostics and qualify only the fixture contract.');
    const sub = (tool, files) => f(tool, { files });
    const count = () => readLines(trace).length, setups = () => readLines(setupTrace).length;
    const record = () => { try { return JSON.parse(fs.readFileSync(evidence, 'utf8')); } catch { return {}; } };
    const head = () => H.git(c, ['rev-parse', 'HEAD']);
    const cleanRecord = async () => { const r = record(); return r.version === 3 && r.candidate_tree === await H.candidateTree(c, await head()) && r.head === await head() && r.sha256 === await hash(); };
    const originalIndex = fs.readFileSync(path.join(c.repo, '.git/index'));
    const originalHead = await head();
    const baseRuns = count(), baseSetups = setups();
    let out, status, extra = {};
    const wildcardOne = pattern => { const found = H.wildcard(pattern); assert.equal(found.length, 1, `${pattern}: ${found}`); return found[0]; };
    if (mode.startsWith('shape')) {
      script([f('read_file', { path: 'README.md' }), f('probe', { command: `node -e 'if(require("./node_modules/parity-local/index.cjs")!==42||require("./_build/result.cjs")!==42)process.exit(9)' && printf ok > '${probeTrace}'` }), sub('submit', pkg), f('read_file', { path: ft }), sub('submit', [pkg[1]])]);
      ({ out, code: status } = await invoke(['intent', 'shape', slug, request]));
    } else if (mode === 'refine' || mode === 'refine-red') {
      for (const p of pkg) put(p.path, p.content);
      const ap = await invoke(['intent', 'approve', slug, await hash()]); assert.equal(ap.code, 0, ap.out);
      const raw = fs.readFileSync(approval);
      const changedText = text.replace('# Check local', '# Clarify local');
      const changedBody = `${body}// accumulated proposal\n`;
      const before = count(), bs = setups();
      const bad = changedText.replace('(source: request)', '(missing source)');
      script([sub('submit_refinement', [{ path: md, content: bad }, { path: step, content: changedBody }]), sub('submit_refinement', [{ path: md, content: changedText }]), f('read_file', { path: ft }), sub('submit_refinement', [{ path: ft, content: feature }])]);
      ({ out, code: status } = await invoke(['intent', 'refine', slug, await hash(), request]));
      const audit = wildcardOne(path.join(c.repo, '.kogen/local/refinements/*/original-readiness.json'));
      const ar = JSON.parse(fs.readFileSync(audit, 'utf8'));
      const archived = H.wildcard(path.join(c.repo, '.kogen/local/refinements/*/revoked-approval.json'));
      extra = { 'accumulated package published': fs.readFileSync(path.join(c.repo, md), 'utf8') === changedText && fs.readFileSync(path.join(c.repo, step), 'utf8') === changedBody, 'original retained': ar.status === 'hit' && ar.source === 'retained', 'candidate setup executions': setups() - bs, 'raw approval archived': archived.some(p => fs.readFileSync(p).equals(raw)), 'acceptance executions': count() - before };
    } else if (mode === 'cache') {
      for (const p of pkg) put(p.path, p.content);
      await invoke(['intent', 'approve', slug]);
      const ck = await cleanRecord();
      const measured = async action => { await action(); const n = count(); await invoke(['intent', 'approve', slug]); return count() - n; };
      const entries = [
        ['exact repeat executions', () => {}],
        ['ignored change executions', () => { put('node_modules/parity-local/index.cjs', 'module.exports=99;'); put('_build/result.cjs', 'module.exports=99;'); }],
        ['legacy executions', () => fs.writeFileSync(evidence, JSON.stringify({ ...record(), version: 2 }))],
        ['nonignored addition executions', () => put('new-input.txt', 'one\n')],
        ['nonignored content executions', () => put('new-input.txt', 'two\n')],
        ['nonignored deletion executions', () => fs.rmSync(path.join(c.repo, 'new-input.txt'))],
        ['mode change executions', () => fs.chmodSync(path.join(c.repo, 'candidate.sh'), 0o644)],
        ['head change executions', () => H.gitBang(c, ['commit', '--allow-empty', '-qm', 'Move fixture HEAD'])],
        ['protected change executions', () => put('.guard', 'new baseline\n')],
        ['declaration change executions', () => put('.kogen/project.yaml', configText.replace('bootstrap.cjs', 'bootstrap.cjs '))],
      ];
      const ex = {};
      for (const [k, a] of entries) ex[k] = await measured(a);
      fs.writeFileSync(evidence, JSON.stringify({ ...record(), version: 2 }));
      const bs = setups();
      script([sub('submit_refinement', [{ path: md, content: `${text}\nClarified fixture.\n` }])]);
      ({ out, code: status } = await invoke(['intent', 'refine', slug, await hash(), request]));
      const audit = wildcardOne(path.join(c.repo, '.kogen/local/refinements/*/original-readiness.json'));
      const ar = JSON.parse(fs.readFileSync(audit, 'utf8'));
      extra = { ...ex, 'clean record': ck && await cleanRecord(), 'legacy original miss': ar.status === 'miss', 'legacy original setup executions': ar.setup_executions, 'fresh candidate setup executions': setups() - bs - (ar.setup_executions || 0) };
    } else {
      for (const p of pkg) put(p.path, p.content);
      if (mode === 'scratch-mutation') put('bootstrap.cjs', `${bootstrap}require('node:fs').writeFileSync('app.txt','mutated input\\n');\n`);
      fs.rmSync(evidence, { force: true });
      const args = mode === 'approve-negative' ? ['intent', 'approve', slug, await hash()] : ['intent', 'approve', slug];
      ({ out, code: status } = await invoke(args));
    }
    const runs = readLines(trace), last = runs.at(-1) || {}, finalSetup = readLines(setupTrace).at(-1) || {};
    const scenarios = record().scenarios || [];
    const diag = c.server.toolOutputs().join('\n');
    const cleanDirs = [...runs, ...readLines(setupTrace)].filter(x => x.cwd !== c.repo);
    const results = {
      'final dependency present': last.dep, 'final build present': last.build, 'final disposable': last.cwd !== undefined && last.cwd !== c.repo,
      'setup started cold': finalSetup.cold === true && finalSetup.cwd !== c.repo,
      'accounted failed': [0, 5].includes(status) && scenarios.some(s => s.status === 'failed'),
      'all passed': status === 0 && scenarios.length > 0 && scenarios.every(s => s.status === 'passed'),
      'diagnostic inspected': diag.includes('Readiness observations') && diag.includes('Cannot find module') && c.server.providerRequests().some(req => (req.json.input || []).some(i => i.type === 'function_call_output' && String(i.output || '').includes('Actual generated imports'))),
      'warm probe succeeded': fs.existsSync(probeTrace) && fs.readFileSync(probeTrace, 'utf8') === 'ok',
      'exact inputs and env': last.git === true && last.tracked === 'tracked ignored bytes\n' && last.mode === true && last.env === 'caller-value' && last.app === 'baseline\n',
      'acceptance executions': count() - baseRuns, 'clean record': await cleanRecord(),
      'caller index unchanged': fs.readFileSync(path.join(c.repo, '.git/index')).equals(originalIndex),
      'caller custody': fs.readFileSync(path.join(c.repo, '.git/index')).equals(originalIndex) && await head() === originalHead && fs.readFileSync(path.join(c.repo, 'app.txt'), 'utf8') === 'baseline\n' && fs.existsSync(approval) === (mode === 'approve-negative'),
      'disposable cleaned': cleanDirs.length > 0 && cleanDirs.every(x => !fs.existsSync(x.cwd)),
      refused: ![0, 5].includes(status), 'no clean evidence': !fs.existsSync(evidence), 'no approval': !fs.existsSync(approval),
      'root effect honest': fs.readFileSync(path.join(c.repo, 'app.txt'), 'utf8') === (mode === 'root-drift' ? 'external drift\n' : 'baseline\n'),
      output: out, status, 'setup executions': setups() - baseSetups,
      ...extra,
    };
    return results;
  } finally { await H.cleanupCase(c); }
}
async function runExercise() {
  const suite = await H.setupSuite();
  try {
    const results = {};
    for (const mode of ['shape-negative', 'shape-setup', 'refine', 'refine-red', 'card-negative', 'approve-negative', 'cache', 'scratch-mutation', 'root-drift']) results[mode] = await runMode(suite, mode);
    return results;
  } finally { H.cleanupSuite(suite); }
}
When('I qualify clean readiness parity in mode {string}', { timeout: 600000 }, async function (mode) {
  if (!exercise) exercise = runExercise();
  const all = await exercise;
  assert.ok(Object.hasOwn(all, mode), mode);
  this.cleanReadinessParity = all[mode];
});
Then('the clean readiness parity observations are:', function (table) {
  const failures = [];
  for (const [key, raw] of table.raw()) {
    const expected = JSON.parse(raw);
    try { assert.deepEqual(this.cleanReadinessParity[key], expected); }
    catch { failures.push(`${key}: expected ${raw}, got ${JSON.stringify(this.cleanReadinessParity[key])}`); }
  }
  assert.deepEqual(failures, [], JSON.stringify(this.cleanReadinessParity, null, 2));
});
