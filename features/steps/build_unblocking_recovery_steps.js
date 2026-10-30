const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const util = require('node:util');
const { execFileSync, spawn, spawnSync } = require('node:child_process');
const H = require('./go_driver_support.js');

// This library drives the installed Go candidate (the one `kogen` program) the way a person would: the command line, files on
// disk, git and a scripted local provider. It replaces the Elixir driver build_unblocking_recovery_driver.exs observation for
// observation. The two helpers with no user-visible form (a tool's full text result, and the shared bounded form) run through
// the small Go program test/migration/drivers/build_unblocking_recovery.

function observe(receipt, rows) {
  assert.ok(receipt, 'no actual installed observations');
  for (const [key, value] of rows) assert.deepEqual(receipt[key], JSON.parse(value), `${key}: ${JSON.stringify(receipt)}`);
}

const hash = bytes => H.sha(bytes);
const git = (c, args) => H.git(c, args);
const count = c => c.server.providerRequests().length;
const call = (name, args) => H.fn(name, args);
// Replace the answers not yet consumed (the old driver's `script`), padding consumed positions.
const script = (c, tail) => c.server.setScript(tail);
const invoke = (c, args) => H.runKogen(c, args);
const contract = c => H.baselineHash(c, 'fixture', []);
const approvalFile = c => H.approvalPath(c.repo, 'fixture');
const read = (p, encoding) => fs.readFileSync(p, encoding);
const readOptional = p => fs.existsSync(p) ? read(p).toString('base64') : null;
function put(root, rel, bytes) {
  const p = path.join(root, rel);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, bytes);
}
const alive = pid => { try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } };
const gitBytes = (c, args) => execFileSync('git', ['-C', c.repo, ...args], { env: H.envFor(c), maxBuffer: 1 << 28 });
const sortedStrings = list => [...list].sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));

async function custody(c) {
  const head = await git(c, ['rev-parse', 'HEAD']);
  return { head, tree: await H.candidateTree(c, head), index: read(path.join(c.repo, '.git/index')).toString('base64'), approval: readOptional(approvalFile(c)) };
}
// A path's entry in a tree: { mode, sha256 } and its raw bytes, or nulls.
function treeEntry(c, tree, p) {
  const out = gitBytes(c, ['ls-tree', tree, '--', ':(literal)' + p]).toString('utf8').trim();
  const m = /^(\d+) blob ([0-9a-f]+)\t/.exec(out);
  if (!m) return [null, null];
  const bytes = gitBytes(c, ['cat-file', 'blob', m[2]]);
  return [{ mode: m[1], sha256: hash(bytes) }, bytes];
}
function filesIn(dir) {
  return fs.readdirSync(dir).sort().flatMap(n => {
    const p = path.join(dir, n), st = fs.lstatSync(p);
    if (st.isDirectory()) return filesIn(p).map(x => path.join(n, x));
    if (st.isFile()) return [n];
    return assert.fail(`unsafe archive entry ${p}`);
  });
}
function privateModes(dir) {
  assert.equal(fs.statSync(dir).mode & 0o777, 0o700, `directory mode: ${dir}`);
  for (const n of fs.readdirSync(dir)) {
    const p = path.join(dir, n);
    if (fs.statSync(p).isDirectory()) privateModes(p); else assert.equal(fs.lstatSync(p).mode & 0o777, 0o600, `file mode: ${p}`);
  }
}
// Independent archive observer: never calls production recovery code or its tests.
function archiveCheck(dir, expected) {
  const m = JSON.parse(read(path.join(dir, 'manifest.json'), 'utf8'));
  assert.deepEqual(Object.fromEntries(Object.keys(expected.meta).map(k => [k, m[k]])), expected.meta);
  assert.deepEqual(m.changes, expected.changes);
  const actual = filesIn(dir).filter(f => f !== 'manifest.json');
  const entries = m.artifacts;
  assert.ok(Array.isArray(entries));
  assert.deepEqual(entries.map(e => e.path), sortedStrings(actual));
  assert.equal(new Set(entries.map(e => e.path)).size, entries.length);
  for (const e of entries) assert.equal(e.sha256, hash(read(path.join(dir, e.path))));
  for (const [p, bytes] of Object.entries(expected.bytes)) assert.ok(read(path.join(dir, p)).equals(Buffer.from(bytes)), `archive bytes: ${p}`);
  const isData = f => f.startsWith('before/') || f.startsWith('candidate/');
  assert.deepEqual(sortedStrings(actual.filter(isData)), sortedStrings(Object.keys(expected.bytes).filter(isData)));
  privateModes(dir);
  return true;
}

// The archive observer controls (`--control good|bad`): a synthetic archive that is accepted, and one whose candidate bytes
// differ from the manifest and must be rejected.
function archiveControl(which) {
  const root = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'unblocking-observer-'));
  const bytes = { 'candidate/binary file': Buffer.from([0, 255, 13, 10]), 'before/deleted': 'old\n', 'approval.json': 'retained\n' };
  const changes = [{ path: 'binary file', before: null, after: { mode: '100755', sha256: hash(bytes['candidate/binary file']) } }];
  const meta = { version: 1, classification: 'BUILDER-REPORTED', build: '01234567' };
  try {
    for (const [p, b] of Object.entries(bytes)) put(root, p, b);
    const artifacts = Object.keys(bytes).sort().map(p => ({ path: p, sha256: hash(bytes[p]) }));
    put(root, 'manifest.json', JSON.stringify({ ...meta, changes, artifacts }));
    for (const p of filesIn(root)) fs.chmodSync(path.join(root, p), 0o600);
    for (const p of [root, path.join(root, 'before'), path.join(root, 'candidate')]) fs.chmodSync(p, 0o700);
    if (which === 'bad') put(root, 'candidate/binary file', Buffer.from([0, 254, 13, 10]));
    try { archiveCheck(root, { meta, bytes, changes }); return true; } catch (e) { if (e instanceof assert.AssertionError) return false; throw e; }
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
}

// The protected acceptance step: its bytes are the protected expectation of the fixture.
function step(fixed) {
  const expected = fixed ? 'A\\n' : 'baseline\\n';
  return `const fs=require('node:fs'); const assert=require('node:assert/strict');
const observe=s=>s==='${expected}';
if(require.main===module){const ok=observe(process.argv[2]==='good'?'A\\n':'baseline\\n');process.stdout.write(ok?'accepted\\n':'rejected\\n');process.exit(ok?0:1);}
else {const {Given,Then}=require('@cucumber/cucumber');Given('the fixture is available',()=>{});Then('the acceptance check passes',()=>assert.equal(observe(fs.readFileSync('app.txt','utf8')),true));}
`;
}
function declaration(observer, badExit = 1, goodExit = 0) {
  return { id: 'fixture-observer', kind: 'observer', inputs: [], observers: [observer], checks: [
    { name: 'good', command: `node ${observer} good`, exit: goodExit, output: 'accepted\n' },
    { name: 'bad', command: `node ${observer} bad`, exit: badExit, output: 'rejected\n' }] };
}
function md(evidence = []) {
  const lines = evidence.length === 0 ? '- none' : evidence.map(e => '- evidence: ' + JSON.stringify(e)).join('\n');
  return `# Write the requested production text

Slug: fixture
Model: not applicable — local text replacement
Acceptance:
- .kogen/intents/fixture/acceptance.feature
- features/steps/integration_steps.js

Write exactly A followed by a newline to app.txt. Preserve valuable production work for inspection. A protected expectation for baseline contradicts this request.

## Decisions
- Preserve exact authority. (source: request)

## Source comparison
- addressed: requested A newline; contract outcome and acceptance.

## Tests
- requested text: real file observation (scenario)

## Feasibility
${lines}
`;
}
async function configure(c, mode) {
  // A failing check no longer stops a Build at startup (it is recorded as a baseline), so the
  // startup stop is a setup command that fails only in the checkout, where the marker below is.
  const setup = "mkdir -p .kogen/local; printf 'setup\\n' >> .kogen/local/setup-trace; test ! -e .kogen/local/fail-setup";
  H.configure(c, { setup: [setup], fix: [], checks: [{ name: 'fixture-check', run: "printf 'check\\n' >> .kogen/local/check-trace; test -f app.txt" }], protect: [] });
  put(c.repo, 'binary file', Buffer.from([0, 1, 255, 10]));
  put(c.repo, 'deleted.txt', 'original deleted file\n');
  put(c.repo, 'executable.sh', '#!/bin/sh\nexit 0\n');
  await git(c, ['add', '.kogen/project.yaml', 'binary file', 'deleted.txt', 'executable.sh']);
  await git(c, ['commit', '-qm', 'Configure recovery fixture']);
  put(c.repo, H.intentMd('fixture'), md());
  put(c.repo, 'features/steps/integration_steps.js', step(false));
  const r = await invoke(c, ['intent', 'approve', 'fixture', await contract(c)]);
  assert.equal(r.code, 0, r.out);
  if (mode === 'startup-stop') {
    fs.mkdirSync(path.join(c.repo, '.kogen/local'), { recursive: true });
    fs.writeFileSync(path.join(c.repo, '.kogen/local/fail-setup'), 'x\n');
  }
}

// ------------------------------------------------------------------ the exercise, per mode
async function exercise(mode) {
  const suite = await H.setupSuite();
  try {
    const c = await H.project(suite, [], { stagedIntent: false });
    try {
      if (mode === 'fixture-lifecycle') return await fixtureLifecycle(c);
      if (mode === 'guidance') return await guidance(c);
      if (mode === 'polarity' || mode === 'masked-controls') return await controls(c, mode);
      return await recovery(c, mode);
    } finally { await H.cleanupCase(c); }
  } finally { H.cleanupSuite(suite); }
}
async function guidance(c) {
  const request = path.join(c.root, 'request.md');
  fs.writeFileSync(request, 'Investigate a risky protected acceptance driver.\n');
  await invoke(c, ['intent', 'shape', 'new-unblocking', request]);
  const shape = c.server.providerRequests().at(-1);
  await invoke(c, ['intent', 'refine', 'fixture', await contract(c), request]);
  const refine = c.server.providerRequests().at(-1);
  const has = r => {
    const t = JSON.stringify({ instructions: r.json.instructions, input: r.json.input }).toLowerCase();
    return t.includes('must declare') && t.includes('observer') && t.includes('masked') && t.includes('nonzero');
  };
  return { 'Shape guidance': has(shape), 'Refine guidance': has(refine) };
}
async function controls(c, mode) {
  const observer = 'features/steps/integration_steps.js';
  put(c.repo, H.featurePath('fixture'), 'Feature: Masked fixture\n  Scenario: Product red masks observer\n    Given the product is absent\n    Then the deep observer is correct\n');
  if (mode === 'polarity') {
    const body = `if(require.main===module){const good=process.argv[2]==='good';process.stdout.write(good?'accepted\\n':'rejected\\n');process.exit(good?0:1);}
else{const {Given,Then}=require('@cucumber/cucumber');Given('the product is absent',()=>{throw Error('unimplemented product')});Then('the deep observer is correct',()=>{});}
`;
    put(c.repo, observer, body);
    const card = ds => { put(c.repo, H.intentMd('fixture'), md(ds)); return invoke(c, ['intent', 'approve', 'fixture']); };
    const zero = declaration(observer, 0, 0); zero.checks = [zero.checks[0], { ...zero.checks[0], name: 'bad' }];
    const nonzero = declaration(observer, 1, 1); nonzero.checks = [{ ...nonzero.checks[1], name: 'good' }, nonzero.checks[1]];
    const o1 = await card([zero]);
    const o2 = await card([nonzero]);
    const support = { id: 'local-rejection', kind: 'capability', inputs: [], observers: [], checks: [{ name: 'support', command: "printf 'rejected\\n'; exit 23", exit: 23, output: 'rejected\n' }] };
    const o3 = await card([support, declaration(observer)]);
    return {
      'bad-zero refused': o1.code === 1 && o1.out.includes('observer'),
      'good-nonzero refused': o2.code === 1 && o2.out.includes('observer'),
      'rejected capability supported': o3.code === 5 && !o3.out.includes('not_ready'),
      'corrected observer ready': o3.code === 5,
    };
  }
  // An unchanged approved local fixture is needed to reach the transport.
  const cursor = await H.project(c.suite, [], { stagedIntent: false });
  let s;
  try {
    script(cursor, [{ http: [503, { error: { message: 'local cursor retry', code: 'server_error' } }] }]);
    await invoke(cursor, ['intent', 'build', 'fixture']);
    s = { script: cursor.server.script.slice(), next: cursor.server.next };
  } finally { await H.cleanupCase(cursor); }
  assert.ok(s.next > s.script.length, `the cursor did not advance beyond the script: ${s.next} <= ${s.script.length}`);
  const tail = ['first replay', 'second replay'];
  const wrong = s.script.slice(0, s.next).concat(tail)[s.next];
  // Append at the cursor through the real scripted provider, padding consumed positions.
  const probe = new H.FakeProvider(s.script); probe.next = s.next;
  probe.setScript(tail);
  assert.equal(probe.script[s.next], 'first replay');

  const long = path.join(c.root, 'long.txt'); fs.writeFileSync(long, 'x'.repeat(20000));
  const unblock = await H.driverProgram('build_unblocking_recovery');
  const toolResult = await unblock(['tool', c.root, 'read_file', JSON.stringify({ path: 'long.txt' })]);
  assert.equal(toolResult.code, 0, toolResult.out);
  const full = toolResult.out;
  const cut = await unblock(['cut'], { input: full });
  assert.equal(cut.code, 0, cut.out);
  assert.notEqual(full, cut.out);

  // Elixir language semantics of the two historical expressions (there is no Elixir in this suite any more): `input != []` is
  // a comparison and `input!=[]` assigns to `input!`; an `if` that rebinds `input` leaves the outer binding unchanged. The
  // values are those the focused probe recorded in the Intent's Feasibility.
  const goodToken = true, badToken = [];
  const goodScope = ['authority', 'exchange'], badScope = ['authority'];
  const protocol = path.join(c.root, 'protocol.cjs'); fs.writeFileSync(protocol, "console.log('fixture')\n");
  const rightExtension = spawnSync(process.execPath, [protocol], { encoding: 'utf8' }).status;
  const wrongExtension = spawnSync(process.execPath, [path.join(c.root, 'protocol.py')], { encoding: 'utf8' }).status;

  // Obtain consumed approval from a genuine landed installed Build.
  const other = await H.project(c.suite, [], { stagedIntent: false });
  let absent;
  try {
    await H.signCommits(other);
    script(other, [call('finish', { summary: 'complete fixture' }), call('submit_review', { verdict: 'approve', findings: [] })]);
    const landed = await invoke(other, ['intent', 'build', 'fixture']);
    assert.equal(landed.code, 0, landed.out);
    absent = fs.existsSync(approvalFile(other));
  } finally { await H.cleanupCase(other); }

  const cases = [
    ['retry cursor beyond script', 'first replay', wrong],
    ['full Refine tool output', full, cut.out],
    ['landed approval absence', absent, true],
    ['comparison tokenization', goodToken, badToken],
    ['outer input scope', goodScope, badScope],
    ['generated protocol extension', rightExtension, wrongExtension],
  ];
  const receipt = {};
  for (const [name, good, bad] of cases) {
    // Final protected step bytes accept actual good data and reject actual bad data.
    const body = flawed => {
      const expected = JSON.stringify(flawed ? bad : good), goodJson = JSON.stringify(good), badJson = JSON.stringify(bad);
      return `const assert=require('node:assert/strict');const expect=${expected};
function observe(v){try{assert.deepEqual(v,expect);return true}catch{return false}}
if(require.main===module){const ok=observe(process.argv[2]==='good'?${goodJson}:${badJson});process.stdout.write(ok?'accepted\\n':'rejected\\n');process.exit(ok?0:1)}
else{const {Given,Then}=require('@cucumber/cucumber');Given('the product is absent',()=>{throw Error('unimplemented product')});Then('the deep observer is correct',()=>assert.equal(observe(${goodJson}),true))}
`;
    };
    const ds = [declaration(observer)];
    put(c.repo, H.intentMd('fixture'), md(ds)); put(c.repo, observer, body(true));
    const wrongRun = await invoke(c, ['intent', 'approve', 'fixture']);
    put(c.repo, observer, body(false));
    const goodRun = await invoke(c, ['intent', 'approve', 'fixture']);
    const r = JSON.parse(read(path.join(c.repo, '.kogen/local/readiness/fixture.json'), 'utf8'));
    const proof = r.feasibility || [];
    let exact = false;
    if (proof.length === 1) {
      const p = proof[0];
      exact = util.isDeepStrictEqual(p.observers, { [observer]: hash(body(false)) })
        && util.isDeepStrictEqual((p.checks || []).map(k => ({ name: k.name, command: k.command, exit: k.exit, output: k.output })), ds[0].checks)
        && (p.checks || []).every(k => k.timed_out === false);
    }
    receipt[name] = {
      wrongRefused: wrongRun.code === 1 && wrongRun.out.includes('fixture-observer'),
      correctedReady: goodRun.code === 5 && !goodRun.out.includes('not_ready'),
      exactProof: exact,
      productRed: (r.scenarios || []).some(s => s.status === 'failed' && String(s.detail || '').includes('unimplemented product')),
    };
  }
  return receipt;
}

async function recovery(c, mode) {
  await configure(c, mode);
  const original = await custody(c);
  const originalHash = await contract(c);
  if (mode === 'login-stop') fs.rmSync(path.join(c.home, '.kogen/credentials/chatgpt.json'));
  const stopping = ['startup-stop', 'login-stop', 'provider-stop', 'non-blocker'].includes(mode);
  if (['provider-stop', 'non-blocker'].includes(mode)) {
    script(c, [{ http: [400, { error: { message: 'scripted provider refusal', code: 'invalid_request_error' } }] }]);
  } else {
    script(c, [call('shell', { command: "printf 'A\\n' > app.txt; printf '\\000\\376new' > 'binary file'; rm deleted.txt; chmod +x executable.sh; printf valuable > 'valuable new.txt'" }),
      call('finish', { summary: 'production implemented' }),
      call('report_blocker', { paths: ['features/steps/integration_steps.js'], reason: 'step expects baseline although approved outcome is A newline', evidence: 'finish acceptance fails after app.txt becomes A; protected comparison still expects baseline' })]);
  }
  const sleeper = stopping ? spawn('/bin/sleep', ['120'], { stdio: 'ignore' }) : null;
  try {
    const first = await invoke(c, ['intent', 'build', 'fixture']);
    const results = H.wildcard(path.join(c.repo, '.kogen/local/runs/*/result.json'));
    const resultPath = results.at(-1);
    const id = resultPath ? path.basename(path.dirname(resultPath)) : '01234567';
    const runDir = path.join(c.repo, `.kogen/local/runs/${id}`);
    const cp = path.join(runDir, 'checkpoint.json');
    let archive = path.join(c.root, 'preserved candidate');
    if (stopping) {
      const before = await custody(c), n = count(c);
      const { out, code: k } = await invoke(c, ['intent', 'recover', id, '--output', archive]);
      const reason = { 'startup-stop': 'environment/setup_failed', 'login-stop': 'provider/login' }[mode] || 'provider/';
      return {
        'recovery exit': k,
        'no archive published': !fs.existsSync(path.join(archive, 'manifest.json')),
        'honest stop': first.code !== 0 && first.out.includes(reason),
        'unchanged checkout': util.isDeepStrictEqual(await custody(c), before) && util.isDeepStrictEqual(before, original),
        'native recovery refusal': k === 1 && /candidate\/recovery_(refused|unsupported)/.test(out),
        'no recovery inference': count(c) === n,
        'unrelated process alive': alive(sleeper.pid),
        output: out, first: first.out,
      };
    }
    assert.ok(first.code === 1 && first.out.includes('candidate/build_blocked'), first.out);
    const stopped = await custody(c);
    const doc = JSON.parse(read(cp, 'utf8'));
    // The Go engine's checkpoint (version 4) keeps its state as JSON.
    const b = { start_tree: doc.state.start_tree, baseline: doc.state.baseline, blocker: doc.state.blocker };
    const history = Object.fromEntries(filesIn(runDir).map(p => [p, read(path.join(runDir, p))]));
    const changed = gitBytes(c, ['diff-tree', '-r', '-z', '--name-only', '--no-renames', b.start_tree, doc.candidate]).toString('utf8').split('\0').filter(Boolean);
    const changes = sortedStrings(changed.filter(p => !b.baseline.includes(p)));
    const data = {};
    const changeRows = changes.map(p => {
      const [before, bbytes] = treeEntry(c, b.start_tree, p), [after, abytes] = treeEntry(c, doc.candidate, p);
      if (before) data['before/' + p] = bbytes;
      if (after) data['candidate/' + p] = abytes;
      return { path: p, before, after };
    });
    const expected = {
      meta: { version: 1, build: id, slug: 'fixture', project: c.repo, start_head: original.head, start_tree: b.start_tree, candidate_tree: doc.candidate, contract_sha256: originalHash, classification: 'BUILDER-REPORTED' },
      changes: changeRows,
      bytes: { ...data, 'checkpoint.json': read(cp), 'result.json': read(resultPath), 'approval.json': read(approvalFile(c)), 'index-at-start': Buffer.from(original.index, 'base64') },
    };
    if (mode === 'inside-output') archive = path.join(c.repo, 'archive');
    switch (mode) {
      case 'candidate-drift': put(c.repo, 'unrelated.txt', 'do not discard\n'); break;
      case 'index-drift': await git(c, ['add', 'app.txt']); break;
      case 'approval-drift': fs.writeFileSync(approvalFile(c), Buffer.concat([read(approvalFile(c)), Buffer.from('\n')])); break;
      case 'head-drift': await git(c, ['commit', '--allow-empty', '-qm', 'Move HEAD']); break;
      case 'baseline-drift': fs.writeFileSync(path.join(c.repo, 'features/steps/integration_steps.js'), step(false) + '\n// drift\n'); break;
      case 'missing-checkpoint': fs.rmSync(cp); break;
      case 'legacy-checkpoint': fs.writeFileSync(cp, JSON.stringify({ ...doc, version: 2 })); break;
      case 'existing-output': fs.mkdirSync(archive); put(archive, 'sentinel', 'do not overwrite'); break;
      default: break;
    }
    const before = await custody(c), n = count(c);
    const { out, code: k } = await invoke(c, ['intent', 'recover', id, '--output', archive]);
    if (mode !== 'recover') {
      return {
        'recovery exit': k,
        'native recovery refusal': /candidate\/recovery_(refused|unsupported)/.test(out),
        'unchanged checkout': util.isDeepStrictEqual(await custody(c), before),
        'no recovery inference': count(c) === n,
        'no archive published': !fs.existsSync(path.join(archive, 'manifest.json')) && (mode !== 'existing-output' || read(path.join(archive, 'sentinel'), 'utf8') === 'do not overwrite'),
        output: out,
      };
    }
    if (k !== 0) return { 'recovery exit': k, output: out };
    const archiveOk = archiveCheck(archive, expected);
    assert.deepEqual(JSON.parse(read(path.join(archive, 'blocker.json'), 'utf8')), b.blocker);
    const context = read(path.join(archive, 'context.md'), 'utf8'), correction = read(path.join(archive, 'correction.md'), 'utf8');
    const size = Buffer.byteLength(context);
    assert.ok(size >= 1 && size <= 262144, `context.md size ${size}`);
    for (const t of [context, correction]) assert.ok(t.includes(archive) && t.includes(id) && t.includes(originalHash), 'handoff lacks the archive, run id or contract hash');
    assert.ok(out.includes(hash(read(path.join(archive, 'manifest.json')))), 'the printed output lacks the manifest hash');
    const cleaned = await custody(c);
    const only = cleaned.head === original.head && cleaned.index === original.index && cleaned.approval === original.approval && cleaned.tree === b.start_tree;
    const historyOk = Object.entries(history).every(([p, bytes]) => fs.existsSync(path.join(runDir, p)) && read(path.join(runDir, p)).equals(bytes));
    const noInference = count(c) === n;
    const repeat = await invoke(c, ['intent', 'recover', id, '--output', archive]);
    const repeatOk = repeat.code === 1 && repeat.out.includes('recovery_refused') && util.isDeepStrictEqual(await custody(c), cleaned);
    return {
      ...(await journey(c, archive, originalHash, original.head)),
      'recovery exit': k, 'exact private archive': archiveOk, 'only production cleared': only, 'original run unchanged': historyOk,
      'no recovery inference': noInference, 'repeat refused': repeatOk, 'stopped tree': stopped.tree,
    };
  } finally {
    if (sleeper) { try { sleeper.kill('SIGTERM'); } catch {} }
  }
}
// Qualify later observers without inventing a recovery implementation: start with a clean production tree and explicitly
// constructed diagnostic artifacts.
async function fixtureLifecycle(c) {
  await configure(c, 'recover');
  const originalHash = await contract(c);
  const startHead = await git(c, ['rev-parse', 'HEAD']);
  const archive = path.join(c.root, 'manual production evidence');
  put(archive, 'candidate/app.txt', 'A\n');
  put(archive, 'context.md', `Lower-authority diagnostic production archive at ${archive}; no automatic import.\n`);
  put(archive, 'correction.md', 'Correct only the protected step to expect A newline as the approved prose requires. app.txt is production-clean baseline; inspect the observer control.\n');
  return journey(c, archive, originalHash, startHead);
}
async function journey(c, archive, originalHash, startHead) {
  const context = read(path.join(archive, 'context.md'), 'utf8');
  const ds = [declaration('features/steps/integration_steps.js')];
  const proposed = [{ path: H.intentMd('fixture'), content: md(ds) }, { path: 'features/steps/integration_steps.js', content: step(true) }];
  const featureText = read(path.join(c.repo, H.featurePath('fixture')), 'utf8');
  script(c, [call('submit_refinement', { files: proposed }), call('submit_refinement', { files: [{ path: H.featurePath('fixture'), content: featureText }] })]);
  const refine = await invoke(c, ['intent', 'refine', 'fixture', originalHash, path.join(archive, 'correction.md')]);
  const beforeApproval = count(c);
  const refusal = await invoke(c, ['intent', 'build', 'fixture']);
  const needs = refine.code === 0 && refusal.code === 5 && refusal.out.includes('intent/not_approved') && count(c) === beforeApproval && !fs.existsSync(approvalFile(c));
  const newHash = await contract(c);
  const approve = await invoke(c, ['intent', 'approve', 'fixture', newHash]);
  assert.equal(approve.code, 0, approve.out + refine.out);
  await H.signCommits(c);
  script(c, [call('read_file', { path: path.join(archive, 'candidate/app.txt') }), call('write_file', { path: 'app.txt', content: 'A\n' }), call('finish', { summary: 'fresh implementation' }),
    call('write_file', { path: 'review.txt', content: 'independent scoped repair\n' }), call('submit_review', { verdict: 'approve', findings: [] })]);
  const nfresh = count(c);
  const cleanStart = read(path.join(c.repo, 'app.txt'), 'utf8') === 'baseline\n' && !fs.existsSync(path.join(c.repo, 'valuable new.txt'));
  const landed = await invoke(c, ['intent', 'build', 'fixture', '--context', path.join(archive, 'context.md')]);
  const finalResults = H.wildcard(path.join(c.repo, '.kogen/local/runs/*/result.json')).map(p => JSON.parse(read(p, 'utf8')));
  const landedResult = finalResults.find(r => r.outcome === 'landed') || {};
  const signed = await H.run('git', ['-C', c.repo, 'verify-commit', 'HEAD'], { env: H.envFor(c) });
  const fresh = c.server.providerRequests().slice(nfresh);
  const firstInput = fresh.length ? H.FakeProvider.inputText(fresh[0]) : '';
  return {
    'refinement exit': refine.code,
    'fresh approval required': needs,
    'fresh build exit': landed.code,
    'one signed commit': (await git(c, ['rev-list', '--count', `${startHead}..HEAD`])) === '1' && signed.code === 0 && signed.out.includes('Good'),
    'independent changed-tree verification': Number.isInteger(landedResult.passes) && landedResult.passes >= 2 && landedResult.reviews === 1 && read(path.join(c.repo, 'review.txt'), 'utf8') === 'independent scoped repair\n',
    'landed approval consumed': !fs.existsSync(approvalFile(c)),
    'handoff used not imported': cleanStart && firstInput.includes(context) && !fs.existsSync(path.join(c.repo, 'valuable new.txt')),
    output: refine.out + landed.out,
  };
}

// ------------------------------------------------------------------ controls and steps
if (require.main === module) {
  // These controls qualify the archive observer and the later lifecycle assertions separately. The lifecycle fixture uses
  // today's manual clean-start path; it neither implements recovery nor pretends the missing command already works.
  (async () => {
    const choice = process.argv[2] === '--control' && process.argv[3];
    assert.ok(['good', 'bad', 'journey-good', 'journey-bad'].includes(choice), 'select a control');
    const good = choice.endsWith('good');
    let accepted;
    try {
      if (choice.startsWith('journey-')) {
        const data = await exercise('fixture-lifecycle');
        // Known bad evidence: a final reviewer edit was not externally verified.
        if (!good) data['independent changed-tree verification'] = false;
        try {
          observe(data, [
            ['refinement exit', '0'], ['fresh approval required', 'true'],
            ['fresh build exit', '0'], ['one signed commit', 'true'],
            ['independent changed-tree verification', 'true'],
            ['landed approval consumed', 'true'], ['handoff used not imported', 'true'],
          ]);
          accepted = true;
        } catch (e) {
          if (!(e instanceof assert.AssertionError)) throw e;
          accepted = false;
        }
      } else accepted = archiveControl(choice);
      assert.equal(accepted, good, 'invalid control outcome');
    } catch (e) {
      process.stderr.write(String(e)); process.exit(3);
    }
    process.stdout.write(accepted ? 'accepted\n' : 'rejected\n');
    process.exit(accepted ? 0 : 1);
  })();
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('I exercise native unblocking in mode {string}', { timeout: 600000 }, async function (mode) {
    this.unblocking = await exercise(mode);
    await this.attach(JSON.stringify(this.unblocking), 'application/json');
  });
  Then('the unblocking observations are:', function (table) {
    observe(this.unblocking, table.raw());
  });
  Then('every unblocking control is independently qualified:', function (table) {
    for (const [name] of table.raw()) assert.deepEqual(this.unblocking[name], {
      wrongRefused: true, correctedReady: true, exactProof: true, productRed: true,
    }, `${name}: ${JSON.stringify(this.unblocking)}`);
  });
}
