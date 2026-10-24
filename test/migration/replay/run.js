'use strict';
// node run.js <kogen> <out>: the bounded production-transition replay (see docs/evidence/go-core-migration/replay.md).
//
// For each journey: run it with the installed kogen under test, write the observations, generate a Quint trace
// over spec/quint/build.qnt and run `quint test` on it (it must pass). For each production mutant: apply it to an
// isolated copy of cli/, build it into a mutant kogen, run the matching journey with it, generate its trace and run
// `quint test` on that (it must fail with an expectation or invariant failure).
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const { Lab, which } = require('./lab.js');
const { journeys } = require('./journeys.js');
const { generate } = require('./trace.js');

const REPO = path.resolve(__dirname, '../../..');
const CASES = ['approval', 'verification-review', 'interruption-resume', 'commit-recovery'];
const QUINT = path.join(REPO, 'spec/node_modules/@informalsystems/quint/dist/src/cli.js');

const [, , kogenArg, outArg] = process.argv;
if (!kogenArg || !outArg) { console.error('usage: node run.js <kogen> <out>'); process.exit(2); }
const kogen = path.resolve(kogenArg), out = path.resolve(outArg);
const rel = p => path.relative(out, p).split(path.sep).join('/');
const log = (...a) => console.error('replay:', ...a);
const writeJSON = (file, data) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`); };

function execute(file, args, { cwd, env = process.env, timeout = 15 * 60000 } = {}) {
  return new Promise(resolve => {
    const child = cp.spawn(file, args, { cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
    const out = [], err = [];
    child.stdout.on('data', b => out.push(b)); child.stderr.on('data', b => err.push(b));
    const timer = setTimeout(() => child.kill('SIGKILL'), timeout);
    child.once('close', code => { clearTimeout(timer); resolve({ code, stdout: Buffer.concat(out).toString('utf8'), stderr: Buffer.concat(err).toString('utf8') }); });
  });
}

async function quintTest(trace) {
  const r = await execute(process.execPath, [QUINT, 'test', trace], { cwd: path.dirname(trace) });
  const text = `${r.stdout}\n${r.stderr}`;
  fs.writeFileSync(path.join(path.dirname(trace), 'quint.txt'), text);
  const passing = Number(/(\d+) passing/.exec(text)?.[1] || 0), failed = Number(/^\s*(\d+) failed/m.exec(text)?.[1] || 0);
  return { code: r.code, passing, failed, text };
}

// Run one journey with one kogen and write observations and the trace into dir.
async function replay(name, kogenBin, dir, strict) {
  const lab = await new Lab({ kogen: kogenBin, node: process.execPath, label: name, strict }).init();
  let failure = null;
  try { await journeys[name](lab); } catch (e) { failure = e; }
  try {
    lab.runRecords(dir);
    const observations = {
      journey: name, strict, kogen: strict ? 'installed' : 'mutant',
      deviations: lab.deviations, snapshotErrors: lab.snapshotErrors, failure: failure ? failure.message : null,
      refusals: lab.refusals, notes: lab.notes, commands: lab.commands, chains: lab.chains,
    };
    writeJSON(path.join(dir, 'observations.json'), observations);
    if (failure) throw failure;
    if (lab.chains.length === 0) throw new Error(`${name}: no observations were taken`);
    const t = generate(name, lab.chains, `${path.relative(dir, path.join(out, 'model'))}/build`);
    fs.writeFileSync(path.join(dir, 'trace.qnt'), t.text);
    return { observations, trace: t };
  } finally {
    await lab.close();
  }
}

// A refutation: only this trace's own tests fail, each on an expectation (QNT508 "Expect condition does not hold true")
// or on an invariant or a transition the model does not allow ("Cannot continue"), never on a parse, type or
// evaluator error.
function refutation(res, ownTests) {
  const failedNames = [...res.text.matchAll(/^\s*\d+\) (\w+) failed after/gm)].map(m => m[1]);
  const codes = [...new Set([...res.text.matchAll(/\[?(QNT\d{3})\]?/g)].map(m => m[1]))];
  const own = failedNames.length > 0 && failedNames.every(n => ownTests.includes(n));
  const kind = /Expect condition does not hold/.test(res.text) ? 'expectation' : /invariant|violated/i.test(res.text) ? 'invariant' : /Cannot continue/.test(res.text) ? 'transition not allowed by the model' : null;
  return { refuted: res.code !== 0 && own && kind !== null && codes.every(c => c === 'QNT508'), kind, failedNames, codes };
}

// The first step of the failing test whose prefix already fails: where the model and the observation part.
async function firstFailingStep(trace, dir, name) {
  const info = trace.steps.find(s => s.name === name);
  const fails = async k => {
    const file = path.join(dir, 'prefix.qnt');
    fs.writeFileSync(file, trace.only(name, k));
    const r = await execute(process.execPath, [QUINT, 'test', '--match', `^${name}$`, file], { cwd: dir });
    return r.code !== 0;
  };
  let lo = 1, hi = info.count;
  if (!(await fails(hi))) return null;
  while (lo < hi) { const mid = (lo + hi) >> 1; if (await fails(mid)) hi = mid; else lo = mid + 1; }
  fs.rmSync(path.join(dir, 'prefix.qnt'), { force: true });
  return { step: lo, of: info.count, action: info.actions[lo - 1], observed: info.comments[lo - 1] };
}

async function buildMutant(m, dir) {
  const copy = path.join(dir, 'cli');
  fs.rmSync(copy, { recursive: true, force: true });
  fs.cpSync(path.join(REPO, 'cli'), copy, { recursive: true, filter: src => !src.endsWith('_test.go') && path.basename(src) !== 'kogen' });
  const pristine = path.join(dir, 'original');
  for (const file of new Set(m.edits.map(e => e.file))) {
    fs.mkdirSync(path.dirname(path.join(pristine, file)), { recursive: true });
    fs.copyFileSync(path.join(copy, file), path.join(pristine, file));
  }
  for (const edit of m.edits) {
    const target = path.join(copy, edit.file);
    const before = fs.readFileSync(target, 'utf8');
    const count = before.split(edit.old).length - 1;
    if (count !== 1) throw new Error(`mutant ${m.id}: the text to change occurs ${count} times in cli/${edit.file} (production code moved?):\n${edit.old}`);
    fs.writeFileSync(target, before.replace(edit.old, () => edit.new));
  }
  const patch = [];
  for (const file of [...new Set(m.edits.map(e => e.file))]) {
    const d = await execute('diff', ['-u', '--label', `a/cli/${file}`, '--label', `b/cli/${file}`, path.join(pristine, file), path.join(copy, file)]);
    patch.push(d.stdout);
  }
  fs.rmSync(pristine, { recursive: true, force: true });
  fs.writeFileSync(path.join(dir, 'mutant.patch'), patch.join(''));
  // An install-shaped folder: the mutant program in bin/, everything else shared with the installed kogen.
  const root = path.dirname(path.dirname(fs.realpathSync(kogen)));
  const install = path.join(dir, 'install/lib/kogen');
  fs.mkdirSync(path.join(install, 'bin'), { recursive: true });
  for (const entry of fs.readdirSync(root)) if (entry !== 'bin') fs.symlinkSync(path.join(root, entry), path.join(install, entry));
  const env = { ...process.env, CGO_ENABLED: '0', GOFLAGS: '-buildvcs=false', GOPROXY: 'off', GOTOOLCHAIN: 'local' };
  const built = await execute('go', ['build', '-trimpath', '-o', path.join(install, 'bin/kogen'), '.'], { cwd: copy, env });
  fs.writeFileSync(path.join(dir, 'build.log'), `$ go build -trimpath -o install/lib/kogen/bin/kogen .\n${built.stdout}${built.stderr}exit ${built.code}\n`);
  if (built.code !== 0) throw new Error(`mutant ${m.id} does not build; see ${path.join(dir, 'build.log')}`);
  return path.join(install, 'bin/kogen');
}

(async () => {
  if (!fs.existsSync(QUINT)) throw new Error(`Quint is missing at ${QUINT}; run npm ci in spec/`);
  if (!which('go')) throw new Error('go is not on PATH');
  fs.mkdirSync(out, { recursive: true });
  fs.mkdirSync(path.join(out, 'model'), { recursive: true });
  const model = path.join(out, 'model/build.qnt');
  fs.copyFileSync(path.join(REPO, 'spec/quint/build.qnt'), model);

  const mutants = fs.readdirSync(path.join(__dirname, 'mutants')).filter(f => f.endsWith('.json')).sort().map(f => JSON.parse(fs.readFileSync(path.join(__dirname, 'mutants', f), 'utf8')));
  for (const m of mutants) if (!CASES.includes(m.case)) throw new Error(`mutant ${m.id} names the unknown case ${m.case}`);
  const index = { cases: [] };
  const problems = [];

  for (const name of CASES.filter(c => !process.env.REPLAY_CASES || process.env.REPLAY_CASES.split(',').includes(c))) {
    const dir = path.join(out, 'cases', name);
    fs.rmSync(dir, { recursive: true, force: true });
    log(`journey ${name}`);
    const { trace } = await replay(name, kogen, dir, true);
    const res = await quintTest(path.join(dir, 'trace.qnt'));
    log(`  quint test: ${res.passing} passing, ${res.failed} failed (exit ${res.code})`);
    if (res.code !== 0 || res.failed > 0) problems.push(`${name}: quint test failed on the trace of the installed kogen (see ${rel(path.join(dir, 'quint.txt'))})`);
    const entry = { name, model: 'model/build.qnt', invariant: 'Safety', trace: rel(path.join(dir, 'trace.qnt')), observations: rel(path.join(dir, 'observations.json')), tests: trace.tests, quint: { exit: res.code, passing: res.passing, failed: res.failed }, mutants: [] };

    for (const m of mutants.filter(m => m.case === name)) {
      const mdir = path.join(out, 'mutants', m.id);
      fs.rmSync(mdir, { recursive: true, force: true });
      fs.mkdirSync(mdir, { recursive: true });
      log(`mutant ${m.id}`);
      const bin = await buildMutant(m, mdir);
      let status = { id: m.id, case: name, description: m.description, built: true };
      try {
        const run = await replay(name, bin, mdir, false);
        const mres = await quintTest(path.join(mdir, 'trace.qnt'));
        status = { ...status, journeyDeviations: run.observations.deviations.map(d => d.split('\n')[0].slice(0, 300)), quint: { exit: mres.code, passing: mres.passing, failed: mres.failed }, ...refutation(mres, run.trace.tests) };
        if (status.refuted) status.firstFailingStep = await firstFailingStep(run.trace, mdir, status.failedNames[0]);
        log(`  quint test: ${mres.passing} passing, ${mres.failed} failed (exit ${mres.code}); refuted: ${status.refuted} (${status.kind}; ${status.codes.join(',')}); first failing step: ${status.firstFailingStep ? `${status.firstFailingStep.step}/${status.firstFailingStep.of} ${status.firstFailingStep.action}` : '-'}`);
        if (!status.refuted) problems.push(`${m.id}: the trace of the mutant was not refuted by quint test (see ${rel(path.join(mdir, 'quint.txt'))})`);
      } catch (e) {
        status = { ...status, refuted: false, error: e.message };
        problems.push(`${m.id}: ${e.message}`);
      }
      writeJSON(path.join(mdir, 'status.json'), status);
      fs.rmSync(path.join(mdir, 'install'), { recursive: true, force: true });
      fs.rmSync(path.join(mdir, 'cli'), { recursive: true, force: true });
      entry.mutants.push({ id: m.id, patch: rel(path.join(mdir, 'mutant.patch')), trace: rel(path.join(mdir, 'trace.qnt')), observations: rel(path.join(mdir, 'observations.json')), build: rel(path.join(mdir, 'build.log')), status: rel(path.join(mdir, 'status.json')), refuted: status.refuted === true, failure: status.kind });
    }
    index.cases.push(entry);
  }
  writeJSON(path.join(out, 'replay.json'), index);
  if (problems.length) { console.error(`replay: ${problems.length} problem(s):\n- ${problems.join('\n- ')}`); process.exit(1); }
  log('every trace of the installed kogen passes and every mutant is refuted');
})().catch(e => { console.error(`replay: ${e.stack || e.message}`); process.exit(1); });
