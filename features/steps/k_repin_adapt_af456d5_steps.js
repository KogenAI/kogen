'use strict';
// Acceptance steps of k-repin-adapt-af456d5: Kogen's own checks with kogen-loop af456d5.
// `node features/steps/k_repin_adapt_af456d5_steps.js good|bad` runs the observer controls of
// the Go-test and scenario-summary assertions without Cucumber.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '../..');

function tail(text, n = 4000) {
  return text.length > n ? '[...]' + text.slice(-n) : text;
}

function outcome(result) {
  const timedOut = result.error && result.error.code === 'ETIMEDOUT';
  return `exit ${result.status}${result.signal ? `, signal ${result.signal}` : ''}${timedOut ? ', timed out' : result.error ? `, ${result.error.message}` : ''}`;
}

// goTestProblem is why test `name` of package `pkg` did not run exactly once and pass in the
// `go test -json` output of `command`, or null when it did.
function goTestProblem(pkg, name, command, result) {
  const events = [];
  for (const line of String(result.stdout || '').split('\n')) {
    if (!line.startsWith('{')) continue;
    try { events.push(JSON.parse(line)); } catch { /* not a test event */ }
  }
  const own = events.filter(e => e.Package === pkg && e.Test === name);
  const count = action => own.filter(e => e.Action === action).length;
  let state = null;
  if (count('run') === 0) state = 'is absent: it ran zero times';
  else if (count('run') > 1) state = `ran ${count('run')} times`;
  else if (count('skip') > 0) state = 'was skipped';
  else if (count('fail') > 0) state = 'failed';
  else if (count('pass') !== 1) state = 'reported no pass';
  else if (result.error || result.status !== 0) state = 'passed, but its go test command did not succeed';
  if (state === null) return null;
  const output = events.filter(e => e.Package === pkg && e.Action === 'output' && (e.Test === name || String(e.Test || '').startsWith(name + '/')))
    .map(e => e.Output).join('');
  return `${pkg} ${name} ${state}; command: ${command}; ${outcome(result)}\n${tail(output || String(result.stdout || ''))}${result.stderr ? '\nstderr: ' + tail(result.stderr) : ''}`;
}

// scenarioProblem is why the Cucumber run of `command` did not run exactly one scenario,
// `name`, that passed, or null when it did.
function scenarioProblem(name, command, result) {
  const output = String(result.stdout || '') + String(result.stderr || '');
  let state = null;
  if (result.error || result.status !== 0) state = 'did not pass';
  else if (!/(^|\n)1 scenario \(1 passed\)\n/.test(output)) state = 'did not run as exactly one passing scenario';
  if (state === null) return null;
  return `building scenario "${name}" ${state}; command: ${command}; ${outcome(result)}\n${tail(output)}`;
}

function events(name, actions) {
  return actions.map(Action => JSON.stringify({ Package: 'kogen/build', Test: name, Action })).join('\n') + '\n';
}

function controls(mode) {
  const test = 'TestKRevodGatePartsUnchanged';
  const command = `(cd cli && go test -json -count=1 ./build -run '^(${test})$')`;
  const scenario = 'Completed builder and independent reviewer windows reset locally';
  const run = '(cd test/acceptance && npx cucumber-js ...)';
  const good = [
    goTestProblem('kogen/build', test, command, { status: 0, stdout: events(test, ['run', 'pass']) }),
    scenarioProblem(scenario, run, { status: 0, stdout: '.....\n\n1 scenario (1 passed)\n21 steps (21 passed)\n' }),
  ];
  const bad = [
    goTestProblem('kogen/build', test, command, { status: 0, stdout: events(test, ['run', 'skip']) }),
    goTestProblem('kogen/build', test, command, { status: 0, stdout: events('TestOther', ['run', 'pass']) }),
    goTestProblem('kogen/build', test, command, { status: 1, stdout: events(test, ['run', 'pass']) }),
    goTestProblem('kogen/build', test, command, { status: 0, stdout: events(test, ['run', 'pass', 'run', 'pass']) }),
    goTestProblem('kogen', test, command, { status: 0, stdout: events(test, ['run', 'pass']) }),
    scenarioProblem(scenario, run, { status: 0, stdout: '0 scenarios\n0 steps\n' }),
    scenarioProblem(scenario, run, { status: 1, stdout: '1 scenario (1 failed)\n21 steps (10 passed, 10 skipped, 1 failed)\n' }),
    scenarioProblem(scenario, run, { status: 0, stdout: '2 scenarios (2 passed)\n' }),
  ];
  const accepted = mode === 'good' ? good.every(p => p === null) : !bad.every(p => p !== null);
  console.log(accepted ? 'accepted' : 'rejected');
  if (!accepted) process.exitCode = 1;
}

function walk(dir, keep, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (!['node_modules', '.git', 'third_party'].includes(entry.name)) walk(full, keep, out);
    } else if (entry.isFile() && keep(full)) out.push(full);
  }
  return out;
}

// kogenTests are Kogen's own test files: Go tests and test data in cli/ (not the vendored
// loop), the scenario suite's steps and support, the specification's features and the
// Intent steps other than this file.
function kogenTests() {
  const self = path.resolve(__filename);
  return [
    ...walk(path.join(root, 'cli'), f => f.endsWith('_test.go') || f.split(path.sep).includes('testdata')),
    ...['test/acceptance/steps', 'test/acceptance/support', 'spec/features', 'features/steps']
      .flatMap(dir => walk(path.join(root, dir), f => path.resolve(f) !== self)),
  ];
}

function paragraph(file, id) {
  const lines = fs.readFileSync(path.join(root, file), 'utf8').split('\n');
  const start = lines.findIndex(line => line.startsWith(`**${id} `));
  assert.ok(start >= 0, `${file} has no paragraph starting "**${id} "`);
  const end = lines.findIndex((line, i) => i > start && line.trim() === '');
  return lines.slice(start, end < 0 ? lines.length : end).join('\n');
}

function scenarioBlock(name) {
  const file = 'spec/features/04-building.feature';
  const lines = fs.readFileSync(path.join(root, file), 'utf8').split('\n').map(line => line.trim());
  const start = lines.indexOf(`Scenario: ${name}`);
  assert.ok(start >= 0, `${file} has no scenario "${name}"`);
  let end = start + 1;
  while (end < lines.length && !/^(Scenario|Scenario Outline|Rule|Examples):/.test(lines[end]) && !lines[end].startsWith('@')) end++;
  return { file, tags: lines[start - 1], steps: lines.slice(start + 1, end).filter(line => line !== '' && !line.startsWith('#')) };
}

if (require.main === module) {
  controls(process.argv[2]);
} else {
  const { When, Then } = require('@cucumber/cucumber');

  When('af456d5 adaptation runs these Go tests:', { timeout: 115000 }, function (table) {
    const goModule = fs.readFileSync(path.join(root, 'cli/go.mod'), 'utf8').match(/^module (\S+)$/m)[1];
    const rows = table.hashes();
    for (const row of rows) {
      assert.match(row.test, /^Test[A-Za-z0-9_]+$/, `test name ${row.test}`);
      assert.match(row.package, /^\.(\/[a-z0-9_]+)*$/, `package ${row.package}`);
    }
    const packages = [...new Set(rows.map(row => row.package))];
    const pattern = `^(${[...new Set(rows.map(row => row.test))].join('|')})$`;
    const args = ['test', '-json', '-count=1', ...packages, '-run', pattern];
    const command = `(cd cli && go ${args.slice(0, -1).join(' ')} '${pattern}')`;
    const result = spawnSync('go', args, { cwd: path.join(root, 'cli'), encoding: 'utf8', timeout: 110000, maxBuffer: 256 * 1024 * 1024 });
    this.af456d5Go = rows.map(row => ({ pkg: row.package === '.' ? goModule : `${goModule}/${row.package.slice(2)}`, test: row.test, command, result }));
  });

  Then('af456d5 adaptation observed each of those Go tests run once and pass', function () {
    assert.ok(this.af456d5Go, 'no Go tests were run');
    const problems = this.af456d5Go.map(({ pkg, test, command, result }) => goTestProblem(pkg, test, command, result)).filter(Boolean);
    assert.ok(problems.length === 0, problems.join('\n\n'));
  });

  Then("af456d5 adaptation finds none of these texts in Kogen's tests outside the vendored loop:", function (table) {
    const texts = table.hashes().map(row => row.text);
    const found = [];
    for (const file of kogenTests()) {
      fs.readFileSync(file, 'utf8').split('\n').forEach((line, i) => {
        for (const text of texts) if (line.includes(text)) found.push(`${path.relative(root, file)}:${i + 1} contains "${text}"`);
      });
    }
    assert.ok(found.length === 0, `Kogen's tests still make claims about the loop's default instructions:\n${found.join('\n')}`);
  });

  Then('af456d5 adaptation finds the {string} paragraph of {string} contains {string}', function (id, file, text) {
    assert.ok(paragraph(file, id).includes(text), `the ${id} paragraph of ${file} does not contain "${text}"`);
  });

  Then('af456d5 adaptation finds the {string} paragraph of {string} does not contain {string}', function (id, file, text) {
    assert.ok(!paragraph(file, id).includes(text), `the ${id} paragraph of ${file} still contains "${text}"`);
  });

  When('af456d5 adaptation runs the building scenario {string}', { timeout: 115000 }, function (name) {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const args = ['cucumber-js', '--strict', '--tags', 'not @live', '--require', 'steps/*.js', '--require', 'support/*.js',
      '--name', `^${escaped}$`, '../../spec/features/04-building.feature'];
    const env = { ...process.env };
    delete env.NODE_PATH;
    const result = spawnSync('npx', args, { cwd: path.join(root, 'test/acceptance'), env, encoding: 'utf8', timeout: 110000, maxBuffer: 64 * 1024 * 1024 });
    const command = `(cd test/acceptance && npx ${args.map(a => (/^[\w./@-]+$/.test(a) ? a : `'${a}'`)).join(' ')})`;
    this.af456d5Scenario = { name, command, result };
  });

  Then('af456d5 adaptation finds that building scenario tagged {string} with these steps:', function (tags, table) {
    assert.ok(this.af456d5Scenario, 'no building scenario was run');
    const { file, tags: actualTags, steps } = scenarioBlock(this.af456d5Scenario.name);
    assert.equal(actualTags, tags, `${file}: scenario "${this.af456d5Scenario.name}" tags`);
    const wanted = table.hashes().map(row => row.step);
    const patterns = wanted.map(step => new RegExp('^' + step.split('<n>').map(part => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('\\d+') + '$'));
    const mismatch = steps.length !== patterns.length || patterns.some((re, i) => !re.test(steps[i]));
    assert.ok(!mismatch, `${file}: scenario "${this.af456d5Scenario.name}" no longer proves what it did\nwant:\n${wanted.join('\n')}\ngot:\n${steps.join('\n')}`);
  });

  Then('af456d5 adaptation observed that building scenario run once and pass', function () {
    assert.ok(this.af456d5Scenario, 'no building scenario was run');
    const { name, command, result } = this.af456d5Scenario;
    const problem = scenarioProblem(name, command, result);
    assert.ok(problem === null, problem);
  });
}
