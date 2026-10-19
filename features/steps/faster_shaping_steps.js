const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { spawn, spawnSync } = require('node:child_process');
const REPO = path.resolve(__dirname, '../..');
let candidatePromise, candidateRoot;
function run(program, args, options = {}) {
  return new Promise((resolve, reject) => {
    const p = spawn(program, args, { ...options, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    p.stdout.on('data', b => { stdout += b; }); p.stderr.on('data', b => { stderr += b; });
    p.stdin.on('error', e => { if (e.code !== 'EPIPE') reject(e); }); p.stdin.end(options.input || '');
    const timer = setTimeout(() => { try { process.kill(-p.pid, 'SIGKILL'); } catch {} }, 90000);
    p.on('error', e => { clearTimeout(timer); reject(e); });
    p.on('close', code => { clearTimeout(timer); resolve({ code, stdout, stderr }); });
  });
}
async function candidate() {
  if (!candidatePromise) candidatePromise = (async () => {
    candidateRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-faster-native-'));
    // Fresh native CLI/core, never a stale archive or the driving engine.
    // Adapter only locates compiled source; Main and bridge/executor remain real.
    const env = { ...process.env, ERL_FLAGS: process.env.ERL_FLAGS || '+S 2:2 +SDcpu 1 +SDio 1' };
    const compiled = await run('mix', ['compile', '--warnings-as-errors'], { cwd: REPO, env });
    assert.equal(compiled.code, 0, compiled.stdout + compiled.stderr);
    for (const dir of ['bin', 'lib/release/bin', 'lib/cucumber', 'lib/quint']) fs.mkdirSync(path.join(candidateRoot, dir), { recursive: true });
    const built = await run('go', ['build', '-o', path.join(candidateRoot, 'bin/kogen'), '.'], { cwd: path.join(REPO, 'cli'), env });
    assert.equal(built.code, 0, built.stdout + built.stderr);
    const mix = spawnSync('/bin/sh', ['-c', 'command -v mix'], { encoding: 'utf8' }).stdout.trim();
    assert.ok(path.isAbsolute(mix));
    const quote = s => "'" + s.replaceAll("'", "'\\''") + "'";
    fs.writeFileSync(path.join(candidateRoot, 'lib/release/bin/kogen'), '#!/bin/sh\ncd ' + quote(REPO) + '\nexec ' + quote(mix) + " run --no-compile -e 'Kogen.Main.main()'\n", { mode: 0o755 });
    fs.writeFileSync(path.join(candidateRoot, 'node-path'), process.execPath + '\n');
    fs.symlinkSync(path.join(REPO, 'test/acceptance/node_modules'), path.join(candidateRoot, 'lib/cucumber/node_modules'));
    const localQuint = path.join(REPO, 'spec/node_modules/@informalsystems/quint/dist/src/cli.js');
    const quintCli = fs.existsSync(localQuint) ? localQuint : process.env.KOGEN_QUINT;
    assert.ok(quintCli && fs.existsSync(quintCli), 'pinned Quint unavailable');
    const dest = path.join(candidateRoot, 'lib/quint/node_modules/@informalsystems/quint/dist/src');
    fs.mkdirSync(dest, { recursive: true });
    // Transparent execution counter, not a model stub: forward every command to pinned Quint.
    fs.writeFileSync(path.join(dest, 'cli.js'), `const fs=require('node:fs'),{spawnSync}=require('node:child_process');\nif(process.env.FASTER_MODEL_TRACE){const p='.kogen/intents/batch-fixture/intent.md'; const kind=fs.existsSync(p)&&fs.readFileSync(p,'utf8').includes('SPEED_CORRECTION')?'candidate':'original';fs.appendFileSync(process.env.FASTER_MODEL_TRACE,JSON.stringify({kind,args:process.argv.slice(2)})+'\\n');}\nconst r=spawnSync(process.execPath,[${JSON.stringify(quintCli)},...process.argv.slice(2)],{stdio:'inherit'});process.exit(r.status===null?99:r.status);\n`);
    fs.symlinkSync(path.join(REPO, 'docs'), path.join(candidateRoot, 'docs'));
    return candidateRoot;
  })();
  return candidatePromise;
}
function put(w, file, text) { fs.mkdirSync(path.dirname(path.join(w.project, file)), { recursive: true }); fs.writeFileSync(path.join(w.project, file), text); }
function git(w, args) {
  const r = spawnSync('git', args, { cwd: w.project, env: w.env, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stdout + r.stderr); return r.stdout.trim();
}
async function fixture(root) {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-faster-case-'));
  const w = { workspace, project: path.join(workspace, 'project'), home: path.join(workspace, 'home'), processes: [] };
  for (const dir of [w.project, w.home, path.join(workspace, 'tmp')]) fs.mkdirSync(dir);
  w.env = { ...process.env, HOME: w.home, TMPDIR: path.join(workspace, 'tmp'), GIT_CONFIG_GLOBAL: path.join(w.home, '.gitconfig'), GIT_CONFIG_NOSYSTEM: '1', ERL_FLAGS: process.env.ERL_FLAGS || '+S 2:2 +SDcpu 1 +SDio 1' };
  fs.writeFileSync(w.env.GIT_CONFIG_GLOBAL, '[user]\n name = Faster Fixture\n email = faster@example.invalid\n');
  fs.cpSync(path.join(REPO, 'test/acceptance/fixtures/projects/notes'), w.project, { recursive: true });
  git(w, ['init', '-q', '--initial-branch', 'main']);
  fs.mkdirSync(path.join(w.home, '.kogen/credentials'), { recursive: true });
  fs.writeFileSync(path.join(w.home, '.kogen/credentials/chatgpt.json'), JSON.stringify({ client_id: 'oaiapp_test', access_token: 'faster-shaping-fixture', refresh_token: 'faster-shaping-fixture', expires_at: Math.floor(Date.now() / 1000) + 3600 }), { mode: 0o600 });
  w.invoke = async (args, input) => run(path.join(root, 'bin/kogen'), args, { cwd: w.project, env: w.env, input });
  w.start = (args, input) => {
    const p = spawn(path.join(root, 'bin/kogen'), args, { cwd: w.project, env: w.env, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
    const r = { child: p, stdout: '', stderr: '', code: null };
    p.stdout.on('data', b => { r.stdout += b; }); p.stderr.on('data', b => { r.stderr += b; });
    p.stdin.on('error', e => { if (e.code !== 'EPIPE') r.stderr += e.message; }); p.stdin.end(input);
    r.done = new Promise((resolve, reject) => { p.on('error', reject); p.on('close', code => { r.code = code; resolve(r); }); });
    w.processes.push(r); return r;
  };
  return w;
}
function call(name, args, id) { return { type: 'function_call', id: 'i_' + id, call_id: 'c_' + id, name, arguments: JSON.stringify(args) }; }
const slug = 'batch-fixture', dir = '.kogen/intents/' + slug, stepPath = 'features/steps/batch_fixture.js';
const draft = { path: stepPath, content: "const { Then } = require('@cucumber/cucumber');\nconst assert = require('node:assert/strict');\nconst fs = require('node:fs');\n// INTEGRATED_DRAFT\nThen('the delegated note is {string}', function (expected) { assert.equal(fs.readFileSync('notes.txt', 'utf8').trim(), expected); });\n" };
function packageFiles(step) {
  return [
    { path: dir + '/intent.md', content: '# Change the delegated note\n\nSlug: ' + slug + '\nModel: not applicable — a stateless note fixture\nAcceptance:\n- ' + dir + '/acceptance.feature\n- ' + stepPath + '\n\nChange notes.txt to second note. This fixture intentionally has missing-feature red.\n\n## Decisions\n- Use the requested note text. (source: request)\n\n## Tests\n- The note has the requested value: delegated note scenario (scenario)\n\n## Feasibility\n- none\n' },
    { path: dir + '/acceptance.feature', content: 'Feature: Delegated note\n  Scenario: Requested note\n    Then the delegated note is "second note"\n' }, step,
  ];
}
const usage = { input_tokens: 100, input_tokens_details: { cached_tokens: 5 }, output_tokens: 20, output_tokens_details: { reasoning_tokens: 10 } };
function reply(res, items, tokens = usage) {
  res.writeHead(200, { 'content-type': 'text/event-stream', connection: 'close' });
  for (let i = 0; i < items.length; i++) res.write('data: ' + JSON.stringify({ type: 'response.output_item.done', output_index: i, item: items[i] }) + '\n\n');
  res.end('data: ' + JSON.stringify({ type: 'response.completed', response: tokens === null ? {} : { usage: tokens } }) + '\n\n');
}
function outputs(body) { return (body.input || []).filter(x => x.type === 'function_call_output'); }
function parseJSON(text) { try { return JSON.parse(text); } catch { return null; } }
function events(w) {
  const file = path.join(w.project, '.kogen/local/shaping/' + slug + '/events.ndjson');
  return fs.existsSync(file) ? fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map(parseJSON).filter(Boolean) : [];
}
async function until(test, message) {
  const end = Date.now() + 20000;
  while (!test()) { assert.ok(Date.now() < end, message); await new Promise(r => setTimeout(r, 10)); }
}
function unionLength(records) {
  const intervals = records.map(e => [e.started_ms, e.started_ms + e.wall_ms]).sort((a, b) => a[0] - b[0]);
  let total = 0, end = -Infinity;
  for (const [start, stop] of intervals) { total += Math.max(0, stop - Math.max(start, end)); end = Math.max(end, stop); }
  return total;
}
const sh = s => "'" + s.replaceAll("'", "'\\''") + "'";
const lines = p => fs.existsSync(p) ? fs.readFileSync(p, 'utf8').trim().split('\n').filter(Boolean) : [];
const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };
async function cleanup(w, provider) {
  for (const r of w.processes) if (r.code === null) { try { process.kill(-r.child.pid, 'SIGKILL'); } catch {} }
  if (provider) { provider.closeAllConnections(); await new Promise(r => provider.close(r)); }
  await Promise.allSettled(w.processes.map(r => r.done));
  fs.rmSync(w.workspace, { recursive: true, force: true });
}
async function exercise(mode, trial) {
  const root = await candidate(), w = await fixture(root);
  let provider, descendant;
  try {
    const trace = path.join(w.workspace, 'readiness-executions');
    const runner = `const fs=require('node:fs'),{spawnSync}=require('node:child_process');\nif (/Scenario(?: Outline)?:/.test(fs.readFileSync(process.env.KOGEN_ACCEPTANCE_FEATURES,'utf8'))) fs.appendFileSync(${JSON.stringify(trace)},'run\\n');\nconst r=spawnSync(process.env.KOGEN_NODE,[process.env.KOGEN_CUCUMBER+'/@cucumber/cucumber/bin/cucumber.js','--strict','--require','features/steps/*.js','--format','message:'+process.env.KOGEN_ACCEPTANCE_REPORT,process.env.KOGEN_ACCEPTANCE_FEATURES],{stdio:'inherit',env:{...process.env,NODE_PATH:process.env.KOGEN_CUCUMBER}});process.exit(r.status===null?99:r.status);\n`;
    put(w, 'runner.cjs', runner); put(w, '.gitignore', '.kogen/local/\n'); put(w, 'features/steps/empty.js', '// No delegated steps yet.\n'); put(w, 'guard.txt', 'protected fixture\n');
    let config = 'version: 1\ncommands:\n  setup: []\n  fix: []\n  checks: []\n  acceptance:\n    run: \'"$KOGEN_NODE" runner.cjs\'\n    steps_dir: features/steps\nprotect: [guard.txt]\nmodels:\n  shape: {model: gpt-6.1-sol, effort: high}\n  build: {model: gpt-6.1-sol, effort: medium}\n  review: {model: gpt-6.1-sol, effort: high}\n';
    if (mode !== 'opt-out') config += trial;
    if (mode === 'missing-role') config = config.replace(/  draft:.*\n/, '');
    if (mode === 'missing-effort') config = config.replace('gpt-6-luna, effort: max', 'gpt-6-luna');
    if (mode === 'disabled') config = config.replace('enabled: true', 'enabled: false');
    put(w, '.kogen/project.yaml', config); git(w, ['add', '-A']); git(w, ['commit', '-qm', 'Prepare native shaping fixture']);
    const head = git(w, ['rev-parse', 'HEAD']), index = git(w, ['write-tree']);
    const brief = { revision: { head, tree: index }, outcomes: 'Change notes.txt to second note; shape only.', interfaces: 'Then the delegated note is "second note"; use features/steps/batch_fixture.js.', transitions: 'Stateless note; no Quint. Main alone submits and waits for readiness observations.', fixtures: 'notes.txt initially first note; Node/Cucumber available; baseline intentionally red.', exclusions: 'No implementation, approval, Build or commit; no new planner or service.', protected_paths: ['guard.txt', '.kogen/project.yaml'], artifacts: [{ path: dir + '/intent.md', expectation: 'Prose declares feature and batch_fixture.js; no model.' }, { path: dir + '/acceptance.feature', expectation: 'One scenario Then the delegated note is "second note".' }, { path: stepPath, expectation: 'Node fs reads notes.txt; assert.equal uses the Gherkin expected string.' }] };
    let jobs = [{ id: 'read-note', role: 'read', scope: 'Inspect notes.txt, report exact initial note.', paths: ['notes.txt'], owns: [] }, { id: 'probe-node', role: 'probe', scope: 'Run one scratch check; do not change live notes.txt.', paths: ['README.md'], owns: [] }, { id: 'draft-step', role: 'draft', scope: 'Draft only batch_fixture.js consistent with shared artifacts.', paths: [], owns: [stepPath] }];
    if (mode === 'single') jobs = [jobs[2]];
    if (mode === 'two-drafts') jobs = [jobs[2], { id: 'draft-feature', role: 'draft', scope: 'Draft only acceptance.feature consistent with shared artifacts.', paths: [], owns: [dir + '/acceptance.feature'] }];
    if (mode === 'owner') jobs = [{ ...jobs[1], id: 'probe-a' }, { ...jobs[1], id: 'probe-b' }, jobs[2]];
    const ownerLog = path.join(w.workspace, 'owner-log'), release = path.join(w.workspace, 'release'), pidFile = path.join(w.workspace, 'descendant'), scratchFile = path.join(w.workspace, 'scratch');
    const batch = { brief, jobs };
    if (mode === 'missing-brief') delete batch.brief;
    if (mode === 'stale-revision') brief.revision.head = '0'.repeat(40);
    if (mode === 'stale-tree') brief.revision.tree = '0'.repeat(40);
    if (mode === 'missing-boundary') delete brief.fixtures;
    if (mode === 'overlap') jobs[0] = { ...jobs[2], id: 'other-draft' };
    if (mode === 'alias-overlap') jobs[0] = { ...jobs[2], id: 'other-draft', owns: ['features/steps/../steps/batch_fixture.js'] };
    if (mode === 'empty') batch.jobs = [];
    if (mode === 'four') batch.jobs = [...jobs, { ...jobs[0], id: 'fourth' }];
    const invalidModes = ['missing-brief', 'stale-revision', 'stale-tree', 'missing-boundary', 'overlap', 'alias-overlap', 'empty', 'four'];
    const sequential = ['opt-out', 'disabled', 'sequential'].includes(mode);
    const records = [], held = [], serverErrors = [], jobCounts = {}, liveWorkerResponses = new Set();
    let firstMain = true, batchResult, overlap = false, mainSubmitted = false, noLiveDraft = true, workerCapabilities = {}, mainHasBatch = false, forgedCallsRefused = false, independentHTTPHeld = false;
    let ownerDraft;
    const question = id => [call('submit', { questions: [{ question: 'Fixture stopped for caller inspection?', options: [{ label: 'Inspect', recommended: true }] }] }, id)];
    const finishWorker = (res, job, id) => {
      let files = job.role === 'draft' ? [job.id === 'draft-feature' ? packageFiles(draft)[1] : draft] : [];
      if (mode === 'unowned') files = [{ path: 'guard.txt', content: 'poison' }];
      reply(res, [call('worker_result', { evidence: 'evidence:' + job.id, files }, id)], mode === 'unknown-usage' ? null : usage);
    };
    const processRequest = (body, res) => {
      const tools = (body.tools || []).map(t => t.name), main = tools.includes('submit');
      records.push({ body, tools, main });
      if (main) {
        mainHasBatch ||= tools.includes('shape_batch');
        if (firstMain) { firstMain = false; return reply(res, sequential && mode !== 'opt-out' ? question('sequential') : [call('shape_batch', batch, 'batch')]); }
        const out = outputs(body).find(x => x.call_id === 'c_batch'); if (out) batchResult = parseJSON(out.output);
        if (!mainSubmitted) noLiveDraft &&= !fs.existsSync(path.join(w.project, stepPath));
        if (sequential || invalidModes.includes(mode) || ['failure', 'limits', 'unowned'].includes(mode)) return reply(res, question('stop'));
        if (!batchResult || batchResult.status !== 'completed') return reply(res, question('unexpected_refusal'));
        const returned = batchResult.jobs.flatMap(j => j.files || []), resultStep = returned.find(f => f.path === stepPath);
        if (!resultStep) return reply(res, question('missing_draft'));
        mainSubmitted = true;
        const merged = packageFiles(resultStep).map(f => returned.find(r => r.path === f.path) || f);
        return reply(res, [call('submit', { files: merged }, 'merged_' + records.length)]);
      }
      liveWorkerResponses.add(res); res.on('close', () => liveWorkerResponses.delete(res));
      // External provider-input contract, not an internal helper assertion.
      const payload = (body.input || []).filter(x => x.role === 'user').map(x => parseJSON(x.content)).find(x => x?.job);
      assert.ok(payload, 'worker lacks JSON shared brief/job input'); assert.deepEqual(payload.brief, brief);
      const job = payload.job; assert.ok(jobs.some(j => j.id === job.id)); workerCapabilities[job.role] = tools.sort();
      const n = jobCounts[job.id] = (jobCounts[job.id] || 0) + 1;
      if (mode === 'cancel' && job.role !== 'read') { res.writeHead(200, { 'content-type': 'text/event-stream' }); res.flushHeaders(); return; }
      if (mode === 'cancel') return finishWorker(res, job, job.id + n);
      if (mode === 'owner-cancel' && job.role === 'draft') { res.writeHead(200, { 'content-type': 'text/event-stream' }); res.flushHeaders(); return; }
      if (mode === 'owner-cancel' && job.role === 'read') return finishWorker(res, job, job.id + n);
      // This mode intentionally leaves draft HTTP open and completes read early;
      // its probe must not wait on the all-first-responses barrier below.
      if (mode === 'owner-cancel' && job.role === 'probe' && n === 1) return reply(res, [call('probe', { command: `pwd > ${sh(scratchFile)}; sleep 120 & child=$!; printf '%s\\n' "$child" > ${sh(pidFile)}; wait "$child"` }, job.id + n)]);
      if (mode === 'failure' && job.role === 'probe' && n === 2) { res.writeHead(503, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: { code: 'server_error', message: 'controlled worker failure' } })); return; }
      if (mode === 'limits') return reply(res, [call('read_file', { path: 'notes.txt' }, job.id + n)]);
      const respond = () => {
        if (mode === 'owner' && job.role === 'draft') { ownerDraft = () => finishWorker(res, job, job.id + n); return; }
        if (mode === 'owner' && n === 1) {
          const command = `mkdir ${sh(path.join(w.workspace, 'probe-lock'))} || exit 77; printf '%s\\n' ${sh(job.id + ':start')} >> ${sh(ownerLog)}; while test ! -f ${sh(release)}; do sleep 0.05; done; printf '%s\\n' ${sh(job.id + ':end')} >> ${sh(ownerLog)}; rmdir ${sh(path.join(w.workspace, 'probe-lock'))}; printf 'probe-ok\\n'`;
          return reply(res, [call('probe', { command }, job.id + n)]);
        }
        if (mode === 'restrictions' && n === 1) return reply(res, [call('submit', { files: packageFiles(draft) }, job.id + '_submit'), call('shape_batch', batch, job.id + '_delegate'), call('shell', { command: 'printf poison > guard.txt' }, job.id + '_shell'), call('write_file', { path: 'guard.txt', content: 'poison' }, job.id + '_write'), ...(job.role !== 'probe' ? [call('probe', { command: 'printf poison > notes.txt' }, job.id + '_probe')] : [])]);
        if (mode === 'restrictions' && n === 2) { assert.ok(outputs(body).length >= 4); assert.ok(outputs(body).every(x => /unknown tool|refused|not allowed/i.test(x.output))); forgedCallsRefused = true; return finishWorker(res, job, job.id + n); }
        if (n === 1 && job.role === 'read') return reply(res, [call('read_file', { path: 'notes.txt' }, job.id + n)]);
        if (n === 1 && job.role === 'probe') return reply(res, [call('probe', { command: "printf 'scratch note\\n' > notes.txt; printf 'probe-ok\\n'; cat notes.txt" }, job.id + n)]);
        if (job.role === 'read') assert.ok(outputs(body).some(x => x.output.includes('first note')), 'read never inspected note');
        if (job.role === 'probe') assert.ok(outputs(body).some(x => /exit status: 0/.test(x.output) && x.output.includes('probe-ok')), 'safe probe never ran');
        return finishWorker(res, job, job.id + n);
      };
      // Barrier proves HTTP overlap without elapsed-time thresholds.
      if (n === 1 && jobs.length > 1) { held.push(respond); if (held.length === jobs.length) { overlap = true; held.splice(0).forEach(f => f()); } } else respond();
    };
    provider = http.createServer((req, res) => { let data = ''; req.on('data', b => { data += b; }); req.on('end', () => { try { assert.equal(req.url, '/v1/responses'); assert.equal(req.headers.authorization, 'Bearer faster-shaping-fixture'); processRequest(JSON.parse(data), res); } catch (e) { serverErrors.push(e.message); if (!res.headersSent) res.writeHead(500); res.end(JSON.stringify({ error: { code: 'fixture_error', message: e.message } })); } }); });
    await new Promise(r => provider.listen(0, '127.0.0.1', r));
    w.env.KOGEN_PROVIDER_URL = 'http://127.0.0.1:' + provider.address().port;
    const active = w.start(['intent', 'shape', slug, '-'], 'Shape the shared delegated note fixture; do not implement it.');
    if (mode === 'owner') {
      await until(() => active.code !== null || lines(ownerLog).length > 0, 'owner probe never started');
      if (active.code === null) {
        independentHTTPHeld = !!ownerDraft && liveWorkerResponses.size > 0;
        fs.writeFileSync(release, 'release\n');
        await until(() => active.code !== null || lines(ownerLog).filter(l => l.endsWith(':end')).length === 2, 'owner probes did not settle');
        if (active.code === null && ownerDraft) ownerDraft();
      }
    }
    if (mode === 'cancel' || mode === 'owner-cancel') {
      await until(() => active.code !== null || (events(w).some(e => e.event === 'job_result' && e.job === 'read-note' && e.status === 'completed') && (mode === 'cancel' || fs.existsSync(pidFile))), 'completed read/running probe evidence not persisted');
      if (mode === 'owner-cancel' && fs.existsSync(pidFile)) { descendant = Number(fs.readFileSync(pidFile, 'utf8').trim()); independentHTTPHeld = liveWorkerResponses.size > 0; }
      if (active.code === null) active.child.kill('SIGINT');
    }
    await until(() => active.code !== null, 'native shaping did not terminate'); await active.done;
    if (['cancel', 'owner-cancel'].includes(mode) && active.code === 130) await until(() => liveWorkerResponses.size === 0, 'cancelled worker HTTP requests remain open');
    if (descendant && active.code === 130) await until(() => !alive(descendant), 'probe descendant survived cancellation');
    const ev = events(w), workers = records.filter(r => !r.main), count = () => lines(trace).length;
    const probeEvents = ev.filter(e => e.event === 'probe_result'), ownerLines = lines(ownerLog);
    const r = {
      code: active.code, allCalls: records.length, workerCalls: workers.length, mainModel: records.find(r => r.main) ? records.find(r => r.main).body.model + '/' + records.find(r => r.main).body.reasoning.effort : null,
      mainHasBatch, overlap, serverErrors, noLiveDraft, mainSubmitted, readinessRuns: count(), forgedCallsRefused,
      headUnchanged: git(w, ['rev-parse', 'HEAD']) === head, indexUnchanged: git(w, ['write-tree']) === index,
      protectedUnchanged: fs.readFileSync(path.join(w.project, 'guard.txt'), 'utf8') === 'protected fixture\n' && fs.readFileSync(path.join(w.project, '.kogen/project.yaml'), 'utf8') === config,
      scratchIsolated: fs.readFileSync(path.join(w.project, 'notes.txt'), 'utf8').trim() === 'first note',
      unapproved: !fs.existsSync(path.join(w.project, '.kogen/local/approvals/' + slug + '.json')), noIntent: !fs.existsSync(path.join(w.project, dir + '/intent.md')),
      refused: batchResult?.status === 'refused', refusalHasReason: typeof batchResult?.reason === 'string' && batchResult.reason.trim().length > 0,
      batchStatus: batchResult?.status || null, workerCapabilities,
      configuredModels: [...new Set(workers.map(x => x.body.model + '/' + x.body.reasoning.effort))].sort(),
      roleProvenance: workers.length > 0 && workers.every(x => { const p = (x.body.input || []).map(i => parseJSON(i.content)).find(v => v?.job); return p && ev.some(e => e.event === 'provider_call' && e.job === p.job.id && e.role === p.job.role && e.revision?.head === head && e.revision?.tree === index && e.scope === p.job.scope && e.configured_model === x.body.model && e.effective_model === x.body.model && e.configured_effort === x.body.reasoning.effort && e.effective_effort === x.body.reasoning.effort && Number.isInteger(e.wall_ms) && e.wall_ms >= 0); }),
      knownUsageRetained: ev.some(e => e.event === 'provider_call' && e.job === 'probe-node' && e.status === 'completed' && e.usage?.input === 100 && e.usage?.cached === 5 && e.usage?.output === 20 && e.usage?.reasoning === 10),
      unknownUsage: ev.some(e => e.event === 'provider_call' && e.role !== 'shape' && e.status === 'completed' && e.usage && ['input', 'cached', 'output', 'reasoning'].every(k => e.usage[k] === null)),
      failureTruthful: batchResult?.jobs?.some(j => j.id === 'probe-node' && j.status === 'failed' && /503|server_error|controlled worker failure/.test(JSON.stringify(j.error))) || false,
      probeCalls: jobCounts['probe-node'] || 0, limitCalls: jobCounts['read-note'] || 0,
      unauthorizedRejected: batchResult?.jobs?.length > 0 && batchResult.jobs.every(j => j.status === 'failed' && j.error),
      completedEvidenceRetained: ev.some(e => e.event === 'job_result' && e.job === 'read-note' && e.status === 'completed'),
      cancelledEvidence: ev.some(e => e.event === 'batch_result' && e.status === 'cancelled') && ev.some(e => e.event === 'job_result' && e.status === 'cancelled'),
      workerResponsesClosed: liveWorkerResponses.size === 0,
      phaseDurations: ['setup', 'model', 'probe', 'readiness'].every(phase => ev.some(e => e.event === 'phase_duration' && e.phase === phase && Number.isInteger(e.wall_ms) && e.wall_ms >= 0)),
      unionDurations: ['model', 'probe'].every(phase => { const intervals = ev.filter(e => e.event === (phase === 'model' ? 'provider_call' : 'probe_result')); const reported = ev.find(e => e.event === 'phase_duration' && e.phase === phase); return reported && intervals.every(e => Number.isInteger(e.started_ms) && Number.isInteger(e.wall_ms)) && reported.wall_ms === unionLength(intervals); }),
      integratedDraft: fs.existsSync(path.join(w.project, stepPath)) && fs.readFileSync(path.join(w.project, stepPath), 'utf8') === draft.content,
      observationsReturned: records.filter(x => x.main).some(x => outputs(x.body).some(o => o.output.includes('Readiness observations') && o.output.includes('Requested note'))),
      noImplicitAuthority: !records.some(x => x.tools.includes('submit_review') || x.tools.includes('finish')), errorOutput: active.stdout + active.stderr,
      independentHTTPHeld,
      ownerProbeCompleted: mode === 'owner' && batchResult?.jobs?.filter(j => j.role === 'probe').length === 2 && batchResult.jobs.filter(j => j.role === 'probe').every(j => j.status === 'completed'),
      probesSerialized: ownerLines.length === 4 && ownerLines[0].endsWith(':start') && ownerLines[1] === ownerLines[0].replace(':start', ':end') && ownerLines[2].endsWith(':start') && ownerLines[3] === ownerLines[2].replace(':start', ':end') && new Set([ownerLines[0], ownerLines[2]]).size === 2 && probeEvents.length === 2 && unionLength(probeEvents) === probeEvents.reduce((s, e) => s + e.wall_ms, 0),
      ownerProbeStarted: !!descendant && independentHTTPHeld,
      probeDescendantStopped: !!descendant && !alive(descendant),
      probeScratchRemoved: fs.existsSync(scratchFile) && !fs.existsSync(fs.readFileSync(scratchFile, 'utf8').trim()),
    };
    if (mainSubmitted && active.code === 0) {
      const before = count(), card = await w.invoke(['intent', 'approve', slug]), hash = card.stdout.match(/^SHA-256: ([a-f0-9]{64})$/m)?.[1], again = await w.invoke(['intent', 'approve', slug]);
      r.cardStable = card.code === 5 && again.code === 5 && card.stdout === again.stdout; r.cardReuse = count() === before; r.cardUnapproved = !fs.existsSync(path.join(w.project, '.kogen/local/approvals/' + slug + '.json'));
      const mismatch = await w.invoke(['intent', 'approve', slug, '0'.repeat(64)]); r.mismatchRefused = mismatch.code === 1 && mismatch.stdout.includes('intent/hash_mismatch:');
      assert.ok(hash, card.stdout + card.stderr); const approval = await w.invoke(['intent', 'approve', slug, hash]);
      r.explicitApproval = approval.code === 0 && JSON.parse(fs.readFileSync(path.join(w.project, '.kogen/local/approvals/' + slug + '.json'))).sha256 === hash; r.approvalReuse = count() === before;
      put(w, stepPath, draft.content + '// baseline changed after approval\n'); const build = await w.invoke(['intent', 'build', slug]);
      r.changedBaselineRefused = build.code === 1 && build.stdout.includes('intent/changed_since_approval:') && git(w, ['rev-parse', 'HEAD']) === head;
    }
    return r;
  } finally {
    await cleanup(w, provider);
    if (descendant && alive(descendant)) { try { process.kill(descendant, 'SIGKILL'); } catch {} }
  }
}

// Bundled context/refinement fixtures. No product implementation or shared steps.
const crypto = require('node:crypto');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
function rootManifest(w) {
  const names = spawnSync('git', ['ls-files', '-co', '--exclude-standard', '-z'], { cwd: w.project, env: w.env, encoding: 'utf8' });
  assert.equal(names.status, 0, names.stderr);
  return [...new Set(names.stdout.split('\0').filter(p => p && !p.startsWith('.kogen/local/')))].sort().map(p => [p, sha(fs.readFileSync(path.join(w.project, p)))]);
}
function evidenceObjects(folder) {
  if (!fs.existsSync(folder)) return [];
  const all = [];
  for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
    const full = path.join(folder, entry.name);
    if (entry.isDirectory() && !/^(original|candidate-|publish|rollback)/.test(entry.name)) all.push(...evidenceObjects(full));
    else if (entry.isFile() && /\.(json|ndjson)$/.test(entry.name) && !entry.name.startsWith('submission-')) {
      for (const line of lines(full)) { const value = parseJSON(line); if (value) all.push(value); }
    }
  }
  return all;
}
// Inspect supplied text rather than its JSON-escaped wire representation.
function suppliedText(body) { return (body?.input || []).map(i => typeof i.content === 'string' ? i.content : typeof i.output === 'string' ? i.output : '').join('\n'); }
async function speedBoundary(mode) {
  const root = await candidate(), w = await fixture(root);
  let provider;
  try {
    const shape = mode === 'shape-context', context = mode.endsWith('-context'), accept = context || mode === 'reuse' || mode === 'environment-failure';
    const acceptanceTrace = path.join(w.workspace, 'acceptance'), modelTrace = path.join(w.workspace, 'model'), setupTrace = path.join(w.workspace, 'setup');
    w.env.FASTER_MODEL_TRACE = modelTrace;
    const runner = `const fs=require('node:fs'),{spawnSync}=require('node:child_process');const feature=fs.readFileSync(process.env.KOGEN_ACCEPTANCE_FEATURES,'utf8');if(/Scenario(?: Outline)?:/.test(feature)){const text=fs.readFileSync('${dir}/intent.md','utf8');fs.appendFileSync(${JSON.stringify(acceptanceTrace)},(text.includes('SPEED_CORRECTION')?'candidate':'original')+'\\n');}const r=spawnSync(process.env.KOGEN_NODE,[process.env.KOGEN_CUCUMBER+'/@cucumber/cucumber/bin/cucumber.js','--strict','--require','features/steps/*.js','--format','message:'+process.env.KOGEN_ACCEPTANCE_REPORT,process.env.KOGEN_ACCEPTANCE_FEATURES],{stdio:'inherit',env:{...process.env,NODE_PATH:process.env.KOGEN_CUCUMBER}});process.exit(r.status===null?99:r.status);\n`;
    put(w, 'runner.cjs', runner); put(w, 'guard.txt', 'protected fixture\n');
    put(w, '.gitignore', '.kogen/local/\n');
    const bulk = 'UNRELATED_BULK_BODY_' + 'x'.repeat(24000);
    put(w, 'src/unrelated.txt', 'unrelated source\n' + bulk + '\nEXACT_SOURCE_BYTES_731\n');
    put(w, 'features/steps/unrelated.js', "const { Given } = require('@cucumber/cucumber');\nGiven('the unrelated bulk fixture exists', function () {});\n// " + bulk + '\n');
    // A real configured command with observable effects, not an empty-setup exemption.
    put(w, 'setup.cjs', `const fs=require('node:fs');const file='${dir}/intent.md';const kind=fs.existsSync(file)&&fs.readFileSync(file,'utf8').includes('SPEED_CORRECTION')?'candidate':'original';fs.appendFileSync(${JSON.stringify(setupTrace)},kind+'\\n');if(kind==='candidate'&&process.env.FASTER_SETUP_FAIL==='1'){console.error('controlled candidate setup environment failure');process.exit(7);}
`);
    const setup = '[' + JSON.stringify('"$KOGEN_NODE" setup.cjs') + ']';
    put(w, '.kogen/project.yaml', 'version: 1\ncommands:\n  setup: ' + setup + '\n  fix: []\n  checks: []\n  acceptance:\n    run: \'"$KOGEN_NODE" runner.cjs\'\n    steps_dir: features/steps\nprotect: [guard.txt]\nmodels:\n  shape: {model: gpt-6.1-sol, effort: high}\n  build: {model: gpt-6.1-sol, effort: medium}\n  review: {model: gpt-6.1-sol, effort: high}\n');
    git(w, ['add', '-A']); git(w, ['commit', '-qm', 'Prepare selective context fixture']);
    const model = 'module note_state {\n var value: int\n action init = value\' = 0\n action step = value\' = 1 - value\n val Safety = value == 0 or value == 1\n}\n';
    const files = packageFiles({ path: stepPath, content: draft.content + '// ' + bulk + '\n// EXACT_OWNED_BYTES_947\n' });
    files[0].content = files[0].content.replace('Model: not applicable — a stateless note fixture', 'Model: ' + dir + '/model.qnt invariants=Safety seed=19 samples=2 steps=2');
    files.push({ path: dir + '/model.qnt', content: model });
    const proposed = { ...files[0], content: files[0].content.replace('This fixture intentionally', 'SPEED_CORRECTION preserves the literal "second note" and guard.txt. This fixture intentionally') };
    if (!shape) for (const f of files) put(w, f.path, f.content);
    const records = [], serverErrors = [];
    const request = 'Preserve the exact literal "second note", guard.txt protection and Acceptance paths. Add SPEED_CORRECTION to the prose only; do not implement. A focused Node version probe may resolve the fixture prerequisite.';
    let phase = 0;
    provider = http.createServer((req, res) => {
      let data = ''; req.on('data', b => { data += b; });
      req.on('end', () => {
        try {
          assert.equal(req.url, '/v1/responses'); assert.equal(req.headers.authorization, 'Bearer faster-shaping-fixture');
          const body = JSON.parse(data); records.push(body);
          if (mode === 'environment-failure' && records.length > 1) return reply(res, [call('submit_refinement', { constraint: 'Retain original after the actual candidate setup failure.' }, 'stop_failure')]);
          if (!accept) return reply(res, [call('submit_refinement', { constraint: 'Fixture intentionally refuses after inspecting actual original observations.' }, 'refuse')]);
          if (context && phase++ === 0) return reply(res, [call('read_file', { path: 'src/unrelated.txt', start_line: 3, end_line: 3 }, 'source'), ...(shape ? [] : [call('read_file', { path: stepPath, start_line: 7, end_line: 7 }, 'owned')]), call('probe', { command: 'node --version' }, 'version')]);
          const changed = shape ? files.map(f => f.path === proposed.path ? proposed : f) : [proposed];
          return reply(res, [call(shape ? 'submit' : 'submit_refinement', { files: changed }, 'candidate_' + records.length)]);
        } catch (e) { serverErrors.push(e.message); if (!res.headersSent) res.writeHead(500); res.end(JSON.stringify({ error: { message: e.message } })); }
      });
    });
    await new Promise(r => provider.listen(0, '127.0.0.1', r));
    w.env.KOGEN_PROVIDER_URL = 'http://127.0.0.1:' + provider.address().port;
    const cachePath = path.join(w.project, '.kogen/local/readiness/' + slug + '.json');
    let hash;
    if (!shape) {
      const card = await w.invoke(['intent', 'approve', slug]);
      hash = card.stdout.match(/^SHA-256: ([a-f0-9]{64})$/m)?.[1];
      assert.equal(card.code, 5, card.stdout + card.stderr); assert.ok(hash, card.stdout + card.stderr);
      const originalCache = fs.readFileSync(cachePath, 'utf8');
      if (mode === 'changed-head' || mode === 'changed-protection') {
        if (mode === 'changed-head') git(w, ['commit', '--allow-empty', '-qm', 'Change frozen fixture HEAD']);
        else put(w, 'guard.txt', 'different protected bytes\n');
        const updated = await w.invoke(['intent', 'approve', slug]);
        hash = updated.stdout.match(/^SHA-256: ([a-f0-9]{64})$/m)?.[1]; assert.ok(hash, updated.stdout + updated.stderr);
        fs.writeFileSync(cachePath, originalCache);
      }
      if (mode === 'missing' || mode === 'smoke') fs.unlinkSync(cachePath);
      if (mode === 'malformed') fs.writeFileSync(cachePath, '{broken');
      if (mode === 'stale') { const c = JSON.parse(originalCache); c.sha256 = '0'.repeat(64); fs.writeFileSync(cachePath, JSON.stringify(c)); }
    }
    if (mode === 'environment-failure') {
      const approved = await w.invoke(['intent', 'approve', slug, hash]);
      assert.equal(approved.code, 0, approved.stdout + approved.stderr);
      w.env.FASTER_SETUP_FAIL = '1';
    }
    const before = rootManifest(w), indexPath = git(w, ['rev-parse', '--path-format=absolute', '--git-path', 'index']), indexBytes = fs.readFileSync(indexPath), head = git(w, ['rev-parse', 'HEAD']);
    const approvalPath = path.join(w.project, '.kogen/local/approvals/' + slug + '.json');
    const approvalBytes = fs.existsSync(approvalPath) ? fs.readFileSync(approvalPath) : null;
    const ac = lines(acceptanceTrace).length, mc = lines(modelTrace).length, sc = lines(setupTrace).length;
    const result = await w.invoke(shape ? ['intent', 'shape', slug, '-'] : ['intent', 'refine', slug, hash, '-'], request);
    const ar = lines(acceptanceTrace).slice(ac), mr = lines(modelTrace).slice(mc).map(parseJSON), sr = lines(setupTrace).slice(sc);
    const after = rootManifest(w), initial = suppliedText(records[0]), later = suppliedText(records.at(-1)), allOutputs = records.flatMap(outputs);
    const ixText = initial.match(/^Context index: (.+)$/m)?.[1];
    const ix = parseJSON(ixText), entries = ix?.entries || [];
    const indexedRetrievable = ['src/unrelated.txt', 'features/steps/unrelated.js', ...(shape ? [] : [stepPath])].every(p => entries.some(e => e.path === p && e.sha256 === sha(fs.readFileSync(path.join(w.project, p))) && e.bytes === fs.statSync(path.join(w.project, p)).size && e.source && e.ownership)) && !!ix?.retrieval && ix?.revision?.head === head && entries.map(e => e.path).join('\n') === entries.map(e => e.path).sort().join('\n');
    const objects = [...events(w), ...evidenceObjects(path.join(w.project, '.kogen/local/refinements'))];
    const original = objects.find(o => o.event === 'original_readiness');
    const originalRuns = ar.filter(k => k === 'original').length, originalModelRuns = mr.filter(k => k?.kind === 'original').length;
    const candidateRuns = ar.filter(k => k === 'candidate').length, candidateModelRuns = mr.filter(k => k?.kind === 'candidate').length;
    const guidance = records[0]?.instructions || '';
    const expectedAfter = before.map(([p, h]) => [p, p === proposed.path ? sha(proposed.content) : h]);
    return {
      code: result.code, originalRuns, originalModelRuns, candidateRuns, candidateModelRuns, originalSetupRuns: sr.filter(k => k === 'original').length, candidateSetupRuns: sr.filter(k => k === 'candidate').length, providerCalls: records.length, serverErrors,
      rootUnchanged: JSON.stringify(before) === JSON.stringify(after) && git(w, ['rev-parse', 'HEAD']) === head,
      rootOnlyCorrection: JSON.stringify(expectedAfter) === JSON.stringify(after),
      rawIndexUnchanged: fs.readFileSync(indexPath).equals(indexBytes),
      approvalUnchanged: approvalBytes === null ? !fs.existsSync(approvalPath) : fs.existsSync(approvalPath) && fs.readFileSync(approvalPath).equals(approvalBytes),
      unapproved: !fs.existsSync(approvalPath),
      realObservations: initial.includes('Readiness observations') && initial.includes('Requested note') && initial.includes('second note') && initial.includes('first note'),
      observationsReturned: allOutputs.some(o => o.output.includes('Readiness observations') && o.output.includes('Requested note')),
      indexedRetrievable, bulkOmitted: !initial.includes(bulk),
      exactReadReturned: allOutputs.some(o => o.call_id === 'c_source' && o.output.includes('EXACT_SOURCE_BYTES_731')) && (shape || allOutputs.some(o => o.call_id === 'c_owned' && o.output.includes('EXACT_OWNED_BYTES_947'))),
      focusedProbeRan: allOutputs.some(o => o.call_id === 'c_version' && /exit status: 0/.test(o.output) && /v\d+\./.test(o.output)),
      focusedGuidance: /focused|concrete uncertainty|hypothesis/i.test(guidance) && /readiness/i.test(guidance) && /entire|full|whole/i.test(guidance) && /acceptance/i.test(guidance),
      authorityRetained: initial.includes(request) && initial.includes('guard.txt') && later.includes('SPEED_CORRECTION') && later.includes('second note') && later.includes('guard.txt') && (shape || later.includes('Requested note')),
      contextMeasured: objects.some(o => o.event === 'context_selection' && Number.isInteger(o.supplied_input_bytes) && o.supplied_input_bytes > 0),
      originalHit: original?.status === 'hit', originalMiss: original?.status === 'miss' && typeof original.reason === 'string' && original.reason.length > 0,
      truthfulReuseReceipt: original?.status === 'hit' && original.source === 'retained' && original.setup_executions === 0 && original.acceptance_executions === originalRuns && original.model_executions === originalModelRuns && originalRuns === 0 && originalModelRuns === 0 && ['setup', 'acceptance', 'model', 'source_wall_ms'].every(k => original.avoided && (original.avoided[k] === null || (Number.isInteger(original.avoided[k]) && original.avoided[k] >= 0))),
      candidateFailureReturned: allOutputs.some(o => /setup_failed/.test(o.output) && o.output.includes('controlled candidate setup environment failure')),
      errorOutput: result.stdout + result.stderr,
    };
  } finally { await cleanup(w, provider); }
}
const { Given, When, Then, AfterAll } = require('@cucumber/cucumber');
Given('the faster shaping trial configuration:', function (text) { this.fasterTrial = text + '\n'; });
When('I exercise native shaping delegation in mode {string}', { timeout: 150000 }, async function (mode) { this.fasterReceipt = await exercise(mode, this.fasterTrial); });
When('I exercise the native shaping speed boundary in mode {string}', { timeout: 150000 }, async function (mode) { this.fasterReceipt = await speedBoundary(mode); });
Then('the faster shaping observations are:', function (table) { assert.ok(this.fasterReceipt); for (const [key, value] of table.raw()) { const expected = parseJSON(value) ?? value; assert.deepEqual(this.fasterReceipt[key], expected, key + ': ' + JSON.stringify(this.fasterReceipt)); } });
Then('the faster shaping diagnostic contains {string}', function (value) { assert.ok(this.fasterReceipt.errorOutput.includes(value), this.fasterReceipt.errorOutput); });
AfterAll(function () { if (candidateRoot) fs.rmSync(candidateRoot, { recursive: true, force: true }); });
