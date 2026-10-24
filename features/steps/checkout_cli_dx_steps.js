const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { isDeepStrictEqual } = require('node:util');
const { spawnSync } = require('node:child_process');
const { When, Then, AfterAll } = require('@cucumber/cucumber');
const H = require('./go_driver_support.js');
const { fn: f, sleep, shellQuote: q } = H;

// Independent installed-CLI driver: it drives the installed `kogen` (the one Go program) with a scripted local provider
// and reads files on disk. Each mode returns the receipt the scenario's table is checked against.

const same = isDeepStrictEqual;
const now = () => Date.now();

async function json(c, args, opts) {
  const { out, code } = await H.runKogen(c, args, opts);
  let doc; try { doc = JSON.parse(out); } catch {}
  assert.ok(doc && typeof doc === 'object' && !Array.isArray(doc), `expected one JSON object for ${JSON.stringify(args)} (${code}): ${out}`);
  return [doc, code];
}
const json0 = async (c, args, opts) => { const [d, k] = await json(c, args, opts); assert.equal(k, 0, `${args.join(' ')} exited ${k}: ${JSON.stringify(d)}`); return d; };
const context = async c => (await json0(c, ['context'])).data;
const count = c => c.server.providerRequests().length;
const script = (c, tail) => c.server.setScript(tail);
const git = (c, args) => H.git(c, args);
const resumeCommand = (c, id) => `kogen intent resume ${id} --project ${q(c.repo)}`;
const runpath = (c, id, file) => path.join(c.repo, '.kogen/local/runs', id, file);
const runIds = c => H.wildcard(path.join(c.repo, '.kogen/local/runs/*/result.json')).map(p => path.basename(path.dirname(p)));
const without = (a, b) => a.filter(x => !b.includes(x));
async function custody(c) {
  const local = {};
  for (const p of H.listFiles(path.join(c.repo, '.kogen/local'))) local[path.relative(c.repo, p)] = fs.readFileSync(p).toString('latin1');
  return { head: await git(c, ['rev-parse', 'HEAD']), index: fs.readFileSync(path.join(await git(c, ['rev-parse', '--absolute-git-dir']), 'index')).toString('latin1'), approval: fs.readFileSync(H.approvalPath(c.repo, 'fixture'), 'latin1'), app: fs.readFileSync(path.join(c.repo, 'app.txt'), 'latin1'), local };
}
async function approveFixture(c) {
  const card = await H.runKogen(c, ['intent', 'approve', 'fixture']); assert.equal(card.code, 5, card.out);
  const hash = /SHA-256: ([0-9a-f]{64})/.exec(card.out)[1];
  const done = await H.runKogen(c, ['intent', 'approve', 'fixture', hash]); assert.equal(done.code, 0, done.out);
}
async function configureSetup(c, command) {
  const file = path.join(c.repo, '.kogen/project.yaml');
  const lines = fs.readFileSync(file, 'utf8').split('\n').map(l => l.startsWith('  setup:') ? `  setup:\n    - '${command.replaceAll("'", "''")}'` : l);
  fs.writeFileSync(file, lines.join('\n'));
  await git(c, ['add', '.kogen/project.yaml']); await git(c, ['commit', '-qm', 'fixture setup']);
}
async function pages(c, cursor, acc, n) {
  assert.ok(n < 20, 'pagination did not terminate');
  const doc = await json0(c, ['intent', 'list', '--json', '--limit', '1', ...(cursor ? ['--cursor', cursor] : [])]);
  const d = doc.data, rows = acc.concat(d.items);
  return d.next_cursor === null ? rows : pages(c, d.next_cursor, rows, n + 1);
}
async function waitIdle(c, deadline) {
  for (;;) {
    const data = await context(c);
    if (data.active === null) return data;
    assert.ok(now() < deadline, 'the active Build never cleared'); await sleep(20);
  }
}
async function measure(c, samples) {
  const out = {};
  for (const [label, args] of [['context', ['context']], ['completion', ['__complete', 'resume']]]) {
    const times = [];
    for (let i = 0; i < samples; i++) {
      const t = process.hrtime.bigint();
      const r = await H.runKogen(c, args); assert.equal(r.code, 0, r.out);
      times.push(Number(process.hrtime.bigint() - t) / 1e6);
    }
    times.sort((a, b) => a - b);
    out[label] = { p50: times[Math.floor(samples / 2)], p95: times[Math.ceil(samples * 0.95) - 1], max: times[times.length - 1] };
  }
  return out;
}

const exercises = {
  async isolation(c, initial) {
    const before = await custody(c);
    const empty = initial.data.active === null && initial.data.last_built === null;
    const nested = path.join(c.repo, 'nested/deep'); fs.mkdirSync(nested, { recursive: true });
    const nd = await json0(c, ['context'], { cd: nested });
    const outside = await json0(c, ['context'], { cd: c.root });
    // Worktrees are test fixtures only, not a new product orchestration feature.
    await git(c, ['add', '.kogen', 'features']); await git(c, ['commit', '-qm', 'fixture package']);
    const wt = path.join(c.root, 'other-checkout'); await git(c, ['worktree', 'add', '-q', '-b', 'other', wt]);
    const wd = await json0(c, ['context', '--project', wt]);
    const built = await H.runKogen(c, ['intent', 'build', 'fixture']); assert.notEqual(built.code, 0);
    const a = await json0(c, ['context']);
    const w = await json0(c, ['context', '--project', wt]);
    fs.writeFileSync(path.join(c.repo, 'app.txt'), 'dirty, not activity\n');
    const dirty = await json0(c, ['context']);
    const readBefore = await custody(c);
    await json0(c, ['context']);
    return {
      outside: outside.checkout === null && outside.error === null && outside.data.project === false,
      empty, nested: same(nd.checkout, initial.checkout),
      worktreeIdentity: wd.checkout.id !== initial.checkout.id && wd.checkout.root === path.resolve(wt),
      worktreeAbsence: a.data.last_built !== null && w.data.last_built === null && w.data.active === null,
      dirtyIsNotActive: dirty.data.active === null && same(dirty.data.last_built, a.data.last_built),
      readOnly: same(await custody(c), readBefore) && before.approval === readBefore.approval,
    };
  },
  async attempts(c) {
    const b1 = await H.runKogen(c, ['intent', 'build', 'fixture']);
    const one = runIds(c); assert.equal(one.length, 1, b1.out); const [id1] = one;
    const original = fs.readFileSync(runpath(c, id1, 'result.json'), 'latin1');
    const b2 = await H.runKogen(c, ['intent', 'build', 'fixture']);
    const [id2] = without(runIds(c), one);
    const ctx = await json0(c, ['context']);
    const listing = await json0(c, ['intent', 'list', '--json', '--limit', '100']);
    const rows = listing.data.items;
    const builds = rows.filter(r => r.type === 'build'), packages = rows.filter(r => r.type === 'intent');
    const paged = await pages(c, null, [], 0);
    const before = await custody(c);
    const d = await json0(c, ['intent', 'inspect', id2, '--json']); const r = d.data;
    const inspectClean = same(await custody(c), before);
    const approval = H.approvalPath(c.repo, 'fixture'), bytes = fs.readFileSync(approval); fs.rmSync(approval);
    const reject = await H.runKogen(c, ['intent', 'build', 'fixture']);
    const afterReject = await json0(c, ['context']);
    fs.writeFileSync(approval, bytes);
    const old2 = fs.readFileSync(runpath(c, id2, 'result.json'), 'latin1');
    const resume = await H.runKogen(c, ['intent', 'resume', id2]);
    const [id3] = without(runIds(c), [id1, id2]);
    const rd = await json0(c, ['intent', 'inspect', id3, '--json']); const rr = rd.data;
    const last = await json0(c, ['context']);
    return {
      twoAttempts: b1.code !== 0 && b2.code !== 0 && same(builds.map(x => x.run_id), [id2, id1]),
      packageSeparate: packages.length === 1 && packages[0].approval_state === 'current' && ['valid', 'unknown'].includes(packages[0].package_state) && builds.every(x => typeof x.state === 'string'),
      pagination: same(paged, rows),
      failureInspection: r.run_id === id2 && r.slug === 'fixture' && r.reason !== null && r.phase === 'building' && r.state !== 'active' && Array.isArray(r.verification) && Array.isArray(r.reviews) && Array.isArray(r.blockers) && r.locations.candidate === c.repo && r.locations.run_dir === path.dirname(runpath(c, id2, 'result.json')) && r.commit === null && r.resume_status === 'potentially_available' && r.next_command === resumeCommand(c, id2) && r.observations !== null && typeof r.observations === 'object',
      lastStarted: same(ctx.data.last_built, { slug: 'fixture', run_id: id2 }) && ctx.data.active === null,
      rejectedDoesNotReplace: reject.code !== 0 && same(afterReject.data.last_built, ctx.data.last_built),
      resumeLineage: resume.code !== 0 && resume.out.includes(id3) && rr.resumed_from === id2 && rr.root_run === id2 && last.data.last_built.run_id === id3,
      originalResults: original === fs.readFileSync(runpath(c, id1, 'result.json'), 'latin1') && old2 === fs.readFileSync(runpath(c, id2, 'result.json'), 'latin1'),
      inspectReadOnly: inspectClean,
      receipt: b2.out.includes(id2) && b2.out.includes('building') && b2.out.includes('inspect') && b2.out.includes(c.repo),
    };
  },
  async lifecycle(c) {
    const gate = path.join(c.root, 'verify-gate'), marker = path.join(c.root, 'verify-marker'), release = path.join(c.root, 'verify-release');
    const step = path.join(c.repo, 'features/steps/integration_steps.js');
    const original = fs.readFileSync(step, 'utf8');
    fs.writeFileSync(step, `${original}\nconst fs=require('node:fs'); const {Before}=require('@cucumber/cucumber'); Before(function(){ if(fs.existsSync(${JSON.stringify(gate)})){fs.writeFileSync(${JSON.stringify(marker)},'waiting'); while(!fs.existsSync(${JSON.stringify(release)})) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,20);}});\n`);
    await approveFixture(c);
    await H.signCommits(c);
    const commitMarker = path.join(c.root, 'commit-marker'), commitRelease = path.join(c.root, 'commit-release');
    await H.writeHook(c, `touch ${q(commitMarker)}; while ! test -f ${q(commitRelease)}; do sleep 0.02; done\n`);
    fs.writeFileSync(gate, '');
    script(c, [{ pause: f('write_file', { path: 'app.txt', content: 'builder work\n' }) }, f('finish', { summary: 'done' }), { pause: f('write_file', { path: 'app.txt', content: 'reviewer repair\n' }) }, f('submit_review', { verdict: 'approve', findings: [] })]);
    const p = H.startKogen(c, ['intent', 'build', 'fixture']);
    let peer = await c.server.waitPaused(); const a = await context(c); const id = a.active.run_id; peer.continue();
    await H.waitForFile(marker); const b = await context(c);
    fs.writeFileSync(release, '');
    peer = await c.server.waitPaused(); const d = await context(c);
    fs.rmSync(marker); fs.rmSync(release); peer.continue();
    await H.waitForFile(marker); const e = await context(c); fs.writeFileSync(release, '');
    await H.waitForFile(commitMarker); const h = await context(c); fs.writeFileSync(commitRelease, '');
    const { out, code } = await p.awaitExit(30000);
    const final = await context(c); const head = await git(c, ['rev-parse', 'HEAD']);
    const verified = await H.gitBang(c, ['verify-commit', head]);
    const inspect = await json0(c, ['intent', 'inspect', id, '--json']); const r = inspect.data;
    const result = JSON.parse(fs.readFileSync(runpath(c, id, 'result.json'), 'utf8'));
    return {
      phases: [a, b, d, e, h].map(x => x.active.phase), passes: [a, b, d, e, h].map(x => x.active.verification_pass),
      oneReviewerConversation: result.reviews === 1 && c.server.reviewRequests().length === 2,
      oneSignedCommit: code === 0 && verified.includes('Good') && (await git(c, ['show', 'HEAD:app.txt'])) === 'reviewer repair' && out.includes('landed'),
      idleRetainsLast: final.active === null && same(final.last_built, { slug: 'fixture', run_id: id }),
      landedInspection: r.commit === head && r.state === 'landed' && r.verification.length > 0 && r.reviews.length > 0 && r.resumed_from === null && r.root_run === id,
      localNotCommitted: !(await git(c, ['ls-tree', '-r', '--name-only', 'HEAD'])).includes('.kogen/local/'),
    };
  },
  async stopped(c, _, mode) {
    const marker = path.join(c.repo, '.kogen/local/pause');
    script(c, [f('shell', { command: `touch ${q(marker)}; sleep 600` })]);
    const before = await git(c, ['rev-parse', 'HEAD']);
    const p = H.startKogen(c, ['intent', 'build', 'fixture']);
    await H.waitForFile(marker); const active = await context(c); const id = active.active.run_id;
    assert.equal(typeof id, 'string', JSON.stringify(active));
    // The Go program is one process: its owner stops by the signal it is sent (the former separate core cannot crash alone).
    p.signal({ interrupt: 'SIGINT', 'cli-death': 'SIGKILL', 'core-crash': 'SIGTERM' }[mode]);
    const { out, code } = await p.awaitExit(15000);
    const stopped = await waitIdle(c, now() + 15000);
    const doc = await json0(c, ['intent', 'inspect', id, '--json']); const r = doc.data;
    return {
      observedActive: active.active.phase === 'building', cleared: stopped.active === null, lastRetained: stopped.last_built.run_id === id,
      noCommit: (await git(c, ['rev-parse', 'HEAD'])) === before,
      inspectionStopped: r.state !== 'active' && r.phase === 'building' && r.reason !== null,
      receipt: mode === 'cli-death' ? r.locations.run_dir !== null && r.state === 'interrupted' : code === (mode === 'interrupt' ? 130 : 143) && out.includes(id) && out.includes('inspect'),
    };
  },
  async invalid(c) {
    await H.runKogen(c, ['intent', 'build', 'fixture']);
    const file = path.join(c.repo, '.kogen/local/context.json'); const saved = fs.readFileSync(file);
    fs.writeFileSync(file, '{broken');
    const before = await custody(c); const bad = await json0(c, ['context']);
    const malformed = bad.data.integration_state === 'invalid' && bad.data.active === null;
    const unchanged = fs.readFileSync(file, 'utf8') === '{broken' && same(await custody(c), before);
    fs.rmSync(file); const missing = await json0(c, ['context']);
    const absent = !fs.existsSync(file);
    fs.writeFileSync(file, saved);
    return { malformedSafe: malformed, missingSafe: missing.data.active === null && missing.data.integration_state === 'missing', noReconstruction: missing.data.last_built === null && absent, readOnly: unchanged };
  },
  async preflight(c) {
    const trace = path.join(c.root, 'executed');
    await configureSetup(c, `echo unexpected >> ${q(trace)}`);
    await approveFixture(c); fs.rmSync(trace, { force: true });
    const before = await custody(c); const n = count(c);
    const [green, gcode] = await json(c, ['intent', 'preflight', 'fixture', '--json']);
    let readOnly = same(await custody(c), before);
    fs.writeFileSync(path.join(c.repo, 'app.txt'), 'dirty\n');
    const dirtyBefore = await custody(c); const [dirty, dcode] = await json(c, ['intent', 'preflight', 'fixture', '--json']);
    readOnly = readOnly && same(await custody(c), dirtyBefore);
    fs.writeFileSync(path.join(c.repo, 'app.txt'), before.app);
    const ap = H.approvalPath(c.repo, 'fixture'); const approval = JSON.parse(fs.readFileSync(ap, 'utf8'));
    fs.writeFileSync(ap, JSON.stringify({ ...approval, sha256: '0'.repeat(64) }));
    const badBefore = await custody(c); const [changed, ccode] = await json(c, ['intent', 'preflight', 'fixture', '--json']);
    readOnly = readOnly && same(await custody(c), badBefore); fs.writeFileSync(ap, before.approval, 'latin1');
    const lock = path.join(c.repo, '.kogen/local/build.lock'); const release = H.acquireLock(lock);
    try {
      const lockedBefore = await custody(c); const lockBefore = fs.readdirSync(lock);
      const [conflict, fcode] = await json(c, ['intent', 'preflight', 'fixture', '--json']);
      return {
        green: gcode === 0 && green.data.ready === true && same(green.data.checks.map(x => x.name), ['configuration', 'package', 'approval', 'cleanliness', 'conflict']),
        scopeHonest: Array.isArray(green.data.limitations) && /setup[\s\S]*checks|checks[\s\S]*setup/i.test(JSON.stringify(green.data.limitations)),
        dirtyBlocked: dcode === 1 && dirty.data.ready === false && JSON.stringify(dirty.data.blockers).includes('app.txt'),
        approvalBlocked: ccode === 1 && changed.data.ready === false && JSON.stringify(changed.data.blockers).includes('approval'),
        conflictBlocked: fcode === 1 && conflict.data.ready === false && JSON.stringify(conflict.data.blockers).includes('build_running'),
        readOnly: readOnly && same(await custody(c), lockedBefore) && same(fs.readdirSync(lock), lockBefore),
        noCommandsOrProvider: !fs.existsSync(trace) && n === count(c),
      };
    } finally { release(); }
  },
  async fast(c, _, mode, o) {
    await H.runKogen(c, ['intent', 'build', 'fixture']); const [id] = runIds(c);
    const legacy = '00000000'; fs.mkdirSync(path.dirname(runpath(c, legacy, 'log.jsonl')), { recursive: true });
    fs.writeFileSync(runpath(c, legacy, 'result.json'), JSON.stringify({ slug: 'fixture', build: legacy, outcome: 'failed' }));
    const completion = await H.runKogen(c, ['completion', 'zsh']); assert.equal(completion.code, 0, completion.out);
    const scriptfile = path.join(c.root, '_kogen'); fs.writeFileSync(scriptfile, completion.out);
    const syntax = spawnSync('zsh', ['-n', scriptfile], { encoding: 'utf8' }); assert.equal(syntax.status, 0, syntax.stdout + syntax.stderr);
    const intents = await H.runKogen(c, ['__complete', 'build']); assert.equal(intents.code, 0, intents.out);
    const resumes = await H.runKogen(c, ['__complete', 'resume']); assert.equal(resumes.code, 0, resumes.out);
    const n = count(c); const base = await measure(c, o.samples);
    for (let x = 1; x <= 2000; x++) {
      const dir = path.join(c.repo, `.kogen/local/runs/history-${x}`); fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(path.join(dir, 'log.jsonl'), 'not a summary\n'.repeat(16));
    }
    const accumulated = await measure(c, o.samples);
    const runs = path.join(c.repo, '.kogen/local/runs'), backup = `${runs}-saved`; fs.renameSync(runs, backup);
    assert.equal(spawnSync('mkfifo', [runs]).status, 0);
    try {
      const ctx = await json0(c, ['context']);
      const candidates = await H.runKogen(c, ['__complete', 'resume']); assert.equal(candidates.code, 0, candidates.out);
      const blocked = await measure(c, o.samples);
      const timings = { platform: `${os.platform()}-${os.arch()}`, samples: o.samples, baseline: base, accumulated, blocked };
      return {
        completionSyntax: syntax.status === 0 && completion.out.includes('_kogen') && completion.out.includes('__complete'),
        intentCandidates: intents.out.split('\n').some(l => l.startsWith('fixture\t')),
        resumeCandidates: resumes.out.split('\n').some(l => l.startsWith(`${id}\t`) && l.includes('fixture')),
        unsupportedExcluded: !resumes.out.includes(legacy), noCoreOrHistory: ctx.data.last_built.run_id === id && candidates.out === resumes.out,
        noProvider: n === count(c), measuredWithinBudget: [base, accumulated, blocked].every(group => Object.values(group).every(x => x.p95 <= o.p95 && x.max <= o.max)), measurementsRecorded: true, timings,
      };
    } finally { fs.rmSync(runs, { force: true }); fs.renameSync(backup, runs); }
  },
  async errors(c) {
    const list = await json0(c, ['intent', 'list', '--json']);
    const [unknown, k] = await json(c, ['intent', 'inspect', 'ffffffff', '--json']);
    const limits = [];
    for (const n of ['0', '101', 'x']) { const [d, kk] = await json(c, ['intent', 'list', '--json', '--limit', n]); limits.push(kk === 2 && d.error.reason === 'invalid_argument'); }
    const [bad, bk] = await json(c, ['context', '--project', path.join(c.root, 'absent')]);
    const human = await H.runKogen(c, ['intent', 'list']);
    const pkg = path.join(c.repo, '.kogen/intents'); fs.renameSync(pkg, `${pkg}-saved`);
    const [empty, ek] = await json(c, ['intent', 'list', '--json']); fs.renameSync(`${pkg}-saved`, pkg);
    return {
      versioned: [list, unknown, bad, empty].every(d => d.schema_version === 1 && 'checkout' in d && 'data' in d && 'error' in d),
      emptyList: ek === 0 && same(empty.data.items, []) && empty.data.next_cursor === null,
      unknownRun: k === 1 && unknown.error.reason === 'run_not_found', invalidLimits: limits.every(Boolean),
      unavailableProject: bk === 3 && bad.error.reason === 'project_unavailable',
      humanOutput: human.code === 0 && human.out.includes('fixture') && !human.out.trim().startsWith('{'),
    };
  },
};

AfterAll(function () { /* the shared support removes its own work folder */ });
async function exercise(world, mode, samples = 20, p95 = 100, max = 500) {
  const suite = await H.setupSuite(); let c;
  try {
    c = await H.project(suite, [], { stagedIntent: false });
    const { out, code } = await H.runKogen(c, ['context']);
    let doc; try { doc = JSON.parse(out); } catch {}
    let receipt;
    if (doc && doc.schema_version === 1 && doc.kind === 'context' && code === 0) {
      assert.ok(doc.data && typeof doc.data === 'object', out);
      const name = ['interrupt', 'core-crash', 'cli-death'].includes(mode) ? 'stopped' : mode;
      receipt = { ...(await exercises[name](c, doc, mode, { samples, p95, max })), supported: true };
    } else receipt = { supported: false, output: out, code };
    world.checkoutCLI = receipt;
    await world.attach(JSON.stringify(receipt), 'application/json');
  } finally { await H.cleanupCase(c); H.cleanupSuite(suite); }
}
When('I exercise checkout CLI facts in mode {string}', { timeout: 300000 }, async function (mode) { await exercise(this, mode); });
When('I exercise checkout CLI facts in mode {string} with {int} samples and p95 budget {int} and maximum {int} milliseconds', { timeout: 300000 }, async function (mode, samples, p95, max) { await exercise(this, mode, samples, p95, max); });
Then('the checkout CLI observations are:', function (table) {
  assert.ok(this.checkoutCLI, 'no installed observations');
  for (const [key, raw] of table.raw()) assert.deepEqual(this.checkoutCLI[key], JSON.parse(raw), `${key}: ${JSON.stringify(this.checkoutCLI)}`);
});
