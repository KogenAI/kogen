'use strict';
// Observes Kogen's go-test check as it runs (`GOFLAGS=-trimpath go test ./...` in cli) with four CPUs' worth of Go
// scheduling (GOMAXPROCS=4: four test binaries at once, four parallel tests in each), uncached and with JSON events:
// how long kogen/build and kogen/shape run their serial tests and in all, whether every package passes, and exactly
// which tests the two packages run. It also checks the durability switch through an acceptance-owned Go test that
// `go test -overlay` adds to kogen/durable without writing into the checkout, and scans the Go test sources.
// Run directly as `node features/steps/k_go_test_critical_path_steps.js --control good|bad`, it checks these
// observers against synthetic Go JSON events and sources, without Go and without the product.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const CLI = path.join(ROOT, 'cli');
const MIN = 60000;
const sha256 = text => crypto.createHash('sha256').update(text).digest('hex');
const nameHash = names => sha256([...names].sort().join('\n') + '\n');
const ENDS = ['pass', 'fail', 'skip'];

// ------------------------------------------------------------------ Go JSON events

function newObservation() { return { packages: new Map(), stopped: null, code: null, signal: null, stderr: '' }; }

function pkgOf(obs, name) {
  if (!obs.packages.has(name)) obs.packages.set(name, { start: null, firstCont: null, end: null, results: [], output: new Map() });
  return obs.packages.get(name);
}

// feed folds one Go test JSON event into the observation; arrived is when it was read (ms).
function feed(obs, ev, arrived) {
  if (!ev || typeof ev.Package !== 'string') return;
  const p = pkgOf(obs, ev.Package);
  const at = Number.isFinite(Date.parse(ev.Time)) ? Date.parse(ev.Time) : arrived;
  if (p.start === null) p.start = at;
  if (ev.Action === 'cont' && ev.Test && !ev.Test.includes('/') && p.firstCont === null) p.firstCont = at;
  if (ev.Action === 'output' && ev.Test) {
    const lines = p.output.get(ev.Test) || [];
    if (lines.length < 60) lines.push(ev.Output);
    p.output.set(ev.Test, lines);
  }
  if (ev.Test && ENDS.includes(ev.Action)) p.results.push({ test: ev.Test, action: ev.Action });
  if (!ev.Test && ENDS.includes(ev.Action)) p.end = { action: ev.Action, elapsed: ev.Elapsed, at };
}

// overdue is why the run must stop now (null: it may go on): a watched package still in its serial phase past its
// serial limit, or still running past the total limit.
function overdue(obs, now, limits) {
  for (const [name, serial] of Object.entries(limits.serial)) {
    const p = obs.packages.get(name);
    if (!p || p.start === null || p.end) continue;
    const ran = (now - p.start) / 1000;
    if (p.firstCont === null && ran > serial) return `${name} was still running serial tests more than ${serial} seconds after it started (${ran.toFixed(1)} s)`;
    if (ran > limits.total) return `${name} was still running more than ${limits.total} seconds after it started (${ran.toFixed(1)} s)`;
  }
  return null;
}

// serialSeconds is how long a package ran tests one at a time: from its start to the first resumed top-level parallel
// test (Go runs every serial top-level test before any parallel one), or to its end or the stop when none resumed.
function serialSeconds(obs, name) {
  const p = obs.packages.get(name);
  if (!p || p.start === null) return null;
  const end = p.firstCont ?? (p.end ? p.end.at : obs.stopped?.at ?? null);
  return end === null ? null : (end - p.start) / 1000;
}

function describeStop(obs) {
  return obs.stopped ? `the run was stopped early: ${obs.stopped.reason}` : `go test exited ${obs.code}${obs.signal ? ' (' + obs.signal + ')' : ''}`;
}

// summary is one line per package: its result, elapsed and serial seconds, for the report.
function summary(obs) {
  const lines = [];
  for (const [name, p] of [...obs.packages].sort()) {
    const s = serialSeconds(obs, name);
    lines.push(`${name}: ${p.end ? p.end.action + " in " + p.end.elapsed + " s" : "unfinished"}, serial ${s === null ? "-" : s.toFixed(1) + " s"}`);
  }
  return lines.join("\n") + (obs.stopped ? `\nstopped: ${obs.stopped.reason}` : "");
}

function checkSerial(obs, name, limit) {
  const s = serialSeconds(obs, name);
  assert.ok(s !== null, `${name} never started (${describeStop(obs)}); go test stderr: ${obs.stderr.slice(-2000)}`);
  const p = obs.packages.get(name);
  const still = p.firstCont === null && !p.end;
  assert.ok(s <= limit, still
    ? `${name} had not resumed any parallel test when the run stopped (${describeStop(obs)}); serial tests may take at most ${limit} seconds`
    : `${name} ran serial tests for ${s.toFixed(1)} seconds before its first parallel test resumed, limit ${limit} seconds`);
}

function failedTests(obs) {
  const out = [];
  for (const [name, p] of obs.packages) {
    for (const r of p.results) if (r.action === 'fail') out.push(`${name} ${r.test}:\n${(p.output.get(r.test) || []).join('').slice(0, 3000)}`);
  }
  return out;
}

function checkAllPassed(obs) {
  assert.equal(obs.stopped, null, describeStop(obs));
  assert.ok(obs.packages.size > 0, `go test reported no packages; stderr: ${obs.stderr.slice(-2000)}`);
  const bad = [];
  for (const [name, p] of obs.packages) {
    if (!p.end) bad.push(`${name}: no final result`);
    else if (p.end.action === 'fail') bad.push(`${name}: failed`);
    else if (p.end.action === 'skip' && p.results.length > 0) bad.push(`${name}: skipped although it has tests`);
  }
  assert.deepEqual(bad, [], `packages that did not pass: ${bad.join('; ')}\n${failedTests(obs).join('\n').slice(0, 12000)}\nstderr: ${obs.stderr.slice(-2000)}`);
  assert.equal(obs.code, 0, `go test exited ${obs.code} although every package passed; stderr: ${obs.stderr.slice(-2000)}`);
}

function checkElapsed(obs, name, limit) {
  const p = obs.packages.get(name);
  assert.ok(p && p.end, `${name} did not finish (${describeStop(obs)})`);
  assert.equal(p.end.action, 'pass', `${name} did not pass`);
  assert.ok(typeof p.end.elapsed === 'number' && p.end.elapsed <= limit, `${name} took ${p.end.elapsed} seconds, limit ${limit} seconds`);
}

function checkInventory(obs, name, count, hash, skips) {
  const p = obs.packages.get(name);
  assert.ok(p && p.end, `${name} did not finish (${describeStop(obs)})`);
  const passed = p.results.filter(r => r.action === 'pass').map(r => r.test);
  const failed = p.results.filter(r => r.action === 'fail').map(r => r.test);
  const skipped = p.results.filter(r => r.action === 'skip').map(r => r.test).sort();
  assert.deepEqual(failed, [], `${name} failed tests: ${failed.join(', ')}`);
  const dups = passed.filter((n, i) => passed.indexOf(n) !== i);
  assert.deepEqual(dups, [], `${name} reported these tests passing more than once: ${dups.join(', ')}`);
  const wantSkips = skips === 'none' ? [] : skips.split(',').map(s => s.trim()).filter(Boolean).sort();
  assert.deepEqual(skipped, wantSkips, `${name} skipped ${JSON.stringify(skipped)}, expected exactly ${JSON.stringify(wantSkips)}`);
  assert.equal(passed.length, count, `${name} passed ${passed.length} tests and subtests, expected ${count}`);
  assert.equal(nameHash(passed), hash, `${name} passed a different set of ${passed.length} test and subtest names (hash ${nameHash(passed)})`);
}

// ------------------------------------------------------------------ processes

const groups = new Set();
const killGroup = (pid, signal) => { try { process.kill(-pid, signal); } catch {} };
process.on('exit', () => { for (const pid of groups) killGroup(pid, 'SIGKILL'); });

// runGo runs go in cli in its own process group, feeding complete stdout lines to onLine; stop(reason) ends the
// group (only the processes this run started).
function runGo(args, env, onLine, hardLimitMs) {
  return new Promise((resolve, reject) => {
    const child = spawn('go', args, { cwd: CLI, env: { ...process.env, ...env }, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    const pid = child.pid;
    if (pid) groups.add(pid);
    let pending = '';
    let stderr = '';
    let stopped = null;
    const stop = reason => {
      if (stopped) return;
      stopped = { reason, at: Date.now() };
      killGroup(pid, 'SIGTERM');
      setTimeout(() => killGroup(pid, 'SIGKILL'), 5000).unref();
    };
    const hard = setTimeout(() => stop(`no result after ${hardLimitMs / 1000} seconds`), hardLimitMs);
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', chunk => {
      pending += chunk;
      let i;
      while ((i = pending.indexOf('\n')) >= 0) {
        const line = pending.slice(0, i);
        pending = pending.slice(i + 1);
        onLine(line, stop);
      }
    });
    child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-65536); });
    child.once('error', e => { clearTimeout(hard); groups.delete(pid); reject(new Error(`cannot start go: ${e.message}`)); });
    child.once('close', (code, signal) => {
      clearTimeout(hard);
      if (pending) onLine(pending, stop);
      groups.delete(pid);
      killGroup(pid, 'SIGKILL');
      resolve({ code, signal, stderr, stopped });
    });
  });
}

const GO_ENV = { GOFLAGS: '-trimpath' };

// ------------------------------------------------------------------ sources

function goFiles(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === 'third_party' || entry.name === 'testdata' || entry.name === 'node_modules' || entry.name.startsWith('.')) continue;
      goFiles(p, out);
    } else if (entry.isFile() && entry.name.endsWith('.go')) out.push(p);
  }
  return out;
}

function testSources(dir) {
  return fs.readdirSync(dir).filter(n => n.endsWith('_test.go')).sort().map(n => ({ file: n, text: fs.readFileSync(path.join(dir, n), 'utf8') }));
}

function skipCount(sources) { return sources.reduce((n, s) => n + (s.text.match(/\bt\.Skip(?:f|Now)?\(/g) || []).length, 0); }

function constraints(sources) {
  const out = [];
  for (const s of sources) for (const m of s.text.matchAll(/^\/\/(?:go:build|\s\+build)\s.*$/gm)) out.push(m[0].trim());
  return out.sort();
}

const SETTER = /\btest\.(?:timeout|parallel)\b|\bruntime\.GOMAXPROCS\(|\bflag\.Set\(|Setenv\(\s*"(?:GOMAXPROCS|GOFLAGS)"/;

function setters(files) {
  const out = [];
  for (const f of files) {
    if (!f.file.endsWith('_test.go')) continue;
    f.text.split('\n').forEach((line, i) => { if (SETTER.test(line)) out.push(`${f.file}:${i + 1}: ${line.trim()}`); });
  }
  return out;
}

function switchCallers(files, name) {
  return files.filter(f => !f.file.startsWith('durable/') && !f.file.endsWith('_test.go') && f.text.includes(name)).map(f => f.file);
}

function cliFiles() {
  return goFiles(CLI).map(p => ({ file: path.relative(CLI, p).split(path.sep).join('/'), text: fs.readFileSync(p, 'utf8') }));
}

// ------------------------------------------------------------------ the acceptance's own durability test

const DURABLE_TEST = 'TestKogenAcceptanceDurableSync';
const DURABLE_SOURCE = `package durable

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// ${DURABLE_TEST} is added by the acceptance harness through go test -overlay.
func ${DURABLE_TEST}(t *testing.T) {
	dir := t.TempDir()
	closed, err := os.Create(filepath.Join(dir, "closed"))
	if err != nil {
		t.Fatal(err)
	}
	closed.Close()
	if err := Sync(closed); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("by default Sync must reach the file: Sync of a closed file returned %v, want os.ErrClosed", err)
	}
	open, err := os.Create(filepath.Join(dir, "open"))
	if err != nil {
		t.Fatal(err)
	}
	defer open.Close()
	if _, err := open.WriteString("record\\n"); err != nil {
		t.Fatal(err)
	}
	if err := Sync(open); err != nil {
		t.Fatalf("Sync of an open written file returned %v", err)
	}
	SkipSyncInTests()
	if err := Sync(closed); err != nil {
		t.Fatalf("after SkipSyncInTests, Sync must return nil without reaching the file: it returned %v", err)
	}
}
`;

function namedOutcome(events, test, command) {
  const mine = events.filter(e => e.Test === test);
  const runs = mine.filter(e => e.Action === 'run').length;
  const ends = mine.filter(e => ENDS.includes(e.Action)).map(e => e.Action);
  const output = mine.filter(e => e.Action === 'output').map(e => e.Output).join('').slice(0, 3000);
  const what = runs === 0 ? 'was absent (it never ran)' : `ran ${runs} time(s) with results ${JSON.stringify(ends)}`;
  assert.ok(runs === 1 && ends.length === 1 && ends[0] === 'pass', `Go test ${test} must run exactly once and pass; \`${command}\` in cli: it ${what}\n${output}`);
}

// ------------------------------------------------------------------ observer controls

function controls(kind) {
  const t0 = Date.parse('2026-10-31T00:00:00Z');
  const at = s => new Date(t0 + s * 1000).toISOString();
  const ev = (s, Package, Action, Test, extra = {}) => ({ Time: at(s), Package, Action, ...(Test ? { Test } : {}), ...extra });
  const B = 'kogen/build', S = 'kogen/shape', O = 'kogen/other';
  const goodEvents = () => [
    ev(0, B, 'start'), ev(0, S, 'start'), ev(0, O, 'start'),
    ev(1, B, 'run', 'TestSerial'), ev(5, B, 'pass', 'TestSerial', { Elapsed: 4 }),
    ev(5, B, 'run', 'TestPar'), ev(5, B, 'pause', 'TestPar'), ev(5, B, 'run', 'TestSkipped'), ev(5, B, 'skip', 'TestSkipped', { Elapsed: 0 }),
    ev(6, B, 'cont', 'TestPar'), ev(6, B, 'run', 'TestPar/sub'), ev(9, B, 'pass', 'TestPar/sub', { Elapsed: 3 }), ev(9, B, 'pass', 'TestPar', { Elapsed: 3 }),
    ev(10, B, 'pass', undefined, { Elapsed: 10 }),
    ev(1, S, 'run', 'TestA'), ev(1, S, 'pause', 'TestA'), ev(2, S, 'cont', 'TestA'), ev(3, S, 'pass', 'TestA', { Elapsed: 1 }), ev(3, S, 'pass', undefined, { Elapsed: 3 }),
    ev(1, O, 'skip', undefined, { Elapsed: 0 })
  ];
  const limits = { serial: { [B]: 30, [S]: 120 }, total: 400 };
  const buildNames = ['TestPar', 'TestPar/sub', 'TestSerial'];
  const observe = (events, extra = {}) => {
    const obs = newObservation();
    for (const e of events) feed(obs, e, Date.parse(e.Time));
    return Object.assign(obs, { code: 0 }, extra);
  };
  const checkGood = obs => {
    checkSerial(obs, B, 30); checkSerial(obs, S, 120); checkAllPassed(obs);
    checkElapsed(obs, B, 400); checkElapsed(obs, S, 400);
    checkInventory(obs, B, 3, nameHash(buildNames), 'TestSkipped');
    checkInventory(obs, S, 1, nameHash(['TestA']), 'none');
  };
  const goodSources = [{ file: 'build/a_test.go', text: '//go:build !race\n\npackage build\nfunc TestX(t *testing.T) { t.Skip("x"); t.Skipf("y") }\n' }, { file: 'build/b.go', text: 'package build\nfunc f() { durable.Sync(nil) }\n' }, { file: 'build/main_test.go', text: 'func TestMain(m *testing.M) { durable.SkipSyncInTests() }\n' }];
  const checkSources = files => {
    const build = files.filter(f => f.file.startsWith('build/') && f.file.endsWith('_test.go'));
    assert.equal(skipCount(build), 2);
    assert.deepEqual(constraints(build), ['//go:build !race']);
    assert.deepEqual(setters(files), []);
    assert.deepEqual(switchCallers(files, 'SkipSyncInTests'), []);
  };
  const goodNamed = [{ Action: 'run', Test: DURABLE_TEST }, { Action: 'pass', Test: DURABLE_TEST }];
  // The live stop rule: nothing is overdue at 20 s; a package still serial past its limit or running past the total is.
  const live = (events, now) => { const obs = observe(events); delete obs.code; return overdue(obs, t0 + now * 1000, limits); };
  const serialOnly = [ev(0, B, 'start'), ev(1, B, 'run', 'TestSerial')];
  const parallelLong = [ev(0, S, 'start'), ev(1, S, 'run', 'TestA'), ev(1, S, 'pause', 'TestA'), ev(2, S, 'cont', 'TestA')];

  checkGood(observe(goodEvents()));
  checkSources(goodSources);
  namedOutcome(goodNamed, DURABLE_TEST, 'control');
  assert.equal(live(serialOnly, 20), null);
  assert.equal(live(parallelLong, 399), null);
  assert.equal(serialSeconds(observe(goodEvents()), B), 6);
  if (kind === 'good') {
    console.log('go-test critical path observers accepted known-good controls');
    return;
  }
  assert.equal(kind, 'bad');
  const mutate = f => { const e = goodEvents(); f(e); return e; };
  const find = (e, pkg, action, test) => e.findIndex(x => x.Package === pkg && x.Action === action && x.Test === test);
  const bad = [
    // build ran serial tests for 40 s
    () => checkGood(observe(mutate(e => { e[find(e, B, 'cont', 'TestPar')].Time = at(40); }))),
    // shape never resumed a parallel test and ran 130 s
    () => checkGood(observe(mutate(e => { e.splice(find(e, S, 'cont', 'TestA'), 1); const i = find(e, S, 'pass', undefined); e[i].Time = at(130); }))),
    // a package failed
    () => checkGood(observe(mutate(e => { e[find(e, O, 'skip', undefined)].Action = 'fail'; }))),
    // go test exited nonzero
    () => checkGood(observe(goodEvents(), { code: 1 })),
    // the run was stopped early
    () => checkGood(observe(goodEvents(), { stopped: { reason: 'control stop', at: t0 + 10000 } })),
    // build took 401 s
    () => checkGood(observe(mutate(e => { e[find(e, B, 'pass', undefined)].Elapsed = 401; }))),
    // build never finished
    () => checkGood(observe(mutate(e => { e.splice(find(e, B, 'pass', undefined), 1); }))),
    // a subtest went missing
    () => checkGood(observe(mutate(e => { e.splice(find(e, B, 'pass', 'TestPar/sub'), 1); }))),
    // a renamed test
    () => checkGood(observe(mutate(e => { e[find(e, B, 'pass', 'TestSerial')].Test = 'TestSerial2'; }))),
    // a new skip
    () => checkGood(observe(mutate(e => { e[find(e, B, 'pass', 'TestPar/sub')].Action = 'skip'; }))),
    // an expected skip that now passes
    () => checkGood(observe(mutate(e => { e[find(e, B, 'skip', 'TestSkipped')].Action = 'pass'; }))),
    // a failing subtest
    () => checkGood(observe(mutate(e => { e[find(e, B, 'pass', 'TestPar/sub')].Action = 'fail'; }))),
    // a test reported passing twice
    () => checkGood(observe(mutate(e => { e.push(ev(9, B, 'pass', 'TestSerial', { Elapsed: 1 })); }))),
    // source scans: one Skip fewer, an added constraint, a timeout setter, GOMAXPROCS, production disabling syncs
    () => checkSources(goodSources.map(f => f.file === 'build/a_test.go' ? { ...f, text: f.text.replace('t.Skipf("y")', '') } : f)),
    () => checkSources([...goodSources, { file: 'build/c_test.go', text: '//go:build linux\n\npackage build\n' }]),
    () => checkSources([...goodSources, { file: 'build/d_test.go', text: 'func init() { flag.Set("test.timeout", "30m") }\n' }]),
    () => checkSources([...goodSources, { file: 'shape/e_test.go', text: 'func TestMain(m *testing.M) { runtime.GOMAXPROCS(16) }\n' }]),
    () => checkSources([...goodSources, { file: 'main.go', text: 'func main() { durable.SkipSyncInTests() }\n' }]),
    // the named durability test: absent, skipped, failed, twice
    () => namedOutcome([], DURABLE_TEST, 'control'),
    () => namedOutcome([{ Action: 'run', Test: DURABLE_TEST }, { Action: 'skip', Test: DURABLE_TEST }], DURABLE_TEST, 'control'),
    () => namedOutcome([{ Action: 'run', Test: DURABLE_TEST }, { Action: 'fail', Test: DURABLE_TEST }], DURABLE_TEST, 'control'),
    () => namedOutcome([...goodNamed, ...goodNamed], DURABLE_TEST, 'control'),
    // the live stop rule
    () => assert.equal(live(serialOnly, 31), null),
    () => assert.equal(live(parallelLong, 401), null)
  ];
  for (const [i, run] of bad.entries()) {
    let rejected = false;
    try { run(); } catch { rejected = true; }
    if (!rejected) { console.log(`go-test critical path observer accepted known-bad control ${i + 1}`); process.exitCode = 2; return; }
  }
  console.log('go-test critical path observers rejected known-bad controls');
  process.exitCode = 1;
}

if (require.main === module) {
  assert.equal(process.argv[2], '--control');
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');

  When('I list the Go tests of package {string} in cli', { timeout: 10 * MIN }, async function (pkg) {
    let out = '';
    const r = await runGo(['test', '-list', '.', pkg], GO_ENV, line => { out += line + '\n'; }, 9 * MIN);
    assert.equal(r.code, 0, `go test -list . ${pkg} in cli failed (${r.code}): ${out}${r.stderr}`);
    this.listed = { pkg, names: out.split('\n').filter(l => /^(Test|Fuzz|Example|Benchmark)\w*$/.test(l)) };
  });

  Then('the listing has {int} tests whose sorted names hash to {string}', function (count, hash) {
    const { pkg, names } = this.listed;
    assert.equal(names.length, count, `${pkg} lists ${names.length} tests, expected ${count}`);
    assert.equal(nameHash(names), hash, `${pkg} lists a different set of test names (hash ${nameHash(names)})`);
  });

  Then('the Go test files in {string} have exactly {int} t.Skip calls and the build constraints {string}', function (dir, count, list) {
    const sources = testSources(path.join(ROOT, dir));
    assert.equal(skipCount(sources), count, `${dir} test files have ${skipCount(sources)} t.Skip calls, expected ${count}`);
    const want = list === 'none' ? [] : list.split(',').map(s => s.trim()).sort();
    assert.deepEqual(constraints(sources), want, `${dir} test files have build constraints ${JSON.stringify(constraints(sources))}`);
  });

  Then('no Go test file under cli outside third_party sets the test timeout, the test parallelism, GOMAXPROCS or GOFLAGS', function () {
    assert.deepEqual(setters(cliFiles()), []);
  });

  When('I run the acceptance\'s own durability test in package {string} in cli', { timeout: 10 * MIN }, async function (pkg) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-durable-acceptance-'));
    try {
      const source = path.join(dir, 'durable_acceptance_test.go');
      fs.writeFileSync(source, DURABLE_SOURCE);
      const overlay = path.join(dir, 'overlay.json');
      fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(CLI, pkg, 'kogen_acceptance_durable_test.go')]: source } }));
      const args = ['test', '-count=1', '-json', '-overlay', overlay, '-run', `^${DURABLE_TEST}$`, pkg];
      const events = [];
      let text = '';
      const r = await runGo(args, GO_ENV, line => { text += line + '\n'; try { events.push(JSON.parse(line)); } catch {} }, 9 * MIN);
      this.durable = { events, command: `GOFLAGS=-trimpath go ${args.join(' ')}`, code: r.code, text: text + r.stderr };
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  Then('that Go test ran exactly once and passed', function () {
    const d = this.durable;
    try {
      namedOutcome(d.events, DURABLE_TEST, d.command);
    } catch (e) {
      e.message += `\ngo test exited ${d.code}:\n${d.text.slice(-3000)}`;
      throw e;
    }
  });

  Then('outside cli\\/durable only Go test files call {string}', function (name) {
    assert.deepEqual(switchCallers(cliFiles(), name), [], `non-test Go files call ${name}`);
  });

  When('I run the go-test check\'s tests uncached in cli with GOMAXPROCS {int}, stopping once kogen\\/build has run serial tests for more than {int} seconds, kogen\\/shape for more than {int} seconds, or either has run for more than {int} seconds',
    { timeout: 25 * MIN }, async function (procs, buildSerial, shapeSerial, total) {
      const obs = newObservation();
      const limits = { serial: { 'kogen/build': buildSerial, 'kogen/shape': shapeSerial }, total };
      let stopRef = null;
      const timer = setInterval(() => { const why = overdue(obs, Date.now(), limits); if (why && stopRef) stopRef(why); }, 1000);
      try {
        const r = await runGo(['test', '-count=1', '-json', './...'], { ...GO_ENV, GOMAXPROCS: String(procs) }, (line, stop) => {
          stopRef = stop;
          if (!line.startsWith('{')) return;
          let ev;
          try { ev = JSON.parse(line); } catch { return; }
          feed(obs, ev, Date.now());
          const why = overdue(obs, Date.now(), limits);
          if (why) stop(why);
        }, 20 * MIN);
        Object.assign(obs, { code: r.code, signal: r.signal, stderr: r.stderr, stopped: r.stopped });
        if (typeof this.log === "function") this.log(summary(obs));
      } finally {
        clearInterval(timer);
      }
      this.check = obs;
    });

  Then('{word} ran its serial tests within {int} seconds', function (name, limit) { checkSerial(this.check, name, limit); });
  Then('every package of the run passed', function () { checkAllPassed(this.check); });
  Then('kogen\\/build and kogen\\/shape each finished within {int} seconds', function (limit) {
    checkElapsed(this.check, 'kogen/build', limit);
    checkElapsed(this.check, 'kogen/shape', limit);
  });
  Then('{word} passed {int} tests and subtests whose sorted names hash to {string} and skipped exactly {string}', function (name, count, hash, skips) {
    checkInventory(this.check, name, count, hash, skips);
  });
}

module.exports = { feed, overdue, serialSeconds, newObservation };
