'use strict';
// Acceptance of k-consumes-review-parts-unpinned: kogen's TestKReviewVerdictStrandPinnedResume runs
// against kogen-review variants (the committed go.mod, kogen-review main, a stand-in for the layout
// of 7d005ed6 and two faults of that stand-in) and go test -json is judged. Variant modules and go.mod
// files are made in a temporary directory; the checkout is not written. Run directly with `good` or
// `bad`, the file instead runs the judge's observer controls on real go test output.
const { spawn, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');

const root = path.resolve(__dirname, '../..');
const cli = path.join(root, 'cli');
const pkg = path.join(cli, 'buildprogram');
const MODULE = 'github.com/KogenAI/kogen-review';
const TEST = 'TestKReviewVerdictStrandPinnedResume';
const P = 'k-consumes-review-parts-unpinned: ';
const RUN_LIMIT_MS = 105000;

function goEnv(modfile) {
  return { ...process.env, GOFLAGS: modfile ? `-trimpath -modfile=${modfile}` : '-trimpath' };
}

function must(cwd, command, args, env) {
  const r = spawnSync(command, args, { cwd, env: env || goEnv(), encoding: 'utf8', timeout: 90000, maxBuffer: 64 << 20 });
  if (r.error || r.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} in ${cwd}: exit ${r.status}, error ${r.error || 'none'}\n${r.stdout}\n${r.stderr}`);
  }
  return r.stdout;
}

function edit(dir, { file, from, to, count }) {
  const f = path.join(dir, file);
  const text = fs.readFileSync(f, 'utf8');
  const found = text.split(from).length - 1;
  assert.equal(found, Number(count), `stand-in edit of ${file}: ${JSON.stringify(from)} occurs ${found} time(s), want ${count}`);
  fs.writeFileSync(f, text.split(from).join(to));
}

function copyModule(from, to) {
  must(path.dirname(to), 'cp', ['-R', from, to]);
  must(path.dirname(to), 'chmod', ['-R', 'u+w', to]);
}

// replacing is a copy of the main go.mod (and go.sum) that replaces kogen-review by dir.
function replacing(work, name, main, dir) {
  const mod = path.join(work, `${name}.mod`);
  fs.copyFileSync(main, mod);
  fs.copyFileSync(main.replace(/\.mod$/, '.sum'), mod.replace(/\.mod$/, '.sum'));
  must(work, 'go', ['mod', 'edit', `-replace=${MODULE}=${dir}`, mod]);
  return mod;
}

// prepare makes every variant's go.mod: null for the committed one.
function prepare(c, work) {
  const main = path.join(work, 'main.mod');
  fs.copyFileSync(path.join(cli, 'go.mod'), main);
  fs.copyFileSync(path.join(cli, 'go.sum'), path.join(work, 'main.sum'));
  must(cli, 'go', ['get', `${MODULE}@${c.main}`], goEnv(main));
  const required = fs.readFileSync(main, 'utf8').split('\n').map(l => l.trim());
  assert.ok(required.includes(`${MODULE} ${c.main}`), `go get did not make the main variant require ${MODULE} ${c.main}:\n${required.join('\n')}`);
  const info = JSON.parse(must(cli, 'go', ['mod', 'download', '-json', `${MODULE}@${c.main}`], goEnv(main)));
  const standin = path.join(work, 'standin');
  copyModule(info.Dir, standin);
  for (const e of c.edits) edit(standin, e);
  assert.ok(c.added, 'the stand-in names no added file');
  fs.writeFileSync(path.join(standin, c.added.file), c.added.text);
  const variants = { committed: null, main, standin: replacing(work, 'standin', main, standin) };
  Object.values(c.faults).forEach((fault, i) => {
    const dir = path.join(work, `fault-${i + 1}`);
    copyModule(standin, dir);
    edit(dir, fault);
    variants[`fault:${fault.fault}`] = replacing(work, `fault-${i + 1}`, main, dir);
  });
  return variants;
}

// runTest runs one named test of package buildprogram with go test -json under modfile.
function runTest(name, modfile) {
  const args = ['test', '-json', '-count=1', '-run', `^${name}$`, '.'];
  const command = `GOFLAGS='${goEnv(modfile).GOFLAGS}' go ${args.join(' ')} (in cli/buildprogram)`;
  return new Promise(resolve => {
    const child = spawn('go', args, { cwd: pkg, env: goEnv(modfile), detached: true });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', d => { stdout += d; });
    child.stderr.on('data', d => { stderr += d; });
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, RUN_LIMIT_MS);
    child.on('error', error => { clearTimeout(timer); resolve({ status: null, error, stdout, stderr, command, timedOut }); });
    child.on('close', (status, signal) => { clearTimeout(timer); resolve({ status, signal, stdout, stderr, command, timedOut }); });
  });
}

async function runAll(c) {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'k-consumes-review-parts-unpinned-'));
  try {
    const variants = prepare(c, work);
    const keys = Object.keys(variants);
    const results = await Promise.all(keys.map(k => runTest(TEST, variants[k])));
    return new Map(keys.map((k, i) => [k, results[i]]));
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

// bounded keeps the head and tail of a long text.
function bounded(text, head, tail) {
  if (text.length <= head + tail) return text;
  return `${text.slice(0, head)}\n[... ${text.length - head - tail} characters omitted ...]\n${text.slice(-tail)}`;
}

// judge accepts a go test -json run in which test ran once with the expected outcome
// (pass or fail) and the package result and exit status agree; otherwise it throws. Every
// message starts with the test, the package, the command, how often the test ran and its
// outcome, followed by go test's own text output (the Output rows in order).
function judge(r, test, expected) {
  const rows = [];
  for (const line of r.stdout.split('\n')) {
    if (!line.startsWith('{')) continue;
    try { rows.push(JSON.parse(line)); } catch { rows.push({ Action: 'malformed', Output: line }); }
  }
  const count = action => rows.filter(x => x.Test === test && x.Action === action).length;
  const runs = count('run');
  const outcomes = ['pass', 'fail', 'skip'].filter(a => count(a) > 0);
  const outcome = runs === 0 ? 'absent (ran zero times)' : outcomes.length ? outcomes.join('+') : 'no result';
  const text = rows.filter(x => x.Action === 'output' || x.Action === 'malformed').map(x => x.Output).join('');
  const summary = `${test} in package kogen/buildprogram, ${r.command}: ran ${runs} time(s), outcome ${outcome}, ` +
    `go test exit ${r.status}${r.signal ? `, signal ${r.signal}` : ''}${r.timedOut ? `, killed after ${RUN_LIMIT_MS} ms` : ''}` +
    `${r.error ? `, error ${r.error}` : ''}; want ${expected}`;
  const diagnostic = `${summary}\ngo test output:\n${bounded(text, 4000, 6000)}\nstderr:\n${bounded(r.stderr, 1000, 2000)}`;
  const other = expected === 'pass' ? 'fail' : 'pass';
  assert.equal(rows.filter(x => x.Action === 'malformed').length, 0, `go test -json printed a malformed row; ${diagnostic}`);
  assert.equal(runs, 1, `${test} must run exactly once (absent, filtered out or not built otherwise); ${diagnostic}`);
  assert.equal(count('skip'), 0, `${test} was skipped; ${diagnostic}`);
  assert.equal(count(expected), 1, `${test} ran but did not ${expected}; ${diagnostic}`);
  assert.equal(count(other), 0, `${test} ran and reported ${other}; ${diagnostic}`);
  const result = rows.filter(x => x.Test === undefined && (x.Action === 'pass' || x.Action === 'fail'));
  assert.equal(result.length, 1, `${test}: go test gave no single package result; ${diagnostic}`);
  assert.equal(result[0].Action, expected, `${test}: package result ${result[0].Action}; ${diagnostic}`);
  assert.equal(r.status, expected === 'pass' ? 0 : 1, `${test}: go test exit ${r.status}, want ${expected === 'pass' ? 0 : 1}; ${diagnostic}`);
}

module.exports = { judge, prepare, runTest };

if (require.main === module) {
  // Observer controls on real go test output of the committed go.mod: good accepts a real passing
  // run; bad must reject both a real passing run judged as failing and a real run that ran nothing.
  const accepts = (r, test, expected) => { try { judge(r, test, expected); return true; } catch { return false; } };
  (async () => {
    const real = 'TestSatisfiedRebuildAlreadyPresent';
    const passing = await runTest(real);
    let ok;
    if (process.argv[2] === 'good') {
      ok = accepts(passing, real, 'pass');
    } else {
      const absent = 'TestKConsumesReviewPartsUnpinnedAbsent';
      const none = await runTest(absent);
      ok = accepts(passing, real, 'fail') || accepts(none, absent, 'pass');
    }
    process.stdout.write(ok ? 'accepted\n' : 'rejected\n');
    process.exitCode = ok ? 0 : 1;
  })();
} else {
  const { Given, When, Then, setDefaultTimeout } = require('@cucumber/cucumber');
  setDefaultTimeout(115000);
  let memo = null;
  const result = async (world, key) => {
    const config = JSON.stringify(world.krpu);
    if (!memo || memo.config !== config) memo = { config, runs: runAll(world.krpu) };
    const runs = await memo.runs;
    assert.ok(runs.has(key), `no variant ${key}`);
    return runs.get(key);
  };

  Given(P + 'kogen-review main, the newest main commit kogen\'s pinned lineup builds, is {word}', function (version) {
    this.krpu = { main: version, edits: [], faults: {} };
  });
  Given(P + 'the 7d005ed6 layout stand-in is kogen-review main with these edits:', function (table) {
    this.krpu.edits = table.hashes();
  });
  Given(P + 'the stand-in adds the file {word}:', function (file, text) {
    this.krpu.added = { file, text: text.endsWith('\n') ? text : `${text}\n` };
  });
  Given(P + 'the faults of the stand-in are:', function (table) {
    for (const row of table.hashes()) this.krpu.faults[row.fault] = row;
  });

  // A "/" in a Cucumber expression is alternation, so the literal slashes are escaped.
  Then(P + 'cli\\/go.mod requires github.com\\/KogenAI\\/kogen-review at {word} without replacing it', function (version) {
    const lines = fs.readFileSync(path.join(cli, 'go.mod'), 'utf8').split('\n').map(l => l.trim());
    assert.ok(lines.includes(`${MODULE} ${version}`), `cli/go.mod does not require ${MODULE} ${version}`);
    assert.deepEqual(lines.filter(l => l.includes(MODULE) && l.includes('=>')), [], `cli/go.mod replaces ${MODULE}`);
  });

  When(P + 'go test runs TestKReviewVerdictStrandPinnedResume in package buildprogram with the committed go.mod', async function () {
    this.krpuRun = await result(this, 'committed');
  });
  When(P + 'go test runs TestKReviewVerdictStrandPinnedResume in package buildprogram against kogen-review main', async function () {
    this.krpuRun = await result(this, 'main');
  });
  When(P + 'go test runs TestKReviewVerdictStrandPinnedResume in package buildprogram against the stand-in', async function () {
    this.krpuRun = await result(this, 'standin');
  });
  When(P + 'go test runs TestKReviewVerdictStrandPinnedResume in package buildprogram against the stand-in with the fault {string}', async function (fault) {
    assert.ok(this.krpu.faults[fault], `no fault named ${fault}`);
    this.krpuRun = await result(this, `fault:${fault}`);
  });
  Then(P + 'go test reported TestKReviewVerdictStrandPinnedResume passing', function () {
    judge(this.krpuRun, TEST, 'pass');
  });
  Then(P + 'go test reported TestKReviewVerdictStrandPinnedResume failing', function () {
    judge(this.krpuRun, TEST, 'fail');
  });
}
