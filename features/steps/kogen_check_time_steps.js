'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
const hex = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const nonblank = value => typeof value === 'string' && value.trim().length > 0;

// The observer is independent of the six implementation tests. It consumes actual
// go test JSON, including subtest lifecycles; success alone cannot prove execution.
function observeRun(result, names) {
  assert.equal(result.timed, false, 'Go test timed out');
  assert.equal(result.code, 0, `Go test failed: ${result.out}`);
  const events = result.out.trim().split('\n').map(line => JSON.parse(line));
  const states = new Map();
  const selected = new Set(names);
  const active = new Set();
  let peak = 0;
  let packagePass = 0;
  for (const event of events) {
    assert.equal(event.Package, 'kogen/build', 'unexpected package');
    if (!event.Test) {
      assert.notEqual(event.Action, 'fail', 'package failed');
      assert.notEqual(event.Action, 'skip', 'package skipped');
      if (event.Action === 'pass') packagePass++;
      continue;
    }
    const top = event.Test.split('/')[0];
    assert.ok(selected.has(top), `unexpected test ${event.Test}`);
    if (event.Action === 'output') continue;
    let state = states.get(event.Test);
    if (event.Action === 'run') {
      assert.equal(state, undefined, `duplicate run ${event.Test}`);
      state = { pause: 0, cont: 0, pass: 0 };
      states.set(event.Test, state);
      continue;
    }
    assert.ok(state, `event before run: ${event.Test}`);
    assert.equal(state.pass, 0, `event after pass: ${event.Test}`);
    if (event.Action === 'pause') {
      assert.equal(state.pause++, 0, `duplicate pause ${event.Test}`);
    } else if (event.Action === 'cont') {
      assert.equal(state.pause, 1, `resume without pause ${event.Test}`);
      assert.equal(state.cont++, 0, `duplicate resume ${event.Test}`);
      if (selected.has(event.Test)) {
        active.add(event.Test);
        peak = Math.max(peak, active.size);
      }
    } else if (event.Action === 'pass') {
      state.pass++;
      active.delete(event.Test);
    } else {
      assert.fail(`nonpassing or unknown lifecycle ${event.Action}: ${event.Test}`);
    }
  }
  assert.equal(packagePass, 1, 'missing or duplicate package completion');
  for (const name of names) {
    assert.deepEqual(states.get(name), { pause: 1, cont: 1, pass: 1 }, `not scheduled in parallel: ${name}`);
  }
  for (const [name, state] of states) assert.equal(state.pass, 1, `unfinished test ${name}`);
  assert.ok(peak >= 2, 'selected tests did not overlap');
  return states.size;
}

function validateMeasurement(report, expected, baseline, candidate) {
  assert.equal(report.version, expected.version);
  assert.equal(report.baselineRevision, baseline.revision);
  assert.ok(nonblank(report.preparation), 'missing preparation/load context');
  const before = report.baseline;
  const after = report.final;
  assert.equal(before.cliSha256, baseline.digest);
  assert.equal(after.cliSha256, candidate);
  for (const sample of [before, after]) {
    assert.deepEqual(sample.command, expected.command);
    assert.equal(sample.cwd, expected.cwd);
    assert.deepEqual(sample.packages, expected.packages);
    assert.ok(nonblank(sample.startedAt) && sample.startedAt.endsWith('Z') && Number.isFinite(Date.parse(sample.startedAt)), 'missing UTC start');
    assert.ok(Number.isFinite(sample.elapsedSeconds) && sample.elapsedSeconds > 0, 'invalid wall time');
    assert.equal(sample.status, 0);
    assert.ok(nonblank(sample.host.id) && nonblank(sample.host.os) && nonblank(sample.host.arch));
    assert.ok(Number.isInteger(sample.host.cpus) && sample.host.cpus > 0);
    assert.deepEqual(Object.keys(sample.tools).sort(), ['git', 'go', 'node', 'python']);
    for (const value of Object.values(sample.tools)) assert.ok(nonblank(value), 'missing tool version');
    assert.deepEqual(Object.keys(sample.environment).sort(), [...expected.environmentKeys].sort());
    for (const value of Object.values(sample.environment)) assert.ok(value === null || typeof value === 'string', 'environment must record unset or exact value');
    for (const load of [sample.loadBefore, sample.loadAfter]) {
      assert.ok(Array.isArray(load) && load.length === 3 && load.every(n => Number.isFinite(n) && n >= 0), 'missing load averages');
    }
    assert.ok(Number.isInteger(sample.tests.passed) && sample.tests.passed > 0);
    assert.equal(sample.tests.failed, 0);
    assert.equal(sample.tests.skipped, 0);
    assert.ok(hex(sample.tests.inventorySha256), 'missing complete test inventory identity');
    for (const stream of ['stdout', 'stderr']) {
      assert.ok(path.isAbsolute(sample.raw[stream].path), 'raw custody path must be absolute');
      assert.ok(hex(sample.raw[stream].sha256), 'raw custody hash must be SHA-256');
    }
  }
  assert.deepEqual(after.host, before.host, 'different host');
  assert.deepEqual(after.tools, before.tools, 'different tools');
  assert.deepEqual(after.environment, before.environment, 'different recorded environment');
  assert.deepEqual(after.tests, before.tests, 'coverage changed');
  assert.ok(Date.parse(after.startedAt) > Date.parse(before.startedAt), 'final must follow baseline');
  assert.ok(after.elapsedSeconds < before.elapsedSeconds, 'no observed whole-check saving');
}

// Bind the complete current CLI to the approved current687 source, allowing only
// these six scheduling statements. Nothing here changes the checkout or its index.
function cliIdentity(root, allowed, baseline) {
  const listed = execFileSync('git', ['ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', 'cli'], { cwd: root, encoding: 'utf8' });
  const files = [...new Set(listed.split('\0').filter(Boolean))].sort();
  assert.equal(files.length, baseline.files, 'CLI inputs added or removed');
  const original = [];
  const normalized = [];
  for (const file of files) {
    const bytes = fs.readFileSync(path.join(root, file));
    original.push(`${file}\0${sha(bytes)}\n`);
    let content = bytes;
    const tests = allowed.filter(row => row.file === file);
    if (tests.length) {
      let text = bytes.toString('utf8');
      for (const row of tests) {
        assert.match(row.test, /^Test[A-Za-z0-9_]+$/);
        const header = `func ${row.test}(t *testing.T) {\n`;
        assert.equal(text.split(header).length, 2, `missing/duplicate existing test ${row.test}`);
        text = text.replace(header + '\tt.Parallel()\n', header);
      }
      content = Buffer.from(text);
    }
    normalized.push(`${file}\0${sha(content)}\n`);
  }
  assert.equal(sha(normalized.join('')), baseline.digest, 'CLI changed beyond the six permitted scheduling annotations');
  return sha(original.join(''));
}

function controls(kind) {
  const names = ['TestOne', 'TestTwo'];
  const event = (Action, Test) => ({ Package: 'kogen/build', Action, ...(Test ? { Test } : {}) });
  const events = [event('start'), event('run', names[0]), event('pause', names[0]), event('run', names[1]), event('pause', names[1]), event('cont', names[0]), event('cont', names[1]), event('run', 'TestOne/child'), event('pass', 'TestOne/child'), event('pass', names[0]), event('pass', names[1]), event('pass')];
  const result = rows => ({ code: 0, timed: false, out: rows.map(e => JSON.stringify(e)).join('\n') + '\n' });
  const expected = { version: 1, command: ['go', 'test', '-race', '-count=1', '-json', './...'], cwd: 'cli', packages: ['kogen/build'], environmentKeys: ['GOFLAGS'] };
  const baseline = { revision: 'control-revision', digest: 'a'.repeat(64) };
  const candidate = 'b'.repeat(64);
  const sample = (digest, time, seconds) => ({
    cliSha256: digest, command: expected.command, cwd: 'cli', host: { id: 'control', os: 'control', arch: 'control', cpus: 2 },
    tools: { go: 'control', git: 'control', node: 'control', python: 'control' }, environment: { GOFLAGS: null }, startedAt: time,
    loadBefore: [1, 1, 1], loadAfter: [1, 1, 1], elapsedSeconds: seconds, status: 0, packages: ['kogen/build'],
    tests: { passed: 3, failed: 0, skipped: 0, inventorySha256: 'c'.repeat(64) },
    raw: { stdout: { path: '/control/stdout', sha256: 'd'.repeat(64) }, stderr: { path: '/control/stderr', sha256: 'e'.repeat(64) } }
  });
  const report = { version: 1, baselineRevision: baseline.revision, preparation: 'Synthetic observer control, not product evidence', baseline: sample(baseline.digest, '2026-10-24T10:00:00Z', 10), final: sample(candidate, '2026-10-24T10:01:00Z', 5) };
  const checkReport = r => validateMeasurement(r, expected, baseline, candidate);
  observeRun(result(events), names);
  checkReport(report);
  if (kind === 'good') {
    console.log('check-time observers accepted known-good controls');
    return;
  }
  assert.equal(kind, 'bad');
  const badRuns = [
    events.filter(e => !(e.Test === 'TestOne/child' && e.Action === 'pass')),
    [...events, event('pass', 'TestOne/child')],
    events.map(e => e.Test === 'TestOne/child' && e.Action === 'pass' ? { ...e, Action: 'skip' } : e),
    events.map(e => e.Test === 'TestOne/child' && e.Action === 'pass' ? { ...e, Action: 'fail' } : e),
    events.filter(e => e.Test || e.Action !== 'pass'),
    // All tests pass and have pause/cont, but their active intervals do not overlap.
    [event('start'), event('run', names[0]), event('pause', names[0]), event('cont', names[0]), event('pass', names[0]), event('run', names[1]), event('pause', names[1]), event('cont', names[1]), event('pass', names[1]), event('pass')]
  ].map(rows => () => observeRun(result(rows), names));
  badRuns.push(() => observeRun({ ...result(events), code: 1 }, names));
  badRuns.push(() => observeRun({ ...result(events), timed: true }, names));
  const mutations = [
    r => { r.final.elapsedSeconds = 11; },
    r => { r.final.environment.GOFLAGS = '-short'; },
    r => { r.final.cliSha256 = 'f'.repeat(64); },
    r => { r.final.tests.skipped = 1; },
    r => { r.final.tests.inventorySha256 = 'f'.repeat(64); },
    r => { r.final.packages = []; },
    r => { delete r.final.raw.stderr; }
  ];
  for (const mutate of mutations) badRuns.push(() => { const r = JSON.parse(JSON.stringify(report)); mutate(r); checkReport(r); });
  for (const run of badRuns) {
    let rejected = false;
    try { run(); } catch { rejected = true; }
    if (!rejected) { console.log('check-time observer accepted a bad control'); return; }
  }
  console.log('check-time observers rejected known-bad controls');
  process.exitCode = 1;
}

if (require.main === module) {
  assert.equal(process.argv[2], '--control');
  controls(process.argv[3]);
} else {
  const { Given, When, Then } = require('@cucumber/cucumber');
  const { ROOT, run, MIN } = require('./go_driver_support');
  Given('the check-time baseline is revision {string} with {int} CLI files and digest {string}', function (revision, files, digest) {
    this.checkTime = { baseline: { revision, files, digest } };
  });
  Given('only these existing tests may gain a leading parallel scheduling annotation:', function (table) {
    this.checkTime.allowed = table.hashes();
    this.checkTime.candidate = cliIdentity(ROOT, this.checkTime.allowed, this.checkTime.baseline);
  });
  When('I run the selected Go tests with race detection and uncached JSON reporting', { timeout: 5 * MIN }, async function () {
    const names = this.checkTime.allowed.map(row => row.test);
    this.checkTime.result = await run('go', ['test', '-race', '-count=1', '-json', '-run', `^(${names.join('|')})$`, './build'], { cwd: path.join(ROOT, 'cli'), timeout: 4 * MIN });
  });
  Then('all selected tests pause and resume concurrently with every reported subtest passing exactly once', function () {
    observeRun(this.checkTime.result, this.checkTime.allowed.map(row => row.test));
  });
  Then('{string} records a faster comparable whole-Go-check observation for these inputs:', function (file, doc) {
    const report = JSON.parse(fs.readFileSync(path.join(ROOT, file), 'utf8'));
    validateMeasurement(report, JSON.parse(doc), this.checkTime.baseline, this.checkTime.candidate);
  });
}
