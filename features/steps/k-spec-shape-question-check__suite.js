'use strict';
// Reads the specification text this Intent changes and runs named specification scenarios
// through Kogen's own deterministic suite (test/acceptance), judging its Cucumber JSON report
// (every step and hook of every result), not an exit code alone.
// `node features/steps/k-spec-shape-question-check__suite.js --control good|bad` runs the
// observer controls declared in the Intent's Feasibility on a real report of an existing scenario.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '../..');
const suite = path.join(root, 'test/acceptance');
const squash = text => String(text).replace(/\s+/g, ' ').trim();

// The line of each scenario titled exactly so (Scenario or Scenario Outline).
function titledLines(rel, title) {
  const lines = fs.readFileSync(path.join(root, rel), 'utf8').split('\n');
  const found = [];
  lines.forEach((line, i) => {
    const m = line.match(/^\s*Scenario(?: Outline)?:\s*(.*?)\s*$/);
    if (m && m[1] === title) found.push(i + 1);
  });
  return found;
}

// Runs the scenarios titled in rows ({file, title}) in one suite run with a JSON report.
function runScenarios(rows) {
  const located = [];
  const missing = [];
  for (const { file, title } of rows) {
    const found = titledLines(file, title);
    if (found.length === 1) located.push({ file, title, line: found[0] });
    else missing.push(`${file}: ${found.length} scenarios titled "${title}" (expected exactly 1)`);
  }
  assert.deepEqual(missing, [], `the requested specification scenarios cannot be selected; the suite was not run:\n${missing.join('\n')}`);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-question-check-'));
  const report = path.join(dir, 'report.json');
  const env = { ...process.env };
  for (const name of ['NODE_PATH', 'KOGEN_ACCEPTANCE_REPORT', 'KOGEN_ACCEPTANCE_FEATURES']) delete env[name];
  const args = [path.join(suite, 'node_modules/@cucumber/cucumber/bin/cucumber.js'), '--parallel', '4', '--strict', '--tags', 'not @live',
    '--require', 'steps/*.js', '--require', 'support/*.js', '--format', `json:${report}`,
    ...located.map(s => `${path.relative(suite, path.join(root, s.file))}:${s.line}`)];
  const result = spawnSync(process.execPath, args, { cwd: suite, env, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 840000 });
  const run = { located, status: result.status, signal: result.signal, error: result.error && result.error.message,
    output: String(result.stdout || '') + String(result.stderr || ''), report: null };
  try { if (fs.existsSync(report)) run.report = JSON.parse(fs.readFileSync(report, 'utf8')); }
  finally { fs.rmSync(dir, { recursive: true, force: true }); }
  return run;
}

// Accepts the run only when every requested scenario has a result, there are exactly count
// results, every step and hook of each passed and the suite exited 0.
function judge(run, count) {
  assert.ok(Array.isArray(run.report), `the suite wrote no JSON report (exit ${run.status}, signal ${run.signal}, error ${run.error}):\n${run.output.slice(-6000)}`);
  const results = [];
  for (const feature of run.report) {
    const file = path.relative(root, path.resolve(suite, feature.uri));
    for (const el of feature.elements || []) if (el.type === 'scenario') results.push({ file, el });
  }
  const problems = [];
  for (const { file, el } of results) {
    for (const step of [...(el.before || []), ...(el.steps || []), ...(el.after || [])]) {
      const status = step.result && step.result.status;
      if (status === 'passed') continue;
      const message = step.result && step.result.error_message ? `\n    ${step.result.error_message.split('\n').slice(0, 12).join('\n    ')}` : '';
      problems.push(`${file}:${el.line} ${el.name}: ${(step.keyword || '').trim()} ${step.name || '(hook)'} -> ${status}${message}`);
    }
  }
  for (const want of run.located) {
    if (!results.some(x => x.file === want.file && x.el.name === want.title)) problems.push(`${want.file}:${want.line} ${want.title}: no result in the report`);
  }
  assert.deepEqual(problems, [], `specification scenarios did not all pass (suite exit ${run.status}):\n${problems.join('\n')}`);
  assert.equal(results.length, count, `expected ${count} scenario results, the report has ${results.length}:\n${results.map(x => `${x.file}:${x.el.line} ${x.el.name}`).join('\n')}`);
  assert.equal(run.status, 0, `every result passed but the suite exited ${run.status} (signal ${run.signal}, error ${run.error}):\n${run.output.slice(-6000)}`);
}

// Observer controls: good is a real passing report; bad is that real report with its last step
// failed, and with the requested scenario's result removed. Each bad case must be rejected for its reason.
function control(which) {
  const run = runScenarios([{ file: 'spec/features/02-shaping.feature', title: 'An open UI/UX choice becomes a numbered question and nothing is written' }]);
  if (which === 'good') {
    judge(run, 1);
    process.stdout.write('accepted\n');
    return 0;
  }
  try { judge(run, 1); } catch (error) {
    process.stdout.write(`the known-good report needed by the bad control was not accepted:\n${error.message}\n`);
    return 3;
  }
  const cases = [
    ['-> failed', report => { const el = report[0].elements.find(e => e.type === 'scenario'); el.steps[el.steps.length - 1].result = { status: 'failed', error_message: 'control: injected failure' }; }],
    ['no result in the report', report => { report[0].elements = report[0].elements.filter(e => e.type !== 'scenario'); }],
  ];
  for (const [reason, mutate] of cases) {
    const bad = { ...run, report: JSON.parse(JSON.stringify(run.report)) };
    mutate(bad.report);
    let message = null;
    try { judge(bad, bad.report.flatMap(f => f.elements || []).filter(e => e.type === 'scenario').length || 1); } catch (error) { message = error.message; }
    if (message === null || !message.includes(reason)) {
      process.stdout.write(`the observer did not reject the bad report for "${reason}": ${message}\n`);
      return 2;
    }
  }
  process.stdout.write('rejected\n');
  return 1;
}

if (require.main === module) {
  const which = process.argv[2] === '--control' ? process.argv[3] : null;
  if (which !== 'good' && which !== 'bad') {
    process.stdout.write('usage: node features/steps/k-spec-shape-question-check__suite.js --control good|bad\n');
    process.exitCode = 64;
  } else {
    try { process.exitCode = control(which); } catch (error) {
      process.stdout.write(`${error.message}\n`);
      process.exitCode = 4;
    }
  }
} else {
  const { Given, When, Then } = require('@cucumber/cucumber');

  Given('k-spec-shape-question-check: the specification file {string}', function (rel) {
    this.qcSpecPath = rel;
    this.qcSpecText = fs.readFileSync(path.join(root, rel), 'utf8');
  });

  Then('k-spec-shape-question-check: it contains, ignoring whitespace:', function (text) {
    assert.ok(squash(this.qcSpecText).includes(squash(text)), `${this.qcSpecPath} does not contain (whitespace-insensitive):\n${text}`);
  });

  Then('k-spec-shape-question-check: it does not contain {string}', function (text) {
    assert.ok(!this.qcSpecText.includes(text), `${this.qcSpecPath} still contains: ${text}`);
  });

  When('k-spec-shape-question-check: these specification scenarios run through the deterministic acceptance suite:', { timeout: 900000 }, function (table) {
    this.qcRun = runScenarios(table.hashes());
  });

  Then('k-spec-shape-question-check: exactly {int} scenario results exist and every step and hook of each passed', function (count) {
    judge(this.qcRun, count);
  });
}
