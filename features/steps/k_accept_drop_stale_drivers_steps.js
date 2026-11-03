'use strict';
// Acceptance of Intent k-accept-drop-stale-drivers: Kogen's acceptance observes only the built kogen binary.
// The steps read the checkout, run the bundled Cucumber over the Intents' acceptance features and run Go's test
// runner in cli. The judging functions are exported for k_accept_drop_stale_drivers_control.cjs, which loads this
// file with KOGEN_DSD_CONTROL=1 so that no step is registered outside a Cucumber run.

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const OWN_FEATURE = '.kogen/intents/k-accept-drop-stale-drivers/acceptance.feature';
const MIN = 60000;
const tail = text => String(text || '').slice(-4000);

// ------------------------------------------------------------------ the checkout

function missing(rel) {
  try { fs.lstatSync(path.join(ROOT, rel)); return false; } catch (e) { if (e.code === 'ENOENT') return true; throw e; }
}

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name === '.git') continue;
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(file, out);
    else if (entry.isFile()) out.push(file);
  }
  return out;
}

function filesContaining(dir, texts) {
  const hits = [];
  for (const file of walk(path.join(ROOT, dir))) {
    const body = fs.readFileSync(file, 'utf8');
    for (const text of texts) if (body.includes(text)) hits.push(`${path.relative(ROOT, file)} contains ${JSON.stringify(text)}`);
  }
  return hits.sort();
}

const BLOCK_START = /^\s*(Scenario|Scenario Outline|Scenario Template|Example):/;
const BLOCK_STOP = /^\s*(Scenario|Scenario Outline|Scenario Template|Example|Rule|Feature|Background):/;

// scenarioBlocks cuts a feature file into its scenario blocks: from a Scenario (Outline) line up to the next
// Scenario, Rule, Feature or Background line or the end of the file, without trailing blank lines.
function scenarioBlocks(text) {
  const blocks = [];
  let current = null;
  for (const line of text.split('\n')) {
    if (BLOCK_STOP.test(line)) {
      if (current) blocks.push(current);
      current = BLOCK_START.test(line) ? { title: line.replace(BLOCK_START, '').trim(), lines: [line] } : null;
      continue;
    }
    if (current) current.lines.push(line);
  }
  if (current) blocks.push(current);
  return blocks.map(b => {
    const lines = [...b.lines];
    while (lines.length && /^\s*$/.test(lines[lines.length - 1])) lines.pop();
    return { scenario: b.title, sha256: crypto.createHash('sha256').update(lines.join('\n')).digest('hex') };
  });
}

function acceptanceList(text) {
  const lines = text.split('\n');
  const at = lines.indexOf('Acceptance:');
  assert.ok(at >= 0, 'no "Acceptance:" line');
  const items = [];
  for (const line of lines.slice(at + 1)) {
    if (!line.startsWith('- ')) break;
    items.push(line.slice(2));
  }
  return items;
}

// ------------------------------------------------------------------ the bundled Cucumber

function runCucumber(args, env = {}) {
  const base = process.env.KOGEN_CUCUMBER || path.join(ROOT, 'test/acceptance/node_modules');
  const bin = path.join(base, '@cucumber/cucumber/bin/cucumber.js');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-dsd-'));
  const report = path.join(dir, 'report.json');
  const r = spawnSync(process.env.KOGEN_NODE || process.execPath, [bin, ...args, '--format', `json:${report}`], {
    cwd: ROOT, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 10 * MIN, env: { ...process.env, ...env, NODE_PATH: base, KOGEN_DSD_CONTROL: '0' },
  });
  let parsed = null;
  try { parsed = JSON.parse(fs.readFileSync(report, 'utf8')); } catch { parsed = null; }
  fs.rmSync(dir, { recursive: true, force: true });
  const features = args.filter(a => a.endsWith('.feature')).length;
  return { command: `cucumber.js ${args.filter(a => !a.endsWith('.feature')).join(' ')} over ${features} feature file(s) in the checkout`, status: r.status, signal: r.signal, error: r.error, output: `${r.stdout || ''}${r.stderr || ''}`, report: parsed };
}

function scenariosOf(report) {
  const out = [];
  for (const feature of report) {
    for (const element of feature.elements || []) {
      if (element.type === 'background') continue;
      out.push({ feature: feature.uri, scenario: element.name, statuses: (element.steps || []).map(s => s.result && s.result.status) });
    }
  }
  return out;
}

function intentFeatures() {
  const dir = path.join(ROOT, '.kogen/intents');
  return fs.readdirSync(dir).sort()
    .map(slug => `.kogen/intents/${slug}/acceptance.feature`)
    .filter(rel => rel !== OWN_FEATURE && fs.existsSync(path.join(ROOT, rel)));
}

function dryRun() {
  return runCucumber(['--dry-run', '--require', 'features/steps/*.js', ...intentFeatures()]);
}

// judgeDryRun accepts a dry run with exactly `scenarios` scenarios, no ambiguous step and undefined steps only in
// the scenarios counted per feature in `undefinedIn`.
function judgeDryRun(run, scenarios, undefinedIn) {
  assert.ok(!run.error && run.signal === null && (run.status === 0 || run.status === 1) && Array.isArray(run.report),
    `${run.command} ended with status ${run.status}, signal ${run.signal}, error ${run.error} and ${run.report ? 'a report' : 'no report'}:\n${tail(run.output)}`);
  const all = scenariosOf(run.report);
  const ambiguous = all.filter(s => s.statuses.includes('ambiguous')).map(s => `${s.feature}: ${s.scenario}`);
  assert.deepEqual(ambiguous, [], `${run.command}: scenarios with an ambiguous step`);
  const undefinedSeen = {};
  for (const s of all) if (s.statuses.includes('undefined')) undefinedSeen[s.feature] = (undefinedSeen[s.feature] || 0) + 1;
  assert.deepEqual(undefinedSeen, undefinedIn, `${run.command}: scenarios with an undefined step, per feature`);
  assert.equal(all.length, scenarios, `${run.command}: number of scenarios`);
}

function newestArchive() {
  if (process.env.KOGEN_ARCHIVE) return process.env.KOGEN_ARCHIVE;
  const dist = path.join(ROOT, 'dist');
  const archives = (fs.existsSync(dist) ? fs.readdirSync(dist) : []).filter(n => /^kogen-.*\.tar\.gz$/.test(n))
    .map(n => ({ file: path.join(dist, n), mtime: fs.statSync(path.join(dist, n)).mtimeMs })).sort((a, b) => b.mtime - a.mtime);
  assert.ok(archives.length, 'no release archive in dist/: run sh packaging/package.sh');
  return archives[0].file;
}

const escapeRegExp = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

function runKept(rows) {
  const features = [...new Set(rows.map(r => r.feature))];
  const names = [...new Set(rows.map(r => r.scenario))].flatMap(n => ['--name', `^${escapeRegExp(n)}$`]);
  return runCucumber(['--strict', '--require', 'features/steps/*.js', ...names, ...features], { KOGEN_ARCHIVE: newestArchive() });
}

// judgeKeptRun accepts a run that passed every step of exactly the expected scenarios, each the expected number of
// times (an Outline counts once per Examples row), and ran nothing else.
function judgeKeptRun(run, rows) {
  assert.ok(!run.error && run.signal === null && Array.isArray(run.report),
    `${run.command} ended with status ${run.status}, signal ${run.signal}, error ${run.error} and ${run.report ? 'a report' : 'no report'}:\n${tail(run.output)}`);
  const all = scenariosOf(run.report);
  const notPassed = all.filter(s => !s.statuses.length || s.statuses.some(st => st !== 'passed')).map(s => `${s.feature}: ${s.scenario}: ${s.statuses.join(',')}`);
  assert.deepEqual(notPassed, [], `${run.command}: scenarios that did not pass:\n${tail(run.output)}`);
  const seen = {};
  for (const s of all) seen[`${s.feature} | ${s.scenario}`] = (seen[`${s.feature} | ${s.scenario}`] || 0) + 1;
  const expected = {};
  for (const r of rows) expected[`${r.feature} | ${r.scenario}`] = Number(r.runs);
  assert.deepEqual(seen, expected, `${run.command}: scenarios that ran, with their number of runs`);
  assert.equal(run.status, 0, `${run.command} exited ${run.status}:\n${tail(run.output)}`);
}

// ------------------------------------------------------------------ Go's test runner in cli

function goTest(args) {
  const r = spawnSync('go', ['test', ...args], { cwd: path.join(ROOT, 'cli'), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 10 * MIN });
  return { command: `go test ${args.join(' ')} (in cli)`, status: r.status, signal: r.signal, error: r.error, output: `${r.stdout || ''}${r.stderr || ''}` };
}

function runNamedTest(name, pkg) {
  const run = goTest(['-run', `^${name}$`, '-count=1', '-v', pkg]);
  return { ...run, name };
}

// judgeNamedTest accepts a verbose run in which the named top-level test passed exactly once.
function judgeNamedTest(run, name) {
  const at = re => (run.output.match(new RegExp(`^${re} ${escapeRegExp(name)}( |$)`, 'gm')) || []).length;
  const passes = at('--- PASS:');
  const outcome = at('--- FAIL:') ? 'failed' : at('--- SKIP:') ? 'was skipped' : at('=== RUN  ') ? `ran ${at('=== RUN  ')} time(s)` : 'did not run (absent or ran zero times)';
  assert.ok(!run.error && run.signal === null, `${run.command}: ${name} could not run: ${run.error || run.signal}`);
  assert.equal(passes, 1, `${run.command}: ${name} passed ${passes} time(s) and ${outcome}; exit ${run.status}:\n${tail(run.output)}`);
  assert.equal(run.status, 0, `${run.command}: ${name} passed but the run exited ${run.status}:\n${tail(run.output)}`);
}

function listTests(pkg, pattern) {
  return goTest(['-list', pattern, pkg]);
}

// judgeListed accepts a go test -list run that listed exactly these test names (in any order).
function judgeListed(run, names) {
  assert.ok(!run.error && run.signal === null && run.status === 0, `${run.command} exited ${run.status}:\n${tail(run.output)}`);
  const listed = run.output.split('\n').filter(l => /^(Test|Fuzz|Example|Benchmark)\w*$/.test(l)).sort();
  assert.deepEqual(listed, [...names].sort(), `${run.command}: listed tests`);
}

module.exports = { scenarioBlocks, acceptanceList, filesContaining, dryRun, judgeDryRun, scenariosOf, runCucumber, runKept, judgeKeptRun, runNamedTest, judgeNamedTest, listTests, judgeListed };

if (process.env.KOGEN_DSD_CONTROL !== '1') {
  const { When, Then } = require('@cucumber/cucumber');
  const column = (table, name) => table.hashes().map(r => r[name]);

  Then('the checkout has none of these paths:', function (table) {
    const present = column(table, 'path').filter(rel => !missing(rel));
    assert.deepEqual(present, [], 'paths that still exist');
  });

  Then('the checkout has each of these paths:', function (table) {
    const absent = column(table, 'path').filter(rel => missing(rel));
    assert.deepEqual(absent, [], 'paths that are missing');
  });

  Then('the Go files under {string} are exactly these, each declaring package main:', function (dir, table) {
    const files = walk(path.join(ROOT, dir)).filter(f => f.endsWith('.go'));
    assert.deepEqual(files.map(f => path.relative(path.join(ROOT, dir), f)).sort(), column(table, 'file').sort(), `Go files under ${dir}`);
    const other = files.filter(f => !/^package main$/m.test(fs.readFileSync(f, 'utf8'))).map(f => path.relative(ROOT, f));
    assert.deepEqual(other, [], `Go files under ${dir} that do not declare package main`);
  });

  Then('no file under {string} contains any of these texts:', function (dir, table) {
    assert.deepEqual(filesContaining(dir, column(table, 'text')), [], `files under ${dir} that still name a removed driver`);
  });

  Then('the scenarios of {string} are exactly these, with their SHA-256 block digests:', function (rel, table) {
    assert.deepEqual(scenarioBlocks(fs.readFileSync(path.join(ROOT, rel), 'utf8')), table.hashes().map(r => ({ scenario: r.scenario, sha256: r.sha256 })), `scenario blocks of ${rel}`);
  });

  Then('the Acceptance list of {string} is exactly:', function (rel, doc) {
    assert.deepEqual(acceptanceList(fs.readFileSync(path.join(ROOT, rel), 'utf8')), doc.split('\n'), `Acceptance list of ${rel}`);
  });

  When('the bundled Cucumber dry-runs every Intent acceptance feature except this Intent\'s own', { timeout: 10 * MIN }, function () {
    this.dsdDryRun = dryRun();
  });

  Then('the dry run reports {int} scenarios, none with an ambiguous step, and undefined steps only in:', function (count, table) {
    const undefinedIn = {};
    for (const r of table.hashes()) undefinedIn[r.feature] = Number(r.scenarios);
    judgeDryRun(this.dsdDryRun, count, undefinedIn);
  });

  When('the bundled Cucumber runs these kept scenarios with the step library:', { timeout: 15 * MIN }, function (table) {
    this.dsdKeptRows = table.hashes();
    this.dsdKept = runKept(this.dsdKeptRows);
  });

  Then('each of those scenarios passed its number of runs and nothing else ran', function () {
    judgeKeptRun(this.dsdKept, this.dsdKeptRows);
  });

  When('Go runs the test {string} in package {string} of cli', { timeout: 15 * MIN }, function (name, pkg) {
    this.dsdGoRun = runNamedTest(name, pkg);
  });

  Then('that Go test passed exactly once', function () {
    judgeNamedTest(this.dsdGoRun, this.dsdGoRun.name);
  });

  When('Go lists the tests of package {string} of cli matching {string}', { timeout: 10 * MIN }, function (pkg, pattern) {
    this.dsdListed = listTests(pkg, pattern);
  });

  Then('the listed Go tests are exactly:', function (table) {
    judgeListed(this.dsdListed, column(table, 'test'));
  });
}
