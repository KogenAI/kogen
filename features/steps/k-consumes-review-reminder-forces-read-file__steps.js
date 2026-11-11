'use strict';
// Acceptance of k-consumes-review-reminder-forces-read-file: kogen's
// TestKReviewVerdictStrandPinnedResume runs against kogen-review variants (the committed go.mod,
// a read_file stand-in for kogen-review's review-reminder-reads-unread-parts change and a fault of
// that stand-in) and go test -json is judged. Stand-in modules and go.mod files are made in a
// temporary directory; the checkout is not written. Run directly with `good` or `bad`, the file
// instead runs the judge's observer controls on real go test output of the committed go.mod.
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
const P = 'k-consumes-review-reminder-forces-read-file: ';
const RUN_LIMIT_MS = 200000;

function goEnv(modfile) {
  return { ...process.env, GOFLAGS: modfile ? `-trimpath -modfile=${modfile}` : '-trimpath' };
}

function must(cwd, command, args, env) {
  const r = spawnSync(command, args, { cwd, env: env || goEnv(), encoding: 'utf8', timeout: 120000, maxBuffer: 64 << 20 });
  if (r.error || r.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} in ${cwd}: exit ${r.status}, error ${r.error || 'none'}\n${r.stdout}\n${r.stderr}`);
  }
  return r.stdout;
}

// edit replaces from by to in file of the module copy dir, which must contain from count times.
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

// replacing is a copy of cli/go.mod (and go.sum) that replaces kogen-review by dir.
function replacing(work, name, dir) {
  const mod = path.join(work, `${name}.mod`);
  fs.copyFileSync(path.join(cli, 'go.mod'), mod);
  fs.copyFileSync(path.join(cli, 'go.sum'), mod.replace(/\.mod$/, '.sum'));
  must(work, 'go', ['mod', 'edit', `-replace=${MODULE}=${dir}`, mod]);
  return mod;
}

// prepare makes every variant's go.mod: null for the committed one.
function prepare(c, work) {
  const info = JSON.parse(must(cli, 'go', ['mod', 'download', '-json', `${MODULE}@${c.pinned}`]));
  assert.ok(info.Dir, `go mod download names no directory for ${MODULE}@${c.pinned}`);
  const variants = { committed: null };
  for (const [name, edits] of Object.entries(c.variants)) {
    const dir = path.join(work, name.replace(/[^a-z0-9]+/gi, '-'));
    copyModule(info.Dir, dir);
    for (const e of edits) edit(dir, e);
    variants[name] = replacing(work, name.replace(/[^a-z0-9]+/gi, '-'), dir);
  }
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
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'k-consumes-review-reminder-forces-read-file-'));
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

// judge accepts a go test -json run in which test ran once with the expected outcome (pass or
// fail), the package result and exit status agree and, when message is given, the test's output
// contains it; otherwise it throws. Every message starts with the test, the package, the command,
// how often the test ran and its outcome, followed by go test's own text output.
function judge(r, test, expected, message) {
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
    `${r.error ? `, error ${r.error}` : ''}; want ${expected}${message ? ` reporting ${JSON.stringify(message)}` : ''}`;
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
  if (message) {
    const own = rows.filter(x => x.Test === test && x.Action === 'output').map(x => x.Output).join('');
    assert.ok(own.includes(message), `${test} failed without reporting ${JSON.stringify(message)}; ${diagnostic}`);
  }
}

module.exports = { judge, runTest };

if (require.main === module) {
  // Observer controls on real go test output of the committed go.mod: good accepts a real passing
  // run; bad must reject a real passing run judged as failing (with or without a message) and a
  // real run that ran nothing.
  const accepts = (r, test, expected, message) => { try { judge(r, test, expected, message); return true; } catch { return false; } };
  (async () => {
    const passing = await runTest(TEST);
    let ok;
    if (process.argv[2] === 'good') {
      ok = accepts(passing, TEST, 'pass');
    } else {
      const absent = 'TestKConsumesReviewReminderForcesReadFileAbsent';
      const none = await runTest(absent);
      ok = accepts(passing, TEST, 'fail') || accepts(passing, TEST, 'fail', 'conversation') || accepts(none, absent, 'pass');
    }
    process.stdout.write(ok ? 'accepted\n' : 'rejected\n');
    process.exitCode = ok ? 0 : 1;
  })();
} else {
  const { Given, Then } = require('@cucumber/cucumber');
  const LIMIT = { timeout: 240000 };
  let memo = null;
  const result = async (world, key) => {
    const config = JSON.stringify(world.kcrr);
    if (!memo || memo.config !== config) memo = { config, runs: runAll(world.kcrr) };
    const runs = await memo.runs;
    assert.ok(runs.has(key), `no variant ${key}`);
    return runs.get(key);
  };

  // A "/" in a Cucumber expression is alternation, so the literal slashes are escaped.
  Given(P + 'cli\\/go.mod requires github.com\\/KogenAI\\/kogen-review at {word} without replacing it', function (version) {
    const lines = fs.readFileSync(path.join(cli, 'go.mod'), 'utf8').split('\n').map(l => l.trim());
    assert.ok(lines.includes(`${MODULE} ${version}`), `cli/go.mod does not require ${MODULE} ${version}`);
    assert.deepEqual(lines.filter(l => l.includes(MODULE) && l.includes('=>')), [], `cli/go.mod replaces ${MODULE}`);
    this.kcrr = { pinned: version, variants: {} };
  });
  Given(P + 'the kogen-review stand-ins are the pinned kogen-review with these edits:', function (table) {
    for (const row of table.hashes()) (this.kcrr.variants[row.stand_in] ||= []).push(row);
  });

  Then(P + 'TestKReviewVerdictStrandPinnedResume passes with the committed go.mod', LIMIT, async function () {
    judge(await result(this, 'committed'), TEST, 'pass');
  });
  Then(P + 'TestKReviewVerdictStrandPinnedResume passes against the stand-in {string}', LIMIT, async function (name) {
    assert.ok(this.kcrr.variants[name], `no stand-in named ${name}`);
    judge(await result(this, name), TEST, 'pass');
  });
  Then(P + 'TestKReviewVerdictStrandPinnedResume fails against the stand-in {string} reporting:', LIMIT, async function (name, message) {
    assert.ok(this.kcrr.variants[name], `no stand-in named ${name}`);
    judge(await result(this, name), TEST, 'fail', message);
  });
}
